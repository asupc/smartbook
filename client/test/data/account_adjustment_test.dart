// v42 余额调整记录:调整不再落交易,独立实体只参与余额口径。
//
// 锁定行为:
// - addAccountAdjustment 写行(带符号差额 + 前后快照);
// - 余额口径 = initial + Σ交易 + Σ调整(getAccountBalance / getAccountStats /
//   getAccountBalanceInLedger 三处都吃调整);
// - 调整**不**进收支:expense / income / 交易数不受影响;
// - getAccountAdjustments 时间倒序;delete 后余额回落;
// - 单账本维度:getAccountBalanceInLedger 只吃本账本的调整。

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_account_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late BeeDatabase db;
  late LocalAccountRepository repo;
  late int ledger1;
  late int ledger2;
  late int acc;

  setUp(() async {
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalAccountRepository(db);

    ledger1 = await db
        .into(db.ledgers)
        .insert(LedgersCompanion.insert(name: 'L1'));
    ledger2 = await db
        .into(db.ledgers)
        .insert(LedgersCompanion.insert(name: 'L2'));

    acc = await db.into(db.accounts).insert(AccountsCompanion.insert(
          ledgerId: ledger1,
          name: '现金',
          type: const d.Value('cash'),
          currency: const d.Value('CNY'),
          initialBalance: const d.Value(100.0),
        ));
  });

  tearDown(() async => db.close());

  test('调整改变余额但不动收支统计', () async {
    await repo.addAccountAdjustment(
      ledgerId: ledger1,
      accountId: acc,
      amount: -30.0,
      balanceBefore: 100.0,
      balanceAfter: 70.0,
      note: '对账',
    );
    await repo.addAccountAdjustment(
      ledgerId: ledger1,
      accountId: acc,
      amount: 50.0,
    );

    final stats = await repo.getAccountStats(acc);
    expect(stats.balance, 120.0); // 100 - 30 + 50
    expect(stats.expense, 0.0);   // 调整不是支出
    expect(stats.income, 0.0);    // 调整不是收入

    final balance = await repo.getAccountBalance(acc);
    expect(balance, 120.0);

    // 交易数:调整不产生交易
    final txCount = await repo.getTransactionCountByAccount(acc);
    expect(txCount, 0);
  });

  test('交易与调整混合口径', () async {
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: ledger1,
          type: 'expense',
          amount: 40.0,
          accountId: d.Value(acc),
        ));
    await repo.addAccountAdjustment(
      ledgerId: ledger1,
      accountId: acc,
      amount: 25.0,
    );

    final stats = await repo.getAccountStats(acc);
    expect(stats.balance, 85.0); // 100 - 40(交易) + 25(调整)
    expect(stats.expense, 40.0);
    expect(stats.income, 0.0);
  });

  test('调整记录按时间倒序', () async {
    final id1 = await repo.addAccountAdjustment(
      ledgerId: ledger1,
      accountId: acc,
      amount: -30.0,
    );
    await repo.addAccountAdjustment(
      ledgerId: ledger1,
      accountId: acc,
      amount: 50.0,
    );

    final records = await repo.getAccountAdjustments(acc);
    expect(records.length, 2);
    expect(records.first.amount, 50.0); // 新的在前
    expect(records.last.id, id1);
  });

  test('单账本维度只吃本账本的调整', () async {
    await repo.addAccountAdjustment(
      ledgerId: ledger1,
      accountId: acc,
      amount: -30.0,
    );
    // 同账户在 ledger2 的调整:单账本维度不该吃。
    await db.into(db.accountAdjustments).insert(
          AccountAdjustmentsCompanion.insert(
            ledgerId: ledger2,
            accountId: acc,
            amount: 70.0,
          ),
        );

    final inL1 = await repo.getAccountBalanceInLedger(acc, ledger1);
    expect(inL1, -30.0);
    final inL2 = await repo.getAccountBalanceInLedger(acc, ledger2);
    expect(inL2, 70.0);

    // 全局口径跨账本全吃
    final global = await repo.getAccountGlobalBalance(acc);
    expect(global, 140.0); // 100 + (-30) + 70
  });
}
