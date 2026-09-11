import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'database_providers.dart';
import 'ui_state_providers.dart';
import 'currency_providers.dart';
import '../services/system/logger_service.dart';

// C9:统计刷新 tick 的去抖视图。43 个触发点(记账/批量导入/自动记账…)在
// 短时间内会多次 state++,每个统计 provider 直接 watch tick 会导致一次
// 记账触发十余个 provider 全量重算 × 重复触发。这里 300ms 窗口合并:
// tick 连续变化只发射最后一次,下游统计 provider 全部改 watch 本 provider。
class _StatsRefreshDebounce extends AsyncNotifier<int> {
  Timer? _timer;
  int _lastTick = 0;

  @override
  Future<int> build() async {
    final tick = ref.watch(statsRefreshProvider);
    final link = ref.keepAlive();
    ref.onDispose(() {
      link.close();
      _timer?.cancel();
    });
    if (tick == _lastTick && state.hasValue) {
      return state.value!;
    }
    _lastTick = tick;
    // 同一事件循环内的多次 ++ 合并为一次发射。
    _timer?.cancel();
    final completer = Completer<int>();
    _timer = Timer(const Duration(milliseconds: 300), () {
      if (!completer.isCompleted) completer.complete(tick);
    });
    return completer.future;
  }
}

final statsRefreshDebouncedProvider =
    AsyncNotifierProvider<_StatsRefreshDebounce, int>(
        _StatsRefreshDebounce.new);

// 统计：账本数量
final ledgerCountProvider = FutureProvider.autoDispose<int>((ref) async {
  final repo = ref.watch(repositoryProvider);
  // 依赖全局统计刷新 tick(去抖),确保手动刷新或恢复后能重新计算
  await ref.watch(statsRefreshDebouncedProvider.future);
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return repo.ledgerCount();
});

// 统计：某账本的记账天数与总笔数
final countsForLedgerProvider = FutureProvider.family
    .autoDispose<({int dayCount, int txCount}), int>((ref, ledgerId) async {
  final repo = ref.watch(repositoryProvider);
  // 依赖 tick 触发刷新(去抖)
  await ref.watch(statsRefreshDebouncedProvider.future);
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return repo.getCountsForLedger(ledgerId: ledgerId);
});

// 统计刷新 tick（全局）：每次 +1 触发统计相关 Provider 重新获取
final statsRefreshProvider = StateProvider<int>((ref) => 0);

// 统计：全应用的记账天数与总笔数（跨账本聚合）
final lastCountsAllProvider =
    StateProvider<({int dayCount, int txCount})?>((ref) => null);

final countsAllProvider =
    FutureProvider.autoDispose<({int dayCount, int txCount})>((ref) async {
  final repo = ref.watch(repositoryProvider);
  // 依赖 tick 触发手动刷新(去抖)
  await ref.watch(statsRefreshDebouncedProvider.future);
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  final res = await repo.getCountsAll();
  // 写入最近一次成功值，供 UI 在刷新期间显示旧值
  ref.read(lastCountsAllProvider.notifier).state = res;
  return res;
});

// 统计：当前账本总余额
final currentBalanceProvider =
    FutureProvider.family.autoDispose<double, int>((ref, ledgerId) async {
  final repo = ref.watch(repositoryProvider);
  // 依赖 tick 触发刷新(去抖)
  await ref.watch(statsRefreshDebouncedProvider.future);
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());

  // 获取账户功能开启状态
  final accountFeatureEnabled = await ref.watch(accountFeatureEnabledProvider.future);

  final stats = await repo.getLedgerStats(
    ledgerId: ledgerId,
    accountFeatureEnabled: accountFeatureEnabled,
  );
  return stats.balance;
});

// 统计：月度汇总最近值（避免loading闪烁）
final lastMonthlyTotalsProvider = StateProvider.family<(double income, double expense)?, ({int ledgerId, DateTime month})>((ref, params) => null);

// 统计：月度汇总（收入、支出）
final monthlyTotalsProvider = FutureProvider.family
    .autoDispose<(double income, double expense), ({int ledgerId, DateTime month})>(
        (ref, params) async {
  final repo = ref.watch(repositoryProvider);
  // 依赖 tick 触发刷新
  await ref.watch(statsRefreshDebouncedProvider.future);
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  final res = await repo.monthlyTotals(ledgerId: params.ledgerId, month: params.month);
  // 写入最近一次成功值，供 UI 在刷新期间显示旧值
  ref.read(lastMonthlyTotalsProvider(params).notifier).state = res;
  return res;
});

// 统计：单个账户统计（余额、消费、收入）
final accountStatsProvider = FutureProvider.family
    .autoDispose<({double balance, double expense, double income}), int>(
        (ref, accountId) async {
  final repo = ref.watch(repositoryProvider);
  // 依赖 tick 触发刷新
  await ref.watch(statsRefreshDebouncedProvider.future);
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return repo.getAccountStats(accountId);
});

// 统计：所有账户统计（每个账户的余额、消费、收入）
// v1.15.0: 不再限制账本，获取所有账户
final allAccountStatsProvider = FutureProvider.autoDispose<Map<int, ({double balance, double expense, double income})>>(
        (ref) async {
  final repo = ref.watch(repositoryProvider);
  logger.info('AllAccountStats', '使用的 Repository 类型: ${repo.runtimeType}');
  // 依赖 tick 触发刷新
  await ref.watch(statsRefreshDebouncedProvider.future);
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  final stats = await repo.getAllAccountStats();
  logger.info('AllAccountStats', '获取到 ${stats.length} 个账户的统计数据');
  return stats;
});

// 统计：所有账户汇总统计（总余额、总支出、总收入）
// v1.15.0: 不再限制账本，获取所有账户
final allAccountsTotalStatsProvider = FutureProvider.autoDispose<({double totalBalance, double totalExpense, double totalIncome})>(
        (ref) async {
  final repo = ref.watch(repositoryProvider);
  logger.info('AllAccountsTotalStats', '使用的 Repository 类型: ${repo.runtimeType}');
  // 依赖 tick 触发刷新
  await ref.watch(statsRefreshDebouncedProvider.future);
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  final stats = await repo.getAllAccountsTotalStats();
  logger.info('AllAccountsTotalStats', '总余额: ${stats.totalBalance}, 总支出: ${stats.totalExpense}, 总收入: ${stats.totalIncome}');
  return stats;
});

// 统计：净资产分解（总资产、总负债、净资产）
final netWorthBreakdownProvider = FutureProvider.autoDispose<({double totalAssets, double totalLiabilities, double netWorth})>(
        (ref) async {
  final repo = ref.watch(repositoryProvider);
  await ref.watch(statsRefreshDebouncedProvider.future);
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return repo.getNetWorthBreakdown();
});

// 统计：按币种分组的净资产分解
final netWorthBreakdownByCurrencyProvider = FutureProvider.autoDispose<
    Map<String, ({double totalAssets, double totalLiabilities, double netWorth})>>(
  (ref) async {
    final repo = ref.watch(repositoryProvider);
    await ref.watch(statsRefreshDebouncedProvider.future);
    final link = ref.keepAlive();
    ref.onDispose(() => link.close());
    return repo.getNetWorthBreakdownByCurrency();
  },
);

// 统计：净资产每日趋势
final netWorthTrendProvider = FutureProvider.family
    .autoDispose<List<({DateTime date, double balance})>, ({DateTime startDate, DateTime endDate})>(
        (ref, params) async {
  final repo = ref.watch(repositoryProvider);
  await ref.watch(statsRefreshDebouncedProvider.future);
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return repo.getNetWorthDailyBalances(startDate: params.startDate, endDate: params.endDate);
});

/// 净值趋势序列(资产/负债/净资产每日),范围参数化。
final netWorthTrendSeriesProvider = FutureProvider.family.autoDispose<
    List<({DateTime date, double assets, double liabilities, double net})>,
    ({DateTime startDate, DateTime endDate})>((ref, params) async {
  final repo = ref.watch(repositoryProvider);
  await ref.watch(statsRefreshDebouncedProvider.future);
  // 折算到主币种,与净资产卡(convertedNetWorthProvider)同口径:各币种 → base 汇率,
  // base 自身 1.0;缺汇率的币种在 repo 内整条剔除。这样趋势末点 = 当前净资产。
  final base = ref.watch(baseCurrencyProvider).toUpperCase();
  final rates = await ref.watch(effectiveRatesProvider.future);
  final ratesToBase = <String, double>{base: 1.0};
  for (final e in rates.entries) {
    final r = double.tryParse(e.value.rate);
    if (r != null && r > 0) ratesToBase[e.key.toUpperCase()] = r;
  }
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return repo.getNetWorthTrendSeries(
      startDate: params.startDate, endDate: params.endDate, ratesToBase: ratesToBase);
});

/// 全局最早一笔交易的发生时间（净值趋势「全部」范围的起点）。无交易返回 null。
final earliestTransactionDateProvider =
    FutureProvider.autoDispose<DateTime?>((ref) async {
  final repo = ref.watch(repositoryProvider);
  await ref.watch(statsRefreshDebouncedProvider.future);
  return repo.getEarliestTransactionDate();
});

// 统计：资产构成（按账户类型分组）
final assetCompositionProvider = FutureProvider.autoDispose<List<({String type, double totalBalance})>>(
        (ref) async {
  final repo = ref.watch(repositoryProvider);
  await ref.watch(statsRefreshDebouncedProvider.future);
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return repo.getAssetCompositionByType();
});