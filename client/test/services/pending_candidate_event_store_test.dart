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
    final event = await eventStore.ensure(
      AutoBookInput(
        eventKey: 'sms:v3:candidate-projection',
        source: AutoBookSource.sms,
        capturedAt: DateTime(2026, 9, 4, 12),
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
      time: DateTime(2026, 9, 4, 11, 59),
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
        'captured_at': '2026-09-04T12:00:00.000',
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
        capturedAt: DateTime(2026, 9, 4, 12),
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
}
