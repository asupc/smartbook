/// 账单解析器抽象接口
abstract class BillParser {
  /// 解析器名称
  String get name;

  /// 查找表头所在行
  /// 返回表头行索引，如果未找到返回 -1
  int findHeaderRow(List<List<String>> rows);

  /// 自动映射列到字段
  /// 返回列索引到字段名的映射
  Map<String, int> mapColumns(List<String> headerRow);

  /// 解析单行数据
  /// 返回解析后的交易数据 Map
  Map<String, dynamic>? parseRow(
    List<String> row,
    Map<String, int> columnMapping,
  );

  /// 验证是否为该类型的账单
  /// 用于自动识别账单类型
  bool validateBillType(List<List<String>> rows);

  /// provider 归一化后的短名称，写入 ImportTransaction.provider。
  String get providerKey => name.toLowerCase();

  /// 将平台状态归一为统一状态词，供导入服务过滤非成功行。
  String? normalizeStatus(String? raw) =>
      raw?.trim().isEmpty == true ? null : raw?.trim();

  /// 将平台退款金额归一为正数；空值/非法值返回 null。
  ///
  /// 删除集包含半/全角货币符号、千分位、正负号,以及 **Unicode 负号变体**:
  /// `−`(U+2212 数学减号)、`－`(U+FF0D 全角减号)、`–`(U+2013 en dash)、
  /// `—`(U+2014 em dash)。这些是 `double.tryParse` 不认的字符,不删掉会让
  /// 整笔退款金额归一成 null(下游按"无退款"处理,静默丢数据)。
  double? normalizeRefundAmount(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    return double.tryParse(
      raw.replaceAll(RegExp(r'[¥￥$,+，\u2212\uFF0D\u2013\u2014]'), '').trim(),
    )?.abs();
  }
}

/// 解析结果
class ParseResult {
  final int headerRowIndex;
  final Map<String, int> columnMapping;
  final List<Map<String, dynamic>> transactions;
  final List<String> errors;

  ParseResult({
    required this.headerRowIndex,
    required this.columnMapping,
    required this.transactions,
    this.errors = const [],
  });

  bool get hasErrors => errors.isNotEmpty;
}
