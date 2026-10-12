# 自动记账核心域 · 对抗性测试发现报告

- 范围：SmartBook Flutter 客户端（`D:\github\smartbook\client`）自动记账核心域
- 测试目录：`client/test/adversarial/`（本次新增 4 个文件，仅测试，未改任何 `lib/**`）
- 运行命令：
  ```bash
  export PATH="$HOME/devtools/flutter-3.27.3-sdk/bin:$PATH"
  cd /d/github/smartbook/client
  flutter test test/adversarial/<文件>.dart --reporter compact
  ```
- 纪律：`ADVERSE FINDING` = 确认缺陷，测试保持激活并失败；`HARDENING` = 行为可辩护但脆弱，断言当前行为并通过。
- 时间构造：全部相对 `DateTime.now()`，无固定日期（防 30 天 TTL 腐烂）。

## 总览

| 文件 | 通过 | 失败(ADVERSE) | 合计 |
|---|---|---|---|
| `auto_book_event_store_adversarial_test.dart` | 34 | 5 | 39 |
| `auto_book_state_machine_adversarial_test.dart` | 33 | 2 | 35 |
| `dedup_adversarial_test.dart` | 50 | 5 | 55 |
| `billing_stores_adversarial_test.dart` | 76 | 2 | 78 |
| **合计** | **193** | **14** | **207** |

---

## ADVERSE 发现（14 条）

### A1 · 并发 claim 同 eventKey 双授予（租约失效，同一事件可被执行两次）

- **严重级：高**（静默双记账 / 双份 AI 调用）
- **产品源码**：`client/lib/services/automation/auto_book_event_store.dart:147-179`（`claim`）
- **测试**：`auto_book_event_store_adversarial_test.dart` → `claim 租约边界 ADVERSE: 并发 claim 同 eventKey 双授予(租约失效,同一事件可被执行两次)`
- **期望 vs 实际**：期望 `Future.wait([claim(k), claim(k)])` 中恰好 1 个 `acquired==true`、`attemptCount==1`；**实际 2 个都 `acquired==true`，`attemptCount` 仍为 1**。
- **机制**：`claim` = `ensure()` → `SELECT` 读状态 → 判断租约 → `UPDATE state='processing'`。读与写之间没有事务/条件更新，两个协程都看到"state=captured、租约未占用"，于是都写入 processing 并各自返回 `acquired=true`。源码注释声称"eventKey 的 UNIQUE 约束则负责兜住重启/重复广播等边界竞态"——UNIQUE 只兜住 `ensure` 的 INSERT 竞态，兜不住 `claim` 的读-改-写。
- **影响面**：`auto_book_coordinator.dart:129-143` 的同 key 串行守卫只在本实例内有效；跨实例（进程重启后的新 Coordinator、drain 与手动重试各持一个）仍会双授予 → 同一笔支付落两笔交易。
- **一句话复现**：`await Future.wait([store.claim(input(k)), store.claim(input(k))])`，断言两个 `acquired` 之和为 2。

### A2 · 两个 Coordinator 实例并发 execute 同 eventKey → 业务动作双执行

- **严重级：高**（与 A1 同源，走真实入口）
- **产品源码**：`client/lib/services/automation/auto_book_coordinator.dart:223`（`_runWithContext` 里的 `store.claim`）；注释见 `auto_book_coordinator.dart:34-43`
- **测试**：`auto_book_state_machine_adversarial_test.dart` → `Coordinator 执行语义 ADVERSE: 两个 Coordinator 实例并发 execute 同 eventKey → 业务双执行`
- **期望 vs 实际**：期望 `action` 只被调用 1 次；**实际 2 次**。
- **机制**：`_keyTails` 串行链是实例字段，两个 `AutoBookCoordinator` 各有一条链，互不可见；两条链各自通过 A1 的双授予竞态拿到"租约"。
- **一句话复现**：`final a = AutoBookCoordinator(db), b = AutoBookCoordinator(db);` 两者同时 `execute(input: 同 key)`，计数 `action` 调用次数 == 2。

### A3 · 30 天前的 pending 事件被 `cleanupExpired` 物理删除，丢失过期占位

- **严重级：中高**（历史页记录凭空消失；C8 契约未落实）
- **产品源码**：`client/lib/services/automation/auto_book_event_store.dart:1075-1119`（`cleanupExpired` 末尾的 `DELETE`，`auto_book_event_store.dart:1105`）
- **测试**：`auto_book_event_store_adversarial_test.dart` → `pending TTL ADVERSE: 30 天前的 pending 事件被 cleanupExpired 物理删除,丢失过期占位`
- **期望 vs 实际**：期望 31 天前的 pending 事件在 `cleanupExpired()` 后仍存在且 `state=='expired'`（`reason=='pending_expired'`）；**实际 `findById` 返回 `null`（行被物理删除）**。
- **机制**：`cleanupExpired` 的顺序是 ① `backfillMissingExpiresAt()` ② `cleanupExpiredRawEvidence()` ③ **占位改造**（只对 `rawEvidenceUploadState=='expired'` 的行转占位）④ `DELETE`（`expiresAt < now AND 四个 raw* 全为 null AND uploadState != 'expired'`）。**没有任何 raw 证据的 pending 事件**（短信/通知最常见的形态，因为默认策略不存证据）不满足 ③ 的条件，却被 ④ 直接命中删除。
- **调用点**：`AutoBookCoordinator._initialize()`（`auto_book_coordinator.dart:75`，每个进程首次事件时跑一次）与 `AutoBillingService.retryDueDrafts`（`auto_billing_service.dart:1188-1194`，15 分钟周期）都先于 `expireStalePending`（只在 `PendingCandidateStore.loadForReview` 里跑）。谁先跑决定这条记录是"占位"还是"消失"——这是不确定的。
- **对比测试（通过）**：`HARDENING: 已 expiresAt 置空的占位行不被二次处理` 证明**先** `expireStalePending` 再 `cleanupExpired` 时占位能活下来。两条路径行为不一致本身就是缺陷。
- **一句话复现**：`ensure(capturedAt: now-31d)` → `mark(pending)` → `cleanupExpired()` → `findById(id)` 为 null。

### A4 · `listHistory` 先 `ORDER BY updatedAt DESC LIMIT n` 再在 Dart 里过滤

- **严重级：中**（历史页按状态/来源筛选会漏记录；`AutomationHealth.lastProcessedAt` 语义也偏）
- **产品源码**：`client/lib/services/automation/auto_book_event_store.dart:306-326`（`listHistory`：`orderBy(updatedAt desc)` + `limit(safeLimit)`，随后 `rows.where(state == ... && source == ...)`）
- **测试**：
  - `auto_book_event_store_adversarial_test.dart` → `ADVERSE: listHistory 先 limit 后过滤 → 匹配的旧记录被截断窗口吃掉`
  - `auto_book_event_store_adversarial_test.dart` → `ADVERSE: listHistory 的 source 过滤同样被 limit 窗口截断`
- **期望 vs 实际**：
  - 库内 3 条新 pending + 2 条旧 booked，调 `listHistory(state:'booked', limit: 2)`：期望 2 条；**实际 0 条**。
  - 库内 2 条 notification（`updatedAt` 3 天前）+ 4 条 sms，调 `listHistory(source:'notification', limit: 4)`：期望 2 条；**实际 0 条**。
- **机制**：过滤条件没有下推到 SQL；`limit` 先作用于"最近 N 行"，与筛选维度正交。默认 `limit: 200` 时平时不易暴露，但历史页/每日汇总的显式小 limit 必然暴露。
- **调用点**：`lib/pages/automation/auto_book_history_page.dart:33-36`（历史页筛选）、`lib/providers/automation_providers.dart:102`（`listHistory(limit: 1)` 取 `lastProcessedAt`）、`auto_billing_service.dart:2240`（每日汇总 `limit: 500` 后按当天 `capturedAt` 过滤，同一模式）。
- **一句话复现**：3 条 pending（新）+ 2 条 booked（旧），`listHistory(state:'booked', limit:2).length == 0`。

### A5 · 父事件从 duplicate 回退后残留 `duplicateOfTransactionId`

- **严重级：中**（污染 `sourceKeysForTransaction` 的跨渠道反查）
- **产品源码**：`client/lib/services/automation/auto_book_event_store.dart:666-668`（`resolvePendingItem` 里 `duplicateOfTransactionId: parentState == duplicate ? duplicate.first.transactionId : null`）+ `mark()` 的 null 语义 `auto_book_event_store.dart:205-207`（`update.duplicateOfTransactionId == null → Value.absent()`，即"不改动"）
- **测试**：`auto_book_event_store_adversarial_test.dart` → `ADVERSE: 父事件从 duplicate 回退后残留 stale duplicateOfTransactionId`
- **期望 vs 实际**：期望 reopen 被忽略的子项后（父事件 duplicate → pending）`duplicateOfTransactionId` 被清成 `null`；**实际保留旧值 `9`**。
- **机制**：`resolvePendingItem` 传 `null` 想表达"清空"，但 `mark()` 把 `null` 定义为 `Value.absent()`（不改动）。两处对 null 的语义理解相反。
- **影响**：`sourceKeysForTransaction`（`auto_book_event_store.dart:548-574`）用 `transactionId | duplicateOfTransactionId` 反查"该交易被哪些渠道记录过"，stale 值让**已被用户撤销的判重关系**继续贡献跨渠道证据 → 后续同额捕获更易走 `cross_channel_strong` 强合并。
- **一句话复现**：item0→duplicate(tx9) + item1→ignored + `reopenItem(item1)`；读父行 `duplicateOfTransactionId` == 9（应为 null）。

### A6 · NaN / Infinity 金额绕过 `AutoBookPolicy` 的 `invalid_amount` 闸门

- **严重级：高**（静默数据损坏：非有限金额进入落库/判重链）
- **产品源码**：`client/lib/services/automation/auto_book_policy.dart:118-120`（`final amount = bill.amount; if (amount == null || amount.abs() <= 0)`）
- **测试**：`auto_book_state_machine_adversarial_test.dart` → `AutoBookPolicy 硬闸门 ADVERSE: NaN / Infinity 金额绕过 invalid_amount 闸门被判 allow`
- **期望 vs 实际**：期望 `ignore / invalid_amount`；**实际 `allow / settled_transaction`**（NaN 与 Infinity 都是）。
- **机制**：`double.nan.abs() <= 0` 恒为 `false`（NaN 的所有比较都是 false），Infinity 也不 <= 0。整个自动记账域**没有任何 `isFinite` 守卫**：`JsonResponseParser._sanitize`（`lib/ai/core/json_response_parser.dart:125`）同样只有 `amt == null || amt.abs() <= 0`。
- **可达性证据（测试已证）**：`JsonResponseParser.parse('[{"amount":1e999}]')` → `[BillInfo(amount: Infinity)]`；`'[{"amount":"NaN"}]'` → `[BillInfo(amount: NaN)]`。JSON 数字溢出与字符串 `"Infinity"/"NaN"` 都会被 `double.tryParse` 接受。
- **下游连带**（见 A7/A8/A9）：`BillCreationService` 落 `Infinity` 成功（SQLite 存 `Inf`），`NaN` 则在 NOT NULL 约束上抛 `SqliteException(1299)` —— 一个静默坏数据、一个硬崩。
- **一句话复现**：`policy.evaluate(bill: BillInfo(amount: double.nan, ...)).action` 为 `allow`。

### A7 · `SemanticDedupMatcher.semanticKey` 对 NaN / Infinity 生成可用 key

- **严重级：中高**（判重索引被污染成"万用 key"）
- **产品源码**：`client/lib/services/automation/semantic_dedup_matcher.dart:60-84`，判定点 `:68-72`（`if (merchant == null || time == null || amount == null || amount.abs() <= 0) return null;`）
- **测试**：`dedup_adversarial_test.dart` → `ADVERSE: NaN / Infinity 金额生成可用的 semanticKey(应当为 null)`
- **期望 vs 实际**：期望 `null`；**实际返回 `'semantic:v1:577d00ad...'`**（hash 里含字面 `NaN`；Infinity 同理，且 `Infinity` 与 `-Infinity` 生成**同一个** key，因为都走 `amount.abs()`）。
- **机制**：同 A6——`NaN.abs() <= 0` 为 false。key 落进 `auto_book_event_items.semantic_key` 索引（`lib/data/db.dart:1564-1566` 建的索引），所有 NaN 金额账单共享同一个 key。
- **一句话复现**：`SemanticDedupMatcher.semanticKey(BillInfo(amount: double.nan, merchant:'x', time: now, type: expense))` != null。

### A8 · `hasSecondExactDuplicate` 把两条 Infinity 金额判为"秒级指纹完全命中"（静默合并）

- **严重级：中高**（确定性重复的静默合并通路被非有限金额打开）
- **产品源码**：`client/lib/services/automation/semantic_dedup_matcher.dart:196-220`（`hasSecondExactDuplicate`，`otherAmount.abs() != amount.abs()` 比较）
- **测试**：`dedup_adversarial_test.dart` → `ADVERSE: Infinity 金额被判秒级指纹命中(静默合并)`
- **期望 vs 实际**：期望 `false`（Infinity 不是有效金额，不该进静默合并）；**实际 `true`**。
- **机制**：`otherAmount.abs() != amount.abs()` 对 `Infinity == Infinity` 为 true（相等），于是"金额完全一致"成立；配合相同账本/类型/时间戳/币种，走完整条静默合并路径（`ai_bookkeeper.dart:1015-1047` 命中后 `continue`，不落库不进候选）。
- **不一致性**：同一函数里 `NaN` 反而安全（`NaN != NaN` 恒 true → 跳过）。两个非有限值行为相反，说明这不是有意设计。
- **一句话复现**：`hasSecondExactDuplicate(billInf, [otherInf])` == true。

### A9 · `billFingerprint` 的 note 只 `trim` 不 `normalize` → 同商户写法差异指纹不同

- **严重级：中**（两层去重口径脱节，重复入账只能靠语义判重兜底）
- **产品源码**：`client/lib/services/automation/auto_billing_service.dart:1928`（`final normalizedNote = (note ?? '').trim();`）
- **测试**：`dedup_adversarial_test.dart` → `ADVERSE: billFingerprint 的 note 不归一 → 同商户写法差异指纹不同`
- **期望 vs 实际**：期望 `'商户 X'` 与 `'商户  X '`（内部多空格）指纹相同；**实际不同**（`ea6255cc...` vs `cf23cb5e...`）。
- **机制**：注释声明"账单级指纹按业务要素去重"，但要素只 trim。`normalizeAutoBookText`（`auto_book_event.dart:290-296`，压缩 `\s+`、去标点、lowercase）已在同库存在且被语义判重/豁免表使用，此处未复用。
- **影响**：短信侧与详情页侧对同一笔消费的 note 写法常不同（前者是收款方简称、后者带"支付成功"等尾注），指纹 miss 后依赖语义判重救场；若语义判重也因金额/时间边界未命中，则重复入账。
- **一句话复现**：两次 `billFingerprint(channel:'微信支付', amount:-88, note:'商户 X')` / `note:'商户  X '` 返回不同指纹。

### A10 · `external_id` 快路径与写入侧公式漂移 → 已入账交易反查不到

- **严重级：中高**（外部单号维度判重整体失效）
- **产品源码**：
  - 写入侧：`lib/services/ai/ai_bookkeeper.dart:790`（`semanticKey: SemanticDedupMatcher.semanticKey(bill)` → 内部用 `bill.currency` 走 `externalKey(externalId, currency: bill.currency)`，`semantic_dedup_matcher.dart:52-56`）
  - 查询侧：`auto_book_event_store.dart:411-412`（`SemanticDedupMatcher.externalKey(externalId.trim().toLowerCase())` —— **不传 currency**）
  - 唯一的带 currency 查询点：`lib/services/data_import_service.dart:757-762`（导入路径自己传 `tx.currencyCode`）
- **测试**：`dedup_adversarial_test.dart` → `ADVERSE: external_id 快路径与写入侧公式漂移 → 已入账交易反查不到`
- **期望 vs 实际**：写入行 `semantic_key = externalKey('WX-1', currency:'CNY')`，调 `findTransactionByExternalId('WX-1')`：期望命中 `101`；**实际 `null`**。
- **机制**：`externalKey` 把 currency 拼进 hash 输入（`'${currency ?? ''}|$external'`），所以 `externalKey('WX-1')` 与 `externalKey('WX-1', currency:'CNY')` 是两个不同 key。查询侧不传 currency 时快路径必 miss，只能靠 `_findTransactionByExternalIdScan` 读 `billJson` 里的 `external_id` 兜底。
- **为什么兜底不可靠**：`billJson` 是否含 `external_id` 取决于各写入路径的 payload（`ai_bookkeeper.dart:787-800` 写的是 `bill.toJson()`，含 `external_id`；但真实生产里同一条 `upsertItem` 可能被后写覆盖 —— `upsertItem` 是"先 DELETE 再 INSERT"的覆盖语义）。测试用不含 `external_id` 的行证明**两条路径可以同时 miss**。
- **一句话复现**：`upsertItem(semanticKey: externalKey('WX-1', currency:'CNY'), bill: {'amount': -88})` → `findTransactionByExternalId('WX-1')` 为 null。

### A11 · `JsonResponseParser` 放行 `1e999` / `"Infinity"` / `"NaN"` 为有效金额

- **严重级：中高**（A6-A8 的输入端；AI 输出不可完全信任）
- **产品源码**：`lib/ai/core/json_response_parser.dart:113-144`（`_sanitize`），判定点 `:125`（`if (amt == null || amt.abs() <= 0) return null;`）
- **测试**：`dedup_adversarial_test.dart` → `ADVERSE: 解析器把 1e999 / "Infinity" / "NaN" 放行为有效金额`
- **期望 vs 实际**：期望 `parse` 返回空列表（这些不是有效金额，且下游无守卫）；**实际返回 `[BillInfo(amount: Infinity)]`**（`"NaN"` 同理）。
- **机制**：`BillInfo._parseDouble`（`bill_info.dart:387-397`）用 `double.tryParse`，它接受 `'NaN'`/`'Infinity'`/`'1e999'`（溢出为 Infinity）；JSON 数字 `1e999` 在 `jsonDecode` 阶段就变成 `Infinity`。`_sanitize` 的 `abs() <= 0` 挡不住（同 A6）。
- **文档承诺被打破**：`json_response_parser.dart:15-18` 明确写"**统一 sanitize**：amount 缺失/为 0 的丢弃……可直接逐笔入库，**不需要**再做 `where((b) => b.amount != null && ...)` 之类的二次过滤"——下游确实没做，于是非有限金额一路到落库。
- **一句话复现**：`const JsonResponseParser().parse('[{"amount":1e999,"time":"2026-01-05T12:00:00"}]').isNotEmpty` == true。

### A12 · `BillCreationService` 对 NaN 金额抛 SQLite 异常、对 Infinity 静默落库

- **严重级：中高**（一个崩溃、一个静默坏账；A6/A11 的落地后果）
- **产品源码**：`lib/services/billing/bill_creation_service.dart:118-123`（`if (amount == null || amount.abs() <= 0) { return null; }`）；`lib/data/db.dart:116`（`RealColumn get amount => real()();` NOT NULL）
- **测试（本轮探针实证，正式测试以 A6/A11 覆盖同一根因，此处记录行为差异）**：
  - `createFromBill(amount: double.nan)` → `SqliteException(1299): NOT NULL constraint failed: transactions.amount`（Drift 把 NaN 绑成 SQL NULL）
  - `createFromBill(amount: double.infinity)` → **落库成功**，读回 `amount == Infinity`
- **机制**：`amount.abs() <= 0` 对 NaN 与 Infinity 都是 false → 校验放行；SQLite 无 NaN 表示（NaN 被 Drift 绑成 NULL）→ NOT NULL 违约抛异常；Infinity 是合法 REAL → 静默写入。
- **影响**：Infinity 进入 `transactions` 后污染统计/预算/余额聚合（任何含 Infinity 的求和都是 Infinity）。NaN 路径抛异常在自动记账链上会被 `AutoBookCoordinator` 捕获 → `markRetry` → 重试 8 次 → `failed`（用户看到"失败"但看不出根因）。
- **一句话复现**：`createFromBill(bill: BillInfo(amount: double.infinity, ...))` 返回非 null 交易 id。

### A13 · `ChannelAccountStore` 并发 `upsert` 丢更新

- **严重级：中**（用户配的账户规则静默消失）
- **产品源码**：`lib/services/billing/channel_account_store.dart:262-272`（`upsert` = `load()` → 改 List → `save()`）；`save` 见 `:222-226`；无任何 `_serial`/锁
- **测试**：`billing_stores_adversarial_test.dart` → `ADVERSE: 并发 upsert 丢更新(5 轮全部稳定复现)`
- **期望 vs 实际**：`Future.wait([upsert(招行A), upsert(建行B)])` 后期望 2 条规则；**实际 1 条**（其中一条被整行覆盖掉）。5 轮全部稳定复现。
- **机制**：典型 read-modify-write：两个协程各自 `load()` 到 `[]`，各自 `[...].add(x)`，各自 `save()` → 后写的赢。所有 prefs 读在 `await` 处让出，交错必现。
- **同类已修的对照**：`PendingCandidateStore`（`lib/services/billing/pending_candidate.dart:254-260`）**有** `_tail` 串行化并附注释"SharedPreferences 的 read-modify-write 不是原子的……统一串行化避免互相覆盖候选"。同类风险在 ChannelAccountStore / CategoryLearningStore / AutomationSettingsStore 都未处理。
- **一句话复现**：`await Future.wait([store.upsert(ruleA), store.upsert(ruleB)]); (await store.load()).length == 1`。

### A14 · `CategoryLearningStore` 并发 `add` 丢更新

- **严重级：中**（用户纠正过的分类学习记录丢失）
- **产品源码**：`lib/services/billing/category_learning_store.dart:125-144`（`add` = `list()` → 过滤 → add → `_save()`）；`_save` 见 `:194-203`
- **测试**：`billing_stores_adversarial_test.dart` → `ADVERSE: 并发 add 丢更新(5 轮全部稳定复现)`
- **期望 vs 实际**：`Future.wait([add(kwA), add(kwB)])` 后期望 2 条（不同 keyword）；**实际 1 条**。5 轮全部稳定复现。
- **机制**：同 A13。
- **可达性**：待确认页"编辑确认"与交易编辑页都可能几乎同时落学习规则。
- **一句话复现**：`await Future.wait([store.add(keyword:'kwA',...), store.add(keyword:'kwB',...)]); (await store.list()).length == 1`。

---

## HARDENING 条目（行为可辩护但脆弱，测试断言当前行为并通过）

| # | 条目 | 位置 | 说明 |
|---|---|---|---|
| H1 | `claim` 租约边界按"恰好到期即放行" | `auto_book_event_store.dart:160-162` | `now.isBefore(updatedAt + 10min)`：9:59 拒绝、10:00 放行。依赖 drift 秒级存储，语义精确但边界含义未文档化。 |
| H2 | `retry` 的 `nextRetryAt` 为空 = 无闸门立即放行 | `auto_book_event_store.dart:155-159` | 与 `markRetry` 恒写 nextRetryAt 配合是安全的；`mark()` 可以写 `retry + null`（`auto_book_event_store.dart:214`），此时闸门失效。 |
| H3 | `ensure` 不对 eventKey 归一（`' x '` ≠ `'x'`） | `auto_book_event_store.dart:43-45` | 只查 `trim().isEmpty`；U+200B 零宽空格能通过判空。真实调用方都自己 hash 派生，风险低。 |
| H4 | 已终端 `uploaded` 状态也跳过证据附着 | `auto_book_event_store.dart:113-117` | `cleared`/`expired`/`uploaded` 三态跳过。`uploaded` 跳过是合理的（证据语义已确立），但意味着上传成功后重放同一事件不会再补正文。 |
| H5 | `markRetry` 错误截断按 UTF-16 code unit | `auto_book_event_store.dart:1144-1149` | 240 字符阈值 + `…`；截断可切断代理对，落库后变 U+FFFD。仅可读性受损。 |
| H6 | `mark` 对不存在 eventId 静默 no-op | `auto_book_event_store.dart:181-221` | `void` 返回值，无任何信号。事件行被 `cleanupExpired` 删掉后，迟到的 `mark` 静默丢状态。 |
| H7 | `resetRetryGate` 清 `nextRetryAt` 但不复位非 failed 事件 | `auto_book_event_store.dart:986-999` | 只对 `failed` 做 `failed→retry` + `attemptCount=0`；其它状态只清闸门。语义正确（注释已说明），但 `retry` 事件被手动重试时 `attemptCount` 不复位，用户拿到的尝试次数少于预期的一半。 |
| H8 | `listHistory` 默认按 `updatedAt desc` | `auto_book_event_store.dart:312-320` | `updatedAt` 有 `currentDateAndTime` 默认值且每次 `mark` 刷新，故"最近处理"排序语义正确。 |
| H9 | `listDrafts`/`dueDrafts` 的 `failed` 分支是死过滤 | `auto_book_event_store.dart:936-967` | `state.isIn(['captured','processing','retry','failed'])` 含 `failed`，但 `mark()` 清草稿 + `saveDraftByEventKey` 拒终态 → 恒不可能出现 `failed + draft != null`。注释（`auto_book_event_store.dart:237-241`）解释了动机，但过滤条件保留 `failed` 属误导。 |
| H10 | `resolvePendingItem` 对非 pending 子项静默 `changed==0` | `auto_book_event_store.dart:617-674` | `void` 返回值，调用方无法区分"已处理"与"被并发抢先"。与 `reopenItem` 的 `bool` 期望状态检查不对称。 |
| H11 | 父事件聚合优先级 `pending > booked > duplicate > ignored` | `auto_book_event_store.dart:644-661` | 组合已全覆盖测试。`booked.first.transactionId` 在多笔 booked 时取**第一个子项的** tx（子项按 itemIndex 升序），语义可辩护但未文档化。 |
| H12 | `itemIndex` 无校验（负数 / int32 极大值都接受） | `auto_book_event_store.dart:577-613` | 调用方传错索引不报错，只造出游离子项。 |
| H13 | `listRawEvidence` 的 prefs 契约与 `cleanupExpired` 契合 | `auto_book_event_store.dart:751-795` | `uploadableOnly` 过滤条件完整；负/大 offset 不崩（SQLite 语义）。 |
| H14 | `backfillMissingExpiresAt` 幂等、跳过 `expired` 占位 | `auto_book_event_store.dart:1061-1073` | 与 A3 对照：占位改造只在"证据被清"时触发，无证据行不适用 → 见 A3。 |
| H15 | `AutoBookPolicy` 闸门顺序固定（settlement → confidence → precision） | `auto_book_policy.dart:99-244` | 同时缺多个条件时只报第一个原因码。方向都是保守的"进待确认"，但用户看到的文案可能不指向真实原因。 |
| H16 | `AutoBookRule` 双方时间都缺失时按 `diff=0` 判重 | `lib/services/billing/pending_candidate.dart:183-186` | `Duration.zero` → 判疑似重复进待确认。宁可多问一次，可辩护。 |
| H17 | NaN confidence 被判"非低置信" | `lib/services/billing/pending_candidate.dart:139-141` | `NaN < 0.9` 恒 false → 直接放行自动入账（同 A6 的根因，但此处影响面小：confidence 只来自模型输出）。 |
| H18 | `ChannelAccountRule.cardLast4` 不从 JSON 侧截断到 4 位 | `lib/services/billing/channel_account_store.dart:60-78` | 注释声称"只保留 4 位:完整卡号永不落盘"，UI 有 `LengthLimitingTextInputFormatter(4)`，但反序列化路径不截断。绕过 UI 直写 prefs 会留下完整卡号。 |
| H19 | `ChannelAccountStore.upsert` 按 channelName 覆盖，忽略 ledgerId/sources | `lib/services/billing/channel_account_store.dart:262-272` | 账本 A 的"招行→账户1"规则会被账本 B 的"招行→账户2"静默删除。 |
| H20 | `ChannelAccountStore.ruleFor` 只 `toLowerCase` 不 `trim` | `lib/services/billing/channel_account_store.dart:230-238` | UI 侧 trim 过，程序化调用（`'招行  '`）查不到；而同文件的 `matchChannelRule` 用 `trim().toLowerCase()`，口径不一致。 |
| H21 | `matchChannelRule` 作用域不匹配 → 静默 `none`（回落 AI 路径） | `lib/services/billing/channel_account_store.dart:128-182` | 与"命中但无法验证 → conflict"形成对照。作用域不匹配视为"未命中"可辩护，但用户配了 `sources:['notification']` 的规则在短信路不生效时无任何提示。 |
| H22 | `CategoryLearningStore.setEnabled(keyword, enabled)` 第二参是"期望当前状态" | `lib/services/billing/category_learning_store.dart:171-183` | 传 `(kw, false)` 在规则已停用时返回 `false` 且不动作；要启用必须传 `(kw, true)`。命名与直觉相反。 |
| H23 | `CategoryLearningStore.add` 同 keyword 全局覆盖，忽略 ledgerId | `lib/services/billing/category_learning_store.dart:125-144` | 账本作用域列形同虚设（后裁定顶掉先裁定）。 |
| H24 | `CategoryLearningStore.match` 在 `ledgerId: null` 时跳过所有绑定规则 | `lib/services/billing/category_learning_store.dart:209-223` | `r.ledgerId != null && r.ledgerId != ledgerId` → 调用方不传账本时绑定规则全失效。保守方向，可辩护。 |
| H25 | `AutomationSettingsStore` 高版本配置无写守卫 | `lib/services/automation/automation_settings_store.dart:240-246` | 契约（`docs/plans/B0-基线与状态字段约定-2026-10-10.md:105`）说"读取到更高版本时**只读不写**并显示「待生效」"。`copyWith` 会透传 `schemaVersion`（读-改-写路径不降级），但 `save(const AutomationSettings())` 会把 99 覆盖成 1。`AutomationSettings` 没有 "待生效" 标志位。 |
| H26 | 未知键在下次写盘时丢失 | `lib/services/automation/automation_settings_store.dart:197-203` | 白名单序列化。向前兼容只能靠 `schemaVersion` 分支。 |
| H27 | 旧字段名 `setupProgress`（文档写法）不被识别 | `automation_settings_store.dart:216`（读 `map['setup']`） | B0 文档 §3.1 示例写 `setupProgress`，实现读 `setup`。按文档写入的旧进度被静默忽略。 |
| H28 | `AutoBookSetupProgress.copyWith` 无法清空 `sources` | `automation_settings_store.dart:118-133` | `sources ?? this.sources` → 传 `{}` 有效（非 null），但传 `null` 不能清空。 |
| H29 | `normalizeAutoBookText` 只清全角标点集 | `auto_book_event.dart:290-296` | 正则 `[，。、“”‘’：；！？（）【】［］]` 不含 ASCII 标点 → `'商户!'` 与 `'商户'` 是两个文本，影响判重/学习/豁免表命中。 |
| H30 | `deepLinkEventKey` 只 `trim` 不 `toLowerCase` | `auto_book_coordinator.dart:319-325` | 同一 idempotency key 换大小写重发 → 两个 eventKey → 双事件。幂等键按规范大小写敏感，不改判。 |
| H31 | `AnomalyDetector.detect` 无 `isFinite` 守卫 | `lib/services/billing/anomaly_detector.dart:45-65` | `current=NaN` 时 `NaN <= threshold` 恒 false → 生成 verdict（ratio/excessRatio 为 NaN）。历史序列含 NaN 会让阈值变 NaN → 任何 current 都判异常。上游不会传 NaN，但缺守卫。 |
| H32 | `AutomationHealth` 权限被撤的已开启来源同时产出两条 issue | `automation_health.dart:194-224` | `permissionRevoked`（阻断）+ `listenerUnverified`（不阻断，因 `bridgeConnected == null`）。语义合理，但 UI 需能同时展示。 |
| H33 | `AutomationHealth.unknown()` 只返回 `statusQueryFailed` | `automation_health.dart:118-128` | 查询失败时 AI/队列维度全部缺省，状态卡信息量骤降。设计上"绝不显示正常"，可辩护。 |
| H34 | `smsFingerprint`/`notifyFingerprint` 用 `\|` 直接拼接，可构造碰撞 | `auto_billing_service.dart:1077-1120` | 测试证明 `smsFingerprint('95555', '消费100\|转账')` == `smsFingerprint('95555\|消费100', '转账')`。实际不可达性高（sender 是运营商短号，不含 `\|`）。 |
| H35 | `billFingerprint` 金额按 `toStringAsFixed(2)` 归一分 | `auto_billing_service.dart:1919-1934` | `88.004` 与 `88.0049` 折叠成同一指纹；真实账单金额都是两位小数，威胁面小。 |
| H36 | `PendingCandidateStore.loadForReview` 的投影过滤口径 | `pending_candidate.dart:356-427` | 缺 `amount`/`time` 的行被跳过；`item.reason` 优先于 `payload['candidate_reason']`。均已测。 |
| H37 | `PendingDecisionCoordinator.keyFor` 对缺失 itemIndex 按 0 | `pending_candidate.dart:477-478` | 与 `PendingCandidateStore.remove` 的"不把缺失索引当 0"口径相反，但互斥键取粗粒度是安全方向。 |
| H38 | `transactionIdsForEvent` 不过滤子项 state | `auto_book_event_store.dart:526-537` | 文档注释说"booked/duplicate",实现把 `pending` 子项的 `transactionId` 也算进集合。当前无调用方（grep 为零），风险未兑现。 |
| H39 | `listHistory` 也用于"最近处理时间"语义 | `lib/providers/automation_providers.dart:102-103` | `listHistory(limit: 1).first.updatedAt` 取"最近一次处理"。同时是 A4 的受害点：若将来给这里加 state 过滤，`lastProcessedAt` 会算错。 |
| H40 | `ensure` 的 policy 读取无缓存 | `auto_book_event_store.dart:52` | 每次 `ensure` 都 `RawEvidencePolicyStore().load()`（内部有 `_cache`，但每次 new 一个新实例 → 缓存不生效）。性能问题，非正确性。 |

---

## 未能验证（环境/成本受限，未写测试）

1. **`AutoBillingService` 全链路 drain / 通知 / 短信去重的并发竞态**：`_draftRetryRunning` 是实例布尔标志（`auto_billing_service.dart:1180-1182`），非原子且无跨实例互斥；`_processedSmsFingerprints` 等 Set 也是实例字段。要验证需要 mock `ProviderContainer` + `MethodChannel` + native 队列，成本超出本轮范围。**未验证，但值得单独一轮**。
2. **`AutoBookCoordinator.initialize()` 的真实启动时序**：`_ready ??= _initialize()` 只跑一次，`cleanupExpired` 失败被吞（`auto_book_coordinator.dart:75-82`）。测试里 `initialize` 被 `_awaitSlotAndRun` 调用但失败路径需要注入 DB 故障，未覆盖。
3. **`_replayDraft` 的目标解析与冻结快照联动**（`auto_billing_service.dart:1235-1300`）：需要 `ProviderContainer` + `resolveAutoBookTarget` 全链，本轮以 `resolveAutoBookTargetPure` 纯函数覆盖（`billing_stores_adversarial_test.dart` 已测优先级矩阵），未覆盖 IO 侧。
4. **`BillCreationService` 的汇率预拉路径**（`ensureRate` 注入 / `_hasLocalRate`）：需要可行 `EnsureRate` 与汇率表夹具，本轮只覆盖了币种/账户匹配的边界（`billing_stores_adversarial_test.dart`）。
5. **`AccountRuleConflictException` 到"待确认"的端到端落地**：`matchChannelRule` 的 conflict 判定已测（H21 + 通过用例），但从 `BillCreationService._matchAccount` 抛异常 → 记账层转候选的接线未测（需 `AiBookkeeper` 全装配）。
6. **跨进程/多 isolate 竞态**：A1/A2 已证明**同 isolate 内**的并发双授予。真正的多进程场景（Android 前台服务 + Activity）无法在 `flutter test` 里构造。
7. **`itemsForEvents` 的 999 变量上限**：源码按 400 分块（`auto_book_event_store.dart:348-368`），测试覆盖了 >400 的分块，但未验证 SQLite 编译期 `SQLITE_MAX_VARIABLE_NUMBER` 为 999 的极端配置。
8. **`AutomationSettingsStore.pushAutoBookTargetToNative`**：`Platform.isAndroid` 为 false 时直接 return（`automation_settings_store.dart:272`），Dart 单测无法验证原生通道行为。
9. **`AutoBookTrace` 的 Zone 打点**：`AutoBookTrace.current` 依赖 `runZoned`，已在既有测试（`test/services/automation/auto_book_trace_test.dart`）覆盖，本轮未重复。
10. **`anomaly_detector` / `AutomationHealth` 的 UI 接线**（`post_processor`、状态卡）：纯展示层，本轮只测判定函数。

---

## 修复优先级建议（仅供参考，本轮未改任何 `lib/**`）

| 优先级 | 条目 | 理由 |
|---|---|---|
| P0 | A1 / A2 | 双记账直接影响账本正确性；A1 的修复（`claim` 改条件更新 `UPDATE ... WHERE state=? AND (updatedAt <= ? OR state != 'processing')`）能同时消解 A2。 |
| P0 | A6 / A11（+A7/A8/A12） | 一处 `isFinite` 守卫可同时关闭：`json_response_parser._sanitize`、`auto_book_policy.evaluate`、`semanticKey`、`hasSecondExactDuplicate`、`billFingerprint`、`BillCreationService.createFromBill`。 |
| P1 | A3 | C8 承诺的"过期占位"未兑现；无证据的 pending 是主流量路径。 |
| P1 | A4 | 历史页筛选是用户可见功能，小 limit 下必然漏记录。 |
| P1 | A10 | 外部单号判重整体失效；修复是统一 `externalKey` 调用口径（查询侧不再传/写入侧不再带 currency，或双向对齐）。 |
| P2 | A5 | 影响面是 `sourceKeysForTransaction`（跨渠道反查），修 `resolvePendingItem` 显式传清空信号或改 `mark` 的 null 语义。 |
| P2 | A13 / A14 | 加 `_serial` 链即可，模式已在 `PendingCandidateStore` 存在，可复制。 |
| P2 | A9 | 复用 `normalizeAutoBookText` 归一 note。 |
| P3 | H18 / H25 / H27 | 契约与实现/文档不一致，属"欠账"而非活跃 bug。 |
