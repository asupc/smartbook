// Pull / apply 对抗性测试。
//
// 攻击目标:
//   - 游标回退 / hasMore 恒真死循环 / 游标错乱
//   - 畸形远端 payload:6 种 entityType 各喂缺字段/类型错(apply 崩溃面)
//   - 同一实体批内出现两次(LWW 胜出者)
//   - pull 后 recordPulledFromServer 的调用面(登记缺口 → server 2x 膨胀)
//   - 未知 entityType / 未知 action:跳过且不崩、不阻塞后续条目
//   - ledger monthStartDay 越界、category 自引用父子、tag 空名
//
// 源码:`lib/cloud/sync/sync_engine.dart`(_doPull / _runPullLoop /
// _applyPullPage)、`lib/cloud/sync/sync_engine_apply.dart`、
// `lib/cloud/sync/sync_engine_resolvers.dart`。

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:smartbook/cloud/sync/entity_serializer.dart';
import 'package:smartbook/data/db.dart';

import '_fakes/adversarial_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SyncHarness h;

  setUp(() async {
    h = await SyncHarness.create(ledgerSyncId: 'L1');
  });

  tearDown(() async {
    await h.close();
  });

  // ==================================================================
  group('pull 游标', () {
    test('空页不推进 cursor', () async {
      h.provider.pullResponder = (c, since, limit) => page([], cursor: 0);
      await h.engine.pull('');
      expect(await h.engine.appCursor.read(), 0,
          reason: '无变更 → cursor 留在原地');
    });

    test('正常单页:apply 成功后 cursor 推进到 serverCursor', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
                changeId: 7,
                entitySyncId: 'tx-1',
                ledgerId: 'L1',
                payload:
                    {'syncId': 'tx-1', 'type': 'expense', 'amount': 1.0}),
          ], cursor: 7);

      await h.engine.pull('${h.ledgerId}');
      expect(await h.engine.appCursor.read(), 7);
    });

    test('ADVERSE FINDING: 服务端 serverCursor 回退到本地 cursor 之前 → cursor 被写回退',
        () async {
      // ADVERSE FINDING(中):`_runPullLoop` 无条件 `await appCursor.commit(
      // result.serverCursor)`(sync_engine.dart:1425),不校验
      // `result.serverCursor >= nextSince`。
      //
      // server 端 pull.py:104 `server_cursor = since` 起,取 `max(since,
      // 本页最大 change_id)` —— 正常恒 ≥ since。但一旦 server 端出现
      // 逻辑错误 / 代理缓存 / 分页竞态返回了更小的 cursor,客户端会把
      // 已推进的 cursor **写回退**,导致下次 pull 重放已 apply 的历史
      // (幂等 upsert,不至于丢数据,但每次都白拉 + 所有历史 change 重新
      // 走一遍 apply;更糟的是 pullErrors 里已 markResolved 的错误会被
      // 重新拉起)。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
                changeId: 5,
                entitySyncId: 'tx-1',
                ledgerId: 'L1',
                payload:
                    {'syncId': 'tx-1', 'type': 'expense', 'amount': 1.0}),
          ], cursor: 5);
      await h.engine.pull('${h.ledgerId}');
      expect(await h.engine.appCursor.read(), 5, reason: '前置:cursor=5');
      expect(h.provider.pullCallCount, 1);

      // server 开始返回更小的 cursor(回退)
      var call = 0;
      h.provider.pullResponder = (c, since, limit) {
        call++;
        return page([
          remoteChange(
              changeId: 2,
              entitySyncId: 'tx-2',
              ledgerId: 'L1',
              payload: {'syncId': 'tx-2', 'type': 'expense', 'amount': 2.0}),
        ], cursor: 2);
      };
      await h.engine.pull('${h.ledgerId}');

      expect(await h.engine.appCursor.read(), 5,
          reason: 'ADVERSE FINDING: 期望 cursor 至少单调不降(取 max);'
              '当前实现直接 commit(2) → cursor 从 5 回退到 2');
      expect(call, greaterThan(0));
    });

    test('ADVERSE FINDING: serverCursor 为负数 → 原样 commit,下一轮 since 为负(全量重放)',
        () async {
      // ADVERSE FINDING(低):`appCursor.commit` 与 `_runPullLoop` 都不校验
      // `serverCursor >= 0`(sync_engine_pull.dart:38-43 / sync_engine.dart:1424)。
      // 负 cursor 一旦落库,下一轮 pull 带 `since=-3` 出去;真实 server 的
      // `change_id > since` 对负数恒成立 → 整段历史全量重放(幂等 upsert 不丢
      // 数据,但每次 sync 都白拉全部历史 + pullErrors 被重新 markResolved)。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
                changeId: 5,
                entitySyncId: 'tx-1',
                ledgerId: 'L1',
                payload:
                    {'syncId': 'tx-1', 'type': 'expense', 'amount': 1.0}),
          ], cursor: 5);
      await h.engine.pull('${h.ledgerId}');
      expect(await h.engine.appCursor.read(), 5, reason: '前置:cursor=5');

      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
                changeId: 6,
                entitySyncId: 'tx-2',
                ledgerId: 'L1',
                payload:
                    {'syncId': 'tx-2', 'type': 'expense', 'amount': 2.0}),
          ], cursor: -3); // 服务端/代理返回负 cursor
      await h.engine.pull('${h.ledgerId}');

      expect(await h.engine.appCursor.read(), greaterThanOrEqualTo(0),
          reason: 'ADVERSE FINDING: 期望 cursor 至少非负(拒绝异常值);'
              '当前实现原样 commit(-3) → 游标跌到负数');
      // 机制证据:下一次 pull 请求真的带 since=-3 出去(真实 server = 全量重放)
      h.provider.pullResponder = (c, since, limit) => page([], cursor: since ?? 0);
      await h.engine.pull('${h.ledgerId}');
      expect(h.provider.scriptedPullCalls.last.since, greaterThanOrEqualTo(0),
          reason: 'ADVERSE FINDING: 下一轮 since 应 >= 0;实际 since=-3 会命中 '
              'server 端 change_id > since 的全部历史');
    });

    test('ADVERSE FINDING: serverCursor 极大 → 照单全收,之后真实变更永远拉不到(同步静默死亡)',
        () async {
      // ADVERSE FINDING(中):`appCursor.commit` 对 serverCursor 无上限/合理性
      // 校验。一次异常响应(server bug / 代理串响应 / 中间人)返回
      // 2^63-1 后:
      //   1) 本地游标被写到 9223372036854775807;
      //   2) 之后每轮 pull 都带 since=9223372036854775807,真实 server
      //      (pull.py:104 `server_cursor = since` + `change_id > since`)恒返空;
      //   3) 探针见空页 → return 0,**无报错、无告警、无 unpushed 提示**,
      //      同步静默死亡,只能清 App 数据(SharedPreferences)自救。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
                changeId: 1,
                entitySyncId: 'tx-jump',
                ledgerId: 'L1',
                payload:
                    {'syncId': 'tx-jump', 'type': 'expense', 'amount': 1.0}),
          ], cursor: 9223372036854775807); // 2^63-1
      await h.engine.pull('${h.ledgerId}');
      const absurd = 9223372036854775807;
      expect(await h.engine.appCursor.read(), absurd,
          reason: '前置/机制:极大 cursor 被原样 commit(无上限校验)');

      // 服务端恢复正常:严格按 since 过滤(与真实 pull.py 一致)
      h.provider.pullResponder = (c, since, limit) {
        if ((since ?? 0) >= absurd) {
          return page([], cursor: since ?? 0); // change_id > since 恒空
        }
        return page([
          remoteChange(
              changeId: 2,
              entitySyncId: 'tx-real',
              ledgerId: 'L1',
              payload: {'syncId': 'tx-real', 'type': 'expense', 'amount': 2.0}),
        ], cursor: 2);
      };
      final applied = await h.engine.pull('${h.ledgerId}');

      expect(applied, 1,
          reason: 'ADVERSE FINDING: 期望客户端拒绝异常 cursor(或至少可自愈);'
              '实际 since=2^63-1 → 服务端恒返空 → 服务端已有的 change_id=2 '
              '永远拉不到,同步静默死亡(无报错、无任何 UI 提示)');
      expect(await h.engine.appCursor.read(), 2,
          reason: 'ADVERSE FINDING: 游标应能被正常页拉回');
    });

    test('ADVERSE FINDING: hasMore 恒真 + 游标不前进 → pull 无限循环(永不返回)',
        () async {
      // ADVERSE FINDING(高):`_runPullLoop` 的 while 条件只看 `result.hasMore`
      // (sync_engine.dart:1385),**没有迭代上限**,也不检测"游标没有前进"。
      // 服务端若因 bug / 代理缓存 / 分页参数被忽略而持续返回
      // `has_more=true` 且 `server_cursor` 不前进,客户端会永远循环:
      // 每轮重复 apply 同一批 change + commit 同一 cursor + 打日志。
      //
      // 后果:同步按钮永久转圈、main isolate 持续占用、Service 层日志暴涨;
      // 且因为 cursor 不前进,同一批 change 被**反复 apply**。
      //
      // 本测试用"外部 bail-out"作为有界代理:让 responder 在第 41 次调用时
      // 抛错,从而让 pull 有界地结束。断言"在第 41 次之前 engine 自己从未
      // 停止"= 证明没有自带上限。
      var calls = 0;
      h.provider.pullResponder = (c, since, limit) {
        calls++;
        if (calls > 40) throw StateError('driver-bail-out');
        return page([
          remoteChange(
              changeId: 1,
              entitySyncId: 'tx-loop',
              ledgerId: 'L1',
              payload: {'syncId': 'tx-loop', 'type': 'expense', 'amount': 1.0}),
        ], cursor: 0, hasMore: true); // cursor 不前进 + hasMore 恒真
      };

      Object? err;
      try {
        await h.engine.pull('${h.ledgerId}');
      } catch (e) {
        err = e;
      }

      expect(calls, greaterThanOrEqualTo(41),
          reason: 'ADVERSE FINDING: 证明 engine 无自带上限 —— 只有外部抛错才能终止;'
              '真实环境(server 持续 hasMore=true)下就是无限循环');
      expect(err, isA<StateError>(),
          reason: '结束原因是测试驱动的 bail-out,不是 engine 自己收敛');
      // 副作用:同一 change 被反复 apply(cursor 不前进 → 每次都重来)
      expect(h.provider.pullCallCount, greaterThanOrEqualTo(41),
          reason: 'ADVERSE FINDING: 40+ 轮重复 HTTP + 重复 apply');
    });

    test('hasMore=false 时正常退出(单页 + 后续页两轮)', () async {
      var call = 0;
      h.provider.pullResponder = (c, since, limit) {
        call++;
        if (call == 1) {
          return page([
            remoteChange(
                changeId: 1,
                entitySyncId: 'tx-a',
                ledgerId: 'L1',
                payload:
                    {'syncId': 'tx-a', 'type': 'expense', 'amount': 1.0}),
          ], cursor: 1, hasMore: true);
        }
        return page([
          remoteChange(
              changeId: 2,
              entitySyncId: 'tx-b',
              ledgerId: 'L1',
              payload: {'syncId': 'tx-b', 'type': 'expense', 'amount': 2.0}),
        ], cursor: 2);
      };

      final applied = await h.engine.pull('${h.ledgerId}');
      expect(applied, 2);
      expect(await h.engine.appCursor.read(), 2);
      expect(call, 2, reason: '第 1 轮复用处探针结果,第 2 轮发 HTTP');
    });

    test('sinceOverride=0 从头重放,但仍从 cursor 递进(不越界)', () async {
      h.provider.pullResponder = (c, since, limit) {
        expect(since, 0, reason: 'replay 必须从 0 开始');
        return page([
          remoteChange(
              changeId: 3,
              entitySyncId: 'tx-r',
              ledgerId: 'L1',
              payload: {'syncId': 'tx-r', 'type': 'expense', 'amount': 3.0}),
        ], cursor: 3);
      };
      final n = await h.engine.pull('', sinceOverride: 0);
      expect(n, 1);
      expect(await h.engine.appCursor.read(), 3);
    });

    test('跨设备账本 id 不匹配:change.ledgerId 用 server external_id 解析', () async {
      // 本地 id=1,syncId='L1';远端 change 的 ledgerId 是 'L1'
      final before = await h.db.select(h.db.transactions).get();
      expect(before, isEmpty);
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
                changeId: 1,
                entitySyncId: 'tx-m',
                ledgerId: 'L1',
                payload:
                    {'syncId': 'tx-m', 'type': 'expense', 'amount': 1.0}),
          ], cursor: 1);
      await h.engine.pull('${h.ledgerId}');
      final tx = (await h.db.select(h.db.transactions).get()).single;
      expect(tx.ledgerId, h.ledgerId, reason: '通过 syncId 正确映射到本地 int id');
    });

    test('change.ledgerId 无法解析 → 按 payload.ledgerSyncId 回填(不落 -1 孤儿行)',
        () async {
      // 修复后(2026-10-11 C4,审核记录阻塞-4):`_applyTransactionChange` 不再
      // 用 `?? -1` 兜底。解析顺序:change.ledgerId(syncId 映射)→
      // payload.ledgerSyncId(serializer 明确带来的稳定引用)→ int.tryParse;
      // 全都解析不出 → 登记 deferred(本页 cursor 不推进),留待 ledger change
      // 到达后重放。
      //
      // 旧行为(ADVERSE FINDING,已修):落 ledger_id=-1 的孤儿行 —— 不属于
      // 任何账本、任何列表/统计都查不到、用户看不见也删不掉,且**永久占用
      // syncId**(同 syncId 的后续 change 只会 update 这一行,永远挂不回正确
      // 账本)。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-orphan',
              ledgerId: 'unknown-external-id',
              payload: {
                'syncId': 'tx-orphan',
                'type': 'expense',
                'amount': 9.0,
                // payload 带了正确的账本引用 → 按它回填本地 int id
                'ledgerSyncId': 'L1',
              },
            ),
          ], cursor: 1);

      await h.engine.pull('${h.ledgerId}');

      final txs = await h.db.select(h.db.transactions).get();
      expect(txs, hasLength(1));
      expect(txs.single.ledgerId, h.ledgerId,
          reason: '期望按 payload.ledgerSyncId 回填到真实本地账本;'
              '绝不落 -1 孤儿行(不属于任何账本,永久占用 syncId)');
      // 现在它"看得见",用户能正常查看/编辑/删除
      final visible = await (h.db.select(h.db.transactions)
            ..where((t) => t.ledgerId.equals(h.ledgerId)))
          .get();
      expect(visible, hasLength(1), reason: '交易落在正确账本内,列表可见可删');

      // 机制补充:change.ledgerId 与 payload.ledgerSyncId 都解析不出时,
      // 不落孤儿行,而是推迟整页(cursor 不推进)等 ledger 同步下来后重放。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 2,
              entitySyncId: 'tx-orphan2',
              ledgerId: 'still-unknown',
              payload: {
                'syncId': 'tx-orphan2',
                'type': 'expense',
                'amount': 1.0,
              },
            ),
          ], cursor: 2);
      await h.engine.pull('${h.ledgerId}');
      expect(await h.db.select(h.db.transactions).get(), hasLength(1),
          reason: '解析不出的交易不得落库(更不落 -1 孤儿行)');
      expect(await h.engine.appCursor.read(), 1,
          reason: '本页推迟 → cursor 停在 1,待 ledger 就绪后重放');
    });

    test('HARDENING: 本设备自己推的 change 被 apply 跳过(deviceId 匹配)', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-self',
              ledgerId: 'L1',
              updatedByDeviceId: h.provider.deviceId!,
              payload:
                  {'syncId': 'tx-self', 'type': 'expense', 'amount': 1.0},
            ),
          ], cursor: 1);

      final applied = await h.engine.pull('${h.ledgerId}');
      expect(applied, 0, reason: '自己推的 change 跳过(server 也会过滤,这是双保险)');
      expect(await h.db.select(h.db.transactions).get(), isEmpty);
    });

    test('HARDENING: updatedByDeviceId 为 null 的 change 不被跳过', () async {
      // server pull.py 显式放行 NULL 行(三值逻辑),客户端也必须放行 ——
      // 这里验证 _getDeviceId 拿到 'test-device-id' 时 null 不匹配任何值。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-null-dev',
              ledgerId: 'L1',
              updatedByDeviceId: null,
              payload: {
                'syncId': 'tx-null-dev',
                'type': 'expense',
                'amount': 1.0,
              },
            ),
          ], cursor: 1);
      final applied = await h.engine.pull('${h.ledgerId}');
      expect(applied, 1, reason: 'legacy change 无 device 字段 → 必须 apply');
    });
  });

  // ==================================================================
  group('畸形 payload:6 种 entityType', () {
    test('transaction 类型错(type=int)→ 整页 rollback + 错误入表 + cursor 不动',
        () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-bad',
              ledgerId: 'L1',
              payload: {'syncId': 'tx-bad', 'type': 123, 'amount': 5.0},
            ),
          ], cursor: 1);

      final applied = await h.engine.pull('${h.ledgerId}');

      expect(applied, 0);
      expect(await h.db.select(h.db.transactions).get(), isEmpty,
          reason: '整页事务 rollback:坏条目不落库');
      final errs = await h.db.select(h.db.syncPullErrors).get();
      expect(errs, hasLength(1), reason: '失败 change 被持久化供 UI 展示');
      expect(errs.single.changeId, 1);
      expect(errs.single.entityType, 'transaction');
      expect(await h.engine.appCursor.read(), 0,
          reason: 'cursor 不推进 → 下次 pull 会重试这条(server 修好后自然通过)');
    });

    test('transaction 缺 amount → 落 0.0(不崩,静默错值)', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-noamt',
              ledgerId: 'L1',
              payload: {'syncId': 'tx-noamt', 'type': 'expense'},
            ),
          ], cursor: 1);
      final applied = await h.engine.pull('${h.ledgerId}');
      expect(applied, 1);
      final tx = (await h.db.select(h.db.transactions).get()).single;
      expect(tx.amount, 0.0,
          reason: 'HARDENING: 缺 amount 默认 0.0 —— 一条金额 0 的交易会静默出现'
              '在账本里,用户看到"¥0"记录(比抛错更难发现)');
      expect(tx.happenedAt, isNotNull, reason: '缺 happenedAt → 兜底 now');
    });

    test('HARDENING: transaction amount 为字符串 → 类型转换抛错 → 整页 rollback(不静默归零)',
        () async {
      // `payload['amount'] as num?`(sync_engine_apply.dart:104)对 String 输入
      // **抛 TypeError**(不是返 null 走 `?? 0.0`)。所以"类型错"的字段一律
      // 走整页 rollback 路径,不会静默降级成 0。
      // 这比静默归零好(不产生假数据),代价是**一条坏 change 卡住整页 +
      // cursor 不推进**,直到 server 修数据。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-stramt',
              ledgerId: 'L1',
              payload:
                  {'syncId': 'tx-stramt', 'type': 'expense', 'amount': 'abc'},
            ),
          ], cursor: 1);
      final applied = await h.engine.pull('${h.ledgerId}');
      expect(applied, 0);
      expect(await h.db.select(h.db.transactions).get(), isEmpty);
      final err = (await h.db.select(h.db.syncPullErrors).get()).single;
      expect(err.errorClass, contains('TypeError'));
    });

    test('transaction amount=1e400(JSON→Infinity)不毒化后续 push(U-04 出口守卫)',
        () async {
      // 2026-10-11 追加(缺陷 F,pull-apply 策略):apply 侧**不再**落库非有限
      // 金额 —— 远端坏金额在 `_skipPulledTxIfInvalid` 处被跳过 + 告警
      // (sync_engine_apply.dart;pull 路径刻意**不抛**,抛会中断整页 apply、
      // cursor 卡死)。见本文件下方 group 的"pull-apply 金额守卫"新用例。
      //
      // 原用例的前提"apply 侧仍落库(SQLite REAL 接受 Infinity)"已被上述修复
      // 取代:现由**直插**构造同一条存量脏行(旧版本落库 / 建行历史数据),
      // push 出口守卫的断言面完全保留(毒条不交给 provider、好条照推、
      // 毒条不 markPushed)。
      //
      // push 出口守卫(2026-10-11 C4 / C1 同源):含非有限数值的 payload 在
      // **交给 provider 之前**被跳过 + 告警 + 不 markPushed(保守重推),
      // 其余实体照常推送。
      //
      // 旧行为(ADVERSE FINDING,已修):Infinity 原样交给 provider,
      // 真实 provider 对整批 body 一次 `jsonEncode`
      // (smartbook_cloud_provider.dart:1790/3482)→ JsonUnsupportedObjectError
      // → 该设备**整个推送通道瘫痪**,所有正常变更都推不出去。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-inf',
              ledgerId: 'L1',
              payload: {
                'syncId': 'tx-inf',
                'type': 'expense',
                'amount': 1e400, // JSON 数字字面量 → Infinity
              },
            ),
          ], cursor: 1);

      final applied = await h.engine.pull('${h.ledgerId}');
      // 中-2(2026-10-11 三轮复查):值跳过不再计入 applied —— 行没落库,
      // "处理了 1 条"的旧口径被修正为 applied=0(skipped 语义,见
      // `sync_engine_apply.dart` 的 `_valueSkipRegistered`)。
      expect(applied, 0, reason: '中-2:值跳过的 change 计入 skipped 而非 applied');

      // 修复后:apply 跳过坏行 → 主表里**没有**非有限金额。
      expect(await h.db.select(h.db.transactions).get(), isEmpty,
          reason: '缺陷 F 修复:远端 amount=Infinity 在 apply 入口被跳过,'
              '不再落库污染全部聚合');

      // 直插构造存量脏行(旧版本落库的历史数据)—— 出口守卫的作用面。
      final txId = await h.db.into(h.db.transactions).insert(
            TransactionsCompanion.insert(
              ledgerId: h.ledgerId,
              type: 'expense',
              amount: double.infinity,
              syncId: const Value('tx-inf'),
              happenedAt: Value(DateTime(2026, 1, 1)),
            ),
          );
      final tx = (await h.db.select(h.db.transactions).get()).single;
      expect(tx.id, txId);
      expect(tx.amount.isInfinite, isTrue,
          reason: '前置:存量脏数据确实在库(出口守卫的作用面就在这条)');

      // 这条 tx 后续一旦被登记为待推(用户编辑 / 附件回填 / 迁移),push 就会
      // 在 provider 层 jsonEncode 时炸 —— 除非出口守卫拦下它。
      await h.recordChange(
        entityType: 'transaction',
        entityId: tx.id,
        entitySyncId: 'tx-inf',
        action: 'update',
      );
      // 同批带一条**正常**交易:验证"坏条不连坐好条"(旧行为是整批死)
      final goodId = await h.seedTx(syncId: 'tx-fine', amount: 8.0);
      await h.recordChange(
        entityType: 'transaction',
        entityId: goodId,
        entitySyncId: 'tx-fine',
        action: 'update',
      );

      await h.engine.push('${h.ledgerId}');

      // 毒条没被交给 provider(真实设备上就不会炸整批)
      expect(h.provider.pushedBatches, hasLength(1),
          reason: '只发正常条那一批(毒条在交给 provider 前被跳过)');
      final sent = h.provider.pushedBatches.single;
      expect(sent.map((c) => c['entity_sync_id']), ['tx-fine'],
          reason: '正常交易照常推送 —— 一条远端脏数据不再毒化整个通道');
      // 每一条真正交给 provider 的 payload 都必须可编码
      for (final c in sent) {
        expect(
            () => EntitySerializer.toJsonString(
                c['payload'] as Map<String, dynamic>),
            returnsNormally,
            reason: '交给真实 provider 的每批 body 都能 jsonEncode');
      }
      // 毒条保留本地未推(保守,绝不静默丢)
      final unpushed = await h.unpushedForLedger();
      expect(unpushed.map((c) => c.entitySyncId), contains('tx-inf'),
          reason: '毒条不 markPushed → 保留在 local_changes,等数据修正后重推');
    });

    // ══════════════════════════════════════════════════════════════════
    // pull-apply 金额守卫(缺陷 F/G,2026-10-11)
    //
    // **策略:跳过 + 告警,绝不抛**(抛会中断整页 apply → cursor 不推进 →
    // 本页所有好 change 永远应用不到,同步静默死亡)。cursor 照常推进:
    // change 已在 server 侧,重放不会变好。
    // 见 `sync_engine_apply.dart` 的 `_skipPulledTxIfInvalid` /
    // `_skipPulledMoneyIfInvalid`。
    // ══════════════════════════════════════════════════════════════════

    test('transaction amount=Infinity → 跳过 + 不落库 + 不阻断同页好行',
        () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-inf-bad',
              ledgerId: 'L1',
              payload: {
                'syncId': 'tx-inf-bad',
                'type': 'expense',
                'amount': 1e400, // → Infinity
              },
            ),
            remoteChange(
              changeId: 2,
              entitySyncId: 'tx-good',
              ledgerId: 'L1',
              payload: {
                'syncId': 'tx-good',
                'type': 'expense',
                'amount': 42.0,
              },
            ),
          ], cursor: 2);

      await h.engine.pull('${h.ledgerId}');

      final rows = await h.db.select(h.db.transactions).get();
      expect(rows, hasLength(1),
          reason: '修复:坏行被跳过,好行照常落库(一条坏 change 不连坐)');
      expect(rows.single.syncId, 'tx-good');
      expect(rows.single.amount, 42.0);
      expect(await h.engine.appCursor.read(), 2,
          reason: 'cursor 照常推进(不 defer —— 重放坏 change 不会变好,'
              'defer 会让 cursor 永久卡死)');
    });

    test('transaction nativeAmount=Infinity → 同样跳过(payload 键存在时)',
        () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-nat-bad',
              ledgerId: 'L1',
              payload: {
                'syncId': 'tx-nat-bad',
                'type': 'expense',
                'amount': 10.0,
                'nativeAmount': 1e400, // → Infinity
                'currencyCode': 'USD',
              },
            ),
          ], cursor: 1);
      await h.engine.pull('${h.ledgerId}');
      expect(await h.db.select(h.db.transactions).get(), isEmpty,
          reason: '修复:nativeAmount 非有限同样不落库(折算值会污染全部聚合)');
    });

    test('account initial_balance=Infinity → 跳过(不污染 accountBalance)',
        () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'account',
              entitySyncId: 'acc-inf',
              payload: {
                'syncId': 'acc-inf',
                'name': 'INF',
                'initialBalance': 1e400,
              },
            ),
          ], cursor: 1);
      await h.engine.pull('');
      expect(await h.db.select(h.db.accounts).get(), isEmpty,
          reason: '修复:远端 Infinity 初始余额被跳过(原:落库 + 余额变 Infinity)');
    });

    test('budget amount=Infinity → 跳过', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'budget',
              entitySyncId: 'bud-inf',
              ledgerId: 'L1',
              payload: {
                'syncId': 'bud-inf',
                'ledgerSyncId': 'L1',
                'amount': 1e400,
              },
            ),
          ], cursor: 1);
      await h.engine.pull('${h.ledgerId}');
      expect(await h.db.select(h.db.budgets).get(), isEmpty,
          reason: '修复:远端 Infinity 预算被跳过(原:使用率变 Infinity)');
    });

    test('account_adjustment amount=Infinity → 跳过(三列都拦)', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'account_adjustment',
              entitySyncId: 'adj-inf',
              ledgerId: 'L1',
              payload: {
                'syncId': 'adj-inf',
                'ledgerSyncId': 'L1',
                'accountId': null,
                'amount': 1e400,
              },
            ),
          ], cursor: 1);
      await h.engine.pull('${h.ledgerId}');
      expect(await h.db.select(h.db.accountAdjustments).get(), isEmpty,
          reason: '修复:远端 Infinity 调整被跳过');
    });

    test('exchange_rate_override rate="Infinity" → 跳过(字符串列旁路)',
        () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'exchange_rate_override',
              entitySyncId: 'ero-inf',
              payload: {
                'syncId': 'ero-inf',
                'baseCurrency': 'CNY',
                'quoteCurrency': 'USD',
                'rate': 'Infinity', // invertRate 下溢面产出的字面量
              },
            ),
          ], cursor: 1);
      await h.engine.pull('');
      expect(await h.db.select(h.db.exchangeRateOverrides).get(), isEmpty,
          reason: '修复:字面量 Infinity 汇率被跳过'
              '(消费方 tryParse 后不命中 rate<=0 降级 → 折算出 Infinity)');
    });

    test('pull-apply 守卫不误伤合法负值(退款/调整语义)', () async {
      // adjustment 类型带符号;expense 的负值仍被拒(与本地写路径同口径)。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-adjust',
              ledgerId: 'L1',
              payload: {
                'syncId': 'tx-adjust',
                'type': 'adjustment',
                'amount': -300.0,
              },
            ),
          ], cursor: 1);
      await h.engine.pull('${h.ledgerId}');
      final rows = await h.db.select(h.db.transactions).get();
      expect(rows, hasLength(1), reason: '非方向性类型(adjustment)的负值合法');
      expect(rows.single.amount, -300.0);
    });

    // ══════════════════════════════════════════════════════════════════
    // 缺陷 A(2026-10-11 复现缺陷修复):pull-apply 的值跳过必须可观测。
    //
    // 旧行为:非有限金额只写一行 warning;cursor 照常推进 → 该 change 的
    // change_id 落到 cursor 之后**永久拉不回来**,UI 面(pullErrors)完全看不到
    // (探针实测:页含坏 change 9 + 好 change 10 → 好行落地、cursor=10、
    // pullErrors=0、unresolved=0)。
    //
    // 修复:跳过登记为 `error_class=PulledValueSkipped` 的错误行(强制
    // resolved_at=NULL,且排除出同轮 markResolved),watchUnresolved 查得到;
    // cursor 仍照常推进(否则整页 apply 卡死)。
    // ══════════════════════════════════════════════════════════════════
    test('DEFECT-A: 值跳过持久化为 PulledValueSkipped,watchUnresolved 可见(跨轮存活)',
        () async {
      h.provider.pullResponder = (c, since, limit) {
        if ((since ?? 0) >= 10) return page([], cursor: 10);
        return page([
          remoteChange(
            changeId: 9,
            entitySyncId: 'tx-bad',
            ledgerId: 'L1',
            payload: {
              'syncId': 'tx-bad',
              'type': 'expense',
              'amount': 1e400, // → Infinity
            },
          ),
          remoteChange(
            changeId: 10,
            entitySyncId: 'tx-good',
            ledgerId: 'L1',
            payload: {
              'syncId': 'tx-good',
              'type': 'expense',
              'amount': 42.0,
            },
          ),
        ], cursor: 10);
      };

      await h.engine.pull('${h.ledgerId}');

      // 活性:坏行不落库、好行照常落地、cursor 照常推进。
      final rows = await h.db.select(h.db.transactions).get();
      expect(rows.map((r) => r.syncId), ['tx-good'],
          reason: '坏行被跳过,好行照常落库');
      expect(await h.engine.appCursor.read(), 10,
          reason: 'cursor 必须照常推进(不 defer —— defer 会让整页 apply 卡死)');

      // 可观测:跳过的 change 9 落错误行,且未解决(旧实现 errors=0)。
      final errs = await h.db.select(h.db.syncPullErrors).get();
      expect(errs, hasLength(1),
          reason: 'DEFECT-A: 值跳过必须持久化 —— 否则该远端变更永久静默消失,'
              '只能从 48h 日志里看到一行 warning');
      expect(errs.single.changeId, 9);
      expect(errs.single.entityType, 'transaction');
      expect(errs.single.entitySyncId, 'tx-bad');
      expect(errs.single.errorClass, 'PulledValueSkipped',
          reason: '可机器区分的独立 error_class(区别于普通 apply 失败/放弃重放)');
      expect(errs.single.resolvedAt, isNull,
          reason: '同一轮的 markResolved 不得清掉它(否则落库即死、UI 永远看不到)');
      expect(errs.single.errorMessage, contains('non_finite'),
          reason: '错误文案带 reason,可诊断');

      final unresolved = await h.engine.pullErrors.watchUnresolved().first;
      expect(unresolved.map((e) => e.changeId), [9],
          reason: 'DEFECT-A: UI 查询面必须看得到这条跳过');

      // 跨轮存活:下一轮(cursor 已在 10,不再返回 change 9)不得被清掉。
      await h.engine.pull('${h.ledgerId}');
      expect(await h.engine.pullErrors.watchUnresolved().first, hasLength(1),
          reason: 'DEFECT-A: 后续轮次不得误清(该 change 的 change_id 已在 '
              'cursor 之后,不会再被拉取;错误行是唯一可见面)');
      expect(await h.engine.appCursor.read(), 10);
    });

    test('DEFECT-A: 值跳过自愈 —— 服务端修数据后同 change_id 重放成功 → resolve',
        () async {
      // 第 1 轮:坏值 → 跳过 + 错误行。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 9,
              entitySyncId: 'tx-fix',
              ledgerId: 'L1',
              payload: {
                'syncId': 'tx-fix',
                'type': 'expense',
                'amount': 1e400,
              },
            ),
          ], cursor: 9);
      await h.engine.pull('${h.ledgerId}');
      expect(await h.engine.pullErrors.watchUnresolved().first, hasLength(1),
          reason: '前置:值跳过已可见');

      // 服务端修好数据 + 全量重放(sinceOverride=0)→ 同 change_id 真正落地。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 9,
              entitySyncId: 'tx-fix',
              ledgerId: 'L1',
              payload: {
                'syncId': 'tx-fix',
                'type': 'expense',
                'amount': 12.0,
              },
            ),
          ], cursor: 9);
      await h.engine.pull('${h.ledgerId}', sinceOverride: 0);

      expect((await h.db.select(h.db.transactions).get()).single.amount, 12.0,
          reason: '前置:重放后真正落地');
      expect(await h.engine.pullErrors.watchUnresolved().first, isEmpty,
          reason: 'DEFECT-A 自愈:该 change 真正 apply 成功后错误行被 resolve');
    });

    test('DEFECT-A: 坏值行与普通 apply 失败共存时互不干扰', () async {
      // 一条值跳过(transaction) + 一条类型错抛错(account)分属两轮,验证
      // PulledValueSkipped 与普通失败各自独立记录。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-bad-amt',
              ledgerId: 'L1',
              payload: {
                'syncId': 'tx-bad-amt',
                'type': 'expense',
                'amount': 1e400,
              },
            ),
          ], cursor: 1);
      await h.engine.pull('${h.ledgerId}');

      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 2,
              entityType: 'account',
              entitySyncId: 'acc-crash',
              payload: {'syncId': 'acc-crash', 'name': 'X', 'type': 7},
            ),
          ], cursor: 2);
      await h.engine.pull('');

      final unresolved = await h.engine.pullErrors.watchUnresolved().first;
      expect(unresolved.map((e) => e.changeId), [1, 2]);
      final classes = unresolved.map((e) => e.errorClass).toList();
      expect(classes, contains('PulledValueSkipped'),
          reason: '值跳过有独立可机器区分的 error_class');
      expect(classes.where((c) => c != 'PulledValueSkipped'), isNotEmpty,
          reason: '普通 apply 失败(errorClass = 异常 runtimeType,如 TypeError)'
              '与值跳过各自保留自己的 error_class');
      expect(classes.where((c) => c == 'PulledValueSkipped'), hasLength(1));
    });

    test('account 缺 name → 落空串', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'account',
              entitySyncId: 'acc-noname',
              payload: {'syncId': 'acc-noname'},
            ),
          ], cursor: 1);
      expect(await h.engine.pull(''), 1);
      final acc = (await h.db.select(h.db.accounts).get()).single;
      expect(acc.name, '');
      expect(acc.type, 'cash', reason: 'HARDENING: 缺 type 兜底 cash');
      expect(acc.currency, 'CNY', reason: 'HARDENING: 缺 currency 兜底 CNY');
    });

    test('account type=int → apply 抛错 → 整页 blocked + 错误入表', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'account',
              entitySyncId: 'acc-bad',
              payload: {'syncId': 'acc-bad', 'name': 'A', 'type': 7},
            ),
          ], cursor: 1);
      final applied = await h.engine.pull('');
      expect(applied, 0);
      expect((await h.db.select(h.db.syncPullErrors).get()), hasLength(1));
      expect(await h.db.select(h.db.accounts).get(), isEmpty);
    });

    test('category 缺 name/kind → 落空串 + expense 兜底', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'category',
              entitySyncId: 'cat-min',
              payload: {'syncId': 'cat-min'},
            ),
          ], cursor: 1);
      expect(await h.engine.pull(''), 1);
      final c = (await h.db.select(h.db.categories).get()).single;
      expect(c.name, '');
      expect(c.kind, 'expense');
      expect(c.level, 1);
      expect(c.iconType, 'material');
    });

    test('ADVERSE FINDING: category 自引用 parentName → 唯一一级分类从 picker 消失',
        () async {
      // ADVERSE FINDING(中):`_applyCategoryChange` 按 (parentName, kind,
      // level=1) 反查父分类(sync_engine_apply.dart:470-477),**不排除自身**,
      // 且这一步在"收编 seed 行"之后执行。
      //
      // 可达路径(本地有 legacy seed 分类,syncId 为 NULL):
      //   1. apply 先给 seed 行补 syncId='cat-remote'(收编,id 保持 1)
      //   2. 然后按 parentName='Food' + kind + level=1 反查 → 命中**刚刚
      //      收编的这一行自己**(id=1)
      //   3. 写 parentId=1 → 自己成为自己的父分类
      //
      // 结果:该分类变成"有子分类的父分类",`CategoryHierarchy
      // .getUsableCategories` 把它排除 → **可用分类数 = 0**,
      // 记账页分类选择器彻底空掉(且它本身 level 仍是 1,数据结构自相矛盾)。
      //
      // 注意:这里必须用 **syncId 为 NULL** 的 seed 行才复现"收编"路径
      // (有 syncId 时会新插一行,只造成同名重复)。
      await h.db.into(h.db.categories).insert(
          CategoriesCompanion.insert(name: 'Food', kind: 'expense'));

      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'category',
              entitySyncId: 'cat-remote',
              payload: {
                'syncId': 'cat-remote',
                'name': 'Food',
                'kind': 'expense',
                'level': 1,
                'parentName': 'Food', // 指向同名分类(= 自己)
              },
            ),
          ], cursor: 1);
      await h.engine.pull('');

      final cats = await h.db.select(h.db.categories).get();
      expect(cats, hasLength(1), reason: 'seed 行被收编,不新插');
      expect(cats.single.parentId, cats.single.id,
          reason: 'ADVERSE FINDING: 分类成为自己的父分类');
      expect(cats.single.level, 1,
          reason: 'ADVERSE FINDING: level=1 且有 parentId —— 结构自相矛盾');

      // 关键后果:可用分类为空 → 记账时选不到分类
      final parentIds =
          cats.where((c) => c.parentId != null).map((c) => c.parentId!).toSet();
      final usable = cats.where((c) => !parentIds.contains(c.id)).toList();
      expect(usable, isEmpty,
          reason: 'ADVERSE FINDING: 期望至少保留自身为可用分类;'
              '当前 getUsableCategories 把它排除 → 记账分类选择器全空');
    });

    test('HARDENING: 有 syncId 的同名 seed 走新插 → 只造成同名重复(非自引用)',
        () async {
      // 与上条对比:seed 行已有 syncId 时不会收编,而是新插一行,
      // parentId 指向 seed 行。结果是两个同名一级分类(一个成为另一个的父),
      // 可用分类还剩 1 个 —— 问题降级为"列表里出现重复名"。
      await h.seedCategory(syncId: 'cat-local', name: 'Food');
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'category',
              entitySyncId: 'cat-remote',
              payload: {
                'syncId': 'cat-remote',
                'name': 'Food',
                'kind': 'expense',
                'level': 1,
                'parentName': 'Food',
              },
            ),
          ], cursor: 1);
      await h.engine.pull('');

      final cats = await h.db.select(h.db.categories).get();
      expect(cats, hasLength(2));
      final parentIds =
          cats.where((c) => c.parentId != null).map((c) => c.parentId!).toSet();
      final usable = cats.where((c) => !parentIds.contains(c.id)).toList();
      expect(usable, hasLength(1),
          reason: 'HARDENING: 只剩一个"Food"可用,但列表里有两个同名行');
      expect(cats.where((c) => c.name == 'Food'), hasLength(2));
    });

    test('category 二级分类的 parentName 找不到父 → parentId 落 null(不崩)', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'category',
              entitySyncId: 'cat-orphan-sub',
              payload: {
                'syncId': 'cat-orphan-sub',
                'name': 'Lunch',
                'kind': 'expense',
                'level': 2,
                'parentName': 'NoSuchParent',
              },
            ),
          ], cursor: 1);
      expect(await h.engine.pull(''), 1);
      final c = (await h.db.select(h.db.categories).get()).single;
      expect(c.parentId, isNull,
          reason: 'HARDENING: 父找不到 → parentId null,但 level=2 → '
              '"level=2 + parentId=null" 的孤儿二级分类;'
              'buildHierarchy 把它当 topLevel(`level==1 || parentId==null`)');
      expect(c.level, 2);
    });

    test('ADVERSE FINDING: 同名分类两条 → _resolveCategoryId 抛 StateError → pull 永久卡死',
        () async {
      // ADVERSE FINDING(严重/阻塞):`_resolveCategoryId`
      // (sync_engine_resolvers.dart:58-66)按 `name(+kind)` 查分类,用
      // **`getSingleOrNull()`** —— 查不到返 null,查到**多行则抛
      // `StateError: Too many elements`**。
      //
      // 而 categories 表**没有 name 唯一约束**(仅 app 层 createCategory 检查),
      // 所以"两条同名一级分类"完全可达:
      //   路径 A:两台设备各自有同名 seed 分类(syncId 各是不同 UUID,
      //           v19/v22 migration 给老行补的是本地 UUID)
      //   路径 B:同一条远端同名分类被 apply 两次(pull 重放 / 不同 syncId)
      //   路径 C:上面自引用用例的"新插一行同名"
      //
      // 触发方式:任何**按名字**引用分类的远端 change ——
      //   `_applyTransactionChange` 在 `_resolveCategoryIdBySyncId` miss 后
      //   无条件调 `_resolveCategoryId`(sync_engine_apply.dart:135-138)。
      //   老协议 payload(无 categoryId)/ 跨设备 syncId 未对齐 都会走这条。
      //
      // 后果链条(**整页事务抛错 → rollback → cursor 不推进 → 下次 pull
      // 拉到同一条 → 再抛**)= 该设备的云同步**永久卡死**在 change_id=1,
      // 所有后续变更(含用户自己的编辑)全都同步不了,只有
      // replayAllChanges / 手工删库能恢复。
      //
      // 对照:`_resolveAccountId`(同文件 68-86 行)的注释明确写了
      //   "多次同步后 accounts 表里可能出现重名…按 name 全局查会 throw;
      //    这里用 take(1) 保守一点"
      // —— 账户侧已修,category 侧**漏改**。
      await h.seedCategory(syncId: 'cat-mine-uuid', name: '餐饮');
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'category',
              entitySyncId: 'cat-theirs-uuid',
              payload: {
                'syncId': 'cat-theirs-uuid',
                'name': '餐饮',
                'kind': 'expense',
                'level': 1,
              },
            ),
          ], cursor: 1);
      await h.engine.pull('');
      expect(
          (await h.db.select(h.db.categories).get())
              .where((c) => c.name == '餐饮'),
          hasLength(2),
          reason: '前置:两条同名一级分类(syncId 不同 → 不触发收编 fallback)');

      // 一条按 categoryName 引用该分类的 tx(老协议 / syncId 未对齐)
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 2,
              entitySyncId: 'tx-ref-dup',
              ledgerId: 'L1',
              payload: {
                'syncId': 'tx-ref-dup',
                'type': 'expense',
                'amount': 25.0,
                'categoryName': '餐饮',
                'categoryKind': 'expense',
              },
            ),
          ], cursor: 2);

      final applied = await h.engine.pull('${h.ledgerId}');
      expect(applied, 1,
          reason: 'ADVERSE FINDING: 期望 tx 正常 apply(按 take(1) 取第一个同名分类);'
              '实际 _resolveCategoryId 的 getSingleOrNull 抛 StateError → '
              '整页 rollback,applied=0');

      final errs = await h.db.select(h.db.syncPullErrors).get();
      expect(errs.map((e) => e.errorClass).toList(), isNot(contains('StateError')),
          reason: 'ADVERSE FINDING: StateError(Too many elements) 落进 sync_pull_errors');

      // 最关键的后果:永久卡死 —— 第二次 pull 仍然是同一结果
      final applied2 = await h.engine.pull('${h.ledgerId}');
      expect(await h.engine.appCursor.read(), 2,
          reason: 'ADVERSE FINDING: cursor 应推进到 2;实际恒为 1'
              '(每次 pull 都在同一条 change 上抛错回滚)→ 云同步永久卡死,'
              '用户所有后续编辑都推不出去也拉不下来');
      expect(applied2, 1);
    });

    test('HARDENING: 同名账户两条不会卡死(take(1) 已修)', () async {
      // 与上条对照:account 侧 resolver 用 `..limit(1)` + `.get()` +
      // `rows.first`(sync_engine_resolvers.dart:75-83),多行不抛。
      // 这里固定该差异,防止未来"统一"成 getSingleOrNull 时把账户侧也退回去。
      await h.seedAccount(syncId: 'acc-mine-uuid', name: '现金');
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'account',
              entitySyncId: 'acc-theirs-uuid',
              payload: {'syncId': 'acc-theirs-uuid', 'name': '现金'},
            ),
          ], cursor: 1);
      await h.engine.pull('');
      expect(
          (await h.db.select(h.db.accounts).get())
              .where((a) => a.name == '现金'),
          hasLength(2),
          reason: '两条同名账户');

      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 2,
              entitySyncId: 'tx-acc-dup',
              ledgerId: 'L1',
              payload: {
                'syncId': 'tx-acc-dup',
                'type': 'expense',
                'amount': 5.0,
                'accountName': '现金',
              },
            ),
          ], cursor: 2);
      final applied = await h.engine.pull('${h.ledgerId}');
      expect(applied, 1, reason: '账户侧取第一个同名行,不抛');
      final tx = (await h.db.select(h.db.transactions).get()).single;
      expect(tx.accountId, isNotNull);
    });

    test('ADVERSE FINDING: 同名一级分类两条 → 子分类 parentName 反查父也 getSingleOrNull 抛错(另一处调用点)',
        () async {
      // ADVERSE FINDING(严重/阻塞,与上一条 `_resolveCategoryId`
      // (sync_engine_resolvers.dart:65)同族、但**独立的第二处调用点**):
      // `_applyCategoryChange` 解析父分类时用 `getSingleOrNull()` 查
      // name+kind+level=1(sync_engine_apply.dart:471-475)。
      // 只修 resolver 不会顺带修好这里 —— 任何带 parentName 的远端二级分类
      // 在"同名一级分类 x2"常态下都会让**整页事务回滚 → cursor 不推进**,
      // pull 永久卡死在该 change 上(与 resolver 版同级:严重/阻塞)。
      await h.seedCategory(syncId: 'cat-mine-uuid', name: '餐饮');
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'category',
              entitySyncId: 'cat-theirs-uuid',
              payload: {
                'syncId': 'cat-theirs-uuid',
                'name': '餐饮',
                'kind': 'expense',
                'level': 1,
              },
            ),
          ], cursor: 1);
      await h.engine.pull('');
      expect(
          (await h.db.select(h.db.categories).get())
              .where((c) => c.name == '餐饮'),
          hasLength(2),
          reason: '前置:两条同名一级分类');

      // 远端二级分类按 parentName 指向该名
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 2,
              entityType: 'category',
              entitySyncId: 'cat-child-dup',
              payload: {
                'syncId': 'cat-child-dup',
                'name': '午餐',
                'kind': 'expense',
                'level': 2,
                'parentName': '餐饮',
              },
            ),
          ], cursor: 2);

      final applied = await h.engine.pull('');
      expect(applied, 1,
          reason: 'ADVERSE FINDING: 期望子分类正常 apply(父解析取第一个同名行);'
              '实际 _applyCategoryChange:471-475 的 getSingleOrNull 遇两行抛 '
              'StateError → 整页回滚,applied=0');
      expect(await h.engine.appCursor.read(), 2,
          reason: 'ADVERSE FINDING: cursor 应推进到 2;实际恒为 1 → pull 永久卡死');
      final child = (await h.db.select(h.db.categories).get())
          .where((c) => c.syncId == 'cat-child-dup');
      expect(child, hasLength(1), reason: 'ADVERSE FINDING: 子分类应已落库');
      expect(child.single.parentId, isNotNull,
          reason: 'ADVERSE FINDING: 子分类应挂到父分类上');
    });

    test('ADVERSE FINDING: category parentSyncId 被 apply 完全忽略(只用 parentName 反查)',
        () async {
      // ADVERSE FINDING(低,脆弱性):payload 里带了稳定的 `parentSyncId`,
      // 但 `_applyCategoryChange` **只**按 `parentName + kind + level==1`
      // 反查(sync_engine_apply.dart:470)。这违背了 serializer / server 侧
      // "按 id 取名字、不依赖 cascade 改写"的设计承诺;
      // 一旦父分类被重命名,对端的父子关系就会断(name 查不到 → parentId=null)。
      await h.seedCategory(syncId: 'parent-sync-id', name: 'ParentA');
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'category',
              entitySyncId: 'cat-child',
              payload: {
                'syncId': 'cat-child',
                'name': 'Child',
                'kind': 'expense',
                'level': 2,
                // 稳定的父引用 + 一个**过期**的名字(父被重命名过)
                'parentSyncId': 'parent-sync-id',
                'parentName': 'ParentA_OldName',
              },
            ),
          ], cursor: 1);
      await h.engine.pull('');

      final child = (await h.db.select(h.db.categories).get())
          .firstWhere((c) => c.name == 'Child');
      // 实测(缺陷存在时):child.parentId == null —— payload 里
      // parentSyncId='parent-sync-id' 明明能命中父分类,却被完全忽略。
      // 断言只保留"期望行为"这一条,产品修复后本用例即转绿。
      expect(child.parentId, isNotNull,
          reason: 'ADVERSE FINDING: 期望优先按 payload.parentSyncId 命中父分类;'
              '当前 _applyCategoryChange 只按 parentName+kind+level 反查,'
              'parentSyncId 被完全忽略 → 父分类被重命名后,子分类的父子关系'
              '在**对端**断掉(child.parentId=null 成为孤儿一级分类)');
    });

    test('ADVERSE FINDING: tag 空名可落库(重名/空名无唯一约束)', () async {
      // ADVERSE FINDING(低):`_applyTagChange` 对 `name` 只做空串兜底,不拒绝。
      // 空名 tag 会出现在 tag picker / 详情页里(UI 只显示一个色块)。
      // 与 category 的 DuplicateNameException 不同,tag 完全没有唯一性约束。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'tag',
              entitySyncId: 'tag-empty',
              payload: {'syncId': 'tag-empty', 'name': ''},
            ),
            remoteChange(
              changeId: 2,
              entityType: 'tag',
              entitySyncId: 'tag-empty2',
              payload: {'syncId': 'tag-empty2', 'name': ''},
            ),
          ], cursor: 2);
      expect(await h.engine.pull(''), 2);
      final tags = await h.db.select(h.db.tags).get();
      expect(tags, hasLength(2));
      expect(tags.every((t) => t.name.isEmpty), isTrue,
          reason: 'ADVERSE FINDING: 两个空名 tag 并存,UI 无法区分');
    });

    test('budget 缺 ledgerSyncId → 跳过(log 但不崩),不落库', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'budget',
              entitySyncId: 'bud-noledger',
              payload: {'syncId': 'bud-noledger', 'amount': 100.0},
            ),
          ], cursor: 1);
      // ledgerId 为空串 → _resolveLedgerIdBySyncId('') 返 null → skip
      final applied = await h.engine.pull('${h.ledgerId}');
      expect(applied, 1,
          reason: 'HARDENING: apply 返 true 但内部 return(未落库)——'
              'applied 计数把"跳过"也算成"应用了"');
      expect(await h.db.select(h.db.budgets).get(), isEmpty);
    });

    test('ADVERSE FINDING: budget 因 ledger 未就绪被跳过,却返 true 且推进 cursor → 永久丢失',
        () async {
      // ADVERSE FINDING(中):`_applyBudgetChange` 在 `ledgerSyncId` 解析不到
      // 本地账本时直接 `return`(sync_engine_apply.dart:698-703,日志"本地未就绪,
      // 跳过"),但 `applyRemoteChange` 的 switch 分支**仍然 return true**
      // (sync_engine_apply.dart:31-32)。于是 `_applyPullPage` 把 applied +1,
      // `_runPullLoop` 随后把 cursor 推到该页末尾。
      //
      // 后果:这条 budget 的 change_id 落在 cursor 之后 → **再也不会被重拉**。
      // 等目标账本稍后被创建/同步下来,这条预算已经拉不回来了(除非整体
      // replayAllChanges)。同一模式也适用于 `_applyAccountAdjustmentChange`。
      h.provider.pullResponder = (c, since, limit) {
        if ((since ?? 0) == 0) {
          return page([
            remoteChange(
              changeId: 5,
              entityType: 'budget',
              entitySyncId: 'bud-lost',
              ledgerId: 'NOT-YET-LOCAL',
              payload: {'syncId': 'bud-lost', 'amount': 999.0},
            ),
          ], cursor: 5);
        }
        return page([], cursor: since ?? 0);
      };
      final applied = await h.engine.pull('${h.ledgerId}');

      expect(applied, 1);
      expect(await h.db.select(h.db.budgets).get(), isEmpty,
          reason: '前置:budget 确实没落库(跳过)');
      expect(await h.engine.appCursor.read(), 0,
          reason: 'ADVERSE FINDING: 期望"跳过"的条目不推进 cursor(留待重试);'
              '实际 cursor 已推到 5 → 该 budget 永久无法再拉取');
    });

    test('exchange_rate_override 缺字段 → warning 跳过,不崩', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'exchange_rate_override',
              entitySyncId: 'ero-bad',
              payload: {'syncId': 'ero-bad'}, // 缺 base/quote/rate
            ),
          ], cursor: 1);
      final applied = await h.engine.pull('');
      expect(applied, 1, reason: 'HARDENING: 跳过也算 applied');
      expect(await h.db.select(h.db.exchangeRateOverrides).get(), isEmpty);
    });

    test('exchange_rate_override rate="abc" → 落库(消费方解析失败退化)', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'exchange_rate_override',
              entitySyncId: 'ero-abc',
              payload: {
                'syncId': 'ero-abc',
                'baseCurrency': 'CNY',
                'quoteCurrency': 'USD',
                'rate': 'abc',
                'updatedAt': '2026-05-01T00:00:00Z',
              },
            ),
          ], cursor: 1);
      expect(await h.engine.pull(''), 1);
      final row = (await h.db.select(h.db.exchangeRateOverrides).get()).single;
      expect(row.rate, 'abc',
          reason: 'HARDENING: 非法 rate 落库;消费方 double.tryParse 返 null'
              '→ 按"无汇率"处理(不崩,但静默忽略用户设置的假值)');
    });

    test('exchange_rate_override updatedAt 缺失 → updatedAt 落 null', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'exchange_rate_override',
              entitySyncId: 'ero-nodate',
              payload: {
                'syncId': 'ero-nodate',
                'baseCurrency': 'CNY',
                'quoteCurrency': 'USD',
                'rate': '7.2',
              },
            ),
          ], cursor: 1);
      expect(await h.engine.pull(''), 1);
      final row = (await h.db.select(h.db.exchangeRateOverrides).get()).single;
      expect(row.updatedAt, isNull);
      // 下次 push 时 serializer 会用 now 兜底 → 时间戳漂移
      // (见 entity_serializer 套件的 ADVERSE-CANDIDATE 用例)
    });

    test('ledger payload 无 name → 跳过(不新建账本)', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'ledger',
              entitySyncId: 'brand-new-ledger',
              payload: {'syncId': 'brand-new-ledger', 'currency': 'JPY'},
            ),
          ], cursor: 1);
      final applied = await h.engine.pull('');
      expect(applied, 1);
      expect(await h.db.select(h.db.ledgers).get(), hasLength(1),
          reason: 'HARDENING: 只落原来那个 seed ledger,不新建(等 snapshot 兜底)');
    });

    test('ledger payload monthStartDay=0 → clamp 到 1', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'ledger',
              entitySyncId: 'L1',
              payload: {'ledgerName': 'Renamed', 'monthStartDay': 0},
            ),
          ], cursor: 1);
      expect(await h.engine.pull(''), 1);
      final l = (await h.db.select(h.db.ledgers).get()).single;
      expect(l.monthStartDay, 1, reason: 'clamp(1,28)');
      expect(l.name, 'Renamed');
    });

    test('ledger payload monthStartDay=-5 / 31 / 999 → clamp 到 1 / 28 / 28', () async {
      for (final (input, expected) in [( -5, 1), (31, 28), (999, 28)]) {
        final harness = await SyncHarness.create(ledgerSyncId: 'LC');
        harness.provider.pullResponder = (c, since, limit) => page([
              remoteChange(
                changeId: 1,
                entityType: 'ledger',
                entitySyncId: 'LC',
                payload: {'ledgerName': 'X', 'monthStartDay': input},
              ),
            ], cursor: 1);
        await harness.engine.pull('');
        final l = (await harness.db.select(harness.db.ledgers).get()).single;
        expect(l.monthStartDay, expected, reason: 'monthStartDay=$input');
        await harness.close();
      }
    });

    test('ledger payload monthStartDay 是字符串 → absent(保持原值)', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'ledger',
              entitySyncId: 'L1',
              payload: {'ledgerName': 'Y', 'monthStartDay': '15'},
            ),
          ], cursor: 1);
      await h.engine.pull('');
      final l = (await h.db.select(h.db.ledgers).get()).single;
      expect(l.monthStartDay, 1,
          reason: 'HARDENING: `as num?` 对上 String 返 null → Value.absent'
              '→ 保留本地默认 1(不是静默改成 15,也不会崩)');
    });

    test('ledger 撞多行同 syncId → 取第一行 + 清 dup', () async {
      // 直接插两行同 syncId(模拟历史 bug 残留)
      await h.db.into(h.db.ledgers).insert(LedgersCompanion.insert(
          name: 'DupA', syncId: const Value('L1')));
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'ledger',
              entitySyncId: 'L1',
              payload: {'ledgerName': 'Fixed'},
            ),
          ], cursor: 1);
      final applied = await h.engine.pull('');
      expect(applied, 1);
      final ledgers = await h.db.select(h.db.ledgers).get();
      expect(ledgers, hasLength(1),
          reason: 'HARDENING: 撞多行时取第一行 + 清 dup(避免 getSingleOrNull 抛错中断 replay)');
      expect(ledgers.single.name, 'Fixed');
    });

    test('ledger 带 currency → 更新本地币种', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'ledger',
              entitySyncId: 'L1',
              payload: {'ledgerName': 'L', 'currency': 'JPY'},
            ),
          ], cursor: 1);
      await h.engine.pull('');
      expect((await h.db.select(h.db.ledgers).get()).single.currency, 'JPY');
    });
  });

  // ==================================================================
  group('批内同实体两次 / LWW', () {
    test('同 syncId 两条 upsert(不同金额)→ 后者(change 顺序)胜出', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-lww',
              ledgerId: 'L1',
              payload: {
                'syncId': 'tx-lww',
                'type': 'expense',
                'amount': 10.0,
                'note': 'old',
              },
            ),
            remoteChange(
              changeId: 2,
              entitySyncId: 'tx-lww',
              ledgerId: 'L1',
              payload: {
                'syncId': 'tx-lww',
                'type': 'expense',
                'amount': 20.0,
                'note': 'new',
              },
            ),
          ], cursor: 2);

      final applied = await h.engine.pull('${h.ledgerId}');
      expect(applied, 2, reason: '两条都算 applied(第一条 insert,第二条 update)');

      final txs = await h.db.select(h.db.transactions).get();
      expect(txs, hasLength(1), reason: '同 syncId 只一行');
      expect(txs.single.amount, 20.0,
          reason: 'apply 顺序跟随 change_id 升序 → 后到者胜(与 server LWW 结果一致)');
      expect(txs.single.note, 'new');
    });

    test('同 syncId upsert 后 delete → 行被删', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-ud',
              ledgerId: 'L1',
              payload:
                  {'syncId': 'tx-ud', 'type': 'expense', 'amount': 5.0},
            ),
            remoteChange(
              changeId: 2,
              entitySyncId: 'tx-ud',
              ledgerId: 'L1',
              action: 'delete',
            ),
          ], cursor: 2);
      expect(await h.engine.pull('${h.ledgerId}'), 2);
      expect(await h.db.select(h.db.transactions).get(), isEmpty);
    });

    test('同 syncId delete 后 upsert → 行被重新创建(不残留 deleted 标记)', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-du',
              ledgerId: 'L1',
              action: 'delete',
            ),
            remoteChange(
              changeId: 2,
              entitySyncId: 'tx-du',
              ledgerId: 'L1',
              payload:
                  {'syncId': 'tx-du', 'type': 'income', 'amount': 8.0},
            ),
          ], cursor: 2);
      expect(await h.engine.pull('${h.ledgerId}'), 2);
      final tx = (await h.db.select(h.db.transactions).get()).single;
      expect(tx.type, 'income');
      expect(tx.amount, 8.0);
    });

    test('本设备 change 与远端 change 交错 → 自己的跳过、远端的应用', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-mine',
              ledgerId: 'L1',
              updatedByDeviceId: h.provider.deviceId!,
              payload:
                  {'syncId': 'tx-mine', 'type': 'expense', 'amount': 1.0},
            ),
            remoteChange(
              changeId: 2,
              entitySyncId: 'tx-theirs',
              ledgerId: 'L1',
              payload:
                  {'syncId': 'tx-theirs', 'type': 'expense', 'amount': 2.0},
            ),
          ], cursor: 2);
      final applied = await h.engine.pull('${h.ledgerId}');
      expect(applied, 1);
      final txs = await h.db.select(h.db.transactions).get();
      expect(txs.map((t) => t.syncId).toList(), ['tx-theirs']);
    });
  });

  // ==================================================================
  group('未知 entityType / 未知 action', () {
    test('未知 entityType → 跳过(diamond 不崩),后续条目正常 apply', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'weird_new_entity',
              entitySyncId: 'w-1',
              ledgerId: 'L1',
              payload: {'syncId': 'w-1'},
            ),
            remoteChange(
              changeId: 2,
              entitySyncId: 'tx-after',
              ledgerId: 'L1',
              payload:
                  {'syncId': 'tx-after', 'type': 'expense', 'amount': 3.0},
            ),
          ], cursor: 2);
      final applied = await h.engine.pull('${h.ledgerId}');
      expect(applied, 1, reason: '未知类型返 false(不计数),后续条目照常 apply');
      expect((await h.db.select(h.db.transactions).get()).single.syncId,
          'tx-after');
      expect(await h.engine.appCursor.read(), 2,
          reason: 'HARDENING: 跳过未知类型后 cursor 照常推进 —— '
              '若 server 后续为这个新类型补推正确 change,cursor 已过 → 不会重拉');
    });

    test('ledger_snapshot change → 跳过(pull 路径不处理)', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'ledger_snapshot',
              entitySyncId: 'L1',
              ledgerId: 'L1',
              payload: {'syncId': 'L1'},
            ),
          ], cursor: 1);
      expect(await h.engine.pull(''), 0);
    });

    test('未知 action("touch")→ 走 upsert 分支(payload 缺失 → 跳过)', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-touch',
              ledgerId: 'L1',
              action: 'touch',
              // 无 payload
            ),
          ], cursor: 1);
      final applied = await h.engine.pull('${h.ledgerId}');
      expect(applied, 0,
          reason: 'HARDENING: action != "delete" 且 payload==null → 先被 '
              '"无 payload 跳过" 拦下,不崩');
    });

    test('未知 action + 有 payload → 当 upsert 处理(宽松)', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-weird',
              ledgerId: 'L1',
              action: 'rename', // 非 upsert/delete
              payload: {
                'syncId': 'tx-weird',
                'type': 'expense',
                'amount': 4.0,
              },
            ),
          ], cursor: 1);
      final applied = await h.engine.pull('${h.ledgerId}');
      expect(applied, 1, reason: 'HARDENING: 非 delete 一律走 upsert 分支');
      final tx = (await h.db.select(h.db.transactions).get()).single;
      expect(tx.amount, 4.0);
    });

    test('空 entitySyncId 的 change → apply 不崩', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: '',
              ledgerId: 'L1',
              payload: {'syncId': '', 'type': 'expense', 'amount': 1.0},
            ),
          ], cursor: 1);
      final applied = await h.engine.pull('${h.ledgerId}');
      // syncId='' → LookupCache 返 null → 走 DB 查 syncId.equals('') → 无 → insert
      expect(applied, 1, reason: 'HARDENING: 空 syncId 会被当新实体插入');
      final tx = (await h.db.select(h.db.transactions).get()).single;
      expect(tx.syncId, '');
    });
  });

  // ==================================================================
  group('recordPulledFromServer 登记面', () {
    test('account / category / tag 三类 pull 后都打 marker', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'account',
              entitySyncId: 'acc-r',
              payload: {'syncId': 'acc-r', 'name': 'Cash'},
            ),
            remoteChange(
              changeId: 2,
              entityType: 'category',
              entitySyncId: 'cat-r',
              payload: {'syncId': 'cat-r', 'name': 'C', 'kind': 'expense'},
            ),
            remoteChange(
              changeId: 3,
              entityType: 'tag',
              entitySyncId: 'tag-r',
              payload: {'syncId': 'tag-r', 'name': 'T'},
            ),
          ], cursor: 3);
      await h.engine.pull('');

      final markers = await h.db.select(h.db.localChanges).get();
      expect(markers, hasLength(3), reason: '三类 user-global 都必须登记');
      expect(markers.every((m) => m.pushedAt != null), isTrue,
          reason: 'marker 必须是"已推"状态(否则下次 push 会把 server 已有的重推一遍)');
      expect(markers.map((m) => '${m.entityType}|${m.entitySyncId}').toSet(),
          {'account|acc-r', 'category|cat-r', 'tag|tag-r'});
    });

    test('ADVERSE FINDING: 6 种 entityType 中只有 account/category/tag 打 marker',
        () async {
      // ADVERSE FINDING(低-中):`recordPulledFromServer` 只在
      // `_applyAccountChange` / `_applyCategoryChange` / `_applyTagChange`
      // 三处调用(sync_engine_apply.dart:428 / 586 / 661)。
      // transaction / budget / account_adjustment / ledger /
      // exchange_rate_override **全都不登记**。
      //
      // 对 transaction / budget 而言问题不大(它们不会走
      // `_backfillLegacyUserGlobalChanges`)。但 `exchange_rate_override`
      // **是** user-global 类型(ChangeTracker._userGlobalEntityTypes 含它),
      // 而 backfill 只扫 account/category/tag —— 所以也不会误推。
      //
      // 真正的风险:`_backfillLegacyUserGlobalChanges` 只按
      // (entityType, entitySyncId) 判"已知",不看 ledgerId。如果未来新增
      // user-global 类型(marker 未覆盖),pull 来的实体会被 backfill 判为
      // legacy 并补登 change → 重推 → server sync_changes 膨胀(注释
      // change_tracker.dart:128-133 描述的正是这个 bug 类)。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-nomark',
              ledgerId: 'L1',
              payload:
                  {'syncId': 'tx-nomark', 'type': 'expense', 'amount': 1.0},
            ),
            remoteChange(
              changeId: 2,
              entityType: 'exchange_rate_override',
              entitySyncId: 'ero-nomark',
              payload: {
                'syncId': 'ero-nomark',
                'baseCurrency': 'CNY',
                'quoteCurrency': 'USD',
                'rate': '7.3',
                'updatedAt': '2026-05-01T00:00:00Z',
              },
            ),
            remoteChange(
              changeId: 3,
              entityType: 'budget',
              entitySyncId: 'bud-nomark',
              ledgerId: 'L1',
              payload: {
                'syncId': 'bud-nomark',
                'ledgerSyncId': 'L1',
                'amount': 50.0,
              },
            ),
          ], cursor: 3);
      await h.engine.pull('');

      final markers = await h.db.select(h.db.localChanges).get();
      expect(markers, isEmpty,
          reason: 'ADVERSE FINDING: 期望 exchange_rate_override 也登记'
              '(它是 user-global 白名单成员,但 backfill 不扫它 → 当前无害);'
              'transaction / budget 不登记属设计选择');
    });

    test('ADVERSE FINDING: pull 来的 account 未打 marker 时,backfill 会补登并重推(2x 膨胀回归)',
        () async {
      // 反向验证 marker 的价值:删掉 marker 后模拟 v19→v27 老数据场景 ——
      // backfill 会给所有"local_changes 里没记录"的 user-global 实体补
      // upsert change → 下一轮 push 把 server 已有的实体重推一遍。
      // 这正是 change_tracker.dart:128-133 注释描述的历史 bug。
      await h.db.into(h.db.accounts).insert(AccountsCompanion.insert(
            ledgerId: h.ledgerId,
            name: 'FromServer',
            syncId: const Value('acc-from-server'),
          ));
      // 不给它打 marker → backfill 会认作 legacy
      await h.engine.push('${h.ledgerId}');

      expect(h.provider.pushedBatches, hasLength(1));
      expect(h.provider.pushedBatches.single.single['entity_sync_id'],
          'acc-from-server',
          reason: 'ADVERSE FINDING(机制验证): 无 marker 的 pull 实体被 backfill 重推 → '
              'server sync_changes 2x 膨胀。marker 机制是唯一防线');
    });

    test('打了 marker 的 pull 实体不会被 backfill 重推', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'account',
              entitySyncId: 'acc-marked',
              payload: {'syncId': 'acc-marked', 'name': 'A'},
            ),
          ], cursor: 1);
      await h.engine.pull('');
      h.provider.pushedBatches.clear();

      await h.engine.push('${h.ledgerId}');

      expect(h.provider.pushedBatches, isEmpty,
          reason: 'marker 生效:server 已有的 account 不被重推');
    });

    test('多次 pull 同实体(marker 幂等)不膨胀 local_changes', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'account',
              entitySyncId: 'acc-1',
              payload: {'syncId': 'acc-1', 'name': 'A1'},
            ),
          ], cursor: 1);
      await h.engine.pull('');
      // 再拉一次(改名)
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 2,
              entityType: 'account',
              entitySyncId: 'acc-1',
              payload: {'syncId': 'acc-1', 'name': 'A2'},
            ),
          ], cursor: 2);
      await h.engine.pull('');

      final markers = await h.db.select(h.db.localChanges).get();
      expect(markers, hasLength(1),
          reason: '幂等:同实体两次 pull 仍只一行 marker(否则 server 2x 膨胀)');
      expect((await h.db.select(h.db.accounts).get()).single.name, 'A2');
    });

    test('pull delete change 后 marker 不新增(delete 分支不登记)', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'account',
              entitySyncId: 'acc-del',
              payload: {'syncId': 'acc-del', 'name': 'A'},
            ),
          ], cursor: 1);
      await h.engine.pull('');
      expect(await h.db.select(h.db.localChanges).get(), hasLength(1));

      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 2,
              entityType: 'account',
              entitySyncId: 'acc-del',
              action: 'delete',
            ),
          ], cursor: 2);
      await h.engine.pull('');

      expect(await h.db.select(h.db.accounts).get(), isEmpty);
      final markers = await h.db.select(h.db.localChanges).get();
      expect(markers, hasLength(1),
          reason: 'HARDENING: 实体被远端删除后 marker 行残留(pushedAt 非 null)'
              '→ 若同名账户之后被重新创建并拿到**新 syncId**,新 syncId 无 marker'
              '→ 正常登记;残留行只占体积');
    });
  });

  // ==================================================================
  group('apply 崩溃面:整页 rollback 语义', () {
    test('坏条目在页中:前面已 apply 的条目也回滚', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-good1',
              ledgerId: 'L1',
              payload:
                  {'syncId': 'tx-good1', 'type': 'expense', 'amount': 1.0},
            ),
            remoteChange(
              changeId: 2,
              entitySyncId: 'tx-bad',
              ledgerId: 'L1',
              payload: {'syncId': 'tx-bad', 'type': 42, 'amount': 2.0},
            ),
            remoteChange(
              changeId: 3,
              entitySyncId: 'tx-good2',
              ledgerId: 'L1',
              payload:
                  {'syncId': 'tx-good2', 'type': 'expense', 'amount': 3.0},
            ),
          ], cursor: 3);

      final applied = await h.engine.pull('${h.ledgerId}');

      expect(applied, 0, reason: '整页 rollback:applied 计 0');
      expect(await h.db.select(h.db.transactions).get(), isEmpty,
          reason: '页内所有条目一起回滚 —— 好条目也会被下轮重放(幂等)');
      expect(await h.engine.appCursor.read(), 0, reason: 'cursor 不推进');
      final errs = await h.db.select(h.db.syncPullErrors).get();
      expect(errs, hasLength(1));
      expect(errs.single.changeId, 2, reason: '只记录真正失败的那条');
    });

    test('坏条目后 hasMore=true → 不再拉后续页(blocked 短路)', () async {
      var calls = 0;
      h.provider.pullResponder = (c, since, limit) {
        calls++;
        if (calls == 1) {
          return page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-bad',
              ledgerId: 'L1',
              payload: {'syncId': 'tx-bad', 'type': 7, 'amount': 1.0},
            ),
          ], cursor: 1, hasMore: true);
        }
        return page([
          remoteChange(
            changeId: 2,
            entitySyncId: 'tx-later',
            ledgerId: 'L1',
            payload: {'syncId': 'tx-later', 'type': 'expense', 'amount': 2.0},
          ),
        ], cursor: 2);
      };

      await h.engine.pull('${h.ledgerId}');
      expect(calls, 1,
          reason: 'HARDENING: blocked 后立即 break,不发第 2 页请求'
              '(避免连续踩同一坏数据);cursor 停在原位下次重试');
      expect((await h.db.select(h.db.transactions).get()), isEmpty);
    });

    test('错误记录后,server 修好推新 change → markResolved 生效', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-fix',
              ledgerId: 'L1',
              payload: {'syncId': 'tx-fix', 'type': 99, 'amount': 1.0},
            ),
          ], cursor: 1);
      await h.engine.pull('${h.ledgerId}');
      var errs = await h.db.select(h.db.syncPullErrors).get();
      expect(errs.single.resolvedAt, isNull);

      // server 修好同 changeId 的 payload(或推了新的)
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-fix',
              ledgerId: 'L1',
              payload:
                  {'syncId': 'tx-fix', 'type': 'expense', 'amount': 1.0},
            ),
          ], cursor: 1);
      await h.engine.pull('${h.ledgerId}');

      errs = await h.db.select(h.db.syncPullErrors).get();
      expect(errs.single.resolvedAt, isNotNull,
          reason: 'markResolved:apply 通过的 change_id 自动 resolve');
    });

    test('同 change_id 再失败 → attempt_count 累加', () async {
      for (var i = 0; i < 3; i++) {
        h.provider.pullResponder = (c, since, limit) => page([
              remoteChange(
                changeId: 1,
                entitySyncId: 'tx-fail',
                ledgerId: 'L1',
                payload: {'syncId': 'tx-fail', 'type': 3.14, 'amount': 1.0},
              ),
            ], cursor: 1);
        await h.engine.pull('${h.ledgerId}');
      }
      final err = (await h.db.select(h.db.syncPullErrors).get()).single;
      expect(err.attemptCount, 3, reason: '同 changeId 反复失败 → 计数累加供 UI 展示');
    });

    test('错误 payload 不落 DB(整页 rollback 保证)', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entityType: 'account',
              entitySyncId: 'acc-rollback',
              payload: {'syncId': 'acc-rollback', 'name': 'X', 'type': null},
            ),
            remoteChange(
              changeId: 2,
              entityType: 'account',
              entitySyncId: 'acc-ok',
              payload: {'syncId': 'acc-ok', 'name': 'Y', 'type': 'cash'},
            ),
            // 让最后一条崩:type 用 List
            remoteChange(
              changeId: 3,
              entityType: 'account',
              entitySyncId: 'acc-crash',
              payload: {'syncId': 'acc-crash', 'name': 'Z', 'type': <int>[1]},
            ),
          ], cursor: 3);
      await h.engine.pull('');
      expect(await h.db.select(h.db.accounts).get(), isEmpty,
          reason: '前两条(含合法的 acc-ok)也一起回滚');
    });

    test('HARDENING: SQLite busy 不触发(内存库),但错误分类仍写 errorClass', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 1,
              entitySyncId: 'tx-ec',
              ledgerId: 'L1',
              payload: {'syncId': 'tx-ec', 'type': <String>[], 'amount': 1.0},
            ),
          ], cursor: 1);
      await h.engine.pull('${h.ledgerId}');
      final err = (await h.db.select(h.db.syncPullErrors).get()).single;
      expect(err.errorClass, isNotEmpty);
      expect(err.errorMessage, isNotEmpty);
      expect(err.entityType, 'transaction');
      expect(err.action, 'upsert');
      expect(err.rawChangeJson, contains('tx-ec'),
          reason: 'rawChangeJson 保留完整 change 供开发者诊断');
    });
  });

  // ==================================================================
  group('pull 单飞与并发', () {
    test('replay(sinceOverride=0)与普通 pull 的 in-flight 交互', () async {
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 5,
              entitySyncId: 'tx-p',
              ledgerId: 'L1',
              payload: {'syncId': 'tx-p', 'type': 'expense', 'amount': 1.0},
            ),
          ], cursor: 5);

      final results = await Future.wait([
        h.engine.pull('${h.ledgerId}'),
        h.engine.pull('${h.ledgerId}'),
      ]);
      expect(results, [1, 1], reason: '并发普通 pull 复用同一 in-flight 结果');
      expect(h.provider.pullCallCount, 1,
          reason: 'HARDENING: 单飞生效 —— 只发一次 HTTP 探针');
    });

    test('HARDENING: pull 与 push 各有独立单飞锁,互不干扰', () async {
      await h.seedEntityWithChanges('tx-i', 1);
      h.provider.pullResponder = (c, since, limit) => page([], cursor: 0);

      final pushFuture = h.engine.push('${h.ledgerId}');
      final pullFuture = h.engine.pull('${h.ledgerId}');
      await Future.wait([pushFuture, pullFuture]);

      expect(h.provider.pushedBatches, hasLength(1));
      expect(h.provider.pullCallCount, 1);
    });
  });

  // ==================================================================
  // U-08 安全阀"放弃重放"必须可观测(2026-10-11 复现缺陷回归)。
  //
  // 缺陷形态:同一条 change 依赖(ledger)永远不到 → 推迟到 maxDeferredReplays
  // 轮后安全阀触发,在 `_applyPullPage` 内 `pullErrors.record(...)`;同一轮
  // `_runPullLoop` commit cursor 后无条件遍历整页 markResolved → 刚写的错误行
  // 被当场 resolve。`watchUnresolved()`(UI 唯一查询面)永远看不到 →
  // "记录错误、UI 可见、不静默"的承诺不成立(旧实现 13 轮实测:
  // round=10 unresolved=0 totalErrors=1)。
  //
  // 修复不变量(本组逐条锁定):
  //   a. 阀门跳闸后错误行存活(resolved_at IS NULL),watchUnresolved 查得到;
  //   b. 错误带可执行上下文(change_id / entityType / entitySyncId / 为什么);
  //   c. error_class=DeferredGiveUp 可机器区分的 needs-attention 状态;
  //   d. 活性:同轮 cursor 照常推进(不停机);
  //   e. 自愈:依赖到达后重放成功 → 错误自动 resolve;
  //   f. 放弃后不再把整页钉在页首(每轮不再重复写错误、不阻塞后续 change)。
  // ==================================================================
  group('U-08 安全阀放弃重放的可观测性', () {
    /// 依赖永远不满足的 budget change(ledgerSyncId 指向本地不存在的账本)。
    /// 用 var + 闭包参数标注,避免让本文件 import flutter_cloud_sync
    /// (返回类型由 `page()` 推断)。
    giveUpPage() {
      return (int c, int? since, int limit) {
        if ((since ?? 0) >= 4242) return page([], cursor: 4242);
        return page([
          remoteChange(
            changeId: 4242,
            entityType: 'budget',
            entitySyncId: 'bud-giveup',
            ledgerId: 'NOT-YET-LOCAL',
            payload: {'syncId': 'bud-giveup', 'amount': 999.0},
          ),
        ], cursor: 4242);
      };
    }

    test('阀门跳闸后错误在 watchUnresolved 存活(cursor 同轮推进,不停机)', () async {
      h.provider.pullResponder = giveUpPage();

      // maxDeferredReplays = 10 → 第 11 次 apply 该 change 时放弃。
      for (var i = 0; i < 10; i++) {
        await h.engine.pull('${h.ledgerId}');
        expect(await h.engine.appCursor.read(), 0,
            reason: '推迟期间(第 ${i + 1} 轮):cursor 必须停在页首待重放');
        expect(await h.engine.pullErrors.watchUnresolved().first, isEmpty,
            reason: '推迟阶段尚未放弃,不应有错误行');
      }

      // 第 11 轮:安全阀跳闸 —— 记录错误 + 放行 cursor(同一轮内完成)。
      await h.engine.pull('${h.ledgerId}');

      final rows = await h.db.select(h.db.syncPullErrors).get();
      expect(rows, hasLength(1));
      expect(rows.single.changeId, 4242);
      expect(rows.single.resolvedAt, isNull,
          reason: 'ADVERSE FINDING(已修):旧实现同轮 record+markResolved,'
              '错误行落库即被 resolve —— watchUnresolved 永远为空;'
              '修复后放弃的记录必须 resolved_at IS NULL');
      expect(await h.engine.appCursor.read(), 4242,
          reason: '活性:阀门跳闸后 cursor 必须照常推进(不停机)');
      expect(await h.db.select(h.db.budgets).get(), isEmpty,
          reason: '前提:budget 确实没落地(依赖缺失)');

      // UI 查询面(a):watchUnresolved 能看到。
      final unresolved = await h.engine.pullErrors.watchUnresolved().first;
      expect(unresolved, hasLength(1),
          reason: 'ADVERSE FINDING(已修):放弃记录必须能被 UI 的 watchUnresolved'
              '查询到(旧实现 round=10 即 unresolved=0)');
      final row = unresolved.single;

      // UI 查询面(b):可执行上下文 —— 不用翻 server log 就能定位。
      expect(row.entityType, 'budget');
      expect(row.entitySyncId, 'bud-giveup',
          reason: '错误行必须带实体 sync id,便于开发者按它定位脏数据');
      expect(row.errorMessage, contains('budget'),
          reason: '错误文案给出实体类型,可读可诊断');
      expect(row.errorMessage, contains('bud-giveup'),
          reason: '错误文案给出实体 syncId,可读可诊断');
      expect(row.rawChangeJson, contains('bud-giveup'),
          reason: 'rawChangeJson 保留完整 change 供诊断');

      // needs-attention 状态(c):error_class 可机器区分。
      expect(row.errorClass, 'DeferredGiveUp',
          reason: '放弃重放是可机器区分的独立终态,不等于普通 apply 失败;'
              'UI 据此可显示「有 N 条远端变更被跳过」而非泛化错误');
      final giveUps =
          await h.engine.pullErrors.watchUnresolvedDeferredGiveUps().first;
      expect(giveUps, hasLength(1),
          reason: 'HARDENING: distinct needs-attention 查询面可用');

      // 稳定性:后续空轮不得把该错误清掉(旧实现每轮全页 markResolved)。
      await h.engine.pull('${h.ledgerId}');
      expect(await h.engine.pullErrors.watchUnresolved().first, hasLength(1),
          reason: '后续轮次不得误清放弃错误(cursor 已在 4242,不再拉该页)');
      expect(await h.engine.appCursor.read(), 4242);
    });

    test('放弃后不再把整页钉在页首:同页后续 change 不被永久阻塞', () async {
      // 同页:1 条永远依赖失败的 budget + 1 条正常 transaction。
      // 前 10 轮整页推迟(cursor 0);第 11 轮放弃 budget 后,同轮的 tx 必须
      // 落下且 cursor 推进 —— 否则放弃只救了单页里的自己的 change_id,
      // 后续 change 仍被钉死。
      var rounds = 0;
      h.provider.pullResponder = (c, since, limit) {
        if ((since ?? 0) >= 77) return page([], cursor: 77);
        rounds++;
        return page([
          remoteChange(
            changeId: 77,
            entityType: 'budget',
            entitySyncId: 'bud-stuck',
            ledgerId: 'NEVER-LOCAL',
            payload: {'syncId': 'bud-stuck', 'amount': 1.0},
          ),
          remoteChange(
            changeId: 78,
            entitySyncId: 'tx-after-stuck',
            ledgerId: 'L1',
            payload: {
              'syncId': 'tx-after-stuck',
              'type': 'expense',
              'amount': 5.0,
            },
          ),
        ], cursor: 78);
      };

      for (var i = 0; i < 11; i++) {
        await h.engine.pull('${h.ledgerId}');
      }

      final txs = await h.db.select(h.db.transactions).get();
      expect(txs.map((t) => t.syncId), contains('tx-after-stuck'),
          reason: '同页正常 change 必须已落地(放弃不得阻塞同页其它条目)');
      expect(await h.engine.appCursor.read(), 78,
          reason: '活性:放弃后 cursor 推进到页尾');
      final unresolved = await h.engine.pullErrors.watchUnresolved().first;
      expect(unresolved.map((e) => e.changeId), [77]);
      // 不重复写错误:第 11 轮之后不再拉该页,attempt_count 保持 1。
      expect(unresolved.single.attemptCount, 1,
          reason: '放弃只记一次(后续轮不再重复放弃同一 change)');
      expect(rounds, 11, reason: '前 10 轮推迟 + 第 11 轮放弃,共 11 次拉取');
    });

    test('自愈:依赖到达后放弃错误自动 resolve(无需人工清理)', () async {
      h.provider.pullResponder = giveUpPage();
      for (var i = 0; i < 11; i++) {
        await h.engine.pull('${h.ledgerId}');
      }
      expect(await h.engine.pullErrors.watchUnresolved().first, hasLength(1),
          reason: '前置:已放弃 + 错误可见');
      expect(await h.engine.appCursor.read(), 4242);

      // 依赖终于到达:cursor 拨回 0 全量重放(等价 replayAllChanges /
      // 「账本刚从 server 拉到本地」的恢复路径)。budget 的依赖以
      // payload.ledgerSyncId 表达(handler 的解析口径),修正为本地已有的 L1。
      h.provider.pullResponder = (c, since, limit) => page([
            remoteChange(
              changeId: 4242,
              entityType: 'budget',
              entitySyncId: 'bud-giveup',
              ledgerId: 'L1',
              payload: {
                'syncId': 'bud-giveup',
                'amount': 999.0,
                'ledgerSyncId': 'L1',
              },
            ),
          ], cursor: 4242);

      await h.engine.pull('${h.ledgerId}', sinceOverride: 0);

      final budgets = await h.db.select(h.db.budgets).get();
      expect(budgets, hasLength(1), reason: '前置:重放后 budget 真正落地');
      expect(await h.engine.pullErrors.watchUnresolved().first, isEmpty,
          reason: '自愈:change 真正 apply 成功后错误行必须 resolve'
              '(UI 不再显示)');
      final rows = await h.db.select(h.db.syncPullErrors).get();
      expect(rows.single.resolvedAt, isNotNull);
    });

    test('DISPATCH: 放弃集按 pull 轮隔离,不跨轮/跨账本泄漏', () async {
      // _deferredChangeIds 每轮 clear(既定设计),_abandonedDeferredIds 是
      // per-SyncEngine 会话状态 —— 放弃的 change 在任何后续轮的 markResolved
      // 里都不得被误清。用「放弃后大量无关正常页」压这条不变量。
      h.provider.pullResponder = giveUpPage();
      for (var i = 0; i < 11; i++) {
        await h.engine.pull('${h.ledgerId}');
      }
      expect(await h.engine.pullErrors.watchUnresolved().first, hasLength(1));

      // 大量无关正常 pull(cursor 已在 4242 → 空页)。
      for (var i = 0; i < 5; i++) {
        await h.engine.pull('${h.ledgerId}');
      }
      expect(await h.engine.pullErrors.watchUnresolved().first, hasLength(1),
          reason: '无关轮次不得清掉放弃记录');
    });
  });
}
