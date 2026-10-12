// ChangeTracker 对抗性测试。
//
// 攻击目标:`recordPulledFromServer` 幂等性 / 不覆盖待推变更、
// `cleanupPushedChanges` 边界、`markPushed` 边界、unpushed 计数语义。
//
// 契约来源:`lib/cloud/sync/change_tracker.dart`
//
// 既有 `test/cloud/sync/change_tracker_test.dart` 只覆盖 scope 契约
// (recordUserGlobalChange / recordLedgerChange),本文件专打边界与幂等。

import 'package:drift/drift.dart' as d;
import 'package:flutter_test/flutter_test.dart';

import 'package:smartbook/cloud/sync/change_tracker.dart';
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
  group('recordPulledFromServer 幂等', () {
    test('同实体两次调用只插一行(幂等)', () async {
      await h.changeTracker.recordPulledFromServer(
        entityType: 'account',
        entityId: 1,
        entitySyncId: 'acc-1',
        ledgerId: 0,
      );
      await h.changeTracker.recordPulledFromServer(
        entityType: 'account',
        entityId: 1,
        entitySyncId: 'acc-1',
        ledgerId: 0,
      );

      final rows = await h.db.select(h.db.localChanges).get();
      expect(rows, hasLength(1),
          reason: '幂等:同 (entityType, entitySyncId) 只留一行,防 server 2x 膨胀');
      expect(rows.single.pushedAt, isNotNull, reason: 'marker 行必须已 pushed');
    });

    test('HARDENING: recordPulledFromServer 对同 syncId 的**新 entityId** 也视为已存在(静默 no-op)',
        () async {
      // 语义:该检查只按 (entityType, entitySyncId) 判定"已知"。若本地
      // 因某种原因换了一个 int id 指向同一 syncId(重建行),marker 不会更新,
      // 但这只影响诊断信息(ledgerId/entityId 列),不影响"不重推"的目标。
      await h.changeTracker.recordPulledFromServer(
        entityType: 'account',
        entityId: 1,
        entitySyncId: 'acc-1',
        ledgerId: 0,
      );
      await h.changeTracker.recordPulledFromServer(
        entityType: 'account',
        entityId: 999,
        entitySyncId: 'acc-1',
        ledgerId: 0,
      );
      final rows = await h.db.select(h.db.localChanges).get();
      expect(rows, hasLength(1));
      expect(rows.single.entityId, 1,
          reason: 'HARDENING: 首行 entityId 保持,marker 不追更新 int id');
    });

    test('ADVERSE-CANDIDATE: 已存在 unpushed 行时 recordPulledFromServer 保留原行(不覆盖为已推)',
        () async {
      // 关键攻击:用户本地有未推的 account 变更,此时 pull 拉到同 syncId 的
      // server 版本 → 若 marker 把该行改成 pushed,用户的待推变更会被静默丢弃。
      await h.recordUserGlobalChange(
        entityType: 'account',
        entityId: 1,
        entitySyncId: 'acc-race',
        action: 'update',
      );
      final before = await h.unpushedGlobal();
      expect(before, hasLength(1));
      final originalChangeId = before.single.id;

      await h.changeTracker.recordPulledFromServer(
        entityType: 'account',
        entityId: 1,
        entitySyncId: 'acc-race',
        ledgerId: 0,
      );

      final after = await h.unpushedGlobal();
      expect(after, hasLength(1),
          reason: '原 unpushed 必须仍在(前缀早 return 保住它)');
      expect(after.single.id, originalChangeId,
          reason: '同一行,不是新插的 marker');
      expect(after.single.pushedAt, isNull,
          reason: 'unpushed 行绝不能被 marker 改成已推 —— 否则本地编辑静默丢失');
      expect(await h.db.select(h.db.localChanges).get(), hasLength(1),
          reason: '也不该多插一行');
    });

    test('pulled marker 不计入 unpushed 计数', () async {
      await h.changeTracker.recordPulledFromServer(
        entityType: 'category',
        entityId: 1,
        entitySyncId: 'cat-1',
        ledgerId: 0,
      );
      expect(await h.changeTracker.getUnpushedCount(), 0);
      expect(await h.changeTracker.getUnpushedCountForLedger(0), 0);
    });

    test('pulled marker 不会被 getUnpushedChanges() 捞到', () async {
      await h.changeTracker.recordPulledFromServer(
        entityType: 'tag',
        entityId: 1,
        entitySyncId: 'tag-1',
        ledgerId: 0,
      );
      expect(await h.changeTracker.getUnpushedChanges(), isEmpty);
    });

    test('不同 entityType 同 syncId 是两个实体,各插一行', () async {
      await h.changeTracker.recordPulledFromServer(
        entityType: 'account',
        entityId: 1,
        entitySyncId: 'same-id',
        ledgerId: 0,
      );
      await h.changeTracker.recordPulledFromServer(
        entityType: 'category',
        entityId: 2,
        entitySyncId: 'same-id',
        ledgerId: 0,
      );
      expect(await h.db.select(h.db.localChanges).get(), hasLength(2));
    });

    test('HARDENING: marker 行 action 固定 upsert,与实体真实状态无关', () async {
      // recordPulledFromServer 内部硬编码 action:'upsert'。若调用方拿它给
      // 一个"已删除"实体打 marker,行上仍写 upsert。当前所有调用点在
      // upsert 分支之后,所以不构成缺陷;记下来防未来误用。
      await h.changeTracker.recordPulledFromServer(
        entityType: 'account',
        entityId: 1,
        entitySyncId: 'acc-del',
        ledgerId: 0,
      );
      final row = (await h.db.select(h.db.localChanges).get()).single;
      expect(row.action, 'upsert');
    });
  });

  // ==================================================================
  group('cleanupPushedChanges 边界', () {
    test('HARDENING: pushed_at 是秒级存储(Unix 秒),retention 比较精度=1 秒',
        () async {
      // drift 默认把 DateTime 存成 Unix **秒**(int),毫秒/微秒全部截断。
      // 因此 `pushedAt.isSmallerThanValue(cutoff)` 实际是「秒 < 秒」:
      // 同一秒内写入的 pushed 行与 cutoff 相等 → 不会被删。
      // 这不是丢数据(下个 cleanup 周期会补删),但意味着
      // "恰好 retention 边界" 在亚秒层面不可分辨 —— 边界由秒决定。
      final id = await h.recordAndMark(syncId: 'tx-subsec');
      final withMicros = DateTime.now().subtract(
        const Duration(days: 7, milliseconds: 500),
      );
      await h.setPushedAt(id, withMicros);
      final raw = await h.db
          .customSelect('SELECT pushed_at FROM local_changes WHERE id = $id')
          .getSingle();
      expect(raw.data['pushed_at'], isA<int>(),
          reason: 'HARDENING: 底层存 Unix 秒 int,毫秒精度丢失');
    });

    test('早于 retention 一个整秒的行必被清', () async {
      final id = await h.recordAndMark(syncId: 'tx-over-7d');
      await h.setPushedAt(
          id, DateTime.now().subtract(const Duration(days: 7, seconds: 5)));

      final removed = await h.changeTracker.cleanupPushedChanges();
      expect(removed, 1, reason: '超过 7 天(带 5s 余量)的已推行必删');
      expect(await h.db.select(h.db.localChanges).get(), isEmpty);
    });

    test('late 于 retention 的行不被清', () async {
      final id = await h.recordAndMark(syncId: 'tx-under-7d');
      await h.setPushedAt(
          id, DateTime.now().subtract(const Duration(days: 6, hours: 23)));

      final removed = await h.changeTracker.cleanupPushedChanges();
      expect(removed, 0, reason: '未满 7 天的已推行保留');
      expect(await h.db.select(h.db.localChanges).get(), hasLength(1));
    });

    test('刚好落在 retention 边界(同秒)→ 本轮不删,下一轮(多 1s)删', () async {
      // 秒级精度的直接后果:边界行留到下一次 cleanup。这里显式断言该行为,
      // 避免未来有人把 `isSmallerThanValue` 改成 `isSmallerOrEqualValue`
      // 而无测试发现。
      final id = await h.recordAndMark(syncId: 'tx-on-edge');
      final edge = DateTime.now().subtract(const Duration(days: 7));
      await h.setPushedAt(id, edge);
      final sameSec = await h.db
          .customSelect('SELECT pushed_at FROM local_changes WHERE id = $id')
          .getSingle();
      final storedSec = sameSec.data['pushed_at'] as int;

      // 用与存储值完全相同的时刻作 cutoff 基准:cutoff == pushedAt → 不删
      final baseRetentionMs =
          DateTime.now().millisecondsSinceEpoch - storedSec * 1000;
      final removed = await h.changeTracker.cleanupPushedChanges(
        retention: Duration(milliseconds: baseRetentionMs),
      );
      expect(removed, 0, reason: 'cutoff 与 pushedAt 同秒相等 → isSmaller 为假');

      // 再往前推(retention 缩短 1 秒 → cutoff 晚 1 秒)→ 删
      final removed2 = await h.changeTracker.cleanupPushedChanges(
        retention: Duration(milliseconds: baseRetentionMs - 1000),
      );
      expect(removed2, 1, reason: 'cutoff 比 pushedAt 晚 1 秒 → 删');
    });

    test('刚刚 markPushed 的行永不被默认 retention 清掉', () async {
      await h.recordAndMark(syncId: 'tx-just-pushed');
      final removed = await h.changeTracker.cleanupPushedChanges();
      expect(removed, 0, reason: '刚推的必须还在');
      expect(await h.db.select(h.db.localChanges).get(), hasLength(1));
    });

    test('未推推行永不被清理(retention 极短也一样)', () async {
      await h.recordChange(
        entityType: 'transaction',
        entityId: 1,
        entitySyncId: 'tx-unpushed',
      );
      // retention=Duration.zero → cutoff=now;未推行的 pushedAt IS NULL,
      // 不满足 isNotNull 前置条件,与 retention 无关。
      final removed = await h.changeTracker.cleanupPushedChanges(
        retention: Duration.zero,
      );
      expect(removed, 0);
      expect(await h.unpushedForLedger(), hasLength(1),
          reason: '未推行与 retention 无关,永不清');
    });

    test('retention=Duration.zero 清掉所有已推旧行', () async {
      final a = await h.recordAndMark(syncId: 'tx-p1');
      final b = await h.recordAndMark(syncId: 'tx-p2');
      await h.setPushedAt(
          a, DateTime.now().subtract(const Duration(seconds: 5)));
      await h.setPushedAt(
          b, DateTime.now().subtract(const Duration(seconds: 5)));

      final removed = await h.changeTracker.cleanupPushedChanges(
        retention: Duration.zero,
      );
      expect(removed, 2);
      expect(await h.db.select(h.db.localChanges).get(), isEmpty);
    });

    test('retention 为负 → cutoff 在未来,清掉全部已推行', () async {
      final id = await h.recordAndMark(syncId: 'tx-neg');
      // 秒级精度:确保 pushedAt 落在过去(至少 1 秒),才能 < 未来 cutoff
      await h.setPushedAt(
          id, DateTime.now().subtract(const Duration(seconds: 2)));
      final removed = await h.changeTracker.cleanupPushedChanges(
        retention: const Duration(days: -1),
      );
      expect(removed, 1,
          reason: 'cutoff = now + 1d,已推行都 < cutoff → 全删');
      // 未推行不受影响
      await h.recordChange(
        entityType: 'transaction',
        entityId: 2,
        entitySyncId: 'tx-keep',
      );
      expect(
          await h.changeTracker.cleanupPushedChanges(
            retention: const Duration(days: -1),
          ),
          0,
          reason: '未推行的 pushedAt IS NULL 不满足 isNotNull,永不清');
      expect(await h.unpushedForLedger(), hasLength(1));
    });

    test('混合:老的已推 + 新的已推 + 未推 → 只删老的已推', () async {
      final oldId = await h.recordAndMark(syncId: 'tx-old');
      await h.setPushedAt(
          oldId, DateTime.now().subtract(const Duration(days: 30)));
      await h.recordAndMark(syncId: 'tx-new');
      await h.recordChange(
        entityType: 'transaction',
        entityId: 9,
        entitySyncId: 'tx-pending',
      );

      final removed = await h.changeTracker.cleanupPushedChanges();
      expect(removed, 1);
      final rows = await h.db.select(h.db.localChanges).get();
      expect(rows.map((r) => r.entitySyncId).toSet(),
          {'tx-new', 'tx-pending'});
    });

    test('user-global 与 ledger-scope 的已推旧行一起被清', () async {
      final g = await h.recordUserGlobalAndMark(syncId: 'acc-old');
      await h.setPushedAt(
          g, DateTime.now().subtract(const Duration(days: 10)));
      final l = await h.recordAndMark(syncId: 'tx-old2');
      await h.setPushedAt(l, DateTime.now().subtract(const Duration(days: 10)));

      expect(await h.changeTracker.cleanupPushedChanges(), 2);
      expect(await h.db.select(h.db.localChanges).get(), isEmpty);
    });

    test('HARDENING: cleanupPushedChanges 无任何调用点(仅测试可达)', () async {
      // 全仓 grep 只有本方法和测试引用它 —— 说明线上没有任何路径会触发
      // 清理,local_changes 表会随使用无限增长(每设备每账本每条 tx 至少
      // 一行 marker/change)。这是数据体积问题而非正确性缺陷,记为观察项。
      expect(
        await h.changeTracker.cleanupPushedChanges(),
        0,
        reason: '空表调用返回 0;方法本身安全,只是没人调',
      );
    });
  });

  // ==================================================================
  group('markPushed 边界', () {
    test('空数组是 no-op,不报错也不改任何行', () async {
      await h.recordChange(
        entityType: 'transaction',
        entityId: 1,
        entitySyncId: 'tx-a',
      );
      await h.changeTracker.markPushed(const []);
      expect(await h.unpushedForLedger(), hasLength(1),
          reason: 'markPushed([]) 必须完全不动作 —— 否则会把所有行清空');
    });

    test('不存在的 id 静默(不抛错),存在的照常标记', () async {
      await h.recordChange(
        entityType: 'transaction',
        entityId: 1,
        entitySyncId: 'tx-real',
      );
      final realId = (await h.unpushedForLedger()).single.id;
      await h.changeTracker.markPushed([realId, 999999, -1]);
      expect(await h.unpushedForLedger(), isEmpty);
    });

    test('重复调用幂等(二次 markPushed 只刷新时间戳)', () async {
      await h.recordAndMark(syncId: 'tx-dup');
      final first = (await h.db.select(h.db.localChanges).get()).single.pushedAt;
      await h.changeTracker.markPushed(
          [(await h.db.select(h.db.localChanges).get()).single.id]);
      final second = (await h.db.select(h.db.localChanges).get()).single.pushedAt;
      expect(second!.isAfter(first!) || second.isAtSameMomentAs(first!), isTrue);
      expect(await h.unpushedForLedger(), isEmpty);
    });

    test('GET unpushed 计数与实际行数一致(COUNT 快修口径)', () async {
      for (var i = 0; i < 5; i++) {
        await h.recordChange(
          entityType: 'transaction',
          entityId: i,
          entitySyncId: 'tx-$i',
        );
      }
      final list = await h.unpushedForLedger();
      expect(await h.changeTracker.getUnpushedCountForLedger(ledgerId),
          list.length);
      expect(await h.changeTracker.getUnpushedCount(), list.length);
    });

    test('只标记指定 ledger 的行,不影响其它 ledger', () async {
      final otherLedger = await h.db.into(h.db.ledgers).insert(
          LedgersCompanion.insert(name: 'L2', syncId: const d.Value('L2')));
      await h.recordChange(
        entityType: 'transaction',
        entityId: 1,
        entitySyncId: 'tx-l1',
      );
      await h.recordChange(
        entityType: 'transaction',
        entityId: 2,
        entitySyncId: 'tx-l2',
        inLedgerId: otherLedger,
      );
      final l1 = await h.unpushedForLedger(ledgerId);
      await h.changeTracker.markPushed([l1.single.id]);

      expect(await h.unpushedForLedger(ledgerId), isEmpty);
      expect(await h.unpushedForLedger(otherLedger), hasLength(1),
          reason: 'markPushed 按 id 精确,不误伤其它账本');
    });
  });

  // ==================================================================
  group('scope 契约边界', () {
    test('ledgerId=0 的 ledger-scope 行(误用)会混进 user-global 通道被带出',
        () async {
      // recordLedgerChange 有 assert ledgerId > 0,但 release 模式 assert 被
      // 剥掉。这里直接走低层表插入模拟 release 模式下的误用后果。
      await h.db.into(h.db.localChanges).insert(LocalChangesCompanion.insert(
            entityType: 'transaction',
            entityId: 1,
            entitySyncId: 'tx-orphan-zero',
            ledgerId: 0,
            action: 'create',
          ));
      // 它出现在 user-global 查询里(会被 pushUserGlobalEntities 当 user-global
      // 发出去,ledger_id 发 null)
      final global = await h.unpushedGlobal();
      expect(global, hasLength(1),
          reason: 'ledgerId=0 的行走 user-global 查询 —— 契约破坏的可见后果');
      expect(global.single.entityType, 'transaction');
      // 且不会出现在任何具体账本查询里
      expect(await h.unpushedForLedger(ledgerId), isEmpty);
    });

    test('user-global 白名单含 exchange_rate_override', () async {
      await h.recordUserGlobalChange(
        entityType: 'exchange_rate_override',
        entityId: 1,
        entitySyncId: 'ero-1',
      );
      expect(await h.unpushedGlobal(), hasLength(1));
    });

    test('多账本:同一 user-global change 对每个账本查询都可见(设计如此)', () async {
      final otherLedger = await h.db.into(h.db.ledgers).insert(
          LedgersCompanion.insert(name: 'L2', syncId: const d.Value('L2')));
      await h.recordUserGlobalChange(
        entityType: 'account',
        entityId: 1,
        entitySyncId: 'acc-shared',
      );
      expect(await h.unpushedGlobal(), hasLength(1));
      expect(await h.unpushedForLedger(ledgerId), isEmpty,
          reason: 'user-global 不挂具体账本');
      expect(await h.unpushedForLedger(otherLedger), isEmpty);
    });
  });
}
