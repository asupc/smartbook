import 'package:drift/drift.dart' as d;

import '../../db.dart';
import '../recurring_transaction_repository.dart';

/// 本地周期记账Repository实现
/// 基于 Drift 数据库实现
class LocalRecurringTransactionRepository implements RecurringTransactionRepository {
  final BeeDatabase db;

  LocalRecurringTransactionRepository(this.db);

  /// 缺陷 G:`recurring_transactions.amount` 此前无任何守卫(写入面无校验)。
  /// 非有限金额的模板会在每次生成轮被 `addTransaction` 的落库守卫拒绝 ——
  /// 现在模板自己也拒,把失败**提前到录入面**(编辑页能立刻报错),
  /// 而不是留到后台扫描期静默/告警。
  /// 有限的大值(用户历史数据)照旧放行:模板到交易的量级守卫在
  /// `LocalTransactionRepository.txAmountViolation`,此处只看有限性,避免
  /// 让存量超大模板值在编辑时被拒(与缺陷 E「存量豁免」同精神)。
  ///
  /// 负数**允许**:周期模板允许退款/冲销语义的负值模板(存量可能已有),
  /// 真正的方向性校验在生成落库那一刻(`expense/income/transfer` + 负值)。
  static void _assertRecurringAmount(double amount) {
    if (!amount.isFinite) {
      throw ArgumentError.value(
          amount, 'amount', '周期记账金额必须是有限数(NaN/Infinity 不能落库)');
    }
  }

  @override
  Future<List<RecurringTransaction>> getAllRecurringTransactions() async {
    return await (db.select(db.recurringTransactions)).get();
  }

  @override
  Future<List<RecurringTransaction>> getRecurringTransactionsByLedger(int ledgerId) async {
    return await (db.select(db.recurringTransactions)
          ..where((t) => t.ledgerId.equals(ledgerId)))
        .get();
  }

  @override
  Future<List<RecurringTransaction>> getEnabledRecurringTransactions(int ledgerId) async {
    return await (db.select(db.recurringTransactions)
          ..where((t) => t.ledgerId.equals(ledgerId) & t.enabled.equals(true)))
        .get();
  }

  @override
  Future<int> addRecurringTransaction({
    required int ledgerId,
    required String type,
    required double amount,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    String? note,
    required String frequency,
    required int interval,
    int? dayOfMonth,
    int? dayOfWeek,
    int? monthOfYear,
    required DateTime startDate,
    DateTime? endDate,
    bool enabled = true,
    String? currencyCode,
  }) async {
    _assertRecurringAmount(amount);
    return await db.into(db.recurringTransactions).insert(
      RecurringTransactionsCompanion.insert(
        ledgerId: ledgerId,
        type: type,
        amount: amount,
        categoryId: d.Value(categoryId),
        accountId: d.Value(accountId),
        toAccountId: d.Value(toAccountId),
        note: d.Value(note),
        frequency: frequency,
        interval: d.Value(interval),
        dayOfMonth: d.Value(dayOfMonth),
        dayOfWeek: d.Value(dayOfWeek),
        monthOfYear: d.Value(monthOfYear),
        startDate: startDate,
        endDate: d.Value(endDate),
        enabled: d.Value(enabled),
        currencyCode: d.Value(_normalizeCurrency(currencyCode)),
      ),
    );
  }

  /// 币种统一大写存储(与 transactions.currency_code 一致);空串按 null。
  static String? _normalizeCurrency(String? code) {
    if (code == null) return null;
    final trimmed = code.trim();
    return trimmed.isEmpty ? null : trimmed.toUpperCase();
  }

  @override
  Future<void> updateRecurringTransaction({
    required int id,
    required int ledgerId,
    required String type,
    required double amount,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    String? note,
    required String frequency,
    required int interval,
    int? dayOfMonth,
    int? dayOfWeek,
    int? monthOfYear,
    required DateTime startDate,
    DateTime? endDate,
    bool? enabled,
    DateTime? lastGeneratedDate,
    String? currencyCode,
  }) async {
    // 缺陷 G:同 addRecurringTransaction(仅有限性;负数放行,存量负模板
    // 仍可编辑 —— 生成落库那一刻才做方向性校验)。
    _assertRecurringAmount(amount);
    await (db.update(db.recurringTransactions)..where((t) => t.id.equals(id)))
        .write(
      RecurringTransactionsCompanion(
        ledgerId: d.Value(ledgerId),
        type: d.Value(type),
        amount: d.Value(amount),
        categoryId: d.Value(categoryId),
        accountId: d.Value(accountId),
        toAccountId: d.Value(toAccountId),
        note: d.Value(note),
        frequency: d.Value(frequency),
        interval: d.Value(interval),
        dayOfMonth: d.Value(dayOfMonth),
        dayOfWeek: d.Value(dayOfWeek),
        monthOfYear: d.Value(monthOfYear),
        startDate: d.Value(startDate),
        endDate: d.Value(endDate),
        enabled: enabled != null ? d.Value(enabled) : const d.Value.absent(),
        lastGeneratedDate: d.Value(lastGeneratedDate),
        // null 即写 NULL(改回本位币要能清掉旧外币),与本方法其它字段同语义
        currencyCode: d.Value(_normalizeCurrency(currencyCode)),
        updatedAt: d.Value(DateTime.now()),
      ),
    );
  }

  @override
  Future<void> deleteRecurringTransaction(int id) async {
    await (db.delete(db.recurringTransactions)..where((t) => t.id.equals(id)))
        .go();
  }

  @override
  Future<void> toggleRecurringTransaction(int id, bool enabled) async {
    await (db.update(db.recurringTransactions)..where((t) => t.id.equals(id)))
        .write(RecurringTransactionsCompanion(
      enabled: d.Value(enabled),
      updatedAt: d.Value(DateTime.now()),
    ));
  }

  @override
  Future<void> updateLastGeneratedDate(int id, DateTime date) async {
    await (db.update(db.recurringTransactions)..where((t) => t.id.equals(id)))
        .write(RecurringTransactionsCompanion(
      lastGeneratedDate: d.Value(date),
      updatedAt: d.Value(DateTime.now()),
    ));
  }

  @override
  Future<int> getActiveRecurringCountByAccount(int accountId) async {
    final rows = await (db.select(db.recurringTransactions)
          ..where((t) =>
              t.enabled.equals(true) &
              (t.accountId.equals(accountId) | t.toAccountId.equals(accountId))))
        .get();
    return rows.length;
  }

  @override
  Stream<List<RecurringTransaction>> watchAllRecurringTransactions() {
    return (db.select(db.recurringTransactions)).watch();
  }

  @override
  Stream<List<RecurringTransaction>> watchRecurringTransactionsByLedger(int ledgerId) {
    return (db.select(db.recurringTransactions)
          ..where((t) => t.ledgerId.equals(ledgerId)))
        .watch();
  }

  @override
  Future<void> batchInsertRecurringTransactions(
      List<RecurringTransactionsCompanion> items) async {
    // 缺陷 G:批量入口同样补齐非有限守卫(与单条同口径,缺失即整批拒)。
    for (var i = 0; i < items.length; i++) {
      final amount = items[i].amount;
      if (!amount.present) {
        throw ArgumentError('[batchInsertRecurringTransactions] 第 $i 行缺 amount');
      }
      _assertRecurringAmount(amount.value);
    }
    await db.batch((batch) {
      batch.insertAll(db.recurringTransactions, items);
    });
  }
}
