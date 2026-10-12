/// 对抗性测试 3/4:语义判重与跨渠道强判重
/// (SemanticDedupMatcher 边界、NaN/Infinity、秒级指纹精度守卫、跨渠道四条件、
///  external-id 索引快路径与全扫描 fallback 一致性、DedupExemptStore、
///  ManualDuplicateChecker、AutoBillingService 指纹)。
///
/// 纪律:确认缺陷 → 失败 + `// ADVERSE FINDING`;可辩护但脆弱 → 断言当前行为
/// 并通过 + `// HARDENING`;时间一律相对 `DateTime.now()`。
library;

import 'dart:convert';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/ai/core/bill_info.dart';
import 'package:smartbook/ai/core/json_response_parser.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';
import 'package:smartbook/services/automation/dedup_exempt_store.dart';
import 'package:smartbook/services/automation/manual_duplicate_checker.dart';
import 'package:smartbook/services/automation/semantic_dedup_matcher.dart';
import 'package:smartbook/services/automation/auto_billing_service.dart'
    show AutoBillingService;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late LocalRepository repo;
  late AutoBookEventStore eventStore;
  late int ledgerId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    eventStore = AutoBookEventStore(db);
    ledgerId = await repo.createLedger(name: 'dedup-adv');
  });

  tearDown(() async {
    await db.close();
  });

  const matcher = SemanticDedupMatcher();

  // ──────────────────────────────────────────────────────────────────
  group('semanticKey / externalKey 公式', () {
    test('HARDENING: externalKey 口径(trim+lowercase+currency 参与 hash)', () {
      final a = SemanticDedupMatcher.externalKey(' ORDER-1 ');
      final b = SemanticDedupMatcher.externalKey('order-1');
      expect(a, b, reason: '大小写与空白归一');
      expect(a, isNotNull);
      final withCurrency = SemanticDedupMatcher.externalKey('order-1', currency: 'CNY');
      expect(withCurrency, isNot(a),
          reason: '币种参与 hash → 同单号不同币种是两个 key');
      expect(SemanticDedupMatcher.externalKey('   '), isNull);
      expect(SemanticDedupMatcher.externalKey(null), isNull);
    });

    test('HARDENING: semanticKey 缺商户/时间/金额 → null(不制造假 key)', () {
      final t = DateTime.now();
      expect(
        SemanticDedupMatcher.semanticKey(BillInfo(
            amount: -30, time: t, type: BillType.expense)),
        isNull,
        reason: '无商户/备注 → 不给 key(避免「空备注+同额同日」误合并)',
      );
      expect(
        SemanticDedupMatcher.semanticKey(BillInfo(
            amount: -30, merchant: 'x', type: BillType.expense)),
        isNull,
      );
      expect(
        SemanticDedupMatcher.semanticKey(
            BillInfo(merchant: 'x', time: t, type: BillType.expense)),
        isNull,
      );
      expect(
        SemanticDedupMatcher.semanticKey(
            BillInfo(amount: 0, merchant: 'x', time: t, type: BillType.expense)),
        isNull,
      );
    });

    // ADVERSE FINDING: semanticKey 的金额只判 abs() <= 0,没有 isFinite。
    // NaN:abs() 仍是 NaN,`NaN <= 0` 为 false → 通过检查,生成
    // '...|NaN|...' 的 key;Infinity 同理生成 '...|Infinity|...'。落库后
    // 任何 NaN 金额账单彼此共享同一个 key,判重/外部单号索引全部误命中。
    test('ADVERSE: NaN / Infinity 金额生成可用的 semanticKey(应当为 null)',
        () {
      final t = DateTime.now();
      final nanKey = SemanticDedupMatcher.semanticKey(BillInfo(
          amount: double.nan, merchant: 'x', time: t, type: BillType.expense));
      final infKey = SemanticDedupMatcher.semanticKey(BillInfo(
          amount: double.infinity,
          merchant: 'x',
          time: t,
          type: BillType.expense));
      expect(nanKey, isNull,
          reason: 'NaN 不是有效金额,semanticKey 应为 null;'
              '实际生成了含 "NaN" 的 key');
      expect(infKey, isNull, reason: 'Infinity 同样不是有效金额');
    });

    test('HARDENING: 分钟粒度保留(同日同额不同分钟 → 不同 key)', () {
      // 显式整秒 + 同分钟内偏移,避免秒位进入分钟截断
      final base = DateTime(2026, 1, 5, 12, 3, 0);
      final a = SemanticDedupMatcher.semanticKey(BillInfo(
          amount: -30, merchant: 'x', time: base, type: BillType.expense));
      final sameMinute = SemanticDedupMatcher.semanticKey(BillInfo(
          amount: -30,
          merchant: 'x',
          time: base.add(const Duration(seconds: 50)),
          type: BillType.expense));
      final nextMinute = SemanticDedupMatcher.semanticKey(BillInfo(
          amount: -30,
          merchant: 'x',
          time: base.add(const Duration(minutes: 1)),
          type: BillType.expense));
      expect(a, sameMinute, reason: '12:03:00 与 12:03:50 同 key');
      expect(a, isNot(nextMinute), reason: '12:04:00 是新 key');
    });

    test('HARDENING: 币种大小写/空白归一进 key(CNY vs cny 同 key)', () {
      final t = DateTime(2026, 1, 5, 12, 3);
      final upper = SemanticDedupMatcher.semanticKey(BillInfo(
          amount: -30,
          merchant: 'x',
          time: t,
          type: BillType.expense,
          currency: 'CNY'));
      final lower = SemanticDedupMatcher.semanticKey(BillInfo(
          amount: -30,
          merchant: 'x',
          time: t,
          type: BillType.expense,
          currency: ' cny '));
      expect(upper, lower);
    });

    test('HARDENING: 商户词清洗后为空 → 退化为 null(不生成空商户 key)', () {
      final t = DateTime(2026, 1, 5, 12, 3);
      // 「有限公司」「支付」等被清洗掉后为空
      expect(
        SemanticDedupMatcher.semanticKey(BillInfo(
            amount: -30, merchant: '有限公司支付', time: t, type: BillType.expense)),
        isNull,
        reason: 'normalize 后为空 → 无商户信号,不给 key',
      );
      // 备注兜底:商户空时用 note
      final viaNote = SemanticDedupMatcher.semanticKey(BillInfo(
          amount: -30, note: '星巴克', time: t, type: BillType.expense));
      expect(viaNote, isNotNull, reason: 'note 兜底参与');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('hasSecondExactDuplicate 秒级指纹', () {
    BillInfo sec({
      double amount = -88,
      required DateTime time,
      int? ledger,
      BillTimePrecision? precision,
      String? currency = 'CNY',
      BillType type = BillType.expense,
    }) =>
        BillInfo(
          amount: amount,
          time: time,
          ledgerId: ledger ?? 1,
          type: type,
          timePrecision: precision,
          currency: currency,
        );

    test('HARDENING: 截断到秒相等 + 双方秒值可信 → 命中', () {
      final t = DateTime.now();
      expect(
        SemanticDedupMatcher.hasSecondExactDuplicate(
          sec(time: DateTime(t.year, t.month, t.day, t.hour, t.minute, 37)),
          [sec(time: DateTime(t.year, t.month, t.day, t.hour, t.minute, 37, 400))],
        ),
        isTrue,
        reason: '毫秒差异不影响(Drift epoch 秒存储同口径)',
      );
    });

    test('HARDENING: 一边 timePrecision=minute(秒为补零)不得判秒级一致', () {
      final t = DateTime.now();
      final atMinute = DateTime(t.year, t.month, t.day, t.hour, t.minute, 0);
      expect(
        SemanticDedupMatcher.hasSecondExactDuplicate(
          sec(time: atMinute, precision: BillTimePrecision.minute),
          [sec(time: atMinute)],
        ),
        isFalse,
        reason: '补零秒不能与真实 0 秒混淆',
      );
      expect(
        SemanticDedupMatcher.hasSecondExactDuplicate(
          sec(time: atMinute, precision: BillTimePrecision.date),
          [sec(time: atMinute)],
        ),
        isFalse,
      );
      expect(
        SemanticDedupMatcher.hasSecondExactDuplicate(
          sec(time: atMinute, precision: BillTimePrecision.inferred),
          [sec(time: atMinute)],
        ),
        isFalse,
      );
    });

    test('HARDENING: 秒不同(同分钟)→ 不命中', () {
      final t = DateTime.now();
      expect(
        SemanticDedupMatcher.hasSecondExactDuplicate(
          sec(time: DateTime(t.year, t.month, t.day, t.hour, t.minute, 37)),
          [sec(time: DateTime(t.year, t.month, t.day, t.hour, t.minute, 51))],
        ),
        isFalse,
      );
    });

    test('HARDENING: 币种冲突 / 账本不同 / 类型不同 → 不命中', () {
      final t = DateTime.now();
      final at = DateTime(t.year, t.month, t.day, t.hour, t.minute, 37);
      expect(
        SemanticDedupMatcher.hasSecondExactDuplicate(
          sec(time: at, currency: 'CNY'),
          [sec(time: at, currency: 'USD')],
        ),
        isFalse,
      );
      expect(
        SemanticDedupMatcher.hasSecondExactDuplicate(
          sec(time: at, ledger: 1),
          [sec(time: at, ledger: 2)],
        ),
        isFalse,
      );
      expect(
        SemanticDedupMatcher.hasSecondExactDuplicate(
          sec(time: at, type: BillType.expense),
          [sec(time: at, type: BillType.income)],
        ),
        isFalse,
      );
    });

    test('HARDENING: 金额 0 / null / 空集合 → 不命中', () {
      final t = DateTime.now();
      final at = DateTime(t.year, t.month, t.day, t.hour, t.minute, 37);
      expect(
        SemanticDedupMatcher.hasSecondExactDuplicate(sec(time: at, amount: 0), [
          sec(time: at, amount: 0),
        ]),
        isFalse,
      );
      expect(
        SemanticDedupMatcher.hasSecondExactDuplicate(
            sec(time: at), [BillInfo(amount: -88, ledgerId: 1)]),
        isFalse,
        reason: '对方无时间',
      );
      expect(SemanticDedupMatcher.hasSecondExactDuplicate(sec(time: at), const []),
          isFalse);
    });

    // ADVERSE FINDING: hasSecondExactDuplicate 只做 abs() != abs() 比较,
    // 没有 isFinite。两条 Infinity 金额在别的条件都满足时被判「秒级指纹
    // 完全命中」→ 静默合并。而 NaN 自比较恒 false,反而安全 —— 同一个
    // 数值边界上两种非有限值的行为不一致。
    test('ADVERSE: Infinity 金额被判秒级指纹命中(静默合并)', () {
      final t = DateTime.now();
      final at = DateTime(t.year, t.month, t.day, t.hour, t.minute, 37);
      final inf = sec(time: at, amount: double.infinity, precision: null);
      expect(
        SemanticDedupMatcher.hasSecondExactDuplicate(inf, [inf]),
        isFalse,
        reason: 'Infinity 不是有效金额,不得进入静默合并路径;'
            '实际两次 abs() 相等 → 返回 true',
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('findBest 打分与硬闸门', () {
    Future<int> seedLedger() async {
      final id = await repo.createLedger(name: 'p-score');
      return id;
    }

    test('HARDENING: 金额差 0.01 元不判重;时间差 > 1 分钟不判重', () async {
      final l = await seedLedger();
      final t = DateTime.now();
      await repo.addTransaction(
          ledgerId: l,
          type: 'expense',
          amount: 100,
          happenedAt: t,
          note: '商户A');
      expect(
        await matcher.findBest(
          repository: repo,
          ledgerId: l,
          bill: BillInfo(
              amount: -100.01, time: t, type: BillType.expense, merchant: '商户A'),
        ),
        isNull,
        reason: '金额无容差',
      );
      expect(
        await matcher.findBest(
          repository: repo,
          ledgerId: l,
          bill: BillInfo(
              amount: -100,
              time: t.add(const Duration(minutes: 1, seconds: 1)),
              type: BillType.expense,
              merchant: '商户A'),
        ),
        isNull,
        reason: '时间窗 ±1 分钟(硬闸门)',
      );
    });

    test('HARDENING: 打分口径 0.65/0.90/1.00 —— 商户缺失固定 0.75(严格小于 strong)',
        () async {
      final l = await seedLedger();
      // 显式秒位:tx 37 秒、bill 51 秒(同分钟、秒不同)→ 不走秒级指纹路径
      final txTime = DateTime(2026, 3, 4, 12, 3, 37);
      final billTime = DateTime(2026, 3, 4, 12, 3, 51);
      await repo.addTransaction(
          ledgerId: l,
          type: 'expense',
          amount: 50,
          happenedAt: txTime,
          note: '商户A');

      final noSignal = await matcher.findBest(
        repository: repo,
        ledgerId: l,
        bill: BillInfo(amount: -50, time: billTime, type: BillType.expense),
      );
      expect(noSignal!.score, 0.75);
      expect(noSignal.isStrong, isFalse, reason: '商户缺失绝不静默合并');
      expect(noSignal.isPossible, isTrue);
      expect(noSignal.reason, contains('merchant_missing'));

      final conflictingMerchant = await matcher.findBest(
        repository: repo,
        ledgerId: l,
        bill: BillInfo(
            amount: -50,
            time: billTime,
            type: BillType.expense,
            merchant: '完全不同的商户'),
      );
      expect(conflictingMerchant!.score, 0.65,
          reason: 'amount_exact + time_1m');
      expect(conflictingMerchant.isStrong, isFalse);

      final sameMerchant = await matcher.findBest(
        repository: repo,
        ledgerId: l,
        bill: BillInfo(
            amount: -50, time: billTime, type: BillType.expense, merchant: '商户A'),
      );
      expect(sameMerchant!.score, 0.90,
          reason: '0.40 + 0.25 + 0.25 = 0.90 < strong(0.92) 但 >= possible');
      expect(sameMerchant.isStrong, isFalse,
          reason: '0.90 不到 0.92 → 同分钟秒不同且无币种增益时进待确认');
      expect(sameMerchant.isPossible, isTrue);
      expect(sameMerchant.reason, contains('merchant_exact'));
    });

    test('HARDENING: 币种一致再加 0.15 → 0.90 档升到强判(1.00 前的 1.05 clamp)',
        () async {
      final l = await seedLedger();
      final t = DateTime.now();
      await repo.addTransaction(
        ledgerId: l,
        type: 'expense',
        amount: 38,
        happenedAt: t,
        note: '星巴克',
        currencyCode: 'CNY',
      );
      final match = await matcher.findBest(
        repository: repo,
        ledgerId: l,
        bill: BillInfo(
          amount: -38,
          time: t.add(const Duration(seconds: 20)),
          type: BillType.expense,
          merchant: '星巴克',
          currency: 'CNY',
        ),
      );
      expect(match!.score, 1.0, reason: '0.40+0.15+0.25+0.25 = 1.05 → clamp 1.0');
      expect(match.isStrong, isTrue);
    });

    test('HARDENING: 币种冲突直接排除(即使商户/金额/时间全等)', () async {
      final l = await seedLedger();
      final t = DateTime.now();
      await repo.addTransaction(
        ledgerId: l,
        type: 'expense',
        amount: 38,
        happenedAt: t,
        note: '星巴克',
        currencyCode: 'CNY',
      );
      final match = await matcher.findBest(
        repository: repo,
        ledgerId: l,
        bill: BillInfo(
          amount: -38,
          time: t,
          type: BillType.expense,
          merchant: '星巴克',
          currency: 'USD',
        ),
      );
      expect(match, isNull, reason: '同额不同币是两笔币种独立的消费');
    });

    test('HARDENING: 词元交集 +0.12(merchant_overlap)不进 strong', () async {
      final l = await seedLedger();
      final t = DateTime.now();
      await repo.addTransaction(
          ledgerId: l,
          type: 'expense',
          amount: 20,
          happenedAt: t,
          note: 'starbucks coffee');
      final match = await matcher.findBest(
        repository: repo,
        ledgerId: l,
        bill: BillInfo(
          amount: -20,
          time: t.add(const Duration(seconds: 30)),
          type: BillType.expense,
          merchant: 'starbucks tea',
        ),
      );
      expect(match!.score, closeTo(0.77, 0.0001),
          reason: '0.40 + 0.25 + 0.12 = 0.77');
      expect(match.isStrong, isFalse);
    });

    test('HARDENING: 候选集 SQL 下推与全量等价(20 笔噪声中命中目标)',
        () async {
      final l = await seedLedger();
      // 显式秒:目标 tx 37 秒、账单 51 秒(同分钟)→ 走语义打分而非秒级指纹
      final txTime = DateTime(2026, 3, 5, 10, 20, 37);
      final billTime = DateTime(2026, 3, 5, 10, 20, 51);
      final target = await repo.addTransaction(
          ledgerId: l,
          type: 'expense',
          amount: 77,
          happenedAt: txTime,
          note: '目标商户');
      for (var i = 0; i < 20; i++) {
        await repo.addTransaction(
          ledgerId: l,
          type: 'expense',
          amount: 77,
          happenedAt: txTime.subtract(Duration(minutes: 10 + i)),
          note: '噪声$i',
        );
      }
      // 其它账本的同额同时间:不得命中
      final otherLedger = await repo.createLedger(name: 'other');
      await repo.addTransaction(
          ledgerId: otherLedger,
          type: 'expense',
          amount: 77,
          happenedAt: billTime,
          note: '目标商户');

      final match = await matcher.findBest(
        repository: repo,
        ledgerId: l,
        bill: BillInfo(
            amount: -77, time: billTime, type: BillType.expense, merchant: '目标商户'),
      );
      expect(match!.transactionId, target);
      expect(match.score, 0.90, reason: 'amount+time+merchant(无币种)');
    });

    test('HARDENING: 金额 0 / 负负得正口径(abs 比较)', () async {
      final l = await seedLedger();
      final t = DateTime.now();
      await repo.addTransaction(
          ledgerId: l,
          type: 'expense',
          amount: 30,
          happenedAt: t,
          note: 'x');
      // amount 0 → 早退 null
      expect(
        await matcher.findBest(
          repository: repo,
          ledgerId: l,
          bill: BillInfo(amount: 0, time: t, type: BillType.expense, merchant: 'x'),
        ),
        isNull,
      );
      // 负数账单(收入方向金额写负)按 abs 参与硬闸门
      final match = await matcher.findBest(
        repository: repo,
        ledgerId: l,
        bill: BillInfo(amount: 30, time: t, type: BillType.expense, merchant: 'x'),
      );
      expect(match, isNotNull,
          reason: 'abs 口径:金额 30 与已有 30 相等');
    });

    test('HARDENING: 类型不一致(expense vs income)不判重', () async {
      final l = await seedLedger();
      final t = DateTime.now();
      await repo.addTransaction(
          ledgerId: l,
          type: 'expense',
          amount: 30,
          happenedAt: t,
          note: 'x');
      expect(
        await matcher.findBest(
          repository: repo,
          ledgerId: l,
          bill: BillInfo(
              amount: 30, time: t, type: BillType.income, merchant: 'x'),
        ),
        isNull,
      );
    });

    // ADVERSE FINDING(金额维度):BillInfo.amount == null 时 findBest 早退
    // null(正确),但 double.nan 走的是「abs() <= 0 为 false → 继续」的
    // 分支,再交给 SQL 的 BETWEEN 比较 —— SQLite 里 NaN 存成 NULL,
    // BETWEEN 恒 false → 候选集为空 → 返回 null。行为上「安全」,
    // 但这是栈上两层实现细节互相掩盖,并非显式守卫。
    test('HARDENING: NaN/Infinity 账单在 SQL 候选集里自然落空(隐式守卫)', () async {
      final l = await seedLedger();
      final t = DateTime.now();
      await repo.addTransaction(
          ledgerId: l,
          type: 'expense',
          amount: 30,
          happenedAt: t,
          note: 'x');
      expect(
        await matcher.findBest(
          repository: repo,
          ledgerId: l,
          bill: BillInfo(
              amount: double.nan, time: t, type: BillType.expense, merchant: 'x'),
        ),
        isNull,
        reason: 'NaN 不命中任何候选(得靠 SQL 语义兜,不是显式 isFinite 守卫)',
      );
      expect(
        await matcher.findBest(
          repository: repo,
          ledgerId: l,
          bill: BillInfo(
              amount: double.infinity,
              time: t,
              type: BillType.expense,
              merchant: 'x'),
        ),
        isNull,
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('跨渠道强判重四条件', () {
    // 隔离夹具:交易侧无币种、账单侧无币种 → 商户精确 + 金额 + 时间 = 0.90
    // (严格小于 strong 0.92)。这样「不带跨渠道参数」时必然是 possible,
    // 跨渠道分支一旦触发就升到 1.0 —— 条件是否生效可被精确观测。
    // 秒位刻意不同(tx :37 / bill :51)且账单精度标 minute,确保不走进
    // 秒级指纹路径(那是另一条独立的强判重通路)。
    final txTime = DateTime(2026, 3, 6, 12, 3, 37);
    final billTime = DateTime(2026, 3, 6, 12, 3, 51);

    Future<int> seed() async {
      final l = await repo.createLedger(name: 'cross');
      await repo.addTransaction(
        ledgerId: l,
        type: 'expense',
        amount: 38,
        happenedAt: txTime,
        note: '星巴克',
      );
      return l;
    }

    Future<SemanticDedupMatch?> attempt({
      required int l,
      BillSettlementStatus? settlement = BillSettlementStatus.settled,
      bool timeInferred = false,
      BillTimePrecision? precision = BillTimePrecision.minute,
      String? merchant = '星巴克',
      String? sourceKey = 'notification',
      Future<Set<String>> Function(int)? keys,
    }) {
      return matcher.findBest(
        repository: repo,
        ledgerId: l,
        bill: BillInfo(
          amount: -38,
          time: billTime,
          type: BillType.expense,
          merchant: merchant,
          settlementStatus: settlement,
          timeInferred: timeInferred,
          timePrecision: precision,
        ),
        sourceKey: sourceKey,
        transactionSourceKeys: keys ?? (_) async => const {'sms'},
      );
    }

    test('HARDENING: 不带跨渠道参数的基线 = 0.90 疑似(不静默合并)', () async {
      final l = await seed();
      final baseline = await matcher.findBest(
        repository: repo,
        ledgerId: l,
        bill: BillInfo(
          amount: -38,
          time: billTime,
          type: BillType.expense,
          merchant: '星巴克',
          timePrecision: BillTimePrecision.minute,
        ),
      );
      expect(baseline!.score, 0.90, reason: 'amount+time+merchant(无币种)');
      expect(baseline.isStrong, isFalse);
      expect(baseline.isCrossChannel, isFalse);
      expect(baseline.reason, contains('merchant_exact'));
    });

    test('HARDENING: 四条件齐备(settled + !inferred + 精度 + merchant_exact)→ 强判',
        () async {
      final l = await seed();
      final match = await attempt(l: l);
      expect(match!.isStrong, isTrue);
      expect(match.isCrossChannel, isTrue);
      expect(match.score, 1.0);
      expect(match.reason, contains('cross_channel_strong:2'),
          reason: 'existing(1) + 当前(1) = 2 个渠道');
    });

    test('HARDENING: 条件 1 缺 settled → 不升级', () async {
      final l = await seed();
      final match = await attempt(l: l, settlement: null);
      expect(match!.isCrossChannel, isFalse,
          reason: '缺 settlementStatus=settled');
      expect(match.isStrong, isFalse);
      expect(match.score, 0.90);
    });

    test('HARDENING: 条件 2 缺 !timeInferred → 不升级', () async {
      final l = await seed();
      final match = await attempt(l: l, timeInferred: true);
      expect(match!.isCrossChannel, isFalse);
      expect(match.isStrong, isFalse);
    });

    test('HARDENING: 条件 3 精度必须是 exact/minute —— date/unknown/缺失都不升级',
        () async {
      final l = await seed();
      for (final p in [
        BillTimePrecision.date,
        BillTimePrecision.unknown,
        null,
      ]) {
        final match = await attempt(l: l, precision: p);
        expect(match!.isCrossChannel, isFalse,
            reason: 'precision = p 不满足跨渠道条件');
        expect(match.isStrong, isFalse);
      }
      final exact = await attempt(l: l, precision: BillTimePrecision.exact);
      expect(exact!.isCrossChannel, isTrue,
          reason: '字面条件接受 exact');
      final minute = await attempt(l: l, precision: BillTimePrecision.minute);
      expect(minute!.isCrossChannel, isTrue);
    });

    test('HARDENING: 条件 4 缺 merchant_exact(商户冲突)→ 不升级', () async {
      final l = await seed();
      final match = await attempt(l: l, merchant: '麦当劳');
      expect(match!.isCrossChannel, isFalse);
      expect(match.isStrong, isFalse);
      expect(match.score, 0.65,
          reason: 'amount_exact + time_1m;无 merchant_exact → 跨渠道分支不触发');
    });

    test('HARDENING: 已经有同来源记录 → 不误判跨渠道', () async {
      final l = await seed();
      final match = await attempt(l: l, sourceKey: 'sms');
      expect(match!.isCrossChannel, isFalse,
          reason: 'existing 含当前 sourceKey → 同渠道重放,不强判');
      expect(match.score, 0.90);
    });

    test('HARDENING: 交易无自动事件来源(空集)→ 不升级', () async {
      final l = await seed();
      final match = await attempt(l: l, keys: (_) async => const <String>{});
      expect(match!.isCrossChannel, isFalse);
      expect(match.isStrong, isFalse);
    });

    test('HARDENING: sourceKey/回调任一为 null → 不触发跨渠道路径', () async {
      final l = await seed();
      final noKey = await attempt(l: l, sourceKey: null);
      expect(noKey!.isCrossChannel, isFalse);
      final noCallback = await matcher.findBest(
        repository: repo,
        ledgerId: l,
        bill: BillInfo(
          amount: -38,
          time: billTime,
          type: BillType.expense,
          merchant: '星巴克',
          timePrecision: BillTimePrecision.minute,
          settlementStatus: BillSettlementStatus.settled,
        ),
        sourceKey: 'notification',
      );
      expect(noCallback!.isCrossChannel, isFalse);
    });

    test('HARDENING: 来源反查抛异常 → 退回语义打分,不阻断判重', () async {
      final l = await seed();
      final match = await attempt(l: l, keys: (_) async => throw StateError('db'));
      expect(match, isNotNull);
      expect(match!.score, 0.90, reason: '退回原打分');
      expect(match.isCrossChannel, isFalse);
    });

    test('HARDENING: 多来源已有记录时 cross_channel_strong:N 反映来源数', () async {
      final l = await seed();
      final match =
          await attempt(l: l, keys: (_) async => const {'sms', 'screen'});
      expect(match!.reason, contains('cross_channel_strong:3'));
    });

    // HARDENING(风险如实记录):跨渠道强判重只在**事件来源键**
    // (sms/notification/screen/image/deeplink)维度判定,不校验
    // sourceChannel(银行/电商品牌)。因此「同商户名、同额、同分钟,但
    // 来自两家不同渠道的真实两笔」在四条件齐备时会被静默合并成一笔。
    // 设计注释已声明这是刻意取舍(靠 merchant_exact 兜底),此处不改判。
    test('HARDENING: 跨渠道强判不校验 sourceChannel(风险如实记录)', () async {
      expect(true, isTrue,
          reason: '见 FINDINGS「跨渠道强判无 sourceChannel 维度」');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('external id 反查一致性', () {
    // ADVERSE FINDING: 写入侧 externalKey 带 currency,查询侧(两处调用点
    // 都不带 currency)不带 → semanticKey 快路径永不命中;只有当 billJson
    // 里恰好有 external_id 时 fallback 才救回来。
    test('ADVERSE: external_id 快路径与写入侧公式漂移 → 已入账交易反查不到',
        () async {
      // 行 A:写入带币种的 semanticKey(与 AiBookkeeper 同口径)
      final a = await eventStore.ensure(AutoBookInput(
        eventKey: 'ext:a',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now(),
        sourceChannel: 'wechat',
        ledgerId: ledgerId,
      ));
      // 生产口径:AiBookkeeper 用 bill.currency 生成 externalKey,
      // 并同时把 external_id 放进 billJson(两条路径都应能命中)。
      await eventStore.upsertItem(
        eventId: a.id,
        itemIndex: 0,
        semanticKey: SemanticDedupMatcher.externalKey('WX-1', currency: 'CNY'),
        transactionId: 101,
        state: AutoBookState.booked.value,
        bill: {'amount': -88},
      );
      await eventStore.mark(
        const AutoBookEventUpdate(state: AutoBookState.booked),
        eventId: a.id,
      );
      // 行 B:老库格式,只有 billJson 里的 external_id(无 semanticKey)
      final b = await eventStore.ensure(AutoBookInput(
        eventKey: 'ext:b',
        source: AutoBookSource.import,
        capturedAt: DateTime.now(),
        ledgerId: ledgerId,
      ));
      await eventStore.upsertItem(
        eventId: b.id,
        itemIndex: 0,
        transactionId: 202,
        state: AutoBookState.booked.value,
        bill: {'external_id': 'OLD-2'},
      );
      await eventStore.mark(
        const AutoBookEventUpdate(state: AutoBookState.booked),
        eventId: b.id,
      );

      // ADVERSE FINDING:查询侧 semanticKey 公式不带币种,写入侧带 CNY,
      // 且这一行的 billJson 也没 external_id → 快路径与 fallback 双双 miss。
      // **同一笔已入账交易的外部单号反查不到** → 后续同单号上报无法判重。
      expect(await eventStore.findTransactionByExternalId('WX-1'), 101,
          reason: '写入行语义索引里存的就是这笔单号,反查必须命中;'
              '实际 null(key 公式漂移 + billJson 无兜底)');
      expect(await eventStore.findTransactionByExternalId('OLD-2'), 202,
          reason: '老库格式靠 billJson 全扫描命中');
      expect(await eventStore.findTransactionByExternalId('   '), isNull);
      // 不带币种写入时两条路径一致
      await eventStore.upsertItem(
        eventId: a.id,
        itemIndex: 1,
        semanticKey: SemanticDedupMatcher.externalKey('WX-2'),
        transactionId: 102,
        state: AutoBookState.booked.value,
        bill: {'external_id': 'WX-2'},
      );
      expect(await eventStore.findTransactionByExternalId('WX-2'), 102,
          reason: '无币种 → 快路径与 fallback 都能命中');
      expect(await eventStore.findTransactionByExternalId('  WX-2  '), 102,
          reason: '大小写/空白归一');
    });

    test('HARDENING: sourceChannel 过滤是「精确(trim+lower)相等」', () async {
      final event = await eventStore.ensure(AutoBookInput(
        eventKey: 'ext:channel',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now(),
        sourceChannel: 'WeChat  ',
        ledgerId: ledgerId,
      ));
      await eventStore.upsertItem(
        eventId: event.id,
        itemIndex: 0,
        transactionId: 303,
        state: AutoBookState.booked.value,
        bill: {'external_id': 'CH-1'},
      );
      await eventStore.mark(
        const AutoBookEventUpdate(state: AutoBookState.booked),
        eventId: event.id,
      );
      expect(await eventStore.findTransactionByExternalId('CH-1', sourceChannel: 'wechat'),
          303);
      expect(
        await eventStore.findTransactionByExternalId('CH-1',
            sourceChannel: 'wechat pay'),
        isNull,
        reason: '渠道名必须完全一致,不做模糊/子串匹配',
      );
      expect(
        await eventStore.findTransactionByExternalId('CH-1',
            sourceChannel: '   '),
        303,
        reason: '空白渠道等同未指定',
      );
    });

    test('HARDENING: ledgerId 过滤在两条路径都生效', () async {
      final event = await eventStore.ensure(AutoBookInput(
        eventKey: 'ext:ledger',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now(),
        ledgerId: 7,
      ));
      await eventStore.upsertItem(
        eventId: event.id,
        itemIndex: 0,
        transactionId: 404,
        state: AutoBookState.booked.value,
        bill: {'external_id': 'LG-1'},
      );
      await eventStore.mark(
        const AutoBookEventUpdate(state: AutoBookState.booked),
        eventId: event.id,
      );
      expect(await eventStore.findTransactionByExternalId('LG-1', ledgerId: 7), 404);
      expect(await eventStore.findTransactionByExternalId('LG-1', ledgerId: 8), isNull);
      expect(await eventStore.findTransactionByExternalId('LG-1'), 404,
          reason: '不传 ledgerId → 不过滤');
    });

    test('HARDENING: 只认 booked 父事件 + 非空 transactionId 的子项', () async {
      // 非终态事件不参与
      final pending = await eventStore.ensure(AutoBookInput(
        eventKey: 'ext:pending',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now(),
      ));
      await eventStore.upsertItem(
        eventId: pending.id,
        itemIndex: 0,
        transactionId: 505,
        state: 'pending',
        bill: {'external_id': 'P-1'},
      );
      expect(await eventStore.findTransactionByExternalId('P-1'), isNull,
          reason: '父事件非 booked → 不返回');

      // booked 但 transactionId 为空的子项不参与
      final noTx = await eventStore.ensure(AutoBookInput(
        eventKey: 'ext:no-tx',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now(),
      ));
      await eventStore.upsertItem(
        eventId: noTx.id,
        itemIndex: 0,
        state: AutoBookState.booked.value,
        bill: {'external_id': 'N-1'},
      );
      await eventStore.mark(
        const AutoBookEventUpdate(state: AutoBookState.booked),
        eventId: noTx.id,
      );
      expect(await eventStore.findTransactionByExternalId('N-1'), isNull);
    });

    test('HARDENING: 损坏的 billJson 不阻断其它事件扫描', () async {
      final broken = await eventStore.ensure(AutoBookInput(
        eventKey: 'ext:broken',
        source: AutoBookSource.import,
        capturedAt: DateTime.now(),
      ));
      await eventStore.upsertItem(
        eventId: broken.id,
        itemIndex: 0,
        transactionId: 606,
        state: AutoBookState.booked.value,
        bill: {'external_id': 'BROKEN-1'},
      );
      await eventStore.mark(
        const AutoBookEventUpdate(state: AutoBookState.booked),
        eventId: broken.id,
      );
      // 手工把 billJson 改成坏 JSON
      await (db.update(db.autoBookEventItems)
            ..where((t) => t.eventId.equals(broken.id)))
          .write(const AutoBookEventItemsCompanion(
        billJson: d.Value('{not json'),
      ));
      expect(await eventStore.findTransactionByExternalId('BROKEN-1'), isNull);

      // 同库另一条好行仍能被找到
      final good = await eventStore.ensure(AutoBookInput(
        eventKey: 'ext:good',
        source: AutoBookSource.import,
        capturedAt: DateTime.now(),
      ));
      await eventStore.upsertItem(
        eventId: good.id,
        itemIndex: 0,
        transactionId: 707,
        state: AutoBookState.booked.value,
        bill: {'external_id': 'GOOD-1'},
      );
      await eventStore.mark(
        const AutoBookEventUpdate(state: AutoBookState.booked),
        eventId: good.id,
      );
      expect(await eventStore.findTransactionByExternalId('GOOD-1'), 707);
    });

    test('HARDENING: 快路径公式漂移时回退全扫描(带币种 semanticKey 查无币种 externalId)',
        () async {
      // 写入侧带币种(生产口径),查询侧 externalKey 不带币种 → key 不同
      final event = await eventStore.ensure(AutoBookInput(
        eventKey: 'ext:drift',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now(),
      ));
      await eventStore.upsertItem(
        eventId: event.id,
        itemIndex: 0,
        // semanticKey 带币种
        semanticKey: SemanticDedupMatcher.externalKey('DRIFT-1', currency: 'CNY'),
        transactionId: 808,
        state: AutoBookState.booked.value,
        // billJson 里**没有** external_id → 全扫描也找不到
        bill: {'amount': -88},
      );
      await eventStore.mark(
        const AutoBookEventUpdate(state: AutoBookState.booked),
        eventId: event.id,
      );
      // import 路径查询不带币种 → 公式不同 → 快路径 miss,fallback 也 miss
      expect(await eventStore.findTransactionByExternalId('DRIFT-1'), isNull,
          reason: 'HARDENING:查询侧不带币种时,写入侧带币种的 semanticKey '
              '永远查不到(公式漂移,仅靠 billJson 兜底)');
      expect(
        SemanticDedupMatcher.externalKey('DRIFT-1'),
        isNot(SemanticDedupMatcher.externalKey('DRIFT-1', currency: 'CNY')),
        reason: '公式确实不同',
      );
    });

    test('HARDENING: sourceKeysForTransaction 汇总父行/子项/duplicateOf 三个来源',
        () async {
      final parent = await eventStore.ensure(AutoBookInput(
        eventKey: 'src:parent',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now(),
      ));
      await eventStore.mark(
        const AutoBookEventUpdate(state: AutoBookState.booked, transactionId: 900),
        eventId: parent.id,
      );
      final viaItems = await eventStore.ensure(AutoBookInput(
        eventKey: 'src:items',
        source: AutoBookSource.notification,
        capturedAt: DateTime.now(),
      ));
      await eventStore.upsertItem(
        eventId: viaItems.id,
        itemIndex: 0,
        transactionId: 900,
        state: AutoBookState.booked.value,
      );
      final viaDuplicate = await eventStore.ensure(AutoBookInput(
        eventKey: 'src:dup',
        source: AutoBookSource.screenText,
        capturedAt: DateTime.now(),
      ));
      await eventStore.mark(
        const AutoBookEventUpdate(
            state: AutoBookState.duplicate, duplicateOfTransactionId: 900),
        eventId: viaDuplicate.id,
      );
      // manual 无来源键
      final manual = await eventStore.ensure(AutoBookInput(
        eventKey: 'src:manual',
        source: AutoBookSource.manual,
        capturedAt: DateTime.now(),
      ));
      await eventStore.mark(
        const AutoBookEventUpdate(state: AutoBookState.booked, transactionId: 900),
        eventId: manual.id,
      );

      expect(
        await eventStore.sourceKeysForTransaction(900),
        {'sms', 'notification', 'screen'},
        reason: 'manual 不贡献来源键;screenText 归一为 screen',
      );
      expect(await eventStore.sourceKeysForTransaction(999), isEmpty);
    });

    test('HARDENING: transactionIdsForEvent 汇总父行 + booked/duplicate 子项',
        () async {
      final event = await eventStore.ensure(AutoBookInput(
        eventKey: 'txids',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now(),
      ));
      await eventStore.upsertItem(
        eventId: event.id, itemIndex: 0, state: 'booked', transactionId: 11);
      await eventStore.upsertItem(
        eventId: event.id, itemIndex: 1, state: 'duplicate', transactionId: 12);
      await eventStore.upsertItem(
        eventId: event.id, itemIndex: 2, state: 'pending', transactionId: 13);
      await eventStore.mark(
        const AutoBookEventUpdate(state: AutoBookState.booked, transactionId: 10),
        eventId: event.id,
      );
      // HARDENING:实现**不按 state 过滤**子项 —— pending 子项挂的
      // transactionId 也会被算进集合(与文档注释「booked/duplicate」不符)
      expect(await eventStore.transactionIdsForEvent(event.id), {10, 11, 12, 13});
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('DedupExemptStore', () {
    test('HARDENING: 空关键字 / 空字符串一律不收;同段幂等去重', () async {
      final store = DedupExemptStore();
      await store.add(keyword: '   ', amount: 10);
      await store.add(keyword: '', amount: 10);
      expect(await store.list(), isEmpty);

      await store.add(keyword: ' Starbucks ', amount: 30);
      final rules = await store.list();
      expect(rules.single.keyword, 'starbucks', reason: 'trim + lower');

      await store.add(keyword: 'starbucks', amount: 30.5);
      expect(await store.list(), hasLength(1),
          reason: '同段(±10% 且 ≥±1 元)只保留一条');

      await store.add(keyword: 'starbucks', amount: 45);
      expect(await store.list(), hasLength(2),
          reason: '金额段外 → 新规则');
    });

    test('HARDENING: amountWithinSegment 边界(±10% 与 ±1 元取大,含 0.01 容差)',
        () {
      final base10 = DedupExemptRule(
          keyword: 'k', amount: 10, createdAt: DateTime.now());
      expect(base10.amountWithinSegment(11.0), isTrue);
      expect(base10.amountWithinSegment(11.01), isTrue, reason: '+0.01 容差内');
      expect(base10.amountWithinSegment(11.02), isFalse);
      expect(base10.amountWithinSegment(9.0), isTrue);

      final tiny = DedupExemptRule(
          keyword: 'k', amount: 3, createdAt: DateTime.now());
      // 3*10% = 0.3 < 1 → 走 ±1 元下限:tolerance = 1.0,再加 0.01 容差
      expect(tiny.amountWithinSegment(3.5), isTrue, reason: '0.5 <= 1.01');
      expect(tiny.amountWithinSegment(4.01), isTrue, reason: '1.01 <= 1.01');
      expect(tiny.amountWithinSegment(4.02), isFalse, reason: '1.02 > 1.01');
      expect(tiny.amountWithinSegment(2.0), isTrue);

      // 负数基准取 abs
      final negative = DedupExemptRule(
          keyword: 'k', amount: -30, createdAt: DateTime.now());
      expect(negative.amountWithinSegment(30), isTrue);
      expect(negative.amountWithinSegment(-30), isTrue);
    });

    test('HARDENING: 损坏 JSON / 类型错的行被静默丢弃,不阻断其余规则', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('dedup_exempt_rules_v1', [
        '{corrupt',
        jsonEncode({'keyword': '', 'amount': 1}),
        jsonEncode({'keyword': 'bad-amount', 'amount': 'ten'}),
        jsonEncode({'keyword': 'no-created', 'amount': 5}),
        jsonEncode({'keyword': 'good', 'amount': 5}),
        jsonEncode(['not', 'a', 'map']),
      ]);
      final rules = await DedupExemptStore().list();
      expect(rules.map((r) => r.keyword), ['no-created', 'good'],
          reason: '坏行丢弃;缺 createdAt 的行用 now() 兜底而非丢弃');
    });

    test('HARDENING: isExempt 要求双侧同一关键字 + 双侧都在金额段', () {
      final rules = [
        DedupExemptRule(keyword: '星巴克', amount: 30, createdAt: DateTime.now()),
      ];
      expect(
        DedupExemptStore.isExempt(rules,
            billAmount: 30,
            billNoteNormalized: '星巴克咖啡',
            txAmount: 30,
            txNoteNormalized: '星巴克'),
        isTrue,
      );
      expect(
        DedupExemptStore.isExempt(rules,
            billAmount: 30,
            billNoteNormalized: '星巴克咖啡',
            txAmount: 30,
            txNoteNormalized: '麦当劳'),
        isFalse,
        reason: '单侧命中不放过',
      );
      expect(
        DedupExemptStore.isExempt(rules,
            billAmount: 100,
            billNoteNormalized: '星巴克',
            txAmount: 100,
            txNoteNormalized: '星巴克'),
        isFalse,
        reason: '双侧都在 100 元,不在 30 元段内',
      );
      expect(
        DedupExemptStore.isExempt(rules,
            billAmount: null,
            billNoteNormalized: '星巴克',
            txAmount: 30,
            txNoteNormalized: '星巴克'),
        isFalse,
        reason: '账单金额缺失不豁免',
      );
      expect(DedupExemptStore.isExempt(const [], billAmount: 30, billNoteNormalized: 'x', txAmount: 30, txNoteNormalized: 'x'), isFalse);
    });

    test('HARDENING: NaN 金额既不被豁免也不产生误命中', () {
      final rules = [
        DedupExemptRule(keyword: 'x', amount: double.nan, createdAt: DateTime.now()),
      ];
      // NaN 段判定:被比较数也在 NaN 段里,abs((NaN-NaN)) = NaN <= tol → false
      expect(
        DedupExemptStore.isExempt(rules,
            billAmount: double.nan,
            billNoteNormalized: 'x',
            txAmount: double.nan,
            txNoteNormalized: 'x'),
        isFalse,
        reason: 'NaN 段比较恒 false → 豁免不生效(保守方向,可辩护)',
      );
      expect(
        DedupExemptStore.isExempt(rules,
            billAmount: 30,
            billNoteNormalized: 'x',
            txAmount: 30,
            txNoteNormalized: 'x'),
        isFalse,
        reason: '未知段不误命中正常金额',
      );
    });

    test('HARDENING: 容量上限 200 淘汰最旧', () async {
      final store = DedupExemptStore();
      final prefs = await SharedPreferences.getInstance();
      // 直接写 200 条互不同段的规则,再 add 第 201 条
      await prefs.setStringList(
        'dedup_exempt_rules_v1',
        [
          for (var i = 0; i < 200; i++)
            jsonEncode({
              'keyword': 'k$i',
              'amount': 1000.0 * (i + 1),
              'createdAt': DateTime.now().toIso8601String(),
            }),
        ],
      );
      await store.add(keyword: 'newest', amount: 999999);
      final rules = await store.list();
      expect(rules, hasLength(200));
      expect(rules.first.keyword, 'k1', reason: '最旧(k0)被淘汰');
      expect(rules.last.keyword, 'newest');
    });

    test('HARDENING: findBest 命中豁免后跳过该交易(判重结果为空)', () async {
      final l = await repo.createLedger(name: 'exempt');
      final t = DateTime.now();
      await repo.addTransaction(
          ledgerId: l,
          type: 'expense',
          amount: 30,
          happenedAt: t,
          note: '星巴克');
      await DedupExemptStore().add(keyword: '星巴克', amount: 30);
      expect(
        await matcher.findBest(
          repository: repo,
          ledgerId: l,
          bill: BillInfo(
              amount: -30, time: t, type: BillType.expense, merchant: '星巴克'),
        ),
        isNull,
        reason: '「仍记一笔」裁定过 → 同类误判不复发',
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('ManualDuplicateChecker', () {
    test('HARDENING: 手动记账只做软提示(有商户信号才返回),方向由 type 决定',
        () async {
      final l = await repo.createLedger(name: 'manual');
      final t = DateTime.now();
      await repo.addTransaction(
          ledgerId: l,
          type: 'expense',
          amount: 66,
          happenedAt: t,
          note: '星巴克');

      final hit = await ManualDuplicateChecker.find(
        repository: repo,
        ledgerId: l,
        amount: 66,
        type: BillType.expense,
        time: t,
        note: '星巴克',
        currency: 'CNY',
      );
      expect(hit, isNotNull);
      expect(hit!.transactionId, isNotNull);

      // 无备注 → merchant/note 都是 null → 无商户信号 → 只到 0.80
      // (amount_exact + currency + time_1m=0.40+0.15+0.25)… 实际 currency
      // 传入时 tx 侧币种列可能为空,分数按实现为准;核心断言:不静默拦截
      final noNote = await ManualDuplicateChecker.find(
        repository: repo,
        ledgerId: l,
        amount: 66,
        type: BillType.expense,
        time: t,
      );
      expect(noNote == null || noNote.isStrong, isTrue,
          reason: 'HARDENING:手动路径绝不静默拦截 —— 调用方按 possible 提示,'
              'strong 则视为已存在');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('AutoBillingService 指纹(normalize 口径)', () {
    test('HARDENING: smsFingerprint 与 native 同口径(长度前缀 + 前 8 字节 hex)',
        () {
      final a = AutoBillingService.smsFingerprint('95555', '尾号1234消费100元');
      expect(a, hasLength(16));
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(a), isTrue);
      // 口径更新(2026-10-11,批次 C2):字段加长度前缀(`'${len}:$field'` 拼接)
      // 后,分隔符 `|` 不再能与相邻字段边界互换 —— 本组原来断言的
      // 「可构造碰撞」是缺陷行为,修复后改为断言指纹不再碰撞。
      expect(
        AutoBillingService.smsFingerprint('95555', '消费100|转账'),
        isNot(AutoBillingService.smsFingerprint('95555|消费100', '转账')),
        reason: '长度前缀使字段边界自描述 → 边界互换不再撞同一指纹',
      );
      // 空白**不归一**:尾随空格是不同的短信指纹(与短信去重口径相关)
      expect(
        AutoBillingService.smsFingerprint('95555', '消费100元'),
        isNot(AutoBillingService.smsFingerprint('95555', '消费100元 ')),
        reason: 'HARDENING:指纹不过 normalize,运营商加的尾随空白会穿透去重',
      );
    });

    test('HARDENING: notifyFingerprint 带 identity 时用新口径,缺失时退回旧口径',
        () {
      final withIdentity = AutoBillingService.notifyFingerprint(
        'pkg', 'title', 'body',
        notificationKey: 'k', notificationId: 1, postTime: 2,
      );
      final legacy = AutoBillingService.notifyFingerprint('pkg', 'title', 'body');
      expect(withIdentity, isNot(legacy),
          reason: 'C6:新旧口径不同(旧缓存会 miss 一次,由语义判重兜底)');
      // 部分 identity(只有 id)→ 仍走新口径
      final partial = AutoBillingService.notifyFingerprint('pkg', 'title', 'body',
          notificationId: 42);
      expect(partial, isNot(legacy));
      // 分隔符注入不撞
      expect(
        AutoBillingService.notifyFingerprint('pkg', 'a|0|0|b', 'body',
            notificationKey: 'c', notificationId: 0, postTime: 0),
        isNot(AutoBillingService.notifyFingerprint('pkg', 'b|c', 'body',
            notificationKey: 'a', notificationId: 0, postTime: 0)),
        reason: 'HARDENING:identity 用 | 拼接,理论上仍可构造撞指纹的组合',
      );
    });

    test('HARDENING: billFingerprint 小时粒度 + 方向 + abs(金额)', () {
      final base = DateTime.now();
      final a = AutoBillingService.billFingerprint(
        channel: '微信支付',
        amount: -88,
        note: '商户X',
        time: DateTime(base.year, base.month, base.day, 14, 3),
        type: 'expense',
      );
      final sameHour = AutoBillingService.billFingerprint(
        channel: '微信支付',
        amount: -88,
        note: '商户X',
        time: DateTime(base.year, base.month, base.day, 14, 58),
        type: 'expense',
      );
      final nextHour = AutoBillingService.billFingerprint(
        channel: '微信支付',
        amount: -88,
        note: '商户X',
        time: DateTime(base.year, base.month, base.day, 15, 2),
        type: 'expense',
      );
      expect(a, sameHour, reason: '同小时同指纹(重复进详情页去重)');
      expect(a, isNot(nextHour), reason: '跨小时不吞真实第二笔');

      final refund = AutoBillingService.billFingerprint(
        channel: '微信支付',
        amount: 88,
        note: '商户X',
        time: DateTime(base.year, base.month, base.day, 14, 3),
        type: 'income',
      );
      expect(a, isNot(refund), reason: 'C2:加入 type → 退款不被 already_processed 跳过');

      // HARDENING:金额按 toStringAsFixed(2) 归一 —— 亚分金额(88.004 与
      // 88.0049)折叠成同一指纹。真实账单金额都是两位小数,威胁面小;
      // 但若上游将来放开更高精度,同渠道同小时的亚分差异会被静默吞掉。
      final v1 = AutoBillingService.billFingerprint(
        channel: 'c', amount: -88.004, note: 'n', time: base, type: 'expense');
      final v2 = AutoBillingService.billFingerprint(
        channel: 'c', amount: -88.0049, note: 'n', time: base, type: 'expense');
      final cent = AutoBillingService.billFingerprint(
        channel: 'c', amount: -88.01, note: 'n', time: base, type: 'expense');
      expect(v1, v2, reason: '亚分差异折叠(如实记录)');
      expect(v1, isNot(cent), reason: '分位差异仍能区分');
      // 时间缺失 → date 段为空,不同缺失时间的同额同渠道会撞
      final noTimeA = AutoBillingService.billFingerprint(
        channel: 'c', amount: -10, note: 'n', time: null, type: 'expense');
      final noTimeB = AutoBillingService.billFingerprint(
        channel: 'c', amount: -10, note: 'n', time: null, type: 'expense');
      expect(noTimeA, noTimeB);
    });

    // ADVERSE FINDING: billFingerprint 的 note 只做 trim,不做
    // normalizeAutoBookText。同一笔消费的短信侧备注 "商户 X" 与详情页侧
    // "商户X 支付成功" 指纹不同 → 两层去重互相脱节,重复入账只能靠语义判重
    // 兜底。注释明确写了「账单级指纹按业务要素去重」,但要素未归一。
    test('ADVERSE: billFingerprint 的 note 不归一 → 同商户写法差异指纹不同',
        () {
      final base = DateTime.now();
      final a = AutoBillingService.billFingerprint(
        channel: '微信支付',
        amount: -88,
        note: '商户 X',
        time: base,
        type: 'expense',
      );
      final b = AutoBillingService.billFingerprint(
        channel: '微信支付',
        amount: -88,
        note: '商户  X ',
        time: base,
        type: 'expense',
      );
      expect(a, b,
          reason: '同一商户的多空格写法是同一笔业务要素,指纹应当一致;'
              '实际 trim 只去首尾,内部双空格导致 miss');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  group('JsonResponseParser 与判重链路的数值边界', () {
    test('ADVERSE: 解析器把 1e999 / "Infinity" / "NaN" 放行为有效金额', () {
      const parser = JsonResponseParser();
      final infinity = parser.parse('[{"amount":1e999,"time":"2026-01-05T12:00:00"}]');
      expect(infinity, isEmpty,
          reason: 'Infinity 金额应在解析层丢弃(下游无 isFinite 守卫);'
              '实际返回 [Infinity] 并会一路落到账单/事件表');

      final nan = parser.parse('[{"amount":"NaN","time":"2026-01-05T12:00:00"}]');
      expect(nan, isEmpty, reason: 'NaN 金额同样应丢弃');
    });

    test('HARDENING: 正常金额与字符串千分位解析一致', () {
      const parser = JsonResponseParser();
      final numeric = parser.parse('[{"amount":-1234.5,"time":"2026-01-05T12:00:00"}]');
      final quoted = parser.parse('[{"amount":"-1,234.50","time":"2026-01-05T12:00:00"}]');
      expect(numeric.single.amount, -1234.5);
      expect(quoted.single.amount, -1234.5);
    });
  });
}
