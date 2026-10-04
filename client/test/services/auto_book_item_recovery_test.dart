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
      AiExtractionOutcome(
        status:
            bills.isEmpty ? ExtractionStatus.noBill : ExtractionStatus.success,
        bills: bills,
      );

  @override
  Future<List<BillInfo>> extractFromImage(
    File image,
    AiExtractionContext ctx, {
    String billGuard = '',
  }) async =>
      bills;

  @override
  Future<List<ImageExtractOutcome>> extractFromImages(
    List<File> images,
    AiExtractionContext context, {
    String billGuard = '',
  }) async =>
      [for (final _ in images) ImageExtractOutcome(bills: bills)];

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

  test('多笔候选逐项确认:剩余子项仍待确认且重复点击返回各自交易', () async {
    final now = DateTime.now();
    final bills = [
      for (var i = 0; i < 2; i++)
        BillInfo(
          amount: -(18 + i).toDouble(),
          time: now.add(Duration(minutes: i * 5)),
          note: '商户$i',
          category: '餐饮',
          type: BillType.expense,
          eventKind: BillEventKind.purchase,
          settlementStatus: BillSettlementStatus.settled,
          confidence: 0.7,
          confidenceProvided: true,
          timePrecision: BillTimePrecision.minute,
        ),
    ];
    final eventStore = AutoBookEventStore(db);
    const eventKey = 'sms:v3:two-pending-items';
    final event = await eventStore.ensure(AutoBookInput(
      eventKey: eventKey,
      source: AutoBookSource.sms,
      ledgerId: ledgerId,
      capturedAt: now,
    ));
    final bookkeeper = AiBookkeeper(
      repository: repo,
      engine: _FixedEngine(bills),
      persister: BillCreationService(repo),
      eventStore: eventStore,
    );
    final result = await bookkeeper.fromText(
      text: '两笔已付款',
      ledgerId: ledgerId,
      billingTypes: const ['sms'],
      autoBookFlow: AutoBookFlow(
        store: PendingCandidateStore(),
        eventKey: eventKey,
        eventStore: eventStore,
      ),
      source: 'sms',
      evidenceText: '支付成功',
    );
    expect(result.awaitingCount, 2);
    await eventStore.mark(
      const AutoBookEventUpdate(state: AutoBookState.pending),
      eventId: event.id,
    );
    final store = PendingCandidateStore();
    final candidates = await store.loadForReview(eventStore);
    expect(candidates, hasLength(2));
    expect(candidates.map((c) => c.eventItemIndex).toSet(), {0, 1});

    final firstId = await bookkeeper.approvePending(candidates[0]);
    expect(firstId, isNotNull);
    expect((await eventStore.findById(event.id))!.state, 'pending');
    expect(await store.loadForReview(eventStore), hasLength(1));

    final secondId = await bookkeeper.approvePending(candidates[1]);
    expect(secondId, isNotNull);
    expect(secondId, isNot(firstId));
    expect((await eventStore.findById(event.id))!.state, 'booked');
    expect(await store.loadForReview(eventStore), isEmpty);
    expect(await bookkeeper.approvePending(candidates[0]), firstId);
    expect(await (db.select(db.transactions)).get(), hasLength(2));
  });

  test('缺少置信字段与推断时间分别标注准确原因', () async {
    final time = DateTime.now();
    final bills = [
      BillInfo(
        amount: -23,
        time: time,
        type: BillType.expense,
        eventKind: BillEventKind.purchase,
        settlementStatus: BillSettlementStatus.settled,
        timePrecision: BillTimePrecision.minute,
        confidenceProvided: false,
      ),
      BillInfo(
        amount: -24,
        time: time.add(const Duration(minutes: 5)),
        type: BillType.expense,
        eventKind: BillEventKind.purchase,
        settlementStatus: BillSettlementStatus.settled,
        timePrecision: BillTimePrecision.inferred,
        timeInferred: true,
      ),
    ];
    final eventStore = AutoBookEventStore(db);
    const eventKey = 'sms:v3:reason-precision';
    final event = await eventStore.ensure(AutoBookInput(
      eventKey: eventKey,
      source: AutoBookSource.sms,
      ledgerId: ledgerId,
      capturedAt: time,
    ));
    final bookkeeper = AiBookkeeper(
      repository: repo,
      engine: _FixedEngine(bills),
      persister: BillCreationService(repo),
      eventStore: eventStore,
    );
    await bookkeeper.fromText(
      text: '付款成功',
      ledgerId: ledgerId,
      billingTypes: const ['sms'],
      autoBookFlow: AutoBookFlow(
        store: PendingCandidateStore(),
        eventKey: eventKey,
        eventStore: eventStore,
      ),
      source: 'sms',
      evidenceText: '支付成功',
    );
    final items = await eventStore.itemsForEvent(event.id);
    expect(items.map((item) => item.reason),
        ['confidenceMissing', 'timeInferred']);
  });

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
