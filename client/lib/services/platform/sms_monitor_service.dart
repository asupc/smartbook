import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../automation/auto_billing_service.dart'
    show AutoBillingService, SmsProcessOutcome;
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
    _autoBillingService = AutoBillingService(_container);
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
    _processingChain =
        _processingChain.catchError((_) {}).then((_) => task());
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
  /// 启用后立即补处理积压队列。
  Future<void> enable() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('仅支持 Android 平台');
    }
    await _channel.invokeMethod('setEnabled', {'enabled': true});
    await _registerBridge();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, true);
    _isEnabled = true;
    await _enqueue(drainPendingSms);
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
  /// peek 当前队列 → 逐项处理 → 除 noAiConfigured 外全部 ack。
  Future<void> drainPendingSms() async {
    if (!_isEnabled) return;
    try {
      final items = await _channel
              .invokeMethod<List<dynamic>>('peekPendingSms') ??
          const [];
      for (final raw in items) {
        if (!_isEnabled) break; // 用户中途关闭:剩余项留在队列
        if (raw is! Map) continue;
        final sender = (raw['sender'] ?? '').toString();
        final body = (raw['body'] ?? '').toString();
        final fingerprint = (raw['fingerprint'] ?? '').toString();
        if (body.isEmpty) {
          await _ack(fingerprint);
          continue;
        }

        // 已处理过的(如上次处理完成但 ack 前被杀):跳过并补 ack
        if (_autoBillingService.isSmsProcessed(fingerprint)) {
          await _ack(fingerprint);
          continue;
        }

        // AI 未配置的提示每指纹只弹一次(会话内)
        final alreadyWarned = _noAiNotified.contains(fingerprint);
        final outcome = await _autoBillingService.processSms(
          sender,
          body,
          showNotification: !alreadyWarned,
        );
        if (outcome == SmsProcessOutcome.noAiConfigured) {
          _noAiNotified.add(fingerprint);
        } else {
          await _ack(fingerprint);
        }
      }
    } catch (e) {
      // 队列读取/通道异常不抛:不影响主流程。
      // 已处理项未 ack 会在下次 drain 通过指纹预检补 ack。
    }
  }

  Future<void> _ack(String fingerprint) async {
    if (fingerprint.isEmpty) return;
    try {
      await _channel.invokeMethod(
          'ackPendingSms', {'fingerprints': [fingerprint]});
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
