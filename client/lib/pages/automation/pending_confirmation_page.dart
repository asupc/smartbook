import 'dart:async';
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
import '../../services/billing/pending_candidate.dart';
import '../../services/automation/auto_book_event_store.dart';
import '../../services/automation/semantic_dedup_matcher.dart';
import '../../services/automation/auto_book_reason_presenter.dart';

import '../../services/billing/category_learning_store.dart';
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

/// 待确认候选的加载器(可测性 2 注入点)。生产路径为
/// [PendingCandidateStore.loadForReview]。
typedef PendingCandidatesLoader = Future<List<PendingCandidate>> Function(
    AutoBookEventStore eventStore);

/// 待确认记账队列页(自动记账 M2)。
///
/// 自动路径(截图/短信/支付通知)解析出的「候选交易」—— 低置信 / 大额 /
/// 疑似重复 —— 不直接入账,先进入本队列;用户确认 / 编辑后入账 / 拒绝。
///
/// **可测性 2(批次 X,2026-10-11)**:[store] / [candidateLoader] 为注入点。
/// 复现结论:`PendingCandidateStore._serial` 的**进程级静态尾链**在
/// flutter_test 的 fake-async zone 里创建后,下一个用例再 `.then` 它时回调
/// 永不触发 → 同文件第二条用例起 "did not complete"(挂起,不是 pending
/// timer;page/store/coordinator 订阅路径均无 Timer)。生产代码不传这两个
/// 参数,行为不变;测试注入后即可绕开该尾链、整文件运行。
class PendingConfirmationPage extends ConsumerStatefulWidget {
  const PendingConfirmationPage({
    super.key,
    this.store,
    this.candidateLoader,
  });

  /// 候选存储注入点;null = 生产默认 [PendingCandidateStore]。
  final PendingCandidateStore? store;

  /// 候选加载注入点;null = 生产默认 [PendingCandidateStore.loadForReview]。
  final PendingCandidatesLoader? candidateLoader;

  @override
  ConsumerState<PendingConfirmationPage> createState() =>
      _PendingConfirmationPageState();
}

class _PendingConfirmationPageState
    extends ConsumerState<PendingConfirmationPage> {
  /// 生产默认 store(进程级静态尾链由 [PendingCandidateStore] 自身持有,
  /// 注入 [PendingConfirmationPage.store] 可替换实例/换用测试替身)。
  final PendingCandidateStore _defaultStore = PendingCandidateStore();

  PendingCandidateStore get _store => widget.store ?? _defaultStore;

  /// 加载候选:注入的 loader 优先,否则走 store 的合并投影。
  Future<List<PendingCandidate>> _loadCandidates() {
    final eventStore = ref.read(autoBookCoordinatorProvider).store;
    final loader = widget.candidateLoader;
    if (loader != null) return loader(eventStore);
    return _store.loadForReview(eventStore);
  }

  List<PendingCandidate> _candidates = const [];
  bool _loading = true;
  String _sourceFilter = 'all';
  String _reasonFilter = 'all';
  String _ledgerFilter = 'all';
  String _dateFilter = 'all';
  List<schema.Ledger> _ledgers = const [];
  Map<int, _MatchedTransactionDetails?> _matchedTransactions = const {};
  int _reloadToken = 0;
  StreamSubscription<void>? _eventChanges;

  /// 离线识别草稿页签(自动记账连不上服务端时攒下的待重试输入)
  /// 0=候选 1=已忽略 2=草稿(B4:已忽略短期恢复入口)。
  int _tab = 0;

  bool get _showDrafts => _tab == 2;
  bool get _showIgnored => _tab == 1;

  /// 行内即时编辑缓冲(B4 任务 1:卡片内补账户/分类,不必走完整编辑流)。
  final Map<String, PendingCandidate> _inlineEdits = {};

  /// 生效候选:行内编辑优先,其余用原候选。
  PendingCandidate _effective(PendingCandidate c) => _inlineEdits[c.id] ?? c;

  /// 已忽略子项(只含仍留有结构化摘要的,可恢复)。
  List<
      ({
        schema.AutoBookEvent event,
        schema.AutoBookEventItem item,
      })> _ignored = const [];
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
    _eventChanges =
        ref.read(autoBookCoordinatorProvider).store.watchChanges().listen((_) {
      if (mounted) unawaited(_reload());
    });
    _reload();
  }

  @override
  void dispose() {
    _eventChanges?.cancel();
    _reloadToken++;
    super.dispose();
  }

  Future<void> _reload() async {
    final reloadToken = ++_reloadToken;
    final repo = ref.read(repositoryProvider);
    final list = await _loadCandidates();
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
          (candidate.reason ?? '').toLowerCase() == _reasonFilter ||
          (_reasonFilter == 'lowConfidence' &&
              const {'confidenceMissing', 'timeInferred', 'timePrecisionWeak'}
                  .contains(candidate.reason));
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

  /// 已忽略列表(B4 任务 2):材料仍在才允许恢复;恢复只重建候选。
  Widget _buildIgnoredList(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    if (_ignored.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.pendingIgnoredEmpty,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reloadIgnored,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _ignored.length,
        itemBuilder: (context, index) {
          final entry = _ignored[index];
          final bill = _billOfItem(entry.item);
          final updated = entry.item.updatedAt.toLocal();
          final timeLabel =
              '${updated.month}/${updated.day} ${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}';
          final amount = bill?.amount;
          final title = amount == null
              ? (bill?.merchant ?? bill?.note ?? entry.item.merchant ?? '—')
              : '¥${amount.abs().toStringAsFixed(2)} · '
                  '${bill?.merchant ?? bill?.note ?? entry.item.merchant ?? ''}';
          final reason = AutoBookReasonPresenter.present(
            l10n,
            reason: entry.item.reason,
            state: entry.item.state,
          ).title;
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: Icon(Icons.undo_outlined,
                  color: Colors.orange.withValues(alpha: 0.9)),
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '$reason · $timeLabel · ${_sourceLabel(entry.event.source)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              trailing: TextButton(
                onPressed: () =>
                    _restoreIgnored(entry.event, entry.item.itemIndex),
                child: Text(l10n.pendingIgnoredRestore),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 从子项的结构化摘要还原账单(材料缺失返回 null)。
  BillInfo? _billOfItem(schema.AutoBookEventItem item) {
    final raw = item.billJson;
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final payload =
          Map<String, dynamic>.from(decoded.cast<String, dynamic>());
      final billPayload = payload['bill'] is Map
          ? Map<String, dynamic>.from(payload['bill'] as Map)
          : payload;
      return BillInfo.fromJson(billPayload);
    } catch (_) {
      return null;
    }
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
          // U-2(2026-10-11)窄屏加固:三个 DropdownButton + 计数标签在 320 宽
          // 下不可收缩(RenderFlex overflow 161px)。改 Wrap:空间不足时换行,
          // 每个下拉各自可收缩。
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('原因', style: theme.textTheme.labelMedium),
              DropdownButton<String>(
                value: _reasonFilter,
                isDense: true,
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('全部原因')),
                  const DropdownMenuItem(
                      value: 'duplicate', child: Text('疑似重复')),
                  const DropdownMenuItem(
                      value: 'lowConfidence', child: Text('置信度或时间不足')),
                  const DropdownMenuItem(
                      value: 'settlementUnknown', child: Text('结算状态不明')),
                  const DropdownMenuItem(
                      value: 'transferAccountMissing', child: Text('缺少转账账户')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _reasonFilter = value);
                },
              ),
              DropdownButton<String>(
                value: _ledgerFilter,
                isDense: true,
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('全部账本')),
                  ..._ledgers.map((ledger) => DropdownMenuItem(
                        value: ledger.id.toString(),
                        child: Text(ledger.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      )),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _ledgerFilter = value);
                },
              ),
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
      case 'confidenceMissing':
        return l10n.pendingCandidateReasonConfidenceMissing;
      case 'timeInferred':
        return l10n.pendingCandidateReasonTimeInferred;
      case 'timePrecisionWeak':
        return l10n.pendingCandidateReasonTimePrecisionWeak;
      case 'autoBookDisabled':
        return l10n.pendingCandidateReasonAutoBookDisabled;
      case 'settlementUnknown':
        return l10n.pendingCandidateReasonSettlementUnknown;
      case 'transferAccountMissing':
        return l10n.pendingCandidateReasonTransferAccountMissing;
      case 'already_processed':
        return l10n.pendingCandidateReasonAlreadyProcessed;
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

  /// 仅在「仍记一笔」确实入账成功后记住用户的判重裁决。
  Future<void> _rememberSeparatePayment(PendingCandidate candidate) async {
    final keyword = SemanticDedupMatcher.exemptKeyword(candidate.bill);
    final amount = candidate.bill.amount?.abs();
    if (keyword == null || amount == null) return;
    try {
      await DedupExemptStore().add(keyword: keyword, amount: amount);
    } catch (_) {}
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
    // B4 任务 3:确认/忽略/恢复共用互斥链,并由 store 的期望状态检查兜底。
    final txId = await PendingDecisionCoordinator.run(
      PendingDecisionCoordinator.keyFor(c),
      () => bookkeeper.approvePending(
        c,
        l10n: l10n,
        forceCreate: forceCreate,
      ),
    );
    if (!mounted) return;
    if (txId != null) {
      if (forceCreate) await _rememberSeparatePayment(c);
      if (!mounted) return;
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
    // B4:与确认/恢复/后台重试共用一条互斥链,并检查期望状态。
    await PendingDecisionCoordinator.run(
      PendingDecisionCoordinator.keyFor(c),
      () => ref.read(aiBookkeeperProvider).rejectPending(c),
    );
    if (!mounted) return;
    showToast(context, l10n.pendingConfirmationRejected);
    // 10 秒撤销窗口;超时后仍可在「已忽略」标签页恢复。
    await _showIgnoreUndo(c, l10n);
    await _reload();
  }

  /// B4 任务 2:普通候选忽略后给 **10 秒撤销**。
  ///
  /// 撤销只是把候选放回队列并把子项从 ignored 拉回 pending(期望状态检查),
  /// 不创建交易;超过 10 秒后走「已忽略」标签页的恢复入口。
  Future<void> _showIgnoreUndo(PendingCandidate c, AppLocalizations l10n) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.pendingIgnoredUndoHint),
        duration: const Duration(seconds: 10),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: l10n.commonUndo,
          onPressed: () {
            unawaited(_undoIgnore(c, l10n));
          },
        ),
      ),
    );
  }

  Future<void> _undoIgnore(PendingCandidate c, AppLocalizations l10n) async {
    final store = ref.read(autoBookCoordinatorProvider).store;
    final ok = await PendingDecisionCoordinator.run(
      PendingDecisionCoordinator.keyFor(c),
      () async {
        final added = await _store.add(c);
        if (c.eventKey != null && c.eventItemIndex != null) {
          final event = await store.findByEventKey(c.eventKey!);
          if (event != null) {
            await store.reopenItem(
              eventId: event.id,
              itemIndex: c.eventItemIndex!,
              reason: 'undo_ignore',
            );
          }
        }
        return added;
      },
    );
    if (!mounted) return;
    showToast(context, ok ? l10n.pendingIgnoredUndone : l10n.pendingIgnoredUnavailable);
    await _reload();
  }

  /// B4 任务 2:已忽略列表(材料仍在才给恢复按钮)。
  Future<void> _reloadIgnored() async {
    final store = ref.read(autoBookCoordinatorProvider).store;
    try {
      final items = await store.listIgnoredItems();
      if (!mounted) return;
      setState(() => _ignored = items);
    } catch (_) {
      if (!mounted) return;
      setState(() => _ignored = const []);
    }
  }

  /// 恢复被忽略的子项:只重建候选,不创建交易。
  Future<void> _restoreIgnored(
      schema.AutoBookEvent event, int itemIndex) async {
    final l10n = AppLocalizations.of(context);
    final key = 'restore:${event.eventKey}:$itemIndex';
    final restored = await PendingDecisionCoordinator.run(
      key,
      () => ref
          .read(aiBookkeeperProvider)
          .restoreIgnored(event, itemIndex: itemIndex),
    );
    if (!mounted) return;
    if (restored > 0) {
      showToast(context, l10n.pendingIgnoredRestored);
      await _reloadIgnored();
      await _reload();
    } else {
      showToast(
        context,
        l10n.pendingIgnoredUnavailable,
        duration: const Duration(seconds: 3),
      );
    }
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

  /// 批量确认(2026-09-10 改分组裁决):选中项含疑似重复(reason=duplicate
  /// 或带 matchedTransactionId)时,先弹一次性分组选择 ——「合并到已有交易 /
  /// 仍记一笔」由用户定,不再默认静默合并(旧逻辑用户以为「都记上」,实际
  /// 疑似重复组被并入已有交易,只 toast 成功条数)。非重复组不受影响直记。
  /// B4 任务 4:分类纠错的「仅本次 / 记住」选择。
  ///
  /// 返回要记住的关键词(未规范化,展示用);null = 仅本次/取消,不落规则。
  Future<String?> _askRememberKeyword(
    AppLocalizations l10n, {
    required String category,
    required String initialKeyword,
  }) async {
    final controller = TextEditingController(text: initialKeyword);
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.pendingRememberAsk),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.pendingRememberBody(initialKeyword, category),
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: l10n.pendingFieldMerchant,
                  helperText: l10n.pendingFieldHintRememberKeyword,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: Text(l10n.pendingRememberOnce),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, controller.text.trim()),
              child: Text(l10n.pendingRememberYes),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _batchApprove() async {
    final l10n = AppLocalizations.of(context);
    final targets = _selectedCandidates;
    if (targets.isEmpty) return;
    final duplicates = targets
        .where((c) => c.matchedTransactionId != null || c.reason == 'duplicate')
        .toList();
    var forceCreateForDuplicates = false;
    if (duplicates.isNotEmpty) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('发现可能重复'),
          content: Text(
            '选中的 ${targets.length} 笔中有 ${duplicates.length} 笔疑似与已有'
            '交易重复。请选择这些疑似重复项的处理方式。',
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
      if (choice == null || !mounted) return;
      forceCreateForDuplicates = choice;
    }
    final bookkeeper = ref.read(aiBookkeeperProvider);
    var ok = 0;
    var failed = 0;
    for (final c in targets) {
      final isDuplicate =
          c.matchedTransactionId != null || c.reason == 'duplicate';
      try {
        final txId = await PendingDecisionCoordinator.run(
          PendingDecisionCoordinator.keyFor(c),
          () => bookkeeper.approvePending(
            c,
            l10n: l10n,
            forceCreate: isDuplicate ? forceCreateForDuplicates : false,
          ),
        );
        if (txId != null) {
          if (isDuplicate && forceCreateForDuplicates) {
            await _rememberSeparatePayment(c);
          }
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
        await PendingDecisionCoordinator.run(
          PendingDecisionCoordinator.keyFor(c),
          () => bookkeeper.rejectPending(c),
        );
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
    // B4 任务 4:改了分类先问「仅本次 / 记住」;**入账成功后**才落规则,
    // 保存失败不影响本次入账。关键词默认取商户(没有商户才回落备注)并让用户
    // 确认/改写 —— 不默认整段备注,也不自动删数字。
    final finalCategory = picked?.name;
    final categoryChanged =
        finalCategory != null && finalCategory != bill.category;
    final initialKeyword = (bill.merchant ?? finalNote ?? bill.note ?? '')
        .trim();
    String? rememberKeyword;
    if (categoryChanged && initialKeyword.isNotEmpty) {
      rememberKeyword = await _askRememberKeyword(
        l10n,
        category: finalCategory,
        initialKeyword: initialKeyword,
      );
    }

    final txId = await PendingDecisionCoordinator.run(
      PendingDecisionCoordinator.keyFor(editedCandidate),
      () => ref.read(aiBookkeeperProvider).approvePending(
            editedCandidate,
            l10n: l10n,
            forceCreate: true,
          ),
    );
    if (mounted) {
      if (txId != null) {
        if (rememberKeyword != null && rememberKeyword.isNotEmpty) {
          try {
            await CategoryLearningStore().add(
              keyword: normalizeAutoBookText(rememberKeyword),
              categoryName: finalCategory!,
              kind: switch (bill.type) {
                BillType.income => 'income',
                BillType.transfer => 'transfer',
                _ => 'expense',
              },
              ledgerId: editedCandidate.bill.ledgerId,
            );
            showToast(
              context,
              l10n.pendingRememberSaved(
                  rememberKeyword, finalCategory),
            );
          } catch (_) {
            showToast(context, l10n.pendingRememberSaveFailed);
          }
        }
        await _rememberSeparatePayment(editedCandidate);
        if (!mounted) return;
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
            child: SegmentedButton<int>(
              segments: [
                ButtonSegment(
                  value: 0,
                  label: Text(l10n.pendingConfirmationTitle),
                  icon: const Icon(Icons.fact_check_outlined),
                ),
                ButtonSegment(
                  value: 1,
                  label: Text(l10n.pendingIgnoredTab),
                  icon: const Icon(Icons.undo_outlined),
                ),
                ButtonSegment(
                  value: 2,
                  label: Text(l10n.automationDraftsTitle),
                  icon: const Icon(Icons.schedule_send_outlined),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (value) {
                setState(() => _tab = value.single);
                if (_tab == 1) _reloadIgnored();
              },
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _showDrafts
                    ? _buildDraftsList(theme)
                    : _showIgnored
                        ? _buildIgnoredList(theme)
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
                      // U-2:改 Wrap,320 宽/大字体下按钮换行不溢出。
                      if (_multiSelect && _candidates.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              TextButton(
                                onPressed: _selectAllVisible,
                                child: Text(l10n.pendingBatchSelectAll),
                              ),
                              Text('${_selectedIds.length}',
                                  style: theme.textTheme.titleSmall),
                              FilledButton.tonal(
                                onPressed: _selectedIds.isEmpty
                                    ? null
                                    : _batchApprove,
                                child: Text(l10n.pendingBatchApprove),
                              ),
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
                                  final c =
                                      _effective(_visibleCandidates[index]);
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
                                                          FontWeight.w700,
                                                      color: _fieldsToFix(c)
                                                              .contains('amount')
                                                          ? Colors.orange
                                                          : null,
                                                    ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          // B4 任务 1:显示时间/商家/目标账本,
                                          // 并按原因突出**需要修正的字段**;
                                          // 账户与分类可在卡片内直接补。
                                          Builder(builder: (ctx) {
                                            final fix = _fieldsToFix(c);
                                            final timeText = c.bill.time == null
                                                ? l10n.pendingFieldHintTime
                                                : '${c.bill.time.toString().split(' ').first} ${_timePrecisionLabel(l10n, c.bill)}';
                                            return Wrap(
                                              spacing: 8,
                                              runSpacing: 4,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: [
                                                _chip(
                                                  ctx,
                                                  (c.bill.account ?? '')
                                                          .trim()
                                                          .isEmpty
                                                      ? l10n.pendingFieldHintAccount
                                                      : c.bill.account!,
                                                  highlight:
                                                      fix.contains('account'),
                                                  onTap: () =>
                                                      _pickAccountInline(c),
                                                ),
                                                if (c.bill.category != null &&
                                                    c.bill.category!.isNotEmpty)
                                                  _chip(ctx, c.bill.category!,
                                                      onTap: () =>
                                                          _pickCategoryInline(c)),
                                                ...TagSeedService
                                                        .getBillingTagNames(
                                                            c.billingTypes, l10n)
                                                    .map((t) => _chip(ctx, t)),
                                                _chip(
                                                  ctx,
                                                  timeText,
                                                  highlight:
                                                      fix.contains('time'),
                                                  onTap: () =>
                                                      _editAndApprove(c),
                                                ),
                                                _chip(
                                                  ctx,
                                                  '${l10n.pendingFieldLedger}：${_ledgerLabel(c.bill.ledgerId)}',
                                                ),
                                              ],
                                            );
                                          }),
                                          if ((bill.merchant ?? '').trim().isNotEmpty)
                                            Padding(
                                              padding:
                                                  const EdgeInsets.only(top: 2),
                                              child: Text(
                                                '${l10n.pendingFieldMerchant}：${bill.merchant}',
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                  color: theme
                                                      .colorScheme.onSurface
                                                      .withValues(alpha: 0.6),
                                                ),
                                              ),
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
                                          // U-2(2026-10-11):动作行改 Wrap —— 三个
                                          // 按钮的文本在 320 宽 / textScale 2.0 下
                                          // 超出可用宽度(RenderFlex overflow),
                                          // 换行后仍全部可点(不再把按钮挤出屏幕
                                          // 导致无法确认/忽略候选)。每个按钮保持
                                          // 最小点击宽度,文本可收缩省略。
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 6,
                                            crossAxisAlignment:
                                                WrapCrossAlignment.center,
                                            children: [
                                              OutlinedButton(
                                                onPressed: () => _reject(c),
                                                child: Text(
                                                  l10n.pendingConfirmationReject,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              OutlinedButton(
                                                onPressed: () =>
                                                    _editAndApprove(c),
                                                child: Text(
                                                  l10n.pendingConfirmationEdit,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              FilledButton(
                                                onPressed: () => _approve(c),
                                                child: Text(
                                                  l10n.pendingConfirmationConfirm,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
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
                        // U-2:标题行改 Wrap —— 窄屏/大字体下"相似已有交易 #N"
                        // 与"匹配度 N%"不再互相挤压(小屏此前溢出)。
                        Wrap(
                          spacing: 6,
                          runSpacing: 2,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Icon(
                              Icons.compare_arrows,
                              size: 17,
                              color: theme.colorScheme.secondary,
                            ),
                            ConstrainedBox(
                              constraints: const BoxConstraints(
                                  maxWidth: 220),
                              child: Text(
                                '${l10n.pendingConfirmationSimilarTransaction} #$transactionId',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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
                          '${_amountText(details.transaction.amount, details.transaction.currencyCode)}  ·  ${_dateTimeText(details.transaction.happenedAt)}${_matchedCategoryText(details) == null ? '' : '  ·  ${_matchedCategoryText(details)}'}${details.transaction.recordedAt == null ? '' : '  ·  ${l10n.pendingConfirmationRecordedAt} ${_dateTimeText(details.transaction.recordedAt!)}'}',
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
    String? recordedAt,
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
          if (recordedAt != null)
            _buildComparisonField(
                context, l10n.pendingConfirmationRecordedAt, recordedAt),
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
                  recordedAt: transaction.recordedAt == null
                      ? null
                      : _dateTimeText(transaction.recordedAt!),
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

  /// B4 任务 1:[highlight] = 按待确认原因**需要修正的字段**;[onTap] = 卡片
  /// 内直接改这一项,不必进完整编辑流。
  /// U-2(2026-10-11)窄屏/大字体加固:芯片文本可收缩(ellipsis)。
  /// 旧实现 Text 无 maxLines/overflow,超长字段名(账户/分类/备注)在 320 宽
  /// 或 textScale 2.0 下会撑破外层 Wrap 的可用宽度。
  Widget _chip(
    BuildContext context,
    String text, {
    bool highlight = false,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final color = highlight
        ? Colors.orange
        : theme.colorScheme.primary;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: highlight ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(8),
        border: highlight ? Border.all(color: color, width: 1) : null,
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
    if (onTap == null) return chip;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: chip,
    );
  }

  /// 按待确认原因/缺失字段算出「需要修正的字段」。
  Set<String> _fieldsToFix(PendingCandidate c) {
    final fields = <String>{};
    final reason = c.reason ?? '';
    final bill = c.bill;
    if (reason == 'timeInferred' ||
        reason == 'timePrecisionWeak' ||
        bill.timeInferred ||
        bill.timePrecision == BillTimePrecision.date ||
        bill.timePrecision == BillTimePrecision.inferred ||
        bill.timePrecision == BillTimePrecision.unknown ||
        bill.time == null) {
      fields.add('time');
    }
    if (reason == 'transferAccountMissing' ||
        (bill.account ?? '').trim().isEmpty) {
      fields.add('account');
    }
    if (reason == 'confidenceMissing' ||
        reason == 'lowConfidence' ||
        reason == 'settlementUnknown' ||
        bill.amount == null ||
        bill.amount == 0) {
      fields.add('amount');
    }
    if (reason == 'duplicate') fields.add('compare');
    return fields;
  }

  /// 时间精度的可读标注(可信时间的判断口径,不展示内部枚举)。
  String _timePrecisionLabel(AppLocalizations l10n, BillInfo bill) {
    if (bill.time == null) return '· ${l10n.pendingFieldHintTime}';
    if (bill.timeInferred) return '· ${l10n.pendingTimeInferred}';
    return switch (bill.timePrecision) {
      BillTimePrecision.date => '· ${l10n.pendingTimeDateOnly}',
      BillTimePrecision.inferred => '· ${l10n.pendingTimeInferred}',
      BillTimePrecision.unknown => '· ${l10n.pendingTimeDateOnly}',
      _ => '· ${l10n.pendingTimeTrusted}',
    };
  }

  /// 目标账本标签:按本地 id 反查名称,查不到显示 id(不虚构账本名)。
  String _ledgerLabel(int? ledgerId) {
    if (ledgerId == null) return '—';
    for (final l in _ledgers) {
      if (l.id == ledgerId) return l.name;
    }
    return '#$ledgerId';
  }

  /// 卡片内选账户:只补这一个字段,确认仍走「确认」按钮。
  Future<void> _pickAccountInline(PendingCandidate c) async {
    final accounts =
        ref.read(allAccountsStreamProvider).valueOrNull ?? const [];
    if (accounts.isEmpty) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(l10nPendingSelectAccount(ctx),
                  style: Theme.of(ctx).textTheme.titleSmall),
            ),
            for (final a in accounts)
              ListTile(
                dense: true,
                title: Text(a.name),
                subtitle: Text(a.currency),
                trailing: (c.bill.account ?? '') == a.name
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(ctx, a.name),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _inlineEdits[c.id] =
          c.copyWith(bill: c.bill.copyWith(account: picked));
    });
  }

  String l10nPendingSelectAccount(BuildContext ctx) =>
      AppLocalizations.of(ctx).pendingSelectAccount;

  /// 卡片内选分类:同编辑流第一步,选完即生效。
  Future<void> _pickCategoryInline(PendingCandidate c) async {
    final l10n = AppLocalizations.of(context);
    final kind = switch (c.bill.type) {
      BillType.income => 'income',
      BillType.transfer => 'transfer',
      _ => 'expense',
    };
    final ledgerId = c.bill.ledgerId;
    if (ledgerId == null) {
      showToast(context, l10n.pendingConfirmationUncheckedReason);
      return;
    }
    schema.Category? initialCategory;
    try {
      initialCategory = await _matchCategoryByName(c.bill.category, kind);
    } catch (_) {
      initialCategory = null;
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<schema.Category>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(
                children: [
                  Text(l10n.pendingSelectCategory,
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
    );
    if (picked == null || !mounted) return;
    setState(() {
      _inlineEdits[c.id] =
          c.copyWith(bill: c.bill.copyWith(category: picked.name));
    });
  }
}
