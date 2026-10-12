/// 格式化工具函数
///
/// 包含各种数据格式化的工具函数
library;

import 'package:flutter/material.dart';
import 'currencies.dart';
import '../l10n/app_localizations.dart';

/// 定点金额渲染的**安全上限**(缺陷 H):`double.toStringAsFixed(2)` 对
/// `|v| >= 1e21` 返回指数记法(无小数点),`split('.')[1]` 越界。
/// `[formatBalanceFull]` 在 `|v| >= magnitudeCeiling` 时改走科学计数法。
///
/// 这是**渲染侧**下限,与**写入侧**上限
/// ([LocalTransactionRepository.maxWriteAmount] = 1e12,对应 U-1 的
/// 「~12 位整数」UI 键盘上限)是两道不同的闸:写入拦截新脏值,渲染兜底
/// 存量/远端带来的超大值(不能因一条存量行崩掉整页)。
const double magnitudeCeiling = 1e21;

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
///
/// **非有限值兜底**(跨审缺陷 7):NaN/±Infinity(存量脏数据/远端 payload)
/// 走 `abs()` 比较后落在压缩分支,渲染成 `¥Infinity万` / `-¥NaN万` —— 不崩
/// 但编造了不可读的"金额"。与 [formatBalanceFull] 同口径降级为 `--`
/// 占位符(不编造金额),两条渲染路径行为一致。
String formatBalance(double balance, String currencyCode,
    {bool isChineseLocale = true}) {
  if (!balance.isFinite) {
    // 与 formatBalanceFull 同一兜底:占位符,不编造金额。
    return '--';
  }
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
///
/// 非有限值(存量脏数据/同步 payload 里的 NaN/Infinity)渲染兜底为 `--`：
/// 实现走 `toStringAsFixed(2).split('.')`,而 `toStringAsFixed` 对
/// NaN/Infinity 返回不含 `.` 的字符串 → 取 `parts[1]` 会抛 RangeError,
/// 账本卡(非紧凑金额模式)整页崩。金额提交侧已有 `isFinite` 断言
/// (LocalTransactionRepository.txAmountViolation),这里是渲染侧的第二道防线。
///
/// **极大有限值**(缺陷 H,2026-10-11):`double.toStringAsFixed(2)` 对
/// `|value| >= 1e21` 返回**指数记法**("1e+21",无小数点)→ `split('.')[1]`
/// 同样越界抛 RangeError。1e21 是有限数,能通过 `isFinite` 守卫(`1e21`
/// 曾可被 addTransaction 接受;新上限后仍可由历史行/同步 payload 带来),
/// 一条这样的行就让账本卡整页崩。故此处按量级分档:
///
/// - `>= 1e21`(仅 **渲染** 兜底,不依赖写入口):转科学计数法
///   `toStringAsExponential(2).replaceAll('e+', 'e')` → `¥1.00e21`。
///   定点展开会输出 22 位整数(1e20 已输出 20 位,见对抗测试),窄屏宽度
///   爆炸;科学记数法保宽度有界且不编造数值。
/// - `< 1e21`:原定点 + 千分号路径(含 1e20,行为不变)。
///
/// 与 U-1「~12 位整数」UI 上限的对应关系:[magnitudeCeiling] 是**写入侧**
/// 的上限(`LocalTransactionRepository.maxWriteAmount = 1e12`),本函数是
/// **渲染侧**的兜底 —— 存量行(旧版本写入 / 远端 payload)可能超出上限,
/// 渲染不能崩,只能降级展示。
String formatBalanceFull(double balance, String currencyCode) {
  if (!balance.isFinite) {
    // 不编造金额(直接显示 ¥0.00 会误导),用占位符表示不可用。
    return '--';
  }
  final absBalance = balance.abs();
  final currencySymbol = getCurrencySymbol(currencyCode);
  final sign = balance >= 0 ? currencySymbol : '-$currencySymbol';

  // 缺陷 H:|v| >= 1e21 时定点格式已退化为指数记法,按指数输出兜底。
  if (absBalance >= magnitudeCeiling) {
    final exp = absBalance.toStringAsExponential(2);
    return '$sign${exp.replaceAll('e+', 'e')}';
  }

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
