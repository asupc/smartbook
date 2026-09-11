import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 商户关键词 → 分类 学习表(批次5,2026-09-10)。
///
/// 用户在待确认页「编辑确认」或交易编辑页改动 AI 给出的分类时落一条映射,
/// 之后同商户的自动记账优先使用映射分类 —— 分类匹配此前是纯静态关键词表
/// (category_matcher),AI 错一次同一商户永远错下去。
///
/// 与 [DedupExemptStore] 同范式:本地表、SharedPreferences 持久化、设置可
/// 清除、容量上限淘汰最旧。不进云同步(设备各自学习)。
class CategoryLearningRule {
  /// 商户/备注关键词(normalizeAutoBookText 后的小写串,子串匹配)。
  final String keyword;

  /// 用户裁定的分类名(category_matcher 的匹配口径是分类名)。
  final String categoryName;

  /// 分类 kind(expense/income),避免同名不同向的分类误命中。
  final String kind;

  final DateTime createdAt;

  const CategoryLearningRule({
    required this.keyword,
    required this.categoryName,
    required this.kind,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'keyword': keyword,
        'categoryName': categoryName,
        'kind': kind,
        'createdAt': createdAt.toIso8601String(),
      };

  static CategoryLearningRule? fromJson(Map<String, dynamic> json) {
    final keyword = json['keyword'];
    final categoryName = json['categoryName'];
    final kind = json['kind'];
    if (keyword is! String || keyword.trim().isEmpty) return null;
    if (categoryName is! String || categoryName.trim().isEmpty) return null;
    if (kind is! String || kind.isEmpty) return null;
    return CategoryLearningRule(
      keyword: keyword.trim().toLowerCase(),
      categoryName: categoryName.trim(),
      kind: kind,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
              DateTime.now(),
    );
  }

  bool keywordHits(String? normalizedText) {
    if (normalizedText == null || normalizedText.isEmpty) return false;
    return normalizedText.contains(keyword);
  }
}

class CategoryLearningStore {
  static const _key = 'category_learning_rules_v1';
  static const maxRules = 300;

  Future<List<CategoryLearningRule>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    return raw
        .map((s) {
          try {
            final v = jsonDecode(s);
            return v is Map
                ? CategoryLearningRule.fromJson(
                    Map<String, dynamic>.from(v))
                : null;
          } catch (_) {
            return null;
          }
        })
        .whereType<CategoryLearningRule>()
        .toList();
  }

  /// 追加/更新映射;同 keyword 覆盖(用户最近一次裁定为准)。超容量淘汰最旧。
  Future<void> add({
    required String keyword,
    required String categoryName,
    required String kind,
  }) async {
    final kw = keyword.trim().toLowerCase();
    if (kw.isEmpty || categoryName.trim().isEmpty) return;
    final rules = (await list())
        .where((r) => r.keyword != kw)
        .toList();
    rules.add(CategoryLearningRule(
      keyword: kw,
      categoryName: categoryName.trim(),
      kind: kind,
      createdAt: DateTime.now(),
    ));
    await _save(rules);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  Future<void> _save(List<CategoryLearningRule> rules) async {
    if (rules.length > maxRules) {
      rules = rules.sublist(rules.length - maxRules);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _key,
      rules.map((r) => jsonEncode(r.toJson())).toList(),
    );
  }

  /// 命中查询:返回第一个 keyword 命中且 kind 匹配的规则(最近裁定优先)。
  Future<CategoryLearningRule?> match(
    String? normalizedText,
    String kind,
  ) async {
    if (normalizedText == null || normalizedText.isEmpty) return null;
    final rules = await list();
    for (final r in rules.reversed) {
      if (r.kind != kind) continue;
      if (r.keywordHits(normalizedText)) return r;
    }
    return null;
  }
}
