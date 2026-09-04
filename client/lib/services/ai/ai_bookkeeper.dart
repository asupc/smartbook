import 'dart:io';

import '../../ai/core/ai_extraction_context.dart';
import '../../ai/core/ai_extraction_engine.dart';
import '../../ai/core/bill_info.dart';
import '../../ai/core/prompt_builder.dart';
import '../../data/repositories/base_repository.dart';
import '../../l10n/app_localizations.dart';
import '../billing/bill_creation_service.dart';
import '../billing/pending_candidate.dart';
import '../system/logger_service.dart';
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
  final AiCallReporter? _reporter;

  const AiBookkeeper({
    required BaseRepository repository,
    required AiExtractionEngine engine,
    required BillCreationService persister,
    AiCallReporter? reporter,
  })  : _repo = repository,
        _engine = engine,
        _persister = persister,
        _reporter = reporter;

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
  }) async {
    final context = await AiExtractionContext.forLedger(
      repository: _repo,
      ledgerId: ledgerId,
    );
    final bills = await _engine.extractFromText(
      text,
      context,
      billGuard: billGuard,
      onCall: _withLedger(ledgerId),
    );
    return _persistAll(
      bills: bills,
      ledgerId: ledgerId,
      billingTypes: billingTypes,
      l10n: l10n,
      autoBookFlow: autoBookFlow,
      source: source,
      sourceChannel: sourceChannel,
      skipIfProcessed: skipIfProcessed,
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
  }) async {
    final context = await AiExtractionContext.forLedger(
      repository: _repo,
      ledgerId: ledgerId,
    );
    final bills = await _engine.extractFromImage(
      image,
      context,
      billGuard: billGuard,
      onCall: _withLedger(ledgerId),
    );
    return _persistAll(
      bills: bills,
      ledgerId: ledgerId,
      billingTypes: billingTypes,
      l10n: l10n,
      onSaved: onSaved,
      autoBookFlow: autoBookFlow,
      source: source,
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
      onCall: _withLedger(ledgerId),
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
  }) async {
    final ledgerId = candidate.bill.ledgerId;
    if (ledgerId == null) return null;
    final txId = await _persister.createFromBill(
      bill: candidate.bill,
      ledgerId: ledgerId,
      billingTypes: candidate.billingTypes,
      l10n: l10n,
    );
    if (txId != null) {
      await PendingCandidateStore().remove(candidate.id);
    }
    return txId;
  }

  /// 拒绝待确认候选(从队列删除)。
  Future<void> rejectPending(PendingCandidate candidate) =>
      PendingCandidateStore().remove(candidate.id);

  // ============================================================
  // 内部:分流(自动→候选 / 主动→落库) + 聚合结果
  // ============================================================

  /// 把引擎层的裸调用报告补上当前账本 id(本地 int → 字符串)后交给注入的
  /// reporter。reporter 未注入时 no-op,零开销。
  AiCallReporter _withLedger(int ledgerId) =>
      _LedgerBoundReporter(_reporter, ledgerId);

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
  }) async {
    if (bills.isEmpty) {
      return BookkeepingResult.empty;
    }

    // M2 候选制:分流基准数据只取一次(90 天一次拉取,M3 基线共用)
    List<BillInfo> recentBills = const [];
    List<BillInfo> pendingBills = const [];
    if (autoBookFlow != null) {
      recentBills = (await _loadBaseline(ledgerId)) ?? const [];
      pendingBills = (await autoBookFlow.store.load())
          .map((c) => c.bill)
          .toList();
    }
    var awaitingCount = 0;

    final saved = <BillInfo>[];
    final txIds = <int>[];
    var failed = 0;

    for (var i = 0; i < bills.length; i++) {
      final bill = bills[i].copyWith(ledgerId: ledgerId);

      // 账单级去重(调用方注入,如屏幕文本的「金额+备注+日期」指纹):
      // 命中即视为已入账过,直接跳过,不落库也不进候选。
      if (skipIfProcessed != null && await skipIfProcessed(bill)) {
        logger.info(_tag, '第 ${i + 1} 笔命中账单级去重,跳过: ${bill.toJson()}');
        continue;
      }

      // M2 候选制:低置信 / 疑似重复 → 待确认队列,不入账
      if (autoBookFlow != null &&
          AutoBookRule.requiresConfirmation(
            bill: bill,
            recentBills: recentBills,
            pendingBills: pendingBills,
          )) {
        final duplicate = AutoBookRule.looksLikeDuplicate(
            bill, [...recentBills, ...pendingBills]);
        final reason = AutoBookRule.reasonKeyFor(
          bill: bill,
          duplicate: duplicate,
        );
        final queued = await autoBookFlow.store.add(PendingCandidate(
          id: PendingCandidate.candidateId(bill),
          bill: bill,
          billingTypes: billingTypes,
          source: source,
          capturedAt: DateTime.now(),
          reason: reason,
        ));
        awaitingCount++;
        logger.info(_tag, '第 ${i + 1} 笔进入待确认(候选制): ${bill.toJson()}');
        continue;
      }

      try {
        final txId = await _persister.createFromBill(
          bill: bill,
          ledgerId: ledgerId,
          billingTypes: billingTypes,
          l10n: l10n,
          sourceChannel: sourceChannel,
        );
        if (txId == null) {
          failed++;
          logger.warning(_tag, '第 ${i + 1} 笔创建失败: ${bill.toJson()}');
          continue;
        }

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
          enriched = await _enrichWithActualNames(bill, txId);
        } catch (e, st) {
          logger.error(_tag, 'enrichWithActualNames 异常,用 AI 原始 BillInfo',
              e, st);
          enriched = bill;
        }
        saved.add(enriched);
        txIds.add(txId);
      } catch (e, st) {
        failed++;
        logger.error(_tag, '第 ${i + 1} 笔创建异常', e, st);
      }
    }

    if (failed > 0) {
      logger.warning(_tag, '成功 ${txIds.length} 笔,失败 $failed 笔');
    }

    return BookkeepingResult(
      savedBills: List.unmodifiable(saved),
      transactionIds: List.unmodifiable(txIds),
      failedCount: failed,
      unconvertedCurrencies:
          List.unmodifiable(await _collectUnconverted(txIds, ledgerId)),
      awaitingCount: awaitingCount,
    );
  }

  /// 近 90 天本账本原始交易一次拉取,拆分出最近 24h 的 BillInfo
  /// (疑似重复检测对比池,金额口径与原逻辑一致用 t.amount)。
  /// 失败时整体降级(空 pool),不影响入账。
  Future<List<BillInfo>?> _loadBaseline(int ledgerId) async {
    try {
      final now = DateTime.now();
      final rows = await _repo.getTransactionsByDateRange(
        ledgerId: ledgerId,
        startDate: now.subtract(const Duration(days: 90)),
        endDate: now,
      );
      final recent24h = now.subtract(const Duration(hours: 24));
      final recent = <BillInfo>[];
      for (final r in rows) {
        final t = r.t;
        if (!t.happenedAt.isBefore(recent24h)) {
          recent.add(BillInfo(
            amount: t.amount,
            time: t.happenedAt,
            type: _billTypeFromString(t.type),
            note: t.note,
            ledgerId: ledgerId,
          ));
        }
      }
      return recent;
    } catch (e) {
      logger.warning(_tag, '加载 90 天基线失败,疑似重复判定降级', '$e');
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
  Future<List<String>> _collectUnconverted(List<int> txIds, int ledgerId) async {
    if (txIds.isEmpty) return const [];
    try {
      final ledger = await _repo.getLedgerById(ledgerId);
      final base = ((ledger?.currency.isNotEmpty ?? false)
              ? ledger!.currency
              : 'CNY')
          .toUpperCase();
      final codes = <String>{};
      for (final id in txIds) {
        final tx = await _repo.getTransactionById(id);
        if (tx == null) continue;
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
  Future<BillInfo> _enrichWithActualNames(BillInfo bill, int txId) async {
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

/// [AiBookkeeper._withLedger] 的包装:给引擎层的裸报告补上账本 id。
class _LedgerBoundReporter implements AiCallReporter {
  _LedgerBoundReporter(this._inner, this.ledgerId);

  final AiCallReporter? _inner;
  final int ledgerId;

  @override
  void call(AiCallReport report) =>
      _inner?.call(report.copyWith(ledgerId: '$ledgerId'));
}
