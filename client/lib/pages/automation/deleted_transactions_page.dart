import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart' as schema;
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../widgets/ui/toast.dart';

/// 最近删除页(回收站,v43):删除的交易在本地暂存 30 天,可恢复/彻底删除。
///
/// 与服务端回收站(0030)各自独立:本地删除已向云端发 delete change,云端
/// 同样进它自己的回收站;本页恢复只作用于本机视图(云端恢复走 Web 回收站)。
class DeletedTransactionsPage extends ConsumerStatefulWidget {
  const DeletedTransactionsPage({super.key});

  @override
  ConsumerState<DeletedTransactionsPage> createState() =>
      _DeletedTransactionsPageState();
}

class _DeletedTransactionsPageState
    extends ConsumerState<DeletedTransactionsPage> {
  List<schema.DeletedTransaction> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final repo = ref.read(repositoryProvider);
    final items = await repo.listDeletedTransactions();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _restore(schema.DeletedTransaction item) async {
    final repo = ref.read(repositoryProvider);
    final ok = await repo.restoreDeletedTransaction(item.id) != null;
    if (!mounted) return;
    showToast(
      context,
      ok
          ? AppLocalizations.of(context).trashRestored
          : AppLocalizations.of(context).trashRestoreFailed,
    );
    if (ok) {
      ref.read(statsRefreshProvider.notifier).state++;
    }
    await _reload();
  }

  Future<void> _purge(schema.DeletedTransaction item) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.trashPurgeTitle),
        content: Text(l10n.trashPurgeAsk(
          item.txType == 'income' ? '+' : '-', item.amount.toStringAsFixed(2))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.trashPurgeConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(repositoryProvider).purgeDeletedTransaction(item.id);
    await _reload();
  }

  String _typeLabel(String type, AppLocalizations l10n) {
    return switch (type) {
      'income' => l10n.trashTypeIncome,
      'transfer' => l10n.trashTypeTransfer,
      _ => l10n.trashTypeExpense,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.trashTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.delete_outline,
                          size: 48,
                          color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 12),
                      Text(l10n.trashEmpty,
                          style:
                              Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 4),
                      Text(
                        l10n.trashRetentionHint,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.outline),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (ctx, i) {
                    final item = _items[i];
                    final isIncome = item.txType == 'income';
                    final daysLeft = 30 -
                        DateTime.now()
                            .difference(item.deletedAt)
                            .inDays;
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: Text(
                          isIncome ? '+' : '-',
                          style: TextStyle(
                            color: isIncome
                                ? Colors.green.shade700
                                : Theme.of(context).colorScheme.error,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      title: Text(
                        '${isIncome ? '+' : '-'}${item.amount.toStringAsFixed(2)}'
                        ' · ${_typeLabel(item.txType, l10n)}',
                      ),
                      subtitle: Text(
                        '${l10n.trashDeletedAt} ${item.deletedAt.month}/${item.deletedAt.day}'
                        ' · ${l10n.trashDaysLeft(daysLeft < 0 ? 0 : daysLeft)}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => _restore(item),
                            child: Text(l10n.trashRestore),
                          ),
                          IconButton(
                            icon: Icon(Icons.delete_forever,
                                color: Theme.of(context).colorScheme.error),
                            tooltip: l10n.trashPurgeTitle,
                            onPressed: () => _purge(item),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
