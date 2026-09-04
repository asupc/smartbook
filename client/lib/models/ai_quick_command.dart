import 'package:flutter/material.dart';

/// AI快捷指令数据类型枚举
enum QuickCommandDataType {
  /// 最近交易记录
  recentTransactions,

  /// 本月统计数据
  monthlyStats,

  /// 分类统计
  categoryStats,

  /// 近期趋势
  recentTrends,

  /// 无需数据
  none,
}

/// AI快捷指令模型
class AIQuickCommand {
  /// 指令ID
  final String id;

  /// 图标
  final IconData icon;

  /// 标题的i18n key
  final String titleKey;

  /// 描述的i18n key（可选）
  final String? descriptionKey;

  /// Prompt模板的i18n key
  final String promptTemplateKey;

  /// 需要的数据类型
  final List<QuickCommandDataType> requiredData;

  /// 是否显示
  final bool enabled;

  const AIQuickCommand({
    required this.id,
    required this.icon,
    required this.titleKey,
    this.descriptionKey,
    required this.promptTemplateKey,
    this.requiredData = const [],
    this.enabled = true,
  });
}

/// 预设的快捷指令列表
class AIQuickCommands {
  /// 财务健康分析
  static const financialHealth = AIQuickCommand(
    id: 'financial_health',
    icon: Icons.health_and_safety,
    titleKey: 'aiQuickCommandFinancialHealthTitle',
    descriptionKey: 'aiQuickCommandFinancialHealthDesc',
    promptTemplateKey: 'aiQuickCommandFinancialHealthPrompt',
    requiredData: [
      QuickCommandDataType.monthlyStats,
      QuickCommandDataType.recentTrends,
    ],
  );

  /// 本月支出总结
  static const monthlyExpenseSummary = AIQuickCommand(
    id: 'monthly_expense_summary',
    icon: Icons.calendar_month,
    titleKey: 'aiQuickCommandMonthlyExpenseTitle',
    descriptionKey: 'aiQuickCommandMonthlyExpenseDesc',
    promptTemplateKey: 'aiQuickCommandMonthlyExpensePrompt',
    requiredData: [
      QuickCommandDataType.monthlyStats,
      QuickCommandDataType.categoryStats,
    ],
  );

  /// 分类占比分析
  static const categoryAnalysis = AIQuickCommand(
    id: 'category_analysis',
    icon: Icons.pie_chart,
    titleKey: 'aiQuickCommandCategoryAnalysisTitle',
    descriptionKey: 'aiQuickCommandCategoryAnalysisDesc',
    promptTemplateKey: 'aiQuickCommandCategoryAnalysisPrompt',
    requiredData: [
      QuickCommandDataType.categoryStats,
    ],
  );

  /// 预算规划建议
  static const budgetPlanning = AIQuickCommand(
    id: 'budget_planning',
    icon: Icons.savings,
    titleKey: 'aiQuickCommandBudgetPlanningTitle',
    descriptionKey: 'aiQuickCommandBudgetPlanningDesc',
    promptTemplateKey: 'aiQuickCommandBudgetPlanningPrompt',
    requiredData: [
      QuickCommandDataType.monthlyStats,
      QuickCommandDataType.recentTrends,
    ],
  );

  /// 异常支出提醒
  static const abnormalExpense = AIQuickCommand(
    id: 'abnormal_expense',
    icon: Icons.warning_amber,
    titleKey: 'aiQuickCommandAbnormalExpenseTitle',
    descriptionKey: 'aiQuickCommandAbnormalExpenseDesc',
    promptTemplateKey: 'aiQuickCommandAbnormalExpensePrompt',
    requiredData: [
      QuickCommandDataType.recentTransactions,
      QuickCommandDataType.monthlyStats,
    ],
  );

  /// 省钱小贴士
  static const savingTips = AIQuickCommand(
    id: 'saving_tips',
    icon: Icons.lightbulb_outline,
    titleKey: 'aiQuickCommandSavingTipsTitle',
    descriptionKey: 'aiQuickCommandSavingTipsDesc',
    promptTemplateKey: 'aiQuickCommandSavingTipsPrompt',
    requiredData: [
      QuickCommandDataType.categoryStats,
      QuickCommandDataType.recentTrends,
    ],
  );

  /// 获取所有启用的快捷指令
  static List<AIQuickCommand> getAllCommands() {
    return [
      financialHealth,
      monthlyExpenseSummary,
      categoryAnalysis,
      budgetPlanning,
      abnormalExpense,
      savingTips,
    ].where((cmd) => cmd.enabled).toList();
  }
}
