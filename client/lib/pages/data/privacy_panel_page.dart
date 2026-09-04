import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart' as db;
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../services/attachment_service.dart';
import '../../services/billing/pending_candidate.dart';
import '../../widgets/ui/primary_header.dart';
import '../../widgets/ui/toast.dart';

/// 隐私面板(M5-E,文档 plan §M5 任务 5):
/// - 原文数据展示:截图/图片原文(附件数量+占用空间)、待确认候选数;
/// - 「一键清除截图/图片原文」:删附件目录文件 + 附件行,交易记录保留;
/// - 短信/通知原文不落盘(解析后即弃)为设计保证,面板内说明。
class PrivacyPanelPage extends ConsumerStatefulWidget {
  const PrivacyPanelPage({super.key});

  @override
  ConsumerState<PrivacyPanelPage> createState() => _PrivacyPanelPageState();
}

class _PrivacyPanelPageState extends ConsumerState<PrivacyPanelPage> {
  List<db.TransactionAttachment> _attachments = const [];
  int _pendingCount = 0;
  int _dirSize = 0;
  bool _loading = true;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final repo = ref.read(repositoryProvider);
    final attachments = await repo.getAllAttachments();
    final pending = await PendingCandidateStore().count();
    var size = 0;
    try {
      size = await ref.read(attachmentServiceProvider).getAttachmentDirectorySize();
    } catch (_) {
      // 目录不存在等异常按 0 处理
    }
    if (!mounted) return;
    setState(() {
      _attachments = attachments;
      _pendingCount = pending;
      _dirSize = size;
      _loading = false;
    });
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  /// 一键清除截图/图片原文:删附件行 + 目录文件(交易记录保留)。
  Future<void> _clearAttachments() async {
    final l10n = AppLocalizations.of(context);
    if (_attachments.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.privacyClearAttachmentsConfirmTitle),
        content: Text(l10n.privacyClearAttachmentsConfirmBody(
            _attachments.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _clearing = true);
    try {
      final repo = ref.read(repositoryProvider);
      Directory? dir;
      try {
        dir = await ref.read(attachmentServiceProvider).getAttachmentDirectory();
      } catch (_) {
        dir = null;
      }
      var cleared = 0;
      for (final a in _attachments) {
        await repo.deleteAttachment(a.id);
        cleared++;
        // 删除目录文件(文件名即 sha256 图名)
        final fileName = a.fileName;
        if (dir != null && fileName != null && fileName.isNotEmpty) {
          try {
            final f = File('${dir.path}${Platform.pathSeparator}$fileName');
            if (await f.exists()) {
              await f.delete();
            }
          } catch (_) {
            // 文件删除失败不影响行删除
          }
        }
      }
      if (mounted) {
        showToast(context, l10n.privacyCleared(cleared));
      }
    } catch (e) {
      if (mounted) {
        showToast(context,
            '${AppLocalizations.of(context).commonError}: $e',
            duration: const Duration(seconds: 3));
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Column(
        children: [
          PrimaryHeader(
            title: l10n.privacyPanelTitle,
            showBack: true,
            leadingIcon: Icons.privacy_tip_outlined,
            leadingPlain: true,
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // 统计:截图/图片原文
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.image_outlined),
                          title: Text(l10n.privacyStatsAttachments),
                          subtitle: Text(
                            l10n.privacyStatsAttachmentsDesc(
                              _attachments.length.toString(),
                              _formatSize(_dirSize),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // 统计:待确认候选
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.fact_check_outlined),
                          title: Text(l10n.pendingConfirmationTitle),
                          subtitle:
                              Text(l10n.privacyStatsPending(_pendingCount.toString())),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // 短信/通知原文不落盘(设计保证)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.info_outline,
                                  size: 18, color: Colors.orange),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      l10n.privacyNoOriginalForSmsNotifyTitle,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                              fontWeight: FontWeight.w600),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      l10n.privacyNoOriginalForSmsNotifyDesc,
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // 一键清除
                      FilledButton.icon(
                        onPressed: _clearing || _attachments.isEmpty
                            ? null
                            : _clearAttachments,
                        icon: _clearing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.delete_sweep_outlined),
                        label: Text(l10n.privacyClearAttachments),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
