import 'package:flutter_test/flutter_test.dart';
import 'package:smartbook/services/import/csv_parser.dart';
import 'package:smartbook/services/import/parsers/alipay_parser.dart';

void main() {
  // 2026-09 用户反馈的样本:新版支付宝 CSV(表头第 5 行,描述行与数据行
  // 同为 16 列,字段带引号+tab)
  const newFormatCsv = '''
支付宝交易记录明细查询,,,,,,,,,,,,,,,
账号:[test@example.com],,,,,,,,,,,,,,,,
起始日期:[2025-01-02 00:00:00]    终止日期:[2025-12-31 23:59:00],,,,,,,,,,,,,,,,
---------------------------------交易记录明细列表------------------------------------,,,,,,,,,,,,,,,
交易号                  ,商家订单号               ,交易创建时间              ,付款时间                ,最近修改时间              ,交易来源地     ,类型              ,交易对方            ,商品名称                ,金额（元）   ,收/支     ,交易状态    ,服务费（元）   ,成功退款（元）  ,备注                  ,资金状态
"2026090223001475961447900000\t","VO178834787220780000\t",2026/1/2 04:56,2026/1/2 04:56,2026/1/2 04:56,其他（包括阿里巴巴和外部商家）,即时到账交易          ,示例科技有限公司   ,示例-NFC充值      ,26.50,支出      ,交易成功    ,0,0,                    ,已支出
''';

  const oldFormatCsv = '''
支付宝交易记录明细查询,,,,,,,,,,,,,,,
---------------------------------交易记录明细列表------------------------------------,,,,,,,,,,,,,,,
交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注,
2025-09-04 10:00:00,餐饮美食,商家A,alipay_user,午饭,支出,25.00,余额宝,交易成功,2025090422001,2025090422002,,
''';

  group('AlipayBillParser 新版 CSV(2026-09 反馈)', () {
    test('表头识别为描述行之后(不误认第 0 行描述行)', () {
      final rows = CsvParser.parse(newFormatCsv);
      final headerRow = AlipayBillParser().findHeaderRow(rows);
      expect(headerRow, 4);
    });

    test('自动映射列正确(收/支 优先于类型,商品名称优先于商家订单号)', () {
      final rows = CsvParser.parse(newFormatCsv);
      final parser = AlipayBillParser();
      final headerRow = parser.findHeaderRow(rows);
      final mapping =
          parser.mapColumns(rows[headerRow].map((e) => e.trim()).toList());
      expect(mapping['date'], 2); // 交易创建时间
      expect(mapping['type'], 10); // 收/支 —— 不是"类型"(列7)
      expect(mapping['note'], 8); // 商品名称 —— 不是"商家订单号"(列1)
      expect(mapping['amount'], 9); // 金额（元）
    });

    test('数据行字段提取正确(引号+tab 脏字段)', () {
      final rows = CsvParser.parse(newFormatCsv);
      final parser = AlipayBillParser();
      final headerRow = parser.findHeaderRow(rows);
      final mapping =
          parser.mapColumns(rows[headerRow].map((e) => e.trim()).toList());
      final r = rows[headerRow + 1];
      expect(r[mapping['date']!].trim(), '2026/1/2 04:56');
      expect(r[mapping['type']!].trim(), '支出');
      expect(r[mapping['amount']!].trim(), '26.50');
      expect(r[mapping['note']!].trim(), '示例-NFC充值');
    });
  });

  group('AlipayBillParser 旧版 CSV 回归', () {
    test('旧版表头仍能识别且映射正确', () {
      final rows = CsvParser.parse(oldFormatCsv);
      final parser = AlipayBillParser();
      final headerRow = parser.findHeaderRow(rows);
      expect(headerRow, 2);
      final mapping =
          parser.mapColumns(rows[headerRow].map((e) => e.trim()).toList());
      expect(mapping['date'], 0);
      expect(mapping['category'], 1);
      expect(mapping['note'], 4); // 商品说明
      expect(mapping['type'], 5); // 收/支
      expect(mapping['amount'], 6);
    });
  });
}
