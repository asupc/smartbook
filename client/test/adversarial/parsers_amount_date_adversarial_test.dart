// 对抗性测试 — 金额/日期解析域。
//
// 攻击面:`lib/utils/date_parser.dart`、`lib/services/import/bill_parser.dart`,
// `lib/services/import/parsers/*.dart`, `lib/utils/format_utils.dart`,
// `lib/utils/currency_aliases.dart`, `lib/pages/data/import_confirm_page.dart`
// 的金额/日期清洗逻辑(经其可观察的等价实现断言)。
//
// 红绿纪律:
// - 确认缺陷 → 断言当前错误行为并失败,行内标 `// ADVERSE FINDING: <标题>`。
// - 行为可辩护但脆弱 → 断言当前行为并通过,行内标 `// HARDENING: <说明>`。
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:smartbook/services/import/amount_text.dart';
import 'package:smartbook/services/import/parsers/alipay_parser.dart';
import 'package:smartbook/services/import/parsers/generic_parser.dart';
import 'package:smartbook/services/import/parsers/wechat_parser.dart';
import 'package:smartbook/utils/currency_aliases.dart';
import 'package:smartbook/utils/date_parser.dart';
import 'package:smartbook/utils/format_utils.dart';

/// 导入页使用的金额清洗(与其生产实现同源):
/// `import_confirm_page.dart` 的 `_buildImportDataFromCsv` 直接调用
/// `parseImportAmount` —— 这里改为调用**同一个生产函数**,不再复制字面实现。
/// (原先复制 `replaceAll(RegExp(r'[¥$,+-]'), '')` 是为了在不 pump 页面的前提下
/// 断言同一行为;清洗逻辑抽成公共函数后,直接引用才能真正锁住页面口径。)
double importPageAmount(String? raw) => parseImportAmount(raw);

/// 与 `import_confirm_page.dart:1069` 同口径的日期兜底。
DateTime importPageDate(String? raw) =>
    DateParser.tryParse(raw) ?? DateTime(1970, 1, 1);

/// 断言 [input] **没有**被兜底成"解析那一刻"。真解析出来的日期总是远离
/// now(),兜底 now() 则必然落在 [before, after] 之间 —— 该断言据此确定性地
/// 失败(不受具体日期影响,不依赖 wall-clock 顺序)。
void expectNotFallenBackToNow(String input, {required String reason}) {
  final before = DateTime.now();
  final d = importPageDate(input);
  final after = DateTime.now();
  expect(d.isBefore(before) || d.isAfter(after), isTrue, reason: reason);
}

void main() {
  group('金额:退款金额归一 normalizeRefundAmount', () {
    final alipay = AlipayBillParser();
    final wechat = WechatBillParser();

    test('千分位与货币符号被剥离', () {
      expect(alipay.normalizeRefundAmount('1,234.56'), 1234.56);
      expect(alipay.normalizeRefundAmount('¥1,234.00'), 1234.0);
      expect(alipay.normalizeRefundAmount('￥1,234.00'), 1234.0);
      expect(wechat.normalizeRefundAmount('12.30'), 12.3);
    });

    // HARDENING: 欧式 "1.234,56"(千分位点 + 小数逗号)被解析成 1.23456 ——
    // `normalizeRefundAmount` 只删 `,` 不处理 `.` 作千分位的欧洲写法。
    // 退款金额会缩水 ~1000 倍。中文账单(支付宝/微信)不会出现该写法,
    // 但「用户自定义 CSV + 欧式导出」会;当前行为锁在这里(记为 HARDENING
    // 而非 ADVERSE:目标业务域是中文账单)。
    test('欧式千分位 1.234,56 → 1.23456(量级差 ~1000 倍)', () {
      expect(alipay.normalizeRefundAmount('1.234,56'), 1.23456,
          reason: 'HARDENING 标记:欧式写法被误解,量级差 ~1000 倍');
    });

    test('全角/阿拉伯-印度数字不被识别(返回 null,不会误算)', () {
      expect(alipay.normalizeRefundAmount('１００'), isNull);
      expect(alipay.normalizeRefundAmount('١٢٣'), isNull);
    });

    test('负数变体:减号被剥后取 abs', () {
      expect(alipay.normalizeRefundAmount('-50.00'), 50.0);
      expect(alipay.normalizeRefundAmount('¥-50.00'), 50.0);
    });

    // ADVERSE FINDING: Unicode 负号变体(U+2212 数学减号、U+FF0D 全角减号、
    // U+2013 短横线)不在 `[¥$,+，]` 删除集内,`double.tryParse` 返回 null
    // → 退款金额整笔丢失(归一为 null),下游按「无退款」处理。
    // 源码:`lib/services/import/bill_parser.dart:35` /
    // `lib/services/import/parsers/generic_parser.dart:18`。
    test('Unicode 负号(−/－)导致退款金额丢弃', () {
      expect(alipay.normalizeRefundAmount('\u221250.00'), 50.0,
          reason: 'ADVERSE FINDING: Unicode 减号 U+2212 使 tryParse 返回 null,'
              '退款金额被静默丢弃(期望 50.0,实际 null)');
    });

    // HARDENING: NaN / Infinity 字符串直接透传成 double.nan / double.infinity。
    // 归一函数不做 isFinite 校验,调用方(导入服务)有 `!tx.amount.isFinite`
    // 拦截,但 `normalizeRefundAmount` 的返回值在 preview/导入两处都会被
    // 当成"有效退款金额 > 0"参与 effectiveType 判定 —— NaN > 0 为 false
    // 所以侥幸安全,Infinity > 0 为 true 会被判为收入行。
    test('NaN / Infinity 字符串被透传为 double.nan / double.infinity', () {
      expect(alipay.normalizeRefundAmount('NaN')?.isNaN, isTrue,
          reason: 'HARDENING 标记:非法值不做 isFinite 校验,依赖调用方拦截');
      expect(alipay.normalizeRefundAmount('Infinity'), double.infinity);
    });

    test('0 / 空 / 纯文字 / 括号负数 → null 或 0', () {
      expect(alipay.normalizeRefundAmount('0'), 0.0);
      expect(alipay.normalizeRefundAmount(''), isNull);
      expect(alipay.normalizeRefundAmount('   '), isNull);
      expect(alipay.normalizeRefundAmount(null), isNull);
      expect(alipay.normalizeRefundAmount('abc'), isNull);
      expect(alipay.normalizeRefundAmount('(88.00)'), isNull);
    });

    test('科学计数法与超长数字串被接受(无上限校验)', () {
      expect(alipay.normalizeRefundAmount('1e10'), 1e10);
      expect(alipay.normalizeRefundAmount('99999999999999999999'),
          100000000000000000000.0);
    });

    test('小数位超 2 位原样保留(不做分位取整)', () {
      expect(alipay.normalizeRefundAmount('12.345'), 12.345);
    });

    // HARDENING: 空格千分位 "1 234.56" 完全无法解析 → null。中文账单里
    // 空格分隔的金额(某些银行导出)会整笔丢退款。
    test('空格千分位 1 234.56 → null(当前行为)', () {
      expect(alipay.normalizeRefundAmount(' 1 234.56'), isNull,
          reason: 'HARDENING 标记:空格千分位不识别');
    });
  });

  group('金额:导入页清洗(与 import_confirm_page 同口径)', () {
    test(r'¥ / $ / 逗号 / 正负号被剥离', () {
      expect(importPageAmount('¥1,234.00'), 1234.0);
      expect(importPageAmount(r'$99.99'), 99.99);
      expect(importPageAmount('-88.00'), 88.0);
      expect(importPageAmount('+88.00'), 88.0);
    });

    // ADVERSE FINDING: 导入页只删 ASCII `¥`(U+00A5)与 `$`,
    // 全角 `￥`(U+FFE5)不在删除集内 → `double.tryParse('￥100')` 为 null
    // → 金额 0.0 → 导入服务记 invalid,整行被丢弃且用户只看到「无效行」。
    // 支付宝导出的「金额（元）」列在部分版本里带全角￥。
    // 源码:`lib/pages/data/import_confirm_page.dart:1063`。
    test('全角￥前缀金额被解析成 0.0(整行判无效)', () {
      expect(importPageAmount('￥100.00'), 100.0,
          reason: 'ADVERSE FINDING: 全角￥不会被剥离,'
              'double.tryParse 失败 → 金额 0.0 → 该行 invalid');
    });

    // ADVERSE FINDING: 金额字段一旦带「元」「共￥88.00元」这类混排文字,
    // 清洗只删符号不删汉字 → tryParse 失败 → 0.0。
    test('金额+文字混排「共￥88.00元」→ 0.0', () {
      expect(importPageAmount('共88.00元'), 88.0,
          reason: 'ADVERSE FINDING: 汉字混排使金额归零,该行被判 invalid');
    });

    // ADVERSE FINDING: 全角数字同样无法解析 → 0.0。
    test('全角数字金额 → 0.0', () {
      expect(importPageAmount('１２３'), 123.0,
          reason: 'ADVERSE FINDING: 全角数字不被 double.tryParse 接受,金额归零');
    });

    test('空/纯文字 → 0.0(导入服务据此判 invalid)', () {
      expect(importPageAmount(null), 0.0);
      expect(importPageAmount(''), 0.0);
      expect(importPageAmount('免费'), 0.0);
    });

    test('小数末位被保留,不四舍五入到分', () {
      expect(importPageAmount('12.345'), 12.345);
    });
  });

  group('日期:DateParser 与非法日期的静默顺延', () {
    // ADVERSE FINDING: 非法日历日期被 DateTime/DateFormat「顺延」而不是拒绝。
    // `DateParser.parse('2026-02-30')` 走 DateTime.parse → 2026-03-02;
    // `'2025-02-29'`(非闰年)→ 2025-03-01。错日期会直接落库成
    // happenedAt,用户看到的是一笔发生在不存在日期附近的交易。
    // 源码:`lib/utils/date_parser.dart:41-47`(DateTime.parse 不校验日历)、
    // 中文分支 `:56-79`(DateTime(y,m,d) 同样顺延)。
    test('2026-02-30 应被拒绝(拒绝而非顺延)', () {
      expect(DateParser.tryParse('2026-02-30'), isNull,
          reason: 'ADVERSE FINDING: 期望 null(不存在的日期),'
              '实际 ${DateParser.tryParse('2026-02-30')}(顺延到 03-02)');
    });

    test('2025-02-29(非闰年)应被拒绝', () {
      expect(DateParser.tryParse('2025-02-29'), isNull,
          reason: 'ADVERSE FINDING: 非闰年 2/29 期望 null,'
              '实际 ${DateParser.tryParse('2025-02-29')}(顺延到 03-01)');
    });

    test('闰年 2024-02-29 正常解析(对照组)', () {
      expect(DateParser.tryParse('2024-02-29'), DateTime(2024, 2, 29));
    });

    test('中文非法日期 2026年2月30日 应被拒绝', () {
      expect(DateParser.tryParse('2026年2月30日'), isNull,
          reason: 'ADVERSE FINDING: 中文分支 DateTime(y,m,d) 无日历校验,'
              '实际 ${DateParser.tryParse('2026年2月30日')}');
    });

    test('2026年13月40日 应被拒绝(而非跨年顺延)', () {
      final d = DateParser.tryParse('2026年13月40日');
      expect(d, isNull,
          reason: 'ADVERSE FINDING: 13 月 40 日期望 null,'
              '实际 $d(跨年顺延到 2027-02-09)');
    });

    // ADVERSE FINDING: 短横线分隔的「日-月-年」写法被判成远古年份。
    // "03-04-2026" 是完全合法的 dd-MM-yyyy / MM-dd-yyyy 写法,
    // 但 `_tryParseCommonFormats` 的格式表里 'yyyy-MM-dd' 排在
    // 'dd-MM-yyyy' **之前**,intl 把末段的 2026 当成"日"塞进去并溢出进位
    // → 解析成 0008-10-16(差 ~2018 年)。用户账单日期静默变成公元 8 年。
    // 源码:`lib/utils/date_parser.dart:88-103`(格式表顺序)。
    test('"03-04-2026" 被 yyyy-MM-dd 抢走 → 0008-10-16', () {
      final d = DateParser.tryParse('03-04-2026')!;
      expect(d, DateTime(2026, 4, 3),
          reason: 'ADVERSE FINDING: 期望 dd-MM-yyyy → 2026-04-03,'
              '实际 0008-10-16(年份被当成日溢出),差约 2018 年');
    });

    test('"01-02-2026" 同样塌成 0006-08-19', () {
      final d = DateParser.tryParse('01-02-2026')!;
      expect(d.year, 2026,
          reason: 'ADVERSE FINDING: 期望 2026-02-01(或 2026-01-02),实际 year=${d.year}');
    });

    test('"05/03/2026" 被 yyyy/MM/dd 抢走 → 0010-09-16', () {
      final d = DateParser.tryParse('05/03/2026')!;
      expect(d.year, 2026,
          reason: 'ADVERSE FINDING: 05/03/2026 被当成年=0005,'
              '解析出 year=${d.year},与斜杠格式的直觉语义完全不一致');
    });

    // ADVERSE FINDING: DateParser.tryParse 对**不可解析**的字符串返回 now(),
    // 而不是 null。导入页 `?? DateTime(1970,1,1)` sentinel 因此几乎永不生效:
    // 「待定」「2026.01.05」「Jan 5, 2026」全部落成"导入那一刻"的时间。
    // 用户点导入的日期被当成交易日期写进库,还能通过 validDate 校验
    // (year > 1970 且 <= now+1),不会被判 invalid。
    // 源码:`lib/utils/date_parser.dart:120-126` tryParse → parse(fallback:null)
    // → `:37 return fallback ?? DateTime.now()`。
    test('无法解析的日期串 → now()(导入页 sentinel 失效)', () {
      expectNotFallenBackToNow('待定',
          reason: 'ADVERSE FINDING: "待定" 期望 1970 sentinel(被判 invalid),'
              '实际落成 DateTime.now() 附近,垃圾日期直接入账');
    });

    test('"2026.01.05"(点分隔)不被识别 → now()', () {
      expectNotFallenBackToNow('2026.01.05',
          reason: 'ADVERSE FINDING: 点分隔日期不可识别,落成 now()');
    });

    test('"Jan 5, 2026"(英文月份)不被识别 → now()', () {
      expectNotFallenBackToNow('Jan 5, 2026',
          reason: 'ADVERSE FINDING: 英文月份日期不可识别,落成 now()');
    });

    test('"0" 不被识别 → now()', () {
      expectNotFallenBackToNow('0',
          reason: 'ADVERSE FINDING: "0" 落成 now() 而非 sentinel');
    });

    test('相对日期「昨天/前天」不被识别 → now()(中文账单常见)', () {
      expectNotFallenBackToNow('昨天',
          reason: 'ADVERSE FINDING: "昨天" 落成 now() —— '
              '相对日期完全不支持,且失败兜底是 now() 不是 sentinel');
      expectNotFallenBackToNow('前天', reason: 'ADVERSE FINDING: "前天" 同上');
      expectNotFallenBackToNow('今天', reason: 'ADVERSE FINDING: "今天" 同上');
    });

    test('上午12点 / 下午12点 歧义: 全部落成 now() 且无法区分', () {
      expectNotFallenBackToNow('上午12点',
          reason: 'ADVERSE FINDING: 上午12点落成 now(),期望解析出真实时刻');
      // 两个语义相反的输入都兜底成 now(),间隔只差解析耗时(ms 级)——
      // 不可区分。这里断言"差 < 5 秒"以证明两者是同一次 now() 兜底。
      final am = importPageDate('上午12点');
      final pm = importPageDate('下午12点');
      expect(am.difference(pm).inSeconds.abs() < 5, isTrue,
          reason: 'ADVERSE FINDING: 上午12点 与 下午12点 兜底成同一时刻,'
              '12 点歧义无法区分;期望两者语义相差 12 小时');
    });

    test('2026-01-01 24:00:00 → 次日 00:00(24 点被接受)', () {
      expect(DateParser.tryParse('2026-01-01 24:00:00'),
          DateTime(2026, 1, 2, 0, 0),
          reason: 'HARDENING 标记:24:00 被 DateTime.parse 当次日零点,当前行为');
    });

    test('全角数字日期 → now()', () {
      expectNotFallenBackToNow('２０２６年１月１日',
          reason: 'ADVERSE FINDING: 全角数字不被正则匹配,落 now()');
    });

    test('epoch 0 / 年份 9999 边界', () {
      expect(DateParser.tryParse('1970-01-01'), DateTime(1970, 1, 1));
      expect(DateParser.tryParse('9999-12-31 23:59:59'),
          DateTime(9999, 12, 31, 23, 59, 59));
    });

    test('带时区偏移 +08:00 → 折算成本地时刻(不丢偏移)', () {
      final d = DateParser.tryParse('2026-01-01T00:00:00+08:00')!;
      expect(d.isUtc, isFalse);
      // UTC+8 的 00:00 == UTC 前一天 16:00;本地(本机 UTC+8)仍是 01-01 00:00
      expect(d.toUtc(), DateTime.utc(2025, 12, 31, 16, 0));
    });

    test('无分隔符 20260904 被当 ISO 基本格式接受', () {
      expect(DateParser.tryParse('20260904'), DateTime(2026, 9, 4),
          reason: 'HARDENING 标记:8 位纯数字被 DateTime.parse 当 yyyyMMdd');
    });

    test('13月40日(无年份)不匹配中文正则 → now()', () {
      expectNotFallenBackToNow('13月40日',
          reason: 'ADVERSE FINDING: 无年份非法月日兜底 now()');
    });
  });

  group('日期:导入页 sentinel 与导入服务的 validDate 交互', () {
    test('1970 sentinel 会被导入服务判 invalid(year > 1970 为假)', () {
      final sentinel = DateTime(1970, 1, 1);
      final validDate = sentinel.year > 1970 &&
          sentinel.year <= DateTime.now().year + 1;
      expect(validDate, isFalse);
    });

    // 修复后(2026-10-11,批次 C2):`DateParser.tryParse` 不再回落 now(),
    // 导入页的 1970 sentinel 因此**真正生效** —— 垃圾日期落到 sentinel,
    // 被导入服务的 validDate 拦下判 invalid。原断言(`validDate == true`,
    // 锁"兜底 now() 能穿过校验"这一缺陷链)已按正确行为改写。
    test('未识别日期落到 1970 sentinel 并被 validDate 拦下', () {
      final d = importPageDate('待定');
      expect(d, DateTime(1970, 1, 1),
          reason: '未识别日期必须落到 epoch sentinel,而不是"导入那一刻"');
      final validDate = d.year > 1970 && d.year <= DateTime.now().year + 1;
      expect(validDate, isFalse,
          reason: 'sentinel 会被 validDate 拦下 → 该行判 invalid(不再伪造日期入账)');
    });

    test('9999 年份被有效日期上限拦截(反向:合法老数据也被拦)', () {
      final d = DateTime(9999, 12, 31);
      expect(d.year <= DateTime.now().year + 1, isFalse);
    });
  });

  group('格式化:formatBalance / formatBalanceFull 边界', () {
    test('常规金额', () {
      expect(formatBalance(1234.56, 'CNY'), '¥1234.56');
      expect(formatBalance(-1234.56, 'CNY'), '-¥1234.56');
      expect(formatBalanceFull(1234567.891, 'CNY'), '¥1,234,567.89');
    });

    test('万单位压缩与 0 值', () {
      expect(formatBalance(0, 'CNY'), '¥0.00');
      expect(formatBalance(9999.999, 'CNY'), '¥10000.00');
      expect(formatBalance(10000, 'CNY'), '¥1万');
      expect(formatBalance(-10000, 'CNY'), '-¥1万');
    });

    // 修复后(2026-10-11,批次 C2):formatBalanceFull 对**非有限值**加渲染
    // 兜底(返回 "--" 占位符),不再让账本卡余额渲染崩页。原 ADVERSE 断言
    // (NaN/Infinity 抛 RangeError)记录的是缺陷行为,修复后必须同步改
    // —— 审核记录 建议-9 已预告「未来加渲染兜底须同步改这三条绿锁」。
    // 源码:`lib/utils/format_utils.dart:116-127`。
    test('formatBalanceFull(NaN) 渲染兜底 "--"(原:抛 RangeError)', () {
      expect(() => formatBalanceFull(double.nan, 'CNY'), returnsNormally);
      expect(formatBalanceFull(double.nan, 'CNY'), '--',
          reason: '修复:非有限值显示占位符,不编造金额也不崩溃');
    });

    test('formatBalanceFull(Infinity) 渲染兜底 "--"(原:抛 RangeError)', () {
      expect(() => formatBalanceFull(double.infinity, 'CNY'), returnsNormally);
      expect(formatBalanceFull(double.infinity, 'CNY'), '--');
      expect(formatBalanceFull(double.negativeInfinity, 'CNY'), '--',
          reason: '负无穷同样非有限,走同一兜底');
    });

    // 修复后(2026-10-11,缺陷 H;审核记录 建议-9 预告的第三条绿锁):
    // 1e21 是**有限数**,原实现走 `toStringAsFixed(2).split('.')[1]` ——
    // `toStringAsFixed` 对 |v| >= 1e21 返回指数记法("1e+21",无小数点)
    // → 同样越界抛 RangeError。原断言 `throwsRangeError` 锁定的是**缺陷
    // 行为**,而 `addTransaction` 当时接受 1e21(有限数)→ 一条这样的行就让
    // `getLedgerStats().balance = -1e+21` 把账本卡整页打崩(缺陷 H 探针已复现)。
    //
    // 本次同源修复:① `formatBalanceFull` 在 `|v| >= magnitudeCeiling(1e21)`
    // 时改走科学计数法(宽度有界,不编造数值);② 写入侧新增 12 位整数上限
    // (`LocalTransactionRepository.maxWriteAmount`),把新脏值的入口堵住。
    // 断言随之改为「降级展示科学计数法,不崩」。
    test('formatBalanceFull(1e21) 降级科学计数法(原:抛 RangeError)', () {
      expect(() => formatBalanceFull(1e21, 'CNY'), returnsNormally,
          reason: '修复:≥1e21 不再走定点路径,引擎侧不再抛 RangeError');
      expect(formatBalanceFull(1e21, 'CNY'), '¥1.00e21',
          reason: '修复:降级为科学计数法(位数有界),不崩也不编造金额');
      expect(formatBalanceFull(-1e21, 'CNY'), '-¥1.00e21',
          reason: '符号沿用原口径');
      expect(formatBalanceFull(double.maxFinite, 'CNY'), '¥1.80e308',
          reason: '最大有限 double 同样安全降级(4 位有效数字打印)');
    });

    // 修复后(2026-10-11,跨审缺陷 7):紧凑格式此前对非有限值无守卫 ——
    // `nan >= 10` 为 false 走 1-10 万分支,`nan.toStringAsFixed(1)` = "NaN"
    // → 输出 "¥Infinity万" / "-¥NaN万" 这类脏字符串直接进 UI(不崩但编造
    // 不可读的"金额")。`formatBalanceFull` 早已降级 `--`,本次让紧凑路径与
    // 完整路径同口径(两条渲染路径读同一数据,行为必须一致)。
    // 断言随之改为「降级 `--`」—— 原 HARDENING 断言锁定的是修复前的脏行为,
    // 与本文件上方 formatBalanceFull 的同类断言(抛 RangeError → 返回 `--`)
    // 是同一改法,不是放宽:脏串被更强的占位符契约取代。
    test('formatBalance(NaN/Infinity) 渲染兜底 "--"(原: -¥NaN万 脏串)', () {
      expect(() => formatBalance(double.nan, 'CNY'), returnsNormally);
      expect(formatBalance(double.nan, 'CNY'), '--',
          reason: '修复:非有限值降级占位符,与 formatBalanceFull 同口径');
      expect(formatBalance(double.infinity, 'CNY'), '--');
      expect(formatBalance(double.negativeInfinity, 'CNY'), '--');
    });

    test('1e20 仍走定点(不越界)但输出 20 位整数', () {
      expect(formatBalanceFull(1e20, 'CNY'), '¥100,000,000,000,000,000,000.00',
          reason: 'HARDENING 标记:极大金额可显示但宽度爆炸');
    });

    test('未知币种 code 原样作符号', () {
      expect(formatBalanceFull(1.0, 'XYZ'), 'XYZ1.00');
      expect(() => formatBalanceFull(1.0, ''), returnsNormally);
    });

    test('-0.0 不显示负号(符号位被 abs 吃掉)', () {
      expect(formatBalanceFull(-0.0, 'CNY'), '¥0.00',
          reason: 'HARDENING 标记:balance >= 0 判定 -0.0 为真 → 无负号');
    });
  });

  group('币种别名:歧义与静默降级', () {
    test('ISO 码大小写/空白归一', () {
      expect(currencyCodeFromAlias('USD'), 'USD');
      expect(currencyCodeFromAlias('usd'), 'USD');
      expect(currencyCodeFromAlias(' Usd '), 'USD');
    });

    test('中文别名命中', () {
      expect(currencyCodeFromAlias('美元'), 'USD');
      expect(currencyCodeFromAlias('日元'), 'JPY');
      expect(currencyCodeFromAlias('欧元'), 'EUR');
    });

    test(r'裸 $ 走业界默认 USD;裸 ¥ 有意不猜 → null', () {
      expect(currencyCodeFromAlias(r'$'), 'USD');
      expect(currencyCodeFromAlias('¥'), isNull,
          reason: 'HARDENING 标记:¥ 真歧义按红线不猜,回退账本本位币');
      expect(currencyCodeFromAlias('￥'), isNull);
      expect(currencyCodeFromAlias('元'), isNull);
    });

    test('歧义符号 + 上下文消歧', () {
      expect(currencyCodeFromAlias('¥', disambiguateWith: {'CNY', 'USD'}), 'CNY');
      expect(
          currencyCodeFromAlias('¥', disambiguateWith: {'USD'}), isNull,
          reason: 'HARDENING 标记:上下文与候选无交集 → 不猜');
      expect(
          currencyCodeFromAlias(r'$', disambiguateWith: {'SGD'}), 'USD',
          reason: r'HARDENING 标记:裸 $ 先吃业界默认 USD,上下文 SGD 被忽略');
    });

    // HARDENING: 英文末词表把 'K'(MMK 缅元符号)当单词命中 ——
    // 「K」在记账里更常是「千」的简写。当前行为锁在这里。
    test("单字母 'K' 被解析为 MMK(缅元)", () {
      expect(currencyCodeFromAlias('K'), 'MMK',
          reason: "HARDENING 标记:单字母 K 命中 MMK 符号表,歧义未排除");
    });

    test('多候选别名无上下文 → null(卢比/比索/里拉/法郎)', () {
      expect(currencyCodeFromAlias('卢比'), isNull);
      expect(currencyCodeFromAlias('比索'), isNull);
      expect(currencyCodeFromAlias('里拉'), isNull);
      expect(currencyCodeFromAlias('法郎'), isNull);
    });

    test('多候选 + 唯一交集 → 命中', () {
      expect(currencyCodeFromAlias('卢比', disambiguateWith: {'INR', 'CNY'}),
          'INR');
    });

    test('全角 ISO 码 / 空 / 未知文本 → null', () {
      expect(currencyCodeFromAlias('ＵＳＤ'), isNull);
      expect(currencyCodeFromAlias(''), isNull);
      expect(currencyCodeFromAlias('   '), isNull);
      expect(currencyCodeFromAlias('喵'), isNull);
    });

    test(r"'US\$' 与 'US$' 的归一差异", () {
      expect(currencyCodeFromAlias(r'US$'), 'USD');
      expect(currencyCodeFromAlias(r'US\$'), isNull,
          reason: r'HARDENING 标记:转义写法 US\$ 不在符号表内');
    });

    test('isKnownCurrencyCode 大小写不敏感', () {
      expect(isKnownCurrencyCode('CNY'), isTrue);
      expect(isKnownCurrencyCode('cny'), isTrue);
      expect(isKnownCurrencyCode('XYZ'), isFalse);
    });
  });

  group('解析器列映射与表头探测', () {
    final generic = GenericBillParser();
    final alipay = AlipayBillParser();

    test('重复表头关键词:第一列胜出', () {
      expect(generic.mapColumns(['交易时间', '交易时间', '金额', '金额']),
          {'date': 0, 'amount': 2});
    });

    test('「收/支」优先于「类型」占位 type', () {
      expect(generic.mapColumns(['类型', '收/支', '金额'])['type'], 1);
    });

    test('「退款金额」不被当成「金额」', () {
      final m = generic.mapColumns(['金额', '退款金额', '交易时间']);
      expect(m['amount'], 0);
      expect(m['refund_amount'], 1);
    });

    test('空表头 / 空行不抛异常', () {
      expect(generic.mapColumns([]), isEmpty);
      expect(alipay.findHeaderRow([]), -1);
      expect(alipay.validateBillType([]), isFalse);
    });

    test('全角括号「金额（元）」可识别', () {
      expect(generic.mapColumns(['金额（元）', '交易时间'])['amount'], 0);
    });

    // HARDENING: 纯英文长表头 'Transaction Status' 不含任何已登记关键词
    // (`_normalizeToKey` 只认 noSpace == 'status' 的精确匹配),status 不映射。
    // 同理 'Amount' 命中(≈ 'amount')但复合词不行。当前行为锁在这里。
    test("'Transaction Status' 不映射 status(英文复合词盲区)", () {
      final m = generic.mapColumns(['Transaction Status', 'Amount']);
      expect(m['status'], isNull,
          reason: 'HARDENING 标记:英文复合表头不做 contains 匹配');
      expect(m['amount'], 1);
    });

    // ADVERSE FINDING: 少于 6 行的短文件无法通过列数一致性判据
    // (`consistentCount >= 5` 需要表头后至少 5 行同列数),
    // 于是带描述行的短文件把**描述行**当表头(return 0),
    // 列映射全空 → 所有行都缺 date/amount → 整份导入 invalid。
    // 源码:`lib/services/import/parsers/generic_parser.dart:65`。
    test('短文件(2 数据行)带描述行应找到真表头(行 1)', () {
      final rows = [
        ['我的账单导出'],
        ['日期', '金额', '类型', '备注'],
        ['2026-01-01', '10.00', '支出', '早餐'],
        ['2026-01-02', '20.00', '支出', '午餐'],
      ];
      expect(generic.findHeaderRow(rows), 1,
          reason: 'ADVERSE FINDING: 期望 1(真表头),'
              '实际 ${generic.findHeaderRow(rows)}(描述行)'
              '→ 列映射为空 → 整份文件导入无效');
    });

    test('对照:支付宝关键词路径可穿过短文件描述行', () {
      final rows = [
        ['支付宝交易记录明细查询'],
        ['交易时间', '商品说明', '金额', '收/支'],
        ['2026-01-01 10:00:00', '早餐', '10.00', '支出'],
      ];
      expect(alipay.findHeaderRow(rows), 1);
    });

    test('表头候选行非空字段 <3 被排除', () {
      final desc = List.filled(16, '');
      desc[0] = '支付宝交易记录明细查询';
      final hdr = List.generate(16, (i) => 'h$i');
      final data = List.generate(16, (i) => 'd$i');
      expect(
          generic.findHeaderRow(
              [desc, hdr, data, data, data, data, data, data]),
          1);
    });

    test('parseRow 越界列索引被跳过,不抛异常', () {
      expect(generic.parseRow(['1'], {'date': 0, 'amount': 5}), {'date': '1'});
    });

    test('normalizeStatus:退款优先于关闭(退款关闭 → refund)', () {
      expect(alipay.normalizeStatus('退款关闭'), 'refund');
      expect(alipay.normalizeStatus('部分退款'), 'refund');
      expect(WechatBillParser().normalizeStatus('已完成'), 'success');
      expect(WechatBillParser().normalizeStatus('待支付'), 'pending');
    });

    // HARDENING: 微信 normalizeStatus 不认「已支出/已收入」(只有支付宝认),
    // 原样透传状态词。下游 isNonBookableStatus 不匹配 → 按成功入账,侥幸安全。
    test('微信 parser 不归一「已支出」,原样透传', () {
      expect(WechatBillParser().normalizeStatus('已支出'), '已支出',
          reason: 'HARDENING 标记:微信分支缺 已支出/已收入,原样透传');
      expect(AlipayBillParser().normalizeStatus('已支出'), 'success');
    });
  });

  group('i18n 日期格式:DateFormat 在 RFC 之外的宽容度', () {
    test('DateFormat yyyy-MM-dd 对非法日期同样顺延', () {
      expect(DateFormat('yyyy-MM-dd').parse('2026-02-30'),
          DateTime(2026, 3, 2));
    });

    test('dd-MM-yyyy 对 "03-04-2026" 给出 2026-04-03', () {
      expect(DateFormat('dd-MM-yyyy').parse('03-04-2026'),
          DateTime(2026, 4, 3));
    });
  });
}
