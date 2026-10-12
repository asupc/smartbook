// 对抗性测试 — 并发 / 交叉写域(SmartBook 客户端数据层)。
//
// 攻击面:同账户并发 adjustBalance(lost update?)、并发 update 同字段、
// 并发 read-modify-write(建账户时算 sortOrder、标签查重后插入)、
// 并发回收站操作、transactions 表 concurrent insert 的 change 记录。
//
// 反 flaky 约定:全部并发用一次性 Future.wait;结果不确定的场景只断言
// 「不变量」(如总数、无重复)或明确标注「未能验证」。
//
// 注意:测试跑在**单 isolate** 的 NativeDatabase.memory 上。drift 的写操作
// 经 _BaseExecutor._synchronized 串行化,因此这里验证的是「同一连接上的
// 逻辑并发」,不是真正的多进程/多连接竞争。
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/cloud/sync/change_tracker.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';

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

  Future<void> seedLedger([int id = 1, String currency = 'CNY']) {
    return db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES ($id, 'L$id', '$currency')");
  }

  // ══════════════════════════════════════════════════════════════════════
  // V. 并发余额调整 / 交易写入
  // ══════════════════════════════════════════════════════════════════════

  group('V. 并发写入', () {
    test('V1 同账户并发 addAccountAdjustment:insert-only 无 lost update',
        () async {
      await seedLedger();
      final acc = await repo.createAccount(
          ledgerId: 1, name: 'V1', initialBalance: 1000);

      // 一次性发起,不依赖调度顺序(结果与顺序无关:全为 INSERT)
      final ids = await Future.wait([
        repo.addAccountAdjustment(ledgerId: 1, accountId: acc, amount: 100),
        repo.addAccountAdjustment(ledgerId: 1, accountId: acc, amount: -50),
        repo.addAccountAdjustment(ledgerId: 1, accountId: acc, amount: 25),
        repo.addAccountAdjustment(ledgerId: 1, accountId: acc, amount: -75),
      ]);

      final bal = await repo.getAccountBalance(acc);
      final rows = await db
          .customSelect('SELECT COUNT(*) c FROM account_adjustments')
          .getSingle();
      // HARDENING: 调整记录是 append-only INSERT(每条独立 syncId),
      // 不读-改-写 → 无 lost update。净变动 100-50+25-75 = 0。
      expect(ids.toSet().length, 4, reason: 'HARDENING: 4 条不同 id');
      expect(rows.data['c'], 4, reason: 'HARDENING: 4 行全落库');
      expect(bal, 1000.0,
          reason: 'HARDENING: 净变动 0 → 余额 1000(无丢写)');
    });

    test('V2 并发 addTransaction:全部落库且统计等于逐笔之和', () async {
      await seedLedger();
      final acc = await repo.createAccount(ledgerId: 1, name: 'V2');
      const n = 20;
      // 一半收入一半支出,金额确定
      await Future.wait([
        for (var i = 0; i < n; i++)
          repo.addTransaction(
              ledgerId: 1,
              type: i.isEven ? 'income' : 'expense',
              amount: (i + 1).toDouble(),
              accountId: acc,
              happenedAt: DateTime(2026, 7, 15)),
      ]);

      final rows = await repo.getTransactionsByLedger(1);
      var expectInc = 0.0, expectExp = 0.0;
      for (var i = 0; i < n; i++) {
        if (i.isEven) {
          expectInc += i + 1;
        } else {
          expectExp += i + 1;
        }
      }
      final (inc, exp) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 7, 1));
      expect(rows.length, n, reason: 'HARDENING: $n 笔全落库');
      expect(inc, expectInc, reason: 'HARDENING: 收入合计一致');
      expect(exp, expectExp, reason: 'HARDENING: 支出合计一致');
      // syncId 全不同(每条 UUID)
      expect(rows.map((t) => t.syncId).toSet().length, n,
          reason: 'HARDENING: syncId 无碰撞');
    });

    test('V3 并发 addTransaction + changeTracker:每条都登记 change', () async {
      await seedLedger();
      final tracker = ChangeTracker(db);
      final tracked = LocalRepository(db, changeTracker: tracker);
      const n = 10;
      await Future.wait([
        for (var i = 0; i < n; i++)
          tracked.addTransaction(
              ledgerId: 1, type: 'expense', amount: 1.0,
              happenedAt: DateTime(2026, 7, 15)),
      ]);
      final changes = await db.select(db.localChanges).get();
      final txRows = await db.select(db.transactions).get();
      // HARDENING: LocalRepository.addTransaction 是 insert → getTransactionById
      // → recordLedgerChange 三步非事务(read-then-act),但每步都只依赖
      // "刚插入的行"+ 单调递增的 local_changes.id → 并发下不会互相覆盖。
      expect(txRows.length, n);
      expect(changes.length, n,
          reason: 'HARDENING: 并发 $n 笔 → $n 条 change(无丢失)');
      expect(changes.map((c) => c.entitySyncId).toSet().length, n,
          reason: 'HARDENING: 每条 change 对应不同实体');
      expect(changes.every((c) => c.ledgerId == 1), isTrue);
      expect(changes.every((c) => c.action == 'create'), isTrue);
    });

    test('V4 并发 updateTransaction 同一笔字段:最后写完胜,不产生半更新',
        () async {
      await seedLedger();
      final id = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          happenedAt: DateTime(2026, 7, 1));

      // 两个互斥的整体写:一个写 income/20,一个写 transfer/30 + 换账户
      await Future.wait([
        repo.updateTransaction(
            id: id, type: 'income', amount: 20,
            happenedAt: DateTime(2026, 7, 2)),
        repo.updateTransaction(
            id: id, type: 'transfer', amount: 30,
            happenedAt: DateTime(2026, 7, 3)),
      ]);

      final t = await repo.getTransactionById(id);
      // HARDENING: 两条 UPDATE 各自是完整行写(无 read-modify-write 循环),
      // 只能整体覆盖 → 最终值必是二者之一(不会出现 type=income + amount=30
      // 这种交叉)。
      final isFirst = t!.type == 'income' && t.amount == 20.0;
      final isSecond = t.type == 'transfer' && t.amount == 30.0;
      expect(isFirst || isSecond, isTrue,
          reason: 'HARDENING: 结果是最后写完的整体值之一,无交叉字段'
              '(实际 type=${t.type} amount=${t.amount})');
    });

    test('V5 并发 addTransactionFields + updateTransaction 不同字段:'
        '双方都生效(无整行覆盖竞争)', () async {
      await seedLedger();
      final id = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          happenedAt: DateTime(2026, 7, 1), note: 'keep');

      await Future.wait([
        repo.updateTransactionFields(id: id, accountId: 7),
        repo.updateTransaction(
            id: id, type: 'expense', amount: 55,
            happenedAt: DateTime(2026, 7, 1)),
      ]);

      final t = await repo.getTransactionById(id);
      // ADVERSE FINDING: updateTransactionFields 发的是**部分列** UPDATE
      // (只有 accountId/toAccountId/override),而 updateTransaction 发的是
      // **整行** UPDATE(含 accountId: Value.absent → 不写)。两条 UPDATE
      // 事务化执行、字段集不重叠 → 都生效。
      // 但反过来说明:凡是走 updateTransaction 的路径都会**显式覆盖**
      // 它接收的每个字段(categoryId/note 默认写 null),所以"并发改不同
      // 字段"只在 updateTransactionFields 这条特例上成立。
      expect(t!.accountId, 7, reason: 'HARDENING: 账户列写入生效');
      expect(t.amount, 55.0, reason: 'HARDENING: 金额列写入生效');
      // updateTransaction 不传 note → 被清空(C1 的同一根因)
      expect(t.note, 'keep',
          reason: 'ADVERSE FINDING: updateTransaction 的整行写把未传的 note '
              '清成 null(与 C1 同根因);并发场景下"只改金额"也会连带清字段');
    });

    test('V6 并发创建账户:同名查重存在 TOCTOU 窗口,name 唯一性靠概率',
        () async {
      await seedLedger();
      // createAccount 是 select-then-insert,非原子。单连接下 drift 串行化
      // 每一步,但两步之间有 await 间隙 → 两个并发调用都可能通过查重。
      final results = <Object?>[];
      await Future.wait([
        repo.createAccount(ledgerId: 1, name: 'RACE-NAME').then(
            (v) => results.add(v), onError: (e) => results.add(e)),
        repo.createAccount(ledgerId: 1, name: 'RACE-NAME').then(
            (v) => results.add(v), onError: (e) => results.add(e)),
      ]);
      final rows = await db
          .customSelect("SELECT COUNT(*) c FROM accounts WHERE name = 'RACE-NAME'")
          .getSingle();
      final errCount = results.whereType<Object>().where((r) => r is Exception || r is Error).length;

      // 结果有两种可能(取决于 drift 的调度时机),两种都记录:
      //   (a) 一个成功一个抛 DuplicateNameException → 查重有效
      //   (b) 两个都成功 → 查重被绕过(TOCTOU)
      // 单连接内存库上实测 (b):两步之间没有其它事务可插入,
      // 但 drift 的 select/get 与 insert 之间确实存在 await 让步点。
      expect(rows.data['c'], 1,
          reason: 'ADVERSE FINDING: 并发同名 createAccount 落库 ${rows.data['c']} 行'
              '(期望 1);查重是 select-then-insert 非原子(TOCTOU),'
              '并发调用可绕过"name 全局唯一"契约(errCount=$errCount)');
    });

    test('V7 并发创建分类:同名查重同样可被绕过', () async {
      await seedLedger();
      final results = <Object?>[];
      await Future.wait([
        repo.createCategory(name: 'RACE-CAT', kind: 'expense').then(
            (v) => results.add(v), onError: (e) => results.add(e)),
        repo.createCategory(name: 'RACE-CAT', kind: 'expense').then(
            (v) => results.add(v), onError: (e) => results.add(e)),
      ]);
      final rows = await db
          .customSelect(
              "SELECT COUNT(*) c FROM categories WHERE name = 'RACE-CAT' AND kind = 'expense'")
          .getSingle();
      expect(rows.data['c'], 1,
          reason: 'ADVERSE FINDING: 并发同名 createCategory 落库 '
              '${rows.data['c']} 行(期望 1);(name,kind) 联合唯一只靠'
              '应用层 select-then-insert');
    });

    test('V8 并发 updateAccountSortOrders / updateAccountSortOrders 交错:'
        '各自事务内串行,最终为最后一次', () async {
      await seedLedger();
      final a = await repo.createAccount(ledgerId: 1, name: 'S1');
      final b = await repo.createAccount(ledgerId: 1, name: 'S2');
      await Future.wait([
        repo.updateAccountSortOrders([(id: a, sortOrder: 10), (id: b, sortOrder: 20)]),
        repo.updateAccountSortOrders([(id: a, sortOrder: 30), (id: b, sortOrder: 40)]),
      ]);
      final accounts = await repo.getAllAccounts();
      final sa = accounts.firstWhere((x) => x.id == a).sortOrder;
      final sb = accounts.firstWhere((x) => x.id == b).sortOrder;
      // HARDENING: 每个 updateAccountSortOrders 是一个 db.transaction,
      // 两个事务互斥 → 最终值是某一整批((10,20) 或 (30,40)),不会混。
      expect(
          (sa == 10 && sb == 20) || (sa == 30 && sb == 40), isTrue,
          reason: 'HARDENING: 排序批次整体生效,无混批(实际 $sa/$sb)');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // W. 并发回收站 / 批量
  // ══════════════════════════════════════════════════════════════════════

  group('W. 并发回收站与批量', () {
    test('W1 并发 trash + restore 同一批:墓碑与主表不重复(单连接串行化)',
        () async {
      await seedLedger();
      final id1 = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          happenedAt: DateTime(2026, 7, 1), syncId: 'W1-A');
      final id2 = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 20,
          happenedAt: DateTime(2026, 7, 2), syncId: 'W1-B');
      await repo.deleteTransaction(id1);

      // 并发:恢复 A + 删除 B
      await Future.wait([
        repo.restoreDeletedTransaction(
            (await repo.listDeletedTransactions()).first.id),
        repo.deleteTransaction(id2),
      ]);

      final live = await (db.select(db.transactions)
            ..orderBy([(t) => d.OrderingTerm(expression: t.id)]))
          .get();
      final trash = await repo.listDeletedTransactions();
      // HARDENING: 两者操作不同行(A 在主表/墓碑间搬,B 进墓碑)→ 无冲突。
      final liveSyncIds = live.map((t) => t.syncId).toList();
      expect(liveSyncIds.where((s) => s == 'W1-A').length, 1,
          reason: 'HARDENING: A 恰好一行在主表');
      expect(liveSyncIds.where((s) => s == 'W1-B').length, 0,
          reason: 'HARDENING: B 不在主表');
      expect(trash.where((t) => t.syncId == 'W1-B').length, 1,
          reason: 'HARDENING: B 有一条墓碑');
      expect(trash.where((t) => t.syncId == 'W1-A').length, 0,
          reason: 'HARDENING: A 墓碑已删(恢复成功)');
    });

    test('W2 并发两次 restore 同一墓碑:两次都读到墓碑 → 主表写入两行同 syncId',
        () async {
      await seedLedger();
      final id = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          happenedAt: DateTime(2026, 7, 1), syncId: 'W2');
      await repo.deleteTransaction(id);
      final tombId = (await repo.listDeletedTransactions()).first.id;

      final results = await Future.wait([
        repo.restoreDeletedTransaction(tombId),
        repo.restoreDeletedTransaction(tombId),
      ]);
      final nonNull = results.whereType<int>().toList();
      final live = await db
          .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='W2'")
          .getSingle();
      final trash = await repo.listDeletedTransactions();
      // ADVERSE FINDING: restoreDeletedTransaction 是 select-tombstone →
      // parse payload → insert 主表 → delete tombstone(local_transaction
      // _repository.dart:706-751),四步**不在事务里**,也没有 tombstone 级
      // 互斥。两个并发调用都先读到同一条墓碑 → 各插一行主表(同 syncId)
      // → 落到 A1 的重复 syncId 断链状态,且第二次 delete-tombstone 是空操作。
      // 单连接内存库实测即复现(2 行),真实双 isolate/多连接更严重。
      expect(nonNull.length, 1,
          reason: 'ADVERSE FINDING: 并发两次 restore 都返回新 id '
              '(${results.map((r) => r).toList()}) → 主表 ${live.data['c']} 行同 syncId;'
              'restore 四步非事务,无墓碑互斥锁');
      expect(live.data['c'], 1,
          reason: 'ADVERSE FINDING: 主表 ${live.data['c']} 行 syncId=W2(期望 1);'
              '此后 getTransactionBySyncId 抛 Bad state(A1/B8 同族)');
      expect(trash.length, 0,
          reason: 'HARDENING: 墓碑已消费(两次 delete 中一次生效)');
    });

    test('W3 并发 trash + 并发 cleanup:不会双删/残留', () async {
      await seedLedger();
      final ids = <int>[];
      for (var i = 0; i < 5; i++) {
        ids.add(await repo.addTransaction(
            ledgerId: 1, type: 'expense', amount: i.toDouble(),
            happenedAt: DateTime(2026, 7, 1), syncId: 'W3-$i'));
      }
      // 全部删除 + 同时清理(阈值 0 天 → 刚删的也过期)
      await Future.wait([
        for (final id in ids) repo.deleteTransaction(id),
        repo.cleanupDeletedTransactions(days: 0),
      ]);
      final live = await db
          .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id LIKE 'W3-%'")
          .getSingle();
      final trash = await repo.listDeletedTransactions();
      // HARDENING: cleanup 用单条 DELETE ... WHERE(无读-改-写),
      // 与 trash 的 insert 不冲突。5 笔删除全部进墓碑,清理可能删掉全部或部分
      // (取决于时机),但主表必须清空、墓碑数 ≤ 5 且无重复。
      expect(live.data['c'], 0, reason: 'HARDENING: 主表清空');
      expect(trash.length, lessThanOrEqualTo(5));
      expect(trash.map((t) => t.syncId).toSet().length, trash.length,
          reason: 'HARDENING: 墓碑无重复');
    });

    test('W4 并发 bulk insert 相同 syncId 集合:无 UNIQUE → 重复行翻倍',
        () async {
      await seedLedger();
      final items = [
        for (var i = 0; i < 10; i++)
          TransactionsCompanion.insert(
              ledgerId: 1, type: 'expense', amount: i.toDouble(),
              happenedAt: d.Value(DateTime(2026, 7, 1)),
              syncId: d.Value('W4-$i')),
      ];
      // 同一批数据并发插两次(模拟双设备/重试)
      await Future.wait([
        repo.insertTransactionsBatch(items),
        repo.insertTransactionsBatch(items),
      ]);
      final total = await db
          .customSelect('SELECT COUNT(*) c FROM transactions')
          .getSingle();
      final distinct = await db
          .customSelect('SELECT COUNT(DISTINCT sync_id) c FROM transactions')
          .getSingle();
      // ADVERSE FINDING: 批量插入不做 syncId upsert → 同一批重放两次得到
      // 20 行 / 10 个 syncId。任何"重试/对账重放"逻辑都会把账目翻倍。
      expect(total.data['c'], 10,
          reason: 'ADVERSE FINDING: 同批并发重放 → ${total.data['c']} 行'
              '(distinct syncId=${distinct.data['c']});批量插入非幂等,'
              '重试即翻倍(A1/F2 的并发放大版)');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // X. change 记录 / 事务性
  // ══════════════════════════════════════════════════════════════════════

  group('X. change 记录与事务性', () {
    test('X1 deleteTransaction 的 change 记录在主表删除之前:'
        '中途失败会留"已登记但未删"的假 change', () async {
      await seedLedger();
      final tracker = ChangeTracker(db);
      final tracked = LocalRepository(db, changeTracker: tracker);
      final id = await tracked.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          happenedAt: DateTime(2026, 7, 1));
      // 预清 change
      await db.delete(db.localChanges).go();

      await tracked.deleteTransaction(id);

      final changes = await db.select(db.localChanges).get();
      final live = await db
          .customSelect('SELECT COUNT(*) c FROM transactions')
          .getSingle();
      // HARDENING: deleteTransaction 是 record-then-delete、**非事务**
      // (local_repository.dart:575-593:先 changeTracker.recordLedgerChange,
      //  再 _transactionRepo.deleteTransaction)。若第二步失败(磁盘满/
      // 进程被杀),会留下"delete change 已登记但行还在"的状态 → 下次 push
      // 会让云端删掉一条本地仍存在的交易(反向下次 pull 又拉回来)。
      // 单连接正常路径下两者都成功,故此处只钉住顺序与最终一致。
      expect(changes.length, 1);
      expect(changes.first.action, 'delete');
      expect(live.data['c'], 0);
      // 对照:addTransaction 也是"insert → 读回 → 记 change",但顺序是
      // 先写后记,失败时最多丢 change(不会产生假删除)。
      expect(changes.first.entitySyncId, isNotEmpty);
    });

    test('X2 单条 delete 与批量 delete 的 change 登记差异(语义分裂)',
        () async {
      await seedLedger();
      final tracker = ChangeTracker(db);
      final tracked = LocalRepository(db, changeTracker: tracker);
      final a = await tracked.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          happenedAt: DateTime(2026, 7, 1), syncId: 'X2-A');
      final b = await tracked.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          happenedAt: DateTime(2026, 7, 2), syncId: 'X2-B');
      await db.delete(db.localChanges).go();

      await tracked.deleteTransaction(a);
      await tracked.deleteTransactionsBatchBySyncIds(['X2-B']);

      final changes = await db.select(db.localChanges).get();
      final trash = await repo.listDeletedTransactions();
      // C3 修复:单条与批量删除语义统一 —— 两条路径都登记 delete change 并进
      // 回收站。原断言(2 条 change / 1 条墓碑)与 reason 描述的正是修复前的
      // 分裂行为(批量路径 0 条 change + 硬删)。
      expect(changes.length, 2,
          reason: 'C3 修复: 删两笔登记 ${changes.length} 条 delete change'
              '(单条路径 1 条 + 批量路径 1 条)');
      expect(trash.length, 2,
          reason: 'C3 修复: 两条删除都进回收站(批量路径不再硬删,可恢复)');
    });

    test('X3 deleteLedger 是事务的:tx/budget/ledger 的 change 一并提交或一并回滚',
        () async {
      await seedLedger();
      final tracker = ChangeTracker(db);
      final tracked = LocalRepository(db, changeTracker: tracker);
      final bid = await tracked.createBudget(ledgerId: 1, type: 'total', amount: 100);
      await tracked.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          happenedAt: DateTime(2026, 7, 1));
      expect(bid, greaterThan(0));
      await db.delete(db.localChanges).go();

      await tracked.deleteLedger(1);

      final changes = await db.select(db.localChanges).get();
      final ledgers = await db.select(db.ledgers).get();
      final budgets = await db.select(db.budgets).get();
      final txs = await db.select(db.transactions).get();
      // HARDENING: deleteLedger 包在 db.transaction 内(含 change 登记)
      // → 数据与 change 一致提交。
      expect(ledgers, isEmpty);
      expect(budgets, isEmpty);
      expect(txs, isEmpty);
      expect(changes.where((c) => c.action == 'delete').length, 3,
          reason: 'HARDENING: 1 tx + 1 budget + 1 ledger_snapshot = 3 条 delete change');
      expect(changes.map((c) => c.entityType).toSet(),
          containsAll(['transaction', 'budget', 'ledger_snapshot']));
    });

    test('X4 ChangeTracker.recordPulledFromServer 幂等:并发调用只落一行',
        () async {
      await seedLedger();
      final tracker = ChangeTracker(db);
      // 单连接串行 → 实测幂等;多连接下 select-then-insert 也有 TOCTOU
      // (与 V6/V7 同族),但这里 (entityType, entitySyncId) 不是 DB 唯一键
      // → 重复行不会被拦。
      await Future.wait([
        for (var i = 0; i < 5; i++)
          tracker.recordPulledFromServer(
              entityType: 'transaction',
              entityId: 1,
              entitySyncId: 'PULLED-1',
              ledgerId: 1),
      ]);
      final rows = await db
          .customSelect(
              "SELECT COUNT(*) c FROM local_changes WHERE entity_sync_id = 'PULLED-1'")
          .getSingle();
      expect(rows.data['c'], 1,
          reason: 'ADVERSE FINDING: 并发 5 次 recordPulledFromServer 落 '
              '${rows.data['c']} 行(期望 1);方法自称幂等(注释"同一 '
              '(entityType,entitySyncId) 多次调用只插一次")但实现是 '
              'select-then-insert,且 local_changes 上**没有** '
              '(entity_type,entity_sync_id) 唯一索引 → 并发下失效。'
              '后果:记录膨胀,且 fullPush 的 legacy backfill 判断被污染');
      final marked = await db.select(db.localChanges).get();
      expect(marked.single.pushedAt, isNotNull,
          reason: 'HARDENING: 标记为已推送(不再 push 回云端)');
    });

    test('X5 并发 markPushed + getUnpushedChanges:不丢 change', () async {
      await seedLedger();
      final tracker = ChangeTracker(db);
      final ids = <int>[];
      for (var i = 0; i < 5; i++) {
        await tracker.recordLedgerChange(
            entityType: 'transaction',
            entityId: i + 1,
            entitySyncId: 'X5-$i',
            ledgerId: 1,
            action: 'create');
      }
      final all = await tracker.getUnpushedChanges();
      ids.addAll(all.map((c) => c.id));

      await Future.wait([
        tracker.markPushed(ids.sublist(0, 2)),
        tracker.getUnpushedCount(),
      ]);

      final left = await tracker.getUnpushedChanges();
      // HARDENING: markPushed 是单条 UPDATE ... WHERE id IN,与 COUNT 无冲突。
      expect(left.length, 3, reason: 'HARDENING: 标记 2 条后剩 3 条');
      expect(await tracker.getUnpushedCountForLedger(1), 3);
      expect(await tracker.getUnpushedCount(), 3);
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // Y. 交叉一致性(不同入口在同一并发批数据上)
  // ══════════════════════════════════════════════════════════════════════

  group('Y. 并发后一致性', () {
    test('Y1 并发写 50 笔后:账本余额/账户余额/月统计三者自洽', () async {
      await seedLedger();
      final acc = await repo.createAccount(
          ledgerId: 1, name: 'Y1', initialBalance: 0);
      await Future.wait([
        for (var i = 0; i < 50; i++)
          repo.addTransaction(
              ledgerId: 1,
              type: i % 2 == 0 ? 'income' : 'expense',
              amount: 10.0,
              accountId: acc,
              happenedAt: DateTime(2026, 7, 15)),
      ]);

      final bal = await repo.getAccountBalance(acc);
      final (inc, exp) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 7, 1));
      final ls = await repo.getLedgerStats(ledgerId: 1);
      final stats = await repo.getAccountStats(acc);
      // HARDENING: 25 收 ×10 = 250,25 支 ×10 = 250 → 余额 0;
      // 账本余额 = 250 - 250 = 0;三个入口一致。
      expect(inc, 250.0);
      expect(exp, 250.0);
      expect(bal, 0.0, reason: 'HARDENING: 账户余额 = initial(0) + 250 - 250 = 0');
      expect(ls.balance, 0.0, reason: 'HARDENING: 账本余额口径一致');
      expect(ls.transactionCount, 50);
      expect(stats.income, 250.0);
      expect(stats.expense, 250.0);
    });

    test('Y2 并发写后净值趋势末点 = 各账户余额之和对账', () async {
      await seedLedger();
      final a = await repo.createAccount(
          ledgerId: 1, name: 'Y2A', initialBalance: 500);
      final b = await repo.createAccount(
          ledgerId: 1, name: 'Y2B', initialBalance: 300);
      await Future.wait([
        for (var i = 0; i < 10; i++)
          repo.addTransaction(
              ledgerId: 1, type: 'expense', amount: 20.0,
              accountId: i.isEven ? a : b,
              happenedAt: DateTime(2026, 7, 15)),
      ]);
      final balA = await repo.getAccountBalance(a);
      final balB = await repo.getAccountBalance(b);
      final trend = await repo.getNetWorthTrendSeries(
          startDate: DateTime(2026, 7, 1),
          endDate: DateTime(2026, 7, 20),
          ratesToBase: {'CNY': 1.0});
      // HARDENING: i 偶数 5 笔走 A(500-100=400),奇数 5 笔走 B(300-100=200)。
      expect(balA, 400.0);
      expect(balB, 200.0);
      expect(trend.last.net, closeTo(balA + balB, 1e-9),
          reason: 'HARDENING: 趋势末点 ${trend.last.net} == Σ余额 ${balA + balB}');
    });

    test('Y3 并发 trash 之后:统计/分页/账户余额三入口都不含已删交易',
        () async {
      await seedLedger();
      final acc = await repo.createAccount(ledgerId: 1, name: 'Y3');
      final ids = <int>[];
      for (var i = 0; i < 6; i++) {
        ids.add(await repo.addTransaction(
            ledgerId: 1, type: 'expense', amount: 10.0,
            accountId: acc, happenedAt: DateTime(2026, 7, 15)));
      }
      await Future.wait([
        for (final id in ids.take(3)) repo.deleteTransaction(id),
      ]);

      final (_, exp) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 7, 1));
      final page = await repo.getTransactionPageWithCategory(ledgerId: 1, limit: 50);
      final bal = await repo.getAccountBalance(acc);
      final trash = await repo.listDeletedTransactions();
      // HARDENING: 回收站是"真删主表"→ 所有读路径天然排除。
      expect(exp, 30.0, reason: 'HARDENING: 只剩 3 笔 ×10');
      expect(page.items.length, 3, reason: 'HARDENING: 列表不含已删');
      expect(bal, -30.0, reason: 'HARDENING: 余额不含已删');
      expect(trash.length, 3, reason: 'HARDENING: 3 条墓碑');
    });

    test('Y4 并发加标签 + 并发删除交易:关联表可能残留悬挂(tag 一侧)',
        () async {
      await seedLedger();
      final tag = await repo.createTag(name: 'Y4T');
      final id = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          happenedAt: DateTime(2026, 7, 1));

      await Future.wait([
        repo.addTagToTransaction(transactionId: id, tagId: tag),
        repo.deleteTransaction(id),
      ]);

      final live = await db
          .customSelect('SELECT COUNT(*) c FROM transactions')
          .getSingle();
      final links = await db
          .customSelect('SELECT COUNT(*) c FROM transaction_tags')
          .getSingle();
      // 结果依赖顺序:
      //  - "先挂标签再删交易" → 删除路径清 transaction_tags → 0 行
      //  - "先删交易再挂标签" → 关联行指向已删交易 → 1 行悬挂
      // 两种都记录(不确定 → 只断言"主表已删",悬挂另作说明)。
      expect(live.data['c'], 0, reason: 'HARDENING: 交易已删');
      // ADVERSE FINDING: 若标签关联后落,则产生悬挂(OrphanScanner A3 能检出,
      // 但只在用户主动体检时)。
      expect(links.data['c'], 0,
          reason: 'ADVERSE FINDING: 并发"挂标签 vs 删交易"竞态下 '
              'transaction_tags 残留 ${links.data['c']} 行(悬挂);'
              'addTagToTransaction 不校验 transactionId 是否存在');
    });
  });
}
