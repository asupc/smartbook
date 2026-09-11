import 'package:drift/drift.dart' as d;

import '../../db.dart';
import '../../../utils/month_range.dart';
import '../../../utils/shared_ledger_picker_filter.dart';
import '../statistics_repository.dart';

/// 本地统计Repository实现
/// 基于 Drift 数据库实现
class LocalStatisticsRepository implements StatisticsRepository {
  final BeeDatabase db;

  LocalStatisticsRepository(this.db);


  /// C5:本机时区偏移秒(东八区 = 28800)。drift 把 naive DateTime 按本机
  /// 时区转 epoch 秒存储;SQL 侧取"本地日期"时把 epoch 加回偏移再走
  /// 'unixepoch' 解析 —— 等价于 Dart 侧 happenedAt.toLocal() 的字段语义。
  /// 不能用 SQLite 的 'localtime' 修饰符:部分 Android 构建不含 OS 时区
  /// 支持,返回 NULL。
  static int get _localTzOffsetSeconds =>
      DateTime.now().timeZoneOffset.inSeconds;

  @override
  Future<List<({int? id, String name, String? icon, double total})>>
      totalsByCategory({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  }) async {
    // C5:SQL GROUP BY 下推(此前全表物化后在 Dart 循环累加,10 万行 = 10 万
    // 个 data class)。共享账本 override 兜底单独一条小查询。
    final rows = await db.customSelect(
      '''
      SELECT c.id AS catId, c.name AS catName, c.icon AS catIcon,
             COALESCE(SUM(COALESCE(t.native_amount, t.amount)), 0) AS total
      FROM transactions t
      LEFT JOIN categories c ON c.id = t.category_id
      WHERE t.ledger_id = ?1 AND t.type = ?2 AND t.exclude_from_stats = 0
        AND t.happened_at >= ?3 AND t.happened_at < ?4
      GROUP BY c.id, c.name, c.icon
      ''',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions, db.categories},
    ).get();

    final map = <int?, double>{};
    final names = <int?, String>{};
    final icons = <int?, String?>{};
    for (final r in rows) {
      final id = r.read<int?>('catId');
      names[id] = r.read<String?>('catName') ?? '未分类';
      icons[id] = r.read<String?>('catIcon');
      map[id] = (r.read<double>('total'));
    }

    // §7 共享账本:Editor 写的 tx categoryId 为空但 categorySyncIdOverride 指向
    // Owner 分类 —— 只对这些行(有 override 的少量行)做补充聚合。
    final shared = await _loadSharedCategoriesForLedger(ledgerId);
    if (shared.isNotEmpty) {
      final overrideRows = await db.customSelect(
        '''
        SELECT t.category_sync_id_override AS syncId,
               COALESCE(SUM(COALESCE(t.native_amount, t.amount)), 0) AS total
        FROM transactions t
        WHERE t.ledger_id = ?1 AND t.type = ?2 AND t.exclude_from_stats = 0
          AND t.happened_at >= ?3 AND t.happened_at < ?4
          AND t.category_id IS NULL AND t.category_sync_id_override IS NOT NULL
        GROUP BY t.category_sync_id_override
        ''',
        variables: [
          d.Variable<int>(ledgerId),
          d.Variable<String>(type),
          d.Variable<DateTime>(start),
          d.Variable<DateTime>(end),
        ],
        readsFrom: {db.transactions},
      ).get();
      for (final r in overrideRows) {
        final s = shared[r.read<String>('syncId')];
        if (s == null) continue;
        final id = syntheticIdForSyncId(s.syncId);
        names[id] = s.name;
        icons[id] = s.icon;
        map.update(id, (v) => v + (r.read<double>('total')),
            ifAbsent: () => r.read<double>('total'));
      }
    }

    final list = map.entries
        .map((e) => (id: e.key, name: names[e.key] ?? '未分类', icon: icons[e.key], total: e.value))
        .toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    return list;
  }

  /// 加载当前账本的 SharedLedger 分类索引(by syncId)。单人账本返回空 map,
  /// 共享账本返回 Owner user-global 的镜像。
  Future<Map<String, SharedLedgerCategory>> _loadSharedCategoriesForLedger(
      int ledgerId) async {
    final ledger = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(ledgerId)))
        .getSingleOrNull();
    final syncId = ledger?.syncId;
    if (syncId == null || syncId.isEmpty) return const {};
    final rows = await (db.select(db.sharedLedgerCategories)
          ..where((t) => t.ledgerSyncId.equals(syncId)))
        .get();
    return {for (final r in rows) r.syncId: r};
  }

  @override
  Future<Map<int, Category>> getSharedSyntheticCategoriesForLedger(
      int ledgerId) async {
    final shared = await _loadSharedCategoriesForLedger(ledgerId);
    if (shared.isEmpty) return const {};
    return {
      for (final s in shared.values)
        syntheticIdForSyncId(s.syncId): Category(
          id: syntheticIdForSyncId(s.syncId),
          name: s.name,
          kind: s.kind,
          icon: s.icon,
          sortOrder: s.sortOrder,
          // §7 二级分类 hierarchy:转 synthetic 父 id,让 analytics 的
          // L2→L1 rollup 找到 SharedLedger* 父分类(主表查不到这些 negative id)。
          parentId: (s.parentSyncId != null && s.parentSyncId!.isNotEmpty)
              ? syntheticIdForSyncId(s.parentSyncId!)
              : null,
          level: s.level,
          iconType: s.iconType,
          customIconPath: s.iconType == 'custom' && s.iconCloudSha256 != null
              ? 'custom_icons/shared_${s.iconCloudSha256}.png'
              : null,
          communityIconId: null,
          syncId: s.syncId,
        )
    };
  }

  @override
  Future<List<({int? id, String name, String? icon, int? parentId, int level, double total})>>
      totalsByCategoryWithHierarchy({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  }) async {
    // C5:SQL GROUP BY 下推,Java/Dart 侧只做分类信息映射与 override 兜底。
    final rows = await db.customSelect(
      '''
      SELECT t.category_id AS catId, t.category_sync_id_override AS overrideSyncId,
             COALESCE(SUM(COALESCE(t.native_amount, t.amount)), 0) AS total
      FROM transactions t
      WHERE t.ledger_id = ?1 AND t.type = ?2 AND t.exclude_from_stats = 0
        AND t.happened_at >= ?3 AND t.happened_at < ?4
      GROUP BY t.category_id, t.category_sync_id_override
      ''',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).get();

    final shared = await _loadSharedCategoriesForLedger(ledgerId);
    final catIds = <int>{};
    for (final r in rows) {
      final id = r.read<int?>('catId');
      if (id != null) catIds.add(id);
    }
    var catInfos = const <int, Category>{};
    if (catIds.isNotEmpty) {
      final cats = await (db.select(db.categories)
            ..where((c) => c.id.isIn(catIds)))
          .get();
      catInfos = {for (final c in cats) c.id: c};
    }

    final map = <int?, double>{};
    final categoryInfo = <int?, ({String name, String? icon, int? parentId, int level})>{};

    for (final r in rows) {
      final catId = r.read<int?>('catId');
      final overrideSync = r.read<String?>('overrideSyncId');
      final total = r.read<double>('total');
      int? id = catId;

      if (catId != null && catInfos.containsKey(catId)) {
        final c = catInfos[catId]!;
        categoryInfo[id] = (
          name: c.name,
          icon: c.icon,
          parentId: c.parentId,
          level: c.level,
        );
      } else if (overrideSync != null && shared[overrideSync] != null) {
        // §7 共享账本:Editor 写的 tx 用 categorySyncIdOverride 指向 Owner
        // 的分类,主表 join 不到,查 SharedLedger* 兜底。用 synthetic 负 id
        // 做聚合 key,跟 picker filter 保持一致。
        // §7 二级分类 hierarchy:Phase 2 加了 parent_sync_id 后,L2 SharedLedger*
        // 行有父分类 syncId — 转 synthetic 负 id 写入 parentId,让 analytics
        // 的 L2→L1 rollup 正确累加,而不是把 L2 当 orphan 丢掉。
        final s = shared[overrideSync]!;
        id = syntheticIdForSyncId(s.syncId);
        final pSyncId = s.parentSyncId;
        final parentSyntheticId = (pSyncId != null && pSyncId.isNotEmpty)
            ? syntheticIdForSyncId(pSyncId)
            : null;
        categoryInfo[id] = (
          name: s.name,
          icon: s.icon,
          parentId: parentSyntheticId,
          level: s.level,
        );
      } else {
        categoryInfo[id] = (
          name: '未分类',
          icon: null,
          parentId: null,
          level: 1,
        );
      }

      map.update(id, (v) => v + total, ifAbsent: () => total);
    }

    final list = map.entries.map((e) {
      final info = categoryInfo[e.key]!;
      return (
        id: e.key,
        name: info.name,
        icon: info.icon,
        parentId: info.parentId,
        level: info.level,
        total: e.value,
      );
    }).toList()
      ..sort((a, b) => b.total.compareTo(a.total));

    return list;
  }

  @override
  Future<List<({DateTime day, double total})>> totalsByDay({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  }) async {
    // C5:SQL GROUP BY(本地日分桶)。drift 的 DateTime 变量按 UTC 写入,
    // 'localtime' 修饰符与 t.happenedAt.toLocal() 同口径。
    final rows = await db.customSelect(
      '''
      SELECT strftime('%Y-%m-%d', datetime(happened_at + $_localTzOffsetSeconds, 'unixepoch')) AS day,
             COALESCE(SUM(COALESCE(native_amount, amount)), 0) AS total
      FROM transactions
      WHERE ledger_id = ?1 AND type = ?2 AND exclude_from_stats = 0
        AND happened_at >= ?3 AND happened_at < ?4
      GROUP BY day
      ''',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).get();
    final map = <String, double>{};
    for (final r in rows) {
      final day = r.read<String?>('day');
      if (day != null) map[day] = r.read<double>('total');
    }
    // ensure full range continuity
    final result = <({DateTime day, double total})>[];
    for (DateTime d = DateTime(start.year, start.month, start.day);
        d.isBefore(end);
        d = d.add(const Duration(days: 1))) {
      final key =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      result.add((day: d, total: map[key] ?? 0));
    }
    return result;
  }

  @override
  Future<List<({DateTime month, double total})>> totalsByMonth({
    required int ledgerId,
    required String type,
    required int year,
  }) async {
    final sd = await _monthStartDayOf(ledgerId);
    final yr = yearRangeFor(year, sd);
    // C5:SQL GROUP BY。周期标签月在 SQL 内算好(CASE 归月),Dart 只读结果。
    // CAST(REAL AS INTEGER) 兜底 drift 对表达式列的类型推断。
    final rows = await db.customSelect(
      '''
      SELECT CAST(
        (CAST(strftime('%Y', datetime(happened_at + $_localTzOffsetSeconds, 'unixepoch')) AS INTEGER) * 12
         + CAST(strftime('%m', datetime(happened_at + $_localTzOffsetSeconds, 'unixepoch')) AS INTEGER)
         - (CASE WHEN CAST(strftime('%d', datetime(happened_at + $_localTzOffsetSeconds, 'unixepoch')) AS INTEGER) < $sd
                 THEN 1 ELSE 0 END))
      AS INTEGER) AS label,
             COALESCE(SUM(COALESCE(native_amount, amount)), 0) AS total
      FROM transactions
      WHERE ledger_id = ?1 AND type = ?2 AND exclude_from_stats = 0
        AND happened_at >= ?3 AND happened_at < ?4
      GROUP BY label
      ''',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
        d.Variable<DateTime>(yr.start),
        d.Variable<DateTime>(yr.end),
      ],
      readsFrom: {db.transactions},
    ).get();
    final map = <int, double>{};
    for (final r in rows) {
      // label = 年*12+月 的绝对月序号(跨年减位自动落到上一年 12 月);
      // 结果集限定在 [year-1 周期12月, year+1 周期1月) 之外不会出现,
      // 范围内只有 0(=上年12月)与 1..12 两种,再映射回月号。
      final absMonth = r.read<int?>('label');
      if (absMonth == null) continue;
      final total = r.read<double>('total');
      final m = ((absMonth - 1) % 12) + 1; // 2027-01-05 → 2026*12+0 → 12
      map.update(m, (v) => v + total, ifAbsent: () => total);
    }
    final result = <({DateTime month, double total})>[];
    for (int m = 1; m <= 12; m++) {
      result.add((month: DateTime(year, m, 1), total: map[m] ?? 0));
    }
    return result;
  }

  @override
  Future<List<({int year, double total})>> totalsByYearSeries({
    required int ledgerId,
    required String type,
  }) async {
    final sd = await _monthStartDayOf(ledgerId);
    // C5:SQL GROUP BY(此前整表物化,labelForDate 逐行算)。周期标签年 =
    // 本地年 + (day < startDay 且 month=1 ? -1 : 0)。
    final rows = await db.customSelect(
      '''
      SELECT CAST(strftime('%Y', datetime(happened_at + $_localTzOffsetSeconds, 'unixepoch')) AS INTEGER) AS y,
             CAST(strftime('%m', datetime(happened_at + $_localTzOffsetSeconds, 'unixepoch')) AS INTEGER) AS m,
             CAST(strftime('%d', datetime(happened_at + $_localTzOffsetSeconds, 'unixepoch')) AS INTEGER) AS d,
             COALESCE(SUM(COALESCE(native_amount, amount)), 0) AS total
      FROM transactions
      WHERE ledger_id = ?1 AND type = ?2 AND exclude_from_stats = 0
      GROUP BY y, m, d
      ''',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
      ],
      readsFrom: {db.transactions},
    ).get();
    if (rows.isEmpty) return const [];
    final map = <int, double>{};
    int minYear = 9999, maxYear = 0;
    for (final r in rows) {
      var y = r.read<int>('y');
      final m = r.read<int>('m');
      final day = r.read<int>('d');
      if (m == 1 && day < sd) y -= 1; // 归上一年 12 月周期
      if (y < minYear) minYear = y;
      if (y > maxYear) maxYear = y;
      final total = r.read<double>('total');
      map.update(y, (v) => v + total, ifAbsent: () => total);
    }
    final out = <({int year, double total})>[];
    for (int y = minYear; y <= maxYear; y++) {
      out.add((year: y, total: map[y] ?? 0));
    }
    return out;
  }

  @override
  Future<(double income, double expense)> totalsInRange({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
  }) async {
    // 使用 SQL 聚合查询，比查出全部数据再累加快得多
    final result = await db.customSelect(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN type = 'income' THEN COALESCE(native_amount, amount) ELSE 0 END), 0) AS income,
        COALESCE(SUM(CASE WHEN type = 'expense' THEN COALESCE(native_amount, amount) ELSE 0 END), 0) AS expense
      FROM transactions
      WHERE ledger_id = ?1 AND happened_at >= ?2 AND happened_at < ?3
        AND exclude_from_stats = 0
      ''',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).getSingle();

    final income = (result.data['income'] as num?)?.toDouble() ?? 0.0;
    final expense = (result.data['expense'] as num?)?.toDouble() ?? 0.0;
    return (income, expense);
  }

  @override
  Future<List<({int? accountId, double total})>> totalsByAccount({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  }) async {
    // SQL 聚合(口径与 totalsByDay 一致:native_amount ?? amount、exclude_from_stats=0)
    final rows = await db.customSelect(
      '''
      SELECT account_id AS accountId,
             COALESCE(SUM(COALESCE(native_amount, amount)), 0) AS total
      FROM transactions
      WHERE ledger_id = ?1 AND type = ?2 AND exclude_from_stats = 0
        AND happened_at >= ?3 AND happened_at < ?4
      GROUP BY account_id
      ORDER BY total DESC
      ''',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).get();
    return rows
        .map((r) => (
              accountId: r.read<int?>('accountId'),
              total: r.read<double>('total'),
            ))
        .toList();
  }

  @override
  Future<List<({String note, double total})>> totalsByNote({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
    int limit = 10,
  }) async {
    final rows = await db.customSelect(
      '''
      SELECT TRIM(note) AS note,
             COALESCE(SUM(COALESCE(native_amount, amount)), 0) AS total
      FROM transactions
      WHERE ledger_id = ?1 AND type = 'expense' AND exclude_from_stats = 0
        AND note IS NOT NULL AND TRIM(note) <> ''
        AND happened_at >= ?2 AND happened_at < ?3
      GROUP BY TRIM(note)
      ORDER BY total DESC
      LIMIT ?4
      ''',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
        d.Variable<int>(limit),
      ],
      readsFrom: {db.transactions},
    ).get();
    return rows
        .map((r) => (
              note: r.read<String>('note'),
              total: r.read<double>('total'),
            ))
        .toList();
  }

  /// 读取账本的自定义每月起始日(1-28);账本缺失或查询异常时按 1(自然月)降级
  /// —— watch 流经 Stream.fromFuture 包裹,这里抛错会让流永久进 error 态。
  Future<int> _monthStartDayOf(int ledgerId) async {
    try {
      final row = await (db.select(db.ledgers)
            ..where((l) => l.id.equals(ledgerId)))
          .getSingleOrNull();
      return (row?.monthStartDay ?? 1).clamp(1, 28);
    } catch (_) {
      return 1;
    }
  }

  @override
  Future<(double income, double expense)> monthlyTotals({
    required int ledgerId,
    required DateTime month,
  }) async {
    final sd = await _monthStartDayOf(ledgerId);
    final range = periodForLabel(month.year, month.month, sd);
    final start = range.start;
    final end = range.end;

    // 使用 SQL 聚合查询，比查出全部数据再累加快得多
    final result = await db.customSelect(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN type = 'income' THEN COALESCE(native_amount, amount) ELSE 0 END), 0) AS income,
        COALESCE(SUM(CASE WHEN type = 'expense' THEN COALESCE(native_amount, amount) ELSE 0 END), 0) AS expense
      FROM transactions
      WHERE ledger_id = ?1 AND happened_at >= ?2 AND happened_at < ?3
        AND exclude_from_stats = 0
      ''',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).getSingle();

    final income = (result.data['income'] as num?)?.toDouble() ?? 0.0;
    final expense = (result.data['expense'] as num?)?.toDouble() ?? 0.0;
    return (income, expense);
  }

  @override
  Future<(double income, double expense)> yearlyTotals({
    required int ledgerId,
    required int year,
  }) async {
    final sd = await _monthStartDayOf(ledgerId);
    final range = yearRangeFor(year, sd);
    final start = range.start;
    final end = range.end;

    // 使用 SQL 聚合查询，比查出全部数据再累加快得多
    final result = await db.customSelect(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN type = 'income' THEN COALESCE(native_amount, amount) ELSE 0 END), 0) AS income,
        COALESCE(SUM(CASE WHEN type = 'expense' THEN COALESCE(native_amount, amount) ELSE 0 END), 0) AS expense
      FROM transactions
      WHERE ledger_id = ?1 AND happened_at >= ?2 AND happened_at < ?3
        AND exclude_from_stats = 0
      ''',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).getSingle();

    final income = (result.data['income'] as num?)?.toDouble() ?? 0.0;
    final expense = (result.data['expense'] as num?)?.toDouble() ?? 0.0;
    return (income, expense);
  }
}
