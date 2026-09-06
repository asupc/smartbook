/// M0-1 自动记账最小 Trace。
///
/// 一条自动事件从 claim 到终态的各阶段耗时,用同一个 `trace_id` 串起来:
/// 日志里 `grep trace_id=<id>` 就能还原时间线,不必再靠时间戳去猜哪几行属于
/// 同一条短信/通知。
///
/// **字段是白名单**:只允许计划 §M0-1 列出的那些键,并且**禁止**任何原文 ——
/// 短信正文、通知 title/body、无障碍页面文本、API Key、未脱敏商户都不进
/// trace,事件身份只用 [eventKeyHash]。
///
/// 下层(中转客户端、记账应用层)用 [current] 取当前 Zone 上的 trace 打点,
/// 因此无需把 trace 参数一路透传。不经 Coordinator 的主动路径(自由对话、
/// 语音、手动选图)取到 null,自然不产生 trace 行。
library;

import 'dart:async';

import '../system/logger_service.dart';
import 'auto_book_event.dart';

class AutoBookTrace {
  AutoBookTrace._({
    required this.traceId,
    required this.source,
    required this.eventKeyHash,
    this.sourceChannel,
    this.ledgerId,
    this.queueDepth,
  });

  /// 从入口事件建 trace。[eventKey] 各入口已是 hash 派生,这里再取一次短 hash,
  /// 保证即使将来有入口用原文拼 key 也不会把原文带进日志。
  factory AutoBookTrace.forInput(AutoBookInput input, {int? queueDepth}) {
    return AutoBookTrace._(
      traceId: _nextTraceId(),
      source: input.source.value,
      eventKeyHash: autoBookHash(input.eventKey, length: 12),
      sourceChannel: input.sourceChannel,
      ledgerId: input.ledgerId,
      queueDepth: queueDepth,
    );
  }

  static const _tag = 'AutoBookTrace';

  /// Zone key 用私有对象,外部无法伪造/覆盖。
  static final Object _zoneKey = Object();

  static int _seq = 0;

  static String _nextTraceId() {
    _seq = (_seq + 1) % 100000;
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return '$stamp-$_seq';
  }

  final String traceId;
  final String source;
  final String eventKeyHash;
  final String? sourceChannel;
  final int? ledgerId;
  final int? queueDepth;

  /// claim 之后由 Coordinator 回填(第几次尝试)。
  int attemptCount = 0;

  final Stopwatch _sinceStart = Stopwatch()..start();
  final Stopwatch _sinceStage = Stopwatch()..start();

  /// 当前 Zone 上的 trace;不在自动记账链上时为 null。
  static AutoBookTrace? get current => Zone.current[_zoneKey] as AutoBookTrace?;

  /// 在挂了本 trace 的 Zone 里跑 [body],期间 [current] 都指向本 trace。
  Future<T> run<T>(Future<T> Function() body) {
    return runZoned(body, zoneValues: {_zoneKey: this});
  }

  /// 记一个阶段。[durationMs] 缺省为「距上一个阶段」的耗时;自己掐表的阶段
  /// (如 provider_call 只想算 HTTP 那一段)可显式传入。
  void stage(
    String stage, {
    int? durationMs,
    String? outcome,
    int? payloadBytes,
    String? providerId,
    String? model,
  }) {
    final elapsed = durationMs ?? _sinceStage.elapsedMilliseconds;
    _sinceStage.reset();
    final fields = <String, Object?>{
      'trace_id': traceId,
      'stage': stage,
      'source': source,
      'source_channel': sourceChannel,
      'ledger_id': ledgerId,
      'event_key_hash': eventKeyHash,
      'queue_depth': queueDepth,
      'attempt_count': attemptCount == 0 ? null : attemptCount,
      'duration_ms': elapsed,
      'total_ms': _sinceStart.elapsedMilliseconds,
      'payload_bytes': payloadBytes,
      'provider_id': providerId,
      'model': model,
      'outcome': outcome,
    };
    final line = fields.entries
        .where((e) => e.value != null)
        .map((e) => '${e.key}=${e.value}')
        .join(' ');
    logger.debug(_tag, line);
  }
}
