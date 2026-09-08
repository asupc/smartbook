import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('v33 to v40 adds raw evidence columns idempotently', () async {
    final executor = NativeDatabase.memory(setup: (database) {
      database.execute('''
        CREATE TABLE auto_book_events (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          event_key TEXT NOT NULL UNIQUE,
          source TEXT NOT NULL,
          raw_title TEXT
        );
        -- v40 迁移会 ALTER transactions,预建空表满足存在性。
        CREATE TABLE transactions (id INTEGER NOT NULL PRIMARY KEY);
      ''');
      // raw_title simulates a partially committed v34 migration. The
      // _addColumnIfMissing guard must skip it and continue with all others.
      database.execute('PRAGMA user_version = 33;');
    });
    final db = BeeDatabase.forTesting(executor);
    addTearDown(db.close);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    final columns =
        await db.customSelect('PRAGMA table_info(auto_book_events)').get();
    final names = columns.map((row) => row.read<String>('name')).toSet();

    expect(version.read<int>('user_version'), 41);
    expect(
      names,
      containsAll(const [
        'raw_title',
        'raw_text',
        'raw_actor',
        'raw_metadata_json',
        'raw_evidence_local_enabled',
        'raw_evidence_server_enabled',
        'raw_evidence_local_expires_at',
        'raw_evidence_server_expires_at',
        'raw_evidence_retention_until',
        'raw_evidence_upload_state',
        'raw_evidence_uploaded_at',
        'raw_evidence_upload_attempts',
        'raw_evidence_last_error',
        'raw_evidence_next_retry_at',
      ]),
    );

    final localEnabled = columns.singleWhere(
      (row) => row.read<String>('name') == 'raw_evidence_local_enabled',
    );
    final uploadState = columns.singleWhere(
      (row) => row.read<String>('name') == 'raw_evidence_upload_state',
    );
    expect(localEnabled.read<int>('dflt_value'), 0);
    expect(uploadState.read<String>('dflt_value'), "'not_requested'");
  });

  test('v35 to v40 backfills independent expiry windows', () async {
    final executor = NativeDatabase.memory(setup: (database) {
      database.execute('''
        CREATE TABLE auto_book_events (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          event_key TEXT NOT NULL UNIQUE,
          source TEXT NOT NULL,
          raw_evidence_local_enabled INTEGER NOT NULL DEFAULT 0,
          raw_evidence_server_enabled INTEGER NOT NULL DEFAULT 0,
          raw_evidence_retention_until INTEGER
        );
        CREATE TABLE transactions (id INTEGER NOT NULL PRIMARY KEY);
        INSERT INTO auto_book_events (
          event_key,
          source,
          raw_evidence_local_enabled,
          raw_evidence_server_enabled,
          raw_evidence_retention_until
        ) VALUES ('sms:v35', 'sms', 1, 1, 2000000000);
      ''');
      database.execute('PRAGMA user_version = 35;');
    });
    final db = BeeDatabase.forTesting(executor);
    addTearDown(db.close);

    final row = await db.customSelect('''
      SELECT raw_evidence_local_expires_at, raw_evidence_server_expires_at
      FROM auto_book_events WHERE event_key = 'sms:v35'
    ''').getSingle();

    expect(row.read<int>('raw_evidence_local_expires_at'), 2000000000);
    expect(row.read<int>('raw_evidence_server_expires_at'), 2000000000);
  });
}
