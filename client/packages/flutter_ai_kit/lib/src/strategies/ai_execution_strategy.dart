import '../core/ai_provider.dart';
import '../core/ai_task.dart';
import '../core/ai_execution_context.dart';

/// 执行策略基类
///
/// 定义如何从多个Provider中选择执行顺序
abstract class AIExecutionStrategy {
  /// 从多个Provider中选择执行顺序
  ///
  /// [availableProviders] 所有已注册的Provider
  /// [task] 要执行的任务
  /// [context] 执行上下文
  ///
  /// 返回按优先级排序的Provider列表
  Future<List<AIProvider>> selectProviders(
    List<AIProvider> availableProviders,
    AITask task,
    AIExecutionContext context,
  );
}
