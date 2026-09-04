/// AI执行上下文
///
/// 包含执行环境信息和策略配置
class AIExecutionContext {
  /// 当前是否有网络连接
  final bool hasNetwork;

  /// 是否允许降级到云端Provider
  final bool allowCloudFallback;

  /// 是否允许降级到本地Provider
  final bool allowLocalFallback;

  /// 执行超时时间（可选）
  final Duration? timeout;

  /// 扩展字段（自定义配置）
  final Map<String, dynamic> extras;

  const AIExecutionContext({
    required this.hasNetwork,
    this.allowCloudFallback = true,
    this.allowLocalFallback = true,
    this.timeout,
    this.extras = const {},
  });

  /// 创建默认上下文（允许所有降级）
  factory AIExecutionContext.defaults({
    required bool hasNetwork,
    Duration? timeout,
  }) {
    return AIExecutionContext(
      hasNetwork: hasNetwork,
      allowCloudFallback: true,
      allowLocalFallback: true,
      timeout: timeout,
    );
  }

  /// 创建仅本地上下文
  factory AIExecutionContext.localOnly({
    Duration? timeout,
  }) {
    return AIExecutionContext(
      hasNetwork: false,
      allowCloudFallback: false,
      allowLocalFallback: true,
      timeout: timeout,
    );
  }

  /// 创建仅云端上下文
  factory AIExecutionContext.cloudOnly({
    required bool hasNetwork,
    Duration? timeout,
  }) {
    return AIExecutionContext(
      hasNetwork: hasNetwork,
      allowCloudFallback: true,
      allowLocalFallback: false,
      timeout: timeout,
    );
  }

  @override
  String toString() {
    return 'AIExecutionContext(hasNetwork: $hasNetwork, allowCloud: $allowCloudFallback, allowLocal: $allowLocalFallback, timeout: $timeout)';
  }
}
