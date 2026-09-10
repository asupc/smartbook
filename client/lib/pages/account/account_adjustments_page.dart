import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart' as db;
import '../../providers.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../styles/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../utils/currencies.dart';

/// 账户的余额调整记录列表(v42)。「调整余额」不再落交易,历史统一在这里看:
/// 每条显示带符号差额 + 调整前后余额快照 + 时间。
///
/// 调整记录是**对账审计数据,append-only**:只增不删(用户决策)。记错就
/// 反向再调一笔,余额口径始终可回溯。
class AccountAdjustmentsPage extends ConsumerStatefulWidget {
  const AccountAdjustmentsPage({
    super.key,
    required this.account,
  });

  final db.Account account;

  @override
  ConsumerState<AccountAdjustmentsPage> createState() =>
      _AccountAdjustmentsPageState();
}

class _AccountAdjustmentsPageState
    extends ConsumerState<AccountAdjustmentsPage> {
  Future<List<db.AccountAdjustment>>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<db.AccountAdjustment>> _load() {
    return ref.read(repositoryProvider).getAccountAdjustments(widget.account.id);
  }

  String _formatAmount(double v, String currency) {
    final sign = v > 0 ? '+' : '';
    return '$sign${v.toStringAsFixed(2)} ${getCurrencySymbol(currency)}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final account = widget.account;

    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      body: Column(
        children: [
          PrimaryHeader(
            title: l10n.accountAdjustmentsTitle,
            subtitle: account.name,
            showBack: true,
            compact: true,
          ),
          Expanded(
            child: FutureBuilder<List<db.AccountAdjustment>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final records = snap.data ?? [];
                if (records.isEmpty) {
                  return Center(
                    child: Text(
                      l10n.accountAdjustmentsEmpty,
                      style: TextStyle(color: BeeTokens.textSecondary(context)),
                    ),
                  );
                }
                return ListView.separated(
                  padding: EdgeInsets.symmetric(
                    horizontal: 12.0.scaled(context, ref),
                    vertical: 8.0.scaled(context, ref),
                  ),
                  itemCount: records.length,
                  separatorBuilder: (_, __) => SizedBox(
                    height: 8.0.scaled(context, ref),
                  ),
                  itemBuilder: (context, i) {
                    final adj = records[i];
                    final isIncrease = adj.amount >= 0;
                    return SectionCard(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12.0.scaled(context, ref),
                          vertical: 4.0.scaled(context, ref),
                        ),
                        leading: Icon(
                          isIncrease
                              ? Icons.arrow_upward_rounded
                              : Icons.arrow_downward_rounded,
                          color: isIncrease
                              ? BeeTokens.success(context)
                              : BeeTokens.error(context),
                        ),
                        title: Text(
                          _formatAmount(adj.amount, account.currency),
                          style: TextStyle(
                            color: isIncrease
                                ? BeeTokens.success(context)
                                : BeeTokens.error(context),
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                        subtitle: Text(
                          '${_fmtDate(adj.happenedAt)}'
                          '${adj.balanceBefore != null && adj.balanceAfter != null ? '\n${adj.balanceBefore!.toStringAsFixed(2)} → ${adj.balanceAfter!.toStringAsFixed(2)}' : ''}'
                          '${adj.note?.isNotEmpty == true ? '\n${adj.note}' : ''}',
                          style: TextStyle(color: BeeTokens.textSecondary(context)),
                        ),

                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _fmtDate(DateTime d) {
    final local = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
}
