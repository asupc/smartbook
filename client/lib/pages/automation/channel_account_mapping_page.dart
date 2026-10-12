import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';

import '../../models/ledger_display_item.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../services/billing/channel_account_store.dart';
import '../../widgets/ui/primary_header.dart';
import '../../widgets/ui/toast.dart';

/// 用户账户规则(渠道→账户)管理页(B2 任务 5/6)。
///
/// 规则 = 渠道名 + 目标账户 + **作用账本 / 适用来源 / 可选卡尾号 / 币种**。
/// 命中且有效的规则**优先于 AI 猜测**;命中但无法验证(账户已删/隐藏/币种
/// 不符)会把该笔账单送进待确认,不静默回落。
///
/// B2 之前创建的规则没有作用账本,统一显示为「旧版渠道规则」,需用户确认
/// 作用账本后才进入新优先级路径;未确认前保持旧兼容路径(AI 未给账户名时
/// 才生效),不会被自动推广到所有账本。
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

  String _accountName(int accountId, List<Account> accounts) =>
      accounts.firstWhereOrNull((a) => a.id == accountId)?.name ??
      '#$accountId';

  /// 添加/覆盖规则:渠道 + 账户 + 作用域。
  Future<void> _addRule(
      List<Account> accounts, List<LedgerDisplayItem> ledgers, int defaultLedgerId) async {
    final l10n = AppLocalizations.of(context);
    final channelCtrl = TextEditingController();
    final cardCtrl = TextEditingController();
    int? accountId;
    int? ledgerId = defaultLedgerId;
    final sources = <String>{};
    String? currency;

    final currencies = <String>{
      for (final a in accounts) a.currency.toUpperCase(),
    }.toList()
      ..sort();

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(l10n.channelMappingAdd),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
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
                  decoration: InputDecoration(
                      labelText: l10n.channelMappingAccountLabel),
                  items: accounts
                      .map((a) => DropdownMenuItem(
                            value: a.id,
                            child: Text(a.name,
                                overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (v) => setDialogState(() => accountId = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  value: ledgerId,
                  decoration: InputDecoration(
                      labelText: l10n.channelMappingScopeLedger),
                  items: ledgers
                      .map((l) => DropdownMenuItem(
                            value: l.id,
                            child: Text(l.name,
                                overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (v) => setDialogState(() => ledgerId = v),
                ),
                const SizedBox(height: 12),
                Text(l10n.channelMappingSources,
                    style: Theme.of(ctx).textTheme.bodySmall),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final key in const [
                      'sms',
                      'notification',
                      'screen',
                      'image',
                    ])
                      FilterChip(
                        label: Text(_sourceLabel(l10n, key)),
                        selected: sources.contains(key),
                        onSelected: (v) => setDialogState(() {
                          v ? sources.add(key) : sources.remove(key);
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: cardCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(4),
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: InputDecoration(
                          labelText: l10n.channelMappingCardLast4,
                          helperText: l10n.channelMappingCardLast4Hint,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: currency,
                        decoration: InputDecoration(
                            labelText: l10n.channelMappingCurrency),
                        items: [
                          DropdownMenuItem<String>(
                              value: '',
                              child: Text(l10n.channelMappingCurrencyAny)),
                          for (final c in currencies)
                            DropdownMenuItem<String>(
                                value: c, child: Text(c)),
                        ],
                        onChanged: (v) =>
                            setDialogState(() => currency = (v ?? '').isEmpty ? null : v),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () {
                if (channelCtrl.text.trim().isEmpty || accountId == null) {
                  return;
                }
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
      final last4 = cardCtrl.text.trim();
      await _store.upsert(ChannelAccountRule(
        channelName: channel,
        accountId: accountId!,
        ledgerId: ledgerId,
        sources: sources.toList(),
        cardLast4: last4.isEmpty ? null : last4,
        currency: currency,
      ));
      if (mounted) showToast(context, l10n.channelMappingSaved);
      await _reload();
    }
  }

  String _sourceLabel(AppLocalizations l10n, String key) => switch (key) {
        'sms' => l10n.channelMappingSourceSms,
        'notification' => l10n.channelMappingSourceNotify,
        'screen' => l10n.channelMappingSourceScreen,
        'image' => l10n.channelMappingSourceImage,
        _ => key,
      };

  /// 旧版规则确认作用账本(B2 任务 6)。
  Future<void> _confirmLegacyScope(
      ChannelAccountRule rule, List<LedgerDisplayItem> ledgers) async {
    final l10n = AppLocalizations.of(context);
    int? chosen = ledgers.isEmpty ? null : ledgers.first.id;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(l10n.channelMappingConfirmScope),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.channelMappingConfirmScopeDesc(rule.channelName)),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                value: chosen,
                items: ledgers
                    .map((l) => DropdownMenuItem(
                          value: l.id,
                          child: Text(l.name),
                        ))
                    .toList(),
                onChanged: (v) => setDialogState(() => chosen = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: chosen == null ? null : () => Navigator.pop(ctx, true),
              child: Text(l10n.commonConfirm),
            ),
          ],
        ),
      ),
    );
    if (ok == true && chosen != null) {
      await _store.upsert(rule.copyWith(ledgerId: chosen));
      if (mounted) showToast(context, l10n.channelMappingScopeSaved);
      await _reload();
    }
  }

  Future<void> _toggleRule(ChannelAccountRule rule, bool enabled) async {
    await _store.upsert(rule.copyWith(enabled: enabled));
    await _reload();
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
    final ledgersAsync = ref.watch(allLedgersProvider);
    final ledgers = ledgersAsync.valueOrNull ?? const [];
    final currentLedgerId = ref.watch(currentLedgerIdProvider);
    final legacy = _rules.where((r) => r.isLegacy).toList();

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
                      // 旧版规则提示(B2 任务 6):未确认作用账本前保持旧兼容
                      // 路径,并明确「不推广到所有账本」。
                      if (legacy.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Card(
                          color: Colors.orange.withValues(alpha: 0.08),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.history,
                                        size: 18, color: Colors.orange),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        l10n.channelMappingLegacyBanner(
                                            legacy.length),
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                for (final rule in legacy)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(rule.channelName,
                                              style: theme.textTheme.bodySmall),
                                        ),
                                        TextButton(
                                          onPressed: () => _confirmLegacyScope(
                                              rule, ledgers),
                                          child: Text(
                                              l10n.channelMappingConfirmScope),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
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
                              leading: Icon(
                                rule.isLegacy ? Icons.history : Icons.link,
                                color: rule.enabled
                                    ? null
                                    : theme.colorScheme.outline,
                              ),
                              title: Text(
                                rule.channelName,
                                style: rule.enabled
                                    ? null
                                    : theme.textTheme.titleMedium?.copyWith(
                                        color: theme.colorScheme.outline,
                                        decoration: TextDecoration.lineThrough,
                                      ),
                              ),
                              subtitle: Text(_ruleSubtitle(rule, l10n, accounts,
                                  ledgers, currentLedgerId)),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Switch(
                                    value: rule.enabled,
                                    onChanged: (v) => _toggleRule(rule, v),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _deleteRule(rule),
                                  ),
                                ],
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
                  onPressed: accounts.isEmpty || ledgers.isEmpty
                      ? null
                      : () => _addRule(accounts, ledgers, currentLedgerId),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _ruleSubtitle(
    ChannelAccountRule rule,
    AppLocalizations l10n,
    List<Account> accounts,
    List<LedgerDisplayItem> ledgers,
    int currentLedgerId,
  ) {
    final parts = <String>[_accountName(rule.accountId, accounts)];
    if (rule.isLegacy) {
      parts.add(l10n.channelMappingLegacyRule);
    } else {
      final ledger = ledgers.firstWhereOrNull((l) => l.id == rule.ledgerId);
      parts.add(ledger?.name ?? '#${rule.ledgerId}');
    }
    parts.add(rule.sources.isEmpty
        ? l10n.channelMappingSourceAny
        : rule.sources
            .map((s) => _sourceLabel(l10n, s))
            .join('+'));
    if ((rule.cardLast4 ?? '').isNotEmpty) {
      parts.add(l10n.channelMappingCardLast4Short(rule.cardLast4!));
    }
    if ((rule.currency ?? '').isNotEmpty) {
      parts.add(rule.currency!);
    }
    if (!rule.enabled) parts.add(l10n.channelMappingDisabled);
    return parts.join(' · ');
  }
}
