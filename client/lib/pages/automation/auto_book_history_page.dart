import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart' as schema;
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../services/automation/auto_book_reason_presenter.dart';
import '../../widgets/ui/primary_header.dart';
import 'auto_book_event_detail_page.dart';

/// 自动入口处理历史。仅展示状态摘要，不展示原始短信/通知/页面文本。
class AutoBookHistoryPage extends ConsumerStatefulWidget {
  const AutoBookHistoryPage({super.key});

  @override
  ConsumerState<AutoBookHistoryPage> createState() =>
      _AutoBookHistoryPageState();
}

class _AutoBookHistoryPageState extends ConsumerState<AutoBookHistoryPage> {
  List<schema.AutoBookEvent> _events = const [];
  bool _loading = true;
  String _stateFilter = 'all';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final store = ref.read(autoBookCoordinatorProvider).store;
    final events = await store.listHistory(
      state: _stateFilter == 'all' ? null : _stateFilter,
    );
    if (!mounted) return;
    setState(() {
      _events = events;
      _loading = false;
    });
  }

  String _stateLabel(String state) =>
      AutoBookReasonPresenter.stateLabel(state);

  Color _stateColor(BuildContext context, String state) {
    final scheme = Theme.of(context).colorScheme;
    return switch (state) {
      'booked' => Colors.green,
      'duplicate' => scheme.secondary,
      'pending' => Colors.orange,
      'retry' || 'failed' => scheme.error,
      'ignored' || 'expired' => scheme.outline,
      _ => scheme.primary,
    };
  }

  String _sourceLabel(String source) =>
      AutoBookReasonPresenter.sourceLabel(source);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          PrimaryHeader(
            title: '自动记账历史',
            subtitle: '只保留来源、状态和交易关联摘要',
            showBack: true,
            leadingIcon: Icons.history,
            leadingPlain: true,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  // 全部九态筛选(P1-2):failed/expired 曾缺失,失败无法定位
                  for (final state in const [
                    'all',
                    'booked',
                    'pending',
                    'duplicate',
                    'retry',
                    'failed',
                    'ignored',
                    'expired',
                    'processing',
                    'captured',
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(state == 'all' ? '全部' : _stateLabel(state)),
                        selected: _stateFilter == state,
                        onSelected: (_) {
                          setState(() {
                            _stateFilter = state;
                            _loading = true;
                          });
                          _reload();
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _events.isEmpty
                    ? const Center(child: Text('暂无自动记账历史'))
                    : RefreshIndicator(
                        onRefresh: _reload,
                        child: ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: _events.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final event = _events[index];
                            final l10n = AppLocalizations.of(context);
                            final color = _stateColor(context, event.state);
                            return Card(
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor:
                                      color.withValues(alpha: 0.12),
                                  child: Icon(Icons.bolt, color: color),
                                ),
                                title: Row(
                                  children: [
                                    Text(_sourceLabel(event.source)),
                                    const SizedBox(width: 8),
                                    Chip(
                                      label: Text(_stateLabel(event.state)),
                                      visualDensity: VisualDensity.compact,
                                      side: BorderSide.none,
                                      backgroundColor:
                                          color.withValues(alpha: 0.12),
                                      labelStyle: TextStyle(color: color),
                                    ),
                                  ],
                                ),
                                subtitle: Text(
                                  // B1:普通列表只展示可读原因;内部原因码与
                                  // 错误信息只在详情页的可展开诊断区出现,
                                  // 不把堆栈/凭据铺进列表。
                                  '${event.updatedAt.toLocal()}\n'
                                  '${AutoBookReasonPresenter.present(l10n, reason: event.reason, state: event.state).title}'
                                  '${event.transactionId == null ? '' : ' · 交易 #${event.transactionId}'}',
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                isThreeLine: true,
                                // 列表项可点进详情(P1-2):状态/原因/证据/错误全量可见
                                onTap: () async {
                                  await Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          AutoBookEventDetailPage(event: event),
                                    ),
                                  );
                                  _reload();
                                },
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
