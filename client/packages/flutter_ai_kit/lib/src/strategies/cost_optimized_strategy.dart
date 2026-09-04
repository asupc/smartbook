import '../core/ai_provider.dart';
import '../core/ai_task.dart';
import '../core/ai_execution_context.dart';
import 'ai_execution_strategy.dart';

/// 成本优先策略
///
/// 按成本从低到高排序Provider
///
/// 排序规则:
/// - 本地模型成本为 0
/// - 云端API按 estimateCost() 返回值排序
class CostOptimizedStrategy implements AIExecutionStrategy {
  const CostOptimizedStrategy();

  @override
  Future<List<AIProvider>> selectProviders(
    List<AIProvider> availableProviders,
    AITask task,
    AIExecutionContext context,
  ) async {
    final candidates = <_ProviderWithCost>[];

    // 收集所有可用Provider及其成本
    for (final provider in availableProviders) {
      if (!provider.supportsTask(task.taskType)) continue;
      if (provider.requiresNetwork && !context.hasNetwork) continue;
      if (!await provider.isReady()) continue;

      final cost = await provider.estimateCost(task);
      candidates.add(_ProviderWithCost(provider, cost));
    }

    // 按成本排序（低到高）
    candidates.sort((a, b) => a.cost.compareTo(b.cost));

    return candidates.map((e) => e.provider).toList();
  }
}

class _ProviderWithCost {
  final AIProvider provider;
  final double cost;

  _ProviderWithCost(this.provider, this.cost);
}
