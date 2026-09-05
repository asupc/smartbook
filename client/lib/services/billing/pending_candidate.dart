import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../ai/core/bill_info.dart';
import '../automation/auto_book_event_store.dart';

/// 待确认候选(自动记账 M2)。
///
/// 自动路径(截图/短信/支付通知)解析出的候选交易:低置信/大额/疑似重复的
/// 一笔不直接入账,先进入队列,由用户在「待确认」页确认/编辑后入账/拒绝。
/// 存储:SharedPreferences 单 key JSON 数组(结构性数据,量小,cap 100),
/// 不引入新 Drift 表 —— 候选不是持久账本数据,且免 migration 风险。
class PendingCandidate {
  final String id; // sha256(bill json) 前 12 位,去重键
  final BillInfo bill; // 需含 ledgerId(入账目标)
  final List<String> billingTypes; // 来源标签,确认入账时复用
  final String source; // sms / notification / image / audio / chat …
  final DateTime capturedAt;
  final String? reason; // 进候选的原因(给用户看:"疑似重复"/"大额"等文案 key)
  /// 原始入口事件 key。与 candidate id 分离，便于同一事件重试时幂等。
  final String? eventKey;

  /// event store 中的解析子项索引。旧版 SharedPreferences 候选可为空。
  final int? eventItemIndex;

  /// 跨来源交易级语义 key（若已能生成）。
  final String? semanticKey;

  /// 疑似重复时命中的已有交易。
  final int? matchedTransactionId;
  final double? matchScore;

  const PendingCandidate({
    required this.id,
    required this.bill,
    this.billingTypes = const [],
    this.source = 'auto',
    required this.capturedAt,
    this.reason,
    this.eventKey,
    this.eventItemIndex,
    this.semanticKey,
    this.matchedTransactionId,
    this.matchScore,
  });

  static String candidateId(BillInfo bill) {
    return sha256
        .convert(utf8.encode(bill.toJson().toString()))
        .toString()
        .substring(0, 12);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'bill': bill.toJson(),
        'billingTypes': billingTypes,
        'source': source,
        'capturedAt': capturedAt.toIso8601String(),
        'reason': reason,
        'eventKey': eventKey,
        'eventItemIndex': eventItemIndex,
        'semanticKey': semanticKey,
        'matchedTransactionId': matchedTransactionId,
        'matchScore': matchScore,
      };

  static PendingCandidate? fromJson(Map<String, dynamic> json) {
    try {
      final billJson = json['bill'];
      if (billJson is! Map) return null;
      return PendingCandidate(
        id: json['id'] as String? ?? '',
        bill: BillInfo.fromJson(Map<String, dynamic>.from(billJson)),
        billingTypes: (json['billingTypes'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        source: json['source'] as String? ?? 'auto',
        capturedAt: DateTime.tryParse(json['capturedAt'] as String? ?? '') ??
            DateTime.now(),
        reason: json['reason'] as String?,
        eventKey: json['eventKey'] as String?,
        eventItemIndex: (json['eventItemIndex'] as num?)?.toInt(),
        semanticKey: json['semanticKey'] as String?,
        matchedTransactionId: (json['matchedTransactionId'] as num?)?.toInt(),
        matchScore: (json['matchScore'] as num?)?.toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  PendingCandidate copyWith({
    String? candidateId,
    BillInfo? bill,
    String? reason,
    String? eventKey,
    int? eventItemIndex,
    String? semanticKey,
    int? matchedTransactionId,
    double? matchScore,
  }) {
    return PendingCandidate(
      id: candidateId ?? id,
      bill: bill ?? this.bill,
      billingTypes: billingTypes,
      source: source,
      capturedAt: capturedAt,
      reason: reason ?? this.reason,
      eventKey: eventKey ?? this.eventKey,
      eventItemIndex: eventItemIndex ?? this.eventItemIndex,
      semanticKey: semanticKey ?? this.semanticKey,
      matchedTransactionId: matchedTransactionId ?? this.matchedTransactionId,
      matchScore: matchScore ?? this.matchScore,
    );
  }
}

/// 入账分流规则(自动记账 M2 §5.3 自动入账建议)。
///
/// 设计取舍:文档原文"总置信度 >= 0.90 且非疑似重复 → 自动入账",但模型
/// 返回的 confidence 并不可靠,且旧模型/聊天路径根本不输出 —— 所以:
/// - 缺省 confidence = 1.0(见 BillInfo),旧模型行为=现状直入账;
/// - 只有模型**主动**输出低 confidence 时才进候选(多义/猜测场景);
/// - "疑似重复"是硬规则,一定能拦下来。
class AutoBookRule {
  static const double confidenceThreshold = 0.9;
  static const double duplicateTolerance = 0.05; // 金额 ±5%
  static const Duration duplicateWindow = Duration(minutes: 10);

  static bool isLowConfidence(BillInfo bill) {
    return bill.confidence < confidenceThreshold;
  }

  /// 疑似重复:同账本、同类型、金额 ±5%(+0.01 容差)且时间差 <= 10 分钟;
  /// 或同备注(同一商户)且金额一致。全为纯函数,便于单测。
  static bool looksLikeDuplicate(BillInfo bill, Iterable<BillInfo> others) {
    final amount = bill.amount;
    if (amount == null || amount.abs() <= 0) return false;
    for (final other in others) {
      final otherAmount = other.amount;
      if (otherAmount == null ||
          otherAmount.abs() <= 0 ||
          other.type != bill.type ||
          other.ledgerId != bill.ledgerId) {
        continue;
      }
      if ((otherAmount.abs() - amount.abs()).abs() >
          amount.abs() * duplicateTolerance + 0.01) {
        continue;
      }
      final sameNote =
          bill.note != null && bill.note!.isNotEmpty && bill.note == other.note;
      final diff = (bill.time == null || other.time == null)
          ? Duration.zero
          : bill.time!.difference(other.time!).abs();
      if (diff <= duplicateWindow || sameNote) return true;
    }
    return false;
  }

  /// 是否需要进待确认(流程分流总入口)。
  ///
  /// 大额/异常消费提醒引擎已下线,现在只认低置信 + 疑似重复两类。
  static bool requiresConfirmation({
    required BillInfo bill,
    required Iterable<BillInfo> recentBills,
    required Iterable<BillInfo> pendingBills,
  }) {
    if (isLowConfidence(bill)) return true;
    return looksLikeDuplicate(bill, [
      ...recentBills,
      ...pendingBills,
    ]);
  }

  /// 待确认原因的展示 key(l10n 前缀"pendingCandidateReason"))。优先级:
  /// 疑似重复 > 低置信(重复信息量最大,最关心是否双记账)。
  static String? reasonKeyFor({
    required BillInfo bill,
    required bool duplicate,
  }) {
    if (duplicate) return 'duplicate';
    if (isLowConfidence(bill)) return 'lowConfidence';
    return null;
  }
}

/// 候选制分流流的运行时参数(由自动路径构造传入 AiBookkeeper)。
class AutoBookFlow {
  final PendingCandidateStore store;
  final String? eventKey;

  /// Coordinator 的本地事件表；主动路径可为空，自动路径由共享 provider 注入。
  final AutoBookEventStore? eventStore;
  final bool strictSemantic;

  /// 影子模式：执行识别/策略/判重，但不创建交易或候选。
  final bool shadowMode;

  /// 自动入账总闸(设置页 `auto_book_enabled`)。关闭时**所有**通过语义
  /// 闸门的识别结果也一律先进待确认队列，不自动入账
  /// (ux-optimization-plan P0-2:接回死开关)。
  final bool requireConfirmationForAll;

  const AutoBookFlow({
    required this.store,
    this.eventKey,
    this.eventStore,
    this.strictSemantic = true,
    this.shadowMode = false,
    this.requireConfirmationForAll = false,
  });
}

/// 待确认候选队列存储(SharedPreferences,cap [maxCandidates])。
class PendingCandidateStore {
  static const _key = 'pending_candidates_v1';
  static const int maxCandidates = 100;

  /// legacy 触 cap 淘汰最旧候选时置位(P1-3):候选数据本身仍在 event store
  /// (确认页合并口径可见),但用户应知道有旧候选被归档、尽快处理。
  static const _archivedHintKey = 'pending_candidates_archived_hint';

  // SharedPreferences 的 read-modify-write 不是原子的；AI 自动入口、候选页
  // 和确认操作可能同时触发，统一串行化避免互相覆盖候选。
  static Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<List<PendingCandidate>> _loadUnlocked() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    return raw
        .map((s) => _tryJson(s))
        .whereType<Map<String, dynamic>>()
        .map(PendingCandidate.fromJson)
        .whereType<PendingCandidate>()
        .toList();
  }

  Future<void> _saveUnlocked(List<PendingCandidate> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _key, list.map((c) => jsonEncode(c.toJson())).toList());
  }

  Future<List<PendingCandidate>> load() => _serial(_loadUnlocked);

  Future<void> save(List<PendingCandidate> list) =>
      _serial(() => _saveUnlocked(list));

  /// 追加候选;同一 id 已存在则幂等跳过。超出容量淘汰最旧(0 为最旧),
  /// 但不再无声(P1-3):淘汰时置位「已归档」提示,由确认页展示。
  /// 候选数据本身始终同时写入 event store,确认页合并口径仍可见全部。
  Future<bool> add(PendingCandidate candidate) => _serial(() async {
        final list = await _loadUnlocked();
        if (list.any((c) => c.id == candidate.id)) return false;
        list.add(candidate);
        var evicted = false;
        while (list.length > maxCandidates) {
          list.removeAt(0);
          evicted = true;
        }
        await _saveUnlocked(list);
        if (evicted) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_archivedHintKey, true);
        }
        return true;
      });

  /// legacy 队列是否发生过触 cap 淘汰(确认页顶部提示用)。
  Future<bool> hasArchivedHint() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_archivedHintKey) ?? false;
  }

  /// 清除「已归档」提示(确认页候选清空后调用)。
  Future<void> clearArchivedHint() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_archivedHintKey);
  }

  Future<bool> remove(String id) => _serial(() async {
        final list = await _loadUnlocked();
        final next = list.where((c) => c.id != id).toList();
        if (next.length == list.length) return false;
        await _saveUnlocked(next);
        return true;
      });

  Future<int> count() => _serial(() async => (await _loadUnlocked()).length);

  /// 从 event store 投影待确认候选，并与旧 SharedPreferences 候选合并。
  ///
  /// event store 是自动入口的事实来源；SharedPreferences 仅作为旧版本和
  /// event item 尚未写入时的兼容兜底。相同 (eventKey,itemIndex) 以 event store
  /// 版本为准，避免候选页展示已经被恢复/更新前的旧副本。
  Future<List<PendingCandidate>> loadForReview(
    AutoBookEventStore eventStore,
  ) async {
    final legacy = await load();
    final merged = <String, PendingCandidate>{};

    try {
      final events = await eventStore.listPending(limit: 500);
      for (final event in events) {
        final items = await eventStore.itemsForEvent(event.id);
        for (final item in items) {
          if (item.state != 'pending') continue;
          final payload = _tryMap(item.billJson);
          if (payload == null) continue;
          final billPayload = payload['bill'] is Map
              ? Map<String, dynamic>.from(payload['bill'] as Map)
              : payload;
          final bill = BillInfo.fromJson(billPayload);
          if (bill.amount == null || bill.time == null) continue;

          final candidate = PendingCandidate(
            id: payload['candidate_id']?.toString() ??
                '${event.eventKey}:${item.itemIndex}',
            bill: bill,
            billingTypes: (payload['billing_types'] as List?)
                    ?.map((value) => value.toString())
                    .toList() ??
                const [],
            source: payload['source']?.toString() ?? event.source,
            capturedAt: DateTime.tryParse(
                  payload['captured_at']?.toString() ?? '',
                ) ??
                event.capturedAt,
            reason: item.reason ?? payload['candidate_reason']?.toString(),
            eventKey: event.eventKey,
            eventItemIndex: item.itemIndex,
            semanticKey: item.semanticKey,
            matchedTransactionId:
                (payload['matched_transaction_id'] as num?)?.toInt() ??
                    item.transactionId,
            matchScore: (payload['match_score'] as num?)?.toDouble(),
          );
          merged['event:${event.eventKey}:${item.itemIndex}'] = candidate;
        }
      }
    } catch (_) {
      // event store 不可用时保留旧候选页，不能阻断用户处理已有候选。
    }

    for (final candidate in legacy) {
      final key = candidate.eventKey == null
          ? 'legacy:${candidate.id}'
          : 'event:${candidate.eventKey}:${candidate.eventItemIndex ?? 0}';
      merged.putIfAbsent(key, () => candidate);
    }

    final result = merged.values.toList()
      ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    return result;
  }
}

Map<String, dynamic>? _tryMap(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  try {
    final value = jsonDecode(raw);
    if (value is! Map) return null;
    return Map<String, dynamic>.from(value.cast<String, dynamic>());
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? _tryJson(String s) {
  try {
    return Map<String, dynamic>.from(
        (jsonDecode(s) as Map).cast<String, dynamic>());
  } catch (_) {
    return null;
  }
}
