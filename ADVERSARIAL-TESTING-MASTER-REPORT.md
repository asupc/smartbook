# SmartBook 全功能对抗性测试 —— 总报告

> 日期：2026-10-11　|　执行方式：lead 主控 + 12 个分域攻击组并行
> 范围：**五个交付面全覆盖** —— Flutter 客户端、Android 原生层（Kotlin）、vendor 包（flutter_cloud_sync）、FastAPI 服务端、Web 前端（React）
> 纪律：**只新增测试，零修改产品代码**；所有红色测试均为确证缺陷，保留为可复现证据。

---

## 一、总结论

| 面 | 新增测试文件 | 用例数 | 绿 | **红（确证缺陷）** |
|---|---|---|---|---|
| Flutter 客户端（Dart 业务/widget 层） | 23 | **834** | 704 | **130** |
| Android 原生层（Kotlin JVM + 仪器） | 3 | 69 | 67 | 2 |
| flutter_cloud_sync 包 | 4 | 154 | 115 | **39** |
| FastAPI 服务端 | 19 | **499** | 400 | **99** |
| Web 前端（React） | 3 | 71 | 63 | 8 |
| **合计** | **52** | **1,627** | **1,349** | **278** |

**全量套件实测（客户端）**：`flutter test` = **1736 通过 / 1 跳过 / 133 失败**。
基线为 1034 通过 / 1 跳过 / 3 失败 → 对抗测试**净增 702 通过 + 130 红**，且 3 条既有失败原样复现
（已逐条核对，无新增污染）。

**全量套件实测（服务端）**：`pytest tests/ --ignore=tests/adversarial` = **623 全绿**（基线未破坏）；
`pytest tests/adversarial/` = **499 用例 / 400 绿 / 99 红**（19 文件，`--collect-only` 核对）。

> 用例数均经**实测计数**（客户端逐个文件 `--reporter json` 汇总；服务端 `--collect-only`；
> Web/Kotlin/vendor 包按其运行器汇总）。红测中含少量同根因的不同表现
> （如服务端非有限浮点污染族、客户端 Infinity 穿透链），各域报告已按「发现」条目归并
> （独立缺陷数合计约 120 条）。

**基线未被破坏**：客户端既有 3 条失败（全部为测试腐烂，见 §三）、服务端既有 623 条全绿、Web 既有 100 条全绿 —— 均在对抗测试加入后复验一致。

---

## 一·补记（2026-10-11 21:30 复核）

**状态更新**：本报告完稿后，仓库内出现了**按 [ADVERSARIAL-FIX-PLAN-2026-10-11.md](ADVERSARIAL-FIX-PLAN-2026-10-11.md) 实施的修复工作**（另一个会话执行，15:00 之后落地）：

- **服务端**：`src/config.py`、`ledger_access.py`、`routers/{admin,admin_backup,auth,ws}.py`、
  `services/ai/provider_client.py`、新增 `services/ai/outbound_policy.py`、`services/backup/{rclone_config,restore_runner,tar_builder}.py` 等
  12 文件 `+901/−78`；其中 **S1 批次的安全项已生效**——`test_auth_adversarial.py` 的 5 条原红测试
  （超长密码 500、并发注册 IntegrityError、超长邮箱/设备字段、禁用用户 WS 等）**现已全绿**（21/21）。
- **客户端**：`lib/ai/core/{bill_info,json_response_parser,prompt_builder}.dart`、
  `lib/cloud/sync/sync_engine*.dart`、`lib/services/automation/*`、新增 `lib/services/import/amount_text.dart` 等，
  与 C1/C2/C4 批次方向一致。实测 `lead_prompt_builder_adversarial_test.dart` **14/14 全绿**
  （prompt 二次替换缺陷已修）、`parsers_amount_date` 由 20 红降至 4 红、`ai_json_response` 由 14 红降至 3 红。

**因此本报告 §一 表中的红测数字为完稿时快照（278），当前实际已下降**。复核时测得：
服务端对抗套件 **91 红**（完稿时 99；`auth` 组 5 条已修复，另有个别条目因测试文件被同步更新而变动）。

**复核中发现的测试基建问题（非产品缺陷）**：
- `test_mcp_adversarial.py` 的 4 条红在**自身文件内**即存在（隔离跑 4 红），
  其中 2 条（`test_scope_violation_is_audit_logged`、`test_mcp_get_with_pat_never_returns`）
  是 MCP 域真实缺陷（scope 越权不落审计、带 PAT 的 GET 无限挂起），
  与计划批次 S4 对应。
- `test_idor_adversarial.py` 隔离跑 **0 红**（原报告记 4 红 —— 修复方已修复或测试被同步更新）。
- 存在**偶发**：`test_revoked_invite_cannot_be_used` 在 `test_idor`+`test_auth` 后同跑时
  6 次中出现 1 次失败，隔离跑稳定通过；判为执行顺序敏感的测试基建问题，建议后续用逐条红测名验收。
- 修复实施方已同步更新部分对抗测试文件（如 `test_auth_adversarial.py` 20:44 被改写），
  因此「红测数」不再是纯增量指标；后续应以**逐条红测名**而非计数做验收。

---

## 二、分域报告索引

| 报告 | 覆盖 | 红 |
|---|---|---|
| [FINDINGS-parsers.md](client/test/adversarial/FINDINGS-parsers.md) | 金额/日期/CSV/AI-JSON/指纹解析 | 50 |
| [FINDINGS-autobook-core.md](client/test/adversarial/FINDINGS-autobook-core.md) | 事件状态机/claim 租约/判重/簇合并/TTL/重试 | 14 |
| [FINDINGS-data-layer.md](client/test/adversarial/FINDINGS-data-layer.md) | 交易仓库/聚合/迁移/账户/类目/并发 | 40 |
| [FINDINGS-sync-engine.md](client/test/adversarial/FINDINGS-sync-engine.md) | push 合并分批/熔断/pull-apply/游标/序列化 | 12 |
| [FINDINGS-widget-ui.md](client/test/adversarial/FINDINGS-widget-ui.md) | 金额编辑器/待确认页渲染与布局 | 4 |
| [FINDINGS-misc-services.md](client/test/adversarial/FINDINGS-misc-services.md) | 备份/YAML 导出导入（**部分完成**，其余子域未产出） | 8 |
| [FINDINGS-kotlin-native.md](client/android/adversarial-findings/FINDINGS-kotlin-native.md) | 原生队列/目标快照/截图门禁（含 18 条仪器测试） | 2 |
| [FINDINGS-cloud-sync-package.md](client/packages/flutter_cloud_sync/test/adversarial/FINDINGS-cloud-sync-package.md) | 认证/存储/实时/序列化/重试/路径 | 39 |
| [FINDINGS-auth-security.md](server/tests/adversarial/FINDINGS-auth-security.md) | 认证/PAT 作用域/IDOR/注入/WS/MCP | 20 |
| [FINDINGS-sync-consistency.md](server/tests/adversarial/FINDINGS-sync-consistency.md) | LWW/幂等/rename cascade/投影/级联/数值 | 26 |
| [FINDINGS-business-api.md](server/tests/adversarial/FINDINGS-business-api.md) | 交易写路径/账本/预算/统计/成员/导入导出/管理员 | 22 |
| [FINDINGS-ai-attachment-backup.md](server/tests/adversarial/FINDINGS-ai-attachment-backup.md) | AI 中转/附件/备份/rclone/证据/MCP | 31 |
| [FINDINGS-web-frontend.md](server/frontend/apps/web/src/adversarial/FINDINGS-web-frontend.md) | 权限/路由/错误本地化/i18n 契约 | 8 |
| 本文件 §四（主控亲自发现） | 跨端契约/提示词/协调器/历史查询 | 4 |

> 说明:「杂项服务域」（周期记账/汇率/隐私证据/存储损坏/匹配器）的独立攻击组两次遭遇
> API 限频中止，其覆盖部分由数据层组（迁移/并发/聚合）、解析器组（金额/日期/编码）
> 与既有测试承担；该域未产出独立报告，属**本轮未完成项**（见 §八）。

---

## 三、基线 3 条失败的定性（全部为**测试腐烂**，非产品缺陷）

1. `test/cloud/sync/sync_engine_push_merge_test.dart` 「第二批失败」—— fake 注入器条件 `changes.length > 200` 永不成立（`pushBatchSize = 200` 是 `sublist` 上限），`expectLater(throwsA)` 必然失败。产品分批/续推逻辑正确（`sync_engine.dart:1180-1260`）。
2. 同文件「附录 B3」—— 测试在 accept 那次 push 之后才 `pushedBatches.clear()`，清掉了本次批次记录，计数断言差 1。
3. `test/services/raw_evidence_store_test.dart` 「local-only policy」—— 固定日期 `DateTime.utc(2026,9,5)` + 7 天保留 = 2026-09-12，早于当前日期（2026-10-11），`shouldWrite` 正确判过期。**固定日期撞 TTL 的腐烂**（本仓库近期已改造过 3 处同型，此处漏网）。

---

## 四、主控亲自发现（跨端 / 高层视角）

### N-1【high】提示词模板二次展开 —— 用户文本可篡改 LLM prompt 结构
`client/lib/ai/core/prompt_builder.dart:263-271` 的 `replaceAll` 链把用户内容（`{{OCR_TEXT}}`）先注入，之后继续替换 `{{CATEGORIES}}`/`{{ACCOUNTS}}`/`{{CURRENCIES}}`。用户文本里出现这些字面量（备注/商户名/聊天内容）即被替换成系统清单 —— 系统指令与用户数据边界消失，是**提示词注入面**，也让账单原文被静默改写。
证据：`test/adversarial/lead_prompt_builder_adversarial_test.dart`（红）。
修复：用户内容最后注入，或单遍扫描替换。

### N-2【medium】自动记账历史先 limit 后过滤 —— 筛选结果被静默截断
`client/lib/services/automation/auto_book_event_store.dart:312-325` 先按 `updatedAt desc` 取前 200 条、再在内存里按 state/source 过滤。库内最新 200 条不含匹配项时筛选显示空列表 —— 用户以为记录丢了。
证据：`test/adversarial/lead_list_history_and_tracker_adversarial_test.dart`（2 条红）。
修复：把 state/source 条件下推到 SQL。

### N-3【medium】跨端序列化键静默丢失：`account.sortOrder` / `tag.sortOrder`
客户端无条件发送（`entity_serializer.dart:87` / `:153`），但云端 projection 无对应列（`server/src/models.py:871` / `:992`），merge spec 也不含该键 → 用户在 mobile 调整的账户/标签排序偏好不跨设备、不跨端，且无任何报错。
证据：`server/tests/adversarial/test_cross_platform_contract_adversarial.py`（含两条钉子测试 + 带理由的豁免表）。
修复：服务端补列，或客户端停发（明确取舍）。

### N-4【low】Kotlin `lossSummary` 字符串插值拼 JSON
`NativeAutoBookQueue.kt:219-220` 用插值拼 JSON，`source`/`kind` 含引号或换行即产出非法 JSON → 消费方 `JSONArray(raw)` 抛异常被吞，损失摘要静默停止累积（违反「不静默丢」承诺）。现不可达（全为内部常量），但函数 public。
证据：`AdversarialQueueLogicTest.kt`（2 条红）。

---

## 五、高危发现精选（按面）

### 服务端（最严重）
- **P0 附件路径穿越**：`ledger.external_id` 无字符集校验 → 附件落盘路径可 6 层 `..` 逃出根目录，实测写出成功（`attachments.py:140`）。
- **P0 SSRF**：relay/`/providers/test` 的 base_url 无 host 策略，实测真打环回并外带 apiKey，`169.254.169.254` 未拦（`provider_client.py:838`）。
- **P0 深嵌套自锁**：`appearance` 无深度限制 → 99 层 JSON 落库后 `GET /profile/me` 永久 500，web 登录后首个请求即崩，用户无法自救。
- **P0 跨用户同名 external_id → 成员端点全 500**：`ledger_access.py:43-64` 用 `.one_or_none()`，而唯一约束是 `(user_id, external_id)`；A 邀 B 后 B 的 10 个端点全 500。
- **P0 幂等判定不比对 action/payload**：`sync/push.py:515-526` 同 `(updated_at, device_id)` 的不同 payload 被当重放丢弃却 `accepted += 1` → 幽灵交易（12 条相关红测）。
- **P0 回收站绕过**：单笔 PATCH 与批量移动可复活/移动软删交易（`write/_shared.py:710`、`transactions_batch_move.py:170`）。
- **数值污染族**：`1e309`→inf 落库使整账 `balance` 变 null；`NaN` 500；`PATCH amount:null` 静默清零；`happened_at:null` 改成服务器当前时间。
- **备份面**：rclone.conf 换行注入伪造 section；zip bomb 无解压上限（65KB → 67MB，1027x）；备份产物路径可穿越投放。

### 客户端
- **P0 双记账**：`claim` 读改写非原子（两个并发调用都 acquired）；跨 Coordinator 实例 `_keyTails` 失效（业务双执行）。
- **P0 非有限数值穿透链**：`NaN`/`Infinity` 绕过 `AutoBookPolicy` 金额闸门 → `semanticKey` 共享 key → `hasSecondExactDuplicate` 误判秒级指纹 → `formatBalanceFull` 抛 `RangeError` 使账本卡渲染崩。
- **P1 血缘丢失**：30 天前 `pending` 被物理删除（占位改造只覆盖有证据行）；`external_id` 快路径与写入侧公式漂移导致反查永久 miss。
- **P1 syncId 身份体系**：无 UNIQUE → 同 syncId 两行使 `getTransactionBySyncId` 抛 `Bad state`、`deleteTransactionBySyncId` 一行未删；批量删既不入回收站也不登记 delete change → 云端复活。
- **P1 日历月视图在 UTC+8 恒空**（`strftime(...,'localtime')` 返回 NULL + 缺 `unixepoch`）。
- **P1 迁移不幂等**：v15/v16/v21/v22/v27 裸 ALTER，半迁移库每次启动 duplicate column → **永久打不开**。
- **逻辑重复**：`rejected` 计数被客户端完全忽略 → 零样本拒绝路径被误标已推，**静默丢数据**，且同时逃过 B1 与 B3 两道保护。

### vendor 包（flutter_cloud_sync）
- **高**：signOut 后恢复凭证自动重登（登出失效）；pull 中字符串 change_id → TypeError 整页崩 → 同步卡死；缺字段 change 丢弃但游标照常推进（变更永久丢失）；本地落后版本绕过 LWW 覆盖云端数据。
- **中**：路径 `..` 不解析（WebDAV join 穿越面）；4xx 重试 3 次；异常文本带云端字段进 UI；dispose 后无限重连；`serverCursor` 字符串整帧丢。

### Kotlin 原生层（整体健壮）
- **18 条仪器测试全绿**：并发同键恰好 1 条入库、跨来源 ACK 不误删、容量闸+损失摘要、过期清理幂等、迁移去重与共存、坏行不阻塞整批 —— 队列核心实现**行为正确**。
- **2 条低危**：`lossSummary` JSON 注入面；`identityOf` 对全空通知项返回 `"|"` 绕过空身份拒收闸。

### Web 前端
- **medium**：`error.SHARE_ROLE_FORBIDDEN` / `error.SHARE_MEMBER_USER_NOT_FOUND` 三语字典全缺 → 共享账本权限被拒时 UI 显示裸 key。
- **medium**：`parseRoute` 遇残缺百分号编码抛 `URIError`（`/app/%` → 白屏，无 ErrorBoundary）。
- **low**：极小汇率 `1/raw` 溢出为 `Infinity`；权限判定无「未知角色默认拒绝」路径（安全靠服务端）。

---

## 六、覆盖矩阵（全部打过的功能面）

| 面 | 覆盖 |
|---|---|
| 自动记账四路 | 短信/通知/屏幕文本/截图的关键词门禁、指纹去重、事件键构造、目标快照冻结、原生队列全链路 |
| 判重与合并 | 秒级指纹、跨渠道强判重四条件、簇文案亲缘、豁免表、外部单号、软删过滤 |
| 事件状态机 | claim 租约边界、8 次退避阶梯、`retry_exhausted`、终态语义、TTL（pending 30 天/证据 30 天）、草稿重放 |
| 数据层 | 交易/账户/类目/标签/预算 CRUD、聚合口径一致性、exclude 标志矩阵、多币种、迁移链、孤儿清理 |
| 云同步 | 客户端 push 合并分批/熔断/pull-apply/游标/序列化；服务端 LWW/幂等/cascade/投影/级联；vendor 包认证/存储/WS |
| AI 链路 | prompt 构造与占位符、JSON 响应清洗、账单过滤 guard、中转/服务商配置/日志 |
| 服务端 API | 认证注册登录、PAT 与作用域、多用户隔离（IDOR 全实体矩阵）、共享账本与邀请、交易/账本/预算/统计/成员/导入导出/管理员、WebSocket、MCP |
| 安全边界 | 路径穿越、SSRF、原型污染、CSV 公式注入、NUL/lone surrogate、超长与深嵌套、限流绕过、备份注入、zip bomb |
| 前端 | 权限矩阵、路由解析、错误本地化、i18n 三语契约 |
| UI/交互 | 金额键盘边界、待确认页渲染、大字体/窄屏布局、50 条批量渲染 |

---

## 七、修复优先级建议

**P0（数据损坏 / 安全 / 不可自愈）**
1. 服务端：附件 `external_id` 字符集校验 + 落盘路径规范化（`attachments.py:140`）
2. 服务端：relay/providers 的 base_url host 白名单 + 私网阻断（`provider_client.py:838`）
3. 服务端：`appearance` 等自由 dict 加深度/大小上限；`/profile/me` 读取对畸形数据容错
4. 服务端：`ledger_access` 改 `.first()` 或补 `ledger_id` 维度；幂等判定加入 action + payload hash
5. 服务端：所有点查补 `deleted_at IS NULL`；写入口统一 `isFinite` 校验与 `null` 语义
6. 客户端：`claim` 改条件 UPDATE 原子化（一处修复同时关闭双记账两条路径）
7. 客户端：解析器与仓库层加 `isFinite` 守卫（一处守卫关闭 6 处入口）
8. 客户端：`sync_engine.dart:1213` 消费服务端 `rejected` 计数
9. 客户端：迁移加 `_addColumnIfMissing` 幂等（防启动永久崩溃）

**P1（静默丢数据 / 用户可见错误）**
10. `listHistory` 下推过滤；`external_id` 快路径公式对齐；30 天 pending 保留占位
11. syncId 全链路唯一性（先清历史重复行再加 UNIQUE）
12. 日历月视图 `strftime` 修正；分类统计双计；编辑丢字段
13. vendor 包：登出清凭证、游标严格校验、缺字段 change 不推进游标、LWW 版本比较
14. Web：补两条 i18n key；`parseRoute` 解码容错

**P2（加固与体验）**
15. 服务端 CSV 公式注入转义、`tz_offset_minutes` 范围校验、深分页参数校验
16. 客户端金额输入位数上限；待确认页窄屏/大字体布局（`Wrap`）
17. Kotlin `lossSummary` 改 `JSONObject` 构造；`identityOf` 空串短路
18. `account/tag.sortOrder` 跨端取舍明确化

---

## 八、未能验证（环境限制，如实记录）

- **PostgreSQL 专有行为**：advisory lock 真实语义、VARCHAR 越界、int8 边界 —— 测试环境为 SQLite（锁为空实现），相关契约仅静态审计。
- **真机行为**：vivo OriginOS 无障碍「一开就关」、smartshot 浮层包名、通知冷启动直达、故障注入（交接前被杀 / ACK 前崩溃 / 并发 drain）。
- **多进程/多 isolate 竞态**：单 isolate 内已证双执行必现；跨进程概率未测。
- **真实 HTTP/WS 端到端**：客户端全部基于 fake provider + 内存 SQLite。
- **UI 动作链**：待确认页确认/忽略链在 flutter_test 的 fake-async 下残留定时器（单跑每条可过）；金额编辑器运算模式的纯等号分支无法经 `tester.tap` 触发（`onTap`/`onDoubleTap` 共存）—— 两者均为测试基建限制，已改由源码评审与服务层测试覆盖。
- **渲染层组件测试**：Web 端 `jsdom`/testing-library 未在本包 devDeps，未做 DOM 级交互。
- **真实外部服务**：MCP JSON-RPC 往返、rclone/WebDAV/S3 真实连接、Excel 打开导出 CSV 的实际表现。
- **杂项服务域的 5 个计划文件未产出**（周期记账/汇率/隐私证据/存储损坏/匹配器）：独立攻击组两轮均遇 API 限频，
  预算耗尽于探测阶段。已有 1 个文件落盘（`misc_json_backup_adversarial_test.dart`，23 用例 / 15 绿 / 8 红，含
  **7 条真实缺陷**：YAML 转义缺失导致备份不可解析与键注入、坏日期中止整批导入、Infinity 使整份备份导出失败，
  另 1 条为该测试自身断言缺陷已定性）。探测阶段另有 6 条发现未固化为测试（配置换行静默折叠、导入幂等键
  externalId 大小写敏感、seedDatabase 非幂等、store 容量防线不收敛、AnomalyDetector 未接线、
  PostProcessor 顺序规则无冲突）—— 详见
  [FINDINGS-misc-services.md](client/test/adversarial/FINDINGS-misc-services.md)。

---

## 九、运行指南

```bash
# Flutter 客户端（业务/widget 层）
export PATH="$HOME/devtools/flutter-3.27.3-sdk/bin:$PATH"
cd client && flutter test test/adversarial/ --reporter compact
#   注:ui_pending_confirmation_adversarial_test.dart 需逐条单跑(见其文件头)

# Android 原生层
export JAVA_HOME="$HOME/devtools/jdk-17"; export ANDROID_HOME="$LOCALAPPDATA/Android/Sdk"
cd client/android
./gradlew :app:testDevDebugUnitTest --tests "com.smartbook.zhi.Adversarial*"
./gradlew :app:connectedDevDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.smartbook.zhi.AdversarialQueueDbTest

# vendor 包
cd client/packages/flutter_cloud_sync && flutter test test/adversarial/

# 服务端
cd server && python -m pytest tests/adversarial/ -q

# Web 前端
cd server/frontend/apps/web && pnpm vitest run src/adversarial/
```
