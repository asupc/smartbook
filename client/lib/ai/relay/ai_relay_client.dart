import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../providers/ai_provider_config.dart';
import '../../services/system/logger_service.dart';

/// 中转请求里的一条消息(role: system / user / assistant)。
class AiRelayMessage {
  final String role;
  final String content;

  const AiRelayMessage({required this.role, required this.content});
}

/// /ai/relay/chat 的响应。
///
/// [duplicate] = 服务端在识别前命中了该用户已识别过的账单唯一标识
/// (订单号/流水号):**没有调用 LLM**,content 为空串。App 端按
/// 「重复账单」静默处理 —— 不记账、不进待确认、不发通知。
class AiRelayChatResult {
  final String content;
  final bool duplicate;
  final String? matchedIdentifier;

  const AiRelayChatResult({
    required this.content,
    this.duplicate = false,
    this.matchedIdentifier,
  });
}

/// 中转调用失败(网络 / 服务端错误)。工厂层会转成 [format] 后抛 AIException。
class AiRelayException implements Exception {
  final String message;
  final int? statusCode;

  /// true = 可恢复的临时失败(连不上服务端 / 超时 / 上游 5xx / 限流)。
  /// 自动记账据此把输入存为草稿等待重试;4xx 校验类失败为 false。
  final bool transient;

  AiRelayException(this.message, {this.statusCode, this.transient = false});

  @override
  String toString() => message;
}

/// App → SmartBook-Cloud 的 AI 中转客户端。
///
/// 所有 LLM 调用(文本提取 / 视觉 / 语音转写)都经自建服务端代理:API Key
/// 只存服务端(`UserProfile.ai_config_json`),App 只带自己的 JWT 调这里。
/// 每次中转调用由服务端直接落一行 `ai_analysis_logs`(截图原文随请求落盘),
/// 客户端不再事后上报日志。
///
/// 服务商配置(/ai/providers CRUD)也走这里:返回的 apiKey 一律是
/// `****+末4位` 掩码,写入时空 / 掩码 = 保留服务端原值。
class AiRelayClient {
  AiRelayClient({
    required this.baseUrl,
    required this.apiPrefix,
    required this.accessToken,
    this.onUnauthorized,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String apiPrefix;

  /// 取当前 access token(实现方自带临近过期自动刷新)。
  final Future<String> Function() accessToken;

  /// 收到 401 时触发一次(实现方刷新 session),然后本请求重试一次。
  final Future<void> Function()? onUnauthorized;

  final http.Client _client;

  // ────────────────────────────────────────────────────────────────────
  // AI 能力中转
  // ────────────────────────────────────────────────────────────────────

  /// 文本对话中转。服务端按 entry_type 落日志:
  /// `parse_tx_text`(记账提取,带 ledgerId)/ `chat`(自由对话)。
  ///
  /// 服务端在识别前会用该用户已识别过的账单唯一标识(订单号/流水号)判重;
  /// 命中时返回 `duplicate: true` 且 content 为空 —— 没有发生 LLM 调用。
  Future<AiRelayChatResult> chat({
    required List<AiRelayMessage> messages,
    required String entryType,
    double temperature = 0.7,
    bool disableThinking = false,
    String? ledgerId,
    String? logInput,
  }) async {
    final data = await _postJson(
      'ai/relay/chat',
      body: {
        'messages': [
          for (final m in messages)
            {'role': m.role, 'content': m.content},
        ],
        'temperature': temperature,
        'disable_thinking': disableThinking,
        'entry_type': entryType,
        if (ledgerId != null && ledgerId.isNotEmpty) 'ledger_id': ledgerId,
        if (logInput != null && logInput.isNotEmpty) 'log_input': logInput,
      },
    );
    return AiRelayChatResult(
      content: (data['content'] as String?) ?? '',
      duplicate: data['duplicate'] == true,
      matchedIdentifier: data['matched_identifier'] as String?,
    );
  }

  /// 视觉中转(截图/选图记账)。服务端拼 base64 content array 并把原图
  /// 随日志落盘。[logInput] 传原图摘要(caption),保持日志可读。
  Future<String> vision({
    required File image,
    required String prompt,
    bool disableThinking = true,
    String? ledgerId,
    String? logInput,
  }) async {
    final data = await _postMultipart(
      'ai/relay/vision',
      fileField: 'image',
      file: image,
      fields: {
        'prompt': prompt,
        'disable_thinking': disableThinking ? 'true' : 'false',
        if (ledgerId != null && ledgerId.isNotEmpty) 'ledger_id': ledgerId,
        if (logInput != null && logInput.isNotEmpty) 'log_input': logInput,
      },
    );
    return (data['content'] as String?) ?? '';
  }

  /// 语音转文字中转。服务端按绑定的 speech provider 转写并落 stt 日志。
  Future<String> speechToText(File audio) async {
    final data = await _postMultipart(
      'ai/relay/stt',
      fileField: 'audio',
      file: audio,
      fields: const {},
    );
    return (data['text'] as String?) ?? '';
  }

  // ────────────────────────────────────────────────────────────────────
  // 服务商配置(密钥只存服务端)
  // ────────────────────────────────────────────────────────────────────

  /// 服务商列表 + 能力绑定。apiKey 字段是掩码(`****1234`,未配置时为空串)。
  Future<(List<AIServiceProviderConfig>, AICapabilityBinding)> listProviders() async {
    final data = await _get('ai/providers');
    final providers = <AIServiceProviderConfig>[
      for (final p in (data['providers'] as List? ?? []))
        AIServiceProviderConfig.fromJson(p as Map<String, dynamic>),
    ];
    final binding = AICapabilityBinding.fromJson(
      (data['binding'] as Map<String, dynamic>?) ?? const {},
    );
    return (providers, binding);
  }

  /// 新建服务商。本地已生成 id(与能力绑定引用一致),服务端原样收。
  Future<AIServiceProviderConfig> createProvider(AIServiceProviderConfig provider) async {
    final data = await _postJson(
      'ai/providers',
      method: 'POST',
      body: provider.toJson(),
    );
    return AIServiceProviderConfig.fromJson(data);
  }

  /// 更新服务商。[provider.apiKey] 为空 / 掩码时服务端保留原 key。
  Future<AIServiceProviderConfig> updateProvider(AIServiceProviderConfig provider) async {
    final data = await _send(
      (token) => _client.patch(
        _uri('ai/providers/${provider.id}'),
        headers: _jsonHeaders(token),
        body: jsonEncode({
          'name': provider.name,
          'apiKey': provider.apiKey,
          'baseUrl': provider.baseUrl,
          'textModel': provider.textModel,
          'visionModel': provider.visionModel,
          'audioModel': provider.audioModel,
        }),
      ),
    );
    return AIServiceProviderConfig.fromJson(_decode(data));
  }

  /// 删除服务商(内置不可删;相关能力由服务端重绑到内置智谱)。
  Future<void> deleteProvider(String id) async {
    await _send(
      (token) => _client.delete(_uri('ai/providers/$id'), headers: _authHeaders(token)),
    );
  }

  /// 保存能力绑定(text / vision / speech)。
  Future<void> updateBinding(AICapabilityBinding binding) async {
    await _postJson('ai/providers/binding', method: 'PUT', body: binding.toJson());
  }

  /// 用**存储的**配置测试(掩码 key 场景 / 列表页一键测试)。
  Future<({bool success, String? errorCode, String? errorMessage, int latencyMs, String preview})>
      testStoredProvider(String providerId, String capability) async {
    final data = await _postJson(
      'ai/providers/test',
      body: {'providerId': providerId, 'capability': capability},
    );
    return _toTestResult(data);
  }

  /// 用表单里的内联配置测试(「先测后存」;真实 key 只出现在请求里,不落任何返回)。
  Future<({bool success, String? errorCode, String? errorMessage, int latencyMs, String preview})>
      testInlineProvider(AIServiceProviderConfig provider, String capability) async {
    final data = await _postJson(
      'ai/test-provider',
      body: {'provider': provider.toJson(), 'capability': capability},
    );
    return _toTestResult(data);
  }

  // ────────────────────────────────────────────────────────────────────
  // HTTP 基础设施
  // ────────────────────────────────────────────────────────────────────

  Uri _uri(String path) => Uri.parse('$baseUrl$apiPrefix/$path');

  Map<String, String> _authHeaders(String token) => {
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  Map<String, String> _jsonHeaders(String token) => {
        'Content-Type': 'application/json',
        ..._authHeaders(token),
      };

  Map<String, dynamic> _decode(http.Response resp) {
    final body = resp.body;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw _errorFrom(resp);
    }
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } on FormatException catch (e) {
      throw AiRelayException('响应不是合法 JSON: ${e.message}', statusCode: resp.statusCode);
    }
  }

  AiRelayException _errorFrom(http.Response resp) {
    // 服务端全局错误中间件:{error_code, message} / FastAPI {detail: ...}
    String message = 'HTTP ${resp.statusCode}';
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map<String, dynamic>) {
        final m = decoded['message'] ?? decoded['detail'];
        if (m is String && m.isNotEmpty) message = m;
      } else if (decoded is String && decoded.isNotEmpty) {
        message = decoded;
      }
    } on FormatException {
      if (resp.body.isNotEmpty && resp.body.length < 300) message = resp.body;
    }
    return AiRelayException('[${resp.statusCode}] $message', statusCode: resp.statusCode);
  }

  /// 统一发送:401 时触发一次 onUnauthorized(刷新 session)后重试;
  /// 网络层异常归一为 **transient** AiRelayException(自动记账据此保存草稿
  /// 等待重试,而不是当成"未识别到账单")。
  Future<http.Response> _send(
    Future<http.Response> Function(String token) fn, {
    bool retried = false,
  }) async {
    final token = await accessToken();
    http.Response resp;
    try {
      resp = await fn(token);
    } on AiRelayException {
      rethrow;
    } on SocketException catch (e) {
      throw AiRelayException('无法连接服务端: ${e.message}', transient: true);
    } on http.ClientException catch (e) {
      throw AiRelayException('服务端连接失败: ${e.message}', transient: true);
    } on TimeoutException catch (e) {
      throw AiRelayException('服务端请求超时', transient: true);
    }
    if (resp.statusCode == 401 && !retried && onUnauthorized != null) {
      logger.info('AiRelay', '401,刷新会话后重试');
      try {
        await onUnauthorized!();
      } catch (e) {
        logger.warning('AiRelay', '刷新会话失败: $e');
      }
      return _send(fn, retried: true);
    }
    // 服务端在线但上游/网关临时不可用 → 同样视为可重试
    if (resp.statusCode == 429 || resp.statusCode == 502 ||
        resp.statusCode == 503 || resp.statusCode == 504) {
      throw AiRelayException(
        '[${resp.statusCode}] ${_extractErrorMessage(resp)}',
        statusCode: resp.statusCode,
        transient: true,
      );
    }
    return resp;
  }

  String _extractErrorMessage(http.Response resp) {
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map<String, dynamic>) {
        final m = decoded['message'] ?? decoded['detail'];
        if (m is String && m.isNotEmpty) return m;
      }
    } on FormatException {
      // 保留默认信息
    }
    return resp.body.length > 120 ? resp.body.substring(0, 120) : resp.body;
  }

  Future<Map<String, dynamic>> _postJson(
    String path, {
    required Map<String, dynamic> body,
    String method = 'POST',
  }) async {
    final resp = await _send(
      (token) => _client.post(_uri(path), headers: _jsonHeaders(token), body: jsonEncode(body)),
    );
    return _decode(resp);
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final resp = await _send((token) => _client.get(_uri(path), headers: _authHeaders(token)));
    return _decode(resp);
  }

  Future<Map<String, dynamic>> _postMultipart(
    String path, {
    required String fileField,
    required File file,
    required Map<String, String> fields,
  }) async {
    if (!await file.exists()) {
      throw AiRelayException('文件不存在: ${file.path}');
    }
    final resp = await _send((token) async {
      final req = http.MultipartRequest('POST', _uri(path));
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      req.fields.addAll(fields);
      req.files.add(await http.MultipartFile.fromPath(
        fileField, file.path,
        filename: file.path.split(Platform.pathSeparator).last,
      ));
      return http.Response.fromStream(await _client.send(req));
    });
    return _decode(resp);
  }

  ({
    bool success,
    String? errorCode,
    String? errorMessage,
    int latencyMs,
    String preview,
  }) _toTestResult(Map<String, dynamic> data) {
    return (
      success: data['success'] as bool? ?? false,
      errorCode: data['error_code'] as String?,
      errorMessage: data['error_message'] as String?,
      latencyMs: (data['latency_ms'] as num?)?.toInt() ?? 0,
      preview: data['preview'] as String? ?? '',
    );
  }
}
