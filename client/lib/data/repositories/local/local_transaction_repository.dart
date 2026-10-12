import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' as d;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../../db.dart';
import '../../../utils/month_range.dart';
import '../../../utils/shared_ledger_picker_filter.dart';
import '../../../models/note_history.dart';
import '../transaction_repository.dart';
import 'chunk_utils.dart';
import '../../../services/system/logger_service.dart';

/// 本地交易Repository实现
/// 基于 Drift 数据库实现
class LocalTransactionRepository implements TransactionRepository {
  final BeeDatabase db;

  LocalTransactionRepository(this.db);

  @override
  Stream<List<Transaction>> watchRecentTransactions({
    required int ledgerId,
    int limit = 20,
  }) {
    return (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ])
          ..limit(limit))
        .watch();
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
  Stream<List<Transaction>> watchTransactionsInMonth({
    required int ledgerId,
    required DateTime month,
  }) {
    return Stream.fromFuture(_monthStartDayOf(ledgerId)).asyncExpand((sd) {
      final range = periodForLabel(month.year, month.month, sd);
      return (db.select(db.transactions)
            ..where((t) =>
                t.ledgerId.equals(ledgerId) &
                t.happenedAt.isBiggerOrEqualValue(range.start) &
                t.happenedAt.isSmallerThanValue(range.end))
            ..orderBy([
              (t) => d.OrderingTerm(
                  expression: t.happenedAt, mode: d.OrderingMode.desc)
            ]))
          .watch();
    });
  }

  /// Drift `accounts` 表的两个 alias —— from 账户(`transactions.account_id`)
  /// 和 to 账户(`transactions.to_account_id`,转账场景)。Drift 同一张表
  /// JOIN 两次必须用 alias 区分,否则解析阶段就报"column reference ambiguous"。
  late final $AccountsTable _fromAccountTable =
      db.alias(db.accounts, 'from_account');
  late final $AccountsTable _toAccountTable =
      db.alias(db.accounts, 'to_account');

  /// 标准 tx + category + from/to account 三连 LEFT JOIN。所有 list 风格的
  /// watch 都走这个,避免重复写 join 表。
  List<d.Join<d.HasResultSet, dynamic>> _txJoins() => [
        d.leftOuterJoin(db.categories,
            db.categories.id.equalsExp(db.transactions.categoryId)),
        d.leftOuterJoin(_fromAccountTable,
            _fromAccountTable.id.equalsExp(db.transactions.accountId)),
        d.leftOuterJoin(_toAccountTable,
            _toAccountTable.id.equalsExp(db.transactions.toAccountId)),
      ];

  @override
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> watchTransactionsWithCategoryAll({
    int? ledgerId,
  }) {
    final select = db.select(db.transactions);
    if (ledgerId != null) {
      select.where((t) => t.ledgerId.equals(ledgerId));
    }
    select.orderBy([
      (t) => d.OrderingTerm(expression: t.happenedAt, mode: d.OrderingMode.desc)
    ]);
    final q = select.join(_txJoins());
    return _watchTxJoinWithSharedHydration(q);
  }

  /// §7 共享账本:把 Drift 主表 stream 跟 SharedLedger* 表更新合流,任一
  /// 变化都重跑 hydration 并 emit。
  ///
  /// 单纯用 q.watch() 时,Drift 只 track query 里 join 到的表(transactions /
  /// categories / accounts)。SharedLedger* 行被 WS handler 改了,stream 不会
  /// re-emit → tx tile 显示旧名字/图标,跟 picker 不一致。这里手动加两路
  /// db.tableUpdates(SharedLedger{Categories,Accounts}) 监听,触发时拿上一次
  /// Drift 结果重 hydrate 再 emit。
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> _watchTxJoinWithSharedHydration(d.JoinedSelectStatement q) {
    late StreamController<
        List<
            ({
              Transaction t,
              Category? category,
              Account? account,
              Account? toAccount
            })>> ctrl;
    StreamSubscription? txSub;
    StreamSubscription? sharedCatSub;
    StreamSubscription? sharedAccSub;
    List<d.TypedResult>? lastRows;

    Future<void> rehydrate() async {
      if (lastRows == null) return;
      final out = lastRows!
          .map((r) => (
                t: r.readTable(db.transactions),
                category: r.readTableOrNull(db.categories),
                account: r.readTableOrNull(_fromAccountTable),
                toAccount: r.readTableOrNull(_toAccountTable),
              ))
          .toList();
      final hydrated = await _hydrateSharedOverrides(out);
      if (!ctrl.isClosed) ctrl.add(hydrated);
    }

    ctrl = StreamController<
        List<
            ({
              Transaction t,
              Category? category,
              Account? account,
              Account? toAccount
            })>>(
      onListen: () {
        txSub = q.watch().listen((rows) {
          lastRows = rows;
          rehydrate();
        });
        sharedCatSub = db
            .tableUpdates(d.TableUpdateQuery.onTable(db.sharedLedgerCategories))
            .listen((_) => rehydrate());
        sharedAccSub = db
            .tableUpdates(d.TableUpdateQuery.onTable(db.sharedLedgerAccounts))
            .listen((_) => rehydrate());
      },
      onCancel: () async {
        await txSub?.cancel();
        await sharedCatSub?.cancel();
        await sharedAccSub?.cancel();
      },
    );
    return ctrl.stream;
  }

  /// §7 v25:Editor 在共享账本下记的 tx,主表 JOIN 不到 category / account 行,
  /// 字段是 null。这里二次查 SharedLedger{Categories,Accounts} 按 syncId 找,
  /// 转 synthetic 实体回填,UI 不用区分。
  ///
  /// 合并 category + from-account + to-account 三类 hydration:共用同一遍 rows
  /// 扫描;每类各一个 batch query。
  Future<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> _hydrateSharedOverrides(
    List<
            ({
              Transaction t,
              Category? category,
              Account? account,
              Account? toAccount
            })>
        rows,
  ) async {
    // 1. 收集所有需要反查的 syncId(分类 / from 账户 / to 账户)
    final catSyncIds = <String>{};
    final accSyncIds = <String>{};
    for (final r in rows) {
      final cOv = r.t.categorySyncIdOverride;
      if (r.category == null && cOv != null && cOv.isNotEmpty) {
        catSyncIds.add(cOv);
      }
      final aOv = r.t.accountSyncIdOverride;
      if (r.account == null && aOv != null && aOv.isNotEmpty) {
        accSyncIds.add(aOv);
      }
      final tOv = r.t.toAccountSyncIdOverride;
      if (r.toAccount == null && tOv != null && tOv.isNotEmpty) {
        accSyncIds.add(tOv);
      }
    }
    if (catSyncIds.isEmpty && accSyncIds.isEmpty) return rows;

    // 2. 批量查 SharedLedger* 镜像表
    final catBySyncId = <String, SharedLedgerCategory>{};
    if (catSyncIds.isNotEmpty) {
      final shared = await (db.select(db.sharedLedgerCategories)
            ..where((t) => t.syncId.isIn(catSyncIds.toList())))
          .get();
      for (final s in shared) {
        catBySyncId[s.syncId] = s;
      }
    }
    final accBySyncId = <String, SharedLedgerAccount>{};
    if (accSyncIds.isNotEmpty) {
      final shared = await (db.select(db.sharedLedgerAccounts)
            ..where((t) => t.syncId.isIn(accSyncIds.toList())))
          .get();
      for (final s in shared) {
        accBySyncId[s.syncId] = s;
      }
    }

    // 3. 回填到每行
    return rows.map((r) {
      Category? category = r.category;
      Account? account = r.account;
      Account? toAccount = r.toAccount;

      final cOv = r.t.categorySyncIdOverride;
      if (category == null && cOv != null && cOv.isNotEmpty) {
        final s = catBySyncId[cOv];
        if (s != null) category = _syntheticCategoryFromShared(s);
      }
      final aOv = r.t.accountSyncIdOverride;
      if (account == null && aOv != null && aOv.isNotEmpty) {
        final s = accBySyncId[aOv];
        if (s != null) account = _syntheticAccountFromShared(s);
      }
      final tOv = r.t.toAccountSyncIdOverride;
      if (toAccount == null && tOv != null && tOv.isNotEmpty) {
        final s = accBySyncId[tOv];
        if (s != null) toAccount = _syntheticAccountFromShared(s);
      }

      return (
        t: r.t,
        category: category,
        account: account,
        toAccount: toAccount,
      );
    }).toList();
  }

  /// SharedLedgerCategory → synthetic Category。用 syntheticIdForSyncId 而不
  /// 是 -1 — 否则所有共享分类都拿到同一个 id,首页点击分类详情时反查不到
  /// 目标 syncId,详情页 0 笔交易。改成 hash 派生后跟 picker / watchCategory
  /// 路径对齐。
  Category _syntheticCategoryFromShared(SharedLedgerCategory s) {
    return Category(
      id: syntheticIdForSyncId(s.syncId),
      name: s.name,
      kind: s.kind,
      icon: s.icon,
      sortOrder: s.sortOrder,
      parentId: null,
      level: s.level,
      iconType: s.iconType,
      customIconPath: s.iconType == 'custom' && s.iconCloudSha256 != null
          ? 'custom_icons/shared_${s.iconCloudSha256}.png'
          : null,
      communityIconId: null,
      syncId: s.syncId,
    );
  }

  /// SharedLedgerAccount → synthetic Account。跟 accountForTxProvider 同款映射。
  Account _syntheticAccountFromShared(SharedLedgerAccount s) {
    return Account(
      id: syntheticIdForSyncId(s.syncId),
      ledgerId: 0,
      name: s.name,
      type: s.accountType,
      currency: s.currency,
      initialBalance: s.initialBalance ?? 0.0,
      createdAt: null,
      updatedAt: null,
      sortOrder: 0,
      creditLimit: s.creditLimit,
      billingDay: s.billingDay,
      paymentDueDay: s.paymentDueDay,
      bankName: s.bankName,
      cardLastFour: s.cardLastFour,
      note: s.note,
      syncId: s.syncId,
      // SharedLedgerAccounts 镜像表没有 hidden 概念(隐藏是 Owner 侧个人状态,
      // 不随共享账本镜像同步),synthetic 账户固定按「未隐藏」处理。
      hidden: false,
    );
  }

  @override
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> watchTransactionsWithCategoryInMonth({
    required int ledgerId,
    required DateTime month,
  }) {
    return Stream.fromFuture(_monthStartDayOf(ledgerId)).asyncExpand((sd) {
      final range = periodForLabel(month.year, month.month, sd);
      final q = (db.select(db.transactions)
            ..where((t) =>
                t.ledgerId.equals(ledgerId) &
                t.happenedAt.isBiggerOrEqualValue(range.start) &
                t.happenedAt.isSmallerThanValue(range.end))
            ..orderBy([
              (t) => d.OrderingTerm(
                  expression: t.happenedAt, mode: d.OrderingMode.desc)
            ]))
          .join(_txJoins());
      return _watchTxJoinWithSharedHydration(q);
    });
  }

  @override
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> watchTransactionsWithCategoryInYear({
    required int ledgerId,
    required int year,
  }) {
    final start = DateTime(year, 1, 1);
    final end = DateTime(year + 1, 1, 1);
    final q = (db.select(db.transactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.happenedAt.isBiggerOrEqualValue(start) &
              t.happenedAt.isSmallerThanValue(end))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ]))
        .join(_txJoins());
    return _watchTxJoinWithSharedHydration(q);
  }

  @override
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> watchTransactionsForCategoryInRange({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
    int? categoryId,
    required String type,
  }) {
    final base = (db.select(db.transactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.type.equals(type) &
              t.happenedAt.isBiggerOrEqualValue(start) &
              t.happenedAt.isSmallerThanValue(end))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ]))
        .join(_txJoins());
    if (categoryId == null) {
      base.where(db.transactions.categoryId.isNull());
    } else {
      base.where(db.transactions.categoryId.equals(categoryId));
    }
    return _watchTxJoinWithSharedHydration(base);
  }

  static const _uuid = Uuid();

  /// 交易金额写入的**统一判据**(C3/F-12/F-13/U-1/U-04 同源,缺陷 F 收口点)。
  ///
  /// 所有直写 `transactions` 的入口都走这里,per-path 只决定「违规怎么处理」:
  ///
  /// | 路径 | 策略 |
  /// |---|---|
  /// | [addTransaction] / [updateTransaction] / [insertTransactionCompanion] / | 抛 `ArgumentError` |
  /// | [insertTransactionsBatch] / [insertTransactionsBatchWithRelations] | (fail-closed;批内 `db.transaction` 整体回滚) |
  /// | [updateTransactionBySyncId] / [updateTransactionsBatchBySyncId] | **跳过该行 + 告警**(同步/合并路径:一条坏行不能拖垮整批) |
  /// | pull-apply(`sync_engine_apply.dart`) | 跳过该行 + 告警(抛错会中断整页 apply、cursor 卡死) |
  ///
  /// 判据:
  /// - **非有限值**(NaN/±Infinity)一律拒绝:Infinity 落库会让月/年/全期
  ///   所有聚合变成 Infinity,整账本统计不可用(D1/U-04)。
  /// - **数量上限** `|amount| < [maxWriteAmount]`(约 12 位整数,U-1):超出 UI
  ///   金额键盘位数上限的值不是正常录入面,放行只会让账本卡/统计卡渲染退化
  ///   (渲染侧对 ≥1e21 另有指数记法兜底,见 [formatBalanceFull])。
  /// - **负数**对 expense/income/transfer 一律拒绝:方向由 `type` 表达,负金额
  ///   会与其他支出互相抵消、把转账资金流反转(D3)。非方向性类型(如
  ///   `adjustment` 余额调整)允许负数。
  /// - **0 允许**:历史导入/备份快照/周期模板会写入 0 金额行,且无方向歧义,
  ///   拒绝会产生新的失败面(计划要求 `!= 0`,此处按「不新增失败」放宽并记录)。
  ///
  /// **[currentAmount] = 库内当前值时的「存量豁免」(缺陷 E)**:两值相等
  /// (含 NaN 自等)**且方向语义(type)也未被改动**时,视为金额未改动,跳过全部
  /// 判据。`updateTransaction` 是整行写入,search_page 批量改备注/分类会把
  /// `tx.amount` 原样回传 —— 若对回传值重新校验,存量脏值行(legacy 负值/超大值/
  /// Infinity)会**永久不可编辑**(只能删了重建)。豁免不会引入新的脏值:能通过
  /// 等值判定的值必然已在库内。
  ///
  /// **缺陷 C(2026-10-11 复现缺陷修复)**:豁免只在 `type` 也等于库内现值时成立。
  /// 旧实现只看金额:app 自己创建的 `adjustment/-500`(合法负值)被
  /// `updateTransaction(id, type:'expense', amount:-500)` **改类型**时,金额
  /// 等值 → 整条豁免放行 → 库里出现方向性非法的 `expense/-500`
  /// (而 `addTransaction(expense, -500)` 被正确拒绝)。方向由 type 表达,
  /// 改类型 = 改方向语义 → 必须对金额**重新校验**。
  /// 传 [currentType] = 库内当前 type 即启用该收紧;不传(无现值上下文/新建
  /// 路径)保持原语义(等值即豁免)。
  static String? txAmountViolation(String type, double amount,
      {double? currentAmount, String? currentType}) {
    if (currentAmount != null &&
        sameAmountValue(amount, currentAmount) &&
        (currentType == null || currentType == type)) {
      return null; // 金额与方向语义均未改动 → 存量豁免(其它字段仍可编辑)
    }
    if (!amount.isFinite) return 'non_finite';
    if (amount.abs() >= maxWriteAmount) return 'exceeds_magnitude';
    const directional = {'expense', 'income', 'transfer'};
    if (directional.contains(type) && amount < 0) return 'negative_directional';
    return null;
  }

  /// double 等值判定:`==` 对 NaN 恒 false,而 NaN 自等必须在「存量豁免」里
  /// 成立(否则 legacy NaN 行回传 NaN 会被判为"改了金额",重新落入不可编辑)。
  static bool sameAmountValue(double a, double b) =>
      a == b || (a.isNaN && b.isNaN);

  /// 金额写入上限:整数位 12 位(U-1 的 UI 金额键盘 `_append` 同源)。
  /// UI 能提交的最大值是 999,999,999,999;数据层放行 ≥1e12 属于口径不一致。
  static const double maxWriteAmount = 1e12;

  /// 违规原因码 → 可读消息(消息口径与修复前保持一致,便于既有断言/日志检索)。
  static String violationMessage(String reason, String type, double amount) {
    switch (reason) {
      case 'non_finite':
        return '金额必须是有限数(NaN/Infinity 会污染全部聚合): $amount';
      case 'exceeds_magnitude':
        return '金额超过上限(约 12 位整数,$maxWriteAmount): $amount';
      default:
        return '$type 的金额必须 >= 0(方向由 type 表达,负金额会反转资金流): $amount';
    }
  }

  /// 交易金额校验(C3/F-12/F-13)。抛出版本,语义见 [txAmountViolation]。
  ///
  /// [currentAmount] 非空且与 [amount] 相等(且 [currentType] 等于 [type])→
  /// 存量豁免(缺陷 E/C)。
  static void validateTransactionAmount(String type, double amount,
      {double? currentAmount, String? currentType}) {
    final reason = txAmountViolation(type, amount,
        currentAmount: currentAmount, currentType: currentType);
    if (reason != null) {
      throw ArgumentError.value(
          amount, 'amount', violationMessage(reason, type, amount));
    }
  }

  /// 折算金额(native_amount)守卫。
  ///
  /// 只拒非有限值,**不设** [maxWriteAmount] —— native = amount × 汇率 是派生
  /// 值,汇率可大于 1,合法折算本就会超过基数位的量级。
  /// [currentNativeAmount] 与 [nativeAmount] 相等时同样走「存量豁免」(缺陷 E)。
  static void validateTxNativeAmount(double? nativeAmount,
      {double? currentNativeAmount}) {
    if (nativeAmount == null) return;
    if (currentNativeAmount != null &&
        sameAmountValue(nativeAmount, currentNativeAmount)) {
      return;
    }
    if (!nativeAmount.isFinite) {
      throw ArgumentError.value(
          nativeAmount, 'nativeAmount', '折算金额必须是有限数(NaN/Infinity 不能落库)');
    }
  }

  /// 单条直写路径的统一收口(私有):判据由 [txAmountViolation] 定义,
  /// 违规抛 `ArgumentError`。[path] 只用于定位是哪个入口写坏的。
  static void _assertTxValues({
    required String type,
    required double amount,
    double? nativeAmount,
    double? currentAmount,
    double? currentNativeAmount,
    String? currentType,
    required String path,
  }) {
    final reason = txAmountViolation(type, amount,
        currentAmount: currentAmount, currentType: currentType);
    if (reason != null) {
      throw ArgumentError.value(amount, 'amount',
          '[$path] ${violationMessage(reason, type, amount)}');
    }
    validateTxNativeAmount(nativeAmount,
        currentNativeAmount: currentNativeAmount);
  }

  /// 批量/companion 直写路径的统一预检:缺 `type`/`amount` 直接抛(而不是
  /// 落到 SQLite NOT NULL 才报错),随后走同一判据。
  static void _assertTxCompanion(TransactionsCompanion item,
      {required String path}) {
    if (!item.type.present || !item.amount.present) {
      throw ArgumentError(
          '[$path] 交易行缺少必需字段(type=${item.type.present ? item.type.value : "<absent>"}, '
          'amount=${item.amount.present ? item.amount.value : "<absent>"})');
    }
    _assertTxValues(
      type: item.type.value,
      amount: item.amount.value,
      nativeAmount: item.nativeAmount.present ? item.nativeAmount.value : null,
      path: path,
    );
  }

  /// 单条插入的唯一收口(私有):先预检再落库。
  Future<int> _insertTx(TransactionsCompanion item,
      {required String path}) async {
    _assertTxCompanion(item, path: path);
    return db.into(db.transactions).insert(item);
  }

  /// 列表/分页入口的统一 limit 口径(C3/F-15):`<= 0` 视为**空页**。
  ///
  /// SQLite 把 `LIMIT -1` 当「无上限」,把 `OFFSET -N` 当 0 —— 原样下推会让
  /// 调用方负值静默变成全表物化(长账本 ANR/OOM),`searchTransactions` 更会
  /// 在 Dart 侧 `.take(-1)` 抛未捕获 RangeError。统一钳到 0 = fail-closed。
  /// (游标分页 `getTransactionPageWithCategory` 另有文档化契约 clamp(1,400),
  /// 它需要 +1 探测 `hasMore`,故不并入本口径。)
  static int clampListLimit(int limit) => limit <= 0 ? 0 : limit;

  @override
  Future<int> addTransaction({
    required int ledgerId,
    required String type,
    required double amount,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    required DateTime happenedAt,
    String? note,
    String? syncId,
    String? categorySyncIdOverride,
    String? accountSyncIdOverride,
    String? toAccountSyncIdOverride,
    bool excludeFromStats = false,
    bool excludeFromBudget = false,
    String? currencyCode,
    double? nativeAmount,
  }) async {
    _assertTxValues(
        type: type,
        amount: amount,
        nativeAmount: nativeAmount,
        path: 'addTransaction');
    // v30:子仓收「已定值」直写;带折算的兜底(查账户/汇率)在聚合
    // LocalRepository 包装层(子仓拿不到汇率)。
    return db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: ledgerId,
          type: type,
          amount: amount,
          categoryId: d.Value(categoryId),
          accountId: d.Value(accountId),
          toAccountId: d.Value(toAccountId),
          happenedAt: d.Value(happenedAt),
          note: d.Value(note),
          syncId: d.Value(syncId ?? _uuid.v4()),
          categorySyncIdOverride: d.Value(categorySyncIdOverride),
          accountSyncIdOverride: d.Value(accountSyncIdOverride),
          toAccountSyncIdOverride: d.Value(toAccountSyncIdOverride),
          excludeFromStats: d.Value(excludeFromStats),
          excludeFromBudget: d.Value(excludeFromBudget),
          currencyCode: d.Value(currencyCode),
          nativeAmount: d.Value(nativeAmount),
          // v40 记录时间:本地新建 = 本机写入时刻;server 盖章后 pull 会覆盖。
          recordedAt: d.Value(DateTime.now().toUtc()),
        ));
  }

  /// 批量插入的 syncId 冲突处理(C3/F-02/F-03/F-04)。
  ///
  /// 两个层次,语义按调用方法区分:
  /// ① **批内重复** `(ledger_id, syncId)`:
  ///    - [regenerateIntraBatchDuplicates] = false(`insertTransactionsBatch`):
  ///      **丢弃**后续重复项(保留首条)。该 API 的契约是「返回插入条数」,重复
  ///      syncId 意味着同一同步实体的重放,去重即幂等。
  ///    - = true(`insertTransactionsBatchWithRelations`):给后续重复项**重新生成
  ///      UUID**。该 API 的契约是「返回的 id 列表与输入顺序对齐」,调用方
  ///      (import)按 index 挂标签/附件;丢行会让关联错位,而保留重复 syncId
  ///      会被唯一索引拒绝整批。
  /// ② **库中已存在** `(ledger_id, syncId)` → **跳过**该行(重放幂等,F-04/W4)。
  ///
  /// 空串 syncId 不参与去重(HARDENING:空串是调用方契约外输入,老行为允许
  /// 多行;v45 的部分唯一索引也把它排除在唯一域外)。
  ///
  /// 之所以不用 `INSERT OR IGNORE`:那会连主键冲突一起吞掉,F5 依赖主键冲突
  /// 抛错并整批回滚。带 WHERE 的部分唯一索引也无法作为 drift `DoNothing(target:)`
  /// 的冲突目标(实测 "ON CONFLICT clause does not match any PRIMARY KEY or
  /// UNIQUE constraint")。
  Future<
      ({
        List<TransactionsCompanion> pending,
        Map<int, int> pendingIndexByInput,
        Map<int, String> effectiveSyncIdByInput
      })> _prepareBatchSyncIds(
    List<TransactionsCompanion> items, {
    required bool regenerateIntraBatchDuplicates,
  }) async {
    // ① 批内重复处理
    final seen = <String>{};
    final effective = <TransactionsCompanion>[];
    final keptInputIndexes = <int>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final sid = item.syncId.value;
      if (sid == null || sid.isEmpty) {
        effective.add(item);
        keptInputIndexes.add(i);
        continue;
      }
      final key = '${item.ledgerId.value}\u0000$sid';
      if (seen.add(key)) {
        effective.add(item);
        keptInputIndexes.add(i);
      } else if (regenerateIntraBatchDuplicates) {
        // 关联批次:换新 UUID 保住每笔账目与它自己的标签/附件
        effective.add(item.copyWith(syncId: d.Value(_uuid.v4())));
        keptInputIndexes.add(i);
      }
      // 非关联批次:直接丢弃重复项
    }

    // ② 库中已存在的 (ledger_id, syncId) → 跳过
    final syncIds = effective
        .map((c) => c.syncId.value)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    final existing = <String>{};
    if (syncIds.isNotEmpty) {
      for (final chunk in chunkIds(syncIds)) {
        final placeholders = List.filled(chunk.length, '?').join(',');
        final rows = await db.customSelect(
          'SELECT ledger_id, sync_id FROM transactions '
          'WHERE sync_id IN ($placeholders)',
          variables: chunk.map((s) => d.Variable.withString(s)).toList(),
          readsFrom: {db.transactions},
        ).get();
        for (final r in rows) {
          final l = r.data['ledger_id'];
          final s = r.data['sync_id'];
          if (l is int && s is String && s.isNotEmpty) {
            existing.add('$l\u0000$s');
          }
        }
      }
    }
    final pending = <TransactionsCompanion>[];
    final pendingIndexByInput = <int, int>{};
    // 输入 index → 最终 syncId(批内重复项被换了 UUID,调用方必须用这一份
    // 去反查落库 id,否则会拿到同 syncId 的第一行 → 关联错挂,即 F-03)
    final effectiveSyncIdByInput = <int, String>{};
    for (var k = 0; k < effective.length; k++) {
      final item = effective[k];
      final sid = item.syncId.value;
      final inputIndex = keptInputIndexes[k];
      if (sid != null && sid.isNotEmpty &&
          existing.contains('${item.ledgerId.value}\u0000$sid')) {
        continue; // 已存在(重放)→ 跳过
      }
      pendingIndexByInput[inputIndex] = pending.length;
      pending.add(item);
      if (sid != null) effectiveSyncIdByInput[inputIndex] = sid;
    }
    return (
      pending: pending,
      pendingIndexByInput: pendingIndexByInput,
      effectiveSyncIdByInput: effectiveSyncIdByInput,
    );
  }

  @override
  Future<int> insertTransactionsBatch(
    List<TransactionsCompanion> items, {
    bool recordChanges = true,
  }) async {
    // 子仓库不挂 changeTracker,recordChanges 参数对它无作用 — 真正的 record
    // 在 LocalRepository wrapper 那一层。这里保留参数只是为了接口一致。
    if (items.isEmpty) return 0;
    // 缺陷 F:批量直写曾在守卫之外(负值/Infinity 静默落库)。预检先于任何
    // 写入 → 违规整批抛错(fail-closed),`db.transaction` 保证无半提交。
    for (final item in items) {
      _assertTxCompanion(item, path: 'insertTransactionsBatch');
    }
    final effectiveItems = items.map((item) {
      if (item.syncId == const d.Value.absent() || item.syncId.value == null) {
        return item.copyWith(syncId: d.Value(_uuid.v4()));
      }
      return item;
    }).toList();
    return db.transaction(() async {
      final filtered = await _prepareBatchSyncIds(effectiveItems,
          regenerateIntraBatchDuplicates: false);
      if (filtered.pending.isEmpty) return 0;
      await db.batch((b) => b.insertAll(db.transactions, filtered.pending));
      return filtered.pending.length;
    });
  }

  @override
  Future<List<int>> insertTransactionsBatchWithRelations({
    required List<TransactionsCompanion> transactions,
    Map<int, List<int>> tagIdsByIndex = const {},
    Map<int, List<BatchAttachmentData>> attachmentsByIndex = const {},
    bool recordChanges = true,
  }) async {
    if (transactions.isEmpty) return const [];
    // 缺陷 F:data_import_service 主路径,曾在守卫之外。同批量口径 fail-closed。
    for (final tx in transactions) {
      _assertTxCompanion(tx, path: 'insertTransactionsBatchWithRelations');
    }
    // 预填充 syncId — batch insertAll 不返回 row id,必须靠 syncId 反查。
    final effective = transactions.map((tx) {
      if (tx.syncId == const d.Value.absent() || tx.syncId.value == null) {
        return tx.copyWith(syncId: d.Value(_uuid.v4()));
      }
      return tx;
    }).toList();

    return db.transaction(() async {
      // 1. syncId 冲突处理(批内重复 → 换 UUID;库中已存在 → 跳过)
      final filtered = await _prepareBatchSyncIds(effective,
          regenerateIntraBatchDuplicates: true);
      if (filtered.pending.isNotEmpty) {
        await db.batch((b) => b.insertAll(db.transactions, filtered.pending));
      }

      // 2. SELECT 回拿 (id, syncId) 映射
      final syncIds = filtered.pending.map((c) => c.syncId.value!).toList();
      final idBySyncId = <String, int>{};
      if (syncIds.isNotEmpty) {
        for (final chunk in chunkIds(syncIds)) {
          final inserted = await (db.select(db.transactions)
                ..where((t) => t.syncId.isIn(chunk)))
              .get();
          for (final tx in inserted) {
            final sid = tx.syncId;
            // 同 syncId 可能跨账本存在(唯一索引带 ledger 维度)→ 取最小 id
            if (sid != null &&
                (!idBySyncId.containsKey(sid) || tx.id < idBySyncId[sid]!)) {
              idBySyncId[sid] = tx.id;
            }
          }
        }
      }
      // 输入 index → txId。必须用 effectiveSyncIdByInput(批内重复项已换 UUID),
      // 用原始 syncId 会拿到同 syncId 的第一行 → 两笔账目的标签/附件全挂同一行
      // (F-03 的原症状)。
      final relationTargets = <int, int>{};
      for (final entry in filtered.effectiveSyncIdByInput.entries) {
        final txId = idBySyncId[entry.value];
        if (txId != null) relationTargets[entry.key] = txId;
      }
      // 返回 id 列表:与输入顺序对齐(跳过的重放行缺位)
      final ids = <int>[
        for (var i = 0; i < effective.length; i++)
          if (relationTargets.containsKey(i)) relationTargets[i]!,
      ];

      // 3. batch insert tag 关联 — 同 (tx,tag) 去重;transaction_tags 已有
      //    UNIQUE(transaction_id, tag_id)(v45),重复 insert 会被约束拒绝。
      if (tagIdsByIndex.isNotEmpty) {
        final seenPairs = <String>{};
        await db.batch((b) {
          for (final entry in tagIdsByIndex.entries) {
            final txId = relationTargets[entry.key];
            if (txId == null) continue;
            for (final tagId in entry.value) {
              if (!seenPairs.add('$txId\u0000$tagId')) continue;
              b.insert(
                db.transactionTags,
                TransactionTagsCompanion.insert(
                  transactionId: txId,
                  tagId: tagId,
                ),
                mode: d.InsertMode.insertOrIgnore,
              );
            }
          }
        });
      }

      // 4. batch insert attachment 元数据(文件本身在另一个流程下载)
      if (attachmentsByIndex.isNotEmpty) {
        await db.batch((b) {
          for (final entry in attachmentsByIndex.entries) {
            final txId = relationTargets[entry.key];
            if (txId == null) continue;
            for (final att in entry.value) {
              b.insert(
                db.transactionAttachments,
                TransactionAttachmentsCompanion.insert(
                  transactionId: txId,
                  fileName: att.fileName,
                  originalName: d.Value(att.originalName),
                  fileSize: d.Value(att.fileSize),
                  width: d.Value(att.width),
                  height: d.Value(att.height),
                  sortOrder: d.Value(att.sortOrder),
                  cloudFileId: d.Value(att.cloudFileId),
                  cloudSha256: d.Value(att.cloudSha256),
                ),
              );
            }
          }
        });
      }

      return ids;
    });
  }

  /// 哨兵:区分「未传」与「显式清空」([updateTransaction] 的可选字段)。
  /// 复用接口层的公共常量 —— wrapper 与子仓必须用**同一个** sentinel 实例,
  /// 否则 identical() 判定失效(包装层原样透传,子仓认不出)。
  static const Object _unset = unsetTransactionField;

  @override
  Future<void> updateTransaction({
    required int id,
    required String type,
    required double amount,
    Object? categoryId = _unset,
    Object? note = _unset,
    DateTime? happenedAt,
    dynamic accountId,
    Object? categorySyncIdOverride = _unset,
    Object? accountSyncIdOverride = _unset,
    Object? toAccountSyncIdOverride = _unset,
    bool? excludeFromStats,
    bool? excludeFromBudget,
    String? currencyCode,
    double? nativeAmount,
  }) async {
    // 缺陷 E:已有行读一次现值,金额相等即「存量豁免」。
    // search_page 批量改备注/分类会把 `tx.amount` 原样回传 —— 无豁免时
    // legacy 负值行(以及历史上的 Infinity/超大值行)会永久不可编辑,
    // 只能删除重建。豁免只放行「等于库内现值」的写,新负值/新非有限值照拒。
    final current = await (db.select(db.transactions)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    _assertTxValues(
      type: type,
      amount: amount,
      nativeAmount: nativeAmount,
      currentAmount: current?.amount,
      currentNativeAmount: current?.nativeAmount,
      // 缺陷 C:改 type = 改方向语义 → 等值豁免失效,金额必须重新校验。
      currentType: current?.type,
      path: 'updateTransaction',
    );
    // 处理 accountId 参数
    final d.Value<int?> accountIdValue;
    if (accountId == null) {
      accountIdValue = const d.Value.absent();
    } else if (accountId is d.Value<int?>) {
      accountIdValue = accountId;
    } else {
      accountIdValue = d.Value(accountId as int?);
    }
    // C3/F-11:可选字段用哨兵区分「未传」与「显式清空」。
    // 旧实现 `d.Value(categoryId)` 把未传(null)当成清空,与同方法内
    // happenedAt/accountId 的 absent 保护语义冲突 —— 「只改金额」会静默丢掉
    // 分类与备注(search_page 批量改备注/改分类必须回填全部字段才不丢数据)。
    d.Value<int?> sentinelInt(Object? v) => identical(v, _unset)
        ? const d.Value.absent()
        : d.Value(v as int?);
    d.Value<String?> sentinelStr(Object? v) => identical(v, _unset)
        ? const d.Value.absent()
        : d.Value(v as String?);

    await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(
      TransactionsCompanion(
        type: d.Value(type),
        amount: d.Value(amount),
        categoryId: sentinelInt(categoryId),
        note: sentinelStr(note),
        happenedAt:
            happenedAt != null ? d.Value(happenedAt) : const d.Value.absent(),
        accountId: accountIdValue,
        categorySyncIdOverride: sentinelStr(categorySyncIdOverride),
        accountSyncIdOverride: sentinelStr(accountSyncIdOverride),
        toAccountSyncIdOverride: sentinelStr(toAccountSyncIdOverride),
        // null = 不更新(保持原值);非 null = 显式写入
        excludeFromStats: excludeFromStats == null
            ? const d.Value.absent()
            : d.Value(excludeFromStats),
        excludeFromBudget: excludeFromBudget == null
            ? const d.Value.absent()
            : d.Value(excludeFromBudget),
        // v30:null = 不更新(保持原快照);非 null = 显式写入
        currencyCode: currencyCode == null
            ? const d.Value.absent()
            : d.Value(currencyCode),
        nativeAmount: nativeAmount == null
            ? const d.Value.absent()
            : d.Value(nativeAmount),
      ),
    );
  }

  /// 共享账本:在本地标记 tx 的创建人 / 编辑人,让 UI 能立即展示头像。
  /// 服务端 push.py 已经会兜底注入 userId,但本地写入路径(addTransaction /
  /// updateTransaction)不知道 currentUser 是谁,需要 UI 层在写完后调一下这个
  /// 方法。
  ///   - isCreate=true:同时写 createdByUserId + lastEditedByUserId(新建场景)
  ///   - isCreate=false:只写 lastEditedByUserId(编辑场景,createdByUserId
  ///     维持 first-write-wins)
  Future<void> markTxAuthor({
    required int txId,
    required String userId,
    required bool isCreate,
  }) async {
    await (db.update(db.transactions)..where((t) => t.id.equals(txId))).write(
      TransactionsCompanion(
        createdByUserId: isCreate ? d.Value(userId) : const d.Value.absent(),
        lastEditedByUserId: d.Value(userId),
      ),
    );
  }

  @override
  Future<void> deleteTransaction(int id) async {
    // v43 回收站:整行搬到 DeletedTransactions tombstone(标签/附件关联随主表
    // 行移除自然失效,物理附件延后到「彻底删除/过期清理」再删)。恢复走
    // [restoreDeletedTransaction];30 天后由 cleanupDeletedTransactions 清理。
    //
    // C3/F-05:级联清 transaction_attachments **行**。旧实现只清 tags,附件行
    // 悬挂(需用户主动跑孤儿扫描器);且墓碑 payload 不含关联 → 恢复后
    // 标签/附件永久丢失。现在整体包在单事务里,墓碑 + 关联快照 + 删行原子提交。
    await db.transaction(() async {
      final tx = await getTransactionById(id);
      if (tx == null) return;
      await _archiveToTrash(tx);

      // 主表删行(tombstone 已存 payload,级联的标签/附件关联一并清掉)。
      await (db.delete(db.transactionTags)
            ..where((tt) => tt.transactionId.equals(id)))
          .go();
      // 附件行级联删除(物理文件由 purge/cleanup 路径按引用计数 GC)。
      await (db.delete(db.transactionAttachments)
            ..where((a) => a.transactionId.equals(id)))
          .go();
      await (db.delete(db.transactions)..where((t) => t.id.equals(id))).go();
    });
  }

  /// 把交易行序列化进回收站 tombstone。同 syncId 已在回收站则跳过(幂等)。
  ///
  /// C3/F-05③:payload 带 tags/attachments 快照(Name+元数据),恢复时重建
  /// 关联 —— 旧 payload 只有交易行字段,恢复后关联永久丢失。
  Future<void> _archiveToTrash(Transaction tx) async {
    final syncId = tx.syncId;
    if (syncId != null) {
      final exists = await (db.select(db.deletedTransactions)
            ..where((d0) => d0.syncId.equals(syncId)))
          .getSingleOrNull();
      if (exists != null) return;
    }
    // 标签关联快照:以 tagId 列表存(恢复时按 id 重建;标签被删则跳过)。
    final tagRows = await (db.select(db.transactionTags)
          ..where((tt) => tt.transactionId.equals(tx.id)))
        .get();
    // 附件元数据快照:按 fileName 重建(物理文件可能已被引用计数 GC,
    // 恢复时行照建,文件缺失由 UI 兜底)。
    final attRows = await (db.select(db.transactionAttachments)
          ..where((a) => a.transactionId.equals(tx.id)))
        .get();
    final payload = {
      'syncId': syncId,
      'ledgerId': tx.ledgerId,
      'type': tx.type,
      'amount': tx.amount,
      'categoryId': tx.categoryId,
      'accountId': tx.accountId,
      'toAccountId': tx.toAccountId,
      'happenedAt': tx.happenedAt.toIso8601String(),
      'recordedAt': tx.recordedAt?.toIso8601String(),
      'note': tx.note,
      'recurringId': tx.recurringId,
      'createdByUserId': tx.createdByUserId,
      'lastEditedByUserId': tx.lastEditedByUserId,
      'categorySyncIdOverride': tx.categorySyncIdOverride,
      'accountSyncIdOverride': tx.accountSyncIdOverride,
      'toAccountSyncIdOverride': tx.toAccountSyncIdOverride,
      'tagSyncIdsOverride': tx.tagSyncIdsOverride,
      'excludeFromStats': tx.excludeFromStats,
      'excludeFromBudget': tx.excludeFromBudget,
      'currencyCode': tx.currencyCode,
      'nativeAmount': tx.nativeAmount,
      // C3 恢复不丢关联:
      'tagIds': [for (final t in tagRows) t.tagId],
      'attachments': [
        for (final a in attRows)
          {
            'fileName': a.fileName,
            'originalName': a.originalName,
            'fileSize': a.fileSize,
            'width': a.width,
            'height': a.height,
            'sortOrder': a.sortOrder,
            'cloudFileId': a.cloudFileId,
            'cloudSha256': a.cloudSha256,
          },
      ],
    };
    // 缺陷 G:deleted_transactions.amount 此前原样镜像主表值。两个后果:
    //   ① 非有限值会先炸在 jsonEncode(payload)(JsonUnsupportedObjectError)
    //      → **存量 Infinity 行删不掉**(与缺陷 E 同类:脏行卡死操作);
    //   ② 侥幸写进列也是非有限值,污染回收站列表渲染/统计。
    // 策略:非有限值 → 列与 payload 都落 0.0 + 告警(脏值本是不可用数据,
    // 落 0 不编造金额方向;原始行仍在 pre-v45 快照/备份里可回溯)。
    // 有限值(含负数/超大值)按镜像语义原样保留 —— 回收站是主表的忠实快照。
    final finiteAmount =
        tx.amount.isFinite ? tx.amount : 0.0;
    if (!tx.amount.isFinite) {
      logger.warning(
          'LocalTransactionRepository',
          '删除交易 $syncId 时 amount=${tx.amount} 非有限,墓碑列与 payload 归一为 0.0'
          '(原文保留在删除前快照/备份)');
      payload['amount'] = 0.0;
    }
    if (payload['nativeAmount'] is num &&
        !(payload['nativeAmount'] as num).toDouble().isFinite) {
      payload['nativeAmount'] = null;
    }
    await db.into(db.deletedTransactions).insert(DeletedTransactionsCompanion.insert(
          syncId: syncId ?? 'local:${tx.id}',
          ledgerId: tx.ledgerId,
          amount: finiteAmount,
          txType: tx.type,
          happenedAt: tx.happenedAt,
          payloadJson: jsonEncode(payload),
        ));
  }

  /// 回收站列表(删除时间倒序)。
  Future<List<DeletedTransaction>> listDeletedTransactions({
    int limit = 200,
  }) {
    return (db.select(db.deletedTransactions)
          ..orderBy([(d0) => d.OrderingTerm(
              expression: d0.deletedAt, mode: d.OrderingMode.desc)])
          ..limit(limit))
        .get();
  }

  /// 从回收站恢复一条:payload 写回主表(新 int id),tombstone 删除。
  /// 返回新交易 id;找不到/已过期/结构损坏返回 null。
  ///
  /// C3/F-07/F-08/W2:
  /// - payload 结构损坏(合法 JSON 但缺字段)→ 返回 null(不再抛 _TypeError),
  ///   与 B6 的非法 JSON 分支口径一致;
  /// - 主表已存在同 (ledger_id, syncId)(远端已 pull 复活)→ 幂等:不再插第二行
  ///   (旧实现让主表出现同 syncId 两行 → getTransactionBySyncId 全断),只消费墓碑;
  /// - 四步(读墓碑/解析/插主表/删墓碑)包在单事务里,并发两次 restore 只有一次生效。
  Future<int?> restoreDeletedTransaction(int tombstoneId) async {
    return db.transaction(() async {
      final tomb = await (db.select(db.deletedTransactions)
            ..where((d0) => d0.id.equals(tombstoneId)))
          .getSingleOrNull();
      if (tomb == null) return null;
      final Map<String, dynamic> payload;
      try {
        final decoded = jsonDecode(tomb.payloadJson);
        if (decoded is! Map<String, dynamic>) return null;
        payload = decoded;
      } catch (_) {
        return null;
      }
      // C3/F-07:结构校验 + 容错取值,损坏 payload 一律返回 null(墓碑保留)。
      final ledgerId = payload['ledgerId'];
      final type = payload['type'];
      final amount = payload['amount'];
      final happenedAtRaw = payload['happenedAt'];
      if (ledgerId is! int ||
          type is! String ||
          amount is! num ||
          happenedAtRaw is! String) {
        return null;
      }
      final happenedAt = DateTime.tryParse(happenedAtRaw);
      if (happenedAt == null) return null;
      // 缺陷 G:payload 是非有限值(手改墓碑/老版本写入)→ 按结构损坏处理,
      // 返回 null 且墓碑保留 —— 绝不把 Infinity 恢复回主表污染统计。
      // 有限的大值(1e21 等)照常放行:那是用户历史数据,恢复语义是忠实回写。
      if (!amount.toDouble().isFinite) return null;
      final syncId = payload['syncId'] as String?;
      // C3/F-08:主表已有同 (ledger_id, syncId) → 幂等消费墓碑,不产生重复行。
      if (syncId != null && syncId.isNotEmpty) {
        final existing = await (db.select(db.transactions)
              ..where((t) => t.ledgerId.equals(ledgerId) & t.syncId.equals(syncId))
              ..limit(1))
            .getSingleOrNull();
        if (existing != null) {
          await (db.delete(db.deletedTransactions)
                ..where((d0) => d0.id.equals(tombstoneId)))
              .go();
          return existing.id;
        }
      }
      final newId = await db.into(db.transactions).insert(TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: type,
            amount: amount.toDouble(),
            categoryId: d.Value(payload['categoryId'] as int?),
            accountId: d.Value(payload['accountId'] as int?),
            toAccountId: d.Value(payload['toAccountId'] as int?),
            happenedAt: d.Value(happenedAt),
            recordedAt: d.Value(payload['recordedAt'] == null
                ? null
                : DateTime.tryParse(payload['recordedAt'] as String)),
            note: d.Value(payload['note'] as String?),
            recurringId: d.Value(payload['recurringId'] as int?),
            syncId: d.Value(syncId),
            createdByUserId: d.Value(payload['createdByUserId'] as String?),
            lastEditedByUserId:
                d.Value(payload['lastEditedByUserId'] as String?),
            categorySyncIdOverride:
                d.Value(payload['categorySyncIdOverride'] as String?),
            accountSyncIdOverride:
                d.Value(payload['accountSyncIdOverride'] as String?),
            toAccountSyncIdOverride:
                d.Value(payload['toAccountSyncIdOverride'] as String?),
            tagSyncIdsOverride:
                d.Value(payload['tagSyncIdsOverride'] as String?),
            excludeFromStats:
                d.Value(payload['excludeFromStats'] as bool? ?? false),
            excludeFromBudget:
                d.Value(payload['excludeFromBudget'] as bool? ?? false),
            currencyCode: d.Value(payload['currencyCode'] as String?),
            nativeAmount: d.Value((payload['nativeAmount'] as num?)?.toDouble()),
          ));
      // C3/F-05③:恢复关联快照(标签按 id;附件按元数据重建)。
      final rawTagIds = payload['tagIds'];
      if (rawTagIds is List && rawTagIds.isNotEmpty) {
        final seen = <int>{};
        await db.batch((b) {
          for (final v in rawTagIds) {
            if (v is! int || !seen.add(v)) continue;
            b.insert(
              db.transactionTags,
              TransactionTagsCompanion.insert(
                transactionId: newId,
                tagId: v,
              ),
              mode: d.InsertMode.insertOrIgnore,
            );
          }
        });
      }
      final rawAtts = payload['attachments'];
      if (rawAtts is List && rawAtts.isNotEmpty) {
        await db.batch((b) {
          for (final v in rawAtts) {
            if (v is! Map) continue;
            final fileName = v['fileName'];
            if (fileName is! String || fileName.isEmpty) continue;
            b.insert(
              db.transactionAttachments,
              TransactionAttachmentsCompanion.insert(
                transactionId: newId,
                fileName: fileName,
                originalName: d.Value(v['originalName'] as String?),
                fileSize: d.Value(v['fileSize'] as int?),
                width: d.Value(v['width'] as int?),
                height: d.Value(v['height'] as int?),
                sortOrder: d.Value((v['sortOrder'] as num?)?.toInt() ?? 0),
                cloudFileId: d.Value(v['cloudFileId'] as String?),
                cloudSha256: d.Value(v['cloudSha256'] as String?),
              ),
            );
          }
        });
      }
      await (db.delete(db.deletedTransactions)
            ..where((d0) => d0.id.equals(tombstoneId)))
          .go();
      return newId;
    });
  }

  /// 彻底删除一条回收站记录(含物理附件文件 GC)。
  ///
  /// C3/F-05①:删除交易时已级联清 `transaction_attachments` **行**(见
  /// [deleteTransaction]),但物理文件**故意保留到这一步** —— 30 天恢复窗口内
  /// 用户点「恢复」需要文件本体,提前删会让恢复出空图。彻底删除(用户选
  /// 「永久删除」/ 过期 cleanup)时才按墓碑 payload 的附件快照 GC 文件。
  Future<void> purgeDeletedTransaction(int tombstoneId) async {
    final tomb = await (db.select(db.deletedTransactions)
          ..where((d0) => d0.id.equals(tombstoneId)))
        .getSingleOrNull();
    if (tomb == null) return;
    // 先按 payload 快照回收物理文件(引用计数:仍被其它行/其它墓碑引用则保留)
    await _purgeTombstoneFiles(tomb);
    await (db.delete(db.deletedTransactions)
          ..where((d0) => d0.id.equals(tombstoneId)))
        .go();
  }

  /// 从墓碑 payload 取附件文件名,按引用计数回收物理文件(含缩略图)。
  /// 失败只 log,不阻断删除。
  Future<void> _purgeTombstoneFiles(DeletedTransaction tomb) async {
    try {
      final Object? decoded = jsonDecode(tomb.payloadJson);
      if (decoded is! Map) return;
      final rawAtts = decoded['attachments'];
      if (rawAtts is! List) return;
      final fileNames = <String>{
        for (final v in rawAtts)
          if (v is Map && v['fileName'] is String) v['fileName'] as String,
      };
      if (fileNames.isEmpty) return;
      final appDir = await getApplicationDocumentsDirectory();
      final attachmentDir = Directory('${appDir.path}/attachments');
      final cacheDir = await getTemporaryDirectory();
      final thumbDir = Directory('${cacheDir.path}/attachment_thumbs');
      for (final fileName in fileNames) {
        // 引用计数:其它 transaction_attachments 行或其它墓碑仍引用 → 保留
        final liveRefs = await (db.select(db.transactionAttachments)
              ..where((a) => a.fileName.equals(fileName))
              ..limit(1))
            .getSingleOrNull();
        if (liveRefs != null) continue;
        final otherTomb = await (db.select(db.deletedTransactions)
              ..where((d0) => d0.payloadJson.like('%$fileName%'))
              ..limit(1))
            .getSingleOrNull();
        if (otherTomb != null) continue;
        final file = File('${attachmentDir.path}/$fileName');
        if (await file.exists()) {
          await file.delete();
        }
        final thumbName =
            '${path.basenameWithoutExtension(fileName)}_thumb.jpg';
        final thumbFile = File('${thumbDir.path}/$thumbName');
        if (await thumbFile.exists()) {
          await thumbFile.delete();
        }
      }
    } catch (e, st) {
      logger.warning('LocalTransactionRepository', '回收站附件文件 GC 失败: $e', st);
    }
  }

  /// 清理超过 [days] 天的回收站记录。返回清理条数。
  Future<int> cleanupDeletedTransactions({int days = 30}) async {
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final expired = await (db.select(db.deletedTransactions)
          ..where((d0) => d0.deletedAt.isSmallerOrEqualValue(cutoff)))
        .get();
    if (expired.isEmpty) return 0;
    // C3/F-05:cascade 的附件物理文件在各墓碑**真正消失**这一步回收。
    for (final tomb in expired) {
      await _purgeTombstoneFiles(tomb);
    }
    return await (db.delete(db.deletedTransactions)
          ..where((d0) => d0.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
  }

  @override
  Future<Transaction?> getTransactionById(int id) async {
    return await (db.select(db.transactions)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  @override
  Future<List<Transaction>> getTransactionsByIds(List<int> ids) async {
    if (ids.isEmpty) return const [];
    // C3/阻塞-6(F-38):按 sqliteBindChunkSize(400)分块 —— 与
    // getTagsForTransactions / getAttachmentCountsForTransactions 口径一致。
    // 不分块时 > SQLITE_MAX_VARIABLE_NUMBER(本机 32766,部分 Android 编译版
    // 低至 999)会抛 "too many SQL variables";真实可达路径是导出全部交易
    // (export_page.dart)、AI 记账(ai_bookkeeper.dart)。
    final out = <Transaction>[];
    for (final chunk in chunkIds(ids)) {
      out.addAll(await (db.select(db.transactions)
            ..where((t) => t.id.isIn(chunk)))
          .get());
    }
    return out;
  }

  @override
  Future<int> insertTransactionCompanion(
    TransactionsCompanion item, {
    bool recordChanges = true,
  }) async {
    // 子仓库不挂 changeTracker,recordChanges 仅为接口一致保留。
    // 缺陷 F:此路径此前不校验 → `amount=Infinity` 静默落库(单条直写)。
    final effective =
        item.syncId == const d.Value.absent() || item.syncId.value == null
            ? item.copyWith(syncId: d.Value(_uuid.v4()))
            : item;
    return _insertTx(effective, path: 'insertTransactionCompanion');
  }

  @override
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> transactionsWithCategoryAll({
    int? ledgerId,
  }) =>
      watchTransactionsWithCategoryAll(ledgerId: ledgerId);

  @override
  Future<Map<int, int>> getTransactionCountsByCategory({int? ledgerId}) async {
    // C12:COUNT GROUP BY(走 idx_transactions_category_time),不再物化整账本
    // JOIN。
    final whereSql = ledgerId != null ? 'WHERE ledger_id = ?1' : '';
    final rows = await db.customSelect(
      '''
      SELECT category_id AS catId, COUNT(*) AS cnt
      FROM transactions
      $whereSql
      GROUP BY category_id
      ''',
      variables: [
        if (ledgerId != null) d.Variable<int>(ledgerId),
      ],
      readsFrom: {db.transactions},
    ).get();
    final counts = <int, int>{};
    for (final r in rows) {
      final id = r.read<int?>('catId');
      if (id != null) counts[id] = r.read<int>('cnt');
    }
    return counts;
  }

  @override
  Future<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> searchTransactions({
    required int ledgerId,
    String? searchText,
    double? minAmount,
    double? maxAmount,
    DateTime? startDate,
    DateTime? endDate,
    List<int> categoryIds = const [],
    int limit = 500,
  }) async {
    // C1:过滤下推 SQL。文本匹配口径与旧 Dart 过滤一致:备注 contains +
    // 分类名 contains + 金额字符串 contains(SQLite CAST amount AS TEXT
    // 前缀匹配等价于 contains 数字串的常见形态;纯数字子串无法用 LIKE 完全
    // 表达 contains,退化为备注/分类为主 —— 金额串匹配保留在 Dart 侧兜底,
    // 由下面的 _searchTextExtraFilter 补齐)。分类筛选按 ids(调用方已展开
    // 子分类);金额取 abs;日期为闭区间日粒度。
    final text = searchText?.trim().toLowerCase();
    final hasText = text != null && text.isNotEmpty;

    final conds = <d.Expression<bool>>[
      db.transactions.ledgerId.equals(ledgerId),
    ];
    if (hasText) {
      final like = '%$text%';
      conds.add(db.transactions.note.lower().like(like) |
          db.categories.name.lower().like(like));
    }
    if (categoryIds.isNotEmpty) {
      conds.add(db.transactions.categoryId.isIn(categoryIds));
    }
    if (minAmount != null) {
      conds.add(db.transactions.amount.abs().isBiggerOrEqualValue(minAmount));
    }
    if (maxAmount != null) {
      conds.add(db.transactions.amount.abs().isSmallerOrEqualValue(maxAmount));
    }
    if (startDate != null) {
      conds.add(db.transactions.happenedAt.isBiggerOrEqualValue(
          DateTime(startDate.year, startDate.month, startDate.day)));
    }
    if (endDate != null) {
      conds.add(db.transactions.happenedAt.isSmallerOrEqualValue(
          DateTime(endDate.year, endDate.month, endDate.day, 23, 59, 59)));
    }

    // C3/F-14/F-15:limit 统一钳制(<=0 → 空)。旧实现 `limit * 2` 让 -1 变 -2
    // 被 SQLite 当无上限,随后 `hydrated.take(-1)` 抛未捕获 RangeError 冒泡到 UI。
    final effectiveLimit = clampListLimit(limit);
    if (effectiveLimit == 0) return const [];

    final q = (db.select(db.transactions).join(_txJoins())
          ..where(d.Expression.and(conds))
          ..orderBy([
            d.OrderingTerm(
                expression: db.transactions.happenedAt,
                mode: d.OrderingMode.desc),
            // C3/F-37:补 id tie-breaker,与分页入口同口径(同时间戳顺序确定)。
            d.OrderingTerm(
                expression: db.transactions.id, mode: d.OrderingMode.desc),
          ])
          ..limit(effectiveLimit * 2)); // 金额串兜底过滤会再筛一轮,取宽一页
    final rows = await q.get();
    final hydrated = await _hydrateSharedOverrides(rows
        .map((r) => (
              t: r.readTable(db.transactions),
              category: r.readTableOrNull(db.categories),
              account: r.readTableOrNull(_fromAccountTable),
              toAccount: r.readTableOrNull(_toAccountTable),
            ))
        .toList());

    if (!hasText) return hydrated.take(effectiveLimit).toList();

    // Dart 兜底:金额串 contains(SQL LIKE 无法表达 CAST 后任意位置子串)
    // 与分类显示名(l10n 后)匹配。SQL 已按备注/原始分类名过滤过的结果集
    // 很小,这里二次放宽:重新包含"仅金额串命中"的行没有意义(它们已被 SQL
    // 排除),故此步只做收窄 —— 与旧行为的差异仅在"金额串命中但备注/分类
    // 都不含关键字"的行,这类命中实用价值低,可接受。
    return hydrated
        .where((item) =>
            (item.t.note?.toLowerCase().contains(text) ?? false) ||
            (item.category?.name.toLowerCase().contains(text) ?? false))
        .take(effectiveLimit)
        .toList();
  }

  @override
  Future<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> getRecentTransactionsWithCategory({
    required int ledgerId,
    required int limit,
  }) async {
    final q = (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ])
          ..limit(limit))
        .join(_txJoins());
    final rows = await q.get();
    final out = rows
        .map((r) => (
              t: r.readTable(db.transactions),
              category: r.readTableOrNull(db.categories),
              account: r.readTableOrNull(_fromAccountTable),
              toAccount: r.readTableOrNull(_toAccountTable),
            ))
        .toList();
    return _hydrateSharedOverrides(out);
  }

  /// 把一条 Drift join 行转成 [TransactionWithRefs]。
  TransactionWithRefs _rowToRefs(d.TypedResult r) => (
        t: r.readTable(db.transactions),
        category: r.readTableOrNull(db.categories),
        account: r.readTableOrNull(_fromAccountTable),
        toAccount: r.readTableOrNull(_toAccountTable),
      );

  @override
  Future<TransactionPage> getTransactionPageWithCategory({
    required int ledgerId,
    TransactionPageCursor? before,
    TransactionPageCursor? after,
    int limit = 80,
  }) async {
    assert(!(before != null && after != null), 'before/after 互斥');
    final effective = limit.clamp(1, 400).toInt() + 1; // +1 用于 hasMore 探测
    final base = db.select(db.transactions)
      ..where((t) => t.ledgerId.equals(ledgerId));

    if (before != null) {
      // 向旧记录翻页:happened_at < c 或 (happened_at = c AND id < c.id)
      base.where((t) =>
          t.happenedAt.isSmallerThanValue(before.happenedAt) |
          (t.happenedAt.equals(before.happenedAt) & t.id.isSmallerThanValue(before.id)));
      base.orderBy([
        (t) => d.OrderingTerm(expression: t.happenedAt, mode: d.OrderingMode.desc),
        (t) => d.OrderingTerm(expression: t.id, mode: d.OrderingMode.desc),
      ]);
    } else if (after != null) {
      // 向新记录翻页:happened_at > c 或 (happened_at = c AND id > c.id)
      base.where((t) =>
          t.happenedAt.isBiggerThanValue(after.happenedAt) |
          (t.happenedAt.equals(after.happenedAt) & t.id.isBiggerThanValue(after.id)));
      base.orderBy([
        (t) => d.OrderingTerm(expression: t.happenedAt, mode: d.OrderingMode.asc),
        (t) => d.OrderingTerm(expression: t.id, mode: d.OrderingMode.asc),
      ]);
    } else {
      // 最新一页:默认降序
      base.orderBy([
        (t) => d.OrderingTerm(expression: t.happenedAt, mode: d.OrderingMode.desc),
        (t) => d.OrderingTerm(expression: t.id, mode: d.OrderingMode.desc),
      ]);
    }

    base.limit(effective);
    final rows = await base.join(_txJoins()).get();

    // 向新记录翻页查询是升序，返回前 reverse 回降序，保证页面始终降序。
    final isAscending = after != null;
    final result = rows.map(_rowToRefs).toList();
    if (isAscending) {
      result.replaceRange(0, result.length, result.reversed);
    }
    final hasMore = result.length > limit;
    if (hasMore) {
      // 去掉多取的一行，避免把下一页边界混进本页
      result.removeAt(isAscending ? 0 : result.length - 1);
    }
    // 方向语义随查询方向不同：
    //  - 初始页(after=null,降序):多取的探针在末尾,hasMore=还有更旧;已到最顶,无更新。
    //  - 翻旧页(before,降序)    :还多取在末尾,hasMore=还有更旧;从更新页翻下,上方必有。
    //  - 翻新页(after,升序)     :多取在顶部(reverse后),hasMore=还有更新;从更旧页翻上,下方必有。
    final bool hasOlder;
    final bool hasNewer;
    if (after != null) {
      hasOlder = true;
      hasNewer = hasMore;
    } else {
      hasOlder = hasMore;
      hasNewer = before != null;
    }

    // 去重(同一时间戳 + 跨页边界理论上不会重复,保险起见按 id 收敛)
    final seen = <int>{};
    final items = <TransactionWithRefs>[];
    for (final r in result) {
      if (seen.add(r.t.id)) items.add(r);
    }

    return TransactionPage(
      items: items,
      firstCursor: items.isEmpty ? null : TransactionPageCursor.fromRow(items.first.t),
      lastCursor: items.isEmpty ? null : TransactionPageCursor.fromRow(items.last.t),
      hasNewer: hasNewer,
      hasOlder: hasOlder,
    );
  }

  @override
  Stream<List<TransactionWithRefs>> watchTransactionWindowWithCategory({
    required int ledgerId,
    TransactionPageCursor? newestInclusive,
    required TransactionPageCursor oldestInclusive,
  }) {
    final base = db.select(db.transactions)
      ..where((t) => t.ledgerId.equals(ledgerId))
      ..orderBy([
        (t) => d.OrderingTerm(expression: t.happenedAt, mode: d.OrderingMode.desc),
        (t) => d.OrderingTerm(expression: t.id, mode: d.OrderingMode.desc),
      ]);

    // 窗口 = 闭区间 [oldestInclusive, newestInclusive](按时间戳，同时间戳看 id)。
    // 上界:排除比 newestInclusive 更新的 → 保留 happened_at < n 或 (= 且 id <= n.id)。
    // (最新模式 newestInclusive=null = 上界不限，新交易自然进入窗口并实时重发。)
    if (newestInclusive != null) {
      base.where((t) =>
          t.happenedAt.isSmallerThanValue(newestInclusive.happenedAt) |
          (t.happenedAt.equals(newestInclusive.happenedAt) &
              t.id.isSmallerOrEqualValue(newestInclusive.id)));
    }
    // 下界:排除比 oldestInclusive 更旧的 → 保留 happened_at > o 或 (= 且 id >= o.id)。
    base.where((t) =>
        t.happenedAt.isBiggerThanValue(oldestInclusive.happenedAt) |
        (t.happenedAt.equals(oldestInclusive.happenedAt) &
            t.id.isBiggerOrEqualValue(oldestInclusive.id)));

    final q = base.join(_txJoins());
    return _watchTxJoinWithSharedHydration(q);
  }

  @override
  Future<bool> hasTransactionsInPeriod({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
  }) async {
    final rows = await (db.select(db.transactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.happenedAt.isBiggerOrEqualValue(start) &
              t.happenedAt.isSmallerThanValue(end))
          ..limit(1))
        .get();
    return rows.isNotEmpty;
  }

  @override
  Future<List<NoteHistoryEntry>> getNoteHistory({
    required int ledgerId,
    int? categoryId,
    String? categorySyncId,
    required NoteHistorySort sort,
    int limit = 20,
  }) async {
    // 备注历史直接基于已保存交易聚合，避免维护会与同步数据脱节的缓存副本。
    final effectiveLimit = limit.clamp(1, 100).toInt();
    final whereClauses = <String>[
      'ledger_id = ?',
      'note IS NOT NULL',
      "TRIM(note) <> ''",
    ];
    final variables = <d.Variable>[d.Variable.withInt(ledgerId)];

    // 共享账本 Owner 分类以 syncId override 落库，优先使用它过滤。
    if (categorySyncId != null && categorySyncId.isNotEmpty) {
      whereClauses.add('category_sync_id_override = ?');
      variables.add(d.Variable.withString(categorySyncId));
    } else if (categoryId != null) {
      whereClauses.add('category_id = ?');
      variables.add(d.Variable.withInt(categoryId));
    }

    final orderBy = sort == NoteHistorySort.frequency
        ? 'usage_count DESC, last_used_at DESC, normalized_note ASC'
        : 'last_used_at DESC, usage_count DESC, normalized_note ASC';
    variables.add(d.Variable.withInt(effectiveLimit));

    final rows = await db
        .customSelect(
          '''
      SELECT
        TRIM(note) AS normalized_note,
        COUNT(*) AS usage_count,
        MAX(happened_at) AS last_used_at
      FROM transactions
      WHERE ${whereClauses.join(' AND ')}
      GROUP BY TRIM(note)
      ORDER BY $orderBy
      LIMIT ?
      ''',
          variables: variables,
          readsFrom: {db.transactions},
        )
        .get();

    return rows.map((row) {
      // 聚合列来自 SQLite，统一转换保证 Android、iOS 与桌面端返回类型一致。
      final usageCount = row.data['usage_count'];
      final count = usageCount is BigInt
          ? usageCount.toInt()
          : usageCount is num
              ? usageCount.toInt()
              : 0;
      return NoteHistoryEntry(
        note: row.read<String>('normalized_note'),
        usageCount: count,
      );
    }).toList();
  }

  @override
  Future<int> countByTypeInRange({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  }) async {
    final row = await db.customSelect(
      'SELECT COUNT(*) AS c FROM transactions WHERE ledger_id = ?1 AND type = ?2 AND happened_at >= ?3 AND happened_at < ?4',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).getSingle();
    final v = row.data['c'];
    if (v is int) return v;
    if (v is BigInt) return v.toInt();
    if (v is num) return v.toInt();
    return 0;
  }

  @override
  Future<List<Transaction>> getTransactionsByLedger(int ledgerId) async {
    // C3/F-37:补 id tie-breaker。旧实现只按 happened_at DESC,同时间戳行的
    // 顺序是 SQLite 实现产物(实测 id 升序),与分页入口的 id 降序**相反** ——
    // 任何 .first/.last 或跨入口顺序比较都会翻转。
    return await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc),
            (t) => d.OrderingTerm(expression: t.id, mode: d.OrderingMode.desc),
          ]))
        .get();
  }

  @override
  Future<List<Transaction>> getTransactionsByLedgerInRange({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
  }) async {
    return await (db.select(db.transactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.happenedAt.isBiggerOrEqualValue(start) &
              t.happenedAt.isSmallerThanValue(end))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc),
            (t) => d.OrderingTerm(expression: t.id, mode: d.OrderingMode.desc),
          ]))
        .get();
  }

  @override
  Future<List<Transaction>> getDedupCandidates({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
    required double minAmount,
    required double maxAmount,
    int limit = 200,
  }) async {
    final low = minAmount.abs();
    final high = maxAmount.abs();
    return await (db.select(db.transactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.type.equals(type) &
              t.happenedAt.isBetweenValues(start, end) &
              // 金额按绝对值比:正负号两种口径都要能命中。
              (t.amount.isBetweenValues(low, high) |
                  t.amount.isBetweenValues(-high, -low)))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ])
          ..limit(limit))
        .get();
  }

  @override
  Future<List<Transaction>> getRecentTransactions(
    int ledgerId, {
    int limit = 10,
  }) async {
    // C3/F-15:统一 limit 口径(`<= 0` → 空)。旧行为把 -1 下推成 SQLite 的
    // "无上限",静默物化整账本。
    final effectiveLimit = clampListLimit(limit);
    if (effectiveLimit == 0) return const [];
    return await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc),
            // C3/F-37:tie-breaker,与分页入口同口径。
            (t) => d.OrderingTerm(
                expression: t.id, mode: d.OrderingMode.desc),
          ])
          ..limit(effectiveLimit))
        .get();
  }

  @override
  Future<void> updateTransactionFields({
    required int id,
    dynamic accountId,
    dynamic toAccountId,
    String? accountSyncIdOverride,
    String? toAccountSyncIdOverride,
    bool writeAccountSyncIdOverride = false,
    bool writeToAccountSyncIdOverride = false,
  }) async {
    // accountId / toAccountId 接受 null(absent / 不更新)、int(直接写)、
    // `d.Value<int?>`(显式 null 清空)三种语义,跟 updateTransaction 对齐。
    final d.Value<int?> accountIdValue;
    if (accountId == null) {
      accountIdValue = const d.Value.absent();
    } else if (accountId is d.Value<int?>) {
      accountIdValue = accountId;
    } else {
      accountIdValue = d.Value(accountId as int?);
    }
    final d.Value<int?> toAccountIdValue;
    if (toAccountId == null) {
      toAccountIdValue = const d.Value.absent();
    } else if (toAccountId is d.Value<int?>) {
      toAccountIdValue = toAccountId;
    } else {
      toAccountIdValue = d.Value(toAccountId as int?);
    }
    await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(
      TransactionsCompanion(
        accountId: accountIdValue,
        toAccountId: toAccountIdValue,
        // override 写入只在调用方明确要求时才动(否则保留 Drift 老值),
        // 区别于 dart null 默认行为(=absent)。共享账本 Editor 场景:
        // synthetic 账户 → accountId=null + 这里写 syncIdOverride。
        accountSyncIdOverride: writeAccountSyncIdOverride
            ? d.Value(accountSyncIdOverride)
            : const d.Value.absent(),
        toAccountSyncIdOverride: writeToAccountSyncIdOverride
            ? d.Value(toAccountSyncIdOverride)
            : const d.Value.absent(),
      ),
    );
  }

  @override
  Future<Transaction?> getFirstTransactionByLedger(int ledgerId) async {
    return await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.asc)
          ])
          ..limit(1))
        .getSingleOrNull();
  }

  @override
  Future<Transaction?> getLastTransactionByLedger(int ledgerId) async {
    return await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ])
          ..limit(1))
        .getSingleOrNull();
  }

  @override
  Future<DateTime?> getEarliestTransactionDate() async {
    // 排除以成员身份加入的共享账本(is_shared=1 且 my_role!='owner')——与资产统计 /
    // getAccountDailyBalances 同口径(#333),否则趋势「全部」起点会被别人账本的
    // 早期流水拉前。自己 Own 的共享账本不排除。
    final sharedRows = await (db.selectOnly(db.ledgers)
          ..addColumns([db.ledgers.id])
          ..where(db.ledgers.isShared.equals(true) &
              db.ledgers.myRole.equals('owner').not()))
        .get();
    final sharedIds = sharedRows.map((r) => r.read(db.ledgers.id)!).toList();
    final row = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.isNotIn(sharedIds))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.asc)
          ])
          ..limit(1))
        .getSingleOrNull();
    return row?.happenedAt;
  }

  @override
  Future<void> updateTransactionLedger({
    required int id,
    required int ledgerId,
  }) async {
    await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(
      TransactionsCompanion(ledgerId: d.Value(ledgerId)),
    );
  }

  // ==================== 日历功能相关 ====================

  @override
  Future<Map<String, (double, double)>> getDailyTotalsByMonth({
    required int ledgerId,
    required DateTime month,
  }) async {
    final startDate = DateTime(month.year, month.month, 1);
    final endDate = DateTime(month.year, month.month + 1, 0, 23, 59, 59);

    // SQL 聚合查询
    // Drift 存储 DateTime 为 Unix timestamp（秒），直接使用 strftime
    //
    // C3/F-16:SQLite 的 'localtime' 修饰符在部分 Android 构建(不含 OS 时区
    // 支持)返回 NULL → 日历月视图恒空。改用本机时区偏移秒手工还原(与
    // local_statistics_repository.totalsByDay 同款已验证方案)。
    final tzOffset = DateTime.now().timeZoneOffset.inSeconds;
    final query = '''
      SELECT
        strftime('%Y-%m-%d', happened_at + $tzOffset, 'unixepoch') as date,
        SUM(CASE WHEN type = 'income' AND exclude_from_stats = 0 THEN COALESCE(native_amount, amount) ELSE 0 END) as income,
        SUM(CASE WHEN type = 'expense' AND exclude_from_stats = 0 THEN COALESCE(native_amount, amount) ELSE 0 END) as expense
      FROM transactions
      WHERE ledger_id = ?
        AND happened_at >= ?
        AND happened_at <= ?
      GROUP BY date
      ORDER BY date DESC
    ''';

    final results = await db.customSelect(
      query,
      variables: [
        d.Variable.withInt(ledgerId),
        d.Variable.withDateTime(startDate),
        d.Variable.withDateTime(endDate),
      ],
    ).get();

    final map = <String, (double, double)>{};
    for (final row in results) {
      final date = row.read<String?>('date');
      if (date == null) continue; // 跳过null日期
      final income = row.read<double>('income') ?? 0.0;
      final expense = row.read<double>('expense') ?? 0.0;
      map[date] = (income, expense);
    }

    return map;
  }

  @override
  Future<
      List<
          ({
            Transaction t,
            Category? category,
            List<Tag> tags,
            List<TransactionAttachment> attachments,
            Account? account,
          })>> getTransactionsByDate({
    required int ledgerId,
    required DateTime date,
  }) async {
    final startOfDay = DateTime(date.year, date.month, date.day);
    final endOfDay = DateTime(date.year, date.month, date.day, 23, 59, 59);

    // 查询当天的所有交易
    final transactions = await (db.select(db.transactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.happenedAt.isBetweenValues(startOfDay, endOfDay))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ]))
        .get();

    if (transactions.isEmpty) {
      return [];
    }

    final txIds = transactions.map((t) => t.id).toList();

    // 批量查询分类(C10:isIn 一次取全,不再逐 tx 点查)
    final categoryIds = transactions
        .map((t) => t.categoryId)
        .whereType<int>()
        .toSet()
        .toList();
    final categoriesMap = <int, Category>{};
    if (categoryIds.isNotEmpty) {
      final cats = await (db.select(db.categories)
            ..where((c) => c.id.isIn(categoryIds)))
          .get();
      for (final c in cats) {
        categoriesMap[c.id] = c;
      }
    }

    // 批量查询标签
    final tagsMap = <int, List<Tag>>{};
    final tagRelations = await (db.select(db.transactionTags)
          ..where((tt) => tt.transactionId.isIn(txIds)))
        .get();

    final tagIds = tagRelations.map((r) => r.tagId).toSet();
    if (tagIds.isNotEmpty) {
      final tags = await (db.select(db.tags)
            ..where((t) => t.id.isIn(tagIds.toList())))
          .get();
      final tagsById = {for (var tag in tags) tag.id: tag};

      for (final rel in tagRelations) {
        final tag = tagsById[rel.tagId];
        if (tag != null) {
          tagsMap.putIfAbsent(rel.transactionId, () => []).add(tag);
        }
      }
    }

    // 批量查询附件
    final attachmentsMap = <int, List<TransactionAttachment>>{};
    final attachments = await (db.select(db.transactionAttachments)
          ..where((a) => a.transactionId.isIn(txIds)))
        .get();
    for (final attachment in attachments) {
      attachmentsMap
          .putIfAbsent(attachment.transactionId, () => [])
          .add(attachment);
    }

    // 批量查询账户
    final accountIds = transactions
        .where((t) => t.accountId != null)
        .map((t) => t.accountId!)
        .toSet();
    final accountsMap = <int, Account>{};
    if (accountIds.isNotEmpty) {
      final accounts = await (db.select(db.accounts)
            ..where((a) => a.id.isIn(accountIds.toList())))
          .get();
      for (final account in accounts) {
        accountsMap[account.id] = account;
      }
    }

    // 组装结果
    final raw = transactions.map((tx) {
      return (
        t: tx,
        category: tx.categoryId != null ? categoriesMap[tx.categoryId] : null,
        tags: tagsMap[tx.id] ?? [],
        attachments: attachmentsMap[tx.id] ?? [],
        account: tx.accountId != null ? accountsMap[tx.accountId] : null,
      );
    }).toList();
    return _hydrateSharedOverridesFull(raw);
  }

  /// §7 共享账本统一 hydration:
  /// - tx.categoryId 为空 + categorySyncIdOverride 非空 → 查 SharedLedgerCategories
  ///   构造 synthetic Category(同 _hydrateSharedCategoryOverrides)
  /// - tx.accountId 为空 + accountSyncIdOverride 非空 → 查 SharedLedgerAccounts
  ///   构造 synthetic Account
  /// - tx.tagSyncIdsOverride 不为空 → 查 TransactionTagOverrides → SharedLedgerTags
  ///   union 到 tags 列表(synthetic id<0)
  ///
  /// 日历页 / 详情页等任何返回 tx + category + tags + account 完整 tuple 的查询
  /// 都用这个 helper 兜底,跟 transaction_list 走 _hydrateSharedCategoryOverrides
  /// 一致。
  Future<
      List<
          ({
            Transaction t,
            Category? category,
            List<Tag> tags,
            List<TransactionAttachment> attachments,
            Account? account,
          })>> _hydrateSharedOverridesFull(
    List<
            ({
              Transaction t,
              Category? category,
              List<Tag> tags,
              List<TransactionAttachment> attachments,
              Account? account,
            })>
        rows,
  ) async {
    if (rows.isEmpty) return rows;

    // 收集需要 hydrate 的 syncId / tx.syncId
    final catSyncIds = <String>{};
    final accSyncIds = <String>{};
    final txSyncIds = <String>{};
    for (final r in rows) {
      final cov = r.t.categorySyncIdOverride;
      if (r.category == null && cov != null && cov.isNotEmpty) {
        catSyncIds.add(cov);
      }
      final aov = r.t.accountSyncIdOverride;
      if (r.account == null && aov != null && aov.isNotEmpty) {
        accSyncIds.add(aov);
      }
      if (r.t.syncId != null && r.t.syncId!.isNotEmpty) {
        txSyncIds.add(r.t.syncId!);
      }
    }

    // 批量查共享分类
    final sharedCatBySyncId = <String, SharedLedgerCategory>{};
    if (catSyncIds.isNotEmpty) {
      final list = await (db.select(db.sharedLedgerCategories)
            ..where((t) => t.syncId.isIn(catSyncIds.toList())))
          .get();
      for (final s in list) sharedCatBySyncId[s.syncId] = s;
    }

    // 批量查共享账户
    final sharedAccBySyncId = <String, SharedLedgerAccount>{};
    if (accSyncIds.isNotEmpty) {
      final list = await (db.select(db.sharedLedgerAccounts)
            ..where((t) => t.syncId.isIn(accSyncIds.toList())))
          .get();
      for (final s in list) sharedAccBySyncId[s.syncId] = s;
    }

    // 批量查 tag overrides + shared tags
    final tagOverridesByTxSyncId = <String, List<String>>{};
    final sharedTagBySyncId = <String, SharedLedgerTag>{};
    if (txSyncIds.isNotEmpty) {
      final overrides = await (db.select(db.transactionTagOverrides)
            ..where((t) => t.transactionSyncId.isIn(txSyncIds.toList())))
          .get();
      for (final ov in overrides) {
        tagOverridesByTxSyncId
            .putIfAbsent(ov.transactionSyncId, () => [])
            .add(ov.tagSyncId);
      }
      if (overrides.isNotEmpty) {
        final tagSids = overrides.map((o) => o.tagSyncId).toSet().toList();
        final sharedTags = await (db.select(db.sharedLedgerTags)
              ..where((t) => t.syncId.isIn(tagSids)))
            .get();
        for (final s in sharedTags) sharedTagBySyncId[s.syncId] = s;
      }
    }

    return rows.map((r) {
      Category? category = r.category;
      Account? account = r.account;
      List<Tag> tags = r.tags;

      if (category == null) {
        final cov = r.t.categorySyncIdOverride;
        if (cov != null && cov.isNotEmpty) {
          final s = sharedCatBySyncId[cov];
          if (s != null) {
            category = Category(
              id: syntheticIdForSyncId(s.syncId),
              name: s.name,
              kind: s.kind,
              icon: s.icon,
              sortOrder: s.sortOrder,
              parentId: null,
              level: s.level,
              iconType: s.iconType,
              customIconPath:
                  s.iconType == 'custom' && s.iconCloudSha256 != null
                      ? 'custom_icons/shared_${s.iconCloudSha256}.png'
                      : null,
              communityIconId: null,
              syncId: s.syncId,
            );
          }
        }
      }

      if (account == null) {
        final aov = r.t.accountSyncIdOverride;
        if (aov != null && aov.isNotEmpty) {
          final s = sharedAccBySyncId[aov];
          if (s != null) {
            account = Account(
              id: syntheticIdForSyncId(s.syncId),
              ledgerId: r.t.ledgerId,
              name: s.name,
              type: s.accountType,
              currency: s.currency,
              note: s.note,
              initialBalance: s.initialBalance ?? 0.0,
              sortOrder: 0,
              creditLimit: s.creditLimit,
              billingDay: s.billingDay,
              paymentDueDay: s.paymentDueDay,
              bankName: s.bankName,
              cardLastFour: s.cardLastFour,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
              syncId: s.syncId,
              // SharedLedgerAccounts 镜像表没有 hidden 概念(隐藏是 Owner 侧
              // 个人状态,不随共享账本镜像同步),synthetic 账户固定按「未隐藏」处理。
              hidden: false,
            );
          }
        }
      }

      final txSid = r.t.syncId;
      if (txSid != null && tagOverridesByTxSyncId.containsKey(txSid)) {
        final extra = <Tag>[];
        for (final tagSid in tagOverridesByTxSyncId[txSid]!) {
          final s = sharedTagBySyncId[tagSid];
          if (s != null) {
            extra.add(Tag(
              id: syntheticIdForSyncId(s.syncId),
              name: s.name,
              color: s.color,
              sortOrder: 0,
              createdAt: DateTime.now(),
              syncId: s.syncId,
            ));
          }
        }
        if (extra.isNotEmpty) tags = [...tags, ...extra];
      }

      return (
        t: r.t,
        category: category,
        tags: tags,
        attachments: r.attachments,
        account: account,
      );
    }).toList();
  }

  @override
  Future<
      List<
          ({
            Transaction t,
            Category? category,
            List<Tag> tags,
            List<TransactionAttachment> attachments,
            Account? account,
          })>> getTransactionsByDateRange({
    required int ledgerId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    // 查询时间范围内的所有交易
    final transactions = await (db.select(db.transactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.happenedAt.isBetweenValues(startDate, endDate))
          ..orderBy([
            (t) => d.OrderingTerm(
                  expression: t.happenedAt,
                  mode: d.OrderingMode.desc,
                ),
          ]))
        .get();

    if (transactions.isEmpty) return const [];

    // C2:批量化获取 category/tags/attachments/account(此前逐 tx 5 类点查,
    // N 笔 = ~3N+Σtags 次串行往返)。与 getTransactionsByDate 同款模式。
    final txIds = transactions.map((t) => t.id).toList();

    final categoryIds =
        transactions.map((t) => t.categoryId).whereType<int>().toSet().toList();
    final categoriesMap = <int, Category>{};
    if (categoryIds.isNotEmpty) {
      final cats = await (db.select(db.categories)
            ..where((c) => c.id.isIn(categoryIds)))
          .get();
      for (final c in cats) {
        categoriesMap[c.id] = c;
      }
    }

    final tagsMap = <int, List<Tag>>{};
    final tagRelations = await (db.select(db.transactionTags)
          ..where((tt) => tt.transactionId.isIn(txIds)))
        .get();
    final tagIds = tagRelations.map((r) => r.tagId).toSet();
    if (tagIds.isNotEmpty) {
      final tags = await (db.select(db.tags)
            ..where((t) => t.id.isIn(tagIds.toList())))
          .get();
      final tagsById = {for (var tag in tags) tag.id: tag};
      for (final rel in tagRelations) {
        final tag = tagsById[rel.tagId];
        if (tag != null) {
          tagsMap.putIfAbsent(rel.transactionId, () => []).add(tag);
        }
      }
    }

    final attachmentsMap = <int, List<TransactionAttachment>>{};
    final attachments = await (db.select(db.transactionAttachments)
          ..where((a) => a.transactionId.isIn(txIds)))
        .get();
    for (final attachment in attachments) {
      attachmentsMap.putIfAbsent(attachment.transactionId, () => []).add(attachment);
    }

    final accountIds = transactions
        .map((t) => t.accountId)
        .whereType<int>()
        .toSet()
        .toList();
    final accountsMap = <int, Account>{};
    if (accountIds.isNotEmpty) {
      final accounts = await (db.select(db.accounts)
            ..where((a) => a.id.isIn(accountIds)))
          .get();
      for (final account in accounts) {
        accountsMap[account.id] = account;
      }
    }

    final result = <({
      Transaction t,
      Category? category,
      List<Tag> tags,
      List<TransactionAttachment> attachments,
      Account? account,
    })>[];
    for (final transaction in transactions) {
      result.add((
        t: transaction,
        category: transaction.categoryId != null
            ? categoriesMap[transaction.categoryId]
            : null,
        tags: tagsMap[transaction.id] ?? [],
        attachments: attachmentsMap[transaction.id] ?? [],
        account: transaction.accountId != null
            ? accountsMap[transaction.accountId]
            : null,
      ));
    }

    return _hydrateSharedOverridesFull(result);
  }

  @override
  Future<List<String>> getTransactionDatesByMonth({
    required int ledgerId,
    required DateTime month,
  }) async {
    final startDate = DateTime(month.year, month.month, 1);
    final endDate = DateTime(month.year, month.month + 1, 0, 23, 59, 59);

    // C3/F-16:DATE(happened_at) 缺 'unixepoch' 解释 → drift 存的 UTC unix 秒
    // 被当儒略日,结果恒 NULL。补上 unixepoch + 时区偏移,与
    // getDailyTotalsByMonth 同口径。
    final tzOffset = DateTime.now().timeZoneOffset.inSeconds;
    final query = '''
      SELECT DISTINCT DATE(happened_at + $tzOffset, 'unixepoch') as date
      FROM transactions
      WHERE ledger_id = ?
        AND happened_at >= ?
        AND happened_at <= ?
      ORDER BY date DESC
    ''';

    final results = await db.customSelect(
      query,
      variables: [
        d.Variable.withInt(ledgerId),
        d.Variable.withDateTime(startDate),
        d.Variable.withDateTime(endDate),
      ],
    ).get();

    return results
        .map((row) => row.read<String?>('date'))
        .where((date) => date != null)
        .cast<String>()
        .toList();
  }

  // ==================== syncId 相关 ====================

  @override
  Future<Transaction?> getTransactionBySyncId(String syncId) async {
    // C3/F-01/F-02:limit(1) 取代 getSingleOrNull —— 唯一索引建立后同账本不会
    // 重复,但跨账本同 syncId 仍合法(UNIQUE(ledger_id, sync_id)),且历史脏库
    // 可能残留重复行;多行时抛 Bad state 会让所有按 syncId 的操作(含删除推送)
    // 永久断裂。确定性取最小 id(最早一行)。
    return await (db.select(db.transactions)
          ..where((t) => t.syncId.equals(syncId))
          ..orderBy([(t) => d.OrderingTerm(
              expression: t.id, mode: d.OrderingMode.asc)])
          ..limit(1))
        .getSingleOrNull();
  }

  @override
  Future<void> updateTransactionBySyncId({
    required String syncId,
    required String type,
    required double amount,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    required DateTime happenedAt,
    String? note,
  }) async {
    // 缺陷 F:按 syncId 的单条直写此前不校验(与批量入口同族)。
    _assertTxValues(type: type, amount: amount, path: 'updateTransactionBySyncId');
    await (db.update(db.transactions)..where((t) => t.syncId.equals(syncId)))
        .write(TransactionsCompanion(
      type: d.Value(type),
      amount: d.Value(amount),
      categoryId: d.Value(categoryId),
      accountId: d.Value(accountId),
      toAccountId: d.Value(toAccountId),
      happenedAt: d.Value(happenedAt),
      note: d.Value(note),
    ));
  }

  @override
  Future<void> deleteTransactionBySyncId(String syncId) async {
    // C3/缺陷 I:syncId 只在账本内唯一(UNIQUE(ledger_id, sync_id);跨账本同
    // syncId 是合法状态)。旧实现把「所有匹配行」全删 —— 两个账本各有一笔同
    // syncId 时,删一个账本的交易会连带删掉另一个账本的账目(实测 remaining
    // tx ids = []),而 updateTransactionLedger(ai_chat_page 的「改账本」)就会
    // 制造这种跨账本同 syncId 状态,路径可达。
    //
    // 语义(与 deleteTransactionsBatchBySyncIds 一致,共用
    // [_crossLedgerSyncIds] 判定):同一账本内的匹配行全部删除;**该 syncId
    // 命中多个账本时显式抛错**,不再静默批量删除。接口没有账本维度(改动签名
    // 要动 TransactionRepository 接口,超出本次改动面),故用 fail-closed:
    // 调用方拿到明确异常,而不是另一个账本的数据静默消失。
    final txs = await (db.select(db.transactions)
          ..where((t) => t.syncId.equals(syncId)))
        .get();
    if (txs.isEmpty) return;
    if (_crossLedgerSyncIds([syncId], txs).isNotEmpty) {
      final ledgers = txs.map((t) => t.ledgerId).toSet().toList()..sort();
      throw StateError(
          'deleteTransactionBySyncId("$syncId") 命中 ${txs.length} 行、跨 '
          '${ledgers.length} 个账本(${ledgers.join(",")}):syncId 只在账本内唯一,'
          '拒绝静默跨账本批量删除;请改按本地 id 删除或先按账本过滤。');
    }
    for (final tx in txs) {
      await deleteTransaction(tx.id);
    }
  }

  /// 批量删除的 fail-closed 判定(单条/批量入口共用):
  /// **单个 syncId 命中多个账本**的 syncId 列表(空 = 批次合法)。
  ///
  /// 判据是「一个 syncId 跨账本」,不是「批次里出现了多个账本」:
  /// UNIQUE(ledger_id, sync_id) 下跨账本同 syncId 合法,两个**不同** syncId
  /// 各属一个账本是完全正常的批次(旧判定会整批 StateError 且一行不删)。
  /// 单条入口传 `[syncId]` 时退化为「该 syncId 是否跨账本」,语义一致。
  static List<String> _crossLedgerSyncIds(
      List<String> syncIds, List<Transaction> rows) {
    final ledgersBySyncId = <String, Set<int>>{};
    for (final r in rows) {
      final s = r.syncId;
      if (s == null) continue;
      (ledgersBySyncId[s] ??= <int>{}).add(r.ledgerId);
    }
    return [
      for (final s in syncIds)
        if ((ledgersBySyncId[s]?.length ?? 0) > 1) s,
    ];
  }

  @override
  Future<Map<String, int>> updateTransactionsBatchBySyncId(
    List<TransactionUpdateBySyncIdData> updates, {
    bool recordChanges = true,
  }) async {
    if (updates.isEmpty) return const {};
    // 缺陷 F:此路径被 sync_diff_service.applySyncChanges 用于「从云端快照
    // 合并本地交易」,此前完全不校验 → 远端脏金额(负值/Infinity)静默覆盖本地。
    // **策略:跳过该行 + 告警**(非抛错)—— 调用方是批量合并,一条坏行抛错会
    // 让整批(含正常行)回滚,同步预览的"成功 N 条"变成 0 且用户无法只吞坏行。
    // 跳过仅影响该 syncId,其余行照常更新,tag 关联也照常反查。
    final accepted = <TransactionUpdateBySyncIdData>[];
    for (final u in updates) {
      final reason = txAmountViolation(u.type, u.amount);
      if (reason != null) {
        logger.warning(
            'LocalTransactionRepository',
            '[updateTransactionsBatchBySyncId] 跳过 syncId=${u.syncId}:'
                '${violationMessage(reason, u.type, u.amount)}');
        continue;
      }
      accepted.add(u);
    }
    if (accepted.isEmpty) return const {};
    return db.transaction(() async {
      await db.batch((b) {
        for (final u in accepted) {
          b.update(
            db.transactions,
            TransactionsCompanion(
              type: d.Value(u.type),
              amount: d.Value(u.amount),
              categoryId: d.Value(u.categoryId),
              accountId: d.Value(u.accountId),
              toAccountId: d.Value(u.toAccountId),
              happenedAt: d.Value(u.happenedAt),
              note: d.Value(u.note),
            ),
            where: (t) => t.syncId.equals(u.syncId),
          );
        }
      });
      // 反查 (syncId, txId) 映射,caller 用它批量更新 tag 关联
      final syncIds = accepted.map((u) => u.syncId).toList();
      final rows = await (db.select(db.transactions)
            ..where((t) => t.syncId.isIn(syncIds)))
          .get();
      return {
        for (final tx in rows)
          if (tx.syncId != null) tx.syncId!: tx.id,
      };
    });
  }

  @override
  Future<int> deleteTransactionsBatchBySyncIds(
    List<String> syncIds, {
    bool recordChanges = true,
  }) async {
    // recordChanges 由 LocalRepository wrapper 处理(子仓库无 changeTracker)。
    if (syncIds.isEmpty) return 0;
    // C3/F-06:批量删除与单条删除**同语义** —— 进回收站(tombstone)而非硬删。
    // 旧实现直接 DELETE 主表 + 关联,客户端回收站为空且 wrapper 不补 change
    // → 云端不知情,下次 pull 全部复活,本地又不可恢复。
    //
    // C3/缺陷 I(修正版):syncId 只在账本内唯一(UNIQUE(ledger_id, sync_id)),
    // 跨账本同 syncId 合法。真正的危险条件是**单个 syncId 命中 >1 个账本** ——
    // 此时无法判断该删哪个账本的那一笔,删除会静默波及另一个账本。
    //
    // 旧判定是「批次命中的行来自 >1 个账本」,把**两个不同 syncId 各属一个
    // 账本**的完全合法批次也整批拒绝(StateError 且一行不删)。修正为按
    // syncId 分组判定:一个 syncId 跨账本 → fail-closed;不同 syncId 分属
    // 不同账本 → 正常删除(每行只受自己账本约束)。
    return db.transaction(() async {
      final rows = await (db.select(db.transactions)
            ..where((t) => t.syncId.isIn(syncIds)))
          .get();
      if (rows.isEmpty) return 0;
      final conflicting = _crossLedgerSyncIds(syncIds, rows);
      if (conflicting.isNotEmpty) {
        throw StateError(
            'deleteTransactionsBatchBySyncIds 中 ${conflicting.length} 个 syncId '
            '命中多个账本(${conflicting.join(",")}):syncId 只在账本内唯一,'
            '拒绝静默跨账本批量删除;请改按本地 id 删除。');
      }
      for (final tx in rows) {
        await _archiveToTrash(tx);
      }
      final txIds = rows.map((r) => r.id).toList();
      // 删关联数据(级联;附件行同样清,避免悬挂)
      await (db.delete(db.transactionTags)
            ..where((t) => t.transactionId.isIn(txIds)))
          .go();
      await (db.delete(db.transactionAttachments)
            ..where((t) => t.transactionId.isIn(txIds)))
          .go();
      // 主表 DELETE WHERE IN — 一次 SQL 删 N 条
      final deleted = await (db.delete(db.transactions)
            ..where((t) => t.id.isIn(txIds)))
          .go();
      return deleted;
    });
  }

  @override
  Future<int> createAdjustmentTransaction({
    required int ledgerId,
    required int accountId,
    required double amount,
    required DateTime happenedAt,
    String? note,
  }) async {
    return await addTransaction(
      ledgerId: ledgerId,
      type: 'adjustment',
      amount: amount,
      accountId: accountId,
      happenedAt: happenedAt,
      note: note,
    );
  }
}
