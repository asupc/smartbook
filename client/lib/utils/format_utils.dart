/// 格式化工具函数
///
/// 包含各种数据格式化的工具函数
library;

import 'package:flutter/material.dart';
import 'currencies.dart';
import '../l10n/app_localizations.dart';

/// 格式化余额显示，支持多语言单位和多币种
///
/// [balance] 金额
/// [currencyCode] 币种代码 (如 'CNY', 'USD')
/// [isChineseLocale] 是否为中文环境，中文显示万单位，其他语言显示k/M单位
///
/// 智能精度规则：
/// - 小于1万：完整显示，不压缩
/// - 1万-10万：保留1-2位小数（智能判断）
/// - 10万以上：保留1-2位小数（智能判断）
/// - 如果小数部分为.0或.00，则不显示小数
String formatBalance(double balance, String currencyCode,
    {bool isChineseLocale = true}) {
  final absBalance = balance.abs();
  final currencySymbol = getCurrencySymbol(currencyCode);
  final sign = balance >= 0 ? currencySymbol : '-$currencySymbol';

  if (isChineseLocale) {
    // 中文环境：使用万作为单位
    if (absBalance < 10000) {
      // 小于1万：完整显示，不压缩
      return '$sign${absBalance.toStringAsFixed(2)}';
    } else {
      final wan = absBalance / 10000;

      // 智能决定小数位数
      String formattedWan;
      if (wan >= 10) {
        // 10万以上：先尝试1位小数，如果舍入误差大则用2位
        final rounded1 = double.parse(wan.toStringAsFixed(1));
        final error = (rounded1 * 10000 - absBalance).abs();

        if (error > 100) {
          // 误差超过100元，使用2位小数
          formattedWan = wan.toStringAsFixed(2);
        } else {
          formattedWan = wan.toStringAsFixed(1);
        }
      } else {
        // 1-10万：先尝试1位小数，如果舍入误差大则用2位
        final rounded1 = double.parse(wan.toStringAsFixed(1));
        final error = (rounded1 * 10000 - absBalance).abs();

        if (error > 50) {
          // 误差超过50元，使用2位小数
          formattedWan = wan.toStringAsFixed(2);
        } else {
          formattedWan = wan.toStringAsFixed(1);
        }
      }

      // 移除末尾的.0或.00
      formattedWan = formattedWan.replaceAll(RegExp(r'\.0+$'), '');

      return '$sign$formattedWan万';
    }
  } else {
    // 其他语言环境：使用k、M作为单位
    if (absBalance >= 1000000) {
      final million = absBalance / 1000000;

      // 智能决定小数位数
      final rounded1 = double.parse(million.toStringAsFixed(1));
      final error = (rounded1 * 1000000 - absBalance).abs();

      String formattedMillion;
      if (error > 1000) {
        formattedMillion = million.toStringAsFixed(2);
      } else {
        formattedMillion = million.toStringAsFixed(1);
      }

      // 移除末尾的.0或.00
      formattedMillion = formattedMillion.replaceAll(RegExp(r'\.0+$'), '');

      return '$sign${formattedMillion}M';
    } else if (absBalance >= 1000) {
      final thousand = absBalance / 1000;

      // 智能决定小数位数
      final rounded1 = double.parse(thousand.toStringAsFixed(1));
      final error = (rounded1 * 1000 - absBalance).abs();

      String formattedThousand;
      if (error > 100) {
        formattedThousand = thousand.toStringAsFixed(2);
      } else {
        formattedThousand = thousand.toStringAsFixed(1);
      }

      // 移除末尾的.0或.00
      formattedThousand = formattedThousand.replaceAll(RegExp(r'\.0+$'), '');

      return '$sign${formattedThousand}k';
    } else {
      return '$sign${absBalance.toStringAsFixed(2)}';
    }
  }
}

/// 格式化完整余额显示（带千分号）
///
/// [balance] 金额
/// [currencyCode] 币种代码 (如 'CNY', 'USD')
///
/// 始终显示完整金额，使用千分号分隔
String formatBalanceFull(double balance, String currencyCode) {
  final absBalance = balance.abs();
  final currencySymbol = getCurrencySymbol(currencyCode);
  final sign = balance >= 0 ? currencySymbol : '-$currencySymbol';

  // 格式化为带千分号的字符串
  final parts = absBalance.toStringAsFixed(2).split('.');
  final intPart = parts[0];
  final decPart = parts[1];

  // 添加千分号
  final buffer = StringBuffer();
  for (int i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(intPart[i]);
  }

  return '$sign${buffer.toString()}.$decPart';
}

/// 翻译账本名称
///
/// 如果账本名称是 "Default Ledger"，则返回国际化后的名称
/// 否则返回原始名称
String translateLedgerName(BuildContext context, String ledgerName) {
  final l10n = AppLocalizations.of(context);

  // 处理默认账本名称的多种形式
  if (ledgerName == 'Default Ledger' ||
      ledgerName == '默认账本' ||
      ledgerName == 'デフォルト家計簿' ||
      ledgerName == '기본 가계부' ||
      ledgerName == 'Standard-Kontenbuch' ||
      ledgerName == 'Livre par Défaut' ||
      ledgerName == 'Libro Predeterminado' ||
      ledgerName == '預設帳本') {
    return l10n.ledgersDefaultLedgerName;
  }

  return ledgerName;
}
