import 'dart:io';

import '../providers/ai_provider_config.dart';
import '../providers/ai_provider_factory.dart';
import '../providers/ai_provider_manager.dart';
import '../../services/system/logger_service.dart';
import 'ai_extraction_context.dart';
import 'bill_info.dart';
import 'json_response_parser.dart';
import 'prompt_builder.dart';

/// AI 多模态记账底座 · 提取引擎。
///
/// 把 text / image / audio 输入 + [AiExtractionContext] 转换成
/// `List<BillInfo>`。这一层是 Layer 1 底座的对外契约,不依赖 Repository /
/// Riverpod / UI,可以独立单测。
abstract class AiExtractionEngine {
  /// 从文本提取账单信息。空 list 表示失败或无有效账单。
  ///
  /// [billGuard] 前置过滤段，截图/自动路径传入 [PromptBuilder.billGuardForImage]，
  /// 聊天等主动输入传空字符串。
  /// [onCall] 每次真实 AI 调用完成(含失败)后回调一次,应用层借它上报
  /// `ai_analysis_logs`(见 [AiCallReport])。
  Future<List<BillInfo>> extractFromText(
    String text,
    AiExtractionContext context, {
    String billGuard = '',
    AiCallReporter? onCall,
  });

  /// 从图片提取账单信息。空 list 表示失败或无有效账单。
  ///
  /// [billGuard] 前置过滤段，截图/自动路径传入 [PromptBuilder.billGuardForImage]，
  /// 手动选图等主动输入传空字符串。
  Future<List<BillInfo>> extractFromImage(
    File image,
    AiExtractionContext context, {
    String billGuard = '',
    AiCallReporter? onCall,
  });

  /// 从音频提取账单信息(语音转文字 → 文本提取)。
  Future<AudioExtractionResult> extractFromAudio(
    File audio,
    AiExtractionContext context, {
    AiCallReporter? onCall,
  });

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

/// 一次 AI 调用(记账分析)的裸事实 —— 引擎层在每次真实调用后上报给
/// observer(失败也上报,status='error')。
///
/// 只含引擎层知道的信息(时长/结果/原文);归属方补充业务元数据 —
/// ledger_id 由应用层(AiBookkeeper)在回调里补上。
/// [imageFile] 图片输入的原文(App 上报路径随日志一起 multipart 上传,
/// 服务端落盘供 Web「AI 调用记录」详情查看;文本/语音为 null)。
class AiCallReport {
  /// 与 server `ai_analysis_logs.entry_type` 对齐(3 种,见项目 CLAUDE.md)。
  final String entryType;
  final String status; // 'ok' | 'error'
  final String? providerId;
  final String? model;
  final String? ledgerId;
  final String? inputText;
  final String? outputText;
  final String? errorMessage;
  final int durationMs;
  final File? imageFile;

  const AiCallReport({
    required this.entryType,
    required this.status,
    this.providerId,
    this.model,
    this.ledgerId,
    this.inputText,
    this.outputText,
    this.errorMessage,
    this.durationMs = 0,
    this.imageFile,
  });

  AiCallReport copyWith({String? ledgerId, File? imageFile}) => AiCallReport(
        entryType: entryType,
        status: status,
        providerId: providerId,
        model: model,
        ledgerId: ledgerId ?? this.ledgerId,
        inputText: inputText,
        outputText: outputText,
        errorMessage: errorMessage,
        durationMs: durationMs,
        imageFile: imageFile ?? this.imageFile,
      );
}

/// AI 调用观察者。实现方拿到 report 后自行决定做什么(上报 server /
/// 落本地/丢弃);实现契约与引擎层相同:不抛异常、不阻塞主流程。
abstract class AiCallReporter {
  void call(AiCallReport report);
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
  Future<List<BillInfo>> extractFromText(
    String text,
    AiExtractionContext context, {
    String billGuard = '',
    AiCallReporter? onCall,
  }) async {
    if (text.trim().isEmpty) {
      logger.warning(_tag, '输入文本为空');
      return const [];
    }
    final stopwatch = Stopwatch()..start();
    String? outputText;
    try {
      final prompt = _promptBuilder.build(
        context: context,
        inputSource: '从以下支付账单文本中',
        billGuard: billGuard,
        ocrText: text,
      );
      logger.debug(_tag, '文本 prompt 长度: ${prompt.length}');
      logger.debug(_tag, '完整 prompt:\n$prompt');

      final config =
          await AIProviderManager.getProviderForCapability(AICapabilityType.text);
      final response = await AIProviderFactory.chat(
        prompt,
        temperature: 0.3,
        logTag: _tag,
      );
      outputText = response;
      _fireReport(
        onCall,
        stopwatch,
        entryType: 'parse_tx_text',
        status: 'ok',
        providerId: config?.name,
        model: config?.textModel,
        inputText: text,
        outputText: response,
      );
      return _parser.parse(response);
    } on AIException catch (e) {
      logger.warning(_tag, '文本账单提取失败: ${e.message}');
      _fireReport(
        onCall,
        stopwatch,
        entryType: 'parse_tx_text',
        status: 'error',
        inputText: text,
        outputText: outputText,
        errorMessage: e.message,
      );
      return const [];
    } catch (e, st) {
      logger.error(_tag, '文本账单提取异常', e, st);
      _fireReport(
        onCall,
        stopwatch,
        entryType: 'parse_tx_text',
        status: 'error',
        inputText: text,
        outputText: outputText,
        errorMessage: '$e',
      );
      return const [];
    }
  }

  @override
  Future<List<BillInfo>> extractFromImage(
    File image,
    AiExtractionContext context, {
    String billGuard = '',
    AiCallReporter? onCall,
  }) async {
    if (!await image.exists()) {
      logger.warning(_tag, '图片文件不存在');
      return const [];
    }
    // 服务端记录图片输入时不存 base64,只存元信息摘要(见 AIAnalysisLog 注释)。
    final caption = 'image: ${image.path.split(Platform.pathSeparator).last} '
        '(${image.lengthSync()} bytes)';
    final stopwatch = Stopwatch()..start();
    String? outputText;
    try {
      final prompt = _promptBuilder.build(
        context: context,
        inputSource: '分析支付账单截图，从中',
        billGuard: billGuard,
      );
      logger.debug(_tag, '图片 prompt 长度: ${prompt.length}');
      logger.debug(_tag, '完整 prompt:\n$prompt');

      final config =
          await AIProviderManager.getProviderForCapability(AICapabilityType.vision);
      final response = await AIProviderFactory.vision(
        image,
        prompt,
        logTag: _tag,
      );
      outputText = response;
      _fireReport(
        onCall,
        stopwatch,
        entryType: 'parse_tx_image',
        status: 'ok',
        providerId: config?.name,
        model: config?.visionModel,
        inputText: caption,
        outputText: response,
        imageFile: image,
      );
      return _parser.parse(response);
    } on AIException catch (e) {
      logger.warning(_tag, '图片账单提取失败: ${e.message}');
      _fireReport(
        onCall,
        stopwatch,
        entryType: 'parse_tx_image',
        status: 'error',
        inputText: caption,
        outputText: outputText,
        errorMessage: e.message,
        imageFile: image,
      );
      rethrow;
    } catch (e, st) {
      logger.error(_tag, '图片账单提取异常', e, st);
      _fireReport(
        onCall,
        stopwatch,
        entryType: 'parse_tx_image',
        status: 'error',
        inputText: caption,
        outputText: outputText,
        errorMessage: '$e',
        imageFile: image,
      );
      rethrow;
    }
  }

  @override
  Future<AudioExtractionResult> extractFromAudio(
    File audio,
    AiExtractionContext context, {
    AiCallReporter? onCall,
  }) async {
    if (!await audio.exists()) {
      logger.warning(_tag, '音频文件不存在');
      return const AudioExtractionResult();
    }
    // 语音 = STT + 文本提取 两次 AI 调用,但对外只记一条(entry=parse_tx_text),
    // 递归调 extractFromText 时不传 onCall,避免重复上报。
    final stopwatch = Stopwatch()..start();
    var status = 'ok';
    String? errorMessage;
    String? recognizedText;
    // 在 try 内首次 await(getProviderForCapability 可能抛,var 放外面让
    // finally 可见)。
    AIServiceProviderConfig? speechConfig;
    try {
      speechConfig = await AIProviderManager.getProviderForCapability(
        AICapabilityType.speech,
      );
      logger.info(_tag, '步骤1: 语音转文字');
      recognizedText = await AIProviderFactory.speechToText(
        audio,
        logTag: _tag,
      );
      logger.info(_tag, '识别结果: $recognizedText');
      if (recognizedText.trim().isEmpty) {
        logger.warning(_tag, '语音识别结果为空');
        return const AudioExtractionResult();
      }

      logger.info(_tag, '步骤2: 提取账单信息');
      final bills = await extractFromText(recognizedText, context);
      return AudioExtractionResult(
        bills: bills,
        recognizedText: recognizedText,
      );
    } on AIException catch (e) {
      logger.warning(_tag, '语音账单提取失败: ${e.message}');
      status = 'error';
      errorMessage = e.message;
      return const AudioExtractionResult();
    } catch (e, st) {
      logger.error(_tag, '语音账单提取异常', e, st);
      status = 'error';
      errorMessage = '$e';
      return const AudioExtractionResult();
    } finally {
      _fireReport(
        onCall,
        stopwatch,
        entryType: 'parse_tx_text',
        status: status,
        providerId: speechConfig?.name,
        model: speechConfig?.audioModel,
        inputText: recognizedText,
        errorMessage: errorMessage,
      );
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

  /// 触发一次调用上报。回调自身异常不向外传播(日志记一笔),上报失败不得
  /// 影响记账主流程。
  void _fireReport(
    AiCallReporter? onCall,
    Stopwatch stopwatch, {
    required String entryType,
    required String status,
    String? providerId,
    String? model,
    String? inputText,
    String? outputText,
    String? errorMessage,
    File? imageFile,
  }) {
    if (onCall == null) return;
    try {
      onCall(AiCallReport(
        entryType: entryType,
        status: status,
        providerId: providerId,
        model: model,
        inputText: inputText,
        outputText: outputText,
        errorMessage: errorMessage,
        durationMs: stopwatch.elapsedMilliseconds,
        imageFile: imageFile,
      ));
    } catch (e) {
      logger.warning(_tag, 'AI 调用上报回调异常(已忽略): $e');
    }
  }
}
