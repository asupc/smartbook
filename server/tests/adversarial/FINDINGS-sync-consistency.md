# FINDINGS —— 同步 / 数据一致性域对抗性测试

- **目标**:`D:\github\smartbook\server`(FastAPI + SQLAlchemy,SmartBook-Cloud)
- **测试目录**:`server/tests/adversarial/`(本次新增 6 个文件:`_adv_helpers.py` 脚手架 + 5 个测试文件)
- **运行**:`cd /d/github/smartbook/server && python -m pytest tests/adversarial/test_sync_push_malformed_adversarial.py tests/adversarial/test_lww_adversarial.py tests/adversarial/test_cascade_and_projection_adversarial.py tests/adversarial/test_sync_numeric_boundary_adversarial.py tests/adversarial/test_shared_ledger_adversarial.py -q`
- **统计**:106 个测试,**80 绿 / 26 红**;26 红全部为已确认缺陷(注释 `// ADVERSE FINDING`)。
- **不修改任何 `src/**` 与既有测试**;所有发现只留测试 + 本报告。
- 术语:**F-** = 缺陷(测试保持红);**H-** = 可辩护但脆弱(测试绿,注释 `HARDENING`);**U-** = 未能验证。

---

## 0. 执行摘要(按修复优先级)

| 优先级 | 编号 | 标题 | 严重级 | 影响面 |
|---|---|---|---|---|
| P0 | F-01 | 幂等判定不比对 action/payload:同 `(updated_at, device_id)` 的不同变更被静默丢弃 | **阻塞** | 数据丢失,三端分裂 |
| P0 | F-02 | 同批 rename cascade 抢占 tx 的 LWW 槽位 → 客户端交易编辑被吞 | **阻塞** | 数据丢失,移动端最易触发 |
| P0 | F-03 | 时钟偏移 clamp 把同批同实体多编辑坍缩为同一 ts → 后序编辑全部丢失 | **高** | 数据丢失,无任何告警 |
| P0 | F-04 | 非有限浮点(NaN/Infinity)可写入投影:`/sync/full` 输出非法 JSON | **高** | mobile 全量同步崩 |
| P1 | F-05 | `entity_sync_id` ≠ `payload.syncId` 时 delete 永远删不掉投影行(幽灵行) | **高** | 不可清理脏数据 |
| P1 | F-06 | 未来时间戳的 clamp 天花板随请求漂移 → 重试破坏幂等,事件流膨胀 | **中** | 事件流无界增长 |
| P1 | F-07 | rename 后陈旧交易推送把 denorm 名写回旧值(投影内 FK 双副本分裂) | **中** | web 显示旧名 |
| P1 | F-08 | tag 删除后陈旧交易推送复活悬挂 tag 引用 | **中** | 孤儿引用永久残留 |
| P1 | F-09 | 删被交易引用的分类:push 静默成功留悬挂引用,web 返回 400 | **中** | 双路径语义相反 |
| P1 | F-10 | push 到已软删账本被接受,留下幽灵投影行 | **中** | 幽灵数据复活 |
| P2 | F-11 | 金额字段长度/取值/大小写无校验,PG 上会 `value too long` | **中** | 生产环境才炸 |
| P2 | F-12 | 金额浮点精度 / 求和溢出静默变 null | **中** | 金额不可读 |
| P2 | F-13 | 多处写路径修改 projection 未取 §4.7 锁 | **中** | PG 并发竞态 |
| P2 | F-14 | push 路径币种大小写不归一(push vs web 不一致) | **低** | 分组口径分裂 |
| P3 | F-15 | 预算金额/起始日 push 侧无校验(web 侧有) | **低** | UI 语义崩坏 |
| P3 | F-16 | 未知 `entity_type` 被静默接受进事件流 | **低** | 事件流污染 |

**共同根因**:`/sync/push` 的 `SyncChangeIn.payload` 是裸 `dict[str, Any]`
(`src/schemas.py:158-173`),**没有任何字段级 schema**。web 写路径有 pydantic
模型(`WriteTransactionCreateRequest` 等)兜住类型/长度/范围,push 路径全部靠
`sync_applier` / `projection` 的**容错强制转换**(`_as_float` / `_as_int` /
`_as_str`)兜底 —— 容错方向是「静默变形」而不是「拒绝」。

---

## F-01 幂等判定不比对 action / payload:同 tuple 的不同变更被静默丢弃

- **严重级**:阻塞
- **源码定位**:`src/routers/sync/push.py:515-526`
  ```python
  if existing_tuple is not None and existing_tuple == incoming_tuple:
      # Idempotent replay (same device, same timestamp) — don't duplicate.
      accepted += 1
      continue                      # ← 不比对 action、不比对 payload
  ```
- **复现**:同 device 用同一 `updated_at` 推两次不同金额(或 upsert 后推 delete)。
  一句话:`把同一毫秒的第二次编辑再推一遍(或 create 后删除),服务端返回 accepted=1 但值不变。`
- **期望**:同 `(updated_at, device_id)` 且 payload 不同 → 应拒绝并给冲突信号;
  或按 change 级序号(revision)判定重放。
- **实际**:`accepted += 1` 后跳过 apply。投影保持旧值(例:11 而非 12);
  delete 被吞后交易仍可见(`deleted_at=None`),而客户端本地已删 → 幽灵交易。
- **测试**:
  - `test_lww_adversarial.py::test_same_tuple_different_payload_cross_request_is_lost`
    —— 期望 12,实际 11。
  - `test_lww_adversarial.py::test_same_tuple_delete_after_upsert_is_swallowed`
    —— 期望 deleted_at 非空,实际 None。
  - `test_lww_adversarial.py::test_lww_tie_same_ts_same_device_different_action_keeps_first`
- **可达性**:mobile 用 `change.createdAt`(本地编辑时刻)当 `updated_at`
  (`client/lib/cloud/sync/sync_engine.dart:837`),离线期间的连续编辑若落在同一
  毫秒/微秒即命中;也可由 clamp 坍缩人为制造(见 F-03)。

---

## F-02 同批 rename cascade 抢占 tx 的 LWW 槽位 → 客户端交易编辑被吞

- **严重级**:阻塞(mobile 高频路径)
- **源码定位**:
  - 补发点:`src/routers/sync/push.py:50-103`(`_emit_user_global_cascade_tx_changes`)
    以 `"updated_at": updated_at` bulk insert(同文件 :94);
  - 调用点:`src/routers/sync/push.py:600-613`(用 rename 的 `incoming_updated_at`);
  - 被抢占后命中 F-01 的 replay 分支(`:515`)。
- **复现**:一个批里先放「类目改名」再放「该改名影响到的交易编辑」,两者 `updated_at`
  相同。
  一句话:`离线时改了分类名顺手又改了一笔该分类下的金额,一个批推上去,金额改动消失但响应说成功。`
- **期望**:批内客户端自己的 change 必须优先于服务端派生的 cascade-only 事件;
  cascade 事件不应占用 LWW 比较键。
- **实际**:投影 amount 停在 10(客户端 amount=555),事件流里那条 tx 是 cascade 版
  payload;push 响应 `accepted=2`、`rejected=0` —— 客户端以为两条都成功。
- **测试**:`test_lww_adversarial.py::test_cascade_fanout_swallows_same_batch_client_tx_edit`
  (期望 555.0,实际 10.0)。
- **附带**:同批「rename 之后**新建**的交易沿用旧名」也是同一处补发快照遗漏
  (`test_cascade_and_projection_adversarial.py::test_new_tx_with_stale_name_same_batch_as_rename_drifts`)。

---

## F-03 时钟偏移 clamp 把同批同实体多编辑坍缩为同一 ts

- **严重级**:高
- **源码定位**:`src/routers/sync/push.py:422-424`
  ```python
  max_allowed = now + timedelta(seconds=5)
  incoming_updated_at = min(raw_updated_at, max_allowed)
  ```
  每条 change 独立计算,`now` 是请求级常量 → 超前时钟的多个**递增**时间戳全部
  坍缩到同一个 `server_now + 5s`。再叠加 F-01 的 replay 分支。
- **复现**:设备时钟快 1 小时,一个批里把同一笔交易连改三次(ts 各差 5s)。
  一句话:`手机时钟超前时,一个同步批里对同一笔交易的最后一次编辑会丢。`
- **期望**:clamp 后仍应保留批内相对顺序(LWW 决定性),或对坍缩给出冲突信号。
- **实际**:`accepted=3`、`rejected=0`、`conflict_count=0`,但投影 amount=1
  (第一次的值),客户端最后编辑=3 永久丢失。
- **测试**:
  - `test_lww_adversarial.py::test_clock_skew_single_batch_multi_edit_same_entity_collapses`
    —— 期望 3.0,实际 1.0。
  - 相关(绿,记录为 H-04):`test_clock_skew_legit_later_push_within_window_wins`
    —— clamp 天花板领先真实时钟,存在最长 5s 的「合法写入被拒」真空期。

---

## F-04 非有限浮点(NaN / Infinity)可写入投影,`/sync/full` 输出非法 JSON

- **严重级**:高
- **源码定位**:
  - `src/projection.py:54-60` `_as_float` 用裸 `float(v)`,接受 `'inf'` / `inf`;
  - `src/routers/sync/full.py:61` `json.dumps(cached, ensure_ascii=False)`
    —— **默认 `allow_nan=True`**,输出 `Infinity` 字面量(violates RFC 8259);
  - 对比 HTTP 层:`starlette.responses.JSONResponse` 用 `allow_nan=False`,
    于是同一数据在两条通道表现不同(HTTP 变 `null`,full 变非法 token)。
- **复现**:push body 里把 `"amount": 1` 换成 `"amount": Infinity`(Python
  `json` 默认接受该字面量),然后 `GET /sync/full`。
  一句话:`推一笔金额是 Infinity 的交易,新手机首次同步会解析失败。`
- **期望**:push 入口拒绝非有限浮点(`math.isfinite` 校验),或 `full` 侧
  `allow_nan=False` 提前暴露。
- **实际**:
  - 投影 `amount = inf`;
  - `/sync/full` 的 `snapshot.payload.content` 含字面量 `Infinity` → 严格 JSON
    解析器(Dart `json.decode` / JS)抛错;
  - `/read/ledgers/L01/transactions` 的 `amount` 变 `null`(金额语义丢失);
  - `NaN` 反而不进投影(SQLite NOT NULL 拒绝 → savepoint 隔离,`failed_count=1`)。
- **测试**:
  - `test_sync_numeric_boundary_adversarial.py::test_push_infinity_amount_enters_projection_and_poisons_reads`
  - `::test_snapshot_content_with_infinity_is_invalid_strict_json`
  - `::test_amount_sum_overflow_to_infinity_yields_null_in_read`(3 × 1e308 求和 → null)
  - `::test_account_initial_balance_infinity_accepted`
  - `::test_account_adjustment_balance_infinity`
  - `::test_push_budget_amount_string_inf_coerced_to_inf`
  - `::test_push_string_numeric_amounts_coerced_inconsistently`
    (`'1e400'`→inf 落库;`'0x1p3'`→0.0 静默归零)
- **说明**:同一 `_as_float` 在 account / budget / tx / adjustment 四处复用,
  是单点修复位。

---

## F-05 `entity_sync_id` ≠ `payload.syncId`:delete 永远删不掉投影行

- **严重级**:高
- **源码定位**:
  - `src/sync_applier.py:751` `payload.setdefault("syncId", sync_id)` —— 只在
    **缺键**时注入;payload 已带 `syncId` 则原样透传;
  - `src/projection.py:199` `sync_id = _as_str(payload.get("syncId"))` ——
    投影 PK 用 **payload 的值**;
  - `src/projection.py:500` `delete_tx(ledger_id, sync_id)` 的 `sync_id` 来自
    **`change.entity_sync_id`**(`sync_applier._delete_tx:300`)。两者不一致 → 删不掉。
- **复现**:推一条 `entity_sync_id='tx-A'` / `payload.syncId='tx-B'` 的 upsert,
  随后 delete `tx-A`。
  一句话:`一个 syncId 写错位,这笔交易从此删不掉、任何事件都改不动它。`
- **期望**:入口校验 `entity_sync_id == payload.syncId`(或以 `entity_sync_id`
  为唯一权威,投影忽略 payload 的 `syncId`)。
- **实际**:投影留下 `sync_id='tx-B'` 的永久幽灵行,read/统计/导出都看得到;
  delete 事件在事件流里存在(mobile 会删自己那份)但服务端行不动。
- **测试**:`test_sync_push_malformed_adversarial.py::test_push_payload_syncid_mismatch_writes_payload_syncid_into_projection`

---

## F-06 未来时间戳:clamp 天花板漂移破坏幂等,事件流膨胀

- **严重级**:中
- **源码定位**:`src/routers/sync/push.py:422-424`(`now` 每请求重取)+ F-01 的
  replay 判定。
- **复现**:同一批(含 `updated_at` 超前 1 小时)连续重试 3 次。
  一句话:`时钟超前设备的同一次推送重试三次,事件表多两行,幂等承诺失效。`
- **期望**:SYNC_ARCHITECTURE §4.2「同 `(updated_at, device_id)` 重推 = 幂等回放」。
- **实际**:clamp 值随请求漂移(`now+5s` 每次不同)→ 元组不等 → 每次都是新事件行。
  数据最终收敛(投影正确),但事件流按重试次数线性膨胀;pulled 端反复 apply 同 payload。
- **测试**:`test_lww_adversarial.py::test_future_ts_retry_breaks_idempotency_duplicate_events`
  (期望 1 行,实际 3 行)

---

## F-07 rename 后陈旧交易推送把 denorm 名写回旧值

- **严重级**:中
- **源码定位**:`src/sync_applier.py:814-843`(`_detect_and_run_rename_cascade_user`
  只在**被改名实体自身**被 push 时才跑)+ `:822-842`(`merge_with_existing_user`
  只补 None 字段,不校验 denorm 一致性 / `src/sync_applier.py:763-771` 的
  ledger-scope 同款逻辑)。
- **复现**:改类目名 → 另一台离线设备(只知旧名)推该交易的编辑。
  一句话:`改名后,离线手机推一笔旧编辑,电脑上这笔交易又显示旧分类名。`
- **期望**:tx upsert 时按 `category_sync_id` / `account_sync_id` 从权威实体行
  回填 denorm 名(或以 FK 列为准,读路径 join)。
- **实际**:`tx.category_name='Food'` 而 `category.name='Meals'` —— 同一 FK 的
  两个 denorm 副本分裂,直到下一次 rename 才自愈。
- **测试**:
  - `test_cascade_and_projection_adversarial.py::test_stale_tx_push_with_old_name_after_rename_restores_old_denorm`
  - `::test_account_rename_then_stale_tx_push_denorm_drift`
  - `::test_new_tx_with_stale_name_same_batch_as_rename_drifts`(同批新建)

---

## F-08 tag 删除后陈旧交易推送复活悬挂 tag 引用

- **严重级**:中
- **源码定位**:`src/sync_applier.py:456-476`(`_delete_user_tag` 只在 delete 时
  剥离一次)+ `merge_with_existing` 原样写回 payload 的 `tags` / `tagIds`。
- **复现**:删标签 → 离线设备推带该标签的交易。
  一句话:`删掉一个标签,离线手机推回旧数据后,交易详情里那个标签又出现了(且标签列表里没有)。`
- **期望**:tx upsert 时按 `tag_sync_ids_json` 校验引用有效性(无效引用剥离或忽略)。
- **实际**:`tag_sync_ids_json='["tag-1"]'`,`tags_csv='Travel'`,而 `tag-1` 行已删除
  —— 永久孤儿引用,`cascade_tx_rows_for_tag` 的点查会把它算进去(导致后续 cascade
  事件对着一个不存在的 tag 发)。
- **测试**:`test_cascade_and_projection_adversarial.py::test_stale_tx_push_after_tag_delete_resurrects_dangling_tag_ref`

---

## F-09 删被交易引用的分类:push 静默成功,web 返回 400

- **严重级**:中
- **源码定位**:
  - push 路径:`src/sync_applier.py:303` `_delete_user_category` —— **无关联校验**;
  - web 路径:`src/routers/write/categories.py` 的
    `_cascade_items_for_category_delete` + `src/snapshot_mutator.py:706-750`
    的家族校验 → 400;
  - 对照 account 侧 push **有**校验:`src/sync_applier.py:419` `_delete_user_account`。
- **复现**:对同一「有交易的分类」分别用 push 与 web 删除。
  一句话:`同一个删除分类的操作,mobile 上成功并在服务端留下悬挂引用,网页面板却报"该分类下有交易"。`
- **期望**:三条(account/category/tag)统一策略;至少 push 与 web 同口径。
- **实际**:push `accepted=1` + 投影 `category_sync_id='cat-p'` 悬挂(分类行已删);
  web `HTTP 400` + `"write validation failed: category has 1 transactions"`。
- **测试**:`test_cascade_and_projection_adversarial.py::test_push_and_web_path_delete_category_with_linked_tx_diverge`

---

## F-10 push 到已软删账本被接受,留下幽灵投影行

- **严重级**:中
- **源码定位**:`src/routers/sync/push.py` 的 ledger-scope 分支(`:668-715`)
  —— 无 `_is_ledger_deleted` 检查(`grep -c _is_ledger_deleted src/routers/sync/push.py` = 0)。
  对照 web:`src/routers/write/_shared.py:447-456` 明确 404
  (已有测试 `test_issue31_phantom_ledger.py::test_b2_write_to_soft_deleted_ledger_404_no_resurrection`)。
- **复现**:web 删账本 → owner 的 app 设备推一笔交易到该 external_id。
  一句话:`账本删掉之后,手机推上来的交易被接受写进投影(用户看不见),账本一旦恢复就凭空冒出来。`
- **期望**:与 web 同口径拒绝(或直接忽略并对齐客户端)。
- **实际**:`accepted=1`,投影新增行;read 路径 404/过滤使行不可见,但
  `snapshot_builder` 只过滤 `deleted_at` 不过滤账本墓碑 → mobile 全量同步可拉到。
- **测试**:`test_shared_ledger_adversarial.py::test_owner_push_to_deleted_ledger_creates_ghost_projection_row`

---

## F-11 字段长度无校验:SQLite 静默,PostgreSQL `value too long`

- **严重级**:中(生产环境相关)
- **源码定位**:
  - `src/schemas.py:158-173` `SyncChangeIn.payload: dict[str, Any]` —— 无字段 schema;
  - 列声明:`src/models.py:556` `entity_sync_id String(255)`、
    `:782` `currency_code String(16)`、`:479` `Ledger.currency String(16)`;
  - web 侧部分有校验(`WriteLedgerCreateRequest.currency: Field(max_length=16)`),
    但 `WriteTransactionCreateRequest.currency_code: str | None` **没有**。
- **复现**:push 一条 `currencyCode = "Z"*200` / `entity_sync_id` 长 400 字符。
  一句话:`一个超长币种代码在开发环境(SQLite)静默通过,在生产(PostgreSQL)会直接报错。`
- **期望**:入口按列宽校验(pydantic `max_length` 或显式 normalize/truncate)。
- **实际**:SQLite 落库 200 / 403 字符(无约束);PG 会抛
  `value too long for type character varying(16)` → 整批 500 或 savepoint 隔离。
- **测试**:
  - `test_sync_numeric_boundary_adversarial.py::test_push_overlong_currency_code_exceeds_column_declaration`
  - `::test_push_overlong_sync_id_and_entity_sync_id_exceed_columns`
  - `::test_web_overlong_currency_code_via_tx_create_also_unvalidated`

---

## F-12 金额浮点精度 / 求和溢出

- **严重级**:中
- **源码定位**:`src/models.py:743` `amount: Mapped[float]`(双精度)+
  `src/projection.py:54-60`;求和侧 `src/routers/read/ledgers.py:73`
  `float(r[2] or 0)`。
- **复现**:push `amount = 2**53 + 1`;或三笔 `1e308` 后读账本列表。
  一句话:`大额金额静默丢精度;多笔极大金额相加后,账面合计显示为空。`
- **期望**:金额用 Decimal / 字符串(对照:`UserExchangeRateProjection.rate`
  注释明确写「金额语义数据不走浮点」——交易金额却走了);或对溢出封顶/报错。
- **实际**:`2**53+1` → `9007199254740992.0`;`3 × 1e308` → SUM = inf →
  Starlette `allow_nan=False` 序列化成 `null`,`expense_total` / `balance` 全 null。
- **测试**:
  - `test_sync_numeric_boundary_adversarial.py::test_amount_2pow53_and_beyond_loses_precision_silently`
  - `::test_amount_sum_overflow_to_infinity_yields_null_in_read`

---

## F-13 多处写路径修改 projection 未取 §4.7 锁

- **严重级**:中(架构级;SQLite 下不可复现,PG 下真实竞态)
- **源码定位**(静态扫描 `tests/adversarial/test_shared_ledger_adversarial.py::test_projection_write_paths_acquire_locks_static_audit`):
  - `src/routers/read/trash.py:282`(`restore_tx`)、`:365`(`purge_tx`)、`:366`(GC)
    —— 无 `lock_ledger_for_materialize` 也无 `lock_user_global`;
  - `src/services/data_cleanup/cleaner.py:306`(`purge_tx` + GC)、
    `src/services/data_cleanup/duplicates.py:182`(`delete_tx` + GC)—— 同上;
  - `src/routers/write/ledgers.py:308`(delete_ledger)有 ledger 锁但**无 user 锁**
    —— 与 push 的 user-scope 分支交错时,账本 truncate 可与
    `rename_cascade_*` 的全表 `sync_id` UPDATE 并发命中同一批行。
  - 对照(有锁):`src/routers/write/_shared.py`、`src/routers/sync/push.py`、
    `src/routers/import_data/endpoints.py`。
- **复现**:静态审计即可(测试用源码扫描,新增无锁入口立即变红)。
  一句话:`回收站恢复、后台清理、账本删除这些入口改动投影时没有拿同步锁,PostgreSQL 上会与正常同步并发打架。`
- **期望**:§4.7「/sync/push 和 /write/* 应用 projection 之前都加事务级 advisory lock」;
  这些旁路入口应同口径(至少 ledger 锁)。
- **测试**:`test_shared_ledger_adversarial.py::test_projection_write_paths_acquire_locks_static_audit`
- **说明**:SQLite 的 `lock_*` 是 no-op,该行为**不可在测试中复现**(见「未能验证」节)。

---

## F-14 push 路径币种大小写不归一

- **严重级**:低
- **源码定位**:`src/routers/write/_shared.py:1763-1767` `_normalize_currency`
  (strip + upper + 截断 16)只作用于 web;push 侧 payload 直通
  (`src/sync_applier.py:732-733` 仅 `strip()[:16]` 用于 `ledger.currency`,
  tx/account 的币种无任何处理)。
- **复现**:push `currency='usd'` / `currencyCode='usd'` / `account.currency='usd'`。
  一句话:`网页写入存 EUR,手机推送存 eur —— 大多数读路径靠 .upper() 兜底,但按原值分组的地方会把它们当两种币。`
- **期望**:写入口统一归一。
- **实际**:`ledger.currency='usd'`、`tx.currency_code='usd'`、`account.currency='usd'`
  全部原样落库。
- **测试**:`test_sync_numeric_boundary_adversarial.py::test_push_currency_fields_are_not_normalized_to_upper`

---

## F-15 预算字段 push / web 校验不一致

- **严重级**:低
- **源码定位**:`src/schemas.py:1057` `WriteBudgetCreateRequest.amount: float = Field(gt=0)`
  / `:1065` `start_day: int | None = Field(default=1, ge=1, le=28)`;
  push 侧无对应模型。
- **复现**:push `budget.amount = -50` / `startDay = 99`。
  一句话:`手机能建出金额为负的预算,网页建不出来。`
- **期望**:两侧同口径(或者 push 侧也 clamp)。
- **实际**:push `accepted=1`,落库 `-50.0`;web 同参数 422。
  `start_day=99` 也原样落库(读端改用 `ledger.month_start_day` 故实际无害)。
- **测试**:
  - `test_sync_numeric_boundary_adversarial.py::test_push_budget_negative_amount_accepted_while_web_rejects`
  - `::test_push_budget_start_day_out_of_range_not_clamped`(HARDENING,绿)

---

## F-16 未知 entity_type 被静默接受进事件流

- **严重级**:低
- **源码定位**:`src/routers/sync/push.py:276-733` 的循环 —— entity_type 无白名单
  (`INDIVIDUAL_ENTITY_TYPES` 只决定是否走 apply);`sync_applier` 的
  `_LEDGER_MERGE_SPECS.get(...)` 未命中就跳过 apply,但 SyncChange 行已写。
- **复现**:push `entity_type='wombat'`。
  一句话:`推一个服务端完全不认识的实体类型,它会安静地写进事件表,然后永远没人能消费它。`
- **期望**:白名单校验(与 `INDIVIDUAL_ENTITY_TYPES` / `USER_GLOBAL_ENTITY_TYPES` 对齐)。
- **实际**:`accepted=1`,事件落库(无投影),pull 端 mobile 只 warning 跳过。
- **测试**:`test_sync_push_malformed_adversarial.py::test_push_unknown_entity_type_is_loosely_accepted`(HARDENING,绿)

---

## HARDENING 条目(行为可辩护但脆弱,测试绿)

| 编号 | 说明 | 测试 |
|---|---|---|
| H-01 | `poison` change 的 SyncChange 行随 savepoint 回滚 → 重放时仍是「首次见到」,再次失败。结果确定性(failed 恒为 1),客户端可据此熔断标记,但服务端无持久化 poison 标记 | `test_sync_push_malformed_adversarial.py::test_batch_replay_after_partial_failure_is_idempotent` |
| H-02 | 非法 `happenedAt` 字符串被静默替换成「服务器当前时刻」而非拒绝(`projection._parse_happened_at`)—— 容错 vs 拒绝的取舍,静默数据变形 | `::test_push_invalid_happened_at_falls_back_to_now` |
| H-03 | 未知 `entity_type` 接受(见 F-16) | `::test_push_unknown_entity_type_is_loosely_accepted` |
| H-04 | clamp 天花板领先真实时钟 → 最长 5s 内合法写入被 LWW 拒(不自锁死,等窗口过去即可;数据最终可收敛) | `test_lww_adversarial.py::test_clock_skew_legit_later_push_within_window_wins` |
| H-05 | 时钟回拨设备的同 ts 重推由 `(ts, device_id)` 元组决胜(确定性),不按到达顺序 | `::test_clock_rollback_device_same_ts_uses_device_tiebreak` |
| H-06 | push 对 amount 无范围约束(0 / 负数 / 1e308 全接受),与 web 一致 | `test_sync_numeric_boundary_adversarial.py::test_amount_zero_negative_and_huge_are_accepted` |
| H-07 | 4 位小数金额 round-trip 无损 | `::test_amount_four_decimal_places_round_trip` |
| H-08 | `txIndex` 在 int64 内接受(含负数),超 int64 → savepoint 隔离(failed_count=1,不 500) | `::test_tx_index_beyond_int64_isolated_int64_max_accepted` |
| H-09 | 预算 `startDay=99` 原样落库,但读端统一 clamp 到 [1,28] 且改用 `ledger.month_start_day`(D5),实际无害 | `::test_push_budget_start_day_out_of_range_not_clamped` |
| H-10 | `exchange_rate_override.rate` 是字符串列(不落 float),读端 `float()` + `> 0` 判定,`inf` 会通过 → 汇率表污染。仅客户端主动写非法值可达(push 侧无校验) | `::test_exchange_rate_override_rate_is_string_so_inf_possible_but_read_is_guarded` |
| H-11 | 被移除成员仍可推**自己的** user-global 资源(设计如此),owner 的 pull 按 `user_id` 过滤看不到,不越权 | `test_shared_ledger_adversarial.py::test_removed_member_user_global_push_still_allowed` |
| H-12 | 空批 / 无 ledger 的 pull / 空账本 `/sync/full` 均正常返回不炸 | `test_sync_push_malformed_adversarial.py::test_push_empty_changes_batch_is_accepted_noop`、`test_cascade_and_projection_adversarial.py::test_full_snapshot_absent_when_ledger_has_no_changes` |
| H-13 | 冲突 AuditLog 节流(TTL 1h)不使计数器失真,每次 push 都准确回报 `conflict_count` | `test_sync_push_malformed_adversarial.py::test_push_conflict_audit_is_throttled_but_counters_accurate` |
| H-14 | rename cascade 双路径(web 快路径 / push)都刷新投影 denorm | `test_cascade_and_projection_adversarial.py::test_push_and_web_path_category_rename_both_refresh_projection` |
| H-15 | 同名不同 sync_id 的分类不互相误伤(by-id 谓词正确) | `::test_rename_cascade_does_not_cross_ledger_boundary_by_name` |
| H-16 | 软删行不补发 cascade-only 事件(避免 mobile 重建已删交易) | `::test_rename_cascade_skips_soft_deleted_tx_rows` |
| H-17 | 生命周期(create→update→delete→revive)多轮后投影与事件重放一致 | `test_lww_adversarial.py::test_delete_revive_multiple_rounds_consistent` |
| H-18 | purge 后墓碑仍占 LWW 槽位 → 陈旧设备老版本被拒(不被复活) | `::test_purged_tombstone_still_blocks_stale_replay` |
| H-19 | 1000 条批量 push 全部落地、change_id 连续无断档 | `test_sync_push_malformed_adversarial.py::test_push_1000_changes_all_land_no_packet_loss` |
| H-20 | 批内 apply 失败隔离不留孤儿事件行(事件与投影原子) | `::test_push_partial_apply_failure_keeps_batch_consistent` |

---

## 未能验证(测试不可确定性复现)

1. **PostgreSQL advisory lock 的真实并发语义(§4.7)**
   `src/concurrency.py:19-25` 的 `lock_ledger_for_materialize` /
   `lock_user_global` 在 SQLite 下是 **no-op**(`dialect_name != "postgresql"` 直接
   return)。以下均**未能验证**:
   - 两个并发 push 同账本时 cascade 是否真的串行(rename × tx upsert 交错);
   - `lock_user_global` 对「owner 侧 user-global rename cascade」与「Editor 的 tx
     upsert 刷同一批行」的防抖效果;
   - **user→ledger 锁顺序契约**是否真的防住了死锁(push 批内含 user-global 变更 +
     ledger-scope 混合时的真实交叉);
   - F-13 列出的无锁入口(trash / cleaner / duplicates / delete_ledger)在 PG 下的
     实际竞态窗口。
   *建议*:如有 PG 测试环境,用 `pytest-postgresql` 或 docker-compose 起真库,
   把 `tests/adversarial/` 的并发用例重跑一遍。
2. **并发线程推送(sqlite 不可用)**
   尝试用 3 线程并发 push 同一账本 → sqlite 报
   `UNIQUE constraint failed: ledgers.user_id, ledgers.external_id`
   (两个线程同时走 auto-create 分支)。这在 PG 上由 `lock_ledger_for_materialize`
   + 唯一约束组合处理,SQLite 无法复现真实行为 → 未写成测试。
   (`test_p2_s7_s8_write_race.py` 用 monkeypatch 模拟 IntegrityError,本域并发
   未做同款,因为真实竞态的语义依赖 PG 锁。)
3. **多进程 / 多 worker 下的 `_conflict_audit_last` 节流字典**
   (`src/routers/sync/push.py:178`)是进程内字典,多 worker 部署下最坏退化为
   「每 worker 一条/小时」。属于性能而非一致性,未测。
4. **时钟回拨的跨批次行为**
   只验证了「同批坍缩」(F-03)与「同 ts tie-break」(H-05)。跨批次、跨设备、
   穿插 web 写入的时钟偏移场景需要可控时钟源(freezegun 对 FastAPI 内
   `datetime.now` 的 monkeypatch 会影响 jti/exp 生成),未做。
5. **`/sync/full` 在含 `inf` 账本上的 mobile 端实际表现**
   只验证了服务端输出非法 JSON 字面量(F-04);mobile(Dart `json.decode`)的
   具体报错路径未在 Flutter 侧端到端验证。
6. **`entity_sync_id` 长度在 PostgreSQL 的真实报错**
   只验证 SQLite 静默接受 403 字符;PG 的 `value too long` 属推断
   (列声明 `String(255)` + PG 强制 VARCHAR 长度),未在真库验证。

---

## 覆盖清单(攻击清单 → 测试映射)

| 攻击清单条目 | 覆盖情况 | 代表测试 |
|---|---|---|
| 缺字段 / 类型错 | ✅ | `test_push_missing_required_fields_returns_422_not_500`、`test_push_malformed_updated_at_never_500`(parametrize 6 种) |
| ledger_id 通道混用(user-global vs ledger-scoped) | ✅ | `test_push_ledger_scoped_without_ledger_id_is_rejected_not_applied`、`test_push_user_global_ignores_borrowed_ledger_id_channel` |
| change_id 重复/倒序/跳跃/负数/0/2^63/字符串 | ✅ | `test_push_client_supplied_change_id_and_scope_are_ignored`、`test_change_id_is_strictly_monotonic_across_batches`(客户端值被忽略,服务端自增连续) |
| 时间戳:epoch 0 / 9999 / 未来 / 同毫秒并列 | ✅ | `test_push_epoch_and_year_9999_updated_at_are_actionable`、`test_push_same_millisecond_two_devices_tiebreak_is_deterministic` |
| 批量 1000 条 / 丢包 / 部分失败 | ✅ | `test_push_1000_changes_all_land_no_packet_loss`、`test_push_partial_apply_failure_keeps_batch_consistent` |
| 重放:同 change_id / 同批整体重放 → 幂等 | ✅ | `test_replay_same_batch_is_idempotent_no_duplicate_rows`(发现 F-06:未来 ts 重放非幂等) |
| 两设备并发改同一实体(时间戳不同 / 相同) | ✅ | `test_push_later_arrival_with_older_timestamp_is_rejected`、`test_push_same_millisecond_two_devices_tiebreak_is_deterministic` |
| 删除 vs 更新竞态 | ✅ | `test_delete_then_older_upsert_does_not_revive`、`test_delete_then_newer_upsert_revives_with_full_fields`、`test_lww_series_compares_delete_and_upsert_together` |
| 时钟倒退 / 超前设备 | ✅ | `test_clock_skew_single_batch_multi_edit_same_entity_collapses`(F-03)、`test_clock_rollback_device_same_ts_uses_device_tiebreak`、`test_future_ts_retry_breaks_idempotency_duplicate_events`(F-06) |
| 软删复活(含多轮) | ✅ | `test_delete_revive_multiple_rounds_consistent`、`test_soft_deleted_row_keeps_lww_slot_over_newer_upsert_from_older_device` |
| rename + 同批引用旧名/新名(两种顺序) | ✅ | `test_cascade_fanout_swallows_same_batch_client_tx_edit`(F-02)、`test_new_tx_with_stale_name_same_batch_as_rename_drifts`(F-07)、`test_rename_after_rejected_stale_tx`(对照,绿) |
| rename 后老客户端推旧名 → 孤儿引用 | ✅ | F-07 三条 + `test_stale_tx_push_after_tag_delete_resurrects_dangling_tag_ref`(F-08) |
| 两条路径(push 与 write)rename 行为一致性 | ✅ | `test_push_and_web_path_category_rename_both_refresh_projection`(一致)、`test_push_and_web_path_delete_category_with_linked_tx_diverge`(F-09,不一致) |
| 投影 ↔ 事件重放一致(全生命周期) | ✅ | `test_projection_matches_replay_after_lifecycle_ops`、`test_projection_matches_replay_with_interleaved_entities` |
| pull 增量边界(since 等于最后一条 / 极大 / 负数 / 非数字) | ✅ | `test_pull_cursor_boundaries_exact_last_max_negative_nonnum`、`test_pull_has_more_and_cursor_pagination_no_gap`、`test_pull_cursor_ahead_of_server_returns_empty_not_error` |
| 级联删除(类目/标签/账户关联清理) | ✅ | `test_tag_delete_detaches_references_from_projection`(绿)、F-08 / F-09、`test_push_and_web_path_delete_category_with_linked_tx_diverge` |
| 被删实体在离线设备继续被引用后再次同步 | ✅ | F-07 / F-08 / `test_account_delete_guard_soft_deleted_only`(软删交易不阻塞账户删除 → 回收站恢复后悬挂) |
| trash 恢复后再 purge 的边界 | ✅ | `test_purged_tombstone_still_blocks_stale_replay`、`test_soft_deleted_row_invisible_in_full_snapshot`、`test_projection_matches_replay_after_lifecycle_ops` |
| 成员移除后离线变更再 push | ✅ | `test_removed_member_ledger_scope_push_rejected_not_auto_created`、`test_removed_member_can_no_longer_pull_ledger_data` |
| 账本删除时在线/离线成员后续同步 | ✅ | `test_ledger_deleted_editor_push_rejected`、`test_pull_after_ledger_delete_delivers_tombstone_to_owner`、`test_ledger_delete_prunes_other_members_data_visibility`、F-10 |
| lock_ledger_for_materialize 覆盖不到的入口 | ✅(静态) | F-13 `test_projection_write_paths_acquire_locks_static_audit`、`test_lock_ordering_is_user_then_ledger_in_push` |
| 数值:0 / 负 / 2^53 / 4 位小数 / NaN / Infinity / 巨整数 | ✅ | `test_sync_numeric_boundary_adversarial.py` 19 条 |
| 币种非法值 / 小写 / 超长 | ✅ | F-11 / F-14 |
| 预算级联/数值 | ✅ | F-15、`test_push_budget_negative_amount_accepted_while_web_rejects` |

### 未覆盖(时间/环境限制)

- 并发线程真实交错(见「未能验证」2)——**只有静态锁审计**代替;
- 多账本同名 sync_id 的 trash 消歧(已有既有测试 `test_tx_trash.py` 覆盖,未重复);
- attachment GC 与 rename/delete 的交错(超出本域范围,属附件域);
- WebSocket 广播内容(本域聚焦持久化状态)。

---

## 建议修复顺序

1. **F-01 + F-02 + F-03**(同一根因簇):把 replay 判定从
   `(updated_at, device_id)` 元组升级为「元组 + action + payload hash」,
   或引入单调 revision。修复 F-01 自动缓解 F-02/F-03(它们都靠 replay 分支吞数据)。
2. **F-04**:`_as_float` / `_as_float_or_none` 加 `math.isfinite` 校验并记录
   warning+拒绝;`full.py` 的 `json.dumps` 加 `allow_nan=False` 做防御性断言。
3. **F-05**:push 入口校验 `entity_sync_id == payload.syncId`(不一致直接
   `rejected++`,带 reason)。
4. **F-06**:clamp 时把「被 clamp 过的 change」的元组键改为
   `(clamp 值, device_id)` 之外的稳定键;或在 clamp 时记 warning 并在响应里
   回带 `clamped: true` 让客户端不要依赖幂等。
5. **F-07 / F-08**:tx upsert 后按 FK 列(`category_sync_id` /
   `account_sync_id` / `tag_sync_ids_json`)从权威投影回填 denorm,而不是信任 payload。
6. **F-09 / F-10**:push 端补关联校验(类别)与 `_is_ledger_deleted` 检查,
   与 web 口径对齐。
7. **F-11**:给 `SyncChangeIn.payload` 加轻量 pydantic 子模型(至少长度/类型),
   或在 applier 入口做 `_as_str(v, max_len=col_width)` 截断 + 记 metric。
8. **F-13**:给 trash / cleaner / duplicates / delete_ledger 补 ledger 锁
   (delete_ledger 额外补 owner user 锁以统一 user→ledger 顺序)。
