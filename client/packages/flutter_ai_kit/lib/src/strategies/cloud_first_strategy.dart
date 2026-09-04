import '../core/ai_provider.dart';
import '../core/ai_task.dart';
import '../core/ai_execution_context.dart';
import 'ai_execution_strategy.dart';

/// 云端优先策略
///
/// 优先使用云端Provider，失败后降级到本地Provider
///
/// 执行顺序:
/// 1. 云端Provider（如果有网络）
/// 2. 本地Provider（如果 allowLocalFallback = true）
class CloudFirstStrategy implements AIExecutionStrategy {
  const CloudFirstStrategy();

  @override
  Future<List<AIProvider>> selectProviders(
    List<AIProvider> availableProviders,
    AITask task,
    AIExecutionContext context,
  ) async {
    final result = <AIProvider>[];

    // 1. 优先选择云端Provider（如果有网络）
    if (context.hasNetwork) {
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

    // 2. 如果允许本地降级
    if (context.allowLocalFallback) {
      final localProviders = availableProviders
          .where((p) => p.type == AIProviderType.local)
          .where((p) => p.supportsTask(task.taskType))
          .toList();

      for (final provider in localProviders) {
        if (await provider.isReady()) {
          result.add(provider);
        }
      }
    }

    return result;
  }
}
