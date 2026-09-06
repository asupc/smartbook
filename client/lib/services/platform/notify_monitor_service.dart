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

/// 支付通知监听服务(Android 专用)。
///
/// 原生 [NotificationWatcher](NotificationListenerService) 在系统「通知使用权」
/// 授权后永续监听支付类通知(包名白名单+过滤+去重+入队);本服务负责:
/// - 进程存活时经桥接广播即时处理(onNotifyCaptured);
/// - 启动时 [drainPending] 补处理积压队列(peek + 逐项 ack,同短信队列语义)。
///
/// 启用前置条件:用户在系统「通知使用权」中授权,
/// [isListenerGranted] 可查,`enable()` 未授权时抛 StateError 由 UI 引导。
class NotifyMonitorService {
  static const _channel = MethodChannel('com.smartbook.zhi/notify');
  static const _enabledKey = 'notify_monitor_enabled';

  final ProviderContainer _container;
  late final AutoBillingService _autoBillingService;
  late final AutoBookCoordinator _coordinator;

  bool _isEnabled = false;
  bool _bridgeRegistered = false;

  // 本会话已就"AI 未配置"提醒过的指纹:避免每次启动都重复打扰
  final Set<String> _noAiNotified = {};

  Future<void> _processingChain = Future.value();

  static NotifyMonitorService? _instance;

  factory NotifyMonitorService(ProviderContainer container) {
    _instance ??= NotifyMonitorService._internal(container);
    return _instance!;
  }

  NotifyMonitorService._internal(this._container) {
    _autoBillingService = _container.read(autoBillingServiceProvider);
    _coordinator = _container.read(autoBookCoordinatorProvider);
    _setupMethodCallHandler();
  }

  void _setupMethodCallHandler() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNotifyCaptured') {
        _enqueue(() async {
          if (!_isEnabled) return;
          await drainPending();
        });
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() task) {
    _processingChain = _processingChain.catchError((_) {}).then((_) => task());
    return _processingChain;
  }

  /// 系统「通知使用权」是否已授权(监听生效的硬前提)
  Future<bool> isListenerGranted() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('isListenerGranted') ?? false;
  }

  /// 打开系统「通知使用权」设置页
  Future<void> openListenerSettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('openListenerSettings');
  }

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool(_enabledKey) ?? false;
    return _isEnabled;
  }

  /// 启用通知监听。未授权「通知使用权」时抛 StateError(UI 层应引导授权)。
  ///
  /// M2-2:只 await 到桥接注册,积压队列交给 [scheduleDrain] 后台跑。
  Future<void> enable() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('仅支持 Android 平台');
    }
    if (!await isListenerGranted()) {
      throw StateError('notification_listener_not_granted');
    }
    await _channel.invokeMethod('setEnabled', {'enabled': true});
    await _registerBridge();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, true);
    _isEnabled = true;
    scheduleDrain();
  }

  /// 调度一次积压处理,不阻塞调用方(M2-2)。返回值只给测试 await。
  Future<void> scheduleDrain() {
    final done = _enqueue(drainPending);
    unawaited(done);
    return done;
  }

  Future<void> disable() async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('setEnabled', {'enabled': false});
      } catch (_) {}
      await _unregisterBridge();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, false);
    _isEnabled = false;
  }

  /// 补处理积压通知(启动时 / 桥接触发 / 启用时),语义同短信 drain。
  Future<void> drainPending() async {
    if (!_isEnabled) return;
    // M1-1:AI 运行时未就绪时保留整条队列,不消耗事件的退避窗口。
    final runtime = AiRuntimeCoordinator.instance;
    if (!await runtime.awaitReady()) {
      logger.info(
          'NotifyMonitor', 'AI 运行时未就绪(${runtime.state.name}),保留通知队列待下次 drain');
      return;
    }
    try {
      final items =
          await _channel.invokeMethod<List<dynamic>>('peekPending') ?? const [];
      for (final raw in items) {
        if (!_isEnabled) break;
        if (raw is! Map) continue;
        final pkg = (raw['package'] ?? '').toString();
        final title = (raw['title'] ?? '').toString();
        final body = (raw['body'] ?? '').toString();
        final fingerprint = (raw['fingerprint'] ?? '').toString();
        final notificationKey = (raw['notificationKey'] ?? '').toString();
        final notificationId =
            int.tryParse((raw['notificationId'] ?? '').toString());

        final alreadyWarned = _noAiNotified.contains(fingerprint);
        final timestamp = int.tryParse((raw['timestamp'] ?? '').toString());
        // native fingerprint 已包含 StatusBarNotification key/id/postTime；
        // 旧队列没有这些字段时仍能通过 content fingerprint 兼容。
        final eventKey = 'notification:v3:$fingerprint';
        final execution = await _coordinator.execute(
          input: AutoBookInput(
            eventKey: eventKey,
            source: AutoBookSource.notification,
            captureIntent: AutoBookCaptureIntent.automatic,
            capturedAt: DateTime.now(),
            sourceOccurredAt: timestamp == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(timestamp),
            contentHash: fingerprint,
            sourceChannel: SourceChannelResolver.channelForPackage(pkg),
            rawTitle: title,
            rawText: body,
            rawActor: pkg,
            rawMetadata: {
              'fingerprint': fingerprint,
              if (notificationKey.isNotEmpty)
                'notificationKey': notificationKey,
              if (notificationId != null) 'notificationId': notificationId,
              if (timestamp != null) 'timestamp': timestamp,
            },
          ),
          action: () => _autoBillingService.processNotification(
            pkg,
            title,
            body,
            showNotification: !alreadyWarned,
            // 事件幂等由 Coordinator 负责，避免旧内存 cache 影响 retry。
            skipDedup: true,
            eventKey: eventKey,
          ),
          // M1-3:与短信/详情页共用一份走向映射。
          updateFor: (outcome) => outcome.eventUpdate,
        );

        if (execution.skipped) {
          if (execution.terminal) await _ack(fingerprint);
          continue;
        }

        final outcome = execution.value;
        if (outcome == null) continue;
        if (outcome == SmsProcessOutcome.noAiConfigured) {
          _noAiNotified.add(fingerprint);
        }
        if (outcome.canAckNativeQueue) {
          await _ack(fingerprint);
        }
      }
    } catch (_) {
      // 队列读取/通道异常不抛;未 ack 的项下次 drain 通过指纹预检补 ack
    }
  }

  /// 模拟通知(调试/验证入口):直接注入通知文本走完整 AI 提取 → 落库流程,
  /// 用于没有真实支付通知时验证「自动记账是否正常」。skipDedup 保证同一
  /// 模板可反复发送。
  Future<void> mockNotification(String title, String body) {
    return _enqueue(() async {
      await _autoBillingService.processNotification(
        'com.tencent.mm',
        title,
        body,
        skipDedup: true,
      );
    });
  }

  Future<void> _ack(String fingerprint) async {
    if (fingerprint.isEmpty) return;
    try {
      await _channel.invokeMethod('ackPending', {
        'fingerprints': [fingerprint]
      });
    } catch (_) {}
  }

  Future<void> _registerBridge() async {
    if (_bridgeRegistered || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('registerBridge');
      _bridgeRegistered = true;
    } catch (_) {}
  }

  Future<void> _unregisterBridge() async {
    if (!_bridgeRegistered || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('unregisterBridge');
      _bridgeRegistered = false;
    } catch (_) {}
  }

  void dispose() {
    _autoBillingService.dispose();
  }
}
