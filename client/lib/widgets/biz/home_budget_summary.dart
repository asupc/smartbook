import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/budget_repository.dart';
import '../../providers/budget_providers.dart';
import '../../styles/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../pages/budget/budget_page.dart';

/// 首页 Header 底部预算进度条
/// 替代 header 的 border-bottom，百分比显示在进度条中间
/// - 有预算 + 开关开启：细进度条（~3px）+ 百分比居中
/// - 无预算 or 开关关闭：返回 SizedBox.shrink()
class HomeBudgetSummary extends ConsumerWidget {
  const HomeBudgetSummary({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(homeBudgetCardEnabledProvider);
    if (!enabled) return const SizedBox.shrink();

    final overviewAsync = ref.watch(budgetOverviewProvider);

    // 用 valueOrNull 拿当前/历史 value,绕开 invalidate 期间的 loading 闪烁:
    // - 冷启动首次 fetch:overview = null → 返 shrink(没旧数据可显示)
    // - 增删 tx 触发 invalidate:Riverpod AsyncLoading 自带 previous value,
    //   valueOrNull 仍返回上次的 BudgetOverview → 进度条不消失
    // - 数据 fetch 出错:value 为 null → 走 shrink,但 previous 保留时也会
    //   继续渲染旧数据,符合「网络抖动也别闪」的预期
    final overview = overviewAsync.valueOrNull;
    if (overview == null || overview.totalBudget == null) {
      return const SizedBox.shrink();
    }
    return _BudgetProgressBar(usage: overview.totalBudget!);
  }
}

/// 进度条替代 header bottom border，百分比居中显示
class _BudgetProgressBar extends ConsumerWidget {
  final BudgetUsage usage;
  const _BudgetProgressBar({required this.usage});

  Color _progressColor(double rate) {
    if (rate >= 1.0) return const Color(0xFFB71C1C);
    if (rate >= 0.9) return const Color(0xFFD32F2F);
    if (rate >= 0.7) return const Color(0xFFF57C00);
    return const Color(0xFF4CAF50);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = BeeTokens.isDark(context);
    final rate = usage.rate.clamp(0.0, 1.5);
    final displayRate = (usage.rate * 100).toInt();
    final color = _progressColor(usage.rate);
    const barHeight = 14.0;

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const BudgetPage()),
        );
      },
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: barHeight,
        child: Stack(
          children: [
            // 背景轨道
            Positioned.fill(
              child: Container(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.04),
              ),
            ),
            // 进度填充
            FractionallySizedBox(
              widthFactor: rate.clamp(0.0, 1.0),
              child: Container(
                color: color.withValues(alpha: isDark ? 0.7 : 0.5),
              ),
            ),
            // 百分比居中
            Center(
              child: Text(
                '${AppLocalizations.of(context).budgetUsed} $displayRate%',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white70 : Colors.black54,
                  height: 1.0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
