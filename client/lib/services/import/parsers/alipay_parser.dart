import 'generic_parser.dart';

/// 支付宝账单解析器
class AlipayBillParser extends GenericBillParser {
  @override
  String get name => 'Alipay';

  @override
  int findHeaderRow(List<List<String>> rows) {
    if (rows.isEmpty) return -1;

    // 优先：通过关键词查找支付宝表头。
    // 旧版表头:交易时间/交易分类/对方账号/商品说明/收/支/金额...
    // 新版表头:交易号/商家订单号/交易创建时间/.../商品名称/金额（元）/收/支/...
    // 两者分别探测,新版用"交易创建时间+金额+收/支"组合命中。
    final keywordIndex = _findHeaderRow(rows, ['交易时间', '商品说明']) ??
        _findHeaderRow(rows, ['交易创建时间', '金额', '收/支']) ??
        _findHeaderRow(rows, ['交易号', '商家订单号']);
    if (keywordIndex != null) return keywordIndex;

    // 兜底：使用列数一致性规则（继承自通用解析器）
    return super.findHeaderRow(rows);
  }

  @override
  bool validateBillType(List<List<String>> rows) {
    // 验证是否为支付宝账单：
    // 1. 能找到包含"交易时间"和"商品说明"的表头行
    // 2. 或前几行包含"支付宝"相关标识
    final headerRowIndex = _findHeaderRow(rows, ['交易时间', '商品说明']);
    if (headerRowIndex != null) return true;

    // 检查前10行是否包含"支付宝"相关文字
    final maxRows = rows.length < 10 ? rows.length : 10;
    for (int i = 0; i < maxRows; i++) {
      final rowText = rows[i].join('');
      if (rowText.contains('支付宝') || rowText.contains('alipay')) {
        return true;
      }
    }

    return false;
  }

  /// 在前30行中查找包含指定关键词的行
  int? _findHeaderRow(List<List<String>> rows, List<String> keywords) {
    final maxRows = rows.length < 30 ? rows.length : 30;
    for (int i = 0; i < maxRows; i++) {
      final row = rows[i];
      if (row.isEmpty) continue;

      final rowStr = row.map((e) => e.toString().trim()).toList();

      // 检查是否包含所有关键词
      bool containsAll = true;
      for (final keyword in keywords) {
        bool found = false;
        for (final cell in rowStr) {
          if (cell.contains(keyword)) {
            found = true;
            break;
          }
        }
        if (!found) {
          containsAll = false;
          break;
        }
      }

      if (containsAll) {
        return i;
      }
    }
    return null;
  }
}
