import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/automation/auto_billing_service.dart';
import '../services/automation/auto_book_coordinator.dart';
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
