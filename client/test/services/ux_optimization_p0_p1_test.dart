import 'dart:io';

import 'package:drift/drift.dart' as d;
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
import 'package:smartbook/services/automation/dedup_exempt_store.dart';
import 'package:smartbook/services/automation/semantic_dedup_matcher.dart';
import 'package:smartbook/services/billing/bill_creation_service.dart';
import 'package:smartbook/services/billing/pending_candidate.dart';

/// ux-optimization-plan P0-2/P1-1/P1-2/P1-3 的核心逻辑回归:
/// - 自动入账总闸(requireConfirmationForAll)分流
/// - 判重豁免表命中/清除 + 匹配器跳过豁免对
/// - 徽标计数与确认页同口径(loadForReview)
/// - cleanupExpired 保留「证据已清理」占位
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
  Future<AudioExtractionResult> extractFromAudio(
    File audio,
    AiExtractionContext ctx,
  ) async =>
      AudioExtractionResult(bills: bills);

  @override
  Future<String?> speechToText(File audio) async => null;
}

BillInfo _settledBill({
  double amount = -38,
  String merchant = '星巴克',
  DateTime? time,
}) {
  return BillInfo(
    amount: amount,
    time: time ?? DateTime(2026, 9, 4, 10, 30),
    note: merchant,
    merchant: merchant,
    category: '餐饮',
    type: BillType.expense,
    eventKind: BillEventKind.purchase,
    settlementStatus: BillSettlementStatus.settled,
    confidence: 0.98,
    confidenceProvided: true,
    timePrecision: BillTimePrecision.minute,
    currency: 'CNY',
    ledgerId: 1,
  );
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
    ledgerId = await repo.createLedger(name: 'ux-opt');
    await repo.createCategory(name: '餐饮', kind: 'expense');
  });

  tearDown(() async => db.close());

  group('P0-2 自动入账总闸', () {
    test('总闸关闭:高置信已结算账单也进待确认,不入账', () async {
      final bill = _settledBill();
      final eventStore = AutoBookEventStore(db);
      const eventKey = 'sms:v3:master-off';
      await eventStore.ensure(AutoBookInput(
        eventKey: eventKey,
        source: AutoBookSource.sms,
        ledgerId: ledgerId,
        capturedAt: DateTime(2026, 9, 4, 10),
      ));
      final bookkeeper = AiBookkeeper(
        repository: repo,
        engine: _FixedEngine([bill]),
        persister: BillCreationService(repo),
        eventStore: eventStore,
      );

      final result = await bookkeeper.fromText(
        text: '支付成功 38 元',
        ledgerId: ledgerId,
        billingTypes: const ['sms'],
        autoBookFlow: AutoBookFlow(
          store: PendingCandidateStore(),
          eventKey: eventKey,
          eventStore: eventStore,
          requireConfirmationForAll: true,
        ),
        source: 'sms',
        evidenceText: '支付成功 38 元',
      );

      expect(result.savedCount, 0);
      expect(result.awaitingCount, 1);
      expect(await (db.select(db.transactions)).get(), isEmpty);
      final merged = await PendingCandidateStore().loadForReview(eventStore);
      expect(merged, hasLength(1));
      expect(merged.single.reason, 'autoBookDisabled');
    });

    test('总闸开启(默认):同一账单直接入账', () async {
      final bill = _settledBill();
      final eventStore = AutoBookEventStore(db);
      const eventKey = 'sms:v3:master-on';
      await eventStore.ensure(AutoBookInput(
        eventKey: eventKey,
        source: AutoBookSource.sms,
        ledgerId: ledgerId,
        capturedAt: DateTime(2026, 9, 4, 10),
      ));
      final bookkeeper = AiBookkeeper(
        repository: repo,
        engine: _FixedEngine([bill]),
        persister: BillCreationService(repo),
        eventStore: eventStore,
      );

      final result = await bookkeeper.fromText(
        text: '支付成功 38 元',
        ledgerId: ledgerId,
        billingTypes: const ['sms'],
        autoBookFlow: AutoBookFlow(
          store: PendingCandidateStore(),
          eventKey: eventKey,
          eventStore: eventStore,
        ),
        source: 'sms',
        evidenceText: '支付成功 38 元',
      );

      expect(result.savedCount, 1);
      expect(result.awaitingCount, 0);
    });
  });

  group('P1-1 判重豁免表', () {
    test('add/list/clear 幂等且按金额段去重', () async {
      final store = DedupExemptStore();
      await store.add(keyword: '星巴克', amount: 38);
      await store.add(keyword: '星巴克', amount: 39); // 同段,幂等
      await store.add(keyword: '瑞幸', amount: 15);
      expect((await store.list()).length, 2);
      expect(await store.clear(), 2);
      expect(await store.list(), isEmpty);
    });

    test('isExempt:关键字+金额段命中;金额段外/关键字不匹配不命中', () {
      final rules = [
        DedupExemptRule(keyword: '星巴克', amount: 38, createdAt: DateTime(2026)),
      ];
      expect(
        DedupExemptStore.isExempt(
          rules,
          billAmount: -38,
          billNoteNormalized: '星巴克咖啡',
          txAmount: 38,
          txNoteNormalized: '星巴克',
        ),
        isTrue,
      );
      // 金额段外(38 vs 100)
      expect(
        DedupExemptStore.isExempt(
          rules,
          billAmount: -100,
          billNoteNormalized: '星巴克',
          txAmount: 100,
          txNoteNormalized: '星巴克',
        ),
        isFalse,
      );
      // 关键字不匹配
      expect(
        DedupExemptStore.isExempt(
          rules,
          billAmount: -38,
          billNoteNormalized: '麦当劳',
          txAmount: 38,
          txNoteNormalized: '麦当劳',
        ),
        isFalse,
      );
    });

    test('匹配器跳过豁免对:命中豁免 → findBest 返回 null;清空后恢复强匹配', () async {
      final time = DateTime(2026, 9, 4, 10, 30);
      final txId = await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 38,
        happenedAt: time,
        note: '星巴克',
        currencyCode: 'CNY',
      );
      final bill = _settledBill(time: time);
      const matcher = SemanticDedupMatcher();

      // 无豁免:同商户同金额同币种近时间 → 强匹配
      final strong = await matcher.findBest(
        repository: repo,
        ledgerId: ledgerId,
        bill: bill,
      );
      expect(strong, isNotNull);
      expect(strong!.isStrong, isTrue);
      expect(strong.transactionId, txId);

      // 用户「仍记一笔」→ 落豁免
      final keyword = SemanticDedupMatcher.exemptKeyword(bill);
      expect(keyword, '星巴克');
      await DedupExemptStore().add(keyword: keyword!, amount: 38);

      final exempted = await matcher.findBest(
        repository: repo,
        ledgerId: ledgerId,
        bill: bill,
      );
      expect(exempted, isNull, reason: '豁免命中后该对不再参与判重');

      // 清空豁免后恢复
      await DedupExemptStore().clear();
      final restored = await matcher.findBest(
        repository: repo,
        ledgerId: ledgerId,
        bill: bill,
      );
      expect(restored, isNotNull);
    });
  });

  group('P1-3 计数口径', () {
    test('loadForReview 合并 legacy 与 event store 候选,口径一致', () async {
      final eventStore = AutoBookEventStore(db);
      final store = PendingCandidateStore();
      final bill = _settledBill(merchant: '事件路候选');

      // event store 路候选(模拟 recordEventItem 写入结构)
      final event = await eventStore.ensure(AutoBookInput(
        eventKey: 'sms:v3:count-evt',
        source: AutoBookSource.sms,
        ledgerId: ledgerId,
        capturedAt: DateTime(2026, 9, 4, 10),
      ));
      // listPending 只投影 parent state=pending 的事件(真实流程中候选制确认
      // 后事件即为 pending 终态)
      await eventStore.mark(
        const AutoBookEventUpdate(state: AutoBookState.pending),
        eventId: event.id,
      );
      await eventStore.upsertItem(
        eventId: event.id,
        itemIndex: 0,
        state: 'pending',
        bill: {
          ...bill.toJson(),
          'candidate_id': 'c-evt',
          'billing_types': ['sms'],
          'source': 'sms',
          'captured_at': DateTime(2026, 9, 4, 10).toIso8601String(),
        },
        reason: 'lowConfidence',
      );

      // legacy 路候选(不同 eventKey)
      await store.add(PendingCandidate(
        id: 'legacy-x',
        bill: _settledBill(merchant: '旧队列候选'),
        capturedAt: DateTime(2026, 9, 4, 11),
        reason: 'lowConfidence',
      ));

      final merged = await store.loadForReview(eventStore);
      expect(merged.length, 2, reason: '角标/确认页必须同口径:两路候选都计数');
      expect(merged.map((c) => c.reason), everyElement('lowConfidence'));
    });
  });

  group('P1-2 cleanupExpired 占位', () {
    test('曾有证据被清理的过期事件保留占位;从未有证据的照旧删除', () async {
      final eventStore = AutoBookEventStore(db);
      final past = DateTime.now().subtract(const Duration(days: 1));

      // 曾有证据:留存策略清理后 rawEvidenceUploadState = 'expired'
      final hadEvidence = await eventStore.ensure(AutoBookInput(
        eventKey: 'exp:v1:had-evidence',
        source: AutoBookSource.sms,
        ledgerId: ledgerId,
        capturedAt: past,
        expiresAt: past,
      ));
      await (db.update(db.autoBookEvents)
            ..where((t) => t.id.equals(hadEvidence.id)))
          .write(const AutoBookEventsCompanion(
        rawEvidenceUploadState: d.Value('expired'),
      ));

      // 从未有证据:not_requested,照旧删行
      await eventStore.ensure(AutoBookInput(
        eventKey: 'exp:v1:no-evidence',
        source: AutoBookSource.sms,
        ledgerId: ledgerId,
        capturedAt: past,
        expiresAt: past,
      ));

      await eventStore.cleanupExpired();

      final kept = await eventStore.findById(hadEvidence.id);
      expect(kept, isNotNull, reason: '历史不再凭空消失');
      expect(kept!.state, 'expired');
      expect(kept.reason, 'expired_evidence_cleared');
      expect(kept.expiresAt, isNull, reason: '不再被下一轮清理删除');

      final deleted = await eventStore.findByEventKey('exp:v1:no-evidence');
      expect(deleted, isNull);
    });
  });
}
