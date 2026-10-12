import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/ai/core/bill_info.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';
import 'package:smartbook/services/billing/pending_candidate.dart';

/// B4:忽略恢复的期望状态检查 + 裁决互斥层。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reopenItem(期望状态检查)', () {
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

    Future<AutoBookEvent> makeEvent(String key) =>
        store.ensure(AutoBookInput(
          eventKey: key,
          source: AutoBookSource.sms,
          capturedAt: DateTime(2026, 10, 10, 12),
        ));

    test('ignored → pending,父事件同步回到 pending', () async {
      final event = await makeEvent('sms:v2:one');
      await store.upsertItem(
        eventId: event.id,
        itemIndex: 0,
        state: 'ignored',
        amount: -30,
        reason: 'user_rejected',
        bill: {'amount': -30, 'note': '星巴克'},
      );
      await store.mark(
        const AutoBookEventUpdate(state: AutoBookState.ignored),
        eventId: event.id,
      );

      final ok = await store.reopenItem(
        eventId: event.id,
        itemIndex: 0,
        reason: 'undo_ignore',
      );
      expect(ok, isTrue);

      final items = await store.itemsForEvent(event.id);
      expect(items.single.state, AutoBookState.pending.value);
      expect(items.single.reason, 'undo_ignore');
      final reloaded = await store.findByEventKey('sms:v2:one');
      expect(reloaded!.state, AutoBookState.pending.value);
    });

    test('非 ignored 状态不可恢复 → false(并发/重复点击兜底)', () async {
      final event = await makeEvent('sms:v2:two');
      await store.upsertItem(
        eventId: event.id,
        itemIndex: 0,
        state: 'booked',
        amount: -30,
        transactionId: 7,
        bill: {'amount': -30},
      );
      final ok = await store.reopenItem(eventId: event.id, itemIndex: 0);
      expect(ok, isFalse);
      final items = await store.itemsForEvent(event.id);
      expect(items.single.state, AutoBookState.booked.value);
    });

    test('itemIndex 不匹配 → false', () async {
      final event = await makeEvent('sms:v2:three');
      await store.upsertItem(
        eventId: event.id,
        itemIndex: 0,
        state: 'ignored',
        bill: {'amount': -10},
      );
      expect(
        await store.reopenItem(eventId: event.id, itemIndex: 5),
        isFalse,
      );
    });

    test('listIgnoredItems 只返回「已忽略 + 有结构化摘要」的子项', () async {
      final withBill = await makeEvent('sms:v2:with-bill');
      final withoutBill = await makeEvent('sms:v2:no-bill');
      final pending = await makeEvent('sms:v2:pending');

      await store.upsertItem(
        eventId: withBill.id,
        itemIndex: 0,
        state: 'ignored',
        bill: {'amount': -42, 'note': '美团'},
      );
      await store.upsertItem(
        eventId: withoutBill.id,
        itemIndex: 0,
        state: 'ignored',
        // 没有 billJson:无法重建候选,不给恢复入口
        bill: null,
      );
      await store.upsertItem(
        eventId: pending.id,
        itemIndex: 0,
        state: 'pending',
        bill: {'amount': -5},
      );

      final rows = await store.listIgnoredItems();
      expect(rows, hasLength(1));
      expect(rows.single.event.eventKey, 'sms:v2:with-bill');
      expect(rows.single.item.billJson, isNotEmpty);
    });
  });

  group('PendingDecisionCoordinator(裁决互斥)', () {
    setUp(() {
      PendingDecisionCoordinator.resetForTest();
    });

    test('同一 key 串行执行:后一个等前一个结束', () async {
      final order = <String>[];
      Future<void> run(String key, String tag, int ms) =>
          PendingDecisionCoordinator.run(key, () async {
            order.add('start:$tag');
            await Future.delayed(Duration(milliseconds: ms));
            order.add('end:$tag');
            return null;
          });

      await Future.wait([
        run('k', 'slow', 40),
        run('k', 'fast', 5),
      ]);

      expect(order, [
        'start:slow',
        'end:slow',
        'start:fast',
        'end:fast',
      ]);
    });

    test('不同 key 互不阻塞(两个同时在跑)', () async {
      var running = 0;
      var maxConcurrent = 0;
      Future<void> run(String key) => PendingDecisionCoordinator.run(key, () async {
            running++;
            if (running > maxConcurrent) maxConcurrent = running;
            await Future.delayed(const Duration(milliseconds: 30));
            running--;
            return null;
          });

      await Future.wait([run('a'), run('b')]);
      expect(maxConcurrent, 2, reason: '不同 key 应并行,不被互斥层串起来');
      expect(running, 0);
    });

    test('异常不卡住同 key 的后续裁决', () async {
      var threw = false;
      try {
        await PendingDecisionCoordinator.run<int>('x', () async {
          throw StateError('boom');
        });
      } catch (_) {
        threw = true;
      }
      expect(threw, isTrue);

      final ok = await PendingDecisionCoordinator.run<int>(
        'x',
        () async => 42,
      );
      expect(ok, 42);
    });

    test('keyFor:同事件同子项恒定', () {
      final base = PendingCandidate(
        id: 'c1',
        bill: const BillInfo(amount: -1, time: null),
        billingTypes: const [],
        source: 'sms',
        capturedAt: DateTime(2026, 10, 10),
        eventKey: 'sms:v2:x',
        eventItemIndex: 2,
      );
      final same = base.copyWith(reason: 'duplicate');
      expect(
        PendingDecisionCoordinator.keyFor(base),
        PendingDecisionCoordinator.keyFor(same),
      );
    });
  });
}
