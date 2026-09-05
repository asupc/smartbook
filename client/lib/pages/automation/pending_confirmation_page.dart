import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../ai/core/bill_info.dart';
import '../../data/db.dart' as schema;
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/ai_chat_providers.dart';
import '../../services/billing/pending_candidate.dart';
import '../../services/data/tag_seed_service.dart';
import '../../widgets/ui/primary_header.dart';
import '../../widgets/ui/toast.dart';
import 'auto_book_history_page.dart';

/// 待确认记账队列页(自动记账 M2)。
///
/// 自动路径(截图/短信/支付通知)解析出的「候选交易」—— 低置信 / 大额 /
/// 疑似重复 —— 不直接入账,先进入本队列;用户确认 / 编辑后入账 / 拒绝。
class PendingConfirmationPage extends ConsumerStatefulWidget {
  const PendingConfirmationPage({super.key});

  @override
  ConsumerState<PendingConfirmationPage> createState() =>
      _PendingConfirmationPageState();
}

class _PendingConfirmationPageState
    extends ConsumerState<PendingConfirmationPage> {
  final PendingCandidateStore _store = PendingCandidateStore();
  List<PendingCandidate> _candidates = const [];
  bool _loading = true;
  String _sourceFilter = 'all';
  String _reasonFilter = 'all';
  String _ledgerFilter = 'all';
  String _dateFilter = 'all';
  List<schema.Ledger> _ledgers = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final repo = ref.read(repositoryProvider);
    final list = await _store.loadForReview(
      ref.read(autoBookCoordinatorProvider).store,
    );
    if (_ledgers.isEmpty) {
      try {
        _ledgers = await repo.getAllLedgers();
      } catch (_) {
        _ledgers = const [];
      }
    }
    if (!mounted) return;
    setState(() {
      _candidates = list;
      _loading = false;
    });
    // M2 统计维度 M5?此处刷新交易列表 provider,确认入账后 UI 即时反映
    ref.read(statsRefreshProvider.notifier).state++;
  }

  List<PendingCandidate> get _visibleCandidates {
    return _candidates.where((candidate) {
      final sourceMatches = _sourceFilter == 'all' ||
          candidate.source.toLowerCase().contains(_sourceFilter);
      final reasonMatches = _reasonFilter == 'all' ||
          (candidate.reason ?? '').toLowerCase() == _reasonFilter;
      final ledgerMatches = _ledgerFilter == 'all' ||
          candidate.bill.ledgerId?.toString() == _ledgerFilter;
      final date = candidate.bill.time ?? candidate.capturedAt;
      final now = DateTime.now();
      final dateMatches = switch (_dateFilter) {
        'today' => date.year == now.year &&
            date.month == now.month &&
            date.day == now.day,
        '7d' => date.isAfter(now.subtract(const Duration(days: 7))),
        '30d' => date.isAfter(now.subtract(const Duration(days: 30))),
        _ => true,
      };
      return sourceMatches && reasonMatches && ledgerMatches && dateMatches;
    }).toList();
  }

  String _sourceLabel(String source) {
    switch (source.toLowerCase()) {
      case 'sms':
        return '短信';
      case 'notification':
        return '通知';
      case 'screen':
      case 'screentext':
        return '详情页';
      case 'image':
      case 'screenshot':
      case 'sharedimage':
        return '图片/截图';
      case 'import':
        return '导入';
      case 'recurring':
        return '周期交易';
      default:
        return source;
    }
  }

  Widget _buildFilters(BuildContext context) {
    final theme = Theme.of(context);
    final sourceOptions = <String>[
      'all',
      'sms',
      'notification',
      'screen',
      'image',
      'import',
      'recurring'
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final source in sourceOptions)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label:
                          Text(source == 'all' ? '全部来源' : _sourceLabel(source)),
                      selected: _sourceFilter == source,
                      onSelected: (_) => setState(() => _sourceFilter = source),
                    ),
                  ),
              ],
            ),
          ),
          Row(
            children: [
              Text('原因', style: theme.textTheme.labelMedium),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _reasonFilter,
                isDense: true,
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('全部原因')),
                  const DropdownMenuItem(
                      value: 'duplicate', child: Text('疑似重复')),
                  const DropdownMenuItem(
                      value: 'lowConfidence', child: Text('低置信度')),
                  const DropdownMenuItem(
                      value: 'settlementUnknown', child: Text('结算状态不明')),
                  const DropdownMenuItem(
                      value: 'transferAccountMissing', child: Text('缺少转账账户')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _reasonFilter = value);
                },
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _ledgerFilter,
                isDense: true,
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('全部账本')),
                  ..._ledgers.map((ledger) => DropdownMenuItem(
                        value: ledger.id.toString(),
                        child: Text(ledger.name),
                      )),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _ledgerFilter = value);
                },
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _dateFilter,
                isDense: true,
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('全部日期')),
                  DropdownMenuItem(value: 'today', child: Text('今天')),
                  DropdownMenuItem(value: '7d', child: Text('近 7 天')),
                  DropdownMenuItem(value: '30d', child: Text('近 30 天')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _dateFilter = value);
                },
              ),
              const Spacer(),
              Text('${_visibleCandidates.length}/${_candidates.length}',
                  style: theme.textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }

  String _reasonText(PendingCandidate c, AppLocalizations l10n) {
    switch (c.reason) {
      case 'duplicate':
        return l10n.pendingCandidateReasonDuplicate;
      case 'large':
        return l10n.pendingCandidateReasonLarge;
      case 'anomaly':
        return l10n.pendingCandidateReasonAnomaly;
      case 'lowConfidence':
        return l10n.pendingCandidateReasonLowConfidence;
      case 'settlementUnknown':
        return '结算状态不明确,请核对是否已支付';
      case 'transferAccountMissing':
        return '转账/还款缺少账户,请补充';
      case 'already_processed':
        return '同一账单已处理过';
      default:
        return l10n.pendingConfirmationUncheckedReason;
    }
  }

  Future<bool?> _duplicateChoice(PendingCandidate c) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发现可能重复'),
        content: Text(
          c.matchedTransactionId == null
              ? '这笔账单与已有记录可能重复。请选择处理方式。'
              : '可能命中已有交易 #${c.matchedTransactionId}，请选择处理方式。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('稍后'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('合并到已有交易'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('仍记一笔'),
          ),
        ],
      ),
    );
  }

  Future<void> _approve(PendingCandidate c) async {
    final l10n = AppLocalizations.of(context);
    var forceCreate = false;
    if (c.matchedTransactionId != null || c.reason == 'duplicate') {
      final choice = await _duplicateChoice(c);
      if (choice == null) return;
      forceCreate = choice;
    }
    final bookkeeper = ref.read(aiBookkeeperProvider);
    final txId = await bookkeeper.approvePending(
      c,
      l10n: l10n,
      forceCreate: forceCreate,
    );
    if (!mounted) return;
    if (txId != null) {
      showToast(context, l10n.pendingConfirmationApproved);
    } else {
      showToast(context, l10n.pendingConfirmationApproveFailed,
          duration: const Duration(seconds: 3));
    }
    await _reload();
  }

  Future<void> _reject(PendingCandidate c) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.pendingConfirmationRejectAsk),
        content: Text(c.bill.note ?? c.bill.toJson().toString(),
            maxLines: 3, overflow: TextOverflow.ellipsis),
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
    await ref.read(aiBookkeeperProvider).rejectPending(c);
    if (mounted) showToast(context, l10n.pendingConfirmationRejected);
    await _reload();
  }

  Future<void> _editAndApprove(PendingCandidate c) async {
    final l10n = AppLocalizations.of(context);
    final bill = c.bill;
    final amountCtrl =
        TextEditingController(text: bill.amount?.toString() ?? '');
    final noteCtrl = TextEditingController(text: bill.note ?? '');
    final edited = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.pendingConfirmationEdit),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  InputDecoration(labelText: l10n.pendingConfirmationAmount),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              decoration:
                  InputDecoration(labelText: l10n.pendingConfirmationNote),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.pendingConfirmationConfirm),
          ),
        ],
      ),
    );
    if (edited != true || !mounted) return;
    final amount = double.tryParse(amountCtrl.text.trim().replaceAll(',', ''));
    if (amount == null) {
      showToast(context, l10n.pendingConfirmationEditFailed);
      return;
    }
    final bookkeeper = ref.read(aiBookkeeperProvider);
    final editedCandidate = c.copyWith(
      candidateId: c.id,
      bill: bill.copyWith(amount: amount, note: noteCtrl.text),
    );
    final txId = await bookkeeper.approvePending(
      editedCandidate,
      l10n: l10n,
    );
    if (mounted) {
      if (txId != null) {
        showToast(context, l10n.pendingConfirmationApproved);
      } else {
        showToast(
          context,
          l10n.pendingConfirmationApproveFailed,
          duration: const Duration(seconds: 3),
        );
      }
    }
    await _reload();
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
            title: l10n.pendingConfirmationTitle,
            showBack: true,
            leadingIcon: Icons.fact_check_outlined,
            leadingPlain: true,
            actions: [
              IconButton(
                tooltip: '自动记账历史',
                icon: const Icon(Icons.history),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AutoBookHistoryPage(),
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    children: [
                      if (_candidates.isNotEmpty) _buildFilters(context),
                      Expanded(
                        child: _visibleCandidates.isEmpty
                            ? Center(
                                child: Text(
                                  l10n.pendingConfirmationEmpty,
                                  style: TextStyle(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.6)),
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.all(16),
                                itemCount: _visibleCandidates.length,
                                itemBuilder: (context, index) {
                                  final c = _visibleCandidates[index];
                                  final bill = c.bill;
                                  return Card(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Icon(
                                                bill.type == BillType.income
                                                    ? Icons.south_west
                                                    : bill.type ==
                                                            BillType.transfer
                                                        ? Icons.swap_horiz
                                                        : Icons.north_east,
                                                color:
                                                    theme.colorScheme.primary,
                                                size: 18,
                                              ),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: Text(
                                                  bill.note ??
                                                      l10n.pendingConfirmationUncheckedReason,
                                                  style: theme
                                                      .textTheme.titleMedium,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              Text(
                                                bill.amount
                                                        ?.toStringAsFixed(2) ??
                                                    '-',
                                                style: theme
                                                    .textTheme.titleMedium
                                                    ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w700),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          Wrap(
                                            spacing: 8,
                                            crossAxisAlignment:
                                                WrapCrossAlignment.center,
                                            children: [
                                              if (c.bill.category != null &&
                                                  c.bill.category!.isNotEmpty)
                                                _chip(
                                                    context, c.bill.category!),
                                              ...TagSeedService
                                                      .getBillingTagNames(
                                                          c.billingTypes, l10n)
                                                  .map(
                                                      (t) => _chip(context, t)),
                                              Text(
                                                c.bill.time
                                                        ?.toString()
                                                        .split(' ')
                                                        .first ??
                                                    '',
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                  color: theme
                                                      .colorScheme.onSurface
                                                      .withValues(alpha: 0.5),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          // 待确认原因(疑似重复/大额/低置信)
                                          if (c.reason != null)
                                            Row(
                                              children: [
                                                const Icon(Icons.info_outline,
                                                    size: 14,
                                                    color: Colors.orange),
                                                const SizedBox(width: 4),
                                                Expanded(
                                                  child: Text(
                                                    _reasonText(c, l10n),
                                                    style: theme
                                                        .textTheme.bodySmall
                                                        ?.copyWith(
                                                      color: Colors.orange,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          if (c.matchedTransactionId != null)
                                            Padding(
                                              padding:
                                                  const EdgeInsets.only(top: 4),
                                              child: Text(
                                                '可能与已有交易 #${c.matchedTransactionId} 重复${c.matchScore == null ? '' : '（匹配度 ${(c.matchScore! * 100).round()}%）'}',
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                  color: theme
                                                      .colorScheme.secondary,
                                                ),
                                              ),
                                            ),
                                          Padding(
                                            padding:
                                                const EdgeInsets.only(top: 4),
                                            child: Text(
                                              '来源：${_sourceLabel(c.source)}',
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                color: theme
                                                    .colorScheme.onSurface
                                                    .withValues(alpha: 0.55),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: OutlinedButton(
                                                  onPressed: () => _reject(c),
                                                  child: Text(l10n
                                                      .pendingConfirmationReject),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: OutlinedButton(
                                                  onPressed: () =>
                                                      _editAndApprove(c),
                                                  child: Text(l10n
                                                      .pendingConfirmationEdit),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: FilledButton(
                                                  onPressed: () => _approve(c),
                                                  child: Text(l10n
                                                      .pendingConfirmationConfirm),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}
