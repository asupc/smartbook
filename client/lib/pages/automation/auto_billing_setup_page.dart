import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' hide SyncStatus;

import '../../ai/core/ai_runtime_state.dart';
import '../../ai/providers/ai_provider_config.dart' show AICapabilityType;
import '../../ai/providers/ai_provider_manager.dart' show AIProviderManager;
import '../../data/db.dart' as schema;
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../services/automation/automation_health.dart';
import '../../services/automation/automation_settings_store.dart';
import '../../services/platform/notify_monitor_service.dart';
import '../../services/platform/screenshot_monitor_service.dart';
import '../../services/platform/screen_text_monitor_service.dart';
import '../../services/platform/sms_monitor_service.dart';
import '../../styles/tokens.dart';
import '../../utils/notification_android.dart';
import '../../utils/notification_factory.dart';
import '../../widgets/ui/primary_header.dart';
import '../../widgets/ui/toast.dart';

/// 自动记账开通引导(B1 任务 1)。
///
/// 五步:**连接服务与检查 AI → 选择入账目标 → 选择来源并授权 → 检查后台
/// 运行设置 → 完成一次真实来源验证**。逐步保存进度,退出后可续接;权限
/// 解释在用户开启对应来源时显示,不一次性索取全部权限;回到前台时重查。
///
/// 模拟/解析测试**不算**真实验证(见 §3.1「不把模拟成功标为真实监听通过」)。
class AutoBillingSetupPage extends ConsumerStatefulWidget {
  const AutoBillingSetupPage({super.key, this.initialStep});

  /// 指定起始步(设置页「继续开通」用);缺省按进度续接。
  final int? initialStep;

  @override
  ConsumerState<AutoBillingSetupPage> createState() =>
      _AutoBillingSetupPageState();
}

class _AutoBillingSetupPageState extends ConsumerState<AutoBillingSetupPage>
    with WidgetsBindingObserver {
  static const _stepCount = 5;

  int _step = 0;
  bool _loading = true;
  bool _saving = false;
  AutoBookSetupProgress _progress = const AutoBookSetupProgress();

  // 步骤 0:服务与 AI
  bool _aiTextReady = false;
  bool _aiVisionReady = false;
  AiRuntimeState _aiState = AiRuntimeState.initializing;
  bool _loggedIn = false;

  // 步骤 1:目标
  List<schema.Ledger> _ledgers = const [];
  int? _targetLedgerId;
  int? _targetAccountId;
  List<schema.Account> _accounts = const [];

  // 步骤 2:来源
  bool _notifyOn = false;
  bool _smsOn = false;
  bool _screenOn = false;
  bool _shotOn = false;
  bool _notifyGranted = false;
  bool _smsGranted = false;
  bool _screenGranted = false;

  // 步骤 3:后台
  bool? _batteryIgnored;

  // 步骤 4:验证
  int _baselineCaptureAt = 0;
  int _baselineQueue = 0;
  bool _verifyChecking = false;
  String? _verifyMessage;
  bool _verifyOk = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _step = widget.initialStep ?? 0;
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 计划 §4 B1 任务 1:回到 APP 后重新检查权限与连接。
    if (state == AppLifecycleState.resumed) {
      _loadAll();
    }
  }

  Future<void> _bootstrap() async {
    final progress =
        await ref.read(automationSettingsStoreProvider).setupProgress();
    if (!mounted) return;
    setState(() {
      _progress = progress;
      if (widget.initialStep == null) _step = progress.nextStepIndex;
    });
    await _loadAll();
  }

  Future<void> _loadAll() async {
    await Future.wait([
      _loadService(),
      _loadTarget(),
      _loadSources(),
      _loadBackground(),
    ]);
    if (_step == 4) await _snapshotCapture();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadService() async {
    var aiText = false;
    var aiVision = false;
    try {
      aiText = await _aiConfigured(true);
      aiVision = await _aiConfigured(false);
    } catch (_) {}
    var loggedIn = false;
    try {
      final cfg = await ref.read(activeCloudConfigProvider.future);
      loggedIn = cfg.valid && cfg.type != CloudBackendType.local;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _aiTextReady = aiText;
      _aiVisionReady = aiVision;
      _aiState = AiRuntimeCoordinator.instance.state;
      _loggedIn = loggedIn;
    });
  }

  Future<bool> _aiConfigured(bool text) async {
    // 与设置页同一判定入口(AIProviderManager),避免两处口径不一致。
    try {
      return await AIProviderManager.isCapabilityConfigured(
          text ? AICapabilityType.text : AICapabilityType.vision);
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadTarget() async {
    final repo = ref.read(repositoryProvider);
    final ledgers = await repo.getAllLedgers();
    var chosen = _targetLedgerId;
    if (chosen == null && ledgers.isNotEmpty) chosen = ledgers.first.id;
    var accounts = const <schema.Account>[];
    if (chosen != null) {
      try {
        accounts = await repo.getAvailableAccountsForLedger(chosen);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _ledgers = ledgers;
      _targetLedgerId = chosen;
      _accounts = accounts;
    });
  }

  Future<void> _loadSources() async {
    if (!Platform.isAndroid) return;
    final container = ProviderScope.containerOf(context);
    final notify = NotifyMonitorService(container);
    final sms = SmsMonitorService(container);
    final screen = ScreenTextMonitorService(container);
    final shot = ScreenshotMonitorService(container);
    final values = await Future.wait([
      _safe(notify.isEnabled),
      _safe(sms.isEnabled),
      _safe(screen.isEnabled),
      _safe(shot.isEnabled),
      _safe(notify.isListenerGranted),
      _safe(() async => (await Permission.sms.status).isGranted),
      _safe(screen.isAccessibilityGranted),
    ]);
    if (!mounted) return;
    setState(() {
      _notifyOn = values[0] ?? false;
      _smsOn = values[1] ?? false;
      _screenOn = values[2] ?? false;
      _shotOn = values[3] ?? false;
      _notifyGranted = values[4] ?? false;
      _smsGranted = values[5] ?? false;
      _screenGranted = values[6] ?? false;
    });
    _syncSourcesToProgress();
  }

  Future<T?> _safe<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadBackground() async {
    bool? ignored;
    try {
      final util = NotificationFactory.getInstance() as AndroidNotificationUtil;
      final info = await util.getBatteryOptimizationInfo();
      ignored = info['isIgnoring'] == true;
    } catch (_) {
      ignored = null;
    }
    if (!mounted) return;
    setState(() => _batteryIgnored = ignored);
  }

  /// 已开启的来源集合写回进度(第 3 步「来源按需授权」的完成判定)。
  Future<void> _syncSourcesToProgress() async {
    final enabled = <String>{
      if (_notifyOn) 'notify',
      if (_smsOn) 'sms',
      if (_screenOn) 'screenText',
      if (_shotOn) 'screenshot',
    };
    if (enabled.length == _progress.sources.length &&
        enabled.containsAll(_progress.sources)) {
      return;
    }
    await _updateProgress((p) => p.copyWith(sources: enabled));
  }

  Future<void> _updateProgress(
    AutoBookSetupProgress Function(AutoBookSetupProgress) transform,
  ) async {
    final store = ref.read(automationSettingsStoreProvider);
    final next = await store.updateSetup(transform);
    if (!mounted) return;
    setState(() => _progress = next);
  }

  Future<void> _snapshotCapture() async {
    final stats = await NativeCaptureStatus.query();
    var queue = 0;
    var last = 0;
    if (stats != null) {
      for (final entry in stats.entries) {
        queue += entry.value['queueSize'] is int
            ? entry.value['queueSize'] as int
            : 0;
        final ms = entry.value['lastCaptureAt'];
        final v = ms is int ? ms : (ms is num ? ms.toInt() : 0);
        if (v > last) last = v;
      }
    }
    if (!mounted) return;
    setState(() {
      _baselineCaptureAt = last;
      _baselineQueue = queue;
    });
  }

  // ───────────────────────────── UI ─────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      body: Column(
        children: [
          PrimaryHeader(
            title: l10n.autoSetupTitle,
            subtitle: l10n.autoSetupSubtitle,
            showBack: true,
          ),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else ...[
            _stepIndicator(l10n),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  switch (_step) {
                    0 => _buildServiceStep(l10n),
                    1 => _buildTargetStep(l10n),
                    2 => _buildSourcesStep(l10n),
                    3 => _buildBackgroundStep(l10n),
                    _ => _buildVerifyStep(l10n),
                  }
                ],
              ),
            ),
            _bottomBar(l10n),
          ],
        ],
      ),
    );
  }

  Widget _stepIndicator(AppLocalizations l10n) {
    final labels = [
      l10n.autoSetupStepService,
      l10n.autoSetupStepTarget,
      l10n.autoSetupStepSources,
      l10n.autoSetupStepBackground,
      l10n.autoSetupStepVerify,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var i = 0; i < _stepCount; i++) ...[
                if (i > 0)
                  Expanded(
                    child: Container(
                      height: 2,
                      color: i <= _step
                          ? Theme.of(context).colorScheme.primary
                          : BeeTokens.border(context),
                    ),
                  ),
                InkWell(
                  onTap: i <= _step ? () => setState(() => _step = i) : null,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < _step
                          ? Colors.green
                          : i == _step
                              ? Theme.of(context).colorScheme.primary
                              : BeeTokens.surfaceChip(context),
                    ),
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: i <= _step
                            ? Colors.white
                            : BeeTokens.textTertiary(context),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            labels[_step.clamp(0, labels.length - 1)],
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: BeeTokens.textSecondary(context),
                ),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(AppLocalizations l10n) {
    final canFinish = _progress.completed;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          children: [
            if (_step > 0)
              OutlinedButton(
                onPressed: _saving ? null : () => setState(() => _step -= 1),
                child: Text(l10n.autoSetupBack),
              ),
            const Spacer(),
            FilledButton(
              onPressed: _saving
                  ? null
                  : () async {
                      if (_step < _stepCount - 1) {
                        await _completeStep(_step);
                        if (!mounted) return;
                        setState(() => _step += 1);
                        if (_step == 4) await _snapshotCapture();
                      } else {
                        await _finish(l10n);
                      }
                    },
              child: Text(
                _step < _stepCount - 1
                    ? l10n.autoSetupNext
                    : (canFinish ? l10n.autoSetupFinish : l10n.autoSetupNext),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _completeStep(int step) async {
    switch (step) {
      case 0:
        await _updateProgress((p) => p.copyWith(serviceChecked: true));
      case 1:
        await _saveTarget();
      case 2:
        await _syncSourcesToProgress();
      case 3:
        await _updateProgress((p) => p.copyWith(backgroundChecked: true));
      default:
        break;
    }
  }

  Future<void> _finish(AppLocalizations l10n) async {
    if (!_progress.completed) {
      // 未验证时不能直接宣称完成:引导用户补验或显式跳过。
      if (!_progress.verified && !_progress.verifySkipped) {
        await _updateProgress((p) => p.copyWith(verifySkipped: true));
      }
    }
    // B5 任务 1:完成开通的新用户默认「仅需确认或故障时提醒」;
    // 升级用户(没走引导)保持配置缺失 → 旧行为。
    try {
      final store = ref.read(automationSettingsStoreProvider);
      final settings = await store.load();
      if (settings.notifyMode == null) {
        await store.bumpVersion(settings.copyWith(
            notifyMode: AutoBookNotifyMode.confirmAndFault.storageValue));
      }
    } catch (_) {}
    if (!mounted) return;
    showToast(context, l10n.autoSetupCompletedTitle);
    Navigator.of(context).pop(true);
  }

  // ── 步骤 0:连接服务与检查 AI ──
  Widget _buildServiceStep(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.autoSetupServiceDesc,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: BeeTokens.textSecondary(context))),
        const SizedBox(height: 12),
        _statusCard(
          icon: Icons.cloud_outlined,
          ok: _loggedIn,
          title: l10n.autoSetupServiceTitle,
          okText: l10n.autoSetupLoginOk,
          badText: l10n.autoSetupLoginMissing,
          action: _loggedIn
              ? null
              : TextButton(
                  onPressed: _loadService, child: Text(l10n.autoSetupRecheck)),
        ),
        _statusCard(
          icon: Icons.auto_awesome_outlined,
          ok: _aiTextReady &&
              _aiVisionReady &&
              _aiState == AiRuntimeState.ready,
          okText: l10n.autoSetupAiOk,
          badText: _aiStateLabel(l10n),
          title: l10n.autoSetupAiTitle,
          action: TextButton(
              onPressed: _loadService, child: Text(l10n.autoSetupRecheck)),
          children: [
            _tag(l10n.autoSetupAiText(_aiTextReady
                ? l10n.autoSetupConfigured
                : l10n.autoSetupNotConfigured)),
            _tag(l10n.autoSetupAiVision(_aiVisionReady
                ? l10n.autoSetupConfigured
                : l10n.autoSetupNotConfigured)),
          ],
        ),
        const SizedBox(height: 8),
        Text(l10n.autoSetupPaused, style: theme.textTheme.bodySmall),
      ],
    );
  }

  String _aiStateLabel(AppLocalizations l10n) => switch (_aiState) {
        AiRuntimeState.ready => l10n.autoHealthAiInitializing,
        AiRuntimeState.unconfigured => l10n.autoHealthAiUnconfigured,
        AiRuntimeState.offline => l10n.autoHealthAiOffline,
        AiRuntimeState.authenticationRequired => l10n.autoHealthAiLoginRequired,
        AiRuntimeState.providerError => l10n.autoHealthAiProviderError,
        AiRuntimeState.initializing => l10n.autoHealthAiInitializing,
      };

  // ── 步骤 1:自动入账目标 ──
  Widget _buildTargetStep(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.autoSetupTargetDesc,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: BeeTokens.textSecondary(context))),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.autoSetupTargetLedgerLabel,
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                for (final ledger in _ledgers)
                  RadioListTile<int>(
                    dense: true,
                    value: ledger.id,
                    groupValue: _targetLedgerId,
                    title: Text(ledger.name),
                    subtitle: (ledger.syncId ?? '').isEmpty
                        ? Text(l10n.autoSetupTargetLocalLedger)
                        : null,
                    onChanged: (v) async {
                      setState(() => _targetLedgerId = v);
                      final repo = ref.read(repositoryProvider);
                      final accounts = await repo
                          .getAvailableAccountsForLedger(v ?? ledger.id);
                      if (!mounted) return;
                      setState(() {
                        _accounts = accounts;
                        _targetAccountId = null;
                      });
                    },
                  ),
                if (_ledgers.isEmpty)
                  Text(l10n.autoBillingNotifyNoLedgerBody,
                      style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.autoSetupTargetAccountLabel,
                    style: theme.textTheme.titleSmall),
                RadioListTile<int>(
                  dense: true,
                  value: -1,
                  groupValue: _targetAccountId ?? -1,
                  title: Text(l10n.autoSetupTargetDefaultAccount),
                  onChanged: (_) => setState(() => _targetAccountId = null),
                ),
                for (final account in _accounts)
                  RadioListTile<int>(
                    dense: true,
                    value: account.id,
                    groupValue: _targetAccountId,
                    title: Text(account.name),
                    onChanged: (v) => setState(() => _targetAccountId = v),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(l10n.autoSetupTargetChangeable,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: BeeTokens.textTertiary(context))),
      ],
    );
  }

  Future<void> _saveTarget() async {
    if (_targetLedgerId == null) return;
    schema.Ledger? ledger;
    for (final l in _ledgers) {
      if (l.id == _targetLedgerId) ledger = l;
    }
    if (ledger == null) return;
    final store = ref.read(automationSettingsStoreProvider);
    final settings = await store.load();
    final syncId = (ledger.syncId ?? '').isEmpty ? null : ledger.syncId;
    final target = AutoBookTarget(
      scope: await _userScope(),
      kind: syncId != null ? 'syncId' : 'localId',
      value: syncId ?? '${ledger.id}',
      accountId: _targetAccountId,
      confirmedAt: DateTime.now(),
    );
    await store.bumpVersion(settings.copyWith(target: target));
    await _updateProgress((p) => p.copyWith(targetChosen: true));
  }

  Future<String> _userScope() async {
    try {
      final auth = await ref.read(authServiceProvider.future);
      final user = await auth.currentUser;
      if (user != null && user.id.isNotEmpty) return 'user:${user.id}';
    } catch (_) {}
    return 'local';
  }

  // ── 步骤 2:来源与授权 ──
  Widget _buildSourcesStep(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.autoSetupSourcesDesc,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: BeeTokens.textSecondary(context))),
        const SizedBox(height: 12),
        Text(l10n.autoSetupSourcesPrimary, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        _sourceCard(
          l10n: l10n,
          icon: Icons.notifications_active_outlined,
          title: l10n.autoBillingNotifyTitle,
          enabled: _notifyOn,
          permissionOk: _notifyGranted,
          permissionMissingText: l10n.autoBillingNotifyPermissionMissing,
          onChanged: _toggleNotify,
        ),
        const SizedBox(height: 8),
        _sourceCard(
          l10n: l10n,
          icon: Icons.sms_outlined,
          title: l10n.autoSmsBillingTitle,
          enabled: _smsOn,
          permissionOk: _smsGranted,
          permissionMissingText: l10n.smsPermissionRequired,
          onChanged: _toggleSms,
        ),
        const SizedBox(height: 16),
        Text(l10n.autoSetupSourcesOptional, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        _sourceCard(
          l10n: l10n,
          icon: Icons.pageview_outlined,
          title: l10n.autoBillingScreenTextTitle,
          enabled: _screenOn,
          permissionOk: _screenGranted,
          permissionMissingText: l10n.autoBillingScreenTextPermissionMissing,
          onChanged: _toggleScreen,
        ),
        const SizedBox(height: 8),
        _sourceCard(
          l10n: l10n,
          icon: Icons.photo_camera_outlined,
          title: l10n.autoScreenshotBillingTitle,
          enabled: _shotOn,
          permissionOk: true,
          permissionMissingText: '',
          onChanged: _toggleScreenshot,
        ),
        const SizedBox(height: 8),
        Text(l10n.autoSetupSourcesAtLeastOne, style: theme.textTheme.bodySmall),
      ],
    );
  }

  Widget _sourceCard({
    required AppLocalizations l10n,
    required IconData icon,
    required String title,
    required bool enabled,
    required bool permissionOk,
    required String permissionMissingText,
    required Future<void> Function(bool) onChanged,
  }) {
    final theme = Theme.of(context);
    final status = enabled
        ? l10n.autoSetupSourceOn
        : (permissionOk ? l10n.autoSetupSourceOff : permissionMissingText);
    return Card(
      child: SwitchListTile(
        secondary: Icon(icon, color: enabled ? Colors.green : null),
        title: Text(title),
        subtitle: Text(
          status,
          style: theme.textTheme.bodySmall?.copyWith(
            color: enabled
                ? Colors.green
                : (permissionOk
                    ? BeeTokens.textSecondary(context)
                    : Colors.orange),
          ),
        ),
        value: enabled,
        onChanged: _saving ? null : onChanged,
      ),
    );
  }

  // 权限解释在用户开启对应来源时显示,不一次性索取全部权限。
  Future<void> _explainThen(
    String title,
    String content, {
    required Future<void> Function() onConfirm,
  }) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonSettings),
          ),
        ],
      ),
    );
    if (ok == true) await onConfirm();
  }

  Future<void> _toggleNotify(bool value) async {
    final l10n = AppLocalizations.of(context);
    final monitor = NotifyMonitorService(ProviderScope.containerOf(context));
    if (value) {
      if (!await monitor.isListenerGranted()) {
        await _explainThen(
          l10n.autoBillingNotifyPermissionTitle,
          l10n.autoBillingNotifyPermissionContent,
          onConfirm: monitor.openListenerSettings,
        );
        await _loadSources();
        return;
      }
      await _safe(() => monitor.enable());
    } else {
      await _safe(() => monitor.disable());
    }
    await _loadSources();
  }

  Future<void> _toggleSms(bool value) async {
    final l10n = AppLocalizations.of(context);
    final monitor = SmsMonitorService(ProviderScope.containerOf(context));
    if (value) {
      final status = await Permission.sms.request();
      if (!status.isGranted) {
        if (mounted) showToast(context, l10n.smsPermissionRequired);
        await _loadSources();
        return;
      }
      await _safe(() => monitor.enable());
    } else {
      await _safe(() => monitor.disable());
    }
    await _loadSources();
  }

  Future<void> _toggleScreen(bool value) async {
    final l10n = AppLocalizations.of(context);
    final monitor =
        ScreenTextMonitorService(ProviderScope.containerOf(context));
    if (value) {
      if (!await monitor.isAccessibilityGranted()) {
        final isVivo = (await _safe(monitor.isVivoDevice)) ?? false;
        await _explainThen(
          l10n.autoBillingScreenTextPermissionTitle,
          isVivo
              ? '${l10n.autoBillingScreenTextPermissionContent}\n\n${l10n.autoBillingScreenTextVivoHint}'
              : l10n.autoBillingScreenTextPermissionContent,
          onConfirm: monitor.openAccessibilitySettings,
        );
        await _loadSources();
        return;
      }
      await _safe(() => monitor.enable());
    } else {
      await _safe(() => monitor.disable());
    }
    await _loadSources();
  }

  Future<void> _toggleScreenshot(bool value) async {
    final monitor =
        ScreenshotMonitorService(ProviderScope.containerOf(context));
    if (value) {
      await _safe(() => monitor.enable());
    } else {
      await _safe(() => monitor.disable());
    }
    await _loadSources();
  }

  // ── 步骤 3:后台运行 ──
  Widget _buildBackgroundStep(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final ok = _batteryIgnored == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.autoSetupBackgroundDesc,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: BeeTokens.textSecondary(context))),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: Icon(
              ok ? Icons.check_circle : Icons.battery_saver,
              color: ok ? Colors.green : Colors.orange,
            ),
            title: Text(l10n.autoBillingBatteryTitle),
            subtitle: Text(
              _batteryIgnored == null
                  ? l10n.autoHealthDimUnknown
                  : (ok
                      ? l10n.reminderBatteryIgnored
                      : l10n.reminderBatteryNotIgnored),
            ),
            trailing: ok
                ? null
                : FilledButton.tonal(
                    onPressed: () async {
                      final util = NotificationFactory.getInstance()
                          as AndroidNotificationUtil;
                      await _safe(util.requestIgnoreBatteryOptimizations);
                      await _loadBackground();
                    },
                    child: Text(l10n.autoBillingCheckBattery),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading:
                const Icon(Icons.rocket_launch_outlined, color: Colors.orange),
            title: Text(l10n.autoStartTitle),
            subtitle: Text(l10n.autoStartDesc),
            trailing: FilledButton.tonal(
              onPressed: () async {
                final util = NotificationFactory.getInstance()
                    as AndroidNotificationUtil;
                final okOpen = await _safe(util.requestAutoStartGuide);
                if (!mounted) return;
                showToast(
                    context,
                    okOpen == true
                        ? l10n.autoStartOpened
                        : l10n.autoStartOpenFailed);
              },
              child: Text(l10n.autoStartGo),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(l10n.autoSetupBackgroundNote,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: BeeTokens.textTertiary(context))),
      ],
    );
  }

  // ── 步骤 4:真实来源验证 ──
  Widget _buildVerifyStep(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final verified = _progress.verified;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.autoSetupVerifyDesc,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: BeeTokens.textSecondary(context))),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      verified ? Icons.verified : Icons.rule,
                      color: verified ? Colors.green : Colors.orange,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        verified
                            ? l10n.autoSetupVerifyOk
                            : l10n.autoSetupVerifyPending,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
                if (_verifyMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(_verifyMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: _verifyOk ? Colors.green : Colors.orange)),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _verifyChecking
                          ? null
                          : () async {
                              setState(() => _verifyChecking = true);
                              await _snapshotCapture();
                              final stats = await NativeCaptureStatus.query();
                              var queue = 0;
                              var last = 0;
                              if (stats != null) {
                                for (final e in stats.entries) {
                                  queue += e.value['queueSize'] is int
                                      ? e.value['queueSize'] as int
                                      : 0;
                                  final raw = e.value['lastCaptureAt'];
                                  final v = raw is int
                                      ? raw
                                      : (raw is num ? raw.toInt() : 0);
                                  if (v > last) last = v;
                                }
                              }
                              final ok = last > _baselineCaptureAt ||
                                  queue > _baselineQueue;
                              if (ok) {
                                await _updateProgress((p) =>
                                    p.copyWith(verifiedAt: DateTime.now()));
                              }
                              if (!mounted) return;
                              setState(() {
                                _verifyChecking = false;
                                _verifyOk = ok;
                                _verifyMessage = ok
                                    ? l10n.autoSetupVerifyOk
                                    : l10n.autoSetupVerifyRetry;
                              });
                            },
                      icon: const Icon(Icons.search, size: 18),
                      label: Text(l10n.autoSetupVerifyAction),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () async {
                        await _updateProgress(
                            (p) => p.copyWith(verifySkipped: true));
                      },
                      child: Text(l10n.autoSetupSkipVerify),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(l10n.autoSetupVerifyNotice,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: BeeTokens.textTertiary(context))),
        if (_progress.verifySkipped) ...[
          const SizedBox(height: 4),
          Text(l10n.autoSetupVerifySkippedNote,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange)),
        ],
      ],
    );
  }

  // ── 通用 ──
  Widget _statusCard({
    required IconData icon,
    required bool ok,
    required String title,
    required String okText,
    required String badText,
    TextButton? action,
    List<Widget> children = const [],
  }) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: ok ? Colors.green : Colors.orange),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                Icon(ok ? Icons.check_circle : Icons.error_outline,
                    color: ok ? Colors.green : Colors.orange, size: 20),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              ok ? okText : badText,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: ok ? Colors.green : Colors.orange),
            ),
            if (children.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: children),
            ],
            if (action != null)
              Align(alignment: Alignment.centerLeft, child: action),
          ],
        ),
      ),
    );
  }

  Widget _tag(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: BeeTokens.surfaceChip(context),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall),
      );
}
