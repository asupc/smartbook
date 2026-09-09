# SmartBook 客户端性能问题清单（App 端审计）

> 文档状态：Audit v1.1（v1.0 已逐条源码复核修订：修正 PERF-P0-05 离线循环量化、第 2 节批量写入扫尾句及若干引用/计数偏差；核心结论与优先级不变）
> 制定日期：2026-09-08
> 适用范围：`client/`（Flutter 3.27.3 / Dart 3.6 / Riverpod 2.5 / Drift 2.20）+ `client/android/` 原生侧
> 分析方法：**静态代码审计**（client/lib 384 个 Dart 文件 / 排除 `.g.dart` 生成文件约 18.9 万行，逐条读源码 + 对照 Flutter / SQLite / Drift 行为），**未做真机 profile**，文中耗时均为「推断 + 量级理由」
> 与现有计划的关系：
> - 本文**不重复** `docs/ux-performance-optimization-plan.md` 与 `docs/performance-followup-implementation-plan.md` 已覆盖的项（M5-4 首页窗口化分页、M6-2 标签/附件查询优化等），只记录**尚未被那两份计划覆盖**的问题
> - 本文性质是问题清单（可用于建 issue / 排期），不是实施计划

---

## 1. 结论速览

### 1.1 只做五件事

| # | 问题 | 用户可感症状 | 优先级 |
|---|---|---|---|
| `PERF-P0-01` | 周期交易生成被 `await` 在 Splash 闸门内，且每生成一笔就全量查一次账本 | 冷启动卡在 Splash 数百 ms～数秒 | P0 |
| `PERF-P0-03` | SQLite 未开 WAL / 未调 `synchronous` / `readPool=0` | 记账卡、导入卡、写期间 UI 查询排队 | P0 |
| `PERF-P0-04` | 账户维度聚合缺索引 + Dart 逐行求和 | 资产/账户页卡，记一笔账整页抖一下 | P0 |
| `PERF-P0-02` | `runApp()` 前 `await` 通知初始化（内含系统权限弹窗/跳设置页） | 首装第一屏被系统对话框挡住 | P0 |
| `PERF-P0-07` | 搜索页 stream 在 `build` 内新建 + 无 debounce + 主线程全量过滤 | 搜索输入框每敲一个字卡一次 | P0 |

### 1.2 问题分布

| 级别 | 数量 | 说明 |
|---|---|---|
| P0 | 8 | 冷启动 / 首帧阻塞 / 写入延迟 / 高频交互卡顿 |
| P1 | 24 | 掉帧热点、后台耗电、N+1 与全表扫描 |
| P2 | 19 | 局部浪费、代码卫生、可选优化 |
| 零风险快修 | 7 | 可与其他改动并行，风险极低 |

---

## 2. 已确认做对的（不要重复劳动）

审计中特意验证并**确认无问题**的项，实施时应复用而非重写：

- **首页已真分页**：`homeWindowPaginationEnabledProvider` 默认 `true`，`pageSize: 80`、常驻上限 960、双向 keyset 预取（`providers/home_transaction_window_provider.dart:108,111`、`widgets/biz/transaction_list.dart:716-722`）。
- **索引清单集中且新旧装一致**：`data/db.dart:1394-1476` 的 `_ensureIndexes()` 幂等、`onCreate`/`onUpgrade` 都跑，修掉了历史上「只有升级用户才有索引」的缺陷。
- **SQLite 已在后台 isolate**：`NativeDatabase.createInBackground(file)`（`data/db.dart:1577`）；迁移不阻塞主 isolate。
- **批量写入已用事务/batch**：`insertTransactionsBatchWithRelations`（`data_import_service.dart:708,785`，500 条/批，单事务）、change log 批量写入（`local_repository.dart:821-834`）、pull 整页一个事务（`cloud/sync/sync_engine.dart:1224-1234`）。**交易导入 / pull / change log 等热路径均已事务化；低频路径仍有逐条独立 commit（配置导入 / seed，见 P2-10），`PERF-P1-18` 的删除循环另计。**
- **原生四路监听设计良好**：持久化队列 + `peek/ACK`、指纹去重、防抖（`ScreenTextWatcher.kt` 800ms / 快速通道 300ms）、锚点预筛、节点数上限（`MAX_DEPTH=30/MAX_NODES=400/MAX_CHARS=2000`）、`apply()` 非 `commit()`。
- **无 wakelock 滥用、无 WorkManager/AlarmManager 周期同步**：后台数据唤醒由系统事件（短信广播 / NotificationListenerService / AccessibilityService）驱动。例外：每日记账提醒是自建 `setExactAndAllowWhileIdle` 精确闹钟（`MainActivity.kt:556`，1 次/天）；App 进程存活期间另有常驻 Dart 定时器（30s 原始证据扫描 = PERF-P1-05、15min 草稿重试）。核心结论「无周期同步」不受影响。
- **同步是增量的**：`change_id` / cursor + 三层防抖（250ms / 2s / 1s），无定时全量同步、无 O(n²) 冲突检测（`sync_conflict_resolver.dart:9-17` 是纯 LWW）、无 `StreamSubscription` 泄漏。
- **列表项 `RepaintBoundary` 已自动添加**：`FlutterListViewDelegate` 的 `addRepaintBoundaries = true`（pub cache `flutter_list_view-1.1.29/lib/src/flutter_list_view_delegate.dart:24,205`）。
- **APK 体积不是问题**：`deploy/smartbook-prod-arm64-dev-1.0.42.apk` = 18.3MB，`minifyEnabled` + `shrinkResources` 已开。
- **`decimal` 未进热路径**：仅 `widgets/biz/amount_editor_sheet.dart:627-643` 使用；数据层金额全是 `double`。
- **l10n 查找不慢**：`Localizations.of` O(1) + `SynchronousFuture`（`l10n/app_localizations.dart:70-72`、`:15310-15312`）。

---

## 3. P0 清单

### PERF-P0-01 周期交易生成在 Splash 闸门内，且每笔生成都全量查账本

**证据**
- `providers/ui_state_providers.dart:358-371`：`generatePendingTransactionsStatic(...)` 与随后的 `PostProcessor.runR` 都在 `ref.read(appInitStateProvider.notifier).state = AppInitState.ready`（`:382`）**之前**且 `await`。
- `services/data/recurring_transaction_service.dart:191`：`for (每个账本) await repository.getAllRecurringTransactions()` —— 账本数 × 全表。
- `services/data/recurring_transaction_service.dart:258-260`：每生成一笔就 `repository.transactionsWithCategoryAll(ledgerId).first`，而该查询**无 `limit`**（`local_transaction_repository.dart:733-736` → `watchTransactionsWithCategoryAll:98-110`），只为按 id 找一条。
- `services/data/recurring_transaction_service.dart:273`：每轮循环再全量 `getAllRecurringTransactions()`。

**为什么慢**：N 笔待生成 occurrence ≈ **L + 2N 次全量查询**（L = 账本数；每笔 occurrence 各 1 次 `transactionsWithCategoryAll` 全量 + 1 次 `getAllRecurringTransactions` 全量），且逐笔 `await`、无批处理、无事务；全部发生在首页出现之前。

**改法**
1. 整段移到 `ready` 之后：`main.dart:120-122` 的 post-frame 里 `unawaited(_generateRecurringAfterReady(container))`；
2. `_createOccurrence` 用已返回的 `transactionId` 直接 `repo.getTransactionById(id)`，删掉全量 `.first`；
3. 账本循环外查一次 recurring 列表，内存推进游标，结束统一写回 `lastGeneratedDate`；
4. `PostProcessor.runR` 一并 fire-and-forget。

**收益 / 风险**：首页提前数百 ms～数秒（积压越多收益越大）+ 消除一次全表读。风险低——幂等已有 `occurrenceEventKey`（`:368-376`）+ event store 保护；首帧后新增交易会触发一次列表刷新（用现有 silent refresh 即可）。

---

### PERF-P0-02 `runApp()` 前 `await` 通知初始化（含系统权限弹窗）

**证据**
- `main.dart:73-79`：`await notificationUtil.initialize()` 在 `runApp` 之前。
- `utils/notification_android.dart:15-29`：`initialize()` 内 `await _plugin.initialize()` 之后**紧接着** `await requestPermissions()`。
- `utils/notification_android.dart:39`：`requestNotificationsPermission()` —— Android 13+ 未授权时**弹系统对话框**，Future 等用户点完才完成。
- `utils/notification_android.dart:44-45`：`requestExactAlarmsPermission()` —— `!canScheduleExactAlarms()` 时插件会 `startActivityForResult(ACTION_REQUEST_SCHEDULE_EXACT_ALARM)`，**跳系统「闹钟与提醒」页**。项目声明了 `USE_EXACT_ALARM`（`AndroidManifest.xml:33`）通常自动授予，故为条件触发；用户撤销后即复现。

**为什么慢**：这两个 Future 只有用户交互后才 complete，而它们在第一帧之前 → 首装/拒绝过通知权限的用户看到「原生白底 + 系统对话框」。注意冲击面：`USE_EXACT_ALARM`（targetSdk 33+）自动授予后，多数 Android 13+ 设备不会触发「闹钟与提醒」跳页；每次冷启动真正阻塞的是**通知权限对话框**（仅未授权时）。

**改法**
1. 把 `notificationUtil.initialize()` 移到 `_bootstrapAfterFirstFrame`（`main.dart:132`）**第一行**（保证 `_restoreUserReminder` 有实例可用）；
2. 把 `requestPermissions()` 从 `initialize()` 拆出来，改首帧后延迟 1–2s 或用户开启提醒时再请求；
3. `requestExactAlarmsPermission()` 只在用户真正开启每日提醒时调；
4. 懒初始化入口 `scheduleDailyReminder` 的 `if (!_initialized) await initialize()`（`notification_android.dart:62`）也会连带弹权限，需区分「插件初始化」与「权限请求」。

**收益 / 风险**：首帧不再被系统弹窗阻塞（可测的确定收益）。风险极低。

---

### PERF-P0-03 数据库未开 WAL / 未调 `synchronous` / `readPool=0`

**证据**
- `data/db.dart:1577`：`return NativeDatabase.createInBackground(file);` —— 无 `setup:`，`readPool` 默认 0。
- 全仓 `*.dart` 检索 `journal_mode|synchronous|cache_size|PRAGMA` 只命中 `PRAGMA table_info(...)`，**没有任何持久化参数设置**。
- drift 2.28.2 `lib/native.dart:143-147` 注释明确：默认 journal 模式禁止并发读写，需在 `setup` 里设 `pragma journal_mode = WAL`；`_defaultReadPoolSize = 0`（`:65`）。

**为什么慢**：当前是 `journal_mode=delete` + `synchronous=FULL`：
- 每次 autocommit = 建 journal → 写 journal → **fsync journal** → 写主库 → **fsync 主库** → 删 journal，Android 单条 insert 典型 **5–20ms**；
- 单连接 + 非 WAL ⇒ **读被写阻塞**，导入/同步期间所有 UI 查询排队；
- `cache_size` 默认 2MB，5 万行时热页反复回盘。

**改法**
```dart
return NativeDatabase.createInBackground(
  file,
  readPool: 4,                       // 仅 WAL 下生效
  setup: (db) {
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA synchronous = NORMAL;');
    db.execute('PRAGMA cache_size = -8000;');   // 8MB
    db.execute('PRAGMA temp_store = MEMORY;');
  },
);
```

**⚠️ 必须同时改**
- `data/db.dart:1582-1602` 的 `clearDatabaseLockFiles()` **直接删除 `-wal` / `-shm` 文件** —— 当前非 WAL 模式下这两个文件不会产生（delete 模式临时文件是 `-journal`，且不被它处理），函数实为 no-op；但开 WAL 后，进程异常退出残留未 checkpoint 的 `-wal` 时直接删除会丢已提交事务，须改成先 `PRAGMA wal_checkpoint(TRUNCATE)` 再删（正常 close 时 SQLite 已自动 checkpoint，无需处理）。
- 备份 / 导出 / 文件搬移逻辑需覆盖 `-wal` / `-shm`（`db.dart:1553-1560` 的品牌更名搬移已顺带处理，可参照）。

**收益 / 风险**：单条写延迟 5–20ms → <1ms（**10–50×**），批量导入吞吐 5–10×，UI 查询不再被写阻塞。风险：`synchronous=NORMAL` 下进程崩溃不丢数据、仅掉电可能丢最近若干事务（要零丢失可保留 `FULL`，收益降到约 3×）；首次切 WAL 需一次 checkpoint，老库启动多几百 ms（一次性）。

---

### PERF-P0-04 账户维度聚合：缺索引 + Dart 逐行求和 → 一次刷新 A×10 次全表扫描

**证据**
- `transactions` 上**没有以 `account_id` 开头的索引**：`data/db.dart:1396-1410` 只有 `(ledger_id, happened_at DESC)`、`(ledger_id, happened_at DESC, id DESC)`、`(ledger_id, type, happened_at DESC)`、`(sync_id)`。
- 全表扫描 + Dart 累加的查询：`data/repositories/local/local_account_repository.dart` 的 `getAccountBalance:251-299`、`getAccountGlobalBalance:314-318`、`getAccountBalanceInLedger:345-349`、`getAccountExpense:420-425`、`getAccountIncome:445-465`、`getAccountDailyBalances:722-727`。
- 调用方是循环：`getAllAccountBalances:381-383`、`getAllAccountStats:487-489`（A×3 次 + `getAccountBalance` 内部 2 次）、`getNetWorthBreakdown:824-831`、`getNetWorthBreakdownByCurrency:845-846`、`getNetWorthDailyBalances:878-884`、`getNetWorthTrendSeries:919-922`、`getAssetCompositionByType:956-958`。
- 资产页同时 watch 4 个此类 provider：`pages/account/accounts_page.dart:99-103,353`。
- 触发频率高：`statsRefreshProvider` 在每次记账后被 bump（`services/billing/post_processor.dart:23,36,49,74,85`、`services/automation/auto_billing_service.dart:577,774,896,1335,1548`、`pages/transaction/transaction_editor_page.dart:452`、`widgets/biz/transaction_list.dart:571`）。
- 附带浪费：`_sharedLedgerIds()`（`:237-244`）在**每个**账户的每个方法里都重查一次（`:265,313,419,444,515,721`）。

**为什么慢**：每账户 2 次全表扫描 → `getAllAccountStats` 单次 = A×5 次全表扫描 → 资产页一次刷新 A×10+ 次；每次把全部命中 `Transaction`（22 列）materialize 进 Dart，A=10、T=5 万时约 **100 万行扫描 + 15–20MB 临时对象**，而只需要一个 `double`。

**改法**
1. 补索引（加进 `data/db.dart:1396-1410` 的 `'transactions'` 列表）：
```sql
CREATE INDEX IF NOT EXISTS idx_transactions_account_time
  ON transactions (account_id, happened_at DESC);
CREATE INDEX IF NOT EXISTS idx_transactions_to_account
  ON transactions (to_account_id) WHERE to_account_id IS NOT NULL;
```
2. Dart 累加改 SQL 聚合，并把 A 次往返合并成 1 次 `GROUP BY account_id`：
```sql
SELECT COALESCE(SUM(CASE
  WHEN account_id = ?1 AND type IN ('income','adjustment') THEN amount
  WHEN account_id = ?1 AND type IN ('expense','transfer')  THEN -amount
  WHEN to_account_id = ?1 AND type = 'transfer'            THEN amount
  ELSE 0 END), 0) AS bal
FROM transactions
WHERE (account_id = ?1 OR to_account_id = ?1)
  AND ledger_id NOT IN (SELECT id FROM ledgers WHERE is_shared = 1 AND my_role != 'owner');
```
3. `_sharedLedgerIds()` 提到调用方只算一次。

**收益 / 风险**：`O(A×10×T)` → `O(A)` 索引点查或 1 次聚合，T=5 万、A=10 时约 **50–100×**，并消除 20MB 临时对象。风险：SQL `CASE` 必须与现有 Dart 分支逐条对齐（`adjustment`/`transfer` 符号、`excludeFromStats` 不影响余额）——**先写新旧实现同库同参数结果一致的对比测试再替换**；新增索引会让写入 +10–15% 写放大（相对 P0-03 的 fsync 收益可忽略）。

---

### PERF-P0-05 WebSocket 断线重连：固定 3s、无退避、强制 refresh、失败清 session

**证据**（`client/packages/flutter_cloud_sync/lib/src/providers/smartbook_cloud_provider.dart`）
- `:4497`：`_reconnectTimer = Timer(const Duration(seconds: 3), () async {`
- `:4501`：`await auth.tryRefreshSession();` —— 无条件 refresh，不判断 token 是否过期。
- `:1673-1683`：`_refreshSession()` 不看过期直接 POST `/auth/refresh`。
- `:1355-1362`：任何失败（含离线 `SocketException`）都 `_clearSession()`；`:1715-1720` 清持久化 session。
- `:1291`（30s 冷却常量在 `:1186`）：`_tryRecoveryLogin` 走 `/auth/login`，30s 冷却。

**为什么耗电 / 费流量**：离线或服务端不可达时每 3 秒一轮失败循环，但网络请求只发生在**首轮**——首轮 `refresh POST` 失败即 `_clearSession()`，此后 `_refreshSession` 因 `session == null` 直接本地抛异常**不再发请求**，`requireAccessToken` 失败也使 WS 连接根本不发起；`login POST` 仅在配置了恢复邮密时发生且受 30s 冷却（无邮密从不发生）。即离线 1 小时 ≈ **1200 次纯本地失败循环 + 至多 1 次 refresh POST + 120 次 login POST（仅限配置邮密）**。危害主要是 CPU 空转、离线清 session 把用户登出、以及（有邮密时）login 反复打扰服务端。

**改法**
1. 指数退避 + 上限 + jitter：`3s → 6s → 12s → 30s → 60s → 120s(max) ±20%`，连接成功重置；
2. 只在 `auth.isAccessTokenExpired` 时 refresh；
3. `_doRefreshSession` 区分**网络失败**与 **401/无效 token**：网络异常不清 session，只标 offline；
4. 用已有 `Connectivity().onConnectivityChanged`（`providers/sync_providers.dart:442`）门控：离线不重连，恢复时立即触发一次。

**收益 / 风险**：本地失败循环从 1200 次/小时降到退避后个位数/分钟，login POST（有邮密时 ~120 次/小时）降到 ~0，且不再因离线把用户登出。风险：退避上限过长会让「服务端刚恢复」时同步最多延迟 2 分钟，用 connectivity 事件立即触发补偿。

---

### PERF-P0-06 同步 HTTP 全程无超时、失败无退避

**证据**
- `smartbook_cloud_provider.dart:1771-1772`、`:3451-3452`、`:3476-3477`、`:3502-3503`、`:3525-3526`：`_httpClient.send()` 后直接 `Response.fromStream`，**全文件无一处 `.timeout(`**。
- 包内存在 `retry_helper.dart`，但 sync 路径**从未调用**（grep 无 call site）。注：附件单条上传/下载已有自身重试（`sync_engine_attachments.dart:108-155`，3 次尝试），本条所指是 push/pull 主链路。
- `lib/cloud/sync/sync_engine.dart:501-504`：catch 后只返回 `SyncResult(error:)`，无重试 / 退避。
- `lib/cloud/sync/sync_engine_realtime.dart:86`：`_autoSyncing` 期间后续触发被丢弃 → 同步看起来"卡住"。

**为什么慢 / 耗电**：DNS 挂起或服务端半开连接时，`/sync/pull`、`/sync/ledgers`、`/profile/me`、`/sync/push` 都可能长时间占着 TCP，radio 保持唤醒。

**改法**：统一 deadline（connect 10s / pull·list 30s / push 60s）+ `RetryHelper.executeWithBackoff`（仅对 5xx 与网络错误重试）；`SyncEngine.sync()` 失败时记 `nextRetryAt`，让 `_scheduleAutoSync` 尊重它。

**收益 / 风险**：卡死路径变可预期失败，失败重试有节奏。风险：超时设太小会让弱网 push 失败——建议 pull/list 30s、push 60s。

---

### PERF-P0-07 搜索页：stream 在 `build` 内新建 + 无 debounce + 主线程全量过滤

**证据**（`pages/transaction/search_page.dart`）
- `:849-850`：`StreamBuilder(stream: repo.transactionsWithCategoryAll(ledgerId: ledgerId))` —— stream **在 build 内联创建**；页面任何 `setState` 都新建 Drift stream（旧订阅取消、新查询全表、snapshot 回 waiting）。
- `:52,62-67`：`_searchController.addListener` 直接 `setState` + `_performSearch()`，**无 debounce**。
- `:89-143`：`_performSearch` 在**主 isolate 同步**遍历 `_allTransactions`，每项做 `_searchText.toLowerCase()`（循环内重复算，`:96`）、`transaction.note?.toLowerCase()`、`CategoryUtils.getDisplayName(...)`、`amount.toString()`。
- `:84-87` 与 `:145-154`：两次 `setState`；`:147-152` 同一 `setState` 内跑两遍 `where+fold`（expense/income 各一遍）。
- `:169-175`：`transactionsWithCategoryAll(ledgerId).first` 把整账本读进内存（无 limit）。
- `:853`：在 builder 里写 `_allTransactions = snapshot.data!`（build 期改状态）。

**为什么慢**：按键频率 ~10/s，每次都是「新建 stream + 全表 SQL + O(N) Dart 过滤 + 2 次全页 setState」。T=1 万时单次过滤即上万次字符串/l10n 调用，主线程阻塞十几～几十 ms → 输入明显卡顿，且 stream 重建导致结果闪烁、丢滚动位置。

**改法**
1. stream 提到 `initState` 或改 `StreamProvider.family(ledgerId)`，build 只消费；
2. 250–300ms debounce（输入框只即时更新文本，不跑搜索）；
3. `_searchText.toLowerCase()` 提到循环外；分类显示名按 `categoryId` 缓存 `Map<int,String>`；
4. 大账本后续再考虑 SQL 侧过滤（`note LIKE ?`、金额区间、日期范围、`categoryId IN`）+ `limit/offset` 分页；
5. `_allTransactions = snapshot.data!` 移出 build。

**收益 / 风险**：输入延迟从几十 ms 降到 <5ms；重建次数减少约 90%。建议先做 1+2+3（零语义变化），SQL 化单列一步。

---

### PERF-P0-08 1.15MB 时区库在 `runApp` 前同步解析

**证据**
- `main.dart:58-62` → `utils/notification_factory.dart:31-48` → `tz.initializeTimeZones()`（**同步**）。
- `timezone-0.9.4/lib/data/latest.dart` = **1,152,145 字节**；`initializeTimeZones()` 内部 `Uint16List.fromList(_embeddedData.codeUnits)`（≈2.3MB 分配+拷贝）后解析成 ~600 个 Location / 数千 TimeZone 条目，纯主 isolate。
- 实际只用 `Asia/Shanghai`（`notification_factory.dart:37` 硬编码）。

**改法**
1. 换 `package:timezone/data/latest_10y.dart`（260,333 B，约 1/4.4）；
2. 更优：延后到真正 `zonedSchedule` 时懒初始化（从 `main()` 移进调度入口）。

**收益 / 风险**：T1 省 30–150 ms（推断），首帧不再等它。风险低——注意 `convertToTZDateTime` 依赖 tz 已初始化，懒初始化要放在调度入口。

> 顺带（非性能）：`tz.setLocalLocation('Asia/Shanghai')` 硬编码会让非中国区用户提醒时间错，建议改用设备时区。

---

## 4. P1 清单

| ID | 问题 | 证据 | 改法要点 | 收益 |
|---|---|---|---|---|
| `PERF-P1-01` | 启动时小组件「全目录预热」= 12 次离屏渲染 + 去重后 ≤12 次原生刷新 | `main.dart:214-225`（`warmUpAllSpecs: true`）→ `widget/widget_manager.dart:228-292,852-860,300-315`（原生刷新按 kind/类名 Set 去重）；`widget/widget_spec.dart:256-269`（catalog 12 项） | 延后到首帧空闲（`SchedulerBinding.scheduleTask(Priority.idle)` 或 `Future.delayed(3s)`，同 `main.dart:752`）；或分批每 2–3 个让出帧；或仅进小组件选择页时补渲 | 首屏窗口少 12 次离屏渲染（推断数百 ms）；风险：削弱「添加组件立刻有图」语义 |
| `PERF-P1-02` | 日志无级别门控 + 每 2s 把 2000 条 `jsonEncode` 重写进 SharedPreferences | `services/system/logger_service.dart:189-212`（每条都入缓冲 + `_notifyListeners()`）、`:250-269`（节流 2s 后全量 `jsonEncode` + `prefs.setString`）、`:215-247`（启动整串 `jsonDecode`）；1386 处调用点 | 加 `minLevel`（release 默认 info）+ `_notifyListeners` 200ms 合并；上限降到 200–500 条；同步 apply 路径逐条 debug 加 `kDebugMode`（`sync_engine_apply.dart:274,308,397,420,551,568,643,654,719,731`、`change_tracker.dart:118`） | 一次 500 条 pull 少 500 次 listener 通知 + 一次全量 JSON 重写 |
| `PERF-P1-03` | `IndexedStack` 让 4 个 tab 在首屏同时 build | `app.dart:49-54,857-863`（IndexedStack 会 build 全部子节点，只是不 paint）；AnalyticsPage `analytics_page.dart:409-482,664-670`；AccountsPage `accounts_page.dart:96-103`；MinePage `mine_page.dart:380-383,989-991,173-175`（后者在**云模式下启动即发一次 `/version` HTTP**，本地模式不发；`sync_providers.dart:715-729`） | tab 懒挂载（记录 `_visitedTabs`，未访问返回 `SizedBox.shrink()`）+ 页面 keepAlive；首屏只建 Home | 冷启动少 6–10 个聚合查询 + 1 次 HTTP（推断 100–400 ms）；风险：首次切 tab 有 loading |
| `PERF-P1-04` | 每次 `sync()` 全表物化 transactions 再 `IN(全量 id)` | `cloud/sync/sync_engine.dart:381` → `sync_engine_attachments.dart:80-88`；WS 侧 `sync_engine_realtime.dart:691` → `sync_engine_attachments.dart:159-167`；另 `sync_engine.dart:265-267`、`sync_engine_status.dart:35-51` 全表计数 | 直接查 `transaction_attachments.where(cloudFileId.isNull())` join ledger；无待传时早退；计数改 `id.count()` | 稳态从 O(全库) → O(待传附件数)，通常为 0；风险：注意共享账本 Editor 的 tx 过滤语义 |
| `PERF-P1-05` | 常驻 30s 定时器做 2 次全表原始证据扫描（含短信/通知原文） | `providers/sync_providers.dart:696` → `services/privacy/raw_evidence_sync_service.dart:125-129` → `services/automation/auto_book_event_store.dart:657-665` | cleanup 改 SQL 侧条件 + `selectOnly` 只取 deadline 列；30s 定时器改「有待传项才快跑，否则退避 5–15min」；`syncPending` 内 cleanup 调一次即可 | 稳态后台 DB 唤醒 120 次/小时 → 个位数 |
| `PERF-P1-06` | 统计页 `FutureBuilder` 的 future 在 build 里新建 + `statsRefreshProvider` 级联 + N+1 | `pages/main/analytics_page.dart:663-670,448-482,1108-1139`、`:413`（顶层 watch）、`:1187-1228`（每个一级分类 `await repo.getCategoryById()`，同类调用另见 `:1253,:1280`） | 改 `FutureProvider.family`（key = ledgerId+type+scope+range+statsTick）；`statsRefreshProvider` 改 `listen`+`invalidate`；分类聚合改批量 `getCategoriesByIds`；加 `skipLoadingOnReload: true` | 切周期/关提示不再重查、不再闪 spinner |
| `PERF-P1-07` | `TransactionList` 的 identity 缓存被父层打破 | `pages/main/home_page.dart:322-327` 每次 build `.map(...).toList()` 新 List → `widgets/biz/transaction_list.dart:333-387`（`identical` 缓存失效）、`:166-173`（每次 O(N) 比较） | 传 `ref.watch(provider.select((s) => s.items))` 保持引用稳定；或给 TransactionList 传 `win.items` 本身 | 滚动中每次重建省 O(N log N) 分组排序 |
| `PERF-P1-08` | `ThemeData` 每次 `MainApp.build` 重建 5+ 份 + MainApp 依赖 MediaQuery | `main.dart:604`（`Theme.of(context).platform` 在 MaterialApp **之上** → 无祖先，走 `ThemeData.localize(_kFallbackTheme,...)` 新建一份）、`:605-656`（lightTheme ×1 + copyWith）、`:676-681`（darkTheme ×2）、`:658-667`（`MediaQuery.of` 建依赖）；`Theme.updateShouldNotify` 是 `data != oldWidget.data`（ThemeData 无 `==` → 恒 true） | 用 `Provider<ThemeData>` 缓存 base，仅 `primaryColor` 变化时 `copyWith`；字体缩放改 `MediaQuery.textScalerOf`；platform 改 `defaultTargetPlatform` | 每次重建省数 ms；键盘弹出不再触发全树 Theme 失效 |
| `PERF-P1-09` | 分类明细页不分页 | `pages/transaction/category_detail_page.dart:595-598`（全量 stream）、`:606-634`（每次 watch 全量排序）、`:53-85`（build 内两遍 O(N)）、`:342,357,434`（每笔新建 `DateFormat`） | 汇总改 SQL 聚合；列表分页；`DateFormat` 提为 `static final`（参照 `transaction_list.dart:341`——`_buildFlatItems` 内局部变量，每次列表重建构造一次、非每笔，可再提为常量） | 首屏 O(N log N) → O(page) |
| `PERF-P1-10` | `getTransactionsByDateRange` 真正的 N+1（注释写"批量"） | `data/repositories/local/local_transaction_repository.dart:1535-1577`（每笔 4~5 次串行查询，标签再嵌套一层）；同类 `getTransactionsByDate:1248-1259`（仅分类部分 N+1，标签已批量）；调用方 `providers/calendar_providers.dart:46` | 照抄同仓正确范式：`export_page.dart:131-135` 的分批 `IN (...)`，或复用同文件 `local_transaction_repository.dart:81-88` 的 `_txJoins()` JOIN 写法 | 1000 笔从 4000+ 次跨 isolate 往返 → 4 次 |
| `PERF-P1-11` | 自动记账判重全表扫描 + JSON 解码 | `services/automation/auto_book_event_store.dart:307-355`（`:314-318` 全表全列含 `raw_text`、`:341-343` 全表 items、`:356` 逐条 `jsonDecode`）；调用链 `semantic_dedup_matcher.dart:70-83` | 条件与 `external_id` 下推 SQL + `json_extract`；补 `auto_book_events(external_id)`、`(ledger_id, state)`、`auto_book_event_items(transaction_id)` 索引 | 每次短信/通知从 O(全表) → 索引点查；风险：`external_id` 需写入时规范化（或新增 `external_id_norm` 列） |
| `PERF-P1-12` | `local_changes` 无索引 + 全表加载计数 | `cloud/sync/change_tracker.dart:170-175,162-167,190-192`（未推送查询）、`:140-145`（`recordPulledFromServer`，每个 pull 实体调一次）、`:200-205`（`.get()` 只取 `.length`） | 补 `(ledger_id, pushed_at, id)`、`(entity_type, entity_sync_id)` 索引；计数改 `id.count()` | push 前查询从全表 → 索引范围 |
| `PERF-P1-13` | `LookupCache.prime` 全表加载 transactions 只为拿 `(syncId→id)` | `cloud/sync/sync_engine_pull.dart:273-274`（注释自称「只保留 id + syncId + createdByUserId，每行 ~100B」，实际 `db.select(db.transactions).get()` 是全 22 列） | 改 `selectOnly(...)..addColumns([id, syncId, createdByUserId])` | prime 内存/时间降 3–5×（自估 200–500ms → 50–100ms） |
| `PERF-P1-14` | push 无分片 + `_serializeEntityForPush` 每条 2–10+ 次 DB 查询（典型带分类/标签 7–10，极简 2–3，转账多标签 >10） | `cloud/sync/sync_engine.dart:958-1039` → `smartbook_cloud_provider.dart:2224-2231`、`:3449`（主 isolate `jsonEncode`）；`sync_engine_serialization.dart:22-100` | 按 200 条切片 push，每批成功即 `markPushed`；关联实体批量查询 + 内存 map | 峰值内存与单请求体积可控；失败重试范围从「全部」降到「一批」 |
| `PERF-P1-15` | `pendingCandidateCountProvider` 为拿 `.length` 做 N+1 | `providers/automation_providers.dart:31-34` → `services/billing/pending_candidate.dart:306-315`（`listPending(500)` + 逐条 `itemsForEvent` + `BillInfo.fromJson`）；触发点 `home_page.dart:93-95`、`mine_page.dart:380-383`、`app.dart:768` | 批量 `isIn(eventIds)` 或 join；只计数时不解析 payload | 首屏少几十到几百次 DB 往返 |
| `PERF-P1-16` | 截图原图直传 AI，无降采样 | `services/automation/auto_billing_service.dart:526` → `ai_relay_client.dart:562-583`（`MultipartFile.fromPath` 原图）；`lib/ai/` 无 `cacheWidth`/压缩 | 长边压到 1280–1600 + JPEG q80（`FlutterImageCompress` 已依赖，见 `attachment_service.dart:273`）；识别失败时保留原图重试一次 | payload 降 60–80%，弱网上行时间显著下降 |
| `PERF-P1-17` | 大文件解析全在主 isolate | `services/import/file_reader.dart:105-166`（UTF-16 手写逐字节 + UTF-8 全量试解 + GBK 全量解码）、`utils/xlsx_reader.dart:15-91`、`services/attachment_export_import_service.dart:161-162`（tar+gzip）、`pages/data/export_page.dart:250`（CSV）；`file_reader.dart:69-92` 用 `List<List<int>>` 累积字节（装箱整数） | 用 `compute`（已有先例 `import_confirm_page.dart:81`）；字节累积改 `BytesBuilder` | 10MB GBK 解码从主线程 200–600ms 卡顿 → 0；内存峰值降 8–16×；风险：`l10n` 依赖项需预解析成 `Map` 传入 |
| `PERF-P1-18` | 删除交易无事务 + 逐文件无索引扫描 + 上层循环调用 | `local_transaction_repository.dart:635-646`（三个独立语句）、`:672-676`（按 `file_name` 单独查，无索引）、`pages/transaction/search_page.dart:486-488`（循环逐条删） | `deleteTransaction` 包 `db.transaction()`；批量路径可参照 `deleteTransactionsBatchBySyncIds`（`:1693-1719`，注意它只删 DB 记录、无物理附件清理/引用计数，直接复用会残留磁盘文件）；补 `transaction_attachments(file_name)` 索引；文件删除放事务提交后 | 删 50 笔从 250 次 commit / 500 次 fsync → 1 次 |
| `PERF-P1-19` | 账户详情页把分页结果全 spread 进 `Column` | `pages/account/account_detail_page.dart:242,279,969-988`（每页 50 条累加）；`:981` 每行 watch `ledgersStreamProvider` | 改 `CustomScrollView` + `SliverList.builder`，或 `ListView.builder` 统一承载；`ledgersStreamProvider` 在 build 顶部 watch 一次 | 常驻组件数 O(已加载条数) → O(视口) |
| `PERF-P1-20` | 日历页 `shrinkWrap + NeverScrollableScrollPhysics` 嵌套列表 | `pages/calendar/calendar_page.dart:195,601-603`；`_buildDateCell:396-496` 每格调用 `BeeTokens.expenseColor/incomeColor`（内部 `ref.watch`）+ 多次 `Theme.of` 依赖 | 当日列表改懒加载或并入外层 `ListView`；颜色在 `_buildCalendar` 算一次传参 | 切日期/切月重建成本下降；注：月度数据已用 `autoDispose.family((ledgerId, month))` 缓存（`calendar_providers.dart:16-28`），不是每次切月全量查库 |
| `PERF-P1-21` | 年度报表：12 次串行月查询 + 全年交易全量进内存 + 每笔新建 `DateFormat` | `pages/report/annual_report_page.dart:75-79,83-85,112-118,128-141,159-174` | `DateFormat` 提常量；12 个月改 `Future.wait` 或一条 `GROUP BY` 月聚合 SQL；统计项用 SQL 聚合替代全量进内存 | 打开耗时从「12×RTT + O(N)」降到 1–2 次查询 |
| `PERF-P1-22` | 缺 `category_id` / `category_sync_id_override` 索引（watch 全表扫描） | `local_category_repository.dart:736-803`（`LEFT JOIN + GROUP BY`，无 `t.category_id` 索引 → `O(C×T)`）；`:640-654,680-691` 为无索引单表过滤 watch/get；`local_transaction_repository.dart:127-182`（每次表更新都 rehydrate 全量）；全仓 `.distinct(` **0 处**、`ANALYZE` **0 处** | 补 `transactions(category_id, happened_at DESC)`、`transactions(category_sync_id_override) WHERE NOT NULL`、`categories(parent_id)`；`_ensureIndexes()` 末尾加 `PRAGMA optimize;` | 分类管理/详情查询 10–50×；无关账本写入不再触发整页重算 |
| `PERF-P1-23` | `Image.file/memory` 全部无 `cacheWidth`/`cacheHeight` | 全仓 20 处 `Image.file/memory`，`cacheWidth|cacheHeight` **0 处**；热点：`widgets/biz/attachment_picker.dart:366-375,457-462`、`widgets/category_icon.dart:320-346`（另 `FutureBuilder` 的 future 在 build 里新建） | 按 `size * devicePixelRatio` 传 `cacheWidth`；future 存进 State 或按路径缓存 | 大图解码内存降 1–2 个数量级；风险低 |
| `PERF-P1-24` | 语言在首帧后才从 prefs 恢复 → `MaterialApp.locale` 变化导致全树重建 | `providers/language_provider.dart:11-30`（构造里异步加载，初始 `null`）→ `main.dart:594,695` | 在 `main()` 已读 prefs 那次（`main.dart:93` 附近）一并读 `selected_language`，用 `ProviderScope(overrides:)` 注入初始值 | 非系统语言用户少一次全树重建 + 重布局 |

---

## 5. 零风险快修（可与其他改动并行）

| # | 改动 | 证据 | 收益 |
|---|---|---|---|
| 1 | `db.select(db.autoBookEvents).watch()` → `db.tableUpdates(TableUpdateQuery.onTable(db.autoBookEvents))` | `providers/sync_providers.dart:691`（现写法每次捕获短信/通知都**全表物化含 `raw_text` 后丢弃结果**，只为调一次 `trigger()`）；同仓正确写法 `local_transaction_repository.dart:168-173` | 每次事件捕获省一次全表读；语义完全一致 |
| 2 | `getUnpushedCount` 改 `id.count()` | `change_tracker.dart:200-205` | 从 materialize 全表 → 一次 COUNT |
| 3 | `getStatus` / `getLedgerStats` 计数改 `COUNT` / SQL 聚合 | `sync_engine.dart:265-267`、`local_ledger_repository.dart:102-132` | 10–30× |
| 4 | `LookupCache.prime` 改 `selectOnly` | `sync_engine_pull.dart:274` | 见 `PERF-P1-13` |
| 5 | 补索引：`local_changes` ×2、`transactions(category_id)`、`categories(parent_id)`、`transaction_attachments(file_name)`、`auto_book_events(external_id)` / `(state, source, updated_at DESC)`（注意已有 `(state, next_retry_at)`，新组合避免与之重复）、`messages(conversation_id, created_at)`、`conversations(updated_at)`、`transactions(recurring_id)`（当前无查询谓词使用点，收益存疑，可缓建） | 见各 P1 项 | 全表扫描 → 索引点查 |
| 6 | `_ensureIndexes()` 末尾加 `PRAGMA optimize;` | 全仓无 `ANALYZE`/`sqlite_stat1` | 减少优化器选错计划 |
| 7 | 启动路径 `print()` 清理 | `main.dart` 38 处（55,61,70,78,246,253,266,274,292,300,305,320,330,353,365,388,394,410,417,419…）；全仓 172 处 | release 下少写 logcat；`auto_billing_service.dart:389` 还泄漏完整文件路径（隐私） |

---

## 6. P2 清单

| # | 问题 | 证据 |
|---|---|---|
| 1 | `NumberFormat` / `DateFormat` 在非一次性路径重复构造（43 处） | `annual_report_page.dart` ×8、`widgets/posters/*` ×19（4 个文件）、`category_detail_page.dart` ×3 |
| 2 | 金额格式化热路径每次新建 `RegExp` | `widgets/biz/format_money.dart:13`、`utils/format_utils.dart:62,83,101` |
| 3 | `FlutterListViewDelegate` 未传 `onItemKey`，且外层 key 含 index | `widgets/biz/transaction_list.dart:427,553`（`Key('tx-${it.t.id}-$index')`） |
| 4 | `_LinePainter` 每个数据点新建 `TextPainter` + `shouldRepaint` 用 List identity | `widgets/charts/line_chart.dart:456-498,501-525,535-545`；统计页每次 build 新建列表 `analytics_page.dart:823-836` |
| 5 | `getStatus` 缓存失效重算时打 HTTP（非每次渲染——有 Riverpod `FutureProvider.family` + `_statusCache` 双层缓存；端点是 `GET /sync/ledgers` 全量账本列表，比 status 更重） | `sync_engine.dart:265-280` → `smartbook_cloud_provider.dart:2028-2046,1984-1986`；`widgets/biz/ledger_card.dart:45`；缓存见 `providers/sync_providers.dart:68-80`、`sync_engine.dart:250-251` |
| 6 | `syncMyProfile` 每轮 sync 都 `GET /profile/me`，无 ETag/TTL | `sync_engine.dart:482` → `sync_engine_profile.dart:23` |
| 7 | 无原生品牌闪屏（`launch_background` 纯白） | `android/app/src/main/res/drawable/launch_background.xml:3-12`；无 `flutter_native_splash` 依赖 |
| 8 | 统计仓库部分聚合仍在 Dart 侧 | `local_statistics_repository.dart:22-63,201-223,260-265`（`totalsByYearSeries` 无日期上界，拉整账本历史）；对比同文件已 SQL 化的 `:291-306,406-421` |
| 9 | 预算 N+1（每个预算 4 次往返） | `local_budget_repository.dart:260-285,154-156,22-31` |
| 10 | 配置导入 / seed 逐条写 | `services/export/config_export_service.dart:2756,2822`、`services/data/seed_service.dart:619-728` |
| 11 | `transaction_tags` 缺唯一约束（先 SELECT 再 INSERT） | `local_tag_repository.dart:133-145` |
| 12 | 附件导出逐个 `file.exists()` + O(N×M) 字符串比较 | `services/attachment_export_import_service.dart:70-76,100-105` |
| 13 | 判重豁免表每次判重都 `jsonDecode` 最多 200 条 | `semantic_dedup_matcher.dart:95` → `dedup_exempt_store.dart:62-78` |
| 14 | `clearLedgerTransactions` 无事务（3 条语句各自 commit） | `local_ledger_repository.dart:245-269` |
| 15 | 小组件 30 分钟刷新触发账户聚合 | `widget/widget_data_service.dart:215,237`；12 个 widget XML `updatePeriodMillis="1800000"`（修好 `PERF-P0-04` 后自动缓解） |
| 16 | `getNoteHistory` 的 `GROUP BY TRIM(note)` 无法走索引 | `local_transaction_repository.dart:939-955`（仅备注历史弹窗，可接受） |
| 17 | `pulse_skeleton` 用 `Opacity` 全帧重合成 | `widgets/ui/skeleton.dart:100-105`（改子项颜色即可） |
| 18 | 声明但未使用的 `WAKE_LOCK` 权限 | `AndroidManifest.xml:20`（全仓无 `newWakeLock`） |
| 19 | 死代码 | `services/data/migration_service.dart` 的 `AccountMigrationService`（无调用点）、`providers/github_star_provider.dart:9`（无调用方） |

---

## 7. 验证方案

现有 `docs/ux-performance-optimization-plan.md` 第 6 章已有基准体系要求，本节只补三条可立即执行的：

1. **冷启动**：`flutter run --profile` + DevTools Timeline，测 `addPostFrameCallback` 到 `AppInitState.ready` 的间隔。`appSplashInitProvider` 内已有逐段耗时日志（`ui_state_providers.dart:257-263` 的 `timed()`），直接抓 logcat 即可得到分段数据。
2. **滚动 / 交互**：`--profile` 下开 Performance Overlay，跑首页、搜索页、统计页、资产页，重点看 UI 与 raster 线程是否都超 16ms。
3. **后台耗电**：`adb shell dumpsys batterystats --charged com.smartbook.zhi`，对比修 `PERF-P0-05` / `PERF-P0-06` 前后的网络请求次数；离线场景用飞行模式跑 1 小时，看 logcat 里 refresh/login 的次数与重连循环（修复前基线：至多 1 次 refresh POST + 有邮密时 ~120 次 login POST + 每 3s 一次本地失败循环；修复后网络请求趋近 0、退避循环 ≤30 次/小时）。

---

## 8. 建议实施顺序

```text
第一批（局部改动、收益立竿见影、都有回退路径）
  PERF-P0-01 周期交易移出 Splash 闸门
  PERF-P0-02 通知权限延后
  PERF-P0-03 SQLite WAL（含 clearDatabaseLockFiles 修正）
  PERF-P0-04 账户索引 + 聚合改 SQL（先写对比测试）

第二批（渲染侧）
  PERF-P0-07 搜索页  →  PERF-P1-07 TransactionList 引用稳定
  →  PERF-P1-06 统计页 FutureProvider  →  PERF-P1-03 tab 懒挂载

第三批（后台 / 同步）
  PERF-P0-05 WS 退避  →  PERF-P0-06 HTTP 超时
  →  PERF-P1-04 附件查询形状  →  PERF-P1-05 30s 扫描  →  PERF-P1-02 日志门控

第四批（数据层收尾）
  PERF-P1-10 N+1  →  PERF-P1-11 判重  →  PERF-P1-12/13 索引与 selectOnly
  →  PERF-P1-18 删除事务  →  PERF-P1-17 大文件 isolate
```

**可并行**：第 5 节的零风险快修不依赖任何一批，可随时插入。

---

## 9. 附：明确「未发现」的问题

避免后续重复排查，以下常见问题经核对**不存在**：

- **启动即把全部交易/账户/分类/标签读进内存**：未发现。首页窗口化分页，Splash 只预取 20 条（`ui_state_providers.dart:266-274`）。唯一例外是 `PERF-P0-01`。
- **主 isolate 上做迁移 / 种子 / 加密**：未发现。Drift 迁移在后台 isolate；`ensureSeed` 只在欢迎页调用。
- **`AutomaticKeepAliveClientMixin` 滥用**：全仓 0 处。
- **一次性 `List.generate` 全量构建长列表**：未发现（仅饼图扇区上限 8、骨架屏格子等固定小集合）。
- **`SingleChildScrollView + Column` 套长列表**：交易/搜索/统计列表里未发现。
- **长列表项里的 `Opacity` / `BackdropFilter` / `ShaderMask`**：未发现。`BackdropFilter` 只在 `main.dart:703` 与 `widgets/ui/dialog.dart:252,530`。
- **定时全量同步 / O(n²) 冲突检测 / Subscription 泄漏**：均未发现（详见第 2 节）。
- **AI 调用无超时**：未发现。`ai/relay/ai_relay_client.dart:126-143` 各能力有 deadline（text 40s / vision 65s / chat 130s）+ `:489` `.timeout()` + 429/502/503/504 归类 transient。
- **`decimal` 在热路径 / `@TableIndex` 注解**：前者未进热路径，后者未使用（索引全在 `_ensureIndexes()`）。
- **交易导入 / pull 逐条 insert**：未发现（已用事务 + batch；配置导入 / seed 的逐条写另见 P2-10）。

---

## 10. 审计方法与局限

- **方法**：4 路并行静态审计（启动链路 / 列表与报表渲染 / 数据层与 Drift / 同步与后台）+ 主审对关键结论逐条回读源码复核。
- **局限**：**未在真机跑 profile**，未采集 DevTools Timeline、未做 batterystats 对比；文中耗时均为「静态推断 + 量级理由」，标注为「推断」。
- **下一步**：按第 7 节建立基准后，用实测数据修正第 3、4 节的收益预估，并据此调整第 8 节排期。
