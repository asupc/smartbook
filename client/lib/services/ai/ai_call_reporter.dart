import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../ai/core/ai_extraction_engine.dart';
import '../system/logger_service.dart';

/// AI 调用记录上报器 —— 把 App 本地的 AI 记账调用(通知记账/对话/截图/语音)
/// POST 到服务端,Web「AI 调用记录」页面与 App 共用同一张 `ai_analysis_logs`
/// 表。
///
/// 两条上报路径:
/// - **带图**(截图记账):`POST /api/v1/ai/logs/image`(multipart,元数据字段
///   + 原图文件),服务端落盘供 Web 详情直接查看;示例图失败(文件不存在 /
///   超过 5MB 上限 / 请求异常)降级为纯文本上报,审计记录不因丢图而缺失。
/// - **纯文本**(对话/短信/语音):`POST /api/v1/ai/logs`(JSON,与旧客户端
///   兼容)。
///
/// 设计约束(与 server 端 `services/ai/analysis_log.py` 同理念):
/// 1. **静默失败** — 网络差/未登录/服务端下线都只打日志,绝不阻塞、绝不
///    影响记账主流程;
/// 2. fire-and-forget — [call] 同步返回,实际 POST 在后台跑。
class AiCallReporterHttp implements AiCallReporter {
  /// 与服务端 `/api/v1/ai/logs/image` 上限一致(5MB);超出的图不上传、
  /// 走纯文本降级。
  static const int _maxImageBytes = 5 * 1024 * 1024;
  AiCallReporterHttp({
    required this.baseUrl,
    required this.apiPrefix,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String apiPrefix;
  final Future<String> Function() accessToken;
  final http.Client _client;

  /// 上报一次 AI 调用。任何异常吞掉(打 warning),调用方无感知。
  @override
  void call(AiCallReport report) {
    unawaited(_post(report));
  }

  Future<void> _post(AiCallReport report) async {
    try {
      if (baseUrl.isEmpty) return; // SmartBook Cloud 未配置,没什么可上报
      final token = await accessToken();
      final jsonUri = Uri.parse('$baseUrl$apiPrefix/ai/logs');
      http.Response resp;
      if (report.imageFile != null) {
        try {
          resp = await _postMultipart(
            Uri.parse('$baseUrl$apiPrefix/ai/logs/image'),
            token,
            report,
          );
        } catch (_) {
          // 图片路径失败(文件被清/太大/网络)降级为纯文本上报 ——
          // 审计记录不因丢图而缺失(与进程被杀兜底同理)。
          resp = await _postJson(jsonUri, token, report);
        }
      } else {
        resp = await _postJson(jsonUri, token, report);
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        logger.warning(
          'AiReporter',
          '上报失败 status=${resp.statusCode}: ${resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body}',
        );
      }
    } catch (e) {
      logger.warning('AiReporter', '上报失败(已忽略,不影响记账): $e');
    }
  }

  /// 带图上报:`POST /ai/logs/image`(multipart,字段 + image 文件)。
  Future<http.Response> _postMultipart(
    Uri uri,
    String token,
    AiCallReport report,
  ) async {
    final image = report.imageFile!;
    if (!await image.exists() || await image.length() > _maxImageBytes) {
      throw StateError('image not uploadable: ${image.path}');
    }
    final req = http.MultipartRequest('POST', uri);
    if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
    req.fields.addAll({
      'entry_type': report.entryType,
      'status': report.status,
      if (report.providerId != null) 'provider_id': report.providerId!,
      if (report.model != null) 'model': report.model!,
      if (report.ledgerId != null) 'ledger_id': report.ledgerId!,
      if (report.inputText != null) 'input_text': report.inputText!,
      if (report.outputText != null) 'output_text': report.outputText!,
      if (report.errorMessage != null) 'error_message': report.errorMessage!,
      if (report.durationMs > 0) 'duration_ms': '${report.durationMs}',
    });
    req.files.add(await http.MultipartFile.fromPath('image', image.path,
        filename: image.path.split(Platform.pathSeparator).last));
    return http.Response.fromStream(await _client.send(req));
  }

  /// 纯文本上报:`POST /ai/logs`(JSON,与旧客户端兼容的端点)。
  Future<http.Response> _postJson(
    Uri uri,
    String token,
    AiCallReport report,
  ) async {
    return _client.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'entry_type': report.entryType,
        'status': report.status,
        'provider_id': report.providerId,
        'model': report.model,
        'ledger_id': report.ledgerId,
        'input_text': report.inputText,
        'output_text': report.outputText,
        'error_message': report.errorMessage,
        'duration_ms': report.durationMs,
      }),
    );
  }
}
