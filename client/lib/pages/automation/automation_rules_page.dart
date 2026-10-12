import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../services/automation/dedup_exempt_store.dart';
import '../../services/billing/category_learning_store.dart';
import '../../widgets/ui/primary_header.dart';
import '../../widgets/ui/toast.dart';
import 'channel_account_mapping_page.dart';

/// 自动记账规则管理(B4 任务 5/6)。
///
/// 三类规则都**只影响未来账单**,不重分类/不改写历史:
/// - 分类学习规则:关键词 → 分类,可编辑/停用/删除,按账本作用域生效;
///   升级前的旧规则未绑定账本,按旧口径全局生效并提示逐条绑定;
/// - 渠道 → 账户规则(B2 已支持账本/来源/卡尾号/币种);
/// - 判重豁免规则(窄条件保留:两侧备注命中同一关键词且金额同段)。
class AutomationRulesPage extends ConsumerStatefulWidget {
  const AutomationRulesPage({super.key});

  @override
  ConsumerState<AutomationRulesPage> createState() =>
      _AutomationRulesPageState();
}

class _AutomationRulesPageState extends ConsumerState<AutomationRulesPage> {
  final CategoryLearningStore _store = CategoryLearningStore();
  List<CategoryLearningRule> _rules = const [];
  List<DedupExemptRule> _exemptRules = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final rules = await _store.list();
    final exempt = await DedupExemptStore().list();
    if (!mounted) return;
    setState(() {
      _rules = rules;
      _exemptRules = exempt;
      _loading = false;
    });
  }

  String _ledgerLabel(int? ledgerId) {
    if (ledgerId == null) return '';
    final ledgers = ref.read(allLedgersProvider).valueOrNull ?? const [];
    for (final l in ledgers) {
      if (l.id == ledgerId) return l.name;
    }
    return '#$ledgerId';
  }

  Future<void> _bindLedger(CategoryLearningRule rule) async {
    final l10n = AppLocalizations.of(context);
    final ledgersAsync = ref.read(allLedgersProvider);
    final ledgers = ledgersAsync.valueOrNull ?? const [];
    if (ledgers.isEmpty) {
      if (mounted) showToast(context, l10n.autoBillingNotifyNoLedgerBody);
      return;
    }
    int? chosen = rule.ledgerId ?? (ledgers.isEmpty ? null : ledgers.first.id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(l10n.automationRulesBindLedger),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${rule.keyword} → ${rule.categoryName}',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
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
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.commonConfirm),
            ),
          ],
        ),
      ),
    );
    if (ok == true && chosen != null) {
      await _store.update(rule.copyWith(ledgerId: chosen));
      if (mounted) showToast(context, l10n.automationRulesBoundSaved);
      await _reload();
    }
  }

  Future<void> _editRule(CategoryLearningRule rule) async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController(text: rule.categoryName);
    try {
      final saved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.automationRulesEdit),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${rule.keyword} → ${rule.categoryName}',
                  style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                decoration:
                    InputDecoration(labelText: l10n.pendingSelectCategory),
                autofocus: true,
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
              child: Text(l10n.commonSave),
            ),
          ],
        ),
      );
      if (saved == true) {
        final name = controller.text.trim();
        if (name.isNotEmpty) {
          await _store.update(rule.copyWith(categoryName: name));
          if (mounted) showToast(context, l10n.automationRulesUpdated);
          await _reload();
        }
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _deleteRule(CategoryLearningRule rule) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.automationRulesEdit),
        content: Text(l10n.automationRulesDeleteAsk),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _store.remove(rule.keyword);
      if (mounted) showToast(context, l10n.automationRulesDeleted);
      await _reload();
    }
  }

  Future<void> _showExemptDialog() async {
    final l10n = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.automationRulesDedupEntry),
        content: SizedBox(
          width: double.maxFinite,
          child: _exemptRules.isEmpty
              ? Text(l10n.automationRulesEmpty)
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final r in _exemptRules)
                      ListTile(
                        dense: true,
                        title: Text(r.keyword),
                        subtitle: Text('±10% · ¥${r.amount.toStringAsFixed(2)}'),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.commonClose),
          ),
          if (_exemptRules.isNotEmpty)
            FilledButton(
              onPressed: () async {
                await DedupExemptStore().clear();
                if (ctx.mounted) Navigator.pop(ctx);
                await _reload();
              },
              child: Text(l10n.commonDelete),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final legacy = _rules.where((r) => r.isLegacy).toList();

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Column(
        children: [
          PrimaryHeader(
            title: l10n.automationRulesTitle,
            subtitle: l10n.automationRulesDesc,
            showBack: true,
            leadingIcon: Icons.rule,
            leadingPlain: true,
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // 分类学习规则
                      Text(l10n.automationRulesCategoryTitle,
                          style: theme.textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text(
                        l10n.automationRulesCategoryDesc,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.hintColor),
                      ),
                      // 旧版规则提示(B4 任务 6):未确认作用账本前保持旧口径
                      if (legacy.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Card(
                          color: Colors.orange.withValues(alpha: 0.08),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              l10n.automationRulesLegacyBanner(legacy.length),
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      if (_rules.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(
                            child: Text(
                              l10n.automationRulesEmpty,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                        )
                      else
                        ..._rules.map((rule) => _ruleCard(rule, l10n, theme)),
                      const SizedBox(height: 16),
                      // 其它两类规则的入口
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.swap_horiz),
                          title: Text(l10n.automationRulesChannelEntry),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    const ChannelAccountMappingPage()),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.link_off),
                          title: Text(l10n.automationRulesDedupEntry),
                          subtitle: Text('${_exemptRules.length}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _showExemptDialog,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _ruleCard(
      CategoryLearningRule rule, AppLocalizations l10n, ThemeData theme) {
    final scope = rule.isLegacy
        ? l10n.automationRulesLedgerAll
        : _ledgerLabel(rule.ledgerId);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          rule.disabled ? Icons.link_off : Icons.school_outlined,
          color: rule.disabled ? theme.colorScheme.outline : null,
        ),
        title: Text(
          '${rule.keyword} → ${rule.categoryName}',
          style: rule.disabled
              ? TextStyle(
                  color: theme.colorScheme.outline,
                  decoration: TextDecoration.lineThrough,
                )
              : null,
        ),
        subtitle: Text(
          [rule.kind, scope, if (rule.disabled) l10n.automationRulesDisabled]
              .join(' · '),
          style: theme.textTheme.bodySmall,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: !rule.disabled,
              onChanged: (v) async {
                await _store.setEnabled(rule.keyword, v);
                await _reload();
              },
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (action) async {
                switch (action) {
                  case 'bind':
                    await _bindLedger(rule);
                  case 'edit':
                    await _editRule(rule);
                  case 'delete':
                    await _deleteRule(rule);
                }
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(
                  value: 'bind',
                  child: Text(l10n.automationRulesBindLedger),
                ),
                PopupMenuItem(
                  value: 'edit',
                  child: Text(l10n.automationRulesEdit),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(l10n.commonDelete),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
