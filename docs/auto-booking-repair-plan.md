# SmartBook Client 自动记账入口、非真实消费与重复记账修复计划

> **状态**：In progress / P0-P1 核心已实现；Phase 5 与真机验收待完成
>
> **版本**：v1.1（实施中）
>
> **制定日期**：2026-09-04
>
> **范围**：仅 `client/`；第一阶段不修改 `server/`，不改变云同步协议。
>
> **原则**：本计划是实施基线。开始编码前应先确认当前工作区未提交修改仍需保留；提交 commit 仍需用户明确确认。

---

## 1. 目标与成功标准

### 1.1 核心目标

把现有“多个入口各自识别、各自去重、各自落库”的模式，修复为：

```text
一次真实账务事件 = 一个 canonical transaction
短信 / 支付通知 / 详情页 / 截图 / 图片分享 / CSV 行 = 该交易的 evidence
```

需要同时解决三类问题：

1. **非真实消费**：商品浏览、购物车、待支付、订单确认、余额提醒、账单汇总、营销/验证码等不应进入消费交易。
2. **账单与交易混淆**：月度信用卡账单、最低还款提醒、充值、还款、转账、退款不能简单按 expense 处理。
3. **重复记账**：同一笔支付从短信、通知、详情页、截图、人工录入、账单导入等多入口到达时，只保留一笔交易。

### 1.2 必须满足的验收标准

- 同一事件重放、重复广播、重复 Deep Link 不会产生第二笔交易。
- 同一笔支付的短信 + 通知 + 详情页 + 截图，最终最多产生一笔 canonical transaction，并可查看多个来源证据。
- “本期账单 / 最低还款 / 余额 / 可用额度 / 待付款 / 交易关闭”等输入默认不创建消费交易。
- 退款、还款、充值、转账与普通消费方向不同，不互相判重。
- 只有金额相同或金额接近时，不能静默丢弃；应进入待确认或显示软提醒。
- AI、数据库、进程被杀等可恢复失败，不应通过“永久标记已处理”来丢失真实账单。
- CSV 账单导入显示“新增 / 已存在 / 疑似重复 / 无效”，默认不重复导入。
- 手动记账不被自动规则静默阻断；仅在可能重复时给用户可解释的软提示。
- 不把原始短信、通知、页面文本写入云同步交易字段或普通日志。
- 第一阶段不复用 `Transaction.syncId` 作为来源去重键；保持现有 SmartBook Cloud 同步契约不变。

---

## 2. 当前实现基线

### 2.1 自动入口

| 入口 | 当前调用链 | 当前问题 |
|---|---|---|
| 系统截图 | `D:\gitee\auto-ledger\client\android\app\src\main\kotlin\com\smartbook\zhi\ScreenshotObserver.kt` → `D:\gitee\auto-ledger\client\lib\services\platform\screenshot_monitor_service.dart` → `AutoBillingService.processScreenshot` | 主要按文件路径去重；原图和分享临时副本可被当成两个事件 |
| 支付通知 | `NotificationWatcher.kt` → `NotifyMonitorService` → `processNotification` | 与短信/详情页使用不同指纹；跨来源只能依赖弱模糊候选 |
| 银行/支付短信 | `SmsReceiver.kt` → `SmsMonitorService` → `processSms` | 账单提醒、充值、还款等仍可能进入 AI；指纹缺少短信时间/消息 ID |
| 账单详情页 | `ScreenTextWatcher.kt` → `ScreenTextMonitorService` → `processScreenText` | 原始页面文本变化会产生新指纹；与其他来源没有统一交易键 |

### 2.2 相邻入口

| 入口 | 代码位置 | 当前问题 |
|---|---|---|
| 文本 Deep Link | `D:\gitee\auto-ledger\client\lib\services\platform\app_link_service.dart:509-523` | 进入 `processText` 时没有专用账单 Guard |
| 直接记账 Deep Link | `D:\gitee\auto-ledger\client\lib\services\platform\app_link_service.dart:365-481` | 直接调用 `repo.addTransaction`，绕过自动候选与跨入口去重 |
| 图片分享 | `D:\gitee\auto-ledger\client\lib\services\platform\image_share_handler_service.dart` | 分享图片被复制为时间戳临时文件，无法和原截图按内容归并 |
| AI 对话/相册/相机/语音 | `D:\gitee\auto-ledger\client\lib\services\ai\ai_chat_service.dart`、`D:\gitee\auto-ledger\client\lib\utils\image_billing_helper.dart`、`D:\gitee\auto-ledger\client\lib\utils\voice_billing_helper.dart` | 属于主动路径，但自动入账后人工再记一笔没有软提醒 |
| CSV 账单导入 | `D:\gitee\auto-ledger\client\lib\pages\data\import_confirm_page.dart` → `D:\gitee\auto-ledger\client\lib\services\data_import_service.dart` | 未使用交易号/订单号和状态字段；重复导入生成新 UUID |
| 周期交易 | `D:\gitee\auto-ledger\client\lib\services\data\recurring_transaction_service.dart` | 与真实短信/通知没有关联关系 |

### 2.3 已有能力，应保留并纳入新架构

- `D:\gitee\auto-ledger\client\lib\ai\core\prompt_builder.dart` 已有图片、短信、通知、屏幕文本 Guard。
- `D:\gitee\auto-ledger\client\lib\services\billing\pending_candidate.dart` 已有低置信度/疑似重复候选机制。
- 当前工作区对 `NotificationWatcher.kt` 增加的自身通知过滤，应保留，用于阻止“成功通知 → 再次入账”反馈循环。
- 当前工作区对 `ScreenTextWatcher.kt` 增加的聊天页黑名单和强详情关键词，应保留，作为 native 第一层预过滤。
- 当前工作区对银行包名及 `SourceChannelResolver` 的修正，应保留，但后续应避免 Kotlin/Dart 规则继续漂移。

---

## 3. 根因分析与优先级

### P0：必须先修复

#### P0-1：没有跨来源统一事件协调器

`D:\gitee\auto-ledger\client\lib\services\automation\auto_billing_service.dart:41-46` 使用多个互相独立的 processed key。短信、通知、屏幕文本、截图分别维护自己的缓存。

此外，下列服务各自实例化 `AutoBillingService`，各自拥有处理链和内存集合：

- `D:\gitee\auto-ledger\client\lib\services\platform\sms_monitor_service.dart`
- `D:\gitee\auto-ledger\client\lib\services\platform\notify_monitor_service.dart`
- `D:\gitee\auto-ledger\client\lib\services\platform\screen_text_monitor_service.dart`
- `D:\gitee\auto-ledger\client\lib\services\platform\screenshot_monitor_service.dart`
- `D:\gitee\auto-ledger\client\lib\services\platform\image_share_handler_service.dart`
- `D:\gitee\auto-ledger\client\lib\services\platform\app_link_service.dart`

结果是短信与通知可能并发读取同一份交易基线，然后各自直接插入。

#### P0-2：直接 Deep Link 绕过所有自动安全策略

`D:\gitee\auto-ledger\client\lib\services\platform\app_link_service.dart:435-444` 直接写入交易。

修复要求：

- 所有外部自动记账请求必须有 `event_id` 或 `idempotency_key`。
- 同一个 key 只能完成一次。
- 没有 key 的静默请求不得直接创建交易。
- 统一走 `AutoBookCoordinator`，禁止新的业务代码直接从自动入口调用 `repo.addTransaction`。

#### P0-3：当前语义模型无法识别“账单不是消费”

`D:\gitee\auto-ledger\client\lib\ai\core\bill_info.dart` 只有 `income / expense / transfer`，没有：

- 是否已结算；
- 是否为汇总账单；
- 是否为退款/充值/还款；
- 外部交易号；
- 商户名和商户标识；
- 时间是否为模型推断。

只靠 prompt 中的自然语言提示，无法形成可靠的本地硬闸门。

### P1：基础设施完成后修复

#### P1-1：业务级账单指纹过弱

`D:\gitee\auto-ledger\client\lib\services\automation\auto_billing_service.dart:1136-1153` 当前账单指纹接近：

```text
渠道 + 绝对金额 + 备注 + 日期
```

缺少交易方向、币种、账户、订单号、发生时间和外部 ID。备注为空时，同渠道同日同金额的两笔真实消费可能互相覆盖；使用绝对金额时，退款和支出可能被混淆。

#### P1-2：当前候选规则只做有限模糊判断

`D:\gitee\auto-ledger\client\lib\services\billing\pending_candidate.dart:83-145`：

- 只对最近 24 小时基线做主要比较；
- 金额允许 ±5%，对大额交易过宽；
- 同备注同金额的规则缺少更严格时间约束；
- 没有利用订单号、卡号后四位、币种、商户规范化；
- `AiBookkeeper._persistAll` 在同一批账单内没有把已保存/已入队项目追加回比较池，模型返回重复数组时可能双记。

#### P1-3：当前处理语义是“宁可丢一笔，也不重复”

短信、通知、屏幕文本在 AI 前标记 processed：

- `D:\gitee\auto-ledger\client\lib\services\automation\auto_billing_service.dart:668-671`
- `D:\gitee\auto-ledger\client\lib\services\automation\auto_billing_service.dart:829`
- `D:\gitee\auto-ledger\client\lib\services\automation\auto_billing_service.dart:969`

随后 monitor 对除“AI 未配置”外的结果 ACK。AI 临时失败、数据库临时异常或进程被杀可能导致真实账单永久丢失。

截图路径则在多笔交易全部处理后才标记；若进程在部分交易已写入后被杀，重试可能重复写入已成功的部分。

目标应改为：**持久化事件状态 + 每个账单项幂等提交 + 可重试**。

#### P1-4：账单导入没有状态/交易号/金额硬校验

- `D:\gitee\auto-ledger\client\lib\pages\data\import_confirm_page.dart:40-53` 没有 status/external ID 映射。
- `D:\gitee\auto-ledger\client\lib\services\import\parsers\generic_parser.dart:219-231` 忽略交易号、订单号等字段。
- `D:\gitee\auto-ledger\client\lib\pages\data\import_confirm_page.dart:850-853` 会把非法金额变成 `0.0`。
- `D:\gitee\auto-ledger\client\lib\services\data_import_service.dart:506-623` 没有统一拦截零金额/无效金额。
- `D:\gitee\auto-ledger\client\lib\data\repositories\local\local_transaction_repository.dart:427-430` 无 syncId 时生成随机 UUID，重复导入无法幂等。

#### P1-5：候选队列用户无法判断和恢复

`D:\gitee\auto-ledger\client\lib\services\billing\pending_candidate.dart` 当前候选只保存 BillInfo、来源和原因：

- 不知道命中的已有交易是哪一笔；
- 不支持多来源候选合并；
- 原始证据摘要不足；
- SharedPreferences 的读改写不是事务操作。

`D:\gitee\auto-ledger\client\lib\pages\automation\pending_confirmation_page.dart:145-152` 编辑确认时先删除旧候选，再尝试入账，失败后候选会丢失。

### P2：体验、治理和长期能力

- `D:\gitee\auto-ledger\client\lib\main.dart:129-141` 启动恢复了截图、短信、通知，但没有恢复 ScreenText monitor。
- AI 自动路径全部候选时，`BookkeepingResult.success` 只看交易 ID，可能被错误展示为“未识别到账单”。
- 当前 `SourceChannelResolver` 与 Kotlin 白名单重复维护，应建立生成或契约校验机制。
- AI 对话/手动录入没有重复软提醒。
- 周期交易与自动捕获交易没有“已由实际支付覆盖”的关系。
- 旧的 `large/anomaly` 候选文案仍在部分 l10n/UI 中，但现行规则不再产生这两类原因，应在重构时清理或明确为兼容字段。

---

## 4. 目标架构

### 4.1 分层

```text
Native capture adapters
  ├─ SmsReceiver
  ├─ NotificationWatcher
  ├─ ScreenTextWatcher
  └─ ScreenshotObserver
          ↓
AutoBookInput (统一入口 DTO)
          ↓
AutoBookCoordinator (全局串行 + 幂等 + 状态机)
          ↓
AutoBookEventStore (本地 Drift，事件/证据持久化)
          ↓
DeterministicPreFilter (便宜、隐私优先的硬过滤)
          ↓
AiBookkeeper / AiExtractionEngine (只负责提取)
          ↓
SemanticPolicy (真实消费/账单/结算状态判定)
          ↓
SemanticDedupMatcher (跨来源交易归并)
          ↓
Decision
  ├─ ignored
  ├─ pendingConfirmation
  ├─ booked
  ├─ duplicateLinked
  └─ retryableFailure
          ↓
BillCreationService (只负责合法交易写入)
          ↓
Evidence link + PostProcessor + sync
```

### 4.2 组件职责

#### `AutoBookInput`

统一承载：

- `eventKey`：原始事件幂等键；
- `source`：sms / notification / screen / screenshot / share / deeplink / import / recurring；
- `captureIntent`：automatic / userInitiated / import / recurring；
- `ledgerId`；
- 捕获时间和来源时间；
- source channel；
- 文本或图片引用；
- native 元数据（通知 key、短信时间、MediaStore ID 等）。

#### `AutoBookCoordinator`

- 单一 Provider 实例，由根 `ProviderContainer` 创建；
- 所有自动入口共用一条全局事件队列；
- 事件进入时先做 eventKey 幂等检查；
- 对同一事件/同一账本加锁；
- 只在终态后 ACK native 队列；
- AI/数据库临时失败保留事件并按退避策略重试；
- 同一事件中的多笔账单按 `(eventKey, itemIndex)` 独立幂等。

#### `AutoBookEventStore`

- 第一阶段使用本地 Drift，不进入云端同步；
- 替代分散的 processed SharedPreferences 和候选 JSON；
- 为候选、已忽略、已去重、已入账提供可查询历史；
- 原始敏感内容设置 TTL，终态只保留摘要/hash。

#### `BillCreationService`

继续负责：

- 分类匹配；
- 账户匹配；
- 币种和汇率；
- 交易实际落库；
- 标签。

不在其中加入自动入口策略，避免手动记账受到自动规则影响。

---

## 5. 数据模型计划

### 5.1 本地表 `auto_book_events`

建议把 `BeeDatabase.schemaVersion` 从 32 升至 33，并在
`D:\gitee\auto-ledger\client\lib\data\db.dart` 增加本地表。

建议字段：

| 字段 | 说明 |
|---|---|
| `id` | 本地自增 ID |
| `eventKey` | 原始事件唯一键，UNIQUE |
| `source` | 入口来源 |
| `captureIntent` | automatic / userInitiated / import / recurring |
| `ledgerId` | 目标账本 |
| `sourceChannel` | 支付宝/微信/银行等 |
| `externalId` | 订单号/交易号/短信 ID，允许为空 |
| `contentHash` | 规范化证据 hash |
| `state` | captured / processing / pending / booked / duplicate / ignored / retry / failed / expired |
| `capturedAt` | 捕获时间 |
| `sourceOccurredAt` | 来源中声明的交易时间 |
| `expiresAt` | 原始证据过期时间 |
| `attemptCount` | 重试次数 |
| `nextRetryAt` | 下次重试时间 |
| `transactionId` | 成功入账的 canonical transaction |
| `duplicateOfTransactionId` | 判重命中的已有交易 |
| `billJson` | 候选/提取摘要，不存原始正文 |
| `reason` | pending/ignored/duplicate 原因 |
| `lastError` | 脱敏后的错误摘要 |

索引：

- unique `event_key`；
- `(ledger_id, state, captured_at)`；
- `(ledger_id, external_id)`；
- `(ledger_id, content_hash)`；
- `(transaction_id)`。

### 5.2 可选表 `auto_book_event_items`

一张截图或一份导入文件可能包含多笔账单。建议在需要精确恢复时拆出子项：

- `eventId`；
- `itemIndex`；
- `semanticKey`；
- `eventKind`；
- `settlementStatus`；
- `amountMinor`；
- `currency`；
- `merchant`；
- `transactionId`；
- `state`；
- unique `(eventId, itemIndex)`。

这样截图返回 3 笔账单、进程在第 2 笔被杀时，重试只处理第 2/3 笔，不重写第 1 笔。

### 5.3 证据关联

如果一笔交易有多条来源，使用 `auto_book_event_links` 或在 event item 中保存：

```text
transaction_id = 123
  ← sms event
  ← notification event
  ← screen event
  ← screenshot event
```

不要把证据 hash 写入 `Transaction.syncId`。`syncId` 继续只表示云同步实体身份。

### 5.4 迁移策略

1. 启动时创建表；
2. 将旧 `pending_candidates_v1` 逐条迁入 `auto_book_events`，状态设为 `pending`；
3. 保留旧 key 一次版本周期，迁移成功后再删除；
4. 旧 processed fingerprint 不直接当成新 semantic key，只可作为兼容 event hash；
5. 迁移失败不得阻断应用启动，保留原 JSON 备份并记录脱敏错误。

---

## 6. 真实消费与账单语义策略

### 6.1 AI 输出字段扩展

在 `D:\gitee\auto-ledger\client\lib\ai\core\bill_info.dart` 增加或等价承载：

- `eventKind`：purchase / income / refund / transfer / repayment / recharge / fee / statement / balanceReminder / pendingOrder / unknown；
- `settlementStatus`：settled / pending / failed / cancelled / reversed / summary / unknown；
- `externalId`：订单号/交易号/流水号；
- `merchant`：规范化商户名；
- `accountHint` / `cardLast4`（如果来源包含）；
- `timePrecision`：exact / minute / date / inferred / unknown；
- `confidenceProvided`：模型是否显式返回 confidence。

保留现有 `BillType`，但不再让它承担全部语义。

### 6.2 硬闸门

| 条件 | 决策 |
|---|---|
| `statement` 或 `summary` | ignored；不创建消费 |
| 纯余额/积分/额度/账单日/还款日提醒 | ignored |
| `pendingOrder`、待付款、订单确认、交易关闭 | ignored 或 pending，不创建 expense |
| `purchase + settled` 且金额有效 | 进入去重判断 |
| `income + settled` | 进入去重判断 |
| `refund + settled` | 作为退款/收入；不能与原消费判重 |
| `transfer / repayment / recharge` 且两端账户明确 | 创建 transfer 或进入用户确认 |
| `transfer / repayment / recharge` 但账户不明确 | pending |
| `unknown`、缺金额、金额为零 | ignored/failed，不写交易 |
| 只有金额相似，没有商户/时间/外部 ID | pending 或手动软提示，不静默跳过 |

### 6.3 来源专属策略

#### 短信

- native 层继续只做可信发送者和明显垃圾过滤；
- 增加短信时间戳和分段消息 ID；
- “本期账单、最低还款、账单已出”进入 summary/repayment 语义，不按普通消费处理；
- “消费/扣款/交易成功”需要具体金额，最好还包含商户或卡号后四位。

#### 支付通知

- 保留当前自身通知过滤；
- 保存 `StatusBarNotification.key`、通知 ID、发布时间；
- 只把明确成功/到账/退款完成的通知作为高质量证据；
- “请支付、待处理、余额变化”不直接记消费。

#### 详情页

- 保留当前聊天页、强详情关键词和列表页过滤；
- 订单号/交易号优先于页面全文 hash；
- 没有明确已支付/已完成状态时，默认 pending；
- 页面只出现价格、优惠、购物车金额时，不发送自动入账。

#### 截图/图片分享

- 先按文件内容 hash / MediaStore ID 做事件级去重；
- 自动截图路径与用户主动分享路径要区分 `captureIntent`；
- 自动截图不应因“出现一个金额”就直接入账；
- 图片只识别出发票/收据/账单汇总时，按语义策略处理。

#### CSV 导入

- 导入始终先预览，不静默写入；
- 解析交易号、商家订单号、交易状态、成功退款金额；
- 明确失败/关闭/待付款状态的行不导入；
- 空金额、非法金额、零金额、页脚行不导入；
- 对无外部 ID 的行只做弱 hash，不能自动硬删除可能的真实交易。

---

## 7. 去重算法计划

### 7.1 两套 key 必须分离

#### A. `eventKey`：原始事件去重

用于判断“同一条输入是否重复到达”。

- SMS：`sender + messageTimestamp + normalizedBody`；
- 通知：`package + notificationKey/id + postTime + normalizedTitle/body`；
- 屏幕：`package + orderId/transactionId`，无 ID 时使用去除动态 UI 后的 hash；
- 截图：MediaStore ID 或图片内容 SHA-256；
- 分享：分享内容 SHA-256；
- Deep Link：调用方 `idempotency_key`；
- CSV：provider + external transaction ID，缺失时使用文件 hash + 行 hash；
- 周期：周期模板 ID + occurrence date。

#### B. `semanticKey`：真实交易归并

用于判断“不同证据是否指向同一笔交易”。不包含来源名称，以便短信和通知互相匹配。

组成优先级：

1. `provider + externalId` 完全一致：硬归并；
2. 账本 + 方向 + 币种 + 金额最小单位 + 规范商户 + 账户/卡号 + 时间：高置信；
3. 金额/币种 + 商户 + 时间接近：疑似重复，进入 pending；
4. 只有金额相同：不判重；
5. 退款/收入与支出方向不同：不判重；
6. 备注为空时，禁止使用“渠道+金额+日期”做硬去重。

### 7.2 金额和时间规范化

- 金额先转换为币种对应的最小单位整数，避免浮点误差；
- 模糊金额使用绝对误差上限 + 相对误差上限，不能固定放宽至 ±5% 所有金额；
- 商户名做大小写、空格、标点、常见渠道后缀规范化；
- 记录时间精度；模型推断的当前时间不能当作精确交易时间；
- 时区统一使用本地交易时区，落库/同步仍遵循现有 DateTime 约定。

### 7.3 决策阈值

建议初始策略：

```text
exact external ID / exact event key       → duplicateLinked
多信号高置信（商户+金额+币种+时间+账户） → duplicateLinked 或 pending（按来源质量）
金额+时间相似但缺商户/账户               → pendingConfirmation
仅金额相同                               → 不判重
```

初期宁可多进入 pending，不要用弱规则静默跳过真实消费。

### 7.4 存量重复治理

在新入口稳定后增加“重复交易扫描”功能：

- 扫描最近 90 天；
- 只展示高置信分组，不自动删除；
- 显示来源和创建时间；
- 用户选择保留交易、合并证据或删除重复；
- 合并时保留用户手动编辑内容、标签和附件。

---

## 8. 分阶段实施计划

### Phase 0：基线与保护（实施前）

**目标**：建立可回滚基线，不影响当前未提交工作。

任务：

- [x] 记录当前 `git status` 和现有未提交 diff；
- [x] 保留 `NotificationWatcher.kt`、`ScreenTextWatcher.kt`、来源映射相关未提交修改；
- [ ] 建立自动入口回归样本：短信、通知、详情页、截图、账单 CSV；
- [x] 补充当前行为测试，锁定现有正常记账路径；
- [x] 确认 `D:\gitee\auto-ledger\docs\development-plan.md` 和 `app-feature-plan.md` 是否需要恢复；当前目录中未找到这两个文件。

**退出条件**：现有 Dart 相关测试可运行；用户数据和工作区修改没有被覆盖。

### Phase 1：统一协调器和幂等状态（P0）

**目标**：先阻止跨入口并发双记和 Deep Link 绕过。

任务：

- [x] 新增 `AutoBookInput`、`AutoBookOutcome`、`AutoBookCoordinator`；
- [x] 新增 `AutoBookEventStore` 接口和 Drift 实现；
- [x] `BeeDatabase` 增加 v33 本地事件表；
- [x] 在根 `ProviderContainer` 创建唯一 Coordinator；
- [x] 所有四个自动 monitor 改为调用 Coordinator，不再各自创建核心处理状态；
- [x] `AutoBillingService` 保留为兼容适配层，事件 store 已成为主状态来源；旧 processed set 暂保留兼容。
- [x] native 队列 ACK 改为“事件到达终态后 ACK”；
- [x] 为短信/通知/屏幕队列补充来源时间和稳定事件元数据；
- [x] `smartbook://add` 增加幂等 key，并禁止无 key 的静默写入；
- [x] `smartbook://auto-billing?text=...` 增加专用 Guard；
- [x] `main.dart` 增加 ScreenText monitor 的恢复和 drain；
- [x] 同一批 AI 账单写入时维护 batch 内比较池。

**验收**：

- 同一 eventKey 重放不会产生第二个 transaction；
- SMS 与通知同时到达时只有一个 Coordinator 处理顺序；
- Deep Link 重放只返回已有结果；
- 进程在处理中被杀后可恢复，不重复已成功 item。

### Phase 2：语义安全闸门（P0/P1）

**目标**：从“AI 认为像账单”升级为“本地确认是可入账的账务事件”。

任务：

- [x] 扩展 `BillInfo` 字段和 JSON 兼容解析；
- [x] 修改默认 Prompt，要求输出 `event_kind`、`settlement_status`、`external_id`、`merchant`、`time_precision`；
- [x] 对旧模型/自定义 Prompt 做兼容：缺失字段按保守策略处理；
- [x] 新增纯 Dart `SemanticPolicy`，先硬过滤再允许 `BillCreationService`；
- [x] 增加 source-specific 规则和自动入口非交易状态过滤；阈值目前为代码常量。
- [x] 修复 AI 全部进入候选时的结果状态和通知文案；
- [x] 将“账单汇总/待支付/余额提醒”加入 ignored 状态和诊断统计；
- [x] 自动路径不再把缺失 confidence 默认无条件视为 1.0。

**验收**：

- 非真实消费样本不会创建 expense；
- 还款/转账/充值/退款不被错误归类为普通消费；
- 低置信但可能真实的事件进入 pending，而不是静默丢弃。

### Phase 3：跨来源语义去重与证据关联（P1）

**目标**：让多来源证据合并为一笔交易。

任务：

- [x] 新增 `SemanticDedupMatcher`；
- [x] 实现 external ID 精确匹配；
- [x] 实现金额、币种、商户、账户、时间的多信号评分；
- [x] 截图/分享使用内容 hash；
- [ ] 屏幕文本优先提取订单号/交易号；
- [x] 候选记录保存命中的已有交易 ID、评分和匹配理由；
- [x] 同一真实交易的多个事件写入 evidence link；
- [x] 手动记账入口增加软重复提醒；
- [ ] 周期交易增加 occurrence key 和实际支付关联建议；
- [ ] 增加存量重复扫描的只读版本。

**验收**：

- 同一支付的短信/通知/详情/截图显示为同一 canonical transaction；
- 两笔同金额但不同订单的真实消费可以同时保留；
- 退款不会被原支出去重掉；
- 用户能从交易详情看到来源证据。

### Phase 4：CSV 账单导入幂等化（P1）

**目标**：解决重复导入、失败交易和汇总行。

任务：

- [x] `ImportTransaction` 增加 external ID、provider、status、refund amount；
- [x] CSV 字段映射增加交易号/订单号/状态；
- [x] 支付宝、微信专属解析器按 provider 处理状态和退款；
- [x] 导入前生成 preview diff；
- [x] 过滤空金额、零金额、非法日期/金额和页脚；
- [x] 明确失败、关闭、待付款状态不导入；
- [x] 以 provider external ID 做幂等；
- [x] 无 external ID 时以行 hash + 批次 key 幂等，并在预览中显示重复；语义疑似重复仍待用户确认。
- [x] 导入批次写入 event store，支持失败恢复和取消。

**验收**：

- 同一文件重复导入默认新增 0 笔；
- 同一交易号重复导入显示为已存在；
- 非成功/汇总/零金额行不落库；
- 导入中断后可以继续，不重复已完成批次。

### Phase 5：候选中心与发布治理（P2）

**目标**：让用户可解释、可恢复、可调整策略。

任务：

- [x] 待确认页改为 event store 投影优先，旧 SharedPreferences 作为兼容兜底；
- [x] 支持按来源、原因、账本、日期筛选；
- [x] 显示来源摘要、命中的已有交易 ID、匹配度和候选原因；完整原证据查看待补；
- [x] 支持“入账 / 合并 / 仍记一笔 / 忽略 / 稍后”；
- [x] 编辑确认成功后再删除候选；
- [x] 增加 ignored/retry 历史；
- [x] 增加 event store 状态统计 API 和历史摘要；完整统计面板待补。
- [x] 提供 shadow/dry-run 模式，只识别不写交易；自动设置页可开关。
- [ ] 观察一个版本周期后再删除旧 SharedPreferences key。

---

## 9. 文件级实施清单

### 9.1 新增文件

- `D:\gitee\auto-ledger\client\lib\services\automation\auto_book_input.dart`
- `D:\gitee\auto-ledger\client\lib\services\automation\auto_book_coordinator.dart`
- `D:\gitee\auto-ledger\client\lib\services\automation\auto_book_policy.dart`
- `D:\gitee\auto-ledger\client\lib\services\automation\auto_book_event_store.dart`
- `D:\gitee\auto-ledger\client\lib\services\automation\semantic_dedup_matcher.dart`
- `D:\gitee\auto-ledger\client\lib\data\repositories\local\local_auto_book_event_repository.dart`
- 对应 Dart 单测和数据库迁移测试。

### 9.2 重点修改文件

- `D:\gitee\auto-ledger\client\lib\services\automation\auto_billing_service.dart`
  - 变成兼容适配层；移除各来源独立核心状态；统一 outcome。
- `D:\gitee\auto-ledger\client\lib\services\platform\sms_monitor_service.dart`
- `D:\gitee\auto-ledger\client\lib\services\platform\notify_monitor_service.dart`
- `D:\gitee\auto-ledger\client\lib\services\platform\screen_text_monitor_service.dart`
- `D:\gitee\auto-ledger\client\lib\services\platform\screenshot_monitor_service.dart`
  - 全部改为提交 `AutoBookInput`。
- `D:\gitee\auto-ledger\client\lib\services\platform\app_link_service.dart`
  - Direct add 加幂等 key并改走 Coordinator。
- `D:\gitee\auto-ledger\client\lib\services\platform\image_share_handler_service.dart`
  - 计算内容 hash，区分 share 与自动截图。
- `D:\gitee\auto-ledger\client\lib\ai\core\bill_info.dart`
- `D:\gitee\auto-ledger\client\lib\ai\core\prompt_builder.dart`
- `D:\gitee\auto-ledger\client\lib\ai\core\json_response_parser.dart`
  - 增加语义字段和保守兼容策略。
- `D:\gitee\auto-ledger\client\lib\services\ai\ai_bookkeeper.dart`
  - 接入 event/item 幂等；修复 batch 内比较池；候选与已入账状态分离。
- `D:\gitee\auto-ledger\client\lib\services\billing\pending_candidate.dart`
- `D:\gitee\auto-ledger\client\lib\pages\automation\pending_confirmation_page.dart`
  - 迁移候选存储并修复失败保留。
- `D:\gitee\auto-ledger\client\lib\services\import\bill_parser.dart`
- `D:\gitee\auto-ledger\client\lib\services\import\parsers\generic_parser.dart`
- `D:\gitee\auto-ledger\client\lib\services\import\parsers\alipay_parser.dart`
- `D:\gitee\auto-ledger\client\lib\services\import\parsers\wechat_parser.dart`
- `D:\gitee\auto-ledger\client\lib\pages\data\import_confirm_page.dart`
- `D:\gitee\auto-ledger\client\lib\services\data_import_service.dart`
  - 导入状态、外部 ID、零金额和重复预览。
- `D:\gitee\auto-ledger\client\lib\data\db.dart`
  - v33 本地事件表和迁移。
- `D:\gitee\auto-ledger\client\lib\main.dart`
  - Coordinator 初始化、ScreenText 恢复、旧数据迁移时机。

### 9.3 Native 修改文件

- `D:\gitee\auto-ledger\client\android\app\src\main\kotlin\com\smartbook\zhi\SmsReceiver.kt`
  - 传递短信时间/消息标识；队列写入保持原子顺序。
- `D:\gitee\auto-ledger\client\android\app\src\main\kotlin\com\smartbook\zhi\NotificationWatcher.kt`
  - 传递 notification key/id/post time；保留自身通知过滤。
- `D:\gitee\auto-ledger\client\android\app\src\main\kotlin\com\smartbook\zhi\ScreenTextWatcher.kt`
  - 保留当前聊天页/详情页预过滤；队列增加页面类名、捕获时间和稳定字段。
- `D:\gitee\auto-ledger\client\android\app\src\main\kotlin\com\smartbook\zhi\ScreenshotObserver.kt`
  - 使用 MediaStore ID/content hash 作为事件元数据。
- `D:\gitee\auto-ledger\client\android\app\src\main\kotlin\com\smartbook\zhi\MainActivity.kt`
  - 统一桥接元数据和 ACK 语义。

---

## 10. 测试计划

### 10.1 纯 Dart 单测

新增或扩展：

- `D:\gitee\auto-ledger\client\test\services\auto_book_coordinator_test.dart`
- `D:\gitee\auto-ledger\client\test\services\semantic_dedup_matcher_test.dart`
- `D:\gitee\auto-ledger\client\test\services\auto_book_policy_test.dart`
- `D:\gitee\auto-ledger\client\test\services\auto_book_event_store_test.dart`
- `D:\gitee\auto-ledger\client\test\services\data_import_dedup_test.dart`
- `D:\gitee\auto-ledger\client\test\data\migration_v33_auto_book_events_test.dart`

必须覆盖：

1. 同一个 eventKey 重放；
2. 同一 event 的多 item 部分成功后恢复；
3. SMS + notification 同一交易；
4. notification + screen 文本不同但订单号相同；
5. 原截图 + 分享副本内容 hash 相同；
6. 同日同金额两笔不同订单不误判；
7. 支出和退款不判重；
8. 本期账单/最低还款/余额提醒不入账；
9. 待付款/交易关闭不入账；
10. 仅金额相同不硬去重；
11. AI 全部进入 pending 时 outcome 正确；
12. Coordinator 临时失败可重试；
13. 候选确认失败后候选仍存在；
14. CSV 重复导入、状态过滤、零金额过滤；
15. Deep Link 同 idempotency key 重放只执行一次；
16. 周期 occurrence key 重复执行不重复创建。

### 10.2 Native JVM 单测

扩展：

- `D:\gitee\auto-ledger\client\android\app\src\test\java\com\smartbook\zhi\SmsReceiverTest.kt`
- `D:\gitee\auto-ledger\client\android\app\src\test\java\com\smartbook\zhi\NotificationWatcherTest.kt`
- `D:\gitee\auto-ledger\client\android\app\src\test\java\com\smartbook\zhi\ScreenTextWatcherTest.kt`

覆盖：

- 自身通知；
- 聊天页/购物车/待付款页；
- 账单汇总/还款提醒；
- 事件指纹稳定性；
- 包名和来源渠道规则一致性。

### 10.3 真机验收场景

至少在 Android 真机执行：

- 微信支付后同时收到通知和银行短信；
- 打开微信/支付宝订单详情并截图；
- 分享同一截图到 SmartBook；
- 重启 App 后 drain；
- AI 未配置、网络断开、AI 超时、进程被杀；
- 两笔相同金额的连续真实消费；
- 信用卡账单日通知和实际消费通知；
- 退款、转账、信用卡还款、充值；
- 侧载环境 Deep Link 重复唤起；
- vivo/iQOO 无障碍服务恢复。

---

## 11. 发布与回滚策略

### 11.1 Feature flags

建议增加以下本地开关，默认按阶段开启：

- `auto_book_coordinator_v1`
- `auto_book_semantic_gate_v1`
- `auto_book_cross_source_dedup_v1`
- `auto_book_import_dedup_v1`
- `auto_book_shadow_mode`

旧 `auto_book_enabled` 不再承担全部安全策略；即使关闭候选制，语义硬闸门和 event 幂等仍必须生效。

### 11.2 Shadow mode

在正式自动入账前，可运行一段时间只记录：

```text
would_book / would_ignore / would_pending / would_duplicate
```

不写交易，只保存脱敏统计，比较误判率后再打开写入。

### 11.3 回滚

- 新表和旧表并行保留一个版本周期；
- 不删除 native 队列旧字段，直到新 Coordinator 稳定；
- Coordinator 失败时保留事件，不自动回退到无幂等直接写入；
- 避免通过关闭校验开关回到“全部直接入账”的危险路径；
- 任何迁移失败不得清空候选和队列。

---

## 12. 隐私与日志要求

- native 层不得记录短信正文、通知正文和完整页面文本；
- Dart 日志不得输出原始短信/通知/页面文本和完整 Deep Link 参数；
- 只记录 source、长度、hash 前缀、状态和脱敏错误；
- 原始证据仅在待处理/待确认期间本地保留，并设置 TTL；
- 云同步只同步正常交易，第一阶段不上传自动入口原文和 event store；
- 图片附件沿用现有用户开关，自动截图删除必须等待全部 item 进入终态。

---

## 13. Definition of Done

### 架构

- [x] 所有自动入口都经过同一个 Coordinator；
- [x] 没有新的自动入口绕过 Coordinator 直接写交易；周期/导入路径的写入位于协调流程内。
- [x] eventKey 与 semanticKey 分离；
- [x] event store 状态可恢复、可重试、可查询。

### 真实消费识别

- [x] 账单汇总、余额提醒、待支付、失败订单不会创建消费；
- [x] 退款/还款/充值/转账有独立语义；
- [x] 缺失 confidence/time precision 时按保守策略处理。

### 重复记账

- [x] 同事件重放幂等；
- [x] 跨来源同交易只保留一笔；
- [x] 两笔同金额真实消费不会互相覆盖；
- [x] 手动记账有软提醒但可明确选择继续。

### 账单导入

- [x] 有交易号/订单号时可幂等；
- [x] 有状态字段过滤非成功行；
- [x] 零金额/非法行不落库；
- [x] 导入预览显示新增、重复、忽略和无效。

### 可靠性

- [x] AI/DB 临时失败可重试；
- [x] 进程被杀后不重复已成功 item；
- [x] 候选确认失败不丢候选；
- [x] ScreenText 队列能在冷启动自动恢复。

### 质量

- [x] Dart 单测通过；
- [x] Android JVM 单测通过；
- [ ] 真机多入口场景通过；
- [x] 无真实密钥或原始隐私数据进入 commit；
- [ ] 提交前获得用户确认。

---

## 14. 实施记录（2026-09-05）

### 已落地

- 统一事件协调器、Drift event store、事件子项恢复、Native 队列终态 ACK。
- 自动入口语义字段、非真实消费硬闸门、跨来源语义去重和手动软提醒。
- CSV 导入订单号/状态/退款字段、导入幂等、失败恢复和只读差异预览。
- 待确认页已改为 event store 投影优先，保留旧 SharedPreferences 候选兼容，并增加来源/原因筛选和匹配交易提示。
- 候选页增加账本/日期筛选、合并/仍记一笔/稍后决策；自动设置页增加 shadow/dry-run 开关。
- 支付宝/微信解析器增加 provider 专属订单号、状态和退款字段归一化。

### 验证结果

- `cd client && flutter test --no-pub`：734 passed，1 skipped。
- `cd client && flutter test --no-pub test/services/...`：事件幂等、候选投影、导入预览、子项恢复等 targeted suites passed。
- `cd client/android && JAVA_HOME=C:\Users\Administrator\devtools\jdk-17 gradlew.bat :app:testDevDebugUnitTest --offline`：BUILD SUCCESSFUL。
- `cd client && flutter build apk --debug --flavor dev --target-platform android-arm64 --no-pub`：APK 构建成功，产物为 `client/build/app/outputs/flutter-apk/app-dev-debug.apk`。
- `git diff --check`：通过；换行符提示为 Git 工作区既有格式提示。

### 当前风险/未完成

- Phase 5 仍缺完整统计面板、完整原证据查看，以及真机观察期治理。
- 尚未进行 vivo 真机多入口、杀进程恢复和截图权限场景验收。
- `flutter analyze` 仍受项目历史 lint 债务影响，需单独治理 info/warning。
- 本次改动尚未 commit，提交仍需用户明确确认。

## 15. 当前建议的下一步

1. **补齐 Phase 5 候选治理**：完整统计面板、完整原证据查看和策略观察期治理。
2. **执行 shadow/dry-run 观察期**：在真机上收集 event store 统计，确认误报率后再决定是否长期开放。
3. **补充 provider 专属导入样本**：支付宝/微信状态、退款和页脚的真实脱敏 CSV 回归样本。
4. **在 vivo Android 真机执行 10.3 全部场景**：重点验证通知 + 短信 + 详情页 + 截图 + 分享的跨入口归并，以及杀进程恢复。
5. **真机验收后整理 diff**，再等待用户明确确认提交；当前不执行 commit/push。
