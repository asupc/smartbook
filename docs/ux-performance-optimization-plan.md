# SmartBook 用户体验、性能与记账速度优化实施计划

> 文档状态：Draft v1.0  
> 制定日期：2026-09-06  
> 适用范围：`client/` Android/Flutter 客户端、`server/` AI Relay 与同步相关服务  
> 当前基线提交：`f7494b8`（`[自动记账] 完成 UX 优化专项(P0-P2 全部落地)`）  
> 计划性质：增量优化，不推翻现有本地优先、事件幂等、候选确认和同步架构
> 未实施项详细拆解：`docs/performance-followup-implementation-plan.md`（2026-09-08）

---

## 1. 文档目的

本计划用于指导 SmartBook 后续一轮以用户感知为中心的专项优化，目标是同时改善：

1. **用户体验**：启动更快、状态更清楚、失败可恢复、手动记账步骤更少；
2. **客户端性能**：减少不必要的 SQLite 查询、页面全量重建、重复同步和图片处理开销；
3. **记账速度**：缩短“捕获到账单本地保存完成”的时间，消除队头阻塞；
4. **可靠性**：任何优化都不得引入丢账、重复记账、跨账本串账或同步契约破坏；
5. **可度量性**：建立可重复的基准、阶段耗时和发布门禁，避免仅凭体感优化。

本文重点针对 vivo / OriginOS Android 自动记账主链路，同时覆盖手动记账、首页明细和 SmartBook Cloud AI Relay。Web 管理端不作为本轮首要范围，除非服务端改动需要对应展示或配置入口；新增 M6-6“重复交易清理原始记账信息对比”作为独立 Web/服务端调整项，详细方案见 `docs/performance-followup-implementation-plan.md`。

---

## 2. 现状与已有能力

当前代码已经具备以下良好基础，实施时应优先复用而不是重写：

- Android 原生通知、短信、截图、无障碍页面均采用持久化队列；
- 原生队列使用 `peek + ACK`，避免读取后进程被杀造成整批丢失；
- `AutoBookCoordinator` 提供事件级串行 claim；
- `AutoBookEventStore` 提供 `eventKey` 唯一约束、父事件状态和多账单子项恢复；
- `SemanticDedupMatcher`、账单唯一标识和候选确认形成多层去重；
- 本地 Drift/SQLite 先写，云同步在后台执行；
- 自动入账总闸、影子模式、待确认、强判重撤销、事件历史已经具备；
- SmartBook Cloud 同步已有 LWW、change_id、projection 和 per-ledger lock 等契约；
- AI 密钥只存服务端，App 经 `/api/v1/ai/relay/*` 中转。

本计划不改变上述产品原则。

---

## 3. 审计范围与关键调用链

### 3.1 自动文本记账

```text
SmsReceiver / NotificationWatcher / ScreenTextWatcher
  → native SharedPreferences queue
  → bridge broadcast
  → Sms/Notify/ScreenTextMonitorService.drainPending
  → AutoBookCoordinator.execute
  → AutoBillingService.process*
  → AiBookkeeper.fromText
  → AiExtractionContext.forLedger
  → AIProviderFactory.chatWithMeta
  → AiRelayClient
  → server /ai/relay/chat
  → provider_client.call_chat_text
  → JsonResponseParser
  → AiBookkeeper._persistAll
  → semantic dedup / pending policy
  → BillCreationService.createFromBill
  → LocalRepository.addTransaction
  → event mark / native ACK
  → PostProcessor / cloud sync
```

### 3.2 自动截图记账

```text
MediaStore ContentObserver
  → ScreenshotObserver 延迟检查文件
  → native pending screenshot queue
  → ScreenshotMonitorService
  → AutoBookCoordinator
  → AutoBillingService.processScreenshot
  → AiBookkeeper.fromImage
  → /ai/relay/vision
  → provider vision model
  → 本地落库、可选附件、事件终态、ACK
```

### 3.3 手动记账

```text
TransactionEditorPage
  → CategorySelector
  → AmountEditorSheet
  → ManualDuplicateChecker
  → LocalRepository.add/updateTransaction
  → TxAuthorService
  → attachments
  → tags / shared overrides
  → PostProcessor
  → 页面关闭和反馈
```

### 3.4 首页明细

```text
HomePage
  → transactionsWithCategoryAll(当前账本全部历史)
  → TransactionList
  → 标签与附件批量补查
  → 每次 build 重新按日分组、排序、扁平化
  → FlutterListView 渲染
```

---

## 4. 核心问题清单

## 4.1 P0：冷启动 AI Relay 就绪竞态

### 现象

`main.dart` 在 `runApp` 之前依次恢复截图、短信、通知、屏幕文本监听，并且 `enable()` 会立即 drain 积压队列。AI Relay 则在 Flutter 页面启动后、`syncServiceProvider` 初始化时才注入。

当本地 AI 配置缓存有效但 Relay 尚未注入时，文本提取可能发生：

```text
isCapabilityConfigured = true
→ AIProviderFactory._requireRelay 抛非 transient 异常
→ DefaultAiExtractionEngine 将异常转换为空账单
→ AutoBillingService 判断 noTransaction
→ Monitor ACK 原生队列
```

### 风险

- 冷启动积压的真实短信或支付通知可能被错误视为非交易；
- 用户无明显失败提示；
- 原生队列被 ACK 后无法自动恢复。

### 必须满足的修复原则

- “配置存在”和“运行时可调用”必须是两个状态；
- Relay 未注入、登录恢复中、网络不可达不得映射为 `noTransaction`；
- 只有模型成功返回并明确解析为空账单，才允许 ACK 为非交易；
- 自动队列 drain 必须等待 AI Runtime 进入可判定状态。

---

## 4.2 P0：失败结果绕过统一退避

### 现象

Coordinator 仅在 `action` 抛异常时调用 `markRetry()`。多数 `processSms/processNotification/processScreenText/processScreenshot` 会自行捕获异常并返回失败结果，Monitor 再把结果映射成 `retry`，但没有写入 `nextRetryAt`。

### 风险

- 退避策略名义上是 `30s → 2m → 8m → 30m → 2h`，实际没有覆盖主要失败路径；
- Bridge 重复触发时可能立即再次调用 AI；
- 增加耗电、流量和第三方模型费用；
- 同一失败事件长期占据队列。

### 补充风险

`retryDraft()` 当前重放时直接调用 `process*`，没有完整经过 Coordinator 的 claim/mark。需要通过测试确认并修复以下状态闭环：

- 重试成功后父事件应变为 `booked/pending/duplicate/ignored`；
- 成功后 `draftPayloadJson` 应清空；
- 重试失败应递增 attempt 并生成新的 `nextRetryAt`；
- 已成功子项不得再次创建交易。

---

## 4.3 P0：全局串行导致队头阻塞

当前所有自动来源共用 `AutoBookCoordinator._tail`。一个慢截图会阻塞后续短信、通知和屏幕文本。各 Monitor 又维护自己的 `_processingChain`，并且一次 drain 会遍历完整来源队列，容易导致来源间不公平。

当前服务端 LLM 默认超时可达 120 秒，客户端 HTTP 调用没有显式 deadline。极端情况下，一个事件可让后续事件等待近两分钟甚至更久。

---

## 4.4 P1：冷启动在首帧前执行过多工作

`runApp` 前当前会等待：

- 通知插件初始化；
- 用户提醒恢复；
- App mode 初始化；
- 信用卡提醒恢复；
- Widget callback 注册；
- AutoBookCoordinator cleanup；
- 四种 Monitor 恢复及积压处理。

当原生队列存在积压时，首帧时间可能与队列数量、AI 延迟成正比。

---

## 4.5 P1：判重和基线查询放大

`AiBookkeeper._persistAll()` 当前：

1. 拉取近 90 天丰富交易对象；
2. 实际只把最近 24 小时放入基础重复池；
3. 每个 BillInfo 又调用一次 `SemanticDedupMatcher.findBest()`；
4. Matcher 再拉一次约 90 天交易；
5. `getTransactionsByDateRange()` 对每笔交易分别查分类、标签、附件和账户。

这会让自动记账本地处理时间随着历史交易量线性甚至更差地增长。

---

## 4.6 P1：BillCreationService 每笔重复加载上下文

每笔账单可能重复执行：

- 一级分类和各一级分类的子分类查询；
- 账本币种查询；
- 全账户查询；
- 默认账户查询；
- 命中账户再次查询；
- SharedPreferences 读取；
- 标签逐名称查询/创建；
- 落库后再查询交易、分类、账户名称。

多笔截图或账单页解析会放大该开销。

---

## 4.7 P1：新建数据库与升级数据库索引集合可能不一致

部分索引只在历史 `onUpgrade` 分支创建，而 `onCreate` 主要执行 `createAll()`，只额外创建汇率唯一索引。新安装用户可能缺少：

- `idx_transaction_tags_transaction`；
- `idx_transaction_tags_tag`；
- `idx_attachments_transaction`；
- `idx_transactions_sync_id`；
- 预算相关索引。

需要统一索引保障逻辑。

---

## 4.8 P1：成功反馈等待非核心副作用

交易已本地落库后，自动流程仍可能等待：

- 截图附件复制；
- 实际分类/账户名称回填；
- AI 助手对话消息写入；
- 待确认或合并通知；
- 最终系统通知。

手动记账页面也会等待附件、标签、共享 override 等步骤后才关闭。

用户真正关心的“已经记到本地账本”与展示增强、云同步没有明确拆开。

---

## 4.9 P1：首页加载整个账本历史

首页 Stream 当前读取当前账本全部交易，并在每次 `TransactionList.build` 中重新：

- 按日期分组；
- 排序日期；
- 创建扁平列表；
- 计算每日收支。

账本达到 1 万笔以上时，首屏、内存和无关 rebuild 成本会明显上升。

---

## 4.10 P2：同步存在重复触发和全量扫描

一次本地变化可能同时由：

- `PostProcessor` 直接触发 `sync.sync()`；
- `SyncCoordinator` 监听 `local_changes` 后再次触发自动同步。

附件上传前会先读取本账本全部交易，再查询其未上传附件。普通同步还会查询远端账本列表判断 fullPush。已有单飞和防抖可缓解，但仍存在重复网络与全表扫描窗口。

---

## 4.11 P2：服务端 AI Relay 连接和日志开销

- 每次调用新建 `httpx.AsyncClient`，无法充分复用连接和 TLS；
- AI Relay 的同步日志 INSERT 和图片落盘在 async route 的 `finally` 内完成；
- 图片以完整字节读入内存，再 base64 放入上游 JSON；
- 并发请求下会增加 event loop 阻塞和内存峰值。

---

## 5. 优化目标与验收指标

以下指标为第一版目标。M0 完成真实基线后允许调整，但任何调整必须记录原因。

| 领域 | 指标 | 目标 |
|---|---|---|
| 启动 | 普通冷启动首个可交互页面 P95 | ≤ 1.5s，首次大迁移除外 |
| 启动 | 有积压自动事件时首帧 | 不随积压数量线性增长 |
| 手动记账 | 无附件本地提交 P95 | ≤ 250ms |
| 手动记账 | 提交后页面反馈 | 本地核心事务完成后立即发生 |
| 自动文本 | App 内部开销 P95，排除第三方 LLM | ≤ 300ms |
| 自动文本 | 已知模板本地快速通道 P95 | ≤ 500ms |
| 自动文本 | 指定参考模型端到端 P95 | 初始目标 ≤ 10s |
| 自动图片 | AI 请求前本地等待 P95 | ≤ 1.2s |
| 自动图片 | 指定参考模型端到端 P95 | 初始目标 ≤ 20s |
| 队列 | 单来源不得长期饿死 | round-robin 可验证 |
| 队列 | Relay 未就绪时 | 0 条错误 ACK |
| 重试 | retry 事件 | 100% 写入 nextRetryAt |
| 去重 | 跨短信/通知/截图同一交易 | 0 重复创建 |
| 首页 | 1 万笔账本首批可见数据 | ≤ 1s |
| 首页 | 典型滚动 | 无明显持续掉帧，jank 率目标 < 1% |
| 同步 | 本地写入到服务端可见 P95 | 网络正常时 ≤ 3s |
| 服务端 | Relay 自身开销，排除上传与上游模型 | P95 ≤ 150ms |
| 图片 | AI 上传副本体积 | 中位数降低 ≥ 60% |

### 5.1 正确性硬门禁

性能指标不能覆盖以下正确性要求：

- 不允许丢失已进入 native 队列的事件；
- 不允许将运行时异常解释为“非交易”；
- 不允许同一事件重复创建交易；
- 不允许跨账本共享资源映射错误；
- 不允许破坏 `sync_changes` append-only；
- 不允许破坏 `change_id` 单调性；
- 不允许绕过 LWW、rename cascade 或 ledger lock；
- 不允许将真实 API Key 下发到客户端；
- 性能日志不得包含短信、通知、页面文本等原文。

---

## 6. 目标架构

## 6.1 启动分层

```text
阶段 A：首帧前最小初始化
  - WidgetsFlutterBinding
  - 必需主题/模式最小读取
  - ProviderContainer
  - runApp

阶段 B：首帧后高优先后台初始化
  - AI Relay/Auth readiness
  - native bridge 注册
  - Notification plugin
  - 自动记账事件 cleanup

阶段 C：AI ready 后处理积压
  - 读取各来源队列深度
  - round-robin 调度
  - 限流和重试

阶段 D：低优先维护
  - reminder restore
  - widget warm-up
  - orphan file GC
  - profile reconciliation
```

注意：监听服务的 native 开关原本已持久化。Flutter 冷启动不应先完整 drain 才允许渲染 UI。

---

## 6.2 AI Runtime 状态模型

建议新增：

```dart
enum AiRuntimeState {
  unconfigured,
  initializing,
  ready,
  offline,
  authenticationRequired,
  providerError,
}
```

状态来源至少包含：

- 本地是否存在能力绑定；
- `AiRelayClient` 是否注入；
- Cloud Auth 是否可取得 access token；
- 服务端是否明确返回未配置；
- 当前网络是否可达。

自动事件策略：

| Runtime 状态 | 自动事件处理 |
|---|---|
| unconfigured | 保留 captured，单次引导，不 ACK |
| initializing | 保留队列，等待 ready 事件 |
| ready | 正常识别 |
| offline | 保存/保留草稿并退避 |
| authenticationRequired | 保留并提示登录 |
| providerError | failed 或长退避，必须可见 |

用户主动事件可等待短时间初始化；自动事件不应占用 UI 启动路径等待。

---

## 6.3 统一提取结果

建议扩展 `AiExtractionOutcome`，禁止用“空 bills”同时表达无账单和异常：

```dart
enum ExtractionStatus {
  success,
  noBill,
  duplicate,
  retryableFailure,
  permanentFailure,
}

class AiExtractionOutcome {
  ExtractionStatus status;
  List<BillInfo> bills;
  String? errorCode;
  String? safeMessage;
  bool duplicate;
  String? matchedIdentifier;
}
```

映射要求：

- HTTP 429/502/503/504、Socket、Timeout → retryableFailure；
- Relay 未注入、Auth 恢复中 → retryableFailure；
- AI 未配置 → permanent/configuration state，但不当作 noBill；
- 合法响应解析为空 → noBill；
- 结构解析失败 → retryable 或 permanent，按错误类型决定；
- duplicate → duplicate。

---

## 6.4 两阶段自动记账调度

```text
Capture/Claim
  ↓
Recognition Pool（并发 2）
  - 网络/LLM/OCR
  - 不写 canonical transaction
  ↓
Per-ledger Commit Gate（同账本串行）
  - 重新加载窄范围候选
  - 最终语义判重
  - policy/candidate 决策
  - 交易与事件子项事务提交
  ↓
Parent Event Terminal Mark + Native ACK
  ↓
After-commit Side Effects
  - 通知
  - AI 对话卡片
  - 附件派生处理
  - widget/stats refresh
  - cloud sync trigger
```

关键点：可以并行的是识别，不能无条件并行最终提交。提交前必须在 per-ledger gate 内重新判重，确保两个来源同时识别同一笔支付时只有一个创建交易。

---

## 6.5 数据热路径

新增批次级上下文：

```dart
class AiLedgerContext {
  ledger;
  usableExpenseCategories;
  usableIncomeCategories;
  visibleAccounts;
  defaultAccounts;
  tagByName;
  effectiveRates;
  preferencesSnapshot;
}
```

一次事件内复用，配置变化后按版本失效。不得无限期缓存 Drift 行。

判重查询改为：

```sql
SELECT id, type, amount, happened_at, note, currency_code
FROM transactions
WHERE ledger_id = ?
  AND type = ?
  AND happened_at BETWEEN ? AND ?
  AND amount BETWEEN ? AND ?
ORDER BY happened_at DESC
LIMIT ?;
```

externalId 精确匹配仍优先于模糊评分。

---

## 7. 分阶段实施计划

# M0：观测与基线

**预计：2–3 人日**  
**目标：先把时间花在哪里量清楚，不改变业务行为。**

## M0-1 建立自动记账 Trace

新增统一 trace 字段：

```text
trace_id
source
source_channel
ledger_id
event_key_hash
queue_depth
attempt_count
stage
duration_ms
payload_bytes
provider_id
model
outcome
```

禁止记录：

- 短信正文；
- 通知 title/body；
- 无障碍页面文本；
- API Key；
- 未脱敏商户等敏感字段。

建议阶段名：

```text
native_capture
native_filter
native_enqueue
flutter_bridge
queue_peek
claim
runtime_wait
context_load
image_prepare
relay_upload
provider_call
response_parse
baseline_load
dedup
policy
persist
relation_persist
event_terminal
native_ack
user_feedback
sync_scheduled
sync_complete
```

### 修改文件

- `client/lib/services/automation/auto_book_event.dart`
- `client/lib/services/automation/auto_book_coordinator.dart`
- `client/lib/services/automation/auto_billing_service.dart`
- `client/lib/services/system/logger_service.dart`
- 四个 Monitor service
- `client/lib/ai/relay/ai_relay_client.dart`
- `server/src/routers/ai/relay.py`
- `server/src/services/ai/provider_client.py`

### 验收

- 一条事件可通过同一 trace 还原阶段耗时；
- 日志中搜索不到测试短信原文；
- Trace 自身对文本事件额外开销 P95 < 5ms。

## M0-2 建立基准测试数据

数据规模：

- 0、1,000、10,000、50,000 笔交易；
- 20/60/200 个分类；
- 5/20/100 个账户；
- 0/2/10 个标签每笔；
- 0/1/5 个附件每笔；
- 自动队列 1/10/30/50 项。

场景：

- 单笔短信；
- 同一交易短信+通知同时到达；
- 一张截图多笔账单；
- AI 延迟 200ms/3s/30s/超时；
- 进程在 claim、交易 insert、子项 mark、父事件 mark、ACK 前被终止；
- 无网、切网、Token 过期、服务端 502。

## M0-3 vivo 真机基线

至少覆盖：

- App 前台；
- App 后台；
- App 被划掉；
- 屏幕锁定；
- 省电模式开启；
- 后台高耗电允许/禁止；
- 通知使用权撤销；
- 无障碍权限被 OriginOS 自动关闭；
- Wi-Fi/移动网络切换。

产出：`artifacts/perf-baseline-<date>.json`，不提交隐私数据。

---

# M1：P0 可靠性闭环

**预计：3–5 人日**  
**前置：M0 trace 最小版本完成。**

## M1-1 AI Runtime Readiness

### 实施

1. 新增 `aiRuntimeStateProvider` 或独立 `AiRuntimeCoordinator`；
2. `AIProviderManager.isCapabilityConfigured` 只表达配置，不再表达运行时 ready；
3. Relay 注入和 Auth ready 后发出状态变化；
4. Monitor drain 遇到 initializing/offline 时保留队列；
5. `_requireRelay` 使用可区分的错误码，并将初始化期错误标记为 retryable；
6. AI 服务端明确区分：未配置、未认证、上游失败、超时。

### 测试

- 本地缓存有效但 relayClient=null；
- Relay 注入后事件自动恢复；
- access token 刷新中；
- 401 刷新成功/失败；
- 未配置能力不 ACK。

## M1-2 Typed Extraction Outcome

### 实施

- 改造 `DefaultAiExtractionEngine.extractFromText`；
- 禁止 catch 后返回空 bills 代表异常；
- `AutoBillingService` 按 status 映射事件状态；
- noBill 与 failure 使用不同通知和历史原因。

### 兼容

主动 AI 聊天仍可展示现有错误文案；自动路径必须保留事件和可重试信息。

## M1-3 Retry Contract

### 实施

1. Coordinator 接受业务返回的 retryable 状态；
2. 所有 retryable 结果统一调用 `markRetry()`；
3. `attemptCount` 只在成功 claim 时增加；
4. `nextRetryAt` 根据 attempt 计算；
5. permanent failure 进入 failed，不再自动忙循环；
6. 手动重试调用 `resetRetryGate()` 后仍经过 Coordinator。

### 建议 API

```dart
class AutoBookActionResult<T> {
  T? value;
  AutoBookState state;
  bool retryable;
  String? reason;
}
```

## M1-4 草稿重放闭环

### 实施

- `_replayDraft` 不再直接裸调用 `process*`；
- 通过统一 scheduler/coordinator 重建 `AutoBookInput`；
- 成功后原子更新 parent state 和 draft；
- 图片消失明确标记 failed/expired，而不是静默删除全部历史；
- 保留已完成 event item 的恢复逻辑。

### M1 验收门禁

- 新增测试全部通过；
- 原有自动记账、候选、语义去重测试全部通过；
- 100 次故障注入无丢账、无重复；
- Relay 未就绪场景 0 错误 ACK；
- 所有 retry 行均存在合理 `nextRetryAt`。

---

# M2：启动与队列调度

**预计：3–5 人日**

## M2-1 前移 runApp

### 实施

首帧前只保留真正必需的初始化。以下任务迁到首帧后：

- reminder restore；
- credit card reminder restore；
- widget callback/warm-up；
- 自动记账 cleanup；
- monitor drain；
- orphan GC；
- profile reconciliation。

如主题和安全状态必须在首帧前读取，保留最小读取，不等待网络或队列。

## M2-2 拆分 Monitor enable

把当前 `enable()` 拆为：

```dart
restoreNativeEnabledFlag()
registerBridge()
startObserverIfNeeded()
scheduleDrain()
drainOneOrBatch()
```

启动恢复仅等待 bridge/observer 注册，不等待 AI 处理完整队列。

## M2-3 Bridge 事件合并

每个来源增加：

```text
isDrainScheduled
isDraining
queueDirty
```

多个广播只标记 dirty，不向 `_processingChain` 追加多个完整 drain。一次 drain 结束若 dirty 再跑一轮。

## M2-4 公平队列

短期方案：每个来源每轮最多取 1–2 项，然后让出。  
长期方案：中央 `AutoBookScheduler` round-robin。

优先级：

```text
用户主动重试/主动记账
  > 即时支付通知/短信
  > 截图
  > 屏幕文本历史详情
  > 周期性草稿重试
```

## M2-5 客户端和服务端 deadline

建议初始值：

| 能力 | 客户端 deadline | 服务端上游 timeout |
|---|---:|---:|
| 文本提取 | 40s | 35s |
| 图片提取 | 65s | 60s |
| STT | 65s | 60s |
| 自由聊天 | 130s | 120s |

自动记账和自由聊天应使用不同 timeout。超时后进入退避，不允许继续占用全局处理槽。

### M2 验收

- 50 条积压不影响首帧；
- 多次 bridge 广播最多产生一条活跃 drain；
- 慢截图不阻止 UI 启动；
- 不同来源均可获得处理机会；
- deadline 生效并落 retry 状态。

---

# M3：SQLite 与落库热路径

**预计：5–7 人日**

## M3-1 统一索引

当前 schemaVersion 为 38。实施时使用实际下一个可用版本，暂记 v39。

新增 `_ensureIndexes()`，在 `onCreate` 和 `onUpgrade` 结束时共同调用。

候选索引：

```sql
CREATE INDEX IF NOT EXISTS idx_transactions_ledger_time
ON transactions(ledger_id, happened_at DESC);

CREATE INDEX IF NOT EXISTS idx_transactions_ledger_type_time
ON transactions(ledger_id, type, happened_at DESC);

CREATE INDEX IF NOT EXISTS idx_transactions_sync_id
ON transactions(sync_id);

CREATE INDEX IF NOT EXISTS idx_transaction_tags_transaction
ON transaction_tags(transaction_id);

CREATE INDEX IF NOT EXISTS idx_transaction_tags_tag
ON transaction_tags(tag_id);

CREATE INDEX IF NOT EXISTS idx_attachments_transaction
ON transaction_attachments(transaction_id);

CREATE INDEX IF NOT EXISTS idx_auto_book_state_retry
ON auto_book_events(state, next_retry_at);

CREATE INDEX IF NOT EXISTS idx_auto_book_items_semantic
ON auto_book_event_items(semantic_key);
```

是否加入 amount 索引由 `EXPLAIN QUERY PLAN` 和 1万/5万笔基准决定，避免无效索引增加写放大。

## M3-2 轻量判重 Repository API

在接口层新增专用查询，不复用包含 tags/attachments/category/account 的丰富列表方法。

修改：

- `client/lib/data/repositories/transaction_repository.dart`
- `client/lib/data/repositories/local/local_transaction_repository.dart`
- `client/lib/services/automation/semantic_dedup_matcher.dart`

查询先按：账本、类型、时间、金额范围过滤，返回有限候选。

## M3-3 基线池复用

- 基础规则只需要最近 24 小时，直接查询 24 小时；
- 一个 `_persistAll` 调用只加载一次池；
- 每成功一笔，将 BillInfo 追加到内存比较池；
- SemanticMatcher 接受预加载候选，避免每 Bill 再查 90 天；
- externalId 查询保持单独快速通道。

## M3-4 AiExtractionContext 并行加载

可并行读取：

- expense categories；
- income categories；
- ledger；
- accounts；
- SharedPreferences。

同一事件内只构造一次，主动语音“STT → 文本提取”不得重复加载。

## M3-5 BillCreationContext

### 实施

- `_loadUsableCategories()` 改为 Repository 单查询接口；
- 账户列表只加载一次；
- 默认账户在内存池验证；
- 命中账户后不再次 SELECT；
- 标签名称一次查全，缺失标签批量创建；
- 实际名称从 Context 或 insert 数据返回，不再逐笔 enrich SELECT；
- `_collectUnconverted` 使用批量按 ID 查询或直接使用本批落库结果。

## M3-6 多笔事务批量落库

优先保证：

```text
transactions
transaction_tags / overrides
auto_book_event_items
```

在单个数据库事务中完成。附件物理文件不放在长 SQLite 事务中。

### M3 验收

- 1万笔数据下判重 SQL 数量与历史总量基本无关；
- 单笔自动记账本地 SQL 往返明显下降；
- 10 笔批量账单不再重复加载 10 次分类/账户；
- 所有数据库迁移测试覆盖新装与升级两条路径；
- `EXPLAIN QUERY PLAN` 命中设计索引。

---

# M4：记账快速通道与并发识别

**预计：核心 4–6 人日；可选 OCR 4–6 人日。**

## M4-1 本地确定性文本解析器

建议新增：

- `client/lib/services/automation/deterministic_bill_parser.dart`
- 按渠道拆分规则测试数据。

适用：

- 银行短信；
- 微信/支付宝支付成功通知；
- 格式稳定的退款到账通知。

输出包含：

```text
amount
type
time
merchant/account hint
externalId
settlementStatus
confidence
matchedRuleId
```

只有高置信且通过现有 `AutoBookPolicy` 才允许跳过 LLM。中置信结果只作为 LLM prompt hint。

## M4-2 影子验证

第一阶段只记录：

- 规则是否命中；
- 规则结果与 LLM 结果是否一致；
- 金额、类型、时间、externalId 的结构化比较；
- 不记录原始文本。

上线门槛建议：

- 金额准确率 ≥ 99.9%；
- 收支方向准确率 ≥ 99.9%；
- 已结算状态准确率 ≥ 99.5%；
- false-positive 自动入账率接近 0；
- 样本覆盖不少于 1,000 条脱敏事件或足够的真实测试周期。

## M4-3 Recognition Pool

- 最大并发初始设置为 2；
- 每个事件有 deadline；
- 相同 eventKey 单飞；
- 同一内容 hash 可共享 in-flight 识别结果；
- 提交仍按 ledgerId 串行；
- 提交前重新运行窄范围语义判重。

## M4-4 图片预处理

为 AI 请求生成临时副本：

- 修正 EXIF 方向；
- 长边限制 1600–2048px；
- JPEG 质量 80–85；
- 不覆盖用户原图；
- 本地附件仍可保留原始文件或内容寻址副本。

后台场景不得依赖容易冻结的长平台通道；需在 vivo 真机验证 Dart isolate、原生压缩或服务端压缩哪种更稳定。

## M4-5 可选本地 OCR

建议顺序：

```text
ML Kit OCR
  → deterministic parser
  → text relay
  → 低质量/版式复杂时 vision fallback
```

需要单独评估 APK 体积、首次模型下载、中文识别率和后台稳定性。OCR 不应阻断原视觉模型路径。

## M4-6 Prompt 压缩

- 不无条件把全部分类、全部账户写入 prompt；
- 根据渠道、商户关键词、最近使用频率选 Top-N；
- 保留“其他”兜底；
- 服务端已有 token usage，应比较准确率和耗时；
- 自定义 prompt 用户必须继续兼容。

### M4 验收

- 常见高置信文本无需网络即可进入候选或本地入账；
- 并发 2 时同账本跨来源无重复；
- AI 图片上传体积中位数下降 ≥ 60%；
- OCR/规则关闭后可立即回退旧路径；
- 快速通道必须受影子模式和 feature flag 控制。

---

# M5：用户体验与首页性能

**预计：5–7 人日**

## M5-1 极速手动记账

建议新增可配置入口：

```text
金额优先
→ 最近/常用分类 Chips
→ 默认账户
→ 一键保存
```

功能：

- 打开后金额输入自动聚焦；
- 显示最近使用分类；
- 记住上次账户；
- 支出/收入左右切换；
- 支持“重复上一笔”；
- 中间按钮默认动作可选：手动、AI、相机；
- 备注、标签、附件继续作为可展开高级项。

保留现有分类优先模式，避免强制改变老用户习惯。

## M5-2 手动提交分层

核心事务：

- transaction；
- 必需 tag/override 关系；
- 作者信息。

核心事务完成后立即：

- 关闭 Sheet/Page；
- 触发触感和点击音；
- 首页由 Drift stream 立即显示。

后台工作：

- 大附件复制/压缩；
- widget 渲染；
- cloud sync；
- 非关键统计预热。

附件失败要在交易详情和状态中心可见，不能静默永久丢失。

## M5-3 自动记账状态反馈

统一状态文案：

```text
已捕获
等待 AI 服务就绪
识别中
已本地记账
待确认
疑似重复已合并
等待重试
配置异常
云端同步中/已同步
```

“已本地记账”和“已同步云端”必须分开，不让网络状态影响本地成功感知。

## M5-4 首页分页

建议首批：

- 最近 100–200 笔；或
- 当前周期 + 前后有限周期。

向下滚动按 cursor/日期增量加载。不要用 offset 深分页，优先使用：

```text
happenedAt < lastTime
或 happenedAt = lastTime 且 id < lastId
```

## M5-5 TransactionList 派生数据缓存

- `_flatItems` 仅在交易 ID、时间、金额等数据变化时重建；
- 主题、隐藏金额、提醒卡变化不重新分组；
- 每日统计可由 Repository SQL 或一次派生计算缓存；
- `accountFeatureEnabledProvider` 等列表级状态在 delegate 外 watch 一次；
- 预加载 ID → item 使用 Map，避免逐行 `where().firstOrNull`。

> 2026-09-08 第一阶段已落地：`TransactionList` 按 transactions List 引用缓存
> `_flatItems` / 日期索引；无关 rebuild 不再重新执行全量分组排序；预加载详情改为
> `Map<int, TransactionDisplayItem>` O(1) 查询；`didUpdateWidget` 增加 identity 快路，
> 避免重复分配全量交易 ID。回归测试：
> `test/widgets/transaction_list_cache_test.dart`。首页分页（M5-4）仍未实施。

### M5 验收

- 无附件手动提交 P95 ≤ 250ms；
- 1万笔首页只加载首批窗口；
- 普通主题/提醒卡 rebuild 不重新扫描完整交易列表；
- 新交易本地落库后立即出现在首页；
- 失败附件有可见状态和重试入口。

---

# M6：同步与服务端优化

**预计：3–5 人日**

## M6-1 统一同步触发

普通本地 mutation：

```text
LocalRepository
→ ChangeTracker local_changes
→ SyncCoordinator debounce
→ SyncEngine.triggerAutoSync
```

`PostProcessor` 只负责 UI refresh 和标记 changed，不再直接发起一轮完整 sync。用户手动点击同步可走 immediate 路径。

需要保留：

- per-ledger push single-flight；
- user-global push single-flight；
- fullPush/fullPull 单飞；
- 现有 LWW 和 projection 契约。

## M6-2 附件直接查询

将：

```text
查询账本全部 transactions
→ 收集 txIds
→ IN 查询附件
```

改为 JOIN：

```sql
SELECT a.*
FROM transaction_attachments a
JOIN transactions t ON t.id = a.transaction_id
WHERE t.ledger_id = ?
  AND a.cloud_file_id IS NULL;
```

## M6-3 云端账本初始化状态缓存

- 本 session 已确认远端存在后，普通增量同步不必每次 list；
- 仅首次绑定、明确 404、服务端重建、用户手动完整同步时重新验证；
- 缓存失败必须保守走增量，不能错误 fullPush。

## M6-4 服务端 HTTP 连接池

在 FastAPI lifespan 创建共享 `httpx.AsyncClient`：

- keep-alive；
- 限制最大连接数；
- provider URL 可动态变化；
- shutdown 时关闭；
- 保留 `AI_HTTP_VERIFY_SSL` 行为。

测试需要覆盖不同 provider、参数自适应摘除和 timeout。

> 2026-09-08 已落地：AI chat / vision / STT / embedding / SSE 共用进程级
> `httpx.AsyncClient`，上限 32 连接、16 keep-alive、30s keep-alive expiry；
> timeout 仍按每次能力调用显式传入，动态 provider origin 与 SSL 校验配置保持。
> FastAPI startup 预热、shutdown 关闭，同时补齐原有 MCP internal client 的 shutdown
> 释放。单测覆盖跨 provider 复用、参数摘除、独立 timeout 与关闭；本机纯 client
> 构造微基准：新建/关闭约 7.41ms/次，共享池 getter 约 0.0015ms/次（不含网络）。

## M6-5 AI 日志异步化

推荐可靠 outbox：

1. 请求内快速写一条日志/任务状态；
2. 图片写入临时 spool；
3. 后台 worker 完成图片归档和扩展字段；
4. 失败可重试；
5. 不影响主响应。

较小改动方案：先使用线程池执行同步写盘，降低 event loop 阻塞。完整 outbox 作为第二步。

> 2026-09-08 第一阶段已落地：`ask`、Web 图片解析与 App Relay 的文本/图片/
> 批量图片/STT 日志统一经 `asyncio.to_thread` 执行，SQLite commit 与图片写盘不再
> 阻塞 FastAPI event loop；仍 await 写入完成，保留原有“响应前日志已可靠落地”语义。
> 持久化 outbox/spool、失败重试和彻底移出响应尾延迟仍为第二阶段。

### 同步改动硬约束

服务端修改前必须遵守：

- `server/docs/SYNC_ARCHITECTURE.md`；
- `sync_changes` 只 INSERT；
- 新代码不得主动写 `ledger_snapshot`；
- user-global 与 ledger-scoped 的 `ledger_id` 通道不能混用；
- `change_id` 必须全局单调；
- rename cascade 两条写路径保持一致；
- 同账本 materialize 必须持有 ledger lock。

### M6 验收

- 单次 mutation 不出现重复完整 sync；
- 附件查询不扫描账本全部交易；
- AI Relay 并发测试连接复用有效；
- 日志写盘故障不拖慢或破坏 AI 响应；
- 全量 server pytest 通过。

---

## 8. PR 拆分建议

不要以一个超大 PR 实施全部内容。建议：

| PR | 内容 | 风险 |
|---|---|---|
| PR-01 | Trace、基准工具、隐私检查 | 低 |
| PR-02 | AI Runtime readiness + typed extraction | 中 |
| PR-03 | retry/backoff + draft replay 闭环 | 高，重点测试 |
| PR-04 | runApp 前移 + Monitor 拆分 + bridge 合并 | 中 |
| PR-05 | 索引统一 + lightweight dedup query | 中 |
| PR-06 | Ai/Bill Creation Context 和批量查询 | 中 |
| PR-07 | recognition pool + per-ledger commit gate | 高，重点判重 |
| PR-08 | 本地规则解析影子模式 | 中 |
| PR-09 | 图片压缩/OCR 实验 | 中，可选 |
| PR-10 | 极速手动记账 | 中，产品体验 |
| PR-11 | 首页分页和派生缓存 | 中 |
| PR-12 | 同步触发合并、附件 JOIN | 高，需同步契约测试 |
| PR-13 | server httpx pool + AI log 异步化 | 中 |

每个 PR 必须可单独回滚，不混入无关重构或品牌改动。

---

## 9. 测试计划

## 9.1 客户端单元测试

必须新增或扩展：

- AI 配置存在但 Relay 未注入；
- noBill 与异常严格区分；
- retryable result 写 nextRetryAt；
- 草稿重试成功闭环；
- 同 eventKey 单飞；
- 同一 externalId 跨来源判重；
- recognition 并发、commit 串行；
- 数据库新装索引存在；
- v38 → 下一版本升级索引存在；
- lightweight dedup 与旧 matcher 结果一致；
- 批量多笔部分成功恢复；
- 极速手动记账软判重；
- 首页分页边界和稳定排序。

现有重点回归：

```text
client/test/services/ux_optimization_p0_p1_test.dart
client/test/services/auto_book_event_store_test.dart
client/test/services/auto_book_item_recovery_test.dart
client/test/services/semantic_dedup_matcher_test.dart
client/test/services/pending_candidate_test.dart
client/test/services/pending_candidate_event_store_test.dart
```

## 9.2 Android 原生测试

- NotificationWatcher filter/fingerprint/queue；
- SmsReceiver sender/filter/eventKey/ACK；
- ScreenTextWatcher debounce/list-page/chat-page；
- ScreenshotObserver `.pending` rename；
- queue cap 和旧格式兼容；
- 多次 bridge broadcast 合并。

## 9.3 服务端测试

重点：

```text
server/tests/test_ai_relay.py
server/tests/test_ai_provider_client_adaptive.py
server/tests/test_ai_analysis_log.py
server/tests/test_issue31_write_perf.py
server/tests/test_sync_concurrency.py
server/tests/test_projection_consistency.py
```

新增：

- 不同 entry_type 使用不同 timeout；
- 共享 AsyncClient lifecycle；
- 上游断连/超时错误码；
- 日志 outbox 失败不影响响应；
- 并发 10/50 AI Relay 请求；
- request trace_id 贯通。

## 9.4 性能测试

### 客户端

- 1k/10k/50k 交易判重；
- 1/5/20 BillInfo 批量落库；
- 20/100/200 分类上下文构造；
- 首页首批、分页、切换账本；
- 手动保存无附件/1附件/5附件；
- 10/50 自动事件 burst。

### 服务端

保留现有 nightly perf，并增加：

- 真实网络 HTTP server 而非仅 TestClient；
- PostgreSQL 场景；
- Relay 自身 overhead；
- 图片 200KB/1MB/5MB；
- 连接池开启前后比较。

---

## 10. 发布策略

## 10.1 Feature Flags

建议至少提供：

```text
auto_book_runtime_gate_v2
auto_book_retry_v2
auto_book_scheduler_v2
auto_book_local_parser
auto_book_ocr_fast_path
auto_book_image_compression_v2
home_transaction_paging_v2
sync_trigger_coalescing_v2
server_ai_log_async
```

可靠性修复稳定后可移除 flag；高风险调度和快速解析至少保留一个发布周期。

## 10.2 灰度顺序

1. 开发/测试环境；
2. 影子模式，仅采集结构化差异；
3. 内部 vivo 真机；
4. 10% 用户；
5. 50% 用户；
6. 全量。

每阶段至少观察：

- 自动入账成功率；
- noBill 率；
- pending 率；
- duplicate 率；
- retry/failed 率；
- 平均和 P95 延迟；
- 队列积压深度；
- 用户撤销/纠错比例；
- LLM 调用次数和 token；
- 电量和后台存活反馈。

## 10.3 自动回滚条件

满足任一条件暂停灰度：

- 丢账或错误 ACK；
- 重复创建率显著高于基线；
- 自动记账用户纠错率上升；
- retry 队列持续增长；
- crash-free 明显下降；
- AI 调用量异常增长；
- 首页内存或 jank 恶化；
- 同步 change 数异常膨胀。

---

## 11. 监控与诊断面板

客户端自动记账历史页可补充安全摘要：

- 捕获时间；
- 来源；
- 当前状态；
- 尝试次数；
- 下一次重试时间；
- 总耗时；
- 最慢阶段；
- 是否走规则/OCR/文本 AI/视觉 AI；
- 是否已同步云端。

不得显示原始证据，除非用户明确启用了现有原始证据留存策略。

服务端管理员面板可增加：

- provider/model P50/P95；
- timeout/429/5xx；
- Relay overhead；
- 图片大小分布；
- 参数自适应重发次数；
- 日志 outbox 堆积。

---

## 12. 工作量与人员建议

### 核心范围

| 阶段 | 人日 |
|---|---:|
| M0 观测与基线 | 2–3 |
| M1 可靠性闭环 | 3–5 |
| M2 启动与调度 | 3–5 |
| M3 SQLite 热路径 | 5–7 |
| M4 快速通道核心，不含 OCR | 4–6 |
| M5 UX 与首页 | 5–7 |
| M6 同步与服务端 | 3–5 |
| 联调、真机、灰度修复 | 3–5 |
| **合计** | **28–43** |

可选 OCR 另计 4–6 人日。

### 排期建议

- 单人串行：约 6–9 周；
- 两人并行：约 4–6 周；
- 推荐分工：
  - A：客户端自动记账/SQLite/UX；
  - B：AI Relay/同步/性能工具；
  - 共同负责 vivo 真机和跨来源判重验证。

不能为了压缩排期跳过 M1 正确性门禁。

---

## 13. 依赖与风险

| 风险 | 应对 |
|---|---|
| 并发识别造成重复创建 | per-ledger commit gate + 提交前重新判重 |
| 本地规则误判 | 影子模式、严格高置信阈值、feature flag |
| OCR 增加包体/不稳定 | 可选模块，保留 vision fallback |
| 前移 runApp 导致配置闪动 | 首帧前只保留必要主题/安全配置 |
| 异步附件造成附件丢失 | 持久化 attachment job + 可见重试状态 |
| 索引增加写放大 | 基于 query plan 和基准选择 |
| Prompt Top-N 降低准确率 | A/B 对比，保留全量 fallback |
| AI 日志异步后进程异常丢日志 | 持久化 outbox/spool，不用纯内存任务 |
| 同步触发重构破坏契约 | 遵守 SYNC_ARCHITECTURE，全量 pytest，多账本测试 |
| OriginOS 后台限制 | 真机测试、队列持久化、WorkManager/前台策略评估 |

---

## 14. 首批建议执行清单

以下为推荐的第一迭代，预计 8–12 人日：

### 第一批必须完成

- [x] M0 最小 Trace；
- [x] AI Runtime readiness；
- [x] typed extraction outcome；
- [x] retryable result 统一 `markRetry`；
- [x] draft replay 经过 Coordinator；
- [x] Relay 未就绪不 ACK 回归测试；
- [x] `runApp` 前移；
- [x] Monitor enable 与 drain 拆分；
- [x] 客户端文本/图片 deadline；
- [x] `_ensureIndexes()`；
- [x] 最近 24h 轻量 baseline；
- [x] lightweight dedup query；
- [x] BillCreation 分类单查询。

### 第一批暂不做

- [ ] 不先做 OCR；
- [ ] 不先做大规模 UI 改版；
- [ ] 不直接开放多并发提交；
- [ ] 不重写同步架构；
- [ ] 不先优化 FastAPI 普通 CRUD；
- [ ] 不删除旧路径和 feature flag。

---

## 15. 实施验收记录(2026-09-06)

### 代码级验收结论

| 验收项 | 命令 / 方法 | 结果 |
|---|---|---|
| 客户端全量回归 | `flutter test`(Flutter 3.27.3) | 通过:`774 passed / 1 skipped` |
| 首批专项回归 | `flutter test test/services/automation/auto_book_transient_retry_test.dart test/data/indexes_migration_test.dart test/services/automation/auto_book_trace_test.dart` | 通过:13 项 |
| 服务端全量回归 | `.venv/Scripts/python.exe -m pytest tests/ -q` | 通过:517 项 |
| Relay timeout 分档 | `pytest tests/test_ai_relay.py::test_relay_upstream_timeout_per_capability tests/test_issue31_write_perf.py -q` | 通过:6 项 |
| M1 故障注入 | 真实 Drift + AutoBookCoordinator,临时验收测试(未提交) | 100 次注入后:100 个唯一事件全部保留为 `retry`,`nextRetryAt` 100% 非空,`attemptCount` 均为 1,无丢账/重复 |
| M3 判重基准 | 内存 SQLite,50 次采样 P95,`getDedupCandidates` 固定返回 200 条 | 1k:1ms;10k:2ms;50k:1ms,未随历史规模线性放大 |
| Trace 隐私 | `auto_book_trace_test.dart` 全量日志断言 | 未出现短信正文、金额、流水号等测试原文 |
| Diff 空白检查 | `git diff --check` | 通过 |

### 服务端合成性能烟测

条件:内存 SQLite + FastAPI TestClient,`REGISTRATION_ENABLED=true`;不代表生产网络和 PostgreSQL。

```text
dataset_size: 500
read_samples: 50
write_success_rate: 100%
write_conflict_rate: 0%
write_p95_ms: 9.897
read_p95_ms: 10.840
```

### 验收补充

- M1-1 补齐“Relay 晚于首轮 drain 变 ready”的恢复路径:`AiRuntimeCoordinator.markReady()` 后会重调度短信 / 通知 / 截图 / 屏幕文本四路原生队列,避免首轮 8 秒等待超时后必须重启 App。
- 本轮改动过的 Dart 文件已单独执行 `dart format`;未把仓库中大量历史未格式化文件卷入本专项。
- 全仓 `flutter analyze` 与 `ruff check .` 均存在大量历史告警,不能作为本次增量是否通过的可靠门禁;本次以编译、全量测试、专项测试和 `git diff --check` 为代码级验收依据。

### 尚未达到的发布级验收

- 尚未在 vivo / OriginOS 真机测量冷启动 P95、首帧、端到端自动记账 P95、图片本地等待 P95 与 jank 率;`§5` 的真实性能指标仍留空。
- 未执行 Android 原生单测/仪器测试和进程被杀五阶段实测;当前正确性结论来自 Flutter 单元测试与持久化队列契约审查。
- M0 的 `native_capture` / `native_filter` / `native_enqueue` / `native_ack` 与 `queue_depth` 尚未接入。
- M2-3 bridge 合并和 M2-4 公平队列按首批范围暂不做;50 条积压的真实设备行为仍需后续实测。
- 服务端性能烟测仍为内存 SQLite + TestClient,生产 PostgreSQL / 真实网络需使用 nightly 环境。

---

## 16. 文档维护规则

- 每完成一个 PR，更新对应任务状态和实测数据；
- 指标调整必须保留旧值和调整原因；
- 实施中发现与本计划冲突的同步契约，以 `server/docs/SYNC_ARCHITECTURE.md` 为准；
- 当前工作区中 `AGENTS.md` 引用的部分总计划文档缺失，本文件暂作为 UX/性能专项执行依据；
- 后续恢复总开发计划时，应在总计划中链接本文，不重复维护两份任务状态；
- 未经用户确认不得执行 git commit；本文件创建本身不代表批准实施全部代码改动。

---

## 17. 状态跟踪模板

| ID | 任务 | 状态 | PR/Commit | 基线 | 优化后 | 备注 |
|---|---|---|---|---:|---:|---|
| M0-1 | 自动记账 Trace | 部分完成 | 未提交 |  |  | 客户端主链已打通:`auto_book_trace.dart` + Zone 传递,阶段 `claim`/`provider_call`/`persist`/`event_terminal`,字段按白名单、无原文。原生侧阶段(`native_capture`/`native_ack`)与 `queue_depth` 未接入(要改四个 Monitor + 原生),留待续做。测试 `test/services/automation/auto_book_trace_test.dart`(5 项) |
| M1-1 | AI Runtime readiness | 已完成 | 未提交 |  |  | Relay 未就绪 → `relay_not_ready`(transient),不再退化成「不是账单」;Runtime 晚于首轮 drain 变 ready 时会重调度四路原生队列。`applyFailureCode` 仍无调用方(可选续做) |
| M1-2 | Typed extraction | 已完成 | 未提交 |  |  | `AiExtractionOutcome` + `ExtractionStatus` 取代「空 list 表示失败」;瞬态失败 → `retryableFailure` |
| M1-3 | Retry contract | 已完成 | 未提交 |  |  | Coordinator 对 retryable 结果统一走 `markRetry`(30s→2m→8m→30m→2h),避免 `nextRetryAt=null` 忙循环;100 次故障注入验收通过 |
| M1-4 | Draft replay 闭环 | 已完成 | 未提交 |  |  | 草稿重放经 Coordinator claim,复用同一套幂等/退避 |
| M2-1 | runApp 前移 | 已完成 | 未提交 |  |  | 重活移到首帧之后 |
| M2-2 | Monitor 拆分 | 已完成 | 未提交 |  |  | enable 与 drain 分离,启用不再阻塞在积压清空上 |
| M2-3 | Bridge 合并 | 待开始 |  |  |  | 第一批暂不做 |
| M2-4 | 公平队列 | 待开始 |  |  |  | 第一批暂不做 |
| M2-5 | Deadline | 已完成 | 未提交 |  |  | 客户端 40/65/65/130s,服务端上游 35/120/60/60s(每档小 5s,服务端先放弃)。测试 `server/tests/test_ai_relay.py::test_relay_upstream_timeout_per_capability` + `test/services/automation/auto_book_transient_retry_test.dart` |
| M3-1 | 统一索引 | 已完成 | 未提交 |  |  | `_ensureIndexes()` 让新装/升级两条路径索引一致;`test/data/indexes_migration_test.dart` 钉住索引集合 |
| M3-2 | 轻量判重查询 | 已完成 | 未提交 |  |  | 判重候选查询命中 `idx_transactions_ledger_type_time` 且不落 TEMP B-TREE;内存 SQLite P95:1k=1ms,10k=2ms,50k=1ms(非真机) |
| M3-3 | 基线池复用 | 已完成 | 未提交 |  |  | 最近 24h 轻量 baseline,替代全量拉取 |
| M3-4 | Context 并行加载 | 待开始 |  |  |  | 第一批暂不做 |
| M3-5 | BillCreationContext | 已完成 | 未提交 |  |  | 分类单查询取代逐笔 1+N |
| M3-6 | 多笔批量落库 | 待开始 |  |  |  | 第一批暂不做 |
| M4-1 | 本地规则解析 | 待开始 |  |  |  |  |
| M4-2 | 规则影子验证 | 待开始 |  |  |  |  |
| M4-3 | Recognition Pool | 待开始 |  |  |  |  |
| M4-4 | 图片预处理 | 待开始 |  |  |  |  |
| M4-5 | 本地 OCR | 可选 |  |  |  |  |
| M4-6 | Prompt 压缩 | 待开始 |  |  |  |  |
| M5-1 | 极速手动记账 | 待开始 |  |  |  |  |
| M5-2 | 手动提交分层 | 待开始 |  |  |  |  |
| M5-3 | 状态反馈 | 待开始 |  |  |  |  |
| M5-4 | 首页分页 | 待开始 |  |  |  |  |
| M5-5 | 列表派生缓存 | 部分完成 | 未提交 | 每次 build O(N) 分组 + 预加载逐行查找 | 同 List 引用 O(1) 复用 | 第一阶段完成；首页分页仍待 M5-4 |
| M6-1 | 同步触发统一 | 待开始 |  |  |  |  |
| M6-2 | 附件 JOIN 查询 | 待开始 |  |  |  |  |
| M6-3 | 云端账本状态缓存 | 待开始 |  |  |  |  |
| M6-4 | Server HTTP 连接池 | 已完成 | 未提交 | 每次调用新建 AsyncClient（本机约 7.41ms/次，不含握手） | 进程池 getter 约 0.0015ms/次 | 32/16 连接限制；动态 origin/timeout/SSL 回归测试 |
| M6-5 | AI 日志异步化 | 部分完成 | 未提交 | 同步 DB/图片 I/O 阻塞 event loop | I/O 在线程池执行 | 仍 await；可靠 outbox/spool 待第二阶段 |
| M6-6 | Web 重复交易原始证据对比 | 待开始 |  | DuplicateRecord 无 evidence link；raw evidence 无 transaction 关联；截图未进入 raw evidence 通道 | 计划新增 link/assets、admin compare API、对比抽屉与审计 | 详细实施方案见 `docs/performance-followup-implementation-plan.md` 第 8 章 |

> 「基线 / 优化后」两列需真机实测填写(冷启动首帧、事件端到端 P95、判重查询
> 耗时等)。第一批改动目前只在单元测试层验证:`flutter test`(客户端)与
> `pytest tests/`(服务端)全绿,尚未做真机测量,因此两列留空。

> 2026-09-08 性能扫描修复验证：服务端 `python -m pytest tests/` 为
> **523 passed**；客户端 `flutter test` 为 **778 passed / 1 skipped**；
> TransactionList 实现与回归测试的定向 `flutter analyze` 无问题。仍未做 Android 真机 /
> 生产 PostgreSQL 网络基准，连接池微基准仅衡量本机 client 构造开销。
