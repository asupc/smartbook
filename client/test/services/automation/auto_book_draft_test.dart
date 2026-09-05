/// 离线识别草稿(auto_book_events.draft_payload_json)store 行为测试。
///
/// 覆盖:
/// - saveDraftByEventKey:写入 + 非法 key 返回 false + 终态事件拒绝复活;
/// - listDrafts:按时间倒序,只含非终态事件;
/// - dueDrafts:只含 retry/failed 且退避到期的;
/// - mark():终态自动清草稿,retry 状态保留草稿;
/// - clearDraft / resetRetryGate。
library;
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/data/db.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late AutoBookEventStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    store = AutoBookEventStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  AutoBookInput input(String key) => AutoBookInput(
        eventKey: key,
        source: AutoBookSource.sms,
        capturedAt: DateTime.now().toUtc(),
        rawText: '短信正文',
      );

  AutoBookDraftPayload payload(String text) =>
      AutoBookDraftPayload(isImage: false, text: text);

  test('saveDraftByEventKey writes payload; unknown key returns false', () async {
    final execution = await store.claim(input('sms:v1:kw-1'));
    expect(execution.acquired, isTrue);

    expect(await store.saveDraftByEventKey('sms:v1:kw-1', payload('奶茶 28')), isTrue);
    final drafts = await store.listDrafts();
    expect(drafts, hasLength(1));
    expect(drafts.first.draftPayloadJson, contains('奶茶 28'));

    expect(await store.saveDraftByEventKey('sms:v1:missing', payload('x')), isFalse);
  });

  test('draft on terminal event is rejected', () async {
    final execution = await store.claim(input('sms:v1:kw-2'));
    await store.mark(
      const AutoBookEventUpdate(state: AutoBookState.booked, transactionId: 9),
      eventId: execution.event.id,
    );
    expect(
      await store.saveDraftByEventKey('sms:v1:kw-2', payload('x')),
      isFalse,
    );
  });

  test('mark() clears draft on terminal state but keeps it on retry', () async {
    final execution = await store.claim(input('sms:v1:kw-3'));
    await store.saveDraftByEventKey('sms:v1:kw-3', payload('星巴克 30'));

    // retry 状态保留草稿
    await store.mark(
      const AutoBookEventUpdate(state: AutoBookState.retry),
      eventId: execution.event.id,
    );
    expect(await store.listDrafts(), hasLength(1));

    // duplicate 终态清草稿
    await store.mark(
      const AutoBookEventUpdate(state: AutoBookState.duplicate),
      eventId: execution.event.id,
    );
    expect(await store.listDrafts(), isEmpty);
  });

  test('dueDrafts only returns retry/failed rows past their backoff window',
      () async {
    final execution = await store.claim(input('sms:v1:kw-4'));
    await store.saveDraftByEventKey('sms:v1:kw-4', payload('打车 35'));

    // captured 状态不在 dueDrafts 里
    expect(await store.dueDrafts(), isEmpty);

    // retry + 退避未到期 → 不算 due
    await (db.update(db.autoBookEvents)
          ..where((t) => t.id.equals(execution.event.id)))
        .write(AutoBookEventsCompanion(
      state: const d.Value('retry'),
      nextRetryAt: d.Value(DateTime.now().toUtc().add(const Duration(hours: 1))),
    ));
    expect(await store.dueDrafts(), isEmpty);

    // 退避到期(置空)→ due
    await store.resetRetryGate(execution.event.id);
    final due = await store.dueDrafts();
    expect(due, hasLength(1));
    expect(due.first.id, execution.event.id);

    // 手动丢弃后不再出现
    await store.clearDraft(execution.event.id);
    expect(await store.dueDrafts(), isEmpty);
  });

  test('listDrafts orders newest first and skips terminal rows', () async {
    final e1 = await store.claim(input('sms:v1:kw-5'));
    await store.saveDraftByEventKey('sms:v1:kw-5', payload('第一笔'));
    final e2 = await store.claim(
      input('sms:v1:kw-6').copyWithCapturedAt(
        DateTime.now().toUtc().add(const Duration(minutes: 1)),
      ),
    );
    await store.saveDraftByEventKey('sms:v1:kw-6', payload('第二笔'));
    await store.mark(
      const AutoBookEventUpdate(state: AutoBookState.booked),
      eventId: e1.event.id,
    );

    final drafts = await store.listDrafts();
    expect(drafts, hasLength(1));
    expect(drafts.first.eventKey, 'sms:v1:kw-6');
  });
}

extension _AutoBookInputX on AutoBookInput {
  AutoBookInput copyWithCapturedAt(DateTime at) => AutoBookInput(
        eventKey: eventKey,
        source: source,
        captureIntent: captureIntent,
        ledgerId: ledgerId,
        capturedAt: at,
        sourceOccurredAt: sourceOccurredAt,
        sourceChannel: sourceChannel,
        externalId: externalId,
        contentHash: contentHash,
        rawTitle: rawTitle,
        rawText: rawText,
        rawActor: rawActor,
        rawMetadata: rawMetadata,
        expiresAt: expiresAt,
      );
}
