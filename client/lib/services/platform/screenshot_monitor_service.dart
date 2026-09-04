import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../automation/auto_billing_service.dart';

/// Google Play 版本(CI 注入)。Photo & Video Permissions 政策禁止记账类 app
/// 长期持有 READ_MEDIA_IMAGES,所以 Google Play 版本砍掉截屏自动记账功能。
const _isGooglePlayBuild = bool.fromEnvironment('GOOGLE_PLAY', defaultValue: false);

/// 截图监听服务（Android专用）
/// 监听系统截图事件，并调用通用的AutoBillingService进行OCR识别和记账
class ScreenshotMonitorService {
  static const _channel = MethodChannel('com.smartbook.zhi/screenshot');
  static const _enabledKey = 'screenshot_monitor_enabled';
  static const _autoDeleteKey = 'auto_delete_screenshot_after_booked';

  final ProviderContainer _container;
  late final AutoBillingService _autoBillingService;

  bool _isEnabled = false;
  bool _isMonitoring = false;

  // 单例模式
  static ScreenshotMonitorService? _instance;

  factory ScreenshotMonitorService(ProviderContainer container) {
    _instance ??= ScreenshotMonitorService._internal(container);
    return _instance!;
  }

  ScreenshotMonitorService._internal(this._container) {
    _autoBillingService = AutoBillingService(_container);
    _setupMethodCallHandler();
  }

  /// 设置方法调用处理器
  void _setupMethodCallHandler() {
    print('📸 [ScreenshotMonitor] 初始化方法调用处理器');
    _channel.setMethodCallHandler((call) async {
      print('📸 [ScreenshotMonitor] 收到方法调用: ${call.method}');
      if (call.method == 'onScreenshotDetected') {
        final path = call.arguments as String;
        print('📸 [ScreenshotMonitor] 检测到截图，路径: $path');
        await _handleScreenshot(path);
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
        throw UnsupportedError('Screenshot monitoring is not available in Google Play builds');
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

      print('✅ [ScreenshotMonitor] 截图监听已启用，_isEnabled=$_isEnabled, _isMonitoring=$_isMonitoring');
    } catch (e) {
      print('❌ [ScreenshotMonitor] 启用截图监听失败: $e');
      rethrow;
    }
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

  /// 处理截图
  Future<void> _handleScreenshot(String path) async {
    print('📸 [ScreenshotMonitor] _handleScreenshot 被调用，path=$path');
    print('📸 [ScreenshotMonitor] 当前状态: _isEnabled=$_isEnabled, _isMonitoring=$_isMonitoring');

    if (!_isEnabled || !_isMonitoring) {
      print('⚠️ [ScreenshotMonitor] 截图监听未启用或未监控，跳过处理');
      return;
    }

    // 调用通用的AutoBillingService处理截图。
    // 静默模式:触发/识别中/非账单/失败不通知,只在成功入账时通知一次
    // (减少打扰;AI 未配置仍保留会话级一次性提示,便于发现配置缺失)。
    final result =
        await _autoBillingService.processScreenshot(path, notifyOnlyOnSuccess: true);

    // 「记账成功自动删截图」:仅 AI 确认是账单且**全部**成功入账才删除。
    // 多笔识别里只要有笔进「待确认」候选队列(此时仍可能部分入账,result.success
    // 为 true),就保留原图 —— 候选制下截图是人工确认的依据。非账单/入库失败
    // 同样保留。分享/快捷指令路径不经过此处,不会误删用户主动传入的图。
    if (result.success &&
        result.awaitingCount == 0 &&
        await isAutoDeleteEnabled()) {
      final deleted = await _deleteScreenshotFile(path);
      print('📸 [ScreenshotMonitor] 记账成功,截图${deleted ? '已' : '未'}自动删除: $path');
    }
  }

  /// 「记账成功自动删截图」开关是否开启(默认关,删除是用户数据的不可逆操作)
  Future<bool> isAutoDeleteEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoDeleteKey) ?? false;
  }

  Future<void> setAutoDeleteEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoDeleteKey, value);
  }

  /// 删除截图文件(调用原生 MediaStore 删除)。
  /// Android 11+ 截图属 SystemUI 所有,删除会弹系统确认框,用户确认
  /// (勾选「不再询问」后后续静默)才真正删除,结果不阻塞记账流程。
  Future<bool> _deleteScreenshotFile(String path) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel
              .invokeMethod<bool>('deleteScreenshot', {'path': path}) ??
          false;
    } catch (e) {
      print('📸 [ScreenshotMonitor] 自动删除截图失败: $path $e');
      return false;
    }
  }

  /// 释放资源
  void dispose() {
    _autoBillingService.dispose();
  }
}
