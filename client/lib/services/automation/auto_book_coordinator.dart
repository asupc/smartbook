import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import '../../ai/providers/ai_provider_config.dart';
import '../../ai/providers/ai_provider_manager.dart';
import '../../data/db.dart';
import '../../services/system/logger_service.dart';
import 'auto_book_event.dart';
import 'auto_book_event_store.dart';
import 'auto_book_trace.dart';

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
/// 执行模型(2026-09 并发化):**有界并发 + 同 eventKey 串行**。
/// - 不同事件(短信/通知/页面文本/截图…)最多并发 [_maxConcurrency] 个(默认 3,
///   实际取 text 绑定服务商的「并发数」)同时执行 —— LLM 提取是大头耗时,
///   并行后一批积压事件的墙钟时间约为原来的 1/K;
/// - 同一 eventKey 仍在各自的串行尾链上排队,幂等 claim / 租约语义与
///   「同一事件绝不双执行」不变;进程重启/广播重放由 eventKey UNIQUE 兜底。
///
/// 落库判重(24h 基线、账单指纹、疑似重复)是 check-then-add,直接并行会在
/// 「同一笔支付的短信+通知同时到达」时双记账 —— 该段由 [AiBookkeeper]
/// `_persistAll` 的静态串行链兜住,协调器不再全局串行。
///
/// 业务提取仍由 [AutoBillingService] / [AiBookkeeper] 完成；协调器只负责
/// 幂等 claim、状态持久化、可重试和统一 key。这样不会把自动策略耦合进
/// BillCreationService，也不会改变手动记账语义。
class AutoBookCoordinator {
  static const _tag = 'AutoBookCoordinator';

  /// AI 配置尚未拉到 / 未配置时的默认并发数(与服务端 visionConcurrency
  /// 缺省一致)。
  static const int defaultMaxConcurrency = 3;

  final AutoBookEventStore store;
  bool _disposed = false;

  // ── 有界并发池(等待者队列信号量;占位直接移交,不经过计数抖动) ──
  int _inFlight = 0;
  int _maxConcurrency = defaultMaxConcurrency;
  bool _concurrencyInitialized = false;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  // ── 同 eventKey 串行守卫 ──
  /// eventKey → 该 key 的任务尾链。同 key 请求严格串行;跨 key 并行。
  final Map<String, Future<void>> _keyTails = {};

  AutoBookCoordinator(BeeDatabase db) : store = AutoBookEventStore(db);

  Future<void>? _ready;

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
    // 并发上限按 AI 配置(text 绑定服务商的「并发数」)设定一次;未配置 /
    // 读失败保持 [defaultMaxConcurrency]。配置变化以「下一次进程启动」为
    // 生效边界 —— 并发上限只影响吞吐,不值得为它做配置监听;外部显式
    // setMaxConcurrency(测试)也不被这里覆盖。
    if (_concurrencyInitialized) return;
    _concurrencyInitialized = true;
    try {
      final provider = await AIProviderManager.getProviderForCapability(
        AICapabilityType.text,
      );
      final limit = provider?.visionConcurrency ?? defaultMaxConcurrency;
      setMaxConcurrency(limit.clamp(1, 32));
      logger.info(_tag, '自动记账并发上限已按 AI 配置设定', 'limit=$limit');
    } catch (e) {
      logger.debug(_tag, '读取 AI 并发配置失败(用默认值)', '$e');
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
    final completer = Completer<AutoBookExecution<T>>();

    // 同 eventKey 串行:真正执行挂到该 key 的尾链上,避免同一事件被两个
    // 调用方(如 drain 与手动重试)同时 claim。跨 key 任务在这里只入各自的
    // key 链,并发池占位在链内进行,不同 key 互不阻塞。
    final key = input.eventKey;
    final chained = _keyTails[key] ?? Future<void>.value();
    final myTurn = chained.then((_) {
      return _awaitSlotAndRun(
        input: input,
        action: action,
        updateFor: updateFor,
        completer: completer,
      );
    });
    // 尾链吞掉异常,失败不阻断同 key 后续任务;链尾离开后清理 map 条目。
    final swallow = myTurn.then<void>((_) {}, onError: (_) {});
    _keyTails[key] = swallow;
    swallow.whenComplete(() {
      if (identical(_keyTails[key], swallow)) _keyTails.remove(key);
    });

    return completer.future;
  }

  /// 等并发池有空位后执行;结果交给 [completer],池占位在 finally 归还。
  Future<void> _awaitSlotAndRun<T>({
    required AutoBookInput input,
    required Future<T> Function(AutoBookEventContext context) action,
    required AutoBookEventUpdate Function(T value) updateFor,
    required Completer<AutoBookExecution<T>> completer,
  }) async {
    await _acquireSlot();
    try {
      if (_disposed) {
        throw StateError('AutoBookCoordinator 已释放');
      }
      await initialize();
      final result = await _runWithContext(
        input: input,
        action: action,
        updateFor: updateFor,
      );
      completer.complete(result);
    } catch (e, st) {
      completer.completeError(e, st);
    } finally {
      _releaseSlot();
    }
  }

  /// 占一个并发位;池满时排队,任务完成时按 FIFO 唤醒(占位直接移交)。
  Future<void> _acquireSlot() {
    if (_inFlight < _maxConcurrency) {
      _inFlight++;
      return Future<void>.value();
    }
    final ticket = Completer<void>();
    _waiters.add(ticket);
    return ticket.future;
  }

  void _releaseSlot() {
    if (_waiters.isNotEmpty) {
      // 占位直接移交给队首等待者,计数不变(所有权转移)。
      _waiters.removeFirst().complete();
    } else {
      _inFlight--;
    }
  }

  /// 并发上限变更入口(测试/配置刷新用)。显式调用优先于 AI 配置 bootstrap:
  /// 生产路径没人调它,首个事件的 initialize 会按 AI 配置设一次;一旦外部
  /// 设过,后续 initialize 不再覆盖。
  void setMaxConcurrency(int limit) {
    if (limit < 1) return;
    _concurrencyInitialized = true;
    if (limit > _maxConcurrency) {
      _maxConcurrency = limit;
      // 放宽后把新增空位移交给等待者。
      while (_inFlight < _maxConcurrency && _waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
        _inFlight++;
      }
    } else {
      _maxConcurrency = limit;
    }
  }

  /// 当前生效的并发上限(测试/诊断用)。
  int get currentMaxConcurrency => _maxConcurrency;

  Future<AutoBookExecution<T>> _runWithContext<T>({
    required AutoBookInput input,
    required Future<T> Function(AutoBookEventContext context) action,
    required AutoBookEventUpdate Function(T value) updateFor,
  }) async {
    // M0-1:trace 覆盖整条链(claim → 业务 → 终态)。挂在 Zone 上，下层
    // (中转客户端/记账应用层)不改签名就能打点；主动路径没有 trace。
    final trace = AutoBookTrace.forInput(input);
    final claim = await store.claim(input);
    if (!claim.acquired) {
      final state = AutoBookStateValue.parse(claim.event.state);
      trace.stage('claim', outcome: 'skipped_${state.value}');
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
    trace.attemptCount = claim.event.attemptCount;
    trace.stage('claim', outcome: 'acquired');
    try {
      final value = await trace.run(() => action(context));
      final update = updateFor(value);
      if (update.state == AutoBookState.retry && update.nextRetryAt == null) {
        // M1-3:业务层返回的 retryable 结果统一走 markRetry —— mark() 会把
        // nextRetryAt 原样写成 null,退避闸门失效后桥接广播/启动 drain 会
        // 立刻重跑同一事件,形成忙循环。attemptCount 由 claim 递增,这里按
        // 它算 30s→2m→8m→30m→2h 阶梯。
        await store.markRetry(
          eventId: claim.event.id,
          attemptCount: claim.event.attemptCount,
          error: update.reason ?? 'retryable_outcome',
        );
      } else {
        await store.mark(update, eventId: claim.event.id);
      }
      trace.stage('event_terminal', outcome: update.state.value);
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
      trace.stage('event_terminal', outcome: 'exception');
      logger.error(_tag, '自动记账事件执行失败', e, st);
      rethrow;
    }
  }

  /// 事件级截图/分享 key。优先使用内容 hash，文件尚未就绪时退回路径+元数据。
  /// C14:文件读取 + sha256 丢 Isolate.run(1-4MB 截图此前在串行队列的
  /// 主 isolate 上算,阻塞 UI 与后续事件)。
  Future<String> imageEventKey(String path) async {
    final file = File(path);
    try {
      if (await file.exists()) {
        final digest = await Isolate.run(() {
          final bytes = File(path).readAsBytesSync();
          return sha256.convert(bytes).toString();
        });
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
