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

/// 屏幕文本监听服务(账单详情页自动记账,Android 专用)。
///
/// 原生 [ScreenTextWatcher](AccessibilityService) 在系统「无障碍」授权后
/// 永续监听白名单 App(支付宝/抖音/京东/微信)前台页面,检测到金额+交易特征
/// 后经过滤/去重入队;本服务负责:
/// - 进程存活时经桥接广播即时处理(onScreenTextCaptured);
/// - 启动时 [drainPending] 补处理积压队列(peek + 逐项 ack,同短信队列语义)。
///
/// 启用前置条件:用户在系统「无障碍」中授权,
/// [isAccessibilityGranted] 可查,`enable()` 未授权时抛 StateError 由 UI 引导。
class ScreenTextMonitorService {
  static const _channel = MethodChannel('com.smartbook.zhi/screen_text');
  static const _enabledKey = 'screen_text_monitor_enabled';

  final ProviderContainer _container;
  late final AutoBillingService _autoBillingService;
  late final AutoBookCoordinator _coordinator;

  bool _isEnabled = false;
  bool _bridgeRegistered = false;

  // 本会话已就"AI 未配置"提醒过的指纹:避免每次启动都重复打扰
  final Set<String> _noAiNotified = {};

  Future<void> _processingChain = Future.value();

  static ScreenTextMonitorService? _instance;

  factory ScreenTextMonitorService(ProviderContainer container) {
    _instance ??= ScreenTextMonitorService._internal(container);
    return _instance!;
  }

  ScreenTextMonitorService._internal(this._container) {
    _autoBillingService = _container.read(autoBillingServiceProvider);
    _coordinator = _container.read(autoBookCoordinatorProvider);
    _setupMethodCallHandler();
  }

  void _setupMethodCallHandler() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onScreenTextCaptured') {
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

  /// 系统「无障碍」服务是否已授权(监听生效的硬前提)
  Future<bool> isAccessibilityGranted() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('isAccessibilityGranted') ?? false;
  }

  /// 是否 vivo/iQOO 设备(「无障碍一开就关」高发,引导 UI 据此展示自救提示)
  Future<bool> isVivoDevice() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isVivoDevice') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开系统「无障碍」设置页
  Future<void> openAccessibilitySettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('openAccessibilitySettings');
  }

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool(_enabledKey) ?? false;
    return _isEnabled;
  }

  /// 启用屏幕文本监听。未授权「无障碍」时抛 StateError(UI 层应引导授权)。
  ///
  /// M2-2:只 await 到桥接注册,积压队列交给 [scheduleDrain] 后台跑。
  Future<void> enable() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('仅支持 Android 平台');
    }
    if (!await isAccessibilityGranted()) {
      throw StateError('accessibility_grant_not_granted');
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

  /// 补处理积压屏幕文本(启动时 / 桥接触发 / 启用时),语义同通知 drain。
  Future<void> drainPending() async {
    if (!_isEnabled) return;
    // M1-1:AI 运行时未就绪时保留整条队列,不消耗事件的退避窗口。
    final runtime = AiRuntimeCoordinator.instance;
    if (!await runtime.awaitReady()) {
      logger.info('ScreenTextMonitor',
          'AI 运行时未就绪(${runtime.state.name}),保留详情页队列待下次 drain');
      await _logDecision('drain_deferred', 'AI 运行时未就绪(${runtime.state.name})');
      return;
    }
    try {
      final items =
          await _channel.invokeMethod<List<dynamic>>('peekPending') ?? const [];
      for (final raw in items) {
        if (!_isEnabled) break;
        if (raw is! Map) continue;
        final pkg = (raw['package'] ?? '').toString();
        final text = (raw['text'] ?? '').toString();
        final fingerprint = (raw['fingerprint'] ?? '').toString();
        final nativeEventKey = (raw['eventKey'] ?? '').toString().trim();
        final timestamp = int.tryParse((raw['timestamp'] ?? '').toString());
        final eventKey = nativeEventKey.isNotEmpty
            ? 'screen:v3:$nativeEventKey'
            : 'screen:v2:$fingerprint:${timestamp ?? 0}';

        final alreadyWarned = _noAiNotified.contains(eventKey);
        final execution = await _coordinator.execute(
          input: AutoBookInput(
            eventKey: eventKey,
            source: AutoBookSource.screenText,
            captureIntent: AutoBookCaptureIntent.automatic,
            capturedAt: DateTime.now(),
            sourceOccurredAt: timestamp == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(timestamp),
            contentHash: fingerprint,
            sourceChannel: SourceChannelResolver.channelForPackage(pkg),
            rawText: text,
            rawActor: pkg,
            rawMetadata: {
              'fingerprint': fingerprint,
              if (nativeEventKey.isNotEmpty) 'nativeEventKey': nativeEventKey,
              if (timestamp != null) 'timestamp': timestamp,
            },
          ),
          action: () => _autoBillingService.processScreenText(
            pkg,
            text,
            // 成功入账始终通知;「AI 未配置」引导按指纹只提示一次
            showNotification: true,
            notifyAiUnconfigured: !alreadyWarned,
            // 内容指纹去重(持久化,跨会话):Coordinator 按 eventKey 幂等,而
            // eventKey 含捕获时间戳每次进入都变,兜不住同内容重复入账。这里
            // 不再跳过 screenTextFingerprint 去重,与原生端指纹拦队形成双保险。
            skipDedup: false,
            eventKey: eventKey,
          ),
          // M1-3:与短信/通知共用一份走向映射。
          updateFor: (outcome) => outcome.eventUpdate,
        );

        if (execution.skipped) {
          await _logDecision(
            'drain_skipped',
            'pkg=$pkg state=${execution.state.value}',
            pkg: pkg,
          );
          if (execution.terminal) await _ack(fingerprint, eventKey);
          continue;
        }

        final outcome = execution.value;
        if (outcome == null) continue;
        await _logDecision('drain_${outcome.name}', 'pkg=$pkg', pkg: pkg);
        if (outcome == SmsProcessOutcome.noAiConfigured) {
          _noAiNotified.add(eventKey);
        }
        if (outcome.canAckNativeQueue) {
          await _ack(fingerprint, eventKey);
        }
      }
    } catch (_) {
      // 队列读取/通道异常不抛;未 ack 的项下次 drain 通过指纹预检补 ack
    }
  }

  /// 模拟屏幕文本(调试/验证入口):直接注入详情页文本走完整 AI 提取 →
  /// 落库流程,用于没有真实页面时验证「自动记账是否正常」。skipDedup 保证
  /// 同一模板可反复发送。
  Future<void> mockScreenText(String pkg, String text) {
    return _enqueue(() async {
      await _autoBillingService.processScreenText(
        pkg,
        text,
        skipDedup: true,
      );
    });
  }

  /// 最近识别决策(原生环形队列,「自动识别记录」页排查真机漏记用)。
  /// 不含页面文本 —— 只有决策码/命中关键词/长度计数。
  Future<List<Map<String, String>>> recentDecisions() async {
    if (!Platform.isAndroid) return const [];
    try {
      final res =
          await _channel.invokeMethod<List<dynamic>>('getDecisions') ?? const [];
      return [
        for (final e in res)
          if (e is Map) e.map((k, v) => MapEntry('$k', '$v')),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 获取已安装 App 的应用图标(PNG 字节数组),仅 Android 平台支持。
  Future<Uint8List?> getAppIcon(String pkg) async {
    if (!Platform.isAndroid || pkg.isEmpty || pkg == 'app') return null;
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('getAppIcon', {'pkg': pkg});
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 追加一条 Dart 段(drain/AI)决策记录,与原生判定拼成完整链路。失败静默。
  Future<void> _logDecision(String decision, String detail, {String? pkg}) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('appendDecision', {
        'pkg': pkg ?? 'app',
        'decision': decision,
        'detail': detail,
      });
    } catch (_) {}
  }

  Future<void> _ack(String fingerprint, String? eventKey) async {
    if (fingerprint.isEmpty && (eventKey == null || eventKey.isEmpty)) return;
    try {
      await _channel.invokeMethod('ackPending', {
        'fingerprints': fingerprint.isEmpty ? const <String>[] : [fingerprint],
        'eventKeys': eventKey == null || eventKey.isEmpty
            ? const <String>[]
            : [eventKey.replaceFirst('screen:v3:', '')],
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
