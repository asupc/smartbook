/// M5 新增聚合统计(totalsByAccount / totalsByNote)口径测试:
/// type 过滤、excludeFromStats 排除、nativeAmount ?? amount、备注空/去空格。
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  test('totalsByAccount:按账户聚合支出,type/口径过滤', () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await db.customStatement(
        "INSERT INTO accounts (id, ledger_id, name, currency) "
        "VALUES (10, 1, '招行', 'CNY'), (11, 1, '微信', 'CNY')");
    await repo.addTransaction(
        ledgerId: 1, type: 'expense', amount: 100, accountId: 10,
        happenedAt: DateTime(2026, 7, 5));
    await repo.addTransaction(
        ledgerId: 1, type: 'expense', amount: 45, accountId: 11,
        happenedAt: DateTime(2026, 7, 6));
    await repo.addTransaction(
        ledgerId: 1, type: 'expense', amount: 80,
        happenedAt: DateTime(2026, 7, 7)); // 无账户
    await repo.addTransaction(
        ledgerId: 1, type: 'income', amount: 200, accountId: 10,
        happenedAt: DateTime(2026, 7, 8)); // 收入不进支出统计
    await repo.addTransaction(
        ledgerId: 1, type: 'expense', amount: 500, accountId: 10,
        happenedAt: DateTime(2026, 7, 9), note: '金融类'); // 带 note 不影响
    // 转账不计入
    await repo.addTransaction(
        ledgerId: 1, type: 'transfer', amount: 90, accountId: 10, toAccountId: 11,
        happenedAt: DateTime(2026, 7, 10));
    // exclude_from_stats 排除
    await repo.addTransaction(
        ledgerId: 1, type: 'expense', amount: 999, accountId: 10,
        happenedAt: DateTime(2026, 7, 11), excludeFromStats: true);

    final rows = await repo.totalsByAccount(
        ledgerId: 1,
        type: 'expense',
        start: DateTime(2026, 7, 1),
        end: DateTime(2026, 8, 1));
    expect(rows, hasLength(3)); // acc10 / null / acc11
    // 按 total 降序: 10=600(100+500), null=80, 11=45
    expect(rows[0].accountId, 10);
    expect(rows[0].total, closeTo(600, 1e-9));
    expect(rows.map((r) => r.accountId), containsAllInOrder([10, null, 11]));
    expect(rows.map((r) => r.total), containsAllInOrder([600, 80, 45]));
  });

  test('totalsByAccount:nativeAmount ?? amount(多币种口径)', () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await db.customStatement(
        "INSERT INTO accounts (id, ledger_id, name, currency) "
        "VALUES (10, 1, 'Chase', 'USD')");
    await repo.addTransaction(
        ledgerId: 1, type: 'expense', amount: 12, accountId: 10,
        happenedAt: DateTime(2026, 7, 5),
        currencyCode: 'USD', nativeAmount: 86.4);
    final rows = await repo.totalsByAccount(
        ledgerId: 1,
        type: 'expense',
        start: DateTime(2026, 7, 1),
        end: DateTime(2026, 8, 1));
    expect(rows.single.total, closeTo(86.4, 1e-9));
  });

  test('totalsByNote:按备注聚合支出,去空备注/去空格,支持 limit', () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await repo.addTransaction(
        ledgerId: 1, type: 'expense', amount: 30,
        happenedAt: DateTime(2026, 7, 5), note: '星巴克');
    await repo.addTransaction(
        ledgerId: 1, type: 'expense', amount: 45,
        happenedAt: DateTime(2026, 7, 6), note: ' 星巴克 ');
    await repo.addTransaction(
        ledgerId: 1, type: 'expense', amount: 88,
        happenedAt: DateTime(2026, 7, 7), note: '美团');
    await repo.addTransaction(
        ledgerId: 1, type: 'expense', amount: 77,
        happenedAt: DateTime(2026, 7, 8)); // 无备注不聚合
    await repo.addTransaction(
        ledgerId: 1, type: 'income', amount: 999,
        happenedAt: DateTime(2026, 7, 9), note: '工资'); // 收入不进

    final rows = await repo.totalsByNote(
        ledgerId: 1,
        start: DateTime(2026, 7, 1),
        end: DateTime(2026, 8, 1));
    expect(rows, hasLength(2)); // 美团 / 星巴克
    expect(rows[0].note, '美团'); // 88 > 75,降序第一
    expect(rows[0].total, closeTo(88, 1e-9));
    expect(rows[1].note, '星巴克'); // TRIM 后合并 75
    expect(rows[1].total, closeTo(75, 1e-9));

    final top1 = await repo.totalsByNote(
        ledgerId: 1,
        start: DateTime(2026, 7, 1),
        end: DateTime(2026, 8, 1),
        limit: 1);
    expect(top1, hasLength(1));
    expect(top1.single.note, '美团'); // 88 > 75
  });
}
