// 对抗性测试 — 统计聚合域(SmartBook 客户端数据层)。
//
// 重点攻击:各聚合入口之间的口径一致性(exclude flags / nativeAmount /
// exclude 各入口是否同一套)、多币种折算方向、净值趋势与账户余额合计的一致性、
// 空集合除零、大数据量、日历入口。
//
// 语义参照(只读):
//   lib/data/repositories/local/local_statistics_repository.dart (565 行)
//   lib/data/repositories/local/local_account_repository.dart
//   lib/data/repositories/local/local_budget_repository.dart
//   lib/data/repositories/local/local_ledger_repository.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/services/currency/rate_math.dart';

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
  // H. exclude flags 组合矩阵 —— 每个聚合入口的口径交叉一致性
  // ══════════════════════════════════════════════════════════════════════

  group('H. exclude flags 跨入口一致性', () {
    /// 2×2 组合:excludeFromStats({F,T}) × excludeFromBudget({F,T}),
    /// 金额 1/2/3/4 一一对应,便于反推每个入口用了哪套口径。
    ///
    /// 契约(source of truth):
    ///   - 收支类(月/年/日/区间/分类/账户/标签/备注)应按 excludeFromStats=0
    ///     → 期望值 1+2 = 3
    ///   - 预算用量应按 excludeFromBudget=0 → 期望值 1+3 = 4
    ///   - 余额/净值不看任何 flag → 期望含全部 4 笔
    Future<({int budgetId, int accountId, int categoryId, int tagId})>
        seedMatrix() async {
      await seedLedger();
      final acc = await repo.createAccount(ledgerId: 1, name: 'MX');
      final cat = await repo.createCategory(name: 'MXC', kind: 'expense');
      final tag = await repo.createTag(name: 'MXT');
      final bid =
          await repo.createBudget(ledgerId: 1, type: 'total', amount: 1000);
      var amount = 1;
      for (final exStats in [false, true]) {
        for (final exBudget in [false, true]) {
          final id = await repo.addTransaction(
              ledgerId: 1, type: 'expense', amount: amount.toDouble(),
              accountId: acc, categoryId: cat, happenedAt: DateTime(2026, 7, 15),
              excludeFromStats: exStats, excludeFromBudget: exBudget);
          await repo.updateTransactionTags(transactionId: id, tagIds: [tag]);
          amount++;
        }
      }
      return (budgetId: bid, accountId: acc, categoryId: cat, tagId: tag);
    }

    test('H1 收支类入口(月/年/日/区间/分类/账户/标签/备注)口径一致 = 3',
        () async {
      final s = await seedMatrix();
      final start = DateTime(2026, 7, 1);
      final end = DateTime(2026, 8, 1);

      final (_, monthExp) =
          await repo.monthlyTotals(ledgerId: 1, month: start);
      final (_, yearExp) = await repo.yearlyTotals(ledgerId: 1, year: 2026);
      final (_, rangeExp) =
          await repo.totalsInRange(ledgerId: 1, start: start, end: end);
      final byDay = await repo.totalsByDay(
          ledgerId: 1, type: 'expense', start: start, end: end);
      final byCat = await repo.totalsByCategory(
          ledgerId: 1, type: 'expense', start: start, end: end);
      final byAcc = await repo.totalsByAccount(
          ledgerId: 1, type: 'expense', start: start, end: end);
      final series =
          await repo.totalsByMonth(ledgerId: 1, year: 2026, type: 'expense');
      final yearSeries =
          await repo.totalsByYearSeries(ledgerId: 1, type: 'expense');
      final tagStats = await repo.getTagStats(s.tagId,
          ledgerId: 1, start: start, end: end);
      final accStats = await repo.getAccountStats(s.accountId);
      final ledgerStats = await repo.getLedgerStats(ledgerId: 1);

      final daySum = byDay.fold<double>(0, (a, b) => a + b.total);
      final catSum = byCat.fold<double>(0, (a, b) => a + b.total);
      final accSum = byAcc.fold<double>(0, (a, b) => a + b.total);
      final seriesSum = series.fold<double>(0, (a, b) => a + b.total);
      final yearSeriesSum = yearSeries.fold<double>(0, (a, b) => a + b.total);

      // HARDENING: 这些入口全部用 exclude_from_stats = 0,口径统一。
      expect(monthExp, 3.0, reason: 'HARDENING: monthlyTotals');
      expect(yearExp, 3.0, reason: 'HARDENING: yearlyTotals');
      expect(rangeExp, 3.0, reason: 'HARDENING: totalsInRange');
      expect(daySum, 3.0, reason: 'HARDENING: totalsByDay');
      expect(catSum, 3.0, reason: 'HARDENING: totalsByCategory');
      expect(accSum, 3.0, reason: 'HARDENING: totalsByAccount');
      expect(seriesSum, 3.0, reason: 'HARDENING: totalsByMonth');
      expect(yearSeriesSum, 3.0, reason: 'HARDENING: totalsByYearSeries');
      expect(tagStats.expense, 3.0, reason: 'HARDENING: getTagStats');
      expect(accStats.expense, 3.0, reason: 'HARDENING: getAccountStats');
      // getLedgerStats 的 balance 是余额口径(不按 flag 过滤),只统计收支：
      // 4 笔 expense 全算 → -10。注释(:132-137)明示"账本余额仅计算交易收支"。
      expect(ledgerStats.balance, -10.0,
          reason: 'HARDENING: getLedgerStats.balance 走余额口径(含全部 4 笔)');
    });

    test('H2 预算用量按 excludeFromBudget = 4(与收支口径 3 不同,符合设计 D2)',
        () async {
      final s = await seedMatrix();
      final usage = await repo.getBudgetUsage(s.budgetId, DateTime(2026, 7, 15));
      // HARDENING: 设计 D2 明确两个 flag 完全独立 → 4 是正确值。
      expect(usage.used, 4.0, reason: 'HARDENING: 预算只按 excludeFromBudget 过滤');
    });

    test('H3 但 getAccountCategoryStats 完全不过滤 exclude flags:口径漏网',
        () async {
      final s = await seedMatrix();
      final byCat = await repo.getAccountCategoryStats(s.accountId, type: 'expense');
      final sum = byCat.fold<double>(0, (a, b) => a + b.total);
      final stats = await repo.getAccountStats(s.accountId);
      // ADVERSE FINDING: getAccountCategoryStats 的 SQL 只有
      //   WHERE t.account_id = ?1 AND t.type = ?2 AND <共享账本排除>
      // (local_account_repository.dart:857-866)**没有 exclude_from_stats = 0**。
      // 同一账户下"总支出"(getAccountStats.expense=3)与"分类明细合计"(=10)
      // 相差 ${4-...},账户详情页的饼图/排行会包含被标记"不计入收支"的账目。
      expect(sum, stats.expense,
          reason: 'ADVERSE FINDING: getAccountCategoryStats 合计 $sum != '
              'getAccountStats.expense ${stats.expense};前者漏了 '
              'exclude_from_stats 过滤(期望 3,实际 10)');
    });

    test('H4 getTagStats 本地分支过滤 flags,共享账本 synthetic 分支不过滤:'
        '同一标签概念两套口径', () async {
      await seedLedger();
      // 本地标签 + excludeFromStats 交易
      final localTag = await repo.createTag(name: 'LT');
      final txId = await repo.addTransaction(ledgerId: 1, type: 'expense',
          amount: 300, happenedAt: DateTime(2026, 7, 5),
          syncId: 'TX-SH', excludeFromStats: true);
      await repo.updateTransactionTags(transactionId: txId, tagIds: [localTag]);

      // 同一笔交易另挂一个共享账本标签(override 路径)
      await db.into(db.sharedLedgerTags).insert(SharedLedgerTagsCompanion.insert(
          ledgerSyncId: 'LS',
          syncId: 'TAG-SH',
          name: '共享标签',
          updatedAt: DateTime(2026, 7, 5)));
      final tx = await repo.getTransactionById(txId);
      await db.into(db.transactionTagOverrides).insert(
          TransactionTagOverridesCompanion.insert(
              transactionSyncId: tx!.syncId!,
              tagSyncId: 'TAG-SH',
              createdAt: DateTime(2026, 7, 5)));
      // 让 synthetic id 可推导
      final shared = await db
          .customSelect("SELECT * FROM shared_ledger_tags WHERE sync_id='TAG-SH'")
          .getSingle();
      expect(shared, isNotNull);
      final localStats = await repo.getTagStats(localTag);
      // 用 synthetic id 拿共享分支(需要 syntheticIdForSyncId)
      // 此处用 hashCode 直接推:
      final h = 'TAG-SH'.hashCode;
      final synthId = h == 0 ? -1 : (h > 0 ? -h : h);
      final sharedStats = await repo.getTagStats(synthId);

      // ADVERSE FINDING: 本地分支 SQL 带 exclude_from_stats = 0
      // (local_tag_repository.dart:403-404);共享分支
      // (_sharedTagStatsBySyntheticId, :645-686)是 Dart 循环累加 type,
      // **完全没有 exclude flag 判断**。同一笔交易,同一"不计入收支"标记,
      // 挂本地标签算 0、挂共享标签算 300。
      expect(localStats.expense, 0.0,
          reason: 'HARDENING: 本地标签分支正确排除 excludeFromStats');
      expect(sharedStats.expense, localStats.expense,
          reason: 'ADVERSE FINDING: 共享标签 synthetic 分支统计 '
              '${sharedStats.expense} ≠ 本地分支 ${localStats.expense};'
              '共享账本视图会把"不计入收支"的账目算进标签总额');
    });

    test('H5 totalsByNote / searchTransactions 的口径差异:同族入口不一致',
        () async {
      await seedLedger();
      final cat = await repo.createCategory(name: 'NT', kind: 'expense');
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 100,
          categoryId: cat, happenedAt: DateTime(2026, 7, 5), note: 'same');
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 900,
          categoryId: cat, happenedAt: DateTime(2026, 7, 6), note: 'same',
          excludeFromStats: true);
      final notes = await repo.totalsByNote(
          ledgerId: 1, start: DateTime(2026, 7, 1), end: DateTime(2026, 8, 1));
      // totalsByNote 硬编码 type='expense'(:464)且带 exclude_from_stats = 0。
      expect(notes.length, 1);
      expect(notes.first.total, 100.0,
          reason: 'HARDENING: totalsByNote 排除 excludeFromStats');
      final hits = await repo.searchTransactions(ledgerId: 1, searchText: 'same');
      // HARDENING: searchTransactions 是"列表"语义,不做 exclude 过滤(与
      // getRecentTransactions 一致)。
      expect(hits.length, 2,
          reason: 'HARDENING: searchTransactions 不做 exclude 过滤(列表语义)');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // I. 多币种折算方向(重点攻击:乘除是否搞反)
  // ══════════════════════════════════════════════════════════════════════

  group('I. 多币种折算方向', () {
    test('I1 手动汇率「1 quote = rate base」方向正确:nativeAmount = amount × rate',
        () async {
      await seedLedger(); // CNY 本位
      // 用户设置:1 USD = 7.2 CNY。rate 字符串存 "7.2"(quote=USD, base=CNY)
      await repo.setOverride(base: 'CNY', quote: 'USD', rate: '7.2');
      final rates = await repo.getOverrides('CNY');
      expect(rates.single.rate, '7.2');
      final usdAcc = await repo.createAccount(
          ledgerId: 1, name: 'U1', currency: 'USD', initialBalance: 0);
      final id = await repo.addTransaction(ledgerId: 1, type: 'expense',
          amount: 10, accountId: usdAcc, happenedAt: DateTime(2026, 7, 5));
      final t = await repo.getTransactionById(id);
      // HARDENING: 方向正确($10 → ¥72,而非 ¥13.9 或 ¥1.39)。
      expect(t!.currencyCode, 'USD');
      expect(t.nativeAmount, closeTo(72.0, 1e-9),
          reason: 'HARDENING: 折算方向 = amount × rate(1 USD = 7.2 CNY)');

      // 通过账户币种 + 汇率表自动折算路径(explicit ==null 走 _resolveTxCurrency)
      final id2 = await repo.addTransaction(ledgerId: 1, type: 'expense',
          amount: 100, accountId: usdAcc, happenedAt: DateTime(2026, 7, 6));
      final t2 = await repo.getTransactionById(id2);
      expect(t2!.nativeAmount, closeTo(720.0, 1e-9),
          reason: 'HARDENING: 自动折算路径方向一致');

      // 账本维度统计读 nativeAmount,账户维度读 amount
      final (_, exp) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 7, 1));
      final balUsd = await repo.getAccountBalance(usdAcc);
      expect(exp, closeTo(792.0, 1e-9),
          reason: 'HARDENING: 账本维度 = 72 + 720(本币口径)');
      expect(balUsd, closeTo(-110.0, 1e-9),
          reason: 'HARDENING: 账户维度 = -(10+100) 原币(不折算)');
    });

    test('I2 反向汇率「1 CNY = 0.1389 USD」不应被用错方向(缺该 base 的组则回落 amount)',
        () async {
      await seedLedger();
      // 只给 1 CNY = 0.1389 USD(即 base=USD, quote=CNY 的组);
      // 折算到 CNY 本位需要 base=CNY 的组 → 缺失 → 回落 amount。
      await repo.setOverride(base: 'USD', quote: 'CNY', rate: '0.1389');
      final usdAcc = await repo.createAccount(
          ledgerId: 1, name: 'U2', currency: 'USD');
      final id = await repo.addTransaction(ledgerId: 1, type: 'expense',
          amount: 10, accountId: usdAcc, happenedAt: DateTime(2026, 7, 5));
      final t = await repo.getTransactionById(id);
      // HARDENING: 缺 CNY-base 组 → computeNativeAmount 返回 null → 兜底
      // nativeAmount = amount(L11 检测可捞回),**不是**错误方向的结果
      // (正确方向会得 10×7.2=72;错误方向 10×0.1389=1.389)。
      expect(t!.nativeAmount, 10.0,
          reason: 'HARDENING: 缺失该 base 的汇率组 → nativeAmount = amount'
              '(${t.nativeAmount});未出现方向搞反的 1.389');
    });

    test('I3 汇率倒数语义:invertRate 与 computeNativeAmount 一致', () {
      // 1 base = 0.1389 quote → 1 quote = 7.1994... base
      final inverted = invertRate(0.1388888888888889);
      final parsed = double.parse(inverted);
      expect(parsed, closeTo(7.2, 1e-6),
          reason: 'HARDENING: invertRate 与 computeNativeAmount 同方向约定');

      final na = computeNativeAmount(
        amount: 10,
        accountCurrency: 'USD',
        ledgerBase: 'CNY',
        rates: {'USD': EffectiveRate(rate: inverted, manual: true)},
      );
      expect(na, closeTo(72.0, 1e-6),
          reason: 'HARDENING: 1 USD = x CNY -> USD 10 = CNY 72');
    });

    test('I4 非法/非正/缺失 rate:computeNativeAmount 返回 null,绝不静默 1.0', () {
      // HARDENING: README D5 红线 —— 汇率缺失就是缺失。
      expect(
          computeNativeAmount(
              amount: 10,
              accountCurrency: 'USD',
              ledgerBase: 'CNY',
              rates: {'USD': EffectiveRate(rate: '0', manual: true)}),
          isNull);
      expect(
          computeNativeAmount(
              amount: 10,
              accountCurrency: 'USD',
              ledgerBase: 'CNY',
              rates: {'USD': EffectiveRate(rate: '-7.2', manual: true)}),
          isNull);
      expect(
          computeNativeAmount(
              amount: 10,
              accountCurrency: 'USD',
              ledgerBase: 'CNY',
              rates: {'USD': EffectiveRate(rate: 'abc', manual: true)}),
          isNull);
      expect(
          computeNativeAmount(
              amount: 10,
              accountCurrency: 'USD',
              ledgerBase: 'CNY',
              rates: const {}),
          isNull);
      // 同币种 → amount
      expect(
          computeNativeAmount(
              amount: 10,
              accountCurrency: 'CNY',
              ledgerBase: 'CNY',
              rates: const {}),
          10.0);
    });

    test('I5 改账本本位币后全量重算:外币按新本位币重折,同币种对齐 amount',
        () async {
      await seedLedger(); // CNY
      await repo.setOverride(base: 'CNY', quote: 'USD', rate: '7.2');
      final usdAcc = await repo.createAccount(
          ledgerId: 1, name: 'U5', currency: 'USD');
      final usdTx = await repo.addTransaction(ledgerId: 1, type: 'expense',
          amount: 10, accountId: usdAcc, happenedAt: DateTime(2026, 7, 5));
      final cnyTx = await repo.addTransaction(ledgerId: 1, type: 'expense',
          amount: 100, happenedAt: DateTime(2026, 7, 6));
      expect((await repo.getTransactionById(usdTx))!.nativeAmount, 72.0);
      expect((await repo.getTransactionById(cnyTx))!.nativeAmount, 100.0);

      // 改本位币为 USD 并重算
      await db.customStatement("UPDATE ledgers SET currency='USD' WHERE id=1");
      final changed = await repo.recalcNativeAmountsForLedger(1, 'USD');
      final afterUsd = await repo.getTransactionById(usdTx);
      final afterCny = await repo.getTransactionById(cnyTx);
      // HARDENING: USD 账户交易 = 新本位币 → native = amount(10);
      // CNY 交易变成外币 → 按 base=USD 的汇率组折算。无该组 → 全量重算路径
      // 退化 =amount(:741-747"让 L11 横幅能捞回"),**不是**保留旧快照。
      expect(afterUsd!.nativeAmount, 10.0,
          reason: 'HARDENING: 同新本位币 → native = amount');
      expect(afterCny!.nativeAmount, 100.0,
          reason: 'HARDENING: 缺 USD-base 汇率组 → 全量重算退化为 amount(可被 L11 捞回),'
              '旧快照 100(CNY 口径)保留也是 100 偶然相同;此处只锁"不为 null/不合理值"');
      expect(changed, greaterThanOrEqualTo(1));
      // L11 检测:currency≠base 且 native==amount
      final unconverted = await repo.countUnconvertedForeignTx(1);
      expect(unconverted, greaterThanOrEqualTo(1),
          reason: 'HARDENING: 退化行被 L11 检测到(可手工补汇率)');
    });

    test('I6 nativeAmount 显式传入 0:COALESCE 把它当有效值(0 而非回落 amount)',
        () async {
      await seedLedger();
      // 显式 nativeAmount = 0(如兑换成 0 元/免费)
      final id = await repo.addTransaction(ledgerId: 1, type: 'expense',
          amount: 50, happenedAt: DateTime(2026, 7, 5),
          currencyCode: 'USD', nativeAmount: 0);
      final t = await repo.getTransactionById(id);
      final (_, exp) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 7, 1));
      // HARDENING: SQL 用 COALESCE(native_amount, amount) —— 0 是"已定义"值,
      // 不回落 amount。语义正确(0 折算就是 0),但调用方传 0 当"没算"会静默丢账。
      expect(t!.nativeAmount, 0.0);
      expect(exp, 0.0,
          reason: 'HARDENING: nativeAmount=0 计入账本统计为 0(不回落 amount=50)');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // J. 净值趋势 vs 账户余额合计(同数据两入口)
  // ══════════════════════════════════════════════════════════════════════

  group('J. 净值一致性', () {
    test('J1 趋势末点 = Σ账户余额 × 汇率(单/多币种都给同一答案)', () async {
      await seedLedger();
      final cny = await repo.createAccount(
          ledgerId: 1, name: 'J1CNY', currency: 'CNY', initialBalance: 1000);
      final usd = await repo.createAccount(
          ledgerId: 1, name: 'J1USD', currency: 'USD', initialBalance: 100);
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 100,
          accountId: cny, happenedAt: DateTime(2026, 7, 5));
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 10,
          accountId: usd, happenedAt: DateTime(2026, 7, 6),
          currencyCode: 'USD', nativeAmount: 72);
      final rates = {'CNY': 1.0, 'USD': 7.2};
      final trend = await repo.getNetWorthTrendSeries(
          startDate: DateTime(2026, 7, 1),
          endDate: DateTime(2026, 7, 10),
          ratesToBase: rates);
      final balCny = await repo.getAccountBalance(cny);
      final balUsd = await repo.getAccountBalance(usd);
      final manual = balCny * 1.0 + balUsd * 7.2;
      // HARDENING: 趋势末点与手工折算一致(900 + 648 = 1548)。
      expect(trend.last.net, closeTo(manual, 1e-9),
          reason: 'HARDENING: 趋势末点 ${trend.last.net} == Σ余额×rate $manual');
      // 与净资产卡(byCurrency + computeConvertedNetWorth)一致
      final byCur = await repo.getNetWorthBreakdownByCurrency();
      final converted = computeConvertedNetWorth(
        breakdown: byCur,
        rates: {
          'USD': const EffectiveRate(rate: '7.2', manual: true),
        },
        base: 'CNY',
      );
      expect(converted.netWorth, closeTo(trend.last.net, 1e-9),
          reason: 'HARDENING: 净资产卡与趋势线同口径');
    });

    test('J2 缺汇率的币种:趋势整条剔除,资产构成/分组余额仍原币列出(不一致)',
        () async {
      await seedLedger();
      final cny = await repo.createAccount(
          ledgerId: 1, name: 'J2CNY', currency: 'CNY', initialBalance: 1000);
      final jpy = await repo.createAccount(
          ledgerId: 1, name: 'J2JPY', currency: 'JPY', initialBalance: 50000);
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 100,
          accountId: cny, happenedAt: DateTime(2026, 7, 5));
      // 区间覆盖交易日 7/5 且延伸到"今天之后",让末点 == 当前余额口径
      final trend = await repo.getNetWorthTrendSeries(
          startDate: DateTime(2026, 7, 1),
          endDate: DateTime(2030, 1, 1),
          ratesToBase: {'CNY': 1.0}); // 无 JPY
      expect(trend.last.net, 900.0,
          reason: 'HARDENING: 缺 JPY 汇率 → JPY 整条剔除'
              '(900 = CNY 1000 - 100),而非裸加 50000 变 50900');
      // 但 getNetWorthBreakdownByCurrency / getAssetCompositionByTypeAndCurrency
      // 仍列出 JPY 原币余额(UI 必须自行标注缺失)
      final byCur = await repo.getNetWorthBreakdownByCurrency();
      expect(byCur.keys, containsAll(['CNY', 'JPY']),
          reason: 'HARDENING: 分组口径保留 JPY(靠 convertAmountsToBase 的 '
              'missingCurrencies 显式标示)');
      final converted = computeConvertedNetWorth(
          breakdown: byCur,
          rates: {'USD': const EffectiveRate(rate: '7.2', manual: true)},
          base: 'CNY');
      expect(converted.missingCurrencies, ['JPY'],
          reason: 'HARDENING: missing 显式列出(不静默按 1.0)');
      // 卡片(当前余额口径)与趋势末点在"区间延伸到当前之后"时一致。
      expect(converted.netWorth, closeTo(900.0, 1e-9),
          reason: 'HARDENING: 卡片剔除 JPY → 900');
      expect(converted.netWorth, closeTo(trend.last.net, 1e-9),
          reason: 'HARDENING: 卡片与趋势都用"剔除"策略,末点一致');
    });

    test('J3 估值账户(real_estate/loan):余额恒等于 initialBalance,忽略交易',
        () async {
      await seedLedger();
      final house = await repo.createAccount(
          ledgerId: 1, name: 'J3房', type: 'real_estate', initialBalance: 2000000);
      final loan = await repo.createAccount(
          ledgerId: 1, name: 'J3贷', type: 'loan', initialBalance: -800000);
      // 试图给估值账户记账
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 50000,
          accountId: house, happenedAt: DateTime(2026, 7, 5));
      final balHouse = await repo.getAccountBalance(house);
      final balLoan = await repo.getAccountBalance(loan);
      // HARDENING: isValuationOnlyType 早退返回 initialBalance(:348-350),交易被忽略。
      expect(balHouse, 2000000.0,
          reason: 'HARDENING: 估值账户余额恒为 initialBalance');
      expect(balLoan, -800000.0);
      final bd = await repo.getNetWorthBreakdown();
      expect(bd.totalAssets, 2000000.0);
      expect(bd.totalLiabilities, -800000.0);
      expect(bd.netWorth, 1200000.0,
          reason: 'HARDENING: 负债以负数计入(loan -800k)');
      // 但同日趋势里的日余额回放也忽略交易
      final daily = await repo.getAccountDailyBalances(house,
          startDate: DateTime(2026, 7, 1), endDate: DateTime(2026, 7, 3));
      expect(daily.every((d) => d.balance == 2000000.0), isTrue,
          reason: 'HARDENING: 估值账户日余额固定');
    });

    test('J4 成员身份加入的共享账本:余额/趋势排除,但 getAccountBalanceInLedger '
        '和 clearLedgerTransactions 不排除(口径分裂)', () async {
      await seedLedger();
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency, is_shared, my_role) "
          "VALUES (2, '别人账本', 'CNY', 1, 'editor')");
      final acc = await repo.createAccount(ledgerId: 1, name: 'J4A', initialBalance: 0);
      // 该账户在自己账本 + 共享账本各有交易
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 100,
          accountId: acc, happenedAt: DateTime(2026, 7, 5));
      await repo.addTransaction(ledgerId: 2, type: 'expense', amount: 900,
          accountId: acc, happenedAt: DateTime(2026, 7, 5));

      final global = await repo.getAccountGlobalBalance(acc);
      final plain = await repo.getAccountBalance(acc);
      final inL2 = await repo.getAccountBalanceInLedger(acc, 2);
      final allBal = await repo.getAllAccountBalances(1);
      final stats = await repo.getAccountStats(acc);
      // HARDENING(部分是 ADVERSE):_kExcludeJoinedSharedLedgerSql 在
      // getAccountBalance / getAccountGlobalBalance / getAllAccountBalances /
      // getAccountStats 里生效 → 排除共享账本的 900。
      expect(global, -100.0, reason: 'HARDENING: 全局余额排除成员账本');
      expect(plain, -100.0, reason: 'HARDENING: 普通余额排除成员账本');
      expect(allBal[acc], -100.0, reason: 'HARDENING: 批量余额排除成员账本');
      expect(stats.expense, 100.0, reason: 'HARDENING: 账户收支排除成员账本');
      // 但单账本维度按设计**不排除**(它本来就是查那个账本)
      expect(inL2, -900.0,
          reason: 'HARDENING: getAccountBalanceInLedger(2) 按设计含该账本'
              '(注释 :394-395 明示"单账本维度不排除共享账本")');

      // 净值趋势:同样排除成员账本?
      final trend = await repo.getNetWorthTrendSeries(
          startDate: DateTime(2026, 7, 5),
          endDate: DateTime(2026, 7, 5),
          ratesToBase: {'CNY': 1.0});
      expect(trend.last.net, -100.0,
          reason: 'HARDENING: 趋势排除成员账本(与余额口径一致)');
    });

    test('J5 getNetWorthDailyBalances(旧入口)多币种裸加,与 ByCurrency/趋势不一致',
        () async {
      await seedLedger();
      final cny = await repo.createAccount(
          ledgerId: 1, name: 'J5CNY', currency: 'CNY', initialBalance: 1000);
      final usd = await repo.createAccount(
          ledgerId: 1, name: 'J5USD', currency: 'USD', initialBalance: 100);
      // C3 修复:旧入口与趋势/净资产卡统一走"折算 + 缺汇率整条剔除"口径。
      // 汇率来源:账本可查到的有效汇率(手动 override 表)。先落一条
      // 1 USD = 7.2 CNY,让两个入口都能拿到同一份汇率 —— 原测试没设汇率就
      // 断言两入口一致,而折算所需的 7.2 在库中根本不存在(不可能自洽)。
      await repo.setOverride(base: 'CNY', quote: 'USD', rate: '7.2');
      expect(usd, greaterThan(0));
      final plain = await repo.getNetWorthDailyBalances(
          startDate: DateTime(2026, 7, 1), endDate: DateTime(2026, 7, 2));
      final series = await repo.getNetWorthTrendSeries(
          startDate: DateTime(2026, 7, 1),
          endDate: DateTime(2026, 7, 2),
          ratesToBase: {'CNY': 1.0, 'USD': 7.2});
      // C3 修复:旧入口不再裸加各币种原币(¥1000 + $100 = 1100),而是与趋势
      // 同口径折算(1000 + 100×7.2 = 1720)。原断言 reason 描述的正是修复前缺陷。
      expect(plain.last.balance, closeTo(1720.0, 1e-9),
          reason: r'C3 修复: 旧入口按汇率折算(¥1000 + $100×7.2 = 1720),不再裸加 1100');
      expect(plain.last.balance, closeTo(series.last.net, 1e-9),
          reason: 'C3 修复: 两个净值趋势入口口径统一');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // K. 边界 / 空集 / 大数据量
  // ══════════════════════════════════════════════════════════════════════

  group('K. 边界与数据量', () {
    test('K1 空集合:全部聚合入口返回 0 / 空,不抛除零', () async {
      await seedLedger();
      final start = DateTime(2026, 7, 1);
      final end = DateTime(2026, 8, 1);
      final (i, e) = await repo.totalsInRange(ledgerId: 1, start: start, end: end);
      final (mi, me) = await repo.monthlyTotals(ledgerId: 1, month: start);
      final (yi, ye) = await repo.yearlyTotals(ledgerId: 1, year: 2026);
      final cats = await repo.totalsByCategory(
          ledgerId: 1, type: 'expense', start: start, end: end);
      final days = await repo.totalsByDay(
          ledgerId: 1, type: 'expense', start: start, end: end);
      final accs = await repo.totalsByAccount(
          ledgerId: 1, type: 'expense', start: start, end: end);
      final notes = await repo.totalsByNote(ledgerId: 1, start: start, end: end);
      final series = await repo.totalsByMonth(ledgerId: 1, year: 2026, type: 'expense');
      final yearSeries = await repo.totalsByYearSeries(ledgerId: 1, type: 'expense');
      final nw = await repo.getNetWorthBreakdown();
      final comp = await repo.getAssetCompositionByType();
      // 无账户 → 空
      final trend = await repo.getNetWorthTrendSeries(
          startDate: start, endDate: end, ratesToBase: {'CNY': 1.0});
      // HARDENING: 全部安全。
      expect([i, e, mi, me, yi, ye], everyElement(0.0));
      expect(cats, isEmpty);
      expect(days.length, 31, reason: 'HARDENING: totalsByDay 仍补全区间(31 天)');
      expect(days.every((d) => d.total == 0.0), isTrue);
      expect(accs, isEmpty);
      expect(notes, isEmpty);
      expect(series.length, 12, reason: 'HARDENING: 12 个月序列全 0');
      expect(series.every((s) => s.total == 0.0), isTrue);
      expect(yearSeries, isEmpty);
      expect(nw, (totalAssets: 0.0, totalLiabilities: 0.0, netWorth: 0.0));
      expect(comp, isEmpty);
      expect(trend, isEmpty, reason: 'HARDENING: 无账户 → 趋势空列表(非异常)');
    });

    test('K2 单笔:所有入口给出同一个数', () async {
      await seedLedger();
      final cat = await repo.createCategory(name: 'K2', kind: 'expense');
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 42.42,
          categoryId: cat, happenedAt: DateTime(2026, 7, 15));
      final (_, rangeE) = await repo.totalsInRange(
          ledgerId: 1, start: DateTime(2026, 7, 1), end: DateTime(2026, 8, 1));
      final (_, monthE) =
          await repo.monthlyTotals(ledgerId: 1, month: DateTime(2026, 7, 1));
      final (_, yearE) = await repo.yearlyTotals(ledgerId: 1, year: 2026);
      final cats = await repo.totalsByCategory(ledgerId: 1, type: 'expense',
          start: DateTime(2026, 7, 1), end: DateTime(2026, 8, 1));
      final series =
          await repo.totalsByMonth(ledgerId: 1, year: 2026, type: 'expense');
      final ySeries = await repo.totalsByYearSeries(ledgerId: 1, type: 'expense');
      expect(rangeE, closeTo(42.42, 1e-9));
      expect(monthE, closeTo(42.42, 1e-9));
      expect(yearE, closeTo(42.42, 1e-9));
      expect(cats.single.total, closeTo(42.42, 1e-9));
      expect(series.firstWhere((s) => s.total != 0).total, closeTo(42.42, 1e-9));
      expect(ySeries.single.total, closeTo(42.42, 1e-9));
    });

    test('K3 1000 笔跨 12 个月:月/年/全期入口三者可对账', () async {
      await seedLedger();
      final items = [
        for (var i = 0; i < 1000; i++)
          TransactionsCompanion.insert(
              ledgerId: 1,
              type: i % 3 == 0 ? 'income' : 'expense',
              amount: 1.0 + (i % 7),
              happenedAt: Value(DateTime(2026, (i % 12) + 1, (i % 27) + 1)),
              syncId: Value('AGG-$i')),
      ];
      await repo.insertTransactionsBatch(items);
      final all = await repo.getTransactionsByLedger(1);
      var expectInc = 0.0, expectExp = 0.0;
      for (final t in all) {
        final v = t.nativeAmount ?? t.amount;
        if (t.type == 'income') expectInc += v;
        if (t.type == 'expense') expectExp += v;
      }
      final (ri, re) = await repo.totalsInRange(
          ledgerId: 1, start: DateTime(2026, 1, 1), end: DateTime(2027, 1, 1));
      final (yi, ye) = await repo.yearlyTotals(ledgerId: 1, year: 2026);
      final series = await repo.totalsByMonth(ledgerId: 1, year: 2026, type: 'expense');
      final ySeries = await repo.totalsByYearSeries(ledgerId: 1, type: 'expense');
      final seriesSum = series.fold<double>(0, (a, b) => a + b.total);
      final ySeriesSum = ySeries.fold<double>(0, (a, b) => a + b.total);
      // HARDENING: 四条路径(区间/年/月序列/年序列)对账一致。
      expect(all.length, 1000);
      expect(ri, closeTo(expectInc, 1e-9));
      expect(re, closeTo(expectExp, 1e-9));
      expect(yi, closeTo(expectInc, 1e-9));
      expect(ye, closeTo(expectExp, 1e-9));
      expect(seriesSum, closeTo(expectExp, 1e-9),
          reason: 'HARDENING: 月序列合计 == 年支出');
      expect(ySeriesSum, closeTo(expectExp, 1e-9),
          reason: 'HARDENING: 年序列合计 == 年支出');
      expect(series.length, 12);
      // 分类/账户/日聚合加总也对得上
      final cats = await repo.totalsByCategory(ledgerId: 1, type: 'expense',
          start: DateTime(2026, 1, 1), end: DateTime(2027, 1, 1));
      final catSum = cats.fold<double>(0, (a, b) => a + b.total);
      expect(catSum, closeTo(expectExp, 1e-9),
          reason: 'HARDENING: 分类合计 == 年支出');
    });

    test('K4 超长区间(10 年)日序列补齐:totalsByDay 与 totalsByMonth 一致',
        () async {
      await seedLedger();
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 1,
          happenedAt: DateTime(2016, 3, 1));
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 2,
          happenedAt: DateTime(2026, 3, 1));
      final days = await repo.totalsByDay(ledgerId: 1, type: 'expense',
          start: DateTime(2016, 1, 1), end: DateTime(2027, 1, 1));
      final sum = days.fold<double>(0, (a, b) => a + b.total);
      // HARDENING: 日序列按日历日补齐(DST 无关,因用 DateTime(y,m,d) 递推),
      // 总计 = 3;天数 = 2016-01-01..2026-12-31。
      expect(sum, 3.0);
      expect(days.first.day, DateTime(2016, 1, 1));
      expect(days.last.day, DateTime(2026, 12, 31));
      expect(days.length, 4018,
          reason: 'HARDENING: 10 年 = 4018 天(含 2 个闰年日)');
    });

    test('K5 分类统计含 null 分类(未分类)与共享 override 分类并行', () async {
      await seedLedger();
      final cat = await repo.createCategory(name: 'K5C', kind: 'expense');
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 10,
          categoryId: cat, happenedAt: DateTime(2026, 7, 5));
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 20,
          happenedAt: DateTime(2026, 7, 6)); // 未分类
      // 共享 override 分类
      await db.customStatement("UPDATE ledgers SET sync_id='LK' WHERE id=1");
      await db.into(db.sharedLedgerCategories).insert(
          SharedLedgerCategoriesCompanion.insert(
              ledgerSyncId: 'LK', syncId: 'SC-1', name: '共享分类',
              kind: 'expense', updatedAt: DateTime(2026, 7, 5)));
      final txId = await repo.addTransaction(ledgerId: 1, type: 'expense',
          amount: 30, happenedAt: DateTime(2026, 7, 7),
          categorySyncIdOverride: 'SC-1');
      expect(txId, greaterThan(0));

      final cats = await repo.totalsByCategory(ledgerId: 1, type: 'expense',
          start: DateTime(2026, 7, 1), end: DateTime(2026, 8, 1));
      final sum = cats.fold<double>(0, (a, b) => a + b.total);
      final unclassified =
          cats.firstWhere((c) => c.name == '未分类', orElse: () => (id: null, name: '', icon: null, total: 0.0));
      final shared =
          cats.firstWhere((c) => c.name == '共享分类', orElse: () => (id: null, name: '', icon: null, total: 0.0));

      // ADVERSE FINDING: totalsByCategory 的共享 override 兜底**重复计数**。
      // 主查询(local_statistics_repository.dart:34-51)的 GROUP BY 只按
      // c.id/c.name/c.icon 分组,不过滤 category_sync_id_override 的行 →
      // override 行(category_id IS NULL)落进"未分类"桶(20+30=50);
      // 随后 override 补充查询(:67-84)又把同一批行按 30 加一次到 synthetic id。
      // 同一笔 ¥30 在总额里出现两次(合计 90 ≠ 实际 60)。
      expect(sum, 60.0,
          reason: 'ADVERSE FINDING: totalsByCategory 合计 $sum ≠ 实际 60 —— '
              'override 行被同时计入"未分类"(${unclassified.total})和'
              '"共享分类"(${shared.total}),双计 ¥30');
      expect(shared.total, 30.0,
          reason: 'ADVERSE FINDING: 共享分类本身 30 正确,但它没从"未分类"里扣除');

      // 对照:hierarchy 入口(另一个 SQL,GROUP BY 带上 override 列)算对了。
      final hier = await repo.totalsByCategoryWithHierarchy(
          ledgerId: 1, type: 'expense',
          start: DateTime(2026, 7, 1), end: DateTime(2026, 8, 1));
      final hSum = hier.fold<double>(0, (a, b) => a + b.total);
      expect(hSum, 60.0,
          reason: 'HARDENING: totalsByCategoryWithHierarchy 合计 60(同数据另一入口正确)'
              ' —— 两入口对同一账本给出 90 vs 60');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // L. 预算用量
  // ══════════════════════════════════════════════════════════════════════

  group('L. 预算用量边界', () {
    test('L1 period=weekly/yearly 被完全忽略,一律按账本月周期算', () async {
      await seedLedger();
      final weekly = await repo.createBudget(
          ledgerId: 1, type: 'total', amount: 1000, period: 'weekly');
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 40,
          happenedAt: DateTime(2026, 7, 3));
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 60,
          happenedAt: DateTime(2026, 7, 20));
      final usage = await repo.getBudgetUsage(weekly, DateTime(2026, 7, 15));
      // C3 修复:getBudgetUsage 现在读 budget.period —— weekly 按包含查询日的
      // 自然周(2026-07-13 周一 ~ 2026-07-20 周一)统计。7/3 与 7/20 都不在
      // 该周内 → used 0。原断言 expect(usage.used, 40.0) 编码的是修复前缺陷
      // (period 被忽略、整月 100 全算本期)。
      expect(usage.used, 0.0,
          reason: 'C3 修复: period=weekly 按自然周统计;查询日 7/15 所在周'
              '(7/13-7/19)无支出 → used 0(不再把整月当本期)');

      // 对照:查询日落在 7/3 那一周时,只有 40 计入
      final weekOfJul3 = await repo.getBudgetUsage(weekly, DateTime(2026, 7, 3));
      expect(weekOfJul3.used, 40.0,
          reason: 'C3 修复: 7/3 所在周仅计入 7/3 的 ¥40');

      // yearly 按账本年周期(自然年)统计
      final yearly = await repo.createBudget(
          ledgerId: 1, type: 'total', amount: 10000, period: 'yearly');
      final yUsage = await repo.getBudgetUsage(yearly, DateTime(2026, 7, 15));
      expect(yUsage.used, 100.0,
          reason: 'C3 修复: period=yearly 按年度统计 → 40 + 60 = 100');
    });

    test('L2 period 非法值 / startDay 越界:原样落库,无校验;预算跟随账本'
        'monthStartDay 而非 startDay', () async {
      await seedLedger();
      final inv = await repo.createBudget(
          ledgerId: 1, type: 'total', amount: 100, period: 'bogus', startDay: 99);
      final row = (await repo.getAllBudgets(1)).firstWhere((b) => b.id == inv);
      expect(row.period, 'bogus',
          reason: 'HARDENING: period 无枚举校验(任意字符串可落库)');
      expect(row.startDay, 99,
          reason: 'HARDENING: startDay 无范围校验(99 原样落库;schema 注释说 1-31)');

      // startDay 也不参与计算,预算周期始终跟账本 monthStartDay
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 50,
          happenedAt: DateTime(2026, 7, 3)); // 月初
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 70,
          happenedAt: DateTime(2026, 7, 25)); // 月末
      final u = await repo.getBudgetUsage(inv, DateTime(2026, 7, 15));
      expect(u.used, 120.0,
          reason: 'HARDENING: startDay=99 被忽略,按自然月 [7/1,8/1) 统计 120');
    });

    test('L3 amount = 0 / 负数:rate 恒 0(不除零),remaining 为负但不报错',
        () async {
      await seedLedger();
      final zero = await repo.createBudget(ledgerId: 1, type: 'total', amount: 0);
      final neg = await repo.createBudget(ledgerId: 1, type: 'total', amount: -100);
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 100,
          happenedAt: DateTime(2026, 7, 5));

      final z = await repo.getBudgetUsage(zero, DateTime(2026, 7, 5));
      final n = await repo.getBudgetUsage(neg, DateTime(2026, 7, 5));
      // HARDENING: BudgetUsage.rate = budget > 0 ? used/budget : 0(:11-13)
      // → 0 与负都安全(不除零)。
      expect(z.rate, 0.0, reason: 'HARDENING: amount=0 → rate 0(不除零)');
      expect(z.status, 'normal',
          reason: 'HARDENING: amount=0 时状态 normal —— 即"预算 0 元已花 100 元"'
              '在 UI 上显示为健康');
      expect(n.rate, 0.0, reason: 'HARDENING: amount<0 → rate 0');
      expect(z.remaining, -100.0, reason: 'HARDENING: remaining 可为负');
    });

    test('L4 getCategoryBudgetUsages 跳过已删分类的预算(预算行成为静默孤儿)',
        () async {
      await seedLedger();
      final cat = await repo.createCategory(name: 'L4C', kind: 'expense');
      final bid = await repo.createBudget(
          ledgerId: 1, type: 'category', categoryId: cat, amount: 50);
      await repo.deleteCategory(cat);
      final usages = await repo.getCategoryBudgetUsages(1, DateTime(2026, 7, 5));
      final rows = await repo.getAllBudgets(1);
      expect(usages.where((u) => u.budgetId == bid), isEmpty,
          reason: 'HARDENING: 已删分类的预算在 UI 列表里消失');
      // C3 修复:deleteCategory 现在级联删除指向该分类的分类预算 —— 不再有
      // 悬挂的预算行("留着但看不到也删不掉")。原断言 expect(isNotEmpty)
      // 编码的正是修复前的缺陷。
      expect(rows.where((b) => b.id == bid), isEmpty,
          reason: 'C3 修复: 分类删除级联清掉分类预算,无静默孤儿');
    });

    test('L5 总预算统计所有支出,分类预算含子分类:两个口径可对账', () async {
      await seedLedger();
      final parent = await repo.createCategory(name: 'L5P', kind: 'expense');
      final child = await repo.createSubCategory(
          parentId: parent, name: 'L5C', kind: 'expense');
      final parentBudget = await repo.createBudget(
          ledgerId: 1, type: 'category', categoryId: parent, amount: 500);
      final childBudget = await repo.createBudget(
          ledgerId: 1, type: 'category', categoryId: child, amount: 500);
      final totalBudget = await repo.createBudget(
          ledgerId: 1, type: 'total', amount: 1000);
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 70,
          categoryId: parent, happenedAt: DateTime(2026, 7, 10));
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 30,
          categoryId: child, happenedAt: DateTime(2026, 7, 11));
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 5,
          happenedAt: DateTime(2026, 7, 12)); // 未分类

      final pu = await repo.getBudgetUsage(parentBudget, DateTime(2026, 7, 10));
      final cu = await repo.getBudgetUsage(childBudget, DateTime(2026, 7, 10));
      final tu = await repo.getBudgetUsage(totalBudget, DateTime(2026, 7, 10));
      expect(pu.used, 100.0,
          reason: 'HARDENING: 父分类预算含自身 + 子分类(70+30)');
      expect(cu.used, 30.0, reason: 'HARDENING: 子分类预算只算自身');
      expect(tu.used, 105.0, reason: 'HARDENING: 总预算含未分类(100+5)');
    });

    test('L6 预算周期跟随账本 monthStartDay(非自然月)', () async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency, month_start_day) VALUES (1, 'L', 'CNY', 10)");
      final bid = await repo.createBudget(ledgerId: 1, type: 'total', amount: 1000);
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 11,
          happenedAt: DateTime(2026, 7, 5)); // 属 6 月周期
      await repo.addTransaction(ledgerId: 1, type: 'expense', amount: 22,
          happenedAt: DateTime(2026, 7, 15)); // 属 7 月周期
      final july = await repo.getBudgetUsage(bid, DateTime(2026, 7, 15));
      final june = await repo.getBudgetUsage(bid, DateTime(2026, 7, 5));
      // HARDENING: 周期 [7/10, 8/10) / [6/10, 7/10)。
      expect(july.used, 22.0, reason: 'HARDENING: 7 月周期只含 7/15 那笔');
      expect(june.used, 11.0, reason: 'HARDENING: 6 月周期只含 7/5 那笔');
    });

    test('L7 getBudgetOverview.daysRemaining 用 now(而非传入 month):'
        '历史月份查询给出错误剩余天数', () async {
      await seedLedger();
      await repo.createBudget(ledgerId: 1, type: 'total', amount: 3000);
      // 查 2020 年的预算概览(历史回看)
      final month = DateTime(2020, 6, 15);
      final ov = await repo.getBudgetOverview(1, month);
      // C3 修复:daysRemaining 绑定传入的 month(该月周期结束日 − month)。
      // 2020-06-15 的自然月周期结束于 2020-07-01 → 16 天。原断言把它与
      // "当前周期剩余天数"比较,编码的正是修复前缺陷(参数与语义脱钩)。
      final expectedDays = DateTime(2020, 7, 1).difference(month).inDays;
      expect(ov.daysRemaining, expectedDays,
          reason: 'C3 修复: getBudgetOverview(month=2020-06-15) 的 daysRemaining '
              '按该月周期算(${ov.daysRemaining} 天),不再用当前周期')
      ;
      // dailyAvailable 随之正确(剩余额度 ÷ 该周期剩余天数)
      expect(ov.dailyAvailable, closeTo(3000.0 / expectedDays, 1e-9),
          reason: 'C3 修复: dailyAvailable = remaining / 该周期剩余天数');
    });
  });
}

/// 与 lib/utils/month_range.dart periodContaining 同构(仅用于期望值推导)。
({DateTime start, DateTime end}) _periodContaining(DateTime date, int startDay) {
  final d = startDay < 1 ? 1 : (startDay > 28 ? 28 : startDay);
  final label = date.day >= d
      ? DateTime(date.year, date.month, 1)
      : DateTime(date.year, date.month - 1, 1);
  return (
    start: DateTime(label.year, label.month, d),
    end: DateTime(label.year, label.month + 1, d),
  );
}
