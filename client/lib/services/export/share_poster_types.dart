/// 分享海报类型和数据模型
library;

/// 海报类型枚举
enum PosterType {
  /// 年度账单总结
  yearSummary,

  /// 月度账单总结
  monthSummary,

  /// 账本总结
  ledgerSummary,

  /// 应用推广海报
  appPromo,

  /// 用户档案海报
  userProfile,
}

/// 海报类型扩展 - 用于UI展示
extension PosterTypeExtension on PosterType {
  String get displayName {
    switch (this) {
      case PosterType.yearSummary:
        return '年度总结';
      case PosterType.monthSummary:
        return '月度总结';
      case PosterType.ledgerSummary:
        return '账本总结';
      case PosterType.appPromo:
        return '分享应用';
      case PosterType.userProfile:
        return '我的档案';
    }
  }

  String get description {
    switch (this) {
      case PosterType.yearSummary:
        return '分享你的年度记账成就';
      case PosterType.monthSummary:
        return '分享你的月度财务报告';
      case PosterType.ledgerSummary:
        return '分享你的账本统计';
      case PosterType.appPromo:
        return '推荐智记给好友';
      case PosterType.userProfile:
        return '分享你的记账档案';
    }
  }
}

/// 年度总结海报数据
class YearSummaryPosterData {
  /// 年份
  final int year;

  /// 记账天数
  final int recordDays;

  /// 记账笔数
  final int recordCount;

  /// 总收入
  final double totalIncome;

  /// 总支出
  final double totalExpense;

  /// TOP 3 支出分类
  final List<CategoryTotal> topExpenseCategories;

  /// TOP 3 收入分类
  final List<CategoryTotal> topIncomeCategories;

  /// 月均支出
  final double avgMonthlyExpense;

  /// 月均收入
  final double avgMonthlyIncome;

  /// 最高支出月份 (1-12)
  final int? maxExpenseMonth;

  /// 最高支出金额
  final double? maxExpenseAmount;

  /// 结余
  final double balance;

  const YearSummaryPosterData({
    required this.year,
    required this.recordDays,
    required this.recordCount,
    required this.totalIncome,
    required this.totalExpense,
    required this.topExpenseCategories,
    required this.topIncomeCategories,
    required this.avgMonthlyExpense,
    required this.avgMonthlyIncome,
    this.maxExpenseMonth,
    this.maxExpenseAmount,
    required this.balance,
  });
}

/// 月度总结海报数据
class MonthSummaryPosterData {
  /// 年份
  final int year;

  /// 月份 (1-12)
  final int month;

  /// 记账笔数
  final int recordCount;

  /// 总收入
  final double totalIncome;

  /// 总支出
  final double totalExpense;

  /// TOP 3 支出分类
  final List<CategoryTotal> topExpenseCategories;

  /// TOP 3 收入分类
  final List<CategoryTotal> topIncomeCategories;

  /// 日均支出
  final double avgDailyExpense;

  /// 结余
  final double balance;

  /// 同比上月支出变化率 (-1.0 到 1.0,如 0.1 表示增长10%)
  final double? expenseChangeRate;

  const MonthSummaryPosterData({
    required this.year,
    required this.month,
    required this.recordCount,
    required this.totalIncome,
    required this.totalExpense,
    required this.topExpenseCategories,
    required this.topIncomeCategories,
    required this.avgDailyExpense,
    required this.balance,
    this.expenseChangeRate,
  });
}

/// 账本总结海报数据
class LedgerSummaryPosterData {
  /// 账本名称
  final String ledgerName;

  /// 记账天数
  final int recordDays;

  /// 记账笔数
  final int recordCount;

  /// 总收入
  final double totalIncome;

  /// 总支出
  final double totalExpense;

  /// TOP 3 支出分类
  final List<CategoryTotal> topExpenseCategories;

  /// TOP 3 收入分类
  final List<CategoryTotal> topIncomeCategories;

  /// 最早记账日期
  final DateTime? firstRecordDate;

  /// 最晚记账日期
  final DateTime? lastRecordDate;

  /// 结余
  final double balance;

  const LedgerSummaryPosterData({
    required this.ledgerName,
    required this.recordDays,
    required this.recordCount,
    required this.totalIncome,
    required this.totalExpense,
    required this.topExpenseCategories,
    required this.topIncomeCategories,
    this.firstRecordDate,
    this.lastRecordDate,
    required this.balance,
  });
}

/// 分类汇总数据
class CategoryTotal {
  /// 分类ID (可能为null,表示未分类)
  final int? id;

  /// 分类名称
  final String name;

  /// 分类图标
  final String? icon;

  /// 总金额
  final double total;

  /// 占比 (0.0 到 1.0)
  final double percentage;

  const CategoryTotal({
    this.id,
    required this.name,
    this.icon,
    required this.total,
    required this.percentage,
  });
}

/// 用户档案海报数据
class UserProfilePosterData {
  /// 用户头像路径 (可为null,表示使用默认头像)
  final String? avatarPath;

  /// 记账天数
  final int recordDays;

  /// 记账笔数
  final int recordCount;

  /// 账本数量
  final int ledgerCount;

  /// 当前账本名称
  final String ledgerName;

  /// 开始记账日期
  final DateTime? firstRecordDate;

  const UserProfilePosterData({
    this.avatarPath,
    required this.recordDays,
    required this.recordCount,
    required this.ledgerCount,
    required this.ledgerName,
    this.firstRecordDate,
  });
}
