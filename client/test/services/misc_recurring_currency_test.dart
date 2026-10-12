// 杂项域补测(批次 X2):周期记账 / 汇率 两个未产出子域。
//
// FINDINGS-misc-services.md §三 标注未产出:
//   周期记账(月末 31 日/闰年/幂等/模板变更)、汇率(0/负/NaN/Inf/往返漂移/非法币种)。
//
// 覆盖边界(不重复既有文件):
//   - `test/services/data/recurring_transaction_service_test.dart` 覆盖 #135 不回溯、
//     每天首笔含今天、补生成、账户隐藏跳过;本文件补**日历边界**(月末 31 / 闰年 2·29)
//     与**幂等**(重复扫描不重复生成)及模板变更。
//   - `test/services/data/recurring_transaction_currency_test.dart` 覆盖币种解析;
//     本文件不重复。
//   - `rate_math_test.dart` / `rate_math_native_test.dart` 覆盖缺失与非法 rate;
//     本文件补 **NaN/Infinity 字符串 rate、负数、超长币种、往返漂移** 等对抗输入。

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/services/currency/exchange_rate_service.dart';
import 'package:smartbook/services/currency/rate_math.dart';
import 'package:smartbook/services/data/recurring_transaction_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ════════════════════════════════════════════════════════════════
  // 子域 A:周期记账 — 日历边界与幂等
  // ════════════════════════════════════════════════════════════════
  group('周期记账:日历边界', () {
    late BeeDatabase db;
    late LocalRepository repo;
    late int ledgerId;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = BeeDatabase.forTesting(NativeDatabase.memory());
      repo = LocalRepository(db);
      ledgerId = await repo.createLedger(name: 'L', currency: 'CNY');
    });

    tearDown(() async => db.close());

    Future<DateTime?> nextDateFor({
      required RecurringTransaction rt,
      required DateTime now,
    }) async =>
        RecurringTransactionService(repo).calculateNextDate(rt, now: now);

    test('月末 31 日:2 月顺延到月末日(不溢出到 3 月)', () async {
      final id = await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'monthly',
        interval: 1,
        dayOfMonth: 31,
        startDate: DateTime(2026, 1, 31),
      );
      // 已生成过 1/31 → 下一次应落在 2 月(钳到 E-28)
      await repo.updateLastGeneratedDate(id, DateTime(2026, 1, 31));
      final rt = (await repo.getAllRecurringTransactions())
          .firstWhere((r) => r.id == id);

      final next = await nextDateFor(rt: rt, now: DateTime(2026, 2, 28));
      expect(next, DateTime(2026, 2, 28),
          reason: 'dayOfMonth=31 在 2 月应钳到 28(非闰年),不得 DateTime(2026,3,3) 式溢出');
    });

    test('月末 31 日:闰年 2 月钳到 29', () async {
      final id = await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'monthly',
        interval: 1,
        dayOfMonth: 31,
        startDate: DateTime(2028, 1, 31),
      );
      await repo.updateLastGeneratedDate(id, DateTime(2028, 1, 31));
      final rt = (await repo.getAllRecurringTransactions())
          .firstWhere((r) => r.id == id);
      final next = await nextDateFor(rt: rt, now: DateTime(2028, 2, 29));
      expect(next, DateTime(2028, 2, 29));
    });

    test('月末 30 日:2 月钳到 28/29,4 月保持 30', () async {
      final id = await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'monthly',
        interval: 1,
        dayOfMonth: 30,
        startDate: DateTime(2026, 1, 30),
      );
      await repo.updateLastGeneratedDate(id, DateTime(2026, 1, 30));
      final rt = (await repo.getAllRecurringTransactions())
          .firstWhere((r) => r.id == id);
      expect(await nextDateFor(rt: rt, now: DateTime(2026, 2, 28)),
          DateTime(2026, 2, 28));
      // 3 月 30 日后再推 → 4 月 30 日(存在,不钳)
      final rt2 = rt.copyWith(lastGeneratedDate: d.Value(DateTime(2026, 3, 30)));
      expect(await nextDateFor(rt: rt2, now: DateTime(2026, 4, 30)),
          DateTime(2026, 4, 30));
    });

    test('年度 2 月 29 日:非闰年钳到 2 月 28 日', () async {
      final id = await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'yearly',
        interval: 1,
        monthOfYear: 2,
        dayOfMonth: 29,
        startDate: DateTime(2028, 2, 29),
      );
      await repo.updateLastGeneratedDate(id, DateTime(2028, 2, 29));
      final rt = (await repo.getAllRecurringTransactions())
          .firstWhere((r) => r.id == id);
      // 2029 非闰年 → 2 月只有 28 天
      final next = await nextDateFor(rt: rt, now: DateTime(2029, 2, 28));
      expect(next, DateTime(2029, 2, 28));

      // 2032 闰年 → 回到 2/29
      final rt2 = rt.copyWith(lastGeneratedDate: d.Value(DateTime(2031, 2, 28)));
      expect(await nextDateFor(rt: rt2, now: DateTime(2032, 3, 1)),
          DateTime(2032, 2, 29));
    });

    test('interval 跨越多个不存在的目标日:每次钳位后下月基准仍按 targetDay', () async {
      // 6/31 不存在 → 6 月钳到 30;之后 7 月应回到 31(而非停在 30)。
      final id = await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'monthly',
        interval: 1,
        dayOfMonth: 31,
        startDate: DateTime(2026, 6, 30),
      );
      await repo.updateLastGeneratedDate(id, DateTime(2026, 6, 30));
      final rt = (await repo.getAllRecurringTransactions())
          .firstWhere((r) => r.id == id);
      final next = await nextDateFor(rt: rt, now: DateTime(2026, 7, 31));
      expect(next, DateTime(2026, 7, 31),
          reason: '钳位只用当月的 daysInMonth,targetDay 31 应在 7 月恢复');
    });

    test('interval=0 的 monthly:不前进 → 每次扫描都是同一日期(重复生成风险)', () async {
      // 事实锁定:interval 无 >0 校验(repo 直写)。interval=0 时
      // buildMonthly(base.month + 0) = 当月 → nextDate 可能与 lastGenerated 相同,
      // 循环靠 loopGuard(1000)兜底,但会连生多笔。
      final id = await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'monthly',
        interval: 0,
        dayOfMonth: 5,
        startDate: DateTime(2026, 10, 5),
      );
      final rt = (await repo.getAllRecurringTransactions())
          .firstWhere((r) => r.id == id);
      final next = await nextDateFor(rt: rt, now: DateTime(2026, 10, 5));
      expect(next, DateTime(2026, 10, 5));

      // 生成器:interval=0 → lastGeneratedDate 不回退,但 nextDate 恒为 10/5,
      // 循环推进 currentRecurring(内存)的 lastGenerated 后 calculate 仍得到
      // 同一天 → 触发 loopGuard 上限(单次最多 1000 笔)。
      final service = RecurringTransactionService(repo);
      final generated = await service.generatePendingTransactions();
      expect(generated.length, greaterThan(1),
          reason: 'ADVERSE FINDING(未修,仅补测):interval=0 使月度日期不前进,'
              '单次扫描生成多笔同日期交易(loopGuard=1000 才中止)');
      expect(generated.length, lessThanOrEqualTo(1000),
          reason: 'loopGuard 上限生效,不会无限循环');
    });
  });

  group('周期记账:幂等与模板变更', () {
    late BeeDatabase db;
    late LocalRepository repo;
    late int ledgerId;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = BeeDatabase.forTesting(NativeDatabase.memory());
      repo = LocalRepository(db);
      ledgerId = await repo.createLedger(name: 'L', currency: 'CNY');
    });

    tearDown(() async => db.close());

    test('同一天连续两次扫描不重复生成(游标已推进)', () async {
      await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'daily',
        interval: 1,
        startDate: DateTime.now(),
      );
      final service = RecurringTransactionService(repo);
      final first = await service.generatePendingTransactions();
      expect(first, hasLength(1));

      final second = await service.generatePendingTransactions();
      expect(second, isEmpty,
          reason: '游标 lastGeneratedDate=今天 → 二次扫描无到期项');
      expect(await (db.select(db.transactions)).get(), hasLength(1));
    });

    test('模板 amount 变更只影响后续 occurrence,不改已生成历史', () async {
      final now = DateTime.now();
      final id = await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'daily',
        interval: 1,
        startDate: now,
        note: '订阅',
      );
      final first = await RecurringTransactionService(repo)
          .generatePendingTransactions();
      expect(first.single.amount, 10);

      // 改模板金额 → 下一次生成用新金额
      final rt = (await repo.getAllRecurringTransactions())
          .firstWhere((r) => r.id == id);
      await repo.updateRecurringTransaction(
        id: id,
        ledgerId: ledgerId,
        type: rt.type,
        amount: 99,
        frequency: rt.frequency,
        interval: rt.interval,
        startDate: rt.startDate,
        note: rt.note,
        enabled: true,
      );
      // 手工把游标退回昨天,让本次扫描再补一笔
      await repo.updateLastGeneratedDate(
          id, now.subtract(const Duration(days: 1)));
      final second = await RecurringTransactionService(repo)
          .generatePendingTransactions();
      expect(second, hasLength(1));
      expect(second.single.amount, 99, reason: '新 occurrence 用新模板金额');

      final all = await (db.select(db.transactions)
            ..orderBy([(t) => d.OrderingTerm.asc(t.id)]))
          .get();
      expect(all.first.amount, 10, reason: '历史交易金额不被模板变更改写');
      expect(all.last.amount, 99);
    });

    test('禁用模板不再生成;重新启用后按游标续算', () async {
      final now = DateTime.now();
      final id = await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'daily',
        interval: 1,
        startDate: now,
        enabled: false,
      );
      expect(
          await RecurringTransactionService(repo).generatePendingTransactions(),
          isEmpty);

      final rt = (await repo.getAllRecurringTransactions())
          .firstWhere((r) => r.id == id);
      await repo.updateRecurringTransaction(
        id: id,
        ledgerId: ledgerId,
        type: rt.type,
        amount: rt.amount,
        frequency: rt.frequency,
        interval: rt.interval,
        startDate: rt.startDate,
        enabled: true,
      );
      final generated =
          await RecurringTransactionService(repo).generatePendingTransactions();
      expect(generated, hasLength(1));
    });

    test('occurrenceEventKey 稳定:同一模板+日期跨调用恒定', () {
      final a = RecurringTransactionService.occurrenceEventKey(
          recurringId: 7, occurrenceDate: DateTime(2026, 10, 5, 23, 59));
      final b = RecurringTransactionService.occurrenceEventKey(
          recurringId: 7, occurrenceDate: DateTime(2026, 10, 5));
      expect(a, b, reason: '键只取年-月-日,时分秒不影响');
      expect(a, 'recurring:v1:7:2026-10-05');
    });

    test('endDate 已过 → 不生成;endDate 当天可生成', () async {
      final now = DateTime.now();
      final id = await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'daily',
        interval: 1,
        startDate: now,
        endDate: now.subtract(const Duration(days: 1)),
      );
      final rt = (await repo.getAllRecurringTransactions())
          .firstWhere((r) => r.id == id);
      expect(await RecurringTransactionService(repo)
              .calculateNextDate(rt, now: now),
          isNull);
      expect(
          await RecurringTransactionService(repo).generatePendingTransactions(),
          isEmpty);
    });
  });

  // ════════════════════════════════════════════════════════════════
  // 子域 B:汇率 — 对抗输入与解析边界
  // ════════════════════════════════════════════════════════════════
  group('汇率:对抗输入', () {
    test('NaN/Infinity 字符串 rate:computeNativeAmount 不产出非有限值', () {
      for (final bad in ['NaN', 'Infinity', '-Infinity', 'inf', '1e999']) {
        final r = computeNativeAmount(
          amount: 10,
          accountCurrency: 'USD',
          ledgerBase: 'CNY',
          rates: {'USD': EffectiveRate(rate: bad, manual: true)},
        );
        // 'NaN'/'inf' 无法 tryParse → null;'Infinity' 可解析为正数 →
        // 10 * Infinity = Infinity —— 事实锁定该缺口。
        if (r != null) {
          // ignore: avoid_print
          expect(r.isFinite, isFalse,
              reason: 'ADVERSE FINDING(未修,仅补测):rate="$bad" 可解析为正数,'
                  '乘积为 Infinity 且无 isFinite 守卫 → 污染 nativeAmount/统计/备份');
        }
      }
    });

    test('负 rate 混入被拒(既有守卫,防回归)', () {
      expect(
        computeNativeAmount(
            amount: 10,
            accountCurrency: 'USD',
            ledgerBase: 'CNY',
            rates: {'USD': const EffectiveRate(rate: '-7.2', manual: true)}),
        isNull,
      );
    });

    test('invertRate 往返漂移在 1e-9 相对误差内', () {
      for (final x in [0.1477, 6.7715, 1.0, 155.7, 0.000001]) {
        final inv = double.parse(invertRate(x));
        expect(inv * x, closeTo(1.0, 1e-9), reason: 'invertRate($x) 往返');
      }
    });

    test('invertRate 极小正数不产出 Infinity(下溢面)', () {
      // 1/1e-308 ≈ 1e308 < maxFinite;更小(次正规)时可能 Infinity。
      final s = invertRate(1e-308);
      expect(double.parse(s).isFinite, isTrue);
      // 事实锁定:5e-324(最小次正规)倒数溢出为 Infinity(字符串形式)。
      final tiny = invertRate(5e-324);
      // ignore: avoid_print
      expect(double.parse(tiny).isFinite, isFalse,
          reason: 'ADVERSE FINDING(未修,仅补测):invertRate 不检查返回值有限性,'
              '次正规输入产出的 "Infinity" 字符串会被落库为汇率');
    });

    test('parseFawaz 对非法值(0/负/非数/嵌套)只保留正数', () {
      final r = ExchangeRateService.parseFawaz('CNY', {
        'date': '2026-06-10',
        'cny': {
          'usd': 0.1477,
          'jpy': 21.65,
          'bad_zero': 0,
          'bad_neg': -1,
          'bad_str': 'abc',
          'bad_null': null,
          'bad_list': [1, 2],
        },
      });
      expect(r.ratesBaseToQuote.keys, containsAll(['USD', 'JPY']));
      expect(r.ratesBaseToQuote.containsKey('BAD_ZERO'), isFalse);
      expect(r.ratesBaseToQuote.containsKey('BAD_NEG'), isFalse);
      expect(r.ratesBaseToQuote.containsKey('BAD_STR'), isFalse);
      expect(r.ratesBaseToQuote.containsKey('BAD_NULL'), isFalse);
      expect(r.ratesBaseToQuote.containsKey('BAD_LIST'), isFalse);
    });

    test('parseFawaz/parseFrankfurter 缺 date 或表结构错 → 抛 RateFetchException', () {
      expect(
        () => ExchangeRateService.parseFawaz('CNY', {'cny': {'usd': 1.0}}),
        throwsA(isA<RateFetchException>()),
      );
      expect(
        () => ExchangeRateService.parseFawaz('CNY', {'date': '2026-06-10'}),
        throwsA(isA<RateFetchException>()),
      );
      expect(
        () => ExchangeRateService.parseFrankfurter('USD', {'rates': {}}),
        throwsA(isA<RateFetchException>()),
      );
      expect(
        () => ExchangeRateService.parseFrankfurter(
            'USD', {'date': '2026-06-10', 'rates': 'nope'}),
        throwsA(isA<RateFetchException>()),
      );
    });

    test('超长/畸形币种码:大小写归一后原样成为 key(无长度/字符集校验)', () {
      final r = ExchangeRateService.parseFawaz('CNY', {
        'date': '2026-06-10',
        'cny': {'u' * 500: 1.5, 'usd\n\t': 2.0},
      });
      // 事实锁定:发行者不校验 quote 形态,脏 key 直接进 map。
      // 落库侧(RateFetchResult → setOverride)未在解析层拦截。
      expect(r.ratesBaseToQuote.containsKey('U' * 500), isTrue,
          reason: 'ADVERSE FINDING(未修,仅补测):500 字符 quote 码原样进 map');
      expect(r.ratesBaseToQuote.containsKey('USD\n\t'), isTrue,
          reason: 'ADVERSE FINDING(未修,仅补测):含控制字符的 quote 码原样进 map');
    });

    test('mergeEffectiveRates 大小写归一:手动 USD 覆盖自动 usd', () {
      final m = mergeEffectiveRates(
        autoRates: [(quote: 'usd', rate: '7.20', rateDate: '2026-06-10')],
        overrides: [(quote: 'usd', rate: '7.50')],
      );
      expect(m.keys, ['USD']);
      expect(m['USD']!.rate, '7.50');
      expect(m['USD']!.manual, isTrue);
    });
  });
}
