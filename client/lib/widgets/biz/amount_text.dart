import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../styles/tokens.dart';
import '../../providers.dart';
import '../../utils/currencies.dart';
import '../../utils/format_utils.dart';
import 'format_money.dart';

class AmountText extends ConsumerWidget {
  final double value;
  final bool? hide; // 改为可选,null时使用全局状态
  final bool signed; // 是否显示正负号
  final int decimals;
  final TextStyle? style;
  final bool showCurrency; // 是否显示币种符号(¥/$等),默认false
  final bool useCompactFormat; // 是否使用大金额缩写(万/千/k/M等),默认false
  final String? currencyCode; // 指定币种代码,null时自动获取当前账本币种
  final bool colorizeIncome; // 是否给收入添加绿色,默认false

  const AmountText({
    super.key,
    required this.value,
    this.hide,
    this.signed = true,
    this.decimals = 2,
    this.style,
    this.showCurrency = false,
    this.useCompactFormat = false,
    this.currencyCode,
    this.colorizeIncome = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 优先使用传入的hide,否则使用全局状态
    final shouldHide = hide ?? ref.watch(hideAmountsProvider);

    if (shouldHide == true) {
      return Text('****',
          style: style ??
              Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: BeeTokens.textPrimary(context)));
    }

    String displayText;

    if (showCurrency || useCompactFormat) {
      // 需要币种符号或大金额缩写时,使用formatBalance
      final effectiveCurrencyCode = currencyCode ??
          ref.watch(currentLedgerProvider).asData?.value?.currency;

      if (effectiveCurrencyCode != null) {
        // 自动检测是否为中文环境
        final selectedLocale = ref.watch(languageProvider);
        final isChinese = selectedLocale?.languageCode == 'zh' ||
            (selectedLocale == null &&
                Localizations.localeOf(context).languageCode == 'zh');

        // 使用formatBalance,然后根据开关移除不需要的部分
        String formatted = formatBalance(value, effectiveCurrencyCode,
            isChineseLocale: isChinese);

        if (!showCurrency) {
          // 移除 formatBalance 加进去的币种符号。要按实际币种动态算 —
          // 老的硬编码字符类 [¥$€£₩] 漏了 ฿ ₹ ₽ ₫ Rp HK$ NT$ C$ 等。
          final symbol = getCurrencySymbol(effectiveCurrencyCode.toUpperCase());
          if (symbol.isNotEmpty && formatted.startsWith(symbol)) {
            formatted = formatted.substring(symbol.length).trimLeft();
          }
        }

        if (!useCompactFormat) {
          // 不使用大金额缩写,回退到formatMoneyCompact
          displayText =
              formatMoneyCompact(value, maxDecimals: decimals, signed: signed);
          // 但如果需要币种符号,添加上去
          if (showCurrency) {
            final currencySymbol =
                getCurrencySymbol(effectiveCurrencyCode.toUpperCase());
            displayText = '$currencySymbol$displayText';
          }
        } else {
          displayText = formatted;
        }
      } else {
        // 如果没有币种,使用简单格式化
        displayText =
            formatMoneyCompact(value, maxDecimals: decimals, signed: signed);
      }
    } else {
      // 默认使用简单格式化
      displayText =
          formatMoneyCompact(value, maxDecimals: decimals, signed: signed);
    }

    // 计算最终样式：收入且开启着色时使用绿色
    final isIncome = value > 0;
    final baseStyle = style ??
        Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: BeeTokens.textPrimary(context));

    final finalStyle = (colorizeIncome && isIncome)
        ? baseStyle?.copyWith(color: BeeTokens.incomeColor(context, ref))
        : baseStyle;

    return Text(
      displayText,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.right,
      style: finalStyle,
    );
  }
}
