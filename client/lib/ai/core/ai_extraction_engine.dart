import 'dart:async';
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
  /// 从文本提取账单信息。结果一律由 [AiExtractionOutcome.status] 表达:
  /// `noBill`(模型明确说不是账单)与 `retryableFailure` / `permanentFailure`
  /// (调用/解析失败)是**不同**语义,自动入口据此决定重试还是终结事件。
  ///
  /// M1-2:禁止用「空 bills」代表异常 —— 那会让瞬态失败被当成「非账单」而
  /// 误 ACK 原始队列项,事件永久丢失。
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

/// 一次文本提取的结果语义(M1-2)。
///
/// 关键约束:**「没有账单」和「调用失败」必须是不同状态**。旧实现把两者都
/// 表达成空 bills,导致 Relay 未就绪 / 网络抖动被自动入口当成「不是交易」,
/// 事件被终结并 ACK 原始队列 —— 真实短信永久丢失。
enum ExtractionStatus {
  /// 模型正常返回,解析出至少一笔账单。
  success,

  /// 模型正常返回,但明确不是账单(或解析后没有有效账单)。
  /// **只有这个状态允许把事件终结为 ignored 并 ACK 原始队列。**
  noBill,

  /// 服务端识别前判重命中:本次没有调用 LLM,按重复账单静默处理。
  duplicate,

  /// 临时失败(Relay 未注入 / 会话恢复中 / 网络 / 超时 / 限流 / 上游 5xx),
  /// 应退避后重试。
  retryableFailure,

  /// 永久失败(参数非法 / 上游拒绝 / 响应结构不可解析),重试无意义,
  /// 事件进 failed 并对用户可见。
  permanentFailure,
}

/// 一次文本提取的完整结果。
class AiExtractionOutcome {
  /// 结果语义。调用方**必须**按它分支,不得只看 [bills] 是否为空。
  final ExtractionStatus status;

  final List<BillInfo> bills;

  /// 可区分的失败原因码(见 [AIException.code]),失败时才有值。
  /// 只用于日志与事件 reason,不含任何输入原文。
  final String? errorCode;

  /// 可直接展示给用户的脱敏提示,失败时才有值。
  final String? safeMessage;

  /// 命中的归一化唯一标识(订单号/流水号),仅 [ExtractionStatus.duplicate]。
  final String? matchedIdentifier;

  const AiExtractionOutcome({
    required this.status,
    this.bills = const [],
    this.errorCode,
    this.safeMessage,
    this.matchedIdentifier,
  });

  /// 服务端识别前判重命中:该输入包含已识别过的账单唯一标识,
  /// 本次没有调用 LLM。应用层按「重复账单」静默处理。
  bool get duplicate => status == ExtractionStatus.duplicate;

  /// 调用/解析失败(与「不是账单」严格区分)。
  bool get failed =>
      status == ExtractionStatus.retryableFailure ||
      status == ExtractionStatus.permanentFailure;

  /// 可退避重试。
  bool get retryable => status == ExtractionStatus.retryableFailure;
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
      return const AiExtractionOutcome(
        status: ExtractionStatus.noBill,
        errorCode: 'empty_input',
      );
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
          status: ExtractionStatus.duplicate,
          matchedIdentifier: response.matchedIdentifier,
        );
      }
      final bills = _parser.parse(response.content);
      return AiExtractionOutcome(
        status:
            bills.isEmpty ? ExtractionStatus.noBill : ExtractionStatus.success,
        bills: bills,
      );
    } on AIException catch (e) {
      // M1-2:失败不再退化成空 bills。transient(Relay 未就绪 / 网络 / 超时 /
      // 限流 / 上游 5xx / 会话待恢复)→ retryableFailure,自动入口保存草稿并
      // 退避;其余(参数 / 配置 / 上游拒绝)→ permanentFailure,进 failed 让
      // 用户可见,两者都**不允许**被当成「不是账单」。
      logger.warning(_tag, '文本账单提取失败: ${e.message} (code=${e.code})');
      return AiExtractionOutcome(
        status: e.transient
            ? ExtractionStatus.retryableFailure
            : ExtractionStatus.permanentFailure,
        errorCode: e.code ?? (e.transient ? 'transient' : 'permanent'),
        safeMessage: e.message,
      );
    } catch (e, st) {
      logger.error(_tag, '文本账单提取异常', e, st);
      final transient = e is SocketException || e is TimeoutException;
      return AiExtractionOutcome(
        status: transient
            ? ExtractionStatus.retryableFailure
            : ExtractionStatus.permanentFailure,
        errorCode: transient ? 'network' : 'unexpected',
        safeMessage: transient ? '网络异常,稍后自动重试' : 'AI 识别异常',
      );
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
