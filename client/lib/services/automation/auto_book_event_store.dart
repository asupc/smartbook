import 'dart:convert';

import 'package:drift/drift.dart' as d;

import '../../data/db.dart' as schema;
import 'auto_book_event.dart';
import '../privacy/raw_evidence_policy.dart';
import 'semantic_dedup_matcher.dart';

/// 一次事件 claim 的结果。
class AutoBookClaim {
  final schema.AutoBookEvent event;
  final bool acquired;

  const AutoBookClaim({required this.event, required this.acquired});
}

/// 自动记账入口事件的本地持久化存储。
///
/// 事件表只属于客户端，不参与云同步。Coordinator 在同一 Dart isolate 内
/// 串行调用本类；eventKey 的 UNIQUE 约束则负责兜住重启/重复广播等边界竞态。
class AutoBookEventStore {
  final schema.BeeDatabase db;

  const AutoBookEventStore(this.db);

  static const maxPendingEvents = 500;
  static const processingLease = Duration(minutes: 10);

  Future<schema.AutoBookEvent?> findByEventKey(String eventKey) {
    return (db.select(db.autoBookEvents)
          ..where((t) => t.eventKey.equals(eventKey)))
        .getSingleOrNull();
  }

  Future<schema.AutoBookEvent?> findById(int id) {
    return (db.select(db.autoBookEvents)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 幂等创建事件。已存在时返回原记录，不覆盖其生命周期状态。
  Future<schema.AutoBookEvent> ensure(AutoBookInput input) async {
    if (input.eventKey.trim().isEmpty) {
      throw ArgumentError.value(input.eventKey, 'eventKey', '不能为空');
    }

    final existing = await findByEventKey(input.eventKey);
    if (existing != null) {
      return _attachRawEvidenceIfNeeded(existing, input);
    }

    final policy = await RawEvidencePolicyStore().load();
    final plan = policy.planFor(input.sourceValue, input.capturedAt);
    final rawMetadata = plan.shouldStore && input.rawMetadata != null
        ? jsonEncode(input.rawMetadata)
        : null;
    final hasRaw = plan.shouldStore &&
        (input.rawTitle?.isNotEmpty == true ||
            input.rawText?.isNotEmpty == true ||
            input.rawActor?.isNotEmpty == true ||
            rawMetadata != null);
    final companion = schema.AutoBookEventsCompanion.insert(
      eventKey: input.eventKey,
      source: input.sourceValue,
      captureIntent: d.Value(input.captureIntentValue),
      ledgerId: d.Value(input.ledgerId),
      sourceChannel: d.Value(input.sourceChannel),
      externalId: d.Value(input.externalId),
      contentHash: d.Value(input.contentHash),
      capturedAt: input.capturedAt,
      sourceOccurredAt: d.Value(input.sourceOccurredAt),
      // A2:证据有效期兜底 —— 调用方漏传时按捕获时刻+30d 落列,保证
      // cleanupExpired 的 DELETE 恒有命中面(旧行为恒写 null → 表只进不出)。
      expiresAt: d.Value(
        input.expiresAt ?? AutoBookInput.defaultExpiresAt(input.capturedAt),
      ),
      rawTitle: d.Value(hasRaw ? input.rawTitle : null),
      rawText: d.Value(hasRaw ? input.rawText : null),
      rawActor: d.Value(hasRaw ? input.rawActor : null),
      rawMetadataJson: d.Value(hasRaw ? rawMetadata : null),
      rawEvidenceLocalEnabled: d.Value(hasRaw && plan.localEnabled),
      rawEvidenceServerEnabled: d.Value(hasRaw && plan.serverEnabled),
      rawEvidenceLocalExpiresAt: d.Value(hasRaw ? plan.localExpiresAt : null),
      rawEvidenceServerExpiresAt: d.Value(hasRaw ? plan.serverExpiresAt : null),
      rawEvidenceRetentionUntil: d.Value(hasRaw ? plan.retentionUntil : null),
      rawEvidenceUploadState: d.Value(
        hasRaw ? plan.uploadState : RawEvidenceUploadState.notRequested,
      ),
    );

    try {
      final id = await db.into(db.autoBookEvents).insert(companion);
      final inserted = await findById(id);
      if (inserted == null) {
        throw StateError('自动记账事件插入后无法读取: $id');
      }
      return inserted;
    } catch (_) {
      // 另一个调用在 SELECT 与 INSERT 之间抢先写入时，UNIQUE 冲突是正常
      // 的；回读既有行即可。真正的数据库错误继续抛出。
      final raced = await findByEventKey(input.eventKey);
      if (raced != null) return raced;
      rethrow;
    }
  }

  Future<schema.AutoBookEvent> _attachRawEvidenceIfNeeded(
      schema.AutoBookEvent event, AutoBookInput input) async {
    if (!_hasRawInput(input)) return event;
    if (event.rawEvidenceUploadState == RawEvidenceUploadState.cleared ||
        event.rawEvidenceUploadState == RawEvidenceUploadState.expired ||
        event.rawEvidenceUploadState == RawEvidenceUploadState.uploaded) {
      return event;
    }
    final policy = await RawEvidencePolicyStore().load();
    final plan = policy.planFor(input.sourceValue, input.capturedAt);
    if (!plan.shouldStore || _hasRawEvent(event)) return event;

    final metadata =
        input.rawMetadata == null ? null : jsonEncode(input.rawMetadata);
    final now = DateTime.now();
    await (db.update(db.autoBookEvents)..where((t) => t.id.equals(event.id)))
        .write(schema.AutoBookEventsCompanion(
      rawTitle: d.Value(input.rawTitle),
      rawText: d.Value(input.rawText),
      rawActor: d.Value(input.rawActor),
      rawMetadataJson: d.Value(metadata),
      rawEvidenceLocalEnabled: d.Value(plan.localEnabled),
      rawEvidenceServerEnabled: d.Value(plan.serverEnabled),
      rawEvidenceLocalExpiresAt: d.Value(plan.localExpiresAt),
      rawEvidenceServerExpiresAt: d.Value(plan.serverExpiresAt),
      rawEvidenceRetentionUntil: d.Value(plan.retentionUntil),
      rawEvidenceUploadState: d.Value(plan.uploadState),
      updatedAt: d.Value(now),
    ));
    return await findById(event.id) ?? event;
  }

  /// 尝试取得事件处理租约。
  ///
  /// terminal 事件不再执行；processing 且租约未过期的事件也不重复执行；
  /// retry 事件在 nextRetryAt 之前不执行。所有状态判断都在 Coordinator 的
  /// 全局串行链中运行，避免同一进程内双执行。
  Future<AutoBookClaim> claim(AutoBookInput input) async {
    final event = await ensure(input);
    final now = DateTime.now();
    final state = AutoBookStateValue.parse(event.state);

    if (_isTerminal(state)) {
      return AutoBookClaim(event: event, acquired: false);
    }
    if (state == AutoBookState.retry &&
        event.nextRetryAt != null &&
        event.nextRetryAt!.isAfter(now)) {
      return AutoBookClaim(event: event, acquired: false);
    }
    if (state == AutoBookState.processing &&
        now.isBefore(event.updatedAt.add(processingLease))) {
      return AutoBookClaim(event: event, acquired: false);
    }

    await (db.update(db.autoBookEvents)..where((t) => t.id.equals(event.id)))
        .write(
      schema.AutoBookEventsCompanion(
        state: const d.Value('processing'),
        attemptCount: d.Value(event.attemptCount + 1),
        nextRetryAt: const d.Value(null),
        updatedAt: d.Value(now),
      ),
    );
    final claimed = await findById(event.id);
    if (claimed == null) {
      throw StateError('自动记账事件 claim 后无法读取: ${event.id}');
    }
    return AutoBookClaim(event: claimed, acquired: true);
  }

  Future<void> mark(AutoBookEventUpdate update, {required int eventId}) async {
    final now = DateTime.now();
    // 终态(booked/duplicate/ignored/pending/failed/expired)同时清除离线
    // 识别草稿:内容已被消化(入账/判重/进待确认)或不再可自动恢复;
    // pending 是终态,因为草稿输入已变成待确认候选,由确认页接管。
    final isTerminal = switch (update.state) {
      AutoBookState.booked ||
      AutoBookState.duplicate ||
      AutoBookState.ignored ||
      AutoBookState.pending ||
      AutoBookState.failed ||
      AutoBookState.expired =>
        true,
      _ => false,
    };
    await (db.update(db.autoBookEvents)..where((t) => t.id.equals(eventId)))
        .write(
      schema.AutoBookEventsCompanion(
        state: d.Value(update.state.value),
        draftPayloadJson:
            isTerminal ? const d.Value(null) : const d.Value.absent(),
        transactionId: update.transactionId == null
            ? const d.Value.absent()
            : d.Value(update.transactionId),
        duplicateOfTransactionId: update.duplicateOfTransactionId == null
            ? const d.Value.absent()
            : d.Value(update.duplicateOfTransactionId),
        billJson: update.billJson == null
            ? const d.Value.absent()
            : d.Value(update.billJson),
        reason: update.reason == null
            ? const d.Value.absent()
            : d.Value(update.reason),
        nextRetryAt: d.Value(update.nextRetryAt),
        expiresAt: update.expiresAt == null
            ? const d.Value.absent()
            : d.Value(update.expiresAt),
        updatedAt: d.Value(now),
      ),
    );
  }

  /// A1(2026-09-15):重试上限。用尽后事件落 `failed` 终态 —— 旧行为在
  /// clamp(1,5) 梯梯满后永远按 2h 重试,截图文件消失等不可恢复场景会形成
  /// 无限循环(每次 drain 都是一次 AI 中转调用/3s 文件等待)。
  static const int maxRetryAttempts = 8;

  Future<void> markRetry({
    required int eventId,
    required int attemptCount,
    String? error,
  }) async {
    // A1:用尽退避次数 → failed 终态(原因码 retry_exhausted,历史页可见)。
    // 与 mark() 的终态语义对齐:同时清 nextRetryAt 与离线草稿 —— 草稿若
    // 保留,会被 dueDrafts 的 [retry, failed] 过滤长期选中,占住 limit 挤掉
    // 新草稿(重放又会因终态被 claim 拒绝,空转)。
    if (attemptCount >= maxRetryAttempts) {
      final now = DateTime.now();
      await (db.update(db.autoBookEvents)..where((t) => t.id.equals(eventId)))
          .write(
        schema.AutoBookEventsCompanion(
          state: const d.Value('failed'),
          reason: const d.Value('retry_exhausted'),
          nextRetryAt: const d.Value(null),
          draftPayloadJson: const d.Value(null),
          lastError: d.Value(_redactError(error)),
          updatedAt: d.Value(now),
        ),
      );
      return;
    }
    // 30s, 2m, 8m, 30m, 2h(第 5 次起固定 2h,直到 [maxRetryAttempts] 用尽);
    // 避免桥接广播/启动 drain 形成忙循环。
    final seconds = switch (attemptCount.clamp(1, 5)) {
      1 => 30,
      2 => 120,
      3 => 480,
      4 => 1800,
      _ => 7200,
    };
    final now = DateTime.now();
    await (db.update(db.autoBookEvents)..where((t) => t.id.equals(eventId)))
        .write(
      schema.AutoBookEventsCompanion(
        state: const d.Value('retry'),
        nextRetryAt: d.Value(now.add(Duration(seconds: seconds))),
        lastError: d.Value(_redactError(error)),
        updatedAt: d.Value(now),
      ),
    );
  }

  Future<List<schema.AutoBookEvent>> listPending({int limit = 100}) async {
    final safeLimit = limit.clamp(1, maxPendingEvents).toInt();
    return (db.select(db.autoBookEvents)
          ..where((t) => t.state.equals('pending'))
          ..orderBy([
            (t) => d.OrderingTerm(
                  expression: t.capturedAt,
                  mode: d.OrderingMode.asc,
                ),
          ])
          ..limit(safeLimit))
        .get();
  }

  Future<int> countPending() async {
    final query = db.selectOnly(db.autoBookEvents)
      ..addColumns([db.autoBookEvents.id.count()])
      ..where(db.autoBookEvents.state.equals('pending'));
    final row = await query.getSingle();
    return row.read(db.autoBookEvents.id.count()) ?? 0;
  }

  /// 查询本地自动入口处理历史。只返回状态/来源/时间/交易关联等摘要，
  /// 不把原始短信、通知或页面文本暴露给历史页。
  Future<List<schema.AutoBookEvent>> listHistory({
    String? state,
    String? source,
    int limit = 200,
  }) async {
    final safeLimit = limit.clamp(1, maxPendingEvents).toInt();
    final rows = await (db.select(db.autoBookEvents)
          ..orderBy([
            (t) => d.OrderingTerm(
                  expression: t.updatedAt,
                  mode: d.OrderingMode.desc,
                ),
          ])
          ..limit(safeLimit))
        .get();
    return rows
        .where((row) =>
            (state == null || row.state == state) &&
            (source == null || row.source == source))
        .toList();
  }

  Future<Map<String, int>> countByState() async {
    final rows = await (db.select(db.autoBookEvents)).get();
    final result = <String, int>{};
    for (final row in rows) {
      result[row.state] = (result[row.state] ?? 0) + 1;
    }
    return result;
  }

  Future<List<schema.AutoBookEventItem>> itemsForEvent(int eventId) {
    return (db.select(db.autoBookEventItems)
          ..where((t) => t.eventId.equals(eventId))
          ..orderBy([(t) => d.OrderingTerm.asc(t.itemIndex)]))
        .get();
  }

  /// C8(2026-09-15):批量读取一组事件的全部子项,按 eventId 分组返回。
  /// [PendingCandidateStore.loadForReview] 旧行为是逐事件调
  /// [itemsForEvent](500 事件 = 500 次 DB 往返,角标计数也走这条路);改一次
  /// 批查(SQLite 变量上限 999,按 400 一段分块)。
  Future<Map<int, List<schema.AutoBookEventItem>>> itemsForEvents(
    List<int> eventIds,
  ) async {
    final grouped = <int, List<schema.AutoBookEventItem>>{};
    for (var i = 0; i < eventIds.length; i += 400) {
      final end =
          (i + 400 > eventIds.length) ? eventIds.length : i + 400;
      final chunk = eventIds.sublist(i, end);
      if (chunk.isEmpty) continue;
      final rows = await (db.select(db.autoBookEventItems)
            ..where((t) => t.eventId.isIn(chunk))
            ..orderBy([
              (t) => d.OrderingTerm.asc(t.eventId),
              (t) => d.OrderingTerm.asc(t.itemIndex),
            ]))
          .get();
      for (final row in rows) {
        grouped.putIfAbsent(row.eventId, () => []).add(row);
      }
    }
    return grouped;
  }

  /// C8(2026-09-15):待确认事件 TTL —— `pending` 超过 [ttl](默认 30 天,
  /// 与 A2 证据保留期同长)的事件转 `expired` 终态。旧行为 pending 无过期,
  /// 确认页/角标被陈年候选长期占用;语义上 30 天未确认的候选等同放弃。
  /// 与 [cleanupExpired] 的占位改造同款:置 expired(终态,不再被 claim)、
  /// 清 expiresAt(不被后续 DELETE 吃掉,历史页保留「为什么停下」)。
  /// 返回本轮过期的事件数。
  static const Duration pendingCandidateTtl = Duration(days: 30);

  Future<int> expireStalePending({Duration? ttl}) async {
    final cutoff = DateTime.now().subtract(ttl ?? pendingCandidateTtl);
    return (db.update(db.autoBookEvents)
          ..where((t) =>
              t.state.equals('pending') &
              t.capturedAt.isSmallerThanValue(cutoff)))
        .write(const schema.AutoBookEventsCompanion(
      state: d.Value('expired'),
      reason: d.Value('pending_expired'),
      expiresAt: d.Value(null),
      nextRetryAt: d.Value(null),
      draftPayloadJson: d.Value(null),
    ));
  }

  /// 按 provider/channel + external ID 找到已经落库的 canonical transaction。
  ///
  /// external ID 只保存在本地事件摘要，不写入 transactions.syncId，也不把
  /// 原始短信/通知正文带入云同步。C4 性能修复:外部单号查重走
  /// `semantic_key` 索引点查(写入侧 semanticKey() 对 externalId 生成的就是
  /// `external:v1:<hash>`),不再全表拉回 + 逐行 jsonDecode。hash 公式对不上
  /// (更老版本写入)或行缺失时回退旧扫描路径,行为不变。
  Future<int?> findTransactionByExternalId(
    String externalId, {
    int? ledgerId,
    String? sourceChannel,
  }) async {
    final normalized = externalId.trim().toLowerCase();
    if (normalized.isEmpty) return null;

    // 快路径:与 SemanticDedupMatcher.semanticKey 相同的 key 公式点查索引。
    // 注意 normalize 口径完全复用 matcher(含商户词清洗),保证与写入侧一致。
    try {
      final externalKey =
          SemanticDedupMatcher.externalKey(externalId.trim().toLowerCase());
      if (externalKey != null) {
        final rows = await (db.select(db.autoBookEventItems)
              ..where((t) => t.semanticKey.equals(externalKey))
              ..where((t) => t.transactionId.isNotNull()))
            .get();
        if (rows.isNotEmpty) {
          final eventIds = rows.map((r) => r.eventId).toSet();
          final events = await (db.select(db.autoBookEvents)
                ..where((e) => e.id.isIn(eventIds)))
              .get();
          final eventById = {for (final e in events) e.id: e};
          bool matchesChannel(schema.AutoBookEvent event) {
            final requested = sourceChannel?.trim().toLowerCase();
            if (requested == null || requested.isEmpty) return true;
            return event.sourceChannel?.trim().toLowerCase() == requested;
          }

          for (final item in rows) {
            final event = eventById[item.eventId];
            if (event == null ||
                event.state != AutoBookState.booked.value ||
                item.transactionId == null) {
              continue;
            }
            if (ledgerId != null && event.ledgerId != ledgerId) continue;
            if (!matchesChannel(event)) continue;
            return item.transactionId;
          }
        }
      }
    } catch (_) {
      // 快路径任何异常(例如老库 hash 函数不一致)都退回全扫描,不影响正确性。
    }

    return _findTransactionByExternalIdScan(
      normalized,
      ledgerId: ledgerId,
      sourceChannel: sourceChannel,
    );
  }

  /// 旧版全扫描实现(保留为 fallback:semanticKey 为空的历史行、以及
  /// externalId 存在于 billJson 而非 parent 行的老数据)。
  Future<int?> _findTransactionByExternalIdScan(
    String normalized, {
    int? ledgerId,
    String? sourceChannel,
  }) async {
    final events = await (db.select(db.autoBookEvents)
          ..where((t) => ledgerId == null
              ? const d.Constant(true)
              : t.ledgerId.equals(ledgerId)))
        .get();
    bool matchesChannel(schema.AutoBookEvent event) {
      final requested = sourceChannel?.trim().toLowerCase();
      if (requested == null || requested.isEmpty) return true;
      return event.sourceChannel?.trim().toLowerCase() == requested;
    }

    // Import/deep-link 事件在 parent 行即可提供 externalId。
    for (final event in events) {
      if (event.state != AutoBookState.booked.value ||
          event.transactionId == null ||
          !matchesChannel(event)) {
        continue;
      }
      if (event.externalId?.trim().toLowerCase() == normalized) {
        return event.transactionId;
      }
    }

    final eventById = {
      for (final event in events) event.id: event,
    };
    if (eventById.isEmpty) return null;
    final items = await (db.select(db.autoBookEventItems)
          ..where((t) => t.transactionId.isNotNull()))
        .get();
    for (final item in items) {
      final event = eventById[item.eventId];
      final transactionId = item.transactionId;
      if (event == null ||
          transactionId == null ||
          event.state != AutoBookState.booked.value ||
          !matchesChannel(event)) {
        continue;
      }
      final raw = item.billJson;
      if (raw == null || raw.isEmpty) continue;
      try {
        final json = jsonDecode(raw);
        if (json is! Map) continue;
        final candidate = [
          json['external_id'],
          json['externalId'],
          json['transaction_id'],
          json['transactionId'],
          json['order_id'],
          json['orderId'],
        ]
            .where((value) => value != null)
            .map((value) => value.toString().trim().toLowerCase())
            .firstWhere((value) => value.isNotEmpty, orElse: () => '');
        if (candidate == normalized) return transactionId;
      } catch (_) {
        // 损坏的旧摘要不影响其他事件扫描。
      }
    }
    return null;
  }

  /// 该事件(及其子项)关联过的交易 id 集合:
  /// 父行 transactionId(booked 路径)+ 子项 transactionId(booked/duplicate)。
  Future<Set<int>> transactionIdsForEvent(int eventId) async {
    final ids = <int>{};
    final parent = await findById(eventId);
    final parentTx = parent?.transactionId;
    if (parentTx != null) ids.add(parentTx);
    final items = await (db.select(db.autoBookEventItems)
          ..where((t) => t.eventId.equals(eventId))
          ..where((t) => t.transactionId.isNotNull()))
        .get();
    ids.addAll(items.map((i) => i.transactionId!));
    return ids;
  }

  /// 反查一笔交易的自动记账来源键集合(跨渠道判重用)。
  ///
  /// 交易可能被多个事件关联(先 booked 后其它渠道 duplicate),这里返回**全部**
  /// 事件行上出现过的来源键 —— [SemanticDedupMatcher] 用它判断「当前捕获的
  /// 来源是否已有别的渠道记录过同一笔」。跨账本迁移后 ledgerId 变化,反查
  /// 不按 ledgerId 过滤(交易 id 是本地自增主键,已唯一定位一行)。
  ///
  /// 返回空集 = 该交易没有自动事件来源(手动记账/导入/云同步),调用方按
  /// 「无来源信号」处理,不影响原有打分。
  Future<Set<String>> sourceKeysForTransaction(int transactionId) async {
    final eventIds = <int>{};
    // 快路径:items.transactionId 有( eventId, itemIndex ) 主键,无独立索引;
    // 全表列扫描行数与事件表同量级,本地库(≤30 天保留)可接受。
    final itemRows = await (db.select(db.autoBookEventItems)
          ..where((t) => t.transactionId.equals(transactionId)))
        .get();
    eventIds.addAll(itemRows.map((r) => r.eventId));

    // 父行两条关联列:booked 的 transactionId + duplicate 的
    // duplicateOfTransactionId(合并/撤销后可能同时存在)。
    final parentRows = await (db.select(db.autoBookEvents)
          ..where((t) =>
              t.transactionId.equals(transactionId) |
              t.duplicateOfTransactionId.equals(transactionId)))
        .get();
    eventIds.addAll(parentRows.map((r) => r.id));
    if (eventIds.isEmpty) return const {};

    final events = await (db.select(db.autoBookEvents)
          ..where((e) => e.id.isIn(eventIds)))
        .get();
    return events
        .map((e) => AutoBookSourceValue.sourceKey(e.source))
        .whereType<String>()
        .toSet();
  }

  /// 以 (eventId,itemIndex) 幂等写入一笔解析结果摘要.
  Future<void> upsertItem({
    required int eventId,
    required int itemIndex,
    String? semanticKey,
    String? eventKind,
    String? settlementStatus,
    double? amount,
    String? currency,
    String? merchant,
    int? transactionId,
    required String state,
    Map<String, dynamic>? bill,
    String? reason,
  }) async {
    await db.transaction(() async {
      await (db.delete(db.autoBookEventItems)
            ..where((t) =>
                t.eventId.equals(eventId) & t.itemIndex.equals(itemIndex)))
          .go();
      await db.into(db.autoBookEventItems).insert(
            schema.AutoBookEventItemsCompanion.insert(
              eventId: eventId,
              itemIndex: itemIndex,
              semanticKey: d.Value(semanticKey),
              eventKind: d.Value(eventKind),
              settlementStatus: d.Value(settlementStatus),
              amount: d.Value(amount),
              currency: d.Value(currency),
              merchant: d.Value(merchant),
              transactionId: d.Value(transactionId),
              state: d.Value(state),
              billJson: d.Value(bill == null ? null : jsonEncode(bill)),
              reason: d.Value(reason),
            ),
          );
    });
  }

  /// 查询已保存的原始证据。默认只返回带正文/元数据的行。
  /// 原始字段不会被 ChangeTracker 记录，也不会进入 sync_changes。
  Future<List<schema.AutoBookEvent>> listRawEvidence({
    String? source,
    int? ledgerId,
    int limit = 200,
    int offset = 0,
    bool uploadableOnly = false,
  }) async {
    final safeLimit = limit.clamp(1, 500).toInt();
    final query = db.select(db.autoBookEvents)
      ..where((t) =>
          t.rawText.isNotNull() |
          t.rawTitle.isNotNull() |
          t.rawActor.isNotNull() |
          t.rawMetadataJson.isNotNull())
      ..orderBy([
        (t) => d.OrderingTerm(
              expression: t.capturedAt,
              mode: d.OrderingMode.desc,
            ),
      ])
      ..limit(safeLimit, offset: offset);
    if (source != null && source.trim().isNotEmpty) {
      query.where((t) => t.source.equals(source.trim()));
    }
    if (ledgerId != null) {
      query.where((t) => t.ledgerId.equals(ledgerId));
    }
    if (uploadableOnly) {
      final now = DateTime.now();
      query.where((t) =>
          t.rawEvidenceServerEnabled.equals(true) &
          t.rawEvidenceUploadedAt.isNull() &
          (t.rawEvidenceNextRetryAt.isNull() |
              t.rawEvidenceNextRetryAt.isSmallerOrEqualValue(now)) &
          (t.rawEvidenceServerExpiresAt.isNull() |
              t.rawEvidenceServerExpiresAt.isBiggerThanValue(now)) &
          t.rawEvidenceUploadState.isNotIn(const [
            RawEvidenceUploadState.uploaded,
            RawEvidenceUploadState.cleared,
            RawEvidenceUploadState.expired,
            RawEvidenceUploadState.rejected,
          ]));
    }
    return query.get();
  }

  Future<int> countRawEvidence({String? source}) async {
    final query = db.selectOnly(db.autoBookEvents)
      ..addColumns([db.autoBookEvents.id.count()])
      ..where(db.autoBookEvents.rawText.isNotNull() |
          db.autoBookEvents.rawTitle.isNotNull() |
          db.autoBookEvents.rawActor.isNotNull() |
          db.autoBookEvents.rawMetadataJson.isNotNull());
    if (source != null && source.trim().isNotEmpty) {
      query.where(db.autoBookEvents.source.equals(source.trim()));
    }
    final row = await query.getSingle();
    return row.read(db.autoBookEvents.id.count()) ?? 0;
  }

  Future<Map<String, int>> countRawEvidenceBySource() async {
    final rows = await (db.select(db.autoBookEvents)
          ..where((t) =>
              t.rawText.isNotNull() |
              t.rawTitle.isNotNull() |
              t.rawActor.isNotNull() |
              t.rawMetadataJson.isNotNull()))
        .get();
    final counts = <String, int>{};
    for (final row in rows) {
      counts[row.source] = (counts[row.source] ?? 0) + 1;
    }
    return counts;
  }

  Future<int> clearRawEvidence({String? source}) async {
    final query = db.update(db.autoBookEvents)
      ..where((t) =>
          t.rawText.isNotNull() |
          t.rawTitle.isNotNull() |
          t.rawActor.isNotNull() |
          t.rawMetadataJson.isNotNull());
    if (source != null && source.trim().isNotEmpty) {
      query.where((t) => t.source.equals(source.trim()));
    }
    return query.write(const schema.AutoBookEventsCompanion(
      rawTitle: d.Value(null),
      rawText: d.Value(null),
      rawActor: d.Value(null),
      rawMetadataJson: d.Value(null),
      rawEvidenceUploadState: d.Value(RawEvidenceUploadState.cleared),
      rawEvidenceLocalExpiresAt: d.Value(null),
      rawEvidenceServerExpiresAt: d.Value(null),
      rawEvidenceRetentionUntil: d.Value(null),
      rawEvidenceUploadedAt: d.Value(null),
      rawEvidenceLastError: d.Value(null),
    ));
  }

  Future<void> markRawEvidenceUploading(int eventId) {
    return markRawEvidenceUploadAttempt(eventId: eventId);
  }

  Future<void> markRawEvidenceUploadSucceeded(int eventId) async {
    final event = await findById(eventId);
    if (event == null) return;
    final now = DateTime.now();
    if (event.rawEvidenceUploadState == RawEvidenceUploadState.cleared ||
        event.rawEvidenceUploadState == RawEvidenceUploadState.expired) return;
    final clearAfterUpload = !event.rawEvidenceLocalEnabled ||
        (event.rawEvidenceLocalExpiresAt != null &&
            !event.rawEvidenceLocalExpiresAt!.isAfter(now));
    await (db.update(db.autoBookEvents)..where((t) => t.id.equals(eventId)))
        .write(schema.AutoBookEventsCompanion(
      rawTitle: clearAfterUpload ? const d.Value(null) : d.Value.absent(),
      rawText: clearAfterUpload ? const d.Value(null) : d.Value.absent(),
      rawActor: clearAfterUpload ? const d.Value(null) : d.Value.absent(),
      rawMetadataJson:
          clearAfterUpload ? const d.Value(null) : d.Value.absent(),
      rawEvidenceUploadState: const d.Value(RawEvidenceUploadState.uploaded),
      rawEvidenceUploadedAt: d.Value(now),
      rawEvidenceLastError: const d.Value(null),
      rawEvidenceNextRetryAt: const d.Value(null),
    ));
  }

  Future<void> markRawEvidenceUploadFailed(
    int eventId,
    String error, {
    String state = RawEvidenceUploadState.retry,
  }) async {
    final now = DateTime.now();
    final event = await findById(eventId);
    if (event == null ||
        event.rawEvidenceUploadState == RawEvidenceUploadState.cleared ||
        event.rawEvidenceUploadState == RawEvidenceUploadState.expired) return;
    // Never persist HTTP exceptions: validation responses can echo the body.
    final clean = state == RawEvidenceUploadState.rejected
        ? 'upload_rejected'
        : 'upload_failed';
    final delaySeconds =
        (30 * (1 << (event.rawEvidenceUploadAttempts - 1).clamp(0, 10)))
            .clamp(30, 21600);
    await (db.update(db.autoBookEvents)..where((t) => t.id.equals(eventId)))
        .write(schema.AutoBookEventsCompanion(
      rawEvidenceUploadState: d.Value(state),
      rawEvidenceLastError: d.Value(clean),
      rawEvidenceNextRetryAt: d.Value(state == RawEvidenceUploadState.retry
          ? now.add(Duration(seconds: delaySeconds))
          : null),
    ));
  }

  // ────────────────────────────────────────────────────────────────────
  // 离线识别草稿(连不上服务端时保存,手动/联网恢复后重试)
  // ────────────────────────────────────────────────────────────────────

  /// 按事件 key 保存离线识别草稿(自动入口瞬态失败时调用)。
  /// 返回 false = 找不到事件 / 事件已终态,无从重试。
  Future<bool> saveDraftByEventKey(
    String eventKey,
    AutoBookDraftPayload payload,
  ) async {
    final row = await (db.select(db.autoBookEvents)
          ..where((t) => t.eventKey.equals(eventKey)))
        .getSingleOrNull();
    if (row == null) return false;
    // 防御终态被草稿复活(理论不可达:瞬态失败只发生在非终态事件上)
    if (const {'booked', 'duplicate', 'ignored', 'pending', 'failed', 'expired'}
        .contains(row.state)) {
      return false;
    }
    await (db.update(db.autoBookEvents)..where((t) => t.id.equals(row.id)))
        .write(schema.AutoBookEventsCompanion(
      draftPayloadJson: d.Value(jsonEncode(payload.toJson())),
      updatedAt: d.Value(DateTime.now()),
    ));
    return true;
  }

  /// 草稿列表(最新在前),供手动重试 UI。
  Future<List<schema.AutoBookEvent>> listDrafts({int limit = 50}) {
    return (db.select(db.autoBookEvents)
          ..where((t) => t.draftPayloadJson.isNotNull())
          ..where((t) =>
              t.state.isIn(['captured', 'processing', 'retry', 'failed']))
          ..orderBy([
            (t) => d.OrderingTerm(
                  expression: t.capturedAt,
                  mode: d.OrderingMode.desc,
                ),
          ])
          ..limit(limit.clamp(1, 200)))
        .get();
  }

  /// 到期可自动重试的草稿(retry/failed 且退避时间已过)。
  Future<List<schema.AutoBookEvent>> dueDrafts({int limit = 10}) {
    final now = DateTime.now();
    return (db.select(db.autoBookEvents)
          ..where((t) => t.draftPayloadJson.isNotNull())
          ..where((t) => t.state.isIn(['retry', 'failed']))
          ..where((t) =>
              t.nextRetryAt.isNull() | t.nextRetryAt.isSmallerOrEqualValue(now))
          ..orderBy([
            (t) => d.OrderingTerm(
                  expression: t.capturedAt,
                  mode: d.OrderingMode.asc,
                ),
          ])
          ..limit(limit.clamp(1, 50)))
        .get();
  }

  /// 清除草稿(手动丢弃 / 重试成功后的兜底清理)。
  Future<void> clearDraft(int eventId) async {
    await (db.update(db.autoBookEvents)..where((t) => t.id.equals(eventId)))
        .write(schema.AutoBookEventsCompanion(
      draftPayloadJson: const d.Value(null),
      updatedAt: d.Value(DateTime.now()),
    ));
  }

  /// 手动重试前把事件恢复成「可被 claim」:清空退避闸门 nextRetryAt,并把
  /// failed 退回 retry —— failed 是终态,claim 会直接拒绝,重放就成了空操作
  /// (M1-4)。只放开 failed:booked/duplicate/pending/ignored/expired 的内容
  /// 已被消化或证据已消失,不能靠重放复活。
  ///
  /// A1:failed → retry 复活时同时把 attemptCount 归零。retry_exhausted 的
  /// 事件 attemptCount 已到 [maxRetryAttempts],不归零的话手动重试的第一次
  /// 可重试失败就会立刻再次用尽退避(用户只买到一次尝试)。
  Future<void> resetRetryGate(int eventId) async {
    final event = await findById(eventId);
    await (db.update(db.autoBookEvents)..where((t) => t.id.equals(eventId)))
        .write(schema.AutoBookEventsCompanion(
      state: event?.state == AutoBookState.failed.value
          ? d.Value(AutoBookState.retry.value)
          : const d.Value.absent(),
      attemptCount: event?.state == AutoBookState.failed.value
          ? const d.Value(0)
          : const d.Value.absent(),
      nextRetryAt: const d.Value(null),
      updatedAt: d.Value(DateTime.now()),
    ));
  }

  Future<int> cleanupExpiredRawEvidence({DateTime? now}) async {
    final cutoff = now ?? DateTime.now();
    final rows = await (db.select(db.autoBookEvents)
          ..where((t) =>
              t.rawText.isNotNull() |
              t.rawTitle.isNotNull() |
              t.rawActor.isNotNull() |
              t.rawMetadataJson.isNotNull()))
        .get();
    var cleared = 0;
    for (final row in rows) {
      final localDeadline = row.rawEvidenceLocalExpiresAt ??
          (row.rawEvidenceLocalEnabled ? row.rawEvidenceRetentionUntil : null);
      final serverDeadline = row.rawEvidenceServerExpiresAt ??
          (row.rawEvidenceServerEnabled ? row.rawEvidenceRetentionUntil : null);
      final localExpired =
          localDeadline != null && !localDeadline.isAfter(cutoff);
      final serverExpired =
          serverDeadline != null && !serverDeadline.isAfter(cutoff);
      final serverDone = row.rawEvidenceUploadedAt != null ||
          !row.rawEvidenceServerEnabled ||
          row.rawEvidenceUploadState == RawEvidenceUploadState.rejected;
      final keepLocal = row.rawEvidenceLocalEnabled && !localExpired;
      final keepQueue = !serverDone && !serverExpired;
      if (keepLocal || keepQueue) continue;
      await (db.update(db.autoBookEvents)..where((t) => t.id.equals(row.id)))
          .write(const schema.AutoBookEventsCompanion(
        rawTitle: d.Value(null),
        rawText: d.Value(null),
        rawActor: d.Value(null),
        rawMetadataJson: d.Value(null),
        rawEvidenceUploadState: d.Value(RawEvidenceUploadState.expired),
        rawEvidenceLastError: d.Value(null),
      ));
      cleared++;
    }
    return cleared;
  }

  Future<void> markRawEvidenceUploadAttempt({required int eventId}) async {
    final event = await findById(eventId);
    if (event == null) return;
    await (db.update(db.autoBookEvents)..where((t) => t.id.equals(eventId)))
        .write(schema.AutoBookEventsCompanion(
      rawEvidenceUploadAttempts: d.Value(event.rawEvidenceUploadAttempts + 1),
      rawEvidenceUploadState: const d.Value(RawEvidenceUploadState.uploading),
      rawEvidenceNextRetryAt: d.Value(DateTime.now().add(processingLease)),
    ));
  }

  Future<void> markRawEvidenceUploaded({required int eventId}) =>
      markRawEvidenceUploadSucceeded(eventId);

  /// A2 存量回填:历史版本从不写 expiresAt,存量事件行该列全 NULL,
  /// [cleanupExpired] 的 DELETE 恒不命中。按 `capturedAt + 30d` 补写
  /// ([AutoBookInput.evidenceRetention]);幂等 —— 只有 NULL 行会被选中,
  /// 空表/新库是一次廉价 SELECT 直接返回。
  ///
  /// `state=expired` 的占位行除外:它们的 expiresAt 是被 cleanupExpired
  /// **有意置空**的(见下方占位改造注释),回填会让语义倒退。
  Future<int> backfillMissingExpiresAt() async {
    final rows = await (db.select(db.autoBookEvents)
          ..where((t) =>
              t.expiresAt.isNull() &
              t.state.isNotIn(const ['expired'])))
        .get();
    for (final row in rows) {
      await (db.update(db.autoBookEvents)..where((t) => t.id.equals(row.id)))
          .write(schema.AutoBookEventsCompanion(
        expiresAt:
            d.Value(row.capturedAt.add(AutoBookInput.evidenceRetention)),
      ));
    }
    return rows.length;
  }

  Future<void> cleanupExpired() async {
    // A2:先做一次性(幂等)回填,再清理 —— 保证 DELETE/占位改造有命中面。
    // 失败不阻断后续清理路径(与下方占位改造同款容错)。
    try {
      await backfillMissingExpiresAt();
    } catch (_) {
      // 老库异常不阻塞;下次调用仍会重试回填。
    }
    await cleanupExpiredRawEvidence();
    final now = DateTime.now();
    // 曾有原始证据、证据已被留存策略清掉的过期事件:保留「已过期(证据已
    // 清理)」占位行,历史页不再凭空消失(P1-2)。置 state=expired(终态,
    // 不会再被 claim)+清 expiresAt(不再被本清理删除)。
    try {
      await (db.update(db.autoBookEvents)
            ..where((t) =>
                t.expiresAt.isNotNull() &
                t.expiresAt.isSmallerThanValue(now) &
                t.state.isNotIn(const ['expired']) &
                t.rawEvidenceUploadState
                    .equals(RawEvidenceUploadState.expired)))
          .write(const schema.AutoBookEventsCompanion(
        state: d.Value('expired'),
        reason: d.Value('expired_evidence_cleared'),
        expiresAt: d.Value(null),
        nextRetryAt: d.Value(null),
      ));
    } catch (_) {
      // 占位改造失败不阻断原删除路径(老库该列可能还没默认值)
    }
    await (db.delete(db.autoBookEvents)
          ..where((t) =>
              t.expiresAt.isNotNull() &
              t.expiresAt.isSmallerThanValue(now) &
              t.rawText.isNull() &
              t.rawTitle.isNull() &
              t.rawActor.isNull() &
              t.rawMetadataJson.isNull() &
              // 已转占位的行(expiresAt 已置空)天然不命中上面的过期条件;
              // 再排除一次,防御同一轮里 update/delete 的顺序竞态
              t.rawEvidenceUploadState.isNotIn(const [
                RawEvidenceUploadState.expired,
              ])))
        .go();
  }

  static bool _hasRawInput(AutoBookInput input) =>
      input.rawTitle?.isNotEmpty == true ||
      input.rawText?.isNotEmpty == true ||
      input.rawActor?.isNotEmpty == true ||
      input.rawMetadata?.isNotEmpty == true;

  static bool _hasRawEvent(schema.AutoBookEvent event) =>
      event.rawTitle?.isNotEmpty == true ||
      event.rawText?.isNotEmpty == true ||
      event.rawActor?.isNotEmpty == true ||
      event.rawMetadataJson?.isNotEmpty == true;

  static bool _isTerminal(AutoBookState state) => switch (state) {
        AutoBookState.booked ||
        AutoBookState.duplicate ||
        AutoBookState.ignored ||
        AutoBookState.pending ||
        AutoBookState.failed ||
        AutoBookState.expired =>
          true,
        _ => false,
      };

  static String? _redactError(String? error) {
    if (error == null || error.trim().isEmpty) return null;
    final firstLine = error.split(RegExp(r'[\r\n]')).first.trim();
    if (firstLine.length <= 240) return firstLine;
    return '${firstLine.substring(0, 240)}…';
  }
}
