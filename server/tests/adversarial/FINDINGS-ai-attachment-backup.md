# 对抗性测试发现 — AI 中转 / 附件 / 备份 / 原始证据 / MCP

- **日期**: 2026-10-11
- **范围**: `server/src` 的 AI 中转(`/ai/relay/*`)、AI 服务商配置(`/ai/providers`)、
  AI 调用日志(`/ai/logs` + `ai_analysis_logs`)、附件(`/attachments/*`)、
  备份/恢复/保留(`/admin/backup*`、`services/backup/*`)、原始证据(`/evidence/raw`)、
  MCP(`/api/v1/mcp`)。
- **测试文件**（本轮仅改这 5 个 + 本报告，未触碰 `src/**` 与任何既有测试）:
  - `tests/adversarial/test_ai_relay_adversarial.py`
  - `tests/adversarial/test_ai_providers_adversarial.py`
  - `tests/adversarial/test_attachment_adversarial.py`
  - `tests/adversarial/test_backup_evidence_adversarial.py`
  - `tests/adversarial/test_mcp_adversarial.py`
- **红绿纪律**:
  - `# ADVERSE FINDING:` = 已确认缺陷，断言按「安全行为」写，**保持红**；
  - `# HARDENING:` = 行为可辩护但脆弱，断言当前行为，**通过**。
- **LLM 全部走本地回环假服务**（`http.server` 绑 127.0.0.1 随机端口）或直接 mock，
  **没有任何真实外网 LLM 调用**；破坏性命令只做参数化/静态验证，不真执行。

---

## 0. 结果总览

| 文件 | 用例 | 绿 | 红（ADVERSE） |
|---|---|---|---|
| `test_ai_relay_adversarial.py` | 31 | 22 | 9 |
| `test_ai_providers_adversarial.py` | 19 | 13 | 6 |
| `test_attachment_adversarial.py` | 26 | 19 | 7 |
| `test_backup_evidence_adversarial.py` | 51 | 44 | 7 |
| `test_mcp_adversarial.py` | 21 | 19 | 2 |
| **合计** | **148** | **117** | **31** |

- 合并运行（5 个文件同一次 pytest）：`31 failed, 117 passed`，稳定可复现。
- **基线未被污染**：`python -m pytest tests/ --ignore=tests/adversarial` → **623 passed**。
- 31 个红用例归并为 **19 条缺陷**：**高 5 / 中 13 / 低 1**。
- 本轮修复的测试侧问题（不是产品缺陷）：MCP 文件 3 处 `client = mcp_client` 被写进
  docstring 导致 `NameError`、1 处过严断言（401 vs 403）、**1 处会让整个文件无限挂起的
  GET 用例**（上一轮“限频中断”之外的另一个跑不完的原因）、日志等待窗口过短导致的偶发误报。

---

## 1. 确证缺陷（红）

### 1.1 高危（5 条 / 12 个红用例）

---

#### F-01 账本 `external_id` 直拼磁盘路径 → 附件可写到存储根之外（5 个红用例）

- **严重级**: 高
- **证据**:
  - `src/routers/attachments.py:140` — `_attachment_root() / ledger.user_id / ledger.external_id / sha256[:2]`
  - `src/schemas.py`（`ledger_id` 只有长度校验，无字符集白名单）
  - 用例：`test_ledger_id_traversal_escapes_attachment_root`、`test_sync_push_created_traversal_ledger_also_escapes`、
    `test_absolute_ledger_id_escapes_root`、`test_ledger_external_id_backslash_escapes_root`、
    `test_ledger_id_traversal_can_target_sibling_storage_dir`（`tests/adversarial/test_attachment_adversarial.py`）
- **期望 vs 实际**:
  - 期望：`external_id` 落盘前安全化（白名单字符 / storage key 用哈希），任何落点都在 attachment 根内。
  - 实际：4 种形态全部逃出根目录，实测落点：
    - `ledger_id="../../escaped-adv"` → `<attroot>/../escaped-adv/0b/<sha>_evil.png`
    - `ledger_id="/tmp-abs-adv-escaped"` → **`C:\tmp-abs-adv-escaped\3c\<sha>_abs.png`（文件系统绝对位置）**
    - `ledger_id="..\\..\\winescaped-adv"`（Windows 分隔符）→ 逃出根
    - `ledger_id="../../ai_log_images/pwn"` → 落进**兄弟存储域**（可伪造/覆盖 AI 日志图片）
  - 第二入口：`POST /sync/push` auto-create 账本（连长度都不校验）同样可穿越，
    `POST /write/ledgers` 的校验补上也不够，两处必须同时收紧。
- **复现**:
  ```bash
  python -m pytest tests/adversarial/test_attachment_adversarial.py -k "traversal or escapes_root or backslash"
  ```

---

#### F-04 relay / `/providers/test` 的 `baseUrl` 无 SSRF 防护（3 个红用例）

- **严重级**: 高
- **证据**:
  - `src/services/ai/provider_client.py:838`（`url = f"{config.base_url}/chat/completions"`）、
    `:1014`、`:1036`（vision / stt 同款）
  - `src/routers/ai/providers.py:465`（`test_stored_provider` 直接用存储配置出站）
  - `src/config.py` 中**不存在**任何 `allow_private_hosts` / SSRF 开关（用例里 `getattr(...)` 恒为 `None`）
  - 用例：`test_relay_base_url_loopback_is_reachable_by_design`、`test_relay_metadata_endpoint_reachable`、
    `test_providers_test_reaches_loopback_with_stored_key`
- **期望 vs 实际**:
  - 期望：出站目标有 scheme/host 策略（默认拒环回/链路本地/私网，或至少有显式开关）。
  - 实际：
    - 非 http(s) scheme（`file://`、`gopher://`）被 httpx 挡住 → 502（**这条是好的**，见绿用例
      `test_relay_non_http_scheme_base_url_no_500`）；
    - **http/https 畅通无阻**：本地回环假 LLM 被真实命中 1 次，路径 `/internal-metadata/chat/completions`
      且 `Authorization` 头带着该用户 apiKey 一起发过去；
    - `http://169.254.169.254/latest/meta-data` **未被 host 黑名单拦截**，请求真实发出（本机网络不可达 → 502
      `network error: All connection attempts failed`，在云主机上会打到实例元数据服务）；
    - `/ai/providers/test` 更直接：请求体不带 key 时**服务端从存储取出真 key 代发**，
      响应回传 `preview`（上游 body 前段）→ 内网响应可被回读。
- **影响**：一个普通账号即可把服务端当内网探测代理（端口扫描 + 响应回读），并把 apiKey 外带到任意 host。
- **复现**:
  ```bash
  python -m pytest tests/adversarial/test_ai_relay_adversarial.py -k "loopback or metadata"
  python -m pytest tests/adversarial/test_ai_providers_adversarial.py -k "reaches_loopback"
  ```

---

#### F-12 备份产物用 `external_id` 拼盘路 → 写出备份根之外（2 个红用例）

- **严重级**: 高
- **证据**:
  - `src/routers/admin.py:883` — `_backup_root() / ledger.external_id / "db"`
  - `src/routers/admin.py:947` — `_backup_root() / ledger.external_id / "snapshot"`
  - 用例：`test_upload_db_ledger_traversal_escapes_backup_root`、`test_upload_snapshot_ledger_traversal_escapes_backup_root`
- **期望 vs 实际**:
  - 期望：产物路径与附件域同标准（external_id 安全化），始终落在 backup 根内。
  - 实际：`ledger_id="../../bk-escaped-adv"` → 产物落到 `<bkroot>/../../bk-escaped-adv/db/<artifact>_x.sqlite3`。
    upload-snapshot 走 **JSON body**（非 multipart），不经 multipart 规范化，更难被 WAF/网关挡住。
- **影响**：备份产物是**整库 SQLite 副本**；有 ops 权限的账号可把它投放到任意可写路径
  （DATA_DIR 其它子目录、`.env` 同级位置等）。
- **复现**:
  ```bash
  python -m pytest tests/adversarial/test_backup_evidence_adversarial.py -k "upload_db_ledger_traversal or upload_snapshot_ledger_traversal"
  ```

---

#### F-14 rclone 配置字段未过滤换行 → 可向 `rclone.conf` 注入伪造 section（1 个红用例）

- **严重级**: 高
- **证据**:
  - `src/routers/admin_backup.py:100`（`_split_config` 只 strip 首尾空白 + 按白名单挑键）
  - `src/services/backup/rclone_config.py`（configparser 写值时不报错，含 `\n` 输出为续行）
  - 用例：`test_rclone_config_field_with_newline_is_injection_vector`
- **期望 vs 实际**:
  - 期望：写入 conf 前过滤值里的 `\r`/`\n`（或直接 422 拒绝）。
  - 实际：`config.url = "http://127.0.0.1/x\n[injected]\ntype = local\nroot = /tmp"`
    生成的 conf 中出现**用户伪造的段头** `[injected]`（go-ini 对 TrimLeft 后以 `[` 开头的行按新 section 解析）。
    攻击者可在服务端 `rclone.conf` 里凭空造 backend，把 `local` 的 `root` 指向任意绝对路径，
    后续 backup / restore / retention 就在那里读写删。
- **边界**：按规则**未真执行 rclone**（不跑破坏命令）；注入面通过「conf 生成结果」直接断言。
- **复现**:
  ```bash
  python -m pytest tests/adversarial/test_backup_evidence_adversarial.py -k "rclone_config_field"
  ```

---

#### F-16 归档解包无体积上限（zip bomb 直接吃满磁盘）（1 个红用例）

- **严重级**: 高
- **证据**：
  - `src/services/backup/tar_builder.py:119`（`zf.extractall(dst)`，无累计写入上限）
  - `src/services/backup/restore_runner.py:279`（tar 分支同理）
  - 用例：`test_extract_zip_zip_bomb_has_no_size_guard`
- **期望 vs 实际**：
  - 期望：解包时累计已写字节并设上限（如 `10 × 压缩后大小` 或绝对上限），超限中止。
  - 实测：**压缩后 65,349 字节的 zip 解出 67,108,864 字节（放大 1027 倍）**，0.1s 内写出。
    restore 侧唯一体积检查 `check_disk_space(required=bytes_total*2)` 用的是**压缩后**大小，严重低估。
- **影响**：远端（或中间人可控的 rclone 目标）放一个高压缩比归档 → 磁盘预检通过 → 解包打满磁盘，
  把 live DB 写入带崩（自部署单机）。
- **复现**：
  ```bash
  python -m pytest tests/adversarial/test_backup_evidence_adversarial.py -k "zip_bomb"
  ```

---

### 1.2 中危（13 条 / 18 个红用例）

| 编号 | 缺陷 | 证据 | 期望 → 实际 | 用例 |
|---|---|---|---|---|
| **F-02** | 附件上传零内容校验：HTML + 声明 `image/png` 落库，下载响应仍回写 `image/png` | `src/routers/attachments.py:150`（`mime_type=file.content_type`） | 期望对 `image/*` 做魔数校验或统一 octet-stream 回写 → 实际原样回写（同源 `/api/v1/attachments/<id>` 被 `<img>` 引用即渲染，存储型 XSS 面） | `test_upload_html_disguised_as_image_is_accepted` |
| **F-03** | `batch-exists` 的 `sha256_list` 无条数上限 → SQL 变量溢出 500 | `src/routers/attachments.py:191-201`、`src/schemas.py:1149`（`list[str]` 无 `max_length`） | 期望 413/422 → 实际 6 万条直接 500（Postgres 上同源：65535 参数上限），任一登录用户零成本 DoS | `test_batch_exists_unbounded_list_causes_500` |
| **F-05** | 脏 `visionConcurrency` 把 relay 打成 500（chat 与 vision-batch 同源） | `src/services/ai/provider_client.py:460`（`int(matched.get("visionConcurrency") or 3)`） | 期望 400 配置类错误 → 实际 `TypeError` → 全局兜底 500（客户端会当 transient 一直重试） | `test_relay_unexpected_provider_config_type_is_500`、`test_relay_vision_batch_bad_vision_concurrency_is_500` |
| **F-06** | vision MIME 只信**文件名后缀**，无 magic bytes | `src/routers/ai/relay.py:225-240`（`_resolve_image_mime`：content-type 不在白名单即回落到后缀） | 期望仅凭后缀不足以过校验 → 实际 `text/html` + `.png`、`PK\x03\x04` zip + `.png`（缺 content-type）都 200 并被 base64 转发上游 | `test_vision_accepts_content_type_spoofed_html_with_png_suffix`、`test_vision_zip_renamed_png_suffix_only_is_accepted_when_ct_missing` |
| **F-07**（低） | STT 把 `application/octet-stream` 一律当音频，无魔数校验 | `src/routers/ai/relay.py:667` | 期望至少校验 wav/mp3 头 → 实际 HTML 载荷 200 转发上游 | `test_stt_octet_stream_html_body_is_forwarded` |
| **F-08** | vision-batch 无图片张数上限，且**限流只记 1 个令牌** | `src/routers/ai/relay.py:540`（循环无长度校验）、`:561`（`_rate_limited` 只在入口调一次） | 期望按张数计限流 + 张数上限 → 实测 16 图只耗 1 令牌、8 图 = 8 次上游调用 / 1 令牌，`60/分钟` 实际可放大成 `60×N` 次上游调用 | `test_vision_batch_has_no_image_count_cap`、`test_relay_vision_batch_amplifies_rate_limit_tokens` |
| **F-09** | 掩码串变形（少一个星 / 带空白 / `*`）被当新 key **静默覆盖真 key** | `src/services/ai/ai_config_store.py:70,74`（`is_unset_key` 只认 `startswith("****")`，不 strip） | 期望形如掩码的串一律视为未变更（或 400 让用户确认）→ 实际 `***abcd`、` ****abcd`、`*` 全部写成 key，之后所有 AI 调用 401 且掩码显示几乎不变，用户无从发现 | `test_patch_near_miss_mask_overwrites_real_key`、`test_patch_whitespace_padded_mask_overwrites_key`、`test_profile_patch_ai_config_near_miss_mask_overwrites_key`（`/profile/me` 合并路径同源，影响面更大） |
| **F-10** | provider 数量无上限 → `ai_config_json` 单行无界增长 | `src/routers/ai/providers.py:287`（create 无计数校验） | 期望有上限（如 32）超出 400 → 实测 60/60 全部 201；满配约 5KB/个，relay 热路径每次 `json.loads` 整串 | `test_provider_count_has_no_cap` |
| **F-11** | `/ai/providers/test` 无任何限流（`/ai/test-provider` 有 30/min） | `src/routers/ai/providers.py:465`（未调 `_check_rate_limit`） | 期望与 `/ai/test-provider` 对等限流 → 实测 50 连发全 200；结合 F-04 = 一个**无限速内网扫描器** | `test_providers_test_has_no_rate_limit` |
| **F-13** | `run-now` 无互斥，同一 schedule 可并发触发两个备份 | `src/routers/admin_backup.py:737`、`:795`（`threading.Thread(target=_bg)`；APScheduler 的 `max_instances=1` 不覆盖这条路径） | 期望已有 running run 时 409 → 实际连点两次两个后台任务同时跑（同 remote 并发 copyto 互覆、retention 互删、staging 双份占盘） | `test_run_now_twice_creates_two_background_runs` |
| **F-15** | `rclone.conf` 是**单文件**且按 `user_id` 全量重写 → 多 admin 互相清空 | `src/services/backup/rclone_config.py:224`（`rewrite_from_db` 只写 caller 的 remote） | 期望按 user 分文件或合并写 → 实际 adminB 一次常规操作把 adminA 的 remote 抹掉，定时备份静默失效 | `test_rclone_conf_is_shared_across_admins_and_gets_clobbered` |
| **F-17** | `POST /evidence/raw/cleanup` 空 body 删掉**全部**证据（无 TTL 语义） | `src/routers/evidence/raw.py:157,164`（payload 缺失 → `cutoff = now`，条件 `captured_at < cutoff`） | 期望缺省只删已过期（或要求显式 `before`）→ 实际 3 条未过期证据被一次空请求全删，取证数据不可逆丢失 | `test_evidence_cleanup_default_wipes_everything_captured_before_now` |
| **F-18** | MCP scope 越权尝试**不落审计日志** | `src/mcp/server.py:119-160`（`require_mcp_scope` 在 `try` 之前抛出，`finally` 里的 `_write_call_log` 没机会执行） | 期望越权探测留痕 → 实测只读 PAT 打写工具后 `MCPCallLog` 为空，可无限次爆破且日志干净 | `test_scope_violation_is_audit_logged` |
| **F-19** | MCP `GET /api/v1/mcp` **永不返回**（连接悬挂），且日志已记 200 | `src/mcp/server.py:517`（`StreamableHTTPASGIApp`）、`src/main.py:196`（`Route` 挂载）、`src/observability.py:45`（`call_next` 返回即打 200） | 期望 405/406 明确拒绝，或立即发响应头再保持 SSE → 实测两路独立验证：① `TestClient` 5s 内连 `http.response.start` 都收不到；② 真实 uvicorn + httpx(timeout=5) 客户端 `ReadTimeout`，而服务端 access 日志已是 `GET /api/v1/mcp → 200`（**监控与实际严重不一致**）。持 PAT 者可并发开 N 个 GET 占满连接 | `test_mcp_get_with_pat_never_returns` |

**F-09 / F-10 / F-11 / F-13 复现**：
```bash
python -m pytest tests/adversarial/test_ai_providers_adversarial.py -k "near_miss or whitespace or profile_patch_ai_config_near or count_has_no_cap or has_no_rate_limit"
python -m pytest tests/adversarial/test_backup_evidence_adversarial.py -k "run_now_twice or shared_across_admins"
```

**F-17 / F-18 / F-19 复现**：
```bash
python -m pytest tests/adversarial/test_backup_evidence_adversarial.py -k "cleanup_default"
python -m pytest tests/adversarial/test_mcp_adversarial.py -k "scope_violation or never_returns"
```

---

## 2. HARDENING（绿：行为可辩护但脆弱，已断言当前行为）

| 主题 | 当前行为 | 用例 |
|---|---|---|
| 非 http(s) scheme | `file://` / `gopher://` → 502 `AI_PROVIDER_ERROR`（不 500、不透传栈） | `test_relay_non_http_scheme_base_url_no_500` |
| vision / stt 0 字节 | 放行并白打一次上游（与 `/attachments/upload` 的 400 口径不一致） | `test_vision_zero_byte_image_is_accepted`、`test_stt_zero_byte_audio_is_forwarded` |
| 上游错误 body 透传 | 截断后回传，canary 字样在响应里可见（排障 vs 泄敏的取舍） | `test_relay_error_message_truncates_upstream_body` |
| 限流窗口不共享 | relay 60/min 与 `/providers/test` 各算各的（无总闸，与 F-11 互补） | `test_providers_test_does_not_share_relay_rate_window` |
| 文件名 NUL / Unicode | multipart 把 NUL 转义成 `%00`；RTL 覆写字符原样落库，但下载头已 percent-encode | `test_filename_nul_byte_is_stored_as_percent_encoding`、`test_unicode_filename_is_stored_verbatim` |
| 附件去重 | 同账本同 sha 复用行；跨账本不复用；预检竞态由唯一索引兜底并回收孤儿文件 | `test_same_image_twice_in_ledger_reuses_row`、`test_dedup_race_path_reclaims_orphan_storage`、`test_cross_ledger_same_bytes_create_separate_rows` |
| GC 引用保护 | 被 tx 投影引用（含**他人投影**）的附件不误删；孤儿行+磁盘文件清掉 | `test_gc_preserves_referenced_and_removes_orphan`、`test_gc_referenced_by_other_users_projection_is_preserved` |
| rclone 命令注入 | `RcloneRunner` 用 `subprocess(list)` 非 `shell=True`；remote name `^[A-Za-z0-9_-]+$`；cron 非法 400 | `test_rclone_runner_passes_args_as_list_not_shell`、`test_rclone_remote_name_pattern_rejects_shell_metacharacters`、`test_schedule_cron_expr_injection_rejected` |
| retention 边界 | 0/负 → 归一并 keep_at_least=1；3650 天不删；cutoff 精确边界；重复计算幂等 | `test_retention_*`（5 个） |
| tar 穿越 | `filter="data"` 拒 `../`（依赖 Python 3.12+，老版本该分支被忽略是平台风险） | `test_restore_tar_extraction_rejects_parent_traversal` |
| pg_dump / sqlite | sqlite URL → `RuntimeError` 明确提示（非裸栈 500）；缺二进制 → 带修复指引 | `test_pg_dump_rejects_sqlite_url_with_clear_error`、`test_pg_dump_missing_binary_gives_actionable_error` |
| 证据 TTL / IDOR / 边界 | 过期插入 410、过期读 404 并顺手删；B 读改删 A → 404；`limit/offset` 负数与极值 422；`event_key` 幂等；`Cache-Control: no-store` | `test_evidence_*`（12 个） |
| MCP 帧与鉴权 | 无凭据/非 PAT/撤销/过期/禁用用户 → 401/403；非 JSON/空 body → parse error；12MB 帧 → 413；unknown tool（含 `\x00`、5000 字符）优雅报错且不落日志 | `test_mcp_*`（14 个） |
| **新增**：`/ai/logs` 读路径 | `entry_type`/`status` 注入串、`limit=-1`/`999999`、`offset=-5` 全部 422（`_ENTRY_TYPE_PATTERN` 只认 5 个枚举）；`offset` 极大值 200 空页；写入侧 `entry_type: Literal[...]` 同样 422 且不落库 | `test_ai_logs_filter_injection_and_pagination_bounds`（本轮补） |
| **新增**：附件 `Content-Length` 谎报 | 虚报 +10KB / 少报 −20B / 巨额 +9MB 全部 200，按**实际字节**解析与计数（size/sha 都是真实载荷），不 500、不挂起 | `test_upload_content_length_lie_is_tolerated_and_sizes_true`（本轮补） |

---

## 3. 本轮对 5 个测试文件的改动（只改测试，未动 `src/**`）

1. **MCP 结构性错误修复（3 处）**：`client = mcp_client` 一行被误写进 docstring，函数体没有 `client`
   → `NameError`（`test_mcp_missing_accept_header_negotiation`、
   `test_unknown_tool_name_with_control_characters_is_graceful`、`test_args_summary_skips_free_text_fields`）。
2. **MCP 断言修正**：`test_mcp_disabled_user_pat_is_401` → 更名 `test_mcp_disabled_user_pat_is_rejected`，
   断言 `in (401, 403)`（源码 `_AuthError(403, "User disabled")`，鉴权过、授权拒，语义正确；原断言过严）。
3. **MCP 挂起修复（关键）**：原 `test_mcp_get_method_not_supported` 直接 `client.get(...)` → **无限挂起**，
   导致整个 MCP 文件跑不完（上一轮中断的可能原因之一）。改为 daemon 线程 + `join(timeout=5)`，
   断言仍按「5s 内必须返回」的安全期望写 → 保留红（`test_mcp_get_with_pat_never_returns`）。
4. **MCP 抖动修复**：3 处等 `MCPCallLog` 落库的窗口 `30×0.05s(1.5s)` → `100×0.05s(5s)`
   （日志写入走 `asyncio.create_task(to_thread(...))`，高负载下会晚到，属「慢」不是「没写」）。
5. **标记补齐**：所有确证红用例补 `# ADVERSE FINDING:` 行内注释（原多数只有 docstring 提法）；
   `test_binding_rejects_other_users_existing_id` 实际是**绿**用例，docstring 从 “ADVERSE FINDING”
   改为「对抗面确认（现状正确）」，避免报告误统计。
6. **卫生修复**：`test_absolute_ledger_id_escapes_root` 把磁盘清理提到断言之前 —— 该用例红灯时
   不再在 `C:\tmp-abs-adv-escaped` 留垃圾（此前历史遗留目录已删除）。
7. **补漏（2 个新用例）**：
   - `test_ai_logs_filter_injection_and_pagination_bounds`（`test_ai_relay_adversarial.py`）
   - `test_upload_content_length_lie_is_tolerated_and_sizes_true` + 辅助 `_upload_raw_cl`
     （`test_attachment_adversarial.py`）

---

## 4. 攻击清单覆盖对照

| 清单项 | 覆盖用例 | 状态 |
|---|---|---|
| relay 未配置 provider → 4xx 非 500 | `test_relay_chat_without_any_config_is_400` / `..._corrupt_json_config...` / `..._missing_base_url...` | ✅ 绿 |
| SSRF：`169.254.169.254` / `file://` / `gopher://` | `test_relay_metadata_endpoint_reachable` / `test_relay_non_http_scheme_base_url_no_500` / `test_relay_base_url_loopback...` / `test_providers_test_reaches_loopback...` | ✅ 覆盖（3 红 1 绿） |
| 请求体畸形：非 JSON / 空 messages / role 非法 / 超深嵌套 | `test_relay_chat_non_json_body_is_4xx` / `..._malformed_bodies_are_422` / `..._deeply_nested_json_no_500` / `..._message_count_cap` / `..._total_chars_cap_413` | ✅ 绿 |
| vision 伪造 MIME / 空文件 / 超尺寸 / 超大 batch | `..._spoofed_html...` / `..._zip_renamed...` / `..._zero_byte...` / `..._oversize_rejected_413` / `..._batch_has_no_image_count_cap`、`..._amplifies_rate_limit_tokens`、`..._partial_mime_failure...` | ✅ 覆盖（5 红 4 绿） |
| providers：GET 不得含 apiKey 明文 | `test_list_and_detail_never_leak_plaintext_key` | ✅ 绿 |
| providers：掩码串被当新 key 覆盖真 key | `test_patch_with_masked_key_preserves_real_key`（`****`/空串 保留）+ 3 个变形覆盖红用例（F-09） | ✅ 覆盖；**注**：该资源无单资源 PUT，掩码只经 `PATCH /providers/{id}` 与 `PATCH /profile/me`，`PUT` 仅用于 `/providers/binding`（不含 key） |
| providers：跨用户越权 | `test_providers_are_isolated_per_user` / `test_binding_cannot_reference_other_users_provider` / `test_binding_rejects_other_users_existing_id` | ✅ 绿 |
| providers：数量上限 | `test_provider_count_has_no_cap` | ✅ 红（F-10） |
| ai_analysis_logs：失败也落 | `test_relay_failure_still_writes_error_log` | ✅ 绿 |
| ai_analysis_logs：图片落盘唯一性 | `test_relay_vision_logs_image_files_unique_per_call` | ✅ 绿 |
| ai_analysis_logs：日志不含明文 key | `test_relay_logs_never_contain_api_key` | ✅ 绿 |
| ai_analysis_logs：entry_type 非法值 | 写入侧（`entry_type="admin"` / SQL 串 → 422 不落库）+ 读侧过滤串 → 422，见 `test_ai_logs_filter_injection_and_pagination_bounds`、`test_relay_chat_malformed_bodies_are_422` | ✅ 覆盖（本轮补读侧） |
| 附件：文件名 `../../` / `%00` / 超长 / Unicode | `test_filename_traversal_is_sanitized` / `..._nul_byte...` / `..._over_255_chars...` / `..._unicode_filename...` | ✅ 绿 |
| 附件：同名并发 | `test_dedup_race_path_reclaims_orphan_storage`（预检 miss → IntegrityError 兜底） | ✅ 绿 |
| 附件：超大 / 0 字节 / HTML 改名 .png | `test_upload_over_limit_rejected_413` / `..._empty_upload_rejected_400` / `..._html_disguised...` | ✅ 覆盖（1 红） |
| 附件：Content-Length 撒谎 | `test_upload_content_length_lie_is_tolerated_and_sizes_true` | ✅ 覆盖（本轮补，绿；见 §5） |
| 附件：GC 不误删被引用 | `test_gc_preserves_referenced_and_removes_orphan` / `test_gc_referenced_by_other_users_projection_is_preserved` | ✅ 绿 |
| 附件：跨用户 IDOR | `test_user_b_cannot_download_or_delete_a_attachment` / `test_removed_member_loses_attachment_access` / `test_download_unknown_attachment_id_404` / `test_batch_exists_*` | ✅ 绿 |
| 备份：无权限触发 / 并发双触发 | `test_backup_admin_surface_rejects_non_admin`(7 参数化) / `test_run_now_non_admin_403_and_others_schedule_404` / `test_restore_rejects_run_owned_by_other_admin` / `test_run_now_twice_creates_two_background_runs` | ✅ 覆盖（1 红 F-13） |
| 备份：rclone 配置字段命令注入（只验参数化） | `test_rclone_runner_passes_args_as_list_not_shell` / `test_rclone_remote_name_pattern_rejects_shell_metacharacters` / `test_rclone_config_field_with_newline_is_injection_vector` | ✅ 覆盖（1 红 F-14，**未真执行破坏命令**） |
| 备份：畸形 / zip bomb 归档拒绝 | `test_extract_zip_rejects_malformed_archive` / `test_extract_zip_zip_bomb_has_no_size_guard` / `test_restore_tar_extraction_rejects_parent_traversal` | ✅ 覆盖（1 红 F-16） |
| 备份：retention 0/负/极大 | `test_retention_zero_and_negative_days_keeps_all` / `..._extreme_days...` / `..._boundary...` / `..._parses_zip_and_legacy_names` / `..._idempotent_repeat...` | ✅ 绿 |
| 备份：清理幂等 | `test_restore_cleanup_idempotent` / `test_cleanup_old_restores_handles_missing_root` | ✅ 绿 |
| 备份：pg_dump 在 sqlite 下不 500 | `test_pg_dump_rejects_sqlite_url_with_clear_error` / `..._missing_binary...` / `test_database_backend_normalizes_urls` | ✅ 绿 |
| 证据：非法 JSON / 超大体 | `test_evidence_rejects_malformed_json_and_oversize` / `..._source_control_chars_rejected` | ✅ 绿 |
| 证据：重复 external id | `test_evidence_duplicate_external_id_creates_two_rows`（靠 event_key 唯一，设计选择） | ✅ 绿 |
| 证据：TTL 清理幂等 | `test_evidence_cleanup_with_before_is_idempotent` / `test_evidence_retention_purge_is_idempotent` / `test_evidence_expired_insert_410_and_read_404` | ✅ 绿 |
| 证据：跨用户 IDOR | `test_evidence_idor_read_update_delete` / `test_evidence_cross_user_ledger_reference_404` | ✅ 绿 |
| 证据：limit/offset 负/极大 | `test_evidence_limit_offset_bounds` | ✅ 绿 |
| MCP：无凭据 / 过期 PAT 拒绝 | `test_mcp_without_credentials_is_401` / `..._expired_pat...` / `..._revoked_pat...` / `..._garbage_pat...` / `..._jwt_instead_of_pat...` / `..._disabled_user_pat_is_rejected` | ✅ 绿 |
| MCP：工具名注入 | `test_unknown_tool_name_is_graceful_error` / `..._with_control_characters...` / `test_args_summary_skips_free_text_fields` / `test_tool_name_length_in_call_log_is_bounded` | ✅ 绿 |
| MCP：畸形 JSON-RPC 帧 | `test_mcp_non_json_body_is_parse_error_400` / `..._empty_body...` / `..._oversize_body_rejected_413` / `..._batch_request_rejected_or_handled` | ✅ 绿 |
| MCP：认证前调用 | `test_mcp_requires_pat_even_for_initialize` / `test_mcp_without_credentials_is_401` | ✅ 绿 |

---

## 5. 未能验证（写进结论，避免被当成「已测过」）

1. **uvicorn 传输层对谎报 `Content-Length` 的组帧行为**：应用层已验证（按实际字节、不 500、不挂起），
   但真实传输层下「少报 → 截断上传 / 虚报 → 等待更多字节（slowloris 面）」需要真 socket 场景才能定性。
2. **云元数据回读**：`169.254.169.254` 只证明「无 host 拦截、请求真实发出」（本机网络不可达 → 502），
   未在云主机上验证元数据内容经 `error_message`/LLM 输出回读。
3. **PostgreSQL 下 `batch-exists` 的 65535 参数上限**：sqlite 下 6 万条 → 500 已复现；
   pg 分支同源（`bind message supplies N parameters`）但本环境未起 pg 实例。
4. **rclone / go-ini 对注入 section 的真实解析**：按硬性规则不执行破坏性命令，
   只断言「伪造段头已进 conf」；rclone 是否据此建 backend 未实测。
5. **MCP GET 在反代（nginx → SSE 长连接）后的行为**：只在 TestClient 与直连 uvicorn 两路验证悬挂。
6. **vision-batch 打满限流窗口**：用 16 图 / 8 图证明「张数 → 上游调用线性放大、令牌只记 1」，
   未真的打满 60 令牌去观察 429（避免用例耗时过长）。
7. **`/providers/test` 无界出站的并发打满**：只验证「50 次无 429」，未做线程/连接池耗尽实验。
8. **附件穿越在 Linux 部署下的 `../` 表现**：`/`-前缀与 `..\..\` 的行为依赖平台 pathlib 语义，
   本报告结论基于 Windows 实测（Linux 上 `../` 形态一致，反斜杠形态不同）。

---

## 附录：一键复现

```bash
cd server

# 本域 5 个文件(预期: 31 failed, 117 passed)
python -m pytest \
  tests/adversarial/test_ai_relay_adversarial.py \
  tests/adversarial/test_ai_providers_adversarial.py \
  tests/adversarial/test_attachment_adversarial.py \
  tests/adversarial/test_backup_evidence_adversarial.py \
  tests/adversarial/test_mcp_adversarial.py --tb=line

# 基线(预期: 623 passed)
python -m pytest tests/ --ignore=tests/adversarial
```

单条缺陷定位见各节 `复现` 命令（`-k` 选择器）。
