import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../widgets/ui/primary_header.dart';
import '../../widgets/ui/toast.dart';
import '../../providers.dart';
import '../../services/automation/dedup_exempt_store.dart';
import '../../services/platform/screenshot_monitor_service.dart';
import '../../services/platform/sms_monitor_service.dart';
import '../../services/platform/notify_monitor_service.dart';
import '../../services/platform/screen_text_monitor_service.dart';
import 'channel_account_mapping_page.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/notification_factory.dart';
import '../../utils/notification_android.dart';
import 'ios_auto_billing_page.dart';

/// 自动记账设置页面（根据平台路由）
class AutoBillingSettingsPage extends StatelessWidget {
  const AutoBillingSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) {
      return const IOSAutoBillingPage();
    } else {
      return const AndroidAutoBillingPage();
    }
  }
}

/// Android自动记账设置页面
class AndroidAutoBillingPage extends ConsumerStatefulWidget {
  const AndroidAutoBillingPage({super.key});

  @override
  ConsumerState<AndroidAutoBillingPage> createState() =>
      _AndroidAutoBillingPageState();
}

class _AndroidAutoBillingPageState extends ConsumerState<AndroidAutoBillingPage>
    with WidgetsBindingObserver {
  late final ScreenshotMonitorService _screenshotMonitor;
  late final SmsMonitorService _smsMonitor;
  late final NotifyMonitorService _notifyMonitor;
  late final ScreenTextMonitorService _screenTextMonitor;
  bool _isMonitorEnabled = false;
  bool _autoDeleteScreenshotEnabled = false;
  bool _isSmsMonitorEnabled = false;
  bool _isNotifyMonitorEnabled = false;
  bool _isNotifyListenerGranted = false;
  bool _isScreenMonitorEnabled = false;
  bool _isScreenAccessibilityGranted = false;
  bool _autoBookCheckEnabled = true;
  bool _shadowModeEnabled = false;
  bool _isBatteryOptimizationIgnored = false;
  bool _isLoading = true;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      final container = ProviderScope.containerOf(context);
      _screenshotMonitor = ScreenshotMonitorService(container);
      _smsMonitor = SmsMonitorService(container);
      _notifyMonitor = NotifyMonitorService(container);
      _screenTextMonitor = ScreenTextMonitorService(container);
      _loadMonitorStatus();
      _isInitialized = true;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 当应用从后台恢复到前台时，重新检查状态
    if (state == AppLifecycleState.resumed) {
      _loadMonitorStatus();
    }
  }

  Future<void> _loadMonitorStatus() async {
    final enabled = await _screenshotMonitor.isEnabled();
    _autoDeleteScreenshotEnabled =
        await _screenshotMonitor.isAutoDeleteEnabled();
    final smsEnabled = await _smsMonitor.isEnabled();
    final notifyEnabled = await _notifyMonitor.isEnabled();
    final notifyGranted = await _notifyMonitor.isListenerGranted();
    final screenEnabled = await _screenTextMonitor.isEnabled();
    final screenGranted = await _screenTextMonitor.isAccessibilityGranted();
    final prefs = await SharedPreferences.getInstance();
    final autoBookCheck = prefs.getBool('auto_book_enabled') ?? true;
    final shadowMode =
        await ref.read(autoBillingServiceProvider).isShadowModeEnabled();

    // 检查电池优化状态
    bool batteryOptimizationIgnored = false;
    try {
      final androidUtil =
          NotificationFactory.getInstance() as AndroidNotificationUtil;
      final batteryInfo = await androidUtil.getBatteryOptimizationInfo();
      batteryOptimizationIgnored = batteryInfo['isIgnoring'] == true;
    } catch (e) {
      print('检查电池优化状态失败: $e');
    }

    setState(() {
      _isMonitorEnabled = enabled;
      _isSmsMonitorEnabled = smsEnabled;
      _isNotifyMonitorEnabled = notifyEnabled;
      _isNotifyListenerGranted = notifyGranted;
      _isScreenMonitorEnabled = screenEnabled;
      _isScreenAccessibilityGranted = screenGranted;
      _autoBookCheckEnabled = autoBookCheck;
      _shadowModeEnabled = shadowMode;
      _isBatteryOptimizationIgnored = batteryOptimizationIgnored;
      _isLoading = false;
    });
  }

  /// 自动入账总闸(`auto_book_enabled`,P0-2 已接回):默认开=候选制
  /// (低置信/疑似重复进待确认,其余自动入账);关=所有识别结果一律先进
  /// 待确认队列,不自动入账。
  Future<void> _toggleAutoBookCheck(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_book_enabled', value);
    if (mounted) {
      setState(() {
        _autoBookCheckEnabled = value;
      });
      showToast(
          context,
          value
              ? AppLocalizations.of(context).enableSuccess
              : AppLocalizations.of(context).disableSuccess);
    }
  }

  Future<void> _toggleShadowMode(bool value) async {
    await ref.read(autoBillingServiceProvider).setShadowModeEnabled(value);
    if (!mounted) return;
    setState(() => _shadowModeEnabled = value);
    showToast(
      context,
      value ? '影子模式已开启：自动入口只识别，不创建交易' : '影子模式已关闭',
      duration: const Duration(seconds: 3),
    );
  }

  Future<void> _toggleNotifyMonitor(bool value) async {
    final l10n = AppLocalizations.of(context);

    if (value) {
      // 「通知使用权」是系统级授权,须引导用户到设置页开启
      if (!await _notifyMonitor.isListenerGranted()) {
        final granted = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.autoBillingNotifyPermissionTitle),
            content: Text(l10n.autoBillingNotifyPermissionContent),
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
        if (granted == true) {
          await _notifyMonitor.openListenerSettings();
        }
        if (!mounted) return;
        setState(() {
          _loadMonitorStatus();
        });
        return;
      }

      try {
        await _notifyMonitor.enable();
        setState(() {
          _isNotifyMonitorEnabled = true;
        });
        if (mounted) {
          showToast(context, l10n.enableSuccess);
        }
      } catch (e) {
        if (mounted) {
          showToast(context, '${l10n.enableFailed}: $e',
              duration: const Duration(seconds: 3));
        }
      }
    } else {
      try {
        await _notifyMonitor.disable();
        setState(() {
          _isNotifyMonitorEnabled = false;
        });
        if (mounted) {
          showToast(context, l10n.disableSuccess);
        }
      } catch (e) {
        if (mounted) {
          showToast(context, '${l10n.disableFailed}: $e',
              duration: const Duration(seconds: 3));
        }
      }
    }
  }

  Future<void> _toggleScreenMonitor(bool value) async {
    final l10n = AppLocalizations.of(context);

    if (value) {
      // 「无障碍」是系统级授权,须引导用户到设置页开启
      if (!await _screenTextMonitor.isAccessibilityGranted()) {
        // vivo/iQOO 的「一开就关」是 ROM 层管控(受限设置/诚信检测),
        // 需要用户走额外的 i 管家放行路径 —— 引导弹窗里带上专属自救步骤。
        final isVivo = await _screenTextMonitor.isVivoDevice();
        final granted = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.autoBillingScreenTextPermissionTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.autoBillingScreenTextPermissionContent),
                if (isVivo) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.autoBillingScreenTextVivoHint,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ],
              ],
            ),
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
        if (granted == true) {
          await _screenTextMonitor.openAccessibilitySettings();
        }
        if (!mounted) return;
        setState(() {
          _loadMonitorStatus();
        });
        return;
      }

      try {
        await _screenTextMonitor.enable();
        setState(() {
          _isScreenMonitorEnabled = true;
        });
        if (mounted) {
          showToast(context, l10n.enableSuccess);
        }
      } catch (e) {
        if (mounted) {
          showToast(context, '${l10n.enableFailed}: $e',
              duration: const Duration(seconds: 3));
        }
      }
    } else {
      try {
        await _screenTextMonitor.disable();
        setState(() {
          _isScreenMonitorEnabled = false;
        });
        if (mounted) {
          showToast(context, l10n.disableSuccess);
        }
      } catch (e) {
        if (mounted) {
          showToast(context, '${l10n.disableFailed}: $e',
              duration: const Duration(seconds: 3));
        }
      }
    }
  }

  /// 「记账成功自动删截图」:仅持久化开关,无系统权限要求;
  /// 实际删除发生在截图处理成功之后(screenshot_monitor_service)。
  Future<void> _toggleAutoDeleteScreenshot(bool value) async {
    final l10n = AppLocalizations.of(context);
    try {
      await _screenshotMonitor.setAutoDeleteEnabled(value);
      if (mounted) {
        setState(() {
          _autoDeleteScreenshotEnabled = value;
        });
        showToast(context, value ? l10n.enableSuccess : l10n.disableSuccess);
      }
    } catch (e) {
      if (mounted) {
        showToast(context, '${l10n.enableFailed}: $e',
            duration: const Duration(seconds: 3));
      }
    }
  }

  Future<void> _toggleSmsMonitor(bool value) async {
    final l10n = AppLocalizations.of(context);

    if (value) {
      // 短信权限:`RECEIVE_SMS` 为运行时权限(API 23+),先请求再启用
      final status = await Permission.sms.request();
      if (!status.isGranted) {
        if (mounted) {
          showToast(context, l10n.smsPermissionRequired);
        }
        return;
      }

      try {
        await _smsMonitor.enable();
        setState(() {
          _isSmsMonitorEnabled = true;
        });
        if (mounted) {
          showToast(context, l10n.enableSuccess);
        }
      } catch (e) {
        if (mounted) {
          showToast(context, '${l10n.enableFailed}: $e',
              duration: const Duration(seconds: 3));
        }
      }
    } else {
      try {
        await _smsMonitor.disable();
        setState(() {
          _isSmsMonitorEnabled = false;
        });
        if (mounted) {
          showToast(context, l10n.disableSuccess);
        }
      } catch (e) {
        if (mounted) {
          showToast(context, '${l10n.disableFailed}: $e',
              duration: const Duration(seconds: 3));
        }
      }
    }
  }

  Future<void> _toggleMonitor(bool value) async {
    final l10n = AppLocalizations.of(context);

    if (value) {
      // 请求存储权限（适用于所有Android设备包括华为）
      print('📸 [AutoBilling] 准备请求存储权限');
      PermissionStatus status;

      // Android 13+ 使用 photos，Android 13以下使用 storage
      if (await Permission.photos.isRestricted ||
          await Permission.photos.isPermanentlyDenied) {
        // 如果photos权限受限，尝试使用storage
        status = await Permission.storage.request();
        print('📸 [AutoBilling] 存储权限请求结果: $status');
      } else {
        // 尝试photos权限
        status = await Permission.photos.request();
        print('📸 [AutoBilling] 照片权限请求结果: $status');

        // Android 13/14「仅允许选中的照片」(limited):MediaStore 查询看不到
        // 未选中的新截图,截图自动记账必须「允许所有照片」——引导去系统设置
        // 改授权,而不是误以为已开通(2026-09-10 真机定位:onChange 仍通知,
        // 查询游标为空,检测链路静默失效)。
        if (status == PermissionStatus.limited) {
          if (mounted) {
            showToast(context, l10n.photosPermissionLimitedHint,
                duration: const Duration(seconds: 4));
            await openAppSettings();
          }
          return;
        }

        // 如果photos被拒绝，尝试storage
        if (!status.isGranted) {
          status = await Permission.storage.request();
          print('📸 [AutoBilling] 存储权限请求结果: $status');
        }
      }

      if (!status.isGranted) {
        if (mounted) {
          showToast(context, l10n.photosPermissionRequired);
        }
        return;
      }

      try {
        print('📸 [AutoBilling] 开始启用截图监听');
        await _screenshotMonitor.enable();
        print('📸 [AutoBilling] 截图监听启用完成');
        setState(() {
          _isMonitorEnabled = true;
        });
        if (mounted) {
          showToast(context, l10n.enableSuccess);
        }
      } catch (e) {
        if (mounted) {
          showToast(context, '${l10n.enableFailed}: $e',
              duration: const Duration(seconds: 3));
        }
      }
    } else {
      try {
        await _screenshotMonitor.disable();
        setState(() {
          _isMonitorEnabled = false;
        });
        if (mounted) {
          showToast(context, l10n.disableSuccess);
        }
      } catch (e) {
        if (mounted) {
          showToast(context, '${l10n.disableFailed}: $e',
              duration: const Duration(seconds: 3));
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _screenshotMonitor.dispose();
    _smsMonitor.dispose();
    _notifyMonitor.dispose();
    _screenTextMonitor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = ref.watch(primaryColorProvider);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Column(
        children: [
          PrimaryHeader(
            title: l10n.autoBilling,
            showBack: true,
            leadingIcon: Icons.auto_fix_high,
            leadingPlain: true,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 开关卡片
                _buildSwitchCard(
                  context,
                  primaryColor,
                  l10n,
                  icon: Icons.auto_awesome,
                  title: l10n.autoBilling,
                  subtitle: _isMonitorEnabled ? l10n.enabled : l10n.disabled,
                  value: _isMonitorEnabled,
                  onChanged: _isLoading ? null : _toggleMonitor,
                ),

                const SizedBox(height: 16),

                // 记账成功自动删截图(「自动记账」的附属设置)
                _buildSwitchCard(
                  context,
                  primaryColor,
                  l10n,
                  icon: Icons.delete_outline,
                  title: l10n.autoDeleteScreenshotTitle,
                  subtitle: l10n.autoDeleteScreenshotDesc,
                  value: _autoDeleteScreenshotEnabled,
                  onChanged: _isLoading ? null : _toggleAutoDeleteScreenshot,
                ),

                const SizedBox(height: 16),

                // 短信自动记账开关卡片
                _buildSwitchCard(
                  context,
                  primaryColor,
                  l10n,
                  icon: Icons.sms_outlined,
                  title: l10n.autoSmsBillingTitle,
                  subtitle: _isSmsMonitorEnabled
                      ? l10n.autoSmsBillingDescEnabled
                      : l10n.autoSmsBillingDesc,
                  value: _isSmsMonitorEnabled,
                  onChanged: _isLoading ? null : _toggleSmsMonitor,
                ),

                const SizedBox(height: 16),

                // 通知自动记账开关卡片
                _buildSwitchCard(
                  context,
                  primaryColor,
                  l10n,
                  icon: Icons.notifications_active_outlined,
                  title: l10n.autoBillingNotifyTitle,
                  subtitle: _isNotifyMonitorEnabled
                      ? l10n.autoBillingNotifyDescEnabled
                      : (_isNotifyListenerGranted
                          ? l10n.autoBillingNotifyDesc
                          : l10n.autoBillingNotifyPermissionMissing),
                  value: _isNotifyMonitorEnabled,
                  onChanged: _isLoading ? null : _toggleNotifyMonitor,
                ),

                const SizedBox(height: 16),

                // 详情页自动记账开关卡片(无障碍)
                _buildSwitchCard(
                  context,
                  primaryColor,
                  l10n,
                  icon: Icons.pageview_outlined,
                  title: l10n.autoBillingScreenTextTitle,
                  subtitle: _isScreenMonitorEnabled
                      ? l10n.autoBillingScreenTextDescEnabled
                      : (_isScreenAccessibilityGranted
                          ? l10n.autoBillingScreenTextDesc
                          : l10n.autoBillingScreenTextPermissionMissing),
                  value: _isScreenMonitorEnabled,
                  onChanged: _isLoading ? null : _toggleScreenMonitor,
                ),

                const SizedBox(height: 16),

                // 自动入账总闸(P0-2 已接回):开=候选制;关=全部需手动确认
                _buildSwitchCard(
                  context,
                  primaryColor,
                  l10n,
                  icon: Icons.fact_check_outlined,
                  title: l10n.autoBookCheckTitle,
                  subtitle: _autoBookCheckEnabled
                      ? l10n.autoBookCheckDesc
                      : l10n.autoBookCheckDisabledDesc,
                  value: _autoBookCheckEnabled,
                  onChanged: _isLoading ? null : _toggleAutoBookCheck,
                ),

                const SizedBox(height: 16),

                // 影子/演练模式：用于新规则观察期，只识别并写入摘要，不写交易。
                _buildSwitchCard(
                  context,
                  primaryColor,
                  l10n,
                  icon: Icons.visibility_outlined,
                  title: '影子/演练模式',
                  subtitle: _shadowModeEnabled
                      ? '自动入口只识别和记录摘要，不创建交易或候选'
                      : '关闭：自动入口按正常策略处理',
                  value: _shadowModeEnabled,
                  onChanged: _isLoading ? null : _toggleShadowMode,
                ),

                const SizedBox(height: 16),

                // 渠道→账户映射入口(M4)
                _buildChannelMappingCard(context, primaryColor, l10n),

                const SizedBox(height: 16),

                // 判重豁免(P1-1):「仍记一笔」落下的规则,可查看/清除
                _buildDedupExemptCard(context, primaryColor, l10n),

                const SizedBox(height: 16),

                // 手动模拟测试:验证 AI 记账链路(不依赖真实短信/通知)
                _buildMockCard(context, primaryColor, l10n),

                const SizedBox(height: 16),

                // 电池优化状态卡片
                _buildBatteryOptimizationStatusCard(
                    context, primaryColor, l10n),

                const SizedBox(height: 16),

                // 自启动/后台保活引导(M4)
                _buildAutoStartCard(context, primaryColor, l10n),

                const SizedBox(height: 16),

                // 电池优化设置引导卡片
                _buildBatteryOptimizationCard(context, primaryColor, l10n),

                const SizedBox(height: 16),

                // 功能说明卡片(置后:功能开关优先展示,说明性内容放最后)
                _buildInfoCard(
                  context,
                  primaryColor,
                  l10n,
                  icon: Icons.info_outline,
                  title: l10n.featureDescription,
                  content: l10n.featureDescriptionContent,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard(
    BuildContext context,
    Color primaryColor,
    AppLocalizations l10n, {
    required IconData icon,
    required String title,
    required String content,
  }) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: primaryColor, size: 24),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              content,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSwitchCard(
    BuildContext context,
    Color primaryColor,
    AppLocalizations l10n, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required void Function(bool)? onChanged,
  }) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: primaryColor, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: value
                          ? primaryColor
                          : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }

  /// 渠道→账户映射入口(M4):短信/通知来源 → 自动记账账户。
  Widget _buildChannelMappingCard(
      BuildContext context, Color primaryColor, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: Icon(Icons.swap_horiz, color: primaryColor),
        title: Text(l10n.channelMappingTitle),
        subtitle: Text(l10n.channelMappingDesc),
        trailing: Icon(Icons.chevron_right,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            size: 20),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
                builder: (_) => const ChannelAccountMappingPage()),
          );
        },
      ),
    );
  }

  /// 判重豁免卡(P1-1):展示用户「仍记一笔」落下的豁免规则,支持清空。
  Widget _buildDedupExemptCard(
      BuildContext context, Color primaryColor, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: Icon(Icons.rule_outlined, color: primaryColor),
        title: Text(l10n.dedupExemptTitle),
        subtitle: Text(l10n.dedupExemptDesc),
        trailing: Icon(Icons.chevron_right,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            size: 20),
        onTap: () => _showDedupExemptDialog(l10n),
      ),
    );
  }

  Future<void> _showDedupExemptDialog(AppLocalizations l10n) async {
    final theme = Theme.of(context);
    final rules = await DedupExemptStore().list();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.dedupExemptTitle),
        content: SizedBox(
          width: double.maxFinite,
          child: rules.isEmpty
              ? Text(l10n.dedupExemptEmpty)
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final r in rules)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.block, size: 18),
                        title: Text(r.keyword,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '¥${r.amount.toStringAsFixed(2)} ±10%',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          if (rules.isNotEmpty)
            TextButton(
              onPressed: () async {
                await DedupExemptStore().clear();
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: Text(l10n.dedupExemptClear),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
  }

  /// 自启动/后台保活引导卡(M4):vivo/OriginOS 等厂商需手动允许自启动、
  /// 关闭后台高耗电限制。按钮尽力跳厂商「自启动管理」页,失败兜底应用详情页。
  Widget _buildAutoStartCard(
      BuildContext context, Color primaryColor, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Card(
      color: primaryColor.withValues(alpha: 0.05),
      child: ListTile(
        leading: const Icon(Icons.rocket_launch_outlined, color: Colors.orange),
        title: Text(l10n.autoStartTitle),
        subtitle: Text(l10n.autoStartDesc),
        trailing: FilledButton.tonal(
          onPressed: () async {
            final androidUtil =
                NotificationFactory.getInstance() as AndroidNotificationUtil;
            final ok = await androidUtil.requestAutoStartGuide();
            if (mounted) {
              showToast(context,
                  ok ? l10n.autoStartOpened : l10n.autoStartOpenFailed);
            }
          },
          child: Text(l10n.autoStartGo),
        ),
      ),
    );
  }

  /// 手动模拟测试卡片:短信/通知两条链路各自可注入模拟数据,
  /// 直接走完整 AI 提取 → 落库流程,验证「自动记账是否正常」。
  Widget _buildMockCard(
      BuildContext context, Color primaryColor, AppLocalizations l10n) {
    final theme = Theme.of(context);

    return Card(
      color: primaryColor.withValues(alpha: 0.05),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.science_outlined, color: primaryColor, size: 24),
                const SizedBox(width: 8),
                Text(
                  l10n.autoBillingMockTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l10n.autoBillingMockDesc,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _sendMockSms(l10n),
                    icon: const Icon(Icons.sms_outlined, size: 18),
                    label: Text(l10n.autoBillingMockSms),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _sendMockNotify(l10n),
                    icon: const Icon(Icons.notifications_active_outlined,
                        size: 18),
                    label: Text(l10n.autoBillingMockNotify),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _sendMockScreen(l10n),
                    icon: const Icon(Icons.pageview_outlined, size: 18),
                    label: Text(l10n.autoBillingMockScreen),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${l10n.autoBillingMockNotice}: ${l10n.autoSmsBillingDesc}\n${l10n.autoBillingNotifyDescEnabled}\n${l10n.autoBillingScreenTextDescEnabled}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 模拟短信:模板选择(测试数据为中文银行样文,仅用于验证链路)/ 自定义
  Future<void> _sendMockSms(AppLocalizations l10n) async {
    const templates = <(String, String)>[
      (
        '银行消费短信',
        '您尾号1234的储蓄卡账户于03月28日14时32分消费人民币(卡内)45.00元,当前余额1,234.56元,商户:星巴克咖啡'
      ),
      ('转账入账短信', '【招商银行】您尾号5678账户收到转账500.00元,余额5,500.00元'),
      ('验证码垃圾短信', '您正在登录招商银行APP,验证码123456,请勿泄露'),
    ];
    final body = await _pickMockBody(l10n, templates);
    if (body == null) return;
    try {
      await _smsMonitor.mockSms(body);
      if (mounted) showToast(context, l10n.autoBillingMockSubmitted);
    } catch (e) {
      if (mounted) {
        showToast(context, '${l10n.enableFailed}: $e',
            duration: const Duration(seconds: 3));
      }
    }
  }

  /// 模拟通知:模板 / 自定义(通知监听未授权时也能模拟 —— 链路验证与
  /// 系统授权是两回事)
  Future<void> _sendMockNotify(AppLocalizations l10n) async {
    const templates = <(String, String, String)>[
      ('微信支付', '已支付45.00元 商家:星巴克咖啡(万通中心店)', '微信支付'),
      ('支付宝', '你已支付 30.00 元 给美团外卖', '支付宝'),
      ('银行消费提醒', '您信用卡于14:32消费35.00元,账单将按期发送', '中国建设银行'),
    ];
    final body = await _pickMockNotifyBody(l10n, templates);
    if (body == null) return;
    try {
      await _notifyMonitor.mockNotification(body.$1, body.$2);
      if (mounted) showToast(context, l10n.autoBillingMockSubmitted);
    } catch (e) {
      if (mounted) {
        showToast(context, '${l10n.enableFailed}: $e',
            duration: const Duration(seconds: 3));
      }
    }
  }

  /// 模拟屏幕文本:模板(详情页文本样例)/ 自定义 —— 无障碍未授权也能模拟,
  /// 直接走完整 AI 提取 → 落库流程验证链路。
  Future<void> _sendMockScreen(AppLocalizations l10n) async {
    const templates = <(String, String, String)>[
      (
        '支付宝账单详情',
        '账单详情\n交易时间:2026-09-03 12:00\n支付金额:30.00元\n对方:美团外卖\n商品:午餐',
        'eg.android.AlipayGphone'
      ),
      (
        '京东订单详情',
        '订单详情\n订单编号:1234567890\n实付金额:¥ 245.00\n商品:小米充电宝\n交易时间:2026-09-03 18:20',
        'com.jingdong.app.mall'
      ),
      (
        '抖音支付成功',
        '支付成功\n已支付 ¥ 19.90\n商品:抖音商城\n订单编号:9876543210',
        'com.ss.android.ugc.aweme'
      ),
    ];
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.autoBillingMockScreen),
        children: [
          ...templates.map((t) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, (t.$3, t.$2)),
                child: Text('${t.$1}\n${t.$2}',
                    maxLines: 3, overflow: TextOverflow.ellipsis),
              )),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ('__custom__', '__custom__')),
            child: Text(l10n.autoBillingMockCustom),
          ),
        ],
      ),
    );
    if (result == null) return;
    final (pkg, text) = result;
    final realText = pkg == '__custom__' ? await _promptCustom(l10n) : text;
    if (realText == null) return;
    try {
      await _screenTextMonitor.mockScreenText(
          pkg == '__custom__' ? 'eg.android.AlipayGphone' : pkg, realText);
      if (mounted) showToast(context, l10n.autoBillingMockSubmitted);
    } catch (e) {
      if (mounted) {
        showToast(context, '${l10n.enableFailed}: $e',
            duration: const Duration(seconds: 3));
      }
    }
  }

  Future<String?> _pickMockBody(
      AppLocalizations l10n, List<(String, String)> templates) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.autoBillingMockSms),
        children: [
          ...templates.map((t) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, t.$2),
                child: Text('${t.$1}\n${t.$2}',
                    maxLines: 3, overflow: TextOverflow.ellipsis),
              )),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '__custom__'),
            child: Text(l10n.autoBillingMockCustom),
          ),
        ],
      ),
    );
    if (result == null) return null;
    if (result != '__custom__') {
      return result;
    }
    return _promptCustom(l10n);
  }

  Future<(String, String)?> _pickMockNotifyBody(
      AppLocalizations l10n, List<(String, String, String)> templates) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.autoBillingMockNotify),
        children: [
          ...templates.map((t) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, (t.$3, t.$2)),
                child: Text('${t.$1}\n${t.$2}',
                    maxLines: 3, overflow: TextOverflow.ellipsis),
              )),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ('__custom__', '__custom__')),
            child: Text(l10n.autoBillingMockCustom),
          ),
        ],
      ),
    );
    if (result == null) return null;
    if (result.$1 != '__custom__') {
      return result;
    }
    final text = await _promptCustom(l10n);
    if (text == null) return null;
    return (l10n.autoBillingMockNotify, text);
  }

  Future<String?> _promptCustom(AppLocalizations l10n) async {
    final controller = TextEditingController();
    final body = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.autoBillingMockCustom),
        content: TextField(
          controller: controller,
          maxLines: 3,
          autofocus: true,
          decoration: const InputDecoration(hintText: '¥ 45.00 ...'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () {
              final v = controller.text.trim();
              Navigator.pop(ctx, v.isEmpty ? null : v);
            },
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
    controller.dispose();
    return body;
  }

  Widget _buildBatteryOptimizationStatusCard(
      BuildContext context, Color primaryColor, AppLocalizations l10n) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: (_isBatteryOptimizationIgnored
                        ? Colors.green
                        : Colors.orange)
                    .withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _isBatteryOptimizationIgnored
                    ? Icons.check_circle
                    : Icons.battery_saver,
                color: _isBatteryOptimizationIgnored
                    ? Colors.green
                    : Colors.orange,
                size: 28,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.autoBillingBatteryTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _isBatteryOptimizationIgnored
                        ? l10n.reminderBatteryIgnored
                        : l10n.reminderBatteryNotIgnored,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _isBatteryOptimizationIgnored
                          ? Colors.green
                          : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              _isBatteryOptimizationIgnored ? Icons.check : Icons.warning_amber,
              color:
                  _isBatteryOptimizationIgnored ? Colors.green : Colors.orange,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatteryOptimizationCard(
      BuildContext context, Color primaryColor, AppLocalizations l10n) {
    final theme = Theme.of(context);

    return Card(
      color: primaryColor.withValues(alpha: 0.05),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.battery_charging_full,
                    color: primaryColor, size: 24),
                const SizedBox(width: 8),
                Text(
                  l10n.autoBillingBatteryGuideTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              l10n.autoBillingBatteryDesc,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  final androidUtil = NotificationFactory.getInstance()
                      as AndroidNotificationUtil;
                  final batteryInfo =
                      await androidUtil.getBatteryOptimizationInfo();
                  if (mounted && context.mounted) {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(l10n.reminderBatteryStatus),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l10n.reminderManufacturer(
                                batteryInfo['manufacturer'] ?? 'Unknown')),
                            Text(l10n.reminderModel(
                                batteryInfo['model'] ?? 'Unknown')),
                            Text(l10n.reminderAndroidVersion(
                                batteryInfo['androidVersion'] ?? 'Unknown')),
                            const SizedBox(height: 8),
                            Text(
                              (batteryInfo['isIgnoring'] == true)
                                  ? l10n.reminderBatteryIgnored
                                  : l10n.reminderBatteryNotIgnored,
                              style: TextStyle(
                                color: (batteryInfo['isIgnoring'] == true)
                                    ? Colors.green
                                    : Colors.orange,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (batteryInfo['isIgnoring'] != true) ...[
                              const SizedBox(height: 8),
                              Text(
                                l10n.autoBillingBatteryWarning,
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.red),
                              ),
                            ],
                          ],
                        ),
                        actions: [
                          if (batteryInfo['isIgnoring'] != true &&
                              batteryInfo['canRequest'] == true)
                            TextButton(
                              onPressed: () async {
                                Navigator.of(context).pop();
                                final androidUtil =
                                    NotificationFactory.getInstance()
                                        as AndroidNotificationUtil;
                                await androidUtil
                                    .requestIgnoreBatteryOptimizations();
                                // 重新加载状态
                                _loadMonitorStatus();
                              },
                              child: Text(l10n.commonSettings),
                            ),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text(l10n.commonConfirm),
                          ),
                        ],
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.settings),
                label: Text(l10n.autoBillingCheckBattery),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSupportCard(
    BuildContext context,
    Color primaryColor,
    AppLocalizations l10n, {
    required IconData icon,
    required String title,
    required List<String> items,
  }) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: primaryColor, size: 24),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...items.map((item) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    item,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }
}
