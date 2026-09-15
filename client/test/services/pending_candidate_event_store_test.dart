import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/ai/core/bill_info.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';
import 'package:smartbook/services/billing/pending_candidate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late AutoBookEventStore eventStore;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    eventStore = AutoBookEventStore(db);
  });

  tearDown(() => db.close());

  test('event store pending item 可投影到候选中心并覆盖旧副本', () async {
    // C8 后 pending 按 capturedAt 30 天过期,固定日期会成为时间炸弹 ——
    // 改相对时间(1 天前,远在 TTL 内)。
    final fresh = DateTime.now().subtract(const Duration(days: 1));
    final event = await eventStore.ensure(
      AutoBookInput(
        eventKey: 'sms:v3:candidate-projection',
        source: AutoBookSource.sms,
        capturedAt: fresh,
      ),
    );
    await eventStore.mark(
      const AutoBookEventUpdate(
        state: AutoBookState.pending,
        reason: 'pending_confirmation',
      ),
      eventId: event.id,
    );
    final bill = BillInfo(
      amount: -30,
      time: fresh,
      note: '星巴克',
      type: BillType.expense,
      ledgerId: 1,
    );
    await eventStore.upsertItem(
      eventId: event.id,
      itemIndex: 0,
      semanticKey: 'semantic:one',
      amount: -30,
      merchant: '星巴克',
      state: AutoBookState.pending.value,
      reason: 'duplicate',
      bill: {
        ...bill.toJson(),
        'candidate_id': 'candidate-event-1',
        'billing_types': ['sms'],
        'source': 'sms',
        'matched_transaction_id': 88,
        'match_score': 0.86,
      },
    );

    final legacy = PendingCandidateStore();
    await legacy.add(
      PendingCandidate(
        id: 'legacy-copy',
        bill: bill,
        source: 'sms',
        capturedAt: fresh,
        reason: 'duplicate',
        eventKey: event.eventKey,
        eventItemIndex: 0,
      ),
    );

    final result = await legacy.loadForReview(eventStore);
    expect(result, hasLength(1));
    expect(result.single.id, 'candidate-event-1');
    expect(result.single.matchedTransactionId, 88);
    expect(result.single.matchScore, closeTo(0.86, 0.0001));
    expect(result.single.eventItemIndex, 0);
  });

  test('C8:pending 事件超过 30 天 TTL 转 expired,不再进 loadForReview', () async {
    final stale = await eventStore.ensure(
      AutoBookInput(
        eventKey: 'sms:v3:stale-pending',
        source: AutoBookSource.sms,
        capturedAt: DateTime.now().subtract(const Duration(days: 31)),
      ),
    );
    await eventStore.mark(
      const AutoBookEventUpdate(state: AutoBookState.pending),
      eventId: stale.id,
    );
    final expiredCount = await eventStore.expireStalePending();
    expect(expiredCount, 1);

    final after = await eventStore.findById(stale.id);
    expect(after?.state, AutoBookState.expired.value);
    expect(after?.reason, 'pending_expired');

    final store = PendingCandidateStore();
    expect(await store.loadForReview(eventStore), isEmpty,
        reason: 'TTL 过期的 pending 不再占确认页/角标');
  });

  test('C8:loadForReview 自带 TTL 过期(不必先手动调 expireStalePending)', () async {
    final stale = await eventStore.ensure(
      AutoBookInput(
        eventKey: 'notify:v3:stale-auto',
        source: AutoBookSource.notification,
        capturedAt: DateTime.now().subtract(const Duration(days: 40)),
      ),
    );
    await eventStore.mark(
      const AutoBookEventUpdate(state: AutoBookState.pending),
      eventId: stale.id,
    );

    final store = PendingCandidateStore();
    expect(await store.loadForReview(eventStore), isEmpty);
    expect((await eventStore.findById(stale.id))?.state,
        AutoBookState.expired.value);
  });

  test('C8:itemsForEvents 一次批查返回按 eventId 分组的子项', () async {
    final ids = <int>[];
    for (var i = 0; i < 3; i++) {
      final event = await eventStore.ensure(
        AutoBookInput(
          eventKey: 'screen:v3:batch-$i',
          source: AutoBookSource.screenText,
          capturedAt: DateTime.now(),
        ),
      );
      ids.add(event.id);
      await eventStore.upsertItem(
        eventId: event.id,
        itemIndex: 0,
        state: AutoBookState.pending.value,
        amount: -10.0 - i,
      );
      await eventStore.upsertItem(
        eventId: event.id,
        itemIndex: 1,
        state: AutoBookState.booked.value,
        transactionId: 100 + i,
        amount: -20.0 - i,
      );
    }
    final grouped = await eventStore.itemsForEvents(ids);
    expect(grouped.keys.toSet(), ids.toSet());
    for (final id in ids) {
      expect(grouped[id], hasLength(2), reason: '两个子项都应返回');
      expect(grouped[id]!.map((i) => i.itemIndex), [0, 1],
          reason: '组内按 itemIndex 升序');
    }
  });
}
