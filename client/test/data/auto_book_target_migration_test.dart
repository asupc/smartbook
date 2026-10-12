import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';

/// v44:自动目标快照列(target_ref / target_config_version / target_state)。
///
/// B0 §5.2 —— 只有目标稳定标识、配置版本无法由既有字段安全表达时才加列;
/// 存量行不回填历史目标(计划 §5.4:不批量改账本),因此升级后这些列必须
/// 为 NULL + 默认 'resolved'。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('v43 to v44 增加目标快照列且不回填历史行', () async {
    final executor = NativeDatabase.memory(setup: (database) {
      database.execute('''
        CREATE TABLE auto_book_events (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          event_key TEXT NOT NULL UNIQUE,
          source TEXT NOT NULL,
          capture_intent TEXT NOT NULL DEFAULT 'automatic',
          ledger_id INTEGER,
          source_channel TEXT,
          external_id TEXT,
          content_hash TEXT,
          state TEXT NOT NULL DEFAULT 'captured',
          captured_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
      ''');
      database.execute('PRAGMA user_version = 43;');
    });

    final db = BeeDatabase.forTesting(executor);
    addTearDown(db.close);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);

    final columns =
        await db.customSelect('PRAGMA table_info(auto_book_events)').get();
    final byName = {
      for (final row in columns) row.read<String>('name'): row,
    };
    expect(byName.keys,
        containsAll(['target_ref', 'target_config_version', 'target_state']));
    expect(byName['target_state']!.read<String>('dflt_value'), "'resolved'");
    expect(byName['target_ref']!.read<int>('notnull'), 0);
    expect(byName['target_config_version']!.read<int>('notnull'), 0);

    // 存量行不回填:目标快照留空,由 B0 §3.4 的迁移路径另行决定。
    final rows = await db
        .select(db.autoBookEvents)
        .get();
    for (final row in rows) {
      expect(row.targetRef, isNull);
      expect(row.targetConfigVersion, isNull);
      expect(row.targetState, 'resolved');
    }
  });

  test('v44 迁移重复执行安全(列已存在时跳过)', () async {
    final executor = NativeDatabase.memory(setup: (database) {
      database.execute('''
        CREATE TABLE auto_book_events (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          event_key TEXT NOT NULL UNIQUE,
          source TEXT NOT NULL,
          capture_intent TEXT NOT NULL DEFAULT 'automatic',
          ledger_id INTEGER,
          source_channel TEXT,
          external_id TEXT,
          content_hash TEXT,
          state TEXT NOT NULL DEFAULT 'captured',
          captured_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL DEFAULT CURRENT_TIMESTAMP,
          target_ref TEXT,
          target_config_version INTEGER,
          target_state TEXT DEFAULT 'resolved'
        );
      ''');
      // 模拟「上一次升级已加过列但没写版本号」的半提交状态。
      database.execute('PRAGMA user_version = 43;');
    });

    final db = BeeDatabase.forTesting(executor);
    addTearDown(db.close);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);

    final columns =
        await db.customSelect('PRAGMA table_info(auto_book_events)').get();
    final names = columns.map((row) => row.read<String>('name')).toList();
    expect(names.where((n) => n == 'target_ref').length, 1);
    expect(names.where((n) => n == 'target_state').length, 1);
  });
}
