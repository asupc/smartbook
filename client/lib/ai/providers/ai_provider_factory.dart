import 'dart:io';

import 'ai_provider_config.dart';
import 'ai_provider_manager.dart';
import '../../services/system/logger_service.dart';
import '../relay/ai_relay_client.dart';

/// AI Provider 工厂类
///
/// 统一管理 AI 基础能力。**所有 LLM 调用都经自建 SmartBook-Cloud 服务端中转**
/// (`/ai/relay/*`):API Key 只存服务端,App 侧不再持有任何服务商密钥,也不
/// 再区分 OpenAI-compatible / 智谱协议 —— 协议适配全部在服务端完成。
///
/// 服务商配置("/ai/providers" CRUD)同样由服务端持有,本类只负责把调用
/// 委托给注入的 [AiRelayClient]([relayClient],sync_providers 启动时注入;
/// 云服务未配置时为 null,AI 功能报错引导登录)。
class AIProviderFactory {
  AIProviderFactory._();

  /// 服务端中转客户端。sync_providers 启动时注入;null = 云服务未配置/未登录。
  static AiRelayClient? relayClient;

  static AiRelayClient _requireRelay(String logTag) {
    final client = relayClient;
    if (client == null) {
      logger.warning(logTag, '云服务未配置,AI 功能不可用');
      // M1-1:冷启动时 Relay 可能只是「还没注入」,与「用户从未配置云服务」
      // 无法在这一层区分。两种情况都必须让自动入口保留事件(退避重试或等
      // Runtime ready),因此统一标记 transient + 可区分错误码。
      throw AIException(
        '需要登录并配置智记云服务后才能使用 AI 功能',
        transient: true,
        code: 'relay_not_ready',
      );
    }
    return client;
  }

  /// 空 / 掩码(`****1234`,来自服务端列表)都表示「本地没有真 key」——
  /// 测试时应走服务端按 provider id 用存储配置测试。
  static bool isMaskedApiKey(String key) =>
      key.isEmpty || key.startsWith('****');

  // ============================================================
  // 基础能力接口
  // ============================================================

  /// 文本对话中转的完整结果。供提取引擎区分「服务端判重跳过」与正常识别。
  ///
  /// [duplicate] = 服务端在识别前命中已知账单唯一标识,**没有调用 LLM**,
  /// content 为空串;App 端按「重复账单」静默处理(不记账/不通知)。
  static Future<AIChatResult> chatWithMeta(
    String prompt, {
    String? systemPrompt,
    double temperature = 0.7,
    String? logTag,
    bool disableThinking = false,
    String entryType = 'chat',
    String? ledgerId,
    String? logInput,
  }) async {
    final tag = logTag ?? 'AIFactory';
    final client = _requireRelay(tag);
    final messages = <AiRelayMessage>[
      if (systemPrompt != null && systemPrompt.isNotEmpty)
        AiRelayMessage(role: 'system', content: systemPrompt),
      AiRelayMessage(role: 'user', content: prompt),
    ];
    logger.debug(tag, '文本对话中转 (entry_type: $entryType)');
    try {
      final result = await client.chat(
        messages: messages,
        entryType: entryType,
        temperature: temperature,
        disableThinking: disableThinking,
        ledgerId: ledgerId,
        logInput: logInput,
      );
      if (result.duplicate) {
        logger.info(
            tag, '服务端判重命中,跳过识别 (identifier=${result.matchedIdentifier})');
      }
      return AIChatResult(
        content: result.content,
        duplicate: result.duplicate,
        matchedIdentifier: result.matchedIdentifier,
      );
    } on AiRelayException catch (e) {
      throw AIException(e.message, transient: e.transient, code: e.errorCode);
    }
  }

  /// 文本对话(自由对话等只需文本结果的入口)。
  ///
  /// [prompt] 用户输入(或拼好的提取 prompt)
  /// [entryType] 服务端日志归类:`chat`(自由对话,默认)/ `parse_tx_text`(记账提取)
  /// [ledgerId] 记账提取时传,日志归属账本
  /// [logInput] 日志里展示的原始用户输入(不含模板/上下文);缺省服务端取最后一条 user 消息
  /// [disableThinking] 对支持的模型关闭深度思考(记账提取建议开启)
  static Future<String> chat(
    String prompt, {
    String? systemPrompt,
    double temperature = 0.7,
    String? logTag,
    bool disableThinking = false,
    String entryType = 'chat',
    String? ledgerId,
    String? logInput,
  }) async {
    return (await chatWithMeta(
      prompt,
      systemPrompt: systemPrompt,
      temperature: temperature,
      logTag: logTag,
      disableThinking: disableThinking,
      entryType: entryType,
      ledgerId: ledgerId,
      logInput: logInput,
    ))
        .content;
  }

  /// 图片理解(截图 / 选图记账)。服务端把原图随日志落盘。
  ///
  /// [logInput] 原图摘要(caption),服务端日志用它而不是 base64。
  static Future<String> vision(
    File image,
    String prompt, {
    String? logTag,
    bool disableThinking = false,
    String? ledgerId,
    String? logInput,
  }) async {
    final tag = logTag ?? 'AIFactory';
    final client = _requireRelay(tag);
    logger.debug(tag, '图片理解中转');
    try {
      return await client.vision(
        image: image,
        prompt: prompt,
        disableThinking: disableThinking,
        ledgerId: ledgerId,
        logInput: logInput,
      );
    } on AiRelayException catch (e) {
      throw AIException(e.message, transient: e.transient, code: e.errorCode);
    }
  }

  /// 语音转文字
  static Future<String> speechToText(
    File audio, {
    String? logTag,
  }) async {
    final tag = logTag ?? 'AIFactory';
    final client = _requireRelay(tag);
    logger.debug(tag, '语音转写中转');
    try {
      return await client.speechToText(audio);
    } on AiRelayException catch (e) {
      throw AIException(e.message, transient: e.transient, code: e.errorCode);
    }
  }

  /// 验证当前文本服务商配置是否可用
  static Future<(bool success, String? error)> validateConfig({
    String? logTag,
  }) async {
    final config = await AIProviderManager.getProviderForCapability(
      AICapabilityType.text,
    );

    if (config == null) {
      return (false, '未配置文本对话服务商');
    }

    return validateProvider(config, logTag: logTag);
  }

  /// 验证指定服务商配置是否可用(兼容旧接口)
  static Future<(bool success, String? error)> validateProvider(
    AIServiceProviderConfig config, {
    String? logTag,
  }) async {
    return validateTextCapability(config, logTag: logTag);
  }

  /// 验证文本对话能力。
  ///
  /// 本地持有真 key(编辑表单「先测后存」)→ 内联配置测试;本地只有掩码 /
  /// 空 key(列表里已保存的服务商)→ 服务端按 id 用存储配置测试。
  static Future<(bool success, String? error)> validateTextCapability(
    AIServiceProviderConfig config, {
    String? logTag,
  }) async {
    final tag = logTag ?? 'AIFactory';
    return _validateCapability(config, 'text', tag);
  }

  /// 验证图片理解能力
  static Future<(bool success, String? error)> validateVisionCapability(
    AIServiceProviderConfig config, {
    String? logTag,
  }) async {
    final tag = logTag ?? 'AIFactory';
    return _validateCapability(config, 'vision', tag);
  }

  /// 验证语音转文字能力
  static Future<(bool success, String? error)> validateSpeechCapability(
    AIServiceProviderConfig config, {
    String? logTag,
  }) async {
    final tag = logTag ?? 'AIFactory';
    return _validateCapability(config, 'speech', tag);
  }

  static Future<(bool success, String? error)> _validateCapability(
    AIServiceProviderConfig config,
    String capability,
    String tag,
  ) async {
    logger.info(tag, '验证$capability能力: ${config.name}');
    final client = _requireRelay(tag);
    try {
      final result = isMaskedApiKey(config.apiKey)
          ? await client.testStoredProvider(config.id, capability)
          : await client.testInlineProvider(config, capability);
      if (result.success) {
        logger.info(tag, '$capability能力验证成功: ${config.name}');
        return (true, null);
      }
      // 与旧直连时代的错误文案对齐:空响应也算失败
      final error = result.errorMessage ??
          (result.errorCode != null
              ? '测试失败 (${result.errorCode})'
              : (result.preview.isEmpty ? 'API返回空响应' : null));
      logger.warning(tag, '$capability能力验证失败: $error');
      return (false, error);
    } on AiRelayException catch (e) {
      logger.warning(tag, '$capability能力验证失败: ${e.message}');
      return (false, e.message);
    } catch (e, st) {
      logger.error(tag, '$capability能力验证异常', e, st);
      return (false, '验证异常: $e');
    }
  }
}

/// 一次文本中转调用的结果。
class AIChatResult {
  final String content;

  /// 服务端识别前判重命中:本次没有调用 LLM,content 为空。
  final bool duplicate;

  /// 命中的归一化唯一标识(订单号/流水号)。
  final String? matchedIdentifier;

  const AIChatResult({
    required this.content,
    this.duplicate = false,
    this.matchedIdentifier,
  });
}

/// AI 异常
class AIException implements Exception {
  final String message;

  /// true = 可恢复的临时失败(连不上服务端 / 超时 / 上游 5xx / 限流 / Relay
  /// 尚未注入)。自动记账据此把输入保存为离线草稿等待重试,**绝不能**把这类
  /// 失败当成「不是账单」而终结事件并 ACK 原始队列。
  final bool transient;

  /// 可区分的失败原因码(M1-1)。取值见 [AiRelayException.errorCode],另加
  /// `relay_not_ready`(云服务未配置 / Relay 未注入)。仅用于日志与事件
  /// reason,不含任何原文。
  final String? code;

  AIException(this.message, {this.transient = false, this.code});

  @override
  String toString() => message;
}
