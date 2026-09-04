import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' hide SyncStatus;
import 'package:http/http.dart' as http;
import '../../providers/sync_providers.dart';
import '../../providers/database_providers.dart';
import '../../services/system/logger_service.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/ui/capsule_switcher.dart';
import '../../widgets/biz/section_card.dart';
import '../../styles/tokens.dart';
import '../../l10n/app_localizations.dart';

// GitHub配置教程链接

class CloudServicePage extends ConsumerStatefulWidget {
  const CloudServicePage({super.key});
  @override
  ConsumerState<CloudServicePage> createState() => _CloudServicePageState();
}

class _CloudServicePageState extends ConsumerState<CloudServicePage> {
  bool _testingConnection = false;
  final Map<String, bool> _connectionTestResults = {};
  bool _hasAutoTested = false;
  String _selectedTab = 'offline'; // 'offline' | 'backup' | 'cloud'

  @override
  void initState() {
    super.initState();

    // 根据当前激活的配置决定初始 Tab
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final activeAsync = ref.read(activeCloudConfigProvider);
      if (activeAsync.hasValue) {
        final active = activeAsync.value!;
        // 备份同步(WebDAV/S3/Supabase/iCloud)已移除;仅剩 local / SmartBook Cloud
        if (active.type == CloudBackendType.smartbookCloud) {
          setState(() => _selectedTab = 'cloud');
        }
      }
      _autoTestActiveConnection();
    });
  }

  Future<void> _autoTestActiveConnection() async {
    if (_hasAutoTested) return;
    _hasAutoTested = true;

    // 多设备同步关闭时，跳过自动测试
    final prefs = await SharedPreferences.getInstance();
    final multiDevice = prefs.getBool('multi_device_sync') ?? false;
    if (!multiDevice) return;

    final activeAsync = ref.read(activeCloudConfigProvider);
    if (!activeAsync.hasValue) return;

    final active = activeAsync.value!;
    if (active.type == CloudBackendType.local || !active.valid) return;

    // 自动测试当前激活的云服务连接（静默测试，不显示对话框）
    await _testConnection(active, showDialog: false);
  }

  @override
  Widget build(BuildContext context) {
    final activeAsync = ref.watch(activeCloudConfigProvider);
    final smartbookCloudAsync = ref.watch(smartbookCloudConfigProvider);

    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      body: Column(
        children: [
          activeAsync.when(
            loading: () => PrimaryHeader(
              title: AppLocalizations.of(context).mineCloudService,
              showBack: true,
            ),
            error: (e, _) => PrimaryHeader(
              title: AppLocalizations.of(context).mineCloudService,
              showBack: true,
            ),
            data: (active) => PrimaryHeader(
              title: AppLocalizations.of(context).mineCloudService,
              showBack: true,
              actions: active.type != CloudBackendType.local && active.valid
                  ? [
                      IconButton(
                        icon: _testingConnection
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.wifi_find),
                        onPressed: _testingConnection ? null : () => _testConnection(active),
                        tooltip: AppLocalizations.of(context).cloudTestConnection,
                      ),
                    ]
                  : null,
              content: active.type != CloudBackendType.local
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: _buildConnectionStatus(active),
                    )
                  : null,
            ),
          ),
          // 胶囊切换器
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: CapsuleSwitcher<String>(
              selectedValue: _selectedTab,
              options: [
                CapsuleOption(value: 'offline', label: AppLocalizations.of(context).cloudTabOffline),
                CapsuleOption(value: 'cloud', label: AppLocalizations.of(context).cloudTabCloudSync),
              ],
              onChanged: (value) => setState(() => _selectedTab = value),
            ),
          ),
          Expanded(
            child: activeAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('${AppLocalizations.of(context).commonError}: $e')),
              data: (active) {
                if (_selectedTab == 'offline') {
                  // ===== 离线模式 =====
                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildServiceCard(
                        context: context,
                        icon: Icons.phone_android,
                        iconColor: BeeTokens.brandLocal,
                        title: AppLocalizations.of(context).cloudLocalStorageTitle,
                        subtitle: AppLocalizations.of(context).cloudLocalStorageSubtitle,
                        isSelected: active.type == CloudBackendType.local,
                        isDisabled: false,
                        onTap: () => _switchService(CloudBackendType.local),
                      ),
                    ],
                  );
                } else {
                  // ===== 云端协同 (SmartBook Cloud) =====
                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      smartbookCloudAsync.when(
                        loading: () => const SizedBox(height: 100, child: Center(child: CircularProgressIndicator())),
                        error: (e, _) => const SizedBox.shrink(),
                        data: (bcCfg) => _buildServiceCard(
                          context: context,
                          icon: Icons.cloud_circle,
                          iconColor: BeeTokens.brandCloud,
                          title: AppLocalizations.of(context).cloudSmartBookCloudTitle,
                          subtitle: bcCfg?.valid == true
                              ? bcCfg!.obfuscatedUrl()
                              : AppLocalizations.of(context).cloudSmartBookCloudSubtitle,
                          isSelected: active.type == CloudBackendType.smartbookCloud,
                          isConfigured: bcCfg?.valid == true,
                          isDisabled: false,
                          onTap: () => bcCfg?.valid == true
                              ? _switchService(CloudBackendType.smartbookCloud)
                              : _configureService(CloudBackendType.smartbookCloud),
                          onConfigure: bcCfg?.valid == true
                              ? () => _configureService(CloudBackendType.smartbookCloud)
                              : null,
                          onShowGuide: _showSmartBookCloudHelpDialog,
                        ),
                      ),
                    ],
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionStatus(CloudServiceConfig config) {
    final testResult = _connectionTestResults[config.id];
    final Color statusColor;
    final IconData statusIcon;
    final String statusText;

    if (testResult == null) {
      // 未测试
      statusColor = BeeTokens.warning(context);
      statusIcon = Icons.help_outline;
      statusText = AppLocalizations.of(context).cloudStatusNotTested;
    } else if (testResult) {
      // 测试成功
      statusColor = BeeTokens.success(context);
      statusIcon = Icons.check_circle_outline;
      statusText = AppLocalizations.of(context).cloudStatusNormal;
    } else {
      // 测试失败
      statusColor = BeeTokens.error(context);
      statusIcon = Icons.error_outline;
      statusText = AppLocalizations.of(context).cloudStatusFailed;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '${AppLocalizations.of(context).commonCurrent}: ${_getTypeName(config.type)}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: statusColor.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          config.obfuscatedUrl(),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: BeeTokens.textSecondary(context),
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }




  Widget _buildServiceCard({
    required BuildContext context,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool isSelected,
    bool isConfigured = true,
    bool isDisabled = false,
    required VoidCallback onTap,
    VoidCallback? onConfigure,
    VoidCallback? onShowGuide,
  }) {
    return Opacity(
      opacity: isDisabled ? 0.5 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          border: isSelected ? Border.all(color: BeeTokens.success(context), width: 2) : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SectionCard(
          margin: EdgeInsets.zero,
          child: InkWell(
            onTap: isDisabled ? null : onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      // 图标
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: iconColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(icon, color: iconColor, size: 24),
                      ),
                      const SizedBox(width: 16),

                      // 文字信息
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    title,
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (isDisabled)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: BeeTokens.textTertiary(context).withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      '不可用',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: BeeTokens.textTertiary(context),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              subtitle,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: BeeTokens.textSecondary(context),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // 选中标记
                      if (isSelected && !isDisabled)
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: BeeTokens.success(context),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.check, color: BeeTokens.textOnPrimary(context), size: 18),
                        ),
                    ],
                  ),

                  // 底部按钮行
                  if (!isDisabled && ((isConfigured && onConfigure != null) || onShowGuide != null))
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (onShowGuide != null)
                            TextButton.icon(
                              onPressed: onShowGuide,
                              icon: const Icon(Icons.help_outline, size: 16),
                              label: Text(AppLocalizations.of(context).commonTutorial, style: const TextStyle(fontSize: 12)),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          if (isConfigured && onConfigure != null) ...[
                            if (onShowGuide != null) const SizedBox(width: 8),
                            TextButton.icon(
                              onPressed: onConfigure,
                              icon: const Icon(Icons.settings, size: 16),
                              label: Text(AppLocalizations.of(context).commonConfigure, style: const TextStyle(fontSize: 12)),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }




  void _showSmartBookCloudHelpDialog() {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.cloud_circle, color: BeeTokens.brandCloud),
            const SizedBox(width: 8),
            Text(l10n.cloudTutorialTitle),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 介绍
              Text(
                l10n.cloudTutorialIntro,
                style: TextStyle(
                  fontSize: 13,
                  color: BeeTokens.textSecondary(context),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              // 4 步教程
              _buildBeeCloudStep('1', l10n.cloudTutorialStep1Title, l10n.cloudTutorialStep1Desc),
              _buildBeeCloudStep('2', l10n.cloudTutorialStep2Title, l10n.cloudTutorialStep2Desc),
              _buildBeeCloudStep('3', l10n.cloudTutorialStep3Title, l10n.cloudTutorialStep3Desc),
              _buildBeeCloudStep('4', l10n.cloudTutorialStep4Title, l10n.cloudTutorialStep4Desc),
              const SizedBox(height: 4),
              // 特色功能 —— 强调 Web + 多设备协同 + 多用户 + 共享账本
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: BeeTokens.brandCloud.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.cloudTutorialFeaturesTitle,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: BeeTokens.brandCloud,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(l10n.cloudTutorialFeature1, style: const TextStyle(fontSize: 12.5, height: 1.7)),
                    Text(l10n.cloudTutorialFeature2, style: const TextStyle(fontSize: 12.5, height: 1.7)),
                    Text(l10n.cloudTutorialFeature3, style: const TextStyle(fontSize: 12.5, height: 1.7)),
                    Text(l10n.cloudTutorialFeature4, style: const TextStyle(fontSize: 12.5, height: 1.7)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Tip
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: BeeTokens.brandCloud.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, color: BeeTokens.brandCloud, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${l10n.cloudTutorialTipTitle}: ',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: BeeTokens.textSecondary(context),
                              ),
                            ),
                            TextSpan(
                              text: l10n.cloudTutorialTipDesc,
                              style: TextStyle(
                                fontSize: 13,
                                color: BeeTokens.textSecondary(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cloudTutorialGotIt),
          ),
        ],
      ),
    );
  }

  Widget _buildBeeCloudStep(String num, String title, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: BeeTokens.brandCloud,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              num,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    )),
                const SizedBox(height: 3),
                Text(
                  desc,
                  style: TextStyle(
                    fontSize: 12,
                    color: BeeTokens.textSecondary(context),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }






  Future<void> _switchService(CloudBackendType type) async {
    final store = ref.read(cloudServiceStoreProvider);
    final active = await ref.read(activeCloudConfigProvider.future);

    if (active.type == type) return; // 已经是当前类型

    // iCloud: 先检查可用性

    // 确认切换
    if (!mounted) return;
    final confirmed = await AppDialog.confirm(
      context,
      title: AppLocalizations.of(context).cloudSwitchConfirmTitle,
      message: AppLocalizations.of(context).cloudSwitchConfirmMessage,
    );
    if (!confirmed || !mounted) return;

    try {
      // 登出（iCloud 使用系统账号，跳过登出）
      if (active.type != CloudBackendType.local) {
        try {
          final authService = await ref.read(authServiceProvider.future);
          await authService.signOut();
        } catch (_) {
          // 忽略登出错误
        }
      }

      // 激活新配置
      final success = await store.activate(type);
      if (!success && type != CloudBackendType.local) {
        if (mounted) {
          await AppDialog.error(context, title: AppLocalizations.of(context).cloudSwitchFailedTitle, message: AppLocalizations.of(context).cloudSwitchFailedConfigMissing);
        }
        return;
      }

      // 延迟刷新 providers，避免在 build 阶段触发 setState
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.invalidate(activeCloudConfigProvider);
        ref.invalidate(supabaseConfigProvider);
        ref.invalidate(webdavConfigProvider);
        ref.invalidate(authServiceProvider);
        ref.invalidate(syncServiceProvider);
      });

      if (mounted) {
        showToast(context, AppLocalizations.of(context).cloudSwitchedTo(_getTypeName(type)));
      }
    } catch (e) {
      if (mounted) {
        await AppDialog.error(context, title: AppLocalizations.of(context).cloudSwitchFailedTitle, message: '$e');
      }
    }
  }

  Future<void> _configureService(CloudBackendType type) async {
    // 备份同步(WebDAV/S3/Supabase/iCloud)已移除,仅剩 SmartBook Cloud 配置
    if (type == CloudBackendType.smartbookCloud) {
      await _showSmartBookCloudConfigDialog();
    }
  }

  Future<void> _showSmartBookCloudConfigDialog() async {
    final existing = await ref.read(smartbookCloudConfigProvider.future);

    if (!mounted) return;

    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (dialogContext) => _SmartBookCloudConfigDialog(
        initialUrl: existing?.smartbookCloudBaseUrl ?? '',
        initialApiPrefix: existing?.smartbookCloudApiPrefix ?? '/api/v1',
        initialEmail: existing?.smartbookCloudEmail ?? '',
        initialPassword: existing?.smartbookCloudPassword ?? '',
      ),
    );

    if (result != null) {
      final url = result['url'] as String;
      final apiPrefix = result['apiPrefix'] as String;
      final email = result['email'] as String;
      final password = result['password'] as String;

      if (url.isEmpty) {
        if (mounted) {
          await AppDialog.error(context, title: AppLocalizations.of(context).cloudConfigInvalidTitle, message: AppLocalizations.of(context).cloudConfigInvalidMessage);
        }
        return;
      }
      // URL 必须是完整的 http(s) 地址。相对路径(如 /api/v1)或本机路径
      // (如 file:///C:/...)会被拼成错误的请求地址(登录接口打到 file 协议),
      // 这里直接拦下,提示用户按 hint 格式填写。
      final parsedUrl = Uri.tryParse(url.trim());
      if (parsedUrl == null ||
          (parsedUrl.scheme != 'http' && parsedUrl.scheme != 'https') ||
          parsedUrl.host.isEmpty) {
        if (mounted) {
          await AppDialog.error(
            context,
            title: AppLocalizations.of(context).cloudConfigInvalidTitle,
            message:
                '${AppLocalizations.of(context).cloudConfigInvalidMessage}\n'
                '（格式: https://host[:port]，如 https://your-server:8888）',
          );
        }
        return;
      }

      final cfg = CloudServiceConfig(
        type: CloudBackendType.smartbookCloud,
        name: AppLocalizations.of(context).cloudSmartBookCloudTitle,
        smartbookCloudBaseUrl: url,
        smartbookCloudApiPrefix: apiPrefix.isEmpty ? '/api/v1' : apiPrefix,
        smartbookCloudEmail: email.isNotEmpty ? email : null,
        smartbookCloudPassword: password.isNotEmpty ? password : null,
      );

      if (!cfg.valid) {
        if (mounted) {
          await AppDialog.error(context, title: AppLocalizations.of(context).cloudConfigInvalidTitle, message: AppLocalizations.of(context).cloudConfigInvalidMessage);
        }
        return;
      }

      try {
        await ref.read(cloudServiceStoreProvider).saveOnly(cfg);
        ref.invalidate(smartbookCloudConfigProvider);
        ref.invalidate(activeCloudConfigProvider);
        ref.invalidate(smartbookCloudProviderInstance);
        if (mounted) showToast(context, AppLocalizations.of(context).cloudConfigSaved);

        // 如果提供了邮箱和密码，尝试登录（恢复旧行为）
        if (email.isNotEmpty && password.isNotEmpty) {
          try {
            // 在全 App 唯一的 provider 上登录，避免 session 只写入临时
            // auth 实例、SyncEngine 仍持有未登录实例。
            final provider =
                await ref.read(smartbookCloudProviderInstance.future);
            if (provider != null) {
              await provider.auth.signInWithEmail(
                email: email,
                password: password,
              );
              ref.invalidate(authServiceProvider);
              ref.invalidate(syncServiceProvider);

              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('auto_sync', true);
              ref.invalidate(autoSyncValueProvider);

              Future(() async {
                try {
                  final sync = ref.read(syncServiceProvider);
                  final ledgerId = ref.read(currentLedgerIdProvider);
                  await sync.uploadCurrentLedger(ledgerId: ledgerId);
                  ref.read(syncStatusRefreshProvider.notifier).state++;
                  ref.read(ledgerListRefreshProvider.notifier).state++;
                } catch (e) {
                  logger.error('CloudServicePage', 'SmartBook Cloud 首次同步失败', e);
                }
              });

              if (mounted) {
                showToast(context, AppLocalizations.of(context).cloudSmartBookCloudLoginSuccess);
              }
            }
          } catch (e) {
            if (mounted) {
              await AppDialog.error(
                context,
                title: AppLocalizations.of(context).cloudSmartBookCloudLoginFailed,
                message: e.toString(),
              );
            }
          }
        }
      } catch (e) {
        if (mounted) {
          await AppDialog.error(context, title: AppLocalizations.of(context).cloudSaveFailed, message: e.toString());
        }
      }
    }
  }




  String _getTypeName(CloudBackendType type) {
    switch (type) {
      case CloudBackendType.local:
        return AppLocalizations.of(context).cloudLocalStorageTitle;
      case CloudBackendType.smartbookCloud:
        return 'SmartBook Cloud';
      // 旧版备份同步类型(WebDAV/S3/Supabase/iCloud)已无入口,不该再出现
      default:
        return '';
    }
  }

  // 测试连接
  Future<void> _testConnection(CloudServiceConfig config, {bool showDialog = true}) async {
    if (!config.valid || config.type == CloudBackendType.local) return;

    setState(() => _testingConnection = true);
    try {
      bool connectionSuccess = false;
      String? errorDetail;

      try {
        switch (config.type) {
          case CloudBackendType.local:
            break;

          case CloudBackendType.smartbookCloud:
            // SmartBook Cloud 连接测试 - 调用健康检查接口
            try {
              final services = await createCloudServices(config);
              if (services.provider == null) {
                throw Exception('SmartBook Cloud provider 初始化失败');
              }
              // 尝试列出文件验证连接
              await services.provider!.storage.list(path: '');
              connectionSuccess = true;
            } catch (e) {
              String errorMsg = e.toString();
              if (errorMsg.contains('Exception:')) {
                errorMsg = errorMsg.replaceFirst('Exception: ', '');
              }
              throw Exception(errorMsg);
            }
            break;

          default:
            // 旧版备份同步类型(WebDAV/S3/Supabase/iCloud)已无入口
            break;
        }
      } on http.ClientException catch (e) {
        connectionSuccess = false;
        errorDetail = AppLocalizations.of(context).cloudErrorNetwork(e.message);
      } on Exception catch (e) {
        connectionSuccess = false;
        errorDetail = e.toString().replaceFirst('Exception: ', '');
      } catch (e) {
        connectionSuccess = false;
        errorDetail = e.toString();
      }

      setState(() {
        _connectionTestResults[config.id] = connectionSuccess;
      });

      // 只在手动测试时显示对话框
      if (mounted && showDialog) {
        if (connectionSuccess) {
          await AppDialog.info(context,
              title: AppLocalizations.of(context).cloudTestSuccessTitle,
              message: AppLocalizations.of(context).cloudTestSuccessMessage);
        } else {
          await AppDialog.error(context,
              title: AppLocalizations.of(context).cloudTestFailedTitle,
              message: errorDetail ?? AppLocalizations.of(context).cloudTestFailedMessage);
        }
      }
    } catch (e) {
      setState(() {
        _connectionTestResults[config.id] = false;
      });
      // 只在手动测试时显示错误对话框
      if (mounted && showDialog) {
        await AppDialog.error(context,
            title: AppLocalizations.of(context).cloudTestErrorTitle,
            message: e.toString());
      }
    } finally {
      if (mounted) setState(() => _testingConnection = false);
    }
  }
}

// Supabase配置对话框(独立Widget,避免controller生命周期问题)
class _SmartBookCloudConfigDialog extends StatefulWidget {
  final String initialUrl;
  final String initialApiPrefix;
  final String initialEmail;
  final String initialPassword;

  const _SmartBookCloudConfigDialog({
    required this.initialUrl,
    required this.initialApiPrefix,
    this.initialEmail = '',
    this.initialPassword = '',
  });

  @override
  State<_SmartBookCloudConfigDialog> createState() => _SmartBookCloudConfigDialogState();
}

class _SmartBookCloudConfigDialogState extends State<_SmartBookCloudConfigDialog> {
  late final TextEditingController urlController;
  late final TextEditingController apiPrefixController;
  late final TextEditingController emailController;
  late final TextEditingController passwordController;
  bool obscurePassword = true;

  @override
  void initState() {
    super.initState();
    urlController = TextEditingController(text: widget.initialUrl);
    apiPrefixController = TextEditingController(text: widget.initialApiPrefix);
    emailController = TextEditingController(text: widget.initialEmail);
    passwordController = TextEditingController(text: widget.initialPassword);
  }

  @override
  void dispose() {
    urlController.dispose();
    apiPrefixController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(AppLocalizations.of(context).cloudConfigureSmartBookCloudTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudSmartBookCloudUrlLabel,
                hintText: AppLocalizations.of(context).cloudSmartBookCloudUrlHint,
              ),
              keyboardType: TextInputType.url,
            ),
            // API Prefix 输入框移除 —— 后端固定 /api/v1,前端用户没有配置场景;
            // 保留 apiPrefixController(默认 /api/v1)让 save 流程不破。
            const SizedBox(height: 16),
            TextField(
              controller: emailController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudSmartBookCloudEmailLabel,
                hintText: AppLocalizations.of(context).cloudSmartBookCloudEmailHint,
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudSmartBookCloudPasswordLabel,
                hintText: AppLocalizations.of(context).cloudSmartBookCloudPasswordHint,
                suffixIcon: IconButton(
                  icon: Icon(
                    obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    size: 20,
                  ),
                  onPressed: () {
                    setState(() {
                      obscurePassword = !obscurePassword;
                    });
                  },
                ),
              ),
              obscureText: obscurePassword,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop({
              'url': urlController.text.trim(),
              'apiPrefix': apiPrefixController.text.trim(),
              'email': emailController.text.trim(),
              'password': passwordController.text.trim(),
            });
          },
          child: Text(AppLocalizations.of(context).commonSave),
        ),
      ],
    );
  }
}

class _SupabaseConfigDialog extends StatefulWidget {
  final String initialUrl;
  final String initialKey;
  final String initialBucket;

  const _SupabaseConfigDialog({
    required this.initialUrl,
    required this.initialKey,
    required this.initialBucket,
  });

  @override
  State<_SupabaseConfigDialog> createState() => _SupabaseConfigDialogState();
}

class _SupabaseConfigDialogState extends State<_SupabaseConfigDialog> {
  late final TextEditingController urlController;
  late final TextEditingController keyController;
  late final TextEditingController bucketController;

  @override
  void initState() {
    super.initState();
    urlController = TextEditingController(text: widget.initialUrl);
    keyController = TextEditingController(text: widget.initialKey);
    bucketController = TextEditingController(text: widget.initialBucket);
  }

  @override
  void dispose() {
    urlController.dispose();
    keyController.dispose();
    bucketController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(AppLocalizations.of(context).cloudConfigureSupabaseTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudSupabaseUrlLabel,
                hintText: AppLocalizations.of(context).cloudSupabaseUrlHint,
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: keyController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudAnonKeyLabel,
                hintText: AppLocalizations.of(context).cloudSupabaseAnonKeyHintLong,
              ),
              keyboardType: TextInputType.text,
              minLines: 1,
              maxLines: 5,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: bucketController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudSupabaseBucketLabel,
                hintText: AppLocalizations.of(context).cloudSupabaseBucketHint,
              ),
              keyboardType: TextInputType.text,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop({
              'url': urlController.text.trim(),
              'key': keyController.text.trim(),
              'bucket': bucketController.text.trim(),
            });
          },
          child: Text(AppLocalizations.of(context).commonSave),
        ),
      ],
    );
  }
}

// WebDAV配置对话框(独立Widget,避免controller生命周期问题)
class _WebdavConfigDialog extends StatefulWidget {
  final String initialUrl;
  final String initialUsername;
  final String initialPassword;
  final String initialPath;

  const _WebdavConfigDialog({
    required this.initialUrl,
    required this.initialUsername,
    required this.initialPassword,
    required this.initialPath,
  });

  @override
  State<_WebdavConfigDialog> createState() => _WebdavConfigDialogState();
}

class _WebdavConfigDialogState extends State<_WebdavConfigDialog> {
  late final TextEditingController urlController;
  late final TextEditingController usernameController;
  late final TextEditingController passwordController;
  late final TextEditingController pathController;
  bool obscurePassword = true;

  @override
  void initState() {
    super.initState();
    urlController = TextEditingController(text: widget.initialUrl);
    usernameController = TextEditingController(text: widget.initialUsername);
    passwordController = TextEditingController(text: widget.initialPassword);
    pathController = TextEditingController(text: widget.initialPath);
  }

  @override
  void dispose() {
    urlController.dispose();
    usernameController.dispose();
    passwordController.dispose();
    pathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(AppLocalizations.of(context).cloudConfigureWebdavTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudWebdavUrlLabel,
                hintText: AppLocalizations.of(context).cloudWebdavUrlHint,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: usernameController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudWebdavUsernameLabel,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudWebdavPasswordLabel,
                suffixIcon: IconButton(
                  icon: Icon(
                    obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    size: 20,
                  ),
                  onPressed: () {
                    setState(() {
                      obscurePassword = !obscurePassword;
                    });
                  },
                ),
              ),
              obscureText: obscurePassword,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: pathController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudWebdavRemotePathLabel,
                hintText: AppLocalizations.of(context).cloudWebdavPathHint,
                helperText: AppLocalizations.of(context).cloudWebdavRemotePathHelperText,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop({
              'url': urlController.text.trim(),
              'username': usernameController.text.trim(),
              'password': passwordController.text.trim(),
              'path': pathController.text.trim(),
            });
          },
          child: Text(AppLocalizations.of(context).commonSave),
        ),
      ],
    );
  }
}

// S3配置对话框(独立Widget,避免controller生命周期问题)
class _S3ConfigDialog extends StatefulWidget {
  final String initialEndpoint;
  final String initialRegion;
  final String initialAccessKey;
  final String initialSecretKey;
  final String initialBucket;
  final bool initialUseSSL;
  final int? initialPort;

  const _S3ConfigDialog({
    required this.initialEndpoint,
    required this.initialRegion,
    required this.initialAccessKey,
    required this.initialSecretKey,
    required this.initialBucket,
    required this.initialUseSSL,
    this.initialPort,
  });

  @override
  State<_S3ConfigDialog> createState() => _S3ConfigDialogState();
}

class _S3ConfigDialogState extends State<_S3ConfigDialog> {
  late final TextEditingController endpointController;
  late final TextEditingController regionController;
  late final TextEditingController accessKeyController;
  late final TextEditingController secretKeyController;
  late final TextEditingController bucketController;
  late final TextEditingController portController;
  late bool useSSL;
  bool obscureSecretKey = true;

  @override
  void initState() {
    super.initState();
    endpointController = TextEditingController(text: widget.initialEndpoint);
    regionController = TextEditingController(text: widget.initialRegion);
    accessKeyController = TextEditingController(text: widget.initialAccessKey);
    secretKeyController = TextEditingController(text: widget.initialSecretKey);
    bucketController = TextEditingController(text: widget.initialBucket);
    portController = TextEditingController(text: widget.initialPort?.toString() ?? '');
    useSSL = widget.initialUseSSL;
  }

  @override
  void dispose() {
    endpointController.dispose();
    regionController.dispose();
    accessKeyController.dispose();
    secretKeyController.dispose();
    bucketController.dispose();
    portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(AppLocalizations.of(context).cloudConfigureS3Title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: endpointController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudS3EndpointLabel,
                hintText: AppLocalizations.of(context).cloudS3EndpointHint,
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: regionController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudS3RegionLabel,
                hintText: AppLocalizations.of(context).cloudS3RegionHint,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: accessKeyController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudS3AccessKeyLabel,
                hintText: AppLocalizations.of(context).cloudS3AccessKeyHint,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: secretKeyController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudS3SecretKeyLabel,
                hintText: AppLocalizations.of(context).cloudS3SecretKeyHint,
                suffixIcon: IconButton(
                  icon: Icon(
                    obscureSecretKey ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    size: 20,
                  ),
                  onPressed: () {
                    setState(() {
                      obscureSecretKey = !obscureSecretKey;
                    });
                  },
                ),
              ),
              obscureText: obscureSecretKey,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: bucketController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudS3BucketLabel,
                hintText: AppLocalizations.of(context).cloudS3BucketHint,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(AppLocalizations.of(context).cloudS3UseSSLLabel),
                ),
                Switch(
                  value: useSSL,
                  onChanged: (value) {
                    setState(() {
                      useSSL = value;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: portController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).cloudS3PortLabel,
                hintText: AppLocalizations.of(context).cloudS3PortHint,
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
        FilledButton(
          onPressed: () {
            final portText = portController.text.trim();
            final port = portText.isEmpty ? null : int.tryParse(portText);

            Navigator.of(context).pop({
              'endpoint': endpointController.text.trim(),
              'region': regionController.text.trim(),
              'accessKey': accessKeyController.text.trim(),
              'secretKey': secretKeyController.text.trim(),
              'bucket': bucketController.text.trim(),
              'useSSL': useSSL,
              'port': port,
            });
          },
          child: Text(AppLocalizations.of(context).commonSave),
        ),
      ],
    );
  }
}
