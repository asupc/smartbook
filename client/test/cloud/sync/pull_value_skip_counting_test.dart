/// 中-2(2026-10-11 三轮复查)回归:pull 的 applied 计数不再把值跳过行算成
/// applied。
///
/// 旧行为:`applyRemoteChange` 对 transaction/account/budget/account_adjustment
/// 的 case handler 无条件 `return true`,即使 `_skipPulledTxIfInvalid` /
/// `_skipPulledMoneyIfInvalid` 已登记值跳过 → 行没落库但 `pull()` 返回 1、
/// 日志报 "applied 1/1"、skipped 恒 0 —— 计数与事实相反。
///
/// 修复:值跳过命中 → 返回 false → [_applyPullPage] 计入 skipped。本文件锁定:
///   1. Infinity payload → pull() 返回 0(applied=0),行不落库;
///   2. 好行照常 applied(1 好 + 1 坏 → 返回 1);
///   3. cursor 推进 / PulledValueSkipped 错误行行为不变(那些原本就正确)。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
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

  test('transaction amount=Infinity → applied=0(计 skipped),行不落库', () async {
    provider.pushFakeChange(
      entitySyncId: 'tx-inf',
      ledgerId: 'L1',
      payload: {
        'syncId': 'tx-inf',
        'type': 'expense',
        'amount': 1e400, // JSON 数字字面量 → Infinity
      },
    );

    final applied = await engine.pull(ledgerId.toString());

    expect(applied, 0,
        reason: '中-2:值跳过行计入 skipped,pull() 的 applied 返回 0');
    expect(await db.select(db.transactions).get(), isEmpty,
        reason: '行未落库(缺陷 F 既有行为保持)');
  });

  test('1 坏 + 1 好同页 → applied=1(只数好行)', () async {
    provider.pushFakeChange(
      entitySyncId: 'tx-inf2',
      ledgerId: 'L1',
      payload: {
        'syncId': 'tx-inf2',
        'type': 'expense',
        'amount': 1e400,
      },
    );
    provider.pushFakeChange(
      entitySyncId: 'tx-good',
      ledgerId: 'L1',
      payload: {
        'syncId': 'tx-good',
        'type': 'expense',
        'amount': 42.0,
      },
    );

    final applied = await engine.pull(ledgerId.toString());

    expect(applied, 1, reason: '只有 tx-good 计入 applied');
    final rows = await db.select(db.transactions).get();
    expect(rows, hasLength(1));
    expect(rows.single.syncId, 'tx-good');
  });

  test('account initialBalance=Infinity → applied=0(账户侧同口径)', () async {
    provider.pushFakeChange(
      entityType: 'account',
      entitySyncId: 'acc-inf',
      payload: {
        'syncId': 'acc-inf',
        'name': 'INF',
        'initialBalance': 1e400,
      },
    );

    final applied = await engine.pull('');

    expect(applied, 0, reason: '中-2:account 值跳过同样计 skipped');
    expect(await db.select(db.accounts).get(), isEmpty);
  });

  test('cursor 推进 + PulledValueSkipped 错误行保持(既有正确行为不回归)',
      () async {
    provider.pushFakeChange(
      entitySyncId: 'tx-inf3',
      ledgerId: 'L1',
      payload: {
        'syncId': 'tx-inf3',
        'type': 'expense',
        'amount': 1e400,
      },
    );

    await engine.pull(ledgerId.toString());

    expect(await engine.appCursor.read(), 1,
        reason: 'cursor 照常推进(值跳过不 defer,否则整页卡死)');
    final errs = await engine.pullErrors.watchUnresolved().first;
    expect(errs, hasLength(1));
    expect(errs.single.errorClass, 'PulledValueSkipped');
    expect(errs.single.changeId, 1);
  });

  test('正常远端交易 → applied=1(计数面不误伤)', () async {
    provider.pushFakeChange(
      entitySyncId: 'tx-ok',
      ledgerId: 'L1',
      payload: {
        'syncId': 'tx-ok',
        'type': 'expense',
        'amount': 5.0,
      },
    );

    final applied = await engine.pull(ledgerId.toString());

    expect(applied, 1);
    expect(await db.select(db.transactions).get(), hasLength(1));
  });
}
