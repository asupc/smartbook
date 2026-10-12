import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../ai/core/ai_runtime_state.dart';
import '../../l10n/app_localizations.dart';
import '../system/logger_service.dart';

/// 状态维度(计划 §3.2 六维状态卡)。
enum AutomationDimension {
  /// 用户开关(当前来源配置)。
  sourceSwitch,

  /// 系统权限(实际权限查询结果)。
  permission,

  /// 监听连接(原生连接/解绑状态与观察器注册状态)。
  listener,

  /// AI 能力(运行时状态 + 能力绑定)。
  ai,

  /// 处理队列(原生积压 / 事件重试 / 待确认子项)。
  queue,

  /// 云同步。
  sync,
}

/// 状态卡上一个问题的可执行动作。
enum AutomationIssueAction {
  none,
  openSetup,
  openSourceSettings,
  openPermissionPage,
  openListenerSettings,
  openAccessibilitySettings,
  openAiConfig,
  openPending,
  openRecords,
  openSyncStatus,
}

/// 结构化问题描述:**不带文案**,文案在 [AutomationHealth.describe] 现场按
/// l10n 生成,避免状态源依赖 BuildContext。
class AutomationIssue {
  const AutomationIssue({
    required this.dimension,
    required this.code,
    required this.action,
    this.count = 0,
    this.blocking = false,
  });

  final AutomationDimension dimension;

  /// 语义码,见 [AutomationHealth.describe] 的映射表。
  final String code;

  final AutomationIssueAction action;

  /// 与该问题相关的数量(积压/待处理/待确认)。
  final int count;

  /// 是否会直接阻断自动记账(阻断项排在状态卡最前)。
  final bool blocking;
}

/// 单个来源的运行状态。
class AutomationSourceHealth {
  const AutomationSourceHealth({
    required this.key,
    required this.enabled,
    this.permissionGranted,
    this.bridgeConnected,
    this.queueSize = 0,
  });

  /// 'screenshot' | 'sms' | 'notify' | 'screenText'
  final String key;

  /// 用户开关。
  final bool enabled;

  /// 实际权限查询结果;null = 该来源无独立权限或查询不适用。
  final bool? permissionGranted;

  /// 原生桥接/观察器连接状态;null = **待验证**(查询不到不等于正常)。
  final bool? bridgeConnected;

  /// 原生队列积压条数。
  final int queueSize;
}

/// 自动记账健康快照:首页状态卡、配置页、开通页共用的**唯一**状态源。
class AutomationHealth {
  const AutomationHealth({
    required this.sources,
    required this.aiState,
    required this.aiTextConfigured,
    required this.aiVisionConfigured,
    required this.eventStateCounts,
    required this.pendingCount,
    required this.shadowMode,
    required this.isAndroid,
    this.lastCaptureAt,
    this.lastProcessedAt,
    this.batteryOptimizationIgnored,
    this.nativeStatusAvailable = false,
    this.queryFailed = false,
    this.targetState,
    this.targetReason,
    this.queueLossCount = 0,
  });

  /// 计算空快照(查询失败时使用:问题可见,但**绝不显示「正常」**)。
  factory AutomationHealth.unknown() => AutomationHealth(
        sources: const [],
        aiState: AiRuntimeState.initializing,
        aiTextConfigured: false,
        aiVisionConfigured: false,
        eventStateCounts: const {},
        pendingCount: 0,
        shadowMode: false,
        isAndroid: Platform.isAndroid,
        queryFailed: true,
      );

  final List<AutomationSourceHealth> sources;
  final AiRuntimeState aiState;
  final bool aiTextConfigured;
  final bool aiVisionConfigured;

  /// 事件表按状态计数(captured/processing/pending/booked/…)。
  final Map<String, int> eventStateCounts;
  final int pendingCount;
  final bool shadowMode;
  final bool isAndroid;

  /// 最近一次原生捕获时间(各路 enqueue 时落盘,ACK 后仍保留)。
  final DateTime? lastCaptureAt;

  /// 最近一次事件处理时间(事件表 updatedAt 最大值)。
  final DateTime? lastProcessedAt;

  final bool? batteryOptimizationIgnored;

  /// 原生只读状态查询是否成功。false = 监听连接维度只能显示「待验证」。
  final bool nativeStatusAvailable;

  /// 整体查询是否失败(失败时不得显示「运行正常」)。
  final bool queryFailed;

  /// B2:自动目标解析状态('resolved'/'unconfirmed'/'invalid'/'undetermined');
  /// null = 尚未查询。
  final String? targetState;

  /// 目标失效/待确定的原因码('target_ledger_missing'/'target_scope_mismatch'/…)。
  final String? targetReason;

  /// B3:容量拒收/过期清理的损失摘要条数(>0 时状态卡可见,不静默丢)。
  final int queueLossCount;

  int get nativeBacklog => sources.fold(0, (sum, s) => sum + s.queueSize);

  int get retryCount =>
      (eventStateCounts['retry'] ?? 0) + (eventStateCounts['failed'] ?? 0);

  int get backlogCount => nativeBacklog + retryCount;

  AutomationSourceHealth? source(String key) {
    for (final s in sources) {
      if (s.key == key) return s;
    }
    return null;
  }

  /// 未开启的来源不产生任何问题(「未选择的来源不算故障」)。
  List<AutomationIssue> issues() {
    if (queryFailed) {
      return const [
        AutomationIssue(
          dimension: AutomationDimension.listener,
          code: 'statusQueryFailed',
          action: AutomationIssueAction.openSetup,
          blocking: true,
        ),
      ];
    }

    final list = <AutomationIssue>[];

    for (final s in sources) {
      if (!s.enabled) continue;
      if (s.permissionGranted == false) {
        list.add(AutomationIssue(
          dimension: AutomationDimension.permission,
          code: 'permissionRevoked:${s.key}',
          action: s.key == 'screenshot'
              ? AutomationIssueAction.openPermissionPage
              : AutomationIssueAction.openPermissionPage,
          blocking: true,
        ));
      }
      if (s.bridgeConnected == false) {
        list.add(AutomationIssue(
          dimension: AutomationDimension.listener,
          code: s.key == 'screenText'
              ? 'accessibilityDisconnected'
              : 'listenerDisconnected:${s.key}',
          action: s.key == 'screenText'
              ? AutomationIssueAction.openAccessibilitySettings
              : AutomationIssueAction.openListenerSettings,
          blocking: true,
        ));
      } else if (s.bridgeConnected == null) {
        list.add(const AutomationIssue(
          dimension: AutomationDimension.listener,
          code: 'listenerUnverified',
          action: AutomationIssueAction.none,
        ));
      }
    }

    // AI 能力:运行时状态优先,能力绑定为辅。
    switch (aiState) {
      case AiRuntimeState.unconfigured:
        list.add(const AutomationIssue(
          dimension: AutomationDimension.ai,
          code: 'aiUnconfigured',
          action: AutomationIssueAction.openAiConfig,
          blocking: true,
        ));
      case AiRuntimeState.authenticationRequired:
        list.add(const AutomationIssue(
          dimension: AutomationDimension.ai,
          code: 'aiLoginRequired',
          action: AutomationIssueAction.openAiConfig,
          blocking: true,
        ));
      case AiRuntimeState.offline:
        list.add(const AutomationIssue(
          dimension: AutomationDimension.ai,
          code: 'aiOffline',
          action: AutomationIssueAction.none,
        ));
      case AiRuntimeState.providerError:
        list.add(const AutomationIssue(
          dimension: AutomationDimension.ai,
          code: 'aiProviderError',
          action: AutomationIssueAction.openAiConfig,
          blocking: true,
        ));
      case AiRuntimeState.initializing:
        list.add(const AutomationIssue(
          dimension: AutomationDimension.ai,
          code: 'aiInitializing',
          action: AutomationIssueAction.none,
        ));
      case AiRuntimeState.ready:
        if (!aiTextConfigured || !aiVisionConfigured) {
          list.add(const AutomationIssue(
            dimension: AutomationDimension.ai,
            code: 'aiCapabilityMissing',
            action: AutomationIssueAction.openAiConfig,
            blocking: true,
          ));
        }
        break;
    }

    // B2:目标失效/待确定 → 停止自动写入并提示修复;未确认 → 提示确认。
    switch (targetState) {
      case 'invalid':
        list.add(AutomationIssue(
          dimension: AutomationDimension.sourceSwitch,
          code: targetReason == 'target_scope_mismatch'
              ? 'targetScopeMismatch'
              : 'targetInvalid',
          action: AutomationIssueAction.openSetup,
          blocking: true,
        ));
      case 'undetermined':
        list.add(const AutomationIssue(
          dimension: AutomationDimension.sourceSwitch,
          code: 'targetUndetermined',
          action: AutomationIssueAction.openSetup,
          blocking: true,
        ));
      case 'unconfirmed':
        list.add(const AutomationIssue(
          dimension: AutomationDimension.sourceSwitch,
          code: 'targetUnconfirmed',
          action: AutomationIssueAction.openSetup,
        ));
      default:
        break;
    }

    if (batteryOptimizationIgnored == false) {
      list.add(const AutomationIssue(
        dimension: AutomationDimension.sourceSwitch,
        code: 'batteryOptimization',
        action: AutomationIssueAction.openSourceSettings,
      ));
    }

    if (queueLossCount > 0) {
      list.add(AutomationIssue(
        dimension: AutomationDimension.queue,
        code: 'queueLoss',
        action: AutomationIssueAction.openRecords,
        count: queueLossCount,
      ));
    }

    if (backlogCount > 0) {
      list.add(AutomationIssue(
        dimension: AutomationDimension.queue,
        code: 'queueBacklog',
        action: AutomationIssueAction.openRecords,
        count: backlogCount,
      ));
    }
    if (pendingCount > 0) {
      list.add(AutomationIssue(
        dimension: AutomationDimension.queue,
        code: 'pendingCount',
        action: AutomationIssueAction.openPending,
        count: pendingCount,
      ));
    }

    // 阻断项在前,可执行项次之。
    list.sort((a, b) {
      final ab = a.blocking ? 0 : 1;
      final bb = b.blocking ? 0 : 1;
      if (ab != bb) return ab - bb;
      return a.dimension.index.compareTo(b.dimension.index);
    });
    return list;
  }

  /// 是否可以对外显示为「运行正常」:必须查询成功、无任何问题。
  bool get isHealthy => !queryFailed && issues().isEmpty;

  /// 用**事件驱动**的实时 AI 状态覆盖快照里的 AI 维度:
  /// AI 状态变化只重算这一个维度,不重查原生桥与网络。
  AutomationHealth withAiState(AiRuntimeState state) => AutomationHealth(
        sources: sources,
        aiState: state,
        aiTextConfigured: aiTextConfigured,
        aiVisionConfigured: aiVisionConfigured,
        eventStateCounts: eventStateCounts,
        pendingCount: pendingCount,
        shadowMode: shadowMode,
        isAndroid: isAndroid,
        lastCaptureAt: lastCaptureAt,
        lastProcessedAt: lastProcessedAt,
        batteryOptimizationIgnored: batteryOptimizationIgnored,
        nativeStatusAvailable: nativeStatusAvailable,
        queryFailed: queryFailed,
        targetState: targetState,
        targetReason: targetReason,
        queueLossCount: queueLossCount,
      );

  /// 演练模式必须在首页明示(计划 §3.1)。
  bool get needsShadowBanner => shadowMode;

  /// 结构化问题 → 用户文案。未知 code 兜底为维度名,不透传英文码。
  static String describe(AppLocalizations l10n, AutomationIssue issue) {
    final code = issue.code;
    if (code.startsWith('permissionRevoked:')) {
      final key = code.split(':').last;
      return '${l10n.autoHealthPermissionRevoked}·${_sourceLabel(l10n, key)}';
    }
    if (code.startsWith('listenerDisconnected:')) {
      final key = code.split(':').last;
      return '${l10n.autoHealthListenerDisconnected}·${_sourceLabel(l10n, key)}';
    }
    return switch (code) {
      'accessibilityDisconnected' => l10n.autoHealthAccessibilityDisconnected,
      'listenerUnverified' => l10n.autoHealthListenerUnverified,
      'statusQueryFailed' => l10n.autoHealthStatusQueryFailed,
      'aiUnconfigured' => l10n.autoHealthAiUnconfigured,
      'aiLoginRequired' => l10n.autoHealthAiLoginRequired,
      'aiOffline' => l10n.autoHealthAiOffline,
      'aiProviderError' => l10n.autoHealthAiProviderError,
      'aiInitializing' => l10n.autoHealthAiInitializing,
      'aiCapabilityMissing' => l10n.autoHealthAiCapabilityMissing,
      'batteryOptimization' => l10n.autoHealthBatteryOptimization,
      'targetInvalid' => l10n.autoHealthTargetInvalid,
      'targetScopeMismatch' => l10n.autoTargetInvalidScope,
      'targetUndetermined' => l10n.autoHealthTargetUndetermined,
      'targetUnconfirmed' => l10n.autoHealthTargetUnconfirmed,
      'queueLoss' => l10n.autoHealthQueueLoss(issue.count),
      'queueBacklog' => l10n.autoHealthQueueBacklog(issue.count),
      'pendingCount' => l10n.autoHealthPendingCount(issue.count),
      _ => l10n.autoHealthDimUnknown,
    };
  }

  static String _sourceLabel(AppLocalizations l10n, String key) =>
      switch (key) {
        'screenshot' => l10n.autoScreenshotBillingTitle,
        'sms' => l10n.autoSmsBillingTitle,
        'notify' => l10n.autoBillingNotifyTitle,
        'screenText' => l10n.autoBillingScreenTextTitle,
        _ => key,
      };

  /// 维度名(状态卡分组标题)。
  static String dimensionLabel(AppLocalizations l10n, AutomationDimension d) =>
      switch (d) {
        AutomationDimension.sourceSwitch => l10n.autoHealthDimSwitch,
        AutomationDimension.permission => l10n.autoHealthDimPermission,
        AutomationDimension.listener => l10n.autoHealthDimListener,
        AutomationDimension.ai => l10n.autoHealthDimAi,
        AutomationDimension.queue => l10n.autoHealthDimQueue,
        AutomationDimension.sync => l10n.autoHealthDimSync,
      };

  /// 短标签(「我的」入口 subtitle 的「未就绪项」列表用,沿用既有健康项文案)。
  static String shortLabel(AppLocalizations l10n, AutomationIssue issue) {
    final code = issue.code;
    if (code.startsWith('permissionRevoked:')) {
      return switch (code.split(':').last) {
        'sms' => l10n.autoBillingHealthIssueSmsPermission,
        'notify' => l10n.autoBillingHealthIssueNotifyListener,
        _ => l10n.autoHealthDimPermission,
      };
    }
    if (code.startsWith('listenerDisconnected:')) {
      return switch (code.split(':').last) {
        'sms' => l10n.autoBillingHealthIssueSms,
        'notify' => l10n.autoBillingHealthIssueNotify,
        'screenshot' => l10n.autoBillingHealthIssueScreenshot,
        _ => l10n.autoHealthDimListener,
      };
    }
    return switch (code) {
      'accessibilityDisconnected' => l10n.autoBillingScreenTextTitle,
      'aiUnconfigured' ||
      'aiCapabilityMissing' =>
        l10n.autoBillingHealthIssueAiText,
      'aiLoginRequired' => l10n.autoHealthAiLoginRequired,
      'aiProviderError' => l10n.autoHealthAiProviderError,
      'aiOffline' => l10n.autoHealthAiOffline,
      'batteryOptimization' => l10n.autoBillingHealthIssueBattery,
      'targetInvalid' ||
      'targetScopeMismatch' ||
      'targetUndetermined' ||
      'targetUnconfirmed' =>
        l10n.autoTargetTitle,
      'listenerUnverified' => l10n.autoHealthListenerUnverified,
      'statusQueryFailed' => l10n.autoHealthStatusQueryFailed,
      _ => describe(l10n, issue),
    };
  }
}

/// 原生只读状态查询(B1 任务 2:只读,不写任何原生状态)。
///
/// 查询失败**不抛给调用方** —— 返回 null,由上层落 `nativeStatusAvailable=false`
/// 并显示「待验证」,绝不把「查不到」当成「正常」。
class NativeCaptureStatus {
  static const MethodChannel _channel =
      MethodChannel('com.smartbook.zhi/automation_status');

  static const Set<String> sources = {
    'sms',
    'notify',
    'screenText',
    'screenshot',
  };

  /// 返回 `{source: {queueSize, lastCaptureAt, ...}, lossSummary: "..."}`;
  /// 查询失败返回 null(维度显示「待验证」,绝不当正常)。
  static Future<Map<String, dynamic>?> query() async {
    if (!Platform.isAndroid) return null;
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'getCaptureStats',
      );
      if (raw == null) return null;
      final out = <String, dynamic>{};
      for (final key in sources) {
        final value = raw[key];
        if (value is Map) {
          out[key] = value.map((k, v) => MapEntry(k.toString(), v));
        }
      }
      out['lossSummary'] = raw['lossSummary'];
      return out;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      logger.warning('AutomationHealth', '原生状态查询失败(显示待验证)', e.message);
      return null;
    }
  }

  /// 损失摘要条目数(容量拒收 / 过期清理);解析失败按 0 处理。
  static int lossCount(Object? raw) {
    if (raw is! String || raw.isEmpty) return 0;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.length;
    } catch (_) {}
    return 0;
  }
}
