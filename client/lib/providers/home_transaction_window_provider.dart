import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/transaction_repository.dart';
import '../../utils/month_range.dart';
import 'database_providers.dart';

/// 首页交易窗口状态（M5-4）。
///
/// 状态持有当前窗口的交易列表与游标边界，供 [HomeTransactionWindowController]
/// 做双向 keyset 加载、月份锚定、新记录提示与 generation 防串账。
class HomeTransactionWindowState {
  final int ledgerId;

  /// generation：账本切换/月份锚定/手动刷新时 +1，异步结果迟到时丢弃。
  final int generation;

  /// 当前窗口内已加载的交易（按 happenedAt 降序）。
  final List<TransactionWithRefs> items;

  /// 窗口最旧游标（加载 older 的锚点）。
  final TransactionPageCursor? oldestCursor;

  /// 窗口最新游标（loadNewer 的锚点）。
  final TransactionPageCursor? newestCursor;

  /// 是否处于「最新模式」（跟随实时新增）；false = 历史锚定模式。
  final bool isLatestMode;

  final bool loadingInitial;
  final bool loadingNewer;
  final bool loadingOlder;

  /// 该方向是否还有更多可加载。
  final bool hasNewer;
  final bool hasOlder;

  /// 历史模式下未加入窗口的新交易数量（仅计数提示，不打断阅读）。
  final int unseenNewCount;

  /// 锚定的月份标签（DateTime(year, month, 1)）；null = 未锚定。
  final DateTime? anchorMonth;

  final Object? error;

  const HomeTransactionWindowState({
    required this.ledgerId,
    required this.generation,
    required this.items,
    this.oldestCursor,
    this.newestCursor,
    this.isLatestMode = true,
    this.loadingInitial = false,
    this.loadingNewer = false,
    this.loadingOlder = false,
    this.hasNewer = false,
    this.hasOlder = false,
    this.unseenNewCount = 0,
    this.anchorMonth,
    this.error,
  });

  HomeTransactionWindowState copyWith({
    int? ledgerId,
    int? generation,
    List<TransactionWithRefs>? items,
    TransactionPageCursor? oldestCursor,
    TransactionPageCursor? newestCursor,
    bool? isLatestMode,
    bool? loadingInitial,
    bool? loadingNewer,
    bool? loadingOlder,
    bool? hasNewer,
    bool? hasOlder,
    int? unseenNewCount,
    DateTime? anchorMonth,
    Object? error,
  }) {
    return HomeTransactionWindowState(
      ledgerId: ledgerId ?? this.ledgerId,
      generation: generation ?? this.generation,
      items: items ?? this.items,
      oldestCursor: oldestCursor ?? this.oldestCursor,
      newestCursor: newestCursor ?? this.newestCursor,
      isLatestMode: isLatestMode ?? this.isLatestMode,
      loadingInitial: loadingInitial ?? this.loadingInitial,
      loadingNewer: loadingNewer ?? this.loadingNewer,
      loadingOlder: loadingOlder ?? this.loadingOlder,
      hasNewer: hasNewer ?? this.hasNewer,
      hasOlder: hasOlder ?? this.hasOlder,
      unseenNewCount: unseenNewCount ?? this.unseenNewCount,
      anchorMonth: anchorMonth ?? this.anchorMonth,
      error: error ?? this.error,
    );
  }
}

/// 首页交易窗口控制器。持有仓库调用与 bounded watch 订阅，负责：
/// - 初始 latest 加载；older/newer 双向 keyset 加载并合并去重；
/// - generation 防串账（账本切换/锚定/刷新时丢弃迟到结果）；
/// - 月份锚定与空月份提示；历史模式收录新记录计数；
/// - dispose 时取消订阅。
class HomeTransactionWindowController
    extends StateNotifier<HomeTransactionWindowState> {
  final Ref ref;

  /// 分页大小，默认 80（文档 §3.2；含 hasMore 探针最多取 81 条）。
  final int pageSize;

  /// 常驻交易上限（文档 §5.7）。超过该值只保留最新窗口并保持可重载。
  static const int _maxResident = 960;

  StreamSubscription<List<TransactionWithRefs>>? _windowSub;
  bool _disposed = false;

  HomeTransactionWindowController(
    this.ref, {
    this.pageSize = 80,
    HomeTransactionWindowState? initial,
  }) : super(initial ??
            HomeTransactionWindowState(
              ledgerId: ref.read(currentLedgerIdProvider),
              generation: 0,
              items: const [],
            )) {
    // 记录首次账本,供账本切换检测(历史遗留字段,当前仅记录)。
  }

  /// 仅当未销毁时写入状态（dispose 后 StateNotifier 不可再 set）。
  void _setState(HomeTransactionWindowState s) {
    if (_disposed) return;
    state = s;
  }

  @override
  void dispose() {
    _disposed = true;
    _windowSub?.cancel();
    super.dispose();
  }

  /// 账本切换：清空窗口、bump generation，并重新初始化 latest。
  Future<void> resetForLedgerChange(int newLedgerId) async {
    await _windowSub?.cancel();
    _setState(HomeTransactionWindowState(
      ledgerId: newLedgerId,
      generation: state.generation + 1,
      items: const [],
    ));
    await initializeLatest(ledgerId: newLedgerId);
  }

  /// 取消既有 watch，重新订阅 bounded window。
  Future<void> _rebindWatch({
    required TransactionPageCursor? newestInclusive,
    required TransactionPageCursor oldestInclusive,
  }) async {
    await _windowSub?.cancel();
    final ledgerId = state.ledgerId;
    final repo = ref.read(repositoryProvider);
    _windowSub = repo
        .watchTransactionWindowWithCategory(
          ledgerId: ledgerId,
          newestInclusive: newestInclusive,
          oldestInclusive: oldestInclusive,
        )
        .listen((rows) {
      if (_disposed) return;
      // 窗口 watch 只负责上界以下、下界以上区间的收敛；latest 模式下
      // newestInclusive=null，新交易自动进入；历史锚定模式则只增计数。
      if (state.isLatestMode) {
        state = state.copyWith(items: rows, loadingInitial: false);
      } else {
        // 历史锚定：不直接插入打断阅读，只增加新记录计数提示。
        final extra = _countNewerNotInWindow(rows);
        state = state.copyWith(unseenNewCount: state.unseenNewCount + extra);
      }
    });
  }

  /// 统计 bounded watch 返回行里「比当前 newestCursor 更新」的条数，
  /// 作为历史模式下的新记录提示计数。
  int _countNewerNotInWindow(List<TransactionWithRefs> rows) {
    final newest = state.newestCursor;
    if (newest == null) return 0;
    var n = 0;
    for (final r in rows) {
      if (r.t.happenedAt.isAfter(newest.happenedAt) ||
          (r.t.happenedAt == newest.happenedAt && r.t.id > newest.id)) {
        n++;
      }
    }
    return n;
  }

  /// 从指定页码位置合并去重后重新组装 items（保持降序）。
  List<TransactionWithRefs> _merge(List<TransactionWithRefs> base, List<TransactionWithRefs> incoming) {
    final seen = base.map((r) => r.t.id).toSet();
    final merged = <TransactionWithRefs>[];
    for (final r in base) {
      merged.add(r);
    }
    for (final r in incoming) {
      if (seen.add(r.t.id)) merged.add(r);
    }
    merged.sort((a, b) {
      final c = b.t.happenedAt.compareTo(a.t.happenedAt);
      if (c != 0) return c;
      return b.t.id.compareTo(a.t.id);
    });
    return merged;
  }

  /// 收敛常驻窗口：超 [maxResident] 时只保留首尾各若干页（首版保守：
  /// 保留最新 12 页，超出时丢弃最旧页并保持 hasOlder 可重载）。
  List<TransactionWithRefs> _clamp(List<TransactionWithRefs> items) {
    if (items.length <= _maxResident) return items;
    return items.sublist(0, _maxResident);
  }

  // ==================== 对外方法 ====================

  /// 初始加载最新一页并建立 watch。
  ///
  /// [ledgerId] 可选：默认读 [currentLedgerIdProvider]；账本切换时由
  /// [resetForLedgerChange] 显式传入，避免依赖 provider 尚未更新的竞态。
  Future<void> initializeLatest({int? ledgerId}) async {
    final int targetLedger =
        ledgerId ?? ref.read(currentLedgerIdProvider);
    final gen = state.generation + 1;
    _setState(state.copyWith(
      generation: gen,
      ledgerId: targetLedger,
      loadingInitial: true,
      isLatestMode: true,
      error: null,
    ));
    try {
      final repo = ref.read(repositoryProvider);
      final page = await repo.getTransactionPageWithCategory(
          ledgerId: targetLedger, limit: pageSize);
      if (_stale(gen)) return;
      final items = page.items;
      _setState(state.copyWith(
        items: items,
        oldestCursor: page.lastCursor,
        newestCursor: null, // latest 模式上界不限
        hasOlder: page.hasOlder,
        hasNewer: page.hasNewer,
        loadingInitial: false,
        anchorMonth: null,
      ));
      await _rebindWatch(
        newestInclusive: null,
        oldestInclusive: page.lastCursor ??
            TransactionPageCursor(happenedAt: DateTime(1970, 1, 1), id: 0),
      );
    } catch (e) {
      if (_stale(gen)) return;
      _setState(state.copyWith(loadingInitial: false, error: e));
    }
  }

  bool _stale(int gen) => gen != state.generation;

  /// 加载更旧的一页并 prepend。
  Future<void> loadOlder() async {
    if (state.loadingOlder || !state.hasOlder) return;
    final gen = state.generation;
    final cursor = state.oldestCursor;
    if (cursor == null) return;
    _setState(state.copyWith(loadingOlder: true));
    try {
      final repo = ref.read(repositoryProvider);
      final page = await repo.getTransactionPageWithCategory(
          ledgerId: state.ledgerId, before: cursor, limit: pageSize);
      if (_stale(gen)) return;
      final merged = _merge(state.items, page.items);
      _setState(state.copyWith(
        items: _clamp(merged),
        oldestCursor: page.lastCursor ?? state.oldestCursor,
        hasOlder: page.hasOlder,
        loadingOlder: false,
      ));
    } catch (e) {
      if (_stale(gen)) return;
      _setState(state.copyWith(loadingOlder: false, error: e));
    }
  }

  /// 加载更新的一页并 append（历史锚定模式下用）。
  Future<void> loadNewer() async {
    if (state.loadingNewer || !state.hasNewer) return;
    final gen = state.generation;
    final cursor = state.newestCursor;
    if (cursor == null) return;
    _setState(state.copyWith(loadingNewer: true));
    try {
      final repo = ref.read(repositoryProvider);
      final page = await repo.getTransactionPageWithCategory(
          ledgerId: state.ledgerId, after: cursor, limit: pageSize);
      if (_stale(gen)) return;
      final merged = _merge(state.items, page.items);
      _setState(state.copyWith(
        items: _clamp(merged),
        newestCursor: page.lastCursor ?? state.newestCursor,
        hasNewer: page.hasNewer,
        loadingNewer: false,
      ));
    } catch (e) {
      if (_stale(gen)) return;
      _setState(state.copyWith(loadingNewer: false, error: e));
    }
  }

  /// 跳转到指定月份周期。end 为上边界加载第一页。
  Future<void> jumpToMonth(DateTime month) async {
    final gen = state.generation + 1;
    final ledgerId = ref.read(currentLedgerIdProvider);
    _setState(state.copyWith(
      generation: gen,
      loadingInitial: true,
      anchorMonth: DateTime(month.year, month.month, 1),
      isLatestMode: false,
      unseenNewCount: 0,
      error: null,
    ));
    try {
      final repo = ref.read(repositoryProvider);
      final sd = await _monthStartDay(ledgerId);
      final range = periodForLabel(month.year, month.month, sd);
      final has = await repo.hasTransactionsInPeriod(
          ledgerId: ledgerId, start: range.start, end: range.end);
      if (_stale(gen)) return;
      if (!has) {
        // 空月份:保留锚定但 items 为空,UI 显示空态。
        _setState(state.copyWith(
          loadingInitial: false,
          items: const [],
          oldestCursor: null,
          newestCursor: null,
          hasOlder: false,
          hasNewer: false,
        ));
        return;
      }
      // 以 end 为上边界,加载该月第一页(降序)。取「发生在 end 之前」的最新一页。
      final page = await repo.getTransactionPageWithCategory(
        ledgerId: ledgerId,
        before: TransactionPageCursor(happenedAt: range.end, id: 0x7fffffff),
        limit: pageSize,
      );
      if (_stale(gen)) return;
      _setState(state.copyWith(
        items: page.items,
        oldestCursor: page.lastCursor,
        newestCursor: page.firstCursor,
        hasOlder: page.hasOlder,
        hasNewer: true, // 上方可 loadNewer 回更近记录
        loadingInitial: false,
      ));
      await _rebindWatch(
        newestInclusive: page.firstCursor,
        oldestInclusive: page.lastCursor ??
            TransactionPageCursor(happenedAt: DateTime(1970, 1, 1), id: 0),
      );
    } catch (e) {
      if (_stale(gen)) return;
      _setState(state.copyWith(loadingInitial: false, error: e));
    }
  }

  Future<int> _monthStartDay(int ledgerId) async {
    final repo = ref.read(repositoryProvider);
    final ledger = await repo.getLedgerById(ledgerId);
    return (ledger?.monthStartDay ?? 1).clamp(1, 28);
  }

  /// 刷新当前窗口（重新拉取当前边界之间的 last page）。
  Future<void> refreshWindow() async {
    if (state.isLatestMode) {
      await initializeLatest();
    } else if (state.anchorMonth != null) {
      await jumpToMonth(state.anchorMonth!);
    }
  }

  /// 回到最新模式。
  Future<void> returnToLatest() async {
    await initializeLatest();
  }

  /// 加载失败后重试。
  Future<void> retry() async {
    await refreshWindow();
  }
}

/// 首页交易窗口 Provider。
///
/// 内部监听账本切换：切账本时立即重置为全新状态（清空 items、bump
/// generation），避免旧账本数据残留，再重新初始化 latest 窗口 —— 迟到的
/// 旧请求结果因 generation 不匹配被丢弃。
final homeTransactionWindowProvider =
    StateNotifierProvider<HomeTransactionWindowController,
        HomeTransactionWindowState>((ref) {
  final controller = HomeTransactionWindowController(ref, pageSize: 80);
  ref.listen<int>(currentLedgerIdProvider, (prev, next) {
    if (prev != null && prev != next) {
      // 账本切换：重置窗口并重新初始化。
      controller.resetForLedgerChange(next);
    }
  });
  return controller;
});
