// format_utils 紧凑金额渲染的非有限值兜底(跨审缺陷 7)。
//
// `formatBalance`(紧凑,万/k/M 压缩)此前对 NaN/±Infinity 无守卫:
// `abs()` 比较后落在压缩分支,渲染出 `¥Infinity万` / `-¥NaN万` —— 不崩但
// 编造了不可读的"金额"。`formatBalanceFull` 早已降级为 `--`,两条渲染路径
// 口径必须一致(账本卡/账户卡在不同显示模式下读不同函数)。
import 'package:flutter_test/flutter_test.dart';
import 'package:smartbook/utils/format_utils.dart';

void main() {
  group('formatBalance 非有限值兜底', () {
    test('NaN → "--"(原: -¥NaN万)', () {
      expect(() => formatBalance(double.nan, 'CNY'), returnsNormally);
      expect(formatBalance(double.nan, 'CNY'), '--',
          reason: '缺陷 7: 不编造金额,与 formatBalanceFull 同口径降级');
      expect(formatBalance(double.nan, 'USD', isChineseLocale: false), '--',
          reason: '缺陷 7: 非中文压缩路径(k/M)同样兜底');
    });

    test('±Infinity → "--"(原: ¥Infinity万)', () {
      expect(() => formatBalance(double.infinity, 'CNY'), returnsNormally);
      expect(formatBalance(double.infinity, 'CNY'), '--');
      expect(formatBalance(double.negativeInfinity, 'CNY'), '--',
          reason: '缺陷 7: 负无穷同样非有限,走同一兜底');
      expect(formatBalance(double.infinity, 'CNY', isChineseLocale: false),
          '--');
    });

    test('与 formatBalanceFull 口径一致', () {
      for (final v in [double.nan, double.infinity, double.negativeInfinity]) {
        expect(formatBalance(v, 'CNY'), formatBalanceFull(v, 'CNY'),
            reason: '缺陷 7: 紧凑与完整渲染器对非有限值必须同口径');
      }
    });

    test('有限值行为不变(回归)', () {
      expect(formatBalance(0, 'CNY'), '¥0.00');
      expect(formatBalance(9999.999, 'CNY'), '¥10000.00');
      expect(formatBalance(10000, 'CNY'), '¥1万');
      expect(formatBalance(-10000, 'CNY'), '-¥1万');
      expect(formatBalance(1000, 'USD', isChineseLocale: false), '\$1k');
      expect(formatBalance(1000000, 'USD', isChineseLocale: false), '\$1M');
    });
  });
}
