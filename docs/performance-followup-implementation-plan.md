# SmartBook 未实施性能优化详细实施计划

> 文档状态：Draft v1.0  
> 制定日期：2026-09-08  
> 适用范围：`client/` Flutter/Android、`server/` FastAPI/PostgreSQL、部署与性能验证工具  
> 上位计划：`docs/ux-performance-optimization-plan.md`  
> 本文性质：实施拆解与验收设计；本次仅制定计划，不代表批准提交代码

---

## 1. 计划目标

本文细化以下尚未完成的性能工作：

1. **M5-4：首页真正的窗口化分页**；
2. **M6-2：标签、附件明细查询优化**；
3. **M6-5 第二阶段：AI 日志可靠 outbox、图片 spool 与失败重试**；
4. **M6-6：Web 重复交易清理时展示原始记账信息并支持对比**；
5. **Android 真机与生产 PostgreSQL / 真实网络性能基准体系**；
6. **客户端产品调整项 A：移除自动记账页「最近识别记录」卡片，新增独立「自动识别记录」页面，入口移到「我的」**；
7. **客户端产品调整项 B：AI 助手移除快捷按钮横条与独立图片/语音按钮，合并为一个「+」入口并收纳全部媒体与快捷分析动作，相册置为首选**。

本轮计划要解决的不是单个“跑分”，而是建立可持续的性能边界：

- 账本有 1 万至 5 万笔交易时，首页不再一次性加载全部历史；
- 标签和附件查询只处理当前窗口，不再拼接全历史 ID；
- AI 日志写入与图片归档可恢复、可重试、可观测；
- 重复交易清理不能只看金额和时间，管理员在删除前可以对照截图、短信/通知文字等原始记账证据；
- 优化结果能在 vivo 真机、PostgreSQL 和受控网络环境中重复验证；
- 每一步都保留回滚路径，不破坏本地优先、同步和自动记账幂等契约。

---

## 2. 当前基线

截至 2026-09-08，相关现状如下：

- 首页仍订阅 `transactionsWithCategoryAll()`，会读取当前账本全部历史；
- `TransactionList` 已完成第一阶段派生缓存：相同 List 引用不会重复按日分组；
- 标签与附件仍按整份交易 ID 列表批量查询；
- 客户端已有索引 `idx_transactions_ledger_time (ledger_id, happened_at DESC)`；
- 服务端 AI 请求已复用共享 `httpx.AsyncClient`；
- AI 日志 DB/图片 I/O 已通过 `asyncio.to_thread` 移出 event loop，但响应仍等待写入完成；
- 服务端完整测试 523 项通过，客户端完整测试 778 项通过、1 项跳过；
- 尚无正式的 Android 真机性能流水线，也没有生产 PostgreSQL + 受控网络压测目录；
- Web `/admin/duplicate-transactions` 当前只返回投影中的交易字段，`DuplicateRecord` 没有原始证据关联；
- `RawBookkeepingEvidence` 以 `user_id + event_key` 唯一，当前服务端没有 transaction ↔ evidence 多对多关联；
- 原始证据 Web API 目前是用户自有的文字/元数据查看通道，客户端隐私说明明确原始截图尚未进入该通道；AI 日志图片也不能覆盖所有自动记账来源。
- 自动记账设置页当前内嵌「最近识别记录」卡片（`auto_billing_settings_page.dart` 的 `_buildScreenDecisionsCard`），展示原生过滤闸 + Dart/AI 段结局决策码，仅取最近 10 条，作为真机漏记排查入口；
- AI 对话页（`ai_chat_page.dart`）当前在输入区上方有独立的 `AIQuickCommandsBar` 快捷指令横条（财务健康分析/本月支出总结/分类占比/预算规划/异常支出/省钱贴士），输入区内有独立的「图片」「语音」「发送」三个 `IconButton`；图片/语音为二级 `showModalBottomSheet` 选择来源。

### 2.1 不在本计划内的工作

- 不改 mobile ↔ server 同步协议；
- 不改变 `sync_changes`、projection、LWW、change_id 或 ledger lock 契约；
- 不在本阶段引入远程分析 SDK；
- 不把 AI 日志明文发送到第三方监控平台；
- 不用 OFFSET 作为首页主分页方案；
- 不直接把多对多标签表 JOIN 到主交易结果中造成交易行倍增；
- 重复扫描接口保持轻量，不在扫描全库时携带原始正文或图片二进制；
- 原始证据只能通过确定性关联展示，禁止仅凭“金额 + 分钟 + 账本”做模糊自动关联；
- 原始证据属于敏感用户数据，管理员查看必须单独鉴权、审计，普通账本成员不得因为重复扫描获得证据权限；
- 删除重复交易时只删除交易与关联边，不删除仍被其它交易引用的证据或原始图片。

---

## 3. 跨任务硬约束

### 3.1 数据正确性

- 分页顺序必须固定为 `(happened_at DESC, id DESC)`；
- 同一时间戳的多笔交易不得跨页重复或漏失；
- 新交易在“最新窗口”模式下必须实时出现；
- 删除或编辑已加载交易后，窗口内数据必须收敛；
- 账本切换时必须取消旧请求，并丢弃旧 generation 的迟到结果；
- 共享账本分类、账户和标签 override 行为必须与现有全量查询一致。

### 3.2 性能

- 首页初始窗口默认不超过 80 笔；
- 单页详情查询的 SQLite bind 参数必须留足余量，禁止依赖设备编译时的超大参数上限；
- UI rebuild 不得重新执行数据库查询；
- AI outbox worker 不得在 event loop 内做 SQLAlchemy、文件复制或 fsync；
- worker 必须有限并发、有限批量和退避，不能在故障时忙循环。

### 3.3 隐私和安全

- 性能日志只记录阶段、耗时、大小、数量、状态码和匿名 ID；
- 不记录短信正文、通知正文、完整 prompt、API Key 或账单原图路径；
- AI outbox 与 spool 目录沿用服务端数据目录权限，不暴露静态下载路径；
- dead-letter 管理接口只返回计数和截断错误，不返回原始敏感 payload。

### 3.4 发布与回滚

- 首页分页至少保留一个版本的旧全量路径开关；
- AI 日志 outbox 使用环境变量开关，迁移必须是 additive；
- 任一新路径失败时均有保守 fallback，不能丢账或丢日志；
- 未经用户确认，不执行 Git commit。

---

## 4. 推荐实施顺序

| 阶段 | 内容 | 依赖 | 预计工作量 | 主要产出 |
|---|---|---|---:|---|
| P0 | 基准与埋点补齐 | 无 | 2–3 人日 | 可重复基线、数据生成器、指标字典 |
| P1 | M5-4 Repository 游标与索引 | P0 | 2 人日 | 稳定 keyset page API、query-plan 测试 |
| P2 | M5-4 首页窗口状态与 UI | P1 | 3–4 人日 | 双向加载、月份跳转、新记录提示、回滚开关 |
| P3 | M6-2 页面级标签/附件详情 | P1/P2 | 2–3 人日 | 仅对窗口 ID 查询、缓存与精准刷新 |
| P4 | M6-6 重复交易原始证据对比 | P0 + 证据关联设计 | 4–6 人日 | link/assets schema、admin compare API、Web 对比抽屉、权限审计 |
| P5 | M6-5 outbox schema 与可靠入队 | P0 | 2–3 人日 | migration、原子 spool、enqueue fallback |
| P6 | M6-5 worker、重试与运维 | P5 | 3–4 人日 | claim/lease、幂等归档、dead-letter、指标 |
| P7 | 真机与 PostgreSQL 验收 | P2/P3/P4/P6 | 3–5 人日 | 结果报告、门禁阈值、发布结论 |
| P8 | 客户端产品调整 A/B | 无 | 2–3 人日 | 自动识别记录页、AI 助手单体「+」入口、l10n、widget 测试 |

**总计：约 23–33 人日。** 其中 P1–P4 与 P5–P6 可在设计冻结后并行，P8 与 P1–P6 独立可并行，最终验收统一进入 P7。

---

# 5. M5-4：首页窗口化分页

## 5.1 当前问题

当前调用链：

```text
HomePage
  → repo.transactionsWithCategoryAll(ledgerId)
  → transactions 全账本 ORDER BY happened_at DESC
  → category/fromAccount/toAccount JOIN
  → shared-resource hydration
  → TransactionList 对全部记录分组、维护日期索引
  → 标签与附件再按全部 transactionIds 查询
```

账本越大，以下成本线性增长：

- SQLite 读取和对象构造；
- Drift stream 每次重发的数据量；
- shared-resource hydration；
- 标签、附件 ID 参数列表；
- `_flatItems`、日期索引和 Widget 状态内存；
- 新增一笔交易后全列表重发。

## 5.2 架构决策

采用 **双向 keyset window**，不用 OFFSET，也不单纯使用“不断增大 LIMIT”。

### 稳定排序键

```text
ORDER BY happened_at DESC, id DESC
```

游标：

```dart
class TransactionPageCursor {
  final DateTime happenedAt;
  final int id;
}
```

向旧记录翻页：

```sql
WHERE ledger_id = :ledger_id
  AND (
    happened_at < :cursor_time
    OR (happened_at = :cursor_time AND id < :cursor_id)
  )
ORDER BY happened_at DESC, id DESC
LIMIT :limit_plus_one;
```

向新记录翻页：

```sql
WHERE ledger_id = :ledger_id
  AND (
    happened_at > :cursor_time
    OR (happened_at = :cursor_time AND id > :cursor_id)
  )
ORDER BY happened_at ASC, id ASC
LIMIT :limit_plus_one;
```

向新查询返回前需 reverse，最终列表始终保持降序。

### 新索引

新增：

```sql
CREATE INDEX IF NOT EXISTS idx_transactions_ledger_time_id
ON transactions (ledger_id, happened_at DESC, id DESC);
```

实施要求：

- `BeeDatabase.schemaVersion` 从 40 增至 41；
- `_ensureIndexes()` 的新装与升级路径同时加入；
- 先保留旧 `idx_transactions_ledger_time` 一个版本；
- 使用 `EXPLAIN QUERY PLAN` 确认新旧方向查询均命中新索引；
- 稳定后再评估删除旧索引，避免永久写放大。

## 5.3 新数据类型与 Repository API

建议在 `client/lib/data/repositories/transaction_repository.dart` 引入统一类型，减少当前重复的长 record 声明：

```dart
typedef TransactionWithRefs = ({
  Transaction t,
  Category? category,
  Account? account,
  Account? toAccount,
});

class TransactionPage {
  final List<TransactionWithRefs> items;
  final TransactionPageCursor? firstCursor;
  final TransactionPageCursor? lastCursor;
  final bool hasNewer;
  final bool hasOlder;
}
```

新增接口：

```dart
Future<TransactionPage> getTransactionPageWithCategory({
  required int ledgerId,
  TransactionPageCursor? before,
  TransactionPageCursor? after,
  int limit = 80,
});

Stream<List<TransactionWithRefs>> watchTransactionWindowWithCategory({
  required int ledgerId,
  TransactionPageCursor? newestInclusive,
  required TransactionPageCursor oldestInclusive,
});

Future<bool> hasTransactionsInPeriod({
  required int ledgerId,
  required DateTime start,
  required DateTime end,
});
```

约束：

- `before` 与 `after` 不能同时传；
- 查询使用 `limit + 1` 判断 `hasMore`；
- page 内及跨 page 都按交易 ID 去重；
- `watchTransactionWindowWithCategory` 只 watch 已加载上下界之间的数据；
- shared category/account hydration 必须复用现有 `_hydrateSharedOverrides`，不能另写一套语义。

## 5.4 首页窗口状态

新增建议文件：

```text
client/lib/providers/home_transaction_window_provider.dart
```

状态结构：

```dart
class HomeTransactionWindowState {
  final int ledgerId;
  final int generation;
  final List<TransactionWithRefs> items;
  final TransactionPageCursor? newestCursor;
  final TransactionPageCursor? oldestCursor;
  final bool isLatestMode;
  final bool loadingInitial;
  final bool loadingNewer;
  final bool loadingOlder;
  final bool hasNewer;
  final bool hasOlder;
  final int unseenNewCount;
  final DateTime? anchorMonth;
  final Object? error;
}
```

Controller 必须提供：

```text
initializeLatest()
loadOlder()
loadNewer()
jumpToMonth(month)
refreshWindow()
returnToLatest()
retry()
```

### generation 防串账

- 每次账本切换、月份锚定或手动刷新，`generation + 1`；
- 异步查询返回时先比较 generation；
- 不匹配则直接丢弃，不得写入状态；
- dispose 时取消 Drift subscription 和 debounce timer。

## 5.5 实时更新策略

### 最新模式

- 初始读取 80 笔；
- 建立从顶部到当前最旧游标的 bounded watch；
- 新交易自动出现在顶部；
- 删除和编辑窗口内交易时，bounded watch 自动收敛；
- 新增记录不改变最旧边界，窗口可短暂增长，重新进入首页时重置为标准页大小。

### 历史锚定模式

用户跳到旧月份时：

1. 用账本 `monthStartDay` 计算目标周期 `[start, end)`；
2. 先执行 `hasTransactionsInPeriod`；
3. 无记录时显示目标月份空状态，不错误跳到相邻月份；
4. 有记录时以 `end` 为上边界加载第一页；
5. 列表顶部允许 `loadNewer`，底部允许 `loadOlder`；
6. 新交易到达时不直接插入并打断历史阅读，而是增加“有 N 条新记录”提示；
7. 点击提示或首页“回到顶部”动作时调用 `returnToLatest()`。

## 5.6 `TransactionList` 改造

新增参数：

```dart
final bool hasOlder;
final bool hasNewer;
final bool loadingOlder;
final bool loadingNewer;
final VoidCallback? onLoadOlder;
final VoidCallback? onLoadNewer;
```

建议实现：

- 使用 `NotificationListener<ScrollNotification>`；
- `extentAfter < 600px` 时预取旧页；
- 历史锚定模式下 `extentBefore < 300px` 时预取新页；
- controller 内部必须有 in-flight guard，避免一次滚动触发多次；
- `_flatItems` 增加 `topLoader`、`bottomLoader`、`retry` 项；
- 增加 `_transactionIndexMap`，以交易 ID 恢复锚点；
- 向顶部 prepend 新页前记录当前首个可见交易 ID；
- state 更新后跳回该 ID，避免列表视觉跳动。

## 5.7 常驻窗口上限

第一版设置：

```text
pageSize = 80
prefetchThreshold = 20 items / 600px
maxResidentPages = 12
maxResidentTransactions ≈ 960
```

超过上限时：

- 只淘汰距离当前可见锚点最远的完整 page；
- 淘汰前记录可见交易 ID；
- 淘汰后恢复该 ID 的屏幕位置；
- 被淘汰方向保留 `hasNewer/hasOlder=true`，可再次加载；
- 不按单条淘汰，避免日期分组被切碎。

如果锚点恢复在 vivo 真机上不稳定，首个版本可暂不启用淘汰，但必须保留计数指标并设置 2,000 笔硬告警；不能静默退化回全历史常驻。

## 5.8 Splash 缓存兼容

现有 `cachedTransactionsProvider` 继续承担首帧占位：

1. 页面先展示缓存的最近交易；
2. window controller 完成第一页后按 ID 替换；
3. 不把 Splash 缓存计入分页游标；
4. 账本切换立即清空旧缓存；
5. 第一页失败时可继续展示缓存，但必须显示“数据可能不是最新”与重试入口。

## 5.9 实施步骤

### M5-4A：查询与索引

- [ ] 定义 `TransactionWithRefs`、cursor、page 类型；
- [ ] 新增 `(ledger_id, happened_at DESC, id DESC)` 索引；
- [ ] 实现 older/newer page 查询；
- [ ] 实现 bounded window watch；
- [ ] 复用 shared hydration；
- [ ] 增加 query-plan 测试。

### M5-4B：状态控制器

- [ ] latest 初始化；
- [ ] older/newer 双向加载；
- [ ] generation 丢弃迟到结果；
- [ ] page 合并与 ID 去重；
- [ ] 月份 anchor 与空月份；
- [ ] 新记录提示；
- [ ] 错误与 retry 状态。

### M5-4C：UI 接入

- [ ] HomePage 移除全历史 `StreamBuilder`；
- [ ] TransactionList 接入双向 loader；
- [ ] 顶部锚点恢复；
- [ ] 首页 scroll-to-top 与 return-to-latest 对齐；
- [ ] 账本切换清理；
- [ ] 增加旧全量路径 feature flag。

### M5-4D：内存窗口

- [ ] page 边界记录；
- [ ] 12 页上限；
- [ ] 淘汰与重新加载；
- [ ] 可见位置恢复真机验证。

## 5.10 测试清单

### Repository

- 同 `happenedAt` 的 200 笔交易跨 3 页无重复、无漏项；
- older/newer 往返后 ID 集合一致；
- 插入、删除、修改时间后 bounded watch 正确收敛；
- 空账本、少于一页、恰好一页、`limit + 1`；
- 多账本相同 syncId 不串数据；
- shared category/account override 与旧查询结果一致；
- `EXPLAIN QUERY PLAN` 命中 `idx_transactions_ledger_time_id`。

### Controller

- 快速切换账本时旧请求结果被 generation 丢弃；
- loadMore 连续触发只产生一次 SQL；
- 网络同步插入新交易时 latest 模式实时出现；
- 历史模式只增加 unseen count，不改变可见锚点；
- 月份无记录显示空状态；
- prepend 新页后当前可见交易位置不跳；
- 超 12 页后淘汰方向可重新加载。

### Widget

- loading、error、retry、hasMore 状态；
- 隐藏金额/主题 rebuild 不触发重新查询；
- 月份选择、滚动月份检测和 monthStartDay 15/28；
- 首页回顶在历史模式下先恢复 latest；
- 1,000 笔窗口滚动无 RangeError 或重复 Key。

## 5.11 验收门槛

| 指标 | 门槛 |
|---|---:|
| 首页初始 DB 行数 | ≤ 81（含 hasMore 探针） |
| 10k/50k 数据集初始常驻交易 | ≤ 80，缓存合并后 ≤ 100 |
| 首页初始查询 P95（vivo 中端机） | ≤ 80ms |
| 加载下一页 P95 | ≤ 100ms |
| 无关 rebuild 的 page SQL 次数 | 0 |
| 同时间戳跨页重复/漏项 | 0 |
| 历史模式新交易导致位置跳动 | 0 次 |
| 常驻交易硬上限 | ≤ 960（正式启用淘汰后） |

---

# 6. M6-2：标签与附件查询优化

## 6.1 架构决策

**先分页，后详情。** 不应先把当前全历史查询“优化得更快”，然后继续一次性加载 5 万笔。

主交易页只返回：

- transaction；
- category；
- from account；
- to account。

标签和附件作为当前 page/window 的辅助详情加载。

### 为什么不直接 JOIN 标签

`transaction_tags` 是多对多关系，一笔交易多个标签会让主交易行倍增：

```text
80 transactions × 平均 3 tags = 240 joined rows
```

随后还要在 Dart 中重新去重，且 shared tag override 会再增加一套 union 逻辑。因此主查询不直接 JOIN 标签。

### 附件 count 的两阶段方案

第一阶段使用 page ID 的聚合查询：

```sql
SELECT transaction_id, COUNT(*)
FROM transaction_attachments
WHERE transaction_id IN (...当前页 IDs...)
GROUP BY transaction_id;
```

第二阶段仅在基准证明有收益时，评估把附件 count 改为带索引的 correlated subquery 或 grouped subquery。没有基准前不为了“单 SQL”牺牲 Drift 类型安全和可维护性。

## 6.2 新详情数据结构

建议：

```dart
class TransactionAuxData {
  final List<Tag> tags;
  final int attachmentCount;
}

class TransactionDetailsBatch {
  final Map<int, TransactionAuxData> byTransactionId;
}
```

Repository API：

```dart
Future<TransactionDetailsBatch> getTransactionDetailsBatch(
  List<TransactionWithRefs> transactions,
);
```

传完整 transaction row 而不只传 ID，是因为 shared tag override 需要 `transaction.syncId`，可避免再查一遍 transactions 表。

## 6.3 查询策略

对一个 80 笔 page：

1. 本地标签：`transaction_tags JOIN tags`；
2. shared override：`transaction_tag_overrides JOIN shared_ledger_tags`；
3. 附件数量：`transaction_attachments GROUP BY transaction_id`；
4. 合并成 `Map<int, TransactionAuxData>`；
5. 未命中项写入空对象，避免列表逐行 fallback 查询。

### SQLite 参数限制

- 新分页路径单次最多 80 个 transaction ID；
- 通用 Repository 仍必须支持更大列表；
- 统一常量 `_sqliteBindChunkSize = 400`；
- `getTagsForTransactions`、`getAttachmentCountsForTransactions` 和 shared syncId 查询均按 chunk 执行；
- 合并结果时保证 tag 不重复、附件 count 不被覆盖。

400 的原因：

- 低于常见 SQLite 999 bind 限制；
- 给 ledgerId、时间边界和其它参数留空间；
- 不依赖不同 Android SQLite 编译版本的高上限。

## 6.4 索引审计

现有索引：

```text
idx_transaction_tags_transaction(transaction_id)
idx_transaction_tags_tag(tag_id)
idx_attachments_transaction(transaction_id)
TransactionTagOverrides PK(transaction_sync_id, tag_sync_id)
```

实施时必须验证：

- 本地 tag query 命中 `idx_transaction_tags_transaction`；
- attachment count 命中 `idx_attachments_transaction`；
- override query 使用复合主键前缀 `transaction_sync_id`；
- shared tag 的 `sync_id` 查询有唯一键或索引；
- 如果 query plan 显示 table scan，再新增索引，禁止凭直觉堆索引。

## 6.5 缓存和刷新

详情缓存放在 `HomeTransactionWindowState` 或独立 controller 中：

```dart
Map<int, TransactionAuxData> detailsById
Set<int> loadingDetailIds
```

规则：

- 每次 page 加载只查询新进入窗口且缓存未命中的 ID；
- page 淘汰时同步淘汰对应详情；
- 标签或附件变化时只刷新受影响交易；
- 若现有刷新信号只有全局 version，第一阶段只刷新“当前窗口 ID”，不能回到全历史；
- 后续把 `tagListRefreshProvider` / `attachmentListRefreshProvider` 扩展为携带 transactionId 的事件；
- 同一交易的并发详情加载合并为一个 Future。

## 6.6 `TransactionList` 接口收敛

当前组件同时接收：

```text
transactions
transactionsWithDetails
```

分页完成后建议改为：

```dart
final List<TransactionWithRefs> transactions;
final Map<int, TransactionAuxData> detailsById;
```

收益：

- 不再维护 `_usePreloadedData` 双模式；
- 不再由 Widget 发数据库请求；
- Splash 和正式窗口使用同一个 details map；
- Widget 变为纯渲染组件；
- 详情刷新不会触发交易 page 重查。

迁移分两步：

1. 先新增 `detailsById`，保留旧参数兼容；
2. Home、分类、标签等调用方迁移完成后删除旧双模式代码。

## 6.7 实施步骤

### M6-2A：安全修复

- [ ] 增加 400 项 chunk helper；
- [ ] 现有 tags/attachments/shared override 查询全部使用 chunk；
- [ ] 增加 >999 ID 回归测试；
- [ ] 增加 query-plan 断言。

### M6-2B：页面详情 API

- [ ] 定义 `TransactionAuxData`；
- [ ] 实现三类 batch query；
- [ ] 保留 shared synthetic Tag ID 语义；
- [ ] page controller 合并详情；
- [ ] 空详情也缓存。

### M6-2C：Widget 纯渲染

- [ ] TransactionList 移除主动 `_loadTags()`；
- [ ] 移除主动 `_loadAttachmentCounts()`；
- [ ] 接入 `detailsById`；
- [ ] 保持附件点击、标签点击和编辑行为不变。

### M6-2D：精准刷新

- [ ] AttachmentService 发出 transactionId；
- [ ] 标签编辑链路发出受影响 transactionId；
- [ ] controller 仅刷新对应详情；
- [ ] sync 批量变化时 debounce 后刷新当前窗口。

## 6.8 测试与验收

### 测试

- 1,200 个 transaction IDs 不触发 SQLite “too many SQL variables”；
- chunk 边界 0/1/399/400/401/1,200；
- 本地标签 + shared override 标签同时存在；
- 多标签不造成交易重复；
- 附件 0/1/N 数量正确；
- 删除附件后仅对应交易 count 变化；
- page 淘汰后详情缓存同步释放；
- 快速重复刷新不会让旧 Future 覆盖新结果。

### 验收门槛

| 指标 | 门槛 |
|---|---:|
| 首页初始标签查询 ID 数 | ≤ 当前窗口交易数 |
| 首页初始附件查询 ID 数 | ≤ 当前窗口交易数 |
| 10k/50k 数据集详情查询 SQL 数 | 固定 3–5 条，不随总历史增长 |
| 80 笔 page 详情加载 P95（vivo 中端机） | ≤ 50ms |
| 标签导致的主交易重复行 | 0 |
| SQLite 参数超限 | 0 |
| 无关交易详情被重查 | 0 |

---

# 7. M6-5 第二阶段：可靠 AI 日志 Outbox 与图片 Spool

## 7.1 目标

当前 `asyncio.to_thread` 已解决 event loop 阻塞，但仍存在：

- 响应尾部等待 DB commit / 图片写盘；
- 写入失败只记录 server error，不能自动重试；
- 进程在关键时刻退出可能丢日志；
- 图片归档与日志行创建没有显式状态机；
- 没有 backlog、最老任务年龄和 dead-letter 指标。

第二阶段目标：

```text
请求 → 持久化 enqueue → 返回
                    ↓
             worker claim/lease
                    ↓
        图片归档 + final AIAnalysisLog
                    ↓
            done / retry / dead
```

## 7.2 数据模型

当前 Alembic head 为 `0024_tx_created_at`。建议新增：

```text
0025_ai_analysis_log_outbox.py
```

### 新表 `ai_analysis_log_outbox`

建议字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | String(36), PK | UUID，亦用于确定性图片文件名 |
| `user_id` | FK users.id | 用户隔离，删除用户时级联 |
| `payload_json` | Text | 不含图片二进制的最终日志字段 |
| `image_spool_path` | String(512), nullable | spool 文件绝对路径 |
| `image_mime` | String(64), nullable | 白名单 mime |
| `state` | String(16) | pending / processing / retry / dead |
| `attempt_count` | Integer | 已执行次数 |
| `next_attempt_at` | DateTime(tz) | 下次可领取时间 |
| `lease_owner` | String(64), nullable | worker/进程实例 ID |
| `lease_expires_at` | DateTime(tz), nullable | 崩溃恢复租约 |
| `last_error` | Text, nullable | 截断后的错误类型与信息 |
| `created_at` | DateTime(tz) | 入队时间 |
| `updated_at` | DateTime(tz) | 状态更新时间 |

索引：

```text
(state, next_attempt_at, created_at)
(user_id, created_at DESC)
(lease_expires_at)
```

### `ai_analysis_logs` 新增字段

```text
source_outbox_id String(36), nullable, unique
```

用途：

- worker 重试时防止重复生成最终日志；
- 支持排查一条最终日志来自哪个 outbox；
- 旧日志保持 null，不需要 backfill。

## 7.3 状态机

```text
pending ──claim──> processing ──success──> 删除 outbox / final log 已存在
   │                    │
   │                    ├─ transient ──> retry
   │                    └─ permanent / attempts exhausted ──> dead
   │
   └─ enqueue 后等待

processing --lease expired--> retry
retry --next_attempt_at reached--> processing
```

建议退避：

```text
5s → 30s → 2m → 10m → 1h → 6h
```

- 最大尝试次数：10；
- lease：60 秒，图片大文件场景可配置到 120 秒；
- 每批：20 条文本或 5 条带图任务；
- worker 空闲轮询：1 秒；有 backlog 时立即继续下一批；
- 所有参数放入 Settings，带合理上限。

## 7.4 原子入队协议

### 文本日志

1. 对输入输出执行现有 50k/100k 截断；
2. 生成 outbox UUID；
3. 在独立 Session 中 INSERT pending row；
4. commit 成功后返回；
5. commit 失败时 fallback 到现有同步 final writer，并增加 fallback metric。

### 带图日志

目录建议：

```text
{data_dir}/ai-log-spool/
{ai_log_image_dir}/
```

步骤：

1. 校验 mime 与大小；
2. 写 `{outbox_id}.tmp`；
3. 可配置是否 `flush + fsync`；
4. `os.replace(tmp, {outbox_id}.ready)` 原子改名；
5. INSERT outbox row 指向 `.ready`；
6. DB INSERT 失败时删除 `.ready`；删除失败交给 orphan sweeper；
7. 入队成功后响应可以结束。

禁止：

- 文件名使用用户输入；
- 先写 pending DB、后慢慢写文件而不区分 staging；
- 把 base64 图片放进 `payload_json`；
- 用内存 `asyncio.Queue` 作为唯一队列。

## 7.5 Worker claim 与多进程

必须兼容 PostgreSQL 和开发 SQLite。

推荐 claim 流程：

1. 查询少量 eligible IDs；
2. 用条件 UPDATE 设置 `processing + lease_owner + lease_expires_at`；
3. commit；
4. 按 lease_owner 重新读取本 worker 成功领取的行；
5. 在 DB 事务外执行文件 I/O；
6. 每条完成后使用短事务写 final log 并删除 outbox。

PostgreSQL 可优先使用：

```sql
SELECT ... FOR UPDATE SKIP LOCKED
```

SQLite 分支使用短写事务和条件 UPDATE。二者必须共用相同的状态机测试，不能让 SQLite 开发环境走完全不同的业务语义。

## 7.6 图片归档幂等

最终图片名改为：

```text
{source_outbox_id}.{ext}
```

而不是依赖自增 log ID。这样可处理以下崩溃窗口：

- spool 已移动、DB 尚未 commit；
- final log 已存在、worker 重试；
- outbox lease 过期被另一个 worker 领取。

归档流程：

1. 如果 final 文件不存在且 spool 存在，`os.replace(spool, final)`；
2. 如果 final 已存在，视为文件步骤已完成；
3. 如果两者都不存在，进入 retry；
4. INSERT final log 时带 `source_outbox_id`；
5. unique conflict 时读取既有 final log，视为幂等成功；
6. final log INSERT 与 outbox DELETE 在同一 DB 事务提交。

## 7.7 Worker 生命周期

新增建议文件：

```text
server/src/services/ai/analysis_log_outbox.py
server/src/services/ai/analysis_log_worker.py
```

FastAPI 生命周期：

- startup：恢复过期 lease，启动 worker task；
- shutdown：设置 stop event；
- 最多等待 5 秒完成当前短批次；
- 超时后取消 task，未完成 row 等 lease 过期后恢复；
- worker DB、文件 I/O 全部经 `asyncio.to_thread`；
- 不使用请求 Session；
- worker 异常不得导致 FastAPI 进程退出。

## 7.8 路由切换

现有调用点：

```text
routers/ai/ask.py
routers/ai/parse_tx_image.py
routers/ai/relay.py
```

改造顺序：

1. 新增 `enqueue_ai_analysis_log[_with_image]`，旧 writer 保留；
2. 单测直接验证 enqueue row 和 spool；
3. worker 单测验证最终归档；
4. 设置 `AI_LOG_OUTBOX_ENABLED=false` 默认部署一版；
5. 开启后路由切换为 enqueue；
6. enqueue 失败自动 fallback 同步 writer；
7. 稳定一个版本后再考虑移除旧 async wrapper。

## 7.9 运维与可观测性

新增指标：

```text
smartbook_ai_log_outbox_enqueued_total{kind}
smartbook_ai_log_outbox_delivered_total{kind}
smartbook_ai_log_outbox_retry_total{kind}
smartbook_ai_log_outbox_dead_total{kind}
smartbook_ai_log_outbox_fallback_total{kind}
smartbook_ai_log_outbox_pending
smartbook_ai_log_outbox_oldest_age_seconds
smartbook_ai_log_spool_bytes
```

管理能力：

- admin 只读状态接口：pending/retry/dead 数量、最老年龄；
- dead-letter 列表只显示 ID、类型、attempt、时间和截断错误；
- admin 可 retry 单条或一批；
- 不在管理接口返回完整 input/output；
- backlog 超阈值时 `/metrics` 可告警，但不让 `/ready` 直接失败。

清理任务：

- 删除无 outbox、无 final log 引用且超过 24h 的 spool/orphan 文件；
- 删除成功后残留的 `.tmp`；
- dead row 默认不自动删，保留人工处理；
- 用户删除账号时，级联删 row，并由 sweeper 清理文件。

## 7.10 故障注入测试

必须覆盖以下进程死亡点：

1. 图片 `.tmp` 写了一半；
2. `.ready` 已生成，outbox INSERT 前；
3. outbox 已 commit，worker claim 前；
4. claim 后、图片 move 前；
5. 图片 move 后、final log commit 前；
6. final log commit 后、outbox delete 前；
7. worker 持 lease 时进程退出；
8. PostgreSQL 暂时不可用；
9. spool 目录只读或磁盘满；
10. 两个 worker 同时领取同一批。

验收断言：

- 最终日志最多一条；
- 可恢复故障最终能生成日志；
- 永久故障进入 dead，不忙循环；
- 原图最多一份；
- 无未引用文件永久增长；
- fallback 不影响 AI 主响应结果。

## 7.11 验收门槛

| 指标 | 门槛 |
|---|---:|
| 故障注入丢日志 | 0 |
| 重试导致重复最终日志 | 0 |
| 空闲 worker CPU | 接近 0，禁止忙循环 |
| 20 并发下 event loop lag P95 | ≤ 50ms |
| 文本 enqueue P95（PostgreSQL） | ≤ 20ms |
| 1MB 图片 durable spool + enqueue P95 | ≤ 100ms，最终以部署磁盘基线校准 |
| 正常 backlog 最老年龄 | ≤ 5s |
| dead row 未告警 | 0 |
| shutdown 后遗留 processing lease | 可在 lease 到期后自动恢复 |

---

# 8. M6-6：Web 重复交易清理的原始记账信息对比

## 8.1 需求定义

当前管理员重复交易清理页 `/admin/duplicate-transactions` 通过“同账本 + 同金额 + 同分钟”
发现候选，并展示备注、类型、账户、分类、标签和记录时间。这个结果足以定位“看起来相同”的
交易，但不足以判断哪一笔是可信来源：

- 一笔可能来自短信，另一笔来自支付通知；
- 一笔可能来自截图 OCR，另一笔来自屏幕文本 OCR；
- 同一张截图可能解析出多笔交易；
- AI 识别结果可能有误，备注已经被归一化，无法还原原始输入；
- 原始证据可能已过期、用户关闭了服务端留存，或从未上传。

新增调整项的目标是：**管理员在勾选删除前，可以打开某个重复组，逐笔并排查看交易快照和
原始记账证据（截图、短信/通知文字、屏幕文字、来源元数据），再决定保留或删除；扫描和
删除主流程保持轻量、可回滚。**

## 8.2 产品交互方案

### 8.2.1 列表页保持轻量

`GET /admin/duplicate-transactions` 继续只返回重复分组和交易摘要，不返回：

- 原始正文全文；
- 图片 base64 或图片二进制；
- 完整 AI prompt / completion；
- 未授权用户的邮箱、手机号或其它个人资料。

每个交易行增加“查看原始记账”按钮；每个重复组增加“对比保留项与重复项”按钮。
只有用户主动打开对比抽屉时才加载证据。

### 8.2.2 默认对比方式

采用“**保留项 vs 当前重复项**”的双栏对比，而不是一次展开所有正文：

1. 默认左栏为 `is_keeper=true` 的交易；
2. 默认右栏为用户点击的非 keeper 交易；
3. 组内有三笔以上时，可在顶部切换任意两笔；
4. 仍保留“查看全部证据”入口，显示每笔交易的证据数量和来源徽标；
5. 对比抽屉中的删除勾选状态与列表页共享，但查看证据不自动改变删除选择。

建议使用 antd `Drawer`（宽屏双栏、窄屏上下排列），避免跳转页面导致扫描结果和勾选状态丢失。

### 8.2.3 交易侧展示字段

每一栏分为“已落库交易”和“原始输入”两块。

**已落库交易：**

- 金额、币种；
- 交易类型（收入/支出/转账）；
- 发生时间与服务端记录时间；
- 账户、转入账户、分类、标签；
- 备注；
- 创建者（只显示脱敏用户标识或角色，不默认显示邮箱）；
- keeper / 待删除状态；
- `source_change_id`、`sync_id` 等技术字段放进可展开的“诊断信息”，默认折叠。

`DuplicateRecord` 当前缺少币种、转入账户、创建者和证据状态，需扩展为摘要字段；这些字段
仍不得携带原始正文。

### 8.2.4 原始证据侧展示字段

证据卡片按 `captured_at` 倒序排列，显示：

- 来源：截图、短信、通知、屏幕文本、分享图片、深链、导入等；
- 来源渠道/应用包名/发送者（如有）；
- 原始标题；
- 原始正文：先显示截断预览，点击后加载全文；支持复制，但不在列表页展开；
- 发生时间、捕获时间和过期时间；
- 外部流水号/订单号（按现有脱敏规则展示）；
- 内容 hash 短指纹，用于判断两条证据是否相同；
- metadata 的白名单键值（禁止直接渲染任意 JSON HTML）；
- 图片数量、mime、大小、宽高和“查看原图”操作。

证据状态必须区分：

```text
available       已关联且可读取
none            没有原始证据
not_linked      有证据记录但尚未与交易确定关联
expired         证据已过期
not_retained    捕获时未开启服务端留存
asset_missing   文字存在但图片文件缺失
loading/error   正在加载 / 暂时加载失败
```

“没有证据”和“证据不可访问”不能都显示成空白，否则管理员会误以为这笔交易是手动录入。

### 8.2.5 截图展示策略

- 图片通过鉴权 blob endpoint 获取，不能把服务器绝对路径拼到前端；
- 对比抽屉打开时只请求图片元数据；用户点击缩略图后才请求原图；
- 浏览器端使用 `URL.createObjectURL`，组件卸载或切换证据时 `revokeObjectURL`；
- 默认限制预览区域尺寸，使用 `object-fit: contain`，不把 5–10MB 原图直接塞进列表 DOM；
- 支持放大和下载时再次校验管理员权限；
- `Cache-Control: private, no-store`，不允许 CDN 或浏览器共享缓存跨用户复用；
- 原图读取失败只影响图片，不影响文字证据和交易删除操作。

第一版不强制引入图片缩略图处理库；如果真机/浏览器基准显示原图解码明显拖慢，第二阶段再增加
服务端缩略图或 `thumbnail_path`，不要在 API 响应中返回 base64。

## 8.3 当前数据缺口与关联原则

### 8.3.1 当前无法直接 JOIN 的原因

现有数据分成三条独立链路：

1. `ReadTxProjection`：重复扫描的交易读模型，键为 `(ledger_id, sync_id)`；
2. `RawBookkeepingEvidence`：原始自动记账证据，唯一键为 `(user_id, event_key)`；
3. 客户端 `AutoBookEvents` / `AutoBookEventItems`：本地事件和子项，保存 `transactionId`，但不参与
   服务端同步。

因此服务端当前不知道“某一笔 projection 交易对应哪个 event_key”。不能用金额、分钟、备注或
`source_change_id` 猜测关联：同一重复组恰好会让这些字段高度相似，误关联后会把错误截图展示
给管理员。

### 8.3.2 采用多对多关联表

不把 `event_key` 直接塞进 transaction sync payload，也不把证据正文复制到
`ReadTxProjection`。原因：

- 一个自动事件可以解析出多笔交易；
- 一笔交易可能同时有短信、通知、截图多份证据；
- 原始证据是 display-only 数据，不应进入 `sync_changes`；
- 避免改变 mobile ↔ server 交易同步协议和全量快照格式；
- 删除交易时可以只删除关联边，保留用户证据和其它交易的关联。

### 8.3.3 历史数据策略

第一版只展示**确定性关联**的证据：

- 新客户端上传证据时提供 transaction sync id；
- 已上传证据通过显式 link endpoint 补关联；
- 若旧记录只有 event_key、没有 transaction link，显示 `not_linked`；
- 禁止上线一个“按金额 + 时间自动回填全部旧数据”的脚本；
- 如确有运营需要，再做仅供管理员使用的人工关联工具，并保存关联来源和操作审计。

这样会导致旧数据覆盖率不是 100%，但不会用错误证据污染清理决策。页面应在摘要处显示
“已关联 X 条 / 未关联 Y 条”，让覆盖率可度量。

## 8.4 服务端数据模型

当前 Alembic head 是 `0024_tx_created_at`。M6-5 已规划占用 `0025_ai_analysis_log_outbox.py`，
本调整项建议使用后续 revision；不要修改已经发布的 migration。

### 8.4.1 `raw_evidence_transaction_links`

建议新增 `0026_raw_evidence_transaction_links.py`：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | String(36), PK | UUID |
| `evidence_id` | FK `raw_bookkeeping_evidence.id` | 原始证据 |
| `user_id` | FK `users.id` | 冗余存储，便于权限和索引过滤 |
| `ledger_id` | String(128) | ledger external id；避免跨账本 sync id 歧义 |
| `transaction_sync_id` | String(255) | projection 交易 sync id |
| `event_item_index` | Integer, nullable | 同一事件解析多笔账单时的子项索引 |
| `link_source` | String(16) | `client` / `admin` / `backfill` |
| `created_at` | DateTime | 关联建立时间 |

约束和索引：

```text
UNIQUE(evidence_id, ledger_id, transaction_sync_id)
INDEX(ledger_id, transaction_sync_id)
INDEX(evidence_id)
INDEX(user_id, created_at DESC)
```

`transaction_sync_id` 不是普通用户输入；服务端必须重新查询 projection 验证交易属于指定账本，
并检查 evidence/user/ledger 的归属一致性。不要依赖客户端传来的 `user_id`。

### 8.4.2 `raw_evidence_assets`

建议新增 `0027_raw_evidence_assets.py`，把图片与文字行分开存储：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | String(36), PK | 资源 ID |
| `evidence_id` | FK | 所属原始证据 |
| `kind` | String(16) | 第一版为 `image`，为后续 PDF/audio 预留 |
| `mime_type` | String(64) | JPEG/PNG/WebP/GIF 白名单 |
| `storage_path` | String(512) | 服务端内部路径，不下发前端 |
| `size_bytes` | BigInteger | 原图大小 |
| `sha256` | String(64) | 去重与完整性校验 |
| `width` / `height` | Integer, nullable | 若能低成本读取则保存 |
| `created_at` | DateTime | 上传时间 |
| `expires_at` | DateTime, nullable | 与 evidence retention 对齐 |

约束：

```text
UNIQUE(evidence_id, sha256)
INDEX(evidence_id, created_at)
```

如果实现阶段确认每个 event 永远只有一张图，可以把 asset 字段收敛到
`raw_bookkeeping_evidence`；但默认采用独立表，避免下一次扩展多图时再次迁移核心证据表。

### 8.4.3 API schema 扩展

`DuplicateRecord` 增加轻量字段：

```text
currency_code
from_account_name / to_account_name
created_by_user_id_masked
raw_evidence_count
raw_evidence_status
attachment_count
```

`RawEvidenceOut` 增加：

```text
transaction_links: [{ ledger_id, transaction_sync_id, event_item_index }]
assets: [{ id, kind, mime_type, size_bytes, sha256, width, height }]
```

原始正文仍通过详情接口按需返回；列表/扫描 response 不包含 `body` 全文和 `storage_path`。

## 8.5 客户端证据关联和截图上传

### 8.5.1 新事件成功后的 link 时机

客户端已有：

- `AutoBookEvents.transactionId`；
- `AutoBookEventItems.transactionId`；
- `transactions.syncId`；
- `RawEvidenceEnvelope.fromEvent()`；
- `SmartBookRawEvidenceUploader` 的独立证据上传通道。

改造为：

1. 交易成功落库后，按 event item 查询本地 transaction 的 `syncId`；
2. 查询对应账本的 external `syncId`；
3. 在证据 upsert 中附带 `transaction_links`；
4. 同一事件多笔交易时附带多个 link，并传 `event_item_index`；
5. 一笔交易多个来源时写入多个 evidence link；
6. 证据先上传、交易后落库时，保留本地待关联操作，稍后调用 link endpoint；
7. link endpoint 成功后才把本地 link 状态标记完成。

不能把本地整数 `transactionId` 直接发给服务端，也不能因为原始证据上传成功就假定交易已关联。

### 8.5.2 API 设计建议

保留现有 JSON evidence upsert 的兼容行为，新增可选字段：

```json
{
  "event_key": "...",
  "source": "screenshot",
  "transaction_links": [
    {
      "ledger_id": "ledger-external-id",
      "transaction_sync_id": "tx-sync-id",
      "event_item_index": 0
    }
  ]
}
```

新增：

```text
POST /evidence/raw/{evidence_id}/links
POST /evidence/raw/{evidence_id}/assets
```

两者都必须幂等：重复提交同一 link 或同一 sha256 不产生重复行。

### 8.5.3 截图资产上传

`POST /evidence/raw/{evidence_id}/assets` 使用 multipart：

- `file` 必填；
- mime 白名单；
- 默认上限建议 10MB，硬上限 20MB；
- 读取时计算 SHA-256；
- 先写 `.tmp`，成功后原子 rename 为不可猜测文件名；
- DB 只存元数据和内部路径；
- 文件落盘成功但 DB 失败时由 orphan sweeper 清理；
- 已存在同一 evidence + sha256 时直接返回已有 asset；
- 不接受用户指定路径或文件名。

如果客户端隐私策略未允许服务器保存截图，只上传文字和 metadata，页面显示 `not_retained`；
不能强制把用户原本关闭的截图留存策略改为开启。

### 8.5.4 交易附件的兼容展示

部分截图可能已经作为普通交易附件上传。对比 API 可以同时返回现有 attachment 摘要，但必须
标注为“交易附件”，不能冒充“原始记账证据”。展示优先级：

1. 原始证据 asset；
2. 关联的交易附件；
3. 无图片。

删除重复交易时沿用附件 GC 规则：如果附件还被其它交易引用，不能物理删除；原始证据 asset
更不能因为某个交易被删除就直接删除。

## 8.6 服务端接口和查询实现

### 8.6.1 对比摘要接口

新增建议：

```text
POST /admin/duplicate-transactions/compare
```

请求：

```json
{
  "items": [
    {"ledger_id": "...", "sync_id": "..."},
    {"ledger_id": "...", "sync_id": "..."}
  ]
}
```

约束：

- 一次最多 20 笔交易，通常是一组重复组；
- 服务端按 `(ledger_id, sync_id)` 去重；
- 不信任前端传入的 keeper 标记，重新从 projection 读取；
- 必须使用 admin + ops read/write 兼容鉴权；
- 返回交易摘要、证据摘要、附件摘要和各自 status；
- 不返回原始正文全文和图片二进制。

查询必须批量化，目标是固定数量 SQL，而不是交易数 N：

1. 一条 projection 查询取回所有交易；
2. 一条 link + evidence 查询取回证据摘要；
3. 一条 asset 查询取回图片元数据；
4. 一条 attachment 查询取回普通附件摘要（若需要）。

不要在 `for item in request.items` 内逐笔 `db.execute`。

### 8.6.2 证据详情接口

新增建议：

```text
POST /admin/duplicate-transactions/evidence-detail
GET  /admin/duplicate-transactions/evidence-assets/{asset_id}
```

详情请求同时携带 transaction key 和 evidence id，服务端必须验证该 evidence 确实关联到该
transaction，防止管理员拿一个合法 evidence id 读取其它用户的任意记录。

- `evidence-detail` 返回单条正文全文（沿用 65,536 字符上限）和 asset 元数据；
- asset endpoint 只返回流，支持 `Content-Length`、正确 `Content-Type` 和可选 Range；
- 错误统一返回“evidence not available”，不泄露路径和其它用户是否存在；
- 对正文详情和图片读取写入 `AuditLog.action = admin_duplicate_evidence_view`，metadata 只记录
  admin id、ledger id、transaction/evidence 短 hash、asset id 和结果，不记录正文。

短期如果不新增 `SCOPE_OPS_READ`，可接受现有重复清理页使用的 `SCOPE_OPS_WRITE`；正式版建议
增加 `SCOPE_OPS_READ`，并让 compare/detail 同时接受 read 或 write，以免“只读查看证据”必须持有删除权限。

### 8.6.3 清理接口兼容和删除语义

`POST /admin/duplicate-transactions/clean` 的请求格式不变。

删除前重新校验：

- 交易仍存在；
- 交易仍属于指定 ledger；
- 不能删除当前请求中唯一的 keeper（除非未来明确增加强制模式）；
- evidence link 删除与 transaction 删除在同一短事务完成；
- `SyncChange delete`、projection 删除和现有附件 GC 语义不变；
- `RawBookkeepingEvidence` 行与 asset 不删除；
- 如果证据还关联其它交易，link 保持；没有任何 link 的证据按原 retention 策略处理。

删除成功后前端清除对比缓存并重新扫描；如果其它管理员同时删除了交易，详情接口返回
`not available`，不能把旧缓存当成当前事实。

## 8.7 Web 前端实施

### 8.7.1 文件落点

建议修改/新增：

```text
server/frontend/packages/api-client/src/admin.ts
server/frontend/packages/api-client/src/types.ts
server/frontend/apps/web/src/pages/sections/AdminDuplicateTransactionsPage.tsx
server/frontend/apps/web/src/pages/sections/components/DuplicateEvidenceDrawer.tsx
server/frontend/apps/web/src/i18n/zh-CN.ts
server/frontend/apps/web/src/i18n/en.ts
server/frontend/apps/web/src/i18n/zh-TW.ts
```

如果 workspace 中 `@smartbook/*` 包仍来自 gitignored `node_modules`，先按
`AGENTS.md` 的 Web build caveat 补齐/固定包来源，再进行前端构建验证。

### 8.7.2 页面状态

新增状态建议：

```text
compareTarget: {groupKey, leftKey, rightKey} | null
compareData: DuplicateCompareResponse | null
compareLoading / compareError
selectedEvidenceId: string | null
selectedAssetUrl: string | null
requestGeneration: number
```

规则：

- 打开同一组重复交易时复用短生命周期缓存；
- rescan / clean / ledger context 变化时清空缓存；
- 请求返回先校验 generation，旧请求不能覆盖新组；
- 切换 evidence 时取消或忽略旧 blob 请求；
- `URL.createObjectURL` 必须在切换和卸载时释放。

### 8.7.3 组件状态

必须覆盖：

- 交易有文字、无图片；
- 交易有图片、无文字；
- 同一交易多条 evidence；
- 同一图片关联多笔交易；
- evidence expired / not_linked / not_retained / asset_missing；
- 401/403/404/410/413 和网络错误；
- 对比抽屉打开时仍能返回列表并保留 checkbox 状态；
- 删除后抽屉自动关闭、重新扫描；
- 语言切换后所有证据状态和按钮均完成本地化。

## 8.8 测试计划

### 8.8.1 Server 单元/接口测试

新增建议：

```text
server/tests/test_duplicate_transaction_evidence.py
```

至少覆盖：

1. link 创建、重复提交幂等；
2. 一条 evidence 关联两笔交易；
3. 一笔交易关联短信 + 通知 + 截图三条 evidence；
4. 多账本同一 `transaction_sync_id` 不串证据；
5. compare endpoint 批量返回且不存在 N+1；
6. scan endpoint 不包含正文全文、asset path 或二进制；
7. 正常管理员可读，普通用户、非 admin、无 ops scope 被拒绝；
8. evidence detail 必须校验 transaction/evidence link；
9. 过期 evidence 返回正确状态，不泄露旧正文；
10. 非法 mime、超限、路径穿越、sha256 冲突；
11. 图片落盘失败时文字 evidence 仍可读；
12. 删除重复交易只删除 link，不删除仍被其它交易引用的 evidence/asset；
13. 删除最后一个 link 后 evidence 仍按 retention 存在；
14. legacy evidence 无 link 显示 `not_linked`；
15. AuditLog 记录查看行为且 metadata 无正文。

查询性能测试应使用 SQLAlchemy event 统计 SQL 次数，目标：

```text
20 笔 compare 摘要 ≤ 4 条核心查询（不计鉴权/事务初始化）
```

### 8.8.2 Client/上传链路测试

- AutoBookEventItems 多笔交易可以产生多个 transaction links；
- 交易先落库后上传、证据先上传后落库两种顺序都最终关联；
- 本地整数 ID 不出现在服务端 payload；
- raw evidence policy 关闭时不上传图片；
- 上传重试不产生重复 evidence/link/asset；
- 上传成功后本地清理 raw text 不影响服务端已保存内容；
- asset upload 失败可单独重试，不重复创建 evidence 行。

### 8.8.3 Web/Vitest 组件测试

- 初次扫描不调用 compare/evidence detail API；
- 点击某组只调用一次 compare API；
- 切换左右交易不重复请求已有摘要；
- 点击正文和图片分别懒加载；
- blob URL 在切换/卸载时释放；
- 证据状态徽标和空状态正确；
- 删除勾选与查看证据相互独立；
- compare 请求迟到不会覆盖当前抽屉；
- 三种语言快照/关键文案测试。

### 8.8.4 端到端场景

构造一个重复组：

- keeper：短信文字 evidence；
- duplicate A：同一来源但不同 event key；
- duplicate B：截图 evidence，并关联同一事件的另一个交易 item。

验收操作：扫描 → 打开对比 → 查看两栏文字/截图 → 选择 duplicate A 删除 → 重新扫描 →
确认 keeper 和 B 的 evidence 仍可读取。

## 8.9 性能、隐私与发布验收

### 性能门槛

| 指标 | 门槛 |
|---|---:|
| 重复扫描响应大小增幅 | ≤ 10%，不得包含正文/图片 |
| 打开一组对比摘要 SQL | ≤ 4 条核心查询 |
| 20 笔交易 compare 摘要 P95（PostgreSQL） | ≤ 100ms（不含网络） |
| 首屏对比抽屉到可见摘要 | ≤ 300ms（内网/已认证） |
| 图片列表初始下载字节数 | 0（只拉元数据） |
| 单证据正文详情 API | ≤ 100KB（不含图片） |
| 单次重复组图片自动下载数 | 0，必须用户点击 |
| 证据查询 N+1 | 0 |

### 隐私门槛

- 普通用户和非管理员不能调用 admin evidence API；
- 管理员查看正文/图片 100% 进入 AuditLog；
- API 响应不暴露绝对路径、API key、原始本地整数 ID；
- 日志和 metrics 不写正文、图片路径或完整 event key；
- 过期、未留存和未关联状态可区分；
- 删除重复交易不会误删 keeper 或其它交易仍使用的原始证据。

### 发布顺序

1. 先部署 additive migration 和只读 compare API，前端开关默认为关闭；
2. 新客户端开始上传 transaction links；
3. 管理员内部账号灰度，观察关联覆盖率、detail 404/410、图片存储增长和审计量；
4. 验证删除链路只清理 link；
5. 开启 Web 入口；
6. 旧客户端仍可扫描和清理，只是看到 `not_linked`；
7. 出现异常时关闭前端开关，保留 additive 表和已上传证据，不回滚已发布 migration。

建议 feature flag：

```text
ADMIN_DUPLICATE_EVIDENCE_COMPARE=true/false
RAW_EVIDENCE_IMAGE_UPLOAD=true/false
```

## 8.10 完成标准

- [ ] 重复交易扫描接口仍为轻量摘要；
- [ ] 新客户端自动记账交易可确定性关联到 event evidence；
- [ ] Web 可在同一抽屉并排查看 keeper 与重复交易的交易字段；
- [ ] Web 可懒加载查看原始文字和截图；
- [ ] evidence 缺失、未关联、过期、未留存、图片缺失状态明确；
- [ ] 一个事件多笔交易、一笔交易多份证据均不串联；
- [ ] 普通用户无权读取 admin evidence；
- [ ] 管理员查看正文/图片有审计记录；
- [ ] 删除交易只删除 link，不误删共享证据/asset；
- [ ] compare 核心查询无 N+1；
- [ ] 中文、英文、繁中 UI 文案齐全；
- [ ] legacy 未关联证据不使用金额/时间模糊回填；
- [ ] 前端开关、服务端开关和回滚步骤完成验证。

---

# 9. 客户端产品调整项（A：自动识别记录页面 / B：AI 助手单体入口）

> 性质：非性能优化，是本轮两项明确的**产品/交互调整**。与 M5-4/M6-2 属同一批客户端改造，
> 建议与 M5-4C/M6-2C 一起进入同一测试与真机验收批次，避免两次 upload/APK 回归。

## 9.1 调整项 A：把「最近识别记录」从自动记账设置页移到独立页面

### 9.1.1 现状与问题

`client/lib/pages/automation/auto_billing_settings_page.dart` 的 `_buildScreenDecisionsCard`
内嵌在自动记账设置页底部，展示最近 10 条识别决策（`recentDecisions()`），含义是：
原生过滤闸 + Dart/AI 段结局，用于真机漏记排查。

问题：

- 设置页职责是「开关 + 权限引导」，排查性、细节密集的决策列表混在其中，页面越来越长；
- 只显示最近 10 条，无法查看更早记录、按来源/结果过滤或回溯到对应交易；
- 记录内容仅决策码/命中词/计数，不含来源（短信/通知/截图/详情页）与去向（已入账/待确认/重复）。

### 9.1.2 目标

1. 移除自动记账设置页中的「最近识别记录」卡片；
2. 新增独立「自动识别记录」页面，展示完整、可分页（或按最近 N 上拉）的识别记录；
3. 入口放到「我的」页，与「自动记账」「待确认记账」等自动记账相关入口相邻；
4. 每条记录尽可能附带来源与结局，便于排查漏记/误发。

### 9.1.3 数据来源

复用现有 `ScreenTextMonitorService.recentDecisions()`（`client/lib/services/platform/screen_text_monitor_service.dart`）的环形队列决策。实施前需确认：

- 当前环形队列容量上限与是否持久化；若仅内存、容量很小，独立页面需要更大的最近记录缓冲或落库方案；
- 若记录仅覆盖无障碍/详情页路径，短信/通知/截图路径是否也有对应的决策记录（若没有，需评估是否补拍，或独立页面先只展示已有来源并以「来源」列标识）。

### 9.1.4 建议页面结构

```text
client/lib/pages/automation/auto_book_records_page.dart
```

- 顶部 PrimaryHeader：标题「自动识别记录」，返回，右侧「刷新」；
- 列表项：时间戳、来源徽标（短信/通知/截图/详情页）、结局文案（已入账/已进待确认/重复跳过/判非账单/失败重试/被拦截），hint 命中词（若有）；
- 支持按「结果」与「来源」筛选的小型筛选条（可选，第一阶段可不做，至少保留最近 50–100 条）；
- 点击某条（若已关联到交易）可跳转到对应交易详情或自动记账事件详情；
- 空态文案说明如何产生记录（引导用户打开一笔账单详情页）。

### 9.1.5 入口修改

`client/lib/pages/main/mine_page.dart` 功能管理卡片组中，在「自动记账」或「待确认记账」旁新增：

```text
AppListTile(
  leading: Icons.manage_search_outlined,
  title: 「自动识别记录」,
  subtitle: 「最近一次识别：…」,
  onTap: → AutoBookRecordsPage(),
)
```

建议放在「自动记账」之后，与自动记账语义相邻；是否需要 pending/最近一次状态子串可由实现决定。

### 9.1.6 迁移与回滚

- 删除 `_buildScreenDecisionsCard` 及其 `labels` 映射、`_screenDecisions` 状态字段；
- `ScreenTextMonitorService.recentDecisions()` 保留（新页面复用），不删数据；
- 遗留：若用户升级后找不到旧入口，新页面入口需足够显眼；不建议保留两处同内容入口造成混乱；
- 回滚：保留新页面代码，仅需在设置页重新挂回卡片即可（数据源不变）。

## 9.2 调整项 B：AI 助手移除快捷横条与独立图片/语音按钮，改为单体「+」入口

### 9.2.1 现状与问题

`client/lib/pages/ai/ai_chat_page.dart` 当前有：

- 输入区上方 `AIQuickCommandsBar`（`client/lib/widgets/ai/ai_quick_commands_bar.dart`），
  横排展示 6 个快捷指令：财务健康分析、本月支出总结、分类占比、预算规划、异常支出、省钱贴士；
- 输入区内独立「图片」「语音」「发送」三个 `IconButton`；
- 图片/语音点击后弹 `showModalBottomSheet` 再选相册/拍照。

问题：

- 输入区横向拥挤，图片/语音按钮占了本应属于文本输入的空间；
- 快捷指令横条与底部 Tab/页面其它信息争抢视觉焦点；
- 「相册」是最高频动作，当前藏在一级底部弹窗里的第一个 item，且「相册/拍照/语音」入口平铺不够聚焦。

### 9.2.2 目标

1. 移除 `AIQuickCommandsBar` 横条；
2. 移除输入区内独立的「图片」「语音」`IconButton`；
3. 替换为一个「+」按钮；
4. 点击「+」后弹出动作面板，收纳：相册图片、拍照、语音、财务健康分析、本月支出总结（以及保留的分类占比/预算规划/异常支出/省钱贴士，视实现取舍）；
5. 相册作为面板中的**首选/默认置顶**项；
6. 文本输入与发送按钮保持不变。

### 9.2.3 交互方案

```text
输入区: [ TextField............... ] [ ＋ ] [ 发送 ]
                 点击「＋」 ↓
        ┌────────────────────────────┐
        │  📷 相册（置顶/默认）        │ ← 首选
        │  📸 拍照                    │
        │  🎤 语音                    │
        │ ───────────────────        │
        │  🩺 财务健康分析            │
        │  📅 本月支出总结            │
        │  （… 其余快捷指令根据取舍）  │
        └────────────────────────────┘
```

- 面板用 `showModalBottomSheet`（与现有一致）；
- 相册项放第一位，视觉上高亮；
- 快捷指令点击行为复用现有 `_handleQuickCommand(command)`，不改变其 `generatePrompt` 与对话注入逻辑；
- 图片/拍照/语音分别复用现有 `_handleImageBilling(source)` / `_startVoiceBilling()`。

### 9.2.4 实现要点

- `client/lib/widgets/ai/ai_quick_commands_bar.dart` 可整体删除或改为可复用的「动作面板」组件；
- `AIQuickCommandsBar` 若删除，`AIQuickCommands.getAllCommands()` 仍在，仅消费方从横条改为面板；
- 建议新增 `AIInputActionSheet`（或复用 `showModalBottomSheet` 内聚）以承载「+」面板；
- 顶部快捷指令在输入区之上隐藏后，仅保留 AI 配置警告横幅；
- l10n 添加：面板标题、相册/拍照/语音（复用 `fabActionGallery`/`fabActionCamera`/`fabActionVoice`）、
  「更多分析」等文案，三种语言（zh-CN/zh-TW/en）都需要补齐。

### 9.2.5 测试与验收

- Widget 测试：点击「+」弹出面板；相册为第一项；点击相册/拍照/语音分别触发对应处理器；点击快捷指令触发 `_handleQuickCommand`；
- 移除横条后：无横条渲染、输入区三个按钮变为「+」「发送」两个；
- 语言切换后面板标题与各动作文案完整（三语言 key 齐全）；
- 现有 AI 记账/图片/语音/快捷指令功能回归不破坏。

---

# 10. Android 真机与 PostgreSQL/真实网络性能基准

## 9.1 基准分层

必须拆成四层，避免把 LLM 延迟误判为 App 或 server 性能：

| 层 | 目的 | 上游 |
|---|---|---|
| L1 客户端纯本地 | SQLite、列表、落库、ACK | Fake AI |
| L2 客户端到本地 mock server | HTTP、序列化、Relay | 固定延迟 mock provider |
| L3 生产栈受控网络 | FastAPI、PostgreSQL、连接池、outbox | mock provider + 网络注入 |
| L4 真实服务商 canary | 真实端到端体验 | 真实 LLM，低频、成本受控 |

任何报告必须同时给出“含 provider”和“剔除 provider”的耗时。

## 9.2 Android 设备矩阵

至少覆盖：

| 档位 | 设备 | 系统 | 用途 |
|---|---|---|---|
| 主设备 | 实际目标 vivo 机型 | 当前 OriginOS | 发布门禁 |
| 中端 | 近 3 年 vivo/iQOO 中端 | Android 14/15 | 性能主基线 |
| 低端 | 6GB RAM 或较弱 SoC | Android 12/13 | 内存和 jank 下限 |

环境控制：

- 电量 ≥ 50%；
- 关闭省电模式；
- 设备温度稳定后开始；
- 每场景 5 次 warm-up + 30 次正式样本；
- 冷启动样本之间执行 force-stop；
- 记录 App 版本、commit、设备、OS、刷新率、网络和温度；
- release/profile 包测试，不用 debug 包作为发布结论。

## 9.3 客户端埋点补齐

现有 `AutoBookTrace` 已有 Flutter 主链阶段。需补齐：

```text
native_capture
native_filter
native_enqueue
flutter_drain_start
claim
provider_call
persist
native_ack
queue_depth
```

字段白名单：

```text
trace_id, source, stage, duration_ms, queue_depth,
payload_bytes, result, retry_count, ledger_id_hash
```

禁止写入原文。

新增 FrameTiming：

- `SchedulerBinding.addTimingsCallback`；
- 记录 build/raster duration；
- 只在 profile/perf flavor 开启；
- 统计页面首 5 秒和加载下一页后的 2 秒；
- 输出 JSON，不上传第三方。

## 9.4 客户端测试工具目录

建议新增：

```text
client/integration_test/performance/
  app_start_benchmark_test.dart
  home_window_benchmark_test.dart
  auto_book_pipeline_benchmark_test.dart

client/tool/performance/
  seed_transactions.dart
  parse_auto_book_trace.dart

deploy/perf/android/
  run_android_perf.ps1
  collect_logcat.ps1
  collect_gfxinfo.ps1
```

数据集：

```text
1k transactions
10k transactions
50k transactions
平均 0/1/3 tags
附件覆盖率 0%/10%/50%
同时间戳密集数据 1,000 笔
多账本 1/5 个
```

数据必须固定随机种子，并记录 schemaVersion。

## 9.5 Android 场景

### 启动

- 冷启动到首帧；
- 冷启动到首页第一批交易可见；
- 有 0/10/50 条原生待处理队列；
- 单币种与多币种；
- 登录恢复和 Relay 初始化。

### 首页

- 1k/10k/50k 初次加载；
- 连续加载 10 页；
- 跳到 1 年、3 年前月份；
- 历史模式收到新交易；
- 标签/附件刷新；
- 主题和隐藏金额切换；
- 快速切换两个账本。

### 自动记账

- 短信、通知、屏幕文本、截图；
- Fake provider 0/100/500ms；
- provider timeout、502、429；
- App 在五个关键阶段被杀；
- 50 条积压队列恢复；
- 重试后 ACK 与幂等。

采集：

- `adb shell am start -W`；
- `adb shell dumpsys gfxinfo`；
- profile timeline / FrameTiming；
- `AutoBookTrace`；
- RSS/PSS；
- SQLite 查询耗时和返回行数。

## 9.6 PostgreSQL 性能环境

建议新增：

```text
deploy/perf/docker-compose.perf.yml
server/perf/mock_ai_provider.py
server/perf/relay_benchmark.py
server/perf/seed_perf_data.py
server/perf/report.py
```

环境组件：

- SmartBook-Cloud 自建镜像；
- PostgreSQL，与生产主版本一致；
- mock OpenAI-compatible provider；
- 可选 Toxiproxy；
- 独立 volume，不使用开发数据库；
- `pg_stat_statements` 开启。

数据规模：

- 10/100/500 并发用户；
- `ai_analysis_logs` 10 万/100 万行；
- outbox backlog 0/1k/10k；
- 图片 spool 0/1GB/10GB；
- 每用户 1/5 个 provider origin。

## 9.7 网络模型

至少测试：

| 网络 | RTT | 丢包 | 上行 |
|---|---:|---:|---:|
| LAN | <5ms | 0 | 不限 |
| 良好 5G/Wi-Fi | 30ms | 0 | 20Mbps |
| 普通移动网 | 100ms | 0.5% | 5Mbps |
| 弱网 | 300ms | 1% | 1Mbps |

mock provider 延迟档：

```text
0ms / 100ms / 1s / 30s / timeout
```

响应体档：

```text
1KB text / 100KB text / 300KB image request / 1MB / 5MB
```

## 9.8 Server 场景

- `/ai/relay/chat`：并发 1/5/20/32/64；
- 相同 provider origin 与混合 5 个 origin；
- 参数自适应 400 → 重试；
- vision 单图和 3 图 batch；
- STT 100KB/1MB/5MB；
- SSE 客户端中途断开；
- outbox 正常 drain；
- PostgreSQL 停 30 秒后恢复；
- spool 磁盘慢、只读、接近满；
- 两个 Uvicorn worker 并发 claim；
- shutdown 时存在 in-flight AI 与 outbox 任务。

采集：

- 请求 P50/P95/P99；
- server overhead（总耗时减 mock provider 延迟）；
- event loop lag；
- CPU、RSS、open sockets；
- PostgreSQL connections、locks、query time；
- outbox pending、oldest age、retry/dead；
- `pg_stat_statements`；
- 关键 SQL `EXPLAIN (ANALYZE, BUFFERS)`。

## 9.9 性能结果格式

结果目录：

```text
perf-results/
  2026-09-08/
    metadata.json
    android-<device>/
      startup.json
      home-window.json
      auto-book.json
    server-postgres/
      relay.json
      outbox.json
      pg-stat-statements.txt
    summary.md
```

`metadata.json` 至少包含：

```text
commit/worktree hash
build flavor
schema versions
device/OS/PostgreSQL version
dataset seed
network profile
sample count
warm-up count
```

原始结果默认不提交 Git；仅提交脱敏后的 `summary.md` 和阈值变化。

## 9.10 发布门禁

### Client

| 指标 | 门槛 |
|---|---:|
| 冷启动到首帧 P95 | 不高于基线 10% |
| 首页 50k 数据集首批可见 P95 | ≤ 500ms |
| 首页初始查询 P95 | ≤ 80ms |
| 加载下一页 P95 | ≤ 100ms |
| 60Hz 设备 jank | < 2% |
| 120Hz 设备 jank | < 3% |
| 首页常驻交易 | ≤ 960 |
| 自动记账本地处理（剔除 provider）P95 | ≤ 300ms |
| 进程死亡测试丢账/重复 | 0 / 0 |

### Server

| 指标 | 门槛 |
|---|---:|
| Relay server overhead P95（text） | ≤ 25ms |
| 20 并发 event loop lag P95 | ≤ 50ms |
| AI HTTP 活跃连接 | 不超过配置上限 |
| outbox 文本 enqueue P95 | ≤ 20ms |
| outbox 正常 backlog age P95 | ≤ 5s |
| 故障恢复后最终日志丢失/重复 | 0 / 0 |
| PostgreSQL connection leak | 0 |
| 连续 30 分钟压测错误率 | < 0.1%，预期注入错误除外 |

阈值第一次以真实基线校准；任何放宽必须在文档中记录旧值、实测值和原因。

---

# 11. 推荐提交拆分

未经用户确认不实际提交。实施时建议拆为以下独立 commit/PR，避免一个大改同时触碰 UI、数据库和后台 worker：

1. `[客户端性能] 增加交易游标分页类型、索引与 Repository 测试`
2. `[客户端性能] 增加首页窗口控制器与双向加载`
3. `[客户端性能] 接入月份锚定、位置恢复与回滚开关`
4. `[客户端性能] 标签附件详情改为窗口级批量加载`
5. `[Web/服务端] 重复交易原始证据关联与对比抽屉`
6. `[服务端性能] 增加 AI 日志 outbox 表与可靠入队`
7. `[服务端性能] 增加 AI 日志 worker、lease 与幂等归档`
8. `[服务端性能] 接入 dead-letter、指标与运维接口`
9. `[性能基准] 增加 Android/PostgreSQL 自动化基准工具与报告`
10. `[客户端] 自动识别记录独立页面并移除设置页内嵌卡片`
11. `[客户端] AI 助手快捷横条与图片/语音按钮合并为「+」单体入口`

每个提交必须能独立通过相关测试；M5-4 与 M6-2 合入前必须跑完整 `flutter test`，M6-5 合入前必须跑完整 `pytest tests/`。

---

# 12. 风险清单

| 风险 | 影响 | 缓解 |
|---|---|---|
| 游标只按时间导致重复/漏项 | 数据列表错误 | 强制 `(time,id)` 双键与同时间戳测试 |
| prepend 页面造成滚动跳动 | UX 回退 | 可见交易 ID 锚点恢复 + vivo 真机验证 |
| 历史模式新交易插入顶部 | 阅读位置跳动 | unseen banner，不直接插入 |
| page 淘汰后无法回滚 | 列表断层 | 保留方向 cursor 与 hasMore，支持重新加载 |
| 标签直接 JOIN 造成行倍增 | CPU/内存增加 | 标签保持独立 batch query |
| SQLite bind 参数超限 | 大账本崩溃 | 固定 400 chunk + 1,200 ID 测试 |
| outbox 双 worker 重复归档 | 重复日志/图片 | lease + source_outbox_id unique + 确定性文件名 |
| DB 与文件无法原子提交 | orphan/缺图 | 原子 rename、幂等重试、orphan sweeper |
| outbox 故障忙循环 | CPU/DB 风暴 | next_attempt_at + 指数退避 + batch 上限 |
| 磁盘满导致主 AI 请求失败 | 用户功能受损 | enqueue fallback、dead 指标、容量告警 |
| 原始证据误关联到错误交易 | 管理员误删正确交易 | 只接受 transaction sync id 确定性 link，禁止金额/时间模糊回填 |
| 管理员查看敏感正文/截图越权 | 隐私泄露 | admin + ops scope、详情二次校验、AuditLog、无静态路径 |
| 删除重复交易误删共享证据 | 其它交易失去证据 | link 与 evidence/asset 分离，删除只清理关联边 |
| 原始图片存储增长过快 | 磁盘耗尽 | mime/大小上限、sha 去重、spool/orphan sweeper、容量告警 |
| 性能测试被 provider 波动污染 | 错误结论 | mock 与真实 provider 分层报告 |
| debug 构建跑分失真 | 门禁无效 | 只用 profile/release 作发布结论 |
| 移除设置页「最近识别」后用户找不到排查入口 | 排查路径丢失 | 「我的」新增入口足够显眼 + 空态引导；数据源复用不删 |
| AI 助手快捷指令收起为「+」后功能不可发现 | 功能被隐藏 | 面板标题清晰 + 短交互动画；保留相册置顶默认 |
| 快捷指令横条删除后 prompt 注入逻辑改动引入回归 | AI 记账行为变化 | 复用现有 `_handleQuickCommand`，只改调用层不动生成逻辑 |

---

# 13. Definition of Done

全部满足才视为本专项完成：

- [ ] 首页默认不再调用全历史 `transactionsWithCategoryAll`；
- [ ] 50k 数据集首屏只读取一页；
- [ ] 月份跳转、双向滚动、回到最新、账本切换均有测试；
- [ ] 标签/附件查询量只与当前窗口相关；
- [ ] `TransactionList` 不再主动访问 Repository；
- [ ] Web 重复交易对比可以查看已关联的原始文字、截图和证据状态；
- [ ] 原始证据关联支持一事件多交易、一交易多证据，且无模糊回填；
- [ ] AI 日志具备 durable enqueue、lease、retry、dead-letter 和 orphan cleanup；
- [ ] 十个 AI 日志故障注入点全部通过；
- [ ] Android 目标 vivo 真机完成至少 30 样本；
- [ ] PostgreSQL + mock provider + 弱网压测完成；
- [ ] 完整客户端和服务端测试通过；
- [ ] 性能结果和阈值写回上位计划；
- [ ] feature flag、回滚步骤和运维告警已验证；
- [ ] 自动记账设置页不再内嵌「最近识别记录」，独立页面可从「我的」进入且记录完整可回溯；
- [ ] AI 助手移除快捷横条与独立图片/语音按钮，改用「+」单体入口且相册置顶为默认；
- [ ] 用户确认后再执行 Git commit。
