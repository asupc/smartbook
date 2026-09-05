import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/ai/core/ai_extraction_context.dart';
import 'package:smartbook/ai/core/ai_extraction_engine.dart';
import 'package:smartbook/ai/core/bill_info.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';
import 'package:smartbook/services/ai/ai_bookkeeper.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';
import 'package:smartbook/services/billing/bill_creation_service.dart';
import 'package:smartbook/services/billing/pending_candidate.dart';

class _FixedEngine implements AiExtractionEngine {
  final List<BillInfo> bills;

  const _FixedEngine(this.bills);

  @override
  Future<AiExtractionOutcome> extractFromText(
    String text,
    AiExtractionContext ctx, {
    String billGuard = '',
  }) async =>
      AiExtractionOutcome(bills: bills);

  @override
  Future<List<BillInfo>> extractFromImage(
    File image,
    AiExtractionContext ctx, {
    String billGuard = '',
  }) async =>
      bills;

  @override
  Future<AudioExtractionResult> extractFromAudio(
    File audio,
    AiExtractionContext ctx,
  ) async =>
      AudioExtractionResult(bills: bills);

  @override
  Future<String?> speechToText(File audio) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late LocalRepository repo;
  late int ledgerId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    ledgerId = await repo.createLedger(name: 'item-recovery');
    await repo.createCategory(name: '餐饮', kind: 'expense');
  });

  tearDown(() async => db.close());

  test('影子模式只记录识别摘要,不创建交易或候选', () async {
    final bill = BillInfo(
      amount: -18,
      time: DateTime(2026, 9, 4, 10),
      note: '影子测试',
      merchant: '影子测试',
      category: '餐饮',
      type: BillType.expense,
      eventKind: BillEventKind.purchase,
      settlementStatus: BillSettlementStatus.settled,
      confidenceProvided: true,
      timePrecision: BillTimePrecision.minute,
    );
    final eventStore = AutoBookEventStore(db);
    const eventKey = 'sms:v3:shadow';
    final event = await eventStore.ensure(
      AutoBookInput(
        eventKey: eventKey,
        source: AutoBookSource.sms,
        ledgerId: ledgerId,
        capturedAt: DateTime(2026, 9, 4, 10),
      ),
    );
    final bookkeeper = AiBookkeeper(
      repository: repo,
      engine: _FixedEngine([bill]),
      persister: BillCreationService(repo),
      eventStore: eventStore,
    );

    final result = await bookkeeper.fromText(
      text: '支付成功 影子测试 18 元',
      ledgerId: ledgerId,
      billingTypes: const ['sms'],
      autoBookFlow: AutoBookFlow(
        store: PendingCandidateStore(),
        eventKey: eventKey,
        eventStore: eventStore,
        shadowMode: true,
      ),
      source: 'sms',
      evidenceText: '支付成功 影子测试 18 元',
    );

    expect(result.savedCount, 0);
    expect(result.shadowCount, 1);
    expect(result.handled, isTrue);
    expect(await (db.select(db.transactions)).get(), isEmpty);
    expect(await PendingCandidateStore().count(), 0);
    final items = await eventStore.itemsForEvent(event.id);
    expect(items.single.reason, contains('shadow_mode'));
  });

  test('自动事件 retry 时复用已完成 event item,不重复创建交易', () async {
    final time = DateTime(2026, 9, 3, 12);
    final bill = BillInfo(
      amount: -30,
      time: time,
      note: '星巴克',
      merchant: '星巴克',
      category: '餐饮',
      type: BillType.expense,
      eventKind: BillEventKind.purchase,
      settlementStatus: BillSettlementStatus.settled,
      confidenceProvided: true,
      timePrecision: BillTimePrecision.minute,
    );
    final engine = _FixedEngine([bill]);
    final eventStore = AutoBookEventStore(db);
    const eventKey = 'sms:v3:item-recovery';
    final event = await eventStore.ensure(
      AutoBookInput(
        eventKey: eventKey,
        source: AutoBookSource.sms,
        ledgerId: ledgerId,
        capturedAt: time,
      ),
    );
    final bookkeeper = AiBookkeeper(
      repository: repo,
      engine: engine,
      persister: BillCreationService(repo),
      eventStore: eventStore,
    );
    final flow = AutoBookFlow(
      store: PendingCandidateStore(),
      eventKey: eventKey,
      eventStore: eventStore,
    );

    final first = await bookkeeper.fromText(
      text: '支付成功 星巴克 30 元',
      ledgerId: ledgerId,
      billingTypes: const ['sms'],
      autoBookFlow: flow,
      source: 'sms',
      evidenceText: '支付成功 星巴克 30 元',
    );
    expect(first.savedCount, 1);

    // 模拟交易/event item 已完成但父事件更新前进程被杀。
    await eventStore.mark(
      const AutoBookEventUpdate(state: AutoBookState.retry),
      eventId: event.id,
    );

    final replay = await bookkeeper.fromText(
      text: '支付成功 星巴克 30 元',
      ledgerId: ledgerId,
      billingTypes: const ['sms'],
      autoBookFlow: flow,
      source: 'sms',
      evidenceText: '支付成功 星巴克 30 元',
    );

    expect(replay.savedCount, 0);
    expect(replay.duplicateCount, 1);
    expect(replay.firstDuplicateTransactionId, first.firstTransactionId);
    expect(await (db.select(db.transactions)).get(), hasLength(1));
  });
}
