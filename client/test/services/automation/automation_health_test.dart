import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smartbook/ai/core/ai_runtime_state.dart';
import 'package:smartbook/l10n/app_localizations.dart';
import 'package:smartbook/services/automation/automation_health.dart';

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('zh'));
  });

  AutomationHealth build({
    List<AutomationSourceHealth>? sources,
    AiRuntimeState aiState = AiRuntimeState.ready,
    bool aiTextConfigured = true,
    bool aiVisionConfigured = true,
    Map<String, int> counts = const {},
    int pending = 0,
    bool shadow = false,
    bool? batteryIgnored = true,
    bool nativeAvailable = true,
    bool queryFailed = false,
    int queueLoss = 0,
  }) =>
      AutomationHealth(
        sources: sources ??
            const [
              AutomationSourceHealth(
                  key: 'notify', enabled: true, permissionGranted: true),
            ],
        aiState: aiState,
        aiTextConfigured: aiTextConfigured,
        aiVisionConfigured: aiVisionConfigured,
        eventStateCounts: counts,
        pendingCount: pending,
        shadowMode: shadow,
        isAndroid: true,
        batteryOptimizationIgnored: batteryIgnored,
        nativeStatusAvailable: nativeAvailable,
        queryFailed: queryFailed,
        queueLossCount: queueLoss,
      );

  group('未开启的来源不算故障', () {
    test('全部未开启 + AI 正常 → 无问题', () {
      final h = build(sources: const [
        AutomationSourceHealth(key: 'sms', enabled: false),
        AutomationSourceHealth(key: 'notify', enabled: false),
      ]);
      expect(h.issues(), isEmpty);
      expect(h.isHealthy, isTrue);
    });

    test('开启但权限被撤 → 阻断问题,指向授权动作', () {
      final h = build(sources: const [
        AutomationSourceHealth(
            key: 'sms', enabled: true, permissionGranted: false),
      ]);
      final issues = h.issues();
      expect(issues, isNotEmpty);
      expect(issues.first.blocking, isTrue);
      expect(issues.first.dimension, AutomationDimension.permission);
      expect(issues.first.action, AutomationIssueAction.openPermissionPage);
      expect(
        AutomationHealth.describe(l10n, issues.first),
        contains(l10n.autoHealthPermissionRevoked),
      );
    });
  });

  group('监听连接:未验证不显示为正常', () {
    test('已开启但桥接未注册 → 阻断问题', () {
      final h = build(sources: const [
        AutomationSourceHealth(
            key: 'notify', enabled: true, permissionGranted: true),
      ]).withBridge('notify', false);
      final issues = h.issues();
      expect(
        issues.any(
            (i) => i.dimension == AutomationDimension.listener && i.blocking),
        isTrue,
      );
    });

    test('桥接状态未知(原生查询不可用) → 待验证,而不是正常', () {
      final h = build(
        sources: const [
          AutomationSourceHealth(
              key: 'notify', enabled: true, permissionGranted: true),
        ],
        nativeAvailable: false,
      ).withBridge('notify', null);
      final issues = h.issues();
      expect(issues.map((i) => i.code), contains('listenerUnverified'));
      expect(h.isHealthy, isFalse);
      expect(
        AutomationHealth.describe(
            l10n, issues.firstWhere((i) => i.code == 'listenerUnverified')),
        l10n.autoHealthListenerUnverified,
      );
    });

    test('整体查询失败 → 只给「状态查询失败」且绝不显示正常', () {
      final h = build(queryFailed: true);
      final issues = h.issues();
      expect(issues.single.code, 'statusQueryFailed');
      expect(h.isHealthy, isFalse);
      expect(AutomationHealth.describe(l10n, issues.single),
          l10n.autoHealthStatusQueryFailed);
    });
  });

  group('AI 维度', () {
    for (final (state, code) in const [
      (AiRuntimeState.unconfigured, 'aiUnconfigured'),
      (AiRuntimeState.authenticationRequired, 'aiLoginRequired'),
      (AiRuntimeState.offline, 'aiOffline'),
      (AiRuntimeState.providerError, 'aiProviderError'),
      (AiRuntimeState.initializing, 'aiInitializing'),
    ]) {
      test('$state → $code 且可读', () {
        final h = build(aiState: state);
        final issues = h.issues();
        final hit = issues.where((i) => i.code == code);
        expect(hit, isNotEmpty, reason: '$state 应产生 $code');
        expect(AutomationHealth.describe(l10n, hit.first), isNotEmpty);
        expect(AutomationHealth.describe(l10n, hit.first), isNot(code));
      });
    }

    test('ready 但能力缺失 → aiCapabilityMissing', () {
      final h = build(aiTextConfigured: false, aiVisionConfigured: false);
      expect(
        h.issues().any((i) => i.code == 'aiCapabilityMissing'),
        isTrue,
      );
    });

    test('ready 且能力齐全 → AI 维度无问题', () {
      final h = build();
      expect(h.issues().where((i) => i.dimension == AutomationDimension.ai),
          isEmpty);
    });

    test('withAiState 只改 AI 维度,其余维度保持', () {
      final base = build(sources: const [
        AutomationSourceHealth(
            key: 'sms', enabled: true, permissionGranted: false),
      ]);
      final next = base.withAiState(AiRuntimeState.offline);
      expect(next.aiState, AiRuntimeState.offline);
      expect(
        next.issues().length,
        base.issues().length + 1,
        reason: '离线应新增一条 AI 问题,权限问题保留',
      );
      expect(next.pendingCount, base.pendingCount);
      expect(next.lastCaptureAt, base.lastCaptureAt);
    });
  });

  group('队列与待确认', () {
    test('原生积压 + 重试事件合并进 backlogCount', () {
      final h = build(
        sources: const [
          AutomationSourceHealth(
              key: 'notify',
              enabled: true,
              permissionGranted: true,
              queueSize: 3),
        ],
        counts: const {'retry': 2, 'failed': 1, 'booked': 5},
      );
      expect(h.backlogCount, 6);
      final issue = h.issues().firstWhere((i) => i.code == 'queueBacklog');
      expect(issue.count, 6);
      expect(AutomationHealth.describe(l10n, issue), contains('6'));
    });

    test('待确认子项单独一条问题', () {
      final h = build(pending: 4);
      final issue = h.issues().firstWhere((i) => i.code == 'pendingCount');
      expect(issue.count, 4);
      expect(issue.action, AutomationIssueAction.openPending);
    });

    test('无积压无待确认 → 不产生队列问题', () {
      expect(
        build().issues().where((i) => i.dimension == AutomationDimension.queue),
        isEmpty,
      );
    });
  });

  group('演练模式与电池', () {
    test('演练模式需要首页横幅', () {
      expect(build(shadow: true).needsShadowBanner, isTrue);
      expect(build(shadow: false).needsShadowBanner, isFalse);
    });

    test('电池优化未忽略 → 非阻断问题', () {
      final h = build(batteryIgnored: false);
      final issue =
          h.issues().firstWhere((i) => i.code == 'batteryOptimization');
      expect(issue.blocking, isFalse);
      expect(AutomationHealth.describe(l10n, issue),
          l10n.autoHealthBatteryOptimization);
    });

    test('电池状态查询失败(null)→ 不当故障', () {
      expect(
          build(batteryIgnored: null)
              .issues()
              .where((i) => i.code == 'batteryOptimization'),
          isEmpty);
    });
  });

  group('B3 损失摘要', () {
    test('解析条目数,坏数据按 0 处理', () {
      expect(NativeCaptureStatus.lossCount(null), 0);
      expect(NativeCaptureStatus.lossCount(''), 0);
      expect(NativeCaptureStatus.lossCount('not json'), 0);
      expect(NativeCaptureStatus.lossCount('{}'), 0);
      expect(
        NativeCaptureStatus.lossCount(
          '[{"source":"sms","kind":"expired","count":2}]',
        ),
        1,
      );
      expect(NativeCaptureStatus.lossCount('[{"a":1},{"b":2},{"c":3}]'), 3);
    });

    test('有损失摘要时状态卡给出可见问题(不静默)', () {
      final h = build(queueLoss: 3);
      final issue = h.issues().firstWhere((i) => i.code == 'queueLoss');
      expect(issue.count, 3);
      expect(issue.action, AutomationIssueAction.openRecords);
      expect(AutomationHealth.describe(l10n, issue), contains('3'));
      expect(h.isHealthy, isFalse);
    });

    test('无损失摘要不产生问题', () {
      expect(
        build().issues().where((i) => i.code == 'queueLoss'),
        isEmpty,
      );
    });
  });

  group('维度短标签', () {
    test('权限/监听/AI 等问题的短标签都不是原始码', () {
      final h = build(sources: const [
        AutomationSourceHealth(
            key: 'notify', enabled: true, permissionGranted: false),
      ]);
      for (final issue in h.issues()) {
        final label = AutomationHealth.shortLabel(l10n, issue);
        expect(label, isNot(issue.code));
        expect(label, isNotEmpty);
      }
    });

    test('六个维度都有名称', () {
      for (final d in AutomationDimension.values) {
        expect(AutomationHealth.dimensionLabel(l10n, d), isNotEmpty);
      }
    });
  });
}

extension on AutomationHealth {
  /// 测试用:替换指定来源的桥接状态。
  AutomationHealth withBridge(String key, bool? connected) {
    return AutomationHealth(
      sources: [
        for (final s in sources)
          s.key == key
              ? AutomationSourceHealth(
                  key: s.key,
                  enabled: s.enabled,
                  permissionGranted: s.permissionGranted,
                  bridgeConnected: connected,
                  queueSize: s.queueSize,
                )
              : s,
      ],
      aiState: aiState,
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
    );
  }
}
