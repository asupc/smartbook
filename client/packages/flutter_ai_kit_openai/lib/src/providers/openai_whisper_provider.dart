import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart' as dio_io;
import 'package:flutter_ai_kit/flutter_ai_kit.dart';

import '../config/openai_config.dart';

/// OpenAI 兼容的语音转文字 Provider
class OpenAIWhisperProvider implements AIProvider<File, String> {
  @override
  String get id => 'openai_whisper_${config.getAudioModel()}';

  @override
  String get name => 'OpenAI Whisper (${config.getAudioModel()})';

  @override
  AIProviderType get type => AIProviderType.cloud;

  @override
  bool get requiresNetwork => true;

  final OpenAIConfig config;
  final Dio _dio;

  OpenAIWhisperProvider({
    required this.config,
    Dio? dio,
  }) : _dio = dio ?? _createDio(config);

  static Dio _createDio(OpenAIConfig config) {
    final dio = Dio(BaseOptions(
      baseUrl: config.baseUrl,
      connectTimeout: Duration(seconds: config.timeout),
      receiveTimeout: Duration(seconds: config.timeout),
      headers: {
        'Authorization': 'Bearer ${config.apiKey}',
      },
    ));

    if (config.proxy != null) {
      (dio.httpClientAdapter as dio_io.IOHttpClientAdapter).createHttpClient =
          () {
        final client = HttpClient();
        client.findProxy = (uri) => 'PROXY ${config.proxy}';
        return client;
      };
    }

    if (config.enableLogging) {
      dio.interceptors.add(LogInterceptor(
        requestBody: true,
        responseBody: true,
      ));
    }

    return dio;
  }

  @override
  bool supportsTask(String taskType) {
    return [
      'speech_to_text',
      'audio_transcription',
    ].contains(taskType);
  }

  @override
  Future<bool> isReady() async => config.validate();

  @override
  Future<AIResult<String>> execute(AITask<File, String> task) async {
    final startTime = DateTime.now();

    try {
      // 使用 getAudioModel() 获取语音任务的模型
      final model = config.getAudioModel();

      // 构建 FormData（Whisper 使用 multipart/form-data）
      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(
          task.input.path,
          filename: task.input.path.split('/').last,
        ),
        'model': model,
        'language': 'zh', // 中文
        'response_format': 'json',
      });

      // 发送请求
      final response = await _dio.post(
        '/audio/transcriptions',
        data: formData,
      );

      // 解析响应
      final text = response.data['text'] as String;

      return AIResult.success(
        text,
        DateTime.now().difference(startTime),
        metadata: AIResultMetadata(
          providerName: name,
          modelName: model,
        ),
      );
    } on DioException catch (e) {
      return AIResult.failure(
        _parseError(e),
        DateTime.now().difference(startTime),
        metadata: AIResultMetadata(providerName: name),
      );
    } catch (e) {
      return AIResult.failure(
        e.toString(),
        DateTime.now().difference(startTime),
        metadata: AIResultMetadata(providerName: name),
      );
    }
  }

  @override
  Future<double> estimateCost(AITask<File, String> task) async {
    return 0.0005; // 语音转文字成本适中
  }

  String _parseError(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return '请求超时，请检查网络连接';
    }

    if (e.type == DioExceptionType.connectionError) {
      return '无法连接到服务器，请检查网络';
    }

    if (e.response?.data is Map) {
      final data = e.response!.data as Map<String, dynamic>;
      if (data['error'] is Map) {
        final error = data['error'] as Map<String, dynamic>;
        return error['message'] as String? ?? '未知错误';
      }
    }

    return e.message ?? '网络请求失败';
  }
}
