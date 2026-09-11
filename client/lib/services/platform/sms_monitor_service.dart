import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../automation/auto_billing_service.dart'
    show AutoBillingService, SmsProcessOutcome, SmsProcessOutcomeEvent;
import '../automation/auto_book_coordinator.dart';
import '../automation/auto_book_event.dart';
import '../data/source_channel_resolver.dart';
import '../../ai/core/ai_runtime_state.dart';
import '../../providers/automation_providers.dart';
import '../system/logger_service.dart' show logger;

/// 短信监听服务(Android 专用,自动记账 M1)。
///
/// 与 [ScreenshotMonitorService] 的分工不同:
/// - native(SmsReceiver)在 App 进程死亡时也能收到短信,完成白名单过滤/
///   垃圾剔除/指纹去重后**持久化入队**;
/// - 本服务负责:进程存活时经桥接广播即时处理(onSmsCaptured)、应用启动时
///   [drainPendingSms] 补处理积压队列。
///
/// 队列语义为 **peek + 逐项 ack**:只有该项处理完成(成功/判定非交易/失败)
/// 才从队列删除;AI 未配置时保留,下次启动补记;进程被杀只会丢"正在处理中
/// 的那一条"。
class SmsMonitorService {
  static const _channel = MethodChannel('com.smartbook.zhi/sms');
  static const _enabledKey = 'sms_monitor_enabled';

  final ProviderContainer _container;
  late final AutoBillingService _autoBillingService;
  late final AutoBookCoordinator _coordinator;

  bool _isEnabled = false;
  bool _bridgeRegistered = false;

  // 本会话已就"AI 未配置"提醒过的指纹:避免每次启动都重复打扰
  final Set<String> _noAiNotified = {};

  // 串行处理链:桥接消息与启动 drain 可能同时到位,AI/key 操作需排队
  Future<void> _processingChain = Future.value();

  // 单例模式(与 ScreenshotMonitorService 一致)
  static SmsMonitorService? _instance;

  factory SmsMonitorService(ProviderContainer container) {
    _instance ??= SmsMonitorService._internal(container);
    return _instance!;
  }

  SmsMonitorService._internal(this._container) {
    _autoBillingService = _container.read(autoBillingServiceProvider);
    _coordinator = _container.read(autoBookCoordinatorProvider);
    _setupMethodCallHandler();
  }

  /// 设置方法调用处理器(native 桥接广播 → "onSmsCaptured")
  void _setupMethodCallHandler() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSmsCaptured') {
        _enqueue(() async {
          if (!_isEnabled) return;
          await drainPendingSms();
        });
      }
    });
  }

  /// 串行执行:前一个任务完成(无论成败)后执行下一个。
  /// 返回整条链,便于调用方 await。
  Future<void> _enqueue(Future<void> Function() task) {
    _processingChain = _processingChain.catchError((_) {}).then((_) => task());
    return _processingChain;
  }

  /// 检查是否已启用
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool(_enabledKey) ?? false;
    return _isEnabled;
  }

  /// 启用短信监听。
  ///
  /// 权限:调用方(设置页)负责先 [Permission.sms] 请求;此处只开关职责。
  /// M2-2:只 **await 到桥接注册**,积压队列交给 [scheduleDrain] 后台跑 ——
  /// 冷启动恢复不能被整条队列的 AI 识别拖住(每条都要等中转往返)。
  Future<void> enable() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('仅支持 Android 平台');
    }
    await _channel.invokeMethod('setEnabled', {'enabled': true});
    await _registerBridge();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, true);
    _isEnabled = true;
    scheduleDrain();
  }

  /// 调度一次积压处理,**不阻塞调用方**(M2-2)。仍然进串行链,所以不会与
  /// 桥接广播触发的 drain 并发。返回值只给测试 await。
  Future<void> scheduleDrain() {
    final done = _enqueue(drainPendingSms);
    unawaited(done);
    return done;
  }

  /// 禁用短信监听。native 侧标志置假后,SmsReceiver 直接丢弃新短信,
  /// 不再入队;积压队列保留(重新启用时补记)。
  Future<void> disable() async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('setEnabled', {'enabled': false});
      } catch (_) {
        // 已在其它平台/进程被清,忽略
      }
      await _unregisterBridge();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, false);
    _isEnabled = false;
  }

  /// 补处理积压短信(启动时 / 桥接触发 / 启用时)。
  ///
  /// peek 当前队列 → 逐项处理 → 按 [SmsProcessOutcomeEvent.canAckNativeQueue]
  /// 决定是否出队。
  Future<void> drainPendingSms() async {
    if (!_isEnabled) return;
    // M1-1:AI 运行时未就绪(Relay 尚未注入 / 离线 / 需要重新登录)时整条队列
    // 原样保留。在这里硬跑只会拿到 relay_not_ready,白白吃掉事件的
    // attemptCount 和退避窗口;更早的版本还会把它当成「不是账单」ACK 掉原始
    // 短信,证据永久丢失。
    final runtime = AiRuntimeCoordinator.instance;
    if (!await runtime.awaitReady()) {
      logger.info(
          'SmsMonitor', 'AI 运行时未就绪(${runtime.state.name}),保留短信队列待下次 drain');
      return;
    }
    try {
      final items =
          await _channel.invokeMethod<List<dynamic>>('peekPendingSms') ??
              const [];
      if (!_isEnabled) return; // 用户中途关闭:整条队列留在 native
      // 并行分发:逐条交给 Coordinator(有界并发,同 eventKey 串行),每条完成
      // 即 ACK,不再逐条 await —— 一批积压短信的识别墙钟时间 ≈ 1/并发数。
      final futures = <Future<void>>[];
      for (final raw in items) {
        if (raw is! Map) continue;
        final sender = (raw['sender'] ?? '').toString();
        final body = (raw['body'] ?? '').toString();
        final fingerprint = (raw['fingerprint'] ?? '').toString();
        final nativeEventKey = (raw['eventKey'] ?? '').toString().trim();
        final timestamp = int.tryParse((raw['timestamp'] ?? '').toString());
        final eventKey = nativeEventKey.isNotEmpty
            ? 'sms:v3:$nativeEventKey'
            : 'sms:v2:$fingerprint:${timestamp ?? 0}';
        if (body.isEmpty) {
          futures.add(_ack(fingerprint, eventKey));
          continue;
        }
        futures.add(_processOne(
          sender: sender,
          body: body,
          fingerprint: fingerprint,
          eventKey: eventKey,
          timestamp: timestamp,
        ));
      }
      await Future.wait(futures);
    } catch (e) {
      // 队列读取/通道异常不抛:不影响主流程。
      // 已处理项未 ack 会在下次 drain 通过指纹预检补 ack。
    }
  }

  /// 单条短信的识别 + ACK(与 drain 并行分发配套;异常自吞,原样保留队列)。
  Future<void> _processOne({
    required String sender,
    required String body,
    required String fingerprint,
    required String eventKey,
    int? timestamp,
  }) async {
    // AI 未配置的提示每事件只弹一次(会话内)
    final alreadyWarned = _noAiNotified.contains(eventKey);
    final execution = await _coordinator.execute(
      input: AutoBookInput(
        // v2 把 native 时间带入 key，避免同一模板在不同日期被误当成
        // 同一条短信；同一条广播重放仍保持相同 key。
        eventKey: eventKey,
        source: AutoBookSource.sms,
        captureIntent: AutoBookCaptureIntent.automatic,
        capturedAt: DateTime.now(),
        sourceOccurredAt: timestamp == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(timestamp),
        contentHash: fingerprint,
        sourceChannel: SourceChannelResolver.channelForSmsSender(sender),
        rawText: body,
        rawActor: sender,
        rawMetadata: {
          'fingerprint': fingerprint,
          if (eventKey.startsWith('sms:v3:'))
            'nativeEventKey': eventKey.substring('sms:v3:'.length),
          if (timestamp != null) 'timestamp': timestamp,
        },
      ),
      action: () => _autoBillingService.processSms(
        sender,
        body,
        showNotification: !alreadyWarned,
        // Coordinator 已接管事件级幂等；避免旧的内存 cache 把 retry
        // 误判成已处理。
        skipDedup: true,
        eventKey: eventKey,
      ),
      // M1-3:走向 → 事件状态的映射收敛到 SmsProcessOutcomeEvent,四路
      // 监听共用一份,新增走向不会漏分支。
      updateFor: (outcome) => outcome.eventUpdate,
    );

    if (execution.skipped) {
      // terminal 事件只需补 ACK；retry/processing 尚未到终态时保留队列。
      if (execution.terminal) await _ack(fingerprint, eventKey);
      return;
    }

    final outcome = execution.value;
    if (outcome == null) return;
    if (outcome == SmsProcessOutcome.noAiConfigured) {
      _noAiNotified.add(eventKey);
    }
    // 只有终态才出队:可重试失败与「AI 未配置」必须留着原始短信。
    if (outcome.canAckNativeQueue) {
      await _ack(fingerprint, eventKey);
    }
  }

  Future<void> _ack(String fingerprint, String? eventKey) async {
    if (fingerprint.isEmpty && (eventKey == null || eventKey.isEmpty)) return;
    try {
      await _channel.invokeMethod('ackPendingSms', {
        'fingerprints': fingerprint.isEmpty ? const <String>[] : [fingerprint],
        'eventKeys': eventKey == null || eventKey.isEmpty
            ? const <String>[]
            : [eventKey.replaceFirst('sms:v3:', '')],
      });
    } catch (_) {}
  }

  Future<void> _registerBridge() async {
    if (_bridgeRegistered || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('registerBridge');
      _bridgeRegistered = true;
    } catch (_) {
      // 桥接失败不影响队列能力(启动时仍会 drain)
    }
  }

  Future<void> _unregisterBridge() async {
    if (!_bridgeRegistered || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('unregisterBridge');
      _bridgeRegistered = false;
    } catch (_) {}
  }

  /// 模拟短信(调试/验证入口):不经过 native 接收链路,直接注入一条短信
  /// 走完整 AI 提取 → 落库流程,用于没有真实短信时验证「自动记账是否正常」。
  /// skipDedup 传入 processSms(真实路径不变),同一模板可反复发送。
  Future<void> mockSms(String body) {
    return _enqueue(() async {
      if (!_isEnabled) {
        logger.warning('SmsMonitor', '短信自动记账未开启,模拟数据仍处理(仅验证链路)');
      }
      await _autoBillingService.processSms('TEST', body, skipDedup: true);
    });
  }

  /// 释放资源
  void dispose() {
    _autoBillingService.dispose();
  }
}
