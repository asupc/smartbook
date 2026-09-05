import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 自动记账来源。字符串值会写入本地 event store，故不要随意改名。
enum AutoBookSource {
  screenshot,
  sharedImage,
  sms,
  notification,
  screenText,
  deepLinkText,
  deepLinkDirect,
  import,
  recurring,
  manual,
}

extension AutoBookSourceValue on AutoBookSource {
  String get value => name;
}

/// 触发意图。自动入口和用户主动入口必须分开，策略不能混用。
enum AutoBookCaptureIntent {
  automatic,
  userInitiated,
  importData,
  recurring,
}

extension AutoBookCaptureIntentValue on AutoBookCaptureIntent {
  String get value => switch (this) {
        AutoBookCaptureIntent.automatic => 'automatic',
        AutoBookCaptureIntent.userInitiated => 'userInitiated',
        AutoBookCaptureIntent.importData => 'import',
        AutoBookCaptureIntent.recurring => 'recurring',
      };
}

/// 自动记账事件生命周期。
enum AutoBookState {
  captured,
  processing,
  pending,
  booked,
  duplicate,
  ignored,
  retry,
  failed,
  expired,
}

extension AutoBookStateValue on AutoBookState {
  String get value => name;

  static AutoBookState parse(String? raw) {
    return AutoBookState.values.firstWhere(
      (s) => s.value == raw,
      orElse: () => AutoBookState.captured,
    );
  }
}

/// 原始入口事件的统一描述。
///
/// [eventKey] 是入口事件的幂等键，不是 transactions.syncId。它可以由 native
/// 元数据、图片内容 hash、Deep Link 的 idempotency_key 或账单文件行 hash 派生。
class AutoBookInput {
  final String eventKey;
  final AutoBookSource source;
  final AutoBookCaptureIntent captureIntent;
  final int? ledgerId;
  final DateTime capturedAt;
  final DateTime? sourceOccurredAt;
  final String? sourceChannel;
  final String? externalId;
  final String? contentHash;

  /// 可选原始证据。仅当隐私策略允许时写入本地/上传服务端。
  final String? rawTitle;
  final String? rawText;
  final String? rawActor;
  final Map<String, dynamic>? rawMetadata;
  final DateTime? expiresAt;

  const AutoBookInput({
    required this.eventKey,
    required this.source,
    this.captureIntent = AutoBookCaptureIntent.automatic,
    this.ledgerId,
    required this.capturedAt,
    this.sourceOccurredAt,
    this.sourceChannel,
    this.externalId,
    this.contentHash,
    this.rawTitle,
    this.rawText,
    this.rawActor,
    this.rawMetadata,
    this.expiresAt,
  });

  String get sourceValue => source.value;
  String get captureIntentValue => captureIntent.value;
}

/// Coordinator 完成一个事件后写入 event store 的结果摘要。
class AutoBookEventUpdate {
  final AutoBookState state;
  final int? transactionId;
  final int? duplicateOfTransactionId;
  final String? billJson;
  final String? reason;
  final DateTime? nextRetryAt;
  final DateTime? expiresAt;

  const AutoBookEventUpdate({
    required this.state,
    this.transactionId,
    this.duplicateOfTransactionId,
    this.billJson,
    this.reason,
    this.nextRetryAt,
    this.expiresAt,
  });
}

/// 一次自动记账执行的返回包装。
class AutoBookExecution<T> {
  final bool skipped;
  final T? value;
  final AutoBookState state;
  final int eventId;
  final int? existingTransactionId;

  const AutoBookExecution({
    required this.skipped,
    required this.value,
    required this.state,
    required this.eventId,
    this.existingTransactionId,
  });

  bool get terminal => switch (state) {
        AutoBookState.booked ||
        AutoBookState.duplicate ||
        AutoBookState.ignored ||
        AutoBookState.pending ||
        AutoBookState.failed ||
        AutoBookState.expired =>
          true,
        _ => false,
      };
}

/// 离线识别草稿(自动记账连不上服务端时保存的待重试输入)。
///
/// 存在 `AutoBookEvents.draftPayloadJson`,与 raw* 证据列相互独立:
/// 识别成功/事件终态后立即清除,不参与隐私面板证据统计,也不进入
/// evidence 上传通道。
class AutoBookDraftPayload {
  static const int currentVersion = 1;

  /// true = 图片识别(截图/分享图片),[imagePath] 是待重跑的原图路径。
  /// false = 文本识别,[text] 为原始正文。
  final bool isImage;
  final String? text;
  final String? title;

  /// 短信发送者 / 通知包名(重试时还原通道上下文)。
  final String? actor;
  final String? imagePath;
  final int version;

  const AutoBookDraftPayload({
    required this.isImage,
    this.text,
    this.title,
    this.actor,
    this.imagePath,
    this.version = currentVersion,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'isImage': isImage,
        if (text != null) 'text': text,
        if (title != null) 'title': title,
        if (actor != null) 'actor': actor,
        if (imagePath != null) 'imagePath': imagePath,
      };

  static AutoBookDraftPayload? fromJson(Object? value) {
    if (value is! Map) return null;
    return AutoBookDraftPayload(
      isImage: value['isImage'] == true,
      text: value['text'] as String?,
      title: value['title'] as String?,
      actor: value['actor'] as String?,
      imagePath: value['imagePath'] as String?,
      version: (value['version'] as num?)?.toInt() ?? 1,
    );
  }

  /// 一行预览文本(草稿列表展示用)。不包含正文全文,只示意来源。
  String get previewLabel => isImage ? 'image' : (text ?? '').trim();
}

/// 规范化文本并生成短 hash。只用于 key/索引，不用于日志展示。
String autoBookHash(String value, {int length = 32}) {
  final digest = sha256.convert(utf8.encode(value)).toString();
  final end = length.clamp(8, digest.length).toInt();
  return digest.substring(0, end);
}

String normalizeAutoBookText(String value) {
  return value
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[，。、“”‘’：；！？（）【】［］]'), '')
      .trim()
      .toLowerCase();
}
