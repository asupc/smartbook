import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/services/automation/auto_book_coordinator.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late BeeDatabase db;
  late AutoBookEventStore store;
  late AutoBookCoordinator coordinator;

  setUp(() {
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    store = AutoBookEventStore(db);
    coordinator = AutoBookCoordinator(db);
  });

  tearDown(() async {
    coordinator.dispose();
    await db.close();
  });

  AutoBookInput input(String key) => AutoBookInput(
        eventKey: key,
        source: AutoBookSource.sms,
        capturedAt: DateTime(2026, 9, 4, 12),
      );

  test('ensure 对相同 eventKey 幂等', () async {
    final first = await store.ensure(input('sms:v2:one'));
    final second = await store.ensure(input('sms:v2:one'));

    expect(second.id, first.id);
    expect((await (db.select(db.autoBookEvents)).get()), hasLength(1));
  });

  test('Coordinator 同一事件只执行一次', () async {
    var calls = 0;
    final first = await coordinator.execute<String>(
      input: input('sms:v2:two'),
      action: () async {
        calls++;
        return 'ok';
      },
      updateFor: (_) => const AutoBookEventUpdate(
        state: AutoBookState.booked,
        transactionId: 42,
      ),
    );
    final second = await coordinator.execute<String>(
      input: input('sms:v2:two'),
      action: () async {
        calls++;
        return 'should-not-run';
      },
      updateFor: (_) => const AutoBookEventUpdate(
        state: AutoBookState.booked,
        transactionId: 43,
      ),
    );

    expect(calls, 1);
    expect(first.state, AutoBookState.booked);
    expect(first.value, 'ok');
    expect(second.skipped, isTrue);
    expect(second.existingTransactionId, 42);
  });

  test('pending 事件是终态，不会被自动重放', () async {
    final execution = await coordinator.execute<String>(
      input: input('sms:pending'),
      action: () async => 'pending',
      updateFor: (_) => const AutoBookEventUpdate(
        state: AutoBookState.pending,
        reason: 'settlement_unknown',
      ),
    );
    final replay = await coordinator.execute<String>(
      input: input('sms:pending'),
      action: () async => 'must-not-run',
      updateFor: (_) => const AutoBookEventUpdate(
        state: AutoBookState.booked,
      ),
    );

    expect(execution.state, AutoBookState.pending);
    expect(replay.skipped, isTrue);
    expect(replay.state, AutoBookState.pending);
  });

  test('event item external_id 可跨来源精确找到已有交易', () async {
    final event = await store.ensure(
      AutoBookInput(
        eventKey: 'notification:one',
        source: AutoBookSource.notification,
        sourceChannel: 'wechat',
        capturedAt: DateTime(2026, 9, 4, 12),
      ),
    );
    await store.upsertItem(
      eventId: event.id,
      itemIndex: 0,
      transactionId: 99,
      state: AutoBookState.booked.value,
      bill: {'external_id': 'WX-ORDER-001'},
    );
    await store.mark(
      const AutoBookEventUpdate(state: AutoBookState.booked),
      eventId: event.id,
    );

    expect(
      await store.findTransactionByExternalId(
        'wx-order-001',
        ledgerId: null,
        sourceChannel: 'wechat',
      ),
      99,
    );
    expect(
      await store.findTransactionByExternalId(
        'wx-order-001',
        sourceChannel: 'alipay',
      ),
      isNull,
    );
  });

  test('历史摘要可按状态筛选且不依赖原始证据正文', () async {
    final booked = await store.ensure(input('history:booked'));
    await store.mark(
      const AutoBookEventUpdate(
        state: AutoBookState.booked,
        transactionId: 11,
        reason: 'success',
      ),
      eventId: booked.id,
    );
    final ignored = await store.ensure(input('history:ignored'));
    await store.mark(
      const AutoBookEventUpdate(
        state: AutoBookState.ignored,
        reason: 'statement_or_balance',
        billJson: 'sensitive body must not be displayed',
      ),
      eventId: ignored.id,
    );

    expect((await store.listHistory(state: 'booked')), hasLength(1));
    expect((await store.listHistory(state: 'ignored')).single.reason,
        'statement_or_balance');
    final counts = await store.countByState();
    expect(counts['booked'], 1);
    expect(counts['ignored'], 1);
  });

  test('候选状态可查询且 event item 按索引幂等', () async {
    final event = await store.ensure(input('screen:v2:three'));
    await store.mark(
      const AutoBookEventUpdate(
        state: AutoBookState.pending,
        reason: 'pending_confirmation',
      ),
      eventId: event.id,
    );
    expect(await store.countPending(), 1);

    await store.upsertItem(
      eventId: event.id,
      itemIndex: 0,
      semanticKey: 'semantic:one',
      amount: -30,
      state: AutoBookState.pending.value,
    );
    await store.upsertItem(
      eventId: event.id,
      itemIndex: 0,
      semanticKey: 'semantic:one-updated',
      amount: -31,
      state: AutoBookState.booked.value,
      transactionId: 7,
    );

    final items = await store.itemsForEvent(event.id);
    expect(items, hasLength(1));
    expect(items.single.semanticKey, 'semantic:one-updated');
    expect(items.single.transactionId, 7);
  });
}
