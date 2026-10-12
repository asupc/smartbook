// 对抗性回归测试 — 金额/非有限值守卫族(2026-10-11 缺陷 E/F/G/H)。
//
// 本文件锁定四组**已修复**的缺陷,防回归:
//   E. 存量脏行(legacy 负值)必须仍可编辑(其它字段),但新负值仍被拒;
//      周期模板逐个隔离,一个坏模板不再吞掉整轮生成。
//   F. 5 条批量/直写旁路全部收口到同一判据(pull-apply 走"跳过 + 告警")。
//   G. 非有限值守卫覆盖全部金额列(账户/预算/调整/周期/回收站/汇率)。
//   H. 极大有限值(≥1e21)渲染降级为科学计数法 + 写入侧 12 位整数上限。
//
// 源码:
//   lib/data/repositories/local/local_transaction_repository.dart
//     (`txAmountViolation` / `_assertTxValues` / `_assertTxCompanion`)
//   lib/data/repositories/local/{local_account_repository,
//     local_budget_repository,local_recurring_transaction_repository,
//     local_exchange_rate_repository}.dart
//   lib/utils/format_utils.dart(`formatBalanceFull` / `magnitudeCeiling`)
//   lib/services/data/recurring_transaction_service.dart(逐模板隔离)
//   lib/cloud/sync/sync_engine_apply.dart(pull-apply 跳过策略)

import 'dart:convert';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/data/repositories/local/local_transaction_repository.dart';
import 'package:smartbook/data/repositories/transaction_repository.dart'
    show TransactionUpdateBySyncIdData;
import 'package:smartbook/services/data/recurring_transaction_service.dart';
import 'package:smartbook/utils/format_utils.dart';

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

  /// 直插一条主表交易(绕过全部守卫 = 模拟 legacy / 远端脏数据)。
  Future<int> rawTx({
    required double amount,
    String type = 'expense',
    String? syncId,
    double? nativeAmount,
    int ledgerId = 1,
  }) async {
    final id = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: type,
            amount: amount,
            syncId: d.Value(syncId),
            nativeAmount: d.Value(nativeAmount),
            happenedAt: d.Value(DateTime(2026, 1, 1)),
          ),
        );
    return id;
  }

  // ══════════════════════════════════════════════════════════════════════
  // E. 存量脏行的可编辑性 + 周期模板隔离
  // ══════════════════════════════════════════════════════════════════════

  group('E. 存量负值行可编辑(等值豁免)与周期模板隔离', () {
    test('E1 legacy 负值行改备注/分类成功(原:永久不可编辑)', () async {
      await seedLedger();
      final id = await rawTx(amount: -50, syncId: 'legacy-neg-1');

      // search_page 批量改备注会把 `tx.amount` 原样回传 —— 修复前这一步抛
      // `Invalid argument (amount): expense 的金额必须 >= 0`,备注永远改不动,
      // 只能删除重建。
      await repo.updateTransaction(
        id: id,
        type: 'expense',
        amount: -50, // 与库内现值相同 → 存量豁免
        note: 'new note',
      );

      final after = await repo.getTransactionById(id);
      expect(after!.note, 'new note', reason: '修复:金额未改动时其它字段可正常编辑');
      expect(after.amount, -50.0, reason: '金额保持原值(不被改写也不被清空)');
    });

    test('E2 等值豁免不放过**新**负值写入', () async {
      await seedLedger();
      final id = await rawTx(amount: -50, syncId: 'legacy-neg-2');

      Object? err;
      try {
        await repo.updateTransaction(
            id: id, type: 'expense', amount: -60, note: 'x'); // 新负值
      } catch (e) {
        err = e;
      }
      expect(err, isA<ArgumentError>(),
          reason: '修复边界:只有"与库内现值相等"才豁免;改成一个新的负数仍被拒');
      expect((await repo.getTransactionById(id))!.note, isNot('x'),
          reason: '被拒的写不产生半更新');
    });

    test('E3 存量 Infinity 行同样可编辑(等值豁免对非有限值生效)', () async {
      await seedLedger();
      final id = await rawTx(amount: double.infinity, syncId: 'legacy-inf-1');

      await repo.updateTransaction(
          id: id, type: 'expense', amount: double.infinity, note: 'fixed note');

      final after = await repo.getTransactionById(id);
      expect(after!.note, 'fixed note',
          reason: '修复:存量 Infinity 行不再"删不掉也改不动"');
    });

    test('E4 NaN 自等在豁免判定中成立(NaN != NaN 的语言级陷阱)', () async {
      // rawTx 的 NaN 会被 NOT NULL 拦(SQLite 把 NaN 当 NULL),所以直接验证
      // 判据函数本身:NaN 与 NaN 必须判为"同值"。
      expect(LocalTransactionRepository.sameAmountValue(double.nan, double.nan),
          isTrue,
          reason: '修复:NaN 自等成立,否则 legacy NaN 行回传会被判成"改了金额"');
      expect(
          LocalTransactionRepository.sameAmountValue(1.0, 1.0), isTrue);
      expect(LocalTransactionRepository.sameAmountValue(1.0, 2.0), isFalse);
    });

    test('E5 0 金额仍放行(导入/周期模板写 0 的既有契约)', () async {
      await seedLedger();
      final id = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 0,
          happenedAt: DateTime(2026, 1, 1));
      expect(id, greaterThan(0), reason: '0 继续放行(计划 != 0 未采纳,保持既有行为)');
      // 存量 0 行改备注也走等值豁免
      await repo.updateTransaction(
          id: id, type: 'expense', amount: 0, note: 'zero note');
      expect((await repo.getTransactionById(id))!.note, 'zero note');
    });

    // ── 缺陷 C(2026-10-11 复现缺陷修复):等值豁免必须同时要求 type 未变 ──
    //
    // 旧行为:豁免只看金额。app 自己创建的 `adjustment/-500`(合法负值)被
    // `updateTransaction(id, type:'expense', amount:-500)` **改类型**时金额
    // 等值 → 整条豁免放行 → 库里出现方向性非法的 expense/-500,而
    // addTransaction(expense, -500) 是被正确拒绝的。方向由 type 表达,
    // 改类型 = 改方向语义 → 必须重新校验金额。
    test('C1 改 type 后等值金额重新校验:adjustment/-500 → expense 被拒', () async {
      await seedLedger();
      final id = await repo.createAdjustmentTransaction(
        ledgerId: 1,
        accountId: 1,
        amount: -500,
        happenedAt: DateTime(2026, 1, 1),
      );
      expect((await repo.getTransactionById(id))!.type, 'adjustment',
          reason: '前置:app 自己创建的负值调整(合法)');

      Object? err;
      try {
        await repo.updateTransaction(
            id: id, type: 'expense', amount: -500, note: 'retyped');
      } catch (e) {
        err = e;
      }
      expect(err, isA<ArgumentError>(),
          reason: 'DEFECT-C: 改成方向性类型(expense)后,等值豁免失效 → '
              '负金额必须被重新校验并拒绝');

      final after = await repo.getTransactionById(id);
      expect(after!.type, 'adjustment',
          reason: '被拒的写不产生半更新(type 保持原值)');
      expect(after.amount, -500.0);
      expect(after.note, isNot('retyped'));
    });

    test('C2 type 未变时等值豁免仍生效(既有 E 语义不退化)', () async {
      await seedLedger();
      final id = await repo.createAdjustmentTransaction(
        ledgerId: 1,
        accountId: 1,
        amount: -500,
        happenedAt: DateTime(2026, 1, 1),
      );
      // 同 type(adjustment)+ 同金额 → 豁免成立,其它字段可编辑。
      await repo.updateTransaction(
          id: id, type: 'adjustment', amount: -500, note: 'still editable');
      final after = await repo.getTransactionById(id);
      expect(after!.note, 'still editable',
          reason: 'DEFECT-C 不收紧"方向语义未变"的合法编辑面');
      expect(after.amount, -500.0);
    });

    test('C3 判据函数:currentType 与 type 不同 → 等值不再豁免', () {
      // 同值 + 同 type → 豁免。
      expect(
          LocalTransactionRepository.txAmountViolation('adjustment', -500,
              currentAmount: -500, currentType: 'adjustment'),
          isNull,
          reason: '金额与方向语义都未变 → 存量豁免');
      // 同值 + 改 type → 走完整判据,方向性负值被拒。
      expect(
          LocalTransactionRepository.txAmountViolation('expense', -500,
              currentAmount: -500, currentType: 'adjustment'),
          'negative_directional',
          reason: 'DEFECT-C: 改 type 后必须重新校验金额');
      // 不传 currentType(无现值上下文)→ 保持原语义(等值即豁免)。
      expect(
          LocalTransactionRepository.txAmountViolation('expense', -500,
              currentAmount: -500),
          isNull,
          reason: '无 currentType 的旧调用面语义不变');
    });

    test('C4 addTransaction(expense, -500) 行为不受影响(基线不退化)', () async {
      await seedLedger();
      Object? err;
      try {
        await repo.addTransaction(
            ledgerId: 1, type: 'expense', amount: -500,
            happenedAt: DateTime(2026, 1, 1));
      } catch (e) {
        err = e;
      }
      expect(err, isA<ArgumentError>(),
          reason: '新建路径本就拒绝负的方向性金额(DEFECT-C 未改变该行为)');
    });

    test('E6 周期模板:一个负金额坏模板不再吞掉整轮生成', () async {
      await seedLedger();
      // 正常模板(daily,今天开始 → 生成 1 笔)
      await repo.addRecurringTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        frequency: 'daily',
        interval: 1,
        startDate: DateTime.now(),
      );
      // 坏模板:负金额(直插绕过模板守卫 = 模拟历史存量坏模板)。
      // 它被生成时的落库守卫拒绝 —— 修复前 `generatePendingTransactionsStatic`
      // 的 catch 会吞掉**整轮**,正常模板也一笔不生成。
      await db.customStatement(
          "INSERT INTO recurring_transactions (ledger_id, type, amount, frequency, interval, start_date, enabled) "
          "VALUES (1, 'expense', -30, 'daily', 1, ${DateTime.now().millisecondsSinceEpoch ~/ 1000}, 1)");

      final service = RecurringTransactionService(repo);
      final generated = await service.generatePendingTransactions();

      expect(generated, hasLength(1),
          reason: '修复:坏模板被隔离,正常模板照常生成 1 笔');
      expect(generated.single.amount, 10.0,
          reason: '生成的是正常模板那一笔(不是坏模板)');
      expect(service.lastFailures, hasLength(1),
          reason: '修复:失败模板被记录并暴露给调用方(修复前静默吞掉整轮)');
      expect(service.lastFailures.single.amount, -30.0);
      expect(service.lastFailures.single.error, isNotEmpty);
    });

    test('E7 周期模板:坏模板不推进游标(下次修好后仍能补生成)', () async {
      await seedLedger();
      await db.customStatement(
          "INSERT INTO recurring_transactions (ledger_id, type, amount, frequency, interval, start_date, enabled) "
          "VALUES (1, 'expense', -30, 'daily', 1, ${DateTime.now().millisecondsSinceEpoch ~/ 1000}, 1)");

      await RecurringTransactionService(repo).generatePendingTransactions();
      final broken = (await repo.getAllRecurringTransactions()).single;
      expect(broken.lastGeneratedDate, isNull,
          reason: '失败模板的 lastGeneratedDate 不被推进 —— 修好金额后下一轮可补生成');

      // 用户把金额修正为正常值 → 下一轮正常生成
      await repo.updateRecurringTransaction(
        id: broken.id,
        ledgerId: 1,
        type: 'expense',
        amount: 30,
        frequency: 'daily',
        interval: 1,
        startDate: broken.startDate,
      );
      final generated =
          await RecurringTransactionService(repo).generatePendingTransactions();
      expect(generated, hasLength(1),
          reason: '修复后补生成成功(游标从未推进)');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // F. 5 条旁路全部收口
  // ══════════════════════════════════════════════════════════════════════

  group('F. 批量/直写旁路收口', () {
    test('F1 insertTransactionsBatch(-50) 被拒且整批回滚', () async {
      await seedLedger();
      Object? err;
      try {
        await repo.insertTransactionsBatch([
          TransactionsCompanion.insert(
              ledgerId: 1, type: 'expense', amount: 1,
              happenedAt: d.Value(DateTime(2026, 1, 1))),
          TransactionsCompanion.insert(
              ledgerId: 1, type: 'expense', amount: -50,
              happenedAt: d.Value(DateTime(2026, 1, 2))),
        ]);
      } catch (e) {
        err = e;
      }
      expect(err, isA<ArgumentError>(), reason: '修复:批量入口预检负金额');
      expect((await db.select(db.transactions).get()), isEmpty,
          reason: 'fail-closed:整批回滚,正常行不留半提交');
    });

    test('F2 insertTransactionsBatchWithRelations(-88) 被拒(data_import 主路径)',
        () async {
      await seedLedger();
      Object? err;
      try {
        await repo.insertTransactionsBatchWithRelations(transactions: [
          TransactionsCompanion.insert(
              ledgerId: 1, type: 'expense', amount: -88,
              happenedAt: d.Value(DateTime(2026, 1, 2))),
        ]);
      } catch (e) {
        err = e;
      }
      expect(err, isA<ArgumentError>(),
          reason: '修复:data_import_service 主路径不再是旁路');
      expect(await db.select(db.transactions).get(), isEmpty);
    });

    test('F3 insertTransactionCompanion(Infinity) 被拒', () async {
      await seedLedger();
      Object? err;
      try {
        await repo.insertTransactionCompanion(TransactionsCompanion.insert(
            ledgerId: 1, type: 'expense', amount: double.infinity,
            happenedAt: d.Value(DateTime(2026, 1, 3))));
      } catch (e) {
        err = e;
      }
      expect(err, isA<ArgumentError>(), reason: '修复:单条 companion 直写被拦');
      expect(await db.select(db.transactions).get(), isEmpty);
    });

    test('F4 updateTransactionsBatchBySyncId 跳过坏行、好行照常更新', () async {
      await seedLedger();
      await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 1,
          happenedAt: DateTime(2026, 1, 4), syncId: 'S-BAD');
      await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 2,
          happenedAt: DateTime(2026, 1, 5), syncId: 'S-GOOD');

      // sync_diff_service.applySyncChanges 的同款调用:一条远端坏金额 + 一条
      // 正常金额。修复前坏值静默覆盖本地(err=null)。
      final map = await repo.updateTransactionsBatchBySyncId([
        TransactionUpdateBySyncIdData(
          syncId: 'S-BAD',
          type: 'expense',
          amount: double.infinity, // 远端脏金额
          categoryId: null,
          accountId: null,
          toAccountId: null,
          happenedAt: DateTime(2026, 1, 4),
          note: 'should be skipped',
        ),
        TransactionUpdateBySyncIdData(
          syncId: 'S-GOOD',
          type: 'expense',
          amount: 99,
          categoryId: null,
          accountId: null,
          toAccountId: null,
          happenedAt: DateTime(2026, 1, 5),
          note: 'updated',
        ),
      ]);

      // 策略:跳过坏行(非抛错)—— 批量合并里抛错会让整批(含好行)回滚。
      expect(map.keys, contains('S-GOOD'),
          reason: '好行照常更新并返回映射(坏行不连坐)');
      expect(map.keys, isNot(contains('S-BAD')),
          reason: '坏行被跳过,映射里不出现');

      final bad = await repo.getTransactionBySyncId('S-BAD');
      final good = await repo.getTransactionBySyncId('S-GOOD');
      expect(bad!.amount, 1.0,
          reason: '修复:坏行金额未被 Infinity 覆盖(原:静默落库)');
      expect(bad.note, isNot('should be skipped'));
      expect(good!.amount, 99.0, reason: '好行正常更新');
      expect(good.note, 'updated');
    });

    test('F5 单条 updateTransaction 直接改新负值仍被拒(基线不退化)', () async {
      await seedLedger();
      final id = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 10,
          happenedAt: DateTime(2026, 1, 1));
      Object? err;
      try {
        await repo.updateTransaction(
            id: id, type: 'expense', amount: -10, note: 'x');
      } catch (e) {
        err = e;
      }
      expect(err, isA<ArgumentError>(),
          reason: '修复 F 不放松既有单条路径的负值拒绝');
    });

    test('F6 判据统一:各入口拒绝原因一致(同一 choke point)', () {
      expect(
          LocalTransactionRepository.txAmountViolation('expense', -1),
          isNotNull);
      expect(LocalTransactionRepository.txAmountViolation('expense', 0),
          isNull,
          reason: '0 放行(既有契约)');
      expect(
          LocalTransactionRepository.txAmountViolation('adjustment', -1),
          isNull,
          reason: '非方向性类型允许负数');
      expect(
          LocalTransactionRepository.txAmountViolation(
              'expense', 1e12),
          'exceeds_magnitude',
          reason: 'U-1 的 12 位整数上限:1e12 起拒绝');
      expect(
          LocalTransactionRepository.txAmountViolation(
              'expense', 999999999999),
          isNull,
          reason: '恰 12 位(UI 可输入的最大值)放行');
      // 等值豁免:任何值只要是"未改动"都放行
      expect(
          LocalTransactionRepository.txAmountViolation('expense', -1e30,
              currentAmount: -1e30),
          isNull,
          reason: '存量豁免:与库内现值相等即放行(含脏值)');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // G. 非有限值守卫覆盖全部金额列
  // ══════════════════════════════════════════════════════════════════════

  group('G. 其它金额列的非有限守卫', () {
    test('G1 accounts.initial_balance / credit_limit', () async {
      await seedLedger();
      Object? e1, e2, e3;
      try {
        await repo.createAccount(
            ledgerId: 1, name: 'A-INF', initialBalance: double.infinity);
      } catch (e) {
        e1 = e;
      }
      try {
        await repo.createAccount(
            ledgerId: 1, name: 'A-CL', creditLimit: double.nan);
      } catch (e) {
        e2 = e;
      }
      expect(e1, isA<ArgumentError>(), reason: '修复:initial_balance=Infinity 被拒');
      expect(e2, isA<ArgumentError>(), reason: '修复:credit_limit=NaN 被拒');
      expect(await db.select(db.accounts).get(), isEmpty,
          reason: '被拒的账户不落库(修复前 err=null + accountBalance=Infinity)');

      // updateAccount 同口径
      final ok = await repo.createAccount(ledgerId: 1, name: 'A-OK');
      try {
        await repo.updateAccount(ok, initialBalance: double.infinity);
      } catch (e) {
        e3 = e;
      }
      expect(e3, isA<ArgumentError>(), reason: '修复:updateAccount 同拦');
      expect((await repo.getAccount(ok))!.initialBalance, 0.0);

      // updateAccountValuation(估值账户直接写 initial_balance)
      Object? e4;
      try {
        await repo.updateAccountValuation(ok, double.negativeInfinity);
      } catch (e) {
        e4 = e;
      }
      expect(e4, isA<ArgumentError>(), reason: '修复:估值写入同拦');
    });

    test('G2 budgets.amount(Infinity 持久化 + 使用率污染)', () async {
      await seedLedger();
      Object? e1, e2;
      try {
        await repo.createBudget(
            ledgerId: 1, type: 'total', amount: double.infinity);
      } catch (e) {
        e1 = e;
      }
      expect(e1, isA<ArgumentError>(), reason: '修复:createBudget(Infinity) 被拒');
      expect(await db.select(db.budgets).get(), isEmpty);

      final ok = await repo.createBudget(ledgerId: 1, type: 'total', amount: 100);
      try {
        await repo.updateBudget(ok, amount: double.infinity);
      } catch (e) {
        e2 = e;
      }
      expect(e2, isA<ArgumentError>(), reason: '修复:updateBudget 同拦');
      expect((await db.select(db.budgets).get()).single.amount, 100.0);
    });

    test('G3 account_adjustments.amount/balanceBefore/balanceAfter', () async {
      await seedLedger();
      final acc = await repo.createAccount(ledgerId: 1, name: 'ADJ');
      Object? e1, e2, e3;
      try {
        await repo.addAccountAdjustment(
            ledgerId: 1, accountId: acc, amount: double.infinity);
      } catch (e) {
        e1 = e;
      }
      try {
        await repo.addAccountAdjustment(
            ledgerId: 1, accountId: acc, amount: 1, balanceBefore: double.nan);
      } catch (e) {
        e2 = e;
      }
      try {
        await repo.addAccountAdjustment(
            ledgerId: 1,
            accountId: acc,
            amount: 1,
            balanceAfter: double.negativeInfinity);
      } catch (e) {
        e3 = e;
      }
      expect(e1, isA<ArgumentError>(), reason: '修复:amount 非有限被拒');
      expect(e2, isA<ArgumentError>(), reason: '修复:balanceBefore 非有限被拒');
      expect(e3, isA<ArgumentError>(), reason: '修复:balanceAfter 非有限被拒');
      expect(await db.select(db.accountAdjustments).get(), isEmpty);

      // 负数(带符号语义)必须继续放行
      final okAdj = await repo.addAccountAdjustment(
          ledgerId: 1, accountId: acc, amount: -300,
          balanceBefore: 1000, balanceAfter: 700);
      expect(okAdj, greaterThan(0), reason: '带符号调整(-300)照常可写');
    });

    test('G4 recurring_transactions.amount(写入面提前拦截)', () async {
      await seedLedger();
      Object? e1, e2;
      try {
        await repo.addRecurringTransaction(
            ledgerId: 1,
            type: 'expense',
            amount: double.infinity,
            frequency: 'daily',
            interval: 1,
            startDate: DateTime.now());
      } catch (e) {
        e1 = e;
      }
      expect(e1, isA<ArgumentError>(), reason: '修复:模板金额非有限在录入面即被拒');
      expect(await db.select(db.recurringTransactions).get(), isEmpty);

      // 负数模板放行(存量/退款语义)—— 方向性在生成落库那一刻判
      final id = await repo.addRecurringTransaction(
          ledgerId: 1,
          type: 'expense',
          amount: -30,
          frequency: 'daily',
          interval: 1,
          startDate: DateTime.now());
      try {
        await repo.updateRecurringTransaction(
            id: id,
            ledgerId: 1,
            type: 'expense',
            amount: double.nan,
            frequency: 'daily',
            interval: 1,
            startDate: DateTime.now());
      } catch (e) {
        e2 = e;
      }
      expect(e2, isA<ArgumentError>(), reason: '修复:updateRecurringTransaction 同拦');
      expect((await db.select(db.recurringTransactions).get()).single.amount,
          -30.0,
          reason: '负数模板值未被修改(守卫只拦非有限)');
    });

    test('G5 deleted_transactions.amount(墓碑镜像归一 + 不可编码 payload)', () async {
      await seedLedger();
      // 存量 Infinity 行删除:修复前 `jsonEncode(payload)` 先炸
      // (JsonUnsupportedObjectError)→ 该行**删不掉**。
      final dirty = await rawTx(
          amount: double.infinity,
          syncId: 'tomb-inf',
          nativeAmount: double.infinity);
      // 修复前 `_archiveToTrash` 的 `jsonEncode(payload)` 先炸
      // (JsonUnsupportedObjectError)→ 该行**删不掉**。
      await expectLater(repo.deleteTransaction(dirty), completes,
          reason: '修复:脏行可正常进回收站(不再炸)');
      final tomb = (await db.select(db.deletedTransactions).get()).single;
      expect(tomb.amount, 0.0,
          reason: '墓碑列归一为 0.0(不编造金额,原文在备份/快照可回溯)');
      // payload 必须仍是合法 JSON 且非有限量已归一
      final payload = jsonDecode(tomb.payloadJson) as Map<String, dynamic>;
      expect(payload['amount'], 0.0, reason: 'payload 内的非有限值同归一(否则不可编码)');
      expect(payload['nativeAmount'], isNull,
          reason: 'payload 内 nativeAmount 非有限 → null');
      // 主表行已搬走
      expect(await repo.getTransactionById(dirty), isNull);
    });

    test('G6 exchange_rates / overrides.rate 非有限字符串', () async {
      await seedLedger();
      Object? e1, e2, e3;
      try {
        await repo.setOverride(base: 'CNY', quote: 'USD', rate: 'Infinity');
      } catch (e) {
        e1 = e;
      }
      try {
        await repo.setOverride(base: 'CNY', quote: 'JPY', rate: 'NaN');
      } catch (e) {
        e2 = e;
      }
      expect(e1, isA<ArgumentError>(),
          reason: '修复:invertRate 下溢面产出的 "Infinity" 字面量被拒');
      expect(e2, isA<ArgumentError>(), reason: '修复:NaN 字面量同拒');
      expect(await db.select(db.exchangeRateOverrides).get(), isEmpty);

      // 自动汇率同口径
      try {
        await repo.upsertAutoRates(
            base: 'CNY',
            rateDate: '2026-10-11',
            rates: {'USD': 'Infinity'},
            source: 'fawazahmed0',
            fetchedAt: DateTime.utc(2026, 10, 11));
      } catch (e) {
        e3 = e;
      }
      expect(e3, isA<ArgumentError>(), reason: '修复:自动汇率写入同拦');

      // 不可解析文本放行(既有 HARDENING:消费方 tryParse null → 显式降级)
      await repo.setOverride(base: 'CNY', quote: 'KRW', rate: 'abc');
      expect((await repo.getOverrides('CNY')).single.rate, 'abc',
          reason: '不新增失败面:非法文本仍放行(README D5 显式降级)');
      // 正常值照常
      await repo.setOverride(base: 'CNY', quote: 'USD', rate: '7.2');
      expect((await repo.getOverrides('CNY')).length, 2);
    });

    test('G7 有限的大值不被守卫误伤(只拦非有限,量级上限只针对交易)', () async {
      await seedLedger();
      // 账户余额可以有合法的大额(房贷/估值),不受交易 12 位上限约束
      final acc = await repo.createAccount(
          ledgerId: 1, name: 'BIG', initialBalance: 1e21);
      expect(acc, greaterThan(0), reason: '账户金额只拦非有限,不套交易量级上限');
      expect(await repo.getAccountBalance(acc), 1e21);
      await repo.updateAccountValuation(acc, 1e30);
      expect(await repo.getAccountBalance(acc), 1e30);
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // H. 极大有限值:写入上限 + 渲染降级
  // ══════════════════════════════════════════════════════════════════════

  group('H. 极大有限值(1e21)', () {
    test('H1 addTransaction(1e21) 被拒(12 位整数上限)', () async {
      await seedLedger();
      Object? err;
      try {
        await repo.addTransaction(
            ledgerId: 1, type: 'expense', amount: 1e21,
            happenedAt: DateTime(2026, 1, 1));
      } catch (e) {
        err = e;
      }
      expect(err, isA<ArgumentError>(),
          reason: '修复:1e21 有限但超上限 → 拒绝,账本统计不再被 -1e+21 污染');
      expect(await db.select(db.transactions).get(), isEmpty);
      expect(
          await repo.getAccountBalance(1), 0.0,
          reason: '拒绝后不留下任何余额痕迹');
    });

    test('H2 12 位边界:999999999999 放行、1e12 拒绝', () async {
      await seedLedger();
      final ok = await repo.addTransaction(
          ledgerId: 1, type: 'expense', amount: 999999999999,
          happenedAt: DateTime(2026, 1, 1));
      expect(ok, greaterThan(0),
          reason: '恰 12 位是 UI 可输入的最大值,必须放行');
      Object? err;
      try {
        await repo.addTransaction(
            ledgerId: 1, type: 'expense', amount: 1e12,
            happenedAt: DateTime(2026, 1, 2));
      } catch (e) {
        err = e;
      }
      expect(err, isA<ArgumentError>(), reason: '1e12 起进入 13 位,拒绝');
    });

    test('H3 formatBalanceFull(1e21) 渲染降级不崩(账本卡路径)', () {
      expect(() => formatBalanceFull(1e21, 'CNY'), returnsNormally,
          reason: '修复:存量 1e+21 余额不再让账本卡整页崩(RangeError)');
      expect(formatBalanceFull(1e21, 'CNY'), '¥1.00e21');
      expect(formatBalanceFull(-1e21, 'CNY'), '-¥1.00e21');
      expect(magnitudeCeiling, 1e21,
          reason: '渲染侧分档点 = 1e21(toStringAsFixed 的指数记法边界)');
    });

    test('H4 1e20 仍走定点千分号(不改变既有输出)', () {
      expect(formatBalanceFull(1e20, 'CNY'),
          '¥100,000,000,000,000,000,000.00',
          reason: 'HARDENING:分档点在 1e21,1e20 行为与此前一致');
    });
  });
}
