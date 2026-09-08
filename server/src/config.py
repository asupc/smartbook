import os
from functools import lru_cache

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # `.env.local` 后加载,字段覆盖 `.env` 同名键。本地调试场景(临时切代理 /
    # 关 SSL 校验 / 用别的 EMBEDDING_API_KEY)可以只改 .env.local 不污染 .env,
    # 且 .env.local 已经在 .gitignore 里,不会误提交。
    model_config = SettingsConfigDict(
        env_file=(".env", ".env.local"),
        extra="ignore",
    )

    # 显示名不再通过 APP_NAME / .env 配置,由 src/version.py 内置(新品牌「SmartBook 智记」)。
    app_env: str = "development"
    api_prefix: str = "/api/v1"
    web_static_dir: str = "/app/static"

    database_url: str = Field(default="sqlite:///./smartbook.db")

    # ===== 数据根目录 =====
    # 服务端产生的**所有**持久化数据(附件 / AI 记账截图 / 备份 / rclone 配置 /
    # .jwt_secret / restore 工作区 …)都落在这个目录下的子目录,见下方
    # _derive_storage_paths。本地开发默认 `./data`(WORKDIR 平级);
    # Docker 镜像里 ENV DATA_DIR=/data,挂一个 volume 即可全量持久化。
    # 任何单个子目录仍可用各自的 env(BACKUP_STORAGE_DIR 等)显式覆盖。
    data_dir: str = Field(default="./data", alias="DATA_DIR")

    jwt_secret: str = Field(default="change-me-in-production-at-least-32-bytes")
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 60
    refresh_token_expire_days: int = 30

    cors_origins: str = "http://localhost:8080,http://localhost:5173,http://localhost:3000"
    rate_limit_window_seconds: int = 60
    rate_limit_max_requests: int = 30
    # 以下存储路径默认空串,统一由 _derive_storage_paths 从 data_dir 派生;
    # 显式设置对应 env(或 init 参数)仍然生效 —— 包括故意设为空串禁用
    # 某个子功能(如 ATTACHMENT_STORAGE_DIR= 关附件存储)。
    backup_storage_dir: str = Field(default="", alias="BACKUP_STORAGE_DIR")
    backup_max_upload_bytes: int = 64 * 1024 * 1024
    attachment_storage_dir: str = Field(default="", alias="ATTACHMENT_STORAGE_DIR")
    attachment_max_upload_bytes: int = 64 * 1024 * 1024
    # AI 调用记录的输入图片(App 上报截图记账原图,Web 详情查看)。文件名
    # {log_id}.{ext},随日志行手动删除时一并删除(不落 DB,避免 blob 撑爆表;
    # AI 日志无自动保留期)。
    ai_log_image_dir: str = Field(default="", alias="AI_LOG_IMAGE_DIR")

    # ===== M6-5 AI 日志可靠 outbox =====
    # 开启后 AI 日志写入走「先持久化 enqueue → 返回 → worker 异步归档」，响应
    # 尾部不再等 DB commit / 图片写盘。默认关闭，先存量部署一版再灰度开启。
    ai_log_outbox_enabled: bool = Field(
        default=False, alias="AI_LOG_OUTBOX_ENABLED"
    )
    # 图片 spool 临时目录(未显式配置时从 data_dir 派生 `<DATA_DIR>/ai-log-spool`)。
    ai_log_spool_dir: str = Field(default="", alias="AI_LOG_SPOOL_DIR")
    # worker 参数(上限保护)。
    ai_log_outbox_batch_size: int = Field(default=20, alias="AI_LOG_OUTBOX_BATCH_SIZE")
    ai_log_outbox_max_attempts: int = Field(default=10, alias="AI_LOG_OUTBOX_MAX_ATTEMPTS")
    ai_log_outbox_lease_seconds: int = Field(default=60, alias="AI_LOG_OUTBOX_LEASE_SECONDS")

    # ===== 中转识别的账单唯一标识去重(/ai/relay/*) =====
    # App 识别请求到达后、调用 LLM 前,先在新请求文本里匹配该用户已识别过的
    # 账单唯一标识(external_id/订单号/流水号);命中即判重复:记日志
    # (dedup_hit)并返回 duplicate,**不调 LLM**,App 端不记账不通知。
    # TTL 只为控制表体积(订单号本身全局唯一),按天。
    ai_bill_identifier_dedup_enabled: bool = Field(
        default=True, alias="AI_BILL_IDENTIFIER_DEDUP_ENABLED"
    )
    ai_bill_identifier_ttl_days: int = Field(
        default=90, alias="AI_BILL_IDENTIFIER_TTL_DAYS"
    )

    # ===== rclone 备份模块 =====
    # rclone.conf 路径(权限 0600,只 server 进程读写)。默认从 data_dir 派生
    # (`<DATA_DIR>/rclone.conf`),跟其他数据一样随挂载卷持久化 —— 历史教训:
    # 容器 WORKDIR /app 下 ./data 是 docs-index COPY 来的临时层,rclone.conf
    # 落临时层的话容器重建即丢,scheduled backup 找不到 conf 直接 fail
    # (2026-05-14 线上事故)。
    rclone_config_path: str = Field(default="", alias="RCLONE_CONFIG_PATH")
    # rclone 二进制路径,Docker 镜像里 apt 装的会在 /usr/bin/rclone。
    rclone_binary: str = "rclone"
    # 备份打包 + 还原解压的临时区。需要 ≥ 2x data_dir 大小。
    backup_staging_dir: str = Field(default="", alias="BACKUP_STAGING_DIR")
    # `local` 类型 rclone 远端的落盘根目录。rclone local backend 没有可配置
    # root,`<name>:<path>` 的相对路径按子进程 cwd(/app)解析 —— 派生时强制
    # abspath(容器里 DATA_DIR=/data → /data/backup),避免备份写进容器 /app
    # 可写层、重建即丢。
    local_backup_dir: str = Field(default="", alias="LOCAL_BACKUP_DIR")
    # 还原(restore)隔离目录 —— 服务端只往这写,绝不动 live data。
    restore_dir: str = Field(default="", alias="RESTORE_DIR")
    # 调度器开关。测试和某些命令行场景关掉避免后台 thread 干扰。
    backup_scheduler_enabled: bool = Field(default=True, alias="BACKUP_SCHEDULER_ENABLED")
    # 调度器时区(影响 cron 解释)。空 = 走 tzlocal(读 TZ env 或 /etc/localtime)。
    # 显式设置 IANA 时区名(如 'Asia/Shanghai')可绕开 tzlocal 失效坑 — 容器
    # 没装 tzdata 时 tzlocal 会静默 fallback UTC,"0 4 * * *" 就在 UTC 4 点
    # 跑(不是用户期望的本地 4 点)。
    scheduler_timezone: str = Field(default="", alias="SCHEDULER_TIMEZONE")
    device_online_window_minutes: int = 10
    allow_app_rw_scopes: bool = True

    # Open registration is a footgun on self-hosted deployments: anyone with
    # the public URL could create a user. Default OFF; operators set this to
    # true during bootstrap, create the first admin, then flip back to false.
    # Admins can still create users via POST /api/v1/admin/users regardless.
    registration_enabled: bool = Field(default=False, alias="REGISTRATION_ENABLED")

    # 共享账本邀请短链域名前缀(Phase 2 才点击跳转,MVP 仅用于复制文案展示)。
    invite_share_origin: str = Field(
        default="https://count.beejz.com", alias="INVITE_SHARE_ORIGIN"
    )

    # Legacy strict `base_change_id` check on /write/* endpoints. When mobile
    # fullPush is streaming changes, the server-side materializer bumps the
    # latest ledger_snapshot change_id faster than any web retry can catch up,
    # producing endless 409s. With this flag OFF (default) we drop the strict
    # equality check and fall back to per-entity LWW for actual conflict
    # resolution. Set to ``true`` to re-enable the old behavior if something
    # regresses in the field.
    strict_base_change_id: bool = Field(default=False, alias="STRICT_BASE_CHANGE_ID")

    # ===== AI 文档 Q&A(/api/v1/ai/ask)=====
    # Server-side embedding key —— 用来把 user 的查询问题转向量,跟 docs sqlite
    # 索引(用 BGE-M3 预算好的 1024 维向量)做 cosine 检索。
    # 必须跟 BeeCount-Website build_docs_index.py 用同一个 embedding 模型
    # (默认 BGE-M3),否则向量空间不对齐 → 检索结果错乱。
    # 部署者自己注册 https://siliconflow.cn 拿一把(免费 quota cover 几百万次问答),
    # 或换 OpenAI / 自托管 BGE。空 → /ai/ask 返 503 AI_EMBEDDING_UNAVAILABLE,
    # 前端 fallback 到「跳官网搜文档」。
    embedding_base_url: str = Field(
        default="https://api.siliconflow.cn/v1", alias="EMBEDDING_BASE_URL",
    )
    embedding_api_key: str = Field(default="", alias="EMBEDDING_API_KEY")
    embedding_model: str = Field(default="BAAI/bge-m3", alias="EMBEDDING_MODEL")
    embedding_timeout: float = Field(default=10.0, alias="EMBEDDING_TIMEOUT")
    # AI outbound HTTP SSL 校验。本地走自签根证书代理(MITM)调试时可临时关掉。
    # 默认 true — 生产 / docker 部署千万别关,关了会被中间人篡改流量也不知。
    ai_http_verify_ssl: bool = Field(default=True, alias="AI_HTTP_VERIFY_SSL")

    # ===== 汇率代理(多币种 MVP)=====
    # 设计:SmartBook 仓 .docs/multi-currency/03-tech-design-cloud.md §五。
    # 只允许 CC0/央行类上游(fawazahmed0 / Frankfurter);
    # 绝不可配置 open.er-api.com —— 其 Terms 明文禁止再分发与程序化转发。
    exchange_rate_proxy_enabled: bool = Field(default=True, alias="EXCHANGE_RATE_PROXY_ENABLED")
    exchange_rate_cache_ttl_hours: int = Field(default=12, alias="EXCHANGE_RATE_CACHE_TTL_HOURS")
    # 整体替换内置上游链,指向 Frankfurter 兼容服务的根地址(如自托管
    # `docker run -d -p 8080:8080 lineofflight/frankfurter` → http://host:8080)。
    exchange_rate_upstream: str = Field(default="", alias="EXCHANGE_RATE_UPSTREAM")

    @model_validator(mode="after")
    def _derive_storage_paths(self) -> "Settings":
        """未显式配置的存储路径统一派生自 data_dir(`<DATA_DIR>/<子目录>`)。

        判据用 model_fields_set:env / init 里显式给了值(哪怕空串)就以给值为
        准,完全没给才落默认子目录 —— 这样既保证「服务端产生的所有数据都在
        数据根目录下」,又保留按目录单独覆盖 / 禁用的能力。local_backup_dir
        额外做 abspath:rclone local backend 按子进程 cwd 解析相对路径,必须
        是绝对路径(见字段注释)。
        """
        provided = set(self.model_fields_set)
        derived = {
            "backup_storage_dir": "backups",
            "attachment_storage_dir": "attachments",
            "ai_log_image_dir": "ai_log_images",
            "ai_log_spool_dir": "ai-log-spool",
            "rclone_config_path": "rclone.conf",
            "backup_staging_dir": "backup-staging",
            "restore_dir": "restore",
        }
        for field, sub in derived.items():
            if field not in provided:
                setattr(self, field, os.path.join(self.data_dir, sub))
        if "local_backup_dir" not in provided:
            setattr(
                self,
                "local_backup_dir",
                os.path.join(os.path.abspath(self.data_dir), "backup"),
            )
        return self

    @property
    def cors_origin_list(self) -> list[str]:
        return [x.strip() for x in self.cors_origins.split(",") if x.strip()]

    @property
    def is_default_jwt_secret(self) -> bool:
        return self.jwt_secret in {
            "change-me",
            "change-me-in-production",
            "change-me-in-production-at-least-32-bytes",
        }

    @property
    def is_weak_jwt_secret(self) -> bool:
        return len(self.jwt_secret.encode("utf-8")) < 32

    @property
    def has_wildcard_cors(self) -> bool:
        return any(origin == "*" for origin in self.cors_origin_list)


@lru_cache
def get_settings() -> Settings:
    return Settings()
