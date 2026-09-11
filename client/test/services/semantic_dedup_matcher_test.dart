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

  group('秒级指纹强判重', () {
    test('时间到秒完全一致+金额一致:商户对不上也直接强判重不进待确认', () async {
      final time = DateTime(2026, 9, 4, 12, 0, 37);
      final txId = await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 88,
        happenedAt: time,
        note: '微信支付',
      );

      final match = await const SemanticDedupMatcher().findBest(
        repository: repo,
        ledgerId: ledgerId,
        bill: BillInfo(
          amount: -88,
          time: time,
          type: BillType.expense,
          merchant: '抖音商城',
          currency: 'CNY',
        ),
      );

      expect(match, isNotNull);
      expect(match!.transactionId, txId);
      expect(match.isStrong, isTrue);
      expect(match.score, 1.0);
      expect(match.reason, contains('time_second_exact'));
    });

    test('毫秒位差异不影响秒级判定(Drift epoch 秒存储截断同口径)', () async {
      final time = DateTime(2026, 9, 4, 12, 0, 37, 123);
      await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 88,
        happenedAt: time,
      );

      final match = await const SemanticDedupMatcher().findBest(
        repository: repo,
        ledgerId: ledgerId,
        bill: BillInfo(
          amount: -88,
          time: DateTime(2026, 9, 4, 12, 0, 37),
          type: BillType.expense,
        ),
      );

      expect(match, isNotNull);
      expect(match!.isStrong, isTrue);
      expect(match.reason, contains('time_second_exact'));
    });

    test('秒不同(同分钟)不触发秒级强判:走原商户打分口径', () async {
      final time = DateTime(2026, 9, 4, 12, 0, 37);
      await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 88,
        happenedAt: time,
        note: '微信支付',
      );

      final match = await const SemanticDedupMatcher().findBest(
        repository: repo,
        ledgerId: ledgerId,
        bill: BillInfo(
          amount: -88,
          time: time.add(const Duration(seconds: 20)),
          type: BillType.expense,
          merchant: '抖音商城',
          currency: 'CNY',
        ),
      );

      // 商户对不上且非秒级一致:仍是 possible,进待确认由用户裁决。
      expect(match, isNotNull);
      expect(match!.isStrong, isFalse);
      expect(match.isPossible, isTrue);
    });

    test('账单侧标注 minute 精度(秒为补零)不用秒级指纹', () async {
      final time = DateTime(2026, 9, 4, 12, 30);
      await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 88,
        happenedAt: time,
        note: '微信支付',
      );

      final match = await const SemanticDedupMatcher().findBest(
        repository: repo,
        ledgerId: ledgerId,
        bill: BillInfo(
          amount: -88,
          time: time,
          type: BillType.expense,
          merchant: '抖音商城',
          currency: 'CNY',
          timePrecision: BillTimePrecision.minute,
        ),
      );

      expect(match, isNotNull);
      expect(match!.isStrong, isFalse);
      expect(match.reason, isNot(contains('time_second_exact')));
    });

    test('账单侧标注 exact 但秒为零:交易侧秒位不可信(可能补零)不静默合并',
        () async {
      final time = DateTime(2026, 9, 4, 12, 30, 0);
      await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 88,
        happenedAt: time,
      );

      final match = await const SemanticDedupMatcher().findBest(
        repository: repo,
        ledgerId: ledgerId,
        bill: BillInfo(
          amount: -88,
          time: time,
          type: BillType.expense,
          timePrecision: BillTimePrecision.exact,
        ),
      );

      // 交易侧秒为零时无法区分「整秒发生」与「低精度补零」,退回疑似级
      // 由用户裁决,绝不静默合并。
      expect(match?.isStrong ?? false, isFalse);
      expect(match?.reason ?? '', isNot(contains('time_second_exact')));
    });

    test('同日两笔同金额(date 精度补零)不被秒级指纹静默合并', () async {
      final time = DateTime(2026, 9, 4, 0, 0, 0);
      await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 15,
        happenedAt: time,
        note: '地铁',
      );

      // date 精度(只有日期)的另一笔:秒位是补零,不能判成同一笔。
      final match = await const SemanticDedupMatcher().findBest(
        repository: repo,
        ledgerId: ledgerId,
        bill: BillInfo(
          amount: -15,
          time: time,
          type: BillType.expense,
          merchant: '公交',
          timePrecision: BillTimePrecision.date,
        ),
      );

      // 不静默合并;同金额同分钟的疑似重复仍按既有口径进待确认。
      expect(match?.isStrong ?? false, isFalse);
      expect(match?.reason ?? '', isNot(contains('time_second_exact')));
    });
  });

  group('跨渠道强判重', () {
    test('硬闸门已过+来源不同:商户对不上也直接强判重', () async {
      // 银行短信先落库(备注=收款方,商户信息差)
      final time = DateTime(2026, 9, 10, 12, 3, 11);
      final txId = await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 181.4,
        happenedAt: time,
        note: '微信支付',
      );

      // 电商通知后到:同金额、秒级不同(12:03:31)、商户完全不同 ——
      // 无跨渠道信号时只是 possible(同商户对不上老口径)。
      final match = await const SemanticDedupMatcher().findBest(
        repository: repo,
        ledgerId: ledgerId,
        bill: BillInfo(
          amount: -181.4,
          time: time.add(const Duration(seconds: 20)),
          type: BillType.expense,
          merchant: '抖音商城',
          currency: 'CNY',
        ),
        sourceKey: 'notification',
        transactionSourceKeys: (_) async => {'sms'},
      );

      expect(match, isNotNull);
      expect(match!.transactionId, txId);
      expect(match.isStrong, isTrue);
      expect(match.isCrossChannel, isTrue);
      expect(match.reason, contains('cross_channel_strong'));
    });

    test('来源相同(同渠道重放)不触发跨渠道强判重', () async {
      final time = DateTime(2026, 9, 10, 12, 3, 11);
      await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 181.4,
        happenedAt: time,
        note: '微信支付',
      );

      final match = await const SemanticDedupMatcher().findBest(
        repository: repo,
        ledgerId: ledgerId,
        bill: BillInfo(
          amount: -181.4,
          time: time.add(const Duration(seconds: 20)),
          type: BillType.expense,
          merchant: '抖音商城',
          currency: 'CNY',
        ),
        sourceKey: 'sms',
        transactionSourceKeys: (_) async => {'sms'},
      );

      // 同渠道:维持原口径(商户对不上 → possible 进待确认)。
      expect(match, isNotNull);
      expect(match!.isStrong, isFalse);
      expect(match.isCrossChannel, isFalse);
    });

    test('交易无自动事件来源(手动/导入):不触发跨渠道强判重', () async {
      final time = DateTime(2026, 9, 10, 12, 3, 11);
      await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 181.4,
        happenedAt: time,
        note: '微信支付',
      );

      final match = await const SemanticDedupMatcher().findBest(
        repository: repo,
        ledgerId: ledgerId,
        bill: BillInfo(
          amount: -181.4,
          time: time.add(const Duration(seconds: 20)),
          type: BillType.expense,
          merchant: '抖音商城',
          currency: 'CNY',
        ),
        sourceKey: 'notification',
        transactionSourceKeys: (_) async => const {},
      );

      expect(match, isNotNull);
      expect(match!.isStrong, isFalse);
      expect(match.isCrossChannel, isFalse);
    });

    test('来源反查抛异常:退回语义打分,不阻断判重', () async {
      final time = DateTime(2026, 9, 10, 12, 3, 11);
      await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 181.4,
        happenedAt: time,
        note: '微信支付',
      );

      final match = await const SemanticDedupMatcher().findBest(
        repository: repo,
        ledgerId: ledgerId,
        bill: BillInfo(
          amount: -181.4,
          time: time.add(const Duration(seconds: 20)),
          type: BillType.expense,
          merchant: '抖音商城',
          currency: 'CNY',
        ),
        sourceKey: 'notification',
        transactionSourceKeys: (_) async => throw Exception('db boom'),
      );

      expect(match, isNotNull);
      expect(match!.isStrong, isFalse);
      expect(match.isCrossChannel, isFalse);
    });

    test('不传来源参数:行为与既有口径完全一致(回归)', () async {
      final time = DateTime(2026, 9, 10, 12, 3, 11);
      await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 88,
        happenedAt: time,
        note: '微信支付',
      );

      final match = await const SemanticDedupMatcher().findBest(
        repository: repo,
        ledgerId: ledgerId,
        bill: BillInfo(
          amount: -88,
          time: time.add(const Duration(seconds: 20)),
          type: BillType.expense,
          merchant: '抖音商城',
          currency: 'CNY',
        ),
      );

      expect(match, isNotNull);
      expect(match!.isStrong, isFalse);
      expect(match.isPossible, isTrue);
    });
  });
}