# SmartBook 设计缺陷修复计划（2026-09-15 第二轮 review）

> 文档状态：**Fix Plan v1.1 —— P0 七条 + P1 五主题 + 4.4 部署批次已实施（2026-09-15，工作区待提交）；P2 四批与附录 B 剩余项实施中**（本文既是问题记录也是实施计划，修完一条勾一条/标注 commit）
> v1.1 修订（2026-09-15）：全文经第二轮 5-agent 源码逐条复核（约 109 个核实点），**P0 七条全部属实**；作废 1 条（原 P1-C3「缺索引」——索引已存在于 0029 迁移）、修正 6 条（A5 索引 / B1 机制 / S10 行为 / S8 参照 / P1-C2 路径 / 附录B5 表述）及 P2-D1 后果链，并并入核实新发现（S10 同源 bug、C7 扩面、W3 第四处、A2 存量、契约锁描述错误等），均以〔v1.1 核实修正〕/〔v1.1 核实〕标注
> 制定日期：2026-09-15
> 基线：HEAD `209dfc5`（前次 review 的 5 条 ≥80 分修复之后）
> 审查方法：5-agent 并行分域**只读**审查（服务端同步架构 / 服务端业务路由 / Web 前端 / Flutter 客户端 / 部署配置），以「设计缺陷 + 逻辑优化」为视角，约 **80 条新发现**，每条经源码核证并附 `file:line`
> 与既有文档的关系：
> - 前次（同日上午）仓库级 code review 的 ≥80 分 5 条已修复提交（`e655fe3` / `209dfc5`），**不在本文范围**；其 75 分档 9 条近失仍未修，收录于**附录 B**，建议与本文 P2 同批排期
> - 客户端性能类问题由 `docs/app-performance-audit-2026-09-08.md` 及两份 performance 计划覆盖，与本文不重叠
> - 涉及同步契约的修改（P0-1/P0-2/P0-5）落地前须先更新 `server/docs/SYNC_ARCHITECTURE.md`（见各条「注意」）

---

## 1. 结论速览

### 1.1 修复波次

| 波次 | 内容 | 规模 | 建议 commit 拆分 |
|------|------|------|------------------|
| **P0**（7 条） | 数据丢失 / 数据正确性级 | 每条独立小改 | 每条一个 commit（P0-1 与 P0-2 合并修，同根因） |
| **P1**（5 主题） | 跨域系统性设计债 | 每主题 1-3 天 | 每主题一个 commit |
| **P2**（4 批） | 分域批量清理（中低严重度） | 每条独立小改 | 按域各一个 commit，可穿插进行 |

### 1.2 P0 速览

| 编号 | 问题 | 一句话后果 | 域 |
|------|------|-----------|-----|
| P0-1+2 | 共享账本 user-global 作用域错配 + push user-scope 无锁 | Editor 改名/删除级联全 miss owner 投影，**永久显示旧名 / 悬挂外键**；违背 SYNC_ARCHITECTURE §4.7 | 服务端同步 |
| P0-3 | 客户端把服务端 5xx/403 判为永久失败 | **原始短信/通知被 ACK 永久删除**，一次服务端异常即销毁记账证据 | 客户端 |
| P0-4 | PG 备份断供 + deploy/ compose 空库陷阱 | **生产库无可用备份**；在 deploy/ 下 up 会「数据全丢」 | 部署 |
| P0-5 | 软删 × LWW 交叉语义未定义 | 离线编辑胜过删除时产生**幽灵交易**（C 端重建、服务端眼里不存在、永不进统计） | 服务端同步 |
| P0-6 | Web 列表请求竞态 + 缓存桶不随 key 重置 | 切账本/筛选后**显示错账本数据**；首挂发 unscoped 全 workspace 查询 | Web |
| P0-7 | GlobalEditDialogs 保存后不刷新 | WS 断开时 UI **长期陈旧**（poller 又按 device_id 过滤自己的写） | Web |

### 1.3 系统性主题（P1）一览

| 主题 | 一句话描述 |
|------|-----------|
| P1-A 无出口治理 | 客户端事件表无限增长且重试无上限（截图消失→**无限 2h 循环**）；服务端 sync_changes / ai_analysis_logs / audit_logs 无 retention |
| P1-B fire-and-forget 补偿 | trash restore 实时通知**从未生效过**（广播 task 根本不会被创建，见 B1 v1.1 修正）；Editor 掉线即永久拉不到 owner 的 user-global 变更；AI outbox worker **实现完整但从未接线** |
| P1-C push 批量形态 | 客户端无上限单请求 + 同实体重复序列化；服务端 push 整批同步 DB **阻塞 event loop**（原「user-scope LWW 缺索引」经核实不成立已作废——见 C3） |
| P1-D 配置断链 | compose 白名单外十余项变量静默失效；反代下限流退化为全站共享桶；`SMARTBOOK_APP_URL` 是死变量 |
| P1-E 幽灵账本 guard + role | 「首绑放行」是死代码，Editor 被移除后重推**静默重建私有账本**；`/sync/ledgers` 硬编码 `role="owner"` |

---

## 2. P0：数据丢失 / 数据正确性级

### P0-1 + P0-2：共享账本 user-global 作用域错配 + push 无锁（合并修）✅ 已实施（2026-09-15，待提交；谓词改造+user→ledger 双锁+契约 §4.4/§4.7 更新，测试 `test_user_global_cascade_shared_ledger.py`；附件 GC 漏扫 owner 行同根因补修中）

**问题**
账户/分类（user-global 实体）的 rename cascade、删除前引用校验、cascade 事件补发全部按 `user_id=操作者` 过滤，但 tx 投影行的 `user_id` 写的是 **ledger owner**（Editor 可 push 交易进共享账本）。共享账本场景：
1. Editor 改名账户/分类 → owner 端投影 denorm 列（`account_name` 等）永不刷新，且不补发 cascade SyncChange，owner 的 mobile/web **永久显示旧名**；
2. Editor 删除「仍被共享账本交易引用」的账户 → 引用校验误判为无引用，放行删除，留下悬挂 `account_sync_id`；
3. 附件 GC 同模式漏扫 owner 行（`projection.py:1270-1280`）。

单人单账本（owner==actor）不触发，纯共享账本必现。

**位置**
- `server/src/sync_applier.py:519-557`（`_detect_and_run_rename_cascade_user`，全部以 actor user_id 调 cascade）
- `server/src/sync_applier.py:429-444`（`_delete_user_account` 引用检查按 `ReadTxProjection.user_id == user_id`）
- `server/src/projection.py:745-777, 794-801`（`rename_cascade_account/category` 的 `WHERE user_id == ...`）
- `server/src/routers/write/_shared.py:914-960`（三个 `_cascade_tx_rows_for_*` 点查同样按 actor）
- 〔v1.1 核实补充〕作用面比原清单更大：全量 diff 路径 `write/_shared.py:399-411` 与快路径 `:1134-1147` 的 `rename_cascade_*` 调用、`write/tags.py:41`、`write/categories.py:53` 点查同样以 actor 过滤——谓词改造落在 `projection.rename_cascade_*` 内部即可全覆盖
- 对照：投影行归属 `sync_applier.py:760-766`（`user_id=ledger_owner_id`）、`push.py:159-172`（Editor 可推 transaction）
- 锁缺失：`server/src/routers/sync/push.py:280-342`（user-scope 分支无 `lock_ledger_for_materialize`）；ledger-scope 分支 `push.py:386` 有锁，web 写路径 `write/_shared.py:1072, 1316` 有锁；契约 `server/docs/SYNC_ARCHITECTURE.md` §4.7 明文要求 push 应用投影前取锁

**改法**
1. **谓词改造（治本）**：级联与引用检查的匹配谓词从 `user_id == 操作者` 改为按稳定 FK 列匹配——账户用 `account_sync_id / from_account_sync_id / to_account_sync_id`，分类用 `category_sync_id`（sync_id 是 UUID，跨用户碰撞可忽略；这些列本来就是投影上的真实引用）。`_delete_user_account` 引用检查同理。Editor 触发的级联自然命中 owner 名下的行，不需要在投影上补 actor 维度。
   - ⚠️ 不要用「ledger ∈ 该用户可访问集合」收窄 sync_id 匹配——会重新引入作用域问题。
2. **锁补齐（防抖）**：`concurrency.py` 加 user 级锁 `lock_user_global(user_id)`（与现有 ledger 锁同机制，key `user_global:{user_id}`）。三处调用：push user-scope 分支 apply 前；web 写路径修改 user-global 实体（账户/分类/标签的改名、删除）时；push ledger-scope 分支**双取** user 锁（owner）+ ledger 锁，**固定顺序 user→ledger 防死锁**。
3. 谓词改造落地后级联变为幂等的 sync_id 纠正，锁从「防错」降级为「防抖」，即使有遗漏窗口也不会永久漂移。

**注意**
- `SYNC_ARCHITECTURE.md` 需补两条契约：user-global 实体对投影的匹配按 sync_id 而非 user_id；user-scope push 的锁顺序。
- 〔v1.1 核实补充〕契约文档自身有错需顺带修正：`SYNC_ARCHITECTURE.md:291` 称该锁为「SQLite advisory lock」，实际 `concurrency.py:19-25` 是 SQLite 下 no-op、PostgreSQL 才是 `pg_advisory_xact_lock`（措辞系方案 A 时代遗留）。
- 不改 `rename_cascade_*` 的 UPDATE 本身是否过滤软删行（现不过滤、只改 denorm 列、不发事件——语义无害且 restore 后名字是新的反而正确）。

**验证**
- 新增回归测试：① Editor push 引用自己账户的交易 → Editor 改名该账户 → 断言共享账本投影 denorm 已刷新、cascade SyncChange 已补发（owner 端 pull 可见）；② Editor 删除仍被引用的账户 → 断言拒绝而非放行；③ 并发 push 场景（user-scope rename + ledger-scope tx upsert 交错）投影无漂移。
- 命名沿用现有风格，如 `test_user_global_cascade_shared_ledger.py`。

---

### P0-3：客户端 AI 中转把 5xx/403 判为永久失败 → ACK 删除原始短信/通知 ✅ 已实施（2026-09-15，待提交；默认 transient+400/404/422 白名单 permanent、_send 全 5xx、applyFailureCode 补 http_error、`ai_runtime_state` 分支；14 用例已写，待 Flutter 环境执行 `flutter test test/ai/relay/ai_relay_client_error_classification_test.dart`）

**问题**
`_errorFrom` 仅 401 设 `transient: true`，其余一切状态码（含 **500、403**）均 `transient=false` → `permanentFailure` → `canAckNativeQueue=true` → Kotlin 侧删除原生队列项并写**永久指纹**。服务端一次未捕获异常（FastAPI 500）、网关新错误码、临时 403 都会永久销毁记账证据——与代码库反复强调的 M1-2 原则（「临时失败绝不能 ACK 原始队列」）直接矛盾。

**位置与传播链**（已逐环核证）
- `client/lib/ai/relay/ai_relay_client.dart:438-461`（`_errorFrom`）+ `:516-527`（`_send` 仅 429/502/503/504 转 transient）
- → `client/lib/ai/providers/ai_provider_factory.dart:89` → `client/lib/ai/core/ai_extraction_engine.dart:226-228`（transient? retryable : permanentFailure）
- → `client/lib/services/automation/auto_billing_service.dart:1264` → `SmsProcessOutcome.permanentFailure`，`canAckNativeQueue=true`（`:92-95`）
- → `client/android/app/src/main/kotlin/com/smartbook/zhi/SmsReceiver.kt:237-271`（ackQueue 删队列项 + 永久指纹）
- 配套缺失：`client/lib/ai/core/ai_runtime_state.dart:88-99`（`applyFailureCode` 无 `http_error` 分支）

**改法**
1. 错误分类反转为「**默认 transient，显式白名单 permanent**」：仅 400/404/422（请求本身不合法、重试无意义）判 permanent；401 维持 transient（token 刷新可能修复）；全部 5xx / 网络错误 / 超时均 transient。
2. `_send` 的 transient 状态码集合同步扩为全部 5xx。
3. `applyFailureCode` 补 `http_error` 分支，让 AI 运行时状态机可感知。

**注意**
- 反转后真正的永久失败（如 provider 配错 key 返回 400）依然 ACK，不会造成无限重推；重试放大由 P1-A 的 maxAttempts 兜底（两项配套落地）。

**验证**
- 单测：mock 中转返回 500 → 断言 outcome=retryable 且 `canAckNativeQueue=false`；返回 400 → 断言 permanentFailure 且 ACK；返回 403 → retryable。

---

### P0-4：PG 备份断供 + deploy 副本空库陷阱（部署侧）✅ 已实施（2026-09-15，待提交；pg_dump 方言分支+postgresql-client-16（PGDG trixie 实测）、deploy/docker-compose.yml 已删除、密码 fail-fast、`test_pg_dump_snapshot.py` 6 用例；真实 pg_dump 产物与 restore 链路待部署后手工验证）

**问题 A —— 内置备份与 canonical PostgreSQL 部署根本不兼容**
- `server/src/services/backup/db_snapshot.py:73` 执行 SQLite 专有的 `VACUUM INTO`，PG 下直接语法报错；`runner.py:265` 备份第一步就是它 → **PG 部署下每次定时/手动备份必然失败**（附件与 `.jwt_secret` 都到不了打包阶段）。
- 唯一 PG 脚本 `server/scripts/backup_postgres.sh:8-9` 绑定的是 `server/` 下另一套 compose（服务名 `db`），与根 compose（服务名 `smartbook-db`）不匹配，跑不通；且无调度。
- `db_snapshot.py:32` 注释仍称 ai 日志「7 天滚动」，与实现矛盾（该表不设保留期）。

**问题 B —— deploy/ 副本漂移构成「空库陷阱」**
- `deploy/docker-compose.yml` 缺 `name: auto-ledger`（根 `docker-compose.yml:1` 有）→ compose 项目名默认取目录名 `deploy`，volume 变为 `deploy_smartbook-db-data`，与根的 `auto-ledger_smartbook-db-data` **是两个不同卷** → 在 deploy/ 下 `docker compose up -d` 拉起全新空库新栈，用户表现即「数据全丢了」。
- `deploy/docker-compose.yml:31` 硬编码 `DATABASE_URL`（根 `docker-compose.yml:31` 支持 `${SMARTBOOK_DATABASE_URL:-...}` 覆盖）；`:4,20` 多出 `container_name`。
- `server/docker-compose.yml:3` 仍指向上游官方镜像 `sunxiao0721/beecount-cloud:latest`（AGENTS.md 明确已脱离）；`server/docker-compose.postgres.yml:5-9` `POSTGRES_PASSWORD: smartbook` 弱凭证 + `5432` 端口发布到宿主机。

**改法**
1. `runner.py` 按 `DATABASE_URL` 方言分支：PG 走 `pg_dump --format=custom --no-owner --no-privileges`（子进程，密码经 `PGPASSWORD` 环境变量传入，不落命令行）；`Dockerfile` 安装与 compose 中 PG 大版本**匹配**的 `postgresql-client-XX`（⚠️ pg_dump 客户端大版本必须 ≥ 服务端，这是最易被忽略的坑）。〔v1.1 核实〕当前镜像完全未装 postgresql-client（`Dockerfile:62-66` apt 仅 tzdata/curl/rclone），裸 `docker run` 走 SQLite 默认 `DATABASE_URL`（`:94`）故未暴露——PG 分支与客户端安装必须同批落地。
2. 过渡期三件小事：修 `backup_postgres.sh` 服务名（`db` → `smartbook-db`）+ 附 cron 示例；PG 方言下启动打 WARNING「内置备份对 PostgreSQL 不可用」；修 `db_snapshot.py:32` 过时注释。
3. **删除 `deploy/docker-compose.yml`**（AGENTS.md 已声明根 compose 为 canonical）；若确需保留：补 `name: auto-ledger`、`DATABASE_URL` 改插值、删 `container_name`、文件头注明「以根 compose 为准」。
4. `server/docker-compose.yml` 改 `image: smartbook-server:latest` 或删除；`server/docker-compose.postgres.yml` 密码改必填插值、去端口发布、标注「仅本地开发」。
5. PG 密码 fail-fast 对齐 JWT：`${SMARTBOOK_DB_PASSWORD:?Set SMARTBOOK_DB_PASSWORD in .env}`（现 `${SMARTBOOK_DB_PASSWORD:-CHANGE_ME}`）。

**验证**
- PG 部署下手动触发备份成功产出 `.dump`；`docker compose -f docker-compose.yml config` 确认卷名/插值正确；在 deploy/ 目录下执行 compose 命令应直接失败或指向根（删除方案下）。

---

### P0-5：软删 × LWW 交叉语义未定义 → 幽灵交易 ✅ 已实施（2026-09-15，待提交；复活语义：upsert_tx ON CONFLICT SET 加 deleted_at=None，契约新增 §4.8，测试 `test_soft_delete_lww_revive.py` 2 用例含三端收敛断言）

**问题**
设备 A 删交易（delete 事件），设备 B 离线不知情、编辑该交易后 push upsert（updated_at 更新、LWW 胜出）→ 服务端：
- `upsert_tx` 的 values 不含 `deleted_at`，ON CONFLICT 只 SET 非主键 values 列 → 软删标记保持非 NULL（回收站躺一具「内容已被改过」的尸体）；
- 同时该 upsert 事件**照常广播**给所有设备 → 设备 C pull 后按 upsert 语义**重建这笔交易**——而服务端 `/read/*`、统计、`/sync/full` 都视其不存在 → C 端一笔永不进统计、服务端眼里不存在的幽灵交易。

软删（0030）与 LWW（§4.2）两个机制的交叉语义没有被定义（`read/trash.py:178-179` 服务端自己的注释也证实 mobile 端 pull upsert 会覆盖本地 tombstone 重建）。

**位置**
- `server/src/projection.py:243-298`（`upsert_tx` values 无 `deleted_at`）
- `server/src/sync_applier.py:742-766`（upsert 分支无软删感知）
- LWW 裁决：`push.py:187-224`（〔v1.1 已核实〕lookup 按 entity_type+entity_sync_id 查最新 change **不过滤 action**——delete 事件的 updated_at 参与同一比较，`(updated_at, device_id)` 元组裁决，B 离线编辑更晚则 upsert 胜出进 apply）

**改法**
采用「**复活语义**」：upsert 是客户端「此实体存在且内容如此」的声明，能通过 LWW 胜出的 upsert 应同时清 `deleted_at`（与 trash restore 语义对齐、符合 LWW 最新者胜）。实现上把 `deleted_at=None` 加进 `upsert_tx` 的 ON CONFLICT SET 列即可；`sync_applier.py` 分支无需特判（LWW 已在 push 层裁决）。收敛结果：B 的编辑胜出 → 交易复活且内容为 B 的版本，三端一致。

**注意**
- ⚠️ 这是全计划里**语义改动最大**的一条（改变 delete/upsert 的最终裁决结果），上线前必须在 `SYNC_ARCHITECTURE.md` 落一节「软删与 LWW 交叉语义」，并跑多端模拟（A 删 / B 离线编辑 / C 观察）三端一致性测试。
- 若评审认为删除应优先（墓碑语义），则改为「delete 胜出时拒绝 upsert 且**不广播**」——无论选哪种，当前「不清 deleted_at 但广播 upsert」的自相矛盾状态必须消除。

**验证**
- 测试：A push delete → B push 更晚 updated_at 的 upsert → 断言行 `deleted_at IS NULL`、统计包含该交易、第三端 pull 后可见；B 的 upsert 早于 delete 时间 → 断言仍为软删且**无 upsert 广播**。

---

### P0-6：Web 列表请求竞态 + 缓存桶不随 key 重置 ✅ 已实施止血（2026-09-15，待提交；`useLatestFetch` 5 文件 10 条流、`ledgerId===''` 跳过首拉、`usePageCache` key 重置；vitest 83 用例+tsc+build 全绿。治本 TanStack Query 仍待排期；弱网切账本待人工验证）

**问题**
- `refreshSectionData` 落地后无条件 setState，不感知取消标志——快速切账本 A→B，A 的响应后落地则**列表显示 A 的交易但页头是 B 的账本**；WS/polling 触发路径（`refreshAllSections`）零保护。
- 更隐蔽：首次挂载时 `sectionNeedsLedger('transactions')=false`（`TransactionsPage.tsx:211`），`activeLedgerId` 未 reconcile（`''`）时即发请求，`ledgerId || undefined` 会发一次**不限账本的全 workspace 交易查询**，与后续 scoped 查询竞争。
- `usePageCache` 只在组件首次 mount 读一次 cache，key 变化（切账本）不重置 state；切账本时 Page 不 unmount（Outlet 复用）→ 首帧仍显示**旧账本**数据。`OverviewPage.tsx:39-42` 注释宣称「切账本时读对应桶」与实现不符。
- 同模式页面：AccountsPage / OverviewPage / AiLogsPage / GlobalEntityDialogs（scope 快速切换同样互相覆盖）。

**位置**
- `server/frontend/apps/web/src/pages/sections/TransactionsPage.tsx:765-799`（refreshSectionData）、`:1026-1069`（cancelled 只护到 loadLedgerBase）、`:872-885, 939-941`（WS/polling 路径）
- `server/frontend/apps/web/src/context/PageDataCacheContext.tsx:57-82`；消费方 `TransactionsPage.tsx:312-317`、`OverviewPage.tsx:43-113`、`CalendarPage.tsx:178-179`、`AccountsPage.tsx:138-146`

**改法（两步走：先止血再治本）**
1. **止血（当天可完成）**：
   - 写一个 ~20 行的 `useLatestFetch(fn)` hook（组件内 seq 计数，响应落地 `if (mySeq !== seqRef.current) return` 再 setState），五个消费点统一替换；
   - `sectionNeedsLedger` 语义下 `activeLedgerId === ''` 时**跳过首拉**而不是发 unscoped 查询；
   - `usePageCache` 对 key 变化重置 state（`useEffect` 监听 key → `setState(cache.get(key) ?? initial)`），修正 OverviewPage 失实注释。
2. **治本（排期）**：引入 TanStack Query 替换各页手工 fetch + `usePageCache`，一次性解决竞态/去重/缓存失效/乐观更新；`useSyncRefresh` 配 300-500ms trailing debounce + `refreshLedgers` single-flight（进行中复用同一 Promise）——同时解决「手机批量推变更 → 每条 sync_change 触发 AppShell+当前页全量刷新（交易页每事件 7-10 请求，10 条连续事件 ≈ 100+ 请求）」的**事件风暴放大**问题。

**验证**
- 手动：快速切换账本 A↔B 10 次，断言最终列表与页头账本一致、无 A 数据闪现残留；弱网（DevTools throttle）下复测。

---

### P0-7：GlobalEditDialogs 保存后 UI 长期陈旧 ✅ 已实施（2026-09-15，待提交；保存成功经 `useSyncBroadcast()` 本地派发 sync_change 复用各页 useSyncRefresh 订阅、删除 bumpLedger 失实注释；断 WS 场景待人工验证）

**问题**
`handleSaveTx/handleSaveCat` 成功路径只 `notifySuccess` 不触发任何本地刷新；注释（第 45 行）声称靠 `bumpLedger` 触发刷新——**代码库中不存在该方法**（全仓仅此注释一处）。WS 健康时靠服务端广播回流；WS 断开时兜底 poller 的 drainPull 携带 device_id，服务端 `pull.py:78-90` 明确过滤「自己 push 的变更」→ 页面**长期显示旧数据**。TransactionsPage 自己的保存显式调了 `refreshSectionData`（`:1617`）——行为不一致。

**位置**
- `apps/web/src/components/GlobalEditDialogs.tsx:211-339`（handleSaveTx）、`:376-418`（handleSaveCat）、`:45`（失实注释）
- 兜底链：`apps/web/src/state/sync-client.ts:63` + `server/src/routers/sync/pull.py:78-90`

**改法**
保存成功后主动调用对应刷新（复用 `refreshSectionData` 或经 context 派发本地事件），与 TransactionsPage 对齐；删除失实注释。poller 的 device_id 过滤是协议语义，**不必改**（本条修复后该盲区自然缓解）。

**验证**
- 断开 WS（DevTools offline WS），在全局弹窗编辑交易保存 → 断言列表立即更新。

---

## 3. P1：系统性主题（每主题一个 commit）

### P1-A：「无出口」治理（数据只进不出）✅ 已实施（2026-09-15，待提交；A1 maxAttempts=8+evidenceMissing 终态、A2 十处构造点带 expiresAt(capturedAt+30d)+存量回填+15min 周期清理、A3 purge 时 compact upsert 事件（cleaner+手动 purge 两入口）、A4 每日 trash retention 任务、A5 AI_LOG_RETENTION_DAYS=180/AUDIT_LOG_RETENTION_DAYS=365 进 retention 循环、A6 三索引进 models.py 未建迁移。客户端部分待 Flutter 环境验证）

| # | 问题 | 位置 | 修法 |
|---|------|------|------|
| A1 | 事件重试无上限 + 截图文件消失后**无限 2h 重试循环**（每次都是一次 AI 中转调用） | `client/lib/services/automation/auto_book_event_store.dart:216-239`（`markRetry` clamp(1,5) 用尽后永远 2h）；drain 路径 `auto_billing_service.dart:443-467`（等文件 3s 超时→retryable） | `markRetry` 加 maxAttempts=8，用尽落 `failed`+`retry_exhausted`；drain 主路径对 screenshot 源事件先 `File.existsSync()`，缺失即 `expired`（复用重放路径 `_markReplayEvidenceMissing`（`auto_billing_service.dart:1238-1250`）的逻辑） |
| A2 | `auto_book_events` 无限增长：生产代码**从不写 `expiresAt`**，`cleanupExpired` 恒不命中 | `auto_book_event_store.dart:842-855`（DELETE 要求 expiresAt 非空）；四路 monitor 构造 `AutoBookInput` 均不传（`sms_monitor_service.dart:188-208` 等） | 四路 monitor 构造时统一带 `expiresAt`（建议 30 天）；`countByState` / `_findTransactionByExternalIdScan` 全表 SELECT 随之受控。〔v1.1 核实补充〕不止四路 monitor——data_import/recurring/app_link/image_share 构造点同样不传，且**存量事件行全部无 expiresAt**（`_replayInput` 回放透传原 null），需一次性补写或明确接受存量豁免 |
| A3 | 服务端 `sync_changes` 对最大实体（transaction）只增不减：物理 purge 只删投影不动 upsert 事件；compact 仅覆盖小实体 | `sync_applier.py:294-299`（_delete_tx 注释自认）、`services/data_cleanup/cleaner.py:277-299`（purge_tx）、`sync_applier.py:258-291`（compact 仅 budget/adjustment/category/account/tag/erate） | 物理 purge 交易时同步 compact 其 upsert 事件（复用 `_compact_entity_upsert_events`，保留 delete tombstone 的例外同款）；中期基于 SyncCursor 最老游标做安全水位归档 |
| A4 | 0030 注释承诺「30 天后自动物理删除」但回收站 cleaner **无任何调度**（仅 admin 手动 API） | `0030_tx_soft_delete.py:8-10`、`models.py:752` vs `main.py:326-341, 413-433`（现有 retention 循环不含它）、`admin.py:565-577` | `main.py` retention 循环家族加每日任务：`scanner._scan_tx_trash_expired` → `cleaner.clean`；或改注释明示需手动 |
| A5 | `ai_analysis_logs` 无保留期（二开后四路识别全落这张表，写入频率远超上游）。〔v1.1 核实修正〕原「列表分页缺复合索引」**不成立**：`ix_ai_log_user_time (user_id, called_at DESC)` 已存在（`models.py:236-240`、迁移 `0019_ai_analysis_logs.py:65`），列表查询完全命中，索引部分撤销 | `main.py:318-322`、`config.py:47-50`、`routers/ai/logs.py:204-216`（查询已被现有索引覆盖） | 新增 `AI_LOG_RETENTION_DAYS`（建议默认 180，图片同步删）进 retention 循环；`audit_logs` 一并配 retention；~~迁移 0031 加 `(user_id, called_at DESC)` 复合索引~~（撤销——索引已存在） |
| A6 | models 与迁移漂移：0029/0030 的 3 个热索引只在迁移里，`models.py` 无定义（测试库 create_all 与生产 schema 不一致） | `0029_perf_hot_indexes.py:26-38`、`0030:30-34` vs `models.py:557-572, 758-779` | 3 个索引（含 `coalesce(created_at, happened_at) DESC` 表达式索引）补进 models.py `Index(...)`，恢复单一事实源。〔v1.1〕其中 `idx_sync_changes_user_scope_entity_latest` 即原 C3 误判缺失的索引——生产库已有，此处只补 models 定义，**勿再建新迁移** |

### P1-B：fire-and-forget 补偿 ✅ 已实施（2026-09-15，待提交；B1 commit 前查成员+run_coroutine_threadsafe 逐成员广播、B2 owner user-global 变更派生 ledger-scope 镜像 SyncChange（契约 §4.9）、B3 outbox worker 接线 main.py startup/shutdown（默认仍关））

| # | 问题 | 位置 | 修法 |
|---|------|------|------|
| B1 | trash restore 的实时通知**从未生效过**。〔v1.1 核实修正〕实际失败机制比原描述更安静：`restore_trash_tx` 是同步 `def` 路由（FastAPI 跑线程池），`trash.py:210-213` 的 `asyncio.get_running_loop()` 在 worker 线程必抛 RuntimeError → 被 catch → `loop=None` → 广播 task **根本不会被创建**（连 "Task exception was never retrieved" 都不出现；原预言的 `db=None`→AttributeError 仅在改成 `async def` 后才会触发，但该传参本身仍是错的——`websocket_manager.py:77`→`ledger_access.py:169` 首步查成员必炸） | `read/trash.py:210-227` → `websocket_manager.py:77` | commit **前**把成员列表查出，逐个 `broadcast_to_user`（改动最小）；或让 `broadcast_to_ledger` 支持 `db=None` 时自开 `SessionLocal`。与 write/push 路径「commit 后 await 广播」模式对齐 |
| B2 | 共享账本 owner 的 user-global 变更只靠 WS 推送，**Editor 掉线即永久拉不到**（pull 的 scope 过滤排除 owner 的 user-scope 行）→ 镜像永久分叉，30s polling fallback 对该通道完全无效 | 根因 `pull.py:58-67`；fan-out `write/_shared.py:1456-1458`（注释自认）、`:1506-1538`、`push.py:480-505` | owner 的 user-global 实体变更且账本有成员时，**同步派生 ledger-scope 镜像 SyncChange**（内容即 cascade 后的投影状态）——Editor 的常规 `/sync/pull` 天然拉得到，WS 退化为加速通道，完全复用现有协议、不需要新表。镜像事件只含 Editor 本可见的投影 denorm 内容（隐私边界不变） |
| B3 | AI outbox worker 实现完整（enqueue→claim→archive 状态机、lease、退避、dead-letter）但 **main.py startup 从未接线**——`AI_LOG_OUTBOX_ENABLED` 一开，所有 AI 日志滞留 pending、Web「AI 调用记录」不再更新、spool 图片堆积 | `services/ai/analysis_log_worker.py:299`（`run_worker_forever` 全仓无调用方）、`main.py:248-430`（其它调度器都在）、`config.py:55-58`（默认 False） | `main.py` startup：`if settings.ai_log_outbox_enabled: asyncio.create_task(run_worker_forever(stop_event))` + 先 `recover_stale_leases()`；shutdown 时 set stop_event。接线前不开开关；接线后评估默认开——顺带消除「vision 响应尾部同步等 5MB 图片写盘」（`relay.py:446-464` → `analysis_log.py:103-158`） |

### P1-C：push 批量形态 ✅ 已实施（2026-09-15，待提交；C1 push 批处理核心 run_in_threadpool（锁与事务同线程），C2 客户端按 (entityType,entitySyncId) 合并发最新快照+分批 ≤200 成功一批推进一批+样本截断防误标（附录 B1 一并）；客户端部分待 Flutter 环境验证）

| # | 问题 | 位置 | 修法 |
|---|------|------|------|
| C1 | 服务端 `/sync/push` 为 `async def` 但整批同步 DB 跑在 event loop 上（write 路径已为此改 threadpool，push 没改）——大批推送期间**全进程阻塞秒级**（含 WS 心跳、健康检查） | `push.py:11-18, 57-441`（每条 change 3-6 次同步查询）；对照 `write/_shared.py:644, 816, 1272, 1436`（`run_in_threadpool`，issue #31 A2） | 批处理核心丢 `run_in_threadpool`，WS 广播留在 loop 上；或 handler 改回 `def` 让 FastAPI 自动进线程池 |
| C2 | 客户端 push 无上限单请求（长期离线+导入积压 → 数千条×全量 payload 一次 POST，60s deadline，失败整体重推）+ 同实体多条 change 重复序列化同一最新快照 | `client/lib/cloud/sync/sync_engine.dart:1028-1074`、`client/packages/flutter_cloud_sync/lib/src/providers/smartbook_cloud_provider.dart:2232-2272`（〔v1.1 核实修正〕原路径 `client/lib/cloud/sync/` 下无此文件，实际在本地 path 依赖包内；pull 侧有 50/页分页，push 侧没有） | push 前按 `(entityType, entitySyncId)` 合并 local_changes 只发最新快照（成功后全部 markPushed）；分块每批 ≤200 条，成功一批推进一批 |
| ~~C3~~ **已作废** | ~~user-scope LWW 查询缺匹配索引~~〔v1.1 核实：不属实〕`0029_perf_hot_indexes.py:25-30` **已建** `idx_sync_changes_user_scope_entity_latest (user_id, scope, entity_type, entity_sync_id, change_id DESC)`，与 `push.py:188-198` 查询完全匹配（迁移 docstring 明说为此查询而建）。原审查只查了 models.py 漏了迁移，与 A6 恰好互补印证；真实缺口仅是 A6 范畴（测试库 create_all 缺该索引） | `0029_perf_hot_indexes.py:25-30` | 无需动作（原 0031 迁移建议撤销，避免与 0029 重复；并入 A6） |

### P1-D：配置断链 + 反代失真 ✅ 已实施（2026-09-15，待提交；D1 env_file: .env（required:false 新语法实测）+引导注释、D2 SMARTBOOK_APP_URL 已删除+AGENTS.md 同步、D3 CMD --proxy-headers+FORWARDED_ALLOW_IPS=172.16.0.0/12+docs/deploy/reverse-proxy.md（nginx/caddy 样例））

| # | 问题 | 位置 | 修法 |
|---|------|------|------|
| D1 | compose 环境变量为封闭白名单（12 项），`.env` 里设了也进不了容器的还有：`EXCHANGE_RATE_PROXY_ENABLED/CACHE_TTL_HOURS`（`.env.example:56-57` **未注释引导用户填**，当前默认值恰好相同掩盖断链）、`AI_LOG_OUTBOX_*`（config.py:55-63）、`AI_BILL_IDENTIFIER_DEDUP_*`（:70-75）、`AI_HTTP_VERIFY_SSL`（:141）、`STRICT_BASE_CHANGE_ID`（:123）、`BACKUP_SCHEDULER_ENABLED`、`ATTACHMENT_MAX_UPLOAD_BYTES`、`SCHEDULER_TIMEZONE`、`INVITE_SHARE_ORIGIN` 等 | 两份 compose 的 `smartbook-cloud.environment:` | 加 `env_file: .env`（显式 `environment:` 保留并继续覆盖，插值语义不变），一次解决；已知断链的 `EMBEDDING_*/REGISTRATION_ENABLED` 同步闭环 |
| D2 | `SMARTBOOK_APP_URL` 是**彻底死变量**（compose 与 server/src 均无消费点） | `.env.example:8` | 删除，或注明「保留给外部反代/文档用，服务端不消费」 |
| D3 | 反代下 uvicorn 不认 X-Forwarded（CMD 未配 `--proxy-headers`/`FORWARDED_ALLOW_IPS`，外部反代源 IP 是网桥网关非 127.0.0.1）→ 登录限流 key `f"{action}:{client}"` 全站共享桶——**一个来源可打满全站 429**；审计 client_ip 同样失真 | `server/Dockerfile:118`、`routers/auth.py:118-131`（〔v1.1 核实补充〕`main.py:147-148` 注释自认依赖 `--proxy-headers` 而 CMD 未启用，内证确凿） | compose 或 Dockerfile 设 `FORWARDED_ALLOW_IPS`（docker 网段或 `*`，单层可信反代前提）；部署文档写明「HTTPS-only 由外部反代实现」+ nginx/caddy 样例（AGENTS.md 该声明目前仓库内无实现、不可审计） |

### P1-E：幽灵账本 guard + role 硬编码 ✅ 已实施（2026-09-15，待提交；E1 首绑判据改 SyncChange updated_by_device_id 存在性+被移除成员（LedgerInvite.used_by/SyncChange 证据）显式拒绝 membership_revoked（契约 §4.10）、E2 list_accessible_memberships 真实 role+批量聚合消 N+1）

| # | 问题 | 位置 | 修法 |
|---|------|------|------|
| E1 | 「首绑放行」死代码：请求开头就赋 `device.last_seen_at=now`（`push.py:31-32`），判据 `if device.last_seen_at is not None`（`:117`）恒真，且 models 创建即有 default（`models.py:451-453`）——三重保证恒非 None。实际拦截只剩 `owned>=2`（`:122-142`）。真实路径：共享账本被删/Editor 被移除（`write/ledgers.py:330-335`）→ Editor 掉线未收到 → 后续 push 该账本 tx 时 accessible 返回 None → 若自有账本 ≤1，**以 owner 的 external_id 在 Editor 名下静默重建私有账本**，数据分裂 | `push.py:31-32, 117-142` | 首绑判据改不可变事实：在赋 last_seen_at **之前**查 `db.exists(SyncChange where updated_by_device_id=device)`（或独立 first_push_at 列）；对「caller 曾是该账本 member 但已被移除」显式拒绝（查成员历史/AuditLog），而非落入 auto-create |
| E2 | `/sync/ledgers` 对所有账本硬编码 `role=cast("owner","Any")`（`list_accessible_ledgers` 只返回 Ledger 对象丢了 role）——Editor 端拿到全 owner，客户端 UI 门控被误导；且每账本 4 次 N+1（tombstone/latest/tx_count 串行） | `sync/ledgers.py:20-52, 61`；`ledger_access.py:92-108`；批量版已存在 `read/_shared.py:265-290` | 改用 `list_accessible_memberships` 取 (ledger, role)；tombstone 复用 `_deleted_ledger_ids` 批量版，latest/tx_count 合并 GROUP BY 聚合 |

---

## 4. P2：分域批量清理（每域一个 commit，可与附录 B 合批）

### 4.1 服务端业务路由 ✅ 已实施（2026-09-15，待提交；S1-S12 全部：附件越权收口/Editor AI 上下文/ai_config_version 乐观锁（迁移 0032）/邀请码先抢占/头像鉴权+private 缓存（web 侧 useAvatarUrl fetch+blob 配套已完成，7 消费点全换、Flutter 端带 Bearer 不受影响）/relay to_thread/幂等过期/TOCTOU 409/附件部分唯一索引（迁移 0033，存量去重）/trash 按账本集合+PK+409 消歧/限流 key 清理+单 worker 文档化/S12 七小点。〔附带〕PG 全链迁移断点已修（0004/0005 boolean server_default + alembic_version 长度，真实 PG 容器从零到 head 实测通过）、SQLite batch downgrade 硬错误已修（0029 if_exists））

| # | 问题 | 位置 | 修法 |
|---|------|------|------|
| S1 | **被移除成员仍可下载其曾上传的交易附件**（第一优先分支按上传者放行，不查成员资格） | `attachments.py:283-284`（vs `:303-316` ledger 附件才查） | `ledger_id` 非空行统一走 LedgerMember 校验（owner/editor 均可读）；「本人上传」仅保留给 `ledger_id IS NULL`（category_icon）分支 |
| S2 | Editor 调 AI 记账拿不到共享账本上下文（仍按 `Ledger.user_id==user_id` 判定）→ 空分类/账户提示 + CNY 兜底，识别质量显著下降 | `routers/ai/parse_tx_image.py:270-277`（`parse_tx_text.py:65` 复用） | 换 `get_accessible_ledger_by_external_id`（任意可读角色即可，此处只做 hint 上下文） |
| S3 | `ai_config_json` 单 TEXT 列整块 read-modify-write 无并发保护——App/Web 同时在线（受支持场景）并发创建 provider 互相覆盖、PATCH 与 PUT 并发回滚 | `routers/ai/providers.py:184-190, 221-372`、`routers/profile.py:210-214` | UserProfile 加 `ai_config_version` 乐观锁（`UPDATE ... WHERE version=?`，冲突 409 重试） |
| S4 | SQLite 下邀请码「一次性」竞态：方言直接丢弃 `FOR UPDATE` 且默认 DEFERRED，注释所述排他锁不存在——并发 accept 同码均成功、5 人上限可绕过（PG 部署不受影响） | `invites.py:414-422, 452-457` | 改「先抢占」：`UPDATE ledger_invites SET used_at=?, used_by=? WHERE code=? AND used_at IS NULL`，rowcount=0 即 409；上限用 count + 唯一约束兜底 |
| S5 | `GET /profile/avatar/{user_id}` 完全无鉴权（无 scope dep、无 get_current_user），带 `v` 时还 `Cache-Control: public, immutable` | `routers/profile.py:346-370` | 至少加 `get_current_user`（只认证不查关系） |
| S6 | relay 判重/标识收割在事件循环线程同步打 DB（SQLite busy_timeout=5000 下一次写冲突挂起全进程数秒） | `routers/ai/relay.py:276-278, 339-341, 429-431, 533-535`（`bill_identifier.py:219` 内含 commit） | 统一 `asyncio.to_thread` + 独立 session（与日志写入路径同款） |
| S7 | Idempotency-Key 回放不校验过期（清扫每请求最多 200 行，积压时过期 key 仍被 replay） | `write/_shared.py:497-532` | 查询条件加 `expires_at > now`，命中过期行按 miss 处理并顺带删除 |
| S8 | create_ledger TOCTOU：并发同 external_id 返回 500 而非 409 | `write/ledgers.py:35-42` | 捕获 IntegrityError 转 409（同款模式参照 `write/_shared.py:627-635, 799-807`——〔v1.1 核实修正〕该模式不在 ledgers.py 本文件） |
| S9 | 附件上传去重 check-then-insert 无唯一约束（并发同图重复行+重复磁盘文件） | `attachments.py:104-118`、`write/transactions_batch.py:455-462` | 加部分唯一索引（transaction 类 `(ledger_id, sha256)`）+ 冲突复用 |
| S10 | trash 按 `(user_id, sync_id)` 点查，而表 PK 是 `(ledger_id, sync_id)`：跨账本同 sync_id 时**静默取到不确定的一行**——〔v1.1 核实修正〕实测 SQLAlchemy 2.0 `.scalar()` 多行**不抛** MultipleResultsFound、返回第一行（那是 `scalar_one()` 的行为），不会 500，而是可能 restore/purge **错账本的交易**，更隐蔽；原「无匹配索引」也不成立（0030 已建 `ix_read_tx_deleted_at (user_id, deleted_at DESC)`）。**〔v1.1 核实新增〕同源更重的 bug**：trash 列表/点查均按 `user_id==current_user.id` 过滤，而共享账本 tx 投影行 user_id 是 ledger owner（即 P0-1 的事实）→ **Editor 删除的交易进回收站后自己查不到、也恢复/清除不了**，仅 owner 可操作 | `read/trash.py:58-67, 83`（PK 见 `models.py:703-706`） | 响应带 ledger_id 按 PK 查；trash 列表/操作改按「用户可访问账本集合」过滤（与新增 bug 一并修） |
| S11 | 进程内限流/并发闸多 worker 失效 + 字典只增不减 | `relay.py:92-111`（`_RATE_WINDOWS`/`_PROVIDER_SEMS`）、`auth.py:43` | 部署约定单 worker 写入文档；或迁 DB/Redis；定期清空 deque 的 key |
| S12 | 杂项：`projection.py:129-144` 用 SQLite 方言 insert 跑在 PG（依赖两方言 ON CONFLICT 恰好兼容，引入任一方言特性即断）；`workspace.py:72-78` 逐 ledger N+1；net-worth 历史用**当前汇率**重放（多币种历史净值随当日汇率漂移，至少文档化）；`providers.py:355-372` update_binding 不校验 provider 存在；`read/_shared.py:83-91` `_is_admin` 恒 False 但 user_id 参数仍在（误导）；`analysis_log.py:150-152` image_path 存绝对路径（容器/卷迁移失效）；transfer_ownership 不变量校验在 commit 后（`members.py:390-397`） | 各处 | 按条小改：方言选 insert / GROUP BY 合并 / 文档化 / 补校验 / 移除误导参数 / 存相对路径 / 校验移 commit 前 |

### 4.2 Flutter 客户端 ✅ 已实施（2026-09-15，待提交；C1-C12 全部：指纹降级对齐/指纹加 type（一次性 miss 影响面见报告）/C3 引擎缓存方案（provideFlutterEngine+FlutterEngineCache+四路挂 applicationContext，~105 行，真机冒烟清单见实施报告）/强制抓取丢弃+非账单冷却/截图兜底收口/通知指纹口径统一（含 postTime）/三队列 companion 静态锁/待确认 30d TTL+批量查询/缓存写入裁剪/BOOT_COMPLETED 改 AlarmManager/空序列化跳过+告警/booked 存在性校验。待 Flutter 环境执行 flutter analyze+test 与 gradlew 单测）

| # | 问题 | 位置 | 修法 |
|---|------|------|------|
| C1 | screenText 路内容指纹命中**直接硬丢弃**，与 sms/notify 路 2026-09-10 已改的「降级交语义判重」不一致——详情页文本不含时刻时，**同店同款第二笔真实消费被静默吞掉**（且与 Kotlin 永久 processed 集叠加，误吞面更顽固） | `auto_billing_service.dart:1486-1489`（对照 `:843-852, 1305-1309` 已降级）；`screen_text_monitor_service.dart:229-233` 注释自认「双保险」 | 对齐降级策略：指纹命中只降级交语义判重；或指纹加入页面内时间证据 |
| C2 | `billFingerprint` 用 `amount.abs()` 且不含收支方向——**同渠道同金额的支付与其退款指纹相同**，退款被 `already_processed` 静默跳过（与已知「微信退款漏记」症状重叠但机制不同） | `auto_billing_service.dart:1715-1732`（abs()）、`:1551-1561`（skip）、`ai_bookkeeper.dart:649-660` | 指纹加入 `type` 字段 |
| C3 | 桥接广播挂在 MainActivity 生命周期（`onDestroy` 注销三桥）——进程被系统保活但 UI 划走后**四路自动记账全部停摆**（只入 Kotlin 队列，等下次开 App 才 drain） | `MainActivity.kt:960-966`、`SmsReceiver.kt:86-92` | WorkManager 周期 drain 或前台服务持有 engine |
| C4 | 无障碍「强制抓取」节拍：高频内容变化页面（抖音在白名单）每 ~2.4s 一次全树 IPC 遍历（≤400 节点×多窗口，主线程），结果全被内容闸丢弃——纯耗电 | `ScreenTextWatcher.kt:116-132`（MAX_GRAB_RETRIES=2 强制抓取）、`:699-705` | 重试用尽且事件仍高频到达时丢弃本轮；对已判非账单的 (pkg, pageClass) 短期冷却 |
| C5 | ScreenshotObserver：每次媒体变更（**含拍照**）都跑主线程目录全扫，且 MediaStore 查询已成功时仍跑 | `ScreenshotObserver.kt:281-305, 417-444` | 本周期已 enqueue ≥1 张跳过兜底；兜底仅 MediaStore 恒 0 行时执行并挪后台线程 |
| C6 | 通知指纹两侧口径不一致（native 含 postTime/id，Dart 侧 pkg|title|body 且注释声称同口径）——同通知被更新二次入队，靠下游兜底 | `NotificationWatcher.kt:171-190` vs `auto_billing_service.dart:1004-1011` | 统一口径（建议含 postTime） |
| C7 | 用临时实例调 `@Synchronized` 实例方法——锁对象互不相同，互斥形同虚设；当前只因全在主线程才无竞态，任一侧挪后台即 SharedPreferences 丢更新（丢新短信/复活已 ACK 项）。〔v1.1 核实〕**三套队列全中**：`SmsReceiver()`/`NotificationWatcher()`/`ScreenTextWatcher()` 的 peek/ack 均为临时实例调用（`MainActivity.kt:234/241/245/285/290/374/381`）；仅 `ScreenshotObserver` 用 companion object（`ScreenshotObserver.kt:73-74`）幸免 | `MainActivity.kt:234/241/285/374`；`SmsReceiver.kt:215/237/273`、`ScreenTextWatcher.kt:558/579` | 三个类一并改 companion object 静态方法/静态锁 |
| C8 | 待确认队列无 TTL（SharedPreferences 候选与 event store pending 均无过期）+ `loadForReview` 500 事件×逐事件查询（角标计数也走这条路） | `pending_candidate.dart:217-298, 305-364` | 按 capturedAt（如 30 天）过期转 expired；计数路径瘦身 |
| C9 | 指纹缓存只在加载时裁剪（写入不裁），长会话内存无上限（billFingerprints 写入时裁剪，不一致） | `auto_billing_service.dart:371-374, 1672-1675, 1734-1737` | 写入时统一裁剪到上限 |
| C10 | BOOT_COMPLETED 里 `startActivity` 在 Android 10+ 受后台启动限制——记账提醒「重启后重调度」在非 vivo 豁免场景大概率静默失效 | `NotificationReceiver.kt:39-52` | 改 WorkManager |
| C11 | push 对「实体已被本地删除」的 upsert change 发空 payload `{}`（依赖随后的 delete change 兜底；若 delete 因 orphan ledger 漏推，空 upsert 成为毒数据） | `sync_engine_serialization.dart:38-39` | 序列化为 null 时跳过该行并告警 |
| C12 | `approvePending` booked 快路径不校验交易仍存在（同步 pull 删除不回写事件状态，可能返回悬空 transactionId） | `ai_bookkeeper.dart:271-285` | 加一次存在性检查 |

### 4.3 Web 前端 ✅ 已实施（2026-09-15，待提交；W1 补 9 key 三语+DEV warn Proxy+check-i18n 脚本（1286 引用 0 缺失）/W2 脏检查二次确认（dirtyCloseGuard）/W3 字典统一 user-global（OverviewPage 判定为有意例外并注释）/W4 共享常量+版本通配清理/W5 blobUrl 竞态守卫/W6 observer 单建 ref/W7 WS 首条消息鉴权（web 双端+pytest 6 例；Flutter 保留 query 兼容路径）/W8 死代码删除+挂载请求合一（3 轮→1 轮）+AiLogs 订阅刷新+虚拟化观察项不做/附录 B5 SyncStatusBadge 断线提示）

| # | 问题 | 位置 | 修法 |
|---|------|------|------|
| W1 | i18n 缺失 key 另有 3 处（与已知 GlobalEditDialogs toast 同根因）：`shell.ledgerSwitched`（`t()||fallback` 兜底是死代码——缺 key 时 t 返回 key 本身非空）、`notice.info`、`trash.purgeConfirm.ok` | `LedgersSection.tsx:61`、`CategoriesPage.tsx:245`、`TrashPage.tsx:227`；`LocaleProvider.tsx:57-59` | 补 3 个 key；`t()` 加开发期缺 key console.warn；i18n CI 校验扩为全量 key diff；清理 `t(key)||fallback` 无效模式 |
| W2 | 编辑表单无脏检查：ESC/遮罩关闭静默丢弃全部输入（交易长表单误触即丢） | `TransactionsPanel.tsx:1010-1017, 1032-1042`、`GlobalEditDialogs.tsx:447-450` | Dialog close 拦截加 dirty 比对（打开时快照 vs 当前值），dirty 弹二次确认 |
| W3 | 字典拉取口径自相矛盾：全局弹窗按 ledgerId 过滤 user-global 字典（漏掉该账本没用过的账户/分类），交易页不带（注释明确「不要按 ledger 过滤」），同文件 GlobalEntityDialogs 的 tags 又不带——三处三个口径。〔v1.1 核实〕还有**第四处**：`OverviewPage.tsx:119-120, 135-138` 也带 ledgerId（注释称「当前账本活跃账户/标签」，或系有意口径，统一时需一并决策） | `GlobalEditDialogs.tsx:114-118` vs `TransactionsPage.tsx:742-746, 783-785`（服务端 `workspace.py:588-593` 证实）；`GlobalEntityDialogs.tsx:93/134/210`；`OverviewPage.tsx:119-138` | 统一为不带 ledgerId 的 user-global 拉取（OverviewPage 若确需「活跃」口径，显式注明为例外） |
| W4 | 筛选存储 key 已升 v2，登出清理仍只清 v1 前缀 → v2 键永久残留（隐私残留+膨胀） | `TransactionsPage.tsx:150` vs `App.tsx:130-144` | 清理前缀改 `smartbook:web:txFilter:` 通配，或提取共享常量 |
| W5 | AiLogsPage 详情图片 blob URL 竞态泄漏（effect 重跑早于 resolve 时 objectURL 无人 revoke + stale setState） | `AiLogsPage.tsx:74-89` | `let cancelled=false` 守卫，resolve 后判 cancelled 再 createObjectURL |
| W6 | TransactionList 无限滚动 observer 因 inline `onLoadMore` 每次 render 重建，弹窗打开瞬间可能双发 page-0 | `TransactionList.tsx:108-124`；调用方 `GlobalEntityDialogs.tsx:333/351/366`、`AccountDetailDialog.tsx:92-94` | 内部 ref 持有 onLoadMore，observer 只建一次 |
| W7 | WS 鉴权 token 走 URL query（进反代/服务端访问日志）——与自身 CSV 导出「token 不进 access log」的安全口径不一致 | `SyncSocketContext.tsx:76-80`（对照 `read.ts:417-421`）；服务端 `ws.py:16` 只接 Query | 迁 `Sec-WebSocket-Protocol` 或首条消息鉴权（需服务端配合） |
| W8 | 杂项：`fetchReadSummary` 死代码且 `Promise<any>`（api-client 唯一对外 any 泄漏）；挂载时同一数据重复请求 2-3 轮（三 effect 全 fire + AppShell 重复 loadLedgers）；详情弹窗无限滚动千行 DOM 无虚拟化（有截断提示，数据量增长时上虚拟滚动）；AiLogsPage 未订阅 useSyncRefresh（其它页都订，AI 日志页完全不随 sync 事件刷新，需确认是否有意——〔v1.1 核实补充〕） | `read.ts:122-124`、`TransactionsPage.tsx:887-903, 1026-1069, 1080-1097`、`TransactionList.tsx:143-167` | 删死代码；挂载路径合一（留 effect 1026）、字典拉取二选一复用；虚拟化观察后决定 |

### 4.4 部署 / 迁移杂项 ✅ 已实施（2026-09-15，待提交；D1 PG 分支 CREATE INDEX CONCURRENTLY（真实 PG 容器实测 upgrade/downgrade/indisvalid）、D2 JWT 校验重组为可达（dev warn/非 dev raise）、D3 迁移撞号重命名 0019_ai→0020…0030→0031（revision id 未动，head 唯一）+文案、D4 build.sh 四小修+trap 还原 pubspec+版本号成功后落盘、D5 pnpm frozen 失败即报错、D6 compact_sync_changes_postgres.sql（真实 psql 三路实测）。〔Wave2 新发现待跟进〕PG 全链从零升级在早期迁移报 DatatypeMismatch（新 PG 部署路径断点）、SQLite batch downgrade 丢表达式索引——交 Wave 3 服务端批次评估）

| # | 问题 | 位置 | 修法 |
|---|------|------|------|
| D1 | PG 上 0029/0030 建索引未用 CONCURRENTLY（锁表写）；CMD 内联迁移 + healthcheck（start-period 10s×retries 3，配 30s interval 约 100s 即标 unhealthy）叠加。〔v1.1 核实修正〕「unhealthy → restart → 迁移中断重跑」在纯 docker compose 下**不自动成立**：HEALTHCHECK 只标记状态，`restart: unless-stopped` 仅在主进程退出时生效，迁移期间 alembic 进程不退出；真实风险是 unhealthy 状态误导运维手动干预、以及 autoheal/监控栈等外部重启机制介入 | `0029:26-38`、`0030:30-34`、`Dockerfile:113, 118` | 纯索引迁移加 PG 分支 `CREATE INDEX CONCURRENTLY`（alembic autocommit block）；或升级文档约定停机窗口 + healthcheck 放宽 start-period |
| D2 | main.py JWT 强校验是死代码：`ensure_jwt_secret()`（bootstrap 自动生成强密钥注入 env）在 `if is_default/weak: raise` **之前**执行，raise 不可达；整套校验又被 `app_env != "development"` 门控而默认 development | `main.py:10-11, 57-61`、`bootstrap.py:38-98`、`config.py:18` | 二选一：删死代码避免误导（开箱即用哲学）；或「校验优先于兜底」且 development 下也 warn |
| D3 | 两个 `0019_*` 迁移文件前缀撞号（链线性不影响执行，命名卫生）；`build_docker.sh:193` 提示文案仍说 head 是 0019 | `0019_account_hidden.py` / `0019_ai_analysis_logs.py` | 重命名 `0019_ai_analysis_logs.py` → `0020_*` 并顺延（revision id 不变，仅文件名）；修文案 |
| D4 | build.sh：实际读 `JAVA_HOME_OVERRIDE` 但文档/帮助都说 `JAVA_HOME`；`sed -i` 脏化受跟踪的 pubspec.yaml 失败不还原；AAB 失败仅 warn 仍打印「构建完成」；版本号构建前落盘（失败也烧掉版本） | `build.sh:21, 116-117, 127, 180, 226`；`build_docker.sh:95` | 变量名对齐文档；构建后还原 pubspec；AAB 失败如实报错；版本号构建成功后落盘 |
| D5 | Dockerfile `pnpm install --frozen-lockfile || pnpm install --no-frozen-lockfile` 静默降级——构建不可复现不报警 | `Dockerfile:16` | 失败即报错（lock 应提交一致），或至少 echo WARN |
| D6 | `compact_sync_changes.sh` 只支持 SQLite（canonical PG 无等价 backfill）；`main.py:384` 自述「>=500k 行考虑 retention」仍是纸面阈值 | `server/scripts/compact_sync_changes.sh:65` 起 | 提供 PG 版 backfill（SQL 脚本即可）；与 P1-A3 的水位归档合并考虑 |

---

## 5. 执行与验证策略

### 5.1 顺序

```
P0-1+2（同步谓词+锁） → P0-3（客户端错误分类） → P0-4（备份+副本）
→ P0-5（软删×LWW，先落契约文档） → P0-6+7（Web 竞态+刷新）
→ P1-A/B/C/D/E（按主题）
→ P2 四批（穿插，附录 B 的 9 条旧账并入同批）
```

### 5.2 每波验证

- **服务端**：`python -m pytest tests/`（P0-1/5、P1 各配回归测试，命名沿用 `test_push_apply_failure_no_orphan_event.py` 风格）+ `ruff check`
- **客户端**：`flutter analyze` + 对应单测（P0-3/C1/C2 重点）
- **Web**：现有测试 + W1 的 i18n 全量 key CI 校验；P0-6 手动弱网切换场景
- **P0-5 风险最高**：改变 delete/upsert 最终裁决，上线前跑三端模拟（A 删 / B 离线编辑 / C 观察）一致性测试

### 5.3 commit 约定

沿用现有格式 `[服务端] / [客户端] / [Web 前端] / [文档]` + 变更描述；每个 commit 关联本文档编号（如 `P0-3`），便于回归定位。提交前与用户确认。

---

## 附录 A：审查覆盖面与确认无问题的点（避免重复排查）

- **客户端多路同笔交易竞态防御**：`AiBookkeeper._persistAll` 静态串行链 + `SemanticDedupMatcher` 金额全等/±1min 硬闸门 + 秒级指纹 + cross_channel_strong，经逐环验证无洞；pull 侧 cursor 整页提交才推进、按 result 分流 markPushed 正确。
- **服务端 ledger 隔离**：write/read 全路由经 `_prepare_write`/`_require_ledger` 走 LedgerMember；evidence/rates/ai logs/import_data 均 user_id 过滤；未发现 IDOR（附件下载一处除外，见 S1）。
- **幂等架构**：`(user_id, device_id, key)` 唯一约束 + request_hash 409 + IntegrityError 兜底 replay 整体健全（仅 S7 过期语义瑕疵）。
- **provider 掩码**：`mask_api_key`/`merge_ai_config_on_patch` 闭环，无明文泄漏路径。
- **迁移链**：0001→0030 连续、head 唯一、启动自动 `alembic upgrade head` 策略明确（单副本前提）。
- **push savepoint**：e655fe3 修复（add+flush 在 savepoint 内、失败不留孤儿事件）确认到位，未再发现同类问题。
- **web 快路径 cascade 的软删过滤**：e655fe3 修复覆盖 `_cascade_tx_rows_for_*`、`tags.py:39-54`、`categories.py:51-59`；`rename_cascade_*/detach_cascade_*` 的 UPDATE 不过滤软删行但只改 denorm 列不发事件，语义无害。
- 〔v1.1〕本附录各条已于 2026-09-15 第二轮核实中复核抽验通过。

## 附录 B：前次 review 75 分档 9 条 ✅ 已全部处置（2026-09-15，待提交；1✅ C2 波一并、2〔调研结论〕当前代码不可复现——mobile 统计对 override 行有 category_id IS NULL 守卫、服务端无 union，无活跃缺陷、3✅ 服务端 AuditLog 1h 节流（P1 波）+客户端 8 次熔断（P2 波）、4〔调研结论〕现行链路恢复已带标签/附件（0030 软删+upsert payload 重放），补回归测试锁定、5✅ SyncStatusBadge、6✅ 两侧词表补「退款成功/已退款」（AI 提取层方向判定未动，属 client/lib/ai 禁区）、7✅ 词表对齐 553f945、8✅ P1-D1 env_file、9✅ W1 一并补 key）

1. 客户端 markPushed 依赖服务端截断 20 条的 samples（批量冲突时第 21 条起静默丢失）——与 P1-C2 相关，可同批
2. 共享账本 override 交易在分类统计中双计
3. 被拒 change 永久重推循环（客户端）——服务端配套放大面：每条冲突一条 AuditLog 无节流（`push.py:248-261`）
4. 回收站恢复交易丢标签/附件
5. 同步错误 UI 永不显示〔v1.1 核实修正表述：`lastSyncErrorProvider` 符号在当前代码与 git 全历史均不存在；实际事实是 `useSyncSocket.ts:41` 返回的 `status`/`onDisconnect` 从未被 `SyncSocketContext.tsx:132-149` 消费——Web 端没有任何「同步断开/出错」UI 出口。修复按「暴露 status 到 context + 断线提示」实施〕
6. 微信退款详情页系统性漏记（识别层）——与 P2-C2（指纹机制层）症状重叠，建议合并排查
7. ScreenTextWatcher 词表未同步 553f945 修复
8. `.env` 的 EMBEDDING_*/REGISTRATION_ENABLED 因 compose 无 `env_file` 静默不生效——P1-D1 一并闭环
9. GlobalEditDialogs 成功 toast 显示 raw i18n key——与 P2-W1 同根因，一并修（〔v1.1 核实〕缺的是 `notice.transactionUpdated/transactionCreated` 两个 key；`notice.categoryUpdated/categoryCreated` 存在、分类 toast 正常，仅交易保存受影响）
