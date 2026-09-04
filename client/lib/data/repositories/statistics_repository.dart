import '../db.dart' show Category;

/// 统计Repository接口
/// 定义统计相关的所有数据操作
abstract class StatisticsRepository {
  /// 按分类统计（指定时间范围和类型）
  Future<List<({int? id, String name, String? icon, double total})>> totalsByCategory({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  });

  /// 按分类统计（支持二级分类展开）
  Future<List<({int? id, String name, String? icon, int? parentId, int level, double total})>>
      totalsByCategoryWithHierarchy({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  });

  /// 按天统计（指定时间范围和类型）
  Future<List<({DateTime day, double total})>> totalsByDay({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  });

  /// 按月统计（指定年份和类型）
  ///
  /// [month] 为周期标签,约定传 DateTime(year, month, 1);实际范围由账本
  /// monthStartDay 决定:[y-m-起始日, y-(m+1)-起始日)。
  /// 返回的 12 桶为周期标签月,范围 = 账本起始日定义的
  /// [当年1月周期起点, 次年1月周期起点)。
  Future<List<({DateTime month, double total})>> totalsByMonth({
    required int ledgerId,
    required String type,
    required int year,
  });

  /// 按年统计（所有年份，指定类型）
  Future<List<({int year, double total})>> totalsByYearSeries({
    required int ledgerId,
    required String type,
  });

  /// 获取指定时间范围的收支总额
  Future<(double income, double expense)> totalsInRange({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
  });

  /// 获取指定月份的收支总额
  ///
  /// [month] 为周期标签,约定传 DateTime(year, month, 1);实际范围由账本
  /// monthStartDay 决定:[y-m-起始日, y-(m+1)-起始日)。
  Future<(double income, double expense)> monthlyTotals({
    required int ledgerId,
    required DateTime month,
  });

  /// 获取指定年份的收支总额
  Future<(double income, double expense)> yearlyTotals({
    required int ledgerId,
    required int year,
  });

  /// 按账户统计(指定时间范围和类型;口径与 [totalsByDay] 一致:
  /// excludeFromStats=false、原生币金额 nativeAmount ?? amount)。
  /// 无账户(account_id 为空)归为一行 accountId=null。
  Future<List<({int? accountId, double total})>> totalsByAccount({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  });

  /// 按备注(商户)聚合消费金额 TOP [limit](仅支出口径,空备注不聚合)。
  /// 备注来自 AI 商家名([bill_creation_service]);M5 商户 Top 列表。
  Future<List<({String note, double total})>> totalsByNote({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
    int limit = 10,
  });

  /// §7 共享账本:返回该账本的 SharedLedgerCategories 行转 synthetic
  /// db.Category 索引(key = syntheticIdForSyncId(syncId))。统计页拿
  /// 这个 map 给 totalsByCategory 返回的 negative id 配上图标 / 自定义
  /// 图标路径。单人账本返回空 map。
  Future<Map<int, Category>> getSharedSyntheticCategoriesForLedger(
      int ledgerId);
}
