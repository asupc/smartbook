import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../styles/tokens.dart';
import '../transaction/recurring_transaction_page.dart';
import '../settings/reminder_settings_page.dart';
import '../automation/auto_billing_settings_page.dart';
import '../automation/auto_billing_setup_page.dart';
import '../../providers/automation_providers.dart';
import '../../services/automation/automation_settings_store.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/ui_scale_extensions.dart';

/// 自动化功能二级页面
///
/// B1 入口整合:周期记账与记账提醒归入「固定计划」分组,自动记账单列为
/// 「识别与入账」分组的主入口(与「我的 → 自动记账」指向同一配置页),
/// 原有功能与跳转全部保留。
class AutomationPage extends ConsumerWidget {
  const AutomationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      body: Column(
        children: [
          PrimaryHeader(
            title: AppLocalizations.of(context).automationPageTitle,
            subtitle: AppLocalizations.of(context).automationPageSubtitle,
            showBack: true,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _groupTitle(context, l10n.automationGroupRecognition),
                SectionCard(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      // 自动记账:与「我的」页同一入口语义(未开通先引导)
                      AppListTile(
                        leading: Icons.auto_fix_high_rounded,
                        leadingColor: const Color(0xFFD97706),
                        leadingBgColor:
                            const Color(0xFFD97706).withValues(alpha: 0.12),
                        title: l10n.autoBillingEntryTitle,
                        subtitle: l10n.automationGroupRecognitionDesc,
                        trailing: Icon(Icons.chevron_right,
                            color: BeeTokens.iconTertiary(context), size: 20),
                        onTap: () async {
                          final setupDone = await ref
                              .read(automationSettingsStoreProvider)
                              .isSetupCompleted();
                          if (!context.mounted) return;
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => setupDone
                                  ? const AutoBillingSettingsPage()
                                  : const AutoBillingSetupPage(),
                            ),
                          );
                          // 返回后补查共享状态
                          ref
                              .read(automationHealthRefreshProvider.notifier)
                              .state++;
                          ref.invalidate(automationHealthProvider);
                        },
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 12.0.scaled(context, ref)),
                _groupTitle(context, l10n.automationGroupSchedule),
                SectionCard(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      // 周期记账
                      AppListTile(
                        leading: Icons.repeat,
                        title: AppLocalizations.of(context)
                            .mineRecurringTransactions,
                        subtitle: AppLocalizations.of(context)
                            .mineRecurringTransactionsSubtitle,
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    const RecurringTransactionPage()),
                          );
                        },
                      ),
                      BeeTokens.cardDivider(context),
                      // 记账提醒
                      AppListTile(
                        leading: Icons.notifications_outlined,
                        title: AppLocalizations.of(context)
                            .mineReminderSettings,
                        subtitle: AppLocalizations.of(context)
                            .mineReminderSettingsSubtitle,
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    const ReminderSettingsPage()),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupTitle(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: BeeTokens.textSecondary(context),
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
