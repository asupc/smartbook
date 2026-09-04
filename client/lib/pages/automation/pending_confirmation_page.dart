import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../ai/core/bill_info.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/ai_chat_providers.dart';
import '../../services/billing/pending_candidate.dart';
import '../../services/data/tag_seed_service.dart';
import '../../widgets/ui/primary_header.dart';
import '../../widgets/ui/toast.dart';

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

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await _store.load();
    if (!mounted) return;
    setState(() {
      _candidates = list;
      _loading = false;
    });
    // M2 统计维度 M5?此处刷新交易列表 provider,确认入账后 UI 即时反映
    ref.read(statsRefreshProvider.notifier).state++;
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
      default:
        return l10n.pendingConfirmationUncheckedReason;
    }
  }

  Future<void> _approve(PendingCandidate c) async {
    final l10n = AppLocalizations.of(context);
    final bookkeeper = ref.read(aiBookkeeperProvider);
    final txId = await bookkeeper.approvePending(c, l10n: l10n);
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
    await _store.remove(c.id);
    if (mounted) showToast(context, l10n.pendingConfirmationRejected);
    await _reload();
  }

  Future<void> _editAndApprove(PendingCandidate c) async {
    final l10n = AppLocalizations.of(context);
    final bill = c.bill;
    final amountCtrl = TextEditingController(text: bill.amount?.toString() ?? '');
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
              decoration: InputDecoration(labelText: l10n.pendingConfirmationAmount),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              decoration: InputDecoration(labelText: l10n.pendingConfirmationNote),
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
    await _store.remove(c.id);
    final bookkeeper = ref.read(aiBookkeeperProvider);
    await bookkeeper.approvePending(
      c.copyWith(bill: bill.copyWith(amount: amount, note: noteCtrl.text)),
      l10n: l10n,
    );
    if (mounted) showToast(context, l10n.pendingConfirmationApproved);
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
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _candidates.isEmpty
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
                        itemCount: _candidates.length,
                        itemBuilder: (context, index) {
                          final c = _candidates[index];
                          final bill = c.bill;
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        bill.type == BillType.income
                                            ? Icons.south_west
                                            : bill.type == BillType.transfer
                                                ? Icons.swap_horiz
                                                : Icons.north_east,
                                        color: theme.colorScheme.primary,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          bill.note ?? l10n.pendingConfirmationUncheckedReason,
                                          style: theme.textTheme.titleMedium,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Text(
                                        bill.amount?.toStringAsFixed(2) ?? '-',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                                fontWeight: FontWeight.w700),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 8,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [
                                      if (c.bill.category != null &&
                                          c.bill.category!.isNotEmpty)
                                        _chip(context, c.bill.category!),
                                      ...TagSeedService.getBillingTagNames(
                                              c.billingTypes, l10n)
                                          .map((t) => _chip(context, t)),
                                      Text(
                                        c.bill.time?.toString().split(' ').first ??
                                            '',
                                        style:
                                            theme.textTheme.bodySmall?.copyWith(
                                          color: theme.colorScheme.onSurface
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
                                            size: 14, color: Colors.orange),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            _reasonText(c, l10n),
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                              color: Colors.orange,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton(
                                          onPressed: () => _reject(c),
                                          child: Text(l10n.pendingConfirmationReject),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: OutlinedButton(
                                          onPressed: () => _editAndApprove(c),
                                          child: Text(l10n.pendingConfirmationEdit),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: FilledButton(
                                          onPressed: () => _approve(c),
                                          child: Text(l10n.pendingConfirmationConfirm),
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
