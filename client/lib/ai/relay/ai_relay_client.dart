import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../providers/ai_provider_config.dart';
import '../../services/automation/auto_book_trace.dart';
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

/// /ai/relay/vision-batch 的单张结果。
///
/// [imageIndex] 对应批量请求里该图的序号(与传入顺序一致)。
/// [error] 非空 = 该图识别失败(独占的失败,可对该图重试);content 为空串。
class AiVisionBatchItem {
  final int imageIndex;
  final String content;
  final bool duplicate;
  final String? error;

  const AiVisionBatchItem({
    required this.imageIndex,
    required this.content,
    this.duplicate = false,
    this.error,
  });

  factory AiVisionBatchItem.fromJson(Map<String, dynamic> json) {
    return AiVisionBatchItem(
      imageIndex: (json['image_index'] as num?)?.toInt() ?? 0,
      content: (json['content'] as String?) ?? '',
      duplicate: json['duplicate'] == true,
      error: json['error'] as String?,
    );
  }
}

/// 中转调用失败(网络 / 服务端错误)。工厂层会转成 [format] 后抛 AIException。
class AiRelayException implements Exception {
  final String message;
  final int? statusCode;

  /// true = 可恢复的临时失败(连不上服务端 / 超时 / 上游 5xx / 限流)。
  /// 自动记账据此把输入存为草稿等待重试;4xx 校验类失败为 false。
  final bool transient;

  /// 可区分的失败原因码(M1-1)。只用于日志与事件 reason,不含任何原文:
  /// `network` / `timeout` / `unauthorized` / `upstream_unavailable` /
  /// `http_error` / `bad_response` / `file_missing`。
  final String? errorCode;

  AiRelayException(
    this.message, {
    this.statusCode,
    this.transient = false,
    this.errorCode,
  });

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
  // 请求 deadline(M2-5)
  //
  // 客户端 deadline 略大于服务端上游 timeout,保证「谁先超时」可预期:
  // 超时后调用方拿到 transient 失败进入统一退避,不会让一个慢事件长期
  // 占住处理槽。自动记账提取与自由聊天使用不同值。
  // ────────────────────────────────────────────────────────────────────

  /// 记账文本提取(entry_type=`parse_tx_text`)。
  static const Duration textDeadline = Duration(seconds: 40);

  /// 截图/选图识别。
  static const Duration visionDeadline = Duration(seconds: 65);

  /// 一次多图批量识别的单请求 deadline。图片数越多越慢,按张数线性放大;
  /// 避免大批次被单个固定 deadline 截断。
  static Duration visionBatchDeadline(int imageCount) =>
      Duration(seconds: 65 * (1 + (imageCount ~/ 3)));

  /// 语音转写。
  static const Duration speechDeadline = Duration(seconds: 65);

  /// 自由对话(用户主动、可接受更长等待)。
  static const Duration chatDeadline = Duration(seconds: 130);

  /// 服务商配置 CRUD / 连通性测试。
  static const Duration configDeadline = Duration(seconds: 40);

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
    final payloadBytes =
        messages.fold<int>(0, (n, m) => n + utf8.encode(m.content).length);
    final sw = Stopwatch()..start();
    final Map<String, dynamic> data;
    try {
      data = await _postJson(
        'ai/relay/chat',
        body: {
          'messages': [
            for (final m in messages) {'role': m.role, 'content': m.content},
          ],
          'temperature': temperature,
          'disable_thinking': disableThinking,
          'entry_type': entryType,
          if (ledgerId != null && ledgerId.isNotEmpty) 'ledger_id': ledgerId,
          if (logInput != null && logInput.isNotEmpty) 'log_input': logInput,
        },
        deadline: entryType == 'parse_tx_text' ? textDeadline : chatDeadline,
      );
    } on AiRelayException catch (e) {
      _traceProviderCall(sw,
          payloadBytes: payloadBytes, outcome: e.errorCode ?? 'error');
      rethrow;
    }
    _traceProviderCall(sw, payloadBytes: payloadBytes, data: data);
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
    final payloadBytes = await _lengthOrNull(image);
    final sw = Stopwatch()..start();
    final Map<String, dynamic> data;
    try {
      data = await _postMultipart(
        'ai/relay/vision',
        fileField: 'image',
        file: image,
        fields: {
          'prompt': prompt,
          'disable_thinking': disableThinking ? 'true' : 'false',
          if (ledgerId != null && ledgerId.isNotEmpty) 'ledger_id': ledgerId,
          if (logInput != null && logInput.isNotEmpty) 'log_input': logInput,
        },
        deadline: visionDeadline,
      );
    } on AiRelayException catch (e) {
      _traceProviderCall(sw,
          payloadBytes: payloadBytes, outcome: e.errorCode ?? 'error');
      rethrow;
    }
    _traceProviderCall(sw, payloadBytes: payloadBytes, data: data);
    return (data['content'] as String?) ?? '';
  }

  /// 一次多图批量识别(截图/选图记账,一次发多张)。
  ///
  /// 服务端按该用户 vision provider 的 `visionConcurrency`(有上限并发队列)
  /// 至多并行调用大模型,逐张返回结果数组。每张结果含 `imageIndex`(与传入
  /// 顺序一致)、`content`(识别文本)、以及失败时的 `error`。单张失败不
  /// 影响其它张,整张结果里 `error != null` 即失败,客户端可对其重试。
  Future<List<AiVisionBatchItem>> visionBatch({
    required List<File> images,
    required String prompt,
    bool disableThinking = true,
    String? ledgerId,
    String? logInput,
  }) async {
    final sw = Stopwatch()..start();
    final Map<String, dynamic> data;
    try {
      data = await _postMultipartMulti(
        'ai/relay/vision-batch',
        fileField: 'images',
        files: images,
        fields: {
          'prompt': prompt,
          'disable_thinking': disableThinking ? 'true' : 'false',
          if (ledgerId != null && ledgerId.isNotEmpty) 'ledger_id': ledgerId,
          if (logInput != null && logInput.isNotEmpty) 'log_input': logInput,
        },
        deadline: visionBatchDeadline(images.length),
      );
    } on AiRelayException catch (e) {
      _traceProviderCall(sw,
          payloadBytes: null, outcome: e.errorCode ?? 'error');
      rethrow;
    }
    _traceProviderCall(sw, payloadBytes: null, data: data);
    final results = data['results'] as List? ?? const [];
    return [
      for (final r in results) AiVisionBatchItem.fromJson(r as Map<String, dynamic>),
    ];
  }

  /// M0-1:自动记账链上记一条 `provider_call`(主动路径 trace 为 null,不记)。
  /// 只带尺寸/服务商/耗时,prompt 与响应正文一律不进 trace。
  void _traceProviderCall(
    Stopwatch sw, {
    int? payloadBytes,
    Map<String, dynamic>? data,
    String? outcome,
  }) {
    AutoBookTrace.current?.stage(
      'provider_call',
      durationMs: sw.elapsedMilliseconds,
      payloadBytes: payloadBytes,
      providerId: data?['provider_id'] as String?,
      model: data?['model'] as String?,
      outcome: outcome ?? (data?['duplicate'] == true ? 'duplicate' : 'ok'),
    );
  }

  Future<int?> _lengthOrNull(File file) async {
    try {
      return await file.length();
    } catch (_) {
      return null;
    }
  }

  /// 语音转文字中转。服务端按绑定的 speech provider 转写并落 stt 日志。
  Future<String> speechToText(File audio) async {
    final data = await _postMultipart(
      'ai/relay/stt',
      fileField: 'audio',
      file: audio,
      fields: const {},
      deadline: speechDeadline,
    );
    return (data['text'] as String?) ?? '';
  }

  // ────────────────────────────────────────────────────────────────────
  // 服务商配置(密钥只存服务端)
  // ────────────────────────────────────────────────────────────────────

  /// 服务商列表 + 能力绑定。apiKey 字段是掩码(`****1234`,未配置时为空串)。
  Future<(List<AIServiceProviderConfig>, AICapabilityBinding)>
      listProviders() async {
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
  Future<AIServiceProviderConfig> createProvider(
      AIServiceProviderConfig provider) async {
    final data = await _postJson(
      'ai/providers',
      method: 'POST',
      body: provider.toJson(),
    );
    return AIServiceProviderConfig.fromJson(data);
  }

  /// 更新服务商。[provider.apiKey] 为空 / 掩码时服务端保留原 key。
  Future<AIServiceProviderConfig> updateProvider(
      AIServiceProviderConfig provider) async {
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
          'protocol': provider.protocol,
        }),
      ),
    );
    return AIServiceProviderConfig.fromJson(_decode(data));
  }

  /// 删除服务商(内置不可删;相关能力由服务端重绑到内置智谱)。
  Future<void> deleteProvider(String id) async {
    await _send(
      (token) => _client.delete(_uri('ai/providers/$id'),
          headers: _authHeaders(token)),
    );
  }

  /// 保存能力绑定(text / vision / speech)。
  Future<void> updateBinding(AICapabilityBinding binding) async {
    await _postJson('ai/providers/binding',
        method: 'PUT', body: binding.toJson());
  }

  /// 用**存储的**配置测试(掩码 key 场景 / 列表页一键测试)。
  Future<
      ({
        bool success,
        String? errorCode,
        String? errorMessage,
        int latencyMs,
        String preview
      })> testStoredProvider(String providerId, String capability) async {
    final data = await _postJson(
      'ai/providers/test',
      body: {'providerId': providerId, 'capability': capability},
    );
    return _toTestResult(data);
  }

  /// 用表单里的内联配置测试(「先测后存」;真实 key 只出现在请求里,不落任何返回)。
  Future<
          ({
            bool success,
            String? errorCode,
            String? errorMessage,
            int latencyMs,
            String preview
          })>
      testInlineProvider(
          AIServiceProviderConfig provider, String capability) async {
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
      throw AiRelayException(
        '响应不是合法 JSON: ${e.message}',
        statusCode: resp.statusCode,
        errorCode: 'bad_response',
      );
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
    // 刷新后仍 401 = 会话不可用(authenticationRequired):事件必须保留等
    // 用户登录恢复,绝不能当成「不是账单」终结并 ACK 原始队列。
    final unauthorized = resp.statusCode == 401;
    return AiRelayException(
      '[${resp.statusCode}] $message',
      statusCode: resp.statusCode,
      transient: unauthorized,
      errorCode: unauthorized ? 'unauthorized' : 'http_error',
    );
  }

  /// 统一发送:401 时触发一次 onUnauthorized(刷新 session)后重试;
  /// 网络层异常归一为 **transient** AiRelayException(自动记账据此保存草稿
  /// 等待重试,而不是当成"未识别到账单")。
  ///
  /// [deadline] 单次尝试的上限(M2-5);超时同样归一为 transient。
  Future<http.Response> _send(
    Future<http.Response> Function(String token) fn, {
    bool retried = false,
    Duration deadline = configDeadline,
  }) async {
    final String token;
    try {
      token = await accessToken();
    } on AiRelayException {
      rethrow;
    } catch (e) {
      // 会话不可用 / 静默恢复失败(CloudNotAuthenticatedException 等)=
      // authenticationRequired:事件必须保留等用户登录恢复,不能被当成
      // 「不是账单」终结。
      logger.warning('AiRelay', '取 access token 失败: $e');
      throw AiRelayException(
        '会话不可用,请重新登录后重试',
        transient: true,
        errorCode: 'unauthorized',
      );
    }
    http.Response resp;
    try {
      resp = await fn(token).timeout(deadline);
    } on AiRelayException {
      rethrow;
    } on SocketException catch (e) {
      throw AiRelayException('无法连接服务端: ${e.message}',
          transient: true, errorCode: 'network');
    } on http.ClientException catch (e) {
      throw AiRelayException('服务端连接失败: ${e.message}',
          transient: true, errorCode: 'network');
    } on TimeoutException {
      throw AiRelayException(
        '服务端请求超时(${deadline.inSeconds}s)',
        transient: true,
        errorCode: 'timeout',
      );
    }
    if (resp.statusCode == 401 && !retried && onUnauthorized != null) {
      logger.info('AiRelay', '401,刷新会话后重试');
      try {
        await onUnauthorized!();
      } catch (e) {
        logger.warning('AiRelay', '刷新会话失败: $e');
      }
      return _send(fn, retried: true, deadline: deadline);
    }
    // 服务端在线但上游/网关临时不可用 → 同样视为可重试
    if (resp.statusCode == 429 ||
        resp.statusCode == 502 ||
        resp.statusCode == 503 ||
        resp.statusCode == 504) {
      throw AiRelayException(
        '[${resp.statusCode}] ${_extractErrorMessage(resp)}',
        statusCode: resp.statusCode,
        transient: true,
        errorCode: 'upstream_unavailable',
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
    Duration deadline = configDeadline,
  }) async {
    final resp = await _send(
      (token) => _client.post(_uri(path),
          headers: _jsonHeaders(token), body: jsonEncode(body)),
      deadline: deadline,
    );
    return _decode(resp);
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final resp = await _send(
        (token) => _client.get(_uri(path), headers: _authHeaders(token)));
    return _decode(resp);
  }

  Future<Map<String, dynamic>> _postMultipart(
    String path, {
    required String fileField,
    required File file,
    required Map<String, String> fields,
    Duration deadline = configDeadline,
  }) async {
    if (!await file.exists()) {
      throw AiRelayException('文件不存在: ${file.path}', errorCode: 'file_missing');
    }
    final resp = await _send((token) async {
      final req = http.MultipartRequest('POST', _uri(path));
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      req.fields.addAll(fields);
      req.files.add(await http.MultipartFile.fromPath(
        fileField,
        file.path,
        filename: file.path.split(Platform.pathSeparator).last,
      ));
      return http.Response.fromStream(await _client.send(req));
    }, deadline: deadline);
    return _decode(resp);
  }

  /// 多文件 multipart:向同一字段重复添加多个文件(/ai/relay/vision-batch
  /// 的 `images`)。任一文件不存在 → file_missing。
  Future<Map<String, dynamic>> _postMultipartMulti(
    String path, {
    required String fileField,
    required List<File> files,
    required Map<String, String> fields,
    Duration deadline = configDeadline,
  }) async {
    for (final f in files) {
      if (!await f.exists()) {
        throw AiRelayException('文件不存在: ${f.path}', errorCode: 'file_missing');
      }
    }
    final resp = await _send((token) async {
      final req = http.MultipartRequest('POST', _uri(path));
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      req.fields.addAll(fields);
      for (final f in files) {
        req.files.add(await http.MultipartFile.fromPath(
          fileField,
          f.path,
          filename: f.path.split(Platform.pathSeparator).last,
        ));
      }
      return http.Response.fromStream(await _client.send(req));
    }, deadline: deadline);
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
