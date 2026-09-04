/// AI任务基类（泛型，业务无关）
///
/// [TInput] 输入数据类型
/// [TOutput] 输出数据类型
///
/// 示例:
/// ```dart
/// class TextExtractionTask extends AITask<String, Map<String, dynamic>> {
///   @override
///   String get taskType => 'text_extraction';
///
///   @override
///   final String input;
///
///   TextExtractionTask(this.input);
///
///   @override
///   Map<String, dynamic> toJson() => {'text': input};
/// }
/// ```
abstract class AITask<TInput, TOutput> {
  /// 任务类型标识（如 "text_extraction", "chat", "image_classification"）
  String get taskType;

  /// 输入数据
  TInput get input;

  /// 将任务序列化为JSON（用于云端API或日志记录）
  Map<String, dynamic> toJson();
}
