import '../core/ai_provider.dart';
import '../core/ai_task.dart';
import '../core/ai_execution_context.dart';
import 'ai_execution_strategy.dart';

/// 仅云端策略
///
/// 只使用云端Provider，不使用本地模型
///
/// 适用场景:
/// - 不想下载大模型文件
/// - 追求最高准确率
/// - 有稳定网络连接
class CloudOnlyStrategy implements AIExecutionStrategy {
  const CloudOnlyStrategy();

  @override
  Future<List<AIProvider>> selectProviders(
    List<AIProvider> availableProviders,
    AITask task,
    AIExecutionContext context,
  ) async {
    final result = <AIProvider>[];

    if (!context.hasNetwork) return result;

    final cloudProviders = availableProviders
        .where((p) => p.type == AIProviderType.cloud)
        .where((p) => p.supportsTask(task.taskType))
        .toList();

    for (final provider in cloudProviders) {
      if (await provider.isReady()) {
        result.add(provider);
      }
    }

    return result;
  }
}
