import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../ai/core/bill_info.dart';
import '../../services/automation/auto_book_event.dart';
import '../../data/db.dart' as schema;
import '../../data/repositories/base_repository.dart';
import '../../data/repositories/local/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/ai_chat_providers.dart';
import '../../providers/automation_providers.dart';
import '../../services/billing/pending_candidate.dart';
import '../../services/automation/semantic_dedup_matcher.dart';
import '../../services/automation/dedup_exempt_store.dart';
import '../../services/data/tag_seed_service.dart';
import '../../widgets/category/category_selector.dart';
import '../../widgets/biz/amount_editor_sheet.dart';
import '../../widgets/ui/primary_header.dart';
import '../../widgets/ui/toast.dart';
import '../../utils/transaction_edit_utils.dart';
import 'auto_book_history_page.dart';

class _MatchedTransactionDetails {
  final schema.Transaction transaction;
  final schema.Category? category;
  final schema.Account? account;
  final schema.Account? toAccount;

  const _MatchedTransactionDetails({
    required this.transaction,
    this.category,
    this.account,
    this.toAccount,
  });
}

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
  Map<int, _MatchedTransactionDetails?> _matchedTransactions = const {};
  int _reloadToken = 0;

  /// 离线识别草稿页签(自动记账连不上服务端时攒下的待重试输入)
  bool _showDrafts = false;
  List<schema.AutoBookEvent> _drafts = const [];

  /// legacy 队列触 cap 淘汰过的提示(P1-3):候选在确认页仍全部可见
  /// (event store 合并口径),但要让用户知道有旧候选被归档了。
  bool _archivedHint = false;

  /// 批量操作模式(P1-4):长按候选进入;按当前筛选全选后批量确认/拒绝
  bool _multiSelect = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final reloadToken = ++_reloadToken;
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
    final matchedTransactions = await _loadMatchedTransactions(repo, list);
    if (!mounted || reloadToken != _reloadToken) return;
    final drafts = await ref.read(autoBookCoordinatorProvider).store.listDrafts();
    // 候选已清空则归档提示失去意义,一并清掉
    final archivedHint = list.isEmpty
        ? false
        : await _store.hasArchivedHint();
    if (!mounted || reloadToken != _reloadToken) return;
    if (list.isEmpty) {
      try {
        await _store.clearArchivedHint();
      } catch (_) {}
    }
    setState(() {
      _candidates = list;
      _matchedTransactions = matchedTransactions;
      _drafts = drafts;
      _archivedHint = archivedHint;
      _selectedIds.clear();
      _loading = false;
    });
    // M2 统计维度 M5?此处刷新交易列表 provider,确认入账后 UI 即时反映
    ref.read(statsRefreshProvider.notifier).state++;
  }

  Future<Map<int, _MatchedTransactionDetails?>> _loadMatchedTransactions(
    BaseRepository repo,
    List<PendingCandidate> candidates,
  ) async {
    final ids = candidates
        .map((candidate) => candidate.matchedTransactionId)
        .whereType<int>()
        .toSet()
        .toList();
    if (ids.isEmpty) return const {};

    final details = await Future.wait(
      ids.map((id) => _loadMatchedTransaction(repo, id)),
    );
    return <int, _MatchedTransactionDetails?>{
      for (var i = 0; i < ids.length; i++) ids[i]: details[i],
    };
  }

  Future<_MatchedTransactionDetails?> _loadMatchedTransaction(
    BaseRepository repo,
    int transactionId,
  ) async {
    try {
      final transaction = await repo.getTransactionById(transactionId);
      if (transaction == null) return null;

      schema.Category? category;
      schema.Account? account;
      schema.Account? toAccount;

      // Local transactions use integer foreign keys. Shared-ledger transactions
      // may instead keep the selected category/account in syncId overrides.
      category = transaction.categoryId == null
          ? null
          : await repo.getCategoryById(transaction.categoryId!);
      account = transaction.accountId == null
          ? null
          : await repo.getAccount(transaction.accountId!);
      toAccount = transaction.toAccountId == null
          ? null
          : await repo.getAccount(transaction.toAccountId!);

      // Resolve shared-ledger overrides when the local foreign keys are null.
      if (repo is LocalRepository) {
        if (category == null &&
            transaction.categorySyncIdOverride != null &&
            transaction.categorySyncIdOverride!.isNotEmpty) {
          final shared = await (repo.db.select(repo.db.sharedLedgerCategories)
                ..where((row) => row.syncId.equals(
                      transaction.categorySyncIdOverride!,
                    )))
              .getSingleOrNull();
          if (shared != null) {
            category = schema.Category(
              id: -1,
              name: shared.name,
              kind: shared.kind,
              icon: shared.icon,
              sortOrder: shared.sortOrder,
              parentId: null,
              level: shared.level,
              iconType: shared.iconType,
              customIconPath: null,
              communityIconId: null,
              syncId: shared.syncId,
            );
          }
        }
        Future<schema.Account?> sharedAccount(String? syncId) async {
          if (syncId == null || syncId.isEmpty) return null;
          final shared = await repo.getSharedAccountBySyncId(syncId);
          if (shared == null) return null;
          return schema.Account(
            id: -1,
            ledgerId: transaction.ledgerId,
            name: shared.name,
            type: shared.accountType,
            currency: shared.currency,
            initialBalance: shared.initialBalance ?? 0.0,
            createdAt: null,
            updatedAt: null,
            sortOrder: 0,
            creditLimit: shared.creditLimit,
            billingDay: shared.billingDay,
            paymentDueDay: shared.paymentDueDay,
            bankName: shared.bankName,
            cardLastFour: shared.cardLastFour,
            note: shared.note,
            syncId: shared.syncId,
            hidden: false,
          );
        }

        account ??= await sharedAccount(transaction.accountSyncIdOverride);
        toAccount ??= await sharedAccount(transaction.toAccountSyncIdOverride);
      }

      return _MatchedTransactionDetails(
        transaction: transaction,
        category: category,
        account: account,
        toAccount: toAccount,
      );
    } catch (_) {
      // A stale/deleted match should be visible as such, not break the queue.
      return null;
    }
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

  // ────────────────────────────────────────────────────────────────────
  // 离线识别草稿(自动记账连不上服务端时攒下的待重试输入)
  // ────────────────────────────────────────────────────────────────────

  Widget _buildDraftsList(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    if (_drafts.isEmpty) {
      return Center(
        child: Text(
          l10n.automationDraftsEmpty,
          style:
              TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _drafts.length,
        itemBuilder: (context, index) {
          final event = _drafts[index];
          return _buildDraftCard(event, theme, l10n);
        },
      ),
    );
  }

  Widget _buildDraftCard(
    schema.AutoBookEvent event,
    ThemeData theme,
    AppLocalizations l10n,
  ) {
    final payload = _draftPayloadOf(event);
    final preview = _draftPreviewText(event, payload);
    final captured = event.capturedAt.toLocal();
    final timeLabel =
        '${captured.month}/${captured.day} ${captured.hour.toString().padLeft(2, '0')}:${captured.minute.toString().padLeft(2, '0')}';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(_draftIcon(event.source),
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
        title: Text(
          preview,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium,
        ),
        subtitle: Text(
          '$timeLabel · ${_sourceLabel(event.source)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: l10n.automationDraftsRetry,
              icon: const Icon(Icons.refresh),
              onPressed: () => _retryDraft(event),
            ),
            IconButton(
              tooltip: l10n.automationDraftsDiscard,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _discardDraft(event),
            ),
          ],
        ),
        onTap: () => _retryDraft(event),
      ),
    );
  }

  AutoBookDraftPayload? _draftPayloadOf(schema.AutoBookEvent event) {
    final raw = event.draftPayloadJson;
    if (raw == null || raw.isEmpty) return null;
    try {
      return AutoBookDraftPayload.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  String _draftPreviewText(schema.AutoBookEvent event, AutoBookDraftPayload? payload) {
    if (payload == null) return event.eventKey;
    if (payload.isImage) return _copy('图片识别草稿', 'Image recognition draft');
    final text = (payload.text ?? '').trim();
    return text.isEmpty ? event.eventKey : text;
  }

  IconData _draftIcon(String source) {
    switch (source) {
      case 'sms':
        return Icons.sms_outlined;
      case 'notification':
        return Icons.notifications_outlined;
      case 'screenText':
        return Icons.chrome_reader_mode_outlined;
      case 'screenshot':
      case 'sharedImage':
        return Icons.image_outlined;
      default:
        return Icons.receipt_long_outlined;
    }
  }

  String _draftSourceLabel(String source) {
    switch (source) {
      case 'sms':
        return _copy('短信', 'SMS');
      case 'notification':
        return _copy('通知', 'Notification');
      case 'screenText':
        return _copy('屏幕文本', 'Screen text');
      case 'screenshot':
        return _copy('截图', 'Screenshot');
      case 'sharedImage':
        return _copy('分享图片', 'Shared image');
      case 'deepLinkText':
        return _copy('链接文本', 'Link text');
      default:
        return source;
    }
  }

  String _copy(String zh, String en) {
    final code = Localizations.localeOf(context).languageCode;
    return code == 'zh' ? zh : en;
  }

  Future<void> _retryDraft(schema.AutoBookEvent event) async {
    final l10n = AppLocalizations.of(context);
    final payload = _draftPayloadOf(event);
    try {
      final service = ref.read(autoBillingServiceProvider);
      final replayed = await service.retryDraft(event);
      if (!mounted) return;
      // 重试失败时说明原因(P2-2):截图草稿的原始图片被系统清理是唯一
      // 「无法重试」场景,沿用旧文案「已丢弃」会让用户以为草稿出了别的错
      String toast;
      if (replayed) {
        toast = l10n.automationDraftsRetryQueued;
      } else if (payload != null &&
          payload.isImage &&
          (payload.imagePath ?? '').isNotEmpty &&
          !File(payload.imagePath!).existsSync()) {
        toast = l10n.automationDraftsImageGone;
      } else {
        toast = l10n.automationDraftsDiscarded;
      }
      showToast(context, toast);
      await _reload();
    } catch (e) {
      if (mounted) showToast(context, '$e');
    }
  }

  Future<void> _discardDraft(schema.AutoBookEvent event) async {
    try {
      await ref.read(autoBookCoordinatorProvider).store.clearDraft(event.id);
      await _reload();
    } catch (e) {
      if (mounted) showToast(context, '$e');
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
      case 'autoBookDisabled':
        return l10n.pendingCandidateReasonAutoBookDisabled;
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
    // P1-1:用户裁定「这不是重复」→ 落豁免规则,同类误判不复发
    if (forceCreate) {
      final keyword = SemanticDedupMatcher.exemptKeyword(c.bill);
      final amount = c.bill.amount?.abs();
      if (keyword != null && amount != null) {
        try {
          await DedupExemptStore().add(keyword: keyword, amount: amount);
        } catch (_) {}
      }
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

  // ────────────────────────────────────────────────────────────────────
  // 批量操作(P1-4):积压大量候选时逐条确认不可用。长按进入多选,
  // 按当前筛选全选,批量确认/拒绝;任一条失败不中断其余,结束汇总。
  // ────────────────────────────────────────────────────────────────────

  void _enterMultiSelect(String candidateId) {
    setState(() {
      _multiSelect = true;
      _selectedIds.add(candidateId);
    });
  }

  void _toggleSelected(String candidateId) {
    setState(() {
      if (!_selectedIds.remove(candidateId)) {
        _selectedIds.add(candidateId);
      }
      if (_selectedIds.isEmpty) _multiSelect = false;
    });
  }

  void _selectAllVisible() {
    setState(() {
      _selectedIds.addAll(_visibleCandidates.map((c) => c.id));
    });
  }

  List<PendingCandidate> get _selectedCandidates =>
      _visibleCandidates.where((c) => _selectedIds.contains(c.id)).toList();

  /// 批量确认:reason=duplicate 的条目默认「合并到已有交易」
  /// (approvePending 非 forceCreate 路径即该语义),逐条幂等;
  /// 单条失败不中断,结束后汇总 toast。
  Future<void> _batchApprove() async {
    final l10n = AppLocalizations.of(context);
    final targets = _selectedCandidates;
    if (targets.isEmpty) return;
    final bookkeeper = ref.read(aiBookkeeperProvider);
    var ok = 0;
    var failed = 0;
    for (final c in targets) {
      try {
        final txId = await bookkeeper.approvePending(c, l10n: l10n);
        if (txId != null) {
          ok++;
        } else {
          failed++;
        }
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    showToast(context, l10n.pendingBatchApproved(ok, failed),
        duration: const Duration(seconds: 3));
    await _reload();
  }

  /// 批量拒绝:二次确认后逐条拒绝,单条失败不中断。
  Future<void> _batchReject() async {
    final l10n = AppLocalizations.of(context);
    final targets = _selectedCandidates;
    if (targets.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.pendingBatchReject),
        content: Text(l10n.pendingBatchRejectAsk(targets.length)),
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
    if (confirmed != true || !mounted) return;
    final bookkeeper = ref.read(aiBookkeeperProvider);
    var ok = 0;
    var failed = 0;
    for (final c in targets) {
      try {
        await bookkeeper.rejectPending(c);
        ok++;
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    showToast(context, l10n.pendingBatchRejected(ok, failed),
        duration: const Duration(seconds: 3));
    await _reload();
  }

  /// 编辑确认(P1-5):旧对话框只能改金额/备注,而候选最常见的错误恰恰是
  /// 分类/日期/账户。改为复用手动记账同款组件:
  ///   1. CategorySelector 选分类(转账候选跳过);
  ///   2. AmountEditorSheet 改金额/日期/账户/备注(回填候选字段);
  ///   3. 保存即确认入账(用户显式编辑过=明确入账意图,forceCreate 并落豁免)。
  Future<void> _editAndApprove(PendingCandidate c) async {
    final l10n = AppLocalizations.of(context);
    final bill = c.bill;
    final ledgerId = c.bill.ledgerId;
    if (ledgerId == null) return;
    final kind = switch (bill.type) {
      BillType.income => 'income',
      BillType.transfer => 'transfer',
      _ => 'expense',
    };
    final repo = ref.read(repositoryProvider);

    // Step 1: 分类(按候选自带分类名预选;转账无分类概念,跳过)
    schema.Category? picked;
    final initialCategory = await _matchCategoryByName(bill.category, kind);
    if (kind != 'transfer') {
      if (!mounted) return;
      final picked0 = await showModalBottomSheet<schema.Category>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.65,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Text(l10n.pendingConfirmationPickCategory,
                          style: Theme.of(ctx).textTheme.titleMedium),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(l10n.commonCancel),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: CategorySelector(
                    kind: kind,
                    initialCategoryId: initialCategory?.id,
                    onCategorySelected: (cat) => Navigator.pop(ctx, cat),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (picked0 == null || !mounted) return;
      picked = picked0;
    } else {
      picked = initialCategory;
    }

    // Step 2: AmountEditorSheet(手动记账同款,回填候选字段)
    final initialAccountId =
        await _matchAccountIdByName(bill.account, ledgerId);
    double? finalAmount;
    String? finalNote;
    DateTime? finalDate;
    int? finalAccountId;
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => AmountEditorSheet(
        categoryName: picked?.name ?? bill.category ?? '',
        categoryId: picked?.id,
        categorySyncId: (picked?.id ?? 0) < 0 ? picked?.syncId : null,
        initialDate: bill.time ?? DateTime.now(),
        initialAmount: bill.amount,
        initialNote: bill.note,
        initialAccountId: initialAccountId,
        showAccountPicker: true,
        ledgerId: ledgerId,
        transactionKind: kind,
        onSubmit: (res) async {
          finalAmount = res.amount;
          finalNote = res.note;
          finalDate = res.date;
          finalAccountId = res.accountId;
          if (ctx.mounted) Navigator.pop(ctx);
        },
      ),
    );
    if (!mounted) return;
    if (finalAmount == null) return; // 用户取消

    // 回填到候选 bill:createFromBill 按名称精确匹配分类/账户,把用户
    // 选择的 id 反查成名称回填(synthetic 共享账户拿不到名称时保留原名)。
    String? accountName = bill.account;
    if (finalAccountId != null && finalAccountId! > 0) {
      try {
        accountName = (await repo.getAccount(finalAccountId!))?.name ??
            accountName;
      } catch (_) {}
    }
    final editedCandidate = c.copyWith(
      candidateId: c.id,
      bill: bill.copyWith(
        amount: finalAmount,
        note: finalNote,
        time: finalDate,
        category: picked?.name ?? bill.category,
        account: accountName,
      ),
    );
    // 用户显式编辑后保存 = 明确「这笔记一笔」:跳过合并并落豁免规则(P1-1)
    final keyword = SemanticDedupMatcher.exemptKeyword(editedCandidate.bill);
    final amount = editedCandidate.bill.amount?.abs();
    if (keyword != null && amount != null) {
      try {
        await DedupExemptStore().add(keyword: keyword, amount: amount);
      } catch (_) {}
    }
    final txId = await ref.read(aiBookkeeperProvider).approvePending(
          editedCandidate,
          l10n: l10n,
          forceCreate: true,
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

  Future<schema.Category?> _matchCategoryByName(
      String? name, String kind) async {
    final n = name?.trim();
    if (n == null || n.isEmpty) return null;
    try {
      final repo = ref.read(repositoryProvider);
      final categories = await repo.getUsableCategories(kind);
      for (final c in categories) {
        if (c.name == n) return c;
      }
    } catch (_) {}
    return null;
  }

  Future<int?> _matchAccountIdByName(String? name, int ledgerId) async {
    final n = name?.trim();
    if (n == null || n.isEmpty) return null;
    try {
      final repo = ref.read(repositoryProvider);
      final accounts = await repo.getAllAccounts();
      for (final a in accounts) {
        if (a.name == n && a.ledgerId == ledgerId && a.id > 0) return a.id;
      }
    } catch (_) {}
    return null;
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
              // 批量操作开关(P1-4)
              IconButton(
                tooltip: _multiSelect
                    ? l10n.commonCancel
                    : l10n.pendingBatchMode,
                icon: Icon(_multiSelect ? Icons.close : Icons.checklist),
                onPressed: () => setState(() {
                  _multiSelect = !_multiSelect;
                  _selectedIds.clear();
                }),
              ),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: false,
                  label: Text(l10n.pendingConfirmationTitle),
                  icon: const Icon(Icons.fact_check_outlined),
                ),
                ButtonSegment(
                  value: true,
                  label: Text(l10n.automationDraftsTitle),
                  icon: const Icon(Icons.schedule_send_outlined),
                ),
              ],
              selected: {_showDrafts},
              onSelectionChanged: (value) =>
                  setState(() => _showDrafts = value.single),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _showDrafts
                    ? _buildDraftsList(theme)
                    : Column(
                    children: [
                      if (_archivedHint)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: Row(
                            children: [
                              Icon(Icons.archive_outlined,
                                  size: 18,
                                  color: Colors.orange.shade700),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  l10n.pendingCandidatesArchivedHint,
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: Colors.orange.shade700),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (_candidates.isNotEmpty) _buildFilters(context),
                      // 批量选择条(P1-4):多选模式下按当前筛选全选 + 批量确认/拒绝
                      if (_multiSelect && _candidates.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                          child: Row(
                            children: [
                              TextButton(
                                onPressed: _selectAllVisible,
                                child: Text(l10n.pendingBatchSelectAll),
                              ),
                              Text('${_selectedIds.length}',
                                  style: theme.textTheme.titleSmall),
                              const Spacer(),
                              FilledButton.tonal(
                                onPressed: _selectedIds.isEmpty
                                    ? null
                                    : _batchApprove,
                                child: Text(l10n.pendingBatchApprove),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed:
                                    _selectedIds.isEmpty ? null : _batchReject,
                                child: Text(l10n.pendingBatchReject),
                              ),
                            ],
                          ),
                        ),
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
                                  return _selectableCard(
                                    context,
                                    c,
                                    theme,
                                    child: Card(
                                      margin:
                                          const EdgeInsets.only(bottom: 12),
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
                                            _buildMatchedTransactionPreview(
                                              context,
                                              c,
                                              l10n,
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

  /// 多选包装(P1-4):普通模式长按进入多选;多选模式点按切换选中,
  /// 右上角覆盖选中态图标。
  Widget _selectableCard(
    BuildContext context,
    PendingCandidate c,
    ThemeData theme, {
    required Widget child,
  }) {
    if (!_multiSelect) {
      return GestureDetector(
        onLongPressStart: (_) => _enterMultiSelect(c.id),
        child: child,
      );
    }
    final selected = _selectedIds.contains(c.id);
    return GestureDetector(
      onTap: () => _toggleSelected(c.id),
      onLongPressStart: (_) => _toggleSelected(c.id),
      child: Stack(
        children: [
          child,
          Positioned(
            right: 10,
            top: 10,
            child: Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: selected ? theme.colorScheme.primary : Colors.black26,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMatchedTransactionPreview(
    BuildContext context,
    PendingCandidate candidate,
    AppLocalizations l10n,
  ) {
    final theme = Theme.of(context);
    final transactionId = candidate.matchedTransactionId!;
    final details = _matchedTransactions[transactionId];
    final loaded = _matchedTransactions.containsKey(transactionId);

    return Container(
      key: ValueKey('matched_transaction_$transactionId'),
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.secondary.withValues(alpha: 0.28),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: details == null
            ? null
            : () => _showTransactionComparison(
                  candidate,
                  details,
                  l10n,
                ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: !loaded
              ? Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.secondary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(l10n.pendingConfirmationSimilarTransaction),
                  ],
                )
              : details == null
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 18,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${l10n.pendingConfirmationSimilarTransaction} #$transactionId\n${l10n.pendingConfirmationMatchedMissing}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.compare_arrows,
                              size: 17,
                              color: theme.colorScheme.secondary,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${l10n.pendingConfirmationSimilarTransaction} #$transactionId',
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: theme.colorScheme.secondary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (candidate.matchScore != null)
                              Text(
                                '${l10n.pendingConfirmationMatchScoreLabel} ${(candidate.matchScore! * 100).round()}%',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.secondary,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _matchedTransactionTitle(details, l10n),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${_amountText(details.transaction.amount, details.transaction.currencyCode)}  ·  ${_dateTimeText(details.transaction.happenedAt)}${_matchedCategoryText(details) == null ? '' : '  ·  ${_matchedCategoryText(details)}'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => _showTransactionComparison(
                              candidate,
                              details,
                              l10n,
                            ),
                            icon:
                                const Icon(Icons.visibility_outlined, size: 16),
                            label: Text(l10n.pendingConfirmationCompare),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                            ),
                          ),
                        ),
                      ],
                    ),
        ),
      ),
    );
  }

  String _matchedTransactionTitle(
    _MatchedTransactionDetails details,
    AppLocalizations l10n,
  ) {
    final note = details.transaction.note?.trim();
    if (note != null && note.isNotEmpty) return note;
    final category = details.category?.name.trim();
    if (category != null && category.isNotEmpty) return category;
    return l10n.commonEmpty;
  }

  String? _matchedCategoryText(_MatchedTransactionDetails details) {
    final category = details.category?.name.trim();
    return category == null || category.isEmpty ? null : category;
  }

  String _amountText(double? amount, String? currencyCode) {
    if (amount == null) return '-';
    final value = amount.abs().toStringAsFixed(2);
    final currency = currencyCode?.trim();
    return currency == null || currency.isEmpty ? value : '$currency $value';
  }

  String _dateTimeText(DateTime? value) {
    if (value == null) return '-';
    final local = value.toLocal();
    String pad(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${pad(local.month)}-${pad(local.day)} '
        '${pad(local.hour)}:${pad(local.minute)}';
  }

  String _candidateAccountText(PendingCandidate candidate) {
    final bill = candidate.bill;
    if (bill.type == BillType.transfer) {
      final from = bill.fromAccount?.trim();
      final to = bill.toAccount?.trim();
      if (from != null && from.isNotEmpty && to != null && to.isNotEmpty) {
        return '$from → $to';
      }
      return from ?? to ?? '';
    }
    return bill.account?.trim() ?? '';
  }

  String _matchedAccountText(_MatchedTransactionDetails details) {
    final from = details.account?.name.trim();
    final to = details.toAccount?.name.trim();
    if (details.transaction.type == 'transfer' &&
        from != null &&
        from.isNotEmpty &&
        to != null &&
        to.isNotEmpty) {
      return '$from → $to';
    }
    return from ?? to ?? '';
  }

  Widget _buildComparisonField(
    BuildContext context,
    String label,
    String value,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComparisonPanel(
    BuildContext context, {
    required AppLocalizations l10n,
    required String title,
    required String note,
    required String amount,
    required String time,
    required String category,
    required String account,
  }) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          _buildComparisonField(context, l10n.pendingConfirmationNote, note),
          _buildComparisonField(
              context, l10n.pendingConfirmationAmount, amount),
          _buildComparisonField(context, l10n.billCardTime, time),
          _buildComparisonField(context, l10n.billCardCategory, category),
          _buildComparisonField(context, l10n.billCardAccount, account),
        ],
      ),
    );
  }

  Future<void> _showTransactionComparison(
    PendingCandidate candidate,
    _MatchedTransactionDetails details,
    AppLocalizations l10n,
  ) async {
    final transaction = details.transaction;
    final action = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final bill = candidate.bill;
        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.compare_arrows),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${l10n.pendingConfirmationSimilarTransaction} #${transaction.id}',
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildComparisonPanel(
                  dialogContext,
                  l10n: l10n,
                  title: l10n.pendingConfirmationCandidate,
                  note: bill.note ?? '',
                  amount: _amountText(bill.amount, bill.currency),
                  time: _dateTimeText(bill.time),
                  category: bill.category ?? '',
                  account: _candidateAccountText(candidate),
                ),
                const SizedBox(height: 10),
                _buildComparisonPanel(
                  dialogContext,
                  l10n: l10n,
                  title: l10n.pendingConfirmationExisting,
                  note: transaction.note ?? '',
                  amount: _amountText(
                    transaction.amount,
                    transaction.currencyCode,
                  ),
                  time: _dateTimeText(transaction.happenedAt),
                  category: details.category?.name ?? '',
                  account: _matchedAccountText(details),
                ),
                if (candidate.matchScore != null) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${l10n.pendingConfirmationMatchScoreLabel} ${(candidate.matchScore! * 100).round()}%',
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.commonClose),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.open_in_new, size: 17),
              label: Text(l10n.pendingConfirmationOpenMatched),
            ),
          ],
        );
      },
    );

    if (action == true && mounted) {
      await TransactionEditUtils.editTransaction(
        context,
        ref,
        transaction,
        details.category,
      );
      await _reload();
    }
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
