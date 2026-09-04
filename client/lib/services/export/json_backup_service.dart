/// JSON 结构化导出(M5-D,文档 plan §M5 任务 4「导出结构化账单 + 备份」)。
///
/// 生成自包含的备份 JSON:账本元信息 + 账户 + 分类 + 交易(含标签/附件名)。
/// 设计取舍:
/// - 纯同步函数(输入已是 json-ready 的结构),便于单测;
/// - **不含** 截图/原文(隐私,见 M5-E)与周期记账/预算(由配置 YAML 导出
///   覆盖 —— 数据管理页「导入导出」已有 config_import_export_page);
/// - 交易行以 Drift 行映射为 [BackupTx] 轻量记录,结构可回读。
library;

/// 一笔交易的备份表示(由调用方从 Drift 行映射)。
class BackupTx {
  final int id;
  final String type; // expense / income / transfer
  final double amount;
  final int? categoryId;
  final int? accountId;
  final int? toAccountId;
  final DateTime happenedAt;
  final String? note;
  final String? currencyCode;
  final double? nativeAmount;
  final bool excludeFromStats;
  final List<String> tags; // 标签名
  final List<String> attachments; // 附件文件名

  const BackupTx({
    required this.id,
    required this.type,
    required this.amount,
    this.categoryId,
    this.accountId,
    this.toAccountId,
    required this.happenedAt,
    this.note,
    this.currencyCode,
    this.nativeAmount,
    this.excludeFromStats = false,
    this.tags = const [],
    this.attachments = const [],
  });
}

/// 构建备份 JSON(纯同步;调用方负责 jsonEncode 与落盘)。
Map<String, dynamic> buildBackupJson({
  required ({int id, String name, String currency}) ledger,
  required List<({int id, String name, String type, String currency})>
      accounts,
  required List<({int id, String name, String kind, int? parentId, int level})>
      categories,
  required List<BackupTx> transactions,
  String? exportedAt,
}) {
  return {
    'format': 'smartbook-backup',
    'version': 1,
    'exportedAt': exportedAt ?? DateTime.now().toIso8601String(),
    'ledger': {
      'id': ledger.id,
      'name': ledger.name,
      'currency': ledger.currency,
    },
    'accounts': [
      for (final a in accounts)
        {
          'id': a.id,
          'name': a.name,
          'type': a.type,
          'currency': a.currency,
        },
    ],
    'categories': [
      for (final c in categories)
        {
          'id': c.id,
          'name': c.name,
          'kind': c.kind,
          'parentId': c.parentId,
          'level': c.level,
        },
    ],
    'transactions': [
      for (final t in transactions)
        {
          'id': t.id,
          'type': t.type,
          'amount': t.amount,
          if (t.categoryId != null) 'categoryId': t.categoryId,
          if (t.accountId != null) 'accountId': t.accountId,
          if (t.toAccountId != null) 'toAccountId': t.toAccountId,
          'happenedAt': t.happenedAt.toIso8601String(),
          if (t.note != null && t.note!.isNotEmpty) 'note': t.note,
          if (t.currencyCode != null && t.currencyCode!.isNotEmpty)
            'currencyCode': t.currencyCode,
          if (t.nativeAmount != null) 'nativeAmount': t.nativeAmount,
          'excludeFromStats': t.excludeFromStats,
          'tags': t.tags,
          'attachments': t.attachments,
        },
    ],
  };
}
