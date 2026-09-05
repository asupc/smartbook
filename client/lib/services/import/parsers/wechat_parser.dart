import 'generic_parser.dart';

/// 微信账单解析器
class WechatBillParser extends GenericBillParser {
  @override
  String get name => 'WeChat';

  @override
  int findHeaderRow(List<List<String>> rows) {
    if (rows.isEmpty) return -1;

    // 优先：通过关键词查找微信表头
    final keywordIndex = _findHeaderRow(rows, ['交易时间', '交易类型']);
    if (keywordIndex != null) return keywordIndex;

    // 兜底：使用列数一致性规则（继承自通用解析器）
    return super.findHeaderRow(rows);
  }

  @override
  bool validateBillType(List<List<String>> rows) {
    // 验证是否为微信账单：
    // 1. 能找到包含"交易时间"和"交易类型"的表头行
    // 2. 或前几行包含"微信"相关标识
    final headerRowIndex = _findHeaderRow(rows, ['交易时间', '交易类型']);
    if (headerRowIndex != null) return true;

    // 检查前10行是否包含"微信支付"相关文字
    final maxRows = rows.length < 10 ? rows.length : 10;
    for (int i = 0; i < maxRows; i++) {
      final rowText = rows[i].join('');
      if (rowText.contains('微信支付') ||
          rowText.contains('微信') ||
          rowText.contains('wechat')) {
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

  @override
  Map<String, int> mapColumns(List<String> headerRow) {
    final mapping = super.mapColumns(headerRow);
    _ensure(mapping, headerRow, 'date', ['交易时间', '支付时间']);
    _ensure(mapping, headerRow, 'external_id', ['交易单号', '商户单号', '订单号']);
    _ensure(mapping, headerRow, 'status', ['当前状态', '交易状态', '支付状态']);
    _ensure(mapping, headerRow, 'refund_amount', ['退款金额', '退款']);
    return mapping;
  }

  @override
  String get providerKey => 'wechat';

  @override
  String? normalizeStatus(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;
    final lower = value.toLowerCase();
    if (lower.contains('refund') || value.contains('退款')) return 'refund';
    if (lower.contains('success') ||
        value.contains('成功') ||
        value.contains('已完成')) return 'success';
    if (lower.contains('pending') ||
        value.contains('处理中') ||
        value.contains('待支付')) return 'pending';
    if (lower.contains('fail') || value.contains('失败')) return 'failed';
    if (lower.contains('cancel') ||
        value.contains('关闭') ||
        value.contains('取消')) return 'closed';
    return value;
  }

  void _ensure(
    Map<String, int> mapping,
    List<String> headers,
    String field,
    List<String> keywords,
  ) {
    if (mapping.containsKey(field)) return;
    for (var i = 0; i < headers.length; i++) {
      if (keywords.any((keyword) => headers[i].contains(keyword))) {
        mapping[field] = i;
        return;
      }
    }
  }
}
