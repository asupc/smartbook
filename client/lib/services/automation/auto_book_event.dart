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
