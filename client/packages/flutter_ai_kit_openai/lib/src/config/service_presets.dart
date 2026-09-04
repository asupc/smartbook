import 'openai_config.dart';

/// 服务商预设配置（支持简单配置 + 高级配置）
class ServicePresets {
  /// 智谱 GLM (OpenAI 格式) - 默认推荐
  ///
  /// 简单配置示例：
  /// ```dart
  /// final config = ServicePresets.zhipuGLM(apiKey: 'your-key');
  /// // 所有任务使用 glm-4-flash
  /// ```
  ///
  /// 高级配置示例：
  /// ```dart
  /// final config = ServicePresets.zhipuGLM(
  ///   apiKey: 'your-key',
  ///   textModel: 'glm-4-flash',     // 文本任务
  ///   visionModel: 'glm-4v-flash',  // 视觉任务
  ///   audioModel: 'glm-4-voice',    // 语音任务
  /// );
  /// ```
  static OpenAIConfig zhipuGLM({
    required String apiKey,
    String? textModel,
    String? visionModel,
    String? audioModel,
  }) =>
      OpenAIConfig(
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        apiKey: apiKey,
        defaultModel: 'glm-4-flash', // 默认模型（简单配置）
        textModel: textModel, // 文本专用模型（高级配置）
        visionModel: visionModel, // 视觉专用模型（高级配置）
        audioModel: audioModel, // 语音专用模型（高级配置）
      );

  /// 自定义服务商（支持任何 OpenAI 兼容的服务）
  ///
  /// 简单配置示例：
  /// ```dart
  /// final config = ServicePresets.custom(
  ///   baseUrl: 'https://api.openai.com/v1',
  ///   apiKey: 'sk-xxx',
  ///   defaultModel: 'gpt-4o-mini',
  /// );
  /// ```
  ///
  /// 高级配置示例：
  /// ```dart
  /// final config = ServicePresets.custom(
  ///   baseUrl: 'https://api.siliconflow.cn/v1',
  ///   apiKey: 'your-key',
  ///   defaultModel: 'Qwen/Qwen2.5-7B-Instruct',  // 默认
  ///   textModel: 'Qwen/Qwen2.5-7B-Instruct',     // 文本用便宜的
  ///   visionModel: 'Pro/Qwen/Qwen2-VL-72B-Instruct', // 视觉用强的
  ///   audioModel: 'FunAudioLLM/SenseVoiceSmall', // 语音用快的
  /// );
  /// ```
  static OpenAIConfig custom({
    required String baseUrl,
    required String apiKey,
    required String defaultModel,
    String? textModel,
    String? visionModel,
    String? audioModel,
    String? proxy,
  }) =>
      OpenAIConfig(
        baseUrl: baseUrl,
        apiKey: apiKey,
        defaultModel: defaultModel,
        textModel: textModel,
        visionModel: visionModel,
        audioModel: audioModel,
        proxy: proxy,
      );
}

/// GLM 模型预设
class GLMModels {
  /// GLM-4-Flash（默认推荐，快速且免费额度大）
  static const String flash = 'glm-4-flash';

  /// GLM-4-Flash 视觉版
  static const String flashVision = 'glm-4v-flash';

  /// GLM-4-Voice 语音模型
  static const String voice = 'glm-4-voice';

  /// GLM-4（标准版，更强大但较慢）
  static const String standard = 'glm-4';

  /// GLM-4V（视觉标准版）
  static const String standardVision = 'glm-4v';

  /// GLM-4-Plus（增强版，最强但最贵）
  static const String plus = 'glm-4-plus';

  /// GLM-4V-Plus（视觉增强版）
  static const String plusVision = 'glm-4v-plus';

  /// 所有文本模型选项
  static const List<String> textModels = [
    flash,
    standard,
    plus,
  ];

  /// 所有视觉模型选项
  static const List<String> visionModels = [
    flashVision,
    standardVision,
    plusVision,
  ];

  /// 所有语音模型选项
  static const List<String> audioModels = [
    voice,
  ];

  /// 获取模型显示名称
  static String getDisplayName(String model) {
    switch (model) {
      case flash:
        return 'GLM-4-Flash（快速，推荐）';
      case flashVision:
        return 'GLM-4V-Flash（视觉，快速）';
      case voice:
        return 'GLM-4-Voice（语音识别）';
      case standard:
        return 'GLM-4（标准）';
      case standardVision:
        return 'GLM-4V（视觉，标准）';
      case plus:
        return 'GLM-4-Plus（增强）';
      case plusVision:
        return 'GLM-4V-Plus（视觉，增强）';
      default:
        return model;
    }
  }
}
