// M5-4 keyset 分页 Repository 契约测试。
//
// 覆盖稳定排序键 (happened_at DESC, id DESC)、older/newer 双向翻页、同时间戳
// 跨页无重复/无漏项、bounded window watch 收敛、月份区间探测，以及 query-plan
// 命中新增索引 idx_transactions_ledger_time_id。

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/data/repositories/transaction_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late BeeDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  /// 插入 [n] 笔指定时间戳的交易，返回它们的 (time, id) 序列。
  /// 同一时间戳下按插入顺序得到递增 id。
  Future<List<int>> seedTx(int ledgerId, int idStart, int n,
      {DateTime? at, String type = 'expense'}) async {
    final ids = <int>[];
    final t = at ?? DateTime(2026, 7, 15);
    for (var i = 0; i < n; i++) {
      ids.add(await repo.addTransaction(
          ledgerId: ledgerId, type: type, amount: 100.0 + i, happenedAt: t));
    }
    return ids;
  }

  group('getTransactionPageWithCategory', () {
    test('初始页:降序首屏,hasOlder 由 limit+1 探测,hasNewer=false', () async {
      await seedTx(1, 0, 90);
      final page = await repo.getTransactionPageWithCategory(
          ledgerId: 1, limit: 80);

      expect(page.items.length, 80);
      expect(page.hasOlder, isTrue); // 还有 10 笔更旧
      expect(page.hasNewer, isFalse); // 已到最顶
      // 降序:第一笔 id 最大
      expect(page.items.first.t.id, greaterThan(page.items.last.t.id));
      // 与全量查询同形
      expect(page.firstCursor!.id, page.items.first.t.id);
      expect(page.lastCursor!.id, page.items.last.t.id);
    });

    test('恰好一页:limit+1 探测无更多', () async {
      await seedTx(1, 0, 80);
      final page =
          await repo.getTransactionPageWithCategory(ledgerId: 1, limit: 80);

      expect(page.items.length, 80);
      expect(page.hasOlder, isFalse);
      expect(page.hasNewer, isFalse);
    });

    test('空账本:返回空页且两个方向均不可达', () async {
      final page =
          await repo.getTransactionPageWithCategory(ledgerId: 999, limit: 80);
      expect(page.items, isEmpty);
      expect(page.hasOlder, isFalse);
      expect(page.hasNewer, isFalse);
      expect(page.firstCursor, isNull);
      expect(page.lastCursor, isNull);
    });

    test('翻旧页(before):双键游标,同时间戳跨页无重复无漏项', () async {
      // 200 笔同时间戳(id 0..199),分 3 页(80/80/40)。
      final all = await seedTx(1, 0, 200, at: DateTime(2026, 7, 15));

      final p1 = await repo.getTransactionPageWithCategory(ledgerId: 1, limit: 80);
      expect(p1.items.length, 80);
      expect(p1.items.map((r) => r.t.id).toSet(), all.sublist(120).toSet());

      final p2 = await repo.getTransactionPageWithCategory(
          ledgerId: 1, before: p1.lastCursor, limit: 80);
      expect(p2.items.map((r) => r.t.id).toSet(), all.sublist(40, 120).toSet());

      final p3 = await repo.getTransactionPageWithCategory(
          ledgerId: 1, before: p2.lastCursor, limit: 80);
      expect(p3.items.map((r) => r.t.id).toSet(), all.sublist(0, 40).toSet());
      expect(p3.hasOlder, isFalse);
      expect(p3.hasNewer, isTrue);
    });

    test('翻新页(after):从翻旧页边界向上翻回最新', () async {
      final all = await seedTx(1, 0, 200);

      final init = await repo.getTransactionPageWithCategory(ledgerId: 1, limit: 80);
      // 初始页 = id 199..120,lastCursor = id 120
      final older = await repo.getTransactionPageWithCategory(
          ledgerId: 1, before: init.lastCursor, limit: 80);
      // 翻旧页 = id 119..40,firstCursor = id 119
      expect(older.items.map((r) => r.t.id).toSet(),
          all.sublist(40, 120).toSet());

      // 从翻旧页的 firstCursor(id 119)向上翻 → 应回到初始页 id 199..120
      final backUp = await repo.getTransactionPageWithCategory(
          ledgerId: 1,
          after: older.firstCursor,
          limit: 80,
      );
      expect(backUp.items.map((r) => r.t.id), init.items.map((r) => r.t.id));
      expect(backUp.hasOlder, isTrue);
      expect(backUp.hasNewer, isFalse);
    });

    test('older/newer 往返后 ID 集合一致', () async {
      final all = await seedTx(1, 0, 150);

      final init = await repo.getTransactionPageWithCategory(ledgerId: 1, limit: 80);
      final older = await repo.getTransactionPageWithCategory(
          ledgerId: 1, before: init.lastCursor, limit: 80);
      final backToNew = await repo.getTransactionPageWithCategory(
          ledgerId: 1, after: older.firstCursor, limit: 80);

      // 从 older 页的第一笔向上翻一页 → 应回到 init 的窗口
      expect(backToNew.items.map((r) => r.t.id), init.items.map((r) => r.t.id));
    });

    test('跨账本同 syncId/同时间戳不串数据', () async {
      await seedTx(1, 0, 5);
      await seedTx(2, 0, 5, at: DateTime(2026, 7, 15));

      final p1 = await repo.getTransactionPageWithCategory(ledgerId: 1, limit: 80);
      expect(p1.items.every((r) => r.t.ledgerId == 1), isTrue);
      expect(p1.items.length, 5);
    });
  });

  group('watchTransactionWindowWithCategory', () {
    test('窗口内增删改触发收敛(删除窗口内交易后不再出现)', () async {
      final ids = await seedTx(1, 0, 10);
      final oldestCursor = (await repo.getTransactionPageWithCategory(
              ledgerId: 1, limit: 80))
          .lastCursor!;

      final emitted = <List<TransactionWithRefs>>[];
      final sub = repo
          .watchTransactionWindowWithCategory(
            ledgerId: 1,
            oldestInclusive: oldestCursor,
          )
          .listen(emitted.add);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(emitted, isNotEmpty);
      expect(emitted.last.length, 10);

      // 删除窗口内一笔 → bounded watch 应重发且不包含该 id
      await repo.deleteTransaction(ids.first);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(emitted.last.map((r) => r.t.id), isNot(contains(ids.first)));
      expect(emitted.last.length, 9);

      await sub.cancel();
    });

    test('窗口外(更旧)交易不进入 bounded watch', () async {
      // 一条很旧的时间戳,应被 oldestInclusive 排除
      await repo.addTransaction(
          ledgerId: 1,
          type: 'expense',
          amount: 1,
          happenedAt: DateTime(2020, 1, 1));
      final ids = await seedTx(1, 0, 5);
      final keep = await repo.getTransactionPageWithCategory(ledgerId: 1, limit: 80);

      // keep 降序 = [2026 的 5 笔(id 5..1), 2020 的 1 笔]。以 2026 序列最小
      // id(keep.items[4])为下界 → 窗口应保留全部 5 笔 2026,排除 2020。
      final cut = keep.items[4];
      final emitted = <List<TransactionWithRefs>>[];
      final sub = repo
          .watchTransactionWindowWithCategory(
            ledgerId: 1,
            oldestInclusive: TransactionPageCursor(
                happenedAt: cut.t.happenedAt, id: cut.t.id),
          )
          .listen(emitted.add);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(emitted, isNotEmpty);
      expect(emitted.last.every((r) => !r.t.happenedAt.isBefore(cut.t.happenedAt)),
          isTrue);
      // 5 笔(2026-07-15) — 2020 被排除
      expect(emitted.last.length, 5);
      await sub.cancel();
    });
  });

  group('hasTransactionsInPeriod', () {
    test('区间有无边界正确(左闭右开)', () async {
      await repo.addTransaction(
          ledgerId: 1,
          type: 'expense',
          amount: 10,
          happenedAt: DateTime(2026, 7, 15, 12));

      expect(
          await repo.hasTransactionsInPeriod(
              ledgerId: 1,
              start: DateTime(2026, 7, 15),
              end: DateTime(2026, 7, 16)),
          isTrue);
      // 右边界开:end 恰好等于 16 号 0 点,15 号 12 点不包含 → 但 15号12点在区间内
      expect(
          await repo.hasTransactionsInPeriod(
              ledgerId: 1,
              start: DateTime(2026, 7, 16),
              end: DateTime(2026, 7, 17)),
          isFalse);
      expect(
          await repo.hasTransactionsInPeriod(
              ledgerId: 999,
              start: DateTime(2026, 7, 1),
              end: DateTime(2026, 8, 1)),
          isFalse);
    });
  });

  group('query plan', () {
    test('翻页查询命中 idx_transactions_ledger_time_id', () async {
      final plan = await db.customSelect(
        'EXPLAIN QUERY PLAN SELECT id, happened_at FROM transactions '
        'WHERE ledger_id = ? AND happened_at < ? '
        'ORDER BY happened_at DESC, id DESC LIMIT 81;',
        variables: [d.Variable.withInt(1), d.Variable(DateTime(2026, 7, 16))],
      ).get();
      final detail = plan.map((r) => r.read<String>('detail')).join('\n');
      expect(detail, contains('idx_transactions_ledger_time_id'));
    });

    test('向新翻页(升序)也命中同一索引', () async {
      final plan = await db.customSelect(
        'EXPLAIN QUERY PLAN SELECT id, happened_at FROM transactions '
        'WHERE ledger_id = ? AND happened_at > ? '
        'ORDER BY happened_at ASC, id ASC LIMIT 81;',
        variables: [d.Variable.withInt(1), d.Variable(DateTime(2026, 7, 1))],
      ).get();
      final detail = plan.map((r) => r.read<String>('detail')).join('\n');
      expect(detail, contains('idx_transactions_ledger_time_id'));
    });
  });
}
