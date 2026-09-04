import '../core/ai_provider.dart';
import '../core/ai_task.dart';
import '../core/ai_execution_context.dart';
import 'ai_execution_strategy.dart';

/// 仅本地策略
///
/// 只使用本地Provider，不使用云端API
///
/// 适用场景:
/// - 隐私敏感场景
/// - 完全离线环境
/// - 不想消耗API费用
class LocalOnlyStrategy implements AIExecutionStrategy {
  const LocalOnlyStrategy();

  @override
  Future<List<AIProvider>> selectProviders(
    List<AIProvider> availableProviders,
    AITask task,
    AIExecutionContext context,
  ) async {
    final result = <AIProvider>[];

    final localProviders = availableProviders
        .where((p) => p.type == AIProviderType.local)
        .where((p) => p.supportsTask(task.taskType))
        .toList();

    for (final provider in localProviders) {
      if (await provider.isReady()) {
        result.add(provider);
      }
    }

    return result;
  }
}
