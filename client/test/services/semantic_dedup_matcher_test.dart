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

  test('金额+时间(1分钟内)+商户命中强匹配', () async {
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
        time: time.add(const Duration(seconds: 30)),
        type: BillType.expense,
        merchant: '星巴克',
        currency: 'CNY',
      ),
    );

    expect(match?.transactionId, txId);
    expect(match?.isStrong, isTrue);
  });

  test('只有金额和时间:金额一致+1分钟内判疑似重复,进待确认不强判', () async {
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
    expect(match.isPossible, isTrue);
    expect(match.reason, contains('merchant_missing'));
  });

  test('金额不一样绝不是重复:差0.1元、差0.01元都排除(同商户同分钟也不判)',
      () async {
    final time = DateTime(2026, 9, 4, 12, 0);
    await repo.addTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: 28,
      happenedAt: time,
      note: '拼多多',
    );

    Future<SemanticDedupMatch?> query(double amount) =>
        const SemanticDedupMatcher().findBest(
          repository: repo,
          ledgerId: ledgerId,
          bill: BillInfo(
            amount: -amount,
            time: time,
            type: BillType.expense,
            merchant: '拼多多',
            currency: 'CNY',
          ),
        );

    expect(await query(27.9), isNull);
    expect(await query(27.99), isNull);
  });

  test('金额一致但时间相差超过1分钟不判相似', () async {
    final time = DateTime(2026, 9, 4, 12, 0);
    await repo.addTransaction(
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

    expect(match, isNull);
  });

  test('同金额同分钟但商户对不上:疑似级,进待确认由用户裁决', () async {
    final time = DateTime(2026, 9, 4, 12, 0);
    await repo.addTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: 27.9,
      happenedAt: time,
      note: '群收款转给邓腾',
    );

    final match = await const SemanticDedupMatcher().findBest(
      repository: repo,
      ledgerId: ledgerId,
      bill: BillInfo(
        amount: -27.9,
        time: time,
        type: BillType.expense,
        merchant: '拼多多',
        currency: 'CNY',
      ),
    );

    expect(match, isNotNull);
    expect(match!.isStrong, isFalse);
    expect(match.isPossible, isTrue);
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