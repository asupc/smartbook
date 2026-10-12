# 对抗性测试报告 —— SmartBook-Cloud 业务 API 域

- 范围:交易 / 账本 / 预算 / 统计 / 成员 / 共享 / 邀请 / 导入导出 / 管理员
- 测试文件(均在 `server/tests/adversarial/`):
  - `test_tx_write_adversarial.py`
  - `test_ledger_budget_stats_adversarial.py`
  - `test_members_share_invite_adversarial.py`
  - `test_import_export_admin_adversarial.py`
- 统计:**116 条测试,94 绿 / 22 红**。红色 = 已确认缺陷(故意保持失败)。
  全量基线 `pytest tests/ --ignore=tests/adversarial` = **623 passed**,未被污染。
- 复现:`cd /d/github/smartbook/server && python -m pytest tests/adversarial/test_tx_write_adversarial.py tests/adversarial/test_ledger_budget_stats_adversarial.py tests/adversarial/test_members_share_invite_adversarial.py tests/adversarial/test_import_export_admin_adversarial.py -q`
  (连跑 4 次,失败集完全一致 —— 22 条,无 flaky)

严重级定义:
- **高** = 数据损坏 / 越权 / 静默错账(用户看不到,报表已坏)
- **中** = 500 错误面 / 契约不一致 / 脏数据累积
- **低** = 脆弱但可辩护的行为(已按 HARDENING 记入,断言现状通过)

---

## 一、红色测试清单(22 条已确认缺陷)

### A. 金额与日期边界

#### A1. 负金额支出污染收支统计
- 严重级:**高**
- 测试:`test_tx_write_adversarial.py::test_negative_expense_amount_poisons_expense_total`
- 源码:`src/routers/write/transactions.py:31`(`amount: float`,无 `gt/ge`)+
  `src/snapshot_mutator.py:38-46`(`_to_float` 原样取负)+
  `src/routers/read/workspace.py:1265`(分类排行按 `> 0` 过滤)
- 期望:`expense_total >= 0`(负值拒绝或归一化);实际:两笔 -100 / +50 得
  `expense_total == -50`,且 `balance` 反号。分类排行对负值分类整条隐藏(静默少数据)
- 一句话复现:`POST /write/ledgers/{id}/transactions {"amount": -100, "tx_type":"expense"}` → 200;再读 `/read/workspace/analytics` 得 `expense_total: -50`

#### A2. `1e309` 落库为 inf 并把整本账的 JSON 打回 null
- 严重级:**高**
- 测试:`test_tx_write_adversarial.py::test_amount_1e309_persists_infinity_and_nulls_ledger_aggregates`
- 源码:`src/schemas.py:951`(`amount: float` 无 `allow_inf_nan=False`)→
  `src/snapshot_mutator.py:38` `_to_float` 直通 → `src/projection.py:255` 落
  `ReadTxProjection.amount = inf` → `src/routers/read/_shared.py:499` 聚合 SUM 得 inf
- 期望:非有限浮点 4xx;实际:200 存 inf,随后 `/read/ledgers` 与
  `/read/ledgers/{id}` 的 `expense_total` / `balance` 全部变成 `null`(JSON 不允许
  Infinity,序列化降级为 null)。**一笔坏数据污染整本账的所有聚合数字**
- 一句话复现:raw body `{"amount":1e309,...}` → 200;`GET /read/ledgers` 的 `balance` 为 null

#### A3. `amount=NaN` → 500(而非 4xx)
- 严重级:**中**
- 测试:`test_tx_write_adversarial.py::test_amount_nan_returns_500_instead_of_4xx`
- 源码:`src/schemas.py:951` → `src/projection.py:255` 写 NaN 撞
  `NOT NULL constraint failed: read_tx_projection.amount`;
  `src/routers/write/_shared.py:642-656` 只兜 `IntegrityError` 的幂等复放分支
- 期望:4xx;实际:500 INTERNAL_ERROR(日志里是未处理的 sqlite IntegrityError)
- 一句话复现:raw body `{"amount":NaN,...}` → 500

#### A4. NaN 在 PATCH / 批量创建 / 余额调整三条路径同样 500
- 严重级:**中**
- 测试:`test_tx_write_adversarial.py::test_amount_nan_in_patch_batch_and_adjustment_all_500`
- 源码:`src/routers/write/_shared.py:751`、`src/routers/write/transactions_batch.py:247`、
  `src/snapshot_mutator.py:991`
- 期望:三条路径统一 4xx;实际:PATCH=500 / batch=500 / adjustment=500
  (adjustment 报 `NOT NULL constraint failed: read_account_adjustment_projection.amount`)
- 一句话复现:三处各发一次 `amount: NaN` 的 raw body

#### A5. 未来时间交易让「记账天数」变 -355097
- 严重级:**中**
- 测试:`test_tx_write_adversarial.py::test_future_transaction_yields_negative_days_since_first_tx`
- 源码:`src/routers/read/workspace.py:1029-1034`
  `days_since_first_tx = (today_utc - first_day).days + 1`,无 clamp
- 期望:`>= 0`(clamp 或拒绝未来交易);实际:2999 年交易 → `days_since_first_tx = -355097`
- 一句话复现:建一笔 `happened_at: 2999-01-01` 的交易 → 读 `/read/workspace/ledger-counts`

### B. 更新语义(PATCH)

#### B1. `PATCH {"amount": null}` 静默把金额清零
- 严重级:**高**
- 测试:`test_tx_write_adversarial.py::test_patch_amount_null_silently_zeroes_the_amount`
- 源码:`src/routers/write/transactions.py:82`(`exclude_unset=True` 让显式 null 进入
  payload)→ `src/snapshot_mutator.py:379`(`if "amount" in payload`)→
  `_to_float(None) == 0.0`
- 期望:null 视为"不变"(与 note / category 的 `value is None → 不动` 语义一致)或 400;
  实际:200 且 100.0 → 0.0。**前端表单把可选字段清空就丢金额**
- 一句话复现:`PATCH .../transactions/{tx} {"amount": null}` → 读回 `amount: 0.0`

#### B2. `PATCH {"happened_at": null}` 把交易时间改成"服务器当前时间"
- 严重级:**高**
- 测试:`test_tx_write_adversarial.py::test_patch_happened_at_null_resets_to_now`
- 源码:`src/snapshot_mutator.py:401`(`if "happened_at" in payload`)→
  `_to_iso8601(None)` 走 fallback 返回 `datetime.now()`(`:35`)
- 期望:null 忽略或 4xx;实际:2026-05-06 → 2026-10-11(跳到今天,跨月错账)
- 一句话复现:`PATCH .../transactions/{tx} {"happened_at": null}`

#### B3. `PATCH {"tx_type": null}` → 500
- 严重级:**中**
- 测试:`test_tx_write_adversarial.py::test_patch_tx_type_null_returns_500`
- 源码:`src/schemas.py:976`(`tx_type: Literal[...] | None` 放行 null)→
  `src/snapshot_mutator.py:373-376` 把 None 变 `""` 抛 ValueError;
  快路径 `src/routers/write/_shared.py:751` **没有** try/except ValueError
  (对比全量路径 `_commit_write:1360` 有)
- 期望:400 WRITE_VALIDATION_FAILED;实际:500
- 一句话复现:`PATCH ... {"tx_type": null}`(同端点 `tx_type:"bogus"` 反而是 422 —— 两条
  异常通道不一致)

### C. 回收站(软删安全网被绕过)

#### C1. 回收站里的交易可被 PATCH 复活
- 严重级:**高**
- 测试:`test_tx_write_adversarial.py::test_patch_resurrects_trashed_transaction`
- 源码:`src/routers/write/_shared.py:710-715` 点查 `ReadTxProjection` 时**无
  `deleted_at.is_(None)` 过滤** → `update_transaction` → `upsert_tx` 里
  `src/projection.py:295` `"deleted_at": None` 清软删
- 期望:404(回收站需先 restore);实际:200,交易回账本列表,回收站条目消失
- 一句话复现:DELETE 一笔 → `PATCH .../transactions/{tx} {"note":"x"}` → 读账本列表又见该笔

#### C2. 回收站里的交易可被批量移动复活
- 严重级:**高**
- 测试:`test_tx_write_adversarial.py::test_batch_move_resurrects_trashed_transaction`
- 源码:`src/routers/write/transactions_batch_move.py:170-175` 点查目标行**无软删过滤**
  (对比 `transactions_batch_delete.py:140-146` 有过滤)
- 期望:not_found(与 batch_delete 一致);实际:`moved_tx_ids=[tx]`,交易复活到账本列表
- 一句话复现:DELETE 一笔 → `POST .../transactions/batch/move {"tx_ids":[tx],...}`

### D. 多币种 / 余额调整

#### D1. 交易级外币缺汇率按 1:1 计入且不标 incomplete
- 严重级:**高**
- 测试:`test_tx_write_adversarial.py::test_tx_level_currency_without_rate_is_summed_one_to_one_without_flag`
- 源码:`src/routers/read/workspace.py:1090`(`COALESCE(native_amount, amount)` 不看
  `currency_code`)+ `:1180`(`analytics_missing_rate` 只看**账本**币种)
- 期望:缺折算的外币交易 → `multi_currency_incomplete=True`(或不计 1:1);
  实际:5 笔 100(3 笔外币无折算)得 `expense_total=901` 且 `incomplete=False`
- 一句话复现:`POST .../transactions {"amount":100,"currency_code":"USD"}`(不带 native_amount)
  → 读 analytics

#### D2. 幽灵账户的余额调整直接改动账本余额
- 严重级:**高**
- 测试:`test_tx_write_adversarial.py::test_ghost_account_adjustment_moves_ledger_balance`
- 源码:`src/snapshot_mutator.py:988-993`(`create_account_adjustment` 只查
  `account_id` 非空,不校验账户存在)+ `src/routers/read/_shared.py:530-539`
  (账本 balance 无条件并入 adjustment 合计)
- 期望:400/404;实际:`account_id="acc_does_not_exist"` + `amount=-12345` → 账本
  `balance` 从 -100 变 -12445,而 `/read/workspace/accounts` 里没有任何账户能吃这个差
  (账本维度与账户维度对不上账,钱"凭空消失")
- 一句话复现:`POST .../account-adjustments {"account_id":"acc_ghost","amount":-12345,...}`

### E. 账本 / 预算 / 统计

#### E1. `/read/ledgers/{id}/stats` 把回收站行计入 transaction_count
- 严重级:**中**
- 测试:`test_ledger_budget_stats_adversarial.py::test_ledger_stats_counts_trashed_rows`
- 源码:`src/routers/read/ledgers.py:150-155` `_count(ReadTxProjection)` 只按 ledger_id COUNT
  (无 `deleted_at` 过滤);对比 `src/routers/read/_shared.py:521-525` 有过滤
- 期望:与 `/read/ledgers/{id}.transaction_count` 一致;实际:删 1 笔后 stats 仍报 3,
  detail 报 2 → mobile「深度同步检测」判定服务端更多 → 反复全量同步
- 一句话复现:建 3 笔 → 删 1 笔 → 分别读 stats 与 detail 的 transaction_count

#### E2. 幽灵分类预算可建,永久孤儿
- 严重级:**中**
- 测试:`test_ledger_budget_stats_adversarial.py::test_budget_for_nonexistent_category_is_accepted`
- 源码:`src/snapshot_mutator.py:894-902`(只查 `category_id` 非空 + `(type, categoryId)` 去重,
  不查 `UserCategoryProjection` 存在性)
- 期望:400"分类不存在";实际:200 落库,列表 `category_name=null`,`used` 恒 0,无 UI 入口清理
- 一句话复现:`POST .../budgets {"type":"category","category_id":"cat_does_not_exist","amount":100}`

#### E3. `scope=year` 的 period 越界 → 500
- 严重级:**中**
- 测试:`test_ledger_budget_stats_adversarial.py::test_analytics_year_scope_out_of_range_period_returns_500`
- 源码:`src/routers/read/_shared.py:647-651` —— month 分支有 `1..12` 校验(`:625-626`),
  **year 分支只做 `int(target)`**,不校范围 → `datetime(year, 1, day)` 抛
  `ValueError: year must be in 1..9999, not 0`
- 期望:400 Invalid analytics period;实际:`period=0/-1/99999/0000` 全部 500
- 一句话复现:`GET /read/workspace/analytics?scope=year&period=0`

#### E4. 同一 helper 让 `member-stats` 也 500
- 严重级:**中**
- 测试:`test_ledger_budget_stats_adversarial.py::test_member_stats_year_scope_out_of_range_period_returns_500`
- 源码:`src/routers/member_stats.py:83` 复用 `_analytics_range`
- 期望:400;实际:`scope=year&period=0` 与 `period=9999` 均 500
- 一句话复现:`GET /ledgers/{id}/member-stats?scope=year&period=0`

### F. 成员 / 共享 / 邀请

#### F1. 账本删除后邀请码仍可接受,并写入幽灵成员关系
- 严重级:**高**
- 测试:`test_members_share_invite_adversarial.py::test_invite_accept_after_ledger_deleted_still_writes_membership`
- 源码:`src/routers/invites.py:430-435`(preview)与 `:479-507`(accept)只查
  `Ledger` 行存在(软删只留壳),**不查 tombstone**(`_is_ledger_deleted` 只在
  read/write 路径用);文件头注释写的是"邀请创建后账本被删 → 邀请失效"
- 期望:preview/accept 均 404;实际:preview 200 + accept 200 + `ledger_members`
  多一行。幽灵成员在账本列表/sync 列表都看不见,但 DB 里确实存在
- 一句话复现:owner 建账本 → 发邀请码 → 删账本 → 另一用户 `POST /invites/{code}/accept` → 200

### G. 导入 / 导出 / 管理员

#### G1. CSV 公式注入(导出不做 `=+-@` 转义)
- 严重级:**高**
- 测试:`test_import_export_admin_adversarial.py::test_csv_export_does_not_neutralize_formula_injection`
- 源码:`src/routers/read/workspace.py:500-513` 直接 `_csv_field(note)`;
  `src/routers/read/_shared.py:666-675` `_csv_field` 只做 RFC 4180 引号/逗号/换行处理,
  **不处理** `=` / `+` / `-` / `@` 前缀(无 `'` 前置或制表符兜底)
- 期望:危险前缀被转义;实际:导出行为 `Expense,,,1.00,CNY,,,,=1+1,...`。
  Excel / LibreOffice 打开即当公式执行(可被用于 DDE / 远程引用数据外泄)
- 一句话复现:建一笔备注 `=1+1` 的交易 → `GET /read/workspace/transactions.csv`

#### G2. 自导出 CSV 在「转义引号 + 换行」备注下无法自导入
- 严重级:**高**
- 测试:`test_import_export_admin_adversarial.py::test_csv_export_roundtrip_quote_plus_newline_note_fails_to_import`
- 源码:`src/services/import_data/parser.py:207-220` ——
  `csv.Sniffer().sniff(sample, delimiters=",;\t|")` 的 `doublequote` 推断随样本长度漂移
  (短样本 `True` / 长样本 `False`),未显式 `dialect=csv.excel` 或 `doublequote=True` 兜底;
  导出侧 `src/routers/read/_shared.py:666-675` 是标准 RFC 4180
- 期望:导出 → 导入 1 笔;实际:解析出 0 笔 + 2 条 `COLUMN_COUNT_MISMATCH`,
  execute 报 `PARSE_MISSING_REQUIRED`。**导出的备份无法导入回来**(往返契约破裂)
- 一句话复现:备注写 `note,with"quotes"\nand newline`(真实换行)→ 导出 → 立刻导入

#### G3. 导入去重的金额 key 口径不一致 → 重复导入翻倍
- 严重级:**高**
- 测试:`test_import_export_admin_adversarial.py::test_import_dedup_skips_only_decimal_canonical_amounts`
- 源码:`src/services/import_data/endpoints.py:501`
  `dedup_key = (tx.tx_type, f"{tx.amount}", ...)` —— `tx.amount` 是 `Decimal("35.50")`
  → `"35.50"`;而 `src/services/import_data/stats.py:243` `build_existing_sets` 用
  `f"{amt}"` 读库内 `Float` → `"35.5"`
- 期望:导出→立即回导 3 笔全部判重(`skipped_dedup=3`,总笔数不变);
  实际:只跳过 `12.34`,`skipped_dedup=1`,总笔数 3 → 5。
  **`skip_duplicates` 对整角/整元金额完全失效**(35.50 / 100.00 这类最常见金额全部漏判)
- 一句话复现:建 12.34 / 35.5 / 100.0 三笔 → 导出 → 导入(默认 skip_duplicates) → 执行

#### G4. CSV 导出的 `tz_offset_minutes` 无范围校验 → 500
- 严重级:**中**
- 测试:`test_import_export_admin_adversarial.py::test_csv_export_huge_tz_offset_returns_500`
- 源码:`src/routers/read/workspace.py:322-325`(裸 `int`,无 `Query(ge=-720, le=840)`)
  → `:458` `timedelta(minutes=...)` → `:470` `local_dt = _to_utc(...) + tz_delta` 溢出。
  对比 analytics / budgets-usage / net-worth-history 三个端点都有 `ge/le`
- 期望:422;实际:账本有交易时 500
- 一句话复现:`GET /read/workspace/transactions.csv?ledger_id={id}&tz_offset_minutes=99999999999`

#### G5. `/admin/overview` 把回收站交易计入总量
- 严重级:**中**
- 测试:`test_import_export_admin_adversarial.py::test_admin_overview_counts_include_trashed_transactions`
- 源码:`src/routers/admin.py:497-499` `func.count().select_from(ReadTxProjection)`,
  无 `deleted_at.is_(None)` —— 与该字段注释("projection 是 hard-deleted 的权威源,
  COUNT(*) 就干净正确")自相矛盾
- 期望:软删后 transactions_total 由 2 变 1;实际:仍为 2(purge 后才变 1)
- 一句话复现:建 2 笔 → 删 1 笔 → `GET /admin/overview`

---

## 二、HARDENING 条目(94 绿:行为可辩护但脆弱,已断言现状)

### 金额 / 数值
- **0 元交易被接受**:`WriteTransactionCreateRequest.amount` 无 `gt=0`(预算侧有)。
  0 元无财务意义但无害,依赖 UI 拦。
- **bool 被当数字**:`{"amount": true}` → 1.0(pydantic float 强转)。JSON 类型撒谎。
- **数字字符串被强转**:`"123"` / `"12.5"` 接受,`""` 走 422 —— 宽容度不一致。
- **100 万字符 note** 照收(Text 列无上限)—— 缺一个长度上限就是无界存储。
- **`\x00` 原样存取**(写入/读回均保持),服务端不炸,前端渲染可能截断。

### 日期
- **1970 / 2999 / 9999 全接受**(无合理区间校验);配合 A5 产生负天数。
- **naive `happened_at` 当 UTC**(与文档一致)。
- **非法日期字符串 422**(pydantic 挡住)。

### 批量
- **空数组 422 / 200 条恰好通过 / 201 条 422 / 重复 id 去重** —— 边界正确。
- **跨账本 id 记 not_found**,目标账本数据不动 —— 越权正确。
- **批量创建任一行非法 → 整批 400 且 0 行落库** —— 事务原子性正确。
- **批量创建上限 50**(schema),51 → 422。

### 回收站
- **存活交易 purge/restore → 404;purge 不存在 → 404;purge 幂等(二次 404)** —— 正确。
- **restore → 再批量删 → 再次进回收站** —— 状态机自洽。
- **`days_left` 落在 [0, 30]**。

### 更新语义
- **空 PATCH 也推进 change_id**:`_mark_entity_actor` 写 `updatedByUserId` 使 diff 判为变更,
  移动端多收一条无意义 change,"最后编辑人"被改成调用者。
- **未知字段静默丢弃**(含试图跨账本搬移的 `ledger_id`)—— 宽容但掩盖客户端拼写错误。
- **`currency_code` 单独改成 JPY 而 `native_amount` 缺省** → COALESCE 回退把 JPY 当本位币加
  (契约允许,但 web 端只改币种会静默错账)。
- **`tx_type: "bogus"` → 422,`tx_type: null` → 500** —— 同一字段两条异常通道不一致
  (null 已在 B3 记为缺陷)。

### 多币种 / 调整 / 转账
- **`< 0.005` 的调整被 400 拒绝**(mutator 校验)。
- **同名账户/分类的转账、缺 from/to 的转账都能建** —— 后者让这笔钱的流向在净值历史里
  彻底丢失(两个账户 SUM 都 miss),但账本余额仍吃 `-amount`。

### 幂等
- **同 key 同 payload → replay**(change_id 不变);**同 key 不同 payload → 409** —— 正确。
- **不带 Idempotency-Key 的重复提交不去重**(契约:客户端负责)—— 网络重试会多出一笔。

### 账本
- **msd 非法值(0/29/30/31/32/负数)全部 422**;emoji 名 / 任意币种码(`ZZZ9!`)接受。
- **同名账本允许**(只有 `(user_id, external_id)` 唯一)—— 产品取舍。
- **删账本清 projection + tombstone,SYNC 重建同 id 409,写入 404** —— 无幽灵交易。
- **重复删账本 200**(幂等友好,但 change_id 前进,客户端多收一条事件)。
- **删最后一个账本后所有读端点退化为空**(accounts / ledger-counts / analytics /
  net-worth 均无 500)。
- **改名 LWW**以最后一次为准。
- **账本 analytics 多币种缺汇率时 `multi_currency_incomplete=True` 且净值为 0(绝不裸加)** ——
  正确;设主币种后 CNY 账户计入、USD 账户因缺汇率被剔除。

### 预算
- **amount 0/负、非法 period、start_day 越界 → 422**;total 每账本唯一(第二条 400)。
- **无预算时 usage 返回空 items**;有预算无交易 used=0。
- **父分类预算覆盖子分类支出**(按 `parent_sync_id` 展开)—— 与 mobile 一致。
- **`exclude_from_budget=True` 不计用量**;`exclude_from_stats` 与 `exclude_from_budget` 独立 ——
  正确(analytics 吃后者不吃前者,balance 两者都吃)。
- **分类删除后孤儿预算保留**(`category_name=null`)不 500。

### 统计
- **畸形查询参数(limit/-1/非数字、sort_by 非白名单、sort_order 非白名单、tz 越界)全 422**。
- **`series[].balance == income - expense == summary.balance`** —— 口径自洽。
- **`2^53` 量级金额聚合不抛异常**。
- **已发生月份 < 3 时 `anomaly_months` 为空**。
- **1970 交易让 `days_since_first_tx > 20000`**(真实但荒谬)。

### 成员 / 共享 / 邀请
- **100 次邀请码枚举全 404**(无存在性泄露);熵 30^6。
- **一次性 / 过期 / 撤销后均失效;撤销幂等(二次 204)**。
- **自己邀自己 409;已是成员再接受 409**。
- **活跃邀请上限 10;非成员创建邀请 404;成员上限 5(第 6 个 409)**。
- **owner 自移除 409;移除不存在成员 404**。
- **editor 删账本 / 踢 owner → 404;owner-only 实体(accounts/budgets/meta)对 editor 404,
  tx/categories 允许** —— 角色边界正确。
- **被移除成员 token 仍有效,但账本读写/成员列表全 404** —— 立即生效。
- **transfer 后恰好 1 个 owner,原 owner 失去 owner-only 权限,自转 409,转非成员 404**。
- **member-stats 非成员 404;按 `created_by_user_id` 分账;transfer 不计;回收站行不计**。
- **共享账本 editor 能看到 owner 的 tx 与 `is_shared/member_count`**。
- **两用户同 external_id 账本完全隔离**。
- **邀请并发抢占在 SQL 层确实单赢家**:条件 UPDATE 第一次 `rowcount=1`、第二次 `0`
  (对应 endpoint 的 409 分支)。

### 导入 / 导出
- **导出 BOM + 12 列本地化表头;空账本只输出表头**。
- **RFC 4180 引号/逗号转义正确**(`"他说""好吃"",还想再来"`)。
- **列数不齐的行补空/截断 + 警告,不炸**;非法编码 400;空文件 400;只有表头 400;
  50001 行 413;>10MB 413;5000 列超宽 CSV 接受。
- **同文件内重复行在 execute 阶段按 skip_duplicates 去重**(preview 的 skipped 只看库内)。
- **token 单用户 + 单次**:他人 preview 410 / cancel `False`;execute 后 preview 410。
- **指向他人账本 404**。
- **超大 `tz_offset_minutes` 在导入侧不 500**,但该行解析失败(缺范围校验)。

### 管理员
- **普通用户调 admin 端点 403**(users / overview / data-cleanup / logs / 建用户)。
- **admin 自删 400 / 自禁用 400**;另一 admin 也不可被删(400)。
- **`is_admin: true` 在 create / patch 里都被硬锁为 False**(单租户单管理员),audit 记
  `requestedIsAdmin`。
- **改他人密码需 admin 自己当前密码(错密码 401),目标不存在 404**。
- **分页边界(limit 0/负/超限/非数字、offset 负)** 全 422;offset 超总数返回空 items
  但 total 正确。
- **audit log 只在真实变更时写 1 条**(no-op PATCH 不写噪音),但 no-op 仍返回 200。
- **软删用户 → 后续请求 403、登录 403**。

---

## 三、未能验证 / 不可复现

1. **并发写同一账本的数据一致性(真·线程并发)**
   用 `threading` + `TestClient` 双线程各写 5 笔:得到状态码
   `[500, 500, 200, 200, 200, 200, 500, 500, 200, 200]`,最终只落 6 行。
   但 `starlette.testclient.TestClient` 本身不是线程安全的(共享 `portal` /
   `httpx` 状态),同样的写法在并发 accept 邀请时也伪造出 401。
   **无法区分这是服务端缺陷还是测试脚手架缺陷** → 不计入红色,已从测试集中移除。
   真并发需起 uvicorn + 真实 HTTP 客户端(或在 Postgres 上跑,本仓并发契约
   依赖 `lock_ledger_for_materialize` 的 advisory lock,sqlite 下是 no-op)。
   参考:`src/concurrency.py`、`tests/test_sync_concurrency.py` 头注释
   ("Concurrent Postgres advisory-lock behavior is not exercised here")。

2. **并发 accept 同一邀请码的 HTTP 层结果**
   设计期望 200 + 409;线程版观测到 200 + 500 与 200 + 401 两种结果,
   已被脚手架噪声污染(同上)。已在
   `test_members_share_invite_adversarial.py::test_concurrent_invite_accept_single_winner_at_sql_level`
   用 SQL 层条件 UPDATE 验证了核心不变量(单赢家)。HTTP 层未复现。

3. **`/sync/push` 路径的 NaN / inf**
   push 的 `amount` 走 `_as_float`(非 pydantic),`"abc" → 0.0` 静默归零(非崩溃点)。
   push 侧 NaN/inf 未单独验证 —— 属于 sync 域(另一路工作范围)。

4. **超长文本字段的存储上限**
   只验证了 note 10 万字符可存;未测更大规模(如 1MB+)对 SQLite/PG 的实际影响,
   也未验证其它文本字段(note on account / category / tag)的同款无界性。

5. **`/read/ledgers/{id}/stats` 与 mobile 深度同步检测的端到端影响**
   E1 证明 stats 计数与 detail 不一致;mobile 端"是否真的因此反复全量同步"
   需要 Flutter 客户端参与,未验证。

---

## 四、覆盖清单

| 攻击项 | 覆盖 | 结果 |
|---|---|---|
| 金额 0 / 负 / 2^53 / 4 位小数 / 超长数字 / 字符串数字 | ✅ | HARDENING ×3 + 红 A1 |
| NaN / Infinity / `1e309` | ✅ | 红 A2 A3 A4 |
| 1970 / 9999 / 非法格式 / 时区缺省 / 未来时间 | ✅ | HARDENING ×3 + 红 A5 |
| 批量 delete/move 不存在 id / 重复 id / 跨账本 / 空数组 / 1000→200 / 201 边界 | ✅ | HARDENING ×4 + 红 C2 |
| 批量操作部分失败的事务原子性 | ✅ | HARDENING |
| trash 再 trash / purge 不存在 / purge 后读写 / trash 后被批量引用 | ✅ | HARDENING ×3 + 红 C1 C2 |
| PATCH 空 body / 字段 null vs 省略 / 同改 ledger_id | ✅ | HARDENING ×3 + 红 B1 B2 B3 |
| 外币缺汇率 / 非法币种码 / 汇率 0/负/极大 | ✅ | 红 D1 + HARDENING |
| adjust_balance 负余额 / 巨变边界 | ✅ | 红 D2 + HARDENING |
| 账本重名 / 超长名 / emoji / 非法币种 / msd 0·29·30·31·32·负 | ✅ | HARDENING ×3 |
| 账本删除(after-read/写、重复删、最后一个、有数据) | ✅ | HARDENING ×4 |
| 账本元数据并发改名(LWW)/ 引用完整性 | ✅ | HARDENING |
| 预算 0/负 / 非法周期 / 跨月边界 / exclude 组合 / 无预算 usage / 已删类目预算 | ✅ | 红 E2 + HARDENING ×6 |
| 统计空账本 / 单条 / 跨月界 msd 28 / 排除标志 / 多币种 / 极大金额 | ✅ | HARDENING ×6 |
| limit / 月份参数畸形(`month=13`/`0`/`year=0`/非数字) | ✅ | 红 E3 E4 + HARDENING |
| 邀请码暴力枚举 100 / 失效复用 / 过期 / 自己邀自己 / 重复邀请 | ✅ | HARDENING ×4 + 红 F1 |
| owner 移除自己 / 移除不存在 / 被移除后 token / member 删账本 / 移除 owner | ✅ | HARDENING ×5 |
| member_stats 越权读 | ✅ | HARDENING |
| CSV 导出→导入往返(含特殊字符/引号/换行/金额精度) | ✅ | 红 G2 G3 + HARDENING |
| 导入畸形 CSV(列数不齐 / 编码非法 / 超大 / 超宽) | ✅ | HARDENING |
| 导入重复幂等 / 导出空账本 | ✅ | 红 G3 + HARDENING |
| CSV 公式注入 | ✅ | 红 G1 |
| 普通用户调 admin → 403 / admin 自删自降级 / 分页边界 / audit 完整性 | ✅ | HARDENING ×5 + 红 G5 |
| 分页负数/0/极大/非数字;排序白名单注入 | ✅ | HARDENING |
| `%00` / 超长 / 特殊字符文本字段 | ✅ | HARDENING |
| 并发同资源写(线程 + 既有 race 写法) | ⚠️ | 未能验证(见第三节)|

---

## 五、修复建议优先级(按影响面)

1. **P0 — 数据损坏类**:A2(inf 污染整账)、B1/B2(null 静默改写金额/日期)、
   C1/C2(回收站被绕过)、D2(幽灵账户调整改余额)。
   建议统一在写入口做数值/日期归一化 + 拒绝非有限浮点,并在所有点查加软删过滤。
2. **P0 — 越权 / 契约**:F1(已删账本的邀请码仍可用)、G3(去重失效导致重复记账)。
3. **P1 — 报表可读性**:A1(负金额)、D1(缺汇率 1:1)、E3/E4(year 越界 500)、
   G4(tz 越界 500)、E1/G5(软删行被计数)。
4. **P2 — 数据卫生**:E2(幽灵预算)、A5(负天数)、B3(tx_type null → 500)、
   G1(公式注入,需前端 Excel 使用场景确认风险等级)。
