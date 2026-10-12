import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';

import '../../../cloud/sync/change_tracker.dart';
import '../../db.dart';
import '../exchange_rate_repository.dart';

/// Drift 实现。tracker 用 getter 闭包注入:LocalRepository.changeTracker 是
/// 可变字段(构造后才赋值),直接传引用会捕获 null —— 2026-04 的 orphan-change
/// 坑就是这类时序问题,闭包取值规避。
class LocalExchangeRateRepository implements ExchangeRateRepository {
  static const _uuid = Uuid();
  final BeeDatabase db;
  final ChangeTracker? Function() trackerGetter;

  LocalExchangeRateRepository(this.db, {required this.trackerGetter});

  /// 缺陷 G:`exchange_rates.rate` / `exchange_rate_overrides.rate` 是十进制
  /// **字符串**列,此前把任意文本原样落库。`invertRate` 对次正规输入会产出
  /// 字面量 `"Infinity"`(misc_recurring_currency 测试已锁定该下溢面),
  /// 字符串列不做 REAL 转换 → 该值**能落库**,消费方 `double.tryParse` 得到
  /// Infinity/NaN 后绕过 `rate <= 0` 降级(NaN 与 Infinity 都不 `<= 0`)
  /// → `computeNativeAmount` 产出非有限 nativeAmount,污染统计。
  ///
  /// 守卫口径(只拦**非有限**,不新增其它失败面):
  /// - 可解析且非有限(`"Infinity"`/`"-Infinity"`/`"NaN"`/`"1e999"`)→ 拒;
  /// - 完全不可解析(`"abc"`)→ **放行**,既有行为是消费方 `tryParse` 得 null
  ///   后显式降级(README D5:缺失就是缺失),已有 HARDENING 测试锁定;
  /// - 0 / 负值 → 放行(消费方 `rate <= 0` 显式降级)。
  static void validateRateString(String rate, String field) {
    final parsed = double.tryParse(rate.trim());
    if (parsed != null && !parsed.isFinite) {
      throw ArgumentError.value(rate, field,
          '$field 不能是 NaN/Infinity(NaN 与 Infinity 都不命中 rate<=0 降级,会污染折算)');
    }
  }

  @override
  Future<void> upsertAutoRates({
    required String base,
    required String rateDate,
    required Map<String, String> rates,
    required String source,
    required DateTime fetchedAt,
  }) async {
    final baseUp = base.toUpperCase();
    await db.batch((b) {
      for (final e in rates.entries) {
        // 缺陷 G:自动汇率同样拦截非有限字符串字面量(invertRate 下溢面)。
        validateRateString(e.value, 'rate(${e.key})');
        b.insert(
          db.exchangeRates,
          ExchangeRatesCompanion.insert(
            baseCurrency: baseUp,
            quoteCurrency: e.key.toUpperCase(),
            rateDate: rateDate,
            rate: e.value,
            source: source,
            fetchedAt: fetchedAt,
          ),
          onConflict: d.DoUpdate((_) => ExchangeRatesCompanion(
            rate: d.Value(e.value),
            source: d.Value(source),
            fetchedAt: d.Value(fetchedAt),
          )),
        );
      }
    });
    // 注意:自动汇率绝不记 change(README D2),测试有红线断言。
  }

  @override
  Future<List<ExchangeRate>> getLatestAutoRates(String base) async {
    final rows = await (db.select(db.exchangeRates)
          ..where((t) => t.baseCurrency.equals(base.toUpperCase()))
          ..orderBy([
            (t) => d.OrderingTerm.asc(t.quoteCurrency),
            (t) => d.OrderingTerm.desc(t.rateDate),
          ]))
        .get();
    final latest = <String, ExchangeRate>{};
    for (final r in rows) {
      latest.putIfAbsent(r.quoteCurrency, () => r); // 排序后每 quote 第一行即最新
    }
    return latest.values.toList();
  }

  @override
  Future<DateTime?> getLastFetchedAt(String base) async {
    final row = await (db.select(db.exchangeRates)
          ..where((t) => t.baseCurrency.equals(base.toUpperCase()))
          ..orderBy([(t) => d.OrderingTerm.desc(t.fetchedAt)])
          ..limit(1))
        .getSingleOrNull();
    return row?.fetchedAt;
  }

  @override
  Future<List<ExchangeRateOverride>> getOverrides(String base) {
    return (db.select(db.exchangeRateOverrides)
          ..where((t) => t.baseCurrency.equals(base.toUpperCase()))
          ..orderBy([(t) => d.OrderingTerm.asc(t.quoteCurrency)]))
        .get();
  }

  @override
  Stream<List<ExchangeRateOverride>> watchOverrides(String base) {
    return (db.select(db.exchangeRateOverrides)
          ..where((t) => t.baseCurrency.equals(base.toUpperCase()))
          ..orderBy([(t) => d.OrderingTerm.asc(t.quoteCurrency)]))
        .watch();
  }

  @override
  Future<void> setOverride({
    required String base,
    required String quote,
    required String rate,
  }) async {
    // 缺陷 G:手动汇率同补守卫(用户输入框可粘贴 "Infinity"/"NaN")。
    validateRateString(rate, 'rate');
    final baseUp = base.toUpperCase();
    final quoteUp = quote.toUpperCase();
    final existing = await (db.select(db.exchangeRateOverrides)
          ..where((t) =>
              t.baseCurrency.equals(baseUp) & t.quoteCurrency.equals(quoteUp)))
        .getSingleOrNull();
    final now = DateTime.now().toUtc();
    if (existing == null) {
      final syncId = _uuid.v4();
      final id = await db.into(db.exchangeRateOverrides).insert(
            ExchangeRateOverridesCompanion.insert(
              baseCurrency: baseUp,
              quoteCurrency: quoteUp,
              rate: rate,
              syncId: d.Value(syncId),
              updatedAt: d.Value(now),
            ),
          );
      await trackerGetter()?.recordUserGlobalChange(
        entityType: 'exchange_rate_override',
        entityId: id,
        entitySyncId: syncId,
        action: 'create',
      );
    } else {
      final syncId = existing.syncId ?? _uuid.v4();
      await (db.update(db.exchangeRateOverrides)
            ..where((t) => t.id.equals(existing.id)))
          .write(ExchangeRateOverridesCompanion(
        rate: d.Value(rate),
        syncId: d.Value(syncId),
        updatedAt: d.Value(now),
      ));
      await trackerGetter()?.recordUserGlobalChange(
        entityType: 'exchange_rate_override',
        entityId: existing.id,
        entitySyncId: syncId,
        action: 'update',
      );
    }
  }

  @override
  Future<void> removeOverride({required String base, required String quote}) async {
    final existing = await (db.select(db.exchangeRateOverrides)
          ..where((t) =>
              t.baseCurrency.equals(base.toUpperCase()) &
              t.quoteCurrency.equals(quote.toUpperCase())))
        .getSingleOrNull();
    if (existing == null) return;
    await (db.delete(db.exchangeRateOverrides)
          ..where((t) => t.id.equals(existing.id)))
        .go();
    final syncId = existing.syncId;
    if (syncId != null) {
      await trackerGetter()?.recordUserGlobalChange(
        entityType: 'exchange_rate_override',
        entityId: existing.id,
        entitySyncId: syncId,
        action: 'delete',
      );
    }
  }
}
