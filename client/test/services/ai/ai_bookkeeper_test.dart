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

/// 可编程的 fake engine。不做 AI 调用,直接返回预设的 bills。
class _FakeEngine implements AiExtractionEngine {
  List<BillInfo> bills;
  AudioExtractionResult audio;

  /// 服务端识别前判重命中(订单号已存在,本次没有调用 LLM)。
  bool duplicate;
  String? matchedIdentifier;

  _FakeEngine({
    this.bills = const [],
    this.audio = const AudioExtractionResult(),
    this.duplicate = false,
    this.matchedIdentifier,
  });

  @override
  Future<AiExtractionOutcome> extractFromText(
    String text,
    AiExtractionContext ctx, {
    String billGuard = '',
  }) async =>
      duplicate
          ? AiExtractionOutcome(
              status: ExtractionStatus.duplicate,
              matchedIdentifier: matchedIdentifier)
          : AiExtractionOutcome(
              status: bills.isEmpty
                  ? ExtractionStatus.noBill
                  : ExtractionStatus.success,
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
      this.audio;

  @override
  Future<String?> speechToText(File audio) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late LocalRepository repo;
  late BillCreationService persister;
  late int ledgerId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    persister = BillCreationService(repo);
    ledgerId = await repo.createLedger(name: 'test');
    // 准备一些可用分类供 BillCreationService 匹配
    await repo.createCategory(name: '餐饮', kind: 'expense');
    await repo.createCategory(name: '其他', kind: 'expense');
    await repo.createCategory(name: '工资', kind: 'income');
  });

  tearDown(() async {
    await db.close();
  });

  group('AiBookkeeper.fromText', () {
    test('单笔成功 → savedBills.length == 1 + isMulti=false', () async {
      final engine = _FakeEngine(bills: [
        BillInfo(
          amount: -30,
          time: DateTime(2026, 5, 26, 12, 0),
          category: '餐饮',
          type: BillType.expense,
          note: '午餐',
        ),
      ]);
      final bookkeeper = AiBookkeeper(
        repository: repo,
        engine: engine,
        persister: persister,
      );

      final result = await bookkeeper.fromText(
        text: '午餐30',
        ledgerId: ledgerId,
        billingTypes: const ['ai_chat'],
      );

      expect(result.success, isTrue);
      expect(result.savedBills, hasLength(1));
      expect(result.transactionIds, hasLength(1));
      expect(result.isMulti, isFalse);
      expect(result.failedCount, 0);
      expect(result.totalAbsAmount, 30);
    });

    test('多笔成功 → 全部入库, isMulti=true', () async {
      final engine = _FakeEngine(bills: [
        BillInfo(
          amount: -5,
          time: DateTime(2026, 5, 26, 9, 0),
          category: '餐饮',
          type: BillType.expense,
        ),
        BillInfo(
          amount: -40,
          time: DateTime(2026, 5, 26, 12, 0),
          category: '餐饮',
          type: BillType.expense,
        ),
        BillInfo(
          amount: -35,
          time: DateTime(2026, 5, 26, 19, 0),
          category: '餐饮',
          type: BillType.expense,
        ),
      ]);
      final bookkeeper = AiBookkeeper(
        repository: repo,
        engine: engine,
        persister: persister,
      );

      final result = await bookkeeper.fromText(
        text: '早5中40晚35',
        ledgerId: ledgerId,
        billingTypes: const ['ai_chat'],
      );

      expect(result.success, isTrue);
      expect(result.savedBills, hasLength(3));
      expect(result.transactionIds, hasLength(3));
      expect(result.isMulti, isTrue);
      expect(result.totalAbsAmount, 80);
    });

    test('服务端判重命中 → duplicateCount=1 且不落库(静默不通知)', () async {
      final engine = _FakeEngine(
        bills: const [],
        duplicate: true,
        matchedIdentifier: '2026090512345678',
      );
      final bookkeeper = AiBookkeeper(
        repository: repo,
        engine: engine,
        persister: persister,
      );

      final result = await bookkeeper.fromText(
        text: '又买了一次 订单号2026090512345678',
        ledgerId: ledgerId,
        billingTypes: const ['ai_chat'],
      );

      // duplicateCount>0 → handled=true:自动通道不发通知、不进待确认
      expect(result.duplicateCount, 1);
      expect(result.handled, isTrue);
      expect(result.success, isFalse);
      expect(result.transactionIds, isEmpty);
      expect(result.awaitingCount, 0);
    });

    test('engine 返回空 → success=false', () async {
      final engine = _FakeEngine(bills: const []);
      final bookkeeper = AiBookkeeper(
        repository: repo,
        engine: engine,
        persister: persister,
      );

      final result = await bookkeeper.fromText(
        text: 'noop',
        ledgerId: ledgerId,
        billingTypes: const ['ai_chat'],
      );

      expect(result.success, isFalse);
      expect(result.transactionIds, isEmpty);
      expect(result.savedBills, isEmpty);
    });

    test('ledgerId 被附加到保存后的 BillInfo', () async {
      final engine = _FakeEngine(bills: [
        BillInfo(
          amount: -30,
          time: DateTime(2026, 5, 26, 12, 0),
          category: '餐饮',
          type: BillType.expense,
        ),
      ]);
      final bookkeeper = AiBookkeeper(
        repository: repo,
        engine: engine,
        persister: persister,
      );

      final result = await bookkeeper.fromText(
        text: 'x',
        ledgerId: ledgerId,
        billingTypes: const ['ai_chat'],
      );

      expect(result.savedBills.first.ledgerId, ledgerId);
    });
  });

  group('AiBookkeeper.fromAudio', () {
    test('返回 recognizedText 给 UI 展示', () async {
      final engine = _FakeEngine(
        audio: AudioExtractionResult(
          bills: [
            BillInfo(
              amount: -30,
              time: DateTime(2026, 5, 26, 12, 0),
              category: '餐饮',
              type: BillType.expense,
            ),
          ],
          recognizedText: '午餐30块',
        ),
      );
      final bookkeeper = AiBookkeeper(
        repository: repo,
        engine: engine,
        persister: persister,
      );

      // 必须有可用音频文件,fromAudio 内部会调 extractFromAudio
      // (fake engine 直接返回预设结果,无需读文件)
      final tempFile = await File.fromUri(
              Uri.file('${Directory.systemTemp.path}/test_audio.wav'))
          .create();
      final response = await bookkeeper.fromAudio(
        audio: tempFile,
        ledgerId: ledgerId,
        billingTypes: const ['voice'],
      );
      await tempFile.delete();

      expect(response.result.success, isTrue);
      expect(response.recognizedText, '午餐30块');
    });
  });

  group('AiBookkeeper.approvePending(C12 booked 快路径校验交易存在)', () {
    late AutoBookEventStore eventStore;

    setUp(() {
      eventStore = AutoBookEventStore(db);
    });

    BillInfo candidateBill() => BillInfo(
          amount: -30,
          time: DateTime(2026, 9, 15, 12, 0),
          category: '餐饮',
          type: BillType.expense,
          note: '午餐',
          ledgerId: ledgerId,
        );

    test('事件 booked 且交易仍存在 → 直接返回该交易 id(幂等快路径)', () async {
      final txId = await persister.createFromBill(
          bill: candidateBill(), ledgerId: ledgerId);
      expect(txId, isNotNull);
      final event = await eventStore.ensure(
        AutoBookInput(
          eventKey: 'sms:v3:approve-ok',
          source: AutoBookSource.sms,
          capturedAt: DateTime(2026, 9, 15, 12, 1),
        ),
      );
      await eventStore.mark(
        AutoBookEventUpdate(
          state: AutoBookState.booked,
          transactionId: txId,
        ),
        eventId: event.id,
      );
      final bookkeeper = AiBookkeeper(
        repository: repo,
        engine: _FakeEngine(),
        persister: persister,
        eventStore: eventStore,
      );
      final candidate = PendingCandidate(
        id: 'c-approve-ok',
        bill: candidateBill(),
        source: 'sms',
        capturedAt: DateTime(2026, 9, 15, 12, 1),
        eventKey: event.eventKey,
      );

      final returned = await bookkeeper.approvePending(candidate);
      expect(returned, txId);
    });

    test('C12:事件 booked 但交易已被同步删除 → 不返回悬空 id,重建入账', () async {
      final event = await eventStore.ensure(
        AutoBookInput(
          eventKey: 'sms:v3:approve-dangling',
          source: AutoBookSource.sms,
          capturedAt: DateTime(2026, 9, 15, 12, 1),
        ),
      );
      // 模拟 pull 侧删除不回写事件状态:事件停在 booked,交易 id 已不存在。
      await eventStore.mark(
        const AutoBookEventUpdate(
          state: AutoBookState.booked,
          transactionId: 999999,
        ),
        eventId: event.id,
      );
      final bookkeeper = AiBookkeeper(
        repository: repo,
        engine: _FakeEngine(),
        persister: persister,
        eventStore: eventStore,
      );
      final candidate = PendingCandidate(
        id: 'c-approve-dangling',
        bill: candidateBill(),
        source: 'sms',
        capturedAt: DateTime(2026, 9, 15, 12, 1),
        eventKey: event.eventKey,
      );

      final returned = await bookkeeper.approvePending(candidate);
      expect(returned, isNotNull);
      expect(returned, isNot(999999), reason: 'C12:悬空 transactionId 不外泄');
      expect(await repo.getTransactionById(returned!), isNotNull,
          reason: '返回的 id 必须对应实际存在的交易');
    });
  });
}
