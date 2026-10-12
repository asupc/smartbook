/// 中-1 / 中-1b(2026-10-11 三轮复查)回归:push 终态拒绝不再无限重推;
/// purge 账本时连带清 local_changes。
///
/// 服务端终态拒绝 reason(与 `server/src/routers/sync/push.py` 逐字同步,
/// 见 [SmartBookPushResult.terminalRejectionReasons]):
/// `ledger_deleted` / `membership_revoked` / `unknown_ledger` /
/// `sync_id_mismatch` / `entity_sync_id_too_long`。
///
/// 旧行为:终态拒绝与 LWW 判负同等对待(不 markPushed、留在 local_changes)
/// → 8 次/会话 + 每 30min 探测 + 重启计数重置地永久空转。
/// 修复:唯一匹配到合并组 → **丢弃 + 持久错误行**(error_class =
/// PushTerminalRejected,watchUnresolved 可见);匹配不到 → 保守重推。
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
  late FakeSmartBookCloudProvider provider;
  late SyncEngine engine;
  late int ledgerId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    changeTracker = ChangeTracker(db);
    final repo = LocalRepository(db, changeTracker: changeTracker);
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

  /// 直插 tx + 登记 n 条 change(不经 repo,免自动联动)。
  Future<void> seedWithChanges(String syncId, int rows) async {
    final txId = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: 'expense',
            amount: 10.0,
            syncId: Value(syncId),
          ),
        );
    for (var i = 0; i < rows; i++) {
      await changeTracker.recordLedgerChange(
        entityType: 'transaction',
        entityId: txId,
        entitySyncId: syncId,
        ledgerId: ledgerId,
        action: i == 0 ? 'create' : 'update',
      );
    }
  }

  SmartBookPushResult terminalResult(String syncId,
      {String reason = 'ledger_deleted', String entityType = 'transaction'}) {
    return SmartBookPushResult(
      accepted: 0,
      rejected: 1,
      conflictCount: 0,
      conflictSamples: const [],
      failedCount: 1,
      failedSamples: [
        {
          'reason': reason,
          'ledgerId': 'L1',
          'entityType': entityType,
          'entitySyncId': syncId,
        }
      ],
      serverCursor: 0,
    );
  }

  group('中-1a: 终态拒绝 → 丢弃 + 错误行 + unpushed 排水', () {
    test('ledger_deleted:合并组整组丢弃,错误行落库且跨轮存活,后续轮不再推',
        () async {
      await seedWithChanges('tx-term', 2); // 同实体 2 条 change = 1 合并组
      provider.pushResultOverride = terminalResult('tx-term');

      await engine.push(ledgerId.toString());

      // 合并组 2 条 change 全部删除(不是 markPushed —— 是从队列消失)。
      expect(await changeTracker.getUnpushedChangesForLedger(ledgerId), isEmpty,
          reason: '中-1a:终态拒绝的 change 被丢弃,unpushed 排水');
      final allRows = await db.select(db.localChanges).get();
      expect(allRows.where((c) => c.entitySyncId == 'tx-term'), isEmpty,
          reason: '行被 DELETE 而非标记(不再占用队列)');

      // 错误行:PushTerminalRejected、未解决、带 reason / 实体 / 丢弃清单。
      final errs = await engine.pullErrors.watchUnresolved().first;
      expect(errs, hasLength(1));
      final err = errs.single;
      expect(err.errorClass, 'PushTerminalRejected');
      expect(err.entityType, 'transaction');
      expect(err.entitySyncId, 'tx-term');
      expect(err.ledgerExternalId, 'L1');
      expect(err.errorMessage, contains('ledger_deleted'));
      expect(err.errorMessage, contains('已丢弃本地待推变更'));
      expect(err.resolvedAt, isNull);
      expect(err.rawChangeJson, contains('"kind":"push_terminal_rejected"'));
      expect(err.rawChangeJson, contains('ledger_deleted'));

      // distinct 查询面。
      final term =
          await engine.pullErrors.watchUnresolvedPushTerminalRejected().first;
      expect(term, hasLength(1));

      // 后续轮:队列已空,不再有 POST(旧行为 9 轮 8 批永不排水)。
      provider.pushedBatches.clear();
      provider.pushResultOverride = null;
      await engine.push(ledgerId.toString());
      expect(provider.pushedBatches, isEmpty,
          reason: '终态丢弃后不再重推(旧行为:8 次/会话 + 30min 探测循环)');

      // 错误行跨轮存活(不会被 markResolved 类路径自愈)。
      expect(await engine.pullErrors.watchUnresolved().first, hasLength(1));
    });

    test('五种终态 reason 全部触发丢弃(与 push.py 逐字一致)', () async {
      const reasons = [
        'ledger_deleted',
        'membership_revoked',
        'unknown_ledger',
        'sync_id_mismatch',
        'entity_sync_id_too_long',
      ];
      expect(SmartBookPushResult.terminalRejectionReasons,
          containsAll(reasons),
          reason: '集合必须与服务端 push.py 的终态 reason 逐字同步');
      for (final reason in reasons) {
        await seedWithChanges('tx-$reason', 1);
      }
      provider.pushResultOverride = SmartBookPushResult(
        accepted: 0,
        rejected: reasons.length,
        conflictCount: 0,
        conflictSamples: const [],
        failedCount: reasons.length,
        failedSamples: [
          for (final reason in reasons)
            {
              'reason': reason,
              'ledgerId': 'L1',
              'entityType': 'transaction',
              'entitySyncId': 'tx-$reason',
            }
        ],
        serverCursor: 0,
      );

      await engine.push(ledgerId.toString());

      expect(await changeTracker.getUnpushedChangesForLedger(ledgerId), isEmpty,
          reason: '每种终态 reason 都触发丢弃');
      final errs = await engine.pullErrors.watchUnresolved().first;
      expect(errs, hasLength(reasons.length));
      final recordedReasons = errs
          .map((e) => e.errorMessage)
          .whereType<String>()
          .map((m) => RegExp('reason=([a-z_]+)').firstMatch(m)?.group(1))
          .toSet();
      expect(recordedReasons, containsAll(reasons));
    });

    test('lww_tie_action_kept(非终态)→ 保持既有重试语义(回归保护)', () async {
      await seedWithChanges('tx-lww', 1);
      provider.pushResultOverride = const SmartBookPushResult(
        accepted: 0,
        rejected: 1,
        conflictCount: 1,
        conflictSamples: [
          {'reason': 'lww_tie_action_kept', 'entitySyncId': 'tx-lww'}
        ],
        failedCount: 0,
        failedSamples: [],
        serverCursor: 0,
      );

      await engine.push(ledgerId.toString());

      expect(await changeTracker.getUnpushedChangesForLedger(ledgerId),
          hasLength(1),
          reason: 'LWW 判负保留 local_changes 待 pull 对齐(旧行为不变)');
      final errs = await engine.pullErrors.watchUnresolved().first;
      expect(errs, isEmpty,
          reason: '非终态拒绝不落终态错误行');
    });

    test('安全阀:sample 缺 entityType(匹配不了)→ 保守重推,绝不误删', () async {
      await seedWithChanges('tx-unmatched', 1);
      provider.pushResultOverride = const SmartBookPushResult(
        accepted: 0,
        rejected: 1,
        conflictCount: 0,
        conflictSamples: [],
        failedCount: 1,
        failedSamples: [
          // 有 entitySyncId 但缺 entityType → 无法唯一匹配。
          {'reason': 'ledger_deleted', 'entitySyncId': 'tx-unmatched'}
        ],
        serverCursor: 0,
      );

      await engine.push(ledgerId.toString());

      expect(await changeTracker.getUnpushedChangesForLedger(ledgerId),
          hasLength(1),
          reason: '匹配不了的 sample 保守保留重推(never drop what you '
              'can\'t identify)');
      expect(await engine.pullErrors.watchUnresolved().first, isEmpty);
    });

    test('同批混合:1 终态 + 1 好行 → 终态丢弃、好行照常 markPushed', () async {
      await seedWithChanges('tx-mixed-term', 1);
      await seedWithChanges('tx-mixed-ok', 1);
      provider.pushResultOverride = SmartBookPushResult(
        accepted: 1,
        rejected: 1,
        conflictCount: 0,
        conflictSamples: const [],
        failedCount: 1,
        failedSamples: [
          {
            'reason': 'membership_revoked',
            'ledgerId': 'L1',
            'entityType': 'transaction',
            'entitySyncId': 'tx-mixed-term',
          }
        ],
        serverCursor: 0,
      );

      await engine.push(ledgerId.toString());

      final remaining = await changeTracker.getUnpushedChangesForLedger(ledgerId);
      expect(remaining, isEmpty,
          reason: '终态组被删、好组被 markPushed → 队列净空');
      expect(
          await db.select(db.localChanges).get(),
          everyElement((c) => c.entitySyncId != 'tx-mixed-term'),
          reason: '终态组行删除');
    });
  });

  group('中-1b: purge 账本连带清 local_changes', () {
    test('member_change.removed → 数据 + local_changes 全清 + 汇总错误行',
        () async {
      await seedWithChanges('tx-orphan', 2);

      engine.startListeningRealtime();
      provider.emitRealtimeEvent(SmartBookCloudRealtimeEvent(
        type: 'member_change',
        ledgerId: 'L1',
        rawData: const {'changeType': 'removed', 'userId': 'test-user-id'},
      ));
      await Future.delayed(const Duration(milliseconds: 300));
      engine.stopListeningRealtime();

      expect(await changeTracker.getUnpushedChangesForLedger(ledgerId),
          isEmpty,
          reason: '中-1b:purge 连带清待推 change(旧行为:upsert 被 C11 永久'
              '静默跳过 / delete 吃 ledger_deleted 拒绝进入重推循环)');
      expect(await db.select(db.ledgers).get(), isEmpty);
      expect(await db.select(db.transactions).get(), isEmpty);

      // 汇总错误行:一条,可见于 watchUnresolved。
      final errs = await engine.pullErrors.watchUnresolved().first;
      expect(errs, hasLength(1));
      expect(errs.single.errorClass, 'PushTerminalRejected');
      expect(errs.single.ledgerExternalId, 'L1');
      expect(errs.single.errorMessage, contains('ledger_purged_locally'));
      expect(errs.single.errorMessage, contains('2 条'));
      expect(errs.single.resolvedAt, isNull);
    });

    test('purge 后 push 不再有该账本的待推行(不再触发推送循环)', () async {
      await seedWithChanges('tx-orphan2', 1);
      engine.startListeningRealtime();
      provider.emitRealtimeEvent(SmartBookCloudRealtimeEvent(
        type: 'member_change',
        ledgerId: 'L1',
        rawData: const {'changeType': 'removed', 'userId': 'test-user-id'},
      ));
      await Future.delayed(const Duration(milliseconds: 300));
      engine.stopListeningRealtime();

      final pushed = await engine.push(ledgerId.toString());
      expect(pushed, 0);
      expect(provider.pushedBatches, isEmpty,
          reason: '无待推 change → 不发 POST(旧行为:delete change 被'
              '反复重推吃 ledger_deleted 拒绝)');
    });
  });
}
