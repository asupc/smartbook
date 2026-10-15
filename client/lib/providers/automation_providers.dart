import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ai/core/ai_runtime_state.dart';
import '../ai/providers/ai_provider_config.dart';
import '../ai/providers/ai_provider_manager.dart';
import '../services/automation/auto_billing_service.dart';
import '../services/automation/automation_health.dart';
import '../services/automation/auto_book_coordinator.dart';

import '../services/automation/automation_settings_store.dart';
import '../services/billing/pending_candidate.dart';
import '../services/platform/notify_monitor_service.dart';
import '../services/platform/screenshot_monitor_service.dart';
import '../services/platform/screen_text_monitor_service.dart';
import '../services/platform/sms_monitor_service.dart';
import '../services/system/logger_service.dart';
import '../utils/notification_android.dart';
import '../utils/notification_factory.dart';
import 'database_providers.dart';

/// 全局共享的自动记账 worker。
///
/// 之前每个 monitor 都 new 一个 AutoBillingService，导致 processed cache 和
/// 处理链彼此隔离。将实例放到根 ProviderContainer 后，所有入口至少共享
/// 同一生命周期；跨来源的全局串行由 [autoBookCoordinatorProvider] 负责。
final autoBillingServiceProvider = Provider<AutoBillingService>((ref) {
  final eventStore = ref.container.read(autoBookCoordinatorProvider).store;
  final service = AutoBillingService(ref.container, eventStore: eventStore);
  ref.onDispose(service.dispose);
  return service;
});

/// 自动记账入口统一协调器。
final autoBookCoordinatorProvider = Provider<AutoBookCoordinator>((ref) {
  final coordinator = AutoBookCoordinator(ref.watch(databaseProvider));
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

/// 待确认候选数量:「我的」页角标与首页提醒条共用的唯一计数源(P1-3)。
/// 口径与待确认页一致:loadForReview 合并 event store(cap 500)与
/// legacy SharedPreferences 候选 —— 只数 legacy 会少报(超 100 条被淘汰、
/// 或候选仅存在于 event store 时)。
final pendingCandidateCountProvider = FutureProvider<int>((ref) async {
  final eventStore = ref.watch(autoBookCoordinatorProvider).store;
  return (await PendingCandidateStore().loadForReview(eventStore)).length;
});

/// 手动触发一次全量状态补查(页面回到前台时 bump)。
/// 首页、配置页、开通页共用同一个 [automationHealthProvider],避免各页
/// 各自高频轮询原生桥。
final automationHealthRefreshProvider = StateProvider<int>((ref) => 0);

/// 自动入账目标(B2):配置页展示/确认/更换与状态卡共用。
final automationTargetProvider =
    FutureProvider<AutoBookTargetResolution>((ref) async {
  ref.watch(automationHealthRefreshProvider);
  return resolveAutoBookTarget(ref.container);
});

/// AI 运行时状态的事件流(状态变化才发事件,不轮询)。
/// 状态卡对 AI 维度用它做实时覆盖,不为一次 AI 状态变化重查全部原生桥。
final automationAiStateProvider = StreamProvider<AiRuntimeState>((ref) async* {
  final coordinator = AiRuntimeCoordinator.instance;
  yield coordinator.state;
  yield* coordinator.changes;
});

/// 自动记账运行状态的唯一共享状态源(B1 任务 2)。
///
/// 页面**不在每次 build 里**查原生桥/网络:本 Provider 由首页/配置页/
/// 开通页共用,页面恢复前台时 bump [automationHealthRefreshProvider] 补查。
///
/// 计算异常**绝不向 UI 抛出**:FutureProvider 的 error 状态在状态卡上与
/// loading 同样渲染为「检查中」,会把真实故障伪装成永久转圈。这里兜底成
/// [AutomationHealth.unknown](queryFailed,显示「状态查询失败」)并把异常
/// 写入日志中心,让失败可见、可诊断。
final automationHealthProvider = FutureProvider<AutomationHealth>((ref) async {
  ref.watch(automationHealthRefreshProvider);
  try {
    return await _computeAutomationHealth(ref.container);
  } catch (e, st) {
    logger.error('AutomationHealth', '状态计算失败(按「状态查询失败」展示)', e, st);
    return AutomationHealth.unknown();
  }
});

Future<T?> _safe<T>(Future<T> Function() action) async {
  try {
    return await action();
  } catch (_) {
    return null;
  }
}

Future<AutomationHealth> _computeAutomationHealth(
  ProviderContainer container,
) async {
  // 分阶段打点:真机上状态卡若卡在「检查中」,日志中心可看出停在哪个阶段。
  final sw = Stopwatch()..start();
  void stage(String name) =>
      logger.info('AutomationHealth', '阶段 $name 完成', '${sw.elapsedMilliseconds}ms');

  final coordinator = container.read(autoBookCoordinatorProvider);
  final store = coordinator.store;

  // 事件表统计与待确认计数:与历史页/角标同源,不另起一套口径。
  var eventStateCounts = <String, int>{};
  var pendingCount = 0;
  DateTime? lastProcessedAt;
  try {
    eventStateCounts = await store.countByState();
    pendingCount = (await PendingCandidateStore().loadForReview(store)).length;
    final latest = await store.listHistory(limit: 1);
    if (latest.isNotEmpty) lastProcessedAt = latest.first.updatedAt;
  } catch (e) {
    logger.warning('AutomationHealth', '事件统计查询失败', '$e');
  }
  stage('事件统计');

  final shadowMode = await _safe(
        () => container.read(autoBillingServiceProvider).isShadowModeEnabled(),
      ) ??
      false;

  // B2:目标解析状态(失效/待确定 → 状态卡提示「停止自动写入」)。
  // 解析链会触达云账号(authServiceProvider/CurrentUser,token 过期时发
  // refresh/login 网络请求)。状态卡只是**展示**目标状态,不做入账决策,
  // 不能被网络拖住:给它 3 秒预算,超时按「暂无目标信息」展示(null),
  // 下次补查再补上;真正入账的 drain 路径仍走完整解析,不受影响。
  AutoBookTargetResolution? target;
  try {
    target = await resolveAutoBookTarget(container)
        .timeout(const Duration(seconds: 3));
  } on TimeoutException {
    target = null;
    logger.warning('AutomationHealth', '目标解析超时(状态卡跳过该维度)', '3s');
  } catch (_) {
    target = null;
  }
  stage('目标解析');

  final aiState = AiRuntimeCoordinator.instance.state;
  final aiText = await _aiConfigured(AICapabilityType.text);
  final aiVision = await _aiConfigured(AICapabilityType.vision);
  stage('AI 配置');

  if (!Platform.isAndroid) {
    // iOS 走快捷指令/分享,不参与四路监听检测;只保留 AI 维度。
    return AutomationHealth(
      sources: const [],
      aiState: aiState,
      aiTextConfigured: aiText,
      aiVisionConfigured: aiVision,
      eventStateCounts: eventStateCounts,
      pendingCount: pendingCount,
      shadowMode: shadowMode,
      isAndroid: false,
      lastProcessedAt: lastProcessedAt,
      targetState: target?.stateName,
      targetReason: target?.reason,
    );
  }

  final screenshot = ScreenshotMonitorService(container);
  final sms = SmsMonitorService(container);
  final notify = NotifyMonitorService(container);
  final screenText = ScreenTextMonitorService(container);

  final screenshotOn = (await _safe(screenshot.isEnabled)) ?? false;
  final smsOn = (await _safe(sms.isEnabled)) ?? false;
  final notifyOn = (await _safe(notify.isEnabled)) ?? false;
  final screenOn = (await _safe(screenText.isEnabled)) ?? false;
  // 权限/连接查询失败保持 null(=待验证),不当成「被撤销」。
  final notifyListenerGranted = await _safe(notify.isListenerGranted);
  final screenGranted = await _safe(screenText.isAccessibilityGranted);
  final smsPermission = await _safe(() async => (await Permission.sms.status).isGranted);

  var native = await NativeCaptureStatus.query();
  var nativeAvailable = native != null;
  stage('开关与权限查询');

  // 冷启动竞态:桥由 Dart 侧 enable() 注册,状态卡可能先于注册完成被计算。
  // 只在「已开启来源却查到未注册」时**再确认一次**,不做周期轮询。
  if (_hasUnregisteredEnabledSource(native, {
    'screenshot': screenshotOn,
    'sms': smsOn,
    'notify': notifyOn,
    'screenText': screenOn,
  })) {
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    native = await NativeCaptureStatus.query();
    nativeAvailable = native != null;
  }
  stage('原生状态查询');

  /// 桥接/观察器注册状态。原生查询不可用 → null(待验证),
  /// **不把「查不到」当成「未连接」,更不当成「正常」**。
  bool? bridgeOf(String key) {
    if (!nativeAvailable) return null;
    final value = native![key]?['bridgeRegistered'];
    return value is bool ? value : null;
  }

  int queueOf(String key) {
    final value = native?[key]?['queueSize'];
    return value is int ? value : 0;
  }

  final sources = <AutomationSourceHealth>[
    AutomationSourceHealth(
      key: 'screenshot',
      enabled: screenshotOn,
      // 截图路的媒体权限随 ROM/版本变化,单独查询容易误报;
      // 连接状态以原生 ContentObserver 是否注册为准。
      permissionGranted: null,
      bridgeConnected: bridgeOf('screenshot'),
      queueSize: queueOf('screenshot'),
    ),
    AutomationSourceHealth(
      key: 'sms',
      enabled: smsOn,
      permissionGranted: smsPermission,
      bridgeConnected: bridgeOf('sms'),
      queueSize: queueOf('sms'),
    ),
    AutomationSourceHealth(
      key: 'notify',
      enabled: notifyOn,
      permissionGranted: notifyListenerGranted,
      bridgeConnected: bridgeOf('notify'),
      queueSize: queueOf('notify'),
    ),
    AutomationSourceHealth(
      key: 'screenText',
      enabled: screenOn,
      // 无障碍的「权限」就是「连接」:服务未连接 = 监听断开;
      // 服务已连接时再看原生桥是否注册(未注册 → 待验证/断开)。
      permissionGranted: null,
      bridgeConnected: screenGranted == null
          ? null
          : (screenGranted && bridgeOf('screenText') != false),
      queueSize: queueOf('screenText'),
    ),
  ];

  // 最近捕获时间走 NativeCaptureStatus.latestCaptureAt(纯函数、可单测):
  // 原生 map 里除四路来源外还混有 lossSummary 字符串字段,直接遍历取
  // ['lastCaptureAt'] 会抛 TypeError,整次状态计算被外层 catch 兜成
  // unknown,状态卡恒显示「状态查询失败」(2026-10-14 真机故障根因)。
  final lastCaptureAt =
      nativeAvailable ? NativeCaptureStatus.latestCaptureAt(native) : null;

  bool? batteryIgnored;
  try {
    final util = NotificationFactory.getInstance() as AndroidNotificationUtil;
    final info = await util.getBatteryOptimizationInfo();
    batteryIgnored = info['isIgnoring'] == true;
  } catch (_) {
    // 查询失败 = 待验证(既不当正常,也不当故障)。
    batteryIgnored = null;
  }

  final health = AutomationHealth(
    sources: sources,
    aiState: aiState,
    aiTextConfigured: aiText,
    aiVisionConfigured: aiVision,
    eventStateCounts: eventStateCounts,
    pendingCount: pendingCount,
    shadowMode: shadowMode,
    isAndroid: true,
    lastCaptureAt: lastCaptureAt,
    lastProcessedAt: lastProcessedAt,
    batteryOptimizationIgnored: batteryIgnored,
    nativeStatusAvailable: nativeAvailable,
    targetState: target?.stateName,
    targetReason: target?.reason,
    queueLossCount: NativeCaptureStatus.lossCount(native?['lossSummary']),
  );
  stage('完成(${health.issues().length} 项问题)');
  return health;
}

bool _hasUnregisteredEnabledSource(
  Map<String, dynamic>? native,
  Map<String, bool> enabled,
) {
  if (native == null) return false;
  for (final entry in enabled.entries) {
    if (!entry.value) continue;
    if (native[entry.key]?['bridgeRegistered'] == false) return true;
  }
  return false;
}

Future<bool> _aiConfigured(AICapabilityType type) async {
  try {
    return await AIProviderManager.isCapabilityConfigured(type);
  } catch (_) {
    return false;
  }
}
