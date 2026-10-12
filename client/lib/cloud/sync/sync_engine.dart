import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' as d;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../ai/providers/ai_provider_manager.dart';
import '../../data/db.dart';
import '../../data/repositories/base_repository.dart';
import '../../data/repositories/local/chunk_utils.dart';
import '../../services/custom_icon_service.dart';
import '../../services/data_import_service.dart';
import '../../services/system/logger_service.dart';
import '../../services/ui/avatar_service.dart';
import '../sync_service.dart' as app;
import '../transactions_json.dart';
import 'change_tracker.dart';
import 'entity_serializer.dart';
import 'sync_events.dart';
export 'sync_events.dart';

// SyncEngine 按职责拆分到多个 part 文件,共享同一 library:
// - sync_engine_attachments.dart: 附件上传 / 下载 / 本地清理 / 分类图标上传(并发 + retry)
// - sync_engine_resolvers.dart:   跨设备 ID 解析(syncId ↔ 本地 int id)
// - sync_engine_status.dart:      健康检查 + 历史种子数据补登
// - sync_engine_realtime.dart:    WS 事件监听 + auto sync / pull 防抖调度
// - sync_engine_profile.dart:     profile + avatar 同步(theme/income/appearance/ai)
// - sync_engine_apply.dart:       pull 路径远端变更 → 本地 Drift apply(6 种 entityType)
// - sync_engine_serialization.dart: push 路径本地实体 → server payload 序列化 + fullPush
// - sync_engine_pull.dart:        pull 路径错误恢复 — AppCursorStore + SyncErrorStore
//                                 (cursor 安全 + 失败 change 持久化暴露给 UI)
part 'sync_engine_attachments.dart';
part 'sync_engine_resolvers.dart';
part 'sync_engine_status.dart';
part 'sync_engine_realtime.dart';
part 'sync_engine_profile.dart';
part 'sync_engine_apply.dart';
part 'sync_engine_serialization.dart';
part 'sync_engine_pull.dart';

const _uuid = Uuid();

/// 同步结果
class SyncResult {
  final int pushed;
  final int pulled;
  final int conflicts;
  final String? error;

  const SyncResult({
    this.pushed = 0,
    this.pulled = 0,
    this.conflicts = 0,
    this.error,
  });

  bool get hasError => error != null;

  @override
  String toString() =>
      'SyncResult(pushed=$pushed, pulled=$pulled, conflicts=$conflicts${error != null ? ', error=$error' : ''})';
}

/// 同步状态
enum SyncEngineStatus { idle, pushing, pulling, syncing, error }

/// 核心同步编排器 — 实现 SyncService 接口
/// 负责 push 本地变更到服务端、pull 远程变更到本地
class SyncEngine implements app.SyncService {
  final BeeDatabase db;
  final SmartBookCloudProvider provider;
  final ChangeTracker changeTracker;
  final BaseRepository repo;

  /// 状态缓存
  final Map<int, app.SyncStatus> _statusCache = {};
  bool _localChanged = false;

  /// 批次3(2026-09-10):最近一次 push 被服务端拒绝的计数(LWW 冲突 + poison
  /// apply 失败)。sync() 返回时并入 SyncResult.conflicts,UI 据此提示
  /// 「X 条修改被服务端版本覆盖」。null = 最近一次 push 无拒绝。
  ({int conflict, int failed, DateTime at})? _lastPushConflicts;

  /// 附录 B3(2026-09-15):被拒 change 的重推熔断。
  ///
  /// 旧行为:被拒 change 不 markPushed,留在 local_changes 被每次 push 无限
  /// 重推 —— 服务端配套每条冲突写一条 AuditLog(无节流),重推循环双向放大。
  /// 现在:按 (entityType, entitySyncId) 计数,同一代表条(以 change id 标识,
  /// 用户再次编辑会产生新 change、计数重置)被拒 [maxPushRejectAttempts]
  /// 次后熔断 —— 本进程会话内不再推它,change 保留在 local_changes
  /// (unpushed 计数仍可见,不静默丢失)。
  ///
  /// 仅内存态:进程重启后每个实体重新获得 N 次机会(服务端可能已修好);
  /// 实体之后推送成功时计数清除。UI 暴露(同步页展示被熔断实体)可后置。
  ///
  /// **P-02(2026-10-11)可逆性修复**:熔断必须对新 change id 可穿透 —— 用户
  /// 新编辑产生新代表条(rep.id 变大)时重置计数、放行一次。同时加**超时
  /// 衰减**:熔断后 [pushRejectProbeInterval] 内不再推,之后放行**一次**
  /// 探测(服务端可能已修好 / 数据已从别处对齐),避免"会话内永久死锁"。
  static const int maxPushRejectAttempts = 8;

  /// 熔断后最长静默期。超过它 → 放行一次探测(probe),探测被拒则重新计时。
  ///
  /// 30 min 的取舍:被拒 change 的典型修复路径(服务端修数据 / 用户在 web
  /// 改回)不是秒级操作,但"用户手动点同步 + 等半分钟"也不该永远看不到反应。
  static const Duration pushRejectProbeInterval = Duration(minutes: 30);

  final Map<String, ({int repChangeId, int rejects, bool tripped, DateTime at})>
      _pushRejectState = {};

  String _pushRejectKey(String entityType, String entitySyncId) =>
      '$entityType\u0000$entitySyncId';

  /// WebSocket 实时监听
  StreamSubscription<SmartBookCloudRealtimeEvent>? _realtimeSubscription;
  Timer? _pullDebounce;

  /// 当前正在自动拉取的 ledgerId（防止重复触发）
  bool _autoPulling = false;

  /// 当前是否在执行 WS 重连触发的自动 sync（push+pull），防止 ws reconnect
  /// 和 connectivity 恢复几乎同时命中时重复 sync。
  bool _autoSyncing = false;
  Timer? _autoSyncDebounce;

  /// 外部注入:当前活跃 ledgerId 的解析器。WS 重连 / 网络恢复 时需要知道
  /// 往哪个 ledger 触发 sync,但 SyncEngine 内部不挂 Riverpod ref,所以让
  /// sync_providers 构造完之后塞一个函数进来。返回 0 / null 会跳过本次 sync。
  ///
  /// 这是 SyncEngine 唯一保留的反向"UI → engine"读通道(因为 sync 触发时机
  /// 在 engine 内部,需要主动读当前 ledger)。所有正向"engine → UI"通知都
  /// 走 [events] stream。
  String Function()? ledgerIdResolver;

  /// 对外广播事件总线 — UI 通过 Riverpod `syncEventStreamProvider` 订阅,
  /// SyncEngine 完全不知道 widget / ref 存在。
  ///
  /// **sync: true 关键**:默认 broadcast 是 async 模式,`_emit` 调 `add` 后
  /// listener 要延迟到下个 microtask 才跑。这跟 PR3 之前直接 `onXxx?.call(...)`
  /// 的同步语义不一致 —— 多次 `_emit` 会触发多次独立 microtask,Flutter 有
  /// 机会在两次 listener 之间 schedule rebuild,导致 state 变更分散到多帧,
  /// 视觉上看到首页"刷一次又刷一次"。sync: true 让 add 同步调 listener,跟
  /// 原 callback 行为完全等价,多次 emit 内的 state 变更在同一同步代码段内
  /// batch 成一帧 rebuild。
  final StreamController<SyncEvent> _eventsController =
      StreamController<SyncEvent>.broadcast(sync: true);

  /// 订阅 sync 事件。
  Stream<SyncEvent> get events => _eventsController.stream;

  /// 内部 helper:emit 新事件到 stream。
  void _emit(SyncEvent event) {
    if (!_eventsController.isClosed) {
      _eventsController.add(event);
    }
  }

  /// app 侧 cursor + pull 失败 change 持久化的 DAO。
  /// 详见 [AppCursorStore] / [SyncErrorStore](sync_engine_pull.dart)。
  late final AppCursorStore appCursor;
  late final SyncErrorStore pullErrors;

  /// 自定义分类图标下载队列。`_applyCategoryChange` 在主事务内 enqueue,
  /// `pull` 在事务 commit 之后调 [drainCustomIconQueue] 并发处理。详见
  /// [CustomIconDownloadJob](sync_engine_pull.dart) 和
  /// [drainCustomIconQueue](sync_engine_attachments.dart)。
  final List<CustomIconDownloadJob> pendingCustomIconJobs = [];

  /// pull 期间生效的 [LookupCache]。pull 入口 new + prime,pull 结束清 null。
  /// resolvers 路径(`sync_engine_resolvers.dart`)优先查它,消除 N+1 SELECT。
  /// 详见 [LookupCache](sync_engine_pull.dart)。
  LookupCache? activePullCache;

  /// U-08(2026-10-11):本页"依赖未就绪、必须重放"的 change_id 集合。
  ///
  /// apply handler 只能返回 bool(true=已应用 / false=跳过),无法表达"跳过
  /// 但**必须重放**"的第三种语义。budget / account_adjustment(以及账本解析
  /// 不出的 transaction)在 `ledgerSyncId` 解析不到本地账本时属于这种:现在
  /// 跳过,等 ledger change 到达后还要回来,所以它的 change_id **绝不能落到
  /// cursor 之后**。
  ///
  /// 实现:handler 跳过时把 `change.changeId` 登记进这个集合,
  /// [_applyPullPage] 看到命中即计入 deferred → [_runPullLoop] 本页不 commit
  /// cursor。集合的生命周期 = 单个 pull(入口 clear),不给跨轮泄漏留下状态。
  /// 用 change_id 而非 entitySyncId 做键:同页内同实体出现两次(upsert→delete)
  /// 时不会把一个正常落地的 change 误算成 deferred。
  final Set<int> _deferredChangeIds = {};

  /// 缺陷 A(2026-10-11 复现缺陷修复):本 pull 轮"值不可用被跳过"的 change。
  ///
  /// `_skipPulledTxIfInvalid` / `_skipPulledMoneyIfInvalid` 命中(远端非有限
  /// 金额等)时登记这里,**不再只写一行 warning** —— [_applyPullPage] 在页事务
  /// commit 之后把这些条目写进 [pullErrors](`error_class = PulledValueSkipped`,
  /// 强制 `resolved_at = NULL`),并从本页 [resolveChangeIds] 中排除,使其在
  /// `watchUnresolved()`(UI 面)可见。
  ///
  /// 为什么必须持久化:值跳过的 change **cursor 照常推进**(必须如此,否则
  /// 这条坏 change 每轮重放、整页 apply 永远卡死)。这不抛错的代价是它的
  /// change_id 落到 cursor 之后,**下一轮 pull 再也不会返回它** —— 若没有这条
  /// 持久记录,该远端变更就永久静默消失,只有 48h 保留的日志里一行 warning。
  /// 登记后它是"未解决、UI 可见"的事实状态,直到真正 apply 成功
  /// (服务端修数据 / 全量重放)才被 [SyncErrorStore.markResolved] 自愈。
  ///
  /// 生命周期:与 [_deferredChangeIds] 一样按 pull 轮隔离([_doPull] 入口 clear)
  /// —— 页事务 rollback 时 [_applyPullPage] 会把本页新增的登记回滚掉,判定不会
  /// 残留到下一轮。
  final Map<int, ({SmartBookCloudSyncChange change, String reason})>
      _valueSkips = {};

  /// U-08 的**活性安全阀**:同一条 change 连续被推迟多少次后放弃等待。
  ///
  /// 推迟的前提是"依赖(=ledger change)即将到达"。同一页通常下一次 pull 就
  /// 自愈(页内所有 change 都已 apply,只是 cursor 没走,重放即命中)。但若依赖
  /// 永远不到(引用了一个本设备永远拿不到的账本 —— 服务端路由 / 用户已退出
  /// 共享账本 / 脏 ledgerSyncId),无上限推迟会让**整台设备**的 pull 永久停在
  /// 一页上:后面的所有变更都同步不下来,比原来的"静默丢一条"更糟。
  ///
  /// 阈值 10 的取舍:正常乱序(依赖在后一页 / 同页之后)最多 1-2 次重放就解决,
  /// 10 次给了充足余量;真到 10 次说明依赖不会来了,此时把该 change 记入
  /// [pullErrors](UI 可见、不静默)并放行 cursor —— 与 SyncErrorStore 的既有
  /// 设计意图一致(脏 change 由服务端修数据后推新 change 覆盖)。
  ///
  /// **放弃 = 可观测的终态(2026-10-11 复现缺陷修复)**:旧实现是"在 `_applyPullPage`
  /// 内写 [pullErrors] → 本轮 commit → `_runPullLoop` 的 markResolved 循环把同一
  /// 个 change_id 立刻 resolve" —— 错误行落库即死,`watchUnresolved()` 永远看不到,
  /// "recorded in pullErrors, UI-visible" 的承诺不成立。现在:
  /// 1. 放弃判定与错误行在页事务 commit **之后**才落定(`_applyPullPage`),
  ///    且错误行强制 `resolved_at = NULL`(`SyncErrorStore.recordDeferredGiveUp`);
  /// 2. `_runPullLoop` 的 markResolved 循环只清 [resolveChangeIds](本轮未登记
  ///    deferred 的 id)—— 放弃 / 仍推迟的 change_id 天然跳过,错误行存活于
  ///    `watchUnresolved()`;
  /// 3. 放弃的 change_id 进 [_abandonedDeferredIds],本会话内不再被当作 deferred
  ///    (游标不再被它卡住),也不会被后续轮的 markResolved 误清 —— 直到它真正
  ///    apply 成功(依赖终于到达)才自愈 resolve。
  static const int maxDeferredReplays = 10;

  /// 各 deferred change 已被推迟的轮次(仅内存,per SyncEngine 实例)。
  final Map<int, int> _deferredReplays = {};

  /// 已经"判定依赖不会到达、放弃重放"的 change_id(仅内存,per SyncEngine 实例)。
  ///
  /// 语义:
  /// - 命中 → 该 change 不再计入 deferred(否则兄弟条目会把它继续钉在页首,
  ///   每轮重复放弃、重复写错误);
  /// - `_runPullLoop` 的 markResolved 循环**不会**清这个集合里的 id —— 放弃的
  ///   change 没有落地,其错误行必须在 `watchUnresolved()` 里存活到真正 apply
  ///   成功([_PullPageOutcome.resolveChangeIds] 只收未登记 deferred 的 id);
  /// - 同一条 change 之后真的 apply 成功(依赖到达 / replayAllChanges)→ 从集合
  ///   移除 → 该轮 markResolved 把错误 resolve(自愈,无需人工清理)。
  final Set<int> _abandonedDeferredIds = {};

  /// push / fullPush 的 in-flight 单飞锁。**per-ledger** —— 不同 ledger
  /// 并发不互相阻塞,只阻塞同 ledger 的并发触发。
  ///
  /// 背景:app 启动期 `_triggerInitialCloudSync` 由 microtask + listenManual
  /// 双入口触发,曾经导致同设备 2-3 路 fullPush 并发,服务端 sync_changes
  /// 表 2-2.5x 膨胀。详见 `.docs/concurrent-fullpush-bloat.md`。
  ///
  /// `_pushInFlight` key 用 String(跟 [push] 入参一致),`_fullPushInFlight`
  /// 用 int(跟 [fullPush] 入参一致)。
  final Map<String, Completer<int>> _pushInFlight = {};
  final Map<int, Completer<void>> _fullPushInFlight = {};

  /// user-global 实体(account/category/tag)推送的**全局**单飞锁。
  ///
  /// 用户多账本场景下,Phase 2 并发跑多个 `_push(ledgerN)` / `fullPush(ledgerN)`,
  /// 每个 caller 各自读 user-global unpushed change → 都 push 一份 → server
  /// sync_changes 表里 user-global 实体按 ledger 数倍数膨胀(已观察到 4 账本
  /// 用户的 account/category/tag 4x 膨胀)。
  ///
  /// 解法:所有 push 路径都先 `await pushUserGlobalEntities()`,**单飞**保证
  /// 全 session 只跑一次 user-global push,后续 caller 复用第一个的 future,
  /// 拿到的时候 ChangeTracker 已经 markPushed,再各自处理 ledger-scoped 部分。
  Completer<void>? _userGlobalPushInFlight;

  /// fullPull 的 in-flight 单飞锁。**per-ledger**,跟 fullPush 同款。
  ///
  /// 防御性:用户连点"下载"按钮时,避免两次并发 fullPull 重复下载同一份 JSON
  /// snapshot + 重复 apply。apply 路径是 idempotent upsert(同 syncId 不会插
  /// 重复行),所以不会数据膨胀,但浪费带宽 + CPU。
  ///
  /// 跟 fullPush 不同:**不会**真的把多账本并发拉成 N 倍 —— fullPull 只在用户
  /// 点"下载"时触发,正常单次调用;这个锁是给"快速连点"等边界场景兜底。
  final Map<int, Completer<({int inserted, int deletedDup})>>
      _fullPullInFlight = {};

  /// legacy 数据补 ChangeTracker 记录的一次性 flag。
  ///
  /// 历史:v19 migration 给老 account/category/tag 回填了 syncId,但**没在
  /// local_changes 表里登记对应的 create change**。如果某用户跨过 v19→v27 都
  /// 没开过云同步,后面 fullPush 走 ChangeTracker 驱动就拿不到这些 legacy 实
  /// 体 → 数据丢失。
  ///
  /// 解法:每个 session 第一次跑 `pushUserGlobalEntities` 时扫一遍 DB,给
  /// `local_changes` 里没记录的 user-global 实体补一条 upsert change,后续
  /// 正常走 ChangeTracker 流程。flag 持久存在 SyncEngine 实例上(per-session),
  /// 实例重建时(冷启)再跑一次,代价是一次轻量 SELECT。
  bool _userGlobalLegacyBackfilled = false;

  SyncEngine({
    required this.db,
    required this.provider,
    required this.changeTracker,
    required this.repo,
  }) {
    appCursor = AppCursorStore(provider);
    pullErrors = SyncErrorStore(db);
  }

  // ==================== SyncService 接口实现 ====================

  @override
  Future<void> uploadCurrentLedger({required int ledgerId}) async {
    logger.info('SyncEngine', '上传账本 ledger=$ledgerId');

    // 用户主动点"上传"永远只做增量：用 server 的 entity diff log 把本地未推
    // 送的 changes 推上去，绝不触发 fullPush。
    //
    // 原因：fullPush 会把本地当前 ledger 的 JSON 快照整体覆盖到 server 的
    // snapshot（path = ledger.syncId），一旦本地不是"完整权威版本"（比如
    // B 刚登录、bootstrap pull 还没跑完 / 跑了但漏了几条、多设备期间某条
    // 交易延迟到达），web 立刻就看到"剩几条"的残缺快照 —— 这是典型的
    // "覆盖丢数据"场景。
    //
    // 即使一次 fullPush 之后后续 pull 再回灌也不行：snapshot 是权威源，
    // sync_changes 只是 diff，web 端读的是 snapshot。
    //
    // 增量 push 只推 changeTracker 登记过的本地操作，不会把没 own 的数据
    // 误推回去，所以是安全的。本地没变更时直接返回，不需要 fallback。
    final pushed = await push(ledgerId.toString());
    logger.info('SyncEngine', '上传账本完成：增量推送 $pushed 条变更');

    _statusCache.remove(ledgerId);
    _localChanged = false;
  }

  @override
  Future<({int inserted, int deletedDup})> downloadAndRestoreToCurrentLedger(
      {required int ledgerId}) async {
    logger.info('SyncEngine', '下载并恢复账本 ledger=$ledgerId');

    // 先尝试增量拉取
    final pulled = await pull(ledgerId.toString());
    if (pulled > 0) {
      _statusCache.remove(ledgerId);
      return (inserted: pulled, deletedDup: 0);
    }

    // 增量拉取无数据，尝试全量拉取
    final result = await runFullPull(ledgerId: ledgerId);
    _statusCache.remove(ledgerId);
    return result;
  }

  @override
  Future<app.SyncStatus> getStatus({required int ledgerId}) async {
    // 返回缓存（如果有且未标记变更）
    if (!_localChanged && _statusCache.containsKey(ledgerId)) {
      return _statusCache[ledgerId]!;
    }

    try {
      final user = await provider.auth.currentUser;
      if (user == null) {
        return const app.SyncStatus(
          diff: app.SyncDiff.notLoggedIn,
          localCount: 0,
          localFingerprint: '',
        );
      }

      // 本地交易数(零风险快修:COUNT 替代全表物化取 .length)
      final localCountRow = await db.customSelect(
        'SELECT COUNT(*) AS c FROM transactions WHERE ledger_id = ?1',
        variables: [d.Variable.withInt(ledgerId)],
        readsFrom: {db.transactions},
      ).getSingle();
      final localCountV = localCountRow.data['c'];
      final localCount =
          localCountV is num ? localCountV.toInt() : 0;

      // 检查是否有未推送的本地变更(零风险快修:COUNT 版)
      final unpushedCount =
          await changeTracker.getUnpushedCountForLedger(ledgerId);

      // 检查云端是否有数据。path 用 ledger.syncId 跟 push 侧保持一致。
      final ledgerRowStatus = await (db.select(db.ledgers)
            ..where((l) => l.id.equals(ledgerId)))
          .getSingleOrNull();
      final hasRemote = await provider.storage.exists(
        path: ledgerRowStatus?.syncId ?? ledgerId.toString(),
      );

      app.SyncDiff diff;
      if (!hasRemote && localCount == 0) {
        diff = app.SyncDiff.noRemote;
      } else if (!hasRemote) {
        diff = app.SyncDiff.localNewer; // 本地有数据，云端没有
      } else if (unpushedCount > 0) {
        diff = app.SyncDiff.localNewer;
      } else {
        diff = app.SyncDiff.inSync;
      }

      final status = app.SyncStatus(
        diff: diff,
        localCount: localCount,
        localFingerprint: unpushedCount > 0 ? 'has_changes' : 'synced',
      );
      _statusCache[ledgerId] = status;
      _localChanged = false;
      return status;
    } catch (e, st) {
      logger.error('SyncEngine', '获取同步状态失败', e, st);
      return app.SyncStatus(
        diff: app.SyncDiff.error,
        localCount: 0,
        localFingerprint: '',
        message: e.toString(),
      );
    }
  }

  @override
  void markLocalChanged({required int ledgerId}) {
    _localChanged = true;
    _statusCache.remove(ledgerId);
  }

  @override
  Future<void> deleteRemoteBackup({required int ledgerId}) async {
    // path 用 ledger.syncId，跟 push/upload 对齐。
    final ledgerRow = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(ledgerId)))
        .getSingleOrNull();
    final path = ledgerRow?.syncId ?? ledgerId.toString();
    try {
      await provider.storage.delete(path: path);
    } catch (e) {
      // 忽略 404
      if (!e.toString().contains('404')) rethrow;
    }
    _statusCache.remove(ledgerId);
  }

  @override
  void clearStatusCache({int? ledgerId}) {
    if (ledgerId != null) {
      _statusCache.remove(ledgerId);
    } else {
      _statusCache.clear();
    }
  }

  @override
  Future<({String? fingerprint, int? count, DateTime? exportedAt})>
      refreshCloudFingerprint({required int ledgerId}) async {
    // 对于增量同步，fingerprint 概念不太适用
    // 返回基本信息即可
    final ledgerRow = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(ledgerId)))
        .getSingleOrNull();
    final hasRemote = await provider.storage.exists(
      path: ledgerRow?.syncId ?? ledgerId.toString(),
    );
    if (!hasRemote) {
      return (fingerprint: null, count: null, exportedAt: null);
    }
    return (
      fingerprint: 'incremental',
      count: null,
      exportedAt: DateTime.now(),
    );
  }

  /// 释放资源
  void dispose() {
    stopListeningRealtime();
    _eventsController.close();
  }

  // ==================== 核心同步逻辑 ====================

  /// 执行完整同步（先 push 后 pull）
  Future<SyncResult> sync({required String ledgerId}) async {
    logger.info('SyncEngine', '开始同步 ledger=$ledgerId');
    try {
      final ledgerIdInt = int.tryParse(ledgerId) ?? -1;
      int pushed = 0;

      // 先上传附件文件，确保 cloudFileId 写入本地 DB，后续 push 的 payload 才包含 cloudFileId
      try {
        await uploadAttachments(ledgerId: ledgerIdInt);
      } catch (e, st) {
        logger.error('SyncEngine', '附件上传失败（不阻塞主同步）', e, st);
      }

      // 决策：fullPush 还是增量 push
      //
      // 单 ledger 粒度:本账本的 syncId **不在** 远端 `/sync/ledgers` 列表
      // 里 → fullPush;在 → 增量 _push。
      //
      // 跟旧 `storage.exists(path: ledger.syncId)` 等价(后者内部就是 list +
      // path 比对),但显式 list 一次自己比对,避免后续 snapshot 概念退场后
      // 误判持续返 false。
      //
      // 边界:`ledger.syncId == null`(本地刚建账本还没 sync 过)→ 一定不在
      // 远端列表,触发 fullPush。fullPush 内部 `_ensureLedgerSyncId` 会先
      // 生成 UUID 写回,确保 `pathForSnapshot` 合法。
      final ledgerRow = await (db.select(db.ledgers)
            ..where((l) => l.id.equals(ledgerIdInt)))
          .getSingleOrNull();

      // 短路:本地账本已删除(deleteLedger 路径)。这种情况下:
      //   - hasRemote 检查没意义(syncId 已经丢,fallback 到 int id 对 UUID 账本
      //     会误判)
      //   - fullPush 会 getSingle 抛错(ledger 行不存在)
      //   - pull 也没意义(账本都没了拉啥)
      // 唯一要做的是把 deleteLedger 已登记到 local_changes 的 ledger_snapshot:
      // delete + transaction:delete + budget:delete 推到 server,清掉 canonical
      // state,否则 remote ledgers 列表里还会显示这个被删的账本。
      if (ledgerRow == null) {
        final pushed = await push(ledgerId);
        logger.info(
            'SyncEngine', '账本 $ledgerId 已本地删除,push delete changes: $pushed 条');
        return SyncResult(pushed: pushed, pulled: 0);
      }

      // §7 共享账本:Editor 永不 fullPush(会把 Editor 本地状态覆盖 Owner 的)。
      final isSharedAsEditor =
          ledgerRow.isShared && ledgerRow.myRole != 'owner';

      bool shouldFullPush = false;
      if (!isSharedAsEditor) {
        try {
          final remoteLedgers = await provider.storage.list(path: '');
          // 用本账本的 syncId 跟远端列表比对(没 syncId 视为不在)。
          final mySyncId = ledgerRow.syncId;
          final remoteHasThisLedger = mySyncId != null &&
              mySyncId.isNotEmpty &&
              remoteLedgers.any((l) => l.path == mySyncId);
          shouldFullPush = !remoteHasThisLedger;
          logger.info('SyncEngine',
              '远端账本=${remoteLedgers.length}, 本账本(syncId=$mySyncId) 命中=$remoteHasThisLedger → fullPush=$shouldFullPush');
        } catch (e, st) {
          // list 失败保守走增量(fullPush 风险更大)。
          logger.warning('SyncEngine', '远端 ledger 列表查询失败,按已存在处理: $e', st);
        }
      }

      if (shouldFullPush) {
        // 远端没这个账本 → 首次绑定 / server 数据被清。
        // fullPush 推所有 entity + ledger 自身。

        // 关键:fullPush 前先确保 ledger.syncId 已生成(UUID 串)。否则会
        // fallback 到 `ledger.id.toString()` = 短数字串(如 "2"),触发
        // server 端 WriteLedgerCreateRequest 的 min_length=3 校验失败,并且
        // 跨设备时 server 上挂着的 external_id 也会变成本地 int id,后续多
        // 设备 sync 必然分裂。
        await _ensureLedgerSyncId(ledgerRow);

        final localTxCount = (await (db.select(db.transactions)
                  ..where((t) => t.ledgerId.equals(ledgerIdInt)))
                .get())
            .length;
        logger.info('SyncEngine', '远端无数据,本地 $localTxCount 条交易,触发 fullPush');

        if (localTxCount > 0) {
          // server 端重建/切换后,本地 attachments.cloudFileId 指向的文件已
          // 失效。清掉云端引用,让 uploadAttachments 重新上传并回填新 ID。
          await _resetAttachmentCloudRefs(ledgerIdInt);
        }
        await fullPush(ledgerId: ledgerIdInt);
        // fullPush 不处理 delete change(_pushAllEntities 只 upsert 当前实体)。
        // fullPush 已把非 delete change 都 markPushed,这里 _push 推剩余的
        // delete change,清掉 server canonical state。
        final extraPushed = await push(ledgerId);
        pushed = localTxCount + extraPushed;
      } else {
        pushed = await push(ledgerId);
        logger.info('SyncEngine', '增量推送: $pushed 条');
      }

      final pulled = await pull(ledgerId);

      // 下载远端附件文件（上传已在 push 前完成）
      try {
        await downloadAttachments(ledgerId: ledgerIdInt);
      } catch (e, st) {
        logger.error('SyncEngine', '附件下载失败（不阻塞主同步）', e, st);
      }

      // 顺手再拉一次 profile（多数场景 bootstrap 已经拉过，这里幂等兜底）。
      await syncMyProfile();

      final result = SyncResult(
        pushed: pushed,
        pulled: pulled,
        conflicts: (_lastPushConflicts?.conflict ?? 0) +
            (_lastPushConflicts?.failed ?? 0),
      );
      // 【根因修复】同步完成后清掉本账本 getStatus 的 _statusCache,跟手动上传/
      // 下载路径(uploadToCloudFromCurrentLedger / downloadAndRestoreToCurrentLedger
      // 里的 _statusCache.remove)保持一致。否则 push 后 unpushedCount 已归零,但
      // 「我的」页 syncStatus 仍命中旧缓存(localNewer),用户必须手动去详情页下拉
      // 刷新(那条路径清了缓存)状态才更新 —— 这正是本 bug 的根因。
      if (ledgerIdInt > 0) {
        clearStatusCache(ledgerId: ledgerIdInt);
      }
      // 缓存清掉只是让下次 getStatus 会重算;还得有人触发 syncStatusProvider 去重读。
      // push 上传了本地变更时 emit PushCompleted,listener 收到后 bump
      // syncStatusRefresh → 重读 getStatus(缓存已清 → 重算为 inSync)。
      if (pushed > 0) {
        _emit(PushCompleted(ledgerId: ledgerId, pushed: pushed));
      }
      logger.info('SyncEngine', '同步完成: $result');
      return result;
    } catch (e, st) {
      logger.error('SyncEngine', '同步失败', e, st);
      return SyncResult(error: e.toString());
    }
  }

  /// fullPush 前确保 ledger.syncId 已生成。
  ///
  /// 没 syncId 时 `pathForSnapshot` 会 fallback 到 `ledger.id.toString()`(短
  /// 数字串如 "2"),走两个失败路径:
  /// - `writeCreateLedger` 的 `WriteLedgerCreateRequest.ledger_id` 校验 min_length=3
  /// - server 端 ledger.external_id 被写成 int id 字符串,跨设备时同一账本
  ///   external_id 会分裂(A 设备的 syncId=UUID,B 设备的 syncId=int)
  ///
  /// 这里在 fullPush 入口做最后兜底,生成 UUID 写回。
  Future<void> _ensureLedgerSyncId(Ledger ledger) async {
    if (ledger.syncId != null && ledger.syncId!.length >= 3) return;
    final newSyncId = _uuid.v4();
    await (db.update(db.ledgers)..where((l) => l.id.equals(ledger.id)))
        .write(LedgersCompanion(syncId: d.Value(newSyncId)));
    logger.info(
        'SyncEngine', 'fullPush 前补生成 ledger.syncId: ${ledger.id} → $newSyncId');
  }

  /// 首次登录 / app 启动时从 server 拉全部账本写本地 Drift。
  ///
  /// Server 的 ledger 不走 sync_change log（只有 tx/account/cat/tag 走），
  /// 所以设备 B 首次登录时 `_pull` 拿不到 A 已有的账本。这个方法专门补这一
  /// 刀：走 `GET /sync/ledgers` 拿列表，按 `external_id` 对齐本地 `syncId`
  /// upsert 到 Drift。
  ///
  /// 新插入的 ledger 对应的 tx/account/category/tag sync_changes 历史会被
  /// `replayAllChanges`（由调用方在必要时触发）从 cursor=0 重放应用，因为
  /// 此时设备全局 cursor 可能已经前移、普通 `_pull` 再也拉不回历史。
  ///
  /// 返回新增（非已存在）的账本数，调用方可据此决定要不要 bump 刷新信号。
  /// 并发互斥锁 — **static** 跨 SyncEngine 实例共享。
  /// 关键 bug:join page 拿 syncEngineProvider(family) 的 engine,WS listener
  /// 拿 cloudSyncServiceProvider 创建的 engine,两个不同 instance!instance-level
  /// 字段互不知道,各跑各的。改 static 后整个进程同一时间只有一个 fetch-then-write
  /// 在跑。
  static Completer<int>? _syncLedgersInFlight;

  Future<int> syncLedgersFromServer() async {
    final existing = _syncLedgersInFlight;
    if (existing != null) {
      logger.info('SyncEngine', 'syncLedgersFromServer 已在执行中,等待 in-flight 结果');
      return existing.future;
    }
    final completer = Completer<int>();
    _syncLedgersInFlight = completer;
    try {
      final n = await _syncLedgersFromServerLocked();
      completer.complete(n);
      return n;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _syncLedgersInFlight = null;
    }
  }

  Future<int> _syncLedgersFromServerLocked() async {
    logger.info('SyncEngine', 'syncLedgersFromServer start');
    try {
      final remote = await provider.readLedgers();
      int upserted = 0;
      int inserted = 0;
      // 新设备登录场景:Editor 已是 server LedgerMember 但本地 ledgers 表为空。
      // 检测到 isShared && myRole != owner 的新 insert 时,记下 syncId,本轮
      // 结束后批量拉 /shared-resources 落 SharedLedger* 表。不放循环里直接
      // await 是因为 fetchAndStoreSharedResources 走 HTTP,放循环里会串行慢,
      // 也会让单个失败影响其它账本。
      final newSharedLedgerSyncIds = <String>[];
      for (final r in remote) {
        final syncId = r.ledgerId;
        if (syncId.isEmpty) continue;
        // 用 get() 不用 getSingleOrNull() — 历史可能已经产生过同 syncId 多行
        // (并发 syncLedgersFromServer 串行化前的遗留 / 老版本残留)。这里取 list,
        // 有就保第一行,GC 其余 dup。
        final existingList = await (db.select(db.ledgers)
              ..where((l) => l.syncId.equals(syncId)))
            .get();
        if (existingList.isNotEmpty) {
          final existing = existingList.first;
          // update meta（name / currency / 共享账本字段 server 可能改过）
          await (db.update(db.ledgers)..where((l) => l.id.equals(existing.id)))
              .write(LedgersCompanion(
            name: d.Value(r.ledgerName),
            currency: d.Value(r.currency),
            myRole: d.Value(r.role),
            isShared: d.Value(r.isShared),
            memberCount: d.Value(r.memberCount),
            monthStartDay: r.monthStartDay != null
                ? d.Value(r.monthStartDay!.clamp(1, 28))
                : const d.Value.absent(),
          ));
          // 删 dup 行(及其关联 tx/local_changes,虽然 dup 行还没有这些)
          if (existingList.length > 1) {
            final dupIds = existingList.skip(1).map((l) => l.id).toList();
            logger.warning('SyncEngine',
                '检测到 ledger.syncId=$syncId 重复 ${existingList.length} 行,清除 dup id=$dupIds');
            await (db.delete(db.transactions)
                  ..where((t) => t.ledgerId.isIn(dupIds)))
                .go();
            await (db.delete(db.localChanges)
                  ..where((c) => c.ledgerId.isIn(dupIds)))
                .go();
            await (db.delete(db.ledgers)..where((l) => l.id.isIn(dupIds))).go();
          }
          upserted++;
          continue;
        }
        // fallback：同名 + syncId 为 NULL 的 seed 行 → 收编
        final byName = await (db.select(db.ledgers)
              ..where((l) => l.name.equals(r.ledgerName))
              ..where((l) => l.syncId.isNull()))
            .getSingleOrNull();
        if (byName != null) {
          await (db.update(db.ledgers)..where((l) => l.id.equals(byName.id)))
              .write(LedgersCompanion(
            syncId: d.Value(syncId),
            currency: d.Value(r.currency),
            myRole: d.Value(r.role),
            isShared: d.Value(r.isShared),
            memberCount: d.Value(r.memberCount),
            monthStartDay: r.monthStartDay != null
                ? d.Value(r.monthStartDay!.clamp(1, 28))
                : const d.Value.absent(),
          ));
          upserted++;
          continue;
        }
        // 全新账本：insert。id 是本地 autoIncrement，跟 server 无关。
        await db.into(db.ledgers).insert(LedgersCompanion.insert(
              name: r.ledgerName,
              currency: d.Value(r.currency),
              syncId: d.Value(syncId),
              myRole: d.Value(r.role),
              isShared: d.Value(r.isShared),
              memberCount: d.Value(r.memberCount),
              monthStartDay: r.monthStartDay != null
                  ? d.Value(r.monthStartDay!.clamp(1, 28))
                  : const d.Value.absent(),
            ));
        inserted++;
        // 新设备登录:Editor 的共享账本需要拉 /shared-resources 才能在
        // picker / 详情页 / 洞察 等显示 Owner 的资源。fallback 给 byName
        // 收编路径不记(那是同 ledger 的 syncId 收编,不算新 ledger)。
        if (r.isShared && r.role != 'owner') {
          newSharedLedgerSyncIds.add(syncId);
        }
      }
      logger.info('SyncEngine',
          'syncLedgersFromServer done: total=${remote.length} upserted=$upserted inserted=$inserted');

      // GC 1:清掉本地 isShared=true 但 server 没返回的 ledger — Owner 删了
      // 共享账本,Editor 应该自动清(WS member_change.removed 是主路径,这是
      // 兜底,处理 WS 离线时没推到的情况)。
      final remoteSyncIdSet = remote.map((r) => r.ledgerId).toSet();
      final localShared = await (db.select(db.ledgers)
            ..where((l) => l.isShared.equals(true)))
          .get();
      for (final localLedger in localShared) {
        final sid = localLedger.syncId;
        if (sid == null || sid.isEmpty) continue;
        if (remoteSyncIdSet.contains(sid)) continue;
        // server 不再返这个共享账本 = Owner 删了 / Editor 被踢 → 清本地
        logger.info('SyncEngine', 'GC: server 不再返共享账本 syncId=$sid,清本地数据');
        await _purgeLocalLedgerByExternalId(sid);
      }

      // GC 2:清掉 SharedLedger* 表里 ledger.syncId 在新拉的 ledgers 表里找不
      // 到的孤儿行(测试残留 / 退出账本残留 / 老 invite 接受过又被 byName
      // fallback 改 syncId 时遗弃的旧 ledger_sync_id 行)
      await _gcOrphanSharedLedgerRows();

      // 新设备登录场景的二次拉取:本轮 insert 的共享账本(Editor 角色)逐个
      // 拉 /shared-resources 把 SharedLedger* 镜像表填上。每个独立 await
      // 单一错误不影响其它账本;成功后 bump tick 让 UI 立即生效。
      if (newSharedLedgerSyncIds.isNotEmpty) {
        logger.info('SyncEngine',
            '新 insert 的共享账本(Editor)$newSharedLedgerSyncIds — 拉 /shared-resources');
        for (final sid in newSharedLedgerSyncIds) {
          try {
            await fetchAndStoreSharedResources(sid);
          } catch (e, st) {
            logger.warning('SyncEngine',
                'fetchAndStoreSharedResources 失败 ledger=$sid: $e', st);
          }
        }
        // 通知 UI 刷新(picker / 详情页 watch sharedResourceRefreshProvider)
        // 这里只是拉了 SharedLedger* 镜像表,tx 没变,不该 emit PullCompleted
        // 触发 home 全刷,走 SharedResourceChanged 精确信号。
        _emit(const SharedResourceChanged(ledgerId: ''));
      }

      return inserted;
    } catch (e, st) {
      logger.warning('SyncEngine', 'syncLedgersFromServer failed: $e', st);
      return 0;
    }
  }

  /// 推送 user-global 实体(account / category / tag)的未推 change。
  ///
  /// **全局单飞**:并发调用复用第一个的 future。多账本场景下 Phase 2 并行的
  /// `_push(ledgerN)` / `fullPush(ledgerN)` 都先 await 这个方法,保证 user-global
  /// 实体每个 session 只推一次。
  ///
  /// 注意:**不要在 `_push` / `_pushAllEntities` 内部重复推 user-global**,
  /// 否则单飞失效。这俩内部应该只处理 ledger-scope change(transaction / budget /
  /// ledger / ledger_snapshot)。
  Future<int> pushUserGlobalEntities() async {
    final inFlight = _userGlobalPushInFlight;
    if (inFlight != null) {
      logger.info('SyncEngine', 'pushUserGlobalEntities 已在执行,复用 in-flight');
      await inFlight.future;
      return 0; // 复用不计数,只是等
    }
    final completer = Completer<void>();
    completer.future.ignore();
    _userGlobalPushInFlight = completer;
    try {
      final n = await _doPushUserGlobalEntities();
      completer.complete();
      return n;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      if (_userGlobalPushInFlight == completer) {
        _userGlobalPushInFlight = null;
      }
    }
  }

  Future<int> _doPushUserGlobalEntities() async {
    // Legacy backfill:v19 migration 给老 user-global 实体填了 syncId 但没登记
    // local_changes,这里一次性补登记。每 SyncEngine 实例只跑一次。
    if (!_userGlobalLegacyBackfilled) {
      await _backfillLegacyUserGlobalChanges();
      _userGlobalLegacyBackfilled = true;
    }

    final globalChanges = await changeTracker.getUnpushedChangesForLedger(0);
    if (globalChanges.isEmpty) {
      logger.debug(
          'SyncEngine', 'pushUserGlobalEntities: 无未推 user-global change');
      return 0;
    }

    // C2(2026-09-15):先按 (entityType, entitySyncId) 合并(同实体多条 change
    // 只发最新快照),再把代表条按 entity_type 拆主批/override 批 —— 拆批语义
    // 从「逐条 change」移到「合并代表条」层,exchange_rate_override 依旧单独
    // 推送,不与主批互相拖累。
    final merged = _mergeChangesByEntity(globalChanges);
    final mainReps = <LocalChange>[];
    final mainChangeIds = <List<int>>[];
    final overrideReps = <LocalChange>[];
    final overrideChangeIds = <List<int>>[];
    for (var i = 0; i < merged.representatives.length; i++) {
      final rep = merged.representatives[i];
      if (rep.entityType == 'exchange_rate_override') {
        overrideReps.add(rep);
        overrideChangeIds.add(merged.changeIds[i]);
      } else {
        mainReps.add(rep);
        mainChangeIds.add(merged.changeIds[i]);
      }
    }

    // user-global 实体序列化不需要 ledger 上下文,ledgerId 传 0 占位
    // (_serializeEntityForPush 内部用它查 parent ledger.syncId,user-global
    // 实体不会用到 parentLedgerSyncId)。
    // C11(2026-09-15):序列化为 null(实体已被本地删除)时返回 null,由
    // _pushChangeGroups 跳过该行 + 告警,不再发空 {} upsert。
    Future<Map<String, dynamic>?> buildSyncChange(LocalChange change) async {
      Map<String, dynamic>? payload;
      if (change.action == 'delete') {
        payload = <String, dynamic>{};
      } else {
        payload = await _serializeEntityForPush(
          entityType: change.entityType,
          entityId: change.entityId,
          ledgerId: 0,
        );
        if (payload == null) {
          logger.warning(
              'SyncEngine',
              'pushUserGlobal: ${change.entityType}(${change.entitySyncId}) '
              '本地实体已不存在,跳过 upsert 行(等待 delete change/本地重建对齐)');
          return null;
        }
      }
      return {
        'ledger_id': null,
        'scope': 'user',
        'entity_type': change.entityType,
        'entity_sync_id': change.entitySyncId,
        'action': change.action == 'delete' ? 'delete' : 'upsert',
        'payload': payload,
        'updated_at': change.createdAt.toUtc().toIso8601String(),
      };
    }

    // 主批(account/category/tag):分批推送后按服务端结果分流 markPushed。
    // 批次3(2026-09-10):LWW 判负 / poison 被拒的 change 不再标记已推
    // (旧行为:200 即全量 markPushed,被拒的本地编辑静默丢失)。被拒实体
    // 保留在 local_changes,由紧随的 pull 用服务端版本覆盖对齐。
    // C2 追加:分批 ≤200 条 + samples 截断防误标(见 _pushChangeGroups)。
    if (mainReps.isNotEmpty) {
      await _pushChangeGroups(
        mainReps,
        mainChangeIds,
        buildSyncChange: buildSyncChange,
      );
    }

    // exchange_rate_override 独立批:旧服务器白名单会拒绝该 entity_type,
    // 混在主批会整批失败、阻塞 account/category/tag 同步(README D10)。
    // 失败只 warning、不标记已推 → 留在 local_changes 下次重试。
    if (overrideReps.isNotEmpty) {
      try {
        await _pushChangeGroups(
          overrideReps,
          overrideChangeIds,
          buildSyncChange: buildSyncChange,
        );
      } catch (e, st) {
        logger.warning(
            'SyncEngine', 'override 批推送失败(server 可能未升级),跳过本轮不阻塞: $e', st);
      }
    }

    logger.info('SyncEngine',
        'pushUserGlobalEntities: 推送 ${mainReps.length} 主批 + ${overrideReps.length} override 批 user-global 实体(合并自 ${globalChanges.length} 条 change)');
    return globalChanges.length;
  }

  /// 扫 accounts/categories/tags,给 local_changes 里没登记过的 legacy 实体
  /// 补一条 upsert change。详见 [_userGlobalLegacyBackfilled] doc。
  ///
  /// 兼顾兜底两件事:
  /// 1. 实体 syncId 为 NULL(v22 migration 没覆盖到的脏数据)→ 生成 v4 UUID 写回
  /// 2. 已有 syncId 但 local_changes 表里完全没记录该实体的 change → 补 upsert
  Future<void> _backfillLegacyUserGlobalChanges() async {
    // 预拉:local_changes 表里所有 user-global 实体 syncId,做 in-memory dedup,
    // 避免逐 entity SELECT。
    final existingChanges = await (db.select(db.localChanges)
          ..where((c) => c.entityType.isIn(['account', 'category', 'tag'])))
        .get();
    final knownSyncIds = existingChanges.map((c) => c.entitySyncId).toSet();

    var backfilled = 0;

    // accounts
    final accounts = await db.select(db.accounts).get();
    for (final a in accounts) {
      var syncId = a.syncId;
      if (syncId == null) {
        syncId = _uuid.v4();
        await (db.update(db.accounts)..where((row) => row.id.equals(a.id)))
            .write(AccountsCompanion(syncId: d.Value(syncId)));
      }
      if (!knownSyncIds.contains(syncId)) {
        await changeTracker.recordUserGlobalChange(
          entityType: 'account',
          entityId: a.id,
          entitySyncId: syncId,
          action: 'upsert',
        );
        backfilled++;
      }
    }

    // categories
    final categories = await db.select(db.categories).get();
    for (final c in categories) {
      var syncId = c.syncId;
      if (syncId == null) {
        syncId = _uuid.v4();
        await (db.update(db.categories)..where((row) => row.id.equals(c.id)))
            .write(CategoriesCompanion(syncId: d.Value(syncId)));
      }
      if (!knownSyncIds.contains(syncId)) {
        await changeTracker.recordUserGlobalChange(
          entityType: 'category',
          entityId: c.id,
          entitySyncId: syncId,
          action: 'upsert',
        );
        backfilled++;
      }
    }

    // tags
    final tags = await db.select(db.tags).get();
    for (final t in tags) {
      var syncId = t.syncId;
      if (syncId == null) {
        syncId = _uuid.v4();
        await (db.update(db.tags)..where((row) => row.id.equals(t.id)))
            .write(TagsCompanion(syncId: d.Value(syncId)));
      }
      if (!knownSyncIds.contains(syncId)) {
        await changeTracker.recordUserGlobalChange(
          entityType: 'tag',
          entityId: t.id,
          entitySyncId: syncId,
          action: 'upsert',
        );
        backfilled++;
      }
    }

    if (backfilled > 0) {
      logger.info('SyncEngine',
          'legacy backfill: 补登记 $backfilled 条 user-global ChangeTracker entry');
    } else {
      logger.debug('SyncEngine', 'legacy backfill: 无需补登记');
    }
  }

  /// 推送本地未同步的变更到服务端。
  ///
  /// **in-flight 单飞**:同 ledger 的并发调用复用第一个的 future,避免双触发
  /// 在 sync_changes 表里造成重复 row。不同 ledger 并发不互相阻塞。
  ///
  /// 注意:**只推 ledger-scope change**(transaction / budget / ledger / ledger_snapshot)。
  /// user-global change(account / category / tag)由 [pushUserGlobalEntities] 统一推
  /// (在 [_doPush] 开头调用),避免多账本场景下并行 push 重复推送 user-global。
  Future<int> push(String ledgerId) async {
    final inFlight = _pushInFlight[ledgerId];
    if (inFlight != null) {
      logger.info('SyncEngine', 'push(ledger=$ledgerId) 已在执行,复用 in-flight');
      return inFlight.future;
    }
    final completer = Completer<int>();
    completer.future.ignore(); // 防 unhandled async error
    _pushInFlight[ledgerId] = completer;
    try {
      final result = await _doPush(ledgerId);
      completer.complete(result);
      return result;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      if (_pushInFlight[ledgerId] == completer) {
        _pushInFlight.remove(ledgerId);
      }
    }
  }

  Future<int> _doPush(String ledgerId) async {
    final ledgerIdInt = int.tryParse(ledgerId) ?? -1;

    // 1) 先推 user-global change(account / category / tag)。
    //    全局单飞,Phase 2 多 ledger 并行场景下只跑一次,跨 ledger 不再各推一份。
    //    详见 [pushUserGlobalEntities] doc + .docs/concurrent-fullpush-bloat.md。
    final userGlobalPushed = await pushUserGlobalEntities();

    // 2) ledgerId="0" / "" 语义是"只推 user-global",上面一步已经做完。
    if (ledgerIdInt == 0) return userGlobalPushed;

    final ledger = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(ledgerIdInt)))
        .getSingleOrNull();

    // 3) 再推这个 ledger 的 ledger-scope change(transaction / budget / ledger /
    //    ledger_snapshot)。ledger 删除路径:即使 ledger 行已没,ledger_snapshot:
    //    delete change 还在 local_changes 里,这里照常推。
    //
    // 关键:ledger 已被本地删除时不能直接 return 0。因为 deleteLedger 会先
    // 登记 ledger_snapshot:delete change 再 hard-delete ledger 行,这条 delete
    // change 的 ledger_id 字段就是这个本地 id。如果这里因 ledger==null 短路,
    // 这条 delete change 永远卡在本地不推,云端账本和它的快照永远删不掉,
    // remote ledgers list 还会继续显示。
    //
    // 所以策略改为:先按这个 ledgerIdInt 查未推送变更,有变更就继续推,没
    // 变更才安全 return。
    final ledgerChanges =
        await changeTracker.getUnpushedChangesForLedger(ledgerIdInt);
    // 仅这个 ledger 的 ledger-scope change。user-global 已在上面统一推走。
    final changes = ledgerChanges;
    if (changes.isEmpty) {
      if (ledger == null) {
        logger.warning('SyncEngine', 'push: 本地账本 $ledgerId 已删除且无待推送变更,跳过');
      } else {
        logger.debug('SyncEngine',
            'push: 无 ledger-scope 待推变更(user-global 已推 $userGlobalPushed 条)');
      }
      return userGlobalPushed;
    }
    // 当本地 ledger 行已删,从同批 changes 里捞 ledger_snapshot:delete 的
    // entity_sync_id(= 被删账本的 syncId / UUID),用它给所有相关 change 的
    // push payload 设置 ledger_id 字段。否则 fallback 到 ledgerId 字符串
    // (本地 int id),server 端会把它当成一个不存在的账本 → 整批 delete 静
    // 默失败,canonical state 不变,远端数据看着像没删。
    String? deletedLedgerSyncId;
    if (ledger == null) {
      for (final c in changes) {
        if (c.entityType == 'ledger_snapshot' && c.action == 'delete') {
          deletedLedgerSyncId = c.entitySyncId;
          break;
        }
      }
      logger.info(
          'SyncEngine',
          'push: 本地账本 $ledgerId 已删除,但还有 ${changes.length} 条未推送变更(应包含 ledger_snapshot:delete),'
              '从 snapshot change 拿到 ledgerSyncId=$deletedLedgerSyncId,继续 push');
    }

    // C2(2026-09-15):构建服务端 push 格式 + 合并 + 分批推送。
    // 单条 change 的序列化逻辑与旧版一致(从 DB 读最新实体快照),变化在于:
    // - 按 (entityType, entitySyncId) 合并,同实体多条 change 只序列化/发送
    //   最新一条(旧行为重复序列化同一快照 N 次);
    // - 每批 ≤ [pushBatchSize] 条,成功一批 markPushed 一批,失败批抛出并
    //   保留未推条目下次续推(旧行为数千条一个 POST,60s deadline 大概率
    //   超时,失败整体重推);
    // - markPushed 按客户端本轮实际提交的合并组标记,不再盲信服务端截断
    //   20 条的 samples 回执(附录 B1)。
    Future<Map<String, dynamic>?> buildSyncChange(LocalChange change) async {
      final isUserGlobal =
          ChangeTracker.userGlobalEntityTypes.contains(change.entityType);

      Map<String, dynamic>? payload;

      if (change.action == 'delete') {
        payload = <String, dynamic>{};
      } else {
        // 从数据库读取最新实体并序列化。注意:正常流程到这里 ledger 一定非
        // null —— ledger==null 的唯一来源是 deleteLedger,而它只产生 delete
        // changes(已被 if 分支拦走)。这里用 ledgerIdInt 兜底防御,避免 NPE。
        // C11(2026-09-15):序列化为 null(实体已被本地删除)→ 整行跳过,
        // 旧行为发空 {} upsert,若 delete change 因 orphan ledger 漏推,
        // 空 upsert 成为服务端毒数据。
        payload = await _serializeEntityForPush(
          entityType: change.entityType,
          entityId: change.entityId,
          ledgerId: ledger?.id ?? ledgerIdInt,
        );
        if (payload == null) {
          logger.warning(
              'SyncEngine',
              'push: ${change.entityType}(${change.entitySyncId}) '
              '本地实体已不存在,跳过 upsert 行(等待 delete change/本地重建对齐)');
          return null;
        }
      }

      // user-global 重构后协议(参考 .docs/user-global-refactor/plan.md):
      //   - scope='user' (category/account/tag):ledger_id 发 null,server 按
      //     entity_type 强制按 user-scope 路由,不再依附任何 ledger。
      //   - scope='ledger' (transaction/budget/ledger/ledger_snapshot):
      //     ledger_id 用 ledger.syncId(跨设备唯一 external_id)。删账本路径
      //     从 ledger_snapshot:delete change 拉回 syncId,保证 server 认得。
      final String? pushLedgerId;
      final String pushScope;
      if (isUserGlobal) {
        pushLedgerId = null;
        pushScope = 'user';
      } else {
        pushLedgerId = ledger?.syncId ?? deletedLedgerSyncId ?? ledgerId;
        pushScope = 'ledger';
      }
      return {
        'ledger_id': pushLedgerId,
        'scope': pushScope,
        'entity_type': change.entityType,
        'entity_sync_id': change.entitySyncId,
        'action': change.action == 'delete' ? 'delete' : 'upsert',
        'payload': payload,
        'updated_at': change.createdAt.toUtc().toIso8601String(),
      };
    }

    final merged = _mergeChangesByEntity(changes);
    await _pushChangeGroups(
      merged.representatives,
      merged.changeIds,
      buildSyncChange: buildSyncChange,
    );
    logger.info('SyncEngine',
        'push: 推送 ${changes.length} 条 ledger-scope 变更(合并为 ${merged.representatives.length} 实体)+ 本会话 user-global $userGlobalPushed 条');
    return changes.length + userGlobalPushed;
  }

  // ────────────────────────────────────────────────────────────────────
  // C2(2026-09-15):push 合并 + 分批
  // ────────────────────────────────────────────────────────────────────

  /// 合并后每批推送的最大条数。200 × ~500B/条 ≈ 100KB 请求体,单批在 60s
  /// upload deadline 内稳定;失败也只影响本批,前面已成功批不回滚。
  static const int pushBatchSize = 200;

  /// 按 (entityType, entitySyncId) 合并 local_changes。
  ///
  /// 同一实体的多次编辑会产生多条 change,旧行为逐条序列化同一份最新快照
  /// 重复 POST。合并规则:取组内 id 最大(= 最后意图)的一条作为代表 ——
  /// 最新 action 为 delete 则发 delete,否则从 DB 序列化最新快照。
  ///
  /// 返回代表条与每组的全部 change id(代表条推送成功后整组一起 markPushed
  /// —— 组内旧 change 的内容已被最新快照覆盖,留在本地只会造成重复推送)。
  /// 入参须按 id 升序([ChangeTracker.getUnpushedChanges*] 的自然顺序)。
  ({List<LocalChange> representatives, List<List<int>> changeIds})
      _mergeChangesByEntity(List<LocalChange> changes) {
    final groups = <String, List<LocalChange>>{};
    for (final change in changes) {
      groups
          .putIfAbsent(
              '${change.entityType}\u0000${change.entitySyncId}',
              () => <LocalChange>[])
          .add(change);
    }
    final representatives = <LocalChange>[];
    final changeIds = <List<int>>[];
    for (final group in groups.values) {
      representatives.add(group.last);
      changeIds.add([for (final c in group) c.id]);
    }
    return (representatives: representatives, changeIds: changeIds);
  }

  /// 合并后的代表条分批推送。
  ///
  /// - 成功一批 markPushed 一批;某批网络/HTTP 失败直接抛出(此前已成功批
  ///   的标记保留,失败批及其后批次留在 local_changes,下次 push 续推)。
  /// - 拒绝分流(2026-09-10 批次3 + 附录 B1):服务端 200 不代表全 accepted,
  ///   LWW 判负(conflict)与 apply 异常(failed)都会在 200 里返回,但
  ///   conflict/failed samples 各截断 20 条。样本数 < 计数说明有被拒实体
  ///   无法点名 —— 此时**整批不 markPushed**(全部保留重推;同
  ///   (updated_at, device_id) 元组重推服务端按幂等接受),绝不按残缺样本
  ///   排除、把第 21 条起被拒的 change 误标已推静默丢失。
  /// - **P-01(2026-10-11)**:判定口径改为 `rejected`(服务端总拒收数)与
  ///   `conflict+failed` 的**较大者**。服务端存在只 `rejected += 1` 而不带
  ///   任何 sample 的分支(push.py:305 ledger-scoped change 缺 ledger_id /
  ///   push.py:413 非 owner 推 ledger):只看 conflict+failed 会得 0 →
  ///   既不触发 B1 截断保护也不累计 B3 → change 被误标已推**静默丢失**。
  /// - C11(2026-09-15):`buildSyncChange` 返回 null(实体已被本地删除)的
  ///   行跳过不发送,也不 markPushed(留待 delete change / 本地重建对齐)。
  /// - 附录 B3(2026-09-15):同一代表条被服务端拒绝 [maxPushRejectAttempts]
  ///   次后熔断 —— 本会话不再重推(否则被拒 change 无限重推,服务端每条
  ///   冲突写一条 AuditLog,双向放大)。熔断条保留在 local_changes,unpushed
  ///   计数可见;用户对实体产生新编辑(新 change id)或本会话内该实体推送
  ///   成功时解除。
  /// - **P-02(2026-10-11)**:熔断可逆 —— 见 [_admitToSend]。
  Future<int> _pushChangeGroups(
    List<LocalChange> representatives,
    List<List<int>> changeIds, {
    required Future<Map<String, dynamic>?> Function(LocalChange change)
        buildSyncChange,
  }) async {
    var markedRows = 0;
    for (var start = 0; start < representatives.length;
        start += pushBatchSize) {
      final end = (start + pushBatchSize > representatives.length)
          ? representatives.length
          : start + pushBatchSize;
      final batch = representatives.sublist(start, end);
      // C11:逐条序列化,null(实体已删)跳过;B3:熔断条跳过(不消耗请求位)。
      final sentIndexes = <int>[];
      final syncChanges = <Map<String, dynamic>>[];
      for (var i = 0; i < batch.length; i++) {
        final rep = batch[i];
        if (!_admitToSend(rep)) continue;
        final payload = await buildSyncChange(rep);
        if (payload == null) continue; // 告警已在 buildSyncChange 内打
        // U-04(2026-10-11):毒 payload(NaN/Infinity)在**交给 provider 之前**
        // 拦下。真实 provider 对整批 body 一次 `jsonEncode`,一条非有限值就能
        // 让**整批**失败(JsonUnsupportedObjectError)→ 该设备推送通道整体瘫痪。
        // 这里跳过该条 + 告警 + 不 markPushed(保守重推,绝不静默丢),
        // 其余正常实体照常推送 —— 与"一条远端脏数据毒化整个通道"相反。
        if (_hasNonFiniteNumber(payload)) {
          _skipPoisonPayload(rep.entityType, rep.entitySyncId);
          continue;
        }
        sentIndexes.add(start + i);
        syncChanges.add(payload);
      }
      if (syncChanges.isEmpty) continue;
      final result = await provider.pushChanges(changes: syncChanges);
      final rejectedSyncIds = result.rejectedEntitySyncIds;
      // 中-1:服务端终态拒绝样本(reason ∈ 终态集合)。
      final terminalSamples = result.terminalRejectionSamples;
      // P-01:`rejected` 是服务端**总拒收**,conflict+failed 只是其中可分类
      // 的部分。取较大者保证"零样本拒收"不被当成 0(否则 change 被误标已推)。
      final classifiedRejections = result.conflictCount + result.failedCount;
      final reportedRejections = classifiedRejections > result.rejected
          ? classifiedRejections
          : result.rejected;
      if (reportedRejections > 0) {
        // 无分类样本的拒收(only-rejected 分支)也算进 conflict 计数,让
        // sync() 的 conflicts 反馈与真实拒收量一致。
        final unclassified = reportedRejections - classifiedRejections;
        _lastPushConflicts = (
          conflict: result.conflictCount + (unclassified > 0 ? unclassified : 0),
          failed: result.failedCount,
          at: DateTime.now(),
        );
      }
      // 中-1(2026-10-11 三轮复查):终态拒绝(ledger_deleted / membership_
      // revoked / unknown_ledger / sync_id_mismatch / entity_sync_id_too_long)
      // 的 change **丢弃 + 落错误行**,不再进入下面的保守重推路径。放在
      // B1 截断判定之前:终态样本是自含的精确记录(entityType+entitySyncId+
      // reason),即使本批同时发生 samples 截断,已点名的终态实体也可安全
      // 处置 —— 留着它们只会 8 次/会话 + 每 30min 探测地永久空转。
      final terminalDropped = terminalSamples.isEmpty
          ? const <int>{}
          : await _dropTerminalRejectedGroups(
              batch, start, terminalSamples, changeIds);
      if (rejectedSyncIds.length < reportedRejections) {
        logger.warning(
            'SyncEngine',
            'push: 本批 ${batch.length} 条中 $reportedRejections 条被拒但样本被截断'
            '(conflict/failed samples 各上限 20,或服务端只报 rejected 计数),'
            '整批保留待重推/pull 对齐');
        // B3:样本截断时无法点名,全部已发代表条按被拒计数(保守,不误清)。
        // P-02:计数在熔断判定**之前**累计 —— 本轮的拒收一定进账,下一轮才
        // 依据累计值决定是否熔断。终态已丢弃的条除外(行已删,计数无意义)。
        for (final i in sentIndexes) {
          if (terminalDropped.contains(i)) continue;
          _countPushReject(representatives[i]);
        }
        continue;
      }
      final okChangeIds = <int>[
        for (var i = 0; i < batch.length; i++)
          if (sentIndexes.contains(start + i) &&
              !rejectedSyncIds.contains(batch[i].entitySyncId))
            ...changeIds[start + i],
      ];
      if (okChangeIds.isNotEmpty) {
        await changeTracker.markPushed(okChangeIds);
        markedRows += okChangeIds.length;
      }
      // B3:按服务端点名结果更新计数 —— 被拒 +1(达上限熔断),被接受清除。
      for (var i = 0; i < batch.length; i++) {
        if (!sentIndexes.contains(start + i)) continue;
        final rep = batch[i];
        if (terminalDropped.contains(start + i)) {
          // 终态丢弃:B3 状态已在 _dropTerminalRejectedGroups 清掉,
          // 不计数(实体当前无待推 change,用户重新编辑 = 全新机会)。
          continue;
        }
        if (rejectedSyncIds.contains(rep.entitySyncId)) {
          _countPushReject(rep);
        } else {
          _pushRejectState
              .remove(_pushRejectKey(rep.entityType, rep.entitySyncId));
        }
      }
      if (reportedRejections > 0) {
        logger.warning(
            'SyncEngine',
            'push: 本批 ${batch.length} 条中 ${rejectedSyncIds.length} 条被点名被拒'
            '(LWW 判负/poison),对应合并组保留本地待 pull 对齐');
      }
    }
    return markedRows;
  }

  /// 中-1(2026-10-11 三轮复查):处置本批被服务端**终态**拒绝的合并组。
  ///
  /// 终态 reason(见 [SmartBookPushResult.terminalRejectionReasons],与
  /// `server/src/routers/sync/push.py` 逐字同步)意味着重试永远不可能成功:
  /// `ledger_deleted` / `membership_revoked` / `unknown_ledger` 是服务端状态
  /// 回不来的账本类拒绝,`sync_id_mismatch` / `entity_sync_id_too_long` 是
  /// 数据本身畸形。旧行为把它们与 LWW 判负同等对待(不 markPushed、留在
  /// local_changes)→ 8 次/会话 + 每 30min 探测 + 重启计数重置地永久空转。
  ///
  /// 对每个能**唯一匹配**到本批代表条 (entityType, entitySyncId) 的终态
  /// sample:
  /// 1. 写一条持久错误行([SyncErrorStore.recordPushTerminalRejected],
  ///    `error_class = PushTerminalRejected`,强制 `resolved_at = NULL`,
  ///    `watchUnresolved()` / [watchUnresolvedPushTerminalRejected] 可查);
  /// 2. 删除该合并组的全部 local_changes 行(drop-with-record:可观测、
  ///    非静默);
  /// 3. 清 B3 熔断状态(实体已无待推 change)。
  ///
  /// **匹配安全阀**:sample 无法匹配(或匹配到多个)代表条 → 跳过该 sample,
  /// 保守落回既有重推路径 —— 绝不丢弃一条无法确认身份的 change。
  /// 返回被丢弃组的绝对 index 集合(相对 representatives,供 caller 排除
  /// B3 计数)。
  Future<Set<int>> _dropTerminalRejectedGroups(
    List<LocalChange> batch,
    int start,
    List<Map<String, dynamic>> terminalSamples,
    List<List<int>> changeIds,
  ) async {
    final dropped = <int>{};
    for (final sample in terminalSamples) {
      final reason = sample['reason'] as String?;
      final entitySyncId = sample['entitySyncId'] as String?;
      final entityType = sample['entityType'] as String?;
      if (reason == null || entitySyncId == null || entityType == null) {
        logger.warning('SyncEngine',
            'push: 终态拒绝样本缺字段($sample),跳过处置(保守重推)');
        continue;
      }
      // 唯一匹配判定:同批同 (entityType, entitySyncId) 的合并组必然唯一
      //(_mergeChangesByEntity 的分组键),多命中说明数据异常 → 放弃处置。
      final hits = <int>[
        for (var i = 0; i < batch.length; i++)
          if (batch[i].entityType == entityType &&
              batch[i].entitySyncId == entitySyncId)
            i,
      ];
      if (hits.isEmpty) {
        // sample 指向的实体不在本批(服务端状态异常 / 并发场景)→ 无法对应
        // 本地 change 行,不处置(不误删)。
        logger.warning('SyncEngine',
            'push: 终态拒绝 $entityType($entitySyncId) reason=$reason '
            '未匹配到本批代表条,跳过处置(保守重推)');
        continue;
      }
      if (hits.length > 1) {
        logger.warning('SyncEngine',
            'push: 终态拒绝 $entityType($entitySyncId) 命中 ${hits.length} 个'
            '合并组(数据异常),跳过处置(保守重推)');
        continue;
      }
      final i = hits.first;
      final absIndex = start + i;
      if (dropped.contains(absIndex)) continue;
      final rep = batch[i];
      final groupIds = changeIds[absIndex];
      // 1) 持久错误行(pushLedgerId:ledger-scoped change 的 push ledger_id
      //    = ledger.syncId;样本里的 ledgerId 是 server external_id,优先用)。
      final ledgerExternalId = (sample['ledgerId'] as String?) ?? '';
      try {
        await pullErrors.recordPushTerminalRejected(
          localChangeId: rep.id,
          entityType: rep.entityType,
          entitySyncId: rep.entitySyncId,
          ledgerExternalId: ledgerExternalId,
          reason: reason,
          droppedChangeIds: groupIds,
        );
      } catch (e) {
        // 错误行是可观测性兜底,登记失败也继续 drop(下一轮 unpushed 排水
        // 本身会暴露问题;与 _recordPulledValueSkip 的取舍一致)。
        logger.warning('SyncEngine',
            'push: 终态拒绝错误行登记失败 ${rep.entityType}(${rep.entitySyncId})'
            '(仍继续丢弃 change): $e');
      }
      // 2) 删除合并组的全部 local_changes 行。
      await (db.delete(db.localChanges)..where((c) => c.id.isIn(groupIds)))
          .go();
      // 3) 清 B3 熔断状态。
      _pushRejectState.remove(_pushRejectKey(rep.entityType, rep.entitySyncId));
      dropped.add(absIndex);
      logger.error(
          'SyncEngine',
          'push: ${rep.entityType}(${rep.entitySyncId}) 被服务端终态拒绝'
          '(reason=$reason),丢弃 ${groupIds.length} 条本地 change + 落错误行'
          '(重试不可能成功;用户重新编辑产生新 change 可重试)',
          'push_terminal_rejected');
    }
    return dropped;
  }

  /// P-02(2026-10-11):熔断门禁 —— 决定某条代表条本轮是否真的发送。
  ///
  /// 修复前:熔断判定在发送**之前** `continue`,而计数重置/清除只对**已发送**
  /// 的条生效 —— 熔断条永远进不了这两个点,会话内不可逆(文档承诺的"新
  /// change id 解锁"不可达,用户"改一下试试"无法自救)。
  ///
  /// 现在两条穿透路径,任一命中即放行:
  /// 1. **新 change id**(用户再次编辑):`rep.id > state.repChangeId` →
  ///    清状态、给一轮全新机会(与 [maxPushRejectAttempts] 的文档承诺一致)。
  /// 2. **超时衰减**:距上次被拒超过 [pushRejectProbeInterval] → 计数回退到
  ///    上限-1 并放行**一次**探测(服务端可能已修好 / 数据已被 pull 对齐)。
  ///    探测再被拒 → 立即重新熔断并重新计时,不会退化成无限重推。
  bool _admitToSend(LocalChange rep) {
    final key = _pushRejectKey(rep.entityType, rep.entitySyncId);
    final state = _pushRejectState[key];
    if (state == null || !state.tripped) return true;

    if (rep.id > state.repChangeId) {
      _pushRejectState.remove(key);
      logger.info(
          'SyncEngine',
          'push: ${rep.entityType}(${rep.entitySyncId}) 检测到新 change id'
          '(rep=${rep.id} > 熔断时=${state.repChangeId}),重置熔断计数并重新尝试');
      return true;
    }

    final elapsed = DateTime.now().difference(state.at);
    if (elapsed >= pushRejectProbeInterval) {
      _pushRejectState[key] = (
        repChangeId: rep.id,
        rejects: maxPushRejectAttempts - 1,
        tripped: false,
        at: DateTime.now(),
      );
      logger.info(
          'SyncEngine',
          'push: ${rep.entityType}(${rep.entitySyncId}) 熔断已静默 '
          '${elapsed.inMinutes}min(≥${pushRejectProbeInterval.inMinutes}min),'
          '放行一次探测(再被拒即重新熔断)');
      return true;
    }

    logger.warning(
        'SyncEngine',
        'push: ${rep.entityType}(${rep.entitySyncId}) 已被服务端拒绝 '
        '${state.rejects} 次,本会话熔断不再重推(change 保留本地;用户编辑出'
        '新 change 或 ${pushRejectProbeInterval.inMinutes}min 后自动探测重试)');
    return false;
  }

  /// 附录 B3:被拒代表条计数;同一代表条(同 change id)达到上限即熔断,
  /// 新 change id(用户再次编辑)重置计数。
  void _countPushReject(LocalChange rep) {
    final key = _pushRejectKey(rep.entityType, rep.entitySyncId);
    final prev = _pushRejectState[key];
    final rejects = (prev != null && prev.repChangeId == rep.id)
        ? prev.rejects + 1
        : 1;
    final tripped = rejects >= maxPushRejectAttempts;
    _pushRejectState[key] =
        (repChangeId: rep.id, rejects: rejects, tripped: tripped, at: DateTime.now());
    if (tripped && !(prev?.tripped ?? false)) {
      logger.error(
          'SyncEngine',
          'push: ${rep.entityType}(${rep.entitySyncId}) 被服务端拒绝 $rejects 次,'
          '本会话熔断(停止重推;change 保留本地,unpushed 计数可见;'
          '用户编辑出新 change id 或 ${pushRejectProbeInterval.inMinutes}min 后自动探测)',
          'push_reject_tripped');
    }
  }

  /// 拉取远程变更并应用到本地。
  ///
  /// 改造点(详见 `.docs/full-pull-refactor/`):
  /// 1. **cursor 安全**:cloud-sync 包 `pullChanges(persistCursor: false)`,
  ///    app 侧用 [appCursor] 管,**整页 apply 成功后**才推进
  /// 2. **失败隔离**:整页 apply 抛错 → rollback + 错误入 [pullErrors] 表 +
  ///    cursor 不推进 + 后续页不再拉,UI 显示"同步暂停"
  /// 3. **busy retry**:SQLite busy/locked 单条 retry 2 次
  /// 4. **小颗粒度**:单页 limit 50(原 500),让 retry 范围 + UI 反馈更可控
  ///
  /// 传 [sinceOverride]=0 = 从头重放(等价旧 replayAllChanges)。
  ///
  /// **单飞锁**:多个 caller(bootstrap / WS push / ledger switch /
  /// connectivity restored / 用户下拉刷新)同时触发 pull 时,SQLite 排队 +
  /// main isolate 拥塞会让 apply 时间翻倍。这里用 [_pullInFlight] 互斥:
  /// - 普通 pull(sinceOverride=null)碰到 in-flight 时**复用结果**(节省一
  ///   轮)
  /// - replay(sinceOverride 非 null)语义独立,等 in-flight 完成后再自己跑
  Future<int> pull(String ledgerId, {int? sinceOverride}) async {
    // 1. in-flight 单飞
    final inFlight = _pullInFlight;
    if (inFlight != null) {
      if (sinceOverride == null && _pullInFlightSince == null) {
        // 普通 pull 复用 in-flight 结果
        logger.info('SyncEngine', 'pull 已在执行中,复用 in-flight 结果');
        return inFlight.future;
      }
      // replay / since 不同 → 等当前 pull 完成再独立跑
      logger.info('SyncEngine',
          'pull(sinceOverride=$sinceOverride) 等待 in-flight pull 完成');
      try {
        await inFlight.future;
      } catch (_) {/* 忽略 in-flight 的错,自己单独跑 */}
    }

    final completer = Completer<int>();
    // 默认订阅 future 让出错时不抛 unhandled async error — 后续 caller
    // 复用 in-flight 时会自己 await,如果没人 await(单 caller 场景),
    // completer.completeError 触发的 Future 错误会被 zone 当成 unhandled。
    // 这里 ignore() 等于说"我已经知道这个错,通过 rethrow 抛给当前 caller 了"。
    completer.future.ignore();
    _pullInFlight = completer;
    _pullInFlightSince = sinceOverride;
    try {
      final n = await _doPull(ledgerId, sinceOverride);
      completer.complete(n);
      return n;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      if (_pullInFlight == completer) {
        _pullInFlight = null;
        _pullInFlightSince = null;
      }
    }
  }

  /// pull 单飞锁。多个 caller 同时调 pull 时,只第一个真跑,后续复用 / 等待。
  Completer<int>? _pullInFlight;
  int? _pullInFlightSince;

  /// U-03(2026-10-11):从持久化 cursor 读到的异常值自愈。
  ///
  /// [AppCursorStore.commit] 已拦截负数/回退的写入,但**旧版本已经落盘的**
  /// 坏值(负数 / 接近 2^63 的天文数字)仍会存活到升级后 —— 必须在 pull 入口
  /// 收敛,否则这些设备升级后依然同步静默死亡。收敛为 0(从头重放,幂等
  /// upsert 不丢数据),让服务端下一页把 cursor 拉回正常轨迹。
  ///
  /// 这里用 [AppCursorStore.forceReset] 而非 commit:commit 是单调的,写不下
  /// 比当前更小的值 —— 坏值本身比 0 大,只有强制写才能真正清掉它。
  Future<int> _sanitizeSince(int since) async {
    if (since >= 0 && since <= AppCursorStore.maxReasonableCursor) {
      return since;
    }
    logger.warning(
        'SyncEngine',
        'pull: 持久化 cursor=$since 超出合法域(0..${AppCursorStore.maxReasonableCursor}),'
        '强制重置为 0 重新对齐(幂等重放)');
    await appCursor.forceReset(0);
    return 0;
  }

  Future<int> _doPull(String ledgerId, int? sinceOverride) async {
    // U-08:deferred 集合按 pull 轮次隔离,入口清一次。
    _deferredChangeIds.clear();
    // 缺陷 A:值跳过登记同样按轮隔离(上一轮已落错误行,内存登记不跨轮)。
    _valueSkips.clear();
    int? nextSince = await _sanitizeSince(
        sinceOverride ?? await appCursor.read());
    if (nextSince == 0 && sinceOverride == null) {
      await appCursor.migrateFromProviderCursor();
      nextSince = await _sanitizeSince(await appCursor.read());
    }

    // **Lazy prime**:先 HTTP 一次试探有没有数据。99% 场景(无变更)直接
    // return,跳过 LookupCache 全表 SELECT(transactions 10k+ 行的 prime
    // 每次都要 200-500ms 主线程时间)。多账本场景这里是大头 — 启动时 5 个
    // ledger 各跑一次 sync,空跑也要 prime 5 次,白白卡 1-2s。
    final probe = await provider.pullChanges(
      since: nextSince,
      limit: 500,
      persistCursor: false,
    );
    if (probe.changes.isEmpty) {
      logger.info(
          'SyncEngine', 'pull: since=$nextSince 无新变更,跳过 LookupCache prime');
      return 0;
    }

    // 有数据 → prime LookupCache,然后跑 loop(把已拉的第一页喂进去)
    final cache = LookupCache();
    await cache.prime(db);
    activePullCache = cache;

    try {
      return await _runPullLoop(ledgerId, nextSince, firstPage: probe);
    } finally {
      activePullCache = null;
    }
  }

  /// hasMore 循环的最大迭代页数。服务端若因 bug / 代理缓存持续返回
  /// `has_more=true`(且 cursor 不前进),客户端必须自带上限收敛 —— 旧实现
  /// 只看 `result.hasMore`,没有迭代上限也不检测游标是否前进 → pull 永不
  /// 返回(同步按钮永久转圈 + 同一批 change 被反复 apply)。
  static const int maxPullPages = 200;

  Future<int> _runPullLoop(
    String ledgerId,
    int? nextSince, {
    SmartBookCloudPullResult? firstPage,
  }) async {
    int totalApplied = 0;
    bool hasMore = true;
    int pageIndex = 0;
    final loopStart = DateTime.now();
    SmartBookCloudPullResult? reuseResult = firstPage;
    while (hasMore) {
      pageIndex++;
      // U-05 家族(hasMore 死循环):迭代上限。真实场景一页 500 条,200 页
      // = 10 万条历史,足够任何正常 replay;超限说明服务端 hasMore / cursor
      // 行为异常,停下让下一轮 pull 续拉(cursor 已推进的部分不丢)。
      if (pageIndex > maxPullPages) {
        logger.error(
            'SyncEngine',
            'pull: 达到单次最大页数 $maxPullPages,提前终止(服务端 hasMore 可能异常);'
            '已 apply $totalApplied 条,剩余交给下一轮 pull',
            'pull_page_cap');
        break;
      }
      final pageStart = DateTime.now();
      final SmartBookCloudPullResult result;
      if (reuseResult != null) {
        // 第一轮:复用 _doPull 的探针结果,不再发一次 HTTP
        result = reuseResult;
        reuseResult = null;
        logger.info('SyncEngine',
            'pull #$pageIndex: since=$nextSince got ${result.changes.length} hasMore=${result.hasMore} (reused probe)');
      } else {
        result = await provider.pullChanges(
          since: nextSince,
          limit: 500,
          persistCursor: false, // cursor 由 appCursor 接管
        );
        final httpMs = DateTime.now().difference(pageStart).inMilliseconds;
        logger.info('SyncEngine',
            'pull #$pageIndex: since=$nextSince got ${result.changes.length} hasMore=${result.hasMore} (HTTP ${httpMs}ms)');
      }
      // 空页短路:即使 hasMore=true(服务端异常)也不能继续循环,否则
      // "空页 + hasMore 恒真" 就是纯忙等死循环。
      if (result.changes.isEmpty) {
        if (result.hasMore) {
          logger.error(
              'SyncEngine',
              'pull: 第 $pageIndex 页为空但 hasMore=true(服务端异常),停止续拉',
              'pull_empty_page_with_more');
        }
        break;
      }

      final applyStart = DateTime.now();
      final outcome = await _applyPullPage(result.changes);
      final applyMs = DateTime.now().difference(applyStart).inMilliseconds;
      logger.info('SyncEngine',
          'pull #$pageIndex: applied ${outcome.applied}/${result.changes.length} (apply ${applyMs}ms, page total ${DateTime.now().difference(pageStart).inMilliseconds}ms)');
      totalApplied += outcome.applied;
      if (outcome.blocked) {
        logger.warning(
            'SyncEngine', 'pull 被错误阻塞 cursor 停在 $nextSince — UI 应显示同步异常');
        break;
      }
      // U-08(2026-10-11,阻断-4):本页有"跳过的、必须等前序数据才能落地"的
      // change(ledger 未就绪的 budget / account_adjustment)→ **整页不推进
      // cursor**,也不 markResolved,留待 ledger change 到达后的下一轮 pull
      // 重放。仅把 handler 返回值改成 false 是不够的 —— cursor 必须在
      // 这一页真正提交之前停下,否则该 change 的 change_id 落到 cursor 之后
      // 就永久拉不回来了。
      if (outcome.deferred > 0) {
        logger.warning(
            'SyncEngine',
            'pull: 第 $pageIndex 页有 ${outcome.deferred} 条依赖未就绪(跳过),'
            'cursor 停在 $nextSince 待下轮重放');
        break;
      }

      // 整页成功:**单调**推进 cursor(负值/非法值/回退一律不落盘,见
      // [AppCursorStore.commit]),处理本页 enqueue 的自定义图标。
      final committed = await appCursor.commit(result.serverCursor);
      nextSince = committed;

      // 顺序敏感(2026-10-11 复现缺陷修复):放弃重放的错误行已由
      // [_applyPullPage] 在页事务 commit 后写好(`error_class =
      // DeferredGiveUp`,强制 `resolved_at = NULL`)。这里**只**清
      // [outcome.resolveChangeIds] —— 本轮没有登记 deferred 的 change_id
      // (旧语义:本页处理过的 id 清掉历史错误行)。
      //
      // 绝不能无条件清整页所有 change_id(旧实现,缺陷根因):安全阀放弃的
      // 条目没有落地,它的错误行会被同一轮立刻 resolve → `watchUnresolved()`
      // (UI 查询面)永远看不到,"记录错误、UI 可见、不静默"的承诺失效。
      // 推迟(deferred)的条目同理。放弃条目只在之后真正 apply 成功的那一轮
      // (依赖到达 / replayAllChanges)才进 resolveChangeIds → 被清 → 自愈。
      for (final id in outcome.resolveChangeIds) {
        _abandonedDeferredIds.remove(id);
        await pullErrors.markResolved(id);
      }

      // 主事务已 commit,fire-and-forget 并发处理图标 queue,不阻塞下一页
      if (pendingCustomIconJobs.isNotEmpty) {
        unawaited(drainCustomIconQueue());
      }

      hasMore = result.hasMore;
    }

    final totalMs = DateTime.now().difference(loopStart).inMilliseconds;
    if (totalApplied > 0 || pageIndex > 0) {
      logger.info('SyncEngine',
          'pull: 累计 apply $totalApplied 条 / $pageIndex 页 / 总耗时 ${totalMs}ms');
    }
    return totalApplied;
  }

  /// 单页 apply。整页事务 try/catch:
  /// - 不可恢复异常 → rollback + 错误入 [pullErrors] + return blocked
  /// - SQLite busy/locked → 单条 retry 2 次
  ///
  /// 2026-10-11 缺陷修复(安全阀放弃必须可观测)的三条不变量:
  /// 1. **放弃判定与错误行只在页事务 commit 之后生效** —— 事务中途抛错时
  ///    整页 rollback、cursor 不动、下一轮重放,放弃判定不能残留(残留会让
  ///    下一轮不再计入 deferred,在没有任何错误记录的情况下越过该 change)。
  /// 2. **放弃的错误行在此处写**(而不是 `_runPullLoop` 的 markResolved 区域),
  ///    因为"本页还有别的条目在 deferred → `_runPullLoop` 提前 break"时,
  ///    markResolved 区域根本不会执行 —— 错误行会漏写。
  /// 3. [resolveChangeIds] 只装**本轮未登记 deferred** 的 change_id,旧的
  ///    markResolved 循环据此清错误 —— 放弃/仍 deferred 的条目绝不被清。
  Future<_PullPageOutcome> _applyPullPage(
      List<SmartBookCloudSyncChange> changes) async {
    int applied = 0;
    int skipped = 0;
    int deferred = 0;

    /// 本页安全阀判定"放弃重放"的 change(第一次触发)。按 change_id 去重:
    /// 页内同 change_id 出现两次(服务端异常)时只记一次,避免重复落错误行。
    final abandoned = <int, SmartBookCloudSyncChange>{};

    /// 之前已放弃、本轮(全量重放)依旧落不了地的 change —— 只刷新既有错误行
    /// (attempt_count++ / 保持未解决),不重复计入 deferred(否则重放会被它
    /// 再次钉住)。
    final reassertAbandoned = <int, SmartBookCloudSyncChange>{};

    /// 本页可以 markResolved 的 change_id —— 保持旧语义("本页处理过的
    /// change_id 清掉历史错误"),但**排除**推迟(deferred、放弃)的条目:
    /// 它们没有落地,错误行必须在 `watchUnresolved()`(UI 面)存活到真正
    /// apply 成功的那一轮。旧实现无条件清整页所有 id,正是本次缺陷根因
    /// (安全阀同轮 record+resolve → UI 永远看不到)。
    ///
    /// 含 skipped-by-design(自己设备的 change / 未知 entityType):这类
    /// change_id 已落到 cursor 之后,永远不会再被拉取,历史错误行若不清会
    /// 在 UI 里永久悬挂 —— 旧行为就是清掉,这里保持一致。
    final resolveChangeIds = <int>{};

    /// 本页"重放计数"的增量,事务 commit 后才写回内存 —— rollback 时计数
    /// 不能凭空 +1(否则阀门会比真实重放次数更早跳闸)。
    final replayCountUpdates = <int, int>{};

    /// 本页新增的"值跳过"(缺陷 A):apply handler 调 [_markPulledValueSkip]
    /// 登记,这里把本页开始前的 change_id 快照下来 —— 事务 commit 后才落错误
    /// 行,rollback 时新登记的条目从 [_valueSkips] 撤回(判定不得残留到下一轮)。
    final valueSkipIdsBefore = Set<int>.of(_valueSkips.keys);

    /// 本页内被登记"值跳过"的 change —— 事务 commit 后据此写/刷新错误行。
    final valueSkipped = <int, SmartBookCloudSyncChange>{};

    SmartBookCloudSyncChange? failingChange;

    try {
      await db.transaction(() async {
        for (final ch in changes) {
          failingChange = ch;
          final ok = await _applyOneWithBusyRetry(ch);
          final registeredDeferred = _deferredChangeIds.contains(ch.changeId);
          // U-08:handler 通过 [_deferChange] 声明"依赖未就绪、必须重放"。
          // 无论它的返回值是什么(false=跳过 / true=不计入 skipped 的历史
          // 语义),只要登记了 deferred,本页就不能推进 cursor —— 除非该
          // change 已被推迟超过 [maxDeferredReplays] 轮(依赖显然不会到了,
          // 见安全阀注释)。
          var wasDeferred = registeredDeferred &&
              !_abandonedDeferredIds.contains(ch.changeId);
          if (wasDeferred) {
            final replays = (_deferredReplays[ch.changeId] ?? 0) + 1;
            if (replays > maxDeferredReplays) {
              logger.error(
                  'SyncEngine',
                  'pull: change_id=${ch.changeId} ${ch.entityType}(${ch.entitySyncId}) '
                  '已推迟 $maxDeferredReplays 轮仍依赖未就绪,判定依赖不会到达 → '
                  '记录错误(UI 可见)并放行 cursor(避免整机同步永久停在页首)',
                  'pull_deferred_giveup');
              // 放弃判定只在事务 commit 后生效(见方法注释不变量 1)。
              abandoned[ch.changeId] = ch;
              wasDeferred = false;
            } else {
              replayCountUpdates[ch.changeId] = replays;
            }
          } else if (registeredDeferred) {
            // 已放弃过的 change 在全量重放里再次出现且仍未落地 → 刷新错误行,
            // 让 lastAttemptAt / attempt_count 反映"仍在失败",UI 持续可见。
            reassertAbandoned[ch.changeId] = ch;
          }
          if (wasDeferred) {
            deferred++;
          }
          if (ok) {
            applied++;
          } else if (!wasDeferred) {
            skipped++;
          }
          // 本页可 resolve 的 id:凡是本轮**没有**登记 deferred 的条目
          // (真正落地成功、或按设计跳过)都与旧语义一致地清历史错误。
          // 登记过 deferred 的条目(推迟中 / 本轮放弃 / 放弃后重放仍失败)
          // 绝不清 —— 它们没有落地,错误行必须在 UI 面存活。
          //
          // 缺陷 A 补充:本轮被登记"值跳过"的条目同样不清 —— 它没有落地
          // (cursor 只是必须前进,否则整页卡死),错误行必须在 UI 面存活到
          // 真正 apply 成功。
          if (!registeredDeferred && !_valueSkips.containsKey(ch.changeId)) {
            resolveChangeIds.add(ch.changeId);
          }
        }
      });

      // ---------- 事务已成功 commit,以下副作用此刻才落定 ----------
      replayCountUpdates.forEach((id, n) => _deferredReplays[id] = n);
      for (final id in abandoned.keys) {
        _abandonedDeferredIds.add(id);
        _deferredReplays.remove(id);
      }
      for (final id in resolveChangeIds) {
        // 曾放弃的 change 这次真正落地 → 放弃状态自愈解除,错误行由
        // [_runPullLoop] 的 markResolved 清掉(依赖到达后的正常收敛路径)。
        _abandonedDeferredIds.remove(id);
        _deferredReplays.remove(id);
      }
      // 写放弃错误行:recordDeferredGiveUp 强制 resolved_at=NULL(旧行复活)
      // 且 error_class=DeferredGiveUp —— UI 用 [SyncErrorStore.watchUnresolved]
      // 或 watchUnresolvedDeferredGiveUps 都能查到,不被本轮 cursor 推进吞掉。
      for (final ch in abandoned.values) {
        await _recordDeferredGiveUp(ch,
            reason: '依赖未就绪: 重放 $maxDeferredReplays 轮仍未解析出 '
                '${ch.entityType}(${ch.entitySyncId}) 的所属实体'
                '(可能引用了本设备拿不到的 ledger="${ch.ledgerId}")。'
                '已放弃重放并放行 cursor,该 change 不再自动重试;'
                '需服务端修数据或让依赖实体可达后全量重放');
      }
      for (final ch in reassertAbandoned.values) {
        await _recordDeferredGiveUp(ch,
            reason: '该 change(change_id=${ch.changeId}, '
                '${ch.entityType}/${ch.entitySyncId})此前已被判定放弃重放,'
                '本次全量重放依旧无法落地(依赖实体仍不可解析)');
      }

      // 写值跳过错误行(缺陷 A):本轮新增登记的条目落 [pullErrors],
      // 强制 resolved_at=NULL 且 error_class=PulledValueSkipped —— UI 用
      // [SyncErrorStore.watchUnresolved] 能查到,不被本轮 cursor 推进吞掉。
      for (final entry in _valueSkips.entries) {
        if (valueSkipIdsBefore.contains(entry.key)) continue; // 本轮之前已有
        valueSkipped[entry.key] = entry.value.change;
      }
      for (final entry in valueSkipped.entries) {
        await _recordPulledValueSkip(entry.value,
            reason: _valueSkips[entry.key]?.reason ?? '远端值不可用(已跳过)');
      }

      // 事务已成功 commit(部分 apply 已落库),但 deferred 要求 cursor 不推进
      // —— 重放整页时幂等 upsert 不会重复插入,所以是安全的。
      if (skipped > 0 ||
          deferred > 0 ||
          abandoned.isNotEmpty ||
          valueSkipped.isNotEmpty) {
        logger.info('SyncEngine',
            'pull: 应用 $applied / 跳过 $skipped / 推迟 $deferred / '
            '放弃 ${abandoned.length} / 重新确认放弃 ${reassertAbandoned.length} / '
            '值跳过 ${valueSkipped.length} (本页)');
      }
      return _PullPageOutcome(
          applied: applied,
          blocked: false,
          deferred: deferred,
          resolveChangeIds: resolveChangeIds,
          abandoned: abandoned.values.toList(growable: false));
    } catch (e, st) {
      // 整页 rollback 已自动完成(Drift transaction 抛错回滚)。本页新登记的
      // 值跳过判定一并撤回 —— 该 change 没被处理过,cursor 也不动,下一轮
      // 重放时会重新判定(残留会让下一轮跳过判定提前"已登记"而漏写错误行)。
      for (final id in _valueSkips.keys.toList()) {
        if (!valueSkipIdsBefore.contains(id)) _valueSkips.remove(id);
      }
      logger.error(
          'SyncEngine',
          '本页 apply 抛错 change_id=${failingChange?.changeId} '
              'type=${failingChange?.entityType}',
          e,
          st);
      final ch = failingChange;
      if (ch != null) {
        await pullErrors.record(change: ch, error: e, stackTrace: st);
      }
      return const _PullPageOutcome(applied: 0, blocked: true);
    }
  }

  /// 把一条"安全阀放弃重放"的错误写进 [pullErrors](带可执行上下文)。
  /// 登记失败不阻塞放行 —— 放弃的核心目的是让 cursor 恢复推进,错误行只是
  /// 尽力保证可观测性(与旧实现一致)。
  Future<void> _recordDeferredGiveUp(SmartBookCloudSyncChange ch,
      {required String reason}) async {
    try {
      await pullErrors.recordDeferredGiveUp(
        change: ch,
        error: StateError(reason),
        stackTrace: StackTrace.current,
      );
    } catch (e) {
      logger.warning('SyncEngine',
          'pull: 放弃重放的错误登记失败 change_id=${ch.changeId}(不阻塞 cursor 放行): $e');
    }
  }

  /// 缺陷 A(2026-10-11 复现缺陷修复):apply handler 判定"远端值不可用、跳过
  /// 该条"时登记(内存),由 [_applyPullPage] 在页事务 commit 后写 [pullErrors]。
  ///
  /// 为什么不直接在 handler 里写库:handler 跑在页事务内,错误行必须与"整页
  /// apply 是否真的成功"同生共死(rollback 时不能残留 —— [_applyPullPage] 的
  /// catch 会撤回本页新增登记)。这与 [_deferChange] 的"只登记、由页级提交"
  /// 同款设计。
  ///
  /// **cursor 照常推进**:值跳过是"这条 change 永远落不了地"(重放不会变好),
  /// 不 defer —— defer 会让整页 apply 每轮卡在同一条坏 change 上,整机同步
  /// 永久停摆。代价是 change_id 落到 cursor 之后不再重拉,所以持久登记是这条
  /// change **唯一**的可观测面(除 48h 日志外)。
  void _markPulledValueSkip(SmartBookCloudSyncChange change, String reason) {
    _valueSkips[change.changeId] = (change: change, reason: reason);
  }

  /// 把一条"值跳过"写进 [pullErrors]。登记失败不阻塞 cursor 推进 —— 值跳过的
  /// 核心目的是让整页继续 apply,错误行只是尽力保证可观测性。
  Future<void> _recordPulledValueSkip(SmartBookCloudSyncChange ch,
      {required String reason}) async {
    try {
      await pullErrors.recordPulledValueSkipped(change: ch, reason: reason);
    } catch (e) {
      logger.warning('SyncEngine',
          'pull: 值跳过的错误登记失败 change_id=${ch.changeId}(不阻塞 cursor 推进): $e');
    }
  }


  /// 单条 apply 带 SQLite busy/locked retry。其它异常直接抛,让外层整页 rollback。
  ///
  /// 用 `e.toString()` 探测 SqliteException 类型,避免引入 sqlite3 包依赖
  /// (Drift 内部用,但这里直接 import 会触发 depend_on_referenced_packages)。
  Future<bool> _applyOneWithBusyRetry(SmartBookCloudSyncChange ch) async {
    var attempts = 0;
    while (true) {
      try {
        return await applyRemoteChange(ch);
      } catch (e) {
        final msg = e.toString().toLowerCase();
        final transient =
            (msg.contains('sqlite') || msg.contains('database')) &&
                (msg.contains('busy') || msg.contains('locked'));
        if (transient && attempts < 2) {
          attempts++;
          await Future.delayed(Duration(milliseconds: 50 * (1 << attempts)));
          continue;
        }
        rethrow;
      }
    }
  }

  /// 从 change_id=0 起把整段 sync_changes 重拉一遍并幂等应用。
  /// 用在"账本刚从 server 拉到本地、本地 tx 为空但 cursor 已经被推到顶"
  /// 的恢复场景。跟 S3/WebDAV 的 `_fullPull` 不同，这里走的还是 SmartBook
  /// Cloud 的增量日志，只是把起点拨回 0，符合 SmartBook Cloud 的同步模型。
  Future<int> replayAllChanges() async {
    logger.info('SyncEngine', 'replayAllChanges: 从 0 开始重拉 sync_changes');
    return pull('', sinceOverride: 0);
  }

  // 附件相关方法搬到 sync_engine_attachments.dart 这个 part 文件:
  //   _resetAttachmentCloudRefs / _uploadCategoryIcons / uploadAttachments
  //   downloadAttachments / _getAttachmentFile / _cleanupTxAttachmentFilesOnDisk
  //   _cleanupCategoryIconFilesOnDisk

  /// 新设备全量拉取。
  ///
  /// **in-flight 单飞**:防御性,挡用户连点"下载"按钮时两次并发拉取。
  Future<({int inserted, int deletedDup})> runFullPull(
      {required int ledgerId}) async {
    final inFlight = _fullPullInFlight[ledgerId];
    if (inFlight != null) {
      logger.info(
          'SyncEngine', 'runFullPull(ledger=$ledgerId) 已在执行,复用 in-flight');
      return inFlight.future;
    }
    final completer = Completer<({int inserted, int deletedDup})>();
    completer.future.ignore();
    _fullPullInFlight[ledgerId] = completer;
    try {
      final result = await _doRunFullPull(ledgerId: ledgerId);
      completer.complete(result);
      return result;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      if (_fullPullInFlight[ledgerId] == completer) {
        _fullPullInFlight.remove(ledgerId);
      }
    }
  }

  Future<({int inserted, int deletedDup})> _doRunFullPull(
      {required int ledgerId}) async {
    logger.info('SyncEngine', '开始全量拉取 ledger=$ledgerId');

    // path 对齐 fullPush 上传时用的 ledger.syncId。
    final ledgerRow = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(ledgerId)))
        .getSingleOrNull();
    final path = ledgerRow?.syncId ?? ledgerId.toString();
    final data = await provider.storage.download(path: path);
    if (data == null) {
      logger.warning('SyncEngine', '全量拉取: 服务端无数据');
      return (inserted: 0, deletedDup: 0);
    }

    // 复用 importTransactionsJson;recordChanges:false 阻止反向回流:
    // 从云端拉下来的数据**不应该**再以 local_changes 形式推回去,否则 10k
    // 条 fullPull 会触发 SyncCoordinator 反向 sync,白白多一轮 10k push。
    final result = await importTransactionsJson(
      repo,
      ledgerId,
      data,
      recordChanges: false,
    );
    logger.info('SyncEngine', '全量拉取完成: inserted=${result.inserted}');

    // 下载附件
    try {
      await downloadAttachments(ledgerId: ledgerId);
    } catch (e, st) {
      logger.error('SyncEngine', '附件下载失败（不阻塞拉取）', e, st);
    }

    return (inserted: result.inserted, deletedDup: 0);
  }

  /// 「以服务端为准」强制恢复当前账本：清空本地交易 + 预算，**并用服务端
  /// 快照覆盖重建账户/分类/标签**，从 /sync/full 权威快照重建，把 pull
  /// cursor 推进到服务端 latest_cursor。
  ///
  /// 用于 pull 侧整页 apply 失败导致 cursor 卡住、本地与云端分叉后的手动自救。
  /// 关键安全约束（见计划）：
  /// - 清空与重建都**绕过 ChangeTracker 的 user change 记录**（db 直写 +
  ///   不走 repo.create*），绝不把 delete / upsert 记成未推送 local_changes，
  ///   避免恢复后反向推服务端造成二次覆盖或删光服务端数据。重建出的每个
  ///   user-global 实体都会补打 `recordPulledFromServer` 标记，防止
  ///   [_backfillLegacyUserGlobalChanges] 把它们当 legacy 再反推回服务端。
  /// - 交易/预算只清当前账本（ledger-scoped）；账户/分类/标签是 user-global
  ///   共享数据，**整表按快照覆盖**：快照里没有的本地行（含 NULL syncId 的
  ///   seed 残留）会被删除 —— 这是「本地分类 53 vs 云端 96」这类差异的收敛
  ///   手段。删除语义与 pull delete 一致（tag 关联清除、分类图标文件清理）。
  /// - 推进 cursor 到 latest_cursor，跳过导致卡住的历史坏 change。
  ///
  /// 缺陷 B(2026-10-11):所有恢复路径的金额列(账户 initial_balance/credit_limit、
  /// 预算 amount、调整 amount/balance_before/balance_after)都过非有限守卫 ——
  /// 非有限的快照行**跳过 + 告警 + 计数**,其余实体照常恢复(策略见
  /// [_snapshotMoneyOk])。跳过的行数汇总在 [skippedBadAmounts] 里返回,调用方
  /// 可据此提示"快照部分损坏"。
  Future<({int inserted, int restoredBudgets, int restoredAccounts,
          int restoredCategories, int restoredTags, int skippedBadAmounts})>
      forceRestoreFromServer({
    required int ledgerId,
  }) async {
    logger.info('SyncEngine', 'forceRestoreFromServer: 以服务端为准恢复 ledger=$ledgerId');

    final ledgerRow = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(ledgerId)))
        .getSingleOrNull();
    final path = ledgerRow?.syncId ?? ledgerId.toString();
    final snap = await provider.downloadFullSnapshot(path: path);
    final content = snap.content;
    if (content == null) {
      logger.warning('SyncEngine', 'forceRestoreFromServer: 服务端无快照，中止');
      return (
        inserted: 0,
        restoredBudgets: 0,
        restoredAccounts: 0,
        restoredCategories: 0,
        restoredTags: 0,
        skippedBadAmounts: 0,
      );
    }

    // 1. 清空本地交易（级联删 tags / attachments）+ 预算。直接 db 写，不记 change。
    await db.transaction(() async {
      final txIds = await (db.select(db.transactions)
            ..where((t) => t.ledgerId.equals(ledgerId)))
          .map((t) => t.id)
          .get();
      if (txIds.isNotEmpty) {
        await (db.delete(db.transactionTags)
              ..where((tt) => tt.transactionId.isIn(txIds)))
            .go();
        await (db.delete(db.transactionAttachments)
              ..where((a) => a.transactionId.isIn(txIds)))
            .go();
      }
      await (db.delete(db.transactions)
            ..where((t) => t.ledgerId.equals(ledgerId)))
          .go();
      await (db.delete(db.budgets)
            ..where((b) => b.ledgerId.equals(ledgerId)))
          .go();
      // v42:调整记录随交易一起清(重建从快照来)。
      await (db.delete(db.accountAdjustments)
            ..where((a) => a.ledgerId.equals(ledgerId)))
          .go();

      // 2. 清掉该账本未推送的 transaction/budget/account_adjustment change，防止恢复后残留
      //    delete/upsert change 反向推服务端覆盖权威数据。
      await (db.delete(db.localChanges)
            ..where((c) =>
                c.ledgerId.equals(ledgerId) &
                c.pushedAt.isNull() &
                c.entityType.isIn(['transaction', 'budget', 'account_adjustment'])))
          .go();
    });

    // 3. 用服务端快照覆盖重建账户/分类/标签（见 [_restoreUserGlobalFromSnapshot]）。
    //    ⚠️ 不能用 importTransactionsJson 的账户/分类/标签导入：它走
    //    repo.create* 记 user-global change 推回服务端 → 服务端账户/分类/标签
    //    膨胀（正是「以服务端为准后服务端变多」的根因）。
    final restored = await _restoreUserGlobalFromSnapshot(content);

    // 4. 从权威快照重建交易（recordChanges:false，不反向回流）。映射表在
    //    user-global 重建**之后**构建，交易才能挂上刚重建的账户/分类/标签。
    final importData = parseJsonToImportData(content);
    final accountNameToId = <String, int>{
      for (final a in await repo.getAllAccounts()) a.name: a.id,
    };
    final categoryCache = <String, int>{};
    for (final kind in const ['expense', 'income']) {
      for (final c in await repo.getTopLevelCategories(kind)) {
        categoryCache['$kind|${c.name}'] = c.id;
        for (final sub in await repo.getSubCategories(c.id)) {
          categoryCache['${sub.kind}|${sub.name}'] = sub.id;
        }
      }
    }
    final tagNameToId = <String, int>{
      for (final t in await repo.getAllTags()) t.name: t.id,
    };
    final importResult = await dataImportService.importTransactions(
      repo,
      ledgerId,
      importData.transactions,
      accountNameToId: accountNameToId,
      categoryCache: categoryCache,
      tagNameToId: tagNameToId,
      recordChanges: false,
    );
    final result = (inserted: importResult.inserted,);

    // 5. 从权威快照重建预算（轻量解析，db 直写保留 syncId，不记 change）。
    //    在分类重建之后执行，分类预算的 syncId 才解析得到。
    final budgetsResult = await _restoreBudgetsFromSnapshot(ledgerId, content);
    final restoredBudgets = budgetsResult.restored;
    final restoredBudgetSkips = budgetsResult.skipped;

    // 5b. 从权威快照重建余额调整记录(v42,db 直写不记 change)。在账户重建
    //     之后执行,accountId 的 syncId 才解析得到。
    final adjustmentsResult =
        await _restoreAccountAdjustmentsFromSnapshot(ledgerId, content);
    final restoredAdjustments = adjustmentsResult.restored;
    final restoredAdjustmentSkips = adjustmentsResult.skipped;
    // 6. 推进 cursor 到服务端 latest_cursor，跳过卡住的历史坏 change。
    if (snap.latestCursor > 0) {
      await appCursor.commit(snap.latestCursor);
      logger.info('SyncEngine',
          'forceRestoreFromServer: cursor 推进到 ${snap.latestCursor}');
    }

    // 7. 重建附件。
    try {
      await downloadAttachments(ledgerId: ledgerId);
    } catch (e, st) {
      logger.error('SyncEngine', 'forceRestoreFromServer: 附件下载失败（不阻塞）', e, st);
    }

    logger.info('SyncEngine',
        'forceRestoreFromServer 完成: 交易 ${result.inserted} 笔, 预算 $restoredBudgets 笔, '
        '余额调整 $restoredAdjustments 条, '
        '账户 ${restored.accounts}(删${restored.deletedAccounts}) '
        '分类 ${restored.categories}(删${restored.deletedCategories}) '
        '标签 ${restored.tags}(删${restored.deletedTags}), '
        '金额非有限跳过 ${restored.skippedAccounts + restoredBudgetSkips + restoredAdjustmentSkips} 条');
    return (
      inserted: result.inserted,
      restoredBudgets: restoredBudgets,
      restoredAccounts: restored.accounts,
      restoredCategories: restored.categories,
      restoredTags: restored.tags,
      skippedBadAmounts: restored.skippedAccounts +
          restoredBudgetSkips +
          restoredAdjustmentSkips,
    );
  }

  /// 从 /sync/full 快照 JSON **覆盖重建** user-global 实体（账户/分类/标签）。
  ///
  /// 语义对齐 pull 的 `_apply*Change` upsert（syncId 命中更新、NULL-syncId
  /// seed 按名收编、自定义图标入队下载），但整批跑在一个事务里且不产生任何
  /// 未推送 change：
  /// - 快照里**没有**的本地行（NULL syncId 残留、同 syncId 重复行）按 pull
  ///   delete 同款语义删除（tag 关联清除、分类图标文件清理、子先于父）；
  /// - 每个重建实体补打 `recordPulledFromServer` 标记，防止 legacy backfill
  ///   把它们再推回服务端（「以服务端为准后服务端变多」的根因）；
  /// - 先作废全部未推送的 user-global change —— 恢复后本地旧意图不得再上推。
  ///
  /// 快照缺某个数组的 key（老服务端）时**跳过**该类型（不删不建）；key 存在
  /// 但为空列表则按服务端权威清空。分类重建先一级后二级，预算重建依赖此顺序。
  ///
  /// [skippedAccounts] 是金额非有限被跳过的账户数(缺陷 B),由 caller 汇总。
  Future<({int accounts, int categories, int tags, int deletedAccounts,
          int deletedCategories, int deletedTags, int skippedAccounts})>
      _restoreUserGlobalFromSnapshot(String content) async {
    const zeros = (
      accounts: 0,
      categories: 0,
      tags: 0,
      deletedAccounts: 0,
      deletedCategories: 0,
      deletedTags: 0,
      skippedAccounts: 0,
    );
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) return zeros;
    // key 缺失 = 老服务端不提供该类型，跳过（绝不能误当空集清空本地）
    final accountsRaw =
        decoded['accounts'] is List ? decoded['accounts'] as List : null;
    final categoriesRaw =
        decoded['categories'] is List ? decoded['categories'] as List : null;
    final tagsRaw = decoded['tags'] is List ? decoded['tags'] as List : null;
    if (accountsRaw == null && categoriesRaw == null && tagsRaw == null) {
      return zeros;
    }

    var restoredAccounts = 0, restoredCategories = 0, restoredTags = 0;
    var deletedAccounts = 0, deletedCategories = 0, deletedTags = 0;
    var skippedAccounts = 0;

    await db.transaction(() async {
      // 0) 作废本地 user-global 未推送意图：以服务端为准后，本地旧改名/新建
      //    不得再经 push 覆盖权威数据。已推送的 marker 行保留（防 backfill）。
      await (db.delete(db.localChanges)
            ..where((c) => c.entityType
                    .isIn(['account', 'category', 'tag']) &
                c.pushedAt.isNull()))
          .go();

      // ---------- 账户 ----------
      if (accountsRaw != null) {
        final snapSyncIds = <String>{};
        for (final raw in accountsRaw) {
          if (raw is! Map<String, dynamic>) continue;
          final syncId = (raw['syncId'] as String?)?.trim();
          if (syncId == null || syncId.isEmpty) continue;
          snapSyncIds.add(syncId);
          final name = raw['name'] as String? ?? '';
          final type = raw['type'] as String? ?? 'cash';
          final currency = raw['currency'] as String? ?? 'CNY';
          final initialBalance =
              (raw['initialBalance'] as num?)?.toDouble() ?? 0.0;
          final creditLimit = (raw['creditLimit'] as num?)?.toDouble();
          final sortOrder = (raw['sortOrder'] as num?)?.toInt() ?? 0;
          final hidden =
              raw.containsKey('hidden') ? (raw['hidden'] as bool? ?? false) : null;

          // 缺陷 B(2026-10-11):快照金额列守卫。账户金额列(initial_balance /
          // credit_limit)非有限会污染余额/净资产聚合 —— 与 repo 层
          // `validateAccountAmounts` 同口径,但**不抛**:快照里一条坏值不能让
          // 整个 forceRestore 失败(其它账户/分类/交易仍要恢复)。
          // 策略:跳过该条 + 告警 + 计数(返回值里可见),而不是抛错。
          // 注意 syncId 已进 snapSyncIds(见上)—— 跳过只意味着"不写这一条",
          // 本地同名/同 syncId 行不因此被删(不丢本地已有数据)。
          if (!_snapshotMoneyOk('account', syncId, {
            'initialBalance': initialBalance,
            'creditLimit': creditLimit,
          })) {
            skippedAccounts++;
            continue;
          }

          // syncId 命中 → 更新；miss → 按 name 收编 NULL-syncId seed 行
          // （与 _applyAccountChange 一致，避免同名重复并保住本地 int id）。
          var existing = await (db.select(db.accounts)
                ..where((a) => a.syncId.equals(syncId))
                ..limit(1))
              .getSingleOrNull();
          if (existing == null && name.isNotEmpty) {
            existing = await (db.select(db.accounts)
                  ..where((a) => a.name.equals(name))
                  ..where((a) => a.syncId.isNull())
                  ..limit(1))
                .getSingleOrNull();
          }

          int localId;
          if (existing != null) {
            localId = existing.id;
            await (db.update(db.accounts)..where((a) => a.id.equals(localId)))
                .write(AccountsCompanion(
              name: d.Value(name),
              type: d.Value(type),
              currency: d.Value(currency),
              initialBalance: d.Value(initialBalance),
              sortOrder: d.Value(sortOrder),
              creditLimit: d.Value(creditLimit),
              billingDay: d.Value((raw['billingDay'] as num?)?.toInt()),
              paymentDueDay: d.Value((raw['paymentDueDay'] as num?)?.toInt()),
              bankName: d.Value(raw['bankName'] as String?),
              cardLastFour: d.Value(raw['cardLastFour'] as String?),
              note: d.Value(raw['note'] as String?),
              syncId: d.Value(syncId),
              hidden:
                  hidden == null ? const d.Value.absent() : d.Value(hidden),
            ));
          } else {
            localId = await db.into(db.accounts).insert(
                  AccountsCompanion.insert(
                    ledgerId: 0, // user-global 约定，同 _applyAccountChange
                    name: name,
                    type: d.Value(type),
                    currency: d.Value(currency),
                    initialBalance: d.Value(initialBalance),
                    sortOrder: d.Value(sortOrder),
                    creditLimit: d.Value(creditLimit),
                    billingDay: d.Value((raw['billingDay'] as num?)?.toInt()),
                    paymentDueDay:
                        d.Value((raw['paymentDueDay'] as num?)?.toInt()),
                    bankName: d.Value(raw['bankName'] as String?),
                    cardLastFour: d.Value(raw['cardLastFour'] as String?),
                    note: d.Value(raw['note'] as String?),
                    syncId: d.Value(syncId),
                    hidden: d.Value(hidden ?? false),
                  ),
                );
          }
          await changeTracker.recordPulledFromServer(
            entityType: 'account',
            entityId: localId,
            entitySyncId: syncId,
            ledgerId: 0,
          );
          restoredAccounts++;
        }

        // 删除快照里没有的行（含 NULL syncId 残留、同 syncId 的重复行）
        final rows = await (db.select(db.accounts)
              ..orderBy([(a) => d.OrderingTerm.asc(a.id)]))
            .get();
        final seen = <String>{};
        final extraIds = <int>[];
        final extraSyncIds = <String>[];
        for (final a in rows) {
          final s = a.syncId;
          if (s != null && snapSyncIds.contains(s)) {
            if (!seen.add(s)) {
              extraIds.add(a.id);
              extraSyncIds.add(s);
            }
          } else {
            extraIds.add(a.id);
            if (s != null) extraSyncIds.add(s);
          }
        }
        if (extraIds.isNotEmpty) {
          // 残留 change 全清（含老 pushed marker），防 push 复活已删实体
          await (db.delete(db.localChanges)
                ..where((c) => c.entityType.equals('account') &
                    c.entitySyncId.isIn(extraSyncIds)))
              .go();
          await (db.delete(db.accounts)..where((a) => a.id.isIn(extraIds)))
              .go();
          deletedAccounts = extraIds.length;
        }
      }

      // ---------- 分类（先一级后二级，二级挂父） ----------
      if (categoriesRaw != null) {
        final maps =
            categoriesRaw.whereType<Map<String, dynamic>>().toList();
        final snapSyncIds = <String>{};
        final level1 = <Map<String, dynamic>>[];
        final level2 = <Map<String, dynamic>>[];
        for (final raw in maps) {
          final syncId = (raw['syncId'] as String?)?.trim();
          if (syncId == null || syncId.isEmpty) continue;
          snapSyncIds.add(syncId);
          final parentName = raw['parentName'] as String?;
          if ((raw['level'] as num?)?.toInt() == 2 &&
              parentName != null &&
              parentName.isNotEmpty) {
            level2.add(raw);
          } else {
            level1.add(raw);
          }
        }

        Future<int> upsertCategory(Map<String, dynamic> raw,
            {required bool isLevel2}) async {
          final syncId = (raw['syncId'] as String?)!.trim();
          final name = raw['name'] as String? ?? '';
          final kind = raw['kind'] as String? ?? 'expense';
          final level = isLevel2 ? 2 : ((raw['level'] as num?)?.toInt() ?? 1);
          final sortOrder = (raw['sortOrder'] as num?)?.toInt() ?? 0;
          final icon = raw['icon'] as String?;
          final iconType = raw['iconType'] as String? ?? 'material';

          int? parentId;
          if (isLevel2) {
            final parentName = raw['parentName'] as String?;
            if (parentName != null && parentName.isNotEmpty) {
              final parent = await (db.select(db.categories)
                    ..where((c) => c.name.equals(parentName))
                    ..where((c) => c.kind.equals(kind))
                    ..where((c) => c.level.equals(1))
                    ..limit(1))
                  .getSingleOrNull();
              parentId = parent?.id;
            }
          }

          var existing = await (db.select(db.categories)
                ..where((c) => c.syncId.equals(syncId))
                ..limit(1))
              .getSingleOrNull();
          if (existing == null && name.isNotEmpty) {
            existing = await (db.select(db.categories)
                  ..where((c) => c.name.equals(name))
                  ..where((c) => c.kind.equals(kind))
                  ..where((c) => c.syncId.isNull())
                  ..limit(1))
                .getSingleOrNull();
          }

          // 自定义图标:快照里的 customIconPath 是 A 端本地路径,绝不能直接落
          // (照抄 _applyCategoryChange §Phase 3):本地已含 cloudFileId → 保留;
          // 否则写 null 并入队下载,drain 后写本地真实路径。
          final cloudFileId = raw['iconCloudFileId'] as String?;
          String? resolvedCustomIconPath;
          var needIconDownload = false;
          if (iconType == 'custom' &&
              cloudFileId != null &&
              cloudFileId.isNotEmpty) {
            if (existing != null &&
                (existing.customIconPath ?? '').contains(cloudFileId)) {
              resolvedCustomIconPath = existing.customIconPath;
            } else {
              needIconDownload = true;
            }
          }

          int localId;
          if (existing != null) {
            localId = existing.id;
            await (db.update(db.categories)
                  ..where((c) => c.id.equals(localId)))
                .write(CategoriesCompanion(
              name: d.Value(name),
              kind: d.Value(kind),
              level: d.Value(level),
              sortOrder: d.Value(sortOrder),
              icon: d.Value(icon),
              iconType: d.Value(iconType),
              customIconPath: d.Value(resolvedCustomIconPath),
              communityIconId:
                  d.Value(raw['communityIconId'] as String?),
              parentId: d.Value(parentId),
              syncId: d.Value(syncId),
            ));
          } else {
            localId = await db.into(db.categories).insert(
                  CategoriesCompanion.insert(
                    name: name,
                    kind: kind,
                    level: d.Value(level),
                    sortOrder: d.Value(sortOrder),
                    icon: d.Value(icon),
                    iconType: d.Value(iconType),
                    customIconPath: d.Value(resolvedCustomIconPath),
                    communityIconId:
                        d.Value(raw['communityIconId'] as String?),
                    parentId: d.Value(parentId),
                    syncId: d.Value(syncId),
                  ),
                );
          }
          if (needIconDownload && cloudFileId != null) {
            pendingCustomIconJobs.add(CustomIconDownloadJob(
              categoryId: localId,
              cloudFileId: cloudFileId,
              expectedPath: raw['customIconPath'] as String?,
            ));
          }
          await changeTracker.recordPulledFromServer(
            entityType: 'category',
            entityId: localId,
            entitySyncId: syncId,
            ledgerId: 0,
          );
          return localId;
        }

        for (final raw in level1) {
          await upsertCategory(raw, isLevel2: false);
          restoredCategories++;
        }
        for (final raw in level2) {
          await upsertCategory(raw, isLevel2: true);
          restoredCategories++;
        }

        // 删除快照里没有的分类:子先于父(与 _applyCategoryChange delete 一致),
        // 图标文件先清理(行删了就查不到路径),被删父分类下幸存的子分类脱挂。
        final rows = await (db.select(db.categories)
              ..orderBy([(c) => d.OrderingTerm.asc(c.id)]))
            .get();
        final seen = <String>{};
        final extraIds = <int>[];
        final extraSyncIds = <String>[];
        final extraChildIds = <int>[]; // 有父的先删
        for (final c in rows) {
          final s = c.syncId;
          final isDup = s != null && snapSyncIds.contains(s) && !seen.add(s);
          final isExtra = s == null || !snapSyncIds.contains(s) || isDup;
          if (!isExtra) continue;
          extraIds.add(c.id);
          if (s != null) extraSyncIds.add(s);
          if (c.parentId != null) extraChildIds.add(c.id);
        }
        if (extraIds.isNotEmpty) {
          // 只清被删行自身的图标文件 —— 不能用 _cleanupCategoryIconFilesOnDisk,
          // 它会把被删父分类下**幸存**子分类的图标文件一并删掉(pull 场景子行
          // 必然同删,这里子行会保留,删了文件图标就断了)。
          final extraRows =
              await (db.select(db.categories)..where((c) => c.id.isIn(extraIds)))
                  .get();
          final iconPaths = <String>[];
          for (final r in extraRows) {
            final cp = r.customIconPath;
            if (cp != null && cp.trim().isNotEmpty) iconPaths.add(cp);
          }
          await (db.delete(db.localChanges)
                ..where((c) => c.entityType.equals('category') &
                    c.entitySyncId.isIn(extraSyncIds)))
              .go();
          if (extraChildIds.isNotEmpty) {
            await (db.delete(db.categories)
                  ..where((c) => c.id.isIn(extraChildIds)))
                .go();
          }
          final extraParentIds =
              extraIds.where((id) => !extraChildIds.contains(id)).toList();
          if (extraParentIds.isNotEmpty) {
            await (db.delete(db.categories)
                  ..where((c) => c.id.isIn(extraParentIds)))
                .go();
          }
          // 幸存子分类的父被删 → 脱挂,防止 parentId 悬挂
          await (db.update(db.categories)
                ..where((c) => c.parentId.isIn(extraIds)))
              .write(CategoriesCompanion(parentId: d.Value(null)));
          deletedCategories = extraIds.length;
          // 图标文件删除失败不影响 DB 状态(与 pull 的磁盘清理同策略)
          if (iconPaths.isNotEmpty) {
            try {
              final appDir = await getApplicationDocumentsDirectory();
              final iconDir = Directory('${appDir.path}/custom_icons');
              for (final rel in iconPaths) {
                final f = File('${iconDir.path}/${p.basename(rel)}');
                if (await f.exists()) {
                  try {
                    await f.delete();
                  } catch (e) {
                    logger.warning('SyncEngine',
                        'forceRestore: unlink custom icon failed ${p.basename(rel)}: $e');
                  }
                }
              }
            } catch (e) {
              logger.warning('SyncEngine', 'forceRestore: 清理分类图标文件失败', e);
            }
          }
        }
      }

      // ---------- 标签 ----------
      if (tagsRaw != null) {
        final snapSyncIds = <String>{};
        for (final raw in tagsRaw) {
          if (raw is! Map<String, dynamic>) continue;
          final syncId = (raw['syncId'] as String?)?.trim();
          if (syncId == null || syncId.isEmpty) continue;
          snapSyncIds.add(syncId);
          final name = raw['name'] as String? ?? '';
          final color = raw['color'] as String?;
          final sortOrder = (raw['sortOrder'] as num?)?.toInt() ?? 0;

          var existing = await (db.select(db.tags)
                ..where((t) => t.syncId.equals(syncId))
                ..limit(1))
              .getSingleOrNull();
          if (existing == null && name.isNotEmpty) {
            existing = await (db.select(db.tags)
                  ..where((t) => t.name.equals(name))
                  ..where((t) => t.syncId.isNull())
                  ..limit(1))
                .getSingleOrNull();
          }

          int localId;
          if (existing != null) {
            localId = existing.id;
            await (db.update(db.tags)..where((t) => t.id.equals(localId)))
                .write(TagsCompanion(
              name: d.Value(name),
              color: d.Value(color),
              sortOrder: d.Value(sortOrder),
              syncId: d.Value(syncId),
            ));
          } else {
            localId = await db.into(db.tags).insert(
                  TagsCompanion.insert(
                    name: name,
                    color: d.Value(color),
                    sortOrder: d.Value(sortOrder),
                    syncId: d.Value(syncId),
                  ),
                );
          }
          await changeTracker.recordPulledFromServer(
            entityType: 'tag',
            entityId: localId,
            entitySyncId: syncId,
            ledgerId: 0,
          );
          restoredTags++;
        }

        final rows = await (db.select(db.tags)
              ..orderBy([(t) => d.OrderingTerm.asc(t.id)]))
            .get();
        final seen = <String>{};
        final extraIds = <int>[];
        final extraSyncIds = <String>[];
        for (final t in rows) {
          final s = t.syncId;
          final isDup = s != null && snapSyncIds.contains(s) && !seen.add(s);
          final isExtra = s == null || !snapSyncIds.contains(s) || isDup;
          if (!isExtra) continue;
          extraIds.add(t.id);
          if (s != null) extraSyncIds.add(s);
        }
        if (extraIds.isNotEmpty) {
          await (db.delete(db.localChanges)
                ..where((c) => c.entityType.equals('tag') &
                    c.entitySyncId.isIn(extraSyncIds)))
              .go();
          await (db.delete(db.transactionTags)
                ..where((tt) => tt.tagId.isIn(extraIds)))
              .go();
          await (db.delete(db.tags)..where((t) => t.id.isIn(extraIds))).go();
          deletedTags = extraIds.length;
        }
      }
    });

    // 事务提交后:下载重建分类缺失的自定义图标(与 pull 同款异步 drain)
    if (pendingCustomIconJobs.isNotEmpty) {
      unawaited(drainCustomIconQueue());
    }

    logger.info('SyncEngine',
        'forceRestore user-global: 账户 $restoredAccounts(删$deletedAccounts) '
        '分类 $restoredCategories(删$deletedCategories) '
        '标签 $restoredTags(删$deletedTags)'
        '${skippedAccounts > 0 ? ' 金额非有限跳过 $skippedAccounts 个账户' : ''}');
    return (
      accounts: restoredAccounts,
      categories: restoredCategories,
      tags: restoredTags,
      deletedAccounts: deletedAccounts,
      deletedCategories: deletedCategories,
      deletedTags: deletedTags,
      skippedAccounts: skippedAccounts,
    );
  }

  /// 从 /sync/full 快照 JSON 的 `budgets` 数组重建预算（db 直写，不记 change）。
  ///
  /// 快照 budget 字段（见 server snapshot_builder.py）：
  ///   syncId / ledgerSyncId / type / categoryId(syncId) / amount / period /
  ///   startDay / enabled。分类预算的 categoryId 是 syncId，需换成本地 int id；
  /// 换不到则本预算跳过（等后续 pull 补）。
  ///
  /// 返回 (restored, skipped):skipped = 金额非有限被跳过的条数(缺陷 B)。
  Future<({int restored, int skipped})> _restoreBudgetsFromSnapshot(
      int ledgerId, String content) async {
    int restored = 0;
    int skipped = 0;
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        return (restored: 0, skipped: 0);
      }
      final budgetsRaw = decoded['budgets'];
      if (budgetsRaw is! List) return (restored: 0, skipped: 0);

      for (final raw in budgetsRaw) {
        if (raw is! Map<String, dynamic>) continue;
        final syncId = (raw['syncId'] as String?)?.trim();
        final amount = (raw['amount'] as num?)?.toDouble();
        if (syncId == null || syncId.isEmpty || amount == null) continue;

        // 缺陷 B(2026-10-11):预算金额守卫。与 repo 层 `_validateBudgetAmount`
        // 同口径,但**不抛** —— 跳过该条 + 告警 + 计数,快照里一条坏值不能让
        // 整次恢复失败(其它预算/交易/账户仍要恢复)。
        if (!_snapshotMoneyOk('budget', syncId, {'amount': amount})) {
          skipped++;
          continue;
        }

        final type = (raw['type'] as String?) ?? 'total';
        final period = (raw['period'] as String?) ?? 'monthly';
        final startDay = (raw['startDay'] as num?)?.toInt() ?? 1;
        final enabled = raw['enabled'] == true;

        // 分类预算：categoryId 是 syncId，换成本地 int id。
        int? categoryId;
        if (type == 'category') {
          final catSyncId = (raw['categoryId'] as String?)?.trim();
          categoryId = await _resolveCategoryIdBySyncId(catSyncId);
          if (categoryId == null) {
            logger.warning('SyncEngine',
                'forceRestoreFromServer: 预算 $syncId 的分类 syncId=$catSyncId 本地未就绪，跳过');
            continue;
          }
        }

        await db.into(db.budgets).insert(BudgetsCompanion.insert(
              ledgerId: ledgerId,
              syncId: d.Value(syncId),
              type: d.Value(type),
              categoryId: d.Value(categoryId),
              amount: amount,
              period: d.Value(period),
              startDay: d.Value(startDay),
              enabled: d.Value(enabled),
            ));
        restored++;
      }
    } catch (e, st) {
      logger.error('SyncEngine', 'forceRestoreFromServer: 预算重建失败', e, st);
    }
    if (skipped > 0) {
      logger.warning('SyncEngine',
          'forceRestoreFromServer: 预算跳过 $skipped 条(金额非有限,已不入库)');
    }
    return (restored: restored, skipped: skipped);
  }

  /// 缺陷 B(2026-10-11):快照恢复路径的金额守卫判据(非有限值)。
  ///
  /// forceRestoreFromServer 由用户手动触发(「以服务端为准」),此前直接
  /// `db.into(...).insert(...)` —— 快照 JSON 里 `{"amount": 1e999}` 语法合法
  /// 但解码为 Infinity,会原样落库(SQLite REAL 接受 Inf),随后
  /// `getBudgetUsage` 返回 budget=Infinity / remaining=Infinity / status=normal,
  /// 余额与净资产聚合全部污染。
  ///
  /// 策略与 repo 层 `LocalTransactionRepository.validateMonetaryFinite` /
  /// `validateAccountAmounts` / `validateAdjustmentAmounts` 同口径(非有限即
  /// 违规),但**处理方式不同**:恢复路径选择**跳过该条 + 告警 + 计数**
  /// (返回的 restored* 计数里自然反映),而不是抛错 —— 一份部分损坏的快照
  /// 仍应恢复其余实体,不能因一条坏值整次恢复失败。
  ///
  /// 与 pull-apply 的 `_skipPulledMoneyIfInvalid` 同样"跳过不抛",区别是
  /// 这里没有 change 可登记([pullErrors] 是 change_id 维度的),故用日志 +
  /// 计数作为可观测面。
  ///
  /// 判据与 repo 层同口径(**只拒非有限值**):`local_account_repository.dart`
  /// 的 `validateAccountAmounts` / `validateAdjustmentAmounts`、
  /// `local_budget_repository.dart` 的 `_validateBudgetAmount` 都只拦
  /// NaN/±Infinity,不设量级上限、不拒负数(调整/预算的负值是合法语义)。
  /// 这里刻意不调它们:那些是各自类的静态入口(且本文件与它们是 part/独立类
  /// 关系),按 entity 拆三份反而更容易漂移;同一「只拒非有限」判据在本文件
  /// 内聚成一处。
  bool _snapshotMoneyOk(String entity, String syncId,
      Map<String, double?> fields) {
    for (final e in fields.entries) {
      final v = e.value;
      if (v != null && !v.isFinite) {
        logger.warning('SyncEngine',
            'forceRestoreFromServer: 跳过 $entity $syncId —— 快照 ${e.key}=$v '
            '非有限(NaN/Infinity 会污染余额/预算聚合);其余实体照常恢复');
        return false;
      }
    }
    return true;
  }

  /// 从 /sync/full 快照 JSON 的 `accountAdjustments` 数组重建余额调整记录
  /// (db 直写,不记 change;v42)。字段见 server snapshot_builder.py:
  /// syncId / accountId(账户 syncId) / amount(带符号) / balanceBefore /
  /// balanceAfter / happenedAt / createdAt / note。
  /// 账户 syncId 解析不到本地 int id 时落 accountSyncIdOverride(与增量
  /// apply 同语义),不跳过 —— 调整记录丢一条余额就永久错位。
  ///
  /// 返回 (restored, skipped):skipped = 金额非有限被跳过的条数(缺陷 B)。
  Future<({int restored, int skipped})> _restoreAccountAdjustmentsFromSnapshot(
      int ledgerId, String content) async {
    int restored = 0;
    int skipped = 0;
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        return (restored: 0, skipped: 0);
      }
      final adjRaw = decoded['accountAdjustments'];
      if (adjRaw is! List) return (restored: 0, skipped: 0);

      for (final raw in adjRaw) {
        if (raw is! Map<String, dynamic>) continue;
        final syncId = (raw['syncId'] as String?)?.trim();
        final amount = (raw['amount'] as num?)?.toDouble();
        if (syncId == null || syncId.isEmpty || amount == null) continue;

        final accountSyncId = (raw['accountId'] as String?)?.trim();
        final balanceBefore = (raw['balanceBefore'] as num?)?.toDouble();
        final balanceAfter = (raw['balanceAfter'] as num?)?.toDouble();
        // 缺陷 B(2026-10-11):调整三列金额守卫(带符号,只拦非有限)。
        // 与 repo 层 `validateAdjustmentAmounts` 同口径,但**不抛** —— 跳过该条
        // + 告警 + 计数(快照里一条坏值不能让整次恢复失败)。
        if (!_snapshotMoneyOk('account_adjustment', syncId, {
          'amount': amount,
          'balanceBefore': balanceBefore,
          'balanceAfter': balanceAfter,
        })) {
          skipped++;
          continue;
        }
        final localAccountId =
            await _resolveAccountIdBySyncId(accountSyncId);
        final happenedAt =
            DateTime.tryParse(raw['happenedAt']?.toString() ?? '');
        final recordedAt =
            DateTime.tryParse(raw['createdAt']?.toString() ?? '');

        await db.into(db.accountAdjustments).insert(
              AccountAdjustmentsCompanion.insert(
                syncId: d.Value(syncId),
                ledgerId: ledgerId,
                accountId: localAccountId ?? 0,
                accountSyncIdOverride:
                    d.Value(localAccountId == null ? accountSyncId : null),
                amount: amount,
                balanceBefore: d.Value(balanceBefore),
                balanceAfter: d.Value(balanceAfter),
                happenedAt:
                    d.Value(happenedAt ?? DateTime.now()),
                recordedAt: d.Value(recordedAt),
                note: d.Value(raw['note'] as String?),
              ),
            );
        restored++;
      }
    } catch (e, st) {
      logger.error('SyncEngine', 'forceRestoreFromServer: 余额调整重建失败', e, st);
    }
    if (skipped > 0) {
      logger.warning('SyncEngine',
          'forceRestoreFromServer: 余额调整跳过 $skipped 条(金额非有限,已不入库)');
    }
    return (restored: restored, skipped: skipped);
  }

  // ==================== 附件云端同步 ====================
  //
  // uploadAttachments / downloadAttachments / _getAttachmentFile
  // _cleanupTxAttachmentFilesOnDisk / _cleanupCategoryIconFilesOnDisk
  // 这些方法都搬到 sync_engine_attachments.dart 这个 part 文件里了。
}

/// 一组 local/remote 计数。-1 表示拉不到(网络错 / 老 server 没这个字段)。
class SyncCountPair {
  const SyncCountPair({required this.local, required this.remote});
  const SyncCountPair.missing()
      : local = 0,
        remote = -1;
  final int local;
  final int remote;
  bool get hasDiff => remote >= 0 && local != remote;
}

/// 深度同步检测报告。UI 分两组展示:
/// - `当前账本`:tx / attachment / budget,随 current ledger 走
/// - `全部账本`:上面三项的全量合计,以及 account / category / tag 这些用户级
///   实体(per-ledger 跟 total 同值)
class SyncHealthReport {
  const SyncHealthReport({
    required this.ledgerTx,
    required this.ledgerAttachments,
    required this.ledgerBudgets,
    required this.totalTx,
    required this.totalAttachments,
    required this.totalBudgets,
    required this.categoryAttachments,
    required this.accounts,
    required this.categories,
    required this.tags,
    required this.unpushedChanges,
    this.error,
  });

  factory SyncHealthReport.error(String message) => const SyncHealthReport(
        ledgerTx: SyncCountPair.missing(),
        ledgerAttachments: SyncCountPair.missing(),
        ledgerBudgets: SyncCountPair.missing(),
        totalTx: SyncCountPair.missing(),
        totalAttachments: SyncCountPair.missing(),
        totalBudgets: SyncCountPair.missing(),
        categoryAttachments: SyncCountPair.missing(),
        accounts: SyncCountPair.missing(),
        categories: SyncCountPair.missing(),
        tags: SyncCountPair.missing(),
        unpushedChanges: 0,
      ).copyWithError(message);

  SyncHealthReport copyWithError(String message) => SyncHealthReport(
        ledgerTx: ledgerTx,
        ledgerAttachments: ledgerAttachments,
        ledgerBudgets: ledgerBudgets,
        totalTx: totalTx,
        totalAttachments: totalAttachments,
        totalBudgets: totalBudgets,
        categoryAttachments: categoryAttachments,
        accounts: accounts,
        categories: categories,
        tags: tags,
        unpushedChanges: unpushedChanges,
        error: message,
      );

  /// 当前账本口径。`ledgerAttachments` 只算交易附件(server 端
  /// `attachment_kind='transaction'`),分类自定义图标见 [categoryAttachments]。
  final SyncCountPair ledgerTx;
  final SyncCountPair ledgerAttachments;
  final SyncCountPair ledgerBudgets;

  /// 全量口径(跨当前用户所有账本)。`totalAttachments` 同样只算交易附件。
  final SyncCountPair totalTx;
  final SyncCountPair totalAttachments;
  final SyncCountPair totalBudgets;

  /// 分类自定义图标 — user-global,不分账本。server 端 `attachment_kind=
  /// 'category_icon'`,跨账本只占一份存储。
  final SyncCountPair categoryAttachments;

  /// 用户级实体(per-ledger 跟 total 同值,只留一组)
  final SyncCountPair accounts;
  final SyncCountPair categories;
  final SyncCountPair tags;

  final int unpushedChanges;
  final String? error;

  bool get hasDiff {
    if (error != null) return false;
    if (unpushedChanges > 0) return true;
    return ledgerTx.hasDiff ||
        ledgerAttachments.hasDiff ||
        ledgerBudgets.hasDiff ||
        totalTx.hasDiff ||
        totalAttachments.hasDiff ||
        totalBudgets.hasDiff ||
        categoryAttachments.hasDiff ||
        accounts.hasDiff ||
        categories.hasDiff ||
        tags.hasDiff;
  }

  /// 本地比远端多,但没 unpushed change → 绕过 changeTracker 的历史种子数据。
  bool get needsBackfill {
    if (error != null || unpushedChanges > 0) return false;
    if (accounts.remote >= 0 && accounts.local > accounts.remote) return true;
    if (categories.remote >= 0 && categories.local > categories.remote)
      return true;
    if (tags.remote >= 0 && tags.local > tags.remote) return true;
    return false;
  }
}

/// pull 单页处理结果。详见 [SyncEngine._applyPullPage]。
class _PullPageOutcome {
  const _PullPageOutcome({
    required this.applied,
    required this.blocked,
    this.deferred = 0,
    this.resolveChangeIds = const {},
    this.abandoned = const [],
  });

  /// 本页成功 apply 的条数。整页 rollback 时为 0。
  final int applied;

  /// 是否被错误阻塞(整页 rollback,cursor 不推进)。
  final bool blocked;

  /// U-08(2026-10-11):本页"依赖未就绪被推迟"的条数(apply 返 false 且
  /// 落入 [SyncEngine._deferredChangeIds])。>0 时 cursor 必须**停在页首**,
  /// 留待下一轮 pull 重放 —— 这是"budget / account_adjustment 因 ledger
  /// 未就绪被跳过却推进 cursor → 永久丢失"的解法(阻断-4)。
  final int deferred;

  /// 本页可与旧语义一致地 markResolved 的 change_id:本轮**没有登记 deferred**
  /// 的条目(真正落地成功,或按设计跳过 —— 自己设备的 change / 未知
  /// entityType)。
  ///
  /// `_runPullLoop` 的 markResolved 循环只清这个集合里的 id —— 推迟 / 放弃
  /// 的 change 没有落地,它们的错误行必须在 `watchUnresolved()`(UI 面)存活。
  /// 2026-10-11 复现缺陷:旧实现无条件清本页**所有** change_id,导致安全阀
  /// 同轮 record+resolve,UI 永远看不到放弃记录。
  final Set<int> resolveChangeIds;

  /// 本页安全阀判定"依赖不会到达、放弃重放"的 change。
  ///
  /// 错误行已由 [_applyPullPage] 在页事务 commit 后写好(`error_class =
  /// DeferredGiveUp`、`resolved_at IS NULL`);这里保留列表只为日志/返回口径。
  /// 调用方的 markResolved 循环靠 [resolveChangeIds] 天然跳过它们。
  final List<SmartBookCloudSyncChange> abandoned;
}
