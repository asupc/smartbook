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
