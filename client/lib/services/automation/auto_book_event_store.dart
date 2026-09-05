import 'dart:convert';

import 'package:drift/drift.dart' as d;

import '../../data/db.dart' as schema;
import 'auto_book_event.dart';

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
    if (existing != null) return existing;

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
      expiresAt: d.Value(input.expiresAt),
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
    // null 的 transactionId 表示“本次没有新增交易”，不是清除之前已经
    // 成功的子项关联；这对多笔部分成功后进入 retry 尤其重要。
    await (db.update(db.autoBookEvents)..where((t) => t.id.equals(eventId)))
        .write(
      schema.AutoBookEventsCompanion(
        state: d.Value(update.state.value),
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

  Future<void> markRetry({
    required int eventId,
    required int attemptCount,
    String? error,
  }) async {
    // 30s, 2m, 8m, 30m, 2h；避免桥接广播/启动 drain 形成忙循环。
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

  /// 按 provider/channel + external ID 找到已经落库的 canonical transaction。
  ///
  /// external ID 只保存在本地事件摘要，不写入 transactions.syncId，也不把
  /// 原始短信/通知正文带入云同步。数据量受事件 cap 约束，启动/自动路径可
  /// 接受一次本地扫描；后续可再加独立索引表。
  Future<int?> findTransactionByExternalId(
    String externalId, {
    int? ledgerId,
    String? sourceChannel,
  }) async {
    final normalized = externalId.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    final events = await (db.select(db.autoBookEvents)
          ..where((t) => ledgerId == null
              ? const d.Constant(true)
              : t.ledgerId.equals(ledgerId)))
        .get();
    final matchesChannel = (schema.AutoBookEvent event) {
      final requested = sourceChannel?.trim().toLowerCase();
      if (requested == null || requested.isEmpty) return true;
      return event.sourceChannel?.trim().toLowerCase() == requested;
    };

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

  Future<void> cleanupExpired() async {
    final now = DateTime.now();
    await (db.delete(db.autoBookEvents)
          ..where((t) =>
              t.expiresAt.isNotNull() & t.expiresAt.isSmallerThanValue(now)))
        .go();
  }

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
