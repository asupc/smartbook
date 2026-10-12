// SyncErrorStore 单元测试。
//
// SyncErrorStore 是 pull 路径上 apply 失败 change 的持久化。关键契约:
//   1. 新 change_id → INSERT
//   2. 已存在 change_id → attempt_count += 1(走 update-first 路径,不撞 UNIQUE)
//   3. 并发同 change_id record() → 不抛 UNIQUE constraint(catch + 降级 update)
//   4. markResolved 后 watchUnresolved 不返
//
// 旧实现的 bug:select-then-insert race 时第二次 record 撞 UNIQUE 抛错(已修)。

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/cloud/sync/sync_engine.dart';
import 'package:smartbook/data/db.dart';

SmartBookCloudSyncChange _change({
  required int changeId,
  String ledgerId = 'ledger-1',
  String entityType = 'transaction',
  String entitySyncId = 'tx-1',
  String action = 'upsert',
  Map<String, dynamic>? payload,
}) {
  return SmartBookCloudSyncChange(
    changeId: changeId,
    ledgerId: ledgerId,
    entityType: entityType,
    entitySyncId: entitySyncId,
    action: action,
    updatedByDeviceId: 'dev-test',
    updatedAt: '2026-05-24T10:00:00Z',
    payload: payload,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late BeeDatabase db;
  late SyncErrorStore store;

  setUp(() {
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    store = SyncErrorStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('record(): 新增 / 累加 / 并发', () {
    test('新 change_id → INSERT,行可查到', () async {
      await store.record(
        change: _change(changeId: 100),
        error: Exception('test error'),
        stackTrace: StackTrace.current,
      );

      final rows = await store.watchUnresolved().first;
      expect(rows, hasLength(1));
      expect(rows.first.changeId, 100);
      expect(rows.first.entityType, 'transaction');
      expect(rows.first.attemptCount, 1);
      expect(rows.first.errorMessage, contains('test error'));
      expect(rows.first.resolvedAt, isNull);
    });

    test('同 change_id 再次 record → attempt_count = 2,不抛 UNIQUE', () async {
      final ch = _change(changeId: 200);
      await store.record(
        change: ch,
        error: Exception('first'),
        stackTrace: StackTrace.current,
      );
      await store.record(
        change: ch,
        error: Exception('second'),
        stackTrace: StackTrace.current,
      );
      await store.record(
        change: ch,
        error: Exception('third'),
        stackTrace: StackTrace.current,
      );

      final rows = await store.watchUnresolved().first;
      expect(rows, hasLength(1)); // 仍是同一行
      expect(rows.first.attemptCount, 3);
      // last error 替换为最新一次
      expect(rows.first.errorMessage, contains('third'));
    });

    test('并发 record 同 change_id 不抛 UNIQUE(降级 update 兜底)', () async {
      // 模拟"两个 pull 同时跑撞同一条脏 change"的场景。
      // 实际 race 难精确复现,但 N 次并发 record 不抛即可。
      final ch = _change(changeId: 300);
      await Future.wait([
        store.record(change: ch, error: Exception('a'), stackTrace: StackTrace.current),
        store.record(change: ch, error: Exception('b'), stackTrace: StackTrace.current),
        store.record(change: ch, error: Exception('c'), stackTrace: StackTrace.current),
        store.record(change: ch, error: Exception('d'), stackTrace: StackTrace.current),
        store.record(change: ch, error: Exception('e'), stackTrace: StackTrace.current),
      ]);

      final rows = await store.watchUnresolved().first;
      expect(rows, hasLength(1));
      expect(rows.first.attemptCount, greaterThanOrEqualTo(1));
    });

    test('不同 change_id → 分行', () async {
      for (var i = 0; i < 5; i++) {
        await store.record(
          change: _change(changeId: 400 + i),
          error: Exception('e$i'),
          stackTrace: StackTrace.current,
        );
      }
      final rows = await store.watchUnresolved().first;
      expect(rows, hasLength(5));
      // 按 changeId asc 排序
      for (var i = 0; i < 5; i++) {
        expect(rows[i].changeId, 400 + i);
      }
    });

    test('错误信息字段 errorClass / errorMessage / stackTrace 都被记录', () async {
      try {
        throw FormatException('bad payload field xyz');
      } catch (e, st) {
        await store.record(
          change: _change(changeId: 500),
          error: e,
          stackTrace: st,
        );
      }

      final rows = await store.watchUnresolved().first;
      expect(rows.first.errorClass, 'FormatException');
      expect(rows.first.errorMessage, contains('bad payload field xyz'));
      expect(rows.first.stackTrace, isNotNull);
    });

    test('rawChangeJson 含完整 change 信息(供开发者诊断)', () async {
      await store.record(
        change: _change(
          changeId: 600,
          entitySyncId: 'tx-abc-123',
          payload: {'amount': 12.5, 'type': null},
        ),
        error: Exception('e'),
        stackTrace: StackTrace.current,
      );
      final rows = await store.watchUnresolved().first;
      expect(rows.first.rawChangeJson, contains('tx-abc-123'));
      expect(rows.first.rawChangeJson, contains('12.5'));
    });

    test('ledgerId 空 → ledgerExternalId 写 null(user-global change)', () async {
      await store.record(
        change: _change(changeId: 700, ledgerId: ''),
        error: Exception('e'),
        stackTrace: StackTrace.current,
      );
      final rows = await store.watchUnresolved().first;
      expect(rows.first.ledgerExternalId, isNull);
    });
  });

  group('markResolved()', () {
    test('resolved 后 watchUnresolved 不再返该行', () async {
      await store.record(
        change: _change(changeId: 800),
        error: Exception('e'),
        stackTrace: StackTrace.current,
      );
      expect((await store.watchUnresolved().first), hasLength(1));

      await store.markResolved(800);

      expect((await store.watchUnresolved().first), isEmpty);
    });

    test('markResolved 不存在的 change_id 是 nop', () async {
      await store.markResolved(99999); // 不抛
    });

    test('resolved 的 change 后续再 record → 不会唤醒(仍然 resolved)', () async {
      // server 修了脏数据 + 推新 change → 新 change_id 不同,旧 change_id 保留 resolved。
      await store.record(
        change: _change(changeId: 900),
        error: Exception('e'),
        stackTrace: StackTrace.current,
      );
      await store.markResolved(900);

      // 同 change_id 再次 record(罕见场景:用户跳过后又错误重做)
      await store.record(
        change: _change(changeId: 900),
        error: Exception('e2'),
        stackTrace: StackTrace.current,
      );

      // 行被 update,但 resolvedAt 仍非空 → watchUnresolved 不返
      final rows = await store.watchUnresolved().first;
      expect(rows, isEmpty);
    });
  });

  // ==================================================================
  // recordDeferredGiveUp:安全阀"放弃重放"的持久化(2026-10-11 复现缺陷修复)。
  //
  // 旧实现用普通 record:放弃后同轮 markResolved 无条件 resolve → UI 面
  // (watchUnresolved)永远看不到。recordDeferredGiveUp 的契约:
  //   1. 强制 resolved_at=NULL(旧行复活)—— 放弃是"当前仍未落地"的事实状态;
  //   2. error_class 固定 DeferredGiveUp —— 可机器区分的 needs-attention 状态;
  //   3. 只读语义不变(user_action 不写)。
  // ==================================================================
  group('recordDeferredGiveUp()', () {
    test('新 change_id → 落行且 error_class=DeferredGiveUp、未解决', () async {
      await store.recordDeferredGiveUp(
        change: _change(changeId: 1000, entityType: 'budget'),
        error: StateError('依赖未就绪: 已放弃重放'),
        stackTrace: StackTrace.current,
      );

      final rows = await store.watchUnresolved().first;
      expect(rows, hasLength(1));
      expect(rows.single.changeId, 1000);
      expect(rows.single.errorClass, 'DeferredGiveUp');
      expect(rows.single.entityType, 'budget');
      expect(rows.single.resolvedAt, isNull,
          reason: '放弃记录必须在 UI 查询面存活(不被 resolved)');
      expect(rows.single.userAction, isNull,
          reason: '设计是「只读不可处置」,不得写用户动作');
      expect(rows.single.errorMessage, contains('已放弃重放'));
    });

    test('已 resolved 的 change_id → 复活(resolved_at 清空,UI 重新可见)', () async {
      // 场景:普通 apply 失败被记录 → 后续某轮被 resolve(比如脏数据被服务端
      // 修好前先被全量重放的 markResolved 清掉)→ 之后安全阀放弃同一 change。
      await store.record(
        change: _change(changeId: 1001),
        error: Exception('脏数据'),
        stackTrace: StackTrace.current,
      );
      await store.markResolved(1001);
      expect(await store.watchUnresolved().first, isEmpty,
          reason: '前置:已 resolve');

      await store.recordDeferredGiveUp(
        change: _change(changeId: 1001),
        error: StateError('依赖未就绪: 已放弃重放'),
        stackTrace: StackTrace.current,
      );

      final rows = await store.watchUnresolved().first;
      expect(rows, hasLength(1), reason: '放弃必须把旧行复活为未解决');
      expect(rows.single.resolvedAt, isNull);
      expect(rows.single.errorClass, 'DeferredGiveUp');
      expect(rows.single.attemptCount, greaterThanOrEqualTo(2),
          reason: '同 change_id 复用同一行并累计尝试次数');
    });

    test('DEADLOCK: 放弃行只有该 change 真正落地才被 resolve(自愈)', () async {
      await store.recordDeferredGiveUp(
        change: _change(changeId: 1002),
        error: StateError('依赖未就绪: 已放弃重放'),
        stackTrace: StackTrace.current,
      );
      // 引擎侧修复:markResolved 只对本页真正落地的 change_id 调用;这里
      // 模拟"同轮对另一个正常条目 markResolved",放弃行必须不受影响。
      await store.markResolved(9999);
      expect(await store.watchUnresolved().first, hasLength(1));

      // 而该 change 真正落地后调用 markResolved → 自愈。
      await store.markResolved(1002);
      expect(await store.watchUnresolved().first, isEmpty,
          reason: '依赖到达 / 全量重放成功后错误可被 resolve(自愈)');
    });

    test('watchUnresolvedDeferredGiveUps 只返放弃态,不混普通失败', () async {
      await store.record(
        change: _change(changeId: 1100),
        error: Exception('普通 apply 失败'),
        stackTrace: StackTrace.current,
      );
      await store.recordDeferredGiveUp(
        change: _change(changeId: 1101),
        error: StateError('依赖未就绪: 已放弃重放'),
        stackTrace: StackTrace.current,
      );

      final all = await store.watchUnresolved().first;
      expect(all.map((e) => e.changeId), [1100, 1101],
          reason: 'watchUnresolved 是总面,两种都可见');
      final giveUps = await store.watchUnresolvedDeferredGiveUps().first;
      expect(giveUps.map((e) => e.changeId), [1101],
          reason: 'distinct needs-attention 查询面只返放弃态');
    });
  });

  // ==================================================================
  // recordPulledValueSkipped:缺陷 A(2026-10-11 复现缺陷修复)。
  //
  // pull-apply 的"值跳过"(远端非有限金额)此前只写一行 warning;cursor 照常
  // 推进 → 该 change_id 落到 cursor 之后永久拉不回来,UI 面完全看不到。
  // 契约:
  //   1. 落行且 error_class 固定 PulledValueSkipped(可机器区分);
  //   2. 强制 resolved_at=NULL(旧行复活)—— "仍未落地"必须 UI 可见;
  //   3. 带 change_id / entityType / entitySyncId / reason 可诊断上下文;
  //   4. 该 change 真正 apply 成功后 markResolved 可自愈。
  // ==================================================================
  group('recordPulledValueSkipped()', () {
    test('新 change_id → 落行、error_class=PulledValueSkipped、未解决', () async {
      await store.recordPulledValueSkipped(
        change: _change(
            changeId: 2000, entityType: 'transaction', entitySyncId: 'tx-inf'),
        reason: '远端交易金额不可用(reason=non_finite)',
      );

      final rows = await store.watchUnresolved().first;
      expect(rows, hasLength(1));
      expect(rows.single.changeId, 2000);
      expect(rows.single.entityType, 'transaction');
      expect(rows.single.entitySyncId, 'tx-inf',
          reason: '带实体 syncId,开发者可按它定位脏数据');
      expect(rows.single.errorClass, 'PulledValueSkipped',
          reason: '可机器区分于普通 apply 失败 / DeferredGiveUp');
      expect(rows.single.errorMessage, contains('non_finite'));
      expect(rows.single.resolvedAt, isNull,
          reason: '值跳过必须在 UI 查询面存活(不被同轮 markResolved 清掉)');
      expect(rows.single.userAction, isNull,
          reason: '只读不可处置设计,不写用户动作');
    });

    test('已 resolved 的 change_id → 复活(resolved_at 清空,UI 重新可见)', () async {
      await store.record(
        change: _change(changeId: 2001),
        error: Exception('先前的普通失败'),
        stackTrace: StackTrace.current,
      );
      await store.markResolved(2001);
      expect(await store.watchUnresolved().first, isEmpty, reason: '前置:已 resolve');

      await store.recordPulledValueSkipped(
        change: _change(changeId: 2001),
        reason: '远端金额不可用(跳过)',
      );

      final rows = await store.watchUnresolved().first;
      expect(rows, hasLength(1), reason: '值跳过必须把旧行复活为未解决');
      expect(rows.single.resolvedAt, isNull);
      expect(rows.single.errorClass, 'PulledValueSkipped');
      expect(rows.single.attemptCount, greaterThanOrEqualTo(2));
    });

    test('同 change_id 再次值跳过 → 计数累加,不抛 UNIQUE', () async {
      final ch = _change(changeId: 2002, entitySyncId: 'tx-dup');
      await store.recordPulledValueSkipped(change: ch, reason: '第一次');
      await store.recordPulledValueSkipped(change: ch, reason: '第二次');

      final rows = await store.watchUnresolved().first;
      expect(rows, hasLength(1), reason: '同 change_id 复用一行');
      expect(rows.single.attemptCount, 2);
      expect(rows.single.errorMessage, contains('第二次'));
    });

    test('rawChangeJson 可编码非有限 payload(不抛 JsonUnsupportedObjectError)',
        () async {
      // 缺陷 A 副作用:值跳过恰恰发生在 payload 含 Infinity 时 —— 裸
      // jsonEncode 对 Infinity 抛错会让错误行写不进去(可观测性修复被吞掉)。
      // SyncErrorStore._encodeChange 的 toEncodable 兜底把它编成字符串字面量。
      await store.recordPulledValueSkipped(
        change: _change(
          changeId: 2003,
          entitySyncId: 'tx-inf-json',
          payload: {'syncId': 'tx-inf-json', 'type': 'expense',
              'amount': double.infinity},
        ),
        reason: '远端金额不可用(reason=non_finite)',
      );

      final rows = await store.watchUnresolved().first;
      expect(rows, hasLength(1),
          reason: '含 Infinity 的 payload 也必须能落错误行');
      expect(rows.single.rawChangeJson, contains('tx-inf-json'));
      expect(rows.single.rawChangeJson, contains('Infinity'),
          reason: '非有限值以字符串字面量保留,诊断信息不丢');
    });

    test('该 change 真正落地后 markResolved 自愈', () async {
      await store.recordPulledValueSkipped(
        change: _change(changeId: 2004),
        reason: '远端金额不可用',
      );
      expect(await store.watchUnresolved().first, hasLength(1));

      await store.markResolved(2004);

      expect(await store.watchUnresolved().first, isEmpty,
          reason: '服务端修数据 / 全量重放成功后错误行被清(自愈)');
    });

    test('三种 error_class 并存时互不干扰(总面 + 各自查询面)', () async {
      await store.record(
        change: _change(changeId: 2100),
        error: Exception('普通失败'),
        stackTrace: StackTrace.current,
      );
      await store.recordDeferredGiveUp(
        change: _change(changeId: 2101),
        error: StateError('放弃重放'),
        stackTrace: StackTrace.current,
      );
      await store.recordPulledValueSkipped(
        change: _change(changeId: 2102),
        reason: '值跳过',
      );

      final all = await store.watchUnresolved().first;
      expect(all.map((e) => e.changeId), [2100, 2101, 2102],
          reason: 'watchUnresolved 是总面,三类都可见');
      final classes = all.map((e) => e.errorClass).toList();
      expect(classes, contains('DeferredGiveUp'));
      expect(classes, contains('PulledValueSkipped'));
      expect(classes.where((c) => c != 'DeferredGiveUp' && c != 'PulledValueSkipped'),
          isNotEmpty,
          reason: '普通失败的 errorClass 是异常 runtimeType(如 _Exception)');
      final giveUps = await store.watchUnresolvedDeferredGiveUps().first;
      expect(giveUps.map((e) => e.changeId), [2101],
          reason: '放弃重放查询面不混入值跳过');
    });
  });
}
