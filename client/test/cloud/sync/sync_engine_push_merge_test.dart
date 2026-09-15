/// P1-C2 回归(design-flaw-fix-plan 2026-09-15):push 合并 + 分批。
///
/// - 按 (entityType, entitySyncId) 合并:同实体多条 local_change 只发最新
///   一条,成功后整组 markPushed(旧行为逐条序列化同一快照重复 POST);
/// - 每批 ≤200 条,成功一批推进一批;失败批抛出、未推条目保留,下次续推
///   (旧行为数千条一个 POST,失败整体重推);
/// - 附录 B1:服务端 conflict/failed samples 各截断 20 条 —— 样本数 < 计数
///   时整批不 markPushed,绝不按残缺样本把被拒 change 误标已推静默丢失。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/cloud/sync/change_tracker.dart';
import 'package:smartbook/cloud/sync/sync_engine.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';

import '_fakes/fake_smartbook_cloud_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late ChangeTracker changeTracker;
  late LocalRepository repo;
  late FakeSmartBookCloudProvider provider;
  late SyncEngine engine;
  late int ledgerId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    changeTracker = ChangeTracker(db);
    repo = LocalRepository(db, changeTracker: changeTracker);
    provider = FakeSmartBookCloudProvider();
    engine = SyncEngine(
      db: db,
      provider: provider,
      changeTracker: changeTracker,
      repo: repo,
    );
    ledgerId = await db.into(db.ledgers).insert(
          LedgersCompanion.insert(name: 'L', syncId: const Value('L1')),
        );
  });

  tearDown(() async {
    provider.reset();
    await db.close();
  });

  /// 插一条 tx 行(不经过 repo,不自动登记 change)+ 登记 n 条 change,
  /// 模拟同一实体的多次编辑。
  Future<void> seedEntityWithChanges(String syncId, int changeRows) async {
    final txId = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: 'expense',
            amount: 10.0,
            syncId: Value(syncId),
          ),
        );
    for (var i = 0; i < changeRows; i++) {
      await changeTracker.recordLedgerChange(
        entityType: 'transaction',
        entityId: txId,
        entitySyncId: syncId,
        ledgerId: ledgerId,
        action: i == 0 ? 'create' : 'update',
      );
    }
  }

  test('同实体多条 change 合并为一条 POST,成功后整组 markPushed', () async {
    await seedEntityWithChanges('tx-merge-a', 3);
    await seedEntityWithChanges('tx-merge-b', 2);

    final pushed = await engine.push(ledgerId.toString());

    // 2 个实体 → 1 批、2 条(旧行为会发 5 条)。
    expect(provider.pushedBatches, hasLength(1));
    final batch = provider.pushedBatches.single;
    expect(batch, hasLength(2));
    expect(batch.map((c) => c['entity_sync_id']).toSet(),
        {'tx-merge-a', 'tx-merge-b'});
    // 代表条是组内最新意图:两条 change 的 create/update 都归一为 upsert。
    expect(batch.every((c) => c['action'] == 'upsert'), isTrue);
    // payload 是从 DB 序列化的最新快照。
    expect(batch.first['payload'], isA<Map<String, dynamic>>());
    expect(batch.first['payload']['syncId'], isNotNull);

    // 合并组内 5 行 change 全部标记已推。
    expect(await changeTracker.getUnpushedChangesForLedger(ledgerId), isEmpty);
    // 返回值语义保持「处理了多少条 change 行」。
    expect(pushed, 5);
  });

  test('250 个实体分两批推送,每批 ≤200,全部标记', () async {
    for (var i = 0; i < 250; i++) {
      await seedEntityWithChanges('tx-bulk-$i', 1);
    }

    final pushed = await engine.push(ledgerId.toString());

    expect(provider.pushedBatches, hasLength(2));
    expect(provider.pushedBatches.first, hasLength(200));
    expect(provider.pushedBatches.last, hasLength(50));
    expect(pushed, 250);
    expect(await changeTracker.getUnpushedChangesForLedger(ledgerId), isEmpty);
  });

  test('第二批失败:第一批已标记,第二批保留,下次续推', () async {
    for (var i = 0; i < 250; i++) {
      await seedEntityWithChanges('tx-resume-$i', 1);
    }
    provider.pushErrorInjector = (changes) =>
        changes.length > 200 ? Exception('network down on batch 2') : null;

    await expectLater(
        engine.push(ledgerId.toString()), throwsA(isA<Exception>()));

    // 第一批 200 条已 markPushed(成功一批推进一批),第二批 50 条保留。
    expect(await changeTracker.getUnpushedCountForLedger(ledgerId), 50);

    // 网络恢复后重推:只补第二批。
    provider.pushErrorInjector = null;
    provider.pushedBatches.clear();
    final pushed2 = await engine.push(ledgerId.toString());
    expect(pushed2, 50);
    expect(provider.pushedBatches, hasLength(1));
    expect(provider.pushedBatches.single, hasLength(50));
    expect(await changeTracker.getUnpushedChangesForLedger(ledgerId), isEmpty);
  });

  test('LWW 判负(samples 完整):仅被拒实体的合并组保留', () async {
    await seedEntityWithChanges('tx-r0', 1);
    await seedEntityWithChanges('tx-r1', 2);
    await seedEntityWithChanges('tx-r2', 1);
    provider.pushResultOverride = const SmartBookPushResult(
      accepted: 2,
      rejected: 1,
      conflictCount: 1,
      conflictSamples: [
        {'reason': 'lww_rejected_older_change', 'entitySyncId': 'tx-r1'}
      ],
      failedCount: 0,
      failedSamples: [],
      serverCursor: 0,
    );

    await engine.push(ledgerId.toString());

    final remaining = await changeTracker.getUnpushedChangesForLedger(ledgerId);
    // tx-r1 的 2 条 change 全部保留(整组不标记),其余标记。
    expect(remaining, hasLength(2));
    expect(remaining.every((c) => c.entitySyncId == 'tx-r1'), isTrue);
  });

  test('samples 截断(附录 B1):计数 > 样本数 → 整批不 markPushed', () async {
    await seedEntityWithChanges('tx-b1-0', 1);
    await seedEntityWithChanges('tx-b1-1', 1);
    await seedEntityWithChanges('tx-b1-2', 1);
    provider.pushResultOverride = const SmartBookPushResult(
      accepted: 0,
      rejected: 3,
      conflictCount: 3,
      // 服务端 conflict_samples 上限 20,这里模拟只有 1 条样本可识别。
      conflictSamples: [
        {'reason': 'lww_rejected_older_change', 'entitySyncId': 'tx-b1-0'}
      ],
      failedCount: 0,
      failedSamples: [],
      serverCursor: 0,
    );

    await engine.push(ledgerId.toString());

    // 截断导致无法点名全部被拒实体:宁可不标(重推幂等),不可误标丢失。
    final remaining = await changeTracker.getUnpushedChangesForLedger(ledgerId);
    expect(remaining, hasLength(3),
        reason: 'B1:第 21 条起被拒 change 不能被误标已推而静默丢失');
  });

  test('C11:实体行已被本地删除的 upsert change → 跳过发送且不标记', () async {
    await seedEntityWithChanges('tx-gone', 1);
    // 模拟「upsert change 残留但本地行已删」(delete change 未登记/漏推)
    await (db.delete(db.transactions)..where((t) => t.syncId.equals('tx-gone')))
        .go();

    await engine.push(ledgerId.toString());

    expect(provider.pushedBatches, isEmpty,
        reason: 'C11:序列化为 null 的行跳过,不再发空 {} upsert 毒数据');
    expect(await changeTracker.getUnpushedChangesForLedger(ledgerId),
        hasLength(1),
        reason: '跳过的行保留在 local_changes,等待 delete change/本地重建对齐');
  });

  test('附录 B3:同一代表条被拒 8 次后熔断,本会话不再重推', () async {
    await seedEntityWithChanges('tx-poison', 1);
    provider.pushResultOverride = const SmartBookPushResult(
      accepted: 0,
      rejected: 1,
      conflictCount: 1,
      conflictSamples: [
        {'reason': 'lww_rejected_older_change', 'entitySyncId': 'tx-poison'}
      ],
      failedCount: 0,
      failedSamples: [],
      serverCursor: 0,
    );
    for (var i = 0; i < SyncEngine.maxPushRejectAttempts; i++) {
      await engine.push(ledgerId.toString());
    }
    expect(provider.pushedBatches, hasLength(SyncEngine.maxPushRejectAttempts));
    provider.pushedBatches.clear();

    // 第 9 轮:熔断,整轮无 POST;change 保留本地(unpushed 可见,不静默丢)。
    await engine.push(ledgerId.toString());
    expect(provider.pushedBatches, isEmpty,
        reason: 'B3:被拒超限的实体本会话停止重推(服务端 AuditLog 不再被放大)');
    expect(await changeTracker.getUnpushedChangesForLedger(ledgerId),
        hasLength(1),
        reason: '熔断不等于丢弃:change 保留在 local_changes');
  });

  test('附录 B3:中途接受/新编辑重置计数,不会误熔断', () async {
    final txId = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: 'expense',
            amount: 10.0,
            syncId: const Value('tx-recovered'),
          ),
        );
    Future<void> addChange() => changeTracker.recordLedgerChange(
          entityType: 'transaction',
          entityId: txId,
          entitySyncId: 'tx-recovered',
          ledgerId: ledgerId,
          action: 'update',
        );
    await addChange();

    provider.pushResultOverride = const SmartBookPushResult(
      accepted: 0,
      rejected: 1,
      conflictCount: 1,
      conflictSamples: [
        {'reason': 'lww_rejected_older_change', 'entitySyncId': 'tx-recovered'}
      ],
      failedCount: 0,
      failedSamples: [],
      serverCursor: 0,
    );
    // 前 7 次被拒(未到上限 8)。
    for (var i = 0; i < SyncEngine.maxPushRejectAttempts - 1; i++) {
      await engine.push(ledgerId.toString());
    }
    // 服务端修好后一次接受:change 被标记已推,计数清除。
    provider.pushResultOverride = null;
    provider.pushedBatches.clear();
    await engine.push(ledgerId.toString());
    expect(await changeTracker.getUnpushedChangesForLedger(ledgerId), isEmpty);

    // 用户再次编辑(新 change id)+ 又开始被拒:计数从头累计,不因历史 7 次误熔断。
    await addChange();
    provider.pushResultOverride = const SmartBookPushResult(
      accepted: 0,
      rejected: 1,
      conflictCount: 1,
      conflictSamples: [
        {'reason': 'lww_rejected_older_change', 'entitySyncId': 'tx-recovered'}
      ],
      failedCount: 0,
      failedSamples: [],
      serverCursor: 0,
    );
    for (var i = 0; i < SyncEngine.maxPushRejectAttempts - 1; i++) {
      await engine.push(ledgerId.toString());
    }
    expect(provider.pushedBatches.length,
        SyncEngine.maxPushRejectAttempts - 1,
        reason: '接受/新编辑后计数重置,同样 7 次被拒不会熔断');
  });
}
