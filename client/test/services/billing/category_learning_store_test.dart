import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/services/billing/category_learning_store.dart';

/// B4 任务 5/6:分类学习规则的作用域、停用、编辑与旧版规则口径。
void main() {
  late CategoryLearningStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = CategoryLearningStore();
  });

  test('add + match:同账本命中', () async {
    await store.add(
      keyword: '星巴克',
      categoryName: '餐饮',
      kind: 'expense',
      ledgerId: 1,
    );
    final hit = await store.match('咖啡 星巴克 30', 'expense', ledgerId: 1);
    expect(hit, isNotNull);
    expect(hit!.categoryName, '餐饮');
  });

  test('作用域:规则绑定账本 1,账本 2 不命中', () async {
    await store.add(
      keyword: '美团',
      categoryName: '外卖',
      kind: 'expense',
      ledgerId: 1,
    );
    expect(
      await store.match('美团外卖', 'expense', ledgerId: 2),
      isNull,
      reason: '规则只在绑定账本生效,不自动推广到其它账本',
    );
    expect(await store.match('美团外卖', 'expense', ledgerId: 1), isNotNull);
  });

  test('旧版规则(未绑定账本)保持旧口径:任意账本都命中', () async {
    await store.add(keyword: '滴滴', categoryName: '交通', kind: 'expense');
    final legacy = await store.legacyRules();
    expect(legacy, hasLength(1));
    expect(legacy.single.isLegacy, isTrue);
    expect(await store.match('滴滴出行', 'expense', ledgerId: 7), isNotNull);
    expect(await store.match('滴滴出行', 'expense', ledgerId: 9), isNotNull);
  });

  test('kind(方向)不匹配不命中', () async {
    await store.add(keyword: '工资', categoryName: '收入', kind: 'income');
    expect(await store.match('工资入账', 'income'), isNotNull);
    expect(await store.match('工资入账', 'expense'), isNull);
  });

  test('停用的规则保留但不参与匹配', () async {
    await store.add(keyword: '京东', categoryName: '购物', kind: 'expense');
    expect(await store.match('京东订单', 'expense'), isNotNull);

    expect(await store.setEnabled('京东', false), isTrue);
    expect(await store.match('京东订单', 'expense'), isNull,
        reason: '停用规则不应再影响未来账单');

    final rules = await store.list();
    expect(rules, hasLength(1), reason: '停用只是不匹配,不是删除');
    expect(rules.single.disabled, isTrue);

    await store.setEnabled('京东', true);
    expect(await store.match('京东订单', 'expense'), isNotNull);
  });

  test('绑定作用账本后不再是旧版规则', () async {
    await store.add(keyword: '淘宝', categoryName: '购物', kind: 'expense');
    expect((await store.legacyRules()), hasLength(1));

    final bound = (await store.list()).single.copyWith(ledgerId: 3);
    expect(await store.update(bound), isTrue);
    expect(await store.legacyRules(), isEmpty);
    expect(
      await store.match('淘宝订单', 'expense', ledgerId: 3),
      isNotNull,
    );
    expect(await store.match('淘宝订单', 'expense', ledgerId: 4), isNull);
  });

  test('单条删除与编辑分类名', () async {
    await store.add(keyword: '饿了么', categoryName: '外卖', kind: 'expense');
    final rule = (await store.list()).single;
    expect(await store.update(rule.copyWith(categoryName: '餐饮')), isTrue);
    expect(
      (await store.list()).single.categoryName,
      '餐饮',
    );

    expect(await store.remove('饿了么'), isTrue);
    expect(await store.remove('饿了么'), isFalse, reason: '重复删除返回 false');
    expect(await store.list(), isEmpty);
  });

  test('同 keyword 覆盖(最近裁定优先)', () async {
    await store.add(keyword: '瑞幸', categoryName: '咖啡', kind: 'expense');
    await store.add(keyword: '瑞幸', categoryName: '餐饮', kind: 'expense');
    final rules = await store.list();
    expect(rules, hasLength(1));
    expect(rules.single.categoryName, '餐饮');
  });

  test('损坏条目跳过,不影响其余规则', () async {
    final prefs = await SharedPreferences.getInstance();
    await store.add(keyword: '正常', categoryName: '其他', kind: 'expense');
    final raw = prefs.getStringList('category_learning_rules_v1')!;
    raw.insert(0, 'not-json');
    await prefs.setStringList('category_learning_rules_v1', raw);

    final rules = await store.list();
    expect(rules, hasLength(1));
    expect(rules.single.keyword, '正常');
  });
}
