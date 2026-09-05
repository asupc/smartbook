import 'dart:io';

import '../../services/system/logger_service.dart';
import '../providers/ai_provider_factory.dart';
import 'ai_extraction_context.dart';
import 'bill_info.dart';
import 'json_response_parser.dart';
import 'prompt_builder.dart';

/// AI 多模态记账底座 · 提取引擎。
///
/// 把 text / image / audio 输入 + [AiExtractionContext] 转换成
/// `List<BillInfo>`。这一层是 Layer 1 底座的对外契约,不依赖 Repository /
/// Riverpod / UI,可以独立单测。
///
/// LLM 调用经 [AIProviderFactory] 走自建服务端中转;AI 调用日志由服务端在
/// 中转现场直接落库(`ai_analysis_logs`,截图原文随请求落盘),引擎层不再
/// 事后上报。
abstract class AiExtractionEngine {
  /// 从文本提取账单信息。[AiExtractionOutcome.bills] 空 list 表示失败或无
  /// 有效账单;[AiExtractionOutcome.duplicate] = 服务端识别前判重命中
  /// (订单号/流水号已存在),App 端应静默跳过 —— 不记账不通知。
  ///
  /// 可恢复的临时失败(连不上服务端/超时)会以 [AIException](transient=true)
  /// 抛出,由自动入口保存草稿等待重试;其它失败返回空 outcome。
  ///
  /// [billGuard] 前置过滤段，截图/自动路径传入 [PromptBuilder.billGuardForImage]，
  /// 聊天等主动输入传空字符串。
  Future<AiExtractionOutcome> extractFromText(
    String text,
    AiExtractionContext context, {
    String billGuard = '',
  });

  /// 从图片提取账单信息。空 list 表示失败或无有效账单。
  ///
  /// [billGuard] 前置过滤段，截图/自动路径传入 [PromptBuilder.billGuardForImage]，
  /// 手动选图等主动输入传空字符串。
  Future<List<BillInfo>> extractFromImage(
    File image,
    AiExtractionContext context, {
    String billGuard = '',
  });

  /// 从音频提取账单信息(语音转文字 → 文本提取)。
  Future<AudioExtractionResult> extractFromAudio(
    File audio,
    AiExtractionContext context,
  );

  /// 仅语音转文字,不提取账单。
  Future<String?> speechToText(File audio);
}

/// 音频提取结果(同时返回识别出的原始文本,便于 UI 展示)
class AudioExtractionResult {
  final List<BillInfo> bills;
  final String? recognizedText;

  const AudioExtractionResult({
    this.bills = const [],
    this.recognizedText,
  });
}

/// 一次文本提取的完整结果。
class AiExtractionOutcome {
  final List<BillInfo> bills;

  /// 服务端识别前判重命中:该输入包含已识别过的账单唯一标识,
  /// 本次没有调用 LLM, bills 为空。应用层按「重复账单」静默处理。
  final bool duplicate;

  /// 命中的归一化唯一标识(订单号/流水号)。
  final String? matchedIdentifier;

  const AiExtractionOutcome({
    this.bills = const [],
    this.duplicate = false,
    this.matchedIdentifier,
  });
}

/// 默认实现:`PromptBuilder` + `AIProviderFactory` + `JsonResponseParser`。
class DefaultAiExtractionEngine implements AiExtractionEngine {
  static const String _tag = 'AiExtraction';

  final PromptBuilder _promptBuilder;
  final JsonResponseParser _parser;

  const DefaultAiExtractionEngine({
    PromptBuilder promptBuilder = const PromptBuilder(),
    JsonResponseParser parser = const JsonResponseParser(),
  })  : _promptBuilder = promptBuilder,
        _parser = parser;

  @override
  Future<AiExtractionOutcome> extractFromText(
    String text,
    AiExtractionContext context, {
    String billGuard = '',
  }) async {
    if (text.trim().isEmpty) {
      logger.warning(_tag, '输入文本为空');
      return const AiExtractionOutcome();
    }
    try {
      final prompt = _promptBuilder.build(
        context: context,
        inputSource: '从以下支付账单文本中',
        billGuard: billGuard,
        ocrText: text,
      );
      logger.debug(_tag, '文本 prompt 长度: ${prompt.length}');

      final response = await AIProviderFactory.chatWithMeta(
        prompt,
        temperature: 0.3,
        // 记账提取是结构化识别,不需要模型额外进行深度思考。
        disableThinking: true,
        logTag: _tag,
        entryType: 'parse_tx_text',
        ledgerId: context.ledgerId?.toString(),
        // 日志里展示原始用户输入,不含模板 / 分类上下文。
        logInput: text,
      );
      if (response.duplicate) {
        // 服务端识别前判重:同一笔账单(订单号/流水号)已识别过,
        // 本次没有调用 LLM。应用层据此静默跳过(不记账不通知)。
        return AiExtractionOutcome(
          duplicate: true,
          matchedIdentifier: response.matchedIdentifier,
        );
      }
      return AiExtractionOutcome(bills: _parser.parse(response.content));
    } on AIException catch (e) {
      // 可恢复的临时失败(连不上服务端等)向上抛,让自动入口保存草稿重试;
      // 其它失败(参数/配置/上游拒绝)按"无有效账单"处理。
      if (e.transient) rethrow;
      logger.warning(_tag, '文本账单提取失败: ${e.message}');
      return const AiExtractionOutcome();
    } catch (e, st) {
      logger.error(_tag, '文本账单提取异常', e, st);
      return const AiExtractionOutcome();
    }
  }

  @override
  Future<List<BillInfo>> extractFromImage(
    File image,
    AiExtractionContext context, {
    String billGuard = '',
  }) async {
    if (!await image.exists()) {
      logger.warning(_tag, '图片文件不存在');
      return const [];
    }
    // 服务端记录图片输入时只存元信息摘要 + 原图落盘(见 AIAnalysisLog 注释)。
    final caption = 'image: ${image.path.split(Platform.pathSeparator).last} '
        '(${image.lengthSync()} bytes)';
    try {
      final prompt = _promptBuilder.build(
        context: context,
        inputSource: '分析支付账单截图，从中',
        billGuard: billGuard,
      );
      logger.debug(_tag, '图片 prompt 长度: ${prompt.length}');

      final response = await AIProviderFactory.vision(
        image,
        prompt,
        // 截图记账只需读取文字/金额并输出结构化结果。
        disableThinking: true,
        logTag: _tag,
        ledgerId: context.ledgerId?.toString(),
        logInput: caption,
      );
      return _parser.parse(response);
    } on AIException catch (e) {
      logger.warning(_tag, '图片账单提取失败: ${e.message}');
      rethrow;
    } catch (e, st) {
      logger.error(_tag, '图片账单提取异常', e, st);
      rethrow;
    }
  }

  @override
  Future<AudioExtractionResult> extractFromAudio(
    File audio,
    AiExtractionContext context,
  ) async {
    if (!await audio.exists()) {
      logger.warning(_tag, '音频文件不存在');
      return const AudioExtractionResult();
    }
    try {
      logger.info(_tag, '步骤1: 语音转文字');
      final recognizedText = await AIProviderFactory.speechToText(
        audio,
        logTag: _tag,
      );
      logger.info(_tag, '识别结果: $recognizedText');
      if (recognizedText.trim().isEmpty) {
        logger.warning(_tag, '语音识别结果为空');
        return const AudioExtractionResult();
      }

      logger.info(_tag, '步骤2: 提取账单信息');
      final outcome = await extractFromText(recognizedText, context);
      return AudioExtractionResult(
        bills: outcome.bills,
        recognizedText: recognizedText,
      );
    } on AIException catch (e) {
      logger.warning(_tag, '语音账单提取失败: ${e.message}');
      return const AudioExtractionResult();
    } catch (e, st) {
      logger.error(_tag, '语音账单提取异常', e, st);
      return const AudioExtractionResult();
    }
  }

  @override
  Future<String?> speechToText(File audio) async {
    if (!await audio.exists()) {
      logger.warning(_tag, '音频文件不存在');
      return null;
    }
    try {
      final text = await AIProviderFactory.speechToText(audio, logTag: _tag);
      return text.trim().isEmpty ? null : text;
    } on AIException catch (e) {
      logger.warning(_tag, '语音转文字失败: ${e.message}');
      return null;
    } catch (e, st) {
      logger.error(_tag, '语音转文字异常', e, st);
      return null;
    }
  }
}
