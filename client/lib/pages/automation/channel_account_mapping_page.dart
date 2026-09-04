import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../services/billing/channel_account_store.dart';
import '../../widgets/ui/primary_header.dart';
import '../../widgets/ui/toast.dart';

/// 渠道→账户映射页(M4-B,文档 plan §M4 任务 3)。
///
/// 规则 = 渠道名(短信 sender / 通知 pkg 解析出的,如"招商银行"/"支付宝")→
/// 资产账户。自动记账时 AI 未识别出账户时按来源渠道回退到映射账户。
class ChannelAccountMappingPage extends ConsumerStatefulWidget {
  const ChannelAccountMappingPage({super.key});

  @override
  ConsumerState<ChannelAccountMappingPage> createState() =>
      _ChannelAccountMappingPageState();
}

class _ChannelAccountMappingPageState
    extends ConsumerState<ChannelAccountMappingPage> {
  final ChannelAccountStore _store = ChannelAccountStore();
  List<ChannelAccountRule> _rules = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final rules = await _store.load();
    if (!mounted) return;
    setState(() {
      _rules = rules;
      _loading = false;
    });
  }

  /// 添加/覆盖映射:渠道名 + 账户下拉选择。
  Future<void> _addRule(List<Account> accounts) async {
    final l10n = AppLocalizations.of(context);
    final channelCtrl = TextEditingController();
    int? accountId;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(l10n.channelMappingAdd),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: channelCtrl,
                decoration:
                    InputDecoration(labelText: l10n.channelMappingChannelLabel),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                value: accountId,
                decoration:
                    InputDecoration(labelText: l10n.channelMappingAccountLabel),
                items: accounts
                    .map((a) => DropdownMenuItem(
                          value: a.id,
                          child: Text(
                            a.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ))
                    .toList(),
                onChanged: (v) =>
                    setDialogState(() => accountId = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () {
                final channel = channelCtrl.text.trim();
                if (channel.isEmpty || accountId == null) return;
                Navigator.pop(ctx, true);
              },
              child: Text(l10n.commonConfirm),
            ),
          ],
        ),
      ),
    );
    if (saved == true && accountId != null) {
      final channel = channelCtrl.text.trim();
      await _store.upsert(ChannelAccountRule(
        channelName: channel,
        accountId: accountId!,
      ));
      if (mounted) showToast(context, l10n.channelMappingSaved);
      await _reload();
    }
  }

  Future<void> _deleteRule(ChannelAccountRule rule) async {
    final l10n = AppLocalizations.of(context);
    await _store.remove(rule.channelName);
    if (mounted) showToast(context, l10n.channelMappingDeleted);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final accounts = ref.watch(allAccountsStreamProvider).valueOrNull ?? const [];

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Column(
        children: [
          PrimaryHeader(
            title: l10n.channelMappingTitle,
            showBack: true,
            leadingIcon: Icons.swap_horiz,
            leadingPlain: true,
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
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
                                child: Text(
                                  l10n.channelMappingDesc,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_rules.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(
                            child: Text(
                              l10n.channelMappingEmpty,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                        )
                      else
                        ..._rules.map(
                          (rule) => Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: const Icon(Icons.link),
                              title: Text(rule.channelName),
                              subtitle: Text(
                                accounts
                                    .where((a) => a.id == rule.accountId)
                                    .map((a) => a.name)
                                    .firstOrNull ??
                                    '#${rule.accountId}',
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _deleteRule(rule),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: Text(l10n.channelMappingAdd),
                  onPressed: accounts.isEmpty
                      ? null
                      : () => _addRule(accounts),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
