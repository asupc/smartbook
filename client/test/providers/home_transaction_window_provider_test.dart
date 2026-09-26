// M5-4B 首页窗口控制器契约测试。
//
// 用真实 BeeDatabase + LocalRepository 种数据，通过 ProviderContainer override
// repositoryProvider / currentLedgerIdProvider 驱动 HomeTransactionWindowController。
// 覆盖:latest 初始加载、loadOlder 双向合并、账本切换 generation 防串账、
// 常驻上限收敛。

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/providers/database_providers.dart';
import 'package:smartbook/providers/home_transaction_window_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late BeeDatabase db;
  late LocalRepository repo;
  late ProviderContainer container;

  Future<void> seed(int ledgerId, int n, {DateTime? at}) async {
    final t = at ?? DateTime(2026, 7, 15);
    for (var i = 0; i < n; i++) {
      await repo.addTransaction(
          ledgerId: ledgerId,
          type: 'expense',
          amount: 100.0 + i,
          happenedAt: t);
    }
  }

  setUp(() {
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    container = ProviderContainer(overrides: [
      repositoryProvider.overrideWithValue(repo),
      currentLedgerIdProvider.overrideWith((ref) => 1),
    ]);
    addTearDown(container.dispose);
  });

  tearDown(() async => db.close());

  HomeTransactionWindowController controller() =>
      container.read(homeTransactionWindowProvider.notifier);

  test('latest 初始加载:仅窗口一页,isLatestMode 且 hasOlder 正确', () async {
    await seed(1, 120);
    await controller().initializeLatest();

    final st = container.read(homeTransactionWindowProvider);
    expect(st.isLatestMode, isTrue);
    expect(st.loadingInitial, isFalse);
    expect(st.items.length, lessThanOrEqualTo(81)); // <= pageSize(80)+探针
    expect(st.hasOlder, isTrue);
    expect(st.error, isNull);
  });

  test('loadOlder 合并去重,方向仍有更多', () async {
    await seed(1, 200, at: DateTime(2026, 7, 15));
    await controller().initializeLatest();

    final before = container.read(homeTransactionWindowProvider).items.length;
    await controller().loadOlder();
    final after = container.read(homeTransactionWindowProvider);

    expect(after.items.length, greaterThan(before));
    // 去重:合并后 id 集合大小 == items 长度
    final ids = after.items.map((r) => r.t.id).toSet();
    expect(ids.length, after.items.length);
  });

  test('账本切换:先清空再重载,旧账本结果不残留', () async {
    await seed(1, 50);
    await seed(2, 20);
    await controller().initializeLatest();
    expect(container.read(homeTransactionWindowProvider).items.length, 50);

    await controller().resetForLedgerChange(2);
    final st = container.read(homeTransactionWindowProvider);
    expect(st.items.every((r) => r.t.ledgerId == 2), isTrue);
    expect(st.items.length, 20);
  });

  test('generation 防串账:重置后旧 ledger 结果不污染新状态', () async {
    await seed(1, 10);
    await seed(2, 10);
    await controller().initializeLatest();
    final gen0 = container.read(homeTransactionWindowProvider).generation;

    await controller().resetForLedgerChange(2);
    final gen1 = container.read(homeTransactionWindowProvider).generation;
    expect(gen1, greaterThan(gen0));
    expect(
        container.read(homeTransactionWindowProvider).items.every(
            (r) => r.t.ledgerId == 2),
        isTrue);
  });

  test('常驻上限:超过 960 笔时收敛且不重复', () async {
    // 只种 500 笔,验证 clamp 不误伤上限内数据
    await seed(1, 500);
    await controller().initializeLatest();
    await controller().loadOlder();
    final st = container.read(homeTransactionWindowProvider);
    expect(st.items.length, lessThanOrEqualTo(81 + 81)); // 两页上限
    expect(st.items.map((r) => r.t.id).toSet().length, st.items.length);
  });

  test('jumpToMonth:有数据月份锚定并加载历史记录,returnToLatest切回最新模式', () async {
    // 种 2026-05 的历史数据与 2026-08 的最新数据
    await seed(1, 10, at: DateTime(2026, 5, 20));
    await seed(1, 15, at: DateTime(2026, 8, 10));

    await controller().initializeLatest();
    var st = container.read(homeTransactionWindowProvider);
    expect(st.isLatestMode, isTrue);
    expect(st.items.first.t.happenedAt.month, 8);

    // 跳转到 5 月
    await controller().jumpToMonth(DateTime(2026, 5, 1));
    st = container.read(homeTransactionWindowProvider);
    expect(st.isLatestMode, isFalse);
    expect(st.anchorMonth, DateTime(2026, 5, 1));
    expect(st.items.isNotEmpty, isTrue);
    expect(st.items.first.t.happenedAt.month, 5);

    // 回到最新模式
    await controller().returnToLatest();
    st = container.read(homeTransactionWindowProvider);
    expect(st.isLatestMode, isTrue);
    expect(st.anchorMonth, isNull);
    expect(st.items.first.t.happenedAt.month, 8);
  });

  test('jumpToMonth:空月份 items 清空且 UI 呈现空态', () async {
    await seed(1, 10, at: DateTime(2026, 8, 10));
    await controller().initializeLatest();

    // 跳转到一个无数据的历史月份 (2025-01)
    await controller().jumpToMonth(DateTime(2025, 1, 1));
    final st = container.read(homeTransactionWindowProvider);
    expect(st.isLatestMode, isFalse);
    expect(st.anchorMonth, DateTime(2025, 1, 1));
    expect(st.items.isEmpty, isTrue);
    expect(st.hasOlder, isFalse);
    expect(st.hasNewer, isFalse);
  });
}
