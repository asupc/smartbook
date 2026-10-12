// 对抗性测试 — 迁移域(SmartBook 客户端数据层)。
//
// 攻击面:schemaVersion 与 migration 链、跳版本升级、半迁移库重跑(幂等)、
// 旧数据 NULL 列被新查询命中/漏掉、索引双路径一致、CHECK 约束在两种路径上一致。
//
// 参照(只读):
//   lib/data/db.dart 的 migration strategy(:627-1477)与 _ensureIndexes(:1491)
//   test/data/migration_v30_test.dart、test/data/indexes_migration_test.dart、
//   test/data/raw_evidence_migration_test.dart(既有模式)
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // ══════════════════════════════════════════════════════════════════════
  // Q. schemaVersion 与迁移入口
  // ══════════════════════════════════════════════════════════════════════

  test('Q1 schemaVersion = 45(v45 syncId 唯一索引;v43 回收站 + v44 目标快照)', () async {
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    // HARDENING: 版本号即契约;改这里必须同时补 migration 分支。
    expect(db.schemaVersion, 45);
    final v = await db.customSelect('PRAGMA user_version').getSingle();
    expect(v.read<int>('user_version'), 45,
        reason: 'HARDENING: onset 前 drift 已写 user_version');
  });

  test('Q2 新装库:onCreate 建出 24 张业务表 + 全部索引', () async {
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final tables = (await db
            .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
            .get())
        .map((r) => r.read<String>('name'))
        .where((n) => !n.startsWith('sqlite_'))
        .toSet();
    // HARDENING: onCreate 走 m.createAll() → 全部 @DriftDatabase(tables:[...])
    // 的表都在(db.dart:588-614 共 24 张)。
    expect(
        tables,
        containsAll(const [
          'ledgers', 'accounts', 'categories', 'transactions',
          'recurring_transactions', 'conversations', 'messages', 'tags',
          'transaction_tags', 'budgets', 'transaction_attachments',
          'local_changes', 'sync_state', 'ledger_members',
          'shared_ledger_categories', 'shared_ledger_accounts',
          'shared_ledger_tags', 'transaction_tag_overrides',
          'sync_pull_errors', 'exchange_rates', 'exchange_rate_overrides',
          'auto_book_events', 'auto_book_event_items', 'account_adjustments',
          'deleted_transactions',
        ]));
    expect(tables.length, 25, reason: 'HARDENING: 25 张(含 v43 deleted_transactions)');

    final indexes = (await db
            .customSelect(
                "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'")
            .get())
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(indexes, contains('idx_rate_override_pair'),
        reason: 'HARDENING: onCreate 里显式建汇率唯一索引(db.dart:1472-1474)');
    expect(indexes, contains('idx_transactions_ledger_time_id'));
  });

  // ══════════════════════════════════════════════════════════════════════
  // R. 跳版本升级(老版本 → 最新)
  // ══════════════════════════════════════════════════════════════════════

  test('R1 from=21 -> 45:跳 24 个版本,全链路补齐且旧数据不丢', () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_r1');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/old.sqlite');

    // 反向构造老库:用当前 schema 建库,再删掉 v21 之后新增的**列与表**,
    // 最后退回 user_version=21。比手写 DDL 更可靠(列集合一定与实际一致)。
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    // SQLite 的 DROP COLUMN 会因依赖该列的索引而失败 —— 清掉全部 idx_*
    // (v21 时代的库本来也不会有 v22 之后新建的索引)。
    for (final n in (await seed
            .customSelect(
                "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'")
            .get())
        .map((r) => r.read<String>('name'))) {
      await seed.customStatement('DROP INDEX IF EXISTS $n');
    }
    await seed.customStatement('ALTER TABLE budgets DROP COLUMN sync_id');
    await seed.customStatement('ALTER TABLE ledgers DROP COLUMN month_start_day');
    await seed.customStatement('ALTER TABLE accounts DROP COLUMN hidden');
    await seed.customStatement(
        'ALTER TABLE recurring_transactions DROP COLUMN currency_code');
    for (final c in const [
      'created_by_user_id', 'last_edited_by_user_id',
      'category_sync_id_override', 'account_sync_id_override',
      'to_account_sync_id_override', 'tag_sync_ids_override',
    ]) {
      await seed.customStatement('ALTER TABLE transactions DROP COLUMN $c');
    }
    await seed.customStatement('ALTER TABLE ledgers DROP COLUMN my_role');
    await seed.customStatement('ALTER TABLE ledgers DROP COLUMN member_count');
    await seed.customStatement('ALTER TABLE ledgers DROP COLUMN is_shared');
    await seed.customStatement('ALTER TABLE ledgers DROP COLUMN owner_user_id');
    await seed.customStatement(
        'ALTER TABLE transactions DROP COLUMN exclude_from_stats');
    await seed.customStatement(
        'ALTER TABLE transactions DROP COLUMN exclude_from_budget');
    await seed.customStatement('ALTER TABLE transactions DROP COLUMN currency_code');
    await seed.customStatement('ALTER TABLE transactions DROP COLUMN native_amount');
    await seed.customStatement('ALTER TABLE transactions DROP COLUMN recorded_at');
    for (final t in const [
      'ledger_members', 'shared_ledger_categories', 'shared_ledger_accounts',
      'shared_ledger_tags', 'transaction_tag_overrides', 'sync_pull_errors',
      'exchange_rates', 'exchange_rate_overrides', 'auto_book_event_items',
      'auto_book_events', 'account_adjustments', 'deleted_transactions',
    ]) {
      await seed.customStatement('DROP TABLE IF EXISTS $t');
    }
    await seed.customStatement(
        "INSERT INTO ledgers (id, name, currency, created_at, sync_id) "
        "VALUES (1, 'old', 'USD', 1700000000, 'LEDGER-OLD')");
    await seed.customStatement(
        "INSERT INTO accounts (id, ledger_id, name, currency, initial_balance, sync_id) "
        "VALUES (10, 1, 'oldacc', 'USD', 123.45, 'ACC-OLD')");
    await seed.customStatement(
        "INSERT INTO categories (id, name, kind, sync_id) "
        "VALUES (20, 'food', 'expense', 'CAT-OLD')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, account_id, category_id, "
        "happened_at, sync_id) "
        "VALUES (100, 1, 'expense', 12.5, 10, 20, 1783008000, 'TX-OLD')");
    await seed.customStatement('PRAGMA user_version = 21');
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    final v = await db.customSelect('PRAGMA user_version').getSingle();
    expect(v.read<int>('user_version'), 45, reason: 'HARDENING: 升到最新');

    final tx = await db
        .customSelect('SELECT * FROM transactions WHERE id = 100')
        .getSingle();
    expect(tx.read<double>('amount'), 12.5);
    expect(tx.read<String>('sync_id'), 'TX-OLD');
    expect(tx.readNullable<String>('currency_code'), 'USD',
        reason: 'HARDENING: v30 回填取账户币种');
    expect(tx.readNullable<double>('native_amount'), 12.5,
        reason: 'HARDENING: v30 native_amount = amount');
    expect(tx.read<int>('exclude_from_stats'), 0);
    expect(tx.readNullable<int>('recorded_at'), isNull,
        reason: 'HARDENING: v40 不回填,NULL = 老数据 UI 显示 "-"');

    final led = await db
        .customSelect('SELECT month_start_day, my_role, is_shared FROM ledgers')
        .getSingle();
    expect(led.read<int>('month_start_day'), 1, reason: 'HARDENING: v27 默认 1');
    expect(led.read<String>('my_role'), 'owner', reason: 'HARDENING: v24 默认 owner');
    expect(led.read<int>('is_shared'), 0);
    final acc = await db
        .customSelect('SELECT hidden, ledger_id FROM accounts').getSingle();
    expect(acc.read<int>('hidden'), 0, reason: 'HARDENING: v31 默认 0');

    final tables = (await db
            .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
            .get())
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(
        tables,
        containsAll(const [
          'deleted_transactions', 'account_adjustments', 'exchange_rates',
          'exchange_rate_overrides', 'auto_book_events', 'sync_pull_errors',
          'shared_ledger_categories', 'transaction_tag_overrides',
        ]));
  });

  test('R2 跳版本升级后:新查询能命中旧数据(列回填口径正确)', () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_r2');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/old2.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement('ALTER TABLE transactions DROP COLUMN currency_code');
    await seed.customStatement('ALTER TABLE transactions DROP COLUMN native_amount');
    await seed.customStatement('ALTER TABLE transactions DROP COLUMN recorded_at');
    await seed.customStatement('ALTER TABLE ledgers DROP COLUMN month_start_day');
    await seed.customStatement('ALTER TABLE accounts DROP COLUMN hidden');
    for (final t in const [
      'auto_book_events', 'auto_book_event_items', 'account_adjustments',
      'deleted_transactions',
    ]) {
      await seed.customStatement('DROP TABLE IF EXISTS $t');
    }
    await seed.customStatement(
        "INSERT INTO ledgers (id, name, currency, created_at) "
        "VALUES (1, 'JP', 'JPY', 1700000000)");
    await seed.customStatement(
        "INSERT INTO accounts (id, ledger_id, name, currency, initial_balance) "
        "VALUES (10, 1, 'jpy acc', 'JPY', 0)");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, account_id, happened_at, sync_id) "
        "VALUES (1, 1, 'expense', 1000.0, 10, 1783008000, 'JP-1')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (2, 1, 'expense', 500.0, 1783008000, 'JP-2')");
    await seed.customStatement('PRAGMA user_version = 29');
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    final rows = await db
        .customSelect(
            'SELECT id, currency_code, native_amount FROM transactions ORDER BY id')
        .get();
    expect(rows[0].readNullable<String>('currency_code'), 'JPY');
    expect(rows[0].readNullable<double>('native_amount'), 1000.0);
    expect(rows[1].readNullable<String>('currency_code'), 'JPY',
        reason: 'HARDENING: 无账户回落到账本本位币');
    expect(rows[1].readNullable<double>('native_amount'), 500.0);

    // 悬挂 ledger_id 的旧交易 → COALESCE 末端硬编码 'CNY'
    final dir2 = await Directory.systemTemp.createTemp('smartbook_mig_r2b');
    addTearDown(() => _tryDelete(dir2));
    final file2 = File('${dir2.path}/orphan.sqlite');
    final seed2 = BeeDatabase.forTesting(NativeDatabase(file2));
    await seed2.customStatement('ALTER TABLE transactions DROP COLUMN currency_code');
    await seed2.customStatement('ALTER TABLE transactions DROP COLUMN native_amount');
    await seed2.customStatement('ALTER TABLE transactions DROP COLUMN recorded_at');
    await seed2.customStatement('ALTER TABLE ledgers DROP COLUMN month_start_day');
    await seed2.customStatement('ALTER TABLE accounts DROP COLUMN hidden');
    for (final t in const [
      'auto_book_events', 'auto_book_event_items', 'account_adjustments',
      'deleted_transactions',
    ]) {
      await seed2.customStatement('DROP TABLE IF EXISTS $t');
    }
    await seed2.customStatement(
        "INSERT INTO ledgers (id, name, currency, created_at) "
        "VALUES (1, 'JPY ledger', 'JPY', 1700000000)");
    await seed2.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (1, 999, 'expense', 7.0, 1783008000, 'ORPH')");
    await seed2.customStatement('PRAGMA user_version = 29');
    await seed2.close();
    final db2 = BeeDatabase.forTesting(NativeDatabase(file2));
    addTearDown(db2.close);
    final orphan = await db2
        .customSelect(
            "SELECT currency_code, native_amount FROM transactions WHERE id = 1")
        .getSingle();
    expect(orphan.readNullable<String>('currency_code'), 'CNY',
        reason: 'HARDENING: 悬挂 ledger 的旧交易被标成 CNY(末端硬编码 db.dart:1331-1335);'
            '金额折算不错但币种标签不符,用户需手工改');
  });

  // ══════════════════════════════════════════════════════════════════════

  test('S1 v23->24 的半迁移:v24 段的 ALTER/createTable 全部幂等'
      '(注释声明的防御确实生效)', () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_s1');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/semi24.sqlite');
    // 真实形态:v24 的所有 DDL 已隐式 commit(列/表都在),但 user_version
    // 仍是 23(历史 3.2.0 事故)。用当前 schema 建库后回退版本号,但必须先把
    // v25 及之后新增的列/表删掉,否则 from=23 的链会先撞上更后的裸 ALTER 段
    // (v27,见 S3),掩盖本测试要验证的 v24 段。
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement('DROP INDEX IF EXISTS idx_ledgers_sync_id');
    await seed.customStatement('ALTER TABLE ledgers DROP COLUMN month_start_day');
    await seed.customStatement('ALTER TABLE accounts DROP COLUMN hidden');
    await seed.customStatement(
        'ALTER TABLE recurring_transactions DROP COLUMN currency_code');
    await seed.customStatement('ALTER TABLE transactions DROP COLUMN currency_code');
    await seed.customStatement('ALTER TABLE transactions DROP COLUMN native_amount');
    await seed.customStatement('ALTER TABLE transactions DROP COLUMN recorded_at');
    for (final t in const [
      'exchange_rates', 'exchange_rate_overrides', 'auto_book_events',
      'auto_book_event_items', 'account_adjustments', 'deleted_transactions',
      'sync_pull_errors',
    ]) {
      await seed.customStatement('DROP TABLE IF EXISTS $t');
    }
    await seed.customStatement('PRAGMA user_version = 23');
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    Object? err;
    try {
      await db.customSelect('SELECT 1').get();
    } catch (e) {
      err = e;
    }
    // HARDENING: v24 段每条都走 _addColumnIfMissing / _createTableIfMissing
    // (db.dart:1195-1250),正是为这个场景设计的;v25 段同样有防御。
    expect(err, isNull, reason: 'HARDENING: v24 段幂等,半迁移库可重跑(err=$err)');
    final cols = (await db.customSelect('PRAGMA table_info(transactions)').get())
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(cols, containsAll(const [
      'created_by_user_id', 'last_edited_by_user_id',
      'category_sync_id_override', 'account_sync_id_override',
      'to_account_sync_id_override', 'tag_sync_ids_override',
    ]));
    final dupIdx = (await db
            .customSelect(
                "SELECT name, COUNT(*) c FROM sqlite_master WHERE type='index' GROUP BY name HAVING c > 1")
            .get())
        .length;
    expect(dupIdx, 0, reason: 'HARDENING: 无重复索引');
  });

  test('S2 其它版本段(migration 注释未声明幂等的那些)在半迁移库上会卡死',
      () async {
    // v15 段的 `ALTER TABLE transactions ADD COLUMN sync_id TEXT` 是裸 SQL,
    // 没有 _addColumnIfMissing 保护 → 若该 ALTER 已 commit 但 user_version 仍
    // 是 14(崩溃/被杀进程),下次启动会 duplicate column 抛错。
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_s2');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/semi15.sqlite');
    // 用当前 schema 建库(transactions.sync_id 已存在)→ 回退版本号到 14,
    // 精确模拟"v15 的 ALTER 已隐式 commit,但版本号没更新"。
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement('PRAGMA user_version = 14');
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    Object? err;
    try {
      await db.customSelect('SELECT 1').get();
    } catch (e) {
      err = e;
    }
    // ADVERSE FINDING: v15/v16/v21/v22/v27 等段的 ALTER 是无条件裸 SQL
    // (db.dart:901-902 v15、931-932 v16、1126-1127 v21、1147-1148 v22、
    //  1296-1297 v27),没有 _addColumnIfMissing 防御。
    // 一次崩溃/强杀落在 "ALTER 已提交 + user_version 未更新" 窗口内,DB 将
    // 永久无法打开(每次启动 duplicate column,启动即崩,用户只能重装)。
    // v24 是唯一做了完整防御的版本段(注释 db.dart:1199-1203 明确记录了
    // 3.1.3→3.2.0 的同类事故)。
    expect(err, isNull,
        reason: 'ADVERSE FINDING: v15 半迁移重跑抛 '
            '${err.toString().split('\n').first} → 库永久打不开;'
            'migration 链的幂等保护只覆盖 v24 及其后的 _addColumnIfMissing,'
            'v15/v16/v21/v22/v27 等裸 ALTER 段无保护');
  });

  test('S3 v27(month_start_day)裸 ALTER 同样不幂等', () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_s3');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/semi27.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    // v27 已执行 —— 全量 schema 自带该列 → 退回 26
    await seed.customStatement('PRAGMA user_version = 26');
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    Object? err;
    try {
      await db.customSelect('SELECT 1').get();
    } catch (e) {
      err = e;
    }
    // ADVERSE FINDING: v27 段是裸 `ALTER TABLE ledgers ADD COLUMN month_start_day`
    // (db.dart:1296-1297),无 PRAGMA 检查 → 半迁移重跑 duplicate column。
    expect(err, isNull,
        reason: 'ADVERSE FINDING: v27 半迁移重跑抛 ${err.toString().split('\n').first};'
            'migration 链幂等性不一致(v24 段有防御,前后段没有)');
  });

  test('S4 半迁移库恢复后数据完好:失败前已提交的 ALTER 不丢数据', () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_s4');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/s4.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, '数据', 'CNY')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (1, 1, 'expense', 88.0, 1783008000, 'S4-TX')");
    // 模拟 v34 已部分执行:raw_title 已加(其余 v34 列未加),版本停在 33。
    // 先把 v34 的全套列删干净,再只补回 raw_title。
    for (final c in const [
      'raw_title', 'raw_text', 'raw_actor', 'raw_metadata_json',
      'raw_evidence_uploaded_at', 'raw_evidence_upload_attempts',
      'raw_evidence_last_error',
    ]) {
      await seed.customStatement('ALTER TABLE auto_book_events DROP COLUMN $c');
    }
    await seed.customStatement('ALTER TABLE auto_book_events ADD COLUMN raw_title TEXT');
    await seed.customStatement('PRAGMA user_version = 33');
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    Object? err;
    try {
      await db.customSelect('SELECT 1').get();
    } catch (e) {
      err = e;
    }
    // HARDENING: v34 全走 _addColumnIfMissing → 已存在的 raw_title 被跳过,
    // 其余补上(既有 raw_evidence_migration_test.dart 已钉住的模式)。
    expect(err, isNull, reason: 'HARDENING: v34 段幂等,可恢复(err=$err)');
    final row = await db
        .customSelect('SELECT amount, sync_id FROM transactions WHERE id = 1')
        .getSingle();
    expect(row.read<double>('amount'), 88.0,
        reason: 'HARDENING: 数据在迁移失败/恢复之间完好');
    final cols = (await db.customSelect('PRAGMA table_info(auto_book_events)').get())
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(cols, containsAll(const [
      'raw_title', 'raw_text', 'raw_actor', 'raw_metadata_json',
      'raw_evidence_local_enabled', 'raw_evidence_server_enabled',
    ]));
  });

  // ══════════════════════════════════════════════════════════════════════
  // T. 索引双路径 + CHECK 约束一致性
  // ══════════════════════════════════════════════════════════════════════

  test('T1 索引:新装(onCreate) 与升级(onUpgrade) 两条路径结果一致', () async {
    // 新装
    final fresh = BeeDatabase.forTesting(NativeDatabase.memory());
    addTearDown(fresh.close);
    final freshIdx = (await fresh
            .customSelect(
                "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'")
            .get())
        .map((r) => r.read<String>('name'))
        .toSet();

    // 升级:全量 schema 建库 → 删掉全部索引 → 退回 38
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_t1');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/t1.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    for (final n in (await seed
            .customSelect("SELECT name FROM sqlite_master WHERE type='index'")
            .get())
        .map((r) => r.read<String>('name'))
        .where((n) => n.startsWith('idx_'))) {
      await seed.customStatement('DROP INDEX IF EXISTS $n');
    }
    await seed.customStatement('PRAGMA user_version = 38');
    await seed.close();
    final upgraded = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(upgraded.close);
    await upgraded.customSelect('SELECT 1').get();
    final upIdx = (await upgraded
            .customSelect(
                "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'")
            .get())
        .map((r) => r.read<String>('name'))
        .toSet();

    // HARDENING: _ensureIndexes 两路径共用(db.dart:1491),差异只在
    // idx_rate_override_pair(onCreate 显式建、升级走 v28)。
    expect(upIdx.difference(freshIdx), isEmpty,
        reason: 'HARDENING: 升级路径不缺索引(差集=${upIdx.difference(freshIdx)})');
    // ADVERSE FINDING: _ensureIndexes 的 byTable 表里**没有**
    // exchange_rate_overrides,唯一的 idx_rate_override_pair 只在 onCreate 与
    // v28 分支里建(db.dart:1307-1309 / 1472-1474)。它是 UNIQUE 索引,
    // 一旦丢失(库损坏修复/手工操作/未来重构误删)_ensureIndexes 不会自愈 ——
    // 其它所有索引都会。索引自愈机制存在覆盖缺口。
    expect(freshIdx.difference(upIdx), isEmpty,
        reason: 'ADVERSE FINDING: 升级路径多出 '
            '${freshIdx.difference(upIdx)}(= idx_rate_override_pair);'
            '_ensureIndexes 未覆盖 exchange_rate_overrides,该 UNIQUE 索引'
            '不会在升级时自愈(其它索引都会)');
    expect(freshIdx.length, greaterThan(30),
        reason: 'HARDENING: 索引数量 ${freshIdx.length}');
  });

  test('T2 CHECK 约束:exclude_from_stats/budget 在两条路径上都存在(语义只认 0/1)',
      () async {
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    // 建一个账本
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    // HARDENING: 生成 DDL 带 CHECK(... IN (0,1))(db.g.dart:1998/2008)。
    Object? err;
    try {
      await db.customStatement(
          "INSERT INTO transactions (ledger_id, type, amount, happened_at, exclude_from_stats) "
          "VALUES (1, 'expense', 1.0, 1783008000, 2)");
    } catch (e) {
      err = e;
    }
    expect(err, isNotNull,
        reason: 'HARDENING: CHECK 拦下 exclude_from_stats=2(新装路径)');

    // 其它布尔列:is_shared / hidden / enabled(见 db.g.dart:76/655/3083/5239)
    Object? err2;
    try {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency, is_shared) VALUES (2, 'X', 'CNY', 5)");
    } catch (e) {
      err2 = e;
    }
    expect(err2, isNotNull, reason: 'HARDENING: ledgers.is_shared CHECK');
  });

  test('T3 CHECK 约束覆盖度:sync_id / amount / type 等关键列**没有**约束',
      () async {
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    // 空串 syncId / 任意 type / 超长 ledger 名 都能落库
    await db.customStatement(
        "INSERT INTO transactions (ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (1, '', -12345.0, 0, '')");
    final row = await db
        .customSelect('SELECT type, amount, sync_id, happened_at FROM transactions')
        .getSingle();
    // ADVERSE FINDING(设计取舍层面):DDL 里只有 boolean 列有 CHECK,业务
    // 关键列 type/sync_id/amount 全无约束 —— 这就是 A1/A2/D1/D3 那一族缺陷
    // 的共同根因(脏数据从 SQL 层就拦不住)。
    expect(row.read<String>('type'), '',
        reason: 'ADVERSE FINDING: type="" 可落库(应为 expense/income/transfer)');
    expect(row.read<double>('amount'), -12345.0,
        reason: 'ADVERSE FINDING: 负金额可落库(无 CHECK(amount >= 0))');
    expect(row.read<String>('sync_id'), '',
        reason: 'ADVERSE FINDING: 空串 sync_id 可落库(无 CHECK 非空/格式)');
  });

  // ══════════════════════════════════════════════════════════════════════
  // U. 迁移后的运行期行为(旧 NULL 列被新查询命中/漏掉)
  // ══════════════════════════════════════════════════════════════════════

  test('U1 老数据 recorded_at=NULL:回填边界与迁移后新写入的行', () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_u1');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/u1.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    // v39 形态:transactions 无 recorded_at(v40 才加)。
    // 注意不要删 currency_code/native_amount —— from=39 不会重跑 v30,
    // 删了它们后续 repo 写入会 no such column。
    await seed.customStatement('ALTER TABLE transactions DROP COLUMN recorded_at');
    await seed.customStatement('ALTER TABLE accounts DROP COLUMN hidden');
    // 注意:不删 ledgers.month_start_day —— 从 v39 升级不会重跑 v27,
    // drift 生成的映射器把该列当非空读(g.db.dart:197 `!`),老库本来就该有。
    await seed.customStatement(
        "INSERT INTO ledgers (id, name, currency, created_at) "
        "VALUES (1, 'U', 'CNY', 1700000000)");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (1, 1, 'expense', 10.0, 1783008000, 'U1-OLD')");
    await seed.customStatement('PRAGMA user_version = 39');
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    final cols = (await db.customSelect('PRAGMA table_info(transactions)').get())
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(cols, contains('recorded_at'), reason: 'HARDENING: v40 补列');
    final row = await db
        .customSelect('SELECT recorded_at FROM transactions WHERE id = 1')
        .getSingle();
    // HARDENING: v40 明确不回填(db.dart:1435-1440)→ 老行 NULL,UI 显示 "-"。
    expect(row.readNullable<int>('recorded_at'), isNull,
        reason: 'HARDENING: 老行 NULL(不回填)');

    // 迁移之后经 **repo 写入**的新行有值(recorded_at 由
    // LocalTransactionRepository.addTransaction 显式写 DateTime.now().toUtc(),
    // local_transaction_repository.dart:455);该列无 SQL DEFAULT,故 raw SQL
    // INSERT 会得到 NULL —— 即"绕过 repo 的写入不会被盖章"。
    await db.close();
    final db2 = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db2.close);
    final repo2 = LocalRepository(db2);
    await repo2.addTransaction(
        ledgerId: 1, type: 'expense', amount: 20.0,
        happenedAt: DateTime(2026, 7, 5));
    final fresh = await db2
        .customSelect(
            'SELECT recorded_at FROM transactions WHERE amount = 20.0')
        .getSingle();
    expect(fresh.readNullable<int>('recorded_at'), isNotNull,
        reason: 'HARDENING: 迁移后经 repo 写入的新行有 recorded_at');
  });

  test('U2 v36 回填只针对 enabled=1 的行:disabled 行的新列滞留 NULL', () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_u2');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/u2.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement('''
      DROP TABLE auto_book_events;
      CREATE TABLE auto_book_events (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        event_key TEXT NOT NULL UNIQUE,
        source TEXT NOT NULL,
        captured_at INTEGER NOT NULL,
        raw_evidence_local_enabled INTEGER NOT NULL DEFAULT 0,
        raw_evidence_server_enabled INTEGER NOT NULL DEFAULT 0,
        raw_evidence_retention_until INTEGER
      );
    ''');
    await seed.customStatement('DROP TABLE transactions');
    await seed.customStatement('CREATE TABLE transactions (id INTEGER NOT NULL PRIMARY KEY)');
    await seed.customStatement('''
      INSERT INTO auto_book_events
        (event_key, source, captured_at, raw_evidence_local_enabled,
         raw_evidence_server_enabled, raw_evidence_retention_until)
      VALUES
        ('enabled',   'sms', 1783008000, 1, 1, 2000000000),
        ('disabled',  'sms', 1783008000, 0, 0, 2000000000),
        ('null-window', 'sms', 1783008000, 1, 0, NULL);
    ''');
    await seed.customStatement('PRAGMA user_version = 35');
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    final rows = await db
        .customSelect('''
      SELECT event_key, raw_evidence_local_expires_at, raw_evidence_server_expires_at
      FROM auto_book_events ORDER BY event_key
    ''')
        .get();
    Map<String, ({int? l, int? s})> byKey = {
      for (final r in rows)
        r.read<String>('event_key'): (
          l: r.readNullable<int>('raw_evidence_local_expires_at'),
          s: r.readNullable<int>('raw_evidence_server_expires_at'),
        )
    };
    // HARDENING: v36 的两条 UPDATE 都带 `WHERE <flag> = 1 AND <col> IS NULL`
    // (db.dart:1415-1420)→ disabled 行不回填(NULL 表示"未启用该窗口")。
    expect(byKey['enabled']!.l, 2000000000,
        reason: 'HARDENING: enabled 行 local 窗口回填');
    expect(byKey['enabled']!.s, 2000000000);
    expect(byKey['disabled']!.l, isNull,
        reason: 'HARDENING: disabled 行不回填(窗口概念不适用)');
    expect(byKey['disabled']!.s, isNull);
    expect(byKey['null-window']!.l, isNull,
        reason: 'HARDENING: retention 为 NULL 时不回填(不制造假窗口)');
    expect(byKey['null-window']!.s, isNull);
  });

  test('U3 迁移后 exchange_rate_overrides 唯一索引在两条路径上都生效', () async {
    final fresh = BeeDatabase.forTesting(NativeDatabase.memory());
    addTearDown(fresh.close);
    await fresh.customStatement(
        "INSERT INTO exchange_rate_overrides (base_currency, quote_currency, rate) "
        "VALUES ('CNY', 'USD', '7.2')");
    Object? err;
    try {
      await fresh.customStatement(
          "INSERT INTO exchange_rate_overrides (base_currency, quote_currency, rate) "
          "VALUES ('CNY', 'USD', '7.3')");
    } catch (e) {
      err = e;
    }
    // HARDENING: idx_rate_override_pair 是 UNIQUE(onCreate 显式 + v28),
    // 同一币对不可重复覆盖 —— 是 schema 里少见的"真正唯一约束"。
    expect(err, isNotNull,
        reason: 'HARDENING: (base,quote) 唯一索引拦下重复(对比 transactions.sync_id '
            '只有非唯一索引 → A1 家族缺陷)');
  });

  test('U4 迁移不重建表:pk/rowid 稳定,旧 id 引用不失效', () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_u4');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/u4.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement('ALTER TABLE transactions DROP COLUMN currency_code');
    await seed.customStatement('ALTER TABLE transactions DROP COLUMN native_amount');
    await seed.customStatement('ALTER TABLE transactions DROP COLUMN recorded_at');
    await seed.customStatement('DROP INDEX IF EXISTS idx_ledgers_sync_id');
    await seed.customStatement('ALTER TABLE ledgers DROP COLUMN month_start_day');
    await seed.customStatement('ALTER TABLE accounts DROP COLUMN hidden');
    for (final t in const [
      'auto_book_events', 'auto_book_event_items', 'account_adjustments',
      'deleted_transactions',
    ]) {
      await seed.customStatement('DROP TABLE IF EXISTS $t');
    }
    await seed.customStatement(
        "INSERT INTO ledgers (id, name, currency, created_at) VALUES (1, 'U4', 'CNY', 1700000000)");
    for (var i = 1; i <= 5; i++) {
      await seed.customStatement(
          "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
          "VALUES ($i, 1, 'expense', ${i * 10}.0, ${1783008000 + i}, 'U4-$i')");
    }
    await seed.customStatement('PRAGMA user_version = 29');
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    final ids = (await db
            .customSelect('SELECT id FROM transactions ORDER BY id')
            .get())
        .map((r) => r.read<int>('id'))
        .toList();
    // HARDENING: v29→44 的迁移全部是 ALTER ADD COLUMN / CREATE TABLE,不重建表
    // → 旧 id 全部保留(附件/标签/回收站 payload 里存的 int id 不失效)。
    expect(ids, [1, 2, 3, 4, 5]);
    // 但 v7 那段(&from < 7)会重建 recurring_transactions —— 老库(≤6)升级时
    // 该表 id 也保留(INSERT ... SELECT id) → 同样安全。
    expect(ids.length, 5);
  });

  test('U5 exportSchema / 版本降级:user_version 高于 schemaVersion 时不重跑迁移',
      () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_u5');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/u5.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'Downgrade', 'CNY')");
    // 模拟"装了更新版本 → 回退到老版本":版本号 99 > 44
    await seed.customStatement('PRAGMA user_version = 99');
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    Object? err;
    try {
      await db.customSelect('SELECT * FROM ledgers').get();
    } catch (e) {
      err = e;
    }
    // ADVERSE FINDING: drift 只在 versionBefore < versionNow 时跑 onUpgrade
    // (drift db_base.dart:126-135 的 details.hadUpgrade)。版本高于代码声明时
    // **静默继续**,不报"数据库版本过新"。用户回退 App 版本后可以正常打开库,
    // 但新版本写入的、老代码不认识的数据列/语义会被忽略 → 显示缺失或更糟。
    // 这里只验证"不报错"(是否报错由 drift 决定),并把行为钉住。
    expect(err, isNull,
        reason: 'HARDENING: user_version 高于 schemaVersion 时静默运行'
            '(drift 不校验上界);回退 App 版本后旧代码会读到不认识的新列语义');
    final rows = await db.customSelect('SELECT * FROM ledgers').get();
    expect(rows.length, 1, reason: 'HARDENING: 数据可读');
  });

  // ══════════════════════════════════════════════════════════════════════
  // V. v45 syncId 唯一索引迁移(批次 C3 必测 fixture)
  //   ① 半迁移库(去重/索引已部分执行,user_version 未更新)
  //   ② 已有重复行(去重 + 关联合并 + 唯一索引落地)
  // ══════════════════════════════════════════════════════════════════════

  test('V1 半迁移库:v45 部分执行后重跑幂等,库可打开且终态一致', () async {
    // 真实形态:去重已跑完(无重复行)、唯一索引已建,但 user_version 停在 44。
    // 模拟"迁移中途崩溃/被杀进程"。重跑必须不抛错(否则每次启动都崩,用户
    // 只能重装),且结果与一次跑完一致。
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_v1');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/semi45.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (1, 1, 'expense', 5.0, 1783008000, 'V1-X')");
    // 手工模拟 v45 已执行的 DDL 部分(索引已在),但版本未更新
    await seed.customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_transactions_ledger_sync_id '
        "ON transactions (ledger_id, sync_id) "
        "WHERE sync_id IS NOT NULL AND sync_id <> '';");
    await seed.customStatement('PRAGMA user_version = 44');
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    Object? err;
    try {
      await db.customSelect('SELECT 1').get();
    } catch (e) {
      err = e;
    }
    expect(err, isNull,
        reason: 'HARDENING: v45 半迁移库可重跑(err=$err);整套 v45 逐步骤 '
            'best-effort + 全部 IF NOT EXISTS/幂等 DML');
    final v = await db.customSelect('PRAGMA user_version').getSingle();
    expect(v.read<int>('user_version'), 45);
    // 终态:索引恰好一份,数据完好
    final idx = await db
        .customSelect(
            "SELECT COUNT(*) c FROM sqlite_master WHERE type='index' AND name='idx_transactions_ledger_sync_id'")
        .getSingle();
    expect(idx.data['c'], 1, reason: 'HARDENING: 无重复索引');
    final row = await db
        .customSelect("SELECT amount FROM transactions WHERE sync_id='V1-X'")
        .getSingle();
    expect(row.read<double>('amount'), 5.0, reason: 'HARDENING: 数据未丢');
  });

  test('V2 已有重复行:v45 去重(keep 引用最多)+ 关联合并 + 唯一索引 + 非有限清洗',
      () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_v2');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/dup45.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    // 关键:seed 用**当前 schema** 建库 → v45 索引已在。必须先删掉它,
    // 才能真正模拟"v44 老库里的重复行"这一迁移输入。
    await seed.customStatement('DROP INDEX IF EXISTS idx_transactions_ledger_sync_id');
    await seed.customStatement('DROP INDEX IF EXISTS idx_transaction_tags_pair');
    // 两行同 (ledger_id, sync_id):id=1 无引用,id=2 有 2 个标签 + 1 个附件
    // → keeper 应为 id=2(引用最多)。
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (1, 1, 'expense', 11.0, 1783008000, 'DUP-X')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (2, 1, 'expense', 22.0, 1783008000, 'DUP-X')");
    await seed.customStatement(
        "INSERT INTO tags (id, name, sync_id) VALUES (10, 't1', 'T1'), (11, 't2', 'T2')");
    await seed.customStatement(
        "INSERT INTO transaction_tags (transaction_id, tag_id) VALUES (2, 10), (2, 11), (1, 10)");
    await seed.customStatement(
        "INSERT INTO transaction_attachments (id, transaction_id, file_name) "
        "VALUES (100, 2, 'a.jpg')");
    // 非有限金额行(阻塞-7c):Infinity 落库 + 非有限 native_amount
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (3, 1, 'expense', 9e999, 1783008000, 'INF-X')");
    await seed.customStatement('PRAGMA user_version = 44');
    // 备份导出需要 path_provider —— 测试环境无插件,必须确认迁移在备份失败时
    // **仍能完成**(阻塞-7b 的 fail-safe 要求)。
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    Object? err;
    try {
      await db.customSelect('SELECT 1').get();
    } catch (e) {
      err = e;
    }
    expect(err, isNull,
        reason: 'HARDENING: 有重复行的库可打开(err=$err);备份导出失败(path_provider '
            '在测试环境不可用)不得阻断迁移');

    // ① 去重:keeper = id 2(引用最多),id 1 被删
    final left = await db
        .customSelect("SELECT id, amount FROM transactions WHERE sync_id='DUP-X'")
        .get();
    expect(left.length, 1, reason: 'C3: 重复 syncId 已去重(剩 1 行)');
    expect(left.single.read<int>('id'), 2,
        reason: 'C3: keeper = 引用最多的 id=2');
    // ② 关联合并:id=1 的 tag 关联被改指 keeper,tag 10 去重
    final links = await db
        .customSelect(
            "SELECT tag_id FROM transaction_tags WHERE transaction_id=2 ORDER BY tag_id")
        .get();
    expect(links.map((r) => r.read<int>('tag_id')).toList(), [10, 11],
        reason: 'C3: 关联合并到 keeper 且同 (tx,tag) 去重(2 行,非 3 行)');
    final dangling = await db
        .customSelect(
            "SELECT COUNT(*) c FROM transaction_tags WHERE transaction_id=1")
        .getSingle();
    expect(dangling.data['c'], 0, reason: 'C3: 副本的关联行不再悬挂');
    final atts = await db
        .customSelect(
            "SELECT COUNT(*) c FROM transaction_attachments WHERE transaction_id=2")
        .getSingle();
    expect(atts.data['c'], 1, reason: 'C3: 附件引用随 keeper 保留');

    // ③ 非有限金额清洗
    final inf = await db
        .customSelect("SELECT amount FROM transactions WHERE sync_id='INF-X'")
        .getSingle();
    expect(inf.read<double>('amount').isFinite, isTrue,
        reason: 'C3: 存量 Infinity 被清洗为有限值(0.0),聚合不再被污染');

    // ④ 唯一索引生效:同 (ledger_id, sync_id) 再插被拒
    Object? dupErr;
    try {
      await db.customStatement(
          "INSERT INTO transactions (ledger_id, type, amount, happened_at, sync_id) "
          "VALUES (1, 'expense', 1.0, 1783008000, 'DUP-X')");
    } catch (e) {
      dupErr = e;
    }
    expect(dupErr, isNotNull, reason: 'C3: UNIQUE(ledger_id, sync_id) 已生效');

    // ⑤ 跨账本同 syncId 仍合法(待确认产品决策:取更宽松的带账本维度索引)
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (2, 'L2', 'CNY')");
    Object? crossErr;
    try {
      await db.customStatement(
          "INSERT INTO transactions (ledger_id, type, amount, happened_at, sync_id) "
          "VALUES (2, 'expense', 1.0, 1783008000, 'DUP-X')");
    } catch (e) {
      crossErr = e;
    }
    expect(crossErr, isNull,
        reason: 'C3(待确认产品决策): UNIQUE(ledger_id, sync_id) 保留跨账本同 syncId '
            '的合法性,不因迁移误删跨账本数据');
  });

  test('V3 v45 幂等性:同库连续两次打开结果一致(跑两遍 = 同一结果)', () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_v3');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/idem45.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (1, 1, 'expense', 3.0, 1783008000, 'IDEM')");
    await seed.customStatement('PRAGMA user_version = 44');
    await seed.close();

    Future<({int txCount, int tagLinkCount, Set<String> idxNames})> openAndRead() async {
      final db = BeeDatabase.forTesting(NativeDatabase(file));
      await db.customSelect('SELECT 1').get();
      final txs = await db
          .customSelect('SELECT COUNT(*) c FROM transactions')
          .getSingle();
      final links = await db
          .customSelect('SELECT COUNT(*) c FROM transaction_tags')
          .getSingle();
      final idx = (await db
              .customSelect(
                  "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'")
              .get())
          .map((r) => r.read<String>('name'))
          .toSet();
      await db.close();
      return (
        txCount: txs.data['c'] as int,
        tagLinkCount: links.data['c'] as int,
        idxNames: idx,
      );
    }

    final first = await openAndRead();
    final second = await openAndRead();
    expect(second.txCount, first.txCount,
        reason: 'C3: 二次打开不新增/删除交易行');
    expect(second.tagLinkCount, first.tagLinkCount,
        reason: 'C3: 二次打开不改变关联行数');
    expect(second.idxNames, first.idxNames,
        reason: 'C3: 二次打开的索引集合与首次完全一致');
    expect(first.txCount, 1);
  });

  // ══════════════════════════════════════════════════════════════════════
  // V4-V7 复审核实:旧去重只覆盖 2 张引用表 / keeper 规则丢数据 /
  //   payload 陈旧 / 索引重试死代码(ADVERSARIAL-FIX-PLAN 缺陷 A-D)
  // ══════════════════════════════════════════════════════════════════════

  /// V4/V5/V7 共用的 fixture:两行同 (ledger_id, syncId) 的交易。
  ///
  /// - id=1:业务字段齐全(income / 999 / category 9 / account 7 / 较新
  ///   recorded_at / note='corrected')→ 修复后的 keeper 规则应选它;
  /// - id=2:业务字段几乎全 NULL(仅 type/amount/happened_at),但持有
  ///   标签/附件引用 → 旧规则(引用最多优先)会错选它。
  /// 所有引用表都指向 id=2(loser),用于验证改指覆盖全部引用列。
  Future<File> seedAbcFixture(Directory dir) async {
    final file = File('${dir.path}/v4v5v7.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    // 模拟 v44 库:无 v45 唯一索引(否则重复行插不进去)
    await seed.customStatement(
        'DROP INDEX IF EXISTS idx_transactions_ledger_sync_id');
    await seed.customStatement('DROP INDEX IF EXISTS idx_transaction_tags_pair');
    await seed.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, category_id, account_id, "
        "note, happened_at, recorded_at, sync_id) "
        "VALUES (1, 1, 'income', 999.0, 9, 7, 'corrected', 1783008000, 1783999999, 'DUP-A')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (2, 1, 'expense', 10.0, 1782000000, 'DUP-A')");
    await seed.customStatement(
        "INSERT INTO tags (id, name, sync_id) VALUES (10, 't1', 'T1'), (11, 't2', 'T2')");
    // 标签/附件引用挂在 id=2 上(refcount: id2=3, id1=0 → 旧规则选 id2)
    await seed.customStatement(
        'INSERT INTO transaction_tags (transaction_id, tag_id) VALUES (2, 10), (2, 11), (1, 10)');
    await seed.customStatement(
        "INSERT INTO transaction_attachments (id, transaction_id, file_name) "
        "VALUES (100, 2, 'a.jpg')");
    // AI 账单卡片:父列 + metadata.txIds 双引用 loser(id=2)
    await seed.customStatement(
        "INSERT INTO conversations (id, title) VALUES (1, 'c')");
    await seed.customStatement(
        "INSERT INTO messages (id, conversation_id, role, content, message_type, transaction_id, metadata) "
        "VALUES (1, 1, 'assistant', 'x', 'bill_card', 2, "
        "'{\"bills\":[],\"txIds\":[2,2],\"undoneIds\":[2]}')");
    // 自动记账事件:父行两条关联列 + 子项
    await seed.customStatement(
        "INSERT INTO auto_book_events (id, event_key, source, captured_at, state, "
        "transaction_id, duplicate_of_transaction_id) "
        "VALUES (1, 'k1', 'sms', 1783000000, 'booked', 2, 2)");
    await seed.customStatement(
        "INSERT INTO auto_book_event_items (event_id, item_index, transaction_id) "
        "VALUES (1, 0, 2)");
    // change 记录带 loser 的旧快照(entity_id 与 payload.id 都是 2)
    await seed.customStatement(
        "INSERT INTO local_changes (entity_type, entity_id, entity_sync_id, ledger_id, action, payload_json) "
        "VALUES ('transaction', 2, 'DUP-A', 1, 'update', '{\"id\":2,\"amount\":10}')");
    await seed.customStatement('PRAGMA user_version = 44');
    await seed.close();
    return file;
  }

  test('V4 去重后全部交易引用表都改指 keeper(无悬挂 FK)', () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_v4');
    addTearDown(() => _tryDelete(dir));
    final file = await seedAbcFixture(dir);

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    // keeper = id 1(更完整/更新);id 2 被删
    final surv = await db
        .customSelect("SELECT id FROM transactions WHERE sync_id='DUP-A'")
        .get();
    expect(surv.map((r) => r.read<int>('id')).toList(), [1],
        reason: 'C3: 重复行已去重,剩 keeper=1');
    const keeper = 1;

    // **程序化枚举**全部 `*transaction_id` / `*TransactionId` 列 —— 不依赖
    // 手写清单(评审要求:必须自己枚举,不能只修点名的 4 张表)。
    // 口径:pragma table_info 取每张表的列名,命中
    // `transaction_id` / `duplicate_of_transaction_id` 即视为本地 int 引用。
    // (`transaction_sync_id` / `sync_id` 是字符串身份,不因去重变化,排除。)
    final tables = (await db
            .customSelect(
                "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            .get())
        .map((r) => r.read<String>('name'))
        .toList();
    final refs = <({String table, String col})>[];
    for (final table in tables) {
      final cols = await db.customSelect('PRAGMA table_info($table)').get();
      for (final c in cols) {
        final name = c.read<String>('name');
        if (name == 'transaction_id' || name == 'duplicate_of_transaction_id') {
          refs.add((table: table, col: name));
        }
      }
    }
    // 断言枚举到的清单包含评审点名的四张表 + 原有两张(防止枚举口径漏掉)
    expect(
        refs.map((r) => '${r.table}.${r.col}').toSet(),
        containsAll(const [
          'transaction_tags.transaction_id',
          'transaction_attachments.transaction_id',
          'messages.transaction_id',
          'auto_book_events.transaction_id',
          'auto_book_events.duplicate_of_transaction_id',
          'auto_book_event_items.transaction_id',
        ]),
        reason: 'C3/缺陷 A: 程序化枚举必须覆盖全部 6 个交易 int 引用列');

    for (final ref in refs) {
      final dangling = await db.customSelect(
        'SELECT COUNT(*) c FROM ${ref.table} r '
        'WHERE r.${ref.col} IS NOT NULL '
        'AND NOT EXISTS (SELECT 1 FROM transactions t WHERE t.id = r.${ref.col})',
      ).getSingle();
      expect(dangling.data['c'], 0,
          reason: 'C3/缺陷 A: ${ref.table}.${ref.col} 不得有悬挂交易引用');
    }
    // 逐表确认引用确实指向 keeper(而不是被"清空"式假修复)
    for (final ref in refs) {
      final onKeeper = await db.customSelect(
        'SELECT COUNT(*) c FROM ${ref.table} WHERE ${ref.col} = $keeper',
      ).getSingle();
      expect((onKeeper.data['c'] as int) >= 1, isTrue,
          reason: 'C3/缺陷 A: ${ref.table}.${ref.col} 应改指 keeper=$keeper');
    }
    // 标签/附件:loser 的引用被合并且同键去重(3 行 → 2 行)
    final links = await db
        .customSelect(
            'SELECT tag_id FROM transaction_tags WHERE transaction_id=$keeper ORDER BY tag_id')
        .get();
    expect(links.map((r) => r.read<int>('tag_id')).toList(), [10, 11],
        reason: 'C3: 标签引用合并到 keeper 且同 (tx,tag) 去重');
    final atts = await db
        .customSelect(
            'SELECT file_name FROM transaction_attachments WHERE transaction_id=$keeper')
        .get();
    expect(atts.length, 1, reason: 'C3: 附件引用随 keeper 保留');

    // JSON 内嵌引用(messages.metadata):txIds 与 undoneIds **都是**本地 int
    // 交易主键列表,必须一起改指。只改 txIds 会让卡片自相矛盾:txIds 指向
    // keeper(未撤销)而 undoneIds 还留着被删的 loser → 去重前已撤销的卡片
    // 复活成「可撤销」(消费侧 ai_chat_page.dart:1888 的 isUndone)。
    final metaRow = await db
        .customSelect('SELECT metadata FROM messages WHERE id=1')
        .getSingle();
    final meta = jsonDecode(metaRow.read<String>('metadata')) as Map;
    expect(meta['txIds'], [keeper],
        reason: 'C3/缺陷 A: metadata.txIds 改指 keeper 且去重');
    expect(meta['undoneIds'], [keeper],
        reason: 'C3/缺陷 A: metadata.undoneIds 是本地 int 引用列表,同样必须改指 '
            'keeper —— 漏改会让已撤销卡片复活');
    // 消费侧不变量(与 ai_chat_page.dart:1816 的契约一致):undoneIds ⊆ txIds。
    final txIds = (meta['txIds'] as List).cast<int>().toSet();
    final undoneIds = (meta['undoneIds'] as List).cast<int>().toSet();
    expect(undoneIds.difference(txIds), isEmpty,
        reason: 'C3/缺陷 A: undoneIds 必须是 txIds 的子集(卡片渲染的前提)');
  });

  test('V5 keeper 选择:更完整/更新的行胜出,且 loser 的字段值被合并进 keeper 的空列',
      () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_v5');
    addTearDown(() => _tryDelete(dir));
    final file = await seedAbcFixture(dir);

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    final row = await db
        .customSelect(
            "SELECT id, type, amount, category_id, account_id, note, recorded_at "
            "FROM transactions WHERE sync_id='DUP-A'")
        .getSingle();
    // 旧规则(refcount DESC)会保留 id=2(引用多)并把 corrected/999 丢掉。
    // 修复规则:completeness 多的 id=1 胜出。
    expect(row.read<int>('id'), 1,
        reason: 'C3/缺陷 B: keeper=1(业务字段更完整),不是引用更多的 id=2');
    expect(row.read<String>('type'), 'income',
        reason: 'C3/缺陷 B: 保留修正后的 type');
    expect(row.read<double>('amount'), 999.0,
        reason: 'C3/缺陷 B: 保留修正后的金额(旧规则会留下 10.0)');
    expect(row.readNullable<String>('note'), 'corrected',
        reason: 'C3/缺陷 B: 保留修正后的备注(旧规则会留下 NULL)');
    expect(row.readNullable<int>('category_id'), 9);
    expect(row.readNullable<int>('account_id'), 7);
    expect(row.readNullable<int>('recorded_at'), 1783999999);

    // 反例方向(字段级 merge):keeper 的空列应由 loser 填补,而不是留 NULL。
    // 单独构造:keeper(id=1)较新但 note NULL,loser(id=2)有 note。
    final dir2 = await Directory.systemTemp.createTemp('smartbook_mig_v5b');
    addTearDown(() => _tryDelete(dir2));
    final file2 = File('${dir2.path}/v5b.sqlite');
    final seed2 = BeeDatabase.forTesting(NativeDatabase(file2));
    await seed2.customStatement(
        'DROP INDEX IF EXISTS idx_transactions_ledger_sync_id');
    await seed2.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await seed2.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, category_id, account_id, "
        "note, happened_at, recorded_at, sync_id) "
        "VALUES (1, 1, 'expense', 5.0, 9, 7, NULL, 1783008000, 1783999999, 'MERGE')");
    await seed2.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, note, happened_at, recorded_at, sync_id) "
        "VALUES (2, 1, 'expense', 5.0, 'from-loser', 1783008000, 1783000000, 'MERGE')");
    await seed2.customStatement('PRAGMA user_version = 44');
    await seed2.close();

    final db2 = BeeDatabase.forTesting(NativeDatabase(file2));
    addTearDown(db2.close);
    await db2.customSelect('SELECT 1').get();
    final merged = await db2
        .customSelect(
            "SELECT id, note, category_id, account_id FROM transactions WHERE sync_id='MERGE'")
        .getSingle();
    expect(merged.read<int>('id'), 1,
        reason: 'C3/缺陷 B: completeness 平手时比较新 recorded_at → keeper=1');
    expect(merged.readNullable<String>('note'), 'from-loser',
        reason: 'C3/缺陷 B: keeper 的 NULL note 由 loser 的字段级 merge 填补');
    expect(merged.readNullable<int>('category_id'), 9,
        reason: 'C3/缺陷 B(不覆盖):keeper 非空的 category_id 不被 loser 的 NULL 覆盖');
    expect(merged.readNullable<int>('account_id'), 7);
  });

  test('V6 user_version 已是 45 + 残余重复:重开仍会修复(beforeOpen 自愈,非死代码)',
      () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_v6');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/v6.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    // 精确复现评审探针:user_version=45(不会再进 onUpgrade)、无唯一索引、
    // 两行重复。旧实现只留注释「下次启动重试」,实测连开 3 次仍是
    // uniqueIndex=0 dupRows=2。
    await seed.customStatement(
        'DROP INDEX IF EXISTS idx_transactions_ledger_sync_id');
    await seed.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (1, 1, 'expense', 1.0, 1783008000, 'DUP-D')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (2, 1, 'expense', 2.0, 1783008000, 'DUP-D')");
    await seed.customStatement('PRAGMA user_version = 45');
    await seed.close();

    // 第一次打开:beforeOpen 自愈应该完成去重 + 建索引
    final db = BeeDatabase.forTesting(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();
    final idx = await db
        .customSelect(
            "SELECT COUNT(*) c FROM sqlite_master WHERE type='index' AND name='idx_transactions_ledger_sync_id'")
        .getSingle();
    final dup = await db
        .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='DUP-D'")
        .getSingle();
    final uv = await db.customSelect('PRAGMA user_version').getSingle();
    expect(uv.read<int>('user_version'), 45,
        reason: 'C3/缺陷 D: 版本号不变(已是最新)');
    expect(dup.data['c'], 1,
        reason: 'C3/缺陷 D: 重开即修复残余重复(旧实现永久停在 2 行)');
    expect(idx.data['c'], 1,
        reason: 'C3/缺陷 D: 唯一索引在 user_version=45 时也能建立');
    await db.close();

    // 第二/三次打开:结果稳定(自愈幂等、正常打开零额外工作)
    for (var i = 0; i < 2; i++) {
      final again = BeeDatabase.forTesting(NativeDatabase(file));
      await again.customSelect('SELECT 1').get();
      final c2 = await again
          .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='DUP-D'")
          .getSingle();
      expect(c2.data['c'], 1, reason: 'C3/缺陷 D: 再开不重复删除/不复活');
      await again.close();
    }
  });

  test('V7 去重后 local_changes.payload_json 与 entity_id 自洽(重写为 keeper 状态)',
      () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_v7');
    addTearDown(() => _tryDelete(dir));
    final file = await seedAbcFixture(dir);

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    final lc = await db
        .customSelect(
            "SELECT entity_id, payload_json FROM local_changes WHERE entity_type='transaction'")
        .getSingle();
    expect(lc.read<int>('entity_id'), 1,
        reason: 'C3: entity_id 改指 keeper');
    final payload =
        jsonDecode(lc.read<String>('payload_json')) as Map<String, dynamic>;
    // 旧实现只改 entity_id,payload 里还嵌着 loser 的 {"id":2,"amount":10}:
    // entity_id=1 + payload.id=2 的行是自相矛盾的 latent wrong-value push。
    expect(payload['id'], 1,
        reason: 'C3/缺陷 C: payload.id 必须与 entity_id 一致(不再是 loser id=2)');
    expect(payload['amount'], 999.0,
        reason: 'C3/缺陷 C: payload 金额是 keeper 合并后的值(旧值是 loser 的 10.0)');
    expect(payload['note'], 'corrected',
        reason: 'C3/缺陷 C: payload 反映 keeper 的最终状态');
    expect(payload['sync_id'], 'DUP-A',
        reason: 'C3/缺陷 C: sync_id 保留');
  });

  test('V8 跨账本同 syncId:去重不误删另一账本的行,local_changes 不跨界改写',
      () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_v8');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/v8.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement(
        'DROP INDEX IF EXISTS idx_transactions_ledger_sync_id');
    await seed.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L1', 'CNY'), (2, 'L2', 'CNY')");
    // 账本 1:两行重复。账本 2:一行同 syncId(合法,必须保留)。
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (1, 1, 'expense', 1.0, 1783008000, 'CROSS')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (2, 1, 'expense', 2.0, 1783008000, 'CROSS')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (3, 2, 'expense', 3.0, 1783008000, 'CROSS')");
    // 两个账本各有一条同名 change(旧实现按 syncId 全表 UPDATE → 跨界误改)
    await seed.customStatement(
        "INSERT INTO local_changes (entity_type, entity_id, entity_sync_id, ledger_id, action, payload_json) "
        "VALUES ('transaction', 2, 'CROSS', 1, 'update', '{\"id\":2}'), "
        "('transaction', 3, 'CROSS', 2, 'update', '{\"id\":3}')");
    await seed.customStatement('PRAGMA user_version = 44');
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    final rows = await db
        .customSelect('SELECT id, ledger_id, amount FROM transactions ORDER BY id')
        .get();
    expect(rows.map((r) => r.read<int>('id')).toList(), [1, 3],
        reason: 'C3: 只合并账本 1 的重复;账本 2 的同 syncId 行合法保留');
    // 账本 2 的 change 未被跨界改写(entity_id 仍 3,payload 仍 {"id":3})
    final lc2 = await db
        .customSelect(
            "SELECT entity_id, payload_json FROM local_changes WHERE ledger_id=2")
        .getSingle();
    expect(lc2.read<int>('entity_id'), 3,
        reason: 'C3: local_changes 改写按 ledger_id 作用域,不跨界');
    expect(jsonDecode(lc2.read<String>('payload_json'))['id'], 3,
        reason: 'C3: 账本 2 的 payload 保持自洽');
  });

  test('V9 跨账本同 syncId 的删除不再静默连删(缺陷 I:fail-closed)',
      () async {
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = LocalRepository(db);
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L1', 'CNY'), (2, 'L2', 'CNY')");
    await db.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
        "VALUES (1, 1, 'expense', 1.0, 1783008000, 'SAME'), (2, 2, 'expense', 2.0, 1783008000, 'SAME')");
    // 旧实现:deleteTransactionBySyncId('SAME') 删光两个账本(remaining=[])。
    Object? singleErr;
    try {
      await repo.deleteTransactionBySyncId('SAME');
    } catch (e) {
      singleErr = e;
    }
    expect(singleErr, isA<StateError>(),
        reason: 'C3/缺陷 I: 跨账本命中显式报错,不静默连删另一个账本的账目');
    final afterSingle = await db
        .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='SAME'")
        .getSingle();
    expect(afterSingle.data['c'], 2,
        reason: 'C3/缺陷 I: 报错时一行都不删(原实现 remaining=[])');

    // 批量入口同语义
    Object? batchErr;
    try {
      await repo.deleteTransactionsBatchBySyncIds(['SAME']);
    } catch (e) {
      batchErr = e;
    }
    expect(batchErr, isA<StateError>(),
        reason: 'C3/缺陷 I: 批量入口与单条入口语义一致(同一账本才删)');
    final afterBatch = await db
        .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='SAME'")
        .getSingle();
    expect(afterBatch.data['c'], 2, reason: 'C3/缺陷 I: 批量同样 fail-closed');

    // 同账本内(常态路径)照旧可用;跨账本时持续 fail-closed(不会因报错一次放宽)
    Object? againErr;
    try {
      await repo.deleteTransactionBySyncId('SAME');
    } catch (e) {
      againErr = e;
    }
    expect(againErr, isA<StateError>(),
        reason: 'C3/缺陷 I: 跨账本命中持续拒绝,不因一次报错放宽为全删');
    final stillCross = await db
        .customSelect("SELECT COUNT(*) c FROM transactions WHERE sync_id='SAME'")
        .getSingle();
    expect(stillCross.data['c'], 2,
        reason: 'C3/缺陷 I: 两次尝试都一行未删');
    await db.customStatement("DELETE FROM transactions WHERE ledger_id = 2");
    final n = await repo.deleteTransactionsBatchBySyncIds(['SAME']);
    expect(n, 1, reason: 'C3/缺陷 I: 只剩单账本时批量删除正常生效');
  });

  test('V10 迁移安全:存量 Infinity/NaN 不阻断打开,快照带 Unrepresentable 标记'
      ' + 合并/丢弃明细(dedupePlans)', () async {
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_v10');
    addTearDown(() => _tryDelete(dir));
    final backupDir = Directory('${dir.path}/bk');
    BeeDatabase.v45BackupDirectoryOverrideForTesting = backupDir.path;
    addTearDown(() => BeeDatabase.v45BackupDirectoryOverrideForTesting = null);

    final file = File('${dir.path}/v10.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement(
        'DROP INDEX IF EXISTS idx_transactions_ledger_sync_id');
    await seed.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    // 存量 ±Infinity(1e400 在 SQLite REAL 里即 Infinity):旧设计的「备份失败
    // 则中止迁移」会被 jsonEncode(Infinity) 击穿 → onUpgrade 抛错 = 库永久
    // 打不开(阻塞-7b / misc 域红测 1/2)。
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, native_amount, happened_at, sync_id) "
        "VALUES (1, 1, 'expense', 1e400, 1e400, 1783008000, 'NF')");
    // 同时制造一组重复(其中一行也是 Infinity)→ 备份里的去重计划必须记录
    // 「keeper 是谁 / 删哪些行 / 合并了什么 / 丢弃了什么」。
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, note, happened_at, sync_id) "
        "VALUES (2, 1, 'expense', 5.0, 'keep', 1783008000, 'DUP-NF')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, note, happened_at, sync_id) "
        "VALUES (3, 1, 'expense', 1e400, 'INF', 1783008000, 'DUP-NF')");
    await seed.customStatement('PRAGMA user_version = 44');
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    Object? openErr;
    try {
      await db.customSelect('SELECT 1').get();
    } catch (e) {
      openErr = e;
    }
    expect(openErr, isNull,
        reason: 'C3/阻塞-7: 存量 Infinity 行不得让迁移抛错(抛错=库永久打不开)');

    // 非有限金额被清洗为有限值,且重复组已合并(账目保住,不删净)
    final rows = await db
        .customSelect('SELECT id, amount FROM transactions ORDER BY id')
        .get();
    expect(rows.length, 2, reason: 'C3: DUP-NF 两行合并为一行,NF 行保留');
    for (final r in rows) {
      expect(r.read<double>('amount').isFinite, isTrue,
          reason: 'C3/阻塞-7c: 存量 ±Infinity 被归零,聚合不再返回 Infinity');
    }

    // 快照存在且内嵌去重计划与不可表示标记(回滚唯一依据)
    final files = backupDir.existsSync()
        ? backupDir
            .listSync()
            .whereType<File>()
            .where((f) => f.uri.pathSegments.last.startsWith('pre-v45-'))
            .toList()
        : <File>[];
    expect(files, isNotEmpty,
        reason: 'C3/阻塞-7a: 迁移前必须导出 pre-v45-<ts>.json 快照(去重不可逆)');
    final doc =
        jsonDecode(await files.first.readAsString()) as Map<String, dynamic>;
    expect(doc['rollbackNote'], isNotNull,
        reason: 'C3/阻塞-7a: 快照必须声明「只能按快照重放」,不能再宣称仅 DROP INDEX');
    final plans = doc['dedupePlans'] as List;
    expect(plans.length, 1, reason: 'C3/缺陷 B: 快照内嵌这条重复组的合并计划');
    final plan = plans.single as Map<String, dynamic>;
    expect(plan['keeperId'], 2,
        reason: 'C3/缺陷 B: keeper 选更完整的 id=2(note=keep),不是 Infinity 行');
    expect(plan['deletedRowIds'], [3], reason: 'C3/缺陷 B: 明确记录被删行');
    expect((plan['discardedByLoser'] as Map).keys.map((k) => '$k'),
        contains('3'),
        reason: 'C3/缺陷 B: loser 未采纳的值必须留档(不静默丢失,Infinity 记 '
            '<non-finite>)');
    final snapshotTxs = doc['transactions'] as List;
    expect(
        snapshotTxs
            .whereType<Map>()
            .any((t) => t.keys.any((k) => '$k'.endsWith('Unrepresentable'))),
        isTrue,
        reason: 'C3/阻塞-7b: 快照序列化前过滤非有限值(否则 jsonEncode 抛错)');
  });

  test('V11 合并的结构不变量:金额三元组原子 + 禁止自转账 + 双表示互斥', () async {
    // 跨审缺陷 1a/1b 的持久回归锁。三个探针各自独立成一个 ledger,
    // 避免互相污染(同一库里的重复组按 (ledger_id, sync_id) 分组)。
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_v11');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/v11.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement(
        'DROP INDEX IF EXISTS idx_transactions_ledger_sync_id');
    await seed.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    // 账户:5=本地 id 且 sync_id='ACC-5';6=另一账户。用于自转账反查。
    await seed.customStatement(
        "INSERT INTO accounts (id, ledger_id, name, currency, sync_id) "
        "VALUES (5, 1, 'A5', 'CNY', 'ACC-5'), (6, 1, 'A6', 'CNY', 'ACC-6')");

    // ── 探针 A(缺陷 1a):keeper amount=999 无币种/无折算;
    //    loser amount=10 + currency=USD + native_amount=72。
    //    keeper 更完整(有 category/account/note)故胜出,但**金额不同**,
    //    loser 的币种/折算属于另一个金额 —— 绝不能填进 keeper。
    //    旧实现产出 (999, USD, 72):账本统计读
    //    COALESCE(native_amount, amount) → SUM=72 而非 999(静默错钱)。
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, category_id, account_id, "
        "note, happened_at, recorded_at, sync_id) "
        "VALUES (1, 1, 'expense', 999.0, 9, 7, 'keeper', 1783008000, 1783999999, 'T1A')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, currency_code, native_amount, "
        "happened_at, recorded_at, sync_id) "
        "VALUES (2, 1, 'expense', 10.0, 'USD', 72.0, 1782000000, 1783000000, 'T1A')");

    // ── 探针 B(缺陷 1a 的合法方向):同金额的 loser 币种/折算**应当**被采纳。
    //    keeper(500, 无币种/折算) + loser(500, USD, 3600):三元组同源 → 填。
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, category_id, account_id, "
        "note, happened_at, recorded_at, sync_id) "
        "VALUES (3, 1, 'expense', 500.0, 9, 7, 'keeper', 1783008000, 1783999999, 'T1A-OK')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, currency_code, native_amount, "
        "happened_at, recorded_at, sync_id) "
        "VALUES (4, 1, 'expense', 500.0, 'USD', 3600.0, 1782000000, 1783000000, 'T1A-OK')");

    // ── 探针 C(缺陷 1b):keeper transfer account_id=5 to=NULL;
    //    loser to_account_id=5(同一账户)→ 旧实现合并出自转账
    //    (account_id == to_account_id),getAccountBalance 与
    //    getAccountBalanceInLedger 从此永久分歧。
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, account_id, "
        "note, happened_at, recorded_at, sync_id) "
        "VALUES (5, 1, 'transfer', 100.0, 5, 'keeper', 1783008000, 1783999999, 'T1B')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, to_account_id, "
        "happened_at, recorded_at, sync_id) "
        "VALUES (6, 1, 'transfer', 100.0, 5, 1782000000, 1783000000, 'T1B')");

    // ── 探针 D(缺陷 1b 的合法方向):to_account_id=6 ≠ account_id=5 应当被填。
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, account_id, "
        "note, happened_at, recorded_at, sync_id) "
        "VALUES (7, 1, 'transfer', 200.0, 5, 'keeper', 1783008000, 1783999999, 'T1B-OK')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, to_account_id, "
        "happened_at, recorded_at, sync_id) "
        "VALUES (8, 1, 'transfer', 200.0, 6, 1782000000, 1783000000, 'T1B-OK')");

    // ── 探针 E(I3 双表示):keeper 已有 account_id=6,loser 只有
    //    account_sync_id_override='ACC-5' —— 填进去会让同一引用同时有本地 id
    //    与 syncId 两种表示(同步侧读 override、本地统计读 id,两个口径)。
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, account_id, "
        "note, happened_at, recorded_at, sync_id) "
        "VALUES (9, 1, 'expense', 300.0, 6, 'keeper', 1783008000, 1783999999, 'T1C')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, account_sync_id_override, "
        "happened_at, recorded_at, sync_id) "
        "VALUES (10, 1, 'expense', 300.0, 'ACC-5', 1782000000, 1783000000, 'T1C')");

    // ── 探针 F(I2 非 transfer):keeper expense(无 to_account),loser 带
    //    to_account_id=6 —— 非 transfer 行带转入引用会让两个余额 API 分歧。
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, account_id, "
        "note, happened_at, recorded_at, sync_id) "
        "VALUES (11, 1, 'expense', 400.0, 5, 'keeper', 1783008000, 1783999999, 'T1D')");
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, to_account_id, "
        "happened_at, recorded_at, sync_id) "
        "VALUES (12, 1, 'expense', 400.0, 6, 1782000000, 1783000000, 'T1D')");

    await seed.customStatement('PRAGMA user_version = 44');
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    Object? openErr;
    try {
      await db.customSelect('SELECT 1').get();
    } catch (e) {
      openErr = e;
    }
    expect(openErr, isNull,
        reason: '不变量闸门不得让迁移抛错(抛错 = 库永久打不开)');

    // ── A:金额不同的 loser 币种/折算不采纳;账本统计返回 keeper 的 999 ──
    final a = await db
        .customSelect(
            "SELECT id, amount, currency_code, native_amount FROM transactions WHERE sync_id='T1A'")
        .getSingle();
    expect(a.read<int>('id'), 1, reason: '1a: keeper=1(更完整)');
    expect(a.read<double>('amount'), 999.0, reason: '1a: 保留 keeper 金额');
    expect(a.readNullable<String>('currency_code'), isNull,
        reason: '1a/原子三元组: loser 的 USD 属于金额 10,不得贴到 999 上');
    expect(a.readNullable<double>('native_amount'), isNull,
        reason: '1a/原子三元组: loser 的 72 属于金额 10,不得贴到 999 上');
    final aSum = await db
        .customSelect(
            "SELECT COALESCE(SUM(COALESCE(native_amount, amount)), 0) AS s FROM transactions WHERE ledger_id=1 AND sync_id='T1A'")
        .getSingle();
    expect(aSum.read<double>('s'), 999.0,
        reason: '1a: 账本维度统计(local_statistics_repository 的 '
            'COALESCE(native_amount, amount)) 必须返回 999,不是 loser 的 72');

    // ── B:同金额的 loser 三元组应当被采纳(修复不能过度拒绝) ──
    final b = await db
        .customSelect(
            "SELECT id, amount, currency_code, native_amount FROM transactions WHERE sync_id='T1A-OK'")
        .getSingle();
    expect(b.read<int>('id'), 3, reason: '1a: keeper=3');
    expect(b.readNullable<String>('currency_code'), 'USD',
        reason: '1a: 同金额 loser 的币种是 keeper 金额的正确属性,应当采纳');
    expect(b.readNullable<double>('native_amount'), 3600.0,
        reason: '1a: 同金额 loser 的折算应当采纳(与币种同源)');
    final bSum = await db
        .customSelect(
            "SELECT COALESCE(SUM(COALESCE(native_amount, amount)), 0) AS s FROM transactions WHERE ledger_id=1 AND sync_id='T1A-OK'")
        .getSingle();
    expect(bSum.read<double>('s'), 3600.0,
        reason: '1a: 同金额合并后的统计 = 该金额自身的折算值');

    // ── C:自转账被拒 ──
    final c = await db
        .customSelect(
            "SELECT id, account_id, to_account_id FROM transactions WHERE sync_id='T1B'")
        .getSingle();
    expect(c.read<int>('id'), 5, reason: '1b: keeper=5');
    expect(c.readNullable<int>('account_id'), 5);
    expect(c.readNullable<int>('to_account_id'), isNull,
        reason: '1b/I2: 填入 to_account_id=5 会造出自转账(account_id == '
            'to_account_id),必须拒绝');

    // ── D:合法的转入账户仍应被填(修复不能过度拒绝) ──
    final dRow = await db
        .customSelect(
            "SELECT id, account_id, to_account_id FROM transactions WHERE sync_id='T1B-OK'")
        .getSingle();
    expect(dRow.readNullable<int>('to_account_id'), 6,
        reason: '1b: to_account_id=6 ≠ account_id=5,合法填充应生效');

    // ── E:双表示互斥(keeper 已有本地 id → 拒绝 override 填充) ──
    final eRow = await db
        .customSelect(
            "SELECT id, account_id, account_sync_id_override FROM transactions WHERE sync_id='T1C'")
        .getSingle();
    expect(eRow.read<int>('id'), 9);
    expect(eRow.readNullable<int>('account_id'), 6,
        reason: 'I3: keeper 的本地 id 保留');
    expect(eRow.readNullable<String>('account_sync_id_override'), isNull,
        reason: 'I3: 同一引用不得同时有本地 id 与 syncId override(两个口径)');

    // ── F:非 transfer 行不得带转入引用 ──
    final fRow = await db
        .customSelect(
            "SELECT id, type, to_account_id FROM transactions WHERE sync_id='T1D'")
        .getSingle();
    expect(fRow.read<String>('type'), 'expense');
    expect(fRow.readNullable<int>('to_account_id'), isNull,
        reason: 'I2: expense 行带 to_account_id 会让 getAccountBalance(过滤 '
            'transfer)与 getAccountBalanceInLedger(裸命中)永久分歧');

    // ── 结构不变量终局断言:全库不得出现自转账,也不得出现双表示 ──
    final selfTransfer = await db
        .customSelect(
            'SELECT COUNT(*) c FROM transactions WHERE account_id IS NOT NULL '
            'AND to_account_id IS NOT NULL AND account_id = to_account_id')
        .getSingle();
    expect(selfTransfer.data['c'], 0,
        reason: 'I2: 合并后全库无自转账行');
    final dualRepr = await db
        .customSelect(
            'SELECT COUNT(*) c FROM transactions WHERE '
            '(account_id IS NOT NULL AND account_sync_id_override IS NOT NULL) OR '
            '(category_id IS NOT NULL AND category_sync_id_override IS NOT NULL) OR '
            '(to_account_id IS NOT NULL AND to_account_sync_id_override IS NOT NULL)')
        .getSingle();
    expect(dualRepr.data['c'], 0,
        reason: 'I3: 合并后全库无「本地 id + override」双表示行');

    // ── 幂等:再开一次不改变终态(闸门不产生新的合并/丢弃) ──
    final before = await db
        .customSelect(
            'SELECT id, amount, currency_code, native_amount, account_id, to_account_id '
            'FROM transactions ORDER BY id')
        .get();
    await db.close();
    final again = BeeDatabase.forTesting(NativeDatabase(file));
    await again.customSelect('SELECT 1').get();
    final after = await again
        .customSelect(
            'SELECT id, amount, currency_code, native_amount, account_id, to_account_id '
            'FROM transactions ORDER BY id')
        .get();
    expect(after.length, before.length, reason: '不变量闸门保持迁移幂等');
    for (var i = 0; i < before.length; i++) {
      expect(after[i].data, before[i].data,
          reason: '不变量闸门保持迁移幂等(第 $i 行)');
    }
    await again.close();
  });

  test('V12 反向自转账:keeper 自带 to_account,账户侧从 loser 填入同一账户须撤回',
      () async {
    // 跨审缺陷 1b 的反方向。V11 覆盖的是「转入引用被填入」;这里覆盖
    // 「keeper 自带 to_account_id=5,而 account_id 侧从 loser 填进 5」——
    // 只堵一个方向会留下同一条自转账的另一半入口。
    final dir = await Directory.systemTemp.createTemp('smartbook_mig_v12');
    addTearDown(() => _tryDelete(dir));
    final file = File('${dir.path}/v12.sqlite');
    final seed = BeeDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement(
        'DROP INDEX IF EXISTS idx_transactions_ledger_sync_id');
    await seed.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await seed.customStatement(
        "INSERT INTO accounts (id, ledger_id, name, currency, sync_id) "
        "VALUES (5, 1, 'A5', 'CNY', 'ACC-5')");
    // keeper:transfer,to_account_id=5 已有,account_id 为空(比 loser 更完整)。
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, to_account_id, "
        "category_id, note, happened_at, recorded_at, sync_id) "
        "VALUES (1, 1, 'transfer', 100.0, 5, 9, 'keeper', 1783008000, 1783999999, 'T2')");
    // loser:account_id=5 —— 填入即自转账。
    await seed.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, account_id, "
        "happened_at, recorded_at, sync_id) "
        "VALUES (2, 1, 'transfer', 100.0, 5, 1782000000, 1783000000, 'T2')");
    await seed.customStatement('PRAGMA user_version = 44');
    await seed.close();

    final db = BeeDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    Object? openErr;
    try {
      await db.customSelect('SELECT 1').get();
    } catch (e) {
      openErr = e;
    }
    expect(openErr, isNull, reason: '不变量闸门不得让迁移抛错');

    final row = await db
        .customSelect(
            "SELECT id, account_id, to_account_id FROM transactions WHERE sync_id='T2'")
        .getSingle();
    expect(row.read<int>('id'), 1, reason: 'keeper=1');
    expect(row.readNullable<int>('to_account_id'), 5,
        reason: 'keeper 自带的转入账户保留(不被覆盖)');
    expect(row.readNullable<int>('account_id'), isNull,
        reason: '1b/反向: 填入 account_id=5 会与 to_account_id=5 造出自转账,'
            '必须撤回 loser 的填充');
    final selfTransfer = await db
        .customSelect(
            'SELECT COUNT(*) c FROM transactions WHERE account_id IS NOT NULL '
            'AND to_account_id IS NOT NULL AND account_id = to_account_id')
        .getSingle();
    expect(selfTransfer.data['c'], 0, reason: 'I2: 全库无自转账行');
  });
}

/// Windows 上 SQLite 文件句柄释放有延迟,临时目录删除失败不能算测试失败。
Future<void> _tryDelete(Directory dir) async {
  for (var i = 0; i < 5; i++) {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }
}
