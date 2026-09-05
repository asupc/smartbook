import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';
import 'package:smartbook/services/data_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late BeeDatabase db;
  late LocalRepository repo;
  late DataImportService service;
  late AutoBookEventStore eventStore;

  setUp(() async {
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    service = DataImportService();
    eventStore = AutoBookEventStore(db);
    await db.customStatement(
      "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')",
    );
  });

  tearDown(() async => db.close());

  ImportTransaction order({String status = '交易成功'}) => ImportTransaction(
        type: 'expense',
        amount: 30,
        happenedAt: DateTime(2026, 9, 3, 12),
        note: '咖啡',
        provider: 'alipay',
        externalId: 'ORDER-001',
        status: status,
      );

  test('同一 provider + externalId 重复导入只落一笔交易', () async {
    final first = await service.importTransactions(
      repo,
      1,
      [order()],
      accountNameToId: {},
      categoryCache: {},
      tagNameToId: {},
      eventStore: eventStore,
    );
    final second = await service.importTransactions(
      repo,
      1,
      [order()],
      accountNameToId: {},
      categoryCache: {},
      tagNameToId: {},
      eventStore: eventStore,
    );

    expect(first.inserted, 1);
    expect(second.inserted, 0);
    expect(second.duplicated, 1);

    final transactions = await (db.select(db.transactions)).get();
    expect(transactions, hasLength(1));

    final events = await (db.select(db.autoBookEvents)).get();
    expect(events, hasLength(1));
    expect(events.single.state, 'booked');
    expect(events.single.externalId, 'ORDER-001');

    final items = await eventStore.itemsForEvent(events.single.id);
    expect(items, hasLength(1));
    expect(items.single.transactionId, transactions.single.id);
    expect(
      await eventStore.findTransactionByExternalId(
        'order-001',
        ledgerId: 1,
        sourceChannel: 'alipay',
      ),
      transactions.single.id,
    );
  });

  test('批量导入 retry 恢复已成功子项时不再插入第二笔', () async {
    final first = await service.importTransactions(
      repo,
      1,
      [order()],
      accountNameToId: {},
      categoryCache: {},
      tagNameToId: {},
      eventStore: eventStore,
    );
    expect(first.inserted, 1);

    // 模拟进程在交易和 event item 已写入、父事件状态尚未完成时被杀。
    await db.customStatement(
      "UPDATE auto_book_events SET state = 'retry', "
      'transaction_id = NULL, next_retry_at = NULL',
    );
    final replay = await service.importTransactions(
      repo,
      1,
      [order()],
      accountNameToId: {},
      categoryCache: {},
      tagNameToId: {},
      eventStore: eventStore,
    );

    expect(replay.inserted, 0);
    expect(replay.duplicated, 1);
    expect(await (db.select(db.transactions)).get(), hasLength(1));
    final event = (await (db.select(db.autoBookEvents)).get()).single;
    expect(event.state, 'booked');
    expect(event.transactionId, isNotNull);
  });

  test('导入预览区分新增、已存在、忽略和无效行', () async {
    await service.importTransactions(
      repo,
      1,
      [order()],
      accountNameToId: {},
      categoryCache: {},
      tagNameToId: {},
      eventStore: eventStore,
    );
    final preview = await service.previewTransactions(
      repo,
      1,
      [
        order(),
        ImportTransaction(
          type: 'expense',
          amount: 12,
          happenedAt: DateTime(2026, 9, 3, 13),
          provider: 'alipay',
          externalId: 'ORDER-NEW',
          status: '交易成功',
        ),
        order(status: '待支付'),
        ImportTransaction(
          type: 'expense',
          amount: 0,
          happenedAt: DateTime(1970, 1, 1),
          provider: 'alipay',
          externalId: 'ORDER-BAD',
        ),
      ],
      eventStore: eventStore,
    );

    expect(preview.newCount, 1);
    expect(preview.duplicateCount, 1);
    expect(preview.ignoredCount, 1);
    expect(preview.invalidCount, 1);
  });

  test('待支付/失败导入行被忽略且不创建事件或交易', () async {
    final result = await service.importTransactions(
      repo,
      1,
      [order(status: '待支付'), order(status: '支付失败')],
      accountNameToId: {},
      categoryCache: {},
      tagNameToId: {},
      eventStore: eventStore,
    );

    expect(result.inserted, 0);
    expect(result.ignored, 2);
    expect(await (db.select(db.transactions)).get(), isEmpty);
    expect(await (db.select(db.autoBookEvents)).get(), isEmpty);
  });
}
