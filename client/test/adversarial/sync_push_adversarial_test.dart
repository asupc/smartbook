// Push 合并 / 分批 / 熔断 / markPushed 对抗性测试。
//
// 攻击目标(对应任务清单 push 合并/分批 + 熔断 B3):
//   - 1000 条 change 合并成 1 条 upsert;合并键大小写/空白差异是否误合并
//   - 200 / 201 / 400 / 401 实体边界:批次数、每批 ≤200、pushed 返回值语义
//   - changeIds 顺序与 representatives 对齐(交错实体的 markPushed 错标)
//   - 部分被拒 + 部分 accepted 的 markPushed 正确性
//   - rejectedEntitySyncIds 含未知 syncId 是否连坐误标
//   - rejected 数 > 样本数(截断)整批不标(B1),相邻批不受影响
//   - 熔断 B3:8 次后 0 POST;其它实体不受影响;解除条件;跨 entityType 隔离
//
// 源码:`lib/cloud/sync/sync_engine.dart`(_mergeChangesByEntity /
// _pushChangeGroups / _countPushReject / maxPushRejectAttempts)。

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:smartbook/cloud/sync/sync_engine.dart';
import 'package:smartbook/data/db.dart';

import '_fakes/adversarial_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SyncHarness h;
  late int ledgerId;

  setUp(() async {
    h = await SyncHarness.create(ledgerSyncId: 'L1');
    ledgerId = h.ledgerId;
  });

  tearDown(() async {
    await h.close();
  });

  // ==================================================================
  group('合并语义', () {
    test('同实体 1000 条 change → 合并为 1 条 upsert(最新快照)', () async {
      await h.seedEntityWithChanges('tx-many', 1000, amount: 42.0);

      final pushed = await h.engine.push('$ledgerId');

      expect(h.provider.pushedBatches, hasLength(1));
      final batch = h.provider.pushedBatches.single;
      expect(batch, hasLength(1),
          reason: '1000 条 change 同实体 → 只发 1 条(SYNC 表不再 1000x 膨胀)');
      expect(batch.single['entity_sync_id'], 'tx-many');
      expect(batch.single['action'], 'upsert');
      expect((batch.single['payload'] as Map)['amount'], 42.0);
      // 返回值语义 = 处理了多少条 change 行
      expect(pushed, 1000);
      expect(await h.unpushedForLedger(), isEmpty,
          reason: '整组 1000 行一起 markPushed');
    });

    test('大小写不同的 syncId 不被误合并(tx-a vs tx-A)', () async {
      await h.seedEntityWithChanges('tx-a', 1);
      await h.seedEntityWithChanges('tx-A', 1);

      await h.engine.push('$ledgerId');

      final batch = h.provider.pushedBatches.single;
      expect(batch, hasLength(2),
          reason: '合并键是大小写敏感的字符串,两个不同实体各发一条');
      expect(
          batch.map((c) => c['entity_sync_id']).toSet(), {'tx-a', 'tx-A'});
    });

    test('首尾空白不同的 syncId 不被误合并', () async {
      await h.seedEntityWithChanges('tx-x', 1);
      await h.seedEntityWithChanges('tx-x ', 1);

      await h.engine.push('$ledgerId');

      expect(h.provider.pushedBatches.single, hasLength(2));
      expect(
          h.provider.pushedBatches.single
              .map((c) => c['entity_sync_id'])
              .toSet(),
          {'tx-x', 'tx-x '},
          reason: '合并前不做 trim,空白差异视为不同实体(与 server 一致)');
    });

    test('合并键含 NUL 分隔符:entityType=x + syncId=y 与 entityType=xNULy 不互串',
        () async {
      // 合并键是 '${entityType}\u0000${entitySyncId}'。若 attacker/脏数据把
      // NUL 塞进 syncId,理论上能构造碰撞('transaction\0A' + 'B' vs
      // 'transaction' + 'A\0B')。这里验证不同 entityType 同 syncId 不误合并。
      final txId = await h.seedTx(syncId: 'SAME');
      await h.seedBudget(syncId: 'SAME');
      await h.recordChange(
          entityType: 'transaction', entityId: txId, entitySyncId: 'SAME');
      await h.recordChange(
          entityType: 'budget', entityId: 1, entitySyncId: 'SAME');

      await h.engine.push('$ledgerId');

      expect(h.provider.pushedBatches.single, hasLength(2),
          reason: 'transaction 与 budget 即使 syncId 相同也是两个合并组');
      expect(
          h.provider.pushedBatches.single
              .map((c) => c['entity_type'])
              .toSet(),
          {'transaction', 'budget'});
    });

    test('同实体同 syncId 但多账本 ledger-scope change 会按账本分别查询', () async {
      final other = await h.db.into(h.db.ledgers).insert(
          LedgersCompanion.insert(name: 'L2', syncId: const Value('L2')));
      final a = await h.seedTx(syncId: 'tx-x', inLedgerId: ledgerId);
      final b = await h.seedTx(syncId: 'tx-x', inLedgerId: other);
      await h.recordChange(
          entityType: 'transaction',
          entityId: a,
          entitySyncId: 'tx-x',
          inLedgerId: ledgerId);
      await h.recordChange(
          entityType: 'transaction',
          entityId: b,
          entitySyncId: 'tx-x',
          inLedgerId: other);

      await h.engine.push('$ledgerId');
      expect(h.provider.pushedBatches.single, hasLength(1),
          reason: '只推当前账本的 change');
      await h.engine.push('$other');
      expect(h.provider.pushedBatches.last, hasLength(1));
    });

    test('同实体交错别的实体:合并组内顺序与 changeIds 一一对应', () async {
      // A1 B1 A2 B2 A3 —— 两个实体交错。A 组应含 [A1,A3(最新)],B 组 [B1,B2]。
      final aId = await h.seedTx(syncId: 'tx-A', amount: 1.0);
      final bId = await h.seedTx(syncId: 'tx-B', amount: 2.0);
      final order = <(String, int)>[
        ('A', aId),
        ('B', bId),
        ('A', aId),
        ('B', bId),
        ('A', aId),
      ];
      for (final (label, id) in order) {
        await h.recordChange(
          entityType: 'transaction',
          entityId: id,
          entitySyncId: 'tx-$label',
        );
      }

      await h.engine.push('$ledgerId');

      // 两组都被标已推(first-wins 会让某组残留)
      expect(await h.unpushedForLedger(), isEmpty,
          reason: '交错实体的两组都必须整组 markPushed');
      final batch = h.provider.pushedBatches.single;
      expect(batch, hasLength(2));
      expect(batch.map((c) => c['entity_sync_id']).toSet(), {'tx-A', 'tx-B'});
    });

    test('组内最新意图是 delete → 发 delete', () async {
      final txId = await h.seedTx(syncId: 'tx-del');
      await h.recordChange(
          entityType: 'transaction', entityId: txId, entitySyncId: 'tx-del');
      // 本地删除实体 + 登记 delete change(后者 id 更大 = 最新意图)
      await (h.db.delete(h.db.transactions)
            ..where((t) => t.id.equals(txId)))
          .go();
      await h.recordChange(
        entityType: 'transaction',
        entityId: txId,
        entitySyncId: 'tx-del',
        action: 'delete',
      );

      await h.engine.push('$ledgerId');

      final sent = h.provider.pushedBatches.single.single;
      expect(sent['action'], 'delete',
          reason: '组内最后一条是 delete → representative 发 delete');
      expect(sent['payload'], isEmpty);
    });

    test('组内最新意图是 delete 之前的 upsert 不会先发 upsert(避免误建后删)', () async {
      final txId = await h.seedTx(syncId: 'tx-del2');
      await h.recordChange(
          entityType: 'transaction', entityId: txId, entitySyncId: 'tx-del2');
      await h.recordChange(
        entityType: 'transaction',
        entityId: txId,
        entitySyncId: 'tx-del2',
        action: 'delete',
      );
      // 实体行尚在(delete change 是乐观登记)—— 合并后应只发 delete
      await h.engine.push('$ledgerId');
      expect(h.provider.pushedBatches.single, hasLength(1));
      expect(h.provider.pushedBatches.single.single['action'], 'delete');
    });
  });

  // ==================================================================
  group('分批边界 200/201/400/401', () {
    Future<void> seedN(int n) async {
      for (var i = 0; i < n; i++) {
        await h.seedEntityWithChanges('tx-b-$i', 1);
      }
    }

    test('恰好 200 个实体 → 1 批 200 条', () async {
      await seedN(200);
      final pushed = await h.engine.push('$ledgerId');
      expect(h.provider.pushedBatches, hasLength(1));
      expect(h.provider.pushedBatches.single, hasLength(200));
      expect(pushed, 200);
      expect(await h.unpushedForLedger(), isEmpty);
    });

    test('201 个实体 → 2 批(200 + 1)', () async {
      await seedN(201);
      final pushed = await h.engine.push('$ledgerId');
      expect(h.provider.pushedBatches, hasLength(2));
      expect(h.provider.pushedBatches.first, hasLength(200));
      expect(h.provider.pushedBatches.last, hasLength(1));
      expect(pushed, 201);
      expect(await h.unpushedForLedger(), isEmpty);
    });

    test('400 个实体 → 2 批(200 + 200)', () async {
      await seedN(400);
      final pushed = await h.engine.push('$ledgerId');
      expect(h.provider.pushedBatches, hasLength(2));
      expect(h.provider.pushedBatches.map((b) => b.length).toList(), [200, 200]);
      expect(pushed, 400);
    });

    test('401 个实体 → 3 批(200 + 200 + 1)', () async {
      await seedN(401);
      final pushed = await h.engine.push('$ledgerId');
      expect(h.provider.pushedBatches, hasLength(3));
      expect(h.provider.pushedBatches.map((b) => b.length).toList(),
          [200, 200, 1]);
      expect(pushed, 401);
    });

    test('每批 ≤200 是硬上界(401 实体 + 每组 2 条 change)', () async {
      for (var i = 0; i < 401; i++) {
        await h.seedEntityWithChanges('tx-c-$i', 2);
      }
      final pushed = await h.engine.push('$ledgerId');
      expect(h.provider.pushedBatches.map((b) => b.length).toList(),
          [200, 200, 1],
          reason: '批次按**合并后实体数**切,不是 change 行数');
      expect(pushed, 802, reason: 'pushed 返回值语义 = change 行数');
    });

    test('pushed 返回值 = change 行数(非实体数)', () async {
      await h.seedEntityWithChanges('tx-r1', 3);
      await h.seedEntityWithChanges('tx-r2', 7);
      final pushed = await h.engine.push('$ledgerId');
      expect(pushed, 10, reason: '返回值是处理过的 change 行数,与 batch 条数无关');
      expect(h.provider.pushedBatches.single, hasLength(2));
    });
  });

  // ==================================================================
  group('markPushed 对齐 / 部分被拒', () {
    test('3 实体 1 拒 2 接受 → 只有被拒组的全部 change 保留', () async {
      await h.seedEntityWithChanges('tx-ok1', 1);
      await h.seedEntityWithChanges('tx-bad', 3);
      await h.seedEntityWithChanges('tx-ok2', 2);

      h.provider.pushResultOverride = rejectNamed(['tx-bad']);
      await h.engine.push('$ledgerId');

      final remaining = await h.unpushedForLedger();
      expect(remaining, hasLength(3),
          reason: 'tx-bad 的 3 条 change 整组保留(不部分标记)');
      expect(remaining.every((c) => c.entitySyncId == 'tx-bad'), isTrue,
          reason: '其余 2 个实体的 change 必须全部标已推');
    });

    test('全部被拒 → 一条都不标已推', () async {
      await h.seedEntityWithChanges('tx-a', 1);
      await h.seedEntityWithChanges('tx-b', 1);
      h.provider.pushResultOverride = rejectNamed(['tx-a', 'tx-b']);
      await h.engine.push('$ledgerId');
      expect(await h.unpushedForLedger(), hasLength(2));
    });

    test('failed(reason=apply_failed)与 conflict 同样进 rejectedEntitySyncIds',
        () async {
      await h.seedEntityWithChanges('tx-c', 1);
      await h.seedEntityWithChanges('tx-f', 1);
      h.provider.pushResultOverride =
          rejectFailed(['tx-f']);
      await h.engine.push('$ledgerId');

      final remaining = await h.unpushedForLedger();
      expect(remaining.map((c) => c.entitySyncId).toList(), ['tx-f'],
          reason: 'failedSamples 的 entitySyncId 也被识别为被拒(D10 语义)');
    });

    test('ADVERSE-CANDIDATE: rejectedEntitySyncIds 含**未发送**的未知 syncId → 不连坐已有实体',
        () async {
      // 服务端返回了一个本地这轮根本没发的 syncId(脏数据 / server bug)。
      // Engine 用 `!rejectedSyncIds.contains(batch[i].entitySyncId)` 判定
      // 每条已发代表:未知 id 不在 batch 里 → 不影响任何已发实体。
      await h.seedEntityWithChanges('tx-mine', 1);
      h.provider.pushResultOverride =
          rejectNamed(['tx-never-sent', 'tx-also-unknown']);
      await h.engine.push('$ledgerId');

      expect(await h.unpushedForLedger(), isEmpty,
          reason: '未知 syncId 无法点名任何本地实体 → 已发的 tx-mine 正常标已推');
    });

    test('ADVERSE-CANDIDATE: 同名 syncId 跨 entityType 被连坐(服务端只返 syncId)',
        () async {
      // rejectedEntitySyncIds 是**纯 syncId 集合**,不带 entityType。若同
      // syncId 同时存在于 transaction 与 budget(本地可能的脏数据 / 导入
      // 留下),服务端只拒了 transaction,本地会把 budget 的同名实体也留下
      // 重推 —— 保守方向(不会丢数据),但会造成"该标的没标"。
      final txId = await h.seedTx(syncId: 'SHARED');
      await h.seedBudget(syncId: 'SHARED');
      await h.recordChange(
          entityType: 'transaction', entityId: txId, entitySyncId: 'SHARED');
      await h.recordChange(
          entityType: 'budget', entityId: 1, entitySyncId: 'SHARED');

      h.provider.pushResultOverride = rejectNamed(['SHARED']);
      await h.engine.push('$ledgerId');

      final remaining = await h.unpushedForLedger();
      expect(remaining, hasLength(2),
          reason: 'ADVERSE: syncId 相同 → transaction 与 budget 被一起判为被拒,'
              'budget 的 change 无谓保留(需 pull 对齐或下轮重推)');
    });

    test('samples 截断(B1):计数 > 样本数 → 整批不 markPushed', () async {
      await h.seedEntityWithChanges('tx-t0', 1);
      await h.seedEntityWithChanges('tx-t1', 1);
      await h.seedEntityWithChanges('tx-t2', 1);
      h.provider.pushResultOverride = rejectTruncated(
        reportedCount: 3,
        samples: ['tx-t0'],
      );
      await h.engine.push('$ledgerId');
      expect(await h.unpushedForLedger(), hasLength(3),
          reason: 'B1:第 21 条起被拒 change 不能被误标已推而静默丢失');
    });

    test('B1 只影响截断批:相邻正常批照常标记', () async {
      // 250 实体 → 2 批。第 1 批(200 条)截断不标;第 2 批(50 条)正常。
      for (var i = 0; i < 250; i++) {
        await h.seedEntityWithChanges('tx-x-$i', 1);
      }
      h.provider.pushResultOverride = null;
      h.provider.pushResultScript = (callIndex, changes) {
        if (callIndex == 1) {
          return rejectTruncated(
            reportedCount: changes.length,
            samples: [changes.first['entity_sync_id'] as String],
          );
        }
        return null; // 后续批走 override / 默认全 accepted
      };

      await h.engine.push('$ledgerId');

      expect(h.provider.pushedBatches, hasLength(2));
      // 第 1 批(200 条)整批未标;第 2 批(50 条)全标
      expect(await h.unpushedForLedger(), hasLength(200),
          reason: 'B1 逐批判定:截断批全保留,第 2 批正常标记');
      expect(
        (await h.unpushedForLedger()).map((c) => c.entitySyncId).toSet(),
        {for (var i = 0; i < 200; i++) 'tx-x-$i'},
        reason: '保留的正是第 1 批(前 200 个实体)',
      );
    });

    test('ADVERSE FINDING: rejected 计数 >0 但零样本 → 被拒的 change 被误标已推(静默丢失)',
        () async {
      // ADVERSE FINDING(高):服务端 `rejected` 字段被客户端完全忽略。
      //
      // server push.py 有两条**只 `rejected += 1` 不带任何 sample** 的拒绝分支:
      //   - push.py:305   ledger-scoped change missing ledger_id
      //   - push.py:413   非 owner 推 ledger / ledger_snapshot
      // 这两条路径下响应是 `rejected: 1, conflict_count: 0, failed_count: 0,
      // conflict_samples: [], failed_samples: []`。
      //
      // 客户端 sync_engine.dart:1212 只算
      //   `reportedRejections = conflictCount + failedCount`  → 0
      // 于是 B1 截断保护(`rejectedSyncIds.length < reportedRejections`)判定为
      // 0 < 0 = false,不走「整批保留」;而 rejectedSyncIds 是空集,导致
      // okChangeIds 收下**全部**已发代表条 → markPushed。
      //
      // 结果:服务端明确拒收(未写入 canonical state)的 change 在本地被标记
      // 「已推送」,再也不会重推 —— 用户的本地修改静默丢失。
      await h.seedEntityWithChanges('tx-ns', 1);
      h.provider.pushResultOverride = rejectCountOnly(1);

      await h.engine.push('$ledgerId');

      expect(await h.unpushedForLedger(), hasLength(1),
          reason: 'ADVERSE FINDING: server rejected=1 但 conflict/failed 计数为 0 时,'
              '客户端应保守保留该 change;当前实现把它 markPushed → 修改永久丢失');
    });

    test('ADVERSE FINDING: 零样本拒绝路径既不触发 B1 也不累计 B3 熔断计数', () async {
      // ADVERSE FINDING(高,与上条同根因但后果不同):因为第一轮就把 change
      // 误标已推,后续轮次已无 change 可推 —— B3 熔断计数根本没机会累计。
      // 也就是说 server push.py:305/413 这两类拒绝既逃过 B1(整批保留)也
      // 逃过 B3(熔断限流),直接变成静默丢数据。
      await h.seedEntityWithChanges('tx-ns2', 1);
      h.provider.pushResultOverride = rejectCountOnly(1);

      for (var i = 0; i < 3; i++) {
        await h.engine.push('$ledgerId');
      }

      expect(h.provider.pushedBatches, hasLength(3),
          reason: 'ADVERSE FINDING: 期望 3 轮都在重推(整批保留 + 计数),'
              '实际第 1 轮后 change 已被误标,后两轮 0 POST');
      expect(await h.unpushedForLedger(), hasLength(1),
          reason: 'ADVERSE FINDING: change 应保留到服务端接受为止');
    });
  });

  // ==================================================================
  group('熔断 B3', () {
    Future<void> seedPoison(String syncId) async {
      await h.seedEntityWithChanges(syncId, 1);
    }

    test('被拒 8 次熔断后继续 push 0 POST', () async {
      await seedPoison('tx-poison');
      h.provider.pushResultOverride = rejectNamed(['tx-poison']);
      for (var i = 0; i < SyncEngine.maxPushRejectAttempts; i++) {
        await h.engine.push('$ledgerId');
      }
      expect(h.provider.pushedBatches, hasLength(
          SyncEngine.maxPushRejectAttempts));
      h.provider.pushedBatches.clear();

      await h.engine.push('$ledgerId');
      expect(h.provider.pushedBatches, isEmpty,
          reason: 'B3:被拒超限的实体本会话停止重推');
      expect(await h.unpushedForLedger(), hasLength(1),
          reason: '熔断 ≠ 丢弃:change 保留在 local_changes');
    });

    test('熔断实体不影响其它实体:同一轮内正常实体照常推', () async {
      await seedPoison('tx-poison');
      h.provider.pushResultOverride = rejectNamed(['tx-poison']);
      for (var i = 0; i < SyncEngine.maxPushRejectAttempts; i++) {
        await h.engine.push('$ledgerId');
      }

      // 新实体加入
      await h.seedEntityWithChanges('tx-fresh', 1);
      h.provider.pushedBatches.clear();
      await h.engine.push('$ledgerId');

      expect(h.provider.pushedBatches, hasLength(1));
      final batch = h.provider.pushedBatches.single;
      expect(batch, hasLength(1),
          reason: '熔断条被跳过(不占请求位),只发新实体');
      expect(batch.single['entity_sync_id'], 'tx-fresh');
      expect(await h.unpushedForLedger(), hasLength(1),
          reason: '只剩熔断的那条');
      expect((await h.unpushedForLedger()).single.entitySyncId, 'tx-poison');
    });

    test('ADVERSE: 熔断后服务端改判接受 → 本会话仍 0 POST,永远推不出去', () async {
      // 场景:服务端修好了/用户改了 server 状态,但客户端没有新 change,
      // 熔断状态只在本会话内存。用户反复点"同步"也不会重推,只能重启 App。
      // 这是 B3 的设计取舍(注释已说明"进程重启后重新获得 N 次机会"),但
      // **没有 UI 暴露**(注释里写"UI 暴露…可后置")→ 用户看到
      // "同步完成" 但 unpushed 计数永远 >0,无任何提示。
      await seedPoison('tx-recover');
      h.provider.pushResultOverride = rejectNamed(['tx-recover']);
      for (var i = 0; i < SyncEngine.maxPushRejectAttempts; i++) {
        await h.engine.push('$ledgerId');
      }
      h.provider.pushedBatches.clear();

      // 服务端现在接受
      h.provider.pushResultOverride = null;
      await h.engine.push('$ledgerId');

      expect(h.provider.pushedBatches, isEmpty,
          reason: 'ADVERSE: 服务端已接受但客户端熔断 → 不再 POST');
      expect(await h.unpushedForLedger(), hasLength(1),
          reason: 'ADVERSE: change 滞留本地;仅重启 App(SyncEngine 重建)可解除');
    });

    test('ADVERSE FINDING: pull 对齐也不能解除熔断(只有实体行被删才算"绕过")',
        () async {
      await seedPoison('tx-stuck');
      h.provider.pushResultOverride = rejectNamed(['tx-stuck']);
      for (var i = 0; i < SyncEngine.maxPushRejectAttempts; i++) {
        await h.engine.push('$ledgerId');
      }
      h.provider.pushedBatches.clear();

      // 场景 A:服务端没有该实体的新 change(pull 空)
      h.provider.pullResponder = (c, since, limit) => page([], cursor: 0);
      await h.engine.pull('$ledgerId');
      h.provider.pushResultOverride = null;
      await h.engine.push('$ledgerId');
      expect(h.provider.pushedBatches, isEmpty,
          reason: 'pull 空 → 熔断状态未变 → 仍不推');

      // 场景 B:服务端**主动删除**该实体(pull 下发 delete change)。
      // apply 删掉本地实体行后,本地残留的 upsert change 变成 C11 孤儿行
      // (实体不存在 → buildSyncChange 返 null → 跳过发送 + 不标记)。
      // 结果是 push 永远不发这条,而 unpushed 计数**永久 > 0**。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-stuck',
              ledgerId: h.ledgerSyncId,
              action: 'delete',
            ),
          ], cursor: 1);
      await h.engine.pull('$ledgerId');
      h.provider.pushedBatches.clear();
      await h.engine.push('$ledgerId');

      expect(h.provider.pushedBatches, isEmpty);
      expect(await h.db.select(h.db.transactions).get(), isEmpty,
          reason: '远端 delete 已 apply,本地实体行被删');
      expect(await h.unpushedForLedger(), hasLength(1),
          reason: 'ADVERSE FINDING: upsert change 永久堆在本地'
              '(C11 跳过发送也不标记)→ unpushed 计数永久残留,'
              'UI 永远显示"有未同步变更"但同步报告成功');
    });

    test('ADVERSE FINDING: 熔断后新 change id 无法解除熔断(文档承诺的解锁路径未实现)',
        () async {
      // ADVERSE FINDING(中):`_pushChangeGroups` 的跳过判定在**发送之前**:
      //   sync_engine.dart:1196 `if (state != null && state.tripped) continue;`
      // 而计数重置只发生在**已发送**的代表条上(`_countPushReject` 比较
      // `prev.repChangeId == rep.id`)。熔断条永远进不了 `_countPushReject`,
      // 所以"用户再次编辑产生新 change id → 计数重置"这条文档承诺的解锁
      // 路径 (sync_engine.dart:96-97 / 1264-1265) **不可达**。
      //
      // 唯一能清除 tripped 的是"该实体推送成功"(1250 行 remove)——
      // 但熔断条不被发送,也就永远不会成功 → 会话内永久死锁。
      final txId = await h.seedEntityWithChanges('tx-edit', 1);
      h.provider.pushResultOverride = rejectNamed(['tx-edit']);
      for (var i = 0; i < SyncEngine.maxPushRejectAttempts; i++) {
        await h.engine.push('$ledgerId');
      }
      h.provider.pushedBatches.clear();
      await h.engine.push('$ledgerId');
      expect(h.provider.pushedBatches, isEmpty, reason: '前置:已熔断');

      // 用户编辑 → 新 change id(文档承诺"计数重置")
      await (h.db.update(h.db.transactions)..where((t) => t.id.equals(txId)))
          .write(const TransactionsCompanion(amount: Value(999.0)));
      await h.recordChange(
        entityType: 'transaction',
        entityId: txId,
        entitySyncId: 'tx-edit',
        action: 'update',
      );

      h.provider.pushedBatches.clear();
      // 服务端此时已恢复正常
      h.provider.pushResultOverride = null;
      await h.engine.push('$ledgerId');

      expect(h.provider.pushedBatches, hasLength(1),
          reason: 'ADVERSE FINDING: 新 change id 应重置计数并重新尝试;'
              '当前实现 tripped 条在发送前被 continue 掉,计数永不重置 → 用户编辑也无法自救');
      expect(await h.unpushedForLedger(), isEmpty,
          reason: 'ADVERSE FINDING: 用户新编辑的 change 应能推出去');
    });

    test('ADVERSE FINDING: 熔断后新 change id 也不重置计数(tripped 不可逆)', () async {
      // ADVERSE FINDING(中,与上条同根因的另一面):即使后来服务端改判接受,
      // 熔断条也拿不到"被接受"的机会,`_pushRejectState.remove`(1249 行)
      // 永不执行 —— 因为它只对**已发送**的代表条生效,而熔断条在 1197 行
      // 就被 `continue` 跳过。
      final txId = await h.seedEntityWithChanges('tx-re', 1);
      h.provider.pushResultOverride = rejectNamed(['tx-re']);
      for (var i = 0; i < SyncEngine.maxPushRejectAttempts; i++) {
        await h.engine.push('$ledgerId');
      }
      h.provider.pushedBatches.clear();

      // 用户编辑(新 change id)
      await (h.db.update(h.db.transactions)..where((t) => t.id.equals(txId)))
          .write(const TransactionsCompanion(amount: Value(1.5)));
      await h.recordChange(
          entityType: 'transaction',
          entityId: txId,
          entitySyncId: 'tx-re',
          action: 'update');
      // 夹具修正(2026-10-11 C4):本用例断言"新 change id 获得**全新 8 次
      // 机会**"= 8 轮都要真发。若这里把服务端改成接受(override=null),第 1 轮
      // 就会被 markPushed、后 7 轮无 change 可推 → 1 批 → 断言(期望 8)对不上
      // (原夹具显然是从上一条用例复制的,混淆了两种语义)。保持"服务端持续
      // 拒绝",8 次机会才可观测。**断言未做任何放宽**。
      h.provider.pushResultOverride = rejectNamed(['tx-re']);

      // 再推 maxPushRejectAttempts 轮 —— 期望"新 change 从头尝试"
      for (var i = 0; i < SyncEngine.maxPushRejectAttempts; i++) {
        await h.engine.push('$ledgerId');
      }
      expect(h.provider.pushedBatches, hasLength(SyncEngine.maxPushRejectAttempts),
          reason: 'ADVERSE FINDING: 新 change id 应获得全新 8 次机会;'
              '当前实现 tripped 不可逆 → 0 次 POST');
    });

    test('熔断后再被拒(第 9 次起)不会再计数到"新的一轮"(repChangeId 不变)',
        () async {
      await h.seedEntityWithChanges('tx-cap', 1);
      h.provider.pushResultOverride = rejectNamed(['tx-cap']);
      for (var i = 0; i < SyncEngine.maxPushRejectAttempts + 3; i++) {
        await h.engine.push('$ledgerId');
      }
      // 只有前 8 次真 POST
      expect(h.provider.pushedBatches,
          hasLength(SyncEngine.maxPushRejectAttempts),
          reason: '跳过熔断条时不消耗 HTTP 请求');
    });

    test('跨 entityType 隔离:transaction:x 与 budget:x 互不影响', () async {
      // 注意:服务端只返 syncId(不含 type),所以这里用**不同** syncId 验证
      // 键里确实带了 entityType —— 同 syncId 的跨类型连坐由上面的
      // 'ADVERSE-CANDIDATE' 用例单独覆盖。
      final txId = await h.seedTx(syncId: 'tx-iso');
      final budgetId = await h.seedBudget(syncId: 'bud-iso');
      await h.recordChange(
          entityType: 'transaction', entityId: txId, entitySyncId: 'tx-iso');
      await h.recordChange(
          entityType: 'budget', entityId: budgetId, entitySyncId: 'bud-iso');

      h.provider.pushResultOverride = rejectNamed(['tx-iso']);
      for (var i = 0; i < SyncEngine.maxPushRejectAttempts; i++) {
        await h.engine.push('$ledgerId');
      }
      h.provider.pushedBatches.clear();

      await h.engine.push('$ledgerId');
      // tx-iso 熔断跳过;bud-iso 已被接受过 → 无 unpushed
      expect(h.provider.pushedBatches, isEmpty,
          reason: '两个实体独立计数:tx-iso 熔断不影响 bud-iso 的已完成状态');
      expect(await h.unpushedForLedger(), hasLength(1));
      expect((await h.unpushedForLedger()).single.entitySyncId, 'tx-iso');
    });

    test('user-global 与 ledger-scope 的熔断键共享同一 map 但键带 entityType',
        () async {
      final accId = await h.seedAccount(syncId: 'acc-iso');
      await h.recordUserGlobalChange(
          entityType: 'account', entityId: accId, entitySyncId: 'acc-iso');
      final txId = await h.seedTx(syncId: 'tx-other');
      await h.recordChange(
          entityType: 'transaction', entityId: txId, entitySyncId: 'tx-other');

      h.provider.pushResultOverride = rejectNamed(['acc-iso']);
      for (var i = 0; i < SyncEngine.maxPushRejectAttempts; i++) {
        await h.engine.push('$ledgerId');
      }
      h.provider.pushedBatches.clear();
      await h.engine.push('$ledgerId');
      expect(h.provider.pushedBatches, isEmpty,
          reason: 'account 熔断;tx-other 早已接受 → 整轮 0 POST');
      expect(await h.unpushedGlobal(), hasLength(1));
    });

    test('HARDENING: 熔断状态仅内存(新 SyncEngine 实例重置)', () async {
      await h.seedEntityWithChanges('tx-mem', 1);
      h.provider.pushResultOverride = rejectNamed(['tx-mem']);
      for (var i = 0; i < SyncEngine.maxPushRejectAttempts; i++) {
        await h.engine.push('$ledgerId');
      }
      h.provider.pushedBatches.clear();
      await h.engine.push('$ledgerId');
      expect(h.provider.pushedBatches, isEmpty, reason: '前置:旧实例已熔断');

      // 模拟重启:新 SyncEngine 实例,同 db
      final engine2 = SyncEngine(
        db: h.db,
        provider: h.provider,
        changeTracker: h.changeTracker,
        repo: h.repo,
      );
      await engine2.push('$ledgerId');
      expect(h.provider.pushedBatches, hasLength(1),
          reason: 'HARDENING: 熔断是 per-instance 内存态,重启即重置(设计如此)');
    });
  });
}
