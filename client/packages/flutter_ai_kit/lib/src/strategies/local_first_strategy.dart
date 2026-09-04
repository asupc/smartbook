import '../core/ai_provider.dart';
import '../core/ai_task.dart';
import '../core/ai_execution_context.dart';
import 'ai_execution_strategy.dart';

/// 本地优先策略
///
/// 优先使用本地Provider，失败后降级到云端Provider
///
/// 执行顺序:
/// 1. 本地Provider（按注册顺序）
/// 2. 云端Provider（如果 allowCloudFallback = true）
class LocalFirstStrategy implements AIExecutionStrategy {
  const LocalFirstStrategy();

  @override
  Future<List<AIProvider>> selectProviders(
    List<AIProvider> availableProviders,
    AITask task,
    AIExecutionContext context,
  ) async {
    final result = <AIProvider>[];

    // 1. 优先选择本地Provider
    final localProviders = availableProviders
        .where((p) => p.type == AIProviderType.local)
        .where((p) => p.supportsTask(task.taskType))
        .toList();

    for (final provider in localProviders) {
      if (await provider.isReady()) {
        result.add(provider);
      }
    }

    // 2. 如果允许云端降级 + 有网络
    if (context.allowCloudFallback && context.hasNetwork) {
      final cloudProviders = availableProviders
          .where((p) => p.type == AIProviderType.cloud)
          .where((p) => p.supportsTask(task.taskType))
          .toList();

      for (final provider in cloudProviders) {
        if (await provider.isReady()) {
          result.add(provider);
        }
      }
    }

    return result;
  }
}
