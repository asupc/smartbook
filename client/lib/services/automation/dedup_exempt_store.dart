import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 判重豁免规则(P1-1):用户在待确认页选择「仍记一笔」时落一条
/// (商户/备注关键词, 金额段),后续语义判重命中该对时跳过 ——
/// 用户已经裁定「这是两笔」,同类误判不应复发。
///
/// 本地表,不进云同步;设置页可查看/清除。
class DedupExemptRule {
  /// 商户/备注关键词(normalizeAutoBookText 后的小写串,子串匹配)。
  final String keyword;

  /// 基准金额(绝对值);金额段判定见 [amountWithinSegment]。
  final double amount;
  final DateTime createdAt;

  const DedupExemptRule({
    required this.keyword,
    required this.amount,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'keyword': keyword,
        'amount': amount,
        'createdAt': createdAt.toIso8601String(),
      };

  static DedupExemptRule? fromJson(Map<String, dynamic> json) {
    final keyword = json['keyword'];
    final amount = json['amount'];
    if (keyword is! String || keyword.trim().isEmpty) return null;
    if (amount is! num) return null;
    return DedupExemptRule(
      keyword: keyword.trim().toLowerCase(),
      amount: amount.toDouble(),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  /// 金额段:±10% 且至少 ±1 元(小额同商户常为同价,只按关键字即可)。
  bool amountWithinSegment(double other) {
    final base = amount.abs();
    final target = other.abs();
    final tolerance = base * 0.10 >= 1.0 ? base * 0.10 : 1.0;
    return (base - target).abs() <= tolerance + 0.01;
  }

  /// 关键字是否命中(子串;两侧都应是规范化小写文本)。
  bool keywordHits(String? normalizedText) {
    if (normalizedText == null || normalizedText.isEmpty) return false;
    return normalizedText.contains(keyword);
  }
}

class DedupExemptStore {
  static const _key = 'dedup_exempt_rules_v1';
  static const maxRules = 200;

  Future<List<DedupExemptRule>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    return raw
        .map((s) {
          try {
            final v = jsonDecode(s);
            return v is Map
                ? DedupExemptRule.fromJson(Map<String, dynamic>.from(v))
                : null;
          } catch (_) {
            return null;
          }
        })
        .whereType<DedupExemptRule>()
        .toList();
  }

  /// 追加规则;同 keyword+amount 幂等。超容量淘汰最旧。
  Future<void> add({required String keyword, required double amount}) async {
    final clean = keyword.trim().toLowerCase();
    if (clean.isEmpty) return;
    final rules = await list();
    if (rules.any((r) =>
        r.keyword == clean && r.amountWithinSegment(amount))) {
      return;
    }
    rules.add(DedupExemptRule(
        keyword: clean, amount: amount, createdAt: DateTime.now()));
    while (rules.length > maxRules) {
      rules.removeAt(0);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _key, rules.map((r) => jsonEncode(r.toJson())).toList());
  }

  Future<int> clear() async {
    final prefs = await SharedPreferences.getInstance();
    final before = (prefs.getStringList(_key) ?? const []).length;
    await prefs.remove(_key);
    return before;
  }

  /// (新账单, 已有交易) 是否被豁免。
  ///
  /// [billNoteNormalized]/[txNoteNormalized] 均为 normalizeAutoBookText 后
  /// 的小写文本;任一规则同时命中「关键字 + 金额段」即豁免。
  static bool isExempt(
    List<DedupExemptRule> rules, {
    required double? billAmount,
    required String? billNoteNormalized,
    required double txAmount,
    required String? txNoteNormalized,
  }) {
    if (rules.isEmpty) return false;
    final amount = billAmount;
    if (amount == null || amount.abs() <= 0) return false;
    for (final rule in rules) {
      if (!rule.amountWithinSegment(txAmount)) continue;
      if (!rule.amountWithinSegment(amount)) continue;
      if (rule.keywordHits(billNoteNormalized) ||
          rule.keywordHits(txNoteNormalized)) {
        return true;
      }
    }
    return false;
  }
}
