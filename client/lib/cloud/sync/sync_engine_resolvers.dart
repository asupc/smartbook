part of 'sync_engine.dart';

/// 跨设备 ID 解析:syncId(string,跨设备稳定) ↔ 本地 int id(autoIncrement,设
/// 备私有)。apply remote change 时大量用到——server 推下来的 entity 引用都
/// 是 syncId,本地存储用 int id,中间要靠这些函数转换。
extension _SyncEngineResolvers on SyncEngine {
  /// 按 syncId 查 ledger 的本地 int id。用于 apply remote change 时把
  /// server 的 external_id（string）映射成本地 autoIncrement id。
  ///
  /// pull 路径上 [activePullCache] 非空,先查缓存(prime 时全表加载),
  /// miss 才走 DB — 消除 N+1 SELECT。详见 [LookupCache]。
  Future<int?> _resolveLedgerIdBySyncId(String? syncId) async {
    if (syncId == null || syncId.isEmpty) return null;
    final cached = activePullCache?.ledgerId(syncId);
    if (cached != null) return cached;
    final led = await (db.select(db.ledgers)
          ..where((l) => l.syncId.equals(syncId)))
        .getSingleOrNull();
    if (led != null) activePullCache?.putLedger(syncId, led.id);
    return led?.id;
  }

  /// 按 syncId 查 category 的本地 int id。优先级比 name+kind 高：设备间
  /// category.syncId 是稳定的，name 可能被改过 / 有重名。
  ///
  /// §7 决策 v25:返 null 时调用方应检查 tx 是否有 categorySyncIdOverride
  /// 字段 — 共享账本场景 Editor 选 Owner cat,本地主表没有该 row,需要走
  /// SharedLedgerCategories 表显示。tx UI 应该按 override 优先。
  Future<int?> _resolveCategoryIdBySyncId(String? syncId) async {
    if (syncId == null || syncId.isEmpty) return null;
    final cached = activePullCache?.categoryId(syncId);
    if (cached != null) return cached;
    final cat = await (db.select(db.categories)
          ..where((c) => c.syncId.equals(syncId)))
        .getSingleOrNull();
    if (cat != null) activePullCache?.putCategory(syncId, cat.id);
    return cat?.id;
  }

  /// 按 syncId 查 account 的本地 int id。同理，跨设备稳定。
  /// §7 决策 v25:返 null 时调用方应检查 tx 是否有 accountSyncIdOverride
  /// 字段。
  Future<int?> _resolveAccountIdBySyncId(String? syncId) async {
    if (syncId == null || syncId.isEmpty) return null;
    final cached = activePullCache?.accountId(syncId);
    if (cached != null) return cached;
    final acc = await (db.select(db.accounts)
          ..where((a) => a.syncId.equals(syncId)))
        .getSingleOrNull();
    if (acc != null) activePullCache?.putAccount(syncId, acc.id);
    return acc?.id;
  }

  /// 根据分类名和类型查找 categoryId
  ///
  /// U-05(2026-10-11):改用 `limit(1)` + `.get()` 取第一条 —— `categories`
  /// 表**没有 name 唯一约束**(仅 app 层 createCategory 查重),两台设备各自
  /// seed 同名一级分类(syncId 各是不同 UUID)即可产生两行同名。
  ///
  /// 旧实现用 `getSingleOrNull()`:查不到返 null,查到**多行抛
  /// `Bad state: Too many elements`** → 整页事务回滚 → cursor 不推进 →
  /// 下次 pull 拉到同一条 → 再抛 = 该设备云同步**永久卡死**。与账户侧
  /// [\_resolveAccountId] 的 `take(1)` 保守口径对齐(那里已修,这里是对称补漏)。
  ///
  /// 排序用 `id ASC`(历史最早一条)—— 确定性选取,避免 SQLite 无 ORDER BY
  /// 时返回顺序不稳定导致同一 tx 在不同轮次挂到不同分类。同名多行会打日志,
  /// 留出"两行 seed 分类需要人工对齐"的可观测线索(不静默)。
  Future<int?> _resolveCategoryId({
    String? categoryName,
    String? categoryKind,
  }) async {
    if (categoryName == null || categoryName.isEmpty) return null;
    final query = db.select(db.categories)
      ..where((c) => c.name.equals(categoryName));
    if (categoryKind != null) {
      query.where((c) => c.kind.equals(categoryKind));
    }
    query.orderBy([(c) => d.OrderingTerm.asc(c.id)]);
    query.limit(2); // 取 2 条即可判定"是否重名",不需要全量
    final rows = await query.get();
    if (rows.length > 1) {
      logger.warning(
          'SyncEngine',
          'pull: 分类重名 name="$categoryName" kind=$categoryKind 命中 '
          '${rows.length}+ 行,取历史最早一条(id=${rows.first.id});'
          '这是跨设备 seed 未对齐的痕迹,建议在分类管理页合并同名项');
    }
    return rows.isEmpty ? null : rows.first.id;
  }

  /// 根据账户名查找 accountId
  ///
  /// 账户是 user-scoped（跟 category/tag 一样）—— 同一用户的所有账本共享一份
  /// 账户表。Accounts 表仍带着 ledgerId 字段只是历史遗留（schema 注释里写着
  /// "保留用于v2迁移，后续会移除"），不应该参与解析。
  ///
  /// 之前按 (name + ledgerId) 查会有两个问题：
  ///   1. 同一个账户在别的账本上（因为旧数据沿 ledger 分裂），本账本查不到 → null
  ///      → web 改的 tx 账户在 mobile 上显示空。
  ///   2. 多次同步后 accounts 表里可能出现重名（因为 ledgerId 不同被当成不同
  ///      实体），按 name 全局查会 throw；这里用 take(1) 保守一点。
  Future<int?> _resolveAccountId({
    String? accountName,
    required int ledgerId, // 参数保留兼容上游调用
  }) async {
    if (accountName == null || accountName.isEmpty) return null;
    final rows = await (db.select(db.accounts)
          ..where((a) => a.name.equals(accountName))
          ..limit(1))
        .get();
    return rows.isEmpty ? null : rows.first.id;
  }

  Future<String> _getDeviceId() async {
    final user = await provider.auth.currentUser;
    return user?.metadata?['deviceId'] as String? ?? 'unknown';
  }
}
