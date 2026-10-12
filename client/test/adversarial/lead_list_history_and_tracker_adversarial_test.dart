// 对抗性测试:ZCode 主控亲自攻击的两个高价值疑点。
//
// 1. AutoBookEventStore.listHistory 的「先 limit 再 Dart 过滤」顺序 ——
//    源码先 orderBy(updatedAt desc).limit(200) 再在 Dart 里按 state/source
//    过滤,若库内存在大量不匹配的新事件,匹配的老事件会被 limit 截掉 →
//    历史页「筛选后空列表」,用户以为记录丢失。
// 2. ChangeTracker.markPushed 的边界(空数组/不存在 id/已推 id 幂等)。
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/cloud/sync/change_tracker.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/services/automation/auto_book_event.dart';
import 'package:smartbook/services/automation/auto_book_event_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late BeeDatabase db;
  late AutoBookEventStore store;

  setUp(() {
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    store = AutoBookEventStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('listHistory 过滤顺序对抗', () {
    Future<int> seed(
      String key, {
      required String state,
      required DateTime updatedAt,
      String source = 'sms',
    }) async {
      final id = await db.into(db.autoBookEvents).insert(
            AutoBookEventsCompanion.insert(
              eventKey: key,
              source: source,
              capturedAt: updatedAt,
              updatedAt: drift.Value(updatedAt),
            ),
          );
      await (db.update(db.autoBookEvents)..where((t) => t.id.equals(id)))
          .write(AutoBookEventsCompanion(state: drift.Value(state)));
      return id;
    }

    test('ADVERSE: limit 截断条件下筛选结果不应为空(旧 booked 被新 pending 挤掉)', () async {
      // 构造 3 条「新 pending」+ 1 条「老 booked」。limit 传 3。
      // 期望:筛选 booked 应能返回那 1 条(过滤应先于 limit,或 limit 放大)。
      // 实际:limit(3) 先取最新 3 条(都是 pending)→ Dart 过滤后 0 条。
      final base = DateTime.now();
      await seed('booked-old', state: 'booked', updatedAt: base);
      for (var i = 0; i < 3; i++) {
        await seed('pending-new-$i',
            state: 'pending', updatedAt: base.add(Duration(minutes: i + 1)));
      }

      final booked =
          await store.listHistory(state: 'booked', limit: 3);
      expect(booked, hasLength(1),
          reason: '筛选后的历史条目不应被 limit 提前截掉(期望先过滤再截断)');
      expect(booked.first.eventKey, 'booked-old');
    });

    test('ADVERSE: source 筛选同样受 limit 截断影响', () async {
      final base = DateTime.now();
      await seed('sms-old',
          state: 'booked', updatedAt: base, source: 'sms');
      for (var i = 0; i < 3; i++) {
        await seed('notify-new-$i',
            state: 'booked',
            updatedAt: base.add(Duration(minutes: i + 1)),
            source: 'notification');
      }
      final mine = await store.listHistory(source: 'sms', limit: 3);
      expect(mine, hasLength(1),
          reason: '按来源筛选不应被 limit 提前截断');
      expect(mine.first.eventKey, 'sms-old');
    });

    test('HARDENING: limit 足够大时筛选结果完整', () async {
      final base = DateTime.now();
      await seed('booked-a', state: 'booked', updatedAt: base);
      await seed('booked-b',
          state: 'booked', updatedAt: base.add(const Duration(minutes: 1)));
      await seed('pending-c',
          state: 'pending', updatedAt: base.add(const Duration(minutes: 2)));
      final booked = await store.listHistory(state: 'booked', limit: 200);
      expect(booked.map((e) => e.eventKey).toSet(),
          {'booked-a', 'booked-b'});
    });
  });

  group('ChangeTracker.markPushed 边界', () {
    late ChangeTracker tracker;

    setUp(() {
      tracker = ChangeTracker(db);
    });

    Future<int> seedChange(String syncId, {bool pushed = false}) async {
      final id = await db.into(db.localChanges).insert(
            LocalChangesCompanion.insert(
              entityType: 'transaction',
              entityId: 1,
              entitySyncId: syncId,
              ledgerId: 1,
              action: 'update',
              pushedAt: drift.Value(
                  pushed ? DateTime.now() : null),
            ),
          );
      return id;
    }

    test('空数组 no-op', () async {
      await seedChange('a');
      await tracker.markPushed([]);
      expect(await tracker.getUnpushedCountForLedger(1), 1);
    });

    test('不存在的 id 静默忽略,不影响其它行', () async {
      await seedChange('a');
      await tracker.markPushed([999999]);
      expect(await tracker.getUnpushedCountForLedger(1), 1);
    });

    test('重复 markPushed 幂等(pushedAt 覆盖无害)', () async {
      final id = await seedChange('a');
      await tracker.markPushed([id]);
      await tracker.markPushed([id]);
      expect(await tracker.getUnpushedCountForLedger(1), 0);
    });

    test('markPushed 不越界标记其它账本的行', () async {
      final a = await seedChange('a');
      final other = await db.into(db.localChanges).insert(
            LocalChangesCompanion.insert(
              entityType: 'transaction',
              entityId: 2,
              entitySyncId: 'b',
              ledgerId: 2,
              action: 'update',
            ),
          );
      await tracker.markPushed([a]);
      expect(await tracker.getUnpushedCountForLedger(2), 1,
          reason: 'markPushed 只按 id 集合写入,不应有任何隐式作用域扩大');
      expect(await tracker.getUnpushedCountForLedger(1), 0);
      // 清理其它行,避免干扰
      await tracker.markPushed([other]);
    });
  });
}
