import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' hide SyncStatus;

import '../../providers.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../styles/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../cloud/sync/sync_engine.dart';
import '../../services/system/logger_service.dart';
import '../auth/login_page.dart';
import '../settings/log_center_page.dart';

/// SmartBook Cloud 专属同步页
///
/// 跟老的 `cloud_sync_page.dart` 分开:老页面服务于 iCloud / WebDAV / 本地
/// 备份,UI 语义是"整包快照上传/下载";SmartBook Cloud 是增量 sync_changes 日志,
/// 全自动,用户感知不到"上传/下载"这个动作,所以单独一个页面。
///
/// 页面结构:
///   1. Header + 账号信息(已登录 / 重新登录按钮 / 登录入口)
///   2. 同步状态面板(localTx / remoteTx / localAttachments / remoteAttachments
///      / localAccounts / remoteAccounts / localCategories / remoteCategories
///      / localTags / remoteTags / localBudgets / remoteBudgets / unpushedChanges)
///   3. 下拉刷新:调 checkSyncHealth → 有差异就自动 sync()
class SmartBookCloudSyncPage extends ConsumerStatefulWidget {
  const SmartBookCloudSyncPage({super.key});

  @override
  ConsumerState<SmartBookCloudSyncPage> createState() =>
      _SmartBookCloudSyncPageState();
}

class _SmartBookCloudSyncPageState extends ConsumerState<SmartBookCloudSyncPage> {
  SyncHealthReport? _latestReport;
  bool _checking = false;
  bool _autoSyncing = false;
  bool _forceRestoring = false;

  @override
  void initState() {
    super.initState();
    // 页面一进来就拉一次 sync health,让"同步状态"面板开屏即有内容。
    // server 版本号改用 [smartbookCloudServerVersionProvider] 自动获取(它依赖
    // syncStatusRefreshProvider,每次同步完成自动重新拉一次),不再用本地
    // setState 缓存的死值——server 升级后用户在 app 内任何同步操作完都会刷新。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      unawaited(_onRefresh());
    });
  }

  Future<void> _onRefresh() async {
    // 整个流程异步跑得久(10k 数据可能几分钟),用户随时可能切走页面 →
    // widget dispose,ref 失效。所有访问 ref 的地方都先看 mounted。
    if (!mounted) return;
    final engine = ref.read(syncServiceProvider);
    final ledgerId = ref.read(currentLedgerIdProvider);
    if (engine is! SyncEngine || ledgerId <= 0) return;

    setState(() => _checking = true);
    try {
      // Step 1: 对账 profile。把"server 上缺但本地有"的字段补推上去。
      if (!mounted) return;
      await reconcileProfileToServer(
        cloudProviderFuture: ref.read(smartbookCloudProviderInstance.future),
        currentThemeColor: ref.read(primaryColorProvider),
        currentIncomeIsRed: ref.read(incomeExpenseColorSchemeProvider),
        currentHeaderStyle: ref.read(headerDecorationStyleProvider),
        currentCompactAmount: ref.read(compactAmountProvider),
        currentShowTransactionTime: ref.read(showTransactionTimeProvider),
        currentDisplayName: ref.read(displayNameProvider),
        currentHeaderSkin: ref.read(headerSkinProvider),
        currentNoteDisplayMode: ref.read(noteDisplayModeProvider),
        currentNoteHistoryScope: ref.read(noteHistoryScopeProvider).name,
        currentNoteHistorySort: ref.read(noteHistorySortProvider).name,
        currentNoteHistoryLimit: ref.read(noteHistoryLimitProvider),
      );
      if (!mounted) return;
      await engine.syncMyProfile();

      if (!mounted) return;
      var report = await engine.checkSyncHealth(ledgerId: ledgerId);
      if (!mounted) return;
      setState(() => _latestReport = report);

      if (report.needsBackfill) {
        final backfilled =
            await engine.backfillUntrackedEntities(ledgerId: ledgerId);
        logger.info('CloudSyncPage',
            '_onRefresh: backfill 补写 $backfilled 条 sync_change');
        if (backfilled > 0 && mounted) {
          report = await engine.checkSyncHealth(ledgerId: ledgerId);
          if (mounted) setState(() => _latestReport = report);
        }
      }

      if (report.hasDiff && mounted) {
        setState(() => _autoSyncing = true);
        try {
          await engine.sync(ledgerId: ledgerId.toString());
          if (!mounted) return;
          final after = await engine.checkSyncHealth(ledgerId: ledgerId);
          if (mounted) setState(() => _latestReport = after);
        } catch (e) {
          if (mounted) {
            showToast(
                context, '${AppLocalizations.of(context).commonFailed}: $e');
          }
        } finally {
          if (mounted) setState(() => _autoSyncing = false);
        }
      }

      // 不管是否 sync,都 bump 下 UI tick。widget 已 dispose 时跳过 —
      // 否则 ref.read 会抛 StateError "Cannot use ref after the widget was disposed"。
      if (mounted) {
        ref.read(syncStatusRefreshProvider.notifier).state++;
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// 「以服务端为准」强制恢复：清空当前账本本地交易+预算，并用服务端快照
  /// 覆盖重建账户/分类/标签，推进 cursor。带二次确认（破坏性操作，不可撤销）。
  Future<void> _forceRestore() async {
    if (!mounted) return;
    final engine = ref.read(syncServiceProvider);
    final ledgerId = ref.read(currentLedgerIdProvider);
    if (engine is! SyncEngine || ledgerId <= 0) return;
    final l10n = AppLocalizations.of(context);

    final confirmed = await AppDialog.confirm<bool>(
      context,
      title: l10n.syncForceRestoreConfirmTitle,
      message: l10n.syncForceRestoreConfirmBody,
      okLabel: l10n.syncForceRestoreTitle,
    );
    if (confirmed != true || !mounted) return;

    setState(() => _forceRestoring = true);
    try {
      final res = await engine.forceRestoreFromServer(ledgerId: ledgerId);
      if (!mounted) return;
      showToast(
          context,
          l10n.syncForceRestoreSuccess(res.inserted, res.restoredBudgets,
              res.restoredAccounts, res.restoredCategories, res.restoredTags));
      // 刷新健康面板 + 首页统计，让用户看到恢复结果。
      final report = await engine.checkSyncHealth(ledgerId: ledgerId);
      if (mounted) setState(() => _latestReport = report);
      if (mounted) ref.read(syncStatusRefreshProvider.notifier).state++;
      if (mounted) ref.read(statsRefreshProvider.notifier).state++;
    } catch (e) {
      if (mounted) {
        showToast(context, '${l10n.syncForceRestoreFailed}: $e',
            duration: const Duration(seconds: 3));
      }
    } finally {
      if (mounted) setState(() => _forceRestoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authAsync = ref.watch(authServiceProvider);
    final ledgerId = ref.watch(currentLedgerIdProvider);
    final l10n = AppLocalizations.of(context);

    if (ledgerId == 0) {
      return Scaffold(
        backgroundColor: BeeTokens.scaffoldBackground(context),
        body: Column(
          children: [
            PrimaryHeader(
              title: l10n.cloudSyncPageTitle,
              subtitle: l10n.cloudSyncPageSubtitle,
              showBack: true,
            ),
            Expanded(
              child: Center(
                child: Text(
                  l10n.aiOcrNoLedger,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: BeeTokens.textSecondary(context),
                      ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      body: Column(
        children: [
          PrimaryHeader(
            title: l10n.cloudSyncPageTitle,
            subtitle: l10n.cloudSyncPageSubtitle,
            showBack: true,
          ),
          Expanded(
            child: authAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (auth) => FutureBuilder<CloudUser?>(
                future: auth.currentUser,
                builder: (ctx, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final user = snap.data;
                  return RefreshIndicator(
                    onRefresh: _onRefresh,
                    child: ListView(
                      // 横向交给 SectionCard 自带的 horizontal:12 margin,
                      // 这里只给垂直 8 避免首尾贴屏幕。
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        // Section 1: 账号
                        SectionCard(
                          child: _buildAccountSection(context, user),
                        ),
                        // Section 2: 同步状态(深度检测结果)
                        SectionCard(
                          child: _buildHealthSection(context),
                        ),
                        const SizedBox(height: 8),
                        // Section 3: 同步说明(折叠) — 解释增量/全量、断点续传、排查
                        SectionCard(
                          child: _buildSyncHelpSection(context),
                        ),
                        // SmartBook Cloud server 版本号,底部弱展示。
                        // 跟 web header 的 vX.Y.Z 对齐,方便确认 server 哪版。
                        // 通过 provider 监听,server 升级后跟着 sync ticker 自
                        // 动刷新,不依赖死缓存。
                        Consumer(builder: (ctx, r, _) {
                          final v = r
                              .watch(smartbookCloudServerVersionProvider)
                              .valueOrNull;
                          if (v == null || v.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 16, bottom: 8),
                            child: Center(
                              child: Text(
                                'SmartBook Cloud v$v',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: BeeTokens.textTertiary(context),
                                ),
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountSection(BuildContext context, CloudUser? user) {
    final l10n = AppLocalizations.of(context);
    final cfg = ref.watch(activeCloudConfigProvider).valueOrNull;
    final cachedEmail = cfg?.smartbookCloudEmail ?? '';
    final cachedPassword = cfg?.smartbookCloudPassword ?? '';
    final hasCredentials = cachedEmail.isNotEmpty && cachedPassword.isNotEmpty;

    if (user != null) {
      return AppListTile(
        leading: Icons.verified_user_outlined,
        title: user.email ?? l10n.mineLoggedInEmail,
      );
    }

    // 未登录 + 有保存的邮密 → 显示"重新登录"按钮,点击直接调 signInWithEmail
    if (hasCredentials) {
      return AppListTile(
        leading: Icons.refresh,
        title: l10n.cloudReloginTitle,
        subtitle: cachedEmail,
        onTap: () async {
          final provider =
              ref.read(smartbookCloudProviderInstance).valueOrNull;
          if (provider == null) {
            if (mounted) showToast(context, l10n.cloudReloginFailed);
            return;
          }
          try {
            await provider.auth.signInWithEmail(
              email: cachedEmail,
              password: cachedPassword,
            );
            if (!mounted) return;
            showToast(context, l10n.cloudReloginSuccess);
            ref.read(syncStatusRefreshProvider.notifier).state++;
            ref.read(statsRefreshProvider.notifier).state++;
          } catch (e) {
            if (!mounted) return;
            showToast(context, '${l10n.cloudReloginFailed}: $e');
          }
        },
      );
    }

    // 没凭证 → 跳传统登录页
    return AppListTile(
      leading: Icons.login,
      title: l10n.mineLoginTitle,
      subtitle: l10n.mineLoginSubtitle,
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const LoginPage()),
        );
        ref.read(syncStatusRefreshProvider.notifier).state++;
      },
    );
  }

  /// 同步说明(可折叠):增量/全量、何时走全量、断点续传、排查入口。
  Widget _buildSyncHelpSection(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Theme(
      // 去掉 ExpansionTile 默认的上下分割线,贴合 SectionCard 风格
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        leading: Icon(Icons.help_outline,
            color: BeeTokens.iconSecondary(context)),
        title: Text(
          l10n.cloudSyncHelpTitle,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: BeeTokens.textPrimary(context),
          ),
        ),
        children: [
          _helpBlock(context, l10n.cloudSyncHelpModesTitle,
              l10n.cloudSyncHelpModesBody),
          _helpBlock(context, l10n.cloudSyncHelpWhenFullTitle,
              l10n.cloudSyncHelpWhenFullBody),
          _helpBlock(context, l10n.cloudSyncHelpStuckTitle,
              l10n.cloudSyncHelpStuckBody),
          _helpBlock(context, l10n.cloudSyncHelpTroubleshootTitle,
              l10n.cloudSyncHelpTroubleshootBody),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LogCenterPage()),
              ),
              style: TextButton.styleFrom(
                foregroundColor: ref.watch(primaryColorProvider),
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.article_outlined, size: 18),
              label: Text(l10n.cloudSyncHelpOpenLogCenter),
            ),
          ),
        ],
      ),
    );
  }

  /// 同步说明里的一段:加粗小标题 + 正文(正文里用 \n 分条)。
  Widget _helpBlock(BuildContext context, String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: BeeTokens.textPrimary(context),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: BeeTokens.textSecondary(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHealthSection(BuildContext context) {
    // SectionCard 已经给了 p12 内边距,这里内部只做垂直间距,不再加横向 padding。
    final l10n = AppLocalizations.of(context);
    final report = _latestReport;
    final title = Row(
      children: [
        Icon(Icons.cloud_sync_outlined,
            color: BeeTokens.iconSecondary(context), size: 20),
        const SizedBox(width: 8),
        Text(l10n.syncHealthTitle,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: BeeTokens.textPrimary(context),
                  fontWeight: FontWeight.w600,
                )),
        const Spacer(),
        if (_checking || _autoSyncing)
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );

    // 初次 init 时 report 还没填,仍然把面板骨架 + 占位值画出来(用户要求常驻)。
    final effective = report ??
        const SyncHealthReport(
          ledgerTx: SyncCountPair.missing(),
          ledgerAttachments: SyncCountPair.missing(),
          ledgerBudgets: SyncCountPair.missing(),
          totalTx: SyncCountPair.missing(),
          totalAttachments: SyncCountPair.missing(),
          totalBudgets: SyncCountPair.missing(),
          categoryAttachments: SyncCountPair.missing(),
          accounts: SyncCountPair.missing(),
          categories: SyncCountPair.missing(),
          tags: SyncCountPair.missing(),
          unpushedChanges: 0,
        );

    if (effective.error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          title,
          const SizedBox(height: 8),
          Text(
            l10n.syncHealthCheckFailed(effective.error ?? ''),
            style: const TextStyle(color: Colors.red, fontSize: 12),
          ),
        ],
      );
    }

    final summary = effective.hasDiff
        ? l10n.syncHealthHasDiff
        : l10n.syncHealthInSync;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        title,
        const SizedBox(height: 6),
        Text(
          summary,
          style: TextStyle(
            fontSize: 12,
            color: effective.hasDiff
                ? Colors.orange
                : BeeTokens.textSecondary(context),
          ),
        ),
        const SizedBox(height: 8),
        // 当前账本口径:tx / 附件 / 预算随 ledger 走
        _groupHeader(context, l10n.syncHealthGroupCurrentLedger),
        _pairRow(context, l10n.syncHealthRowTx, effective.ledgerTx),
        _pairRow(context, l10n.syncHealthRowAttachment, effective.ledgerAttachments),
        _pairRow(context, l10n.syncHealthRowBudget, effective.ledgerBudgets),
        const SizedBox(height: 8),
        // 全部账本口径:tx/附件/预算 合计 + 用户级的 account/category/tag
        _groupHeader(context, l10n.syncHealthGroupAll),
        _pairRow(context, l10n.syncHealthRowTx, effective.totalTx),
        _pairRow(context, l10n.syncHealthRowAttachment, effective.totalAttachments),
        _pairRow(context, l10n.syncHealthRowCategoryIcon, effective.categoryAttachments),
        _pairRow(context, l10n.syncHealthRowBudget, effective.totalBudgets),
        _pairRow(context, l10n.syncHealthRowAccount, effective.accounts),
        _pairRow(context, l10n.syncHealthRowCategory, effective.categories),
        _pairRow(context, l10n.syncHealthRowTag, effective.tags),
        const SizedBox(height: 8),
        _unpushedRow(context, effective.unpushedChanges),
        const SizedBox(height: 8),
        _buildForceRestoreSection(context),
      ],
    );
  }

  Widget _groupHeader(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: BeeTokens.textTertiary(context),
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Widget _pairRow(BuildContext context, String label, SyncCountPair pair) {
    final mismatch = pair.hasDiff;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: BeeTokens.textSecondary(context),
              ),
            ),
          ),
          Expanded(
            child: Text(
              pair.remote < 0
                  ? AppLocalizations.of(context).syncHealthValueRemoteMissing(pair.local)
                  : AppLocalizations.of(context).syncHealthValue(pair.local, pair.remote),
              style: TextStyle(
                fontSize: 13,
                color: mismatch
                    ? Colors.orange
                    : BeeTokens.textPrimary(context),
                fontWeight: mismatch ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _unpushedRow(BuildContext context, int count) {
    final highlight = count > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              AppLocalizations.of(context).syncHealthRowUnpushed,
              style: TextStyle(
                fontSize: 13,
                color: BeeTokens.textSecondary(context),
              ),
            ),
          ),
          Expanded(
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 13,
                color: highlight
                    ? Colors.orange
                    : BeeTokens.textPrimary(context),
                fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 「以服务端为准」危险操作区：仅 SyncEngine 模式显示，红色警示 + 二次确认。
  /// 用于 pull 卡住 / 本地云端分叉后的手动自救。
  Widget _buildForceRestoreSection(BuildContext context) {
    final engine = ref.read(syncServiceProvider);
    if (engine is! SyncEngine) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final busy = _forceRestoring;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Colors.red, size: 18),
              const SizedBox(width: 6),
              Text(
                l10n.syncForceRestoreTitle,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.red,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.syncForceRestoreConfirmBody,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.4,
              color: BeeTokens.textSecondary(context),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: busy ? null : _forceRestore,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.red),
                    )
                  : Text(l10n.syncForceRestoreTitle),
            ),
          ),
        ],
      ),
    );
  }
}
