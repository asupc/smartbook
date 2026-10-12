# SmartBook 客户端云同步引擎 — 对抗性测试发现

> 生成日期：2026-10-11
> 测试目录：`client/test/adversarial/`
> 4 个测试文件，173 条测试，**161 绿 / 12 红**；12 条红全部为 `// ADVERSE FINDING:` 确证缺陷。
> 只读语义参照：本轮**未修改任何 `lib/**` 与既有测试**；改动仅限本域 4 个测试文件 + 本报告。

运行方式（单文件）：

```bash
export PATH="$HOME/devtools/flutter-3.27.3-sdk/bin:$PATH"
cd /d/github/smartbook/client
flutter test test/adversarial/sync_push_adversarial_test.dart --reporter compact
# 其余三个同理：sync_pull_apply / change_tracker / entity_serializer
```

**基线排除**：`test/cloud/sync/sync_engine_push_merge_test.dart` 的 2 条既有失败（fake 注入器
`changes.length > 200` 恒不成立 / clear 位置错）属测试腐烂，本轮复跑仍红，**不计入也不重复报告**。

**稳定性**：4 个文件各连续跑 ≥3 轮，结果完全一致（push 29/4、pull 53/8、tracker 26/0、serializer 53/0），
无 flake；全部使用相对时间 + `BeeDatabase.forTesting(NativeDatabase.memory())` + 只读复用
`test/cloud/sync/_fakes/fake_smartbook_cloud_provider.dart`。

严重级定义：
- **严重/阻塞** = 同步链路永久卡死，非重放/删库不可恢复
- **高** = 静默数据丢失 / 推送通道整体瘫痪
- **中** = 数据滞留、同步静默停摆、会话级死锁（重启可解）
- **低** = 契约瑕疵、边界未定义、可自愈但有代价

---

## 0. 统计总览

| 文件 | 测试数 | 绿 | 红 | 红测试行号 |
|---|---|---|---|---|
| `sync_push_adversarial_test.dart` | 33 | 29 | 4 | 381 / 409 / 539 / 581 |
| `sync_pull_apply_adversarial_test.dart` | 61 | 53 | 8 | 59 / 104 / 143 / 444 / 669 / 792 / 852 / 932 |
| `change_tracker_adversarial_test.dart` | 26 | 26 | 0 | — |
| `entity_serializer_adversarial_test.dart` | 53 | 53 | 0 | — |
| **合计** | **173** | **161** | **12** | 12 条红 = 10 条发现（P-01/P-02 各含 2 个测试） |

红 = 断言"期望行为"、当前实现达不到 → 确证缺陷。绿里含 14 条 `HARDENING:`（行为可辩护但脆弱，
断言当前行为并通过）与若干 `ADVERSE:`/`ADVERSE-CANDIDATE:` 机制验证型用例（断言实际缺陷行为并通过），
归并进 §2 / §3。

---

## 1. 红色发现（10 条，12 个红测试）

### P-01 服务端 `rejected` 计数被客户端完全忽略 → 零样本拒绝被误标"已推"，静默丢数据 — **高**

- **证据**
  - 产品：`client/lib/cloud/sync/sync_engine.dart:1213`
    `final reportedRejections = result.conflictCount + result.failedCount;`
    —— 只用 conflict/failed 两个计数，`SmartBookPushResult.rejected`（服务端总拒收数）
    从头到尾没被读过（`packages/flutter_cloud_sync/.../smartbook_cloud_provider.dart:5036-5083`）。
  - 服务端确有"只加 `rejected` 不给任何 sample"的分支：
    `server/src/routers/sync/push.py:305`（ledger-scoped change 缺 `ledger_id`）、
    `server/src/routers/sync/push.py:413`（非 owner 推 ledger/ledger_snapshot）——
    两者 `rejected += 1; continue`，`conflict_count`/`failed_count`/samples 全 0。
  - 测试：
    1. `sync_push_adversarial_test.dart:381` `ADVERSE FINDING: rejected 计数 >0 但零样本 → 被拒的 change 被误标已推(静默丢失)`
       - 期望：`unpushedForLedger()` = 1（保守保留，等服务端接受）
       - 实际：**= 0**（`okChangeIds` 收下全部已发代表 → `markPushed` → 该 change 永不再推）
    2. `sync_push_adversarial_test.dart:409` `ADVERSE FINDING: 零样本拒绝路径既不触发 B1 也不累计 B3 熔断计数`
       - 期望：3 轮 3 次 POST（整批保留重推）+ `unpushed` = 1
       - 实际：**第 1 轮后 0 次 POST**（后两轮 0 请求），`unpushed` = 0
- **一句话复现**：`seedEntityWithChanges('tx-ns',1)` + `pushResultOverride = rejectCountOnly(1)` → `push()` 一次 → 本地 change 已标已推，服务端根本没收。
- **连带**：同一根因下 `sync_engine.dart:1221` 的 B1 截断保护判定 `0 < 0 = false` 不触发，
  `:1249` 的 `_pushRejectState.remove` 还把熔断计数清零 —— 这条拒绝路径同时逃过 B1 与 B3。

### P-02 B3 熔断 tripped 不可逆：文档承诺的"新 change id 解锁"路径不可达 — **中**

- **证据**
  - 产品：`sync_engine.dart:1197`
    `if (state != null && state.tripped) { ... continue; }` —— 跳过发生在**发送之前**；
    计数重置 `_countPushReject`（`:1265-1273`，比较 `prev.repChangeId == rep.id`）只对**已发送**的代表条调用
    （`:1228` 截断分支 / `:1247` 点名分支），清状态 `_pushRejectState.remove`（`:1249`）同样只对已发送条生效。
    熔断条永远进不了这三个点 → `tripped` 会话内不可逆。
  - 而文档明确承诺：`sync_engine.dart:1175-1176`（"用户对实体产生新编辑（新 change id）或本会话内该实体推送成功时解除"）、
    `:1263-1264`（"新 change id（用户再次编辑）重置计数"）。
  - 测试：
    1. `sync_push_adversarial_test.dart:539` `ADVERSE FINDING: 熔断后新 change id 无法解除熔断(文档承诺的解锁路径未实现)`
       - 期望：编辑后 `pushedBatches` = 1（重新尝试）+ `unpushed` 为空
       - 实际：**0 批 POST**（编辑产生的新 change 同样被 1197 行 continue 跳过）
    2. `sync_push_adversarial_test.dart:581` `ADVERSE FINDING: 熔断后新 change id 也不重置计数(tripped 不可逆)`
       - 期望：8 轮 = 8 批 POST（新 change id 拿全新 8 次机会）
       - 实际：**0 批**
- **一句话复现**：同一实体连续 8 轮被拒 → 熔断；随后 `update` 实体 + `recordChange`（新 change id）→ 再推 → 0 请求。
- **影响**：用户"改一下试试"无法自救，只能重启 App；与 `push:474`（绿，见 §2）叠加即会话内彻底死锁。

### U-01 服务端 `serverCursor` 回退 → 本地 cursor 被写回退 — **中**

- **证据**
  - 产品：`sync_engine.dart:1424` `await appCursor.commit(result.serverCursor);` 无条件提交；
    `sync_engine_pull.dart:38-43` `AppCursorStore.commit` 只写不校验（无 `max(local, server)`、无非负校验）。
  - 测试：`sync_pull_apply_adversarial_test.dart:59` `ADVERSE FINDING: 服务端 serverCursor 回退到本地 cursor 之前 → cursor 被写回退`
    - 期望：cursor 保持 5（单调不降）
    - 实际：**cursor = 2**
- **复现**：先拉一页 `cursor:5` → 再拉一页 `cursor:2`（含 1 条新 change）→ `appCursor.read()` 返 2。
- **影响**：已 apply 的历史被全量重放（幂等 upsert 不丢数据），且 `sync_pull_errors` 中已 `markResolved` 的错误被重新拉起。

### U-02 `serverCursor` 为负数 → 原样 commit，下一轮 `since` 为负（全量重放）— **低**（本轮新增测试）

- **证据**
  - 产品：同 U-01（`sync_engine.dart:1424` / `sync_engine_pull.dart:38-43` 均无 `>= 0` 校验）。
  - 服务端：`server/src/routers/sync/pull.py:104` 起 `server_cursor = since` 且按 `change_id > since` 过滤 ——
    负 `since` 恒命中全部历史。
  - 测试：`sync_pull_apply_adversarial_test.dart:104` `ADVERSE FINDING: serverCursor 为负数 → 原样 commit,下一轮 since 为负(全量重放)`
    - 期望：cursor ≥ 0（拒绝异常值）
    - 实际：**cursor = -3**，且机制断言证实下一轮 `scriptedPullCalls.last.since == -3`
- **复现**：cursor=5 后拉一页 `cursor:-3` → `appCursor.read()` 返 -3 → 下一次 pull 请求带 `since=-3`。

### U-03 `serverCursor` 极大 → 照单全收，此后真实变更永远拉不到（同步静默死亡）— **中**（本轮新增测试）

- **证据**
  - 产品：同 U-01，无上限/合理性校验；`sync_engine.dart:1361-1364` 探针见空页直接 `return 0`，**无报错、无告警、无 UI 提示**。
  - 测试：`sync_pull_apply_adversarial_test.dart:143` `ADVERSE FINDING: serverCursor 极大 → 照单全收,之后真实变更永远拉不到(同步静默死亡)`
    - 机制断言（绿）：`cursor: 9223372036854775807`（2^63-1）被原样 commit
    - 期望：服务端恢复正常后能拉到 `change_id=2` → `applied = 1`、cursor 回到 2
    - 实际：**applied = 0**（`since=2^63-1` 下真实 server 恒返空 → 每轮空跑，永远拉不到）
- **复现**：任意一页返回 `cursor: 9223372036854775807` → 之后即使服务端有新 change，`pull()` 恒返 0；恢复只能清 App 数据（SharedPreferences）。
- **触发面**：server bug / 反向代理串响应 / 中间人 —— 与 U-01 同属"客户端对服务端游标零校验"这一根因。

### U-04 远端 `amount=1e400` → `double.infinity` 落库 → push 批 jsonEncode 炸，推送通道瘫痪 — **高**

- **证据**
  - 产品：`sync_engine_apply.dart:103`
    `final amount = (payload['amount'] as num?)?.toDouble() ?? 0.0;` —— 无 `isFinite` 校验；
    SQLite REAL 接受 Infinity → 本地多出一条 `amount=Infinity` 的交易。
    push 侧 `entity_serializer.dart:38` 原样写进 payload、`:224-225` `toJsonString = jsonEncode(payload)` 抛
    `JsonUnsupportedObjectError`；真实 provider 整批一次编码（`smartbook_cloud_provider.dart:1790/3482`）→ 无法隔离单条。
  - 测试：`sync_pull_apply_adversarial_test.dart:444` `ADVERSE FINDING: transaction amount=1e400(JSON→Infinity)落库,毒化后续 push`
    - 期望：`encodeErr == null`（payload 可编码）
    - 实际：`JsonUnsupportedObjectError: Converting object to an encodable object failed: Infinity`
    - 前置断言全绿（证明链路）：`applied=1`、`tx.amount.isInfinite=true`（**无 error 记录、无告警**）、`pushedBatches=1`、`payload['amount']=Infinity`
- **复现**：pull 一条 `payload.amount = 1e400` → 该行登记 change → `push()` → 真实 provider `jsonEncode` 抛错。
- **备注**：`amount=NaN` 走 SQLite NOT NULL 约束报错（单条 apply 失败），Infinity 是更隐蔽的一半；
  serializer 侧同族问题已由 `entity_serializer_adversarial_test.dart:184/206/222` 固定（绿，见 §2）。

### U-05 `_resolveCategoryId` 用 `getSingleOrNull` → 同名分类两条 → pull 永久卡死 — **严重/阻塞**

- **证据**
  - 产品：`sync_engine_resolvers.dart:65` `final cat = await query.getSingleOrNull();`
    （按 `name(+kind)` 查，`categories` 表**无 name 唯一约束**，多行 → `Bad state: Too many elements`）；
    调用点 `sync_engine_apply.dart:131`（`_applyTransactionChange` 在 syncId miss 后无条件按名字解析）。
  - 同文件对照：`sync_engine_resolvers.dart:80-89` `_resolveAccountId` 已改用 `..limit(1)` + `.get()`（注释明写"重名会 throw，用 take(1) 保守"）—— **账户侧已修、分类侧漏改**。
  - 测试：`sync_pull_apply_adversarial_test.dart:669` `ADVERSE FINDING: 同名分类两条 → _resolveCategoryId 抛 StateError → pull 永久卡死`
    - 期望：`applied = 1`、cursor 推进到 2
    - 实际：**applied = 0、cursor 恒为 1**；日志实证 `Bad state: Too many elements` ← `_resolveCategoryId (sync_engine_resolvers.dart:65)` → `_applyTransactionChange (:131)` → 整页 rollback + `pull 被错误阻塞 cursor 停在 1`，错误入 `sync_pull_errors`
  - 可达性（非恶意输入）：两台设备各自 seed 同名一级分类（v19/v22 给老行补的 UUID 各不相同 → 收编 fallback 要求 `syncId IS NULL` 不命中）即可。
- **复现**：seed 一条 `餐饮` + pull 远端另一 `syncId` 的 `餐饮`（2 行）→ 再 pull 一条 `categoryName:'餐饮'` 的交易 → pull 卡死在 change_id=2，每次重拉重复抛错。

### U-06 `_applyCategoryChange` 父分类反查是**第二处** `getSingleOrNull`（修 U-05 不会顺带修好）— **严重/阻塞**（本轮新增测试）

- **证据**
  - 产品：`sync_engine_apply.dart:471-475`
    ```dart
    final parent = await (db.select(db.categories)
          ..where((c) => c.name.equals(parentName))
          ..where((c) => c.kind.equals(kind))
          ..where((c) => c.level.equals(1)))
        .getSingleOrNull();
    ```
  - 测试：`sync_pull_apply_adversarial_test.dart:792` `ADVERSE FINDING: 同名一级分类两条 → 子分类 parentName 反查父也 getSingleOrNull 抛错(另一处调用点)`
    - 期望：`applied = 1`、cursor = 2、子分类落库且 `parentId != null`
    - 实际：**applied = 0、cursor 恒为 1**；日志实证 `Bad state: Too many elements` ← `sync_engine_apply.dart:471`（`_applyCategoryChange`）→ 整页回滚 + 错误入表
  - **与 U-05 是不同调用点**：任何带 `parentName` 的远端二级分类，在"同名一级分类 ×2"常态下都会单独立即触发；只把 resolvers:65 改成 `limit(1)` 仍会在这里炸。
- **复现**：同 U-05 的两行同名分类 → pull 一条 `level:2, parentName:'餐饮'` 的分类 change。

### U-07 category `parentSyncId` 被 apply 完全忽略（只按 `parentName` 反查）— **低**

- **证据**
  - 产品：`sync_engine_apply.dart:468-477` —— payload 明明带了稳定的 `parentSyncId`，但解析父级只读 `parentName`。
  - 测试：`sync_pull_apply_adversarial_test.dart:852` `ADVERSE FINDING: category parentSyncId 被 apply 完全忽略(只用 parentName 反查)`
    - 期望：`child.parentId != null`（按 `parentSyncId` 命中父分类）
    - 实际：**null**（父分类已被改名 → `parentName` 反查 miss → 子分类成孤儿一级分类）
- **复现**：本地有 `ParentA(syncId=parent-sync-id)`；pull 子分类 `parentSyncId='parent-sync-id'` + `parentName='ParentA_OldName'` → `child.parentId == null`。
- **影响**：违背 serializer/server 侧"按 id 取名、不依赖 cascade 改写"的契约，父子关系在对端静默断裂（数据不丢但结构错）。

### U-08 budget 因 ledger 未就绪被跳过，却 `return true` → cursor 推进 → 该预算永久丢失 — **中**

- **证据**
  - 产品：`sync_engine_apply.dart:36-38` `case 'budget': await _applyBudgetChange(change); return true;`（**无条件 true**）；
    `sync_engine_apply.dart:698-703` `_applyBudgetChange` 在 `ledgerSyncId` 解析不到本地账本时直接 `return`（日志"本地未就绪,跳过"）。
    `_applyPullPage` 把它算作 applied → `_runPullLoop`（`sync_engine.dart:1424`）把 cursor 推到页尾。
  - 同型：`sync_engine_apply.dart:40-41` + `:771-776`（`_applyAccountAdjustmentChange` 同样 skip + return true）。
  - 测试：`sync_pull_apply_adversarial_test.dart:932` `ADVERSE FINDING: budget 因 ledger 未就绪被跳过,却返 true 且推进 cursor → 永久丢失`
    - 期望：cursor = 0（跳过不推进，留待 ledger 就绪后重试）
    - 实际：**cursor = 5**（budget change 落在 cursor 之后，再也不会被重拉）
- **复现**：pull 一条 `ledgerId:'NOT-YET-LOCAL'` 的 budget → `budgets` 表为空但 cursor=5；等账本随后同步下来，这条预算已拉不回（除非整体 replay）。

---

## 2. 绿色但确证缺陷（机制验证型：断言"当前缺陷行为"并通过）

这些用例当前是**绿**的——它们用断言把缺陷行为固定下来（避免未来无声漂移），缺陷本身仍然存在。

| 标签 | 严重级 | 测试（文件:行） | 固定的事实 |
|---|---|---|---|
| 熔断后服务端改判接受仍 0 POST | 高 | `sync_push:474` `ADVERSE: 熔断后服务端改判接受 → 本会话仍 0 POST,永远推不出去` | 服务端修好 + 客户端无新 change → 0 请求、`unpushed=1`；注释写明"可后置"的 UI 暴露至今没有 → 用户看到"同步完成"但计数恒 >0 |
| pull 对齐不能解除熔断 + C11 孤儿 change | 中 | `sync_push:497` `ADVERSE FINDING: pull 对齐也不能解除熔断(只有实体行被删才算"绕过")` | 空 pull 后仍 0 POST；远端 delete 后本地 upsert change 变孤儿（`buildSyncChange` 返 null → 不发送也不标记）→ `unpushed` 永久残留 |
| hasMore 恒真 → pull 无限循环 | 高 | `sync_pull:189` `ADVERSE FINDING: hasMore 恒真 + 游标不前进 → pull 无限循环(永不返回)` | `sync_engine.dart:1389` `while (hasMore)` 无迭代上限、不检测游标是否前进；实测 41 轮仍不自停，只有外部抛错才终止 |
| change.ledgerId 解析不到 → 孤儿行 | 中 | `sync_pull:295` `ADVERSE FINDING: change.ledgerId 无法解析 → tx 落 ledgerId=-1(孤儿行)` | `sync_engine_apply.dart:98-99` `int.tryParse(change.ledgerId) ?? -1`，不跳过也不回填 `payload.ledgerSyncId` |
| category 自引用 parentName | 中 | `sync_pull:560` `ADVERSE FINDING: category 自引用 parentName → 唯一一级分类从 picker 消失` | 分类成为自己的父、`level=1` 却有 `parentId`，结构自相矛盾 |
| tag 空名可落库 | 低 | `sync_pull:890` `ADVERSE FINDING: tag 空名可落库(重名/空名无唯一约束)` | 两个空名 tag 并存，UI 无法区分 |
| recordPulledFromServer 登记面缺口 | 低-中 | `sync_pull:1354`（只有 account/category/tag 打 marker）、`sync_pull:1413`（未打 marker 的 pull 实体被 legacy backfill 重推 → 2x 膨胀回归） | `sync_engine_apply.dart` 仅 `:428/:586/:661` 三处登记调用 |
| serializer Infinity/NaN 毒 payload | 高 | `entity_serializer:184`、`:206`、`:222`、`:621` | `serializeTransaction` 对 amount 无 `isFinite` 守卫 → payload 不可编码 → 整批 push 失败（与 U-04 同根，序列化侧） |
| ADVERSE-CANDIDATE：同名 syncId 跨 entityType 连坐 | 低 | `sync_push:317` | `rejectedEntitySyncIds` 只有 syncId 没有 type → 同名 budget 被一起保留重推（保守方向，不丢数据，只"该标的没标"） |
| ADVERSE-CANDIDATE：`updatedAt=null` 兜底 now 漂移 | 低 | `entity_serializer:479` | 同一行两次序列化产出不同 push 时间戳，LWW 元组不稳定 |

**已验证安全（ADVERSE-CANDIDATE 通过 = 行为可接受）**：
`sync_push:303`（rejected 含**未发送**的未知 syncId → 不连坐任何本地已发实体，`okChangeIds` 判定用 `contains` 不会误标）。

---

## 3. HARDENING（绿，断言当前可辩护行为，共 14 条）

- `sync_push:670` 熔断状态仅内存（新 SyncEngine 实例重置，重启即重试窗口）
- `sync_pull:339/356` 本设备自己推的 change 被 apply 跳过 / `updatedByDeviceId=null` 不被跳过
- `sync_pull:421` amount 为字符串 → 类型转换抛错整页回滚（不静默归零）；`sync_pull:1651` SQLite busy 不触发但错误分类仍入表
- `sync_pull:613` 有 syncId 的同名 seed 走新插 → 只造成同名重复（非自引用）
- `sync_pull:753` **同名账户两条不会卡死（`take(1)` 已修）** —— 与 U-05/U-06 形成对照，防止"统一"回 `getSingleOrNull` 时把账户侧也退回去
- `sync_pull:1692` pull 与 push 各有独立单飞锁，互不干扰
- `change_tracker:56/148/165/323` marker 幂等、action 固定 upsert、秒级 retention 精度、cleanup 无调用点
- `entity_serializer:285/629` 毫秒保留在 ISO 串里 / 顶层 `Map<dynamic,dynamic>` cast 会抛

---

## 4. 攻击清单覆盖核对

| 清单项 | 覆盖测试 | 状态 |
|---|---|---|
| push 分批 200/201/400（含 401） | `sync_push:209/218/228/236/245/256` | ✅ |
| 同实体千条 change 合并 | `sync_push:40`（1000 → 1 批 1 条 upsert，返回 1000） | ✅ |
| merged 组 markPushed 不串行 | `sync_push:132`（交错实体 changeIds 一一对应）、`:267`（1 拒 2 接受只留被拒组） | ✅ |
| B3：8 次拒后停推 | `sync_push:435` | ✅ |
| B3：服务端修好能否解除 | `sync_push:474`（绿，机制验证：不能） | ✅ |
| B3：新 change id 重置 | `sync_push:539`、`:581`（**红 P-02**） | ✅ |
| B3：跨 entityType 隔离 | `sync_push:625`、`:650`（user-global/ledger 键带 type） | ✅ |
| rejected 含未知 syncId → okChangeIds 误标 | `sync_push:303`（不连坐）、`:317`（同名跨类型连坐，绿）；零样本路径 **红 P-01** | ✅ |
| B1 样本截断整批不标 + 相邻批 | `sync_push:339`、`:352` | ✅ |
| change_tracker：recordPulled 幂等 | `change_tracker:36`、`:56`、`sync_pull:1452`（pull 侧同族） | ✅ |
| 与未推行共存不覆盖 | `change_tracker:79` | ✅ |
| cleanupPushedChanges 7 天边界 | `change_tracker:184/194/204`（7 天 ±1s）、`:231/238/254/269/294` | ✅ |
| markPushed 空/不存在/幂等/不越界 | `change_tracker:337/348/359`（不越界 lead 已测，跳过） | ✅ |
| pull serverCursor 回退 / **极大** / **负数** | `sync_pull:59`（红 U-01）、`:143`（红 U-03，**本轮补**）、`:104`（红 U-02，**本轮补**） | ✅ 补齐 |
| 未知 entityType/action 跳过不阻塞 | `sync_pull:1229/1255/1268/1284/1304` | ✅ |
| 同实体批内两次 LWW | `sync_pull:1123` 组（upsert×2 / upsert→delete / delete→upsert） | ✅ |
| serializer 金额 NaN/Infinity/负/极大 | `entity_serializer:222/184+206/228/234`（+`:242` 超长数字串溢出、`:252/257` 0/-0.0） | ✅ |
| happenedAt UTC 幂等 | `entity_serializer:266/279/285` | ✅ |
| note emoji / 超长 | `entity_serializer:296/304`（+`:313` NUL/控制字符） | ✅ |
| serializeCategory level 越界 / parentSyncId 悬空 | `entity_serializer:420/429` | ✅ |
| rate 0/负/NaN | `entity_serializer:460`（`'0'/'-1.5'/'abc'/'1e999'` + 本轮补 `'NaN'/'Infinity'`；rate 列为 TEXT，`db.dart:90`） | ✅ 补齐 |
| fromJsonString 非法输入 | `entity_serializer:579/586/591/596`（+`:601/609/629`） | ✅ |

---

## 5. 本轮改动清单（仅限本域 4 文件 + 本报告）

1. **修断言 1 处**：`sync_pull_apply_adversarial_test.dart:852`（原 740 行）——
   同一用例里先 `expect(child.parentId, isNotNull)` 后又 `expect(child.parentId, isNull)`，两条互斥，
   产品修好后第二条必挂。已删除自相矛盾的"实际行为"断言，改为注释说明（缺陷存在时红、修复后即绿）。
2. **补测试 3 条**（清单缺口 + 红测试暴露的未测调用点）：
   - `sync_pull:104` serverCursor 负数（清单"回退/极大/负数"之一）
   - `sync_pull:143` serverCursor 极大 → 同步静默死亡（清单同上）
   - `sync_pull:792` `_applyCategoryChange` 父反查第二处 `getSingleOrNull`（U-05 的同族独立调用点）
   - 附带：`entity_serializer:460` 的 rate 列表补 `'NaN'/'Infinity'` 两值。
3. **补 `// ADVERSE FINDING:` 注释 2 处**：`sync_push:581`、`sync_pull:792`（原本只有测试名带该词，注释行缺标记）。
4. **删除临时探针 2 个**：`_probe_sync_engine8_test.dart`、`_probe_sync_engine9_test.dart`（本轮前序探针，跑完即删）。
   其他 agent 的 `_probe_test.dart` / `misc_probe*` / `ui_scratch_probe_test.dart` 及各域 `FINDINGS-*.md` **未触碰**。

---

## 6. 未能验证 / 限制

- **真实 HTTP/WS 路径未覆盖**：全部结论基于 fake provider（`_fakes/adversarial_providers.dart`）与内存 SQLite；
  provider 层真实 `jsonEncode(body)` 只在 U-04 中用 `EntitySerializer.toJsonString` 等价复现，未跑真网络。
- **U-02/U-03 的"服务端侧影响"是推演**：客户端侧行为（commit 负值/极大值、下一轮 `since` 取值、空页返 0）已实测；
  服务端对负 `since` / 极端 `since` 的实际响应依赖 `server/src/routers/sync/pull.py` 源码判读（`change_id > since`），
  未在本仓起真实 server 验证。
- **P-01 的服务端触发条件**依赖 `push.py:305/413` 源码判读（两条只 `rejected += 1` 的分支），
  未构造真实 server 请求复现。
- **跨设备/多进程竞态**未测：B3 熔断为 per-instance 内存态，多 isolate / 后台任务并发 push 的计数竞争不在本轮范围。
- **既有基线失败未复验根因**：`sync_engine_push_merge_test.dart` 的 2 条既有失败按任务要求未重复报告，仅确认仍红。
