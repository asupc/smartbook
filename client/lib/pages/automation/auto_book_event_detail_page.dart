import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/core/bill_info.dart';
import '../../data/db.dart' as schema;
import '../../l10n/app_localizations.dart';
import '../../providers/ai_chat_providers.dart';
import '../../providers/automation_providers.dart';
import '../../services/automation/auto_book_reason_presenter.dart';
import '../../widgets/ui/primary_header.dart';
import '../../widgets/ui/toast.dart';
import '../transaction/transaction_editor_page.dart';

/// 自动记账事件详情页(ux-optimization-plan P1-2)。
///
/// 历史页列表项不可点、错误不可见曾是诊断死角;这里展示九态全量状态机:
/// 状态/原因/lastError/原始证据(不存在则明示)/解析子项/重复命中交易
/// 跳转/手动重试。原始证据只展示本地仍留存的,不留存时说明原因,不虚构。
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
    final reasonView = AutoBookReasonPresenter.present(l10n,
        reason: event.reason, state: event.state, lastError: event.lastError);

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

                // 原因卡:面向用户的可读原因;内部原因码与错误只进可展开诊断区
                if ((event.reason ?? '').isNotEmpty ||
                    (event.lastError ?? '').isNotEmpty)
                  _card(theme, children: [
                    _kv(
                      l10n.autoBookDetailReason,
                      AutoBookReasonPresenter.present(l10n,
                              reason: event.reason, state: event.state)
                          .title,
                    ),
                    if (_reasonDiagnostic(event) != null) ...[
                      const SizedBox(height: 4),
                      Theme(
                        data: theme.copyWith(
                            dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(bottom: 8),
                          leading: Icon(Icons.bug_report_outlined,
                              size: 18, color: theme.hintColor),
                          title: Text(
                            l10n.autoBookDetailDiagnostics,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.hintColor),
                          ),
                          children: [
                            SelectableText(
                              _reasonDiagnostic(event)!,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(fontFamily: 'monospace'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ]),

                // 原始证据卡(不存在时明示,不虚构)
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
                                          AutoBookReasonPresenter.present(
                                                  l10n,
                                                  reason: item.reason,
                                                  state: item.state)
                                              .title,
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

                // 手动补记(B1 任务 4):硬过滤事件(缺时间/推测时间等)未入账,
                // 用户主动补记时带入**仍可用的可信字段**;时间缺失或为模型
                // 推测时绝不带入,由用户在编辑器里确认。
                if (reasonView.canManualAdd)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: _manualAdd,
                          icon: const Icon(Icons.edit_note),
                          label: Text(l10n.autoBookManualAdd),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.autoBookManualAddTimeHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.hintColor,
                          ),
                        ),
                      ],
                    ),
                  ),

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

  /// 内部原因码 + 错误信息,仅诊断区展示。
  String? _reasonDiagnostic(schema.AutoBookEvent event) {
    final code = (event.reason ?? '').trim();
    final err = (event.lastError ?? '').trim();
    if (code.isEmpty && err.isEmpty) return null;
    if (code.isEmpty) return err;
    if (err.isEmpty) return code;
    return '$code\n$err';
  }

  /// 手动补记:从事件子项里挑仍可用的结构化摘要,带入可信字段打开编辑器。
  /// 多笔时先让用户选;没有任何可用摘要时明示不可恢复,不虚构数据。
  Future<void> _manualAdd() async {
    final l10n = AppLocalizations.of(context);
    final store = ref.read(autoBookCoordinatorProvider).store;
    List<schema.AutoBookEventItem> items;
    try {
      items = await store.itemsForEvent(widget.event.id);
    } catch (_) {
      items = const [];
    }
    final usable = items
        .where((i) =>
            (i.billJson ?? '').isNotEmpty && i.transactionId == null)
        .toList();
    if (usable.isEmpty) {
      if (mounted) showToast(context, l10n.autoBookManualAddUnavailable);
      return;
    }
    if (usable.length == 1) {
      await _openManualEditor(usable.first);
      return;
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<schema.AutoBookEventItem>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(l10n.autoBookManualAddPickItem,
                  style: Theme.of(ctx).textTheme.titleSmall),
            ),
            for (final item in usable)
              ListTile(
                title: Text([
                  if (item.amount != null) '¥${item.amount!.toStringAsFixed(2)}',
                  if ((item.merchant ?? '').trim().isNotEmpty) item.merchant!,
                ].join(' · ')),
                subtitle: Text(AutoBookReasonPresenter.present(l10n,
                        reason: item.reason, state: item.state)
                    .title),
                onTap: () => Navigator.pop(ctx, item),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await _openManualEditor(picked);
  }

  Future<void> _openManualEditor(schema.AutoBookEventItem item) async {
    final l10n = AppLocalizations.of(context);
    BillInfo? bill;
    try {
      final raw = jsonDecode(item.billJson!);
      if (raw is Map<String, dynamic>) bill = BillInfo.fromJson(raw);
    } catch (_) {
      bill = null;
    }
    if (bill == null) {
      if (mounted) showToast(context, l10n.autoBookManualAddUnavailable);
      return;
    }
    // 可信时间:非模型推测且精度到分钟以上。缺时间/推测时间一律不带入,
    // 由用户在编辑器里确认(计划 §3.3)。
    final trustedTime = bill.time != null &&
        !bill.timeInferred &&
        (bill.timePrecision == BillTimePrecision.exact ||
            bill.timePrecision == BillTimePrecision.minute);
    if (!trustedTime && mounted) {
      showToast(context, l10n.autoBookManualAddTimeHint);
    }
    final billInfo = bill;
    final kind = switch (billInfo.type) {
      BillType.income => 'income',
      BillType.transfer => 'transfer',
      _ => 'expense',
    };
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TransactionEditorPage(
          initialKind: kind,
          initialAmount: billInfo.amount?.abs(),
          initialNote: billInfo.merchant ?? billInfo.note,
          initialDate: trustedTime ? billInfo.time : null,
        ),
      ),
    );
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

  // 与历史页同口径的状态/来源标签(统一在 AutoBookReasonPresenter)
  String _stateLabel(String state) =>
      AutoBookReasonPresenter.stateLabel(state);

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

  String _sourceLabel(String source) =>
      AutoBookReasonPresenter.sourceLabel(source);
}
