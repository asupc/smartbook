/// AI执行结果（泛型）
///
/// [T] 结果数据类型
class AIResult<T> {
  /// 执行是否成功
  final bool success;

  /// 结果数据（成功时非空）
  final T? data;

  /// 错误信息（失败时非空）
  final String? error;

  /// 执行耗时
  final Duration duration;

  /// 元数据（Provider信息、Token消耗等）
  final AIResultMetadata metadata;

  const AIResult._({
    required this.success,
    this.data,
    this.error,
    required this.duration,
    required this.metadata,
  });

  /// 创建成功结果
  factory AIResult.success(
    T data,
    Duration duration, {
    AIResultMetadata? metadata,
  }) {
    return AIResult._(
      success: true,
      data: data,
      duration: duration,
      metadata: metadata ?? const AIResultMetadata(),
    );
  }

  /// 创建失败结果
  factory AIResult.failure(
    String error,
    Duration duration, {
    AIResultMetadata? metadata,
  }) {
    return AIResult._(
      success: false,
      error: error,
      duration: duration,
      metadata: metadata ?? const AIResultMetadata(),
    );
  }

  @override
  String toString() {
    if (success) {
      return 'AIResult.success(data: $data, duration: ${duration.inMilliseconds}ms, provider: ${metadata.providerName})';
    } else {
      return 'AIResult.failure(error: $error, duration: ${duration.inMilliseconds}ms, provider: ${metadata.providerName})';
    }
  }
}

/// 结果元数据
class AIResultMetadata {
  /// 使用的Provider名称
  final String? providerName;

  /// 使用的模型名称
  final String? modelName;

  /// 消耗的Token数（云端API）
  final int? tokensUsed;

  /// 置信度 (0.0 - 1.0)
  final double? confidence;

  /// 扩展字段（自定义数据）
  final Map<String, dynamic> extra;

  const AIResultMetadata({
    this.providerName,
    this.modelName,
    this.tokensUsed,
    this.confidence,
    this.extra = const {},
  });

  @override
  String toString() {
    return 'AIResultMetadata(provider: $providerName, model: $modelName, tokens: $tokensUsed, confidence: $confidence)';
  }
}
