import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';

import '../../db.dart';
import '../../../services/system/logger_service.dart';
import '../../../utils/account_type_utils.dart';
import '../account_repository.dart';
import '../exceptions.dart';

/// 单账户聚合结果(余额增量 / 支出 / 收入)。
typedef _AccountAggregates = ({
  double balanceDelta,
  double expense,
  double income,
});

/// 本地账户Repository实现
/// 基于 Drift 数据库实现
class LocalAccountRepository implements AccountRepository {
  static const _uuid = Uuid();
  final BeeDatabase db;

  LocalAccountRepository(this.db);

  @override
  Stream<List<Account>> watchAccountsForLedger(int ledgerId) {
    // 账户是 user-global 实体:当前账本创建的 (== ledgerId) 以及同步下来的
    // user-global 账户 (ledger_id <= 0,包括历史脏值 -1) 都要展示,否则
    // 云端创建的账户在 App 账户管理页永远看不到。
    return (db.select(db.accounts)
          ..where((a) => a.ledgerId.equals(ledgerId) |
              a.ledgerId.isSmallerOrEqualValue(0)))
        .watch();
  }

  @override
  Stream<List<Account>> watchAllAccounts() {
    return (db.select(db.accounts)
          ..orderBy([
            (a) => d.OrderingTerm(expression: a.type),
            (a) => d.OrderingTerm(expression: a.sortOrder),
          ]))
        .watch();
  }

  @override
  Future<List<Account>> getAllAccounts() async {
    return await (db.select(db.accounts)
          ..orderBy([
            (a) => d.OrderingTerm(expression: a.type),
            (a) => d.OrderingTerm(expression: a.sortOrder),
          ]))
        .get();
  }

  @override
  Future<Account?> getAccount(int accountId) async {
    return await (db.select(db.accounts)
          ..where((a) => a.id.equals(accountId)))
        .getSingleOrNull();
  }

  @override
  Future<List<Account>> getAvailableAccountsForLedger(int ledgerId) async {
    // 获取账本信息
    final ledger = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(ledgerId)))
        .getSingle();

    // 通过币种过滤账户
    return await (db.select(db.accounts)
          ..where((a) => a.currency.equals(ledger.currency)))
        .get();
  }

  @override
  Future<List<Account>> getAccountsByCurrency(String currency) async {
    return await (db.select(db.accounts)
          ..where((a) => a.currency.equals(currency)))
        .get();
  }

  @override
  Future<Map<String, List<Account>>> getAccountsGroupedByCurrency() async {
    final allAccounts = await getAllAccounts();
    final Map<String, List<Account>> grouped = {};

    for (final account in allAccounts) {
      grouped.putIfAbsent(account.currency, () => []).add(account);
    }

    return grouped;
  }

  @override
  Future<int> createAccount({
    required int ledgerId,
    required String name,
    String type = 'cash',
    String currency = 'CNY',
    double initialBalance = 0.0,
    double? creditLimit,
    int? billingDay,
    int? paymentDueDay,
    String? bankName,
    String? cardLastFour,
    String? note,
    String? syncId,
  }) async {
    // 撞同名抛 DuplicateNameException(name 全局唯一)。静默路径(import /
    // app-link 等)请改用 [upsertAccount]。
    final existingByName =
        await (db.select(db.accounts)..where((a) => a.name.equals(name))).get();
    if (existingByName.isNotEmpty) {
      throw DuplicateNameException(
        entityType: 'account',
        name: name,
        existingId: existingByName.first.id,
      );
    }
    try {
      // 计算同类型最大 sortOrder + 1
      final maxSortOrderResult = await db.customSelect(
        'SELECT COALESCE(MAX(sort_order), -1) AS max_order FROM accounts WHERE type = ?1',
        variables: [d.Variable.withString(type)],
        readsFrom: {db.accounts},
      ).getSingle();
      final nextSortOrder = (maxSortOrderResult.data['max_order'] as int) + 1;

      final companion = AccountsCompanion.insert(
        ledgerId: ledgerId,
        name: name,
        type: d.Value(type),
        currency: d.Value(currency),
        initialBalance: d.Value(initialBalance),
        createdAt: d.Value(DateTime.now()),
        sortOrder: d.Value(nextSortOrder),
        creditLimit: d.Value(creditLimit),
        billingDay: d.Value(billingDay),
        paymentDueDay: d.Value(paymentDueDay),
        bankName: d.Value(bankName),
        cardLastFour: d.Value(cardLastFour),
        note: d.Value(note),
        syncId: d.Value(syncId ?? _uuid.v4()),
      );

      final id = await db.into(db.accounts).insert(companion);
      // 单条 INFO 日志(import 批量场景下 3 条/账户 会把 logger 队列冲爆,降级
      // 到 debug;只在出错时 error)
      logger.debug('AccountCreate', '账户创建: id=$id name=$name type=$type');
      return id;
    } catch (e, stack) {
      logger.error('AccountCreate', '创建账户失败 name=$name', e, stack);
      rethrow;
    }
  }

  @override
  Future<int> upsertAccount({
    required String name,
    int ledgerId = 0,
    String type = 'cash',
    String currency = 'CNY',
    double initialBalance = 0.0,
  }) async {
    final existing = await (db.select(db.accounts)
          ..where((a) => a.name.equals(name)))
        .get();
    if (existing.isNotEmpty) return existing.first.id;
    // 复用 createAccount(此时 name 不冲突,不会抛)
    return createAccount(
      ledgerId: ledgerId,
      name: name,
      type: type,
      currency: currency,
      initialBalance: initialBalance,
    );
  }

  @override
  Future<void> updateAccount(
    int id, {
    String? name,
    String? type,
    String? currency,
    double? initialBalance,
    double? creditLimit,
    int? billingDay,
    int? paymentDueDay,
    bool clearCreditCardFields = false,
    String? bankName,
    String? cardLastFour,
    String? note,
    bool clearMetadataFields = false,
    bool? hidden,
  }) async {
    await (db.update(db.accounts)..where((a) => a.id.equals(id))).write(
      AccountsCompanion(
        name: name != null ? d.Value(name) : const d.Value.absent(),
        type: type != null ? d.Value(type) : const d.Value.absent(),
        currency: currency != null ? d.Value(currency) : const d.Value.absent(),
        initialBalance: initialBalance != null ? d.Value(initialBalance) : const d.Value.absent(),
        creditLimit: clearCreditCardFields ? const d.Value(null) : (creditLimit != null ? d.Value(creditLimit) : const d.Value.absent()),
        billingDay: clearCreditCardFields ? const d.Value(null) : (billingDay != null ? d.Value(billingDay) : const d.Value.absent()),
        paymentDueDay: clearCreditCardFields ? const d.Value(null) : (paymentDueDay != null ? d.Value(paymentDueDay) : const d.Value.absent()),
        bankName: clearMetadataFields ? const d.Value(null) : (bankName != null ? d.Value(bankName) : const d.Value.absent()),
        cardLastFour: clearMetadataFields ? const d.Value(null) : (cardLastFour != null ? d.Value(cardLastFour) : const d.Value.absent()),
        note: clearMetadataFields ? const d.Value(null) : (note != null ? d.Value(note) : const d.Value.absent()),
        hidden: hidden == null ? const d.Value.absent() : d.Value(hidden),
      ),
    );
  }

  @override
  Future<void> setAccountHidden(int id, bool hidden) =>
      updateAccount(id, hidden: hidden);

  @override
  Future<List<Account>> getCreditCardAccounts() async {
    return await (db.select(db.accounts)
          ..where((a) => a.type.equals('credit_card'))
          ..orderBy([(a) => d.OrderingTerm(expression: a.sortOrder)]))
        .get();
  }

  @override
  Future<double> getCreditCardUsedAmount(int accountId) async {
    // 已用额度 = -balance（余额为负表示欠款）
    final balance = await getAccountBalance(accountId);
    return balance < 0 ? -balance : 0.0;
  }

  @override
  Future<void> deleteAccount(int id) async {
    await (db.delete(db.accounts)..where((a) => a.id.equals(id))).go();
  }

  /// 「以成员身份加入的共享账本」ledger id 集合 —— **个人资产统计一律排除
  /// 这些账本的交易**。加入他人共享账本时,Owner 的历史流水会同步到本机并
  /// 挂在本地账户行上,若计入会把别人账本的收支算进自己的净资产,且与
  /// Web/服务端口径(成员侧不计共享账本)永久不一致。
  /// 注意:**自己 Own 的共享账本不排除** —— 那是自己的账本分享给别人,
  /// 服务端也记在 Owner 名下。SQL 版条件见 _kExcludeJoinedSharedLedgerSql。
  Future<Set<int>> _sharedLedgerIds() async {
    final rows = await (db.selectOnly(db.ledgers)
          ..addColumns([db.ledgers.id])
          ..where(db.ledgers.isShared.equals(true) &
              db.ledgers.myRole.equals('owner').not()))
        .get();
    return rows.map((r) => r.read(db.ledgers.id)!).toSet();
  }

  /// customSelect 用的排除条件(语义同 [_sharedLedgerIds])
  static const String _kExcludeJoinedSharedLedgerSql =
      "ledger_id NOT IN (SELECT id FROM ledgers WHERE is_shared = 1 AND my_role != 'owner')";

  /// PERF-P0-04:两侧并集子查询 —— 主账户侧全类型 + 转入侧(to_account_id)
  /// 全类型,并打 is_to 标记。余额/收支聚合都基于它一次扫完。
  ///
  /// 转入侧不过滤 type:旧 getAccountGlobalBalance / getAccountBalanceInLedger
  /// 对转入侧是「to_account_id 命中即加金额」不看类型(getAccountBalance 虽然在
  /// SQL 里过滤了 transfer,但实际数据 to_account_id 只会出现在转账上,两种
  /// 写法在 CASE 里分别对齐)。
  static const String _kAccountSidesCte = '''
WITH sides AS (
  SELECT account_id AS aid, type, amount, exclude_from_stats, 0 AS is_to
    FROM transactions
   WHERE account_id IS NOT NULL AND $_kExcludeJoinedSharedLedgerSql
  UNION ALL
  SELECT to_account_id AS aid, type, amount, exclude_from_stats, 1 AS is_to
    FROM transactions
   WHERE to_account_id IS NOT NULL AND $_kExcludeJoinedSharedLedgerSql
)''';

  /// PERF-P0-04:一次扫描同时算出每个账户的 (余额增量, 支出, 收入)。
  /// 语义与旧 Dart 逐行累加逐条对齐:
  /// - 余额增量:主账户侧 income/adjustment 加、expense/transfer 减;转入侧
  ///   transfer 加。**不看 exclude_from_stats**(余额口径)。
  /// - 支出:主账户侧 expense + transfer(转出),exclude_from_stats = 0。
  /// - 收入:主账户侧 income + 转入侧 transfer,exclude_from_stats = 0。
  /// - 排除以成员身份加入的共享账本(_kAccountSidesCte 内)。
  static const String _kAccountAggregatesSelect = '''
SELECT aid,
       COALESCE(SUM(CASE
         WHEN is_to = 0 AND type IN ('income', 'adjustment') THEN amount
         WHEN is_to = 0 AND type IN ('expense', 'transfer') THEN -amount
         WHEN is_to = 1 AND type = 'transfer' THEN amount
         ELSE 0 END), 0) AS bal_delta,
       COALESCE(SUM(CASE
         WHEN is_to = 0 AND type IN ('expense', 'transfer')
              AND exclude_from_stats = 0 THEN amount
         ELSE 0 END), 0) AS expense,
       COALESCE(SUM(CASE
         WHEN exclude_from_stats = 0
              AND ((is_to = 0 AND type = 'income')
                   OR (is_to = 1 AND type = 'transfer')) THEN amount
         ELSE 0 END), 0) AS income
  FROM sides''';

  /// 全部(或单个)账户的一次性聚合。返回 map 按账户 id 索引,无交易的账户
  /// 不出现在结果里(调用方按 0 处理)。
  Future<Map<int, _AccountAggregates>> _bulkAccountAggregates(
      {int? accountId}) async {
    final rows = await db.customSelect(
      '$_kAccountSidesCte $_kAccountAggregatesSelect '
      '${accountId != null ? 'WHERE aid = ?1 ' : ''}GROUP BY aid',
      variables:
          accountId != null ? [d.Variable.withInt(accountId)] : const [],
      readsFrom: {db.transactions},
    ).get();

    return {
      for (final row in rows)
        row.data['aid'] as int: (
          balanceDelta: (row.data['bal_delta'] as num).toDouble(),
          expense: (row.data['expense'] as num).toDouble(),
          income: (row.data['income'] as num).toDouble(),
        ),
    };
  }

  /// 全部账户的当前余额(含 initialBalance、估值账户特殊口径),一次 SQL
  /// 聚合替代逐账户 getAccountBalance(PERF-P0-04)。v42:并入调整记录。
  Future<Map<int, double>> _allAccountBalances() async {
    final accounts = await db.select(db.accounts).get();
    final aggs = await _bulkAccountAggregates();
    final adjTotals = await _bulkAdjustmentTotals();
    return {
      for (final a in accounts)
        a.id: isValuationOnlyType(a.type)
            ? a.initialBalance
            : a.initialBalance +
                (aggs[a.id]?.balanceDelta ?? 0.0) +
                (adjTotals[a.id] ?? 0.0),
    };
  }

  @override
  Future<double> getAccountBalance(int accountId) async {
    // 获取账户初始资金
    final account = await (db.select(db.accounts)
          ..where((a) => a.id.equals(accountId)))
        .getSingleOrNull();

    if (account == null) return 0.0;

    // 估值账户直接返回 initialBalance 作为当前估值
    if (isValuationOnlyType(account.type)) {
      return account.initialBalance;
    }

    // PERF-P0-04:一次 CASE 聚合(走 idx_transactions_account_time /
    // idx_transactions_to_account),替代此前两次全表物化 + Dart 累加。
    final aggs = await _bulkAccountAggregates(accountId: accountId);
    // v42:余额口径并入调整记录(带符号差额)。
    final adj = (await _bulkAdjustmentTotals(accountId: accountId))[accountId] ?? 0.0;
    return account.initialBalance + (aggs[accountId]?.balanceDelta ?? 0.0) + adj;
  }

  @override
  Future<double> getAccountGlobalBalance(int accountId) async {
    final account = await (db.select(db.accounts)
          ..where((a) => a.id.equals(accountId)))
        .getSingle();

    // 估值账户直接返回 initialBalance
    if (isValuationOnlyType(account.type)) {
      return account.initialBalance;
    }

    // PERF-P0-04:SQL 聚合。转入侧与旧实现一致(to_account_id 命中即加,
    // 不看类型)。
    final row = await db.customSelect(
      '''
      SELECT COALESCE(SUM(CASE
        WHEN account_id = ?1 AND type IN ('income', 'adjustment') THEN amount
        WHEN account_id = ?1 AND type IN ('expense', 'transfer') THEN -amount
        WHEN to_account_id = ?1 THEN amount
        ELSE 0 END), 0) AS bal_delta
        FROM transactions
       WHERE (account_id = ?1 OR to_account_id = ?1)
         AND $_kExcludeJoinedSharedLedgerSql
      ''',
      variables: [d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).getSingle();
    final adj = (await _bulkAdjustmentTotals(accountId: accountId))[accountId] ?? 0.0;
    return account.initialBalance +
        ((row.data['bal_delta'] ?? 0) as num).toDouble() +
        adj;
  }

  @override
  Future<double> getAccountBalanceInLedger(int accountId, int ledgerId) async {
    // 单账本维度:不排除共享账本(与旧实现一致);转入侧 to_account_id 命中
    // 即加,不看类型。PERF-P0-04:CASE 聚合替代全表物化。
    final row = await db.customSelect(
      '''
      SELECT COALESCE(SUM(CASE
        WHEN account_id = ?1 AND type IN ('income', 'adjustment') THEN amount
        WHEN account_id = ?1 AND type IN ('expense', 'transfer') THEN -amount
        WHEN to_account_id = ?1 THEN amount
        ELSE 0 END), 0) AS bal_delta
        FROM transactions
       WHERE (account_id = ?1 OR to_account_id = ?1)
         AND ledger_id = ?2
      ''',
      variables: [d.Variable.withInt(accountId), d.Variable.withInt(ledgerId)],
      readsFrom: {db.transactions},
    ).getSingle();
    final adj = (await _bulkAdjustmentTotals(accountId: accountId, ledgerId: ledgerId))[accountId] ?? 0.0;
    return ((row.data['bal_delta'] ?? 0) as num).toDouble() + adj;
  }

  @override
  Future<Map<int, double>> getAllAccountBalances(int ledgerId) async {
    final accounts = await (db.select(db.accounts)
          ..where((a) => a.ledgerId.equals(ledgerId)))
        .get();

    // PERF-P0-04:A×2 次全表扫描 → 1 次聚合。v42:并入调整(单账本维度)。
    final aggs = await _bulkAccountAggregates();
    final adjTotals = await _bulkAdjustmentTotals(ledgerId: ledgerId);

    final Map<int, double> balances = {};
    for (final account in accounts) {
      balances[account.id] = isValuationOnlyType(account.type)
          ? account.initialBalance
          : account.initialBalance +
              (aggs[account.id]?.balanceDelta ?? 0.0) +
              (adjTotals[account.id] ?? 0.0);
    }

    return balances;
  }

  @override
  Future<int> getTransactionCountByAccount(int accountId) async {
    // 统计作为主账户的交易数
    final mainCount = await db.customSelect(
      'SELECT COUNT(*) AS count FROM transactions WHERE account_id = ?1',
      variables: [d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).getSingle();

    // 统计作为转入账户的交易数
    final toCount = await db.customSelect(
      'SELECT COUNT(*) AS count FROM transactions WHERE to_account_id = ?1',
      variables: [d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).getSingle();

    int parseCount(dynamic v) {
      if (v is int) return v;
      if (v is BigInt) return v.toInt();
      if (v is num) return v.toInt();
      return 0;
    }

    return parseCount(mainCount.data['count']) + parseCount(toCount.data['count']);
  }

  @override
  Future<double> getAccountExpense(int accountId) async {
    // PERF-P0-04:SQL 聚合。支出口径 = 主账户侧 expense + transfer(转出),
    // 排除共享账本与 excludeFromStats。
    final row = await db.customSelect(
      '''
      SELECT COALESCE(SUM(amount), 0) AS v
        FROM transactions
       WHERE account_id = ?1
         AND type IN ('expense', 'transfer')
         AND exclude_from_stats = 0
         AND $_kExcludeJoinedSharedLedgerSql
      ''',
      variables: [d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).getSingle();
    return ((row.data['v'] ?? 0) as num).toDouble();
  }

  @override
  Future<double> getAccountIncome(int accountId) async {
    // PERF-P0-04:SQL 聚合。收入口径 = 主账户侧 income + 转入侧 transfer,
    // 排除共享账本与 excludeFromStats。
    final row = await db.customSelect(
      '''
      SELECT COALESCE((
        SELECT SUM(amount) FROM transactions
         WHERE account_id = ?1 AND type = 'income'
           AND exclude_from_stats = 0
           AND $_kExcludeJoinedSharedLedgerSql
      ), 0) + COALESCE((
        SELECT SUM(amount) FROM transactions
         WHERE to_account_id = ?1 AND type = 'transfer'
           AND exclude_from_stats = 0
           AND $_kExcludeJoinedSharedLedgerSql
      ), 0) AS v
      ''',
      variables: [d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).getSingle();
    return ((row.data['v'] ?? 0) as num).toDouble();
  }

  @override
  Future<({double balance, double expense, double income})> getAccountStats(int accountId) async {
    // PERF-P0-04:3 次全表扫描 → 1 次聚合。v42:balance 并入调整记录。
    final account = await getAccount(accountId);
    final aggs = await _bulkAccountAggregates(accountId: accountId);
    final a = aggs[accountId];

    final double balance;
    if (account == null) {
      balance = 0.0;
    } else if (isValuationOnlyType(account.type)) {
      balance = account.initialBalance;
    } else {
      final adj =
          (await _bulkAdjustmentTotals(accountId: accountId))[accountId] ?? 0.0;
      balance = account.initialBalance + (a?.balanceDelta ?? 0.0) + adj;
    }
    return (balance: balance, expense: a?.expense ?? 0.0, income: a?.income ?? 0.0);
  }

  @override
  Future<Map<int, ({double balance, double expense, double income})>> getAllAccountStats() async {
    // PERF-P0-04:A×3 次全表扫描(A×5 次查询)→ 2 次查询(账户表 + 1 条聚合)。
    final accounts = await db.select(db.accounts).get();
    final aggs = await _bulkAccountAggregates();
    final adjTotals = await _bulkAdjustmentTotals();

    final Map<int, ({double balance, double expense, double income})> stats = {};
    for (final account in accounts) {
      final a = aggs[account.id];
      final balance = isValuationOnlyType(account.type)
          ? account.initialBalance
          : account.initialBalance +
              (a?.balanceDelta ?? 0.0) +
              (adjTotals[account.id] ?? 0.0);
      stats[account.id] = (
        balance: balance,
        expense: a?.expense ?? 0.0,
        income: a?.income ?? 0.0,
      );
    }

    return stats;
  }

  @override
  /// ⚠️ 多币种口径未处理:本方法跨所有账本/账户按 type 裸加 amount。当前
  /// 无 UI 消费(allAccountsTotalStatsProvider 是死代码),故不影响任何界面。
  /// 若将来接「全局总收支」卡片:这是跨账本汇总,正确口径是按各账户币种
  /// rate 折算到用户主币种(同净值卡 convertedNetWorth),**不是** nativeAmount
  /// (各账本本位币可能不同,nativeAmount 相加无意义)。届时须重写,勿直接
  /// 套账本维度的 nativeAmount 折算。
  Future<({double totalBalance, double totalExpense, double totalIncome})> getAllAccountsTotalStats() async {
    final accounts = await db.select(db.accounts).get();

    // 总余额 = 所有账户余额之和（转账不影响总余额）
    // PERF-P0-04:逐账户 getAccountBalance(A 次全表扫)→ 1 次聚合。
    final balances = await _allAccountBalances();
    double totalBalance = 0.0;
    for (final account in accounts) {
      totalBalance += balances[account.id] ?? 0.0;
    }

    // 总收入/支出：直接从交易表查询，排除转账类型
    final accountIds = accounts.map((a) => a.id).toSet();

    // 收入/支出排除不计入收支的交易(余额不受影响,见上方 totalBalance)
    final sharedIds = await _sharedLedgerIds();
    final allTxs = await (db.select(db.transactions)
          ..where((t) =>
              t.accountId.isNotNull() &
              t.ledgerId.isNotIn(sharedIds) &
              t.excludeFromStats.equals(false)))
        .get();

    double totalIncome = 0.0;
    double totalExpense = 0.0;

    for (final t in allTxs) {
      // 只统计属于已有账户的交易
      if (t.accountId != null && accountIds.contains(t.accountId)) {
        if (t.type == 'income') {
          totalIncome += t.amount;
        } else if (t.type == 'expense') {
          totalExpense += t.amount;
        }
        // 转账类型不计入总收入/支出
      }
    }

    return (totalBalance: totalBalance, totalExpense: totalExpense, totalIncome: totalIncome);
  }

  @override
  Future<Map<int, int>> getAccountUsageInLedgers(int accountId) async {
    final result = await db.customSelect(
      '''
      SELECT ledger_id, COUNT(*) as count
      FROM transactions
      WHERE account_id = ? OR to_account_id = ?
      GROUP BY ledger_id
      ''',
      variables: [d.Variable.withInt(accountId), d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).get();

    final Map<int, int> usage = {};
    for (final row in result) {
      final ledgerId = row.data['ledger_id'] as int;
      final count = row.data['count'];

      int countInt = 0;
      if (count is int) {
        countInt = count;
      } else if (count is BigInt) {
        countInt = count.toInt();
      } else if (count is num) {
        countInt = count.toInt();
      }

      usage[ledgerId] = countInt;
    }

    return usage;
  }

  @override
  Future<int> migrateAccount({
    required int fromAccountId,
    required int toAccountId,
  }) async {
    final beforeCount = await getTransactionCountByAccount(fromAccountId);

    // 迁移作为主账户的交易
    await (db.update(db.transactions)
          ..where((t) => t.accountId.equals(fromAccountId)))
        .write(TransactionsCompanion(accountId: d.Value(toAccountId)));

    // 迁移作为转入账户的交易
    await (db.update(db.transactions)
          ..where((t) => t.toAccountId.equals(fromAccountId)))
        .write(TransactionsCompanion(toAccountId: d.Value(toAccountId)));

    return beforeCount;
  }

  @override
  Future<bool> hasTransactions(int accountId) async {
    final count = await db.customSelect(
      'SELECT COUNT(*) as count FROM transactions WHERE account_id = ? OR to_account_id = ?',
      variables: [d.Variable.withInt(accountId), d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).getSingle();

    final c = count.data['count'];
    if (c is int) return c > 0;
    if (c is BigInt) return c > BigInt.zero;
    if (c is num) return c > 0;
    return false;
  }

  @override
  Stream<Account?> watchAccount(int accountId) {
    return (db.select(db.accounts)..where((a) => a.id.equals(accountId)))
        .watchSingleOrNull();
  }

  @override
  Stream<List<Transaction>> watchAccountTransactions(int accountId) {
    return (db.select(db.transactions)
          ..where((t) => t.accountId.equals(accountId) | t.toAccountId.equals(accountId))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ]))
        .watch();
  }

  @override
  Future<void> batchInsertAccounts(List<AccountsCompanion> accounts) async {
    await db.batch((batch) {
      batch.insertAll(db.accounts, accounts);
    });
  }

  @override
  Future<List<Account>> getAccountsByIds(List<int> accountIds) async {
    if (accountIds.isEmpty) return [];
    return await (db.select(db.accounts)
          ..where((a) => a.id.isIn(accountIds)))
        .get();
  }

  @override
  Future<void> updateAccountSortOrders(
      List<({int id, int sortOrder})> updates) async {
    await db.transaction(() async {
      for (final update in updates) {
        await (db.update(db.accounts)..where((a) => a.id.equals(update.id)))
            .write(AccountsCompanion(sortOrder: d.Value(update.sortOrder)));
      }
    });
  }

  @override
  Future<List<Transaction>> getAccountTransactions(
    int accountId, {int limit = 50, int offset = 0, String? flow}) async {
    // flow 过滤按资金流向:支出视图含转出,收入视图含转入,null 为全部
    final where = switch (flow) {
      'expense' => "account_id = ?1 AND type IN ('expense', 'transfer')",
      'income' =>
        "(type = 'income' AND account_id = ?1) OR (type = 'transfer' AND to_account_id = ?1)",
      _ => 'account_id = ?1 OR to_account_id = ?1',
    };
    final results = await db.customSelect(
      '''
      SELECT * FROM transactions
      WHERE ($where) AND $_kExcludeJoinedSharedLedgerSql
      ORDER BY happened_at DESC
      LIMIT ?2 OFFSET ?3
      ''',
      variables: [
        d.Variable.withInt(accountId),
        d.Variable.withInt(limit),
        d.Variable.withInt(offset),
      ],
      readsFrom: {db.transactions},
    ).get();

    return results.map((row) {
      return Transaction(
        id: row.data['id'] as int,
        ledgerId: row.data['ledger_id'] as int,
        type: row.data['type'] as String,
        amount: (row.data['amount'] as num).toDouble(),
        categoryId: row.data['category_id'] as int?,
        accountId: row.data['account_id'] as int?,
        toAccountId: row.data['to_account_id'] as int?,
        happenedAt: DateTime.fromMillisecondsSinceEpoch(
            (row.data['happened_at'] as int) * 1000),
        note: row.data['note'] as String?,
        recurringId: row.data['recurring_id'] as int?,
        syncId: row.data['sync_id'] as String?,
        excludeFromStats: (row.data['exclude_from_stats'] as int? ?? 0) != 0,
        excludeFromBudget: (row.data['exclude_from_budget'] as int? ?? 0) != 0,
      );
    }).toList();
  }

  @override
  Future<List<({DateTime date, double balance})>> getAccountDailyBalances(
    int accountId, {required DateTime startDate, required DateTime endDate}) async {
    final account = await getAccount(accountId);
    if (account == null) return [];

    // 估值账户：每天返回固定估值
    if (isValuationOnlyType(account.type)) {
      final result = <({DateTime date, double balance})>[];
      var currentDate = DateTime(startDate.year, startDate.month, startDate.day);
      final end = DateTime(endDate.year, endDate.month, endDate.day);
      while (!currentDate.isAfter(end)) {
        result.add((date: currentDate, balance: account.initialBalance));
        currentDate = currentDate.add(const Duration(days: 1));
      }
      return result;
    }

    // 获取 endDate **当天结束**之前的所有交易(按日期升序,排除共享账本)。
    // endDate 语义是「含当天」:调用方(trendTodayAnchor)传当天 0 点,若用
    // <= endDate 会把当天发生的交易全部截掉 —— 趋势终点永远停在"昨晚为止",
    // 今天记的账不进趋势线。
    final endExclusive = DateTime(endDate.year, endDate.month, endDate.day)
        .add(const Duration(days: 1));
    final sharedIds = await _sharedLedgerIds();
    final allTxs = await (db.select(db.transactions)
          ..where((t) => t.accountId.equals(accountId) | t.toAccountId.equals(accountId))
          ..where((t) => t.happenedAt.isSmallerThanValue(endExclusive))
          ..where((t) => t.ledgerId.isNotIn(sharedIds))
          ..orderBy([(t) => d.OrderingTerm(expression: t.happenedAt)]))
        .get();

    // v42:调整记录并入回放(排除共享账本,与交易同口径)。
    final adjRows = await (db.select(db.accountAdjustments)
          ..where((a) => a.accountId.equals(accountId))
          ..where((a) => a.happenedAt.isSmallerThanValue(endExclusive))
          ..where((a) => a.ledgerId.isNotIn(sharedIds))
          ..orderBy([(a) => d.OrderingTerm(expression: a.happenedAt)]))
        .get();
    // (happenedAt, 交易|null, 带符号值):null = 调整事件,直接叠加;
    // 交易事件按 type 分支处理。按时间排序回放。
    final merged = <(DateTime, Transaction?, double)>[
      for (final tx in allTxs) (tx.happenedAt, tx, 0.0),
      for (final adj in adjRows) (adj.happenedAt, null, adj.amount),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    // 计算 startDate 之前的余额
    var runningBalance = account.initialBalance;
    int ei = 0;

    void applyEvent((DateTime, Transaction?, double) e) {
      final (_, tx, value) = e;
      if (tx == null) {
        runningBalance += value;
        return;
      }
      if (tx.accountId == accountId) {
        if (tx.type == 'income') {
          runningBalance += tx.amount;
        } else if (tx.type == 'expense') {
          runningBalance -= tx.amount;
        } else if (tx.type == 'transfer') {
          runningBalance -= tx.amount;
        } else if (tx.type == 'adjustment') {
          runningBalance += tx.amount;
        }
      }
      if (tx.toAccountId == accountId && tx.type == 'transfer') {
        runningBalance += tx.amount;
      }
    }

    // 先累加 startDate 之前的事件
    while (ei < merged.length && merged[ei].$1.isBefore(startDate)) {
      applyEvent(merged[ei]);
      ei++;
    }

    // 按天填充
    final result = <({DateTime date, double balance})>[];
    var currentDate = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(endDate.year, endDate.month, endDate.day);

    while (!currentDate.isAfter(end)) {
      final nextDate = currentDate.add(const Duration(days: 1));

      // 累加当天的事件
      while (ei < merged.length && merged[ei].$1.isBefore(nextDate)) {
        applyEvent(merged[ei]);
        ei++;
      }

      result.add((date: currentDate, balance: runningBalance));
      currentDate = nextDate;
    }

    return result;
  }

  @override
  Future<List<({int? id, String name, String? icon, double total})>>
      getAccountCategoryStats(int accountId, {required String type}) async {
    final results = await db.customSelect(
      '''
      SELECT c.id, c.name, c.icon, SUM(t.amount) as total
      FROM transactions t
      LEFT JOIN categories c ON t.category_id = c.id
      WHERE t.account_id = ?1 AND t.type = ?2
        AND t.$_kExcludeJoinedSharedLedgerSql
      GROUP BY c.id
      ORDER BY total DESC
      ''',
      variables: [
        d.Variable.withInt(accountId),
        d.Variable.withString(type),
      ],
      readsFrom: {db.transactions, db.categories},
    ).get();

    return results.map((row) {
      return (
        id: row.data['id'] as int?,
        name: (row.data['name'] as String?) ?? '未分类',
        icon: row.data['icon'] as String?,
        total: (row.data['total'] as num).toDouble(),
      );
    }).toList();
  }

  @override
  Future<({double totalAssets, double totalLiabilities, double netWorth})> getNetWorthBreakdown() async {
    final accounts = await getAllAccounts();
    // PERF-P0-04:1 次聚合替代逐账户 getAccountBalance。
    final balances = await _allAccountBalances();
    double totalAssets = 0.0;
    double totalLiabilities = 0.0;

    for (final account in accounts) {
      final balance = balances[account.id] ?? 0.0;
      if (isAssetType(account.type)) {
        totalAssets += balance;
      } else {
        totalLiabilities += balance;
      }
    }

    return (
      totalAssets: totalAssets,
      totalLiabilities: totalLiabilities,
      netWorth: totalAssets + totalLiabilities,
    );
  }

  @override
  Future<Map<String, ({double totalAssets, double totalLiabilities, double netWorth})>> getNetWorthBreakdownByCurrency() async {
    final accounts = await getAllAccounts();
    final balances = await _allAccountBalances();
    final Map<String, ({double totalAssets, double totalLiabilities, double netWorth})> result = {};

    for (final account in accounts) {
      final balance = balances[account.id] ?? 0.0;
      final currency = account.currency.toUpperCase();
      final prev = result[currency] ?? (totalAssets: 0.0, totalLiabilities: 0.0, netWorth: 0.0);

      if (isAssetType(account.type)) {
        result[currency] = (
          totalAssets: prev.totalAssets + balance,
          totalLiabilities: prev.totalLiabilities,
          netWorth: prev.netWorth + balance,
        );
      } else {
        result[currency] = (
          totalAssets: prev.totalAssets,
          totalLiabilities: prev.totalLiabilities + balance,
          netWorth: prev.netWorth + balance,
        );
      }
    }

    return result;
  }

  @override
  Future<List<({DateTime date, double balance})>> getNetWorthDailyBalances({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final accounts = await getAllAccounts();
    if (accounts.isEmpty) return [];

    // 获取每个账户的每日余额
    final allBalances = <int, List<({DateTime date, double balance})>>{};
    for (final account in accounts) {
      allBalances[account.id] = await getAccountDailyBalances(
        account.id,
        startDate: startDate,
        endDate: endDate,
      );
    }

    // 按日聚合
    final result = <({DateTime date, double balance})>[];
    var currentDate = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(endDate.year, endDate.month, endDate.day);
    int dayIndex = 0;

    while (!currentDate.isAfter(end)) {
      double dayTotal = 0.0;
      for (final account in accounts) {
        final balances = allBalances[account.id]!;
        if (dayIndex < balances.length) {
          dayTotal += balances[dayIndex].balance;
        }
      }
      result.add((date: currentDate, balance: dayTotal));
      currentDate = currentDate.add(const Duration(days: 1));
      dayIndex++;
    }

    return result;
  }

  @override
  Future<List<({DateTime date, double assets, double liabilities, double net})>>
      getNetWorthTrendSeries({
    required DateTime startDate,
    required DateTime endDate,
    required Map<String, double> ratesToBase,
  }) async {
    final accounts = await getAllAccounts();
    if (accounts.isEmpty) return [];

    final allBalances = <int, List<({DateTime date, double balance})>>{};
    for (final account in accounts) {
      allBalances[account.id] =
          await getAccountDailyBalances(account.id, startDate: startDate, endDate: endDate);
    }

    final result = <({DateTime date, double assets, double liabilities, double net})>[];
    var currentDate = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(endDate.year, endDate.month, endDate.day);
    int dayIndex = 0;
    while (!currentDate.isAfter(end)) {
      double assets = 0.0, liabilities = 0.0;
      for (final account in accounts) {
        final balances = allBalances[account.id]!;
        if (dayIndex < balances.length) {
          // 折算到主币种:缺汇率的币种整条剔除(与净资产卡同口径,绝不按 1.0 裸加)。
          final rate = ratesToBase[account.currency.toUpperCase()];
          if (rate == null) continue;
          final bal = balances[dayIndex].balance * rate;
          if (isAssetType(account.type)) {
            assets += bal;
          } else {
            liabilities += bal;
          }
        }
      }
      result.add((date: currentDate, assets: assets, liabilities: liabilities, net: assets + liabilities));
      currentDate = currentDate.add(const Duration(days: 1));
      dayIndex++;
    }
    return result;
  }

  @override
  Future<List<({String type, double totalBalance})>> getAssetCompositionByType() async {
    final accounts = await getAllAccounts();
    final balances = await _allAccountBalances();
    final Map<String, double> typeBalances = {};

    for (final account in accounts) {
      final balance = balances[account.id] ?? 0.0;
      typeBalances.update(account.type, (v) => v + balance, ifAbsent: () => balance);
    }

    return typeBalances.entries
        .map((e) => (type: e.key, totalBalance: e.value))
        .toList();
  }

  @override
  Future<List<({String type, String currency, double totalBalance})>>
      getAssetCompositionByTypeAndCurrency() async {
    final accounts = await getAllAccounts();
    final balances = await _allAccountBalances();
    // (type, currency 大写) -> 余额累加
    final Map<({String type, String currency}), double> balancesByKey = {};

    for (final account in accounts) {
      final balance = balances[account.id] ?? 0.0;
      final key = (type: account.type, currency: account.currency.toUpperCase());
      balancesByKey.update(key, (v) => v + balance, ifAbsent: () => balance);
    }

    return balancesByKey.entries
        .map((e) => (
              type: e.key.type,
              currency: e.key.currency,
              totalBalance: e.value,
            ))
        .toList();
  }

  @override
  Future<void> updateAccountValuation(int accountId, double newValue) async {
    await (db.update(db.accounts)..where((a) => a.id.equals(accountId))).write(
      AccountsCompanion(
        initialBalance: d.Value(newValue),
        updatedAt: d.Value(DateTime.now()),
      ),
    );
  }

  // ============================================
  // 余额调整记录(v42)— 独立实体,不进收支统计
  // ============================================

  @override
  Future<int> addAccountAdjustment({
    required int ledgerId,
    required int accountId,
    required double amount,
    double? balanceBefore,
    double? balanceAfter,
    DateTime? happenedAt,
    String? note,
  }) async {
    final now = DateTime.now();
    return await db.into(db.accountAdjustments).insert(
          AccountAdjustmentsCompanion.insert(
            syncId: d.Value(_uuid.v4()),
            ledgerId: ledgerId,
            accountId: accountId,
            amount: amount,
            balanceBefore: d.Value(balanceBefore),
            balanceAfter: d.Value(balanceAfter),
            happenedAt: d.Value(happenedAt ?? now),
            recordedAt: d.Value(now),
            note: d.Value(note),
            createdAt: d.Value(now),
            updatedAt: d.Value(now),
          ),
        );
  }

  @override
  Future<List<AccountAdjustment>> getAccountAdjustments(int accountId,
      {int limit = 200}) async {
    return await (db.select(db.accountAdjustments)
          ..where((a) => a.accountId.equals(accountId))
          ..orderBy([
            (a) => d.OrderingTerm(
                expression: a.happenedAt, mode: d.OrderingMode.desc),
            (a) => d.OrderingTerm(
                expression: a.id, mode: d.OrderingMode.desc),
          ])
          ..limit(limit))
        .get();
  }

  /// 全部账户的调整总额(带符号),按账户 id 索引。余额口径 =
  /// initial + Σ交易 + Σ调整(v42)。ledgerId 非空时按账本过滤(单账本维度),
  /// 否则跨账本(共享账本排除条件与交易侧一致)。
  Future<Map<int, double>> _bulkAdjustmentTotals(
      {int? accountId, int? ledgerId}) async {
    final conditions = <String>[];
    final variables = <d.Variable>[];
    if (accountId != null) {
      conditions.add('account_id = ?${variables.length + 1}');
      variables.add(d.Variable.withInt(accountId));
    }
    if (ledgerId != null) {
      conditions.add('ledger_id = ?${variables.length + 1}');
      variables.add(d.Variable.withInt(ledgerId));
    } else {
      // 与 _kAccountSidesCte 同口径:排除以成员身份加入的共享账本。
      conditions.add(_kExcludeJoinedSharedLedgerSql);
    }
    final rows = await db.customSelect(
      'SELECT account_id AS aid, COALESCE(SUM(amount), 0) AS adj '
      'FROM account_adjustments '
      'WHERE ${conditions.join(' AND ')} GROUP BY account_id',
      variables: variables,
      readsFrom: {db.accountAdjustments},
    ).get();
    return {
      for (final row in rows)
        row.data['aid'] as int: (row.data['adj'] as num).toDouble(),
    };
  }

  @override
  Future<SharedLedgerAccount?> getSharedAccountBySyncId(String syncId) {
    return (db.select(db.sharedLedgerAccounts)
          ..where((t) => t.syncId.equals(syncId)))
        .getSingleOrNull();
  }

  @override
  Future<Set<String>> getUsedCurrencies() async {
    final rows = await db
        .customSelect('SELECT DISTINCT currency FROM accounts')
        .get();
    return rows
        .map((r) => (r.read<String>('currency')).toUpperCase())
        .toSet();
  }
}
