// 账户维度聚合 SQL 化的对比测试(PERF-P0-04)。
//
// 审计要求「先写新旧实现同库同参数结果一致的对比测试再替换」。旧实现(全表
// 物化 + Dart 逐行累加)已被 SQL CASE 聚合替换;本测试把**旧实现的口径**作为
// 固定期望值逐分支锁定,任何一处 SQL CASE 与旧 Dart 分支不一致都会在这里挂掉:
//
// - 余额:income/adjustment 加、expense/transfer 减(主账户侧),transfer 加
//   (转入侧);**不看 excludeFromStats**;估值账户直接返回 initialBalance。
// - 支出:主账户侧 expense + transfer(转出),排除 excludeFromStats。
// - 收入:主账户侧 income + 转入侧 transfer,排除 excludeFromStats。
// - 共享账本:以成员身份加入的(editor)一律排除;自己 Own 的共享账本**不排除**。
// - getAccountBalanceInLedger:单账本维度,**不**排除共享账本。

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_account_repository.dart';

void main() {
  // BeeDatabase 初始化路径会调 logger(注册原生 channel + 读 prefs)。
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late BeeDatabase db;
  late LocalAccountRepository repo;
  late int ledgerOwn; // 个人账本
  late int ledgerOwnedShared; // 自己 Own 的共享账本(不排除)
  late int ledgerJoinedShared; // 以 editor 身份加入的共享账本(排除)
  late int a1; // cash, initial 100
  late int a2; // bank_card, initial 0
  late int a3; // credit_card(负债), initial 0
  late int a4; // investment(估值账户), initial 5000

  setUp(() async {
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalAccountRepository(db);

    ledgerOwn = await db.into(db.ledgers)
        .insert(LedgersCompanion.insert(name: 'own'));
    ledgerOwnedShared = await db.into(db.ledgers).insert(LedgersCompanion.insert(
          name: 'owned-shared',
          isShared: const d.Value(true),
          myRole: const d.Value('owner'),
        ));
    ledgerJoinedShared = await db
        .into(db.ledgers)
        .insert(LedgersCompanion.insert(
          name: 'joined-shared',
          isShared: const d.Value(true),
          myRole: const d.Value('editor'),
        ));

    Future<int> addAccount(String name, String type, double initial) =>
        db.into(db.accounts).insert(AccountsCompanion.insert(
              ledgerId: ledgerOwn,
              name: name,
              type: d.Value(type),
              initialBalance: d.Value(initial),
            ));
    a1 = await addAccount('cash', 'cash', 100);
    a2 = await addAccount('bank', 'bank_card', 0);
    a3 = await addAccount('card', 'credit_card', 0);
    a4 = await addAccount('invest', 'investment', 5000);

    Future<void> addTx({
      required int ledgerId,
      required String type,
      required double amount,
      int? accountId,
      int? toAccountId,
      bool excludeFromStats = false,
    }) =>
        db.into(db.transactions).insert(TransactionsCompanion.insert(
              ledgerId: ledgerId,
              type: type,
              amount: amount,
              accountId: d.Value(accountId),
              toAccountId: d.Value(toAccountId),
              excludeFromStats: d.Value(excludeFromStats),
            ));

    // --- 个人账本 ---
    await addTx(ledgerId: ledgerOwn, type: 'income', amount: 50, accountId: a1);
    await addTx(ledgerId: ledgerOwn, type: 'expense', amount: 30, accountId: a1);
    await addTx(
        ledgerId: ledgerOwn, type: 'adjustment', amount: 10, accountId: a1);
    await addTx(
        ledgerId: ledgerOwn,
        type: 'transfer',
        amount: 20,
        accountId: a1,
        toAccountId: a2);
    await addTx(
        ledgerId: ledgerOwn, type: 'expense', amount: 15, accountId: a3);
    // excludeFromStats:进余额、不进收支
    await addTx(
        ledgerId: ledgerOwn,
        type: 'expense',
        amount: 5,
        accountId: a1,
        excludeFromStats: true);
    await addTx(
        ledgerId: ledgerOwn,
        type: 'income',
        amount: 7,
        accountId: a1,
        excludeFromStats: true);
    // --- 自己 Own 的共享账本:计入 ---
    await addTx(
        ledgerId: ledgerOwnedShared, type: 'expense', amount: 10, accountId: a1);
    // --- 以成员身份加入的共享账本:全部排除 ---
    await addTx(
        ledgerId: ledgerJoinedShared, type: 'income', amount: 100, accountId: a1);
  });

  tearDown(() => db.close());

  group('getAccountBalance(余额口径)', () {
    test('income/expense/adjustment/transfer/共享账本排除逐分支对齐', () async {
      // 100 +50 -30 +10 -20 -5 +7 -10(own shared);joined shared 的 +100 排除。
      expect(await repo.getAccountBalance(a1), closeTo(102, 1e-9));
      expect(await repo.getAccountBalance(a2), closeTo(20, 1e-9));
      expect(await repo.getAccountBalance(a3), closeTo(-15, 1e-9));
    });

    test('估值账户直接返回 initialBalance', () async {
      expect(await repo.getAccountBalance(a4), closeTo(5000, 1e-9));
    });

    test('不存在的账户返回 0', () async {
      expect(await repo.getAccountBalance(99999), 0.0);
    });
  });

  group('getAccountGlobalBalance / getAccountBalanceInLedger', () {
    test('global 与 balance 同口径', () async {
      expect(await repo.getAccountGlobalBalance(a1), closeTo(102, 1e-9));
      expect(await repo.getAccountGlobalBalance(a2), closeTo(20, 1e-9));
    });

    test('inLedger 单账本维度不排除共享账本', () async {
      // 个人账本: +50 -30 +10 -20 -5 +7
      expect(await repo.getAccountBalanceInLedger(a1, ledgerOwn),
          closeTo(12, 1e-9));
      // Own 的共享账本: -10
      expect(await repo.getAccountBalanceInLedger(a1, ledgerOwnedShared),
          closeTo(-10, 1e-9));
      // joined shared: +100(此方法不过滤)
      expect(await repo.getAccountBalanceInLedger(a1, ledgerJoinedShared),
          closeTo(100, 1e-9));
    });
  });

  group('收支口径(excludeFromStats / 转账 / 共享账本)', () {
    test('getAccountExpense = expense + 转出,排除 excludeFromStats 与 joined', () async {
      // 30 + 20(转出) + 10(own shared);5(exclude) 与 joined 的不计。
      expect(await repo.getAccountExpense(a1), closeTo(60, 1e-9));
      expect(await repo.getAccountExpense(a3), closeTo(15, 1e-9));
      expect(await repo.getAccountExpense(a2), 0.0);
    });

    test('getAccountIncome = income + 转入,排除 excludeFromStats 与 joined', () async {
      // 50;7(exclude) 与 joined 的 +100 不计。
      expect(await repo.getAccountIncome(a1), closeTo(50, 1e-9));
      // 转入侧 transfer 计入收入。
      expect(await repo.getAccountIncome(a2), closeTo(20, 1e-9));
      expect(await repo.getAccountIncome(a3), 0.0);
    });

    test('getAccountStats 一次聚合三值一致', () async {
      final s = await repo.getAccountStats(a1);
      expect(s.balance, closeTo(102, 1e-9));
      expect(s.expense, closeTo(60, 1e-9));
      expect(s.income, closeTo(50, 1e-9));
    });
  });

  group('批量口径(原 A×N 循环 → 单次聚合)', () {
    test('getAllAccountBalances 与逐账户结果一致', () async {
      final balances = await repo.getAllAccountBalances(ledgerOwn);
      expect(balances[a1], closeTo(102, 1e-9));
      expect(balances[a2], closeTo(20, 1e-9));
      expect(balances[a3], closeTo(-15, 1e-9));
      expect(balances[a4], closeTo(5000, 1e-9));
    });

    test('getAllAccountStats 与逐账户结果一致(估值/负债分支)', () async {
      final stats = await repo.getAllAccountStats();
      expect(stats.length, 4);
      expect(stats[a1]!.balance, closeTo(102, 1e-9));
      expect(stats[a1]!.expense, closeTo(60, 1e-9));
      expect(stats[a1]!.income, closeTo(50, 1e-9));
      expect(stats[a2]!.income, closeTo(20, 1e-9));
      expect(stats[a3]!.balance, closeTo(-15, 1e-9));
      expect(stats[a3]!.expense, closeTo(15, 1e-9));
      expect(stats[a4]!.balance, closeTo(5000, 1e-9));
      expect(stats[a4]!.expense, 0.0);
    });

    test('净资产构成:资产/负债分类正确', () async {
      final nw = await repo.getNetWorthBreakdown();
      // 资产 = 102 + 20 + 5000;负债 = -15。
      expect(nw.totalAssets, closeTo(5122, 1e-9));
      expect(nw.totalLiabilities, closeTo(-15, 1e-9));
      expect(nw.netWorth, closeTo(5107, 1e-9));
    });

    test('资产构成按类型聚合', () async {
      final comp = await repo.getAssetCompositionByType();
      final byType = {for (final e in comp) e.type: e.totalBalance};
      expect(byType['cash'], closeTo(102, 1e-9));
      expect(byType['bank_card'], closeTo(20, 1e-9));
      expect(byType['credit_card'], closeTo(-15, 1e-9));
      expect(byType['investment'], closeTo(5000, 1e-9));
    });
  });
}
