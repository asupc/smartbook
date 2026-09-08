import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/theme_providers.dart';
import 'format_money.dart';

class DaySectionHeader extends ConsumerWidget {
  final String dateText; // yyyy-MM-dd
  final double income;
  final double expense;
  final bool? hide; // 改为可选,null时使用全局状态
  const DaySectionHeader(
      {super.key,
      required this.dateText,
      required this.income,
      required this.expense,
      this.hide});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    String getWeekday(String yyyyMMdd) {
      try {
        final dt = DateTime.parse(yyyyMMdd);
        final l10n = AppLocalizations.of(context);
        switch (dt.weekday) {
          case DateTime.monday:
            return l10n.commonWeekdayMonday;
          case DateTime.tuesday:
            return l10n.commonWeekdayTuesday;
          case DateTime.wednesday:
            return l10n.commonWeekdayWednesday;
          case DateTime.thursday:
            return l10n.commonWeekdayThursday;
          case DateTime.friday:
            return l10n.commonWeekdayFriday;
          case DateTime.saturday:
            return l10n.commonWeekdaySaturday;
          case DateTime.sunday:
            return l10n.commonWeekdaySunday;
          default:
            return '';
        }
      } catch (_) {
        return '';
      }
    }

    // 优先使用传入的hide,否则使用全局状态
    final shouldHide = hide ?? ref.watch(hideAmountsProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    String fmt(double v) => v == 0 ? '' : formatMoneyCompact(v, maxDecimals: 2);
    final week = getWeekday(dateText);

    // 解析日期以显示更亲切的格式（如：09月08日 今天 · 星期二）
    String formattedDate = dateText;
    String relativeTag = '';
    try {
      final dt = DateTime.parse(dateText);
      final now = DateTime.now();
      final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
      final isYesterday = dt.year == now.year && dt.month == now.month && dt.day == (now.day - 1);
      if (isToday) {
        relativeTag = '今天';
      } else if (isYesterday) {
        relativeTag = '昨天';
      }
      formattedDate = '${dt.month.toString().padLeft(2, '0')}月${dt.day.toString().padLeft(2, '0')}日';
    } catch (_) {}

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Text(
                formattedDate,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
              if (relativeTag.isNotEmpty) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: ref.watch(primaryColorProvider).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    relativeTag,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                      color: ref.watch(primaryColorProvider),
                    ),
                  ),
                ),
              ],
              if (week.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  week,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white.withValues(alpha: 0.45) : const Color(0xFF94A3B8),
                  ),
                ),
              ],
            ],
          ),
          Row(
            children: [
              if (shouldHide == false && fmt(expense).isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '支 ¥${fmt(expense)}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: isDark ? Colors.white70 : const Color(0xFF475569),
                    ),
                  ),
                ),
              if (shouldHide == false && fmt(income).isNotEmpty) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF064E3B).withValues(alpha: 0.5)
                        : const Color(0xFFECFDF5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '收 ¥${fmt(income)}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: isDark ? const Color(0xFF34D399) : const Color(0xFF059669),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
