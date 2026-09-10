import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/platform/screen_text_monitor_service.dart';
import '../../services/data/source_channel_resolver.dart';
import '../../widgets/ui/primary_header.dart';
import '../../widgets/biz/recognition_app_icon.dart';
import '../../l10n/app_localizations.dart';

/// 自动识别记录页(真机漏记排查):原生过滤闸 + Dart/AI 段结局,
/// 每次抓取判定的决策码/命中词/计数,不含页面文本(隐私同抓取约定)。
/// 原「自动记账设置页」内的最近识别记录卡片已升级为本独立页面(入口在「我的」)。
class AutoRecognitionRecordsPage extends ConsumerStatefulWidget {
  const AutoRecognitionRecordsPage({super.key});

  @override
  ConsumerState<AutoRecognitionRecordsPage> createState() =>
      _AutoRecognitionRecordsPageState();
}

class _AutoRecognitionRecordsPageState
    extends ConsumerState<AutoRecognitionRecordsPage> {
  late final ScreenTextMonitorService _screenTextMonitor;
  List<Map<String, String>> _decisions = const [];
  bool _isLoading = true;
  bool _isInitialized = false;

  /// 决策码 → 用户可读标签(与原生/Dart 两段记录口径一致)。
  static const _labels = <String, String>{
    'enqueued': '已捕获入队',
    'drain_success': 'AI 已入账',
    'drain_pending': '已进待确认',
    'drain_duplicate': '重复账单,跳过',
    'drain_noTransaction': 'AI 判非账单',
    'drain_failed': '处理失败(将重试)',
    'drain_permanentFailure': '处理失败(终态)',
    'drain_noAiConfigured': 'AI 未配置',
    'drain_deferred': 'AI 未就绪,待重试',
    'drain_skipped': '事件去重跳过',
    'skipped_disabled': '监听开关未开启',
    'too_short': '页面文本过短',
    'rejected': '命中垃圾词',
    'marketing_no_hint': '纯营销页',
    'chat_page': '聊天页黑名单',
    'no_amount_or_hint': '缺金额/交易特征',
    'list_page': '列表页(金额过多)',
    'non_bookable': '不可入账状态',
    'duplicate': '重复页面',
    'partial_access': '照片权限受限',
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      final container = ProviderScope.containerOf(context);
      _screenTextMonitor = ScreenTextMonitorService(container);
      _load();
      _isInitialized = true;
    }
  }

  Future<void> _load() async {
    if (mounted) setState(() => _isLoading = true);
    final decisions = await _screenTextMonitor.recentDecisions();
    if (!mounted) return;
    setState(() {
      _decisions = decisions;
      _isLoading = false;
    });
  }

  /// 最近识别决策(原生环形队列,最多 20 条):时间正序 → 倒序展示。
  /// - enqueued + drain_success → 链路通,已入账;
  /// - rejected/list_page 等决策 → 被哪道闸拦截一目了然;
  /// - 打开详情页后一条新记录都没有 → 无障碍服务未生效(系统开关被关)。
  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final records = _decisions.reversed.toList();

    if (_decisions.isEmpty) {
      // 空态也可下拉刷新(RefreshIndicator 需要可滚动子级)
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: Text(
              l10n.autoRecognitionRecordsEmpty,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                height: 1.6,
              ),
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: records.length,
      itemBuilder: (context, index) {
        final d = records[index];
        final ts = int.tryParse(d['ts'] ?? '') ?? 0;
        final time =
            ts > 0 ? DateTime.fromMillisecondsSinceEpoch(ts) : null;
        final hh = time?.hour.toString().padLeft(2, '0') ?? '--';
        final mm = time?.minute.toString().padLeft(2, '0') ?? '--';
        final ss = time?.second.toString().padLeft(2, '0') ?? '--';
        final code = d['decision'] ?? '';
        var pkg = d['pkg'] ?? '';
        final detail = d['detail'] ?? '';
        if (pkg.isEmpty || pkg == 'app') {
          final m = RegExp(r'pkg=([^\s]+)').firstMatch(detail);
          if (m != null) pkg = m.group(1)!;
        }
        final label = _labels[code] ?? code;
        final channel = SourceChannelResolver.channelForPackage(pkg);
        final displayName = channel ??
            (pkg == 'app'
                ? '智记'
                : (pkg.isNotEmpty ? pkg.split('.').last : '系统/未知'));
        final statusColor = _decisionColor(context, code);
        final source = _sourceLabels[d['source'] ?? 'screen'];
        final sourceColor = _sourceColor(context, d['source'] ?? 'screen');

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 识别的 App 图标
                RecognitionAppIcon(
                  pkg: pkg,
                  size: 40,
                  borderRadius: 10,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 第一行：应用名称与时间戳
                      Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Text(
                                  displayName,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (pkg.isNotEmpty && pkg != displayName && pkg != 'app') ...[
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      pkg,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.onSurface
                                            .withValues(alpha: 0.45),
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '$hh:$mm:$ss',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.5),
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // 第二行：来源分类 + 状态标签
                      Row(
                        children: [
                          if (source != null) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: sourceColor.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: sourceColor.withValues(alpha: 0.28),
                                  width: 0.8,
                                ),
                              ),
                              child: Text(
                                source,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: sourceColor,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: statusColor.withValues(alpha: 0.28),
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: statusColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (detail.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          detail,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.7),
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 来源通道 → 标签(与 AutoDecisionSource 口径一致;旧记录无 source 字段
  /// 按 screen 展示)。
  static const _sourceLabels = <String, String>{
    'screen': '无障碍',
    'notification': '通知',
    'screenshot': '截图',
  };

  static Color _sourceColor(BuildContext context, String source) {
    switch (source) {
      case 'notification':
        return Colors.teal;
      case 'screenshot':
        return Colors.orange;
      case 'screen':
      default:
        return Colors.indigo;
    }
  }

  static Color _decisionColor(BuildContext context, String code) {
    final theme = Theme.of(context);
    switch (code) {
      case 'drain_success':
        return Colors.green;
      case 'enqueued':
        return theme.colorScheme.primary;
      case 'drain_pending':
      case 'drain_deferred':
      case 'drain_failed':
        return Colors.orange;
      case 'drain_permanentFailure':
      case 'drain_noAiConfigured':
        return theme.colorScheme.error;
      case 'drain_duplicate':
      case 'duplicate':
      case 'drain_skipped':
      case 'skipped_disabled':
      case 'too_short':
      case 'rejected':
      case 'marketing_no_hint':
      case 'chat_page':
      case 'no_amount_or_hint':
      case 'list_page':
      case 'non_bookable':
      default:
        return theme.colorScheme.outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Column(
        children: [
          PrimaryHeader(
            title: l10n.autoRecognitionRecordsTitle,
            showBack: true,
            leadingIcon: Icons.manage_search_outlined,
            leadingPlain: true,
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: l10n.commonRefresh,
                onPressed: _isLoading ? null : _load,
              ),
            ],
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: _buildBody(context, l10n),
                  ),
          ),
        ],
      ),
    );
  }
}
