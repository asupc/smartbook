import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smartbook/ai/core/bill_info.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/services/automation/semantic_dedup_matcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late LocalRepository repo;
  late int ledgerId;

  setUp(() async {
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    ledgerId = await repo.createLedger(name: 'dedup-test');
  });

  tearDown(() => db.close());

  test('金额+时间+商户命中强匹配', () async {
    final time = DateTime(2026, 9, 4, 12, 0);
    final txId = await repo.addTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: 30,
      happenedAt: time,
      note: '星巴克',
    );

    final match = await const SemanticDedupMatcher().findBest(
      repository: repo,
      ledgerId: ledgerId,
      bill: BillInfo(
        amount: -30,
        time: time.add(const Duration(minutes: 2)),
        type: BillType.expense,
        merchant: '星巴克',
        currency: 'CNY',
      ),
    );

    expect(match?.transactionId, txId);
    expect(match?.isStrong, isTrue);
  });

  test('只有金额和时间不能静默强判重复', () async {
    final time = DateTime(2026, 9, 4, 12, 0);
    await repo.addTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: 30,
      happenedAt: time,
    );

    final match = await const SemanticDedupMatcher().findBest(
      repository: repo,
      ledgerId: ledgerId,
      bill: BillInfo(
        amount: -30,
        time: time,
        type: BillType.expense,
      ),
    );

    expect(match, isNotNull);
    expect(match!.isStrong, isFalse);
    expect(match.score, lessThan(0.72));
  });

  test('收入与支出方向不同不判重', () async {
    final time = DateTime(2026, 9, 4, 12, 0);
    await repo.addTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: 30,
      happenedAt: time,
      note: '退款测试',
    );

    final match = await const SemanticDedupMatcher().findBest(
      repository: repo,
      ledgerId: ledgerId,
      bill: BillInfo(
        amount: 30,
        time: time,
        type: BillType.income,
        merchant: '退款测试',
      ),
    );

    expect(match, isNull);
  });
}