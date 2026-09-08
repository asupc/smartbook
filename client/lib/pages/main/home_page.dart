import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_list_view/flutter_list_view.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import '../../providers/budget_providers.dart';
import '../budget/budget_page.dart';
import '../../providers.dart';
import '../settings/personalize_page.dart' show headerStyleProvider;
import '../../data/db.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/biz/smartbook_icon.dart';
import '../transaction/search_page.dart';
import '../../l10n/app_localizations.dart';
import '../../services/system/logger_service.dart';
import '../../utils/format_utils.dart';
import '../../utils/month_range.dart';
import '../../services/export/share_poster_service.dart';
import '../report/annual_report_page.dart';
import '../calendar/calendar_page.dart';
import '../../widgets/biz/ledger_picker_sheet.dart';
import 'ledgers_page_new.dart';
import '../../providers/shared_ledger_providers.dart';
import '../automation/pending_confirmation_page.dart';

// 优化版首页 - 使用FlutterListView实现精准定位和丝滑跳转
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  late FlutterListViewController _listController;
  bool _isJumping = false;
  final GlobalKey<TransactionListState> _transactionListKey =
      GlobalKey<TransactionListState>();

  // 可见性管理
  final Set<String> _visibleHeaders = {}; // 当前可见的日期头部
  Timer? _debounceTimer;

  // StreamBuilder 刷新计数器
  int _streamBuilderKey = 0;
  int? _lastLedgerId;

  // home build 缓存的 tx stream。repo.transactionsWithCategoryAll 内部每次调
  // 都 new StreamController,如果在 build 里直接调,只要 home 因任何 setState
  // (例如 _showBudgetSetupHint / _showLastMonthReminder 异步加载完成)重 build,
  // StreamBuilder 看到 stream 引用变了就重新订阅 → snapshot.data 短暂为 null
  // → fallback 到 cachedFullData(只有前 20 条预加载)→ 等 Drift 推数据 → 切回
  // 完整列表,视觉上"整页闪一下"。这里把 stream 缓存到 State,只在 ledgerId
  // 变化时重建,无关 setState 重 build 时复用同一 stream 引用。
  Stream<List<({Transaction t, Category? category, Account? account, Account? toAccount})>>?
      _txStream;
  int? _txStreamLedgerId;

  // 月初提醒状态
  bool _showLastMonthReminder = false;
  static const String _reminderDismissedKey = 'last_month_reminder_dismissed';

  // 年度账单提醒状态（12月15日 - 次年1月31日显示）
  bool _showAnnualReportReminder = false;
  static const String _annualReportDismissedKey =
      'annual_report_reminder_dismissed';

  // 预算设置引导卡片状态
  bool _showBudgetSetupHint = false;
  static const String _budgetSetupHintDismissedKey =
      'budget_setup_hint_dismissed';

  // 待确认提醒条状态(P0-3):有待确认候选时首页提醒;
  // 当日已点过/关过且数量未增加则不再显示(prefs 记日期+当时数量)。
  static const String _pendingBannerDismissedDateKey =
      'pending_banner_dismissed_date';
  static const String _pendingBannerDismissedCountKey =
      'pending_banner_dismissed_count';
  String? _pendingBannerDismissedDate;
  int _pendingBannerDismissedCount = 0;

  @override
  void initState() {
    super.initState();
    _listController = FlutterListViewController();
    _checkLastMonthReminder();
    _checkAnnualReportReminder();
    _checkBudgetSetupHint();
    _loadPendingBannerDismissState();
    // 首页展示期间候选可能变化(后台捕获冷启动 drain 后即 resumed),拉一次新
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(pendingCandidateCountProvider);
    });
  }

  Future<void> _loadPendingBannerDismissState() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _pendingBannerDismissedDate =
          prefs.getString(_pendingBannerDismissedDateKey);
      _pendingBannerDismissedCount =
          prefs.getInt(_pendingBannerDismissedCountKey) ?? 0;
    });
  }

  /// 记录「今日已处理过提醒条」:点按进确认页或点关闭都算;
  /// 数量再增加时提醒条会重新出现。
  Future<void> _dismissPendingBanner(int count) async {
    final now = DateTime.now();
    final today = '${now.year}-${now.month}-${now.day}';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingBannerDismissedDateKey, today);
    await prefs.setInt(_pendingBannerDismissedCountKey, count);
    if (mounted) {
      setState(() {
        _pendingBannerDismissedDate = today;
        _pendingBannerDismissedCount = count;
      });
    }
  }

  // 检查是否应该显示上月报告提醒
  Future<void> _checkLastMonthReminder() async {
    final now = DateTime.now();
    // 只在每月前7天显示提醒
    if (now.day > 7) return;

    final prefs = await SharedPreferences.getInstance();
    final dismissedMonth = prefs.getString(_reminderDismissedKey);
    final currentMonth = '${now.year}-${now.month}';

    // 如果当月已经关闭过，不再显示
    if (dismissedMonth == currentMonth) return;

    if (mounted) {
      setState(() {
        _showLastMonthReminder = true;
      });
    }
  }

  // 关闭上月报告提醒
  Future<void> _dismissLastMonthReminder() async {
    final now = DateTime.now();
    final currentMonth = '${now.year}-${now.month}';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_reminderDismissedKey, currentMonth);

    if (mounted) {
      setState(() {
        _showLastMonthReminder = false;
      });
    }
  }

  // 检查是否应该显示年度账单提醒（12月15日 - 次年1月31日）
  Future<void> _checkAnnualReportReminder() async {
    final now = DateTime.now();

    // 判断是否在提醒时间范围内：12月15日 - 次年1月31日
    final isInRange = (now.month == 12 && now.day >= 15) || now.month == 1;
    if (!isInRange) return;

    // 确定要展示的年度（12月展示当年，1月展示上一年）
    final reportYear = now.month == 1 ? now.year - 1 : now.year;

    final prefs = await SharedPreferences.getInstance();
    final dismissedYear = prefs.getInt(_annualReportDismissedKey);

    // 如果这个年度已经关闭过，不再显示
    if (dismissedYear == reportYear) return;

    if (mounted) {
      setState(() {
        _showAnnualReportReminder = true;
      });
    }
  }

  // 关闭年度账单提醒
  Future<void> _dismissAnnualReportReminder() async {
    final now = DateTime.now();
    final reportYear = now.month == 1 ? now.year - 1 : now.year;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_annualReportDismissedKey, reportYear);

    if (mounted) {
      setState(() {
        _showAnnualReportReminder = false;
      });
    }
  }

  // 检查是否应该显示预算设置引导卡片
  Future<void> _checkBudgetSetupHint() async {
    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getBool(_budgetSetupHintDismissedKey) ?? false;
    if (dismissed) return;

    if (mounted) {
      setState(() {
        _showBudgetSetupHint = true;
      });
    }
  }

  // 关闭预算设置引导卡片（永不再显示）
  Future<void> _dismissBudgetSetupHint() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_budgetSetupHintDismissedKey, true);

    if (mounted) {
      setState(() {
        _showBudgetSetupHint = false;
      });
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _listController.dispose();
    super.dispose();
  }

  // 精准月份跳转 - 使用TransactionList组件的跳转功能
  Future<void> _jumpToTargetMonth(DateTime targetMonth) async {
    if (_isJumping) return; // 防止重复跳转

    setState(() {
      _isJumping = true;
    });

    try {
      // 使用TransactionList组件的跳转方法
      final transactionListState = _transactionListKey.currentState;
      if (transactionListState != null && mounted) {
        transactionListState.jumpToMonth(
          targetMonth,
          startDay: ref.read(currentMonthStartDayProvider),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isJumping = false;
        });
      }
    }
  }

  // 日期头部可见性变化
  void _onHeaderVisibilityChanged(String dateKey, bool isVisible) {
    if (_isJumping) return;

    if (isVisible) {
      _visibleHeaders.add(dateKey);
    } else {
      _visibleHeaders.remove(dateKey);
    }

    // 防抖更新月份
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 100), () {
      _updateCurrentMonth();
    });
  }

  // 更新当前月份
  void _updateCurrentMonth() {
    if (_isJumping || !mounted || _visibleHeaders.isEmpty) return;

    try {
      // 获取最顶部的可见日期头部（按日期排序，取最新的）
      final sortedDates = _visibleHeaders.toList()
        ..sort((a, b) => b.compareTo(a));
      final topDateKey = sortedDates.first;

      final dateParts = topDateKey.split('-');
      if (dateParts.length != 3) return;

      final year = int.parse(dateParts[0]);
      final month = int.parse(dateParts[1]);
      final day = int.parse(dateParts[2]);
      // 交易日期 → 它所属周期的标签月(startDay>1 时月初几天属上个标签月)
      final sd = ref.read(currentMonthStartDayProvider);
      final detectedMonth = labelForDate(DateTime(year, month, day), sd);

      // 更新选中月份
      final currentSelected = ref.read(selectedMonthProvider);
      if (currentSelected.year != detectedMonth.year ||
          currentSelected.month != detectedMonth.month) {
        ref.read(selectedMonthProvider.notifier).state = detectedMonth;
      }
    } catch (e) {
      // 忽略错误，继续正常运行
    }
  }

  /// M5-4 窗口化分页路径：从 [homeTransactionWindowProvider] 读取窗口状态，
  /// 传给 [TransactionList] 并接好双向 loader / 新记录横幅。
  Widget _buildWindowedTransactionList(
    BuildContext context,
    int ledgerId,
    bool hide,
  ) {
    final cachedFullData = ref.watch(cachedTransactionsProvider);
    // 首次进入窗口需初始化（账本切换由 provider 内部 ref.listen 处理）。
    final win = ref.watch(homeTransactionWindowProvider);
    if (!win.loadingInitial && win.items.isEmpty) {
      // 确保初始加载已触发（首次 build 时 provider 尚未初始化）。
      Future.microtask(() {
        ref.read(homeTransactionWindowProvider.notifier).initializeLatest();
      });
    }

    // 窗口 items 就是 TransactionWithRefs,与 TransactionList.transactions 同型。
    final items = win.items.map((r) => (
          t: r.t,
          category: r.category,
          account: r.account,
          toAccount: r.toAccount,
        )).toList();

    final list = TransactionList(
      key: _transactionListKey,
      transactions: items,
      transactionsWithDetails: cachedFullData,
      hideAmounts: hide,
      enableVisibilityTracking: true,
      onDateVisibilityChanged: _onHeaderVisibilityChanged,
      controller: _listController,
      hasOlder: win.hasOlder,
      hasNewer: win.hasNewer,
      loadingOlder: win.loadingOlder,
      loadingNewer: win.loadingNewer,
      onLoadOlder: () =>
          ref.read(homeTransactionWindowProvider.notifier).loadOlder(),
      onLoadNewer: () =>
          ref.read(homeTransactionWindowProvider.notifier).loadNewer(),
      unseenNewCount: win.isLatestMode ? null : win.unseenNewCount,
      onReturnToLatest: () =>
          ref.read(homeTransactionWindowProvider.notifier).returnToLatest(),
      emptyWidget: AppEmpty(
        text: AppLocalizations.of(context).homeNoRecords,
        subtext: AppLocalizations.of(context).homeNoRecordsSubtext,
      ),
    );

    // 初始加载中且无内容时,先用 Splash 缓存占位。
    if (win.loadingInitial && items.isEmpty && cachedFullData != null) {
      return TransactionList(
        key: _transactionListKey,
        transactions: cachedFullData
            .map((item) => (
                  t: item.t,
                  category: item.category,
                  account: item.account,
                  toAccount: item.toAccount,
                ))
            .toList(),
        transactionsWithDetails: cachedFullData,
        hideAmounts: hide,
        enableVisibilityTracking: true,
        onDateVisibilityChanged: _onHeaderVisibilityChanged,
        controller: _listController,
        emptyWidget: AppEmpty(
          text: AppLocalizations.of(context).homeNoRecords,
          subtext: AppLocalizations.of(context).homeNoRecordsSubtext,
        ),
      );
    }

    return list;
  }

  // FlutterListView不需要手动计算偏移量，直接使用jumpToIndex即可！

  // 日期选择处理
  Future<void> _handleDateSelection() async {
    final month = ref.read(selectedMonthProvider);
    final res = await showWheelDatePicker(
      context,
      initial: month,
      mode: WheelDatePickerMode.ym,
      maxDate: DateTime.now(),
    );

    if (res != null) {
      final targetMonth = DateTime(res.year, res.month, 1);
      ref.read(selectedMonthProvider.notifier).state = targetMonth;

      // 使用FlutterListView的精准跳转
      await _jumpToTargetMonth(targetMonth);
    }
  }

  // 构建月初提醒卡片
  Widget _buildLastMonthReminderCard(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final sd = ref.watch(currentMonthStartDayProvider);
    final currentLabel = labelForDate(now, sd);
    final lastMonth = DateTime(currentLabel.year, currentLabel.month - 1, 1);
    final monthFormat = DateFormat.MMMM(l10n.localeName);
    final primaryColor = ref.watch(primaryColorProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: isDark ? const Color(0xFF111726) : Colors.white,
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0),
          width: 0.8,
        ),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            // 左侧装饰条
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(
                width: 4,
                color: primaryColor,
              ),
            ),
            // 主体内容
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(
                children: [
                  // 文案
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          color: primaryColor,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: monthFormat.format(lastMonth),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: primaryColor,
                                  ),
                                ),
                                TextSpan(
                                  text: ' ${l10n.homeLastMonthReportSubtitle}',
                                  style: TextStyle(
                                    color: isDark
                                        ? Colors.white70
                                        : Colors.black54,
                                  ),
                                ),
                              ],
                            ),
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 查看按钮（查看后本次隐藏，下次打开app还会显示）
                  GestureDetector(
                    onTap: () {
                      SharePosterService.showPosterCarouselPreview(
                        context,
                        year: lastMonth.year,
                        month: lastMonth.month,
                      );
                      // 只临时隐藏，不保存到 prefs
                      setState(() {
                        _showLastMonthReminder = false;
                      });
                    },
                    child: Text(
                      l10n.homeLastMonthReportView,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: primaryColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 关闭按钮（关闭后当月不再显示）
                  GestureDetector(
                    onTap: _dismissLastMonthReminder,
                    behavior: HitTestBehavior.opaque,
                    child: Icon(
                      Icons.close,
                      size: 18,
                      color: isDark ? Colors.white38 : Colors.black26,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 待确认提醒卡片(样式与月初提醒一致,P0-3)
  Widget _buildPendingConfirmBanner(BuildContext context, int count) {
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.watch(primaryColorProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = Colors.orange;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: isDark ? const Color(0xFF111726) : Colors.white,
        border: Border.all(
          color: isDark
              ? accent.withValues(alpha: 0.25)
              : accent.withValues(alpha: 0.2),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: isDark ? 0.08 : 0.06),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(width: 4, color: accent),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(
                children: [
                  Icon(Icons.fact_check_outlined, color: accent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.homePendingConfirmBanner(count),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () async {
                      await _dismissPendingBanner(count);
                      if (!mounted) return;
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const PendingConfirmationPage()),
                      );
                      if (mounted) {
                        ref.invalidate(pendingCandidateCountProvider);
                      }
                    },
                    child: Row(
                      children: [
                        Text(
                          l10n.pendingConfirmationTitle,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: primaryColor,
                          ),
                        ),
                        Icon(Icons.chevron_right,
                            size: 18, color: primaryColor),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () => _dismissPendingBanner(count),
                    behavior: HitTestBehavior.opaque,
                    child: Icon(
                      Icons.close,
                      size: 18,
                      color: isDark ? Colors.white38 : Colors.black26,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 年度账单提醒卡片（样式与月初提醒一致）
  Widget _buildAnnualReportReminderCard(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final reportYear = now.month == 1 ? now.year - 1 : now.year;
    final primaryColor = ref.watch(primaryColorProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: isDark ? const Color(0xFF111726) : Colors.white,
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0),
          width: 0.8,
        ),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            // 左侧装饰条
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(
                width: 4,
                color: primaryColor,
              ),
            ),
            // 主体内容
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(
                children: [
                  // 文案
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_graph_rounded,
                          color: primaryColor,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.homeAnnualReportReminder(reportYear),
                            style: TextStyle(
                              fontSize: 14,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 查看按钮
                  GestureDetector(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              AnnualReportPage(initialYear: reportYear),
                        ),
                      );
                      // 临时隐藏
                      setState(() {
                        _showAnnualReportReminder = false;
                      });
                    },
                    child: Text(
                      l10n.homeAnnualReportView,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: primaryColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 关闭按钮
                  GestureDetector(
                    onTap: _dismissAnnualReportReminder,
                    behavior: HitTestBehavior.opaque,
                    child: Icon(
                      Icons.close,
                      size: 18,
                      color: isDark ? Colors.white38 : Colors.black26,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 预算设置引导卡片（无预算时显示，样式与月初提醒一致）
  Widget _buildBudgetSetupHintCard(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.watch(primaryColorProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: isDark ? const Color(0xFF111726) : Colors.white,
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0),
          width: 0.8,
        ),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            // 左侧装饰条
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(
                width: 4,
                color: primaryColor,
              ),
            ),
            // 主体内容
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(
                children: [
                  // 图标 + 文案
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          Icons.pie_chart_outline_rounded,
                          color: primaryColor,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.budgetSetupHint,
                            style: TextStyle(
                              fontSize: 14,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 去设置按钮
                  GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const BudgetPage()),
                      );
                    },
                    child: Text(
                      l10n.budgetSetupAction,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: primaryColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 关闭按钮
                  GestureDetector(
                    onTap: _dismissBudgetSetupHint,
                    behavior: HitTestBehavior.opaque,
                    child: Icon(
                      Icons.close,
                      size: 18,
                      color: isDark ? Colors.white38 : Colors.black26,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    // 预加载数据（含标签、附件、账户，仅前 N 条）
    final cachedFullData = ref.watch(cachedTransactionsProvider);
    final ledgerId = ref.watch(currentLedgerIdProvider);
    final month = ref.watch(selectedMonthProvider);
    final hide = ref.watch(hideAmountsProvider);

    // 检测账本切换，强制刷新 StreamBuilder 并清空缓存
    if (_lastLedgerId != null && _lastLedgerId != ledgerId) {
      _streamBuilderKey++;
      // 清空缓存，避免显示旧账本数据
      Future.microtask(() {
        ref.read(cachedTransactionsProvider.notifier).state = null;
      });
      logger.info('HomePage',
          '账本切换: $_lastLedgerId → $ledgerId, 刷新StreamBuilder (key=$_streamBuilderKey)');
    }
    _lastLedgerId = ledgerId;

    // 监听滚动到顶部的信号
    ref.listen<int>(homeScrollToTopProvider, (previous, next) {
      if (previous != next) {
        // 滚动到列表顶部
        _transactionListKey.currentState?.jumpToTop();
      }
    });

    // 监听切换到 Stream 模式的信号
    ref.listen<int>(homeSwitchToStreamProvider, (previous, next) {
      if (previous != next) {
        _transactionListKey.currentState?.switchToStreamMode();
      }
    });

    // D 方案后:Drift JOIN + SharedLedger* table-watch 已经在 Repository 层
    // 自动响应共享资源变化(分类 / 账户),tx stream 会重 emit 出带新 name
    // 的记录。不再需要在 HomePage 强制 _streamBuilderKey++ / invalidate
    // accountForTxProvider 这种激进刷新 — 那会让 Editor 编辑 tx 的本地
    // push-pull 循环触发整个 StreamBuilder 子树重建("首页全局刷新"症状)。
    // 如果有 forceStreamModeImmediate 的语义需要(强制把 preloaded 切到
    // live stream),可以单独 listen sharedResourceRefreshProvider 处理,
    // 但 StreamBuilder key 重建保持不动。
    ref.listen<int>(sharedResourceRefreshProvider, (previous, next) {
      if (previous != next) {
        _transactionListKey.currentState?.forceStreamModeImmediate();
      }
    });

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor, // ⭐ 自适应背景色
      body: Column(
        children: [
          Consumer(builder: (context, ref, _) {
            ref.watch(headerStyleProvider);
            return PrimaryHeader(
              title: '',
              showTitleSection: false,
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 头部 - 左: BeeIcon + 账本切换, 右: 操作按钮
                  SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        // 左侧：BeeIcon + 标题 + 账本切换胶囊（用 Expanded 包住，
                        // 标题在空间富余时显示自然宽度，仅在不够时 ellipsis）
                        SmartBookIcon(
                          size: 28,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Row(
                            children: [
                              // 标题取自然宽度,溢出时优先压缩账本名而不是 app 名
                              Text(
                                AppLocalizations.of(context).homeAppTitle,
                                maxLines: 1,
                                softWrap: false,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodyLarge
                                          ?.color,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: Consumer(builder: (context, ref, _) {
                                    final currentLedger =
                                        ref.watch(currentLedgerProvider);
                                    return currentLedger.when(
                                      // invalidate(远端改名 / 改币种)期间继续
                                      // 显示旧值,避免账本名胶囊瞬间消失再出现 —
                                      // 用户感知"首页全量刷新"的主要来源。
                                      skipLoadingOnReload: true,
                                      data: (ledger) {
                                        // ledger == null:还没有账本(welcome 未勾默认账本
                                        // / 老用户导入配置不含账本),胶囊直接显示「新建账本」
                                        // + 加号图标,点击 push LedgersPage 并自动弹创建对
                                        // 话框,省两步点击。
                                        final isEmpty = ledger == null;
                                        return GestureDetector(
                                          onTap: () {
                                            if (isEmpty) {
                                              Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (_) =>
                                                      const LedgersPageNew(
                                                          autoOpenCreateDialog:
                                                              true),
                                                ),
                                              );
                                            } else {
                                              showLedgerPicker(context);
                                            }
                                          },
                                          child: Container(
                                            padding:
                                                const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 5),
                                            decoration: BoxDecoration(
                                              color: Theme.of(context)
                                                          .brightness ==
                                                      Brightness.dark
                                                  ? const Color(0xFF1E293B)
                                                  : Colors.white,
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              border: Border.all(
                                                color: Theme.of(context).brightness == Brightness.dark
                                                    ? Colors.white.withValues(alpha: 0.1)
                                                    : const Color(0xFFE2E8F0),
                                                width: 0.8,
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                if (isEmpty) ...[
                                                  Icon(
                                                    Icons.add,
                                                    size: 16,
                                                    color: Theme.of(context)
                                                        .textTheme
                                                        .bodyLarge
                                                        ?.color,
                                                  ),
                                                  const SizedBox(width: 4),
                                                ],
                                                Flexible(
                                                  child: Text(
                                                    isEmpty
                                                        ? AppLocalizations.of(
                                                                context)
                                                            .ledgersNew
                                                        : translateLedgerName(
                                                            context,
                                                            ledger.name),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    softWrap: false,
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                      color: Theme.of(context)
                                                          .textTheme
                                                          .bodyLarge
                                                          ?.color,
                                                    ),
                                                  ),
                                                ),
                                                // v24 共享账本:header 也显示 🤝 角标 + 成员数
                                                if (!isEmpty &&
                                                    ledger.isShared) ...[
                                                  const SizedBox(width: 4),
                                                  Icon(
                                                    Icons.handshake,
                                                    size: 12,
                                                    color: Theme.of(context)
                                                        .textTheme
                                                        .bodyMedium
                                                        ?.color
                                                        ?.withValues(alpha: 0.7),
                                                  ),
                                                  const SizedBox(width: 1),
                                                  Text(
                                                    '${ledger.memberCount}',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: Theme.of(context)
                                                          .textTheme
                                                          .bodyMedium
                                                          ?.color
                                                          ?.withValues(alpha: 0.7),
                                                    ),
                                                  ),
                                                ],
                                                // 没账本时不显示下拉箭头(没东西可选)
                                                if (!isEmpty) ...[
                                                  const SizedBox(width: 2),
                                                  Icon(
                                                    Icons.keyboard_arrow_down,
                                                    size: 16,
                                                    color: Theme.of(context)
                                                        .textTheme
                                                        .bodyMedium
                                                        ?.color
                                                        ?.withValues(alpha: 0.5),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                      loading: () => const SizedBox.shrink(),
                                      error: (_, __) => const SizedBox.shrink(),
                                    );
                                  }),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // 右侧操作按钮：圆角微底色按钮
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: Theme.of(context).brightness == Brightness.dark
                                ? const Color(0xFF1E293B)
                                : const Color(0xFFF1F5F9),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            tooltip: AppLocalizations.of(context).calendarTitle,
                            padding: EdgeInsets.zero,
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const CalendarPage(),
                                ),
                              );
                            },
                            icon: Icon(
                              Icons.calendar_month_outlined,
                              size: 18,
                              color: Theme.of(context).iconTheme.color,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: Theme.of(context).brightness == Brightness.dark
                                ? const Color(0xFF1E293B)
                                : const Color(0xFFF1F5F9),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            tooltip: AppLocalizations.of(context).homeSearch,
                            padding: EdgeInsets.zero,
                            onPressed: () {
                              _transactionListKey.currentState
                                  ?.switchToStreamMode();
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (context) => const SearchPage(),
                                ),
                              );
                            },
                            icon: Icon(
                              Icons.search,
                              size: 18,
                              color: Theme.of(context).iconTheme.color,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 现代科技感月度收支概览卡片（Hero Card）
                  _HomeOverviewHeroCard(
                    month: month,
                    isJumping: _isJumping,
                    onSelectDate: _handleDateSelection,
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 0),
          // 月初提醒卡片
          if (_showLastMonthReminder) _buildLastMonthReminderCard(context),
          // 年度账单提醒卡片（12月15日 - 次年1月31日）
          if (_showAnnualReportReminder)
            _buildAnnualReportReminderCard(context),
          // 待确认提醒条(P0-3):有待确认候选必提醒;当日已点过且数量未增不再现
          Consumer(builder: (context, ref, _) {
            final count =
                ref.watch(pendingCandidateCountProvider).valueOrNull ?? 0;
            final now = DateTime.now();
            final today = '${now.year}-${now.month}-${now.day}';
            final suppressed = count <= 0 ||
                (_pendingBannerDismissedDate == today &&
                    _pendingBannerDismissedCount >= count);
            if (suppressed) return const SizedBox.shrink();
            return _buildPendingConfirmBanner(context, count);
          }),
          // 预算设置引导卡片（无预算 + 未关闭过）
          Consumer(builder: (context, ref, _) {
            final overviewAsync = ref.watch(budgetOverviewProvider);
            final hasBudget = overviewAsync.when(
              data: (overview) =>
                  overview != null && overview.totalBudget != null,
              loading: () => true, // loading 时不显示引导
              error: (_, __) => true, // 出错时不显示引导
            );
            if (!hasBudget && _showBudgetSetupHint) {
              return _buildBudgetSetupHintCard(context);
            }
            return const SizedBox.shrink();
          }),
          Expanded(
            child: ref.watch(homeWindowPaginationEnabledProvider)
                ? _buildWindowedTransactionList(context, ledgerId, hide)
                : StreamBuilder<List<({Transaction t, Category? category, Account? account, Account? toAccount})>>(
                    key: ValueKey('transactions_$_streamBuilderKey'), // 使用递增key强制重建
                    stream: () {
                      // ledgerId 变了或第一次进来才重建 stream;无关 setState(预算
                      // 提示卡片、月度提醒等)的 home rebuild 复用同一 stream 引用,
                      // StreamBuilder 不会重新订阅,不会闪到 fallback 数据。
                      if (_txStream == null || _txStreamLedgerId != ledgerId) {
                        _txStream = repo.transactionsWithCategoryAll(ledgerId: ledgerId);
                        _txStreamLedgerId = ledgerId;
                      }
                      return _txStream;
                    }(),
                    builder: (context, snapshot) {
                      // Stream 数据到来前，使用预加载数据；到来后使用 Stream 数据
                      final streamData = snapshot.data;
                      final hasStreamData =
                          streamData != null && streamData.isNotEmpty;

                      // 如果 Stream 没数据，从预加载数据构建基础列表
                      final transactions = hasStreamData
                          ? streamData
                          : (cachedFullData
                                  ?.map((item) => (
                                        t: item.t,
                                        category: item.category,
                                        account: item.account,
                                        toAccount: item.toAccount,
                                      ))
                                  .toList() ??
                              []);

                      return TransactionList(
                        key: _transactionListKey,
                        transactions: transactions,
                        // 传入预加载数据供详情使用（标签、附件、账户）
                        transactionsWithDetails: cachedFullData,
                        hideAmounts: hide,
                        enableVisibilityTracking: true,
                        onDateVisibilityChanged: _onHeaderVisibilityChanged,
                        controller: _listController,
                        emptyWidget: AppEmpty(
                          text: AppLocalizations.of(context).homeNoRecords,
                          subtext: AppLocalizations.of(context).homeNoRecordsSubtext,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _HomeOverviewHeroCard extends ConsumerWidget {
  final DateTime month;
  final bool isJumping;
  final VoidCallback onSelectDate;

  const _HomeOverviewHeroCard({
    required this.month,
    required this.isJumping,
    required this.onSelectDate,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = ref.watch(primaryColorProvider);
    final hide = ref.watch(hideAmountsProvider);
    final ledgerId = ref.watch(currentLedgerIdProvider);
    final params = (ledgerId: ledgerId, month: month);

    ref.watch(monthlyTotalsProvider(params));
    final cachedTotals = ref.watch(lastMonthlyTotalsProvider(params));
    final (income, expense) = cachedTotals ?? (0.0, 0.0);
    final balance = income - expense;

    // 预算信息
    final budgetEnabled = ref.watch(homeBudgetCardEnabledProvider);
    final overviewAsync = ref.watch(budgetOverviewProvider);
    final budgetUsage = budgetEnabled ? overviewAsync.valueOrNull?.totalBudget : null;

    final l10n = AppLocalizations.of(context);

    return Container(
      margin: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [const Color(0xFF1E293B), const Color(0xFF0F172A)]
              : [
                  primaryColor,
                  Color.lerp(primaryColor, const Color(0xFF1E3A8A), 0.3) ?? primaryColor,
                ],
        ),
        boxShadow: [
          BoxShadow(
            color: (isDark ? Colors.black : primaryColor).withValues(alpha: isDark ? 0.4 : 0.22),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
        border: Border.all(
          color: Colors.white.withValues(alpha: isDark ? 0.1 : 0.18),
          width: 0.8,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 卡片顶部：月份选择胶囊 + 金额遮蔽眼眸按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: isJumping ? null : onSelectDate,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${month.year}年 ${month.month.toString().padLeft(2, '0')}月',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        if (isJumping)
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: Colors.white,
                            ),
                          )
                        else
                          const Icon(
                            Icons.keyboard_arrow_down,
                            size: 16,
                            color: Colors.white70,
                          ),
                      ],
                    ),
                  ),
                ),
                // 隐藏/显示金额切换
                GestureDetector(
                  onTap: () {
                    ref.read(hideAmountsProvider.notifier).state = !hide;
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      hide ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                      size: 16,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 主体金额：本月总支出
            Text(
              l10n.homeExpense,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: AmountText(
                value: expense,
                hide: hide,
                signed: false,
                decimals: 2,
                showCurrency: true,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 12),
            // 底部细项：本月收入 + 本月结余
            Container(
              padding: const EdgeInsets.only(top: 10),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.12),
                    width: 0.8,
                  ),
                ),
              ),
              child: Row(
                children: [
                  // 收入
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.homeIncome,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 11.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: AmountText(
                            value: income,
                            hide: hide,
                            signed: false,
                            decimals: 2,
                            showCurrency: true,
                            style: const TextStyle(
                              color: Color(0xFF6EE7B7),
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 结余
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.homeBalance,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 11.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: AmountText(
                            value: balance,
                            hide: hide,
                            signed: false,
                            decimals: 2,
                            showCurrency: true,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 预算条（开启预算时展示）
            if (budgetUsage != null) ...[
              const SizedBox(height: 10),
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const BudgetPage()),
                  );
                },
                behavior: HitTestBehavior.opaque,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${l10n.budgetUsed} ${(budgetUsage.rate * 100).toInt()}%',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          '${l10n.budgetRemaining} ¥${(budgetUsage.remaining.clamp(0, double.infinity)).toStringAsFixed(0)}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        height: 5,
                        color: Colors.white.withValues(alpha: 0.2),
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: budgetUsage.rate.clamp(0.0, 1.0),
                          child: Container(
                            color: budgetUsage.rate >= 1.0
                                ? const Color(0xFFEF4444)
                                : (budgetUsage.rate >= 0.8
                                    ? const Color(0xFFF59E0B)
                                    : const Color(0xFF34D399)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
