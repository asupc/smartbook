import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';

/// M3-1 验收:索引在「新装」和「升级」两条路径上必须完全一致,并且自动记账
/// 判重的那条查询要真的走到 `idx_transactions_ledger_type_time`。
///
/// 回归价值:v39 之前有几张表的索引只在 onUpgrade 分支里建过 —— 老用户升级
/// 有索引,新用户全新安装反而没有。索引缺失不报错、只是慢,靠人看不出来,
/// 所以用测试钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// `_ensureIndexes()` 应该建出来的全部索引名。新增索引时这里一起加,
  /// 两条路径会同时被校验。
  const expected = <String>{
    'idx_transactions_ledger_time',
    'idx_transactions_ledger_type_time',
    'idx_transactions_sync_id',
    'idx_transaction_tags_transaction',
    'idx_transaction_tags_tag',
    'idx_attachments_transaction',
    'idx_auto_book_state_retry',
    'idx_auto_book_items_semantic',
    'idx_accounts_sync_id',
    'idx_categories_sync_id',
    'idx_tags_sync_id',
    'idx_ledgers_sync_id',
    'idx_budgets_sync_id',
    'idx_budgets_ledger',
    'idx_budgets_category',
    'idx_budgets_ledger_type',
  };

  Future<Set<String>> indexNames(BeeDatabase db) async {
    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='index'")
        .get();
    return rows.map((r) => r.read<String>('name')).toSet();
  }

  test('新装:onCreate 建出全部索引', () async {
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    expect(await indexNames(db), containsAll(expected));
  });

  test('升级:索引缺失的旧库重新打开后补齐', () async {
    // 内存库随连接销毁,升级路径必须落到文件才能「关掉再打开」。
    final dir = await Directory.systemTemp.createTemp('smartbook_idx_test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/upgrade.sqlite');

    // 1. 先用当前 schema 建库(拿到 v40 的全部表),再把索引全删掉、版本退回
    //    38,模拟「表结构是新的、索引没建过」的历史库。
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    for (final name in await indexNames(seed)) {
      if (name.startsWith('idx_')) {
        await seed.customStatement('DROP INDEX IF EXISTS $name;');
      }
    }
    await seed.customStatement('PRAGMA user_version = 38;');
    expect(
      (await indexNames(seed)).where((n) => n.startsWith('idx_')),
      isEmpty,
    );
    await seed.close();

    // 2. 重新打开 → onUpgrade(38 → 40,含 v39 索引统一与 v40 记录时间列) 末尾无条件跑 _ensureIndexes()。
    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    final version = await db.customSelect('PRAGMA user_version').getSingle();

    expect(version.read<int>('user_version'), 40);
    expect(await indexNames(db), containsAll(expected));
  });

  test('判重候选查询命中 idx_transactions_ledger_type_time', () async {
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // 与 LocalTransactionRepository.getDedupCandidates 同形:账本 + 类型 +
    // 时间窗 + 金额区间,按时间倒序取前 N 条。
    final query = db.select(db.transactions)
      ..where((t) =>
          t.ledgerId.equals(1) &
          t.type.equals('expense') &
          t.happenedAt
              .isBetweenValues(DateTime(2026, 1, 1), DateTime(2026, 4, 1)) &
          (t.amount.isBetweenValues(9.9, 10.1) |
              t.amount.isBetweenValues(-10.1, -9.9)))
      ..orderBy([
        (t) => OrderingTerm(expression: t.happenedAt, mode: OrderingMode.desc)
      ])
      ..limit(200);
    final sql = query.constructQuery();
    final plan = await db
        .customSelect('EXPLAIN QUERY PLAN ${sql.buffer}',
            variables: sql.introducedVariables)
        .get();
    final detail = plan.map((r) => r.read<String>('detail')).join(' | ');

    expect(detail, contains('idx_transactions_ledger_type_time'));
    // 索引本身带 happened_at DESC,排序不该再落到临时 B-tree。
    expect(detail, isNot(contains('TEMP B-TREE')));
  });
}
