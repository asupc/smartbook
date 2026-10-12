# SmartBook 客户端数据层 — 对抗性测试发现

> 生成日期：2026-10-11
> 测试目录：`client/test/adversarial/`
> 5 个测试文件，130 条测试，90 绿 / 40 红。
> 只读语义参照（未修改任何 `lib/**` 或既有测试）；所有红色测试保持激活。

运行方式（单文件）：

```bash
export PATH="$HOME/devtools/flutter-3.27.3-sdk/bin:$PATH"
cd /d/github/smartbook/client
flutter test test/adversarial/transaction_repo_adversarial_test.dart --reporter compact
```

---

## 0. 统计总览

| 文件 | 测试数 | 绿 | 红 |
|---|---|---|---|
| `transaction_repo_adversarial_test.dart` | 36 | 21 | 15 |
| `aggregation_adversarial_test.dart` | 28 | 23 | 5 |
| `category_tag_account_adversarial_test.dart` | 29 | 18 | 11 |
| `migration_adversarial_test.dart` | 16 | 13 | 3 |
| `concurrency_adversarial_test.dart` | 21 | 15 | 6 |
| **合计** | **130** | **90** | **40** |

红 = 确认为缺陷（`// ADVERSE FINDING:`）。其余 90 条绿里,大部分带 `// HARDENING:` 标注(行为可辩护但脆弱,断言当前行为并通过),按主题归并为 §10 的 66 条 HARDENING 条目。
全部 5 个文件连续 3 次运行结果完全一致（40 红 / 90 绿，无 flake）。

严重级定义：
- **高** = 数据损坏/丢失、启动崩溃、永久孤儿、跨设备数据不一致
- **中** = 统计口径错误、用户可见的静默行为异常、校验缺口
- **低** = 契约/一致性瑕疵、边界行为未定义

---

## 1. syncId 身份体系（根因族）

### F-01 syncId 无 UNIQUE 约束：重复行让按 syncId 的操作全部断裂 — **高**

- **证据**
  - 产品：`client/lib/data/db.dart:1505-1506`（`idx_transactions_sync_id` 非 UNIQUE，仅普通索引）；`client/lib/data/repositories/local/local_transaction_repository.dart:1885-1889`（`getTransactionBySyncId` 用 `getSingleOrNull`）
  - 测试：`A1 transactions.sync_id 无 UNIQUE 约束…`
  - 期望：同 syncId 第二行被约束拒绝，或单行读稳定返回一行
  - 实际：第二行插入成功（2 行）；`getTransactionBySyncId` 抛 `Bad state: Too many elements`；`deleteTransactionBySyncId` 同样抛错且**一行未删**（删除变更永远推不出去）
- **一句话复现**：用同一 `syncId` 连插两笔交易，再调 `repo.getTransactionBySyncId(syncId)` → StateError；调 `deleteTransactionBySyncId` → 事务无效果。

### F-02 跨账本同 syncId 无隔离 — **中**

- **证据**：测试 `A4 同 syncId 不同账本…`；产品同上
- **期望 vs 实际**：期望跨账本 syncId 互不干扰（或至少读路径可用）；实际两个账本各插一条同 syncId 后，`getTransactionBySyncId` 直接抛 `Bad state`
- **复现**：两账本各插一笔同 `syncId` 的交易，调用单行读。

### F-03 批量插入同 syncId 静默落库，关联关系错挂 — **高**

- **证据**
  - 产品：`local_transaction_repository.dart:467-476`（`insertTransactionsBatch` 直接 `insertAll`，无冲突检测）；`:500-508`（`idBySyncId[syncIds[i]]!` 以 syncId 为键反查，后行覆盖前行）
  - 测试：`F2 批量含重复 syncId…`、`F3 批量 + 关联…`
  - 期望：重复 syncId 应报冲突 / 或至少每笔保留自己的标签附件
  - 实际：两行同 syncId 均落库；**两笔的标签和附件全部挂到最后一行**（`{1: [], 2: [g1, g2]}`）
- **复现**：`insertTransactionsBatchWithRelations` 传两笔同 syncId + 各自标签 → 第一笔标签丢失，全都落到第二笔。

### F-04 并发批量重放使账目翻倍 — **高**

- **证据**：测试 `W4 并发 bulk insert 相同 syncId 集合…`
- **期望 vs 实际**：期望同批重放幂等（10 笔）；实际 20 行（distinct syncId 仍 10）——批量插入非幂等，任何重试/对账重放都会翻倍
- **复现**：同一批带 syncId 的 `TransactionsCompanion` 并发 `insertTransactionsBatch` 两次。

---

## 2. 回收站 / 删除 / 复活

### F-05 删除交易后附件行残留，恢复后标签/附件永久丢失 — **高**

- **证据**
  - 产品：`local_transaction_repository.dart:636-649`（`deleteTransaction` 只清 `transaction_tags`，不清 `transaction_attachments`）；`:660-690`（`_archiveToTrash` 的 payload 只含交易行字段，不含 tagIds/attachments）；`:775-823`（`_deleteAttachmentsForTransaction` 在 v43 路径上**已成死代码**，全仓无调用点）
  - 测试：`B1 删除交易后 attachments 行残留(未级联)…`
  - 期望：删交易的附件行一并处理；恢复能还原关联
  - 实际：`transaction_attachments` 残留 1 行（悬挂）；恢复后 `tags=0 / attachments=0`（原为 1/1）
- **复现**：给一笔交易挂标签+附件 → `deleteTransaction` → 查附件表仍有行 → `restoreDeletedTransaction` → 标签与附件都空。

### F-06 批量删除既不入回收站，也不登记 change（云端复活）— **高**

- **证据**
  - 产品：`local_transaction_repository.dart:1960-1986`（`deleteTransactionsBatchBySyncIds` 硬删主表+关联，不经墓碑）；`local_repository.dart:1289-1310`（wrapper 只给 update 补 change，不补 delete）
  - 测试：`B2 批量删除…`、`X2 单条 delete 与批量 delete 的 change 登记差异…`
  - 期望：与单条删除语义一致（进回收站 + 记 delete change）
  - 实际：墓碑 0 条（单条路径 1 条）；删两笔只登记 1 条 delete change（批量路径 0 条）→ 云端不知情，下次 pull 全部复活，本地又不可恢复
- **复现**：`repo.deleteTransactionsBatchBySyncIds([syncId])` → `listDeletedTransactions()` 为空；查 `local_changes` 无 delete 记录。

### F-07 墓碑 payload 解析分支不一致：缺字段抛 TypeError — **中**

- **证据**
  - 产品：`local_transaction_repository.dart:710-746`（`try { jsonDecode } catch { return null }` 只包住 decode；`:717` 起 `payload['ledgerId'] as int` 之类强转未受保护）
  - 测试：`B7 payload 合法 JSON 但缺 ledgerId…`
  - 期望：注释声明"找不到/已过期返回 null" —— 损坏 payload 也应返回 null
  - 实际：抛 `_TypeError: type 'Null' is not a subtype of type 'int' in type cast`，且墓碑残留（对比 B6 的非法 JSON 会安全返回 null）
- **复现**：手工插一行墓碑，`payload_json` = `{"type":"expense","amount":1}`（合法 JSON、缺 ledgerId）→ `restoreDeletedTransaction`。

### F-08 远端复活 + 本地恢复叠加 → 主表重复 syncId，后续操作全断 — **高**

- **证据**
  - 产品：`local_transaction_repository.dart:706-751`（`restoreDeletedTransaction` 不检查主表是否已有该 syncId；`_archiveToTrash` 只在**写**墓碑方向查重）
  - 测试：`B8 远端 pull 复活 + 本地 restore 叠加…`、`W2 并发两次 restore 同一墓碑…`
  - 期望：恢复前检查主表冲突；并发恢复只成功一次
  - 实际：本地删（进墓碑）→ 远端 pull 按同 syncId upsert 回主表 → 用户点恢复 → 主表 2 行同 syncId；并发两次 restore 同样写 2 行（restore 四步：读墓碑/解析/插主表/删墓碑，**不在事务里**，无互斥）
  - 后果：落入 F-01 状态 —— `getTransactionBySyncId` / `deleteTransactionBySyncId` 全抛 `Bad state`
- **复现**：`deleteTransaction(id)` → `insertTransactionCompanion(syncId 相同)` → `restoreDeletedTransaction(tombId)` → 数主表行数 = 2。

### F-09 单条删除是「先记 change 后删行」，非事务 — **中**

- **证据**：产品 `local_repository.dart:575-593`；测试 `X1 deleteTransaction 的 change 记录在主表删除之前…`
- **期望 vs 实际**：期望数据与 change 原子提交；实际两步独立，第二步失败会留下"delete change 已登记但行还在"→ 下次 push 让云端删掉本地仍存在的交易（反向下次 pull 又拉回）
- **复现**：正常路径不显形；需在 `recordLedgerChange` 与 `deleteTransaction` 之间注入失败（当前无此测试钩子，属静态分析结论 + 顺序断言）。

### F-10 `ChangeTracker.recordPulledFromServer` 并发下不幂等 — **中**

- **证据**
  - 产品：`client/lib/cloud/sync/change_tracker.dart:134-159`（注释自称"幂等：同一 (entityType, entitySyncId) 多次调用只插一次"，实现是「select then insert」，且 `local_changes` 上**没有** `(entity_type, entity_sync_id)` 唯一索引 —— 见 `db.dart:247-257`）
  - 测试：`X4 ChangeTracker.recordPulledFromServer 幂等…`
  - 期望：5 次并发调用落 1 行
  - 实际：落 5 行 —— 幂等失效（会污染 fullPush 的 legacy backfill 判断，并使 `local_changes` 膨胀）
- **复现**：`Future.wait` 并发 5 次 `recordPulledFromServer(entitySyncId: 'X')` → 计数为 5。

---

## 3. 字段语义 / 更新陷阱

### F-11 `updateTransaction` 未传的可选字段被清空（categoryId / note）— **高**

- **证据**
  - 产品：`local_transaction_repository.dart:585-612` —— `categoryId: d.Value(categoryId)`、`note: d.Value(note)` 无条件写入（`null` 即清空），而 `happenedAt`/`accountId` 走 `Value.absent()` 保护。**同一方法内两套 null 语义并存。**
  - 测试：`C1 updateTransaction 未传 categoryId/note 会被清空…`、`V5 并发 addTransactionFields + updateTransaction…`
  - 期望：未传的字段保持不变（与 `accountId` 一致）
  - 实际：分类变 null、备注变 null
  - 波及：`search_page.dart:539/612` 的批量改备注/改分类必须回填**全部**字段才不丢数据；`transfer_form.dart:234` 每次编辑转账都传 `categoryId: transferCategoryId` 掩盖了该问题
- **复现**：带分类+备注建一笔 → `updateTransaction(id, type, amount, happenedAt)`（不传 category/note）→ 两者变 null。

### F-12 无金额校验：负数支出互相抵消，负转账反转资金流 — **中**

- **证据**：产品 `local_transaction_repository.dart:437-457`（直写 amount，无 `isFinite` / `> 0` 校验）；DB 无 `CHECK(amount > 0)`（见 `migration_adversarial_test` 的 `T3`）；测试 `D3 负数金额…`
- **期望 vs 实际**：期望负数被拒或至少语义明确；实际 `expense(100)` + `expense(-100)` = 月支出 0；`transfer(-100, A→B)` 让 A 余额**增加** 100、B 余额**变负** -100（与 UI 文案完全相反）
- **复现**：插一笔 `type:'expense', amount:-100` → `monthlyTotals` 支出被抵消。

### F-13 `Infinity` 静默落库并污染全部聚合 — **中**

- **证据**：产品同上（无 `isFinite` 校验）；测试 `D1 2^53/NaN/Infinity…`
- **期望 vs 实际**：期望非有限金额被拒；实际 `Infinity` 落库成功，`monthlyTotals` 支出变 `Infinity` → 整个账本统计不可用（`NaN` 反而被 SQLite NOT NULL 意外拦下）
- **复现**：`addTransaction(amount: double.infinity)` → `monthlyTotals(...).expense` 为 `Infinity`。

### F-14 `searchTransactions(limit < 0)` 抛未捕获 `RangeError` — **中**

- **证据**：产品 `local_transaction_repository.dart:949`（`limit(limit * 2)`，-2 被 SQLite 当无上限）、`:971`（`hydrated.take(limit)` 对负 count 抛错）；测试 `G4 searchTransactions limit<0 抛 RangeError…`
- **期望 vs 实际**：期望与 `getTransactionPageWithCategory` 一致 clamp(1,400)；实际 `RangeError (takeCount): Invalid value: Not greater than or equal to 0: -1` 冒泡到调用方
- **复现**：`repo.searchTransactions(ledgerId: 1, searchText: 'kw', limit: -1)`。

### F-15 分页/搜索的 `limit` 语义三套并存 — **低**

- **证据**：`getTransactionPageWithCategory` clamp(1,400)（`:1023`）；`getRecentTransactions(limit:-1)` → SQLite 当无上限返回全部（`:1291-1303`）；`getAccountTransactions` 原样下推（`local_account_repository.dart:720-733`，`OFFSET -10` 等价 0、`LIMIT -1` 等价无上限）；`searchTransactions` 抛 RangeError
- **测试**：`D4 分页 limit <= 0 与超大 limit`、`D5 越界 offset / limit…`（均绿，钉住行为）
- **一句话复现**：`repo.getRecentTransactions(1, limit: -1)` 返回账本全部交易（而非 1 条或空）。

---

## 4. 日历 / 时区

### F-16 日历月视图在 UTC+8 下恒返回空 — **高**

- **证据**
  - 产品：`local_transaction_repository.dart:1420`（`strftime('%Y-%m-%d', happened_at, 'unixepoch', 'localtime')`）与 `:1858`（`DATE(happened_at)`）—— 两者都缺正确的 unix 秒解释；本环境 SQLite 3.51 对 `'localtime'` 返回 NULL（`aggregation_adversarial_test` 的 `E2` 显示同一仓库的 `totalsByDay` 用「epoch + 时区偏移秒」自造方案是对的）
  - 消费方：`client/lib/providers/calendar_providers.dart:23,62` → `client/lib/pages/calendar/calendar_page.dart:160-161`（主渲染 `data: (dailyTotals) => _buildCalendar(...)`）
  - 测试：`E1 日历月视图…在 UTC+8 下恒返回空…`
  - 期望：当月每天的收支与"有交易"标记
  - 实际：`getDailyTotalsByMonth` 返回空 `{}`、`getTransactionDatesByMonth` 返回空 `[]`；**同一页面的** `getTransactionsByDate(今天)` 却返回 1 笔 → 同页两入口自相矛盾
- **复现**：插一笔"今天"的交易 → `getDailyTotalsByMonth(ledgerId, 当月)` → 空 map；`getTransactionsByDate(ledgerId, 今天)` → 1 笔。

---

## 5. 统计口径跨入口不一致

### F-17 `getAccountCategoryStats` 完全不过滤 exclude flags — **中**

- **证据**：产品 `local_account_repository.dart:855-866`（SQL 只有 `account_id = ? AND type = ?` + 共享账本排除，**缺** `exclude_from_stats = 0`）；对照 `getAccountStats` 有过滤（`:282-297`）；测试 `H3 但 getAccountCategoryStats 完全不过滤…`
- **期望 vs 实际**：期望同账户的"总支出"与"分类明细合计"一致；实际 3 vs 10（多算了 2 笔标记"不计入收支"的账）
- **复现**：同账户 4 笔（1/2/3/4，其中 3、4 标 excludeFromStats）→ `getAccountStats.expense` = 3，`getAccountCategoryStats` 合计 = 10。账户详情页饼图/排行会显示被排除的账目。

### F-18 `getTagStats` 本地分支过滤 flags，共享账本分支不过滤 — **中**

- **证据**：产品 `local_tag_repository.dart:398-412`（本地分支 SQL 含 `tx.exclude_from_stats = 0`）vs `:645-686`（`_sharedTagStatsBySyntheticId` 是 Dart 循环累加，**无任何 flag 判断**）；测试 `H4 getTagStats 本地分支过滤 flags…`
- **期望 vs 实际**：同一笔带"不计入收支"标记的交易，挂本地标签算 0、挂共享标签算 300
- **复现**：插一笔 `excludeFromStats: true`、金额 300 的交易；分别挂本地标签与共享账本 override 标签 → 两次 `getTagStats` 得 0 与 300。

### F-19 `totalsByCategory` 对共享 override 行双计 — **高**

- **证据**
  - 产品：`local_statistics_repository.dart:34-51`（主查询 `GROUP BY c.id, c.name, c.icon`，**不排除** `category_id IS NULL AND category_sync_id_override IS NOT NULL` 的行 → 它们落进"未分类"桶）；`:67-94`（override 补充查询把同一批行按 synthetic id **再加一次**）
  - 测试：`K5 分类统计含 null 分类(未分类)与共享 override 分类并行`
  - 期望：合计 = 60（10 + 20 + 30）
  - 实际：合计 = **90** —— ¥30 同时计入"未分类"(50) 和"共享分类"(30)；对照同数据的另一入口 `totalsByCategoryWithHierarchy`（`GROUP BY` 带上 override 列）算出正确的 60
- **复现**：本地分类 10 + 未分类 20 + 共享 override 30 → `totalsByCategory` 合计 90，`totalsByCategoryWithHierarchy` 合计 60。

### F-20 `getNetWorthDailyBalances`（旧入口）多币种裸加，与折算版趋势不一致 — **中**

- **证据**：产品 `local_account_repository.dart:938-975`（无 `ratesToBase` 参数，直接 Σ 各币种原币）vs `:978-1018`（`getNetWorthTrendSeries` 有汇率、缺汇率整条剔除）；测试 `J5 getNetWorthDailyBalances(旧入口)多币种裸加…`
- **期望 vs 实际**：期望两个"净值趋势"入口同口径；实际 ¥1000 + $100 得 1100（裸加）vs 1720（按 7.2 折算）
- **复现**：CNY 账户 1000 + USD 账户 100 → 两入口末点分别 1100 / 1720。

### F-21 预算 `period` 列被统计层完整忽略 — **中**

- **证据**：产品 `local_budget_repository.dart:153-219`（`getBudgetUsage` 只读 `budget.type` / `budget.ledgerId`，从不读 `budget.period`）；该列在 schema（`db.dart:449`）、UI 可选、随同步传（`cloud/sync/entity_serializer.dart:190`）；测试 `L1 period=weekly/yearly 被完全忽略…`
- **期望 vs 实际**：期望"周预算 1000"按周统计（月内两周分别为 40 / 60）；实际整月合计 100 都算作本期已用
- **复现**：建 `period: 'weekly'` 的预算 → 同月两笔（7/3: 40、7/20: 60）→ `getBudgetUsage` 返回 used=100。

### F-22 预算已删分类成静默孤儿 + 孤儿扫描器覆盖缺口 — **中**

- **证据**
  - `local_budget_repository.dart:264-268`（`if (category == null) continue` 静默跳过）
  - `services/maintenance/orphan_scanner.dart` 的 `scanAll()`（`:38-64`，10 个 DB 检查项）**没有** `account_adjustments` 相关项；`orphan_record.dart` 的 `OrphanType` 枚举无该类型
  - 测试：`L4 getCategoryBudgetUsages 跳过已删分类的预算…`、`P4 孤儿扫描器不检查的悬挂…`
  - 期望：删分类时级联删预算，或至少能被扫描器发现
  - 实际：预算行留着但不出现在任何 UI 列表（用户看不到也删不掉）；`account_adjustments` 的悬挂行既不被扫描也不被清理 → **永久孤儿**
- **复现**：建分类预算 → `deleteCategory` → `getCategoryBudgetUsages` 不含它，`getAllBudgets` 仍含；删账户 → `account_adjustments` 行残留，`scanAll()` 不报。

### F-23 `getBudgetOverview` 的 `daysRemaining` 与参数 `month` 脱钩 — **低**

- **证据**：产品 `local_budget_repository.dart:235-242`（`DateTime.now()` 算剩余天数，`month` 只透传给 usage）；测试 `L7 getBudgetOverview.daysRemaining 用 now…`
- **期望 vs 实际**：期望传入历史月份时按该周期算；实际永远返回"当前周期剩余天数"，`dailyAvailable` 随之错
- **复现**：`getBudgetOverview(1, DateTime(2020, 6, 15))` → `daysRemaining` 等于当前周期剩余天数。

---

## 6. 类目 / 标签 / 账户

### F-24 类目层级循环导致整链从树里消失 — **中**

- **证据**：产品 `client/lib/data/category_node.dart:22-49`（`buildHierarchy` 只把 `level==1 || parentId==null` 当根）；`local_category_repository.dart:94-112`（`updateCategory` 不做环检测，也不联动 level）；测试 `M1 层级循环…`
- **期望 vs 实际**：期望环被拒或至少有可达性保护；实际 `A.parent=B, B.parent=A` 后两条分类都进不了树 → 分类管理页看不到、用户无法补救；但 `getUsableCategories`（只判"是否被别人当父"）仍含它们 → AI 记账仍可能选中
- **复现**：建 A、B → `updateCategory(A, parentId: B, level: 2)` + `updateCategory(B, parentId: A, level: 2)` → `buildHierarchy` 结果里都不可达。

### F-25 `updateCategory` 的 `parentId` 与 `level` 不联动 — **中**

- **证据**：产品 `local_category_repository.dart:101-111`（两个独立可选参数）；测试 `M5 updateCategory 只改 parentId 不改 level…`
- **期望 vs 实际**：期望设 `parentId` 时 `level` 联动为 2；实际仍为 1 → 该行既进 `getTopLevelCategories`（`level==1`）又同时是别人的子类，树结构自相矛盾
- **复现**：`repo.updateCategory(child, parentId: a)`（不传 level）→ 查回 level 仍 1。

### F-26 `createSubCategory` 查重不含 `parentId`：层级命名空间被压平 — **中**

- **证据**：产品 `local_category_repository.dart:70-79`（查重条件只有 `name` + `kind`）；测试 `M3 同名兄弟…`
- **期望 vs 实际**：期望"餐饮/外卖"与"交通/外卖"可共存（层级命名空间）；实际第二个被 `DuplicateNameException` 拒绝
- **复现**：`createSubCategory(parentId: p1, name: '子')` 后 `createSubCategory(parentId: p2, name: '子')` → 抛异常。

### F-27 删除父类目只删一层，孙级悬挂不可见 — **中**

- **证据**：产品 `local_category_repository.dart:123-124`（只删 `parent_id = id` 一层与自身）；测试 `M4 删除父类目…`
- **期望 vs 实际**：期望级联或把孤儿子类提升为根；实际孙级类目残留、`parentId` 指向已删行 → 树上不可见（只能靠孤儿扫描器 A7），但它的交易仍计入统计
- **复现**：建 父→子→孙 三级 → `deleteCategory(父)` → `getCategoryById(孙)` 非空且 `parentId` 悬空。

### F-28 `updateTag` / `updateAccount` 不查重，与 create 校验不对称 — **中**

- **证据**：产品 `local_tag_repository.dart:70-84`（`updateTag` 无查重）；`local_account_repository.dart:181-212`（`updateAccount` 无查重）；对照 `createTag:32-40`、`createAccount:112-120` 会抛 `DuplicateNameException`；测试 `N2 标签重名…`、`O7 账户重名…`
- **期望 vs 实际**：期望改名与新建同规则；实际改名可制造同名标签/账户 → `getTagByName`（`getSingleOrNull`）在多行时不再可靠
- **复现**：建 A、B → `updateTag(B, name: 'A')` → 两个同名标签。

### F-29 `transaction_tags` 无 UNIQUE(transaction_id, tag_id)：重复关联放大统计 — **中**

- **证据**
  - 产品：`db.dart:272-276`（关联表只有自增 id，无唯一约束）；`local_transaction_repository.dart:511` 注释明示「调用方需保证 tagIds 已去重，本方法不查重」
  - 测试：`N4 批量挂标签含重复 id…`、`N5 重复 tagId 导致的统计双计…`
  - 期望：重复 tagId 被去重（单条路径 `addTagToTransaction` 是幂等的）
  - 实际：批量路径插 2 行；`getTagStats` 用 `INNER JOIN` → 同一笔 77 元算成 **154 元**、`count` = 2
- **复现**：`insertTransactionsBatchWithRelations(..., tagIdsByIndex: {0: [tag, tag]})` → `getTagStats(tag).expense` 翻倍。

### F-30 删除账户/标签/账本不级联引用与调整记录 — **高**

- **证据**
  - 产品：`local_account_repository.dart:234-236`（`deleteAccount` 是裸 DELETE）；`account_adjustments` 无任何级联；`local_ledger_repository.dart:201-208`（`deleteLedger` 只 cascade `transactions` + `ledgers`）
  - `local_repository.dart:144-153` —— budgets 清理写在 `changeTracker == null` 的**早退分支之后**，无 tracker 时**不执行**
  - 测试：`O4 账户删除…`、`O5 账户删除后余额调整记录悬挂`、`O8 账户删除后 clearLedgerTransactions 不清调整记录`、`P9 删除账本:无 changeTracker 时 budgets 残留`
  - 期望：删除时清理/置空引用，或至少被孤儿扫描器覆盖
  - 实际：交易 `toAccountId` 悬挂（仅扫描器可修）；`account_adjustments` 残留且**扫描器无此项** → 永久孤儿；`clearLedgerTransactions` 后余额仍带调整残留（用户以为"清空账本"余额会归 initial）；无 tracker 时删账本残留预算
- **复现**：建账户+调整记录 → `deleteAccount`/`clearLedgerTransactions` → `account_adjustments` 行仍在且余额受影响；`scanAll()` 不报。无 tracker 的 repo 上 `deleteLedger(1)` → budgets 行残留。

### F-31 孤儿扫描器无语义覆盖：不检查「交易悬挂 ledger_id」 — **中**

- **证据**：`orphan_scanner.dart:38-64` 的 `scanAll()` 只有 10 个 DB 检查项（budget→ledger、attachment→tx、txTag→tx/tag、tx→account/category、category→parent、budget→category、sharedCategory→parent、tagOverride→tx）；测试 `P8 孤儿扫描器不检查…`
- **期望 vs 实际**：期望悬挂 `ledger_id` 可被发现；实际交易挂在 `ledger_id=999`（不存在）时 `scanAll()` 零命中 → 它们既不计入任何账本视图也不被清理
- **复现**：`INSERT INTO transactions (ledger_id, ...) VALUES (999, ...)` → `OrphanScanner(db).scanAll()` 无任何记录。

---

## 7. 迁移

### F-32 迁移链幂等性不一致：v15/v16/v21/v22/v27 裸 ALTER 会让库永久打不开 — **高**

- **证据**
  - 产品：`db.dart:901-902`（v15 `ALTER TABLE transactions ADD COLUMN sync_id TEXT;` 裸 SQL）、`:931-932`（v16）、`:1126-1127`（v21）、`:1147-1148`（v22）、`:1296-1297`（v27）；对照 v24 段每条都走 `_addColumnIfMissing`（`:1643-1652`），注释 `:1199-1203` 明确记录了 3.1.3→3.2.0 的同类事故
  - 测试：`S2 其它版本段…在半迁移库上会卡死`、`S3 v27(month_start_day)裸 ALTER 同样不幂等`
  - 期望：任何版本段的半迁移库都能重跑（v24 已做到）
  - 实际：模拟"ALTER 已隐式 commit、`user_version` 未更新"→ 重跑抛 `SqliteException(1): duplicate column name` → **每次启动都崩，用户只能重装**（v24 之前/之后的版本段无保护，v25 之后又恢复保护，呈"点状"覆盖）
- **复现**：建库后 `PRAGMA user_version = 14`（transactions.sync_id 已存在）→ 打开 → duplicate column；`user_version = 26`（month_start_day 已存在）→ 同样。

### F-33 `_ensureIndexes` 未覆盖 `exchange_rate_overrides`：UNIQUE 索引不自愈 — **中**

- **证据**
  - 产品：`db.dart:1491-1606` 的 `byTable` 表里**没有** `exchange_rate_overrides`；`idx_rate_override_pair` 只在 `onCreate`（`:1472-1474`）与 v28 分支（`:1307-1309`）建
  - 测试：`T1 索引:新装(onCreate) 与升级(onUpgrade) 两条路径结果一致`
  - 期望：两条路径索引集合一致（`_ensureIndexes` 的设计目标，见其文档注释 `:1479-1490`）
  - 实际：升级路径比新装**多**出 `idx_rate_override_pair` —— 它是全库唯一的 UNIQUE 索引，一旦丢失（库修复/手工操作/未来重构）不会被自愈，其它所有索引都会
- **复现**：建全量库 → `DROP INDEX idx_rate_override_pair` → 退回 38 → 重新打开 → 索引未恢复（对比任一 `idx_transactions_*` 会恢复）。

### F-34 DDL 缺少业务约束（CHECK/UNIQUE），脏数据从 SQL 层拦不住 — **中**

- **证据**：`db.g.dart:76/655/1998/2008/3083/5239/11078/11089` —— 只有 boolean 列有 `CHECK (... IN (0,1))`；`transactions.type` / `sync_id` / `amount` 无约束；测试 `T3 CHECK 约束覆盖度…`
- **期望 vs 实际**：期望关键列有约束；实际 `type=''`、`amount=-12345`、`sync_id=''` 全部可落库 —— 这是 F-01/F-12/F-13 一族的共同根因
- **复现**：裸 SQL 插 `type=''`、`amount=-12345`、`sync_id=''` → 全部成功。

---

## 8. 并发 / TOCTOU

### F-35 同名创建存在 TOCTOU：并发可绕过唯一性 — **中**

- **证据**
  - 产品：`local_account_repository.dart:112-120`（select 查重 → insert，两步之间有 await 让步点）、`local_category_repository.dart:38-47`（同模式）；DB 无 UNIQUE 兜底
  - 测试：`V6 并发创建账户…`、`V7 并发创建分类…`
  - 期望：`name` 全局唯一契约在并发下成立（1 行）
  - 实际：两个并发调用**都成功**，落 2 行同名账户/分类（errCount=0）
- **复现**：`Future.wait([createAccount(name:'X'), createAccount(name:'X')])` → 表里 2 行。

### F-36 并发删除交易 vs 挂标签：`transaction_tags` 悬挂 — **中**

- **证据**：产品 `local_tag_repository.dart:131-146`（`addTagToTransaction` 不校验 `transactionId` 是否存在）；测试 `Y4 并发加标签 + 并发删除交易…`
- **期望 vs 实际**：期望关联行要么建立要么失败；实际"先删后挂"顺序下残留 1 行指向已删交易（只有孤儿扫描器 A3 能清）
- **复现**：`Future.wait([addTagToTransaction(txId, tagId), deleteTransaction(txId)])` → 关联行可能残留。

---

## 9. 分页 / 排序契约

### F-37 列表入口缺 id tie-breaker，同时间戳顺序与分页入口相反 — **低**

- **证据**
  - 产品：`local_transaction_repository.dart:1234-1242`（`getTransactionsByLedger` 只按 `happenedAt DESC`）；同族：`watchRecentTransactions:29-37`、`getRecentTransactions:1291-1303`、`getFirstTransactionByLedger:1350-1360`、`getLastTransactionByLedger:1363-1372`、`getAccountTransactions`（`local_account_repository.dart:720-733`）、`local_account_repository.dart:674-682`
  - 对照 `getTransactionPageWithCategory:1024-1051` 有双键 `(happened_at DESC, id DESC)`
  - 测试：`G2 同时间戳行的排序契约缺失…`
  - 期望：同族入口排序口径一致
  - 实际：分页入口返回 id 降序，列表入口返回 id **升序**（SQLite 对相等键不保证顺序，属实现产物）
  - 已核实产品首页走的是分页入口的游标（`providers/home_transaction_window_provider.dart:245-260,355-370`），故当前未爆；但任何 `.first`/`.last` 或跨入口顺序比较都可能翻转
- **复现**：同 `happenedAt` 插 5 笔 → 比较 `getTransactionPageWithCategory` 与 `getTransactionsByLedger` 的 id 顺序。

### F-38 未分块的 `isIn` 入口在 id 数 > 32766 时抛 "too many SQL variables" — **中**

- **证据**
  - 产品：`local_transaction_repository.dart:832-836`（`getTransactionsByIds` 无 chunk）、`local_account_repository.dart:692-697`（`getAccountsByIds`）、`local_attachment_repository.dart:222-233`（`getAttachmentsForTransactions`）；对照已分块的 `getTagsForTransactions`（`local_tag_repository.dart:236-312`）与 `getAttachmentCountsForTransactions`（`local_attachment_repository.dart:181-203`）用 `chunkIds`（400，见 `chunk_utils.dart:13`）
  - 真实可达路径：`pages/data/export_page.dart:135,310`（该次导出的**全部**交易 id）、`cloud/sync_diff_service.dart:111`（账号 id 全集）、`services/ai/ai_bookkeeper.dart:1382`
  - 测试：`F7 getTransactionsByIds / getAccountsByIds / getAttachmentsForTransactions 未分块…`
  - 实测阈值（本环境 SQLite 3.51，`SQLITE_MAX_VARIABLE_NUMBER = 32766`）：32766 个 id 通过，32767 个抛错
  - 期望 vs 实际：期望与同仓库其它入口一致分块；实际长期用户导出 > 3.2 万笔即命中异常
- **复现**：`repo.getAttachmentsForTransactions(List.generate(40000, (i) => i+1))` → `SqliteException(1): too many SQL variables`。

---

## 10. HARDENING 清单（行为可辩护但脆弱，断言当前行为并通过）

| 编号 | 内容 | 位置 |
|---|---|---|
| H-01 | 空串 `syncId` 不被 UUID 兜底（只有 `null` 才替换）→ 一写改多行 | `local_transaction_repository.dart:446,844` |
| H-02 | `syncId` 无长度/字符校验（1MB / 含 NUL 可落库） | 同上 |
| H-03 | 回收站三轮 trash→restore→trash 墓碑不膨胀（幂等） | `:652-691` |
| H-04 | `deletedAt = epoch 0` 被当过期清理（时区解析偏 8 小时但不误判） | `:767-772` |
| H-05 | `cleanupDeletedTransactions` 用 `isSmallerOrEqualValue` → 边界日提前清理（承诺窗口实际 < 30 天） | `:767-772` |
| H-06 | 墓碑 payload 为**非法 JSON** 时安全返回 null 且保留墓碑 | `:710-716` |
| H-07 | `updateTransactionFields` 的 `absent` 保护正确（只改 `toAccountId` 不动 from 账户） | `:1306-1348` |
| H-08 | `0.001 × 100` 累计漂移 ~1e-14（可容忍） | SQL SUM + REAL |
| H-09 | 批量部分失败**整体原子回滚**（`db.transaction` 生效，0 行残留） | `:473-476` |
| H-10 | 批量显式重复主键整体回滚（不静默吞行） | 同上 |
| H-11 | 500 条批量 + 标签/附件关联按 400 分块正确 | `:480-556` |
| H-12 | keyset 分页在大量同时间戳行下不漏不重、顺序确定 | `:1016-1095` |
| H-13 | `searchTransactions` 金额子串命中按注释已降级（`note`/分类名可搜） | `:897-973` |
| H-14 | 同类目 `expense(-100)` 抵消效果确定（数值行为，非崩溃） | — |
| H-15 | 分页 `limit=0/-5` 被 clamp 到 1；`LIMIT 0` 返空 | `:1023` |
| H-16 | `monthStartDay` 越界值统计层 clamp 到 [1,28]，写路径也 clamp | `month_range.dart:16` |
| H-17 | 月窗口半开区间 `[start, end)` 正确处理月末 23:59:59 / +1s | 各统计入口 |
| H-18 | `monthStartDay=28` 时 2 月窗口与跨月归属正确 | `month_range.dart:19-41` |
| H-19 | 收支/预算/余额三类口径的 exclude flags 归属正确（月/年/日/区间/分类/账户/标签/序列 9 个入口一致） | `local_statistics_repository.dart` + 各入口 |
| H-20 | 预算用量只按 `excludeFromBudget` 过滤（符合设计 D2） | `local_budget_repository.dart:180,201` |
| H-21 | 多币种折算方向正确（`1 quote = rate base`，$10 → ¥72，非 ¥13.9/¥1.39） | `rate_math.dart:41-53` |
| H-22 | 缺该 base 的汇率组时回落 `amount`（不静默按 1.0，可被 L11 捞回） | `local_repository.dart:644-687` |
| H-23 | `invertRate` ↔ `computeNativeAmount` 方向一致（72 ± 1e-6） | `rate_math.dart:14-53` |
| H-24 | 非法/非正/缺失 rate → `computeNativeAmount` 返回 null（D5 红线守住） | `rate_math.dart:47-52` |
| H-25 | 改本位币后全量重算：同币种对齐 amount、缺汇率退化为 amount 并被 L11 检出 | `local_repository.dart:699-772` |
| H-26 | `nativeAmount = 0` 被 `COALESCE` 当有效值（不回落 amount） | 各统计 SQL |
| H-27 | 净值趋势末点 = Σ账户余额 × 汇率，与净资产卡同口径；缺汇率整条剔除并显式 `missing` | `local_account_repository.dart:978-1018` |
| H-28 | 估值账户（real_estate/loan）余额恒为 `initialBalance`，交易被忽略；负债以负数计入 | `:348-350,536-540` |
| H-29 | 成员身份加入的共享账本在余额/趋势/统计中被排除（`_kExcludeJoinedSharedLedgerSql`） | `:254-273` |
| H-30 | 空集合 / 单笔 / 1000 笔跨 12 月的月/年/全期四路径可对账 | 各统计入口 |
| H-31 | `totalsByDay` 10 年区间补全 4018 天（DST 安全，用日历日递推） | `local_statistics_repository.dart:283-292` |
| H-32 | 分类统计含「未分类」+ 本地分类 + 共享 override 三类（hierarchy 入口合计正确） | `:148-250` |
| H-33 | 父分类预算含子分类、总预算含未分类，两口径可对账 | `local_budget_repository.dart:194-215` |
| H-34 | 预算周期跟随账本 `monthStartDay`（非自然月） | `:165-168` |
| H-35 | `amount=0/负` 预算不除零（rate 恒 0） | `budget_repository.dart:11-13` |
| H-36 | `deleteCategory` 级联删直接子类（一层内正确）；同名子类合并迁移不丢交易 | `local_category_repository.dart:123,466-508` |
| H-37 | `getTransferCategory` 多条脏数据被动合并（保留 id 最小） | `local_repository.dart:1784-1858` |
| H-38 | `migrateCategoryTransactions` 不删源分类本身（调用方需自行 delete） | `:453-524` |
| H-39 | 标签删除清理 `transaction_tags` 干净（override 表按设计不清） | `local_tag_repository.dart:87-95` |
| H-40 | `addTagToTransaction` / `updateTransactionTags` 单条路径幂等（先 select 再 insert） | `:127-192` |
| H-41 | 隐藏账户仍参与余额/净值/转账（隐藏只影响 picker） | `shared_ledger_picker_filter.dart:131-133` |
| H-42 | 账户 `initialBalance` 与 `updateAccountValuation` 线性联动余额 | `local_account_repository.dart:339-358,1060-1067` |
| H-43 | 余额调整记录不进收支/预算，只进余额与净值（v42 设计） | `:1074-1145` |
| H-44 | 孤儿扫描 → 清理 → 再扫描**幂等**（A5/A6 只清引用不删交易） | `orphan_scanner.dart` + `orphan_cleaner.dart` |
| H-45 | 已推送 / `action=delete` 的 `local_changes` 不算孤儿 | `orphan_scanner.dart:483-507` |
| H-46 | 清理单条失败不阻断其余（文件类失败进 `failures`） | `orphan_cleaner.dart:31-105` |
| H-47 | 共享二级分类失父 / tag override 失主能被检出并清理 | `orphan_scanner.dart:289-343` |
| H-48 | 并发 `addAccountAdjustment`（insert-only）无 lost update | `local_account_repository.dart:1074-1099` |
| H-49 | 并发 `addTransaction` 全部落库、统计等于逐笔之和、syncId 无碰撞 | `local_transaction_repository.dart:417-457` |
| H-50 | 并发 `addTransaction` + ChangeTracker：每条都登记 change（无丢失） | `local_repository.dart:422-431` |
| H-51 | 并发 `updateTransaction` 同一笔：整行写，无交叉字段 | `:585-612` |
| H-52 | 并发 `updateAccountSortOrders` 批次整体生效无混批 | `local_account_repository.dart:700-708` |
| H-53 | 单连接下并发两次 `restoreDeletedTransaction` 仅一次成功（多连接未验证，见 §11） | `:706-751` |
| H-54 | 并发 trash + cleanup 无残留/无重复墓碑 | `:767-772` |
| H-55 | `deleteLedger` 事务完整（tx/budget/ledger_snapshot change 一并提交） | `local_repository.dart:144-222` |
| H-56 | 并发 `markPushed` + `getUnpushedCount` 不丢 change | `change_tracker.dart:178-185` |
| H-57 | 并发写后账本余额/账户余额/月统计三入口自洽；趋势末点 = Σ余额 | 各入口 |
| H-58 | 回收站删除后统计/分页/账户余额三入口均不含已删交易 | 各入口 |
| H-59 | 迁移：v21→v44 跳 23 个版本全链路补齐、旧数据不丢、v30 回填口径正确（含无账户回落账本本位币；悬挂 ledger 回落 CNY） | `db.dart:1300-1338` |
| H-60 | 半迁移库（v24 段、v34 段）可重跑幂等 | `db.dart:1195-1250,1643-1667` |
| H-61 | 迁移不重建表：pk/rowid 稳定（附件/标签/墓碑里的 int id 不失效） | 全链 SQL |
| H-62 | v36 回填只针对 `enabled=1` 行（disabled / window=NULL 不回填假窗口） | `db.dart:1415-1420` |
| H-63 | `user_version` 高于 `schemaVersion` 时静默运行（drift 不校验上界）→ 回退 App 版本后旧代码读到新列语义 | drift `db_base.dart:126-135` |
| H-64 | `idx_rate_override_pair` 是 UNIQUE，重复币对被拒（全库唯一真唯一约束） | `db.dart:1308-1309` |
| H-65 | `getAccountBalanceInLedger` 按设计含共享账本（与 `getAccountBalance` 口径有意不同） | `local_account_repository.dart:394-413` |
| H-66 | 标签/账户/分类的 `create*` 严格查重（应用层），`upsert*` 复用 | 各 create 方法 |

> 计数说明：§10 是按**主题**归并的 66 条；测试源码里 `HARDENING` 字样出现 269 次（每条测试的 reason 字符串可能含多处），对应 90 条绿色测试中带 HARDENING 标注的部分。

---

## 11. 未能验证项

1. **多连接 / 多 isolate 并发**
   所有并发测试跑在单 `NativeDatabase.memory()` 上。drift 的写操作经 `_BaseExecutor._synchronized` 串行化，因此 F-35/F-36/W2/W4 验证的是「同连接逻辑并发」。**真正生产环境的并发形态是「主连接写 + 4 条只读连接读」**（`db.dart:1737-1752` 的 `readPool: 4`）与可能的跨 isolate 写 —— 该形态下的 lost update / 读脏未在此覆盖。已实测的 TOCTOU 说明"单连接也已经漏"，多连接只会更严重，但**具体倍数与触发概率未能验证**。

2. **`H-53` 的并发恢复双写概率**
   单连接下实测已复现 2 行（`W2`），但双连接/双 isolate 下的成功窗口大小、以及真实用户触碰概率未能验证（无多连接测试脚手架）。

3. **`deleteTransaction` 非事务的失败窗口（F-09）**
   需要能在 `recordLedgerChange` 与 `deleteTransaction` 之间注入失败。当前仓库无该测试钩子，结论为「代码顺序 + 静态分析」，未做真实故障注入。

4. **`userId` / 共享账本 Editor 路径的统计口径**
   共享账本 synthetic id（`syntheticIdForSyncId` 用 `hashCode`）在极小概率下会哈希冲突 —— 注释（`shared_ledger_picker_filter.dart:25-26`）承认该风险并说明 UI 走 syncId 字符串。冲突率与后果**未构造验证**（需要特意搜索碰撞对，成本高）。

5. **`copyWith` / 序列化往返的字段丢失**
   `EntitySerializer`（`cloud/sync/entity_serializer.dart`）与 `sync_engine_apply.dart` 的 payload 字段覆盖完整性属同步域，本次未逐字段比对（只覆盖了 `recorded_at` / `currencyCode` / `override` 三个已见问题的字段）。

6. **`billingDay` / `paymentDueDay` 的 UI 消费方**
   已确认 repo 层零校验（`createAccount`/`updateAccount` 原样落库，实测 `billingDay=32` / `paymentDueDay=-1` 可通过）。这些脏值在账单生成/提醒逻辑里的实际后果（是否有后续消费方）未追完（`grep` 显示消费点集中在 `account_detail_page.dart:685,777` 的展示与 `config_export_service.dart`）。

7. **`migration_adversarial_test` 的 `T1` 阈值依赖**
   已实测 `SQLITE_MAX_VARIABLE_NUMBER = 32766`（本环境 SQLite 3.51）。**不同 Android 编译版本该上限可能更小**（`chunk_utils.dart:3-5` 的注释也说"不同 Android 编译版本上限不一"）→ 真实设备上 F-38 的触发门槛可能低至 999。

---

## 12. 缺陷按严重级汇总

| 严重级 | 编号 | 数量 |
|---|---|---|
| 高 | F-01, F-03, F-04, F-05, F-06, F-08, F-11, F-16, F-19, F-30, F-32 | 11 |
| 中 | F-02, F-07, F-09, F-10, F-12, F-13, F-14, F-17, F-18, F-20, F-21, F-22, F-24, F-25, F-26, F-27, F-28, F-29, F-31, F-33, F-34, F-35, F-36, F-38 | 24 |
| 低 | F-15, F-23, F-37 | 3 |
| 合计 | | **38** |

其中「同一根因、多点放大」的四个族：
1. **syncId 身份体系缺约束**（F-01/F-03/F-04/F-08/F-29/F-34）：DB 无 UNIQUE + 单行读用 `getSingleOrNull` + 无冲突处理 → 跨设备/重试/恢复任一环节都撞。
2. **删除路径不级联 + 非事务**（F-05/F-06/F-09/F-30/F-36）：`deleteAccount`/`deleteCategory`/`deleteLedger`/批量删交易都只清"一层"，且 change 登记与数据变更非原子。
3. **统计口径分裂**（F-17/F-18/F-19/F-20）：同仓库内多个"同一概念"入口用了不同 WHERE 子句，无共享常量/视图约束。
4. **migration 幂等点状覆盖**（F-32/F-33）：`_addColumnIfMissing` 只在 v24 及其后使用，`_ensureIndexes` 漏了 `exchange_rate_overrides`。

---

## 13. 建议修复优先级（不改代码，仅排序）

1. **F-01/F-03/F-08 + F-04** → 给 `transactions.sync_id` 加 UNIQUE（需先清历史重复行），并把单行读改成 `limit(1)` 或显式多行处理。
2. **F-32** → 把 v15/v16/v21/v22/v27 的裸 `ALTER` 全部改为 `_addColumnIfMissing`（已在 v24 有可直接复用的 helper）。
3. **F-16** → 日历两处 SQL 改用同仓库已验证的「epoch + 时区偏移秒」方案（参照 `local_statistics_repository.dart:20-22, 279-291`）。
4. **F-19** → `totalsByCategory` 主查询补 `AND t.category_sync_id_override IS NULL`（与 hierarchy 版对齐）。
5. **F-11** → `updateTransaction` 的 `categoryId`/`note` 改走 `absent` 语义（对齐 `accountId`），或拆成两个显式方法。
6. **F-05/F-06/F-30** → 引入统一的引用清理 helper（交易删除时清附件行；账户/分类/账本删除时清引用与 adjustment），并把孤儿检查项补全（`account_adjustments`、tx→ledger）。
7. **F-17/F-18** → 抽出共享的 "有效收支交易" WHERE 片段，消除四处手写复制。
8. **F-35/F-36/F-10** → 需要在 DB 层加唯一约束（`accounts.name`、`categories(name,kind)`、`tags.name`、`local_changes(entity_type,entity_sync_id)` + `transaction_tags(transaction_id,tag_id)`），并加 `CHECK(amount > 0)` / `CHECK(type IN (...))`。
