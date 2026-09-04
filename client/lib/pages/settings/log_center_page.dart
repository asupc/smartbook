import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/system/logger_service.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/section_card.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../providers/theme_providers.dart';
import '../../l10n/app_localizations.dart';

/// 日志中心页面
class LogCenterPage extends ConsumerStatefulWidget {
  const LogCenterPage({super.key});

  @override
  ConsumerState<LogCenterPage> createState() => _LogCenterPageState();
}

class _LogCenterPageState extends ConsumerState<LogCenterPage> {
  // 过滤条件
  final Set<LogLevel> _selectedLevels = LogLevel.values.toSet();
  final Set<LogPlatform> _selectedPlatforms = LogPlatform.values.toSet();
  String _searchKeyword = '';

  // 搜索控制器
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 监听日志更新
    logger.addListener(_onLogsChanged);
  }

  @override
  void dispose() {
    logger.removeListener(_onLogsChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onLogsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 获取过滤后的日志
  List<LogEntry> get _filteredLogs {
    return logger.logs
        .where((log) {
          // 级别过滤
          if (!_selectedLevels.contains(log.level)) return false;

          // 平台过滤
          if (!_selectedPlatforms.contains(log.platform)) return false;

          // 关键词搜索
          if (_searchKeyword.isNotEmpty) {
            final keyword = _searchKeyword.toLowerCase();
            final matchMessage = log.message.toLowerCase().contains(keyword);
            final matchTag = log.tag.toLowerCase().contains(keyword);
            if (!matchMessage && !matchTag) return false;
          }

          return true;
        })
        .toList()
        .reversed
        .toList(); // 最新的在前面
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.watch(primaryColorProvider);
    final filteredLogs = _filteredLogs;

    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      body: Column(
        children: [
          PrimaryHeader(
            title: l10n.logCenterTitle,
            subtitle: l10n.logCenterSubtitle,
            showBack: true,
            actions: [
              // 导出日志
              IconButton(
                icon: const Icon(Icons.share_outlined),
                onPressed: _exportLogs,
                tooltip: l10n.logCenterExport,
              ),
              // 清空日志
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: _clearLogs,
                tooltip: l10n.logCenterClear,
              ),
            ],
          ),
          // 搜索框
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 12.0.scaled(context, ref),
              vertical: 8.0.scaled(context, ref),
            ),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: l10n.logCenterSearchHint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchKeyword.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchKeyword = '');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8.0.scaled(context, ref)),
                ),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12.0.scaled(context, ref),
                  vertical: 8.0.scaled(context, ref),
                ),
              ),
              onChanged: (value) {
                setState(() => _searchKeyword = value);
              },
            ),
          ),
          // 过滤器
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 0.scaled(context, ref),
              vertical: 4.0.scaled(context, ref),
            ),
            child: SectionCard(
              margin: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 日志级别过滤
                  Padding(
                    padding: EdgeInsets.only(bottom: 8.0.scaled(context, ref)),
                    child: Text(
                      l10n.logCenterFilterLevel,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: BeeTokens.textSecondary(context),
                          ),
                    ),
                  ),
                  Wrap(
                    spacing: 8.0.scaled(context, ref),
                    runSpacing: 4.0.scaled(context, ref),
                    children: LogLevel.values.map((level) {
                      final isSelected = _selectedLevels.contains(level);
                      return FilterChip(
                        label: Text(level.displayName),
                        selected: isSelected,
                        selectedColor: primaryColor.withOpacity(0.2),
                        onSelected: (selected) {
                          setState(() {
                            if (selected) {
                              _selectedLevels.add(level);
                            } else {
                              _selectedLevels.remove(level);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                  SizedBox(height: 12.0.scaled(context, ref)),
                  // 平台过滤
                  Padding(
                    padding: EdgeInsets.only(bottom: 8.0.scaled(context, ref)),
                    child: Text(
                      l10n.logCenterFilterPlatform,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: BeeTokens.textSecondary(context),
                          ),
                    ),
                  ),
                  Wrap(
                    spacing: 8.0.scaled(context, ref),
                    runSpacing: 4.0.scaled(context, ref),
                    children: LogPlatform.values.where((platform) {
                      // 在 Android 上隐藏 iOS，在 iOS 上隐藏 Android
                      if (Platform.isAndroid && platform == LogPlatform.ios) {
                        return false;
                      }
                      if (Platform.isIOS && platform == LogPlatform.android) {
                        return false;
                      }
                      return true;
                    }).map((platform) {
                      final isSelected = _selectedPlatforms.contains(platform);
                      return FilterChip(
                        label: Text(platform.displayName),
                        selected: isSelected,
                        selectedColor: primaryColor.withOpacity(0.2),
                        onSelected: (selected) {
                          setState(() {
                            if (selected) {
                              _selectedPlatforms.add(platform);
                            } else {
                              _selectedPlatforms.remove(platform);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
          // 日志统计
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 12.0.scaled(context, ref),
              vertical: 8.0.scaled(context, ref),
            ),
            child: Row(
              children: [
                Text(
                  '${l10n.logCenterTotal}: ${logger.logs.length}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: BeeTokens.textSecondary(context),
                      ),
                ),
                SizedBox(width: 16.0.scaled(context, ref)),
                Text(
                  '${l10n.logCenterFiltered}: ${filteredLogs.length}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: BeeTokens.textSecondary(context),
                      ),
                ),
              ],
            ),
          ),
          // 日志列表
          Expanded(
            child: filteredLogs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.inbox_outlined,
                          size: 64.0.scaled(context, ref),
                          color: BeeTokens.textSecondary(context),
                        ),
                        SizedBox(height: 16.0.scaled(context, ref)),
                        Text(
                          l10n.logCenterEmpty,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: BeeTokens.textSecondary(context),
                                  ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.symmetric(
                      horizontal: 12.0.scaled(context, ref),
                      vertical: 8.0.scaled(context, ref),
                    ),
                    itemCount: filteredLogs.length,
                    itemBuilder: (context, index) {
                      final log = filteredLogs[index];
                      return _LogEntryCard(log: log);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 导出日志
  Future<void> _exportLogs() async {
    try {
      final text = logger.exportAsText();
      await Share.share(
        text,
        subject: 'SmartBook 日志导出',
      );
    } catch (e) {
      if (mounted) {
        showToast(context, AppLocalizations.of(context).logCenterExportFailed);
      }
    }
  }

  /// 清空日志
  Future<void> _clearLogs() async {
    final l10n = AppLocalizations.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.logCenterClearConfirmTitle),
        content: Text(l10n.logCenterClearConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );

    if (confirm == true) {
      logger.clear();
      if (mounted) {
        showToast(context, l10n.logCenterCleared);
      }
    }
  }
}

/// 日志条目卡片
class _LogEntryCard extends ConsumerWidget {
  final LogEntry log;

  const _LogEntryCard({required this.log});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    // 根据日志级别选择颜色
    final levelColor = switch (log.level) {
      LogLevel.debug => Colors.grey,
      LogLevel.info => Colors.blue,
      LogLevel.warning => Colors.orange,
      LogLevel.error => Colors.red,
    };

    return SectionCard(
      margin: EdgeInsets.only(bottom: 8.0.scaled(context, ref)),
      child: InkWell(
        onTap: () => _showLogDetail(context),
        onLongPress: () => _copyLog(context),
        child: Padding(
          padding: EdgeInsets.all(12.0.scaled(context, ref)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部：级别 + 平台 + 时间
              Row(
                children: [
                  // 级别标签
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 6.0.scaled(context, ref),
                      vertical: 2.0.scaled(context, ref),
                    ),
                    decoration: BoxDecoration(
                      color: levelColor.withOpacity(0.1),
                      borderRadius:
                          BorderRadius.circular(4.0.scaled(context, ref)),
                      border: Border.all(color: levelColor, width: 1),
                    ),
                    child: Text(
                      log.level.displayName,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: levelColor,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  SizedBox(width: 6.0.scaled(context, ref)),
                  // 平台标签
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 6.0.scaled(context, ref),
                      vertical: 2.0.scaled(context, ref),
                    ),
                    decoration: BoxDecoration(
                      color: BeeTokens.surfaceSecondary(context),
                      borderRadius:
                          BorderRadius.circular(4.0.scaled(context, ref)),
                    ),
                    child: Text(
                      log.platform.displayName,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: BeeTokens.textSecondary(context),
                          ),
                    ),
                  ),
                  const Spacer(),
                  // 时间
                  Text(
                    _formatTime(log.timestamp),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: BeeTokens.textSecondary(context),
                        ),
                  ),
                ],
              ),
              SizedBox(height: 8.0.scaled(context, ref)),
              // Tag
              Text(
                '[${log.tag}]',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: BeeTokens.textSecondary(context),
                      fontWeight: FontWeight.w500,
                    ),
              ),
              SizedBox(height: 4.0.scaled(context, ref)),
              // 消息内容
              Text(
                log.message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: BeeTokens.textPrimary(context),
                    ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              // 错误信息（如果有）
              if (log.error != null) ...[
                SizedBox(height: 4.0.scaled(context, ref)),
                Text(
                  'Error: ${log.error}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.red,
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${_twoDigits(time.hour)}:'
        '${_twoDigits(time.minute)}:'
        '${_twoDigits(time.second)}.'
        '${_threeDigits(time.millisecond)}';
  }

  String _twoDigits(int n) => n.toString().padLeft(2, '0');
  String _threeDigits(int n) => n.toString().padLeft(3, '0');

  /// 显示日志详情
  void _showLogDetail(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('[${log.tag}]'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _DetailRow('时间', log.timestamp.toString()),
              _DetailRow('级别', log.level.displayName),
              _DetailRow('平台', log.platform.displayName),
              const Divider(),
              Text(
                log.message,
                style: const TextStyle(fontSize: 14),
              ),
              if (log.error != null) ...[
                const Divider(),
                Text(
                  'Error: ${log.error}',
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ],
              if (log.stackTrace != null) ...[
                const Divider(),
                Text(
                  'Stack Trace:\n${log.stackTrace}',
                  style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _copyLog(context),
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 复制日志
  void _copyLog(BuildContext context) {
    Clipboard.setData(ClipboardData(text: log.toFormattedString()));
    showToast(context, AppLocalizations.of(context).logCenterCopied);
  }
}

/// 详情行
class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              '$label:',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
