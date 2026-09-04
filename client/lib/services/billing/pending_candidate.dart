import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../ai/core/bill_info.dart';

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

  const PendingCandidate({
    required this.id,
    required this.bill,
    this.billingTypes = const [],
    this.source = 'auto',
    required this.capturedAt,
    this.reason,
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
      };

  static PendingCandidate? fromJson(Map<String, dynamic> json) {
    try {
      final billJson = json['bill'];
      if (billJson is! Map) return null;
      return PendingCandidate(
        id: json['id'] as String? ?? '',
        bill: BillInfo.fromJson(Map<String, dynamic>.from(billJson)),
        billingTypes: (json['billingTypes'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        source: json['source'] as String? ?? 'auto',
        capturedAt:
            DateTime.tryParse(json['capturedAt'] as String? ?? '') ?? DateTime.now(),
        reason: json['reason'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  PendingCandidate copyWith({BillInfo? bill, String? reason}) {
    return PendingCandidate(
      id: bill != null ? candidateId(bill) : id,
      bill: bill ?? this.bill,
      billingTypes: billingTypes,
      source: source,
      capturedAt: capturedAt,
      reason: reason ?? this.reason,
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
      final sameNote = bill.note != null &&
          bill.note!.isNotEmpty &&
          bill.note == other.note;
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

  const AutoBookFlow({required this.store});
}

/// 待确认候选队列存储(SharedPreferences,cap [maxCandidates])。
class PendingCandidateStore {
  static const _key = 'pending_candidates_v1';
  static const int maxCandidates = 100;

  Future<List<PendingCandidate>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    return raw
        .map((s) => _tryJson(s))
        .whereType<Map<String, dynamic>>()
        .map(PendingCandidate.fromJson)
        .whereType<PendingCandidate>()
        .toList();
  }

  Future<void> save(List<PendingCandidate> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _key, list.map((c) => jsonEncode(c.toJson())).toList());
  }

  /// 追加候选;同一 id 已存在则幂等跳过。超出容量删最旧(0 为最旧)。
  Future<bool> add(PendingCandidate candidate) async {
    final list = await load();
    if (list.any((c) => c.id == candidate.id)) return false;
    list.add(candidate);
    while (list.length > maxCandidates) {
      list.removeAt(0);
    }
    await save(list);
    return true;
  }

  Future<bool> remove(String id) async {
    final list = await load();
    final next = list.where((c) => c.id != id).toList();
    if (next.length == list.length) return false;
    await save(next);
    return true;
  }

  Future<int> count() async => (await load()).length;
}

Map<String, dynamic>? _tryJson(String s) {
  try {
    return Map<String, dynamic>.from(
        (jsonDecode(s) as Map).cast<String, dynamic>());
  } catch (_) {
    return null;
  }
}
