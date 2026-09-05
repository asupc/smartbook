import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../data/db.dart';
import '../../services/system/logger_service.dart';
import 'auto_book_event.dart';
import 'auto_book_event_store.dart';

/// 已经取得处理租约的事件上下文。业务层可以在创建交易后先写入
/// transactionId，再执行其它易失败的副作用，缩小“交易已落库但事件未关联”的
/// 崩溃窗口。
class AutoBookEventContext {
  const AutoBookEventContext({required this.store, required this.event});

  final AutoBookEventStore store;
  final dynamic event;

  int get eventId => event.id as int;
  int? get existingTransactionId => event.transactionId as int?;
}

/// 所有自动入口共享的协调器。
///
/// 第一阶段先解决两个高风险问题：
/// 1. 不同来源并发处理同一事件时没有全局串行链；
/// 2. 进程重启/广播重放后无法恢复事件状态。
///
/// 业务提取仍由 [AutoBillingService] / [AiBookkeeper] 完成；协调器只负责
/// 幂等 claim、状态持久化、可重试和统一 key。这样不会把自动策略耦合进
/// BillCreationService，也不会改变手动记账语义。
class AutoBookCoordinator {
  static const _tag = 'AutoBookCoordinator';

  final AutoBookEventStore store;
  Future<void> _tail = Future<void>.value();
  Future<void>? _ready;
  bool _disposed = false;

  AutoBookCoordinator(BeeDatabase db) : store = AutoBookEventStore(db);

  Future<void> initialize() {
    return _ready ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      await store.cleanupExpired();
    } catch (e, st) {
      // 事件表是增强能力，不能阻断数据库/主界面启动；后续 claim 仍会
      // 抛出真实数据库错误并进入 retry。
      logger.warning(_tag, '清理过期自动记账事件失败(继续运行)', '$e');
      logger.debug(_tag, '清理过期事件堆栈', st);
    }
  }

  /// 全局串行执行一个入口事件。
  ///
  /// [updateFor] 将业务层返回值映射为持久化状态。业务异常不会被吞掉，
  /// 事件会先标记 retry，再把异常交给原调用方处理。
  Future<AutoBookExecution<T>> execute<T>({
    required AutoBookInput input,
    required Future<T> Function() action,
    required AutoBookEventUpdate Function(T value) updateFor,
  }) {
    return executeWithContext<T>(
      input: input,
      action: (_) => action(),
      updateFor: updateFor,
    );
  }

  /// 带事件上下文的执行变体，供需要“先关联交易 ID、再完成副作用”的
  /// 多步骤流程（周期交易/批量导入）使用。
  Future<AutoBookExecution<T>> executeWithContext<T>({
    required AutoBookInput input,
    required Future<T> Function(AutoBookEventContext context) action,
    required AutoBookEventUpdate Function(T value) updateFor,
  }) {
    final future = _tail.then((_) async {
      if (_disposed) {
        throw StateError('AutoBookCoordinator 已释放');
      }
      await initialize();
      return _runWithContext(
        input: input,
        action: action,
        updateFor: updateFor,
      );
    }).then((value) => value);

    // 维护一个不带结果的 tail，保证前一个任务成功/失败都不会阻断后续
    // 事件；真正的 future 仍把异常返回给当前调用者。
    _tail = future.then<void>((_) {}, onError: (_) {});
    return future;
  }

  Future<AutoBookExecution<T>> _runWithContext<T>({
    required AutoBookInput input,
    required Future<T> Function(AutoBookEventContext context) action,
    required AutoBookEventUpdate Function(T value) updateFor,
  }) async {
    final claim = await store.claim(input);
    if (!claim.acquired) {
      final state = AutoBookStateValue.parse(claim.event.state);
      logger.debug(_tag, '事件已处理/正在处理，跳过',
          '${input.sourceValue}:${input.eventKey} state=${claim.event.state}');
      return AutoBookExecution<T>(
        skipped: true,
        value: null,
        state: state,
        eventId: claim.event.id,
        existingTransactionId:
            claim.event.transactionId ?? claim.event.duplicateOfTransactionId,
      );
    }

    final context = AutoBookEventContext(store: store, event: claim.event);
    try {
      final value = await action(context);
      final update = updateFor(value);
      await store.mark(update, eventId: claim.event.id);
      return AutoBookExecution<T>(
        skipped: false,
        value: value,
        state: update.state,
        eventId: claim.event.id,
        existingTransactionId:
            update.transactionId ?? update.duplicateOfTransactionId,
      );
    } catch (e, st) {
      final current = await store.findById(claim.event.id);
      try {
        await store.markRetry(
          eventId: claim.event.id,
          attemptCount: current?.attemptCount ?? claim.event.attemptCount,
          error: e.toString(),
        );
      } catch (markError, markStack) {
        logger.error(_tag, '记录自动记账 retry 状态失败', markError, markStack);
      }
      logger.error(_tag, '自动记账事件执行失败', e, st);
      rethrow;
    }
  }

  /// 事件级截图/分享 key。优先使用内容 hash，文件尚未就绪时退回路径+元数据。
  Future<String> imageEventKey(String path) async {
    final file = File(path);
    try {
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final digest = sha256.convert(bytes).toString();
        return 'image:v1:$digest';
      }
    } catch (e) {
      logger.debug(_tag, '计算图片内容 hash 失败，使用路径兜底', '$e');
    }
    try {
      final stat = await file.stat();
      return 'image:path:v1:${autoBookHash('$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}')}';
    } catch (_) {
      return 'image:path:v1:${autoBookHash(path)}';
    }
  }

  static String textEventKey(String source, String value) {
    return '$source:v1:${autoBookHash(normalizeAutoBookText(value))}';
  }

  static String deepLinkEventKey(String? idempotencyKey, String canonicalUrl) {
    final key = idempotencyKey?.trim();
    if (key != null && key.isNotEmpty) {
      return 'deeplink:key:v1:${autoBookHash(key)}';
    }
    return 'deeplink:url:v1:${autoBookHash(canonicalUrl)}';
  }

  void dispose() {
    _disposed = true;
  }
}
