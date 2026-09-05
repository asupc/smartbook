import 'remote_raw_evidence_panel.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart' as db;
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../services/attachment_service.dart';
import '../../services/automation/auto_book_event.dart';
import '../../services/automation/auto_book_event_store.dart';
import '../../services/billing/pending_candidate.dart';
import '../../services/privacy/raw_evidence_policy.dart';
import '../../widgets/ui/primary_header.dart';
import '../../widgets/ui/toast.dart';

/// Privacy controls for both image attachments and raw automatic-bookkeeping
/// evidence. Raw evidence remains in AutoBookEvents and never enters
/// ChangeTracker/sync_changes.
class PrivacyPanelPage extends ConsumerStatefulWidget {
  const PrivacyPanelPage({super.key});

  @override
  ConsumerState<PrivacyPanelPage> createState() => _PrivacyPanelPageState();
}

class _PrivacyPanelPageState extends ConsumerState<PrivacyPanelPage> {
  static const _retentionChoices = <int>[1, 7, 30, 90, 180, 365];
  static const _primarySources = <AutoBookSource>[
    AutoBookSource.sms,
    AutoBookSource.notification,
    AutoBookSource.screenText,
    AutoBookSource.screenshot,
    AutoBookSource.sharedImage,
    AutoBookSource.deepLinkText,
  ];

  final RawEvidencePolicyStore _policyStore = RawEvidencePolicyStore();

  List<db.TransactionAttachment> _attachments = const [];
  List<db.AutoBookEvent> _rawEvidence = const [];
  Map<String, int> _rawCounts = const {};
  RawEvidencePolicy _policy = RawEvidencePolicy.defaults;
  int _pendingCount = 0;
  int _dirSize = 0;
  bool _loading = true;
  bool _clearingAttachments = false;
  bool _clearingRaw = false;
  bool _savingPolicy = false;
  bool _showRemote = false;

  AutoBookEventStore get _eventStore =>
      ref.read(autoBookCoordinatorProvider).store;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  String _copy(String zh, String en) {
    return Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
  }

  Future<void> _reload() async {
    final repo = ref.read(repositoryProvider);
    final eventStore = _eventStore;
    await eventStore.cleanupExpiredRawEvidence();
    final results = await Future.wait<Object>([
      repo.getAllAttachments(),
      PendingCandidateStore().count(),
      _policyStore.load(),
      eventStore.listRawEvidence(limit: 30),
      eventStore.countRawEvidenceBySource(),
    ]);
    var size = 0;
    try {
      size = await ref
          .read(attachmentServiceProvider)
          .getAttachmentDirectorySize();
    } catch (_) {
      // Missing directory is equivalent to zero bytes.
    }
    if (!mounted) return;
    setState(() {
      _attachments = results[0] as List<db.TransactionAttachment>;
      _pendingCount = results[1] as int;
      _policy = results[2] as RawEvidencePolicy;
      _rawEvidence = results[3] as List<db.AutoBookEvent>;
      _rawCounts = results[4] as Map<String, int>;
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

  String _sourceLabel(String source) => switch (source) {
        'sms' => _copy('短信', 'SMS'),
        'notification' => _copy('通知', 'Notification'),
        'screenText' => _copy('屏幕文本', 'Screen text'),
        'screenshot' => _copy('截图', 'Screenshot'),
        'sharedImage' => _copy('分享图片', 'Shared image'),
        'deepLinkText' => _copy('链接文本', 'Deep-link text'),
        'import' => _copy('导入', 'Import'),
        _ => source,
      };

  IconData _sourceIcon(String source) => switch (source) {
        'sms' => Icons.sms_outlined,
        'notification' => Icons.notifications_none_outlined,
        'screenText' => Icons.text_snippet_outlined,
        'screenshot' || 'sharedImage' => Icons.image_outlined,
        _ => Icons.description_outlined,
      };

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _saveSourcePolicy(
    String source,
    RawEvidenceSourcePolicy next,
  ) async {
    if (_savingPolicy) return;
    setState(() => _savingPolicy = true);
    try {
      final policy = await _policyStore.setSource(source, next);
      if (mounted) setState(() => _policy = policy);
    } catch (error) {
      if (mounted) {
        showToast(context, '${_copy('保存失败', 'Save failed')}: $error');
      }
    } finally {
      if (mounted) setState(() => _savingPolicy = false);
    }
  }

  Future<void> _saveDefaultPolicy(RawEvidenceSourcePolicy next) async {
    if (_savingPolicy) return;
    setState(() => _savingPolicy = true);
    try {
      final policy = await _policyStore.setDefault(next);
      if (mounted) setState(() => _policy = policy);
    } catch (error) {
      if (mounted) {
        showToast(context, '${_copy('保存失败', 'Save failed')}: $error');
      }
    } finally {
      if (mounted) setState(() => _savingPolicy = false);
    }
  }

  Future<void> _clearAttachments() async {
    final l10n = AppLocalizations.of(context);
    if (_attachments.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.privacyClearAttachmentsConfirmTitle),
        content: Text(
          l10n.privacyClearAttachmentsConfirmBody(_attachments.length),
        ),
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

    setState(() => _clearingAttachments = true);
    try {
      final repo = ref.read(repositoryProvider);
      Directory? dir;
      try {
        dir =
            await ref.read(attachmentServiceProvider).getAttachmentDirectory();
      } catch (_) {
        dir = null;
      }
      var cleared = 0;
      for (final attachment in _attachments) {
        await repo.deleteAttachment(attachment.id);
        cleared++;
        final fileName = attachment.fileName;
        if (dir != null && fileName.isNotEmpty) {
          try {
            final file = File('${dir.path}${Platform.pathSeparator}$fileName');
            if (await file.exists()) await file.delete();
          } catch (_) {
            // Row cleanup must not be rolled back by a stale/missing file.
          }
        }
      }
      if (mounted) showToast(context, l10n.privacyCleared(cleared));
    } catch (error) {
      if (mounted) {
        showToast(
          context,
          '${AppLocalizations.of(context).commonError}: $error',
          duration: const Duration(seconds: 3),
        );
      }
    } finally {
      if (mounted) setState(() => _clearingAttachments = false);
      await _reload();
    }
  }

  Future<void> _clearRawEvidence({String? source}) async {
    final count =
        source == null ? _rawEvidence.length : (_rawCounts[source] ?? 0);
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_copy('清除原始证据？', 'Clear raw evidence?')),
        content: Text(
          source == null
              ? _copy(
                  '将删除本机保存的短信、通知和屏幕文本等原文，但不会删除已生成的交易。',
                  'This deletes locally stored SMS, notification and screen text, but keeps generated transactions.',
                )
              : _copy(
                  '将删除“${_sourceLabel(source)}”原文，但不会删除已生成的交易。',
                  'This deletes ${_sourceLabel(source)} originals but keeps generated transactions.',
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(ctx).commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppLocalizations.of(ctx).commonConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _clearingRaw = true);
    try {
      final cleared = await _eventStore.clearRawEvidence(source: source);
      if (mounted) {
        showToast(
          context,
          _copy('已清除 $cleared 条原始证据', 'Cleared $cleared raw items'),
        );
      }
    } finally {
      if (mounted) setState(() => _clearingRaw = false);
      await _reload();
    }
  }

  Future<void> _showEvidence(db.AutoBookEvent event) async {
    String metadata = '';
    if (event.rawMetadataJson?.isNotEmpty == true) {
      try {
        metadata = const JsonEncoder.withIndent('  ')
            .convert(jsonDecode(event.rawMetadataJson!));
      } catch (_) {
        metadata = event.rawMetadataJson!;
      }
    }
    final parts = <String>[
      if (event.rawActor?.isNotEmpty == true)
        '${_copy('来源主体', 'Actor')}: ${event.rawActor}',
      if (event.rawTitle?.isNotEmpty == true)
        '${_copy('标题', 'Title')}: ${event.rawTitle}',
      if (event.rawText?.isNotEmpty == true)
        '${_copy('正文', 'Body')}:\n${event.rawText}',
      if (metadata.isNotEmpty) '${_copy('元数据', 'Metadata')}:\n$metadata',
      '${_copy('捕获时间', 'Captured')}: ${_formatDate(event.capturedAt)}',
      '${_copy('上传状态', 'Upload state')}: ${event.rawEvidenceUploadState}',
    ];
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_sourceLabel(event.source)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(parts.join('\n\n')),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_copy('关闭', 'Close')),
          ),
        ],
      ),
    );
  }

  List<int> _choicesWith(int current) {
    final values = {..._retentionChoices, current}.toList()..sort();
    return values;
  }

  Widget _retentionSelector({
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
    required bool enabled,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          DropdownButton<int>(
            value: value,
            onChanged: enabled
                ? (next) {
                    if (next != null) onChanged(next);
                  }
                : null,
            items: [
              for (final days in _choicesWith(value))
                DropdownMenuItem(
                  value: days,
                  child: Text(_copy('$days 天', '$days days')),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _policyCard({
    required String title,
    required IconData icon,
    required RawEvidenceSourcePolicy policy,
    required ValueChanged<RawEvidenceSourcePolicy> onChanged,
    int? savedCount,
    VoidCallback? onClear,
  }) {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(icon),
            title: Text(title),
            subtitle: savedCount == null
                ? Text(_copy(
                    '未单独设置的来源使用此策略', 'Used by sources without an override'))
                : Text(_copy('已保存 $savedCount 条', '$savedCount saved')),
            trailing: savedCount != null && savedCount > 0
                ? IconButton(
                    tooltip: _copy('清除此来源原文', 'Clear this source'),
                    onPressed: _clearingRaw ? null : onClear,
                    icon: const Icon(Icons.delete_outline),
                  )
                : null,
          ),
          SwitchListTile.adaptive(
            title: Text(_copy('保存在本机', 'Keep on this device')),
            subtitle: Text(_copy(
              '原文只保存在 AutoBookEvents，不进入普通账本同步。',
              'Stored only in AutoBookEvents; never added to normal ledger sync.',
            )),
            value: policy.localEnabled,
            onChanged: _savingPolicy
                ? null
                : (value) => onChanged(policy.copyWith(localEnabled: value)),
          ),
          _retentionSelector(
            label: _copy('本机保留', 'Local retention'),
            value: policy.localRetentionDays,
            enabled: policy.localEnabled && !_savingPolicy,
            onChanged: (days) =>
                onChanged(policy.copyWith(localRetentionDays: days)),
          ),
          const Divider(height: 1),
          SwitchListTile.adaptive(
            title: Text(_copy('允许保存到服务端', 'Allow server storage')),
            subtitle: Text(_copy(
              '独立开关；若关闭本机保留，仅为上传重试暂存，上传后立即清除本机原文。',
              'Independent switch. With local retention off, evidence is queued only until upload succeeds.',
            )),
            value: policy.serverEnabled,
            onChanged: _savingPolicy
                ? null
                : (value) => onChanged(policy.copyWith(serverEnabled: value)),
          ),
          _retentionSelector(
            label: _copy('服务端保留', 'Server retention'),
            value: policy.serverRetentionDays,
            enabled: policy.serverEnabled && !_savingPolicy,
            onChanged: (days) =>
                onChanged(policy.copyWith(serverRetentionDays: days)),
          ),
        ],
      ),
    );
  }

  String _evidencePreview(db.AutoBookEvent event) {
    final text = [event.rawTitle, event.rawText, event.rawActor]
        .whereType<String>()
        .map((value) => value.trim())
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    if (text.isEmpty) return _copy('仅保存元数据', 'Metadata only');
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ');
    return normalized.length > 90
        ? '${normalized.substring(0, 90)}…'
        : normalized;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final totalRaw =
        _rawCounts.values.fold<int>(0, (sum, value) => sum + value);

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
                      Text(
                        _copy('原始证据保留策略', 'Raw evidence retention'),
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Card(
                        color: theme.colorScheme.secondaryContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(_copy(
                            'event_key 在本机唯一；短信、通知、屏幕文本等原文按来源独立配置。本功能不会把原文写入 sync_changes。',
                            'event_key is unique locally. SMS, notification, and screen text policies are configurable per source. Raw content is never written to sync_changes.',
                          )),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _policyCard(
                        title: _copy('其他来源默认策略', 'Default for other sources'),
                        icon: Icons.tune_outlined,
                        policy: _policy.defaultPolicy,
                        onChanged: _saveDefaultPolicy,
                      ),
                      for (final source in _primarySources) ...[
                        const SizedBox(height: 8),
                        _policyCard(
                          title: _sourceLabel(source.value),
                          icon: _sourceIcon(source.value),
                          policy: _policy.forSource(source.value),
                          savedCount: _rawCounts[source.value] ?? 0,
                          onClear: () =>
                              _clearRawEvidence(source: source.value),
                          onChanged: (next) =>
                              _saveSourcePolicy(source.value, next),
                        ),
                      ],
                      const SizedBox(height: 16),
                      SegmentedButton<bool>(
                        segments: [
                          ButtonSegment(
                              value: false,
                              label: Text(_copy('本机', 'Local')),
                              icon: const Icon(Icons.phone_android)),
                          ButtonSegment(
                              value: true,
                              label: Text(_copy('服务端', 'Server')),
                              icon: const Icon(Icons.cloud_outlined)),
                        ],
                        selected: {_showRemote},
                        onSelectionChanged: (value) =>
                            setState(() => _showRemote = value.single),
                      ),
                      const SizedBox(height: 8),
                      if (_showRemote) const RemoteRawEvidencePanel(),
                      if (!_showRemote) ...[
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.inventory_2_outlined),
                            title: Text(_copy('本机原始证据', 'Local raw evidence')),
                            subtitle: Text(_copy(
                              '共 $totalRaw 条；点击下方记录可查看原文。',
                              '$totalRaw items; tap a row to view the original.',
                            )),
                            trailing: IconButton(
                              tooltip: _copy('全部清除', 'Clear all'),
                              onPressed: totalRaw == 0 || _clearingRaw
                                  ? null
                                  : () => _clearRawEvidence(),
                              icon: _clearingRaw
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.delete_sweep_outlined),
                            ),
                          ),
                        ),
                        if (_rawEvidence.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          for (final event in _rawEvidence)
                            Card(
                              child: ListTile(
                                leading: Icon(_sourceIcon(event.source)),
                                title: Text(_sourceLabel(event.source)),
                                subtitle: Text(
                                  '${_evidencePreview(event)}\n${_formatDate(event.capturedAt)}',
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                isThreeLine: true,
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => _showEvidence(event),
                              ),
                            ),
                        ],
                        const SizedBox(height: 16),
                      ],
                      Text(
                        _copy('其他隐私数据', 'Other private data'),
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
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
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.fact_check_outlined),
                          title: Text(l10n.pendingConfirmationTitle),
                          subtitle: Text(
                            l10n.privacyStatsPending(_pendingCount.toString()),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _clearingAttachments || _attachments.isEmpty
                            ? null
                            : _clearAttachments,
                        icon: _clearingAttachments
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
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
