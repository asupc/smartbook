import 'ai_task.dart';
import 'ai_result.dart';

/// AI能力提供者接口
///
/// [TInput] 输入数据类型
/// [TOutput] 输出数据类型
///
/// 示例:
/// ```dart
/// class MyCustomProvider implements AIProvider<String, String> {
///   @override
///   String get id => 'my_custom_provider';
///
///   @override
///   String get name => 'My Custom Provider';
///
///   @override
///   AIProviderType get type => AIProviderType.cloud;
///
///   @override
///   bool get requiresNetwork => true;
///
///   @override
///   bool supportsTask(String taskType) => taskType == 'my_task';
///
///   @override
///   Future<bool> isReady() async => true;
///
///   @override
///   Future<AIResult<String>> execute(AITask<String, String> task) async {
///     // 实现逻辑
///   }
///
///   @override
///   Future<double> estimateCost(AITask<String, String> task) async => 0.0;
/// }
/// ```
abstract class AIProvider<TInput, TOutput> {
  /// Provider唯一标识（如 "local_tflite", "zhipu_glm"）
  String get id;

  /// Provider显示名称（用于UI展示）
  String get name;

  /// Provider类型
  AIProviderType get type;

  /// 是否需要网络连接
  bool get requiresNetwork;

  /// 是否支持指定的任务类型
  ///
  /// [taskType] 任务类型标识（来自 [AITask.taskType]）
  bool supportsTask(String taskType);

  /// 检查Provider是否就绪
  ///
  /// 本地模型: 检查模型文件是否存在
  /// 云端API: 检查API Key是否配置
  Future<bool> isReady();

  /// 执行AI任务
  ///
  /// [task] 要执行的任务
  /// 返回 [AIResult] 包含执行结果或错误信息
  Future<AIResult<TOutput>> execute(AITask<TInput, TOutput> task);

  /// 估算任务成本（可选）
  ///
  /// 本地模型: 返回 0.0
  /// 云端API: 返回预计费用（单位: 美元）
  Future<double> estimateCost(AITask<TInput, TOutput> task);
}

/// Provider类型
enum AIProviderType {
  /// 本地模型（TFLite, ONNX等）
  local,

  /// 云端API（OpenAI, Zhipu等）
  cloud,

  /// 混合模式（如边缘计算）
  hybrid,
}

/// Provider类型扩展
extension AIProviderTypeExtension on AIProviderType {
  /// 获取类型名称
  String get displayName {
    switch (this) {
      case AIProviderType.local:
        return 'Local';
      case AIProviderType.cloud:
        return 'Cloud';
      case AIProviderType.hybrid:
        return 'Hybrid';
    }
  }
}
