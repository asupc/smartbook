import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../providers/theme_providers.dart';

/// PIN 码圆点指示器
class PinDotIndicator extends ConsumerWidget {
  final int length;
  final int filledCount;
  final bool isError;

  const PinDotIndicator({
    super.key,
    this.length = 4,
    required this.filledCount,
    this.isError = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final primaryColor = ref.watch(primaryColorProvider);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (index) {
        final filled = index < filledCount;
        final dotSize = 14.0.scaled(context, ref);
        final color = isError
            ? BeeTokens.error(context)
            : (filled ? primaryColor : BeeTokens.border(context));

        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: EdgeInsets.symmetric(horizontal: 10.0.scaled(context, ref)),
          width: dotSize,
          height: dotSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? color : Colors.transparent,
            border: Border.all(color: color, width: 2),
          ),
        );
      }),
    );
  }
}

/// 数字键盘
class NumberPad extends ConsumerWidget {
  final ValueChanged<String> onNumberTap;
  final VoidCallback onDelete;
  final VoidCallback? onBiometric;
  final bool showBiometric;

  const NumberPad({
    super.key,
    required this.onNumberTap,
    required this.onDelete,
    this.onBiometric,
    this.showBiometric = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['bio', '0', 'del'],
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: keys.map((row) {
        return Padding(
          padding: EdgeInsets.symmetric(vertical: 6.0.scaled(context, ref)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: row.map((key) {
              if (key == 'bio') {
                return _buildKeyButton(
                  context,
                  ref,
                  child: showBiometric
                      ? Icon(Icons.fingerprint,
                          size: 28.0.scaled(context, ref),
                          color: BeeTokens.textPrimary(context))
                      : const SizedBox.shrink(),
                  onTap: showBiometric ? onBiometric : null,
                );
              }
              if (key == 'del') {
                return _buildKeyButton(
                  context,
                  ref,
                  child: Icon(Icons.backspace_outlined,
                      size: 24.0.scaled(context, ref),
                      color: BeeTokens.textPrimary(context)),
                  onTap: onDelete,
                );
              }
              return _buildKeyButton(
                context,
                ref,
                child: Text(
                  key,
                  style: TextStyle(
                    fontSize: 28.0.scaled(context, ref),
                    fontWeight: FontWeight.w400,
                    color: BeeTokens.textPrimary(context),
                  ),
                ),
                onTap: () => onNumberTap(key),
              );
            }).toList(),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildKeyButton(
    BuildContext context,
    WidgetRef ref, {
    required Widget child,
    VoidCallback? onTap,
  }) {
    final size = 72.0.scaled(context, ref);
    return GestureDetector(
      onTap: () {
        if (onTap != null) {
          HapticFeedback.lightImpact();
          onTap();
        }
      },
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: onTap != null
              ? BeeTokens.surfaceSecondary(context)
              : Colors.transparent,
        ),
        child: child,
      ),
    );
  }
}
