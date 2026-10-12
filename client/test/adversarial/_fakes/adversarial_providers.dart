// 对抗性测试专用脚手架(只读依赖既有 fake,不修改既有测试/源码)。
//
// 内容:
//   - DeviceAwareProvider:auth.currentUser 带 metadata.deviceId,让
//     SyncEngine._getDeviceId() 返真实 deviceId 而非 'unknown'
//   - ScriptedPullProvider:完全接管 pullChanges 分页响应(游标回退 / 死循环 /
//     畸形 payload / hasMore 恒真等攻击面)
//   - SyncHarness:一句 `await SyncHarness.create()` 拿到 db + tracker + repo +
//     provider + engine + 一个已插好的 ledger,附常用 seed / push 结果构造 helper
//
// 所有扩展都在子类里做,原始 fake 文件保持不动。

import 'package:drift/drift.dart' as d;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/cloud/sync/change_tracker.dart';
import 'package:smartbook/cloud/sync/sync_engine.dart';
import 'package:smartbook/data/db.dart';
import 'package:smartbook/data/repositories/local/local_repository.dart';

import '../../cloud/sync/_fakes/fake_smartbook_cloud_provider.dart';

// =====================================================================
// provider 扩展
// =====================================================================

/// 带 metadata.deviceId 的 auth —— SyncEngine._getDeviceId() 读
/// `currentUser.metadata['deviceId']`;原 fake 的 CloudUser 无 metadata,
/// 导致 deviceId='unknown'。这个子类让「跳过自己设备变更」路径可测。
class DeviceAwareAuthService extends FakeSmartBookCloudAuthService {
  DeviceAwareAuthService({super.userId, super.deviceId});

  @override
  Future<CloudUser?> get currentUser async {
    final uid = currentUserId;
    if (uid == null) return null;
    return CloudUser(
      id: uid,
      metadata: {'deviceId': currentDeviceId ?? 'unknown'},
    );
  }
}

class DeviceAwareProvider extends FakeSmartBookCloudProvider {
  DeviceAwareProvider({String? userId, String? deviceId})
      : _auth = DeviceAwareAuthService(userId: userId, deviceId: deviceId);

  final DeviceAwareAuthService _auth;

  @override
  CloudAuthService get auth => _auth;
}

/// 脚本化 pull 的 provider。
///
/// [pullResponder] 接收 (callIndex 从 1 开始, since, limit),返整页结果;
/// 返 null 表示回落到父类的 in-memory server 逻辑。
///
/// auth 换成 [DeviceAwareAuthService]:`SyncEngine._getDeviceId()` 读
/// `currentUser.metadata['deviceId']`,原 fake 无 metadata 会退化成
/// 'unknown',「跳过自己设备变更」的路径就没法测。
class ScriptedPullProvider extends FakeSmartBookCloudProvider {
  ScriptedPullProvider({
    String? userId = 'test-user-id',
    String? deviceId = 'test-device-id',
  })  : userId = userId,
        deviceId = deviceId,
        // 同时告诉父类(其内部 fake auth),保持行为一致
        super(userId: userId, deviceId: deviceId);

  /// 本 provider 的固定身份(测试断言「自己设备」时用)。
  final String? userId;
  final String? deviceId;

  late final DeviceAwareAuthService _deviceAuth = DeviceAwareAuthService(
    userId: userId,
    deviceId: deviceId,
  );

  @override
  CloudAuthService get auth => _deviceAuth;

  SmartBookCloudPullResult? Function(int callIndex, int? since, int limit)?
      pullResponder;

  /// 按调用序号脚本化 push 结果(1-based)。返 null → 回落 pushResultOverride
  /// / 默认全 accepted。用来构造「第 1 批被拒、第 2 批正常」这类分批场景。
  SmartBookPushResult? Function(int callIndex, List<Map<String, dynamic>> changes)?
      pushResultScript;

  @override
  Future<SmartBookPushResult> pushChanges({
    required List<Map<String, dynamic>> changes,
  }) async {
    final result = await super.pushChanges(changes: changes);
    final script = pushResultScript;
    if (script != null) {
      final scripted = script(pushedBatches.length, changes);
      if (scripted != null) return scripted;
    }
    return result;
  }

  /// 每次 pullChanges 的 (since, limit, persistCursor) 记录(含探针调用)。
  final List<({int? since, int limit, bool persistCursor})> scriptedPullCalls =
      [];

  int get pullCallCount => scriptedPullCalls.length;

  @override
  Future<SmartBookCloudPullResult> pullChanges({
    int? since,
    int limit = 1000,
    bool persistCursor = true,
  }) async {
    scriptedPullCalls
        .add((since: since, limit: limit, persistCursor: persistCursor));
    final responder = pullResponder;
    if (responder != null) {
      final scripted = responder(scriptedPullCalls.length, since, limit);
      if (scripted != null) return scripted;
    }
    return super.pullChanges(
      since: since,
      limit: limit,
      persistCursor: persistCursor,
    );
  }
}

// =====================================================================
// change / page 构造
// =====================================================================

/// 构造一条远端 change(默认来自别的设备,不会被本机 deviceId 跳过)。
SmartBookCloudSyncChange remoteChange({
  required int changeId,
  String entityType = 'transaction',
  required String entitySyncId,
  String ledgerId = '',
  String action = 'upsert',
  Map<String, dynamic>? payload,
  String? updatedByDeviceId = 'remote-device',
}) {
  return SmartBookCloudSyncChange(
    changeId: changeId,
    ledgerId: ledgerId,
    entityType: entityType,
    entitySyncId: entitySyncId,
    action: action,
    updatedByDeviceId: updatedByDeviceId,
    updatedAt: '2026-05-24T10:00:00Z',
    payload: payload,
  );
}

/// 一页 pull 结果。
SmartBookCloudPullResult page(
  List<SmartBookCloudSyncChange> changes, {
  required int cursor,
  bool hasMore = false,
}) {
  return SmartBookCloudPullResult(
    changes: changes,
    serverCursor: cursor,
    hasMore: hasMore,
  );
}

/// 全 accepted 的 push 结果。
const SmartBookPushResult acceptedAll = SmartBookPushResult(
  accepted: 0,
  rejected: 0,
  conflictCount: 0,
  conflictSamples: [],
  failedCount: 0,
  failedSamples: [],
  serverCursor: 0,
);

/// 服务端点名拒绝 N 条(LWW 判负)的结果。
SmartBookPushResult rejectNamed(List<String> syncIds) {
  return SmartBookPushResult(
    accepted: 0,
    rejected: syncIds.length,
    conflictCount: syncIds.length,
    conflictSamples: [
      for (final s in syncIds)
        {'reason': 'lww_rejected_older_change', 'entitySyncId': s},
    ],
    failedCount: 0,
    failedSamples: const [],
    serverCursor: 0,
  );
}

/// 服务端点名拒绝 N 条(apply 失败 / poison)的结果。
SmartBookPushResult rejectFailed(List<String> syncIds) {
  return SmartBookPushResult(
    accepted: 0,
    rejected: syncIds.length,
    conflictCount: 0,
    conflictSamples: const [],
    failedCount: syncIds.length,
    failedSamples: [
      for (final s in syncIds)
        {'reason': 'apply_failed', 'entitySyncId': s},
    ],
    serverCursor: 0,
  );
}

/// 服务端只报 rejected 计数、不带任何样本(server push.py:305 / 413 两条
/// 只 `rejected += 1` 的分支)。
SmartBookPushResult rejectCountOnly(int count) {
  return SmartBookPushResult(
    accepted: 0,
    rejected: count,
    conflictCount: 0,
    conflictSamples: const [],
    failedCount: 0,
    failedSamples: const [],
    serverCursor: 0,
  );
}

/// 计数 > 样本数(B1:conflict/failed samples 各截断 20)。
SmartBookPushResult rejectTruncated({
  required int reportedCount,
  required List<String> samples,
}) {
  return SmartBookPushResult(
    accepted: 0,
    rejected: reportedCount,
    conflictCount: reportedCount,
    conflictSamples: [
      for (final s in samples)
        {'reason': 'lww_rejected_older_change', 'entitySyncId': s},
    ],
    failedCount: 0,
    failedSamples: const [],
    serverCursor: 0,
  );
}

// =====================================================================
// harness
// =====================================================================

/// 一句 create() 拿到全部依赖 + 一个已插好的 ledger。
class SyncHarness {
  SyncHarness._({
    required this.db,
    required this.changeTracker,
    required this.repo,
    required this.provider,
    required this.engine,
    required this.ledgerId,
    required this.ledgerSyncId,
  });

  final BeeDatabase db;
  final ChangeTracker changeTracker;
  final LocalRepository repo;
  final ScriptedPullProvider provider;
  final SyncEngine engine;
  final int ledgerId;
  final String ledgerSyncId;

  /// [userId]/[deviceId] 决定 auth 身份;[ledgerSyncId] 是本账本的跨设备 id。
  static Future<SyncHarness> create({
    String ledgerSyncId = 'L1',
    String ledgerName = 'L',
    String userId = 'test-user-id',
    String deviceId = 'test-device-id',
    bool seedLedger = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final tracker = ChangeTracker(db);
    final repo = LocalRepository(db, changeTracker: tracker);
    final provider = ScriptedPullProvider(userId: userId, deviceId: deviceId);
    final engine = SyncEngine(
      db: db,
      provider: provider,
      changeTracker: tracker,
      repo: repo,
    );
    var ledgerId = 0;
    if (seedLedger) {
      ledgerId = await db.into(db.ledgers).insert(LedgersCompanion.insert(
            name: ledgerName,
            syncId: Value(ledgerSyncId),
          ));
    }
    return SyncHarness._(
      db: db,
      changeTracker: tracker,
      repo: repo,
      provider: provider,
      engine: engine,
      ledgerId: ledgerId,
      ledgerSyncId: ledgerSyncId,
    );
  }

  Future<void> close() async {
    provider.reset();
    await db.close();
  }

  // ---------- seed ----------

  /// 直插一条 transaction(不经 repo,不自动登记 change)。
  Future<int> seedTx({
    required String syncId,
    double amount = 10.0,
    int? inLedgerId,
    String type = 'expense',
    DateTime? happenedAt,
    String? note,
    int? categoryId,
    int? accountId,
    String? currencyCode,
    double? nativeAmount,
  }) {
    return db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: inLedgerId ?? ledgerId,
          type: type,
          amount: amount,
          happenedAt: happenedAt != null ? Value(happenedAt) : const Value.absent(),
          note: Value(note),
          categoryId: Value(categoryId),
          accountId: Value(accountId),
          currencyCode: Value(currencyCode),
          nativeAmount: Value(nativeAmount),
          syncId: Value(syncId),
        ));
  }

  Future<int> seedAccount({
    required String syncId,
    String name = 'Cash',
    String currency = 'CNY',
    double initialBalance = 0.0,
  }) {
    return db.into(db.accounts).insert(AccountsCompanion.insert(
          ledgerId: ledgerId,
          name: name,
          currency: Value(currency),
          initialBalance: Value(initialBalance),
          syncId: Value(syncId),
        ));
  }

  Future<int> seedCategory({
    required String syncId,
    String name = 'Food',
    String kind = 'expense',
    int level = 1,
    int? parentId,
  }) {
    return db.into(db.categories).insert(CategoriesCompanion.insert(
          name: name,
          kind: kind,
          level: Value(level),
          parentId: Value(parentId),
          syncId: Value(syncId),
        ));
  }

  Future<int> seedTag({required String syncId, String name = 'Tag'}) {
    return db.into(db.tags).insert(TagsCompanion.insert(
          name: name,
          syncId: Value(syncId),
        ));
  }

  Future<int> seedBudget({
    required String syncId,
    double amount = 100.0,
    int? inLedgerId,
  }) {
    return db.into(db.budgets).insert(BudgetsCompanion.insert(
          ledgerId: inLedgerId ?? ledgerId,
          amount: amount,
          syncId: Value(syncId),
        ));
  }

  Future<int> seedExchangeRateOverride({
    required String syncId,
    String base = 'CNY',
    String quote = 'USD',
    String rate = '7.1',
    DateTime? updatedAt,
  }) {
    return db.into(db.exchangeRateOverrides).insert(
        ExchangeRateOverridesCompanion.insert(
          baseCurrency: base,
          quoteCurrency: quote,
          rate: rate,
          syncId: Value(syncId),
          updatedAt: Value(updatedAt),
        ));
  }

  // ---------- change 登记 ----------

  /// 登记一条 ledger-scope change。
  Future<void> recordChange({
    required String entityType,
    required int entityId,
    required String entitySyncId,
    String action = 'create',
    int? inLedgerId,
  }) {
    return changeTracker.recordLedgerChange(
      entityType: entityType,
      entityId: entityId,
      entitySyncId: entitySyncId,
      ledgerId: inLedgerId ?? ledgerId,
      action: action,
    );
  }

  /// 登记一条 user-global change(account / category / tag)。
  Future<void> recordUserGlobalChange({
    required String entityType,
    required int entityId,
    required String entitySyncId,
    String action = 'create',
  }) {
    return changeTracker.recordUserGlobalChange(
      entityType: entityType,
      entityId: entityId,
      entitySyncId: entitySyncId,
      action: action,
    );
  }

  /// 插一个实体行 + 登记 [changeRows] 条 change(模拟同一实体多次编辑)。
  Future<int> seedEntityWithChanges(
    String syncId,
    int changeRows, {
    double amount = 10.0,
  }) async {
    final txId = await seedTx(syncId: syncId, amount: amount);
    for (var i = 0; i < changeRows; i++) {
      await recordChange(
        entityType: 'transaction',
        entityId: txId,
        entitySyncId: syncId,
        action: i == 0 ? 'create' : 'update',
      );
    }
    return txId;
  }

  // ---------- 读取 ----------

  /// 登记一条 ledger-scope change 并立刻 markPushed。
  Future<int> recordAndMark({required String syncId, String action = 'create'}) async {
    await recordChange(
      entityType: 'transaction',
      entityId: 1,
      entitySyncId: syncId,
      action: action,
    );
    final id = (await unpushedForLedger()).single.id;
    await changeTracker.markPushed([id]);
    return id;
  }

  /// 登记一条 user-global change 并立刻 markPushed。
  Future<int> recordUserGlobalAndMark({
    required String syncId,
    String action = 'create',
  }) async {
    await recordUserGlobalChange(
      entityType: 'account',
      entityId: 1,
      entitySyncId: syncId,
      action: action,
    );
    final id = (await unpushedGlobal()).single.id;
    await changeTracker.markPushed([id]);
    return id;
  }

  /// 把某条 change 的 pushedAt 精确设成给定时刻(测 cleanup 边界用)。
  Future<void> setPushedAt(int changeId, DateTime at) async {
    await (db.update(db.localChanges)..where((c) => c.id.equals(changeId)))
        .write(LocalChangesCompanion(pushedAt: d.Value(at)));
  }

  Future<List<LocalChange>> unpushedForLedger([int? id]) =>
      changeTracker.getUnpushedChangesForLedger(id ?? ledgerId);

  Future<List<LocalChange>> unpushedGlobal() =>
      changeTracker.getUnpushedChangesForLedger(0);

  Future<int> unpushedCount([int? id]) =>
      changeTracker.getUnpushedCountForLedger(id ?? ledgerId);

  Future<List<String>> pushedEntitySyncIds() async {
    final out = <String>[];
    for (final batch in provider.pushedBatches) {
      for (final c in batch) {
        out.add(c['entity_sync_id'] as String);
      }
    }
    return out;
  }

  /// 所有已推送过的 representative 的 (entityType, entitySyncId)。
  Future<Set<String>> pushedKeys() async {
    final out = <String>{};
    for (final batch in provider.pushedBatches) {
      for (final c in batch) {
        out.add('${c['entity_type']}|${c['entity_sync_id']}');
      }
    }
    return out;
  }

  /// 服务端收到的某条 change 的完整 envelope。
  Map<String, dynamic>? sentEnvelope(String entitySyncId) {
    for (final batch in provider.pushedBatches) {
      for (final c in batch) {
        if (c['entity_sync_id'] == entitySyncId) return c;
      }
    }
    return null;
  }
}
