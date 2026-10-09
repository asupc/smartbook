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
import 'package:smartbook/services/ai/bookkeeping_result.dart';
import 'package:smartbook/services/automation/auto_book_coordinator.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';
import 'package:smartbook/services/automation/auto_billing_service.dart';
import 'package:smartbook/services/automation/semantic_dedup_matcher.dart';
import 'package:smartbook/services/billing/bill_creation_service.dart';
import 'package:smartbook/services/billing/pending_candidate.dart';

/// 簇升级(P1,2026-10-09):同一笔支付被多通道重复上报(地铁 8.1 被
/// 两个 App 通知 + 详情页各报一次)时,不再让用户逐条确认 ——
/// - 对待确认候选:证据齐全的后来者入账并吸收同簇候选;
/// - 对已入账交易:弱匹配但有簇文案亲缘 → 升级强判合并。
/// 文案无亲缘(可能是真实的第二笔同额消费)必须维持人工确认。
class _FakeEngine implements AiExtractionEngine {
  final List<BillInfo> bills;

  _FakeEngine({this.bills = const []});

  @override
  Future<AiExtractionOutcome> extractFromText(
    String text,
    AiExtractionContext ctx, {
    String billGuard = '',
  }) async => AiExtractionOutcome(
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
      const AudioExtractionResult();

  @override
  Future<String?> speechToText(File audio) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late LocalRepository repo;
  late BillCreationService persister;
  late AutoBookEventStore eventStore;
  late PendingCandidateStore candidateStore;
  late int ledgerId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    persister = BillCreationService(repo);
    eventStore = AutoBookEventStore(db);
    candidateStore = PendingCandidateStore();
    ledgerId = await repo.createLedger(name: 'cluster');
    await repo.createCategory(name: '交通', kind: 'expense');
    await repo.createCategory(name: '餐饮', kind: 'expense');
  });

  tearDown(() async {
    await db.close();
  });

  /// 跑一次完整自动记账(单事件),返回识别→分流结果。
  Future<BookkeepingResult> processAuto(
    String eventKey,
    BillInfo bill, {
    String source = 'notification',
  }) async {
    final coordinator = AutoBookCoordinator(db);
    final bookkeeper = AiBookkeeper(
      repository: repo,
      engine: _FakeEngine(bills: [bill]),
      persister: persister,
      eventStore: eventStore,
    );
    final execution = await coordinator.execute<BookkeepingResult>(
      input: AutoBookInput(
        eventKey: eventKey,
        source: AutoBookSource.notification,
        capturedAt: DateTime.now(),
        ledgerId: ledgerId,
      ),
      action: () => bookkeeper.fromText(
        text: 'x',
        ledgerId: ledgerId,
        billingTypes: const ['ai'],
        autoBookFlow: AutoBookFlow(
          store: candidateStore,
          eventKey: eventKey,
          eventStore: eventStore,
        ),
        source: source,
      ),
      updateFor: (value) => value.eventUpdate,
    );
    return execution.value ??
        const BookkeepingResult(awaitingCount: 0);
  }

  group('SemanticDedupMatcher.clusterTextAffinity(纯函数契约)', () {
    BillInfo note(String raw) => BillInfo(
          amount: -8.1,
          type: BillType.expense,
          note: raw,
          time: DateTime(2026, 10, 9, 8, 32),
        );

    test('同渠道不同写法的地铁文案有亲缘(bigram 交集)', () {
      expect(
        SemanticDedupMatcher.clusterTextAffinity(
            note('地铁免密扣款'), note('地铁乘车')),
        isTrue,
      );
      expect(
        SemanticDedupMatcher.clusterTextAffinity(
            note('地铁免密支付'), note('地铁免密扣款')),
        isTrue,
      );
    });

    test('不相关的同额消费没有亲缘 → 不允许自动合并', () {
      expect(
        SemanticDedupMatcher.clusterTextAffinity(
            note('美团外卖'), note('地铁乘车')),
        isFalse,
      );
    });

    test('无商户/备注 → 无亲缘信号', () {
      expect(
        SemanticDedupMatcher.clusterTextAffinity(
          note('地铁乘车'),
          BillInfo(amount: -8.1, type: BillType.expense,
              time: DateTime(2026, 10, 9, 8, 32)),
        ),
        isFalse,
      );
    });
  });

  group('簇升级·对待确认候选', () {
    // 时间锚 now()-5min,保证落在 24h 判重基线窗口内
    final t = DateTime.now().subtract(const Duration(minutes: 5));

    BillInfo metro(String note, Duration offset,
        {BillSettlementStatus? status}) {
      return BillInfo(
        amount: -8.1,
        type: BillType.expense,
        note: note,
        time: t.add(offset),
        ledgerId: ledgerId,
        settlementStatus: status,
        confidenceProvided: true,
        timePrecision: BillTimePrecision.minute,
      );
    }

    test('证据齐全的第三条入账并吸收同簇的两条候选', () async {
      // 事件1/2:通知,结算未知 → 各自进待确认(第二条撞疑似重复)
      await processAuto('ev1', metro('地铁免密扣款', Duration.zero));
      expect(await candidateStore.count(), 1);
      await processAuto('ev2', metro('地铁免密支付', const Duration(seconds: 20)));
      expect(await candidateStore.count(), 2);

      // 事件3:详情页,字段齐全(结算+时间+置信) → 簇升级入账
      final result = await processAuto(
        'ev3',
        metro('地铁乘车', const Duration(seconds: 40),
            status: BillSettlementStatus.settled),
        source: 'screenText',
      );

      expect(result.success, isTrue);
      expect(result.transactionIds, hasLength(1));
      final txId = result.transactionIds.first;

      // 两条候选被吸收:legacy 队列清空,事件投影无 pending
      expect(await candidateStore.count(), 0);
      expect(await eventStore.listPending(limit: 10), isEmpty);

      // 被吸收的事件子项转 duplicate 并关联新交易
      for (final key in ['ev1', 'ev2']) {
        final event = await eventStore.findByEventKey(key);
        expect(event, isNotNull, reason: '事件 $key 应存在');
        final items = await eventStore.itemsForEvent(event!.id);
        final item = items.single;
        expect(item.state as String?, 'duplicate',
            reason: '事件 $key 子项应转为已合并');
        expect(item.transactionId as int?, txId);
        expect(item.reason as String?, 'cluster_merged');
      }
    });

    test('文案无亲缘(疑似真实的第二笔同额消费)→ 不升级,维持人工确认', () async {
      await processAuto('ev1', metro('地铁免密扣款', Duration.zero));
      await processAuto('ev2', metro('地铁免密支付', const Duration(seconds: 20)));
      final result = await processAuto(
        'ev3',
        metro('美团外卖', const Duration(seconds: 40),
            status: BillSettlementStatus.settled),
        source: 'screenText',
      );

      expect(result.success, isFalse);
      expect(result.awaitingCount, 1);
      expect(await candidateStore.count(), 3);
      expect(await eventStore.listPending(limit: 10), isNotEmpty);
    });
  });

  group('簇升级·对已入账交易', () {
    final t = DateTime.now().subtract(const Duration(minutes: 5));

    BillInfo metro(String note, Duration offset) {
      return BillInfo(
        amount: -8.1,
        type: BillType.expense,
        note: note,
        time: t.add(offset),
        ledgerId: ledgerId,
        settlementStatus: BillSettlementStatus.settled,
        confidenceProvided: true,
        timePrecision: BillTimePrecision.minute,
      );
    }

    test('先入账一条,后到的弱匹配有簇亲缘 → 自动合并,不进待确认', () async {
      final first = await processAuto('ev1', metro('地铁免密扣款', Duration.zero));
      expect(first.success, isTrue);

      // 「免密支付」vs「免密扣款」:商户词既不相等也无词元交集,旧口径
      // 只到 possible(0.65)→ 待确认;簇亲缘(bigram)升级为强判合并
      final second =
          await processAuto('ev2', metro('地铁免密支付', const Duration(seconds: 20)));
      expect(second.success, isFalse);
      expect(second.duplicateCount, 1);
      expect(await candidateStore.count(), 0);
      expect(await eventStore.listPending(limit: 10), isEmpty);
    });

    test('弱匹配但文案无亲缘 → 仍进待确认', () async {
      await processAuto('ev1', metro('地铁免密扣款', Duration.zero));
      final second =
          await processAuto('ev2', metro('美团外卖', const Duration(seconds: 20)));
      expect(second.success, isFalse);
      expect(await candidateStore.count(), 1);
    });
  });
}
