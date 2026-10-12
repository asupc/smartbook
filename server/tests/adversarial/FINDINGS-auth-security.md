# 对抗测试发现报告 —— 认证 / 授权 / 安全边界域

- **测试范围**:SmartBook-Cloud(`D:\github\smartbook\server`)认证、授权、令牌与作用域、
  IDOR/越权、注入与畸形输入
- **授权性质**:本仓库自研服务端的防御性安全测试(授权白盒审计)
- **测试目录**:`server/tests/adversarial/`(仅新增文件,未修改 `src/**` 与既有测试)
- **运行方式**:`cd /d/github/smartbook/server && python -m pytest tests/adversarial/<file> -q`
- **基线**:`pytest tests/` 上游 623 条全绿(本次未碰既有测试)
- **交付结果**:4 个文件 / 154 条测试 —— **108 绿 + 20 红(20 条红全部为真实缺陷)**
  + 10 条 HARDENING(断言当前行为并通过)

| 文件 | 条数 | 绿 | 红(缺陷) |
|---|---|---|---|
| `test_auth_adversarial.py` | 21 | 16 | 5 |
| `test_token_scope_adversarial.py` | 27 | 27 | 0 |
| `test_idor_adversarial.py` | 38 | 34 | 4 |
| `test_injection_malformed_adversarial.py` | 37 | 31 | 11 |
| **合计** | **154** | **108** | **20** |

---

## 一、缺陷清单(红色测试)

### F-01 跨用户同名 `external_id` 导致成员大面积 500(越权/可用性)

- **严重级:高**
- **源码**:`src/ledger_access.py:43-64`(`get_accessible_ledger_by_external_id`
  → `db.execute(q).one_or_none()`);`src/models.py:471`
  (`UniqueConstraint("user_id", "external_id")`);`src/routers/write/_shared.py:429-457`
  (`_load_ledger_for_write` 同款查询)
- **测试**:`test_idor_adversarial.py::test_same_external_id_across_users_breaks_member_ledger_access`、
  `test_same_external_id_app_member_push_breaks`
- **期望 vs 实际**:
  - 期望:B 接受 A 的「default」账本邀请后,能正常访问 A 的账本(共享账本核心流程)
  - 实际:B 若自己也有名为 `default` 的账本,`Ledger.external_id == 'default' AND
    LedgerMember.user_id == B` 命中 **2 行** → `MultipleResultsFound` 未被捕获 → **HTTP 500**
- **HTTP 状态码**:500(`/read/ledgers/{id}`、`/read/summary`、`/sync/full`、
  `/ledgers/{id}/members`、`shared-resources`、`member-stats`、
  `POST /write/ledgers/{id}/transactions`)
- **一句话复现**:A、B 各自建 `ledger_id="default"` → A 邀请 B → B 接受成功后,
  B 请求 `GET /api/v1/read/ledgers/default` 返回 500(全部写端点同样 500)。
- **影响**:`default` 是 mobile 默认账本名,该场景在真实部署中极常见 —— 一旦用户接受
  他人同名账本邀请,该用户在**自己**的同名账本上既读不了也写不了(自锁),且无法自助恢复。
- **修复方向**:`one_or_none()` 换 `first()` 并按 `LedgerMember` 语义消歧;或
  查询改为经 `LedgerMember.ledger_id` 定位后再校验 `external_id`,把 external_id 的
  复合唯一真正融入解析逻辑。

---

### F-02 已禁用用户仍可通过 WebSocket 认证并接收实时推送

- **严重级:高**
- **源码**:`src/routers/ws.py:42-50`(`_user_exists` 只判断行存在,**不查 `is_enabled`**);
  对照 `src/deps.py:get_current_user`(`if not user.is_enabled: 403`)
- **测试**:`test_idor_adversarial.py::test_ws_accepts_token_of_disabled_user`、
  `test_ws_query_token_path_also_checks_enabled`
- **期望 vs 实际**:
  - 期望:管理员禁用账号后,WS 首帧认证 → `close(1008)`
  - 实际:返回 `{"type":"auth_ok"}`,连接注册进 `ws_manager`,**可继续收到账本变更 /
    成员变更 / profile_change 推送**;query token 兼容路径(`/ws?token=...`)同样放行
- **HTTP/WS 状态码**:REST 侧 `GET /read/ledgers` 正确返回 403;WS 侧返回 `auth_ok`
  (无拒绝帧)
- **一句话复现**:管理员把用户 `is_enabled=False` → 该用户 `websocket_connect("/ws")`
  发 `{"type":"auth","token":<旧token>}` → 收到 `{"type":"auth_ok"}`。
- **影响**:账号禁用/离职处置不彻底 —— 被禁用账号仍能持续观测实时数据流(账本变更、
  共享成员变动、头像/昵称变化),构成持续性信息泄漏通道。

---

### F-03 用户可控 `external_id` 参与附件落盘路径拼接 → 任意路径写文件

- **严重级:高**
- **源码**:`src/schemas.py:937`(`ledger_id` 只有 `min_length=3, max_length=128`,
  无字符集校验);`src/routers/attachments.py:140`
  (`storage_dir = _attachment_root() / ledger.user_id / ledger.external_id / sha256[:2]`,
  未做 `normpath`/`resolve` 收敛,随后 `mkdir(parents=True)` + `write_bytes`)
- **测试**:`test_injection_malformed_adversarial.py::test_path_traversal_in_ledger_external_id_is_accepted`、
  `test_attachment_storage_path_escapes_root`
- **期望 vs 实际**:
  - 期望:`external_id` 拒绝含 `..`/路径分隔符的值(422);或落盘前规范化并校验
    仍在附件根目录内(对照 `src/main.py:_resolve_static_file` 的 `is_relative_to` 校验)
  - 实际:创建 `ledger_id="../../pwn"` 成功(200),上传附件后文件被写到
    `.../attachments/<user_id>/../../pwn/<sha2>/<uuid>_payload.sh` —— **逃出附件根目录**
- **HTTP 状态码**:创建 200;上传 200(写入成功)
- **一句话复现**:`POST /write/ledgers {"ledger_id":"../../pwn"}` → 200;
  `POST /attachments/upload`(form `ledger_id=../../pwn`)→ 200,文件落在附件根目录之外。
- **实测路径**(6 层 `..`):`root/<uid>/../../../../../../escaped-dir/d7/<uuid>_payload.sh`
- **影响**:local / Docker 部署(DATA_DIR 挂载卷)下可写出附件根目录之外的文件(文件名
  受 `_safe_file_name` 限制为 basename,内容完全可控)。若结合部署目录结构可获得
  写入任意可写路径的能力(如覆盖同卷内可执行文件/配置)。
- **修复方向**:`external_id` 加白名单正则(如 `^[A-Za-z0-9_.:-]{3,128}$` 且禁 `..`),
  并在落盘前对最终路径做 `resolve()` + `is_relative_to(root)` 断言。

---

### F-04 深嵌套 JSON 写入 profile 后**永久自锁**(`GET /profile/me` 500)

- **严重级:高**
- **源码**:`src/schemas.py:84 / :99`(`appearance: dict | None`,
  无深度/体积限制);`src/routers/profile.py:131-135`(`_dump_appearance_json`
  原样 `json.dumps` 落库);触发点在 `PATCH /profile/me` 的响应序列化
  (`PydanticSerializationError: Circular reference detected (depth exceeded)`)
- **测试**:`test_injection_malformed_adversarial.py::test_deeply_nested_json_in_profile_corrupts_profile_read`
- **期望 vs 实际**:
  - 期望:PATCH 深度超限被拒(422),或至少 GET 仍可读
  - 实际:PATCH **数据已落库**但返回 500;此后 `GET /profile/me` 与任何后续
    `PATCH /profile/me` 全部 500
- **HTTP 状态码**:PATCH 500 → 之后 GET 500(持久)
- **阈值实测**:98 层 200;99 层起 500(Python 默认递归限制相关)
- **一句话复现**:`PATCH /api/v1/profile/me {"appearance": <120 层嵌套 dict>}` → 500;
  随后 `GET /api/v1/profile/me` → 500。
- **数据未回滚证据**:`deep_committed_depth = 80`(80 层时写入成功且 GET 可读);
  99 层时写入的 JSON 已入库,GET 因反序列化深度超限失败。
- **影响**:单请求即可让目标账号的 profile 端点永久不可用(DoS),且 **`/profile/me`
  是 web 登录后首个请求 + WS `profile_change` 推送路径**;用户无法自助修复(需要
  admin 直接改库)。已确认 `admin/users` 列表仍可读(未受连带影响),登录仍可成功。
- **修复方向**:`appearance` / `ai_config` 加深度与字节上限(如 ≤10 层、≤64KB),
  或落库前 `json.dumps` 失败/超限即 422。

---

### F-05 超长密码导致注册 / 登录 500(passlib `PasswordSizeError` 未捕获)

- **严重级:中**
- **源码**:`src/security.py:36-41`(`hash_password` / `verify_password` 直接调 passlib);
  `src/routers/auth.py:195`(`register` → `hash_password(req.password)`);
  `src/schemas.py:21`(`password: str = Field(min_length=6)`,**无 max_length**)
- **测试**:`test_auth_adversarial.py::test_register_huge_password_returns_422_not_500`、
  `test_login_huge_password_returns_401_not_500`
- **期望 vs 实际**:期望 422(注册)/ 401(登录);实际 **500**
- **HTTP 状态码**:500(`INTERNAL_ERROR`)
- **阈值实测**:注册 4096 字节 200;4097 字节起 500。登录 4097 字节起 500。
- **一句话复现**:`POST /api/v1/auth/register {"email":"a@b.com","password":"<4097 个 x>"}`
  → 500;`POST /api/v1/auth/login {"email":"a@b.com","password":"<200000 个 x>"}` → 500。
- **影响**:无需凭据即可触发 500(注册路径是公开入口),日志污染 + 监控误报;
  异常信息经全局 handler 收敛,无栈泄漏。
- **修复方向**:`password` 加 `max_length=1024`(或 4096),并在 security 层捕获
  `PasswordSizeError` 转 400。

---

### F-06 并发同邮箱注册暴露 `IntegrityError` → 500(无 TOCTOU 兜底)

- **严重级:中**
- **源码**:`src/routers/auth.py:191-197`(`SELECT 查重` → `db.add(user)` → `db.flush()`,
  flush 处**无 try/except IntegrityError`);对照
  `src/routers/write/ledgers.py:74-100`(`create_ledger` 有兜底返回 409)
- **测试**:`test_auth_adversarial.py::test_register_integrity_error_on_flush_returns_409`
  (用自定义 Session 让 User 插入的 flush 抛 IntegrityError 确定性复现)
- **期望 vs 实际**:期望 409(AUTH_EMAIL_EXISTS);实际 500(INTERNAL_ERROR)
- **HTTP 状态码**:500
- **一句话复现**:两个并发请求同时注册同一邮箱(竞态窗口内 `SELECT` 都未命中 →
  第二个 `flush` 撞 `users.email` UNIQUE)→ 500。
- **补充**:4 线程并发注册同邮箱的实测结果为 `['500','500','500','500']`
  (SQLite 单文件锁放大竞态窗口,全部 500;`users` 表 0 行残留,无重复行泄漏)。
- **影响**:并发注册(重试 / 双开页面)返回 500 而非语义正确的 409;客户端无法区分
  "已存在"与"服务端故障"。无数据损坏。
- **修复方向**:把 `db.flush()` 包进 `try/except IntegrityError` → 409,
  与 `create_ledger` 保持一致。

---

### F-07 超长邮箱 / 超长设备字段写入超出列宽的数据

- **严重级:中**
- **源码**:`src/schemas.py:25-32`(`validate_email` 无长度上限);
  `src/schemas.py:22-27`(`device_name` / `platform` / `device_model` /
  `app_version` / `os_version` 全为裸 `str | None`);
  `src/routers/auth.py:_upsert_device` 原样写库
- **测试**:`test_auth_adversarial.py::test_register_accepts_5000_char_email`、
  `test_register_accepts_oversized_device_fields`
- **期望 vs 实际**:期望 422(或截断);实际 200 且落库
- **HTTP 状态码**:200(注册成功)
- **实测落库**:`email` 5008 字符;`devices.name` / `platform` / `device_model`
  各 5000 字符(声明列宽分别为 `String(255)` / `String(128)` / `String(32)` /
  `String(128)`)
- **一句话复现**:`POST /api/v1/auth/register` 带 `email = "b"*5000 + "@example.com"`
  → 200,`users.email` 存入 5008 字符。
- **影响**:SQLite 不强制 VARCHAR 长度 → 测试/开发环境静默存脏数据;**生产 Postgres
  会因 `String(255)` 抛 DataError → 500**(环境相关,故标中危)。超长 email 也会
  污染 admin 用户列表与邮件相关下游。
- **修复方向**:`email` 加 `max_length=255`,设备字段加合理 `max_length`。

---

### F-08 `NaN` 金额 → 500;`Infinity` 金额 → 200 且污染聚合与 CSV 导出

- **严重级:中**
- **源码**:`src/schemas.py:951`(`amount: float`,无 `allow_inf_nan=False`);
  `src/routers/write/_shared.py:597`(`_core` 内 `projection.upsert_tx` 无兜底);
  `src/projection.py:311 / :151`
- **测试**:`test_injection_malformed_adversarial.py::test_nan_amount_returns_4xx_not_500`、
  `test_infinity_amount_silently_persisted`
- **期望 vs 实际**:
  - 期望:422(金额必须为有限数)
  - 实际:`NaN` → **500**(`sqlite3.IntegrityError: NOT NULL constraint failed:
    read_tx_projection.amount`);`Infinity` → **200**,静默入库
- **HTTP 状态码**:NaN 500;Infinity 200
- **Infinity 落库后的读侧表现**(实测):
  - `GET /read/ledgers/{id}/transactions` 的 `amount` 变成 `null`
  - `GET /read/ledgers` 的 `expense_total` / `balance` 变成 `null`
  - `GET /read/summary` 的 `expense_total` / `balance` 变成 `null`
  - `GET /read/workspace/transactions.csv` 直接输出字面 `inf`
  - `/read/ledgers/{id}/stats` 返回 `transaction_total: 1`(计数正常,金额 null)
- **一句话复现**:`POST /write/ledgers/{id}/transactions` body 用
  `{"amount": Infinity}`(`Content-Type: application/json`,Python `json.dumps`
  默认输出 `Infinity`)→ 200;随后账本汇总字段全变 `null`。
- **影响**:单笔 Infinity 即让该账本的所有金额聚合与导出失真(静默,无校验无告警)。
  前端展示 `null` 金额;CSV 里 `inf` 被 Excel 当文本。
- **修复方向**:`amount: float = Field(allow_inf_nan=False)`(pydantic v2),
  或在写路径显式 `math.isfinite` 校验 → 422。

---

### F-09 超 `int64` 的 `offset` / `log_id` → 500

- **严重级:中**
- **源码**:13 处 `offset: int = Query(default=0, ge=0)` 只有下界无上界
  (`src/routers/read/trash.py:155`、`src/routers/mcp_calls.py:73`、
  `src/routers/ai/logs.py:195`、`src/routers/evidence/raw.py:54`、
  `src/routers/read/workspace.py:56` 等);
  `src/routers/ai/logs.py:223`(`log_id: int` 无上界,`db.get(AIAnalysisLog, 10**22)`)
- **测试**:`test_injection_malformed_adversarial.py::test_offset_beyond_int64_returns_500`、
  `test_huge_int_path_param_returns_500`
- **期望 vs 实际**:期望 422 / 404;实际 500
  (`OverflowError: Python int too large to convert to SQLite INTEGER`)
- **HTTP 状态码**:500
- **实测命中端点**(`offset=2**63`):`/read/workspace/trash`、`/profile/mcp-calls`、
  `/ai/logs`、`/evidence/raw` 全部 500;
  `/ai/logs/10000000000000000000000` 亦 500。
  注:`/read/workspace/transactions?offset=2**63` 侥幸 200(参数在该分支被吞掉)。
  Postgres 上 int8 越界同样会报错(环境无关,SQLite 只是更早暴露)。
- **一句话复现**:`GET /api/v1/read/workspace/trash?offset=9223372036854775808` → 500。
- **修复方向**:所有 `offset` / 整型 path 参数加 `le=`(如 `le=2**31`)。

---

### F-10 `note` 无长度上限(1MB / 5MB 单行入库)

- **严重级:中**
- **源码**:`src/schemas.py:953`(`note: str | None = None`);
  对照 `src/schemas.py:1298`(`RawEvidenceUpsertRequest.body` 有 `max_length=65536`)
- **测试**:`test_injection_malformed_adversarial.py::test_unbounded_note_length_is_accepted`
- **期望 vs 实际**:期望拒绝(413/422)或截断;实际 200 且完整入库
- **HTTP 状态码**:200
- **实测**:1MB note 与 5MB note 均返回 200,`read_tx_projection.note` 存入全量文本;
  10MB 请求体亦 200
- **一句话复现**:`POST /write/ledgers/{id}/transactions {"note": "Z"*5000000}` → 200。
- **影响**:存储放大 —— 同一份 note 会同时留在 `sync_changes.payload_json`(append-only,
  长期只增不减,见 `src/main.py` 的 sync_changes 规模观测注释)、`read_tx_projection.note`、
  以及每次 CSV 导出。无上限即成为低成本存储耗尽面。
- **修复方向**:`note` 加 `max_length`(如 65536,与 evidence body 对齐)。

---

### F-11 NUL 字节与控制字符无过滤

- **严重级:低**
- **源码**:`src/schemas.py:1100`(tag `name` 仅长度校验)、`:1074`(category `name`)、
  `:1022`(account `name`),均无字符集/控制字符过滤
- **测试**:`test_injection_malformed_adversarial.py::test_nul_byte_in_text_fields`
- **期望 vs 实际**:期望 422 或静默剥离;实际 200 且 `\u0000` 原样落库并回读
- **HTTP 状态码**:200
- **一句话复现**:`POST /write/ledgers/{id}/tags {"name":"evil\u0000name"}` → 200;
  `GET /read/workspace/tags` 回读 `"evil\u0000name"`。
- **影响**:NUL/控制字符进入 TEXT 列后,下游(文件命名、日志、部分导出工具)会截断或
  产生不可见字符污染;`evidence._validate_source` 已对 source 做控制字符拒绝
  (`src/routers/evidence/_shared.py:_validate_source`),但名称字段未对齐该口径。
- **修复方向**:名称类字段统一拒绝 `ord(ch) < 32`(或以 `\uFFFD` 替换)。

---

### F-12 非法 UTF-8 代理对(`\ud800`)→ 500

- **严重级:低**
- **源码**:写路径未对字符串做 UTF-8 可编码性校验;`src/routers/write/tags.py:59`
  (`create_tag_api` → mutate → 落库)
- **测试**:`test_injection_malformed_adversarial.py::test_lone_surrogate_rejected_with_422_not_500`
- **期望 vs 实际**:期望 422;实际 500
  (`UnicodeEncodeError: 'utf-8' codec can't encode character '\ud800'`)
- **HTTP 状态码**:500
- **一句话复现**:`POST /write/ledgers/{id}/tags` body 用
  `{"name":"x\ud800y"}`(JSON 转义 `\\ud800`,Python str 允许 lone surrogate)
  → 500。
- **修复方向**:字段 validator 做 `value.encode("utf-8")` 试编码,失败即 422。

---

### F-13 CSV 公式注入未缓解

- **严重级:低**
- **源码**:`src/routers/read/_shared.py:666-675`(`_csv_field` 只做 RFC 4180
  引号/换行转义,**不处理 `=`/`+`/`-`/`@` 公式前缀**)
- **测试**:`test_injection_malformed_adversarial.py::test_csv_formula_injection_not_mitigated`
- **期望 vs 实际**:期望对 `=` 开头的单元格加 `'` 前缀或用制表符包裹(OWASP CSV
  Injection);实际原样输出 `=cmd|'/C calc'!A0`
- **HTTP 状态码**:200
- **实测 CSV 行**:`Expense,,,2.00,CNY,,,,=cmd|'/C calc'!A0,  2026-05-06 12:31:00  ,,`
- **一句话复现**:记账时 note 填 `=cmd|'/C calc'!A0` → web 导出 CSV → 在 Excel 打开
  触发公式解析。
- **影响**:需要用户在 Excel 打开导出文件时才会触发,故低危;但用户可直接在 App 里
  输入备注,构成存储型注入链。

---

## 二、HARDENING 条目(行为可辩护但脆弱,已断言并通过)

| # | 条目 | 位置 | 说明 |
|---|---|---|---|
| H-01 | 同形字邮箱可建双账号 | `test_auth_adversarial.py::test_unicode_confusable_email_creates_separate_account` | `lower()` 无法防 IDN 同形字(`аdmin` vs `admin`);需字符集/域名策略 |
| H-02 | 设备吊销不杀 access token | `test_auth_adversarial.py::test_device_revocation_does_not_kill_access_token_for_rest_reads` | 撤销设备后 refresh 与 device 校验端点正确拒绝(401/403),但 `GET /read/*`、CSV 仍 200(无状态 JWT,无 token 版本号/黑名单) |
| H-03 | Authorization header 宽容解析 | `test_auth_adversarial.py::test_authorization_header_whitespace_laxity` | `Bearer  <tok>`(双空格)、`bearer <tok>`(小写)均被接受(`OAuth2PasswordBearer` 用 `split()`);不构成越权 |
| H-04 | app token 可管理自己的 PAT | `test_token_scope_adversarial.py::test_app_scope_token_can_list_own_pats` | `src/routers/pats.py:43-45` 的 `_AUTH_SCOPE_DEP` 含 `app_write`,与「PAT 管理须用 access token」注释一致但略宽 |
| H-05 | 跨用户同名 external_id 静默建第二份账本 | `test_token_scope_adversarial.py::test_app_push_with_foreign_ledger_id_does_not_corrupt_victim_ledger` | app push 未知 external_id 时自动建 caller 自己的同名账本(数据分裂,非越权);ghost-ledger guard 部分覆盖 |
| H-06 | Idempotency 键含 device 维度 | `test_token_scope_adversarial.py::test_idempotency_key_scope_is_per_device_and_user` | 同 key 换 device header 视为新请求 → 可能静默产生第二笔 |
| H-07 | workspace 端点对他人 ledger_id 返回 200 空集 | `test_idor_adversarial.py::test_foreign_ledger_id_in_workspace_filters_leaks_nothing` | 过滤正确(不泄漏),但调用方无法区分"无数据"与"无权" |
| H-08 | admin 不跨用户读账本 | `test_idor_adversarial.py::test_admin_cannot_read_other_users_ledgers_via_web_read` | `src/routers/read/_shared.py:_is_admin()` 恒 False,刻意关闭旁路;跨用户诊断须走 `/admin/*` |
| H-09 | `/admin/devices` 对非 admin 返回 200 只含自己 | `test_idor_adversarial.py::test_admin_devices_endpoint_filters_for_non_admin` | 无越权,但与其它 admin 端点的 403 语义不一致 |
| H-10 | sync/push 深嵌套 payload 被接受 | `test_injection_malformed_adversarial.py::test_deeply_nested_json_in_sync_push_payload_is_contained` | 150 层嵌套落 `SyncChange.payload_json`(存储放大),但投影侧只读白名单字段,不带到读路径 |

---

## 三、已验证为**正确防御**的关键项(绿)

- **JWT**:错密钥签名、`alg=none`、篡改 `sub`、过期 token、refresh↔access 互换 → 全部 401
- **令牌生命周期**:删除/禁用用户后旧 token 401/403;PAT 删除/过期/用户禁用 → 401/403;
  refresh 轮换后旧 refresh 401;logout 只撤自己的 refresh
- **PAT↔JWT 严格分流**:PAT 打常规 API 403;JWT 打 MCP 403;匿名打 MCP 401;
  PAT 不能自管 PAT(403)
- **PAT scope 严格白名单**:`mcp:ADMIN` / `mcp:read `(尾空格)/ `MCP:READ` / `*` / `[]`
  全部 422
- **MCP 工具级 scope**:read-only PAT 调 write tool → `PermissionError`;反向同理
- **越权矩阵**:非成员对 A 账本 16 个读端点全部 404、16 个写端点全部 403/404/422,
  且 A 的数据(账本名、交易数)完全不变
- **workspace 聚合**:11 个跨账本端点带他人 `ledger_id` / `user_id` 过滤均不泄漏
  (无 A 的账本名/备注)
- **共享账本**:邀请码 30 次随机猜测全 404;撤销后 preview/accept 404;一次性语义;
  editor 不能踢 owner / 不能 transfer / 不能建邀请 / 不能改成员角色 / 不能删账本 /
  不能推 ledger/ledger_snapshot;被移除成员 push 被拒(`membership_revoked`)、读权限立即失效;
  成员上限 5 生效;自接受自己邀请 409
- **设备/账号隔离**:B 不能 revoke A 的设备(404);B 的 device 列表只含自己;
  B 用 A 的 device_id 调 pull/push → 401
- **AI 日志 / MCP 调用日志 / evidence / 头像**:全部按 `user_id` 过滤,跨用户 404 或空集
- **附件下载**:非成员 403、匿名 401、被移除成员 403;超体积 413;空文件 400;
  文件名穿越被 `_safe_file_name` 收敛为 basename
- **注入**:SQL 注入串(5 种)在交易备注/tag/查询参数中全部按字面存储,表结构与
  `is_admin` 未被改写;XSS 串按数据回读
- **分页/枚举校验**:所有已声明的 `limit` 负数/0/超界/非数字 → 422;`status`/`entry_type`
  pattern 校验 422;汇率 `base` pattern 422;超额 `rate` 422
- **profile 字段**:`theme_primary_color` 严格 `#RRGGBB`(含大小写归一化);
  `primary_currency` pattern;`display_name` 空/超长 422
- **SPA 静态路径**:`..%2F..%2Fdata%2F.jwt_secret` 等 3 种穿越变体全部 404,无文件内容泄漏
- **WS**:非 JSON / 数字 token / 认证前发数据 / 错误 type → `close(1008)`;
  PAT 与 refresh token 不能当 WS 凭据(1008);query token 兼容路径工作正常
- **admin 边界**:非 admin 打 8 个 admin 端点全部 403;未知 user_id → 404

---

## 四、未能验证项(不写 flaky 测试)

1. **Postgres 专有行为**:`String(255)` 越界抛 `DataError`、`int8` 越界报错、advisory
   lock 语义 —— sqlite in-memory 无法覆盖。F-07 / F-09 的"生产影响"为推断,
   测试环境证据是 SQLite 侧静默放行。
2. **真实并发竞态**:4 线程并发注册同邮箱在 SQLite 单文件锁下**全部 500**(竞态窗口被
   锁放大),但无法稳定复现"恰好一胜一负"的生产行为,故 F-06 用自定义 Session 确定性
   复现 flush 分支,而非线程跑。
3. **`external_id` 路径穿越的真实落地后果**:`_safe_file_name` 限制了文件名(仅 basename),
   未验证"覆盖既有文件"或"写入可执行路径"的完整利用链(需要具体部署目录知识)。
   F-03 的测试只证明路径逃出根目录。
4. **附件上传的 NUL 文件名**:`evil\x00.sh` 在 TestClient 的 multipart 编码层即被拒绝
   (未到达服务端),无法判断服务端行为 —— 依赖 `Path(raw).name` 的实现也未验证。
5. **`/ai/logs/{log_id}` 超大整数在 Postgres 的行为**:SQLite 报 `OverflowError`,
   Postgres 可能报 `DataError`;状态码一致(500),但错误归因不同。
6. **限流(`_apply_rate_limit`)**:`conftest` 设 `PYTEST_CURRENT_TEST` 时直接 return
   (`src/routers/auth.py:140`),测试环境不可测。生产默认 60s/30 次。
7. **MCP Streamable HTTP 端到端 tool 调用**:真实 session manager 需要 lifespan;
   `with TestClient(app)` 会触发 startup 对真实 DB 跑备份调度器(污染环境),
   故用 ASGI 直调 + stub `handle_request` 验证分流与鉴权,未走真实 JSON-RPC 往返。
8. **WS 的"认证为 B 却订阅 A 的 ledger"**:`/ws` 协议只有心跳,无订阅消息,
   fan-out 由服务端按 `LedgerMember` 决定 —— 没有可注入的订阅参数,
   无从构造该攻击面。

---

## 五、覆盖清单对照

| 攻击清单条目 | 覆盖情况 | 测试 |
|---|---|---|
| 重复邮箱大小写变体 | ✅ | `test_duplicate_email_case_variant_rejected` |
| Unicode 同形字邮箱 | ✅ HARDENING | `test_unicode_confusable_email_creates_separate_account` |
| 超长邮箱/密码、空密码 | ✅ 红 F-05 / F-07 | `test_register_huge_password_*`、`test_login_huge_password_*`、`test_register_accepts_5000_char_email`、`test_empty_and_short_password_rejected` |
| 非常规 client_type / 缺字段 | ✅ | `test_missing_fields_and_bad_client_type_rejected` |
| 并发两次注册同邮箱 | ✅ 红 F-06 | `test_register_integrity_error_on_flush_returns_409` |
| 登录错误密码/不存在用户/大小写 | ✅ | `test_login_nonexistent_and_wrong_password_are_indistinguishable`、`test_duplicate_email_case_variant_rejected` |
| 登录响应敏感字段 | ✅ | `test_login_response_has_no_secret_fields` |
| JWT 伪造/篡改/alg/过期 | ✅ | 5 条 `test_*jwt*` / `test_tampered_*` / `test_expired_*` |
| 删用户/设备后旧 token | ✅ + HARDENING H-02 | `test_token_of_deleted_user_rejected`、`test_device_revocation_*` |
| 撤销后 PAT / 跨用户 PAT / app scope | ✅ | `test_deleted_pat_is_immediately_rejected`、`test_pat_cross_user_management_forbidden`、`test_app_scope_token_blocked_from_web_write_and_read` |
| 作用域非法值/大小写/空格注入 | ✅ | `test_pat_scope_values_are_strict` |
| PAT 名称超长/Unicode | ✅ | `_create_pat(name="n"*129)` → 422 |
| Idempotency-Key 重放/换 body | ✅ | `test_idempotency_key_replay_creates_single_transaction`、`test_idempotency_key_reuse_with_different_body_returns_409` |
| IDOR:ledger 全部子实体读/写/删 | ✅ | `test_web_idor_matrix_reads_return_404`(16 端点)、`test_web_idor_matrix_writes_rejected`(16 端点) |
| IDOR:trash restore/purge | ✅ | 含在写矩阵 |
| IDOR:analytics / member stats / shared_resources | ✅ | 含在读矩阵 |
| IDOR:invites | ✅ | 含在矩阵 + `test_non_member_cannot_guess_ledger_to_create_invite` |
| sync:push 伪造 A 的 ledger_id | ✅ + HARDENING H-05 | `test_sync_push_cannot_write_victim_ledger`、`test_app_push_with_foreign_ledger_id_*` |
| sync:pull 带 A 的 ledger_id / change_id 侧信道 | ✅ | `test_sync_pull_only_returns_own_changes`、`test_foreign_ledger_id_in_workspace_filters_leaks_nothing` |
| 共享账本:未受邀加入 / 猜 invite code | ✅ | `test_invite_code_enumeration_is_expensive_and_fails`、`test_non_member_cannot_guess_*` |
| 邀请码枚举/失效码/超次数码 | ✅ | `test_revoked_invite_cannot_be_used`、`test_invite_is_single_use`、`test_invite_active_limit_enforced` |
| 被移除成员用旧 token push | ✅ | `test_removed_member_cannot_continue_pushing` |
| WebSocket:各种认证变体/畸形 JSON/大帧 | ✅ + 红 F-02 | `test_ws_requires_first_message_auth`、`test_ws_rejects_pat_and_refresh_token`、`test_ws_accepts_token_of_disabled_user` |
| MCP:无凭据/低权限 PAT/调用日志越权 | ✅ | `test_mcp_endpoint_routes_pat_not_jwt`、`test_mcp_tool_scope_guard_rejects_missing_scope`、`test_mcp_call_logs_only_own_records` |
| 注入:SQL/`<script>`/`../`/`%00`/10 万字符 | ✅ 红 F-03/F-11 | `test_sqli_payloads_are_stored_verbatim_*`、`test_xss_payloads_stored_as_data`、`test_path_traversal_*`、`test_nul_byte_in_text_fields`、`test_oversized_ledger_name_rejected` |
| 分页:负数/0/极大/非数字 | ✅ 红 F-09 | `test_pagination_bounds_rejected_with_422`(6 参数化)、`test_offset_beyond_int64_returns_500` |
| JSON body:数组/深层嵌套/超大 | ✅ 红 F-04/F-08 | `test_json_structure_malformations_return_4xx`、`test_deeply_nested_json_in_profile_corrupts_profile_read`、`test_nan_amount_*`、`test_infinity_amount_*` |
| header:超长/畸形 Bearer | ✅ | `test_authorization_header_malformed_variants`、`test_authorization_header_whitespace_laxity` |

---

## 六、优先级建议

| 优先级 | 缺陷 | 理由 |
|---|---|---|
| P0 | F-03(路径穿越写文件)、F-04(profile 自锁 500) | 可被单个已认证用户直接利用;F-04 无需特权且自锁 |
| P0 | F-01(同名 external_id → 成员全端点 500) | `default` 是默认账本名,真实场景高频;接受共享邀请后自锁 |
| P1 | F-02(禁用用户仍收 WS 推送) | 账号处置失效,持续性信息泄漏 |
| P1 | F-05 / F-06(注册/登录 500) | 公开入口可无凭据触发 500 |
| P2 | F-07 / F-08 / F-09 / F-10 | 脏数据入库、聚合污染、参数越界 500、存储放大 |
| P3 | F-11 / F-12 / F-13 | 控制字符、lone surrogate、CSV 公式 |
