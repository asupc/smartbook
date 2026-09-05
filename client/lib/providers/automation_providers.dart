import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/automation/auto_billing_service.dart';
import '../services/automation/auto_book_coordinator.dart';
import '../services/billing/pending_candidate.dart';
import 'database_providers.dart';

/// 全局共享的自动记账 worker。
///
/// 之前每个 monitor 都 new 一个 AutoBillingService，导致 processed cache 和
/// 处理链彼此隔离。将实例放到根 ProviderContainer 后，所有入口至少共享
/// 同一生命周期；跨来源的全局串行由 [autoBookCoordinatorProvider] 负责。
final autoBillingServiceProvider = Provider<AutoBillingService>((ref) {
  final eventStore = ref.container.read(autoBookCoordinatorProvider).store;
  final service = AutoBillingService(ref.container, eventStore: eventStore);
  ref.onDispose(service.dispose);
  return service;
});

/// 自动记账入口统一协调器。
final autoBookCoordinatorProvider = Provider<AutoBookCoordinator>((ref) {
  final coordinator = AutoBookCoordinator(ref.watch(databaseProvider));
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

/// 待确认候选数量:「我的」页角标与首页提醒条共用的唯一计数源(P1-3)。
/// 口径与待确认页一致:loadForReview 合并 event store(cap 500)与
/// legacy SharedPreferences 候选 —— 只数 legacy 会少报(超 100 条被淘汰、
/// 或候选仅存在于 event store 时)。
final pendingCandidateCountProvider = FutureProvider<int>((ref) async {
  final eventStore = ref.watch(autoBookCoordinatorProvider).store;
  return (await PendingCandidateStore().loadForReview(eventStore)).length;
});
