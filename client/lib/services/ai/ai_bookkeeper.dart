import 'dart:convert';
import 'dart:io';

import '../../ai/core/ai_extraction_context.dart';
import '../../ai/core/ai_extraction_engine.dart';
import '../../ai/core/bill_info.dart';
import '../../ai/core/prompt_builder.dart';
import '../../data/db.dart' as schema;
import '../../data/repositories/base_repository.dart';
import '../../l10n/app_localizations.dart';
import '../billing/bill_creation_service.dart';
import '../billing/pending_candidate.dart';
import '../data/tag_seed_service.dart';
import '../system/logger_service.dart';
import '../automation/auto_book_event.dart';
import '../automation/auto_book_event_store.dart';

import '../automation/auto_book_policy.dart';
import '../automation/auto_book_trace.dart';
import '../automation/semantic_dedup_matcher.dart';
import 'bookkeeping_result.dart';

/// AI 记账应用层 (Layer 2)。
///
/// 5 个调用渠道(对话 / 图片 / 语音 / 自动截图 / 自动通知文本)的统一入口。
/// 内部:
/// 1. 构造 [AiExtractionContext](查用户可用分类 + 同币种账户 + 自定义 prompt)
/// 2. 调底座 [AiExtractionEngine] 拿 `List<BillInfo>`
/// 3. 逐笔通过 [BillCreationService.createFromBill] 落库
/// 4. 聚合成 [BookkeepingResult] 返回
///
/// 渠道层只需 `bookkeeper.fromText/fromImage/fromAudio(...)` 一行调用,
/// 不再重复实现「调 extract → createTx → 同步」样板。
class AiBookkeeper {
  static const String _tag = 'AiBookkeeper';

  final BaseRepository _repo;
  final AiExtractionEngine _engine;
  final BillCreationService _persister;
  final AutoBookEventStore? _eventStore;
  static const _semanticPolicy = AutoBookPolicy();
  static const _dedupMatcher = SemanticDedupMatcher();

  const AiBookkeeper({
    required BaseRepository repository,
    required AiExtractionEngine engine,
    required BillCreationService persister,
    AutoBookEventStore? eventStore,
  })  : _repo = repository,
        _engine = engine,
        _persister = persister,
        _eventStore = eventStore;

  /// 文本记账(对话 / 自动通知文本)
  ///
  /// [billGuard] 前置过滤段，截图/自动路径传入 [PromptBuilder.billGuardForImage]，
  /// 聊天等主动输入传空字符串。
  /// [autoBookFlow] 仅自动路径(截图/短信/支付通知)传:低置信/大额/疑似重复
  /// 不进账,改为进「待确认」队列(M2 候选制);主动路径(对话/语音/选图)传 null。
  Future<BookkeepingResult> fromText({
    required String text,
    required int ledgerId,
    required List<String> billingTypes,
    String billGuard = '',
    AppLocalizations? l10n,
    AutoBookFlow? autoBookFlow,
    String source = 'auto',

    /// M4:来源渠道(短信 sender / 通知 pkg 解析出的渠道名),AI 账户名未匹配
    /// 时按渠道→账户映射回退;手动/主动路径传 null。
    String? sourceChannel,

    /// 账单级去重(见 [_persistAll])。
    Future<bool> Function(BillInfo bill)? skipIfProcessed,

    /// 原始文本证据，仅用于自动路径的语义硬闸门；不会写入交易。
    String? evidenceText,
  }) async {
    final context = await AiExtractionContext.forLedger(
      repository: _repo,
      ledgerId: ledgerId,
    );
    final outcome = await _engine.extractFromText(
      text,
      context,
      billGuard: billGuard,
    );
    switch (outcome.status) {
      case ExtractionStatus.duplicate:
        // 服务端识别前判重命中(账单唯一标识已存在):本次没有调用 LLM。
        // duplicateCount>0 → handled=true:自动通道静默(不发通知、不进待
        // 确认队列),监控层把事件置为 duplicate 终态。
        logger.info(
          _tag,
          '服务端判重命中,跳过记账',
          'identifier=${outcome.matchedIdentifier}',
        );
        return const BookkeepingResult(duplicateCount: 1);
      case ExtractionStatus.retryableFailure:
        // M1-2:临时失败(Relay 未就绪 / 网络 / 超时)绝不能退化成「空
        // bills」,否则自动通道会把事件当「非账单」终结并 ACK 原生队列,
        // 原始证据永久丢失。
        logger.warning(
          _tag,
          '文本识别临时失败,保留事件等待重试',
          'code=${outcome.errorCode}',
        );
        return const BookkeepingResult(retryable: true);
      case ExtractionStatus.permanentFailure:
        // 重试也不会好(参数非法 / 上游拒绝 / 响应不可解析):同样不能当
        // 「非账单」,但不再走退避重试,事件直接进 failed 让用户可见。
        logger.warning(
          _tag,
          '文本识别永久失败,不再重试',
          'code=${outcome.errorCode}',
        );
        return const BookkeepingResult(permanentFailure: true);
      case ExtractionStatus.success:
      case ExtractionStatus.noBill:
        break;
    }
    return _persistAll(
      bills: outcome.bills,
      ledgerId: ledgerId,
      billingTypes: billingTypes,
      l10n: l10n,
      autoBookFlow: autoBookFlow,
      source: source,
      sourceChannel: sourceChannel,
      skipIfProcessed: skipIfProcessed,
      evidenceText: evidenceText,
    );
  }

  /// 图片记账(相册 / 相机 / 自动截图)
  ///
  /// [billGuard] 前置过滤段，截图/自动路径传入 [PromptBuilder.billGuardForImage]，
  /// 手动选图等主动输入传空字符串。
  /// [onSaved] 每成功保存一笔就回调一次(传入 txId 和这笔在结果中的序号),
  /// 常用于给每笔挂图片附件 — 用户期望多笔记账时每笔都能溯源到原图,所以
  /// 默认行为是「**每笔都挂**」,而非只挂首笔。
  /// [autoBookFlow] 见 [fromText]。
  Future<BookkeepingResult> fromImage({
    required File image,
    required int ledgerId,
    required List<String> billingTypes,
    String billGuard = '',
    AppLocalizations? l10n,
    Future<void> Function(int txId, int index)? onSaved,
    AutoBookFlow? autoBookFlow,
    String source = 'auto',

    /// 图片原始证据无法稳定转成文本时可由调用方传入 OCR/摘要提示。
    String? evidenceText,
  }) async {
    final context = await AiExtractionContext.forLedger(
      repository: _repo,
      ledgerId: ledgerId,
    );
    final bills = await _engine.extractFromImage(
      image,
      context,
      billGuard: billGuard,
    );
    return _persistAll(
      bills: bills,
      ledgerId: ledgerId,
      billingTypes: billingTypes,
      l10n: l10n,
      onSaved: onSaved,
      autoBookFlow: autoBookFlow,
      source: source,
      evidenceText: evidenceText,
    );
  }

  /// 语音记账。第二项返回值是 STT 识别出的原始文本(便于 UI 在记账失败时
  /// 展示「未识别账单信息: {text}」)。
  Future<({BookkeepingResult result, String? recognizedText})> fromAudio({
    required File audio,
    required int ledgerId,
    required List<String> billingTypes,
    AppLocalizations? l10n,
  }) async {
    final context = await AiExtractionContext.forLedger(
      repository: _repo,
      ledgerId: ledgerId,
    );
    final audioResult = await _engine.extractFromAudio(
      audio,
      context,
    );
    final result = await _persistAll(
      bills: audioResult.bills,
      ledgerId: ledgerId,
      billingTypes: billingTypes,
      l10n: l10n,
    );
    return (result: result, recognizedText: audioResult.recognizedText);
  }

  /// 仅语音转文字(快捷指令首步,不走提取)
  Future<String?> speechToText(File audio) => _engine.speechToText(audio);

  /// 确认待确认候选入账(待确认页「入账」按钮)。成功落库后出队。
  /// 入账失败(数据库异常等)保留候选,返回 null。
  Future<int?> approvePending(
    PendingCandidate candidate, {
    AppLocalizations? l10n,
    bool forceCreate = false,
  }) async {
    final ledgerId = candidate.bill.ledgerId;
    if (ledgerId == null) return null;

    // 用户重复点击/进程在“交易已写入、候选尚未删除”窗口被杀时，优先
    // 返回已经记录的结果，不能再创建第二笔。
    if (_eventStore != null &&
        candidate.eventKey != null &&
        candidate.eventKey!.isNotEmpty) {
      try {
        final event = await _eventStore.findByEventKey(candidate.eventKey!);
        if (event?.state == AutoBookState.booked.value &&
            event?.transactionId != null) {
          await PendingCandidateStore().remove(candidate.id);
          return event!.transactionId;
        }
      } catch (e, st) {
        logger.warning(_tag, '读取候选事件幂等结果失败,继续语义检查', '$e');
        logger.debug(_tag, '读取候选事件堆栈', st);
      }
    }

    // 候选可能已经被短信/通知/导入等其它入口落库；默认强语义命中时
    // 合并到已有 canonical transaction。用户选择“仍记一笔”时跳过这层，
    // 但仍保留上面的同一 event 精确幂等保护。
    if (!forceCreate) {
      try {
        final match = await _dedupMatcher.findBest(
          repository: _repo,
          ledgerId: ledgerId,
          bill: candidate.bill,
          eventStore: _eventStore,
        );
        final strongMatch = match;
        if (strongMatch != null && strongMatch.isStrong) {
          await PendingCandidateStore().remove(candidate.id);
          await _markCandidateEvent(
            candidate,
            state: AutoBookState.duplicate,
            reason:
                'approve_reconciled:${strongMatch.score.toStringAsFixed(3)}',
          );
          return strongMatch.transactionId;
        }
      } catch (e, st) {
        // 判重查询失败不阻断用户确认；创建失败仍保留候选。
        logger.warning(_tag, '确认前语义去重查询失败,继续创建', '$e');
        logger.debug(_tag, '确认前语义去重堆栈', st);
      }
    }

    try {
      final txId = await _persister.createFromBill(
        bill: candidate.bill,
        ledgerId: ledgerId,
        billingTypes: candidate.billingTypes,
        l10n: l10n,
      );
      if (txId != null) {
        await PendingCandidateStore().remove(candidate.id);
        await _markCandidateEvent(
          candidate,
          state: AutoBookState.booked,
          transactionId: txId,
        );
      }
      return txId;
    } catch (e, st) {
      // 失败不删除候选；用户可以修正账户/分类或稍后重试。
      logger.error(_tag, '确认候选入账失败,保留候选', e, st);
      return null;
    }
  }

  /// 拒绝待确认候选(从队列删除)，同时保留事件状态审计。
  Future<void> rejectPending(PendingCandidate candidate) async {
    await PendingCandidateStore().remove(candidate.id);
    await _markCandidateEvent(
      candidate,
      state: AutoBookState.ignored,
      reason: 'user_rejected',
    );
  }

  /// 撤销强判重合并(P1-1):把 duplicate 子项按留存的结构化摘要重建为
  /// 待确认候选,用户可选择「仍记一笔」;事件回到 pending。返回重建候选数
  /// (0 = 没有可恢复内容:子项缺失/摘要已清/候选已在队列)。
  Future<int> undoMerge(schema.AutoBookEvent event) async {
    final store = _eventStore;
    if (store == null) return 0;
    final items = await store.itemsForEvent(event.id);
    var rebuilt = 0;
    for (final item in items) {
      if (item.state != AutoBookState.duplicate.value) continue;
      if (item.transactionId == null) continue;
      final raw = item.billJson;
      if (raw == null || raw.isEmpty) continue;
      final Map<String, dynamic> payload;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        payload = Map<String, dynamic>.from(decoded.cast<String, dynamic>());
      } catch (_) {
        continue;
      }
      final billPayload = payload['bill'] is Map
          ? Map<String, dynamic>.from(payload['bill'] as Map)
          : payload;
      final BillInfo bill;
      try {
        bill = BillInfo.fromJson(billPayload);
      } catch (_) {
        continue;
      }
      if (bill.amount == null || bill.amount!.abs() <= 0) continue;
      final ledgerId = bill.ledgerId ?? event.ledgerId;
      if (ledgerId == null) continue;
      final added = await PendingCandidateStore().add(PendingCandidate(
        id: PendingCandidate.candidateId(bill),
        bill: bill.copyWith(ledgerId: ledgerId),
        billingTypes: _billingTypesForSource(event.source),
        source: event.source,
        capturedAt: DateTime.now(),
        reason: 'duplicate',
        eventKey: event.eventKey,
        eventItemIndex: item.itemIndex,
        semanticKey: item.semanticKey,
        matchedTransactionId: item.transactionId,
      ));
      if (added) rebuilt++;
    }
    if (rebuilt > 0) {
      await store.mark(
        const AutoBookEventUpdate(
          state: AutoBookState.pending,
          reason: 'unmerge_requested',
        ),
        eventId: event.id,
      );
      logger.info(_tag, '强判重合并已撤销,候选重建进待确认',
          'event=${event.eventKey}, rebuilt=$rebuilt');
    }
    return rebuilt;
  }

  List<String> _billingTypesForSource(String source) {
    final primary = switch (source) {
      'sms' => TagSeedService.billingTypeSms,
      'notification' => TagSeedService.billingTypeNotification,
      'screenText' || 'screen' => TagSeedService.billingTypeScreen,
      'screenshot' ||
      'image' ||
      'sharedImage' =>
        TagSeedService.billingTypeImage,
      _ => TagSeedService.billingTypeAi,
    };
    return [primary, TagSeedService.billingTypeAi];
  }

  Future<void> _markCandidateEvent(
    PendingCandidate candidate, {
    required AutoBookState state,
    int? transactionId,
    String? reason,
  }) async {
    final key = candidate.eventKey;
    if (_eventStore == null || key == null || key.isEmpty) return;
    try {
      final event = await _eventStore.findByEventKey(key);
      if (event == null) return;
      await _eventStore.mark(
        AutoBookEventUpdate(
          state: state,
          transactionId: transactionId,
          reason: reason,
        ),
        eventId: event.id,
      );
    } catch (e, st) {
      logger.warning(_tag, '更新候选关联事件失败(不影响用户操作)', '$e');
      logger.debug(_tag, '更新候选关联事件堆栈', st);
    }
  }

  // ============================================================
  // 内部:分流(自动→候选 / 主动→落库) + 聚合结果
  // ============================================================

  /// 把引擎层的裸调用报告补上当前账本 id(本地 int → 字符串)后交给注入的
  Future<BookkeepingResult> _persistAll({
    required List<BillInfo> bills,
    required int ledgerId,
    required List<String> billingTypes,
    AppLocalizations? l10n,
    Future<void> Function(int txId, int index)? onSaved,
    AutoBookFlow? autoBookFlow,
    String source = 'auto',
    String? sourceChannel,

    /// 账单级去重:落库前对每笔调用,返回 true 则跳过该笔(不落库、不 failed、
    /// 不 awaiting)。用于「同一账单重复进入详情页」这类页面文本指纹挡不住
    /// 的场景(见 AutoBillingService.processScreenText 的账单指纹)。
    Future<bool> Function(BillInfo bill)? skipIfProcessed,
    String? evidenceText,
  }) async {
    if (bills.isEmpty) {
      return BookkeepingResult.empty;
    }

    // M2 候选制:分流基准数据只取一次(90 天一次拉取,M3 基线共用)。
    // 用可变副本维护本批已经处理的账单，防止模型一次返回重复对象时
    // 第一笔入账后第二笔仍拿旧 pool 判定为“无重复”。
    List<BillInfo> recentBills = const [];
    List<BillInfo> pendingBills = const [];
    if (autoBookFlow != null) {
      recentBills = (await _loadBaseline(ledgerId)) ?? const [];
      pendingBills =
          (await autoBookFlow.store.load()).map((c) => c.bill).toList();
    }
    final recentComparison = List<BillInfo>.from(recentBills);
    final pendingComparison = List<BillInfo>.from(pendingBills);
    var awaitingCount = 0;
    var ignoredCount = 0;
    var duplicateCount = 0;
    var shadowCount = 0;
    var pendingAbsAmount = 0.0;
    final duplicateTransactionIds = <int>[];

    final eventStore = autoBookFlow?.eventStore;
    final eventKey = autoBookFlow?.eventKey;
    dynamic eventRecord;
    var priorEventItems = <int, dynamic>{};
    if (eventStore != null && eventKey != null && eventKey.isNotEmpty) {
      try {
        eventRecord = await eventStore.findByEventKey(eventKey);
        if (eventRecord != null) {
          final items = await eventStore.itemsForEvent(eventRecord.id as int);
          priorEventItems = {for (final item in items) item.itemIndex: item};
        }
      } catch (e, st) {
        logger.warning(_tag, '读取自动记账事件失败,仅跳过子项审计', '$e');
        logger.debug(_tag, '读取自动记账事件堆栈', st);
      }
    }

    Future<void> recordEventItem({
      required int index,
      required BillInfo bill,
      required String state,
      int? transactionId,
      String? reason,
      Map<String, dynamic>? metadata,
    }) async {
      if (eventRecord == null || eventStore == null) return;
      try {
        await eventStore.upsertItem(
          eventId: eventRecord.id,
          itemIndex: index,
          semanticKey: SemanticDedupMatcher.semanticKey(bill),
          eventKind: bill.eventKind?.name,
          settlementStatus: bill.settlementStatus?.name,
          amount: bill.amount,
          currency: bill.currency,
          merchant: bill.merchant ?? bill.note,
          transactionId: transactionId,
          state: state,
          bill: {
            ...bill.toJson(),
            if (metadata != null) ...metadata,
          },
          reason: reason,
        );
      } catch (e, st) {
        // 审计表写失败不能回滚已经成功的交易；主事件仍由 Coordinator 维护。
        logger.warning(_tag, '写入自动记账子项失败(不影响主流程)', '$e');
        logger.debug(_tag, '写入自动记账子项堆栈', st);
      }
    }

    final saved = <BillInfo>[];
    final txIds = <int>[];
    var failed = 0;
    // M3-5:整批账单共享分类池 / 账户池 / 标签映射 / 账本币种,"一张图 10 笔"
    // 不再把同一批查询做 10 遍。生命周期严格限定在本次 _persistAll 内,
    // 不要提升到字段(见 [BillCreationContext] 的缓存失效说明)。
    final billContext = BillCreationContext();

    for (var i = 0; i < bills.length; i++) {
      final bill = _semanticPolicy.normalizeForPersistence(
        bill: bills[i].copyWith(ledgerId: ledgerId),
        evidenceText: evidenceText,
      );

      // 事件可能在“交易已写入、整批尚未完成”时被进程杀死，父事件会在
      // lease 到期后进入 retry。先恢复已经成功的子项，避免重试再次创建；
      // pending/ignored 子项也要保持原决定，避免重复添加候选或重新送 AI。
      final priorItem = priorEventItems[i];
      if (priorItem != null) {
        final priorState = AutoBookStateValue.parse(priorItem.state as String?);
        final priorTransactionId = priorItem.transactionId as int?;
        if ((priorState == AutoBookState.booked ||
                priorState == AutoBookState.duplicate) &&
            priorTransactionId != null) {
          duplicateCount++;
          duplicateTransactionIds.add(priorTransactionId);
          logger.debug(
            _tag,
            '重试恢复已完成账单子项,跳过创建',
            'index=$i tx=$priorTransactionId state=${priorState.value}',
          );
          continue;
        }
        if (priorState == AutoBookState.ignored) {
          ignoredCount++;
          continue;
        }
        if (priorState == AutoBookState.pending && autoBookFlow != null) {
          final reason =
              (priorItem.reason as String?) ?? 'pending_confirmation';
          await autoBookFlow.store.add(PendingCandidate(
            id: PendingCandidate.candidateId(bill),
            bill: bill,
            billingTypes: billingTypes,
            source: source,
            capturedAt: DateTime.now(),
            reason: reason,
            eventKey: eventKey,
            eventItemIndex: i,
            semanticKey: SemanticDedupMatcher.semanticKey(bill),
            matchedTransactionId: priorTransactionId,
          ));
          awaitingCount++;
          pendingComparison.add(bill);
          continue;
        }
      }

      // 账单级去重(调用方注入,如屏幕文本的「金额+备注+日期」指纹):
      // 命中即视为已入账过,直接跳过,不落库也不进候选。
      if (skipIfProcessed != null && await skipIfProcessed(bill)) {
        duplicateCount++;
        await recordEventItem(
          index: i,
          bill: bill,
          state: AutoBookState.duplicate.value,
          reason: 'already_processed',
        );
        logger.info(_tag, '第 ${i + 1} 笔命中账单级去重,跳过', _billDiagnostic(bill));
        continue;
      }

      final policy = _semanticPolicy.evaluate(
        bill: bill,
        source: source,
        evidenceText: evidenceText,
        automatic: autoBookFlow != null,
      );
      if (autoBookFlow != null && policy.isIgnored) {
        ignoredCount++;
        await recordEventItem(
          index: i,
          bill: bill,
          state: AutoBookState.ignored.value,
          reason: policy.reason,
        );
        logger.info(_tag, '第 ${i + 1} 笔被语义硬闸门忽略: ${policy.reason}');
        continue;
      }

      SemanticDedupMatch? semanticMatch;
      if (autoBookFlow != null) {
        try {
          semanticMatch = await _dedupMatcher.findBest(
            repository: _repo,
            ledgerId: ledgerId,
            bill: bill,
            eventStore: eventStore,
            sourceChannel: sourceChannel,
          );
        } catch (e, st) {
          // 判重失败不阻断自动记账；退回候选规则，并保留诊断信息。
          logger.warning(_tag, '语义去重查询失败,降级到基础规则', '$e');
          logger.debug(_tag, '语义去重堆栈', st);
        }
      }

      final basicDuplicate = AutoBookRule.looksLikeDuplicate(
        bill,
        [...recentComparison, ...pendingComparison],
      );
      final semanticDuplicate = semanticMatch?.isPossible ?? false;
      final duplicate = basicDuplicate || semanticDuplicate;

      // 影子模式只观察识别、语义策略和判重结果，不创建交易，也不写入候选。
      // 事件子项仍保留脱敏后的结构化摘要，便于发布前统计和回溯。
      if (autoBookFlow?.shadowMode == true) {
        shadowCount++;
        await recordEventItem(
          index: i,
          bill: bill,
          state: AutoBookState.ignored.value,
          reason:
              'shadow_mode:${policy.reason}${duplicate ? ':duplicate' : ''}',
        );
        logger.info(_tag, '影子模式跳过写入', _billDiagnostic(bill));
        continue;
      }

      // 强匹配直接关联已有交易，不再创建第二笔；弱匹配必须进入候选。
      if (autoBookFlow != null && semanticMatch?.isStrong == true) {
        duplicateCount++;
        duplicateTransactionIds.add(semanticMatch!.transactionId);
        await recordEventItem(
          index: i,
          bill: bill,
          state: AutoBookState.duplicate.value,
          transactionId: semanticMatch.transactionId,
          reason: 'semantic_strong:${semanticMatch.score.toStringAsFixed(3)}',
        );
        logger.info(_tag,
            '第 ${i + 1} 笔命中强语义重复,跳过创建: tx=${semanticMatch.transactionId} score=${semanticMatch.score.toStringAsFixed(3)}');
        continue;
      }

      // M2 候选制:低置信 / 语义待确认 / 疑似重复 → 待确认队列,不入账。
      // 自动入账总闸关闭(P0-2)时,即使全部通过语义校验也一律先进待确认。
      final requiresConfirmation = autoBookFlow != null &&
          (autoBookFlow.requireConfirmationForAll ||
              policy.isPending ||
              AutoBookRule.isLowConfidence(bill) ||
              duplicate);
      if (requiresConfirmation) {
        final String? reason;
        if (autoBookFlow!.requireConfirmationForAll &&
            !policy.isPending &&
            !AutoBookRule.isLowConfidence(bill) &&
            !duplicate) {
          // 仅因总闸关闭进待确认:语义/置信/查重都没有拦它
          reason = 'autoBookDisabled';
        } else if (duplicate) {
          reason = 'duplicate';
        } else {
          reason = _candidateReasonForPolicy(policy) ??
              AutoBookRule.reasonKeyFor(bill: bill, duplicate: duplicate);
        }
        await autoBookFlow.store.add(PendingCandidate(
          id: PendingCandidate.candidateId(bill),
          bill: bill,
          billingTypes: billingTypes,
          source: source,
          capturedAt: DateTime.now(),
          reason: reason,
          eventKey: autoBookFlow.eventKey,
          semanticKey: SemanticDedupMatcher.semanticKey(bill),
          matchedTransactionId: semanticMatch?.transactionId,
          matchScore: semanticMatch?.score,
        ));
        awaitingCount++;
        pendingAbsAmount += bill.amount?.abs() ?? 0;
        await recordEventItem(
          index: i,
          bill: bill,
          state: AutoBookState.pending.value,
          reason: reason,
          metadata: {
            'candidate_id': PendingCandidate.candidateId(bill),
            'candidate_reason': reason,
            'billing_types': billingTypes,
            'source': source,
            'captured_at': DateTime.now().toIso8601String(),
            if (semanticMatch?.transactionId != null)
              'matched_transaction_id': semanticMatch!.transactionId,
            if (semanticMatch?.score != null)
              'match_score': semanticMatch!.score,
          },
        );
        pendingComparison.add(bill);
        logger.info(_tag, '第 ${i + 1} 笔进入待确认(候选制)', _billDiagnostic(bill));
        continue;
      }

      try {
        final txId = await _persister.createFromBill(
          bill: bill,
          ledgerId: ledgerId,
          billingTypes: billingTypes,
          l10n: l10n,
          sourceChannel: sourceChannel,
          context: billContext,
        );
        if (txId == null) {
          failed++;
          await recordEventItem(
            index: i,
            bill: bill,
            state: AutoBookState.retry.value,
            reason: 'create_returned_null',
          );
          logger.warning(_tag, '第 ${i + 1} 笔创建失败', _billDiagnostic(bill));
          continue;
        }

        // 先写入子项关联，再执行附件/名称等非核心副作用。这样即使进程
        // 在后续步骤被杀，重试也能知道这笔交易已经成功落库。
        await recordEventItem(
          index: i,
          bill: bill,
          state: AutoBookState.booked.value,
          transactionId: txId,
        );

        // 1. **优先**触发 onSaved 回调(主要用于保存图片附件)。
        //    放在 _enrichWithActualNames 前面是为了缩短附件保存的时间窗口 ——
        //    iOS 后台 launch 场景下,用户随时可能切走 / 关 app 导致进程被 kill。
        //    enrich 是给 UI 卡片显示用,被 kill 影响的只是名称展示,不影响数据
        //    完整性;附件被 kill 才是数据丢失。
        if (onSaved != null) {
          try {
            await onSaved(txId, txIds.length);
          } catch (e, st) {
            logger.error(_tag, 'onSaved 回调异常,不影响主流程', e, st);
          }
        }

        // 2. 查实际入库的 category / account 名称,回填到 BillInfo
        //    (UI 卡片显示用,避免显示 AI 原始名称)。
        //    enrich 自带兜底不会抛,但即便抛了也要保 savedBills/txIds 长度对齐。
        BillInfo enriched;
        try {
          enriched = await _enrichWithActualNames(bill, txId, billContext);
        } catch (e, st) {
          logger.error(
              _tag, 'enrichWithActualNames 异常,用 AI 原始 BillInfo', e, st);
          enriched = bill;
        }
        saved.add(enriched);
        txIds.add(txId);
        recentComparison.add(bill);
      } catch (e, st) {
        failed++;
        await recordEventItem(
          index: i,
          bill: bill,
          state: AutoBookState.retry.value,
          reason: 'create_exception',
        );
        logger.error(_tag, '第 ${i + 1} 笔创建异常', e, st);
      }
    }

    if (failed > 0) {
      logger.warning(_tag, '成功 ${txIds.length} 笔,失败 $failed 笔');
    }

    // M0-1:自动记账链上补一段「解析→判重→落库」的耗时(主动路径无 trace)。
    AutoBookTrace.current?.stage(
      'persist',
      outcome: failed > 0
          ? 'partial_failed'
          : (txIds.isEmpty ? 'no_transaction' : 'saved'),
    );

    return BookkeepingResult(
      savedBills: List.unmodifiable(saved),
      transactionIds: List.unmodifiable(txIds),
      failedCount: failed,
      unconvertedCurrencies:
          List.unmodifiable(await _collectUnconverted(txIds, ledgerId)),
      awaitingCount: awaitingCount,
      ignoredCount: ignoredCount,
      duplicateCount: duplicateCount,
      duplicateTransactionIds: List.unmodifiable(duplicateTransactionIds),
      shadowCount: shadowCount,
      pendingAbsAmount: pendingAbsAmount,
    );
  }

  String _billDiagnostic(BillInfo bill) {
    final note = bill.note?.trim();
    final noteHash = note == null || note.isEmpty
        ? null
        : autoBookHash(normalizeAutoBookText(note), length: 12);
    final external = bill.externalId?.trim();
    final externalHash = external == null || external.isEmpty
        ? null
        : autoBookHash(external, length: 12);
    return 'amount=${bill.amount}, type=${bill.type?.name}, '
        'kind=${bill.eventKind?.name}, status=${bill.settlementStatus?.name}, '
        'time=${bill.time?.toIso8601String()}, timePrecision=${bill.timePrecision?.name}, '
        'noteHash=$noteHash, externalHash=$externalHash';
  }

  String? _candidateReasonForPolicy(AutoBookPolicyDecision decision) {
    return switch (decision.reason) {
      'confidence_missing' => 'lowConfidence',
      'time_inferred' => 'lowConfidence',
      'settlement_unknown' => 'settlementUnknown',
      'transfer_account_missing' => 'transferAccountMissing',
      'time_precision_weak' => 'lowConfidence',
      'event_kind_unknown' => 'settlementUnknown',
      _ => null,
    };
  }

  /// 最近 24h 本账本原始交易(疑似重复检测对比池,金额口径与原逻辑一致用
  /// t.amount)。M3-3:基础规则只看 24 小时,不再拉 90 天再在内存里丢掉
  /// 99% 的行。M3-2:改用纯 [Transaction] 查询,富查询会给每行再补
  /// 分类/标签/附件/账户(N+1),这里一个字段都用不上。失败时整体降级(空
  /// pool),不影响入账。
  Future<List<BillInfo>?> _loadBaseline(int ledgerId) async {
    try {
      final now = DateTime.now();
      final rows = await _repo.getTransactionsByLedgerInRange(
        ledgerId: ledgerId,
        start: now.subtract(const Duration(hours: 24)),
        end: now,
      );
      final recent = <BillInfo>[];
      for (final t in rows) {
        recent.add(BillInfo(
          amount: t.amount,
          time: t.happenedAt,
          type: _billTypeFromString(t.type),
          note: t.note,
          ledgerId: ledgerId,
        ));
      }
      return recent;
    } catch (e) {
      logger.warning(_tag, '加载 24h 基线失败,疑似重复判定降级', '$e');
      return null;
    }
  }

  static BillType? _billTypeFromString(String type) {
    if (type == 'expense') return BillType.expense;
    if (type == 'income') return BillType.income;
    if (type == 'transfer') return BillType.transfer;
    return null;
  }

  /// 找出本批里「外币且未折算」的币种(A5)。判定条件与 L11 补折算横幅一致:
  /// `currencyCode != 账本本位币 && nativeAmount == amount`。
  Future<List<String>> _collectUnconverted(
      List<int> txIds, int ledgerId) async {
    if (txIds.isEmpty) return const [];
    try {
      final ledger = await _repo.getLedgerById(ledgerId);
      final base =
          ((ledger?.currency.isNotEmpty ?? false) ? ledger!.currency : 'CNY')
              .toUpperCase();
      final codes = <String>{};
      // M3-5:一条 `id IN (...)` 取回本批交易,不再逐笔 SELECT(顺序无关,这里
      // 只做集合去重)。
      final rows = await _repo.getTransactionsByIds(txIds);
      for (final tx in rows) {
        final code = tx.currencyCode?.toUpperCase();
        if (code == null || code == base) continue;
        if (tx.nativeAmount == null || tx.nativeAmount == tx.amount) {
          codes.add(code);
        }
      }
      if (codes.isNotEmpty) {
        logger.info(_tag, '未折算外币: ${codes.join(",")}(已按 1:1 暂记,可在统计页补折算)');
      }
      return codes.toList()..sort();
    } catch (e, st) {
      // 只影响一行提示,不能影响记账结果
      logger.warning(_tag, '统计未折算币种失败,忽略', st);
      logger.debug(_tag, '异常详情: $e');
      return const [];
    }
  }

  /// 查询实际入库的分类/账户名称,回填到 BillInfo。AI 给的可能是"奶茶"
  /// 但 BillCreationService 匹配到的可能是"餐饮",卡片要显示后者。
  ///
  /// M3-5:落库时 [BillCreationService] 已经把实际用的分类/账户名记进
  /// [BillCreationContext.resolvedNames],命中就直接用,省掉 交易 + 分类 +
  /// 账户 三条 SELECT(每笔都有)。记录里的名称与查库结果同源:分类必定取自
  /// 匹配用的分类池、账户就是落库那一行对象,而落库走的是 categoryId /
  /// accountId 原值(没有 syncId override),所以两条路算出来是同一个名字。
  /// 没有记录(单笔路径没传 context)才回落到查库。
  Future<BillInfo> _enrichWithActualNames(
      BillInfo bill, int txId, BillCreationContext? ctx) async {
    final cached = ctx?.resolvedNames[txId];
    if (cached != null) {
      return bill.copyWith(
        category: cached.categoryName ?? bill.category,
        account: cached.accountName ?? bill.account,
      );
    }
    try {
      final tx = await _repo.getTransactionById(txId);
      if (tx == null) return bill;
      String? actualCategory;
      String? actualAccount;
      if (tx.categoryId != null) {
        final cat = await _repo.getCategoryById(tx.categoryId!);
        actualCategory = cat?.name;
      }
      if (tx.accountId != null) {
        final acc = await _repo.getAccount(tx.accountId!);
        actualAccount = acc?.name;
      }
      return bill.copyWith(
        category: actualCategory ?? bill.category,
        account: actualAccount ?? bill.account,
      );
    } catch (e, st) {
      logger.error(_tag, '回填实际名称失败,使用 AI 原始名称', e, st);
      return bill;
    }
  }
}
