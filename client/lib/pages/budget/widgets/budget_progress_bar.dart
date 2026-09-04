import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../styles/tokens.dart';
import '../../../utils/ui_scale_extensions.dart';

/// 预算进度条组件
class BudgetProgressBar extends ConsumerWidget {
  final double used;
  final double budget;
  final bool showLabel;
  final double height;
  final String currencySymbol;

  const BudgetProgressBar({
    required this.used,
    required this.budget,
    this.showLabel = true,
    this.height = 8,
    this.currencySymbol = '¥',
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rate = budget > 0 ? (used / budget).clamp(0.0, 1.0) : 0.0;
    final color = _getColor(rate);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(height / 2),
          child: LinearProgressIndicator(
            value: rate,
            backgroundColor: color.withValues(alpha: 0.2),
            valueColor: AlwaysStoppedAnimation(color),
            minHeight: height.scaled(context, ref),
          ),
        ),
        if (showLabel) ...[
          SizedBox(height: 4.0.scaled(context, ref)),
          Text(
            '$currencySymbol${used.toStringAsFixed(0)} / $currencySymbol${budget.toStringAsFixed(0)}',
            style: TextStyle(
              fontSize: 12,
              color: BeeTokens.textSecondary(context),
            ),
          ),
        ],
      ],
    );
  }

  Color _getColor(double rate) {
    if (rate >= 1.0) return Colors.red[700]!;
    if (rate >= 0.9) return Colors.red;
    if (rate >= 0.7) return Colors.orange;
    return Colors.green;
  }
}
