# 对抗性缺陷修复计划（2026-10-11）

> **输入**：[ADVERSARIAL-TESTING-MASTER-REPORT.md](ADVERSARIAL-TESTING-MASTER-REPORT.md) 与 13 份分域 `FINDINGS-*.md`
> （278 条红测 ≈ 120 条独立缺陷；52 个对抗测试文件、1,627 用例是现成的**验收器具**）。
> **本计划只排程与定义修法，不含实施**。执行前请确认发布/提交授权。

---

## 一、修复原则

1. **根因优先**：先修「一个改动关闭一族红测」的根因（如 `isFinite` 守卫族、点查软删过滤族、`(updated_at, device_id)` 幂等三元组），不做逐条打补丁。
2. **红测即验收**：每条修复以「哪些红测转绿」为完成判据；修完不许新增失败。
3. **先安全与数据，后语义与体验**：P0（越权/写穿/自锁/双记账/永久打不开）→ P1（静默丢数据/口径错误）→ P2（加固/体验）。
4. **跨端同修**：涉及 mobile ↔ server 契约的项（非有限浮点、排序字段、幂等语义）两端同批落地，避免单端加固被另一端绕过。
5. **迁移安全**：客户端 drift 迁移必须幂等 + 可半迁移恢复；服务端 alembic 每次带 `down_revision`；破坏性迁移（syncId 去重、加 UNIQUE）**先备份、再干跑、后执行**。
6. **红测转为回归护栏**：修复完成后对抗测试整组保留在仓库（建议接 CI），此后任何回归立即变红。

---

## 一·补记：实施进度（2026-10-11 21:30 实测）

本计划落盘后已有实施落地（另一会话执行），实测进度如下：

| 批次 | 状态 | 证据 |
|---|---|---|
| **S1 安全边界** | 🟡 **部分完成** | `test_auth_adversarial.py` **21/21 全绿**（超长密码 500、并发注册 IntegrityError、超长邮箱/设备字段、禁用用户 WS 等已修）；新增 `src/services/ai/outbound_policy.py`（SSRF 默认拒绝 + `AI_ALLOWED_PRIVATE_HOSTS` opt-in）；`ledger_access.py` 补跨用户同名 external_id 消歧（SQL ORDER BY + 审计节流）。**剩余**：`test_attachment_adversarial.py` 7 红、`test_ai_relay_adversarial.py` 15 红（路径穿越与 relay 出站策略的测试尚未转绿，可能未完测或策略未接入全部调用点） |
| **C1/C2/C4 客户端** | 🟡 **推进中** | `prompt_builder.dart` 二次替换已修（`lead_prompt_builder` 14/14 绿）；新增 `lib/services/import/amount_text.dart`（金额清洗归一）；`parsers_amount_date` 20红→**4红**、`ai_json_response` 14红→**3红** |
| **S2 服务端同步** | ⚪ 未开始 | `test_sync_*`/`test_lww_*`/`test_cascade_*` 红数未变 |
| **C3/C5/S3/S4/C6/C7/X2/X3** | ⚪ 未开始 | — |

**验收口径提醒**：因实施方会同步改写对抗测试文件（`test_auth_adversarial.py` 已被改写），
**红测计数不再是可靠指标**，请以「逐条红测名是否转绿」做批次验收，并在每批完成后
确认对应测试文件的断言未被削弱（对照各 `FINDINGS-*.md` 中的期望 vs 实际）。

**复核中发现的测试基建问题（需在批次 X 一并处理）**：
1. `test_mcp_adversarial.py` 4 红为自身真实缺陷（scope 越权不落审计、PAT GET 无限挂起）。
2. `test_idor_adversarial.py` 当前隔离跑 **0 红**（原记 4 红，已随修复转绿或被改写）。
3. **偶发**：`test_revoked_invite_cannot_be_used` 与其它文件同跑时约 1/6 失败、隔离跑稳定通过
   → 存在执行顺序敏感，建议给对抗测试加统一的模块级 fixture 隔离（还原
   `mcp_auth.SessionLocal` / `ws.SessionLocal` 等被模块级替换的全局）。

---

## 二、批次总览

| 批次 | 主题 | 面向 | 关闭红测（约） | 风险 | 依赖 |
|---|---|---|---|---|---|
| **X** | 测试基建修复（3 条基线腐烂 + 可测性） | 全端 | 3 | 低 | 无 |
| **S1** | 服务端·安全边界与 DoS | server | ~30 | 中（SSRF 默认策略影响本地 LLM 用法） | 无 |
| **C1** | 客户端·自动记账核心（原子性 + 非有限值守卫族） | client | ~35 | 中（claim 改条件更新） | 无 |
| **S2** | 服务端·同步与数据一致性 | server | ~45 | 高（幂等/LWW 语义、软删过滤面大） | 无 |
| **C2** | 客户端·解析与导入 | client | ~60 | 中（日期语义收紧改变导入行为） | 无 |
| **C4** | 客户端·同步引擎 | client | 12 | 中（游标/熔断状态） | S2（服务端行为对齐） |
| **C3** | 客户端·数据层（syncId/删除/统计/迁移） | client | 40 | **高**（UNIQUE 迁移需去重） | C4（同步侧先稳） |
| **C5** | vendor 包 flutter_cloud_sync | client | 39 | 中（登出/LWW 行为变更） | C4 |
| **S3** | 服务端·业务 API 语义 | server | ~22 | 中（PATCH null 语义变更影响老客户端） | S2 |
| **S4** | 服务端·AI 中转/附件/备份加固 | server | ~18 | 中（掩码/限额） | S1 |
| **C6** | Web 前端 | web | 8 | 低 | 无 |
| **C7** | 客户端 UI 布局与输入上限 | client | 4 | 低 | C1（金额守卫同源） |
| **X2** | 杂项域补测（周期记账/汇率/隐私/存储/匹配器） | client | —（新增覆盖） | 低 | C1–C3 |
| **X3** | Postgres CI 作业（补 advisory lock/列宽验证缺口） | server | —（基建） | 低 | S2 |

**顺序建议**：`X → S1 → C1 → S2 → C2 → C4 → C3 → C5 → S3 → S4 → C6 → C7 → X2 → X3`
（S1 与 C1 最高危且无依赖，先做；C3 的 syncId 迁移最危险，放在同步链路稳定之后。）

---

## 三、批次详情

### 批次 X · 测试基建修复（0.5 人日）

| 项 | 文件 | 修法 |
|---|---|---|
| 基线腐烂 1 | `client/test/cloud/sync/sync_engine_push_merge_test.dart`「第二批失败」 | 注入器条件改为「第 2 批即 `changes.length <= 200 && pushedBatches.length >= 2`」之类可达条件（现条件 `>200` 永不成立） |
| 基线腐烂 2 | 同文件「附录 B3」 | `pushedBatches.clear()` 挪到 accept 轮**之后**再清，计数对齐 |
| 基线腐烂 3 | `client/test/services/raw_evidence_store_test.dart`「local-only policy」 | `capturedAt` 改相对时间（`DateTime.now().subtract(...)`），与保留窗 7 天对齐 |
| 可测性 1 | `lib/widgets/biz/amount_editor_sheet.dart` 运算符键 | 把 `onDoubleTap` 注册拆到独立 widget（或补 `Semantics`/测试专用入口），使 `applyEquals` 可被 widget 测试驱动（当前 `tester.tap` 无法触发） |
| 可测性 2 | `lib/pages/automation/pending_confirmation_page.dart` | 页面常驻订阅改为可注入/可 dispose 干净（消除批量跑测试的 pending timer），使待确认页动作链可 widget 测 |

**验收**：`flutter test` = 0 既有失败；`ui_amount_editor` 与 `ui_pending_confirmation` 两文件可整文件运行。

---

### 批次 S1 · 服务端·安全边界与 DoS（1–1.5 人日）【P0】

| 发现 | 位置 | 修法 |
|---|---|---|
| 附件路径穿越（5 红） | `src/routers/attachments.py:140` | ① `schemas.py` 对 `ledger_id`/`external_id` 加字符集白名单（`^[A-Za-z0-9_-]{1,64}$`）——**三个入口同改**：`POST /write/ledgers`、`POST /sync/push` auto-create 账本、path 参数校验；② 纵深防御：落盘前 `Path.resolve()` 包含性检查，逃出根目录即 400 并审计日志 |
| 备份产物穿越（2 红） | `src/routers/admin.py:883,947` | 同上（产物路径走同一安全化 + 包含性检查） |
| SSRF（3 红） | `src/services/ai/provider_client.py:838,1014,1036`、`src/routers/ai/providers.py:465` | 出站 host 策略：默认拒绝环回/链路本地/私网/保留段（IPv4+IPv6+十进制变体）；新增 `AI_ALLOWED_PRIVATE_HOSTS`（逗号表，默认空）供自建 Ollama 用户显式放行；`/providers/test` 走同一策略；禁止跨 host 重定向 |
| profile 深嵌套自锁（1 红） | `src/routers/profile.py:131`、`schemas.py` | ① 写入侧：自由 dict 字段加深度（≤8）与序列化体积（≤64 KB）上限 → 422；② 读取侧：`GET /profile/me` 对畸形行容错（解析失败视为空 + 日志），并提供一次性修复脚本/管理端点把已损坏行归零 |
| 禁用用户仍可 WS（2 红） | `src/routers/ws.py:42-50` | `_user_exists` 增加 `is_enabled` 校验，与 REST 403 口径一致 |
| 注册/密码/邮箱边界（4 红） | `src/routers/auth.py:195`、passlib 调用点 | 捕获 `PasswordSizeError` → 422/401；`IntegrityError` flush 兜底 → 409；邮箱/设备字段长度上限（按列宽）→ 422 |
| 畸形字节与超长（5 红） | `schemas.py`、`read/workspace.py:322` | lone surrogate / NUL / 控制字符 → 422；`note` 长度上限（如 8 KB）；`offset`/`log_id` 限制 int64 且 ≤ 合理界 |
| zip bomb / rclone 注入（2 红） | `src/backup/tar_builder.py:119`、`admin_backup.py:100` | 解压：条目数/总展开字节/压缩比三重上限；rclone.conf 值白名单（禁换行与 ini 元字符） |
| HTML 伪装 / vision batch / providers 限额（3 红） | `attachments.py`、`relay.py`、`providers.py` | 图片魔数校验（不只信 MIME/后缀）；vision-batch 张数上限与逐张计费限流；provider 数量上限 |

**验收**：`python -m pytest tests/adversarial/test_attachment_adversarial.py tests/adversarial/test_backup_evidence_adversarial.py tests/adversarial/test_ai_relay_adversarial.py tests/adversarial/test_ai_providers_adversarial.py tests/adversarial/test_auth_adversarial.py tests/adversarial/test_injection_malformed_adversarial.py -q` → 上述红测全绿；既有 `pytest tests/` 623 不回归。

---

### 批次 C1 · 客户端·自动记账核心（1.5–2 人日）【P0】

| 发现 | 位置 | 修法 |
|---|---|---|
| A1 claim 非原子双授予 | `auto_book_event_store.dart:147-179` | 改成**单条条件 UPDATE**（`customUpdate`）：`SET state='processing', attempt_count=attempt_count+1, updated_at=:now WHERE id=:id AND state NOT IN (终态) AND (state<>'processing' OR updated_at <= :now - lease) AND (state<>'retry' OR next_retry_at IS NULL OR next_retry_at <= :now)`；`affectedRows==1` 才 `acquired`。SELECT 仅用于回读展示 |
| A2 跨实例双执行 | `auto_book_coordinator.dart:128-143` | `_keyTails` 改 **static**（进程级），或把串行守卫下沉到 store 的 claim（推荐后者+两者都做） |
| A3 pending 被物理删除 | `auto_book_event_store.dart:1075-1119` | `cleanupExpired` 内**先** `expireStalePending()`；DELETE 条件加 `state NOT IN ('pending')`（让 pending 只由 expire 转终态，保住历史占位） |
| A4 listHistory 截断 | `:306-326` | state/source 条件下推到 SQL `where`；`limit` 只作用于已过滤集合 |
| A5 duplicate 残留 | `:662-672` | `mark()` 的 `duplicateOfTransactionId` 改为**始终写入**（null 也写），消除 `Value.absent()` 残留 |
| A6–A8/A11/A12 Infinity 守卫族 | `json_response_parser.dart:123-125`、`auto_book_policy.dart:118-120`、`semantic_dedup_matcher.dart:68-72,196-220`、`bill_creation_service.dart` | **一处根因**：解析器入口 `if (!amt.isFinite) return null`（金额、nativeAmount、汇率同）；policy/`semanticKey`/`hasSecondExactDuplicate` 复检；`addTransaction` 落库前 `isFinite` 断言（同时关闭数据层 F-13、解析器 P-1、UI U-1 的提交侧） |
| A9 指纹口径 | `auto_billing_service.dart:1916-1935` | `note` 改用 `normalizeAutoBookText`（不只 trim）；`channel` 归一（trim+lower） |
| A10 external key 公式漂移 | `ai_bookkeeper.dart:790` vs `auto_book_event_store.dart:411` | 统一调用 `SemanticDedupMatcher.externalKey(id, currency)`；查询侧把 currency 一并传入 |
| A13/A14 store 并发丢更新 | `channel_account_store.dart:262-272`、`category_learning_store.dart:125-144` | read-modify-write 加 `_serial` 尾链（照抄 `PendingCandidateStore._tail`） |
| K-1/K-2 原生队列 | `NativeAutoBookQueue.kt:219-220,150-153` | `lossSummary` 改 `JSONObject` 构造；`identityOf` notification 分支对全空拼接短路返回 `""`（补 JVM 测试转绿） |

**验收**：`client/test/adversarial/{auto_book_*,dedup_,billing_stores_*,lead_coordinator,lead_list_history,ui_amount_editor}_adversarial_test.dart` 全绿；`client/android ... AdversarialQueueLogicTest` 2 红转绿；`flutter test` 全量不新增失败。

---

### 批次 S2 · 服务端·同步与数据一致性（2.5–3 人日）【P0】

| 发现 | 位置 | 修法 |
|---|---|---|
| F-01 幂等三元组（3+ 红） | `sync/push.py:515-526` | 重放判定改为 `(updated_at, device_id, action, payload_hash)` 四元组；`payload_hash` 对变更体做规范化 sha256（可即时算，**不加列**避免迁移）；不匹配 → 不走 replay 分支 |
| F-02 cascade 抢占 LWW 槽 | `push.py:50-103,600-613` | 同批内：客户端显式变更优先于服务端 cascade 派生；cascade 派生变更在「显式变更之后」应用 |
| F-03/F-06 clamp 坍缩与天花板漂移 | `push.py:422-424` | clamp 改为「保留原始 ts + 单独列/字段记录 clamp 事实」或按 `(device, 原始 ts)` 保序；同批同实体多编辑全部保留（事件流不坍缩） |
| F-04 非有限浮点（7 红） | `projection.py:54-60`、`sync/full.py:61`、`_as_float` | `_as_float` 非有限 → 拒绝（failed 计数）；投影写入前统一守卫；`/sync/full` 输出 `allow_nan=False`（防御） |
| F-05/F-07/F-08/F-09/F-10 投影与级联（6 红） | `sync_applier.py:751,814-843,456-476,303` | ① delete 用 `(entity_type, entity_sync_id)` 且投影主键对齐；② apply 时 denorm 名服务端重算（不信任 payload 陈旧名）；③ tag 删除后陈旧 push 拒绝或重建引用；④ 删分类有引用时与 web 路径同口径（400/拒绝）；⑤ push 到软删账本拒绝（补 `_is_ledger_deleted` 检查） |
| F-11/F-12/F-14/F-15/F-16（6 红） | `schemas.py:158-173`、`models.py` | payload 字段长度/类型/币种大小写归一；金额精度用 Decimal 语义校验；预算字段与 web 校验对齐；未知 entity_type 拒绝并计数 |
| F-13 锁覆盖（1 红 + 静态扫描） | `read/trash.py:282,365`、`data_cleanup/*`、`write/ledgers.py:308` | 所有改投影的写路径补 `lock_ledger_for_materialize` / `lock_user_global`；静态扫描测试纳入 CI 防新增遗漏 |
| 软删过滤族（C1/C2/E1/G5 等 ~8 红） | `write/_shared.py:710`、`transactions_batch_move.py:170`、`read/ledgers.py:150`、`admin.py:497`、`read/*` | 统一 helper（如 `active_only(clause)`），全量审计点查/统计/管理计数补 `deleted_at IS NULL`；批量移动/单笔 PATCH 命中软删行 → 404 |
| `ledger_access` 多行 500（2 红） | `ledger_access.py:43-64` | 同名 external_id（成员同时属于两个 `default`）→ 按「自己 owner 优先 → 创建时间」确定性取一条；同轮加审计日志 |

**验收**：`server/tests/adversarial/test_{sync_*,lww_*,cascade_*,shared_ledger_*,cross_platform_contract_*}.py` 全绿；服务端全量 `pytest tests/`（含 adversarial）除「已接受项」外 0 红。

---

### 批次 C2 · 客户端·解析与导入（2.5–3 人日）【P1】

| 发现 | 位置 | 修法 |
|---|---|---|
| 日期·格式抢序（3 红） | `date_parser.dart:88-103` | 格式表重排：先显式 ISO（严格 regex），再 `dd-MM-yyyy`/`MM/dd/yyyy` 判定（day>12 优先 dd-MM；否则按配置/区域，默认 dd-MM 并记 ambiguity）；**移除裸 `DateTime.parse` 兜底**（正是它把 `03-04-2026` 解析成 0008 年） |
| 日期·非法日历顺延（~9 红） | `date_parser.dart:41-79`、`bill_info.dart:399-419` | 解析后回写校验（`DateTime(y,m,d)` 与原值一致才接受），不一致 → null；`_parseTime` 时分秒范围校验（0-23/0-59/0-59） |
| 日期·tryParse 语义（12 红一批） | `date_parser.dart:37,120-126`、`import_confirm_page.dart:1069` | `parse(fallback: null)` 不再回落 `now()`（区分「无 fallback」与「fallback 为 null」：改签名用哨兵或 `parseOrNull`）；导入页改用它并保留 1970 sentinel；`validDate` 收紧（拒绝远离区间） |
| 金额·导入清洗（3 红） | `import_confirm_page.dart:1063` | 统一 `cleanAmountText`：全角符号/全角数字/汉字单位（元/块）归一（复用/抽取 `normalizeAutoBookText` 思路） |
| 金额·Unicode 负号（1 红） | `bill_parser.dart:33-38`、`generic_parser.dart:16-21` | 删除集加 `−`(U+2212)/`－`(U+FF0D)/`–`/`—` |
| CSV·引号内换行（3 红） | `csv_parser.dart:11-14` | 行切分改为**状态机**（跨行引号聚合）再 `_splitDelimitedLine`；CRLF 与 LF 统一 |
| CSV·分隔符检测（2 红） | `csv_parser.dart:57-95,23-27` | 候选分隔符按「列数一致性 + 表头列数>1」评分选择；非选中分隔符**不做** `replaceAll('\t','')` 全局删除 |
| 文件编码·GBK 误判（3 红） | `file_reader.dart:137-157` | `allowMalformed:false` 成功且仅含少量 U+FFFD 时**保留 UTF-8**（单点损坏不回退）；GBK 兜底仅在「UTF-8 解码失败」或「替换字符比例超阈值」时启用；UTF-16 BOM 检测前置 |
| AI JSON·类型容错（3 红） | `bill_info.dart:311-324` | 裸 `as String?`/`as int?` 全部换成 `_firstString`/`_asInt` 容错范式（`external_id` 已有） |
| AI JSON·BOM/数组退化（2 红） | `json_response_parser.dart:36-73,195-224` | `_extractBalancedBlock` 剥离 BOM/零宽字符后再匹配；数组路径失败时先逐对象重试再降级单对象 |
| prompt 二次替换（1 红） | `prompt_builder.dart:263-271` | 改**单遍**替换（一次正则扫描 + 查表回调），用户内容不再参与后续替换 |
| 指纹边界（3 红 low） | `auto_billing_service.dart:1077-1114` | 加长度前缀或转义后再 hash（`'${len}:$field'` 拼接）；native Kotlin 同口径同改 |
| 短文件表头（1 红） | `generic_parser.dart:39-71` | 一致性判据加自适应：文件行数 < 6 时阈值降为「≥2 行同列数」 |
| 空格千分位（1 红） | 空白分隔模式 | `1 234.56` 形态先做金额合并再列切分 |
| 退款关闭判定冲突（1 红） | `data_import_service.dart:592-621` | 判定顺序：`isRefundStatus` 优先于 `isNonBookableStatus`；`normalizeStatus` 与过滤口径对齐（加交叉单测） |
| 提醒时间范围（2 红） | `notification_util.dart:72-84` | `hour/minute` 范围校验，越界抛 `ArgumentError`（或钳制+告警，取其一并测） |

**验收**：`client/test/adversarial/{parsers_amount_date,ai_json_response,csv_encoding,notification_fingerprint}_adversarial_test.dart` 全绿（50 红转绿）；导入相关既有测试（`test/services/import/*`）不回归。

---

### 批次 C4 · 客户端·同步引擎（1.5–2 人日）【P1】

| 发现 | 位置 | 修法 |
|---|---|---|
| P-01 忽略 `rejected` | `sync_engine.dart:1213` | 汇报口径改 `rejected`（总拒收）参与 B1/B3 判定：`reportedRejections = max(conflict+failed, rejected)`；零样本拒收 → 整批不 markPushed（保守续推） |
| P-02 熔断不可逆 | `:1197,1249,1265` | 被拒计数在**熔断判断之前**累计；新 change id（用户编辑）能穿透熔断（重置判定前置）；或加超时衰减（如 30 min 后放行一次探测） |
| U-01..U-03 游标（3 红） | `sync_engine.dart:1424` | 游标推进条件：`new > current`（单调不减）；负数/非数/超界（>2^63）拒绝；`serverCursor` 仅在 apply 全部成功后 commit |
| U-04 Infinity payload（1 红） | serializer | 由 C1 的 isFinite 守卫同源关闭（push 前过滤 + 记录 skipped） |
| U-05/U-06 apply 卡死（2 红） | `sync_engine_resolvers.dart:65`、`sync_engine_apply.dart:471-475` | `getSingleOrNull` → `limit(1)`（与账户侧 `:80-89` 已修口径一致）；同名分类取历史最早一条并日志 |
| U-07 parentSyncId 忽略（1 红） | `sync_engine_apply.dart` `_applyCategoryChange` | 优先用 payload `parentSyncId`，缺失才回落 `parentName` |
| U-08 预算 apply 早退（1 红） | `sync_engine_apply.dart:36-38,698-703` | ledger 未就绪 → 返回 false（不推进游标），待下次重放；`account_adjustment` 同改 |
| hasMore 死循环 / ledgerId=-1（2 项） | `sync_engine_pull.dart` | hasMore 循环加迭代上限 + 空页短路；`ledgerId` 解析失败 → 中止该账本 pull（不用 -1） |

**验收**：`client/test/adversarial/sync_{push,pull_apply}*_adversarial_test.dart` 12 红转绿；既有 `test/cloud/sync/*` 不回归。

---

### 批次 C3 · 客户端·数据层（3–4 人日）【P1，高风险】

| 组 | 发现 | 修法 |
|---|---|---|
| syncId 身份族 | F-01..F-04（~9 红） | 新增 **v45 迁移**：① 扫描重复 syncId → 保留引用最多/最早一条为 keeper，把 tags/attachments 引用与 change 记录并到 keeper，删除副本（**执行前强制导出 JSON 备份**，迁移内 try/catch 失败保持原状并告警）；② 加 `UNIQUE(sync_id)`（含账本维度：`UNIQUE(ledger_id, sync_id)` 视语义定，跨账本同 id 是否合法需产品确认）；③ `getTransactionBySyncId`/`deleteTransactionBySyncId` 改 `limit(1)`；④ 批量插入遇同 syncId → upsert 或明确报错 |
| 删除/回收站 | F-05..F-10（~10 红） | ① 删交易级联清 `transaction_attachments` + 磁盘文件；② 单条删除与批量删除**统一**走 tombstone + changeTracker（同事务）；③ 墓碑 payload 补 tags/attachments 快照（恢复不丢）；④ `recordPulledFromServer` 加 `_serial`；⑤ 恢复流程包事务 |
| 字段语义 | F-11..F-15（~8 红） | `updateTransaction` 可选字段用哨兵（`Object? = _unset`）区分「未传」与「清空」；`addTransaction` 金额 `isFinite && != 0` 校验（负数按产品定：支出取 abs 或拒绝）；`searchTransactions(limit<0)` 钳制；`limit` 语义三套收敛为一种 |
| 日历/时区 | F-16（1 红） | SQL 改 `strftime('%Y-%m', happened_at, 'unixepoch', 'localtime')`（`DATE()` 同步补 `'unixepoch'`） |
| 统计口径 | F-17..F-23（~12 红） | 抽公共 `activeTxFilter(includeStats/Budget)` 供 9 个入口复用；`totalsByCategory` 排除 override 行；`getTagStats` 两分支同口径；旧净值入口改调用折算版；预算统计尊重 `period`；孤儿预算给扫描器补规则；`daysRemaining` 与 `month` 参数绑定 |
| 类目/标签/账户 | F-24..F-31（~16 红） | 类目树不变量：update 前环检测（沿 parent 链走到根）、`parentId`↔`level` 联动、`createSubCategory` 查重键含 parentId、删父类目递归（或存在子级时拒绝）、update 查重对称；`transaction_tags` 加 `UNIQUE(transaction_id, tag_id)`（迁移内先去重）；删账户/标签/账本级联 adjustments；孤儿扫描器补「交易悬挂 ledger_id」 |
| 迁移/DDL | F-32..F-34（~5 红） | v15/16/21/22/27 裸 ALTER 改 `_addColumnIfMissing` 幂等（照抄 v24）；`_ensureIndexes` 覆盖 `exchange_rate_overrides`；关键表补 CHECK/UNIQUE（金额非负、枚举域） |
| 并发/TOCTOU | F-35/F-36/F-38（~4 红） | 唯一索引 + `INSERT ... ON CONFLICT` 兜底替代「先查后插」；挂标签与删交易同事务；`chunk_utils` 上限按 **999**（保守）而非 32766 |
| U-1 金额上限 | UI 侧 | 金额键 `_append` 位数上限（如 12 位）+ 提交前 `isFinite`（与 C1 同源，UI 归 C7 但断言在此批转绿） |

**验收**：`client/test/adversarial/{transaction_repo,aggregation,category_tag_account,migration,concurrency}_adversarial_test.dart` 40 红转绿；`test/data/*`、`test/repositories/*` 既有测试不回归；**迁移测试必须覆盖「半迁移库」与「已有重复行」两类 fixture**。

---

### 批次 C5 · vendor 包（2–2.5 人日）【P1】

| 发现 | 位置 | 修法 |
|---|---|---|
| R-17 登出后自动重登 | `auth_service.dart` | `signOut` 清理 access/refresh 持久凭证与内存缓存；启动时「无显式凭证」不得走恢复分支 |
| R-30 本地落后仍直通 | `database_sync_manager.dart:553-555` | 版本比较进入 LWW 分支（版本更旧 → 冲突/远端胜），移除绕过条件 |
| R-22/R-23/R-25 pull 健壮性 | pull 路径 | change_id 类型容错（字符串→int，失败跳过并告警）；**缺字段 change 不推进游标**；`serverCursor` 非数拒绝 |
| R-1/R-2 路径规范化 | `path_helper.dart` | 统一 POSIX 段规范化（处理 `.`/`..`/重复斜杠/空段），`join` 后校验逃逸 |
| R-8 4xx 重试 | `retry_helper.dart` | 4xx（除 408/429）不重试 |
| R-19/R-20/R-21 响应健壮 | provider | 2xx 非 JSON → 明确异常；`ledgers` 形态错 → 显式错误而非静默 `[]`；404 与「解析失败」区分错误类型 |
| R-27/R-26 WS | `realtime_service.dart` | 握手失败异常吞掉并退避重连；dispose 后停止重连 |
| R-32/R-33 缓存/迁移 | `cloud_service_store.dart` | 缓存 key 纳入配置版本；迁移同时覆盖 `activeType` 与配置体 |
| R-11/R-12/R-24 异常卫生 | `exceptions.dart` | 补 `statusCode`；`toString` 不展开 `originalError`；401 detail 保留但脱敏 |

**验收**：`client/packages/flutter_cloud_sync`：`flutter test test/adversarial/` 39 红转绿；包内 3 个基线测试不回归；主工程 `test/cloud/sync/*` 不回归。

---

### 批次 S3 · 服务端·业务 API 语义（1.5–2 人日）【P1】

| 发现 | 修法 |
|---|---|
| 负金额 / 未来时间 / `days_since_first_tx` 负值 | 写入口校验 `amount >= 0`（方向由 type 表达）与时间范围；统计侧对负值兜底 |
| PATCH `null` 语义（amount/happened_at/tx_type 三连） | 校验层拒绝「必填字段置 null」（400），或明确「null = 忽略」；两路径（快路径/慢路径）口径一致 |
| 批量移动复活回收站 / 批量删墓碑 | 与 S2 软删过滤族同批（helper 复用） |
| 账本 stats 计入回收站 / admin overview 计入 | 同上 |
| 预算孤儿 / period 越界 500 / member-stats 500 | 校验 `month/year/scope` 参数域（与 month 分支对齐）；孤儿预算返回明确错误/过滤 |
| 邀请码对已删账本（1 红） | preview/accept 前校验账本存在且未删；补 tombstone 检查（与文件头注释对齐） |
| CSV 公式注入 / CSV 往返失败 / 导入去重口径 / tz_offset（4 红） | 导出对 `=+-@\t\r` 起始单元加 `'` 前缀；导入解析器对引号+换行修复（Sniffer 固定 `doublequote=True`）；去重键两侧统一 Decimal 规范化字符串；`tz_offset_minutes` 加 `ge/le` |
| 调整余额幽灵账户（1 红） | 账户存在性校验（含软删）后再写调整记录 |

---

### 批次 S4 · 服务端·AI 中转/附件/备份加固（1.5 人日）【P1】

| 发现 | 修法 |
|---|---|
| 掩码变形覆盖真 key | 掩码识别加正则（`^\*{4}.*$`）与「与当前掩码相同」判定 → 保留原 key；补单测覆盖变形输入 |
| `/providers/test` 无限流 | 纳入限流（与 relay 同策略） |
| MCP scope 越权不落审计 / GET 永不返回 | 工具级 scope 校验补审计日志；不支持的 HTTP 方法返回 405（避免连接悬挂） |
| STT/vision 魔数 | 音频/图片魔数校验（不只信 MIME） |
| 脏 `visionConcurrency` → 500 | 读取时钳制（1..32）并告警 |
| batch-exists 6 万条 DoS | 入参条数上限 |
| 限流计费 | vision-batch 逐张计费（当前只记 1 令牌） |

---

### 批次 C6 · Web 前端（0.5 人日）【P2】

| 发现 | 修法 |
|---|---|
| W-1 i18n 缺 2 键 | `src/i18n/{en,zh-CN,zh-TW}.ts` 补 `error.SHARE_ROLE_FORBIDDEN`、`error.SHARE_MEMBER_USER_NOT_FOUND` |
| W-2 路由 URIError 白屏 | `state/router.ts` 的 `decodeURIComponent` 包 try/catch，失败按原始段处理；补 ErrorBoundary（可选） |
| W-3 `1/raw` 溢出 | `assetAggregation.ts:92-94` 结果再校验 `Number.isFinite` |

---

### 批次 C7 · 客户端 UI（1 人日）【P2】

| 发现 | 修法 |
|---|---|
| U-1 金额输入无上限 | `amount_editor_sheet.dart` `_append` 加位数上限（含整数位与小数位），提交前 `isFinite`（与 C1 同源） |
| U-2 待确认页窄屏/大字体溢出 | 动作行改 `Wrap`/`Flexible` + `ellipsis`；补 320 宽与 textScale 2.0 回归测试 |
| 可测性遗留 | 见批次 X（运算键与页面 timer） |

---

### 批次 X2 · 杂项域补测（1 人日）

补齐 `FINDINGS-misc-services.md` 标注未产出的 5 个子域（周期记账/汇率/隐私证据/存储损坏/匹配器），
并把探测阶段 6 条发现固化为测试（配置换行静默折叠、导入幂等键大小写、`seedDatabase` 非幂等、
store 容量不收敛、`AnomalyDetector` 未接线、`PostProcessor` 顺序规则）。
其中应转红的确证缺陷（如 `seedDatabase` 非幂等、导入键大小写）按同批修法直接修。

---

### 批次 X3 · Postgres CI 作业（0.5 人日，基建）

本轮回测不可达的契约（advisory lock 串行化、user→ledger 锁序防死锁、列宽越界报错、
并发 push 丢更新）全部由 Postgres 专有行为承载。建议：
① 起 `postgres:16` service 容器跑 `pytest tests/`；② 把 `tests/adversarial/` 中标注
「Postgres 不可测」的项加 `@pytest.mark.pg_only`；③ 在 CI 跑双后端矩阵。

---

## 四、验收协议（每批与全局）

**单批门槛（全绿才算完成）**
```bash
# 客户端
export PATH="$HOME/devtools/flutter-3.27.3-sdk/bin:$PATH"
cd client && flutter test test/adversarial/ --reporter compact && flutter test
# Kotlin
export JAVA_HOME="$HOME/devtools/jdk-17"; export ANDROID_HOME="$LOCALAPPDATA/Android/Sdk"
cd client/android && ./gradlew :app:testDevDebugUnitTest && ./gradlew :app:connectedDevDebugAndroidTest
# vendor 包
cd client/packages/flutter_cloud_sync && flutter test test/ test/adversarial/
# 服务端
cd server && python -m pytest tests/ -q          # 含 adversarial
# Web
cd server/frontend/apps/web && pnpm test
```

**全局门槛（收尾）**
1. 客户端 `flutter test`：**0 失败**（含批次 X 修掉的 3 条基线腐烂）；
2. 服务端 `pytest tests/`：**0 失败**（原 623 + 对抗组全绿，除「已接受项」清单）；
3. Web `pnpm test` 0 失败；vendor 包 0 失败；Kotlin JVM+仪器 0 失败；
4. `flutter analyze` 0 error；服务端 `ruff`/`mypy` 不新增告警；
5. 全部对抗测试保留并接入 CI（防回归）；
6. 真机项（vivo 无障碍存活、通知冷启动、TCC 类故障注入）与 Postgres 项按 §三 X3 单独跟踪。

---

## 五、不修 / 接受风险清单（记录理由，避免重复发现）

| 项 | 理由 |
|---|---|
| `AnomalyDetector` 全部边界（含 Infinity 输入） | 全仓无生产调用方（未接线）；建议改为 P2 决策：接线或删除模块 |
| 指纹分隔符碰撞（sms/notify/screenText） | 现有取值域（号码/包名）不含 `|`，碰撞不可达；仅加长度前缀（低成本）后关闭 |
| `billFingerprint` 0.01 元精度归一 | 去重的有意设计（注释已说明），保留；改由金额忠实性把关 |
| Kotlin `identityOf` 全空通知项返回 `"|"` | 现调用方不可达；已在 C1 顺手修（成本≈0） |
| 客户端 `HARDENING` 40 条 / 服务端 `HARDENING` 66 条 / vendor 18 条 | 行为可辩护（多为精度/顺序/兜底的显式取舍）；已在各报告文档化，**不修但保留测试锁行为** |
| 深色模式/大字体在待确认页的历史问题之外的全量 UI 审计 | 需真机走查，非本轮范围 |

---

## 六、迁移与回滚要点

1. **客户端 v45 迁移**（syncId UNIQUE、`transaction_tags` UNIQUE、金额 CHECK）：
   - 迁移前**自动导出 JSON 备份**（复用 `json_backup_service`），失败则中止迁移并提示用户；
   - 去重策略写死在迁移内且幂等（跑两遍结果一致）；提供「迁移前快照」文件命名 `pre-v45-<ts>.json`；
   - 回滚：迁移只做「合并重复 + 加索引」，不删业务字段 → 回滚只需 DROP INDEX（提供脚本）。
2. **服务端 alembic 0034**（若采纳 sortOrder 落库与索引补齐）：保留 `down_revision`，CI 干跑
   `upgrade head` + `downgrade -1` 双向。
3. **附件路径**：S1 只做「校验 + 包含性检查」，**不改变既有文件布局** → 无文件迁移、无回滚需求。
4. **行为变更的用户可见影响**（需在发布说明提示）：
   - 日期解析收紧：以前被静默接受的脏日期行会变为「无效行」（导入页显示原因）；
   - 指纹口径变更（note/channel 归一）：跨版本可能出现一次性重复候选 → 靠判重兜底；
   - PATCH `null` 语义变更：老客户端「置空字段」的调用可能转为 400（需确认客户端无此用法，否则先扩兼容窗口）。
5. **发布顺序**：服务端 S1/S2 与客户端 C1/C2 可独立发布；C4/C5 依赖 S2 的游标/幂等语义 → 先服务端后客户端。

---

## 七、工作量汇总

| 批次 | 人日（估） |
|---|---|
| X（测试基建） | 0.5 |
| S1（安全） | 1–1.5 |
| C1（记账核心） | 1.5–2 |
| S2（同步一致性） | 2.5–3 |
| C2（解析导入） | 2.5–3 |
| C4（同步引擎） | 1.5–2 |
| C3（数据层，含迁移） | 3–4 |
| C5（vendor） | 2–2.5 |
| S3（API 语义） | 1.5–2 |
| S4（AI/附件/备份） | 1.5 |
| C6/C7（Web/UI） | 1.5 |
| X2/X3（补测/CI） | 1.5 |
| **合计** | **≈ 20–25 人日** |

---

## 八、附录：发现 → 批次映射

| 报告 | 红测 | 主要批次 |
|---|---|---|
| `client/test/adversarial/FINDINGS-parsers.md` | 50 | C2（日期/金额/CSV/JSON/prompt）、C1（Infinity 族） |
| `client/test/adversarial/FINDINGS-autobook-core.md` | 14 | C1（A1–A14）、C7（U-1） |
| `client/test/adversarial/FINDINGS-data-layer.md` | 40 | C3（全部）、C1（F-13）、C7（U-1） |
| `client/test/adversarial/FINDINGS-sync-engine.md` | 12 | C4 |
| `client/test/adversarial/FINDINGS-widget-ui.md` | 4 | C7（2）、X（可测性 2） |
| `client/test/adversarial/FINDINGS-misc-services.md` | 8 | X2（补测）、C2（YAML/导入） |
| `client/android/.../FINDINGS-kotlin-native.md` | 2 | C1（顺手） |
| `client/packages/flutter_cloud_sync/.../FINDINGS-cloud-sync-package.md` | 39 | C5 |
| `server/tests/adversarial/FINDINGS-auth-security.md` | 20 | S1（安全/DoS）、S2（路径）、S3（边界） |
| `server/tests/adversarial/FINDINGS-sync-consistency.md` | 26 | S2 |
| `server/tests/adversarial/FINDINGS-business-api.md` | 22 | S3、S2（软删族） |
| `server/tests/adversarial/FINDINGS-ai-attachment-backup.md` | 31 | S1（穿越/SSRF/zip bomb）、S4（加固） |
| `server/frontend/.../FINDINGS-web-frontend.md` | 8 | C6 |
| 主报告 §四（N-1..N-4） | 4 | C2（N-1 prompt）、C1（N-2 历史）、S2（N-3 sortOrder，P2 决策）、C1（N-4） |

---

## 九、待确认的产品决策（需人工拍板，不阻塞 P0）

1. `account.sortOrder` / `tag.sortOrder`：云端补列实现同步（推荐，落 alembic 0034）还是客户端停发并文档标注不支持？
2. 跨账本同 `syncId` 是否合法（决定客户端唯一索引是 `UNIQUE(sync_id)` 还是 `UNIQUE(ledger_id, sync_id)`）？
3. 负金额语义：拒绝入库还是按方向取绝对值（影响 C3 与 S3 同批行为）？
4. `AnomalyDetector`：接线还是删除模块？
5. 日期歧义默认（`03-04-2026`）：默认 dd-MM 还是按区域设置？

---

## 审核记录

### 第 1 轮（2026-10-11，plan-review）

**结论：有条件通过 —— 7 个阻塞项需先处理，处理后复审。**

#### 问题登记表

| 编号 | 严重级 | 位置 | 问题与建议 | 状态 |
|---|---|---|---|---|
| 阻塞-1 | 🔴 | §三 C5 / §四 | 验收要求 39 红全绿，但修法仅覆盖 18 个 R 项（R-1,2,8,11,12,17,19~27,30,32,33）；缺 R-3~7,9,10,13~16,18,28,29,31,34~39 共 21 条（含中危 R-9/R-10/R-31）。建议补齐修法或移入 §五 接受清单并改验收数 | 待修 |
| 阻塞-2 | 🔴 | §八 映射行 / C2 表 | FINDINGS-misc-services 的 8 红（YAML 引号/注入×2、备份 Infinity 导出失败×2、坏行中断导入×2）在 §八 被映射到「C2（YAML/导入）」，但 C2 表无对应行、无修法；YAML 注入可抬高周期账单金额属安全面。建议显式落行 | 待修 |
| 阻塞-3 | 🔴 | §三 S2 第 1 行 | F-01 四元组修法未对齐服务端 payload 注入顺序：重放判定（push.py:515-526）发生在注入 `updatedByUserId/createdByUserId`（:641-655）之前，库内 payload_json 是注入后的。按计划字面对入站裸 payload 算 hash → 真重放 hash 不等 → 重复落 SyncChange → 既有绿测 `tests/test_sync_concurrency.py:217` 变红，违反「修完不许新增失败」。建议 hash 前做同序注入或剔除注入键，并列出需回归的既有幂等测试 | 待修 |
| 阻塞-4 | 🔴 | §三 C4 末两行 | U-08 修法不充分：`_applyBudgetChange` 为 void、调用方无条件 `return true`（sync_engine_apply.dart:36-38/698-703）；游标在 skipped>0 时仍无条件 commit（sync_engine.dart:1423-1424），仅改返回 false 只计入 skipped，红测不转绿。需改为 blocked 语义或延迟重放。另 hasMore 循环实际在 sync_engine.dart:1385-1439、`?? -1` 在 sync_engine_apply.dart:97-99，计划位置标注错误 | 待修 |
| 阻塞-5 | 🔴 | §三 C2 第 1 行 | 归因错误：「移除裸 `DateTime.parse` 兜底（正是它把 03-04-2026 解析成 0008 年）」不属实——实测 `DateTime.parse('03-04-2026')` 直接抛 FormatException；0008-10-16 来自 intl `DateFormat('yyyy-MM-dd')` 宽度不校验（_tryParseCommonFormats）。照字面修找不到对应代码。建议删除该表述，改为「常见格式表内 yyyy-MM-dd 用严格 regex/回写校验兜住 intl 宽度不校验」 | 待修 |
| 阻塞-6 | 🔴 | §三 C3 并发/TOCTOU 行 | 修法方向反了：chunk_utils.dart:13 现值 **400**（注释「低于常见 999」），改 999 是放宽；F-38 真问题在三个未分块入口（tx:832-836、acct:692-697、attachment:209-212）。建议改为「给三个入口套 chunkIds（保持 400）+ 唯一索引/ON CONFLICT」 | 待修 |
| 阻塞-7 | 🔴 | §三 C3 / §六.1 | v45 迁移三处硬伤：(a)「回滚只需 DROP INDEX」与修法「删除重复副本行」矛盾，合并删除不可逆；(b) 迁移前「强制导出 JSON 备份，失败则中止」会被存量 Infinity 行击穿（buildBackupJson 无法 jsonEncode Infinity，misc 域红测 1/2 已证），onUpgrade 抛错=库打不开；(c) 存量 Infinity 行清理与 formatBalanceFull 渲染兜底（format_utils.dart:122-124）无批次承接（C1 只拦新写入）。建议：回滚声明改为依赖 pre-v45 快照恢复；备份前过滤非有限值；明确存量清理归属 | 待修 |
| 建议-1 | 🟡 | §三 S1 SSRF 行 | 策略须插入 `routers/ai/test_provider.py` 的 4 处自建 AsyncClient（:271/300/341/378/398）；providers.py:465 只是委托。只改 provider_client 会漏 `/providers/test` 与 `/ai/test-provider` | 待修 |
| 建议-2 | 🟡 | §三 S1 路径白名单 | `^[A-Za-z0-9_-]{1,64}$` 严于现有 schema max_length=128（schemas.py:937）；应只用于创建点，或先核对存量 external_id 长度，避免旧账本附件不可达 | 待修 |
| 建议-3 | 🟡 | §三 S1 验收 | 验收命令 6 文件漏 `test_idor_adversarial.py`（「禁用用户仍可 WS」2 红所在文件）；「畸形字节」行引 read/workspace.py:322（tz_offset）实为 S3 项 | 待修 |
| 建议-4 | 🟡 | §三 S4 | ①「不支持 HTTP 方法→405」打偏：PUT/PATCH 现状已 405，真问题是 GET SSE 长连接悬挂（SDK _handle_get_request）；②「vision-batch 逐张计费」表述误导：usage 本就逐张落日志，缺的是限流令牌按张计（relay.py:561）；③ 掩码修复需覆盖两个入口（providers.py:366 + ai_config_store.py:108-117） | 待修 |
| 建议-5 | 🟡 | §三 S4 路径 | zip/tar 真路径为 `src/services/backup/tar_builder.py:119` 与 `restore_runner.py:277-281`（tar 分支计划未点名）；`admin_backup.py` 应为 `src/routers/admin_backup.py` | 待修 |
| 建议-6 | 🟡 | §三 C1 K-2 | `identityOf` 全空→`""` 会使现绿 HARDENING 断言 `AdversarialQueueLogicTest.kt:110 assertEquals("|", ...)` 翻红，须同批改该测试，否则「2 红转绿」变 3 红 | 待修 |
| 建议-7 | 🟡 | §三 C1 A5 / A10 | A5 行号错：mark 语义在 :205-207（:662-672 是调用方 resolvePendingItem）；「null 也写」需审计全部 mark() 调用点（recurring/import 会顺带清 dup 列）。A10 需先确认历史行公式（git 历史已重置，仓内无法证明），考虑双 key 探测 | 待修 |
| 建议-8 | 🟡 | §三 C4 | U-05/U-06 同族第三处未列：sync_engine_apply.dart:486-491（seed 分类收编 getSingleOrNull）；验收 glob 字面展开有错（`dedup__`/`lead_list_history_adversarial_test.dart` 不存在），lead_coordinator 文件 0 红，「35 红」口径对不上（可核 ≈20） | 待修 |
| 建议-9 | 🟡 | §三 C2 验收 | 「50 红转绿」与 FINDINGS-parsers 自身「40 条红」矛盾；50 中多条根因归 C1（Infinity/崩溃链 3+3），3 条 formatBalanceFull 为绿锁测试（断言抛 RangeError），未来加渲染兜底须同步改。建议按「文件×转绿数」重新对账 | 待修 |
| 建议-10 | 🟡 | §三 C3 F-32 | v21/v22 已有 PRAGMA 守卫（非裸 ALTER）；真正未覆盖的是 v2/v3/v4 裸 ALTER 与 v7 重建表（DROP+RENAME）；迁移测试只覆盖 v15/v27。另「limit 语义三套」实为 4 套；F-37 全篇未引用 | 待修 |
| 建议-11 | 🟡 | §三 C5 | R-32 实际在 cloud_sync_manager.dart:221-228（非 cloud_service_store）；R-17 修复需同步 App 侧（sync_providers.dart:634-638 每次重建都注入邮密）；改 path_helper 会改变已上传对象键，兄弟包（webdav/supabase/s3）不在验收命令范围，需补跨包回归 | 待修 |
| 建议-12 | 🟡 | §三 X 可测性 2 | 实测失败形态是「did not complete（挂起）」而非 pending timer 告警；page/store/coordinator 订阅路径均无 Timer，指向动作链上的 logger 2s `_saveTimer`（logger_service.dart:251）或 toast 2s。实施前先最小复现定位真实挂起源，再定修法 | 待修 |
| 建议-13 | 🟡 | §三 S2 | ① F-03 clamp 修法隐含一次 SyncChange 迁移（无原始 ts 列），§六 未列；② F-04 漏 `_as_float_or_none` 与内联 `_opt_float`（projection.py:63-71/335-341/673-682）；`allow_nan=False` 单独加会让 /sync/full 500，须与入口拒绝同批；③ S2 验收 glob 不含软删族/ledger_access 红测文件（test_tx_write/test_idor/test_ledger_budget_stats/test_import_export_admin），按现 glob 跑绿不能证明 S2 完成；④ F-13 静态扫描为文件级 grep，强度弱于计划暗示 | 待修 |
| 建议-14 | 🟡 | §三 S3 | S3 段无验收测试清单/glob（其余批次均有），「1 红」等计数无法对账；import 侧 tz_offset（import_data/endpoints.py:83/164）也无 ge/le | 待修 |
| 提示-1 | 🟢 | §二 批次总览 | 「关闭红测（约）」列合计 ≈316，实测红测总数 278（客户端 130 实测一致）；服务端 adversarial 实测 506 collected（报告 499）。建议以实测重列 | 待修 |
| 提示-2 | 🟢 | §六.2 | alembic 下一文件号 0034 成立；但仓内 `0033_attachment_tx_partial_unique.py` 的 revision 实为 `0032_...`（错位一位，pre-existing），新迁移命名注意 | 待修 |
| 提示-3 | 🟢 | §五 | 「客户端 HARDENING 40 条」未逐条核实具体数（报告写 30+）；不影响结论 | 待修 |
| 提示-4 | 🟢 | §四 全局门槛 1 / 各批验收 | 客户端红测基线含 ±5 不确定：同一代码两次全量 `flutter test test/adversarial/` 实测得 -130 与 -135，差额为 `ui_pending_confirmation_adversarial_test.dart` 的 5 条 `did not complete` 是否计入。建议：该文件标注 known-flaky；各批验收改为「该批文件逐文件单跑 + 单跑基线数」的对账口径，不要用全量总数判绿 | 待修 |

#### 核实台账（第 1 轮）

**已核实到方法体（客户端 ~40 项，关键项）**：claim 非原子（auto_book_event_store.dart:147-179，无事务）✓；`_keyTails` 实例字段 + provider 单例（coordinator:63、automation_providers:37-41）+ data_import_service:902 直调 claim 旁路 ✓；cleanupExpired 不调 expireStalePending（:1075-1119）✓；listHistory 先 limit 后内存过滤（:306-326）✓；mark 的 absent 语义与调用方错位（:205-207 vs :666-668）✓；isFinite 缺口 5 处（json_response_parser:123-125、auto_book_policy:118-119、semantic_dedup_matcher:69-72/202-207、local_repository:378-436 落库无守卫）✓；date_parser 全实现 + 实测归因（DateTime.parse 抛错；intl DateFormat 产出 0008）✓；chunk_utils=400 ✓；db.dart schemaVersion=44、v15/16/27 裸 ALTER、v21/22 有守卫、v24 helper、`_ensureIndexes` 无 exchange_rate_overrides ✓；syncId getSingleOrNull 无 UNIQUE ✓；删交易不清 transaction_attachments、`_deleteAttachmentsForTransaction` 死代码 ✓；strftime 月视图已带 unixepoch/localtime、`DATE(happened_at)` 缺 unixepoch（:1858）✓；totalsByCategory 双计 / getBudgetUsage 忽略 period / daysRemaining 脱钩 ✓；updateCategory 无环检测、createSubCategory 查重不含 parentId、transaction_tags 无 UNIQUE ✓；searchTransactions(limit<0) RangeError、limit 语义 4 套 ✓；sync_engine reportedRejections（:1213）、熔断计数实现（:1196-1281）、游标无条件 commit（:1423-1424）、hasMore while 无上限（:1385-1439）✓；resolvers getSingleOrNull（:65）vs 账户侧 limit(1)（:85-88）✓；parentSyncId 被忽略（:466-477）✓；budget 早退 void + 调用方 return true ✓；amount_editor 完成键/applyEquals（:705/:1135-1139）、_append 无位数上限 ✓;logger 2s `_saveTimer`（logger_service.dart:251）✓。

**已核实到方法体（服务端 ~35 项，关键项）**：attachments.py:136-143 拼接无校验 ✓；写入点仅 write/ledgers.py:31 与 push.py:388 两处（第三处实为查询参数）✓；admin.py:883-885/947-949 ✓；SSRF 站点 7+ 处 + test_provider.py 自建 client 5 处 ✓；profile 深嵌套（schemas.py:93-101 无限制、读取 500 机理为响应序列化）✓；ws.py:44-50 不查 is_enabled（对照 deps.py:112/317）✓；passlib 为 pbkdf2_sha256、MAX_PASSWORD_SIZE=4096（非 bcrypt 72 字节）✓；tar_builder.py:107-119 / restore_runner.py:277-281 / admin_backup.py:100-151 / rclone_config.py:274-297 ✓；ai_config_store.py:70-74 startswith 判定 + 两处写入点 ✓；relay.py:561 整批 1 令牌、usage 逐张落日志 ✓；幂等 tuple（:458-464/515-526）与注入顺序（:641-655）✓；cascade 提前 emit（:50-103/:606）✓；clamp（:422-424、SyncChange 无原始 ts 列）✓；projection `_as_float`/`_as_float_or_none`/内联 `_opt_float` 全部无守卫 ✓；软删过滤 4 处 + 无 active_only helper（39 处内联）✓；ledger_access.py:46-56 one_or_none + 约束 models.py:471 ✓；锁调用点全景 + 静态扫描先例（test_shared_ledger_adversarial:464/516，文件级 grep）✓；快/慢路径（_shared.py:550/683 vs :1307）与 PATCH null 三连 ✓；CSV 无公式中和（read/_shared.py:666-675）、Sniffer 未固定 doublequote ✓；调整余额无账户存在性校验（snapshot_mutator.py:985-1013）✓。

**已核实（vendor/web/Kotlin/测试基建）**：vendor R 编号全集 R-1..R-39（计划覆盖 18、缺 21）✓；path_helper 不解析 `..`（:14-27/38-41/108-110）✓；retry_helper:203-205 4xx 重试 ✓；exceptions 无 statusCode、toString 展开 originalError ✓；database_sync_manager:552-556 落后直通 ✓；disconnect/realtime（smartbook_cloud_provider:4410-4569、dispose 不置 _running）✓；cloud_service_store 迁移只覆盖 activeType ✓；`i18n/{en,zh-CN,zh-TW}.ts` 实测恰缺 `error.SHARE_ROLE_FORBIDDEN`/`error.SHARE_MEMBER_USER_NOT_FOUND` 两条 ✓；router.ts:231 decodeURIComponent 无 try/catch ✓；assetAggregation.ts:94 `1/raw`（真实路径在 packages/web-features）✓；Kotlin lossSummary 插值（:219-220）、identityOf 全空返回 `"|"` 且 :110 为绿锁 ✓；vendor 4 个对抗文件与 `flutter test test/ test/adversarial/` 可行性 ✓；`pnpm test`（vitest run）存在 ✓。

**实测运行**：客户端对抗套件同一份代码两次全量运行得 **-130 与 -135 两个不同计数**——差额 5 条恰为 `ui_pending_confirmation_adversarial_test.dart` 批量运行的 5 个 `did not complete` 条目是否被计入（-130 那次该 5 条显示为 `did not complete` 未计入；-135 那次被计为失败）。这意味着**客户端红测基线本身有 ±5 的不确定性**：C1/C2/C4 的「N 红转绿」验收不能只用全量总数对账，需按「逐文件单跑」建立可复现基线，并把该文件标注 known-flaky。另：3 条基线失败复现（B3 计数 7 vs 8）；服务端 `pytest tests/adversarial/` = **506 collected / 99 红**；`--ignore=tests/adversarial` collect-only = **623 条**（与计划一致）；日期解析实验：`DateTime.parse('03-04-2026')` 抛 FormatException、`DateFormat('yyyy-MM-dd')` 给 0008-10-16。

**未核实（外部事实）**：PG advisory lock/列宽/int8 边界（本地 SQLite，锁为 no-op）；真机 vivo 无障碍与通知冷启动；MCP JSON-RPC 往返、rclone/WebDAV/S3 真实连接；Web 渲染层（jsdom 未装 devDeps）。

**未覆盖**：无（计划全部点名对象均已核实；FINDINGS 各报告编号与计划表格已逐份对照，A1-A14/F-01..F-38/P-01..U-08/W-1..3 编号一致，R 编号存在 21 条缺口见阻塞-1）。
