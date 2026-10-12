import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 商户关键词 → 分类 学习表(批次5,2026-09-10;B4 升级为带作用域的规则)。
///
/// 用户在待确认页「编辑确认」或交易编辑页改动 AI 给出的分类时落一条映射,
/// 之后同商户的自动记账优先使用映射分类 —— 分类匹配此前是纯静态关键词表
/// (category_matcher),AI 错一次同一商户永远错下去。
///
/// B4 升级:
/// - **账本作用域**:规则只在指定账本生效;`ledgerId == null` = **旧版规则**
///   (升级前创建,作用账本未确认),未确认前仍按旧口径全局生效,并在规则页
///   提示绑定范围 —— 避免一次迁移让所有旧规则跨账本生效(计划 B4 任务 6);
/// - **可停用**:停用的规则保留但不参与匹配,用户可随时恢复;
/// - **可编辑/删除**:单条 remove / update,规则更改只影响未来事件。
///
/// 与 [DedupExemptStore] 同范式:本地表、SharedPreferences 持久化、容量上限
/// 淘汰最旧。不进云同步(设备各自学习)。
class CategoryLearningRule {
  /// 商户/备注关键词(normalizeAutoBookText 后的小写串,子串匹配)。
  final String keyword;

  /// 用户裁定的分类名(category_matcher 的匹配口径是分类名)。
  final String categoryName;

  /// 分类 kind(expense/income/transfer),避免同名不同向的分类误命中。
  final String kind;

  /// 规则生效账本(本地 id);null = 旧版规则,作用账本未确认。
  final int? ledgerId;

  /// 停用的规则保留但不匹配(用户可恢复)。
  final bool disabled;

  final DateTime createdAt;

  const CategoryLearningRule({
    required this.keyword,
    required this.categoryName,
    required this.kind,
    required this.createdAt,
    this.ledgerId,
    this.disabled = false,
  });

  /// 旧版规则:创建时没有账本作用域。
  bool get isLegacy => ledgerId == null;

  Map<String, dynamic> toJson() => {
        'keyword': keyword,
        'categoryName': categoryName,
        'kind': kind,
        'createdAt': createdAt.toIso8601String(),
        if (ledgerId != null) 'ledgerId': ledgerId,
        if (disabled) 'disabled': true,
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
      ledgerId: (json['ledgerId'] as num?)?.toInt(),
      disabled: json['disabled'] == true,
    );
  }

  CategoryLearningRule copyWith({
    String? categoryName,
    String? kind,
    int? ledgerId,
    bool clearLedger = false,
    bool? disabled,
    String? keyword,
  }) =>
      CategoryLearningRule(
        keyword: keyword ?? this.keyword,
        categoryName: categoryName ?? this.categoryName,
        kind: kind ?? this.kind,
        createdAt: createdAt,
        ledgerId: clearLedger ? null : (ledgerId ?? this.ledgerId),
        disabled: disabled ?? this.disabled,
      );

  bool keywordHits(String? normalizedText) {
    if (normalizedText == null || normalizedText.isEmpty) return false;
    return normalizedText.contains(keyword);
  }
}

class CategoryLearningStore {
  static const _key = 'category_learning_rules_v1';
  static const maxRules = 300;

  // A14(2026-10-11):SharedPreferences 的 read-modify-write 不是原子的 ——
  // add 的「list() → 过滤 → add → _save()」在并发下会互相覆盖,用户纠错过的
  // 分类学习记录静默丢失(待确认页「编辑确认」与交易编辑页可能几乎同时落
  // 规则)。照抄 [PendingCandidateStore._tail] 的进程级尾链统一串行化。
  static Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

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
  /// A14:整段 read-modify-write 走 [_serial] 尾链,并发 add 不丢更新。
  Future<void> add({
    required String keyword,
    required String categoryName,
    required String kind,
    int? ledgerId,
  }) {
    final kw = keyword.trim().toLowerCase();
    if (kw.isEmpty || categoryName.trim().isEmpty) {
      return Future<void>.value();
    }
    return _serial(() async {
      final rules = (await list()).where((r) => r.keyword != kw).toList();
      rules.add(CategoryLearningRule(
        keyword: kw,
        categoryName: categoryName.trim(),
        kind: kind,
        ledgerId: ledgerId,
        createdAt: DateTime.now(),
      ));
      await _save(rules);
    });
  }

  /// 编辑单条规则(B4 任务 5:可编辑)。按原 keyword 定位。
  /// A14:写路径统一串行,避免与并发 add 互相覆盖。
  Future<bool> update(CategoryLearningRule rule) => _serial(() async {
        final rules = await list();
        var changed = false;
        for (var i = 0; i < rules.length; i++) {
          if (rules[i].keyword == rule.keyword) {
            rules[i] = rule;
            changed = true;
          }
        }
        if (changed) await _save(rules);
        return changed;
      });

  /// 删除单条规则;返回是否删到。
  /// A14:与 [add]/[update] 同一条尾链。
  Future<bool> remove(String keyword) => _serial(() async {
        final kw = keyword.trim().toLowerCase();
        final rules = await list();
        final next = rules.where((r) => r.keyword != kw).toList();
        if (next.length == rules.length) return false;
        await _save(next);
        return true;
      });

  /// 停用/启用单条规则(保留规则本身,只影响未来事件)。
  /// A14:与其它写路径同链。
  Future<bool> setEnabled(String keyword, bool enabled) => _serial(() async {
        final kw = keyword.trim().toLowerCase();
        final rules = await list();
        var changed = false;
        for (var i = 0; i < rules.length; i++) {
          if (rules[i].keyword == kw && rules[i].disabled == enabled) {
            rules[i] = rules[i].copyWith(disabled: !enabled);
            changed = true;
          }
        }
        if (changed) await _save(rules);
        return changed;
      });

  /// 旧版规则(作用账本未确认)—— 规则页提示逐条绑定范围。
  Future<List<CategoryLearningRule>> legacyRules() async =>
      (await list()).where((r) => r.isLegacy).toList();

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
  ///
  /// 作用域:停用的不命中;绑定了账本的规则只在 [ledgerId] 相同的账本命中;
  /// 旧版规则(未绑定)保持旧口径全局生效,直到用户确认范围。
  Future<CategoryLearningRule?> match(
    String? normalizedText,
    String kind, {
    int? ledgerId,
  }) async {
    if (normalizedText == null || normalizedText.isEmpty) return null;
    final rules = await list();
    for (final r in rules.reversed) {
      if (r.disabled) continue;
      if (r.kind != kind) continue;
      if (r.ledgerId != null && r.ledgerId != ledgerId) continue;
      if (r.keywordHits(normalizedText)) return r;
    }
    return null;
  }
}
