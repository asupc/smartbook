part of 'sync_engine.dart';

/// Pull 路径的恢复机制:**app 侧 cursor** + **失败 change 持久化**。
///
/// 改造前(详见 `.docs/full-pull-refactor/01-current-state.md` §3.1):
/// flutter_cloud_sync 包内 `pullChanges` 解码完立刻 `_saveCursor`,早于
/// app 端 apply。apply 抛错时整页 rollback,但 cursor 已跳到下一页 → 这页
/// 的 change 再也拉不回,用户只能卸载重装。
///
/// 改造:
/// 1. cloud-sync 包 `pullChanges` 加 `persistCursor: false` 参数
/// 2. app 调 `pullChanges(persistCursor: false)`,自己读 [AppCursorStore],
///    apply 成功后才 commit
/// 3. apply 失败 → [SyncErrorStore.record] 持久化错误供 UI 展示
///
/// 这两个 store 都是数据层薄 DAO,跟主类同 library 走 part,SyncEngine 持有
/// 它们的实例 (`appCursor` / `pullErrors` 字段),pull 路径内部用。

// =====================================================================
// AppCursorStore
// =====================================================================

/// app 侧维护的 pull cursor 管理。语义见上面 part 注释。
class AppCursorStore {
  AppCursorStore(this._provider);

  final SmartBookCloudProvider _provider;

  /// U-03(2026-10-11):服务端 cursor 的"合理"上界,读侧自愈用。
  ///
  /// `server_cursor` 本质是服务端 `sync_changes.change_id`(int64 自增)。
  /// 一次异常响应(server bug / 反向代理串响应 / 中间人)返回一个天文数字
  /// 后,旧实现原样采信 → 之后每轮 pull 都带 `since=<天文数字>`,真实服务端
  /// `change_id > since` 恒不成立 → 恒返空页,同步**静默死亡**(无报错、
  /// 无告警、无 UI 提示),只能清 App 数据自救。
  ///
  /// 取值 2^61:即使服务端每天写 1 亿条 change,也要 6 万多年才能到达;
  /// 正常增量同步的 cursor(几万~几百亿)远在阈值之下,不会被误伤。
  ///
  /// **读侧**使用(写侧只拦负数,见 [commit]):`2^63-1` 是 int64 的合法边界,
  /// 写侧放行以保持"commit 只做域校验、不臆断服务端"的语义 —— 但只要它
  /// 超过本阈值,pull 入口就把游标重置为 0 重放对齐,保证**可自愈**。
  static const int maxReasonableCursor = 0x2000000000000000; // 2^61

  /// 读取当前 cursor。未登录返 0(等价"从头开始")。
  Future<int> read() async {
    final key = await _key();
    if (key == null) return 0;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(key) ?? 0;
  }

  /// 把 cursor **单调推进**到指定值,返回实际生效的 cursor。
  /// **只在整页 apply 成功后调**。
  ///
  /// U-01..U-03(2026-10-11)写入口校验,任一不过则**保持原值**并告警:
  /// 1. 负数(以及超出 int64 的值,Dart int 本身是 64 位有符号,该分支只是
  ///    显式表达域边界)拒绝 —— 防 U-02 `since=-3` 触发服务端全量重放;
  /// 2. 非前进(`cursor <= current`)拒绝 —— 防 U-01 服务端 cursor 回退把本地
  ///    已推进的 cursor 写回退(历史重放 + 已 resolve 的错误被重新拉起)。
  ///
  /// 校验放在 commit(写入口)而不是 read(读取口):坏值一旦落盘就跨进程
  /// 存活,必须在落盘前拦住。合法但倒退的 cursor(服务端 bug)也绝不落盘。
  Future<int> commit(int cursor) async {
    final key = await _key();
    if (key == null) return 0;
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getInt(key) ?? 0;

    if (cursor < 0 || cursor > _maxInt64) {
      logger.warning(
          'AppCursorStore',
          '拒绝异常 serverCursor=$cursor(合法域 0..$_maxInt64),'
          'cursor 保持 $current —— 防止负值触发全量重放');
      return current;
    }
    if (cursor <= current) {
      if (cursor < current) {
        logger.warning(
            'AppCursorStore',
            'serverCursor 回退($cursor <= 本地 $current),cursor 保持 $current'
            '(单调不减)');
      }
      return current;
    }
    await prefs.setInt(key, cursor);
    return cursor;
  }

  /// 强制把 cursor 写成给定值(绕过单调校验)。**只给读侧自愈用** ——
  /// pull 入口发现落盘值是负数 / 超过 [maxReasonableCursor](旧版本写入的
  /// 坏值,升级后仍存活)时,重置为 0 从头重放(幂等 upsert,不丢数据)。
  Future<void> forceReset(int cursor) async {
    final key = await _key();
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, cursor);
  }

  static const int _maxInt64 = 0x7FFFFFFFFFFFFFFF; // 2^63-1

  /// Phase 2 上线时一次性迁移:把 cloud-sync 包内的 provider cursor 复制到
  /// app cursor key。已迁移过(app key 已存在)则 no-op。
  Future<void> migrateFromProviderCursor() async {
    final appKey = await _key();
    if (appKey == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getInt(appKey) != null) return;
    final providerKey = await _providerKey();
    if (providerKey == null) return;
    final providerCursor = prefs.getInt(providerKey);
    if (providerCursor != null && providerCursor > 0) {
      await prefs.setInt(appKey, providerCursor);
      logger.info('AppCursorStore',
          '复制 provider cursor → app cursor: $providerCursor');
    }
  }

  Future<String?> _key() async {
    final auth = _provider.auth as SmartBookCloudAuthService;
    final userId = auth.currentUserId;
    final deviceId = auth.currentDeviceId;
    if (userId == null || deviceId == null) return null;
    final baseUrl = _provider.baseUrl ?? 'unknown';
    final raw = '$baseUrl|$userId|$deviceId';
    final digest = sha1.convert(utf8.encode(raw)).toString();
    return 'app_pull_cursor_$digest';
  }

  Future<String?> _providerKey() async {
    final auth = _provider.auth as SmartBookCloudAuthService;
    final userId = auth.currentUserId ?? 'unknown';
    final deviceId = auth.currentDeviceId ?? 'unknown';
    final baseUrl = _provider.baseUrl ?? 'unknown';
    final apiPrefix = _provider.apiPrefix ?? 'unknown';
    final raw = '$baseUrl|$apiPrefix|$userId|$deviceId';
    final digest = sha1.convert(utf8.encode(raw)).toString();
    final key = 'smartbook_cloud_pull_cursor_$digest';
    // 品牌更名前 key 前缀为 'beecount_cloud_pull_cursor_',读旧值迁移。
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getInt(key) == null) {
      final legacy = prefs.getInt('beecount_cloud_pull_cursor_$digest');
      if (legacy != null) {
        await prefs.setInt(key, legacy);
        await prefs.remove('beecount_cloud_pull_cursor_$digest');
      }
    }
    return key;
  }
}

// =====================================================================
// SyncErrorStore
// =====================================================================

/// `sync_pull_errors` 表的 DAO。
///
/// pull 路径上整页 apply 抛错(不可恢复异常,例如 TypeError /
/// FormatException / FK 解析失败)时,把"造成失败的 change + 错误信息"写入
/// 这张表。UI 据此显示 banner + 详情列表,**只读不可处置** —— SmartBook Cloud
/// 的核心是全自动同步,不引入"跳过"等人工干预入口。开发者从 server log 按
/// change_id 修脏数据 + 推新版本,app 自然下发新 change 后覆盖。
class SyncErrorStore {
  SyncErrorStore(this._db);

  final BeeDatabase _db;

  /// 记录一条 apply 失败。同 [change.changeId] 已存在 → attempt_count++。
  ///
  /// 旧实现 `select existing → if null insert / else update` 在并发场景下有
  /// race(两个 pull 同时跑,都 select 到 null,都 insert,第二个撞 UNIQUE)。
  /// 改成 **update-first**:先按 changeId 尝试 update,affected=0 才 insert,
  /// insert 失败再降级为 update。
  Future<void> record({
    required SmartBookCloudSyncChange change,
    required Object error,
    required StackTrace stackTrace,
  }) async {
    final now = DateTime.now().toUtc();
    final errClass = error.runtimeType.toString();
    final errMessage = _firstLine(error.toString());
    final stackStr = _truncate(stackTrace.toString(), 2048);

    // 步骤 1:update。已存在 → attempt_count + 1 由 customStatement 完成
    // (Drift `.write()` 不支持引用现有列做加法,所以走 raw SQL)。
    final affected = await _db.customUpdate(
      'UPDATE sync_pull_errors '
      'SET attempt_count = attempt_count + 1, '
      '    last_attempt_at = ?, '
      '    error_class = ?, '
      '    error_message = ?, '
      '    stack_trace = ? '
      'WHERE change_id = ?',
      variables: [
        d.Variable<DateTime>(now),
        d.Variable<String>(errClass),
        d.Variable<String>(errMessage),
        d.Variable<String>(stackStr),
        d.Variable<int>(change.changeId),
      ],
      updates: {_db.syncPullErrors},
    );
    if (affected > 0) return;

    // 步骤 2:不存在 → insert。并发场景下可能撞 UNIQUE,catch 后降级 update。
    try {
      await _db.into(_db.syncPullErrors).insert(SyncPullErrorsCompanion.insert(
            changeId: change.changeId,
            ledgerExternalId:
                d.Value(change.ledgerId.isEmpty ? null : change.ledgerId),
            entityType: change.entityType,
            entitySyncId: change.entitySyncId,
            action: change.action,
            rawChangeJson: _encodeChange(change),
            errorClass: d.Value(errClass),
            errorMessage: d.Value(errMessage),
            stackTrace: d.Value(stackStr),
            firstSeenAt: now,
            lastAttemptAt: now,
          ));
      logger.warning('SyncErrorStore',
          '新增 pull error: change_id=${change.changeId} type=${change.entityType} err=$errClass');
    } catch (e) {
      // UNIQUE constraint(并发 record 同 change_id)— 已被另一路径插入,
      // 用同样的 customUpdate 增量更新计数。
      await _db.customUpdate(
        'UPDATE sync_pull_errors '
        'SET attempt_count = attempt_count + 1, last_attempt_at = ? '
        'WHERE change_id = ?',
        variables: [
          d.Variable<DateTime>(now),
          d.Variable<int>(change.changeId),
        ],
        updates: {_db.syncPullErrors},
      );
    }
  }

  /// 后台 apply 成功(server 端修了脏数据 + 推新 change → apply 通过)→
  /// 自动 resolve 历史记录,UI 不再显示这条。
  Future<void> markResolved(int changeId) async {
    await (_db.update(_db.syncPullErrors)
          ..where((t) => t.changeId.equals(changeId))
          ..where((t) => t.resolvedAt.isNull()))
        .write(SyncPullErrorsCompanion(
      resolvedAt: d.Value(DateTime.now().toUtc()),
    ));
  }

  /// 记录一条"安全阀放弃重放"(deferred give-up):依赖([maxDeferredReplays]
  /// 轮内)始终未到达,引擎判定重放无望,**放弃该 change 并放行 cursor**。
  ///
  /// 与 [record] 的两点关键差异(2026-10-11 复现缺陷修复):
  /// 1. **强制复活**:无论该 change_id 是否已有历史行(哪怕已 resolved),
  ///    都把 `resolved_at` 清成 NULL。放弃是"这条 change 当前仍未落地"的
  ///    事实状态,必须在 UI 查询面([watchUnresolved])里可见 —— 旧实现的
  ///    缺陷正是同一轮 record 后立刻被 markResolved 清掉,UI 永远看不到。
  /// 2. `errorClass` 固定为 [DeferredGiveUp](不取 runtimeType),UI / 诊断
  ///    脚本可按它机器区分"放弃重放"与普通 apply 失败;`userAction` 不写
  ///    (该列语义是用户处置动作,null = 尚未处置,与"只读不可处置"设计一致)。
  Future<void> recordDeferredGiveUp({
    required SmartBookCloudSyncChange change,
    required Object error,
    required StackTrace stackTrace,
  }) async {
    final now = DateTime.now().toUtc();
    const errClass = 'DeferredGiveUp';
    final errMessage = _firstLine(error.toString());
    final stackStr = _truncate(stackTrace.toString(), 2048);

    // update-first(与 record 同 race 策略),额外清 resolved_at 复活旧行。
    final affected = await _db.customUpdate(
      'UPDATE sync_pull_errors '
      'SET attempt_count = attempt_count + 1, '
      '    last_attempt_at = ?, '
      '    error_class = ?, '
      '    error_message = ?, '
      '    stack_trace = ?, '
      '    resolved_at = NULL '
      'WHERE change_id = ?',
      variables: [
        d.Variable<DateTime>(now),
        d.Variable<String>(errClass),
        d.Variable<String>(errMessage),
        d.Variable<String>(stackStr),
        d.Variable<int>(change.changeId),
      ],
      updates: {_db.syncPullErrors},
    );
    if (affected > 0) {
      logger.warning('SyncErrorStore',
          '放弃重放(复活既有行): change_id=${change.changeId} '
          'type=${change.entityType}(${change.entitySyncId})');
      return;
    }

    try {
      await _db.into(_db.syncPullErrors).insert(SyncPullErrorsCompanion.insert(
            changeId: change.changeId,
            ledgerExternalId:
                d.Value(change.ledgerId.isEmpty ? null : change.ledgerId),
            entityType: change.entityType,
            entitySyncId: change.entitySyncId,
            action: change.action,
            rawChangeJson: _encodeChange(change),
            errorClass: d.Value(errClass),
            errorMessage: d.Value(errMessage),
            stackTrace: d.Value(stackStr),
            firstSeenAt: now,
            lastAttemptAt: now,
          ));
      logger.warning('SyncErrorStore',
          '新增放弃重放记录: change_id=${change.changeId} '
          'type=${change.entityType}(${change.entitySyncId})');
    } catch (e) {
      // UNIQUE constraint(并发 record 同 change_id)→ 降级 update(含复活)。
      await _db.customUpdate(
        'UPDATE sync_pull_errors '
        'SET attempt_count = attempt_count + 1, last_attempt_at = ?, '
        '    error_class = ?, error_message = ?, resolved_at = NULL '
        'WHERE change_id = ?',
        variables: [
          d.Variable<DateTime>(now),
          d.Variable<String>(errClass),
          d.Variable<String>(errMessage),
          d.Variable<int>(change.changeId),
        ],
        updates: {_db.syncPullErrors},
      );
    }
  }

  /// 登记一条"金额/值不可用、被 pull-apply 主动跳过"的 change(缺陷 A,
  /// 2026-10-11 复现缺陷修复)。
  ///
  /// 与 [recordDeferredGiveUp] 同款可观测性契约,区别只在语义:
  /// - deferred give-up = 依赖(ledger)永远不到 → 放弃重放;
  /// - value skip = change 本身**不可落地**(非有限金额 / 折算值非有限),
  ///   重放也不会变好 → 跳过该条、cursor 照常推进。
  ///
  /// 两点关键差异(与 [record] 相比):
  /// 1. **强制复活**:`resolved_at = NULL`,哪怕该 change_id 已有历史行 ——
  ///    "该远端变更当前仍未落地"是事实状态,必须在 UI 查询面
  ///    ([watchUnresolved])可见,绝不能被同一轮的 markResolved 清成不可见;
  /// 2. `errorClass` 固定为 [PulledValueSkipped](不取 runtimeType),UI / 诊断
  ///    脚本可按它机器区分"值跳过"与普通 apply 失败 / 放弃重放;
  ///    `userAction` 不写(只读不可处置设计)。
  ///
  /// 该 change 之后真正 apply 成功(服务端修数据后推新 change / 全量重放命中
  /// 修正后的 payload)时,[markResolved] 自动清掉(自愈)。
  Future<void> recordPulledValueSkipped({
    required SmartBookCloudSyncChange change,
    required String reason,
  }) async {
    final now = DateTime.now().toUtc();
    const errClass = 'PulledValueSkipped';
    final errMessage = _truncate(_firstLine(reason), 2048);

    // update-first(与 record / recordDeferredGiveUp 同 race 策略),额外清
    // resolved_at 复活旧行 —— 跳过是"仍未落地"的事实状态,必须重新可见。
    final affected = await _db.customUpdate(
      'UPDATE sync_pull_errors '
      'SET attempt_count = attempt_count + 1, '
      '    last_attempt_at = ?, '
      '    error_class = ?, '
      '    error_message = ?, '
      '    resolved_at = NULL '
      'WHERE change_id = ?',
      variables: [
        d.Variable<DateTime>(now),
        d.Variable<String>(errClass),
        d.Variable<String>(errMessage),
        d.Variable<int>(change.changeId),
      ],
      updates: {_db.syncPullErrors},
    );
    if (affected > 0) {
      logger.warning('SyncErrorStore',
          '值跳过(复活既有行): change_id=${change.changeId} '
          'type=${change.entityType}(${change.entitySyncId}): $errMessage');
      return;
    }

    try {
      await _db.into(_db.syncPullErrors).insert(SyncPullErrorsCompanion.insert(
            changeId: change.changeId,
            ledgerExternalId:
                d.Value(change.ledgerId.isEmpty ? null : change.ledgerId),
            entityType: change.entityType,
            entitySyncId: change.entitySyncId,
            action: change.action,
            rawChangeJson: _encodeChange(change),
            errorClass: d.Value(errClass),
            errorMessage: d.Value(errMessage),
            // 值跳过没有异常,stack_trace 留 NULL(区别于 apply 失败)。
            firstSeenAt: now,
            lastAttemptAt: now,
          ));
      logger.warning('SyncErrorStore',
          '新增值跳过记录: change_id=${change.changeId} '
          'type=${change.entityType}(${change.entitySyncId}): $errMessage');
    } catch (e) {
      // UNIQUE constraint(并发 record 同 change_id)→ 降级 update(含复活)。
      await _db.customUpdate(
        'UPDATE sync_pull_errors '
        'SET attempt_count = attempt_count + 1, last_attempt_at = ?, '
        '    error_class = ?, error_message = ?, resolved_at = NULL '
        'WHERE change_id = ?',
        variables: [
          d.Variable<DateTime>(now),
          d.Variable<String>(errClass),
          d.Variable<String>(errMessage),
          d.Variable<int>(change.changeId),
        ],
        updates: {_db.syncPullErrors},
      );
    }
  }

  /// 登记一条"push 被服务端**终态**拒绝、本地 change 已被丢弃"的记录
  /// (中-1,2026-10-11 三轮复查)。
  ///
  /// 语义区别于前三个 record*:那些记录的是 **pull 侧**的 change(带服务端
  /// change_id);这里记录的是 **push 侧**被终态拒绝(`ledger_deleted` /
  /// `membership_revoked` / `unknown_ledger` / `sync_id_mismatch` /
  /// `entity_sync_id_too_long`)的本地 local_changes 行。重试这些 change 永远
  /// 不可能成功,所以修复策略是:**丢弃 + 持久化错误行**——绝不能像旧行为
  /// 那样留在 local_changes 无限重推(8 次/会话 + 每 30min 探测 + 重启计数
  /// 重置 → 服务端 load + 日志噪音 + unpushed 永不排水)。
  ///
  /// 与 [recordPulledValueSkipped] 同款可观测性契约:
  /// - **强制复活** `resolved_at = NULL`(放弃就是当前事实状态);
  /// - `error_class` 固定为 [pushTerminalRejectedErrorClass],UI / 诊断脚本
  ///   可机器区分;
  /// - change_id 哨兵 = [pushTerminalRejectedChangeIdBase] + local change id
  ///   (拼一个绝不与任何服务端 change_id 撞车的合成 key:服务端 change_id 是
  ///   sync_changes 自增 int,正常量级远小于 2^62;base 取 2^62)。
  /// - `rawChangeJson` 存完整诊断上下文(reason / entitySyncId / ledgerId /
  ///   local change ids 被丢弃清单)。
  ///
  /// 该实体之后用户重新编辑会产生**新** local change(新 id),自然获得新
  /// 机会;这条错误行保持未解决直到人工查看(没有自动 resolve 路径 —— 服务端
  /// 状态不会自己变回来,这正是"终态"的含义)。
  Future<void> recordPushTerminalRejected({
    required int localChangeId,
    required String entityType,
    required String entitySyncId,
    required String ledgerExternalId,
    required String reason,
    required List<int> droppedChangeIds,
  }) async {
    final now = DateTime.now().toUtc();
    final sentinelChangeId =
        pushTerminalRejectedChangeIdBase + localChangeId;
    final errMessage =
        '服务端终态拒绝(reason=$reason),已丢弃本地待推变更 '
        '${droppedChangeIds.length} 条(change ids=$droppedChangeIds)。'
        '该拒绝重试不可能成功(账本已删/成员资格已撤销/数据畸形),'
        '如需恢复请在服务端状态修复后重新编辑实体。';
    final rawJson = jsonEncode({
      'kind': 'push_terminal_rejected',
      'reason': reason,
      'entity_type': entityType,
      'entity_sync_id': entitySyncId,
      'ledger_id': ledgerExternalId,
      'dropped_local_change_ids': droppedChangeIds,
      'recorded_from_local_change_id': localChangeId,
    });

    // update-first(与 record* 家族同 race 策略),额外清 resolved_at 复活旧行。
    final affected = await _db.customUpdate(
      'UPDATE sync_pull_errors '
      'SET attempt_count = attempt_count + 1, '
      '    last_attempt_at = ?, '
      '    error_class = ?, '
      '    error_message = ?, '
      '    stack_trace = NULL, '
      '    resolved_at = NULL '
      'WHERE change_id = ?',
      variables: [
        d.Variable<DateTime>(now),
        d.Variable<String>(pushTerminalRejectedErrorClass),
        d.Variable<String>(errMessage),
        d.Variable<int>(sentinelChangeId),
      ],
      updates: {_db.syncPullErrors},
    );
    if (affected > 0) {
      logger.warning('SyncErrorStore',
          '终态拒绝(复活既有行): local_change=$localChangeId '
          '$entityType($entitySyncId) reason=$reason');
      return;
    }

    try {
      await _db.into(_db.syncPullErrors).insert(SyncPullErrorsCompanion.insert(
            changeId: sentinelChangeId,
            ledgerExternalId: d.Value(
                ledgerExternalId.isEmpty ? null : ledgerExternalId),
            entityType: entityType,
            entitySyncId: entitySyncId,
            action: 'push_terminal_rejected',
            rawChangeJson: rawJson,
            errorClass: d.Value(pushTerminalRejectedErrorClass),
            errorMessage: d.Value(errMessage),
            // 无异常栈:stack_trace 留 NULL(区别于 apply 失败)。
            firstSeenAt: now,
            lastAttemptAt: now,
          ));
      logger.warning('SyncErrorStore',
          '新增终态拒绝记录: local_change=$localChangeId '
          '$entityType($entitySyncId) reason=$reason '
          'dropped=${droppedChangeIds.length} 条');
    } catch (e) {
      // UNIQUE constraint(并发同实体被拒)→ 降级 update(含复活)。
      await _db.customUpdate(
        'UPDATE sync_pull_errors '
        'SET attempt_count = attempt_count + 1, last_attempt_at = ?, '
        '    error_class = ?, error_message = ?, resolved_at = NULL '
        'WHERE change_id = ?',
        variables: [
          d.Variable<DateTime>(now),
          d.Variable<String>(pushTerminalRejectedErrorClass),
          d.Variable<String>(errMessage),
          d.Variable<int>(sentinelChangeId),
        ],
        updates: {_db.syncPullErrors},
      );
    }
  }

  /// push 终态拒绝错误行的 change_id 哨兵基址。
  ///
  /// sync_pull_errors.change_id 对 pull 侧语义是「服务端 sync_changes.change_id
  /// (BigInteger 自增)」;push 侧的本地 local_changes.id 也是小整数,直接写
  /// 会撞 pull 错误行的 UNIQUE。基址取 2^62:Dart int 是 64 位有符号(上限
  /// 2^63-1),服务端真实 change_id 即使每天 1 亿条也要 250 万年才到 2^62,
  /// 合成 key 永不越界也永不撞车。
  static const int pushTerminalRejectedChangeIdBase = 0x4000000000000000;

  /// push 终态拒绝的 error_class 固定值(UI / 诊断脚本可机器区分)。
  static const String pushTerminalRejectedErrorClass = 'PushTerminalRejected';

  /// 未解决的"push 终态拒绝"条目 —— 与 [watchUnresolvedDeferredGiveUps]
  /// 同款的 distinct "needs attention" 查询面:这些 change 已被丢弃(不再
  /// 重推),用户/开发者需要知道"有 N 条本地编辑因服务端终态拒绝而放弃"。
  Stream<List<SyncPullError>> watchUnresolvedPushTerminalRejected() {
    return (_db.select(_db.syncPullErrors)
          ..where((t) => t.resolvedAt.isNull())
          ..where((t) => t.errorClass.equals(pushTerminalRejectedErrorClass))
          ..orderBy([(t) => d.OrderingTerm.asc(t.changeId)]))
        .watch();
  }

  /// 监听未解决错误(UI StreamProvider 用)。
  Stream<List<SyncPullError>> watchUnresolved() {
    return (_db.select(_db.syncPullErrors)
          ..where((t) => t.resolvedAt.isNull())
          ..orderBy([(t) => d.OrderingTerm.asc(t.changeId)]))
        .watch();
  }

  /// 未解决的"放弃重放"条目(error_class == [DeferredGiveUp])。
  ///
  /// 这是给 UI 的**distinct "needs attention" 查询面**:普通 apply 失败
  /// (脏 payload 等)会由服务端修数据 + 推新 change 自愈,而放弃重放意味着
  /// "本设备拿不到依赖实体",重试也无法解决 —— UI 若要单独提示"有 N 条远端
  /// 变更被跳过",用本 stream,不必解析 [watchUnresolved] 的行内容。
  /// 该 change 之后真正 apply 成功(账本可见 / 全量重放)时,[markResolved]
  /// 自动清掉它(自愈,无需人工)。
  Stream<List<SyncPullError>> watchUnresolvedDeferredGiveUps() {
    return (_db.select(_db.syncPullErrors)
          ..where((t) => t.resolvedAt.isNull())
          ..where((t) => t.errorClass.equals(_deferredGiveUpErrorClass))
          ..orderBy([(t) => d.OrderingTerm.asc(t.changeId)]))
        .watch();
  }

  static const String _deferredGiveUpErrorClass = 'DeferredGiveUp';

  String _firstLine(String s) {
    final idx = s.indexOf('\n');
    return idx < 0 ? s : s.substring(0, idx);
  }

  String _truncate(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}\n…(truncated)';
  }

  /// 把 change 编成诊断用 JSON。
  ///
  /// ⚠️ 缺陷 A 副作用修复(2026-10-11):pull-apply 的**值跳过**登记恰恰发生在
  /// payload 含非有限金额时 —— 裸 `jsonEncode` 对 Infinity/NaN 抛
  /// `JsonUnsupportedObjectError`,导致错误行写不进去(探测到
  /// "insert failed: Converting object to an encodable object failed: Infinity"),
  /// 可观测性修复被静默吞掉。这里给 `toEncodable` 兜底:非有限 double 编成
  /// 字符串字面量('Infinity'/'NaN'),保留诊断信息且不改变正常 JSON 结构。
  String _encodeChange(SmartBookCloudSyncChange change) {
    return jsonEncode({
      'change_id': change.changeId,
      'ledger_id': change.ledgerId,
      'entity_type': change.entityType,
      'entity_sync_id': change.entitySyncId,
      'action': change.action,
      'updated_by_device_id': change.updatedByDeviceId,
      'updated_at': change.updatedAt,
      'payload': change.payload,
    }, toEncodable: (v) {
      if (v is double && !v.isFinite) {
        return v.isNaN ? 'NaN' : (v > 0 ? 'Infinity' : '-Infinity');
      }
      return v.toString();
    });
  }
}

// =====================================================================
// LookupCache:syncId → 本地 int id 一次性加载缓存
// =====================================================================

/// pull 路径上的 `syncId → 本地 int id` 查找缓存。
///
/// 改造前每条 sync_change apply 会做 5-10 次 SELECT 查 ledger / category /
/// account / tag 的 syncId 映射,10k 条 ≈ 80-100k SELECT,iOS SQLite 主线程
/// 阻塞数十分钟(用户实测 1 万条 20 分钟)。
///
/// 改造后:pull 入口 [prime] 一次性加载 4 张表全表 syncId→id,apply 内查
/// cache,miss 才走 DB(insert 新实体后调 [putXxx] 写回)。10k 条 SELECT
/// 从 ~10万 降到 ~5(prime)+ 极少量 miss。
///
/// **生命周期**:SyncEngine 每次 pull 入口 new 一个实例赋值给 `activePullCache`,
/// pull 结束清空。不跨 pull 复用,避免长期持有大 map。
class LookupCache {
  final Map<String, int> _ledger = {};
  final Map<String, int> _category = {};
  final Map<String, int> _account = {};
  final Map<String, int> _tag = {};

  /// transactions 表 syncId → 已存在记录的轻量信息(id + createdByUserId)。
  /// `_applyTransactionChange` 每条都要查 existing tx 决定 INSERT/UPDATE,
  /// 这是 10k 条 = 10k 次 SELECT,后期变慢的主因。改走 cache 一次性 prime。
  final Map<String, _TxCacheEntry> _tx = {};

  Future<void> prime(BeeDatabase db) async {
    final ledgers = await db.select(db.ledgers).get();
    for (final l in ledgers) {
      final s = l.syncId;
      if (s != null && s.isNotEmpty) _ledger[s] = l.id;
    }
    final categories = await db.select(db.categories).get();
    for (final c in categories) {
      final s = c.syncId;
      if (s != null && s.isNotEmpty) _category[s] = c.id;
    }
    final accounts = await db.select(db.accounts).get();
    for (final a in accounts) {
      final s = a.syncId;
      if (s != null && s.isNotEmpty) _account[s] = a.id;
    }
    final tags = await db.select(db.tags).get();
    for (final t in tags) {
      final s = t.syncId;
      if (s != null && s.isNotEmpty) _tag[s] = t.id;
    }
    // PERF-P1-13/零风险快修:selectOnly 只取 3 列(id/syncId/createdByUserId),
    // 替代全 22 列物化 —— 注释里的「每行 ~100B」估算此前并不成立。
    final txRows = await (db.selectOnly(db.transactions)
          ..addColumns([
            db.transactions.id,
            db.transactions.syncId,
            db.transactions.createdByUserId,
          ]))
        .get();
    for (final row in txRows) {
      final s = row.read(db.transactions.syncId);
      if (s != null && s.isNotEmpty) {
        _tx[s] = _TxCacheEntry(
          id: row.read(db.transactions.id)!,
          createdByUserId: row.read(db.transactions.createdByUserId),
        );
      }
    }
    logger.info('LookupCache',
        'prime: ledgers=${_ledger.length} categories=${_category.length} '
        'accounts=${_account.length} tags=${_tag.length} transactions=${_tx.length}');
  }

  int? ledgerId(String? syncId) =>
      (syncId == null || syncId.isEmpty) ? null : _ledger[syncId];
  int? categoryId(String? syncId) =>
      (syncId == null || syncId.isEmpty) ? null : _category[syncId];
  int? accountId(String? syncId) =>
      (syncId == null || syncId.isEmpty) ? null : _account[syncId];
  int? tagId(String? syncId) =>
      (syncId == null || syncId.isEmpty) ? null : _tag[syncId];
  /// `_TxCacheEntry` 是 part 内私有,仅供 apply 路径用,所以 ignore lint。
  // ignore: library_private_types_in_public_api
  _TxCacheEntry? transaction(String? syncId) =>
      (syncId == null || syncId.isEmpty) ? null : _tx[syncId];

  void putLedger(String syncId, int id) => _ledger[syncId] = id;
  void putCategory(String syncId, int id) => _category[syncId] = id;
  void putAccount(String syncId, int id) => _account[syncId] = id;
  void putTag(String syncId, int id) => _tag[syncId] = id;
  void putTransaction(String syncId, int id, String? createdByUserId) =>
      _tx[syncId] = _TxCacheEntry(id: id, createdByUserId: createdByUserId);
  void removeTransaction(String syncId) => _tx.remove(syncId);
}

/// transactions 表的轻量缓存条目。只存 apply 路径会用到的 2 个字段。
class _TxCacheEntry {
  const _TxCacheEntry({required this.id, required this.createdByUserId});
  final int id;
  final String? createdByUserId;
}

// =====================================================================
// 自定义分类图标下载任务(in-memory queue)
// =====================================================================

/// 自定义分类图标的下载任务。
///
/// 旧实现把 `await provider.downloadAttachment(...)` 放在 `_applyCategoryChange`
/// 的事务内,网络抖动会让整页事务卡死。改造后只在事务内 enqueue 到
/// [SyncEngine.pendingCustomIconJobs],事务 commit 之后 [drainCustomIconQueue]
/// 并发处理。
class CustomIconDownloadJob {
  const CustomIconDownloadJob({
    required this.categoryId,
    required this.cloudFileId,
    this.expectedPath,
  });

  final int categoryId;
  final String cloudFileId;
  final String? expectedPath;
}
