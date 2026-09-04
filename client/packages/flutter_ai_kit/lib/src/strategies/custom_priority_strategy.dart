import '../core/ai_provider.dart';
import '../core/ai_task.dart';
import '../core/ai_execution_context.dart';
import 'ai_execution_strategy.dart';

/// 自定义优先级策略
///
/// 按用户指定的Provider ID顺序执行
///
/// 示例:
/// ```dart
/// final strategy = CustomPriorityStrategy([
///   'my_local_model',
///   'zhipu_glm',
///   'openai_gpt',
/// ]);
/// ```
class CustomPriorityStrategy implements AIExecutionStrategy {
  /// Provider ID优先级列表（从高到低）
  final List<String> providerIdPriority;

  const CustomPriorityStrategy(this.providerIdPriority);

  @override
  Future<List<AIProvider>> selectProviders(
    List<AIProvider> availableProviders,
    AITask task,
    AIExecutionContext context,
  ) async {
    final result = <AIProvider>[];

    for (final providerId in providerIdPriority) {
      final provider = availableProviders.firstWhereOrNull(
        (p) => p.id == providerId,
      );

      if (provider == null) continue;
      if (!provider.supportsTask(task.taskType)) continue;
      if (provider.requiresNetwork && !context.hasNetwork) continue;
      if (!await provider.isReady()) continue;

      result.add(provider);
    }

    return result;
  }
}

/// List扩展：firstWhereOrNull
extension _ListExtension<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}
