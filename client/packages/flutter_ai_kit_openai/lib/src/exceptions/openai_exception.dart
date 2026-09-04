/// OpenAI API 异常
class OpenAIException implements Exception {
  final String message;
  final String? code;
  final int? statusCode;
  final dynamic details;

  OpenAIException({
    required this.message,
    this.code,
    this.statusCode,
    this.details,
  });

  @override
  String toString() {
    final buffer = StringBuffer('OpenAIException: $message');
    if (code != null) buffer.write(' (code: $code)');
    if (statusCode != null) buffer.write(' (HTTP $statusCode)');
    if (details != null) buffer.write('\nDetails: $details');
    return buffer.toString();
  }

  /// 从 HTTP 错误响应创建
  factory OpenAIException.fromResponse(
    int statusCode,
    Map<String, dynamic>? data,
  ) {
    if (data != null && data['error'] is Map) {
      final error = data['error'] as Map<String, dynamic>;
      return OpenAIException(
        message: error['message'] as String? ?? 'Unknown error',
        code: error['code'] as String?,
        statusCode: statusCode,
        details: error,
      );
    }

    return OpenAIException(
      message: 'HTTP Error: $statusCode',
      statusCode: statusCode,
    );
  }

  /// API Key 无效
  factory OpenAIException.invalidApiKey() => OpenAIException(
        message: 'API Key 无效或已过期',
        code: 'invalid_api_key',
        statusCode: 401,
      );

  /// 配额不足
  factory OpenAIException.quotaExceeded() => OpenAIException(
        message: 'API 配额已用尽',
        code: 'quota_exceeded',
        statusCode: 429,
      );

  /// 网络错误
  factory OpenAIException.networkError(String message) => OpenAIException(
        message: '网络请求失败: $message',
        code: 'network_error',
      );

  /// 超时
  factory OpenAIException.timeout() => OpenAIException(
        message: '请求超时',
        code: 'timeout',
      );
}
