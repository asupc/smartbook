import 'dart:io' show Platform, File;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:smartbook/widgets/biz/smartbook_icon.dart';

import '../../providers.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../styles/tokens.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' hide SyncStatus;
import '../../cloud/sync_service.dart';
import '../cloud/cloud_service_page.dart';
import '../../services/system/logger_service.dart';
import '../../services/ui/avatar_service.dart';
import '../../providers/avatar_providers.dart';
import '../../providers/sync_providers.dart' as sp;
import '../../l10n/app_localizations.dart';
import '../automation/auto_billing_settings_page.dart';
import '../automation/auto_recognition_records_page.dart';
import '../cloud/cloud_sync_page.dart';
import '../cloud/smartbook_cloud_sync_page.dart';
import '../../utils/notification_factory.dart';
import '../../utils/notification_android.dart';
import '../settings/data_management_page.dart';
import '../settings/appearance_settings_page.dart';
import '../settings/smart_billing_page.dart';
import '../settings/automation_page.dart';
import '../report/annual_report_page.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:in_app_review/in_app_review.dart';
import '../../ai/providers/ai_provider_config.dart' show AICapabilityType;
import '../../ai/providers/ai_provider_manager.dart' show AIProviderManager;
import '../../services/platform/screenshot_monitor_service.dart';
import '../../services/platform/sms_monitor_service.dart';
import '../../services/platform/notify_monitor_service.dart';
import '../../pages/automation/pending_confirmation_page.dart';
import '../automation/deleted_transactions_page.dart';
import '../../utils/ui_scale_extensions.dart';

/// 自动记账健康检查结果(截图/短信/通知监听 + AI 配置 + 电池优化的聚合)。
class AutoBillingHealth {
  const AutoBillingHealth({
    required this.screenshotOn,
    required this.smsOn,
    required this.smsPermissionGranted,
    required this.notifyOn,
    required this.notifyListenerGranted,
    required this.aiTextReady,
    required this.aiVisionReady,
    this.batteryOptimizationIgnored = true,
  });

  final bool screenshotOn;
  final bool smsOn;
  final bool smsPermissionGranted;
  final bool notifyOn;
  final bool notifyListenerGranted;
  final bool aiTextReady;
  final bool aiVisionReady;

  /// 电池优化是否已被忽略(vivo 保活必查;查询失败/Future 视为通过防误报)。
  final bool batteryOptimizationIgnored;

  /// 未就绪项 key 列表(供 UI 逐项显示 l10n 文案)。
  /// 权限缺失只在对应监听开启时才算问题(没开监听就不必给权限)。
  List<String> get issues {
    final list = <String>[];
    if (!screenshotOn) list.add('screenshot');
    if (!smsOn) list.add('sms');
    if (smsOn && !smsPermissionGranted) list.add('smsPermission');
    if (!notifyOn) list.add('notify');
    if (notifyOn && !notifyListenerGranted) list.add('notifyListener');
    if (!aiTextReady) list.add('aiText');
    if (!aiVisionReady) list.add('aiVision');
    if (!batteryOptimizationIgnored) list.add('battery');
    return list;
  }

  int get issueCount => issues.length;

  bool get isHealthy => issueCount == 0;
}

// 自动记账健康检测:截图/短信/通知监听未开启、监听权限被撤、
// AI 文本或视觉未配置都会导致自动记账不可用。
// 待确认候选数量(M2 候选制)的 pendingCandidateCountProvider 已上移到
// providers/automation_providers.dart(P1-3 统一口径),与首页提醒条共用。

final autoBillingHealthProvider = FutureProvider<AutoBillingHealth>((ref) async {
  final container = ref.container;
  // 截图/短信/通知监听是 Android 专属能力;iOS 走快捷指令/分享,不参与检测
  if (!Platform.isAndroid) {
    return AutoBillingHealth(
      screenshotOn: true,
      smsOn: true,
      smsPermissionGranted: true,
      notifyOn: true,
      notifyListenerGranted: true,
      aiTextReady: await AIProviderManager.isCapabilityConfigured(
          AICapabilityType.text),
      aiVisionReady: await AIProviderManager.isCapabilityConfigured(
          AICapabilityType.vision),
    );
  }
  final screenshot = ScreenshotMonitorService(container);
  final sms = SmsMonitorService(container);
  final notify = NotifyMonitorService(container);
  final smsPerm = await Permission.sms.status;
  bool batteryIgnored = true;
  try {
    final androidUtil =
        NotificationFactory.getInstance() as AndroidNotificationUtil;
    final info = await androidUtil.getBatteryOptimizationInfo();
    batteryIgnored = info['isIgnoring'] == true;
  } catch (_) {
    // 查询失败视为通过,避免误报
  }
  return AutoBillingHealth(
    screenshotOn: await screenshot.isEnabled(),
    smsOn: await sms.isEnabled(),
    smsPermissionGranted: smsPerm.isGranted,
    notifyOn: await notify.isEnabled(),
    notifyListenerGranted: await notify.isListenerGranted(),
    aiTextReady: await AIProviderManager.isCapabilityConfigured(
        AICapabilityType.text),
    aiVisionReady: await AIProviderManager.isCapabilityConfigured(
        AICapabilityType.vision),
    batteryOptimizationIgnored: batteryIgnored,
  );
});

class MinePage extends ConsumerWidget {
  const MinePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authAsync = ref.watch(authServiceProvider);
    final ledgerId = ref.watch(currentLedgerIdProvider);

    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context), // ⭐ 使用 Token
      body: Column(
        children: [
          PrimaryHeader(
            showBack: false,
            title: AppLocalizations.of(context).mineTitle,
            compact: true,
            showTitleSection: false,
            content: _MinePageHeader(),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                BeeTokens.cardDivider(context, indent: 0),
                SizedBox(height: 8.0.scaled(context, ref)),
                // 云同步与备份
                Consumer(builder: (sectionContext, sectionRef, _) {
                  final activeCfg = sectionRef.watch(activeCloudConfigProvider);

                  return SectionCard(
                    margin: EdgeInsets.fromLTRB(
                        12.0.scaled(sectionContext, sectionRef),
                        0,
                        12.0.scaled(sectionContext, sectionRef),
                        0),
                    child: Column(
                      children: [
                        // 云服务 —— SmartBook Cloud 模式下 subtitle 带上
                        // server 版本号(从 fetchServerVersion 拉的 FutureProvider),
                        // 一眼看到 cloud 哪版。其它模式没版本概念,保留原文案。
                        Consumer(builder: (ctx, r, _) {
                          final cloudVersion = r
                              .watch(smartbookCloudServerVersionProvider)
                              .valueOrNull;
                          return AppListTile(
                            leading: Icons.cloud_outlined,
                            leadingColor: const Color(0xFF0284C7),
                            leadingBgColor:
                                const Color(0xFF0284C7).withValues(alpha: 0.12),
                            title: AppLocalizations.of(sectionContext)
                                .mineCloudService,
                            subtitle: activeCfg.when(
                              loading: () => AppLocalizations.of(sectionContext)
                                  .mineCloudServiceLoading,
                              error: (e, _) =>
                                  '${AppLocalizations.of(sectionContext).commonError}: $e',
                              data: (cfg) {
                                switch (cfg.type) {
                                  case CloudBackendType.local:
                                    return AppLocalizations.of(sectionContext)
                                        .mineCloudServiceOffline;
                                  case CloudBackendType.smartbookCloud:
                                    return cloudVersion != null &&
                                            cloudVersion.isNotEmpty
                                        ? 'SmartBook Cloud v$cloudVersion'
                                        : 'SmartBook Cloud';
                                  default:
                                    // 旧版备份同步类型已无入口
                                    return '';
                                }
                              },
                            ),
                            onTap: () async {
                              await Navigator.of(sectionContext).push(
                                MaterialPageRoute(
                                    builder: (_) => const CloudServicePage()),
                              );
                            },
                          );
                        }),
                        // 同步状态
                        Builder(
                          builder: (ctx) {
                            return authAsync.when(
                              loading: () => const Padding(
                                padding: EdgeInsets.all(16.0),
                                child:
                                    Center(child: CircularProgressIndicator()),
                              ),
                              error: (e, _) => Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: Text(
                                  '${AppLocalizations.of(sectionContext).commonError}: $e',
                                  style: const TextStyle(color: Colors.red),
                                ),
                              ),
                              data: (auth) => FutureBuilder<CloudUser?>(
                                future: auth.currentUser,
                                builder: (ctx, snap) {
                                  if (snap.hasError) {
                                    return Padding(
                                      padding: const EdgeInsets.all(16.0),
                                      child: Text(
                                        '${AppLocalizations.of(sectionContext).commonError}: ${snap.error}',
                                        style:
                                            const TextStyle(color: Colors.red),
                                      ),
                                    );
                                  }

                                  final user = snap.data;
                                  final cloudConfig = sectionRef
                                      .watch(activeCloudConfigProvider);
                                  final isLocalMode = cloudConfig.hasValue &&
                                      cloudConfig.value!.type ==
                                          CloudBackendType.local;
                                  // 云同步需要登录(SmartBook Cloud 账号)
                                  final canUseCloud = !isLocalMode &&
                                      user != null;
                                  final asyncSt = sectionRef
                                      .watch(syncStatusProvider(ledgerId));
                                  final cached = sectionRef
                                      .watch(lastSyncStatusProvider(ledgerId));
                                  final st = asyncSt.asData?.value ?? cached;
                                  // 批次3:同步失败的错误详情(此前 provider 建了
                                  // 但没有 UI 消费,失败被静默吞)。有错时副标题
                                  // 直接给原因,点击进同步详情页排查/重试。
                                  final syncError =
                                      sectionRef.watch(sp.lastSyncErrorProvider);

                                  // 计算简化的同步状态显示
                                  String subtitle = '';
                                  bool showCheckIcon = false;
                                  final isFirstLoad = st == null;
                                  final refreshing = asyncSt.isLoading;

                                  if (syncError != null) {
                                    // 失败详情优先于 diff 状态:diff 可能仍显示
                                    // localNewer(还没推上去),错误才是真信号。
                                    subtitle =
                                        '${AppLocalizations.of(sectionContext).mineSyncError}: ${_briefSyncError(syncError)}';
                                  } else if (!isFirstLoad) {
                                    switch (st.diff) {
                                      case SyncDiff.notLoggedIn:
                                        subtitle =
                                            AppLocalizations.of(sectionContext)
                                                .mineSyncNotLoggedIn;
                                        break;
                                      case SyncDiff.notConfigured:
                                        subtitle =
                                            AppLocalizations.of(sectionContext)
                                                .mineSyncNotConfigured;
                                        break;
                                      case SyncDiff.noRemote:
                                        subtitle =
                                            AppLocalizations.of(sectionContext)
                                                .mineSyncNoRemote;
                                        break;
                                      case SyncDiff.inSync:
                                        subtitle =
                                            AppLocalizations.of(sectionContext)
                                                .mineSyncInSyncSimple;
                                        showCheckIcon = true;
                                        break;
                                      case SyncDiff.localNewer:
                                        subtitle =
                                            AppLocalizations.of(sectionContext)
                                                .mineSyncLocalNewerSimple;
                                        break;
                                      case SyncDiff.cloudNewer:
                                        subtitle =
                                            AppLocalizations.of(sectionContext)
                                                .mineSyncCloudNewerSimple;
                                        break;
                                      case SyncDiff.different:
                                        subtitle =
                                            AppLocalizations.of(sectionContext)
                                                .mineSyncDifferent;
                                        break;
                                      case SyncDiff.error:
                                        subtitle =
                                            AppLocalizations.of(sectionContext)
                                                .mineSyncError;
                                        break;
                                    }
                                  }

                                  return Column(
                                    children: [
                                      BeeTokens.cardDivider(sectionContext),
                                      AppListTile(
                                        leading: Icons.cloud_sync_outlined,
                                        leadingColor: const Color(0xFF0D9488),
                                        leadingBgColor: const Color(0xFF0D9488)
                                            .withValues(alpha: 0.12),
                                        title:
                                            AppLocalizations.of(sectionContext)
                                                .mineSyncTitle,
                                        subtitle:
                                            (isFirstLoad && syncError == null)
                                                ? null
                                                : subtitle,
                                        enabled: !isLocalMode,
                                        trailing: (canUseCloud &&
                                                (isFirstLoad || refreshing))
                                            ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2))
                                            : showCheckIcon
                                                ? Icon(Icons.check_circle,
                                                    color: sectionRef.watch(
                                                        primaryColorProvider),
                                                    size: 20)
                                                : Icon(Icons.chevron_right,
                                                    color: BeeTokens.iconTertiary(
                                                        context), // ⭐ 使用 Token
                                                    size: 20),
                                        onTap: () async {
                                          // SmartBook Cloud 专属页跟老的
                                          // iCloud/WebDAV/Supabase 页语义完全不同,
                                          // 路由按 config.type 分叉,避免 UI 里
                                          // 大段 if-else 分支。
                                          final cfg = ref
                                              .read(activeCloudConfigProvider)
                                              .valueOrNull;
                                          final isSmartBook = cfg != null &&
                                              cfg.type ==
                                                  CloudBackendType.smartbookCloud;
                                          await Navigator.of(sectionContext)
                                              .push(
                                            MaterialPageRoute(
                                                builder: (_) => isSmartBook
                                                    ? const SmartBookCloudSyncPage()
                                                    : const CloudSyncPage()),
                                          );
                                        },
                                      ),
                                    ],
                                  );
                                },
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  );
                }),
                // 自动化与智能记账
                SizedBox(height: 10.0.scaled(context, ref)),
                SectionCard(
                  margin: EdgeInsets.fromLTRB(12.0.scaled(context, ref), 0,
                      12.0.scaled(context, ref), 0),
                  child: Column(
                    children: [
                      // 自动记账:入口 + 健康状态检测(subtitle 动态刷新)
                      Consumer(
                        builder: (ctx, r, _) {
                          final health = r.watch(autoBillingHealthProvider);
                          final h = health.asData?.value;
                          final pendingCount =
                              r.watch(pendingCandidateCountProvider).valueOrNull ??
                                  0;
                          final issueCount = h?.issueCount ?? 0;
                          final l10n = AppLocalizations.of(ctx);
                          String? issueLabel(String key) {
                            switch (key) {
                              case 'screenshot':
                                return l10n.autoBillingHealthIssueScreenshot;
                              case 'sms':
                                return l10n.autoBillingHealthIssueSms;
                              case 'smsPermission':
                                return l10n.autoBillingHealthIssueSmsPermission;
                              case 'notify':
                                return l10n.autoBillingHealthIssueNotify;
                              case 'notifyListener':
                                return l10n.autoBillingHealthIssueNotifyListener;
                              case 'aiText':
                                return l10n.autoBillingHealthIssueAiText;
                              case 'aiVision':
                                return l10n.autoBillingHealthIssueAiVision;
                              case 'battery':
                                return l10n.autoBillingHealthIssueBattery;
                              default:
                                return null;
                            }
                          }

                          final statusText = h == null
                              ? l10n.smartBillingChecking
                              : (h.isHealthy
                                  ? l10n.autoBillingHealthy
                                  : l10n.autoBillingPartial(issueCount,
                                      h.issues
                                          .map(issueLabel)
                                          .whereType<String>()
                                          .join('、')));
                          return AppListTile(
                            leading: Icons.auto_fix_high_rounded,
                            leadingColor: const Color(0xFFD97706),
                            leadingBgColor:
                                const Color(0xFFD97706).withValues(alpha: 0.12),
                            title: AppLocalizations.of(ctx)
                                .autoBillingEntryTitle,
                            subtitle: statusText,
                            // trailing:健康图标,右下角叠加待确认计数徽标
                            trailing: Stack(
                              alignment: Alignment.bottomRight,
                              children: [
                                h == null
                                    ? Icon(Icons.chevron_right,
                                        color: BeeTokens.iconTertiary(ctx),
                                        size: 20)
                                    : Icon(
                                        h.isHealthy
                                            ? Icons.check_circle
                                            : Icons.warning_amber_rounded,
                                        color: h.isHealthy
                                            ? Colors.green
                                            : Colors.orange,
                                        size: 20),
                                if (pendingCount > 0)
                                  Positioned(
                                    right: -3,
                                    bottom: -3,
                                    child: Container(
                                      constraints: const BoxConstraints(
                                          minWidth: 14),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 3, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: Colors.orange,
                                        borderRadius:
                                            BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        pendingCount > 99
                                            ? '99+'
                                            : '$pendingCount',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 9,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            onTap: () async {
                              await Navigator.of(ctx).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const AutoBillingSettingsPage()),
                              );
                              // 从设置页返回后刷新健康检测与待确认计数
                              r.invalidate(autoBillingHealthProvider);
                              r.invalidate(pendingCandidateCountProvider);
                            },
                          );
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 待确认记账(M2 候选制):自动路径的候选交易人工审核入口
                      Consumer(
                        builder: (ctx, r, _) {
                          final count = r.watch(pendingCandidateCountProvider).valueOrNull ?? 0;
                          return AppListTile(
                            leading: Icons.fact_check_outlined,
                            leadingColor: const Color(0xFFEA580C),
                            leadingBgColor:
                                const Color(0xFFEA580C).withValues(alpha: 0.12),
                            title: AppLocalizations.of(ctx).pendingConfirmationTitle,
                            subtitle: count > 0
                                ? AppLocalizations.of(ctx)
                                    .pendingConfirmationCountBadge(count)
                                : AppLocalizations.of(ctx).pendingConfirmationDesc,
                            trailing: count > 0
                                ? Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.orange.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '$count',
                                      style: const TextStyle(
                                          color: Colors.orange,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  )
                                : Icon(Icons.chevron_right,
                                    color: BeeTokens.iconTertiary(ctx), size: 20),
                            onTap: () async {
                              await Navigator.of(ctx).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const PendingConfirmationPage()),
                              );
                              // 返回后刷新计数徽标
                              r.invalidate(pendingCandidateCountProvider);
                            },
                          );
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 最近删除(v43 回收站):30 天内可恢复误删交易
                      AppListTile(
                        leading: Icons.delete_sweep_outlined,
                        leadingColor: const Color(0xFF64748B),
                        leadingBgColor:
                            const Color(0xFF64748B).withValues(alpha: 0.12),
                        title: AppLocalizations.of(context).trashTitle,
                        subtitle: AppLocalizations.of(context).trashEntryDesc,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context), size: 20),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    const DeletedTransactionsPage()),
                          );
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 智能记账
                      AppListTile(
                        leading: Icons.auto_awesome_rounded,
                        leadingColor: const Color(0xFF7C3AED),
                        leadingBgColor:
                            const Color(0xFF7C3AED).withValues(alpha: 0.12),
                        title: AppLocalizations.of(context).smartBilling,
                        subtitle: AppLocalizations.of(context).smartBillingDesc,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context),
                            size: 20),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const SmartBillingPage()),
                          );
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 自动化功能
                      AppListTile(
                        leading: Icons.schedule_rounded,
                        leadingColor: const Color(0xFF4F46E5),
                        leadingBgColor:
                            const Color(0xFF4F46E5).withValues(alpha: 0.12),
                        title: AppLocalizations.of(context).automation,
                        subtitle: AppLocalizations.of(context).automationDesc,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context),
                            size: 20),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const AutomationPage()),
                          );
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 自动识别记录(漏记排查):决策码/命中词/计数,不含页面文本
                      AppListTile(
                        leading: Icons.manage_search_rounded,
                        leadingColor: const Color(0xFF475569),
                        leadingBgColor:
                            const Color(0xFF475569).withValues(alpha: 0.12),
                        title: AppLocalizations.of(context)
                            .autoRecognitionRecordsTitle,
                        subtitle: AppLocalizations.of(context)
                            .autoRecognitionRecordsDesc,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context),
                            size: 20),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    const AutoRecognitionRecordsPage()),
                          );
                        },
                      ),
                    ],
                  ),
                ),

                // 通用偏好与数据管理
                SizedBox(height: 10.0.scaled(context, ref)),
                SectionCard(
                  margin: EdgeInsets.fromLTRB(12.0.scaled(context, ref), 0,
                      12.0.scaled(context, ref), 0),
                  child: Column(
                    children: [
                      // 数据管理
                      AppListTile(
                        leading: Icons.storage_rounded,
                        leadingColor: const Color(0xFF059669),
                        leadingBgColor:
                            const Color(0xFF059669).withValues(alpha: 0.12),
                        title: AppLocalizations.of(context).dataManagement,
                        subtitle:
                            AppLocalizations.of(context).dataManagementDesc,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context),
                            size: 20),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const DataManagementPage()),
                          );
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 外观设置
                      AppListTile(
                        leading: Icons.palette_outlined,
                        leadingColor: const Color(0xFFE11D48),
                        leadingBgColor:
                            const Color(0xFFE11D48).withValues(alpha: 0.12),
                        dotAnchor: 'personalize',
                        title: AppLocalizations.of(context).appearanceSettings,
                        subtitle:
                            AppLocalizations.of(context).appearanceSettingsDesc,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context),
                            size: 20),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const AppearanceSettingsPage()),
                          );
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 年度账单
                      AppListTile(
                        leading: Icons.auto_graph_rounded,
                        leadingColor: const Color(0xFFF59E0B),
                        leadingBgColor:
                            const Color(0xFFF59E0B).withValues(alpha: 0.12),
                        title: AppLocalizations.of(context).annualReportTitle,
                        subtitle: AppLocalizations.of(context)
                            .annualReportEntrySubtitle,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context), size: 20),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const AnnualReportPage()),
                          );
                        },
                      ),
                      // 只在iOS上显示评分入口（Android还未上架）
                      if (Platform.isIOS) ...[
                        BeeTokens.cardDivider(context),
                        AppListTile(
                          leading: Icons.star_border_rounded,
                          leadingColor: const Color(0xFFEAB308),
                          leadingBgColor:
                              const Color(0xFFEAB308).withValues(alpha: 0.12),
                          title: AppLocalizations.of(context).mineRateApp,
                          subtitle:
                              AppLocalizations.of(context).mineRateAppSubtitle,
                          onTap: () => _rateApp(context),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(height: BeeDimens.p16.scaled(context, ref)),
                // 底部留白，避免被悬浮 Tab 栏遮挡
                SizedBox(height: 56 + 12 + MediaQuery.of(context).viewPadding.bottom + 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCell extends ConsumerWidget {
  final String label;
  final dynamic value; // 可以是 String 或 double
  final TextStyle? labelStyle;
  final TextStyle? numStyle;
  final bool isAmount; // 是否为金额类型
  final String? currencyCode; // 币种代码
  final bool centered; // 是否居中对齐
  final Widget? trailingWidget;

  const _StatCell({
    required this.label,
    required this.value,
    this.labelStyle,
    this.numStyle,
    this.isAmount = false,
    this.currencyCode,
    this.centered = false,
    this.trailingWidget,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget valueWidget;
    if (isAmount && value is double) {
      // 金额类型,使用 AmountText
      valueWidget = AmountText(
        value: value as double,
        signed: false,
        showCurrency: true,
        useCompactFormat: ref.watch(compactAmountProvider),
        currencyCode: currencyCode,
        style: numStyle,
      );
    } else {
      // 其他类型,直接显示字符串
      valueWidget = Text(value.toString(), style: numStyle);
    }

    return Column(
      crossAxisAlignment:
          centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        valueWidget,
        SizedBox(height: 4.0.scaled(context, ref)), // 数字与标签间距增大
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment:
              centered ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            Text(label,
                style: labelStyle,
                textAlign: centered ? TextAlign.center : TextAlign.start),
            if (trailingWidget != null) ...[
              const SizedBox(width: 4),
              trailingWidget!,
            ],
          ],
        ),
      ],
    );
  }
}

/// 请求应用评分
///
/// iOS系统对原生评分弹窗有限制：
/// 1. 每365天最多弹出3次
/// 2. 模拟器上不显示
/// 3. 用户可在系统设置中禁用
///
/// 因此直接打开App Store评分页面更可靠
Future<void> _rateApp(BuildContext context) async {
  try {
    final InAppReview inAppReview = InAppReview.instance;

    // 直接打开应用商店评分页面（更可靠，不受系统限制）
    if (Platform.isIOS) {
      await inAppReview.openStoreListing(
        appStoreId: '6754611670', // SmartBook的App Store ID
      );
      logger.info('MinePage', '已打开App Store评分页面');
    } else {
      // Android会自动打开Google Play（如果已上架）
      await inAppReview.openStoreListing();
      logger.info('MinePage', '已打开Google Play评分页面');
    }
  } catch (e) {
    logger.error('MinePage', '打开评分失败', e);
    // 失败时不显示错误提示，静默失败
  }
}



/// 我的页面头部
class _MinePageHeader extends ConsumerStatefulWidget {
  const _MinePageHeader();

  @override
  ConsumerState<_MinePageHeader> createState() => _MinePageHeaderState();
}

class _MinePageHeaderState extends ConsumerState<_MinePageHeader> {
  // 本地 optimistic 状态：用户自己刚选完图片时立刻更新到这里，配合 setState
  // 让 UI 零延迟响应。后台同步（SmartBookCloud 拉下来的头像）落盘后通过
  // ref.watch(avatarPathProvider) 自动传播到这里；_avatarPath 只是初始化/
  // optimistic override，渲染时 avatarPathProvider 的值优先。
  String? _avatarPath;
  bool _isLoadingAvatar = true;

  @override
  void initState() {
    super.initState();
    _loadAvatar();
  }

  Future<void> _loadAvatar() async {
    final path = await AvatarService.getAvatarPath();
    if (mounted) {
      setState(() {
        _avatarPath = path;
        _isLoadingAvatar = false;
      });
    }
  }

  Future<void> _showProfileOptions() async {
    final l10n = AppLocalizations.of(context);
    final result = await AppDialog.showActionSheet<String>(
      context,
      title: l10n.mineProfileEditTitle,
      actions: [
        ActionSheetItem(
          icon: Icons.badge_outlined,
          title: l10n.mineDisplayNameEditTitle,
          value: 'nickname',
        ),
        ActionSheetItem(
          icon: Icons.photo_library_outlined,
          title: l10n.mineAvatarFromGallery,
          value: 'gallery',
        ),
        ActionSheetItem(
          icon: Icons.camera_alt_outlined,
          title: l10n.mineAvatarFromCamera,
          value: 'camera',
        ),
        if (_avatarPath != null)
          ActionSheetItem(
            icon: Icons.delete_outline_rounded,
            title: l10n.mineAvatarDelete,
            isDestructive: true,
            value: 'delete',
          ),
      ],
    );

    if (result == null || !mounted) return;

    if (result == 'nickname') {
      await _showEditDisplayName();
      return;
    }

    try {
      if (result == 'gallery') {
        final path = await AvatarService.pickAndSaveAvatar();
        if (mounted && path != null) {
          setState(() => _avatarPath = path);
          ref.invalidate(avatarPathProvider);
          await _syncAvatarToCloud(path);
        }
      } else if (result == 'camera') {
        final path = await AvatarService.takePhotoAndSaveAvatar();
        if (mounted && path != null) {
          setState(() => _avatarPath = path);
          ref.invalidate(avatarPathProvider);
          await _syncAvatarToCloud(path);
        }
      } else if (result == 'delete') {
        await AvatarService.deleteAvatar();
        if (mounted) {
          setState(() => _avatarPath = null);
          ref.invalidate(avatarPathProvider);
        }
      }
    } catch (e) {
      if (!mounted) return;
      showToast(context, '${AppLocalizations.of(context).commonError}: $e');
    }
  }

  /// 头像同步到 SmartBook Cloud（走 /api/v1/profile/avatar）。
  /// 失败仅记日志，不阻塞用户使用本地头像；iCloud/WebDAV/Supabase 场景跳过。
  Future<void> _syncAvatarToCloud(String absolutePath) async {
    try {
      final providerInstance = await ref.read(sp.smartbookCloudProviderInstance.future);
      if (providerInstance == null) {
        logger.debug('avatar_sync', '非 SmartBook Cloud 模式，跳过头像云同步');
        return;
      }
      final file = File(absolutePath);
      if (!file.existsSync()) {
        logger.warning('avatar_sync', 'upload skipped: file missing $absolutePath');
        return;
      }
      final bytes = await file.readAsBytes();
      final name = absolutePath.split('/').last;
      logger.info('avatar_sync',
          'upload start path=$absolutePath size=${bytes.length}B');
      final result = await providerInstance.uploadMyAvatar(
        bytes: bytes,
        fileName: name,
        mimeType: name.toLowerCase().endsWith('.png')
            ? 'image/png'
            : 'image/jpeg',
      );
      // 上传成功后把本地 remoteVersion 立刻推到 server 的新版本，避免下一次
      // bootstrap 再触发一次重新下载自己刚传的头像。
      await AvatarService.setStoredRemoteVersion(result.avatarVersion);
      logger.info('avatar_sync',
          'upload done server_version=${result.avatarVersion} url=${result.avatarUrl}');
    } catch (e, st) {
      logger.warning('avatar_sync', 'upload failed (non-blocking): $e', st);
    }
  }

  /// 按本地时段返回问候语 + 配图(太阳/月亮)+ 图标色:5-11 早 / 11-13 午 /
  /// 13-18 下午 / 18-23 晚 / 23-5 夜。白天用太阳(暖色 amber→orange),晚上 / 夜里
  /// 用月亮(violet / indigo);图标色不随主题变。
  ({String text, IconData icon, Color color}) _greeting(AppLocalizations l10n) {
    final h = DateTime.now().hour;
    if (h >= 5 && h < 11) {
      return (
        text: l10n.mineGreetingMorning,
        icon: Icons.wb_twilight,
        color: const Color(0xFFF59E0B),
      );
    }
    if (h >= 11 && h < 13) {
      return (
        text: l10n.mineGreetingNoon,
        icon: Icons.wb_sunny,
        color: const Color(0xFFF59E0B),
      );
    }
    if (h >= 13 && h < 18) {
      return (
        text: l10n.mineGreetingAfternoon,
        icon: Icons.wb_sunny,
        color: const Color(0xFFF97316),
      );
    }
    if (h >= 18 && h < 23) {
      return (
        text: l10n.mineGreetingEvening,
        icon: Icons.nights_stay,
        color: const Color(0xFF8B5CF6),
      );
    }
    return (
      text: l10n.mineGreetingNight,
      icon: Icons.nightlight_round,
      color: const Color(0xFF818CF8),
    );
  }

  /// 编辑用户昵称。保存写入 displayNameProvider —— 本地持久化与(仅 SmartBook
  /// Cloud 模式)云推送由 provider 的 listener 自动完成。v1 不支持清空已设昵称:
  /// trim 为空则不改动。
  ///
  /// controller 由弹窗 [_EditDisplayNameDialog] 自己持有/释放,不在本异步方法里
  /// `finally { controller.dispose() }` —— 否则取消时弹窗退场动画未结束、TextField
  /// 仍挂载就释放 controller,会触发 "used after disposed" 红屏。
  Future<void> _showEditDisplayName() async {
    final current = ref.read(displayNameProvider);
    final l10n = AppLocalizations.of(context);
    final result = await AppDialog.prompt(
      context,
      title: l10n.mineDisplayNameEditTitle,
      hintText: l10n.mineDisplayNameHint,
      initialValue: current,
      maxLength: 20,
    );
    if (result == null || !mounted) return;
    final name = result.trim();
    if (name.isEmpty || name == current) return; // v1 不清空;无变化不写
    ref.read(displayNameProvider.notifier).state = name;
    showToast(context, l10n.mineDisplayNameSaved);
  }

  @override
  Widget build(BuildContext context) {
    // 监听云同步写下来的头像路径：当 SyncEngine.syncMyProfile 从服务端拉到
    // 新头像并 bump avatarRefreshProvider 时，这里自动拿到新值，无需手动刷新。
    // 优先级：云同步路径 > 本地 optimistic (_avatarPath)。
    final avatarAsync = ref.watch(avatarPathProvider);
    final effectiveAvatarPath = avatarAsync.asData?.value ?? _avatarPath;

    // 获取当前账本信息
    final currentLedgerId = ref.watch(currentLedgerIdProvider);
    final countsAsync = ref.watch(countsForLedgerProvider(currentLedgerId));
    final balanceAsync = ref.watch(currentBalanceProvider(currentLedgerId));
    final currentLedgerAsync = ref.watch(currentLedgerProvider);
    final hide = ref.watch(hideAmountsProvider);
    final displayName = ref.watch(displayNameProvider);
    final l10n = AppLocalizations.of(context);
    final greeting = _greeting(l10n);
    final nameStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          color: BeeTokens.textPrimary(context),
          fontWeight: FontWeight.w600,
        );
    // 已设置=「问候,昵称」(与 web 一致),未设置=Slogan。
    final headerText = displayName.isNotEmpty
        ? l10n.mineGreetingNamed(greeting.text, displayName)
        : l10n.mineSlogan;

    final day = countsAsync.asData?.value.dayCount ?? 0;
    final tx = countsAsync.asData?.value.txCount ?? 0;
    final balance = balanceAsync.asData?.value ?? 0.0;
    final currencyCode = currentLedgerAsync.asData?.value?.currency ?? 'CNY';

    // 统计信息文字颜色
    final labelStyle = Theme.of(context)
        .textTheme
        .labelMedium
        ?.copyWith(color: BeeTokens.textSecondary(context));
    final numStyle = BeeTextTokens.strongTitle(context)
        .copyWith(fontSize: 20, color: BeeTokens.textPrimary(context));

    return Padding(
      padding: EdgeInsets.fromLTRB(
        12.0.scaled(context, ref),
        8.0.scaled(context, ref),
        12.0.scaled(context, ref),
        4.0.scaled(context, ref),
      ),
      child: Column(
        children: [
          // 头像/Logo
          GestureDetector(
            onTap: _showProfileOptions,
            child: Stack(
              children: [
                Container(
                  width: 74.0.scaled(context, ref),
                  height: 74.0.scaled(context, ref),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.08),
                    border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.28),
                      width: 2.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.12),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: _isLoadingAvatar
                        ? Center(
                            child: SizedBox(
                              width: 20.0.scaled(context, ref),
                              height: 20.0.scaled(context, ref),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          )
                        : (effectiveAvatarPath != null
                            ? Image.file(
                                key: ValueKey(effectiveAvatarPath),
                                File(effectiveAvatarPath),
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return SmartBookIcon(
                                    size: 38.0.scaled(context, ref),
                                  );
                                },
                              )
                            : SmartBookIcon(
                                size: 38.0.scaled(context, ref),
                              )),
                  ),
                ),
                Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 22.0.scaled(context, ref),
                      height: 22.0.scaled(context, ref),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.camera_alt_rounded,
                        size: 11.0.scaled(context, ref),
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(height: 10.0.scaled(context, ref)),
          // 昵称行: 时段图标 + 问候/昵称
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (displayName.isNotEmpty) ...[
                Icon(greeting.icon,
                    size: 18.0.scaled(context, ref), color: greeting.color),
                SizedBox(width: 6.0.scaled(context, ref)),
              ],
              Flexible(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _showEditDisplayName,
                  child: Text(
                    headerText,
                    style: nameStyle?.copyWith(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              SizedBox(width: 4.0.scaled(context, ref)),
              GestureDetector(
                onTap: _showEditDisplayName,
                child: Icon(
                  Icons.edit_outlined,
                  size: 15,
                  color: BeeTokens.iconTertiary(context),
                ),
              ),
            ],
          ),
          SizedBox(height: 4.0.scaled(context, ref)),
          // 状态标签胶囊:已连接 SmartBook Cloud / 本地离线模式
          Consumer(
            builder: (ctx, r, _) {
              final cfg = r.watch(activeCloudConfigProvider).valueOrNull;
              final isCloud = cfg != null && cfg.type == CloudBackendType.smartbookCloud;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: isCloud
                      ? const Color(0xFF10B981).withValues(alpha: 0.10)
                      : (BeeTokens.isDark(ctx)
                          ? Colors.white.withValues(alpha: 0.06)
                          : Colors.black.withValues(alpha: 0.04)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isCloud
                            ? const Color(0xFF10B981)
                            : BeeTokens.iconTertiary(ctx),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      isCloud ? 'SmartBook Cloud' : AppLocalizations.of(ctx).mineCloudServiceOffline,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: isCloud
                            ? const Color(0xFF059669)
                            : BeeTokens.textSecondary(ctx),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          SizedBox(height: 12.0.scaled(context, ref)),
          // 统计数据微卡片面板
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: 8.0.scaled(context, ref),
              vertical: 12.0.scaled(context, ref),
            ),
            decoration: BoxDecoration(
              color: BeeTokens.surface(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: BeeTokens.isDark(context)
                    ? Colors.white10
                    : Colors.black.withValues(alpha: 0.04),
                width: 0.8,
              ),
              boxShadow: BeeTokens.isDark(context) ? null : BeeShadows.card,
            ),
            child: Row(
              children: [
                Expanded(
                  child: _StatCell(
                    label: AppLocalizations.of(context).mineDaysCount,
                    value: day.toString(),
                    labelStyle: labelStyle,
                    numStyle: numStyle,
                    centered: true,
                  ),
                ),
                Container(
                  width: 0.5,
                  height: 28,
                  color: BeeTokens.isDark(context)
                      ? Colors.white12
                      : Colors.black.withValues(alpha: 0.07),
                ),
                Expanded(
                  child: _StatCell(
                    label: AppLocalizations.of(context).mineTotalRecords,
                    value: tx.toString(),
                    labelStyle: labelStyle,
                    numStyle: numStyle,
                    centered: true,
                  ),
                ),
                Container(
                  width: 0.5,
                  height: 28,
                  color: BeeTokens.isDark(context)
                      ? Colors.white12
                      : Colors.black.withValues(alpha: 0.07),
                ),
                Expanded(
                  child: _StatCell(
                    label: AppLocalizations.of(context).mineCurrentBalance,
                    value: hide ? '****' : balance,
                    isAmount: !hide,
                    currencyCode: currencyCode,
                    labelStyle: labelStyle,
                    numStyle: numStyle.copyWith(
                      color: balance >= 0
                          ? BeeTokens.textPrimary(context)
                          : BeeTokens.error(context),
                    ),
                    centered: true,
                    trailingWidget: GestureDetector(
                      onTap: () {
                        final cur = ref.read(hideAmountsProvider);
                        ref.read(hideAmountsProvider.notifier).state = !cur;
                      },
                      child: Icon(
                        hide
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 14,
                        color: BeeTokens.iconTertiary(context),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


/// 同步错误摘要:去掉异常类名前缀,截断到 80 字符(副标题一行放得下)。
/// 完整错误在同步详情页(SmartBookCloudSyncPage)可查。
String _briefSyncError(String raw) {
  var text = raw;
  final paren = text.indexOf(': ');
  if (paren > 0 && paren < 40) text = text.substring(paren + 2);
  text = text.replaceAll('\n', ' ').trim();
  return text.length > 80 ? '${text.substring(0, 80)}…' : text;
}
