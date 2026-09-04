import 'package:json_annotation/json_annotation.dart';

part 'openai_config.g.dart';

/// OpenAI 兼容服务配置（支持混合模型配置）
@JsonSerializable()
class OpenAIConfig {
  /// Base URL（可配置，支持不同服务商）
  final String baseUrl;

  /// API Key
  final String apiKey;

  /// 默认模型（简单配置，所有任务使用此模型）
  final String defaultModel;

  /// 高级配置：文本模型（可选，为空时使用 defaultModel）
  final String? textModel;

  /// 高级配置：视觉模型（可选，为空时使用 defaultModel）
  final String? visionModel;

  /// 高级配置：语音模型（可选，为空时使用 defaultModel）
  final String? audioModel;

  /// 超时时间（秒）
  final int timeout;

  /// 是否启用日志
  final bool enableLogging;

  /// HTTP 代理（可选，用于科学上网）
  final String? proxy;

  const OpenAIConfig({
    required this.baseUrl,
    required this.apiKey,
    this.defaultModel = 'gpt-4o-mini',
    this.textModel,
    this.visionModel,
    this.audioModel,
    this.timeout = 60,
    this.enableLogging = false,
    this.proxy,
  });

  /// 获取文本任务使用的模型（优先使用专用模型，否则回退到默认）
  String getTextModel() => textModel ?? defaultModel;

  /// 获取视觉任务使用的模型
  String getVisionModel() => visionModel ?? defaultModel;

  /// 获取语音任务使用的模型
  String getAudioModel() => audioModel ?? defaultModel;

  /// 从 JSON 创建
  factory OpenAIConfig.fromJson(Map<String, dynamic> json) =>
      _$OpenAIConfigFromJson(json);

  /// 转换为 JSON
  Map<String, dynamic> toJson() => _$OpenAIConfigToJson(this);

  /// 验证配置有效性
  bool validate() {
    if (baseUrl.isEmpty || apiKey.isEmpty || defaultModel.isEmpty) {
      return false;
    }
    return true;
  }

  /// 复制并修改
  OpenAIConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? defaultModel,
    String? textModel,
    String? visionModel,
    String? audioModel,
    int? timeout,
    bool? enableLogging,
    String? proxy,
  }) {
    return OpenAIConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      defaultModel: defaultModel ?? this.defaultModel,
      textModel: textModel ?? this.textModel,
      visionModel: visionModel ?? this.visionModel,
      audioModel: audioModel ?? this.audioModel,
      timeout: timeout ?? this.timeout,
      enableLogging: enableLogging ?? this.enableLogging,
      proxy: proxy ?? this.proxy,
    );
  }
}
