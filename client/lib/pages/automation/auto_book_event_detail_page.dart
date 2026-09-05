import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart' as schema;
import '../../l10n/app_localizations.dart';
import '../../providers/ai_chat_providers.dart';
import '../../providers/automation_providers.dart';
import '../../widgets/ui/primary_header.dart';
import '../../widgets/ui/toast.dart';
import '../transaction/transaction_editor_page.dart';

/// 自动记账事件详情页(ux-optimization-plan P1-2)。
///
/// 历史页列表项不可点、错误不可见曾是诊断死角;这里展示九态全量状态机:
/// 状态/原因/lastError/原始证据(按留存策略,已清理则明示)/解析子项/
/// 重复命中交易跳转/手动重试。原始证据展示口径与隐私面板一致:只展示
/// 本地仍留存的,不留存或已过期时说明原因,不虚构。
class AutoBookEventDetailPage extends ConsumerStatefulWidget {
  const AutoBookEventDetailPage({super.key, required this.event});

  final schema.AutoBookEvent event;

  @override
  ConsumerState<AutoBookEventDetailPage> createState() =>
      _AutoBookEventDetailPageState();
}

class _AutoBookEventDetailPageState
    extends ConsumerState<AutoBookEventDetailPage> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final event = widget.event;
    final color = _stateColor(context, event.state);

    return Scaffold(
      body: Column(
        children: [
          PrimaryHeader(
            title: l10n.autoBookDetailTitle,
            showBack: true,
            leadingIcon: Icons.bolt,
            leadingPlain: true,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 状态卡
                _card(theme, children: [
                  Row(
                    children: [
                      Chip(
                        label: Text(_stateLabel(event.state)),
                        visualDensity: VisualDensity.compact,
                        side: BorderSide.none,
                        backgroundColor: color.withValues(alpha: 0.12),
                        labelStyle: TextStyle(color: color),
                      ),
                      const SizedBox(width: 8),
                      Text(_sourceLabel(event.source)),
                      if ((event.sourceChannel ?? '').isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text('· ${event.sourceChannel}',
                            style: theme.textTheme.bodySmall),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  _kv(l10n.autoBookDetailState, _stateLabel(event.state)),
                  _kv(l10n.autoBookDetailSource, _sourceLabel(event.source)),
                  _kv(l10n.autoBookDetailCapturedAt,
                      _formatTime(event.capturedAt)),
                  _kv(
                      l10n.autoBookDetailUpdatedAt, _formatTime(event.updatedAt)),
                  _kv(l10n.autoBookDetailAttempts, '${event.attemptCount}'),
                  if (event.nextRetryAt != null)
                    _kv(l10n.autoBookDetailRetry,
                        _formatTime(event.nextRetryAt!)),
                ]),

                // 原因 / 错误卡
                if ((event.reason ?? '').isNotEmpty ||
                    (event.lastError ?? '').isNotEmpty)
                  _card(theme, children: [
                    if ((event.reason ?? '').isNotEmpty)
                      _kv(l10n.autoBookDetailReason, event.reason!),
                    if ((event.lastError ?? '').isNotEmpty) ...[
                      if ((event.reason ?? '').isNotEmpty)
                        const SizedBox(height: 8),
                      _kv(l10n.autoBookDetailError, event.lastError!),
                    ],
                  ]),

                // 原始证据卡(按留存策略展示;不存在时明示,不虚构)
                _card(theme, children: [
                  Text(l10n.autoBookDetailEvidence,
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  _hasRawEvidence(event)
                      ? SelectableText(
                          [
                            if ((event.rawActor ?? '').isNotEmpty)
                              event.rawActor!,
                            if ((event.rawTitle ?? '').isNotEmpty)
                              event.rawTitle!,
                            if ((event.rawText ?? '').isNotEmpty)
                              event.rawText!,
                          ].join('\n'),
                          style: theme.textTheme.bodySmall,
                        )
                      : Text(l10n.autoBookDetailEvidenceCleared,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color:
                                theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          )),
                ]),

                // 解析子项卡
                _card(theme, children: [
                  Text(l10n.autoBookDetailItems,
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  FutureBuilder<List<schema.AutoBookEventItem>>(
                    future: ref
                        .read(autoBookCoordinatorProvider)
                        .store
                        .itemsForEvent(event.id),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Padding(
                          padding: EdgeInsets.all(8),
                          child: Center(
                              child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))),
                        );
                      }
                      final items = snapshot.data ?? const [];
                      if (items.isEmpty) {
                        return Text(l10n.autoBookDetailNoItems,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.6),
                            ));
                      }
                      return Column(
                        children: [
                          for (final item in items)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: _stateColor(
                                          context, item.state),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      [
                                        '#${item.itemIndex}',
                                        if (item.amount != null)
                                          '¥${item.amount!.toStringAsFixed(2)}',
                                        if ((item.merchant ?? '')
                                            .trim()
                                            .isNotEmpty)
                                          item.merchant!,
                                        _stateLabel(item.state),
                                        if ((item.reason ?? '')
                                            .trim()
                                            .isNotEmpty)
                                          item.reason!,
                                      ].join(' · '),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ),
                                  if (item.transactionId != null)
                                    TextButton(
                                      onPressed: () => _openTransaction(
                                          item.transactionId!),
                                      child: Text(
                                        l10n.autoBookDetailOpenTx(
                                            item.transactionId!),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ]),

                // 关联交易卡
                if (event.transactionId != null ||
                    event.duplicateOfTransactionId != null)
                  _card(theme, children: [
                    Text(l10n.autoBookDetailRelatedTx,
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    if (event.transactionId != null)
                      TextButton(
                        onPressed: () =>
                            _openTransaction(event.transactionId!),
                        child: Text(l10n.autoBookDetailOpenTx(
                            event.transactionId!)),
                      ),
                    if (event.duplicateOfTransactionId != null)
                      TextButton(
                        onPressed: () => _openTransaction(
                            event.duplicateOfTransactionId!),
                        child: Text(
                            '${l10n.autoBookDetailOpenTx(event.duplicateOfTransactionId!)} (duplicate)'),
                      ),
                  ]),

                // 手动重试(P1-2):retry/failed 事件清退避闸门重跑原通道
                if (event.state == 'retry' || event.state == 'failed')
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FilledButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.autoBookDetailRetry),
                    ),
                  ),

                // 撤销合并(P1-1):强判重吞掉的真实消费可恢复为待确认候选
                if (event.state == 'duplicate')
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OutlinedButton.icon(
                      onPressed: _undoMerge,
                      icon: const Icon(Icons.undo),
                      label: Text(l10n.autoBookUndoMerge),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _hasRawEvidence(schema.AutoBookEvent event) {
    return (event.rawTitle?.isNotEmpty ?? false) ||
        (event.rawText?.isNotEmpty ?? false) ||
        (event.rawActor?.isNotEmpty ?? false) ||
        (event.rawMetadataJson?.isNotEmpty ?? false);
  }

  Future<void> _retry() async {
    final l10n = AppLocalizations.of(context);
    try {
      final replayed =
          await ref.read(autoBillingServiceProvider).retryDraft(widget.event);
      if (!mounted) return;
      showToast(
        context,
        replayed
            ? AppLocalizations.of(context).automationDraftsRetryQueued
            : l10n.automationDraftsDiscarded,
      );
    } catch (e) {
      if (mounted) showToast(context, '$e');
    }
  }

  /// 撤销强判重合并(P1-1):重建候选进待确认,事件转 pending。
  Future<void> _undoMerge() async {
    final l10n = AppLocalizations.of(context);
    try {
      final rebuilt =
          await ref.read(aiBookkeeperProvider).undoMerge(widget.event);
      if (!mounted) return;
      showToast(
        context,
        rebuilt > 0 ? l10n.autoBookUndoMergeDone : l10n.autoBookUndoMergeEmpty,
        duration: const Duration(seconds: 3),
      );
    } catch (e) {
      if (mounted) showToast(context, '$e');
    }
  }

  Future<void> _openTransaction(int transactionId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TransactionEditorPage(
          initialKind: 'expense',
          editingTransactionId: transactionId,
        ),
      ),
    );
  }

  Widget _card(ThemeData theme, {required List<Widget> children}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(padding: const EdgeInsets.all(14), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      )),
    );
  }

  Widget _kv(String k, String v) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(k,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              )),
        ),
        Expanded(
          child: SelectableText(v, style: theme.textTheme.bodySmall),
        ),
      ],
    );
  }

  String _formatTime(DateTime t) {
    final local = t.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
  }

  // 与历史页同口径的状态/来源标签(两页各自私有,避免跨页面耦合)
  String _stateLabel(String state) => switch (state) {
        'captured' => '已捕获',
        'processing' => '处理中',
        'pending' => '待确认',
        'booked' => '已入账',
        'duplicate' => '已去重',
        'ignored' => '已忽略',
        'retry' => '待重试',
        'failed' => '失败',
        'expired' => '已过期',
        _ => state,
      };

  Color _stateColor(BuildContext context, String state) {
    final scheme = Theme.of(context).colorScheme;
    return switch (state) {
      'booked' => Colors.green,
      'duplicate' => scheme.secondary,
      'pending' => Colors.orange,
      'retry' || 'failed' => scheme.error,
      'ignored' || 'expired' => scheme.outline,
      _ => scheme.primary,
    };
  }

  String _sourceLabel(String source) => switch (source) {
        'sms' => '短信',
        'notification' => '通知',
        'screenText' => '详情页',
        'screenshot' => '截图',
        'sharedImage' => '分享图片',
        'import' => '导入',
        'recurring' => '周期交易',
        'deepLinkText' || 'deepLinkDirect' => 'Deep Link',
        _ => source,
      };
}
