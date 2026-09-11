import 'package:smartbook/ai/core/bill_info.dart';
import 'package:smartbook/services/billing/pending_candidate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 待确认候选(M2)纯逻辑测试:分流规则、疑似重复、存取。
void main() {
  group('AutoBookRule', () {
    BillInfo bill({double amount = -45, BillType type = BillType.expense, String? note, DateTime? time, double confidence = 0.95}) =>
        BillInfo(amount: amount, type: type, note: note, time: time ?? DateTime(2026, 9, 2, 12), ledgerId: 1, confidence: confidence);

    test('高置信 + 无重复 → 自动入账', () {
      expect(
        AutoBookRule.requiresConfirmation(
          bill: bill(amount: -45, confidence: 0.95),
          recentBills: const [],
          pendingBills: const [],
        ),
        isFalse,
      );
    });

    test('低置信度(<0.9)→ 待确认', () {
      expect(
        AutoBookRule.requiresConfirmation(
          bill: bill(amount: -45, confidence: 0.5),
          recentBills: const [],
          pendingBills: const [],
        ),
        isTrue,
      );
    });

    test('疑似重复:同账本同类型金额完全相等且 1 分钟内 → 待确认', () {
      final recent = bill(amount: -45, time: DateTime(2026, 9, 2, 12, 5));
      expect(
        AutoBookRule.requiresConfirmation(
          bill: bill(amount: -45, time: DateTime(2026, 9, 2, 12, 5, 30)),
          recentBills: [recent],
          pendingBills: const [],
        ),
        isTrue,
      );
    });

    test('金额相近(±5%容差)不再判重(2026-09-10 收紧:交给语义判重)', () {
      final recent = bill(amount: -45.2, time: DateTime(2026, 9, 2, 12, 5));
      expect(
        AutoBookRule.requiresConfirmation(
          bill: bill(amount: -45, time: DateTime(2026, 9, 2, 12, 5, 30)),
          recentBills: [recent],
          pendingBills: const [],
        ),
        isFalse,
      );
    });

    test('金额相等但间隔 30 分钟 → 不算重复', () {
      final recent = bill(amount: -45, time: DateTime(2026, 9, 2, 11, 30));
      expect(
        AutoBookRule.looksLikeDuplicate(
          bill(amount: -45, time: DateTime(2026, 9, 2, 12)),
          [recent],
        ),
        isFalse,
      );
    });

    test('不同账本/不同类型不判重', () {
      final anotherLedger = bill(amount: -45).copyWith(ledgerId: 99);
      final anotherType = bill(amount: -45, type: BillType.income);
      expect(
        AutoBookRule.looksLikeDuplicate(bill(amount: -45), [anotherLedger]),
        isFalse,
      );
      expect(
        AutoBookRule.looksLikeDuplicate(bill(amount: -45), [anotherType]),
        isFalse,
      );
    });

    test('同商户同金额但间隔 1 小时 → 不再判重(2026-09-10 收紧:每天同店同款是正常消费)', () {
      final recent = bill(amount: -30, note: '星巴克', time: DateTime(2026, 9, 2, 11));
      expect(
        AutoBookRule.looksLikeDuplicate(
          bill(amount: -30, note: '星巴克', time: DateTime(2026, 9, 2, 12)),
          [recent],
        ),
        isFalse,
      );
    });

    test('原因:疑似重复优先于低置信', () {
      expect(
        AutoBookRule.reasonKeyFor(
          bill: bill(amount: -45, confidence: 0.5),
          duplicate: true,
        ),
        'duplicate',
      );
      expect(
        AutoBookRule.reasonKeyFor(
          bill: bill(amount: -45, confidence: 0.5),
          duplicate: false,
        ),
        'lowConfidence',
      );
      expect(
        AutoBookRule.reasonKeyFor(
          bill: bill(amount: -45, confidence: 0.95),
          duplicate: false,
        ),
        isNull,
      );
    });
  });

  group('PendingCandidateStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('add / remove / count 幂等与去重', () async {
      final store = PendingCandidateStore();
      final bill = BillInfo(
          amount: -100, time: DateTime(2026, 9, 2), ledgerId: 1, note: '测试');
      final candidate = PendingCandidate(
        id: PendingCandidate.candidateId(bill),
        bill: bill,
        source: 'sms',
        capturedAt: DateTime(2026, 9, 2),
        reason: 'duplicate',
      );
      expect(await store.add(candidate), isTrue);
      expect(await store.add(candidate), isFalse); // 同 id 幂等跳过
      expect(await store.count(), 1);
      expect((await store.load()).single.bill.note, '测试');
      expect(await store.remove(candidate.id), isTrue);
      expect(await store.count(), 0);
    });

    test('candidateId 稳定且与序列化内容一致', () {
      final bill = BillInfo(
          amount: -88.5, time: DateTime(2026, 9, 2, 13, 30), ledgerId: 2);
      expect(PendingCandidate.candidateId(bill),
          PendingCandidate.candidateId(bill));
      expect(PendingCandidate.candidateId(bill), hasLength(12));
    });
  });
}
