# Kotlin 原生层对抗性测试发现报告

**攻击范围**：`client/android/app/src/main/kotlin/com/smartbook/zhi/` 原生捕获层
（`NativeAutoBookQueue`、`AutoBookTargetStore`、`BillingAppGate`/`ForegroundAppTracker`/`ScreenshotOverlay`/`UsageStatsProbe`、`SmsReceiver` 关键词口径）。
**测试文件**（全部新增，未改产品代码与既有测试）：
- `app/src/test/.../AdversarialQueueLogicTest.kt` — 队列纯逻辑，26 条
- `app/src/test/.../AdversarialTargetAndGateTest.kt` — 目标快照 + 门禁判定，25 条
- `app/src/androidTest/.../AdversarialQueueDbTest.kt` — SQLite 真实行为（模拟器 smoke35），18 条

**结果汇总**：JVM 51 条（49 绿 / 2 红）；仪器 18/18 全绿。

---

## 对抗发现（红测试，保留为证据）

### K-1【low】lossSummary 字符串插值拼 JSON，source/kind 含引号或换行即产出非法 JSON

- **证据**：`AdversarialQueueLogicTest.kt` 两条红测试
  - `lossSummary来源名含引号时会破坏JSON` — 输入 `source='sms"inject'`，产出 `{"source":"sms"inject",...}`，`JSONObject(...)` 构造抛异常
  - `lossSummary kind含换行时会破坏JSON` — 输入 `kind="a\nb"`，产出含裸换行的非法 JSON
- **源码**：`NativeAutoBookQueue.kt:219-220`（`"""{"source":"$source",...}"""` 直接插值）
- **实际影响**：消费方 `appendLossLocked`（`NativeAutoBookQueue.kt:586-597`）里 `JSONArray(raw)` 构造抛异常，被 catch 吞掉只打一条 Log — 损失摘要整体停止累积（静默降级，违反「不静默丢」的设计承诺）。
- **可达性**：当前唯一调用点在 `enqueue`/`purgeExpiredLocked` 内部，source 是固定常量（"sms"/"notification"/"screenText"/"screenshot"），kind 是 `EnqueueResult.name.lowercase()` 或字面量 `"expired"` → **现不可达**。但函数是 `public`，一旦未来把包名/路径/用户文本接进 source 参数即成真实缺陷。
- **建议**：改用 `JSONObject().put(...).toString()` 构造（与 `appendLossLocked` 的消费方式同库同构），或对两参数做 JSON 转义。

### K-2【low】identityOf 对全空通知项返回 `"|"` 而非空串，绕过空身份拒收闸

- **证据**：`AdversarialQueueLogicTest.kt` 的 `各来源身份键全空字段时返回空串而非崩溃`（该条已按现行为钉住为绿，含 HARDENING 注释）——实测 `identityOf("notification", {})` 返回 `"|"`，而 sms/screenshot/screenText 返回 `""`。
- **源码**：`NativeAutoBookQueue.kt:150-153`（notification 分支 `title + "|" + body` 无空串短路）
- **实际影响**：`enqueue`（`:238-239`）用 `identity.isEmpty()` 拒收无法识别的项；`"|"` 非空 → 两条不同的全空通知会以同一身份互相判重（enqueue 返回 duplicate 丢弃第二条）。当前 `NotificationWatcher.enqueue` 在标题与正文都取不到时才可能传入，实际不可达；若未来新调用方直接入队空通知项则可达。
- **建议**：notification 分支拼接结果为空串或仅 `"|"` 时返回 `""`。

---

## 硬化建议（绿测试钉住的可辩护但脆弱行为）

| # | 位置 | 现行为 | 风险 |
|---|---|---|---|
| K-H1 | `AutoBookTargetStore.itemFields` | state/version 不校验，未知串原样交给 Dart | Dart 侧若未来直接字符串比较，未知 state 静默变「不可写」→ 漏记 |
| K-H2 | `ScreenshotOverlay.HINTS` | 子串 `screenshot` 泛匹配，名字含该词的三方 App 被当浮层透传 | 类注释已论证「泛匹配更稳」；钉住防收紧时丢 ROM 兼容 |
| K-H3 | `BillingAppClassifier.isBillingApp` | contains 子串匹配 + 大小写敏感 | 伪装包（`com.evil.com.tencent.mm.phish`）会放行；门禁只用于降噪不涉权限，可辩护 |
| K-H4 | `NativeAutoBookQueue.enqueue` | `expiresAt = nowMs + MAX_AGE_MS` 无溢出保护 | nowMs 来自 `System.currentTimeMillis()` 实不可达；纯函数被外部复用需防御 |
| K-H5 | `ForegroundAppTracker.recentForeground` | 遇第一条超窗记录立即返回 null（不再往前找） | 环形队列按时间有序,语义正确;窗口边界由仪器/真机覆盖 |

---

## 全绿覆盖面（攻击过且行为正确）

**仪器测试（SQLite 真实行为，18/18 绿）**：
- 并发入队同事件键 8 线程 → 恰 1 条入库、7 条 duplicate（UNIQUE + `insertWithOnConflict` 语义正确）
- 并发不同键 8 线程 → 全部持久化不丢
- 单来源 500 条容量闸：第 501 条 rejectedFull + 损失摘要落盘；来源间容量独立（sms 满不挡 notification）
- 损失摘要环上限 20 条（25 次拒收后 ≤20）
- ACK 精确性：按指纹只删命中行、未知键不动队列、**跨来源不误删**、空列表 no-op
- 过期清理：入队时用过期时刻 → 下次访问被清；重复访问幂等；清理后仅剩新行
- 目标快照端到端：同批多项各带自己的 ref/version/state，互不串
- 迁移：与库内已有键共存时跳过重复只迁新键；空旧队列迁移标记置位；无时间戳旧项以 nowMs 落列且可读
- 劣质行韧性：手工塞非法 payload_json 行 → peek 跳过坏行、好行照常返回
- 批序：captured_at 升序出队；stats.oldestAt 取最小捕获时刻

**JVM 纯逻辑（49 绿）**：
- 容量裁决优先级：过期项先于满队列判定（不误报 rejectedFull）；条数闸恰好到限即拒；字节闸恰好等于上限放行、超 1 字节即拒；双闸同时命中报条数
- 身份键：各来源缺字段退化、notification 指纹优先、标题|正文回落、screenText 不误用 path、大小写敏感、空白保留（不 trim）
- materialBytes：UTF-8 计（中文 3 字节）、空对象有封套字节
- 迁移候选：跳过非对象元素、无身份项跳过、空数组、非数组 JSON（对象）不崩、保序
- isExpired：0/负/极小值为哨兵不过期
- toMap：全键保留、嵌套对象/数组值不崩
- 门禁：截图组件子串覆盖 6 家 ROM + 子进程；白名单 App 判定对象取最近真实前台；浮层透传回落到白名单；全系统层返回 null 交 UsageStats 兜底；环形队列 8 条挤出语义

**未覆盖（未能验证）**：
- `UsageStatsProbe.lastForegroundPackage` / `isGranted` 需要真实 `UsageStatsManager` + AppOps 授权，JVM 与模拟器均不可控 → 未测
- `SmsReceiver.onReceive` / `NotificationWatcher.onNotificationPosted` 的 Intent/SBN 解析链路（依赖 Telephony/SBN 系统类）→ 未测（关键词过滤纯函数由既有测试覆盖）
- 真机 ROM 行为（vivo smartshot 浮层实际包名、无障碍"一开就关"）→ 需真机
