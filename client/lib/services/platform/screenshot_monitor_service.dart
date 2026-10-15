import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../automation/auto_billing_service.dart';
import '../automation/auto_book_coordinator.dart';
import '../automation/auto_book_event.dart';

import '../automation/automation_settings_store.dart';
import '../../ai/core/ai_runtime_state.dart';
import '../../providers/automation_providers.dart';
import '../system/logger_service.dart' show logger;

/// Google Play 版本(CI 注入)。Photo & Video Permissions 政策禁止记账类 app
/// 长期持有 READ_MEDIA_IMAGES,所以 Google Play 版本砍掉截屏自动记账功能。
const _isGooglePlayBuild =
    bool.fromEnvironment('GOOGLE_PLAY', defaultValue: false);

/// 截图监听服务（Android专用）
/// 监听系统截图事件，并调用通用的AutoBillingService进行OCR识别和记账
class ScreenshotMonitorService {
  static const _channel = MethodChannel('com.smartbook.zhi/screenshot');
  static const _enabledKey = 'screenshot_monitor_enabled';

  final ProviderContainer _container;
  late final AutoBillingService _autoBillingService;
  late final AutoBookCoordinator _coordinator;

  bool _isEnabled = false;
  bool _isMonitoring = false;
  Future<void> _processingChain = Future<void>.value();

  // 单例模式
  static ScreenshotMonitorService? _instance;

  factory ScreenshotMonitorService(ProviderContainer container) {
    _instance ??= ScreenshotMonitorService._internal(container);
    return _instance!;
  }

  ScreenshotMonitorService._internal(this._container) {
    _autoBillingService = _container.read(autoBillingServiceProvider);
    _coordinator = _container.read(autoBookCoordinatorProvider);
    _setupMethodCallHandler();
  }

  /// 设置方法调用处理器
  void _setupMethodCallHandler() {
    print('📸 [ScreenshotMonitor] 初始化方法调用处理器');
    _channel.setMethodCallHandler((call) async {
      print('📸 [ScreenshotMonitor] 收到方法调用: ${call.method}');
      if (call.method == 'onScreenshotDetected') {
        final path = (call.arguments ?? '').toString();
        if (path.isEmpty) return;
        print('📸 [ScreenshotMonitor] 检测到截图，路径: $path');
        await _enqueue(() => _handleScreenshot(path));
      }
    });
  }

  /// 检查是否已启用
  Future<bool> isEnabled() async {
    if (_isGooglePlayBuild) return false;
    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool(_enabledKey) ?? false;
    return _isEnabled;
  }

  /// 启用截图监听
  Future<void> enable() async {
    try {
      print('📸 [ScreenshotMonitor] 开始启用截图监听...');

      if (_isGooglePlayBuild) {
        throw UnsupportedError(
            'Screenshot monitoring is not available in Google Play builds');
      }

      // 只在 Android 平台启用
      if (!Platform.isAndroid) {
        throw UnsupportedError('仅支持 Android 平台');
      }

      print('📸 [ScreenshotMonitor] 调用原生方法 startScreenshotObserver');
      await _channel.invokeMethod('startScreenshotObserver');

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, true);
      _isEnabled = true;
      _isMonitoring = true;

      print(
          '✅ [ScreenshotMonitor] 截图监听已启用，_isEnabled=$_isEnabled, _isMonitoring=$_isMonitoring');
      // M2-2:只 await 到 observer 注册,积压队列交给后台 drain,
      // 冷启动恢复不被整队列的图片识别拖住。
      scheduleDrain();
    } catch (e) {
      print('❌ [ScreenshotMonitor] 启用截图监听失败: $e');
      rethrow;
    }
  }

  /// 调度一次积压处理,不阻塞调用方(M2-2)。返回值只给测试 await。
  Future<void> scheduleDrain() {
    final done = _enqueue(_drainPendingScreenshots);
    unawaited(done);
    return done;
  }

  /// 禁用截图监听
  Future<void> disable() async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod('stopScreenshotObserver');
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, false);
      _isEnabled = false;
      _isMonitoring = false;

      print('✅ 截图监听已禁用');
    } catch (e) {
      print('❌ 禁用截图监听失败: $e');
      rethrow;
    }
  }

  Future<void> _enqueue(Future<void> Function() task) {
    _processingChain = _processingChain.catchError((_) {}).then((_) => task());
    return _processingChain;
  }

  /// 启动/桥接恢复 native 持久化截图队列。peek 不删除，只有事件进入终态
  /// 后 ACK；retry/captured 项保留，等待下次启动或用户修复配置后继续。
  Future<void> _drainPendingScreenshots() async {
    if (!_isEnabled || !_isMonitoring) return;
    // M1-1:AI 运行时未就绪时保留整条队列,不消耗事件的退避窗口。
    final runtime = AiRuntimeCoordinator.instance;
    if (!await runtime.awaitReady()) {
      logger.info('ScreenshotMonitor',
          'AI 运行时未就绪(${runtime.state.name}),保留截图队列待下次 drain');
      return;
    }
    try {
      final items = await _channel
              .invokeMethod<List<dynamic>>('peekPendingScreenshots') ??
          const [];
      if (!_isEnabled || !_isMonitoring) return;
      // 并行分发:逐张交给 Coordinator(有界并发,同一截图的 key 是内容
      // hash,天然串行),不再逐张 await。
            // B3:分批读取、有界处理 —— 每批最多 10 条,批内并发、批间串行,
      // 避免一次把整队(单来源上限 500 条)同时压进 Coordinator。
      const batchSize = 10;
      for (var start = 0; start < items.length; start += batchSize) {
        if (!_isEnabled) return; // 用户中途关闭:剩余项留队
        final futures = <Future<void>>[];
        for (final raw in items.skip(start).take(batchSize)) {
          if (raw is! Map) continue;
          final path = (raw['path'] ?? '').toString();
          if (path.isEmpty) continue;
          futures.add(_handleScreenshot(path, queueItem: raw));
        }
        await Future.wait(futures);
      }
    } catch (e, st) {
      // 队列桥接失败不影响监听；下次启动再 drain。
      print('⚠️ [ScreenshotMonitor] 恢复截图队列失败: $e');
    }
  }

  Future<void> _ackScreenshot(String path) async {
    if (path.isEmpty) return;
    try {
      await _channel.invokeMethod('ackPendingScreenshots', {
        'paths': [path],
      });
    } catch (_) {}
  }

  /// 处理截图
  Future<void> _handleScreenshot(String path, {Map? queueItem}) async {
    print('📸 [ScreenshotMonitor] _handleScreenshot 被调用，path=$path');
    print(
        '📸 [ScreenshotMonitor] 当前状态: _isEnabled=$_isEnabled, _isMonitoring=$_isMonitoring');

    if (!_isEnabled || !_isMonitoring) {
      print('⚠️ [ScreenshotMonitor] 截图监听未启用或未监控，跳过处理');
      return;
    }

    // 调用通用的AutoBillingService处理截图。
    // 静默模式:触发/识别中/非账单/失败不通知,只在成功入账时通知一次
    // (减少打扰;AI 未配置仍保留会话级一次性提示,便于发现配置缺失)。
    final eventKey = await _coordinator.imageEventKey(path);
    final capturedAt = DateTime.now();
    // B2:优先用捕获时冻结的目标快照(积压 drain 路径),否则按当前配置解析。
    final snapshot = AutoBookQueueTargetSnapshot.fromQueueItem(queueItem);
    final target = await resolveAutoBookTarget(
      _container,
      frozenRef: snapshot.ref,
      frozenState: snapshot.state,
      frozenConfigVersion: snapshot.version,
    );
    final input = AutoBookInput(
      eventKey: eventKey,
      source: AutoBookSource.screenshot,
      captureIntent: AutoBookCaptureIntent.automatic,
      capturedAt: capturedAt,
      contentHash: eventKey.startsWith('image:v1:')
          ? eventKey.substring('image:v1:'.length)
          : null,
      targetRef: target.targetRef,
      targetConfigVersion: target.configVersion,
      targetState: target.stateName,
    );
    if (!target.canWrite) {
      // B2:目标失效/待确定 —— 不调 AI、不 ACK,截图留到目标修好再处理。
      await _coordinator.execute<SmsProcessOutcome>(
        input: input,
        action: () async => target.state == AutoBookTargetState.invalid
            ? SmsProcessOutcome.targetInvalid
            : SmsProcessOutcome.targetUndetermined,
        updateFor: (o) => o.eventUpdate,
      );
      return;
    }
    final execution = await _coordinator.execute(
      input: input,
      action: () => _autoBillingService.processScreenshot(
        path,
        notifyOnlyOnSuccess: true,
        eventKey: eventKey,
        targetLedgerId: target.ledgerId,
      ),
      // M1-3:走向映射收敛到 BookkeepingResultEvent,与图片分享/deep-link 共用。
      updateFor: (result) => result.eventUpdate,
    );

    // 已完成事件(例如系统重复回调/图片分享副本)不再重复执行。
    if (execution.skipped) {
      if (execution.terminal) await _ackScreenshot(path);
      return;
    }
    if (execution.value == null) return;
    if (execution.terminal) await _ackScreenshot(path);
    // 截图一律保留,不再自动删除。
  }

  // ---- 截图来源 App 门禁(仅金融/电商类 App 截图触发自动记账) ----
  // 判定在原生 ScreenshotObserver 入队前完成;开关的持久化也在原生侧
  // (screenshot_monitor_prefs),Dart 只做读写转发,避免双份事实源。

  /// 门禁开关是否开启(默认开;非 Android 平台视为关 —— 仅有 Android 实现)。
  Future<bool> isSourceFilterEnabled() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('getSourceAppFilter') ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> setSourceFilterEnabled(bool value) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('setSourceAppFilter', {'enabled': value});
  }

  /// 「使用情况访问」是否已授权 —— 无障碍服务未开启时,来源 App 探测靠
  /// UsageStats 兜底;两者都没有则截图一律被门禁拦截(识别记录页可见原因)。
  Future<bool> isUsageAccessGranted() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isUsageAccessGranted') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openUsageAccessSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openUsageAccessSettings');
    } catch (_) {}
  }

  /// 释放资源
  void dispose() {
    _autoBillingService.dispose();
  }
}
