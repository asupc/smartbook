"""rclone.conf 管理 —— 把 BackupRemote 表里的配置渲染成 rclone 能读的 ini
格式,放在 `<DATA_DIR>/rclone.conf` (0600)。

rclone 自己也有 `rclone config touch` API,但走 subprocess 写入对原子性 + 错
误处理更难,我们直接生成文件:
  - DB 里存非敏感字段(name / backend_type / config_summary 的部分)
  - 敏感字段(access keys 等)以**明文**存 DB 的 `_secrets`,写入 conf 时也明文
    (rclone v1.73.5 s3 backend 不会自动 reveal obscured secrets,obscured 字符
    串会被原样当作 secret,签名直接错)
  - 文件每次"全量重写"(不增量 patch),保证状态唯一权威 = DB

加密方式:tarball 加密走 age(详见 age_runner.py),不再用 rclone crypt。
rclone.conf 现在永远是单段 backend(s3 / r2 / webdav / ...),不挂 crypt 装饰。
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import subprocess
from configparser import ConfigParser
from io import StringIO
from pathlib import Path
from typing import Any

from sqlalchemy.orm import Session

from ...config import get_settings
from ...models import BackupRemote

logger = logging.getLogger(__name__)

# remote name(DB 里的用户可见名)必须单行、不含 ini 元字符。
# API 层 schemas 已用 `^[A-Za-z0-9_-]+$` 校验,这里再守一层防历史脏行。
_REMOTE_NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

# rclone.conf 的 **section 名** 白名单。section = `<namespace>_<remote name>`
# (`_scoped_section_name`,见下),因此比裸 remote name 长:
# `sb_` + ≤32 位 namespace + `_` + ≤64 位 name = ≤100 字符。
_SECTION_NAME_MAX_LEN = 100
_SECTION_SAFE_RE = re.compile(rf"^[A-Za-z0-9_-]{{1,{_SECTION_NAME_MAX_LEN}}}$")

# per-user namespace 前缀。section 名 = `sb_<ns>_<name>`,ns 由 user_id 派生。
_NAMESPACE_PREFIX = "sb_"
_NAMESPACE_LEN = 32

# ini 值里禁止出现控制字符(尤其 \r/\n)。configparser 会把含 \n 的值写成
# 「续行」,而 rclone(go-ini)对 TrimLeft 后以 `[` 开头的续行按**新 section**
# 解析 → 攻击者可用 `\n[injected]\ntype = local\nroot = /tmp` 在服务端
# rclone.conf 里伪造 backend(read/write/delete 任意绝对路径)。
_INI_UNSAFE_VALUE_RE = re.compile(r"[\x00-\x1f\x7f]")


def user_namespace(user_id: str) -> str:
    """user_id → 稳定的 section 命名空间(小写 hex,长度恰 32)。

    **为什么需要它**(2026-10-11 对抗缺陷 4,跨租户泄密):

    历史实现直接把 remote name 当 rclone.conf 的 section 名,而 DB 的唯一
    约束是 `(user_id, name)`(models.BackupRemote)—— 两个 admin 各建一个叫
    `shared` 的 remote 完全合法,于是共享 conf 里 `[shared]` 段互相覆盖:
    后写者赢,前者的下载端点还会把**后者的** secret 返回给前者(下载按
    「section 名 ∈ 自己的 remote 名集合」匹配),前者自己的配置静默丢失。

    修法是让 section 名**全局唯一**:`sb_<namespace>_<name>`,namespace 由
    user_id 确定性派生 —— 同一个用户每次算出同一个值(rewrite / 下载 / 各条
    rclone 命令路径三处必须一致),不同用户不会撞。

    派生规则(确定性、无分支歧义):

    - user_id 去掉连字符后是**恰好 32 位 hex**(UUID 形态,本项目默认)→
      直接用,即 128 bit 原样保留,零碰撞成本;
    - 其它任何形态(短 id / 非 hex / 空)→ `sha256(user_id)` 前 32 位 hex
      (128 bit 抗碰撞)。空 id 走同一条,不再有特殊分支。

    为什么不用「截断 + 拼接」:两段拼接会让「UUID 分支」与「digest 分支」
    有可能产出同一个字符串,把唯一性论证变复杂;分支互斥则不会。
    """
    compact = (user_id or "").replace("-", "").lower()
    if len(compact) == 32 and all(ch in "0123456789abcdef" for ch in compact):
        return compact
    return hashlib.sha256((user_id or "").encode("utf-8")).hexdigest()[:_NAMESPACE_LEN]


def scoped_section_name(user_id: str, remote_name: str) -> str:
    """`(user_id, remote_name)` → 全局唯一的 rclone.conf section 名。"""
    return f"{_NAMESPACE_PREFIX}{user_namespace(user_id)}_{remote_name}"


def section_name_for(remote) -> str:
    """BackupRemote ORM 行 → section 名(写 conf / 拼 rclone 路径**共用**)。

    三条路径必须用同一个函数,否则「写进去的段」和「命令引用的段」会错位:
    `rewrite_from_db`(写)、`read_text_for_user`(下载)、`remote_path` /
    `remote_root`(rclone 命令)。
    """
    return scoped_section_name(str(getattr(remote, "user_id", "") or ""), str(remote.name))


def sanitize_conf_value(value: str) -> str | None:
    """conf 值白名单:单行、无控制字符;不合格返回 None(调用方丢弃并告警)。"""
    if _INI_UNSAFE_VALUE_RE.search(value):
        return None
    return value


def find_unsafe_conf_value(config: dict[str, Any]) -> str | None:
    """返回第一个含控制字符(换行等)的字段名,全部安全则返回 None。

    API 层用它做 400 拒绝;写入层用它做纵深防御。
    """
    for key, raw in config.items():
        if isinstance(raw, str) and _INI_UNSAFE_VALUE_RE.search(raw):
            return str(key)
    return None


def obscure_password(plain: str, *, rclone_binary: str = "rclone") -> str:
    """跑 `rclone obscure <plain>` —— 现在用不到了(crypt 段已移除),保留作
    `reveal_password` 的对偶用于老数据迁移检测。"""
    if not plain:
        return ""
    result = subprocess.run(
        [rclone_binary, "obscure", plain],
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    )
    return result.stdout.strip()


def _mask_conf(content: str) -> str:
    """rclone.conf 内容脱敏后给日志 — 把 sensitive 字段值替换成 ***。"""
    lines = []
    for line in content.splitlines():
        stripped = line.strip()
        if "=" in stripped and not stripped.startswith("["):
            key, _, val = stripped.partition("=")
            key_clean = key.strip()
            val_clean = val.strip()
            if key_clean in SENSITIVE_FIELDS:
                lines.append(f"{key_clean} = ***({len(val_clean)} chars)")
                continue
        lines.append(line)
    return "\n".join(lines)


def reveal_password(obscured: str, *, rclone_binary: str = "rclone") -> str:
    """`rclone reveal` 把 obscured 还原成明文。obscure 不是真加密,这是
    可逆的混淆 — rclone CLI 自己也用同一个 key。

    用途:老数据迁移 — 历史版本对 s3 secret 也做了 obscure,现在改为明文存,
    rewrite_from_db 检测到 obscured 形式就 reveal 后回写 DB。

    输入不是合法 obscured 字符串(已经是明文 / 损坏)时:rclone reveal
    可能 returncode != 0,或 stdout 出来不是 UTF-8 字节。两种情况都返回
    空字符串(=「不是 obscured,保持原值」语义),不让上层 500。
    """
    if not obscured:
        return ""
    try:
        result = subprocess.run(
            [rclone_binary, "reveal", obscured],
            capture_output=True,
            check=False,
            timeout=10,
        )
        if result.returncode != 0:
            return ""
        try:
            return result.stdout.decode("utf-8").strip()
        except UnicodeDecodeError:
            return ""
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        return ""


# config 字段不是任意的 — 我们维护一个 backend_type → 允许字段的白名单,
# UI 表单和 server 校验都用这个。第一版只支持高频后端,需要更多再加。
ALLOWED_BACKEND_FIELDS: dict[str, set[str]] = {
    "s3": {
        "provider",
        "access_key_id",
        "secret_access_key",
        "region",
        "endpoint",
        "bucket",  # 实际不写入 conf,而是用作 path prefix(`base:bucket`)
    },
    "b2": {"account", "key", "bucket"},
    "drive": {"client_id", "client_secret", "scope", "token", "root_folder_id"},
    "onedrive": {"client_id", "client_secret", "token", "drive_id", "drive_type"},
    "dropbox": {"client_id", "client_secret", "token"},
    "webdav": {"url", "vendor", "user", "pass"},
    "sftp": {"host", "user", "pass", "port", "key_file"},
    "ftp": {"host", "user", "pass", "port"},
    "alias": {"remote"},
    "local": set(),  # 没字段,直接 type=local
}

# 这些字段被视作"密语类":存 DB 时作为 _secrets 字段,UI / config_summary
# 不展示。其它字段(region / endpoint / bucket 等)明文展示。
SENSITIVE_FIELDS = {
    "secret_access_key",
    "key",
    "client_secret",
    "token",
    "pass",
    "password",
}


def sanitize_config_summary(backend_type: str, config: dict[str, Any]) -> dict[str, Any]:
    """从 user 提交的 config dict 里挑出非敏感字段(给 UI 展示用)。"""
    allowed = ALLOWED_BACKEND_FIELDS.get(backend_type, set())
    out: dict[str, Any] = {}
    for k, v in config.items():
        if k not in allowed:
            continue
        if k in SENSITIVE_FIELDS:
            out[k] = "******"
        else:
            out[k] = v
    return out


# 这些字段不写入 rclone.conf,只作为 path prefix(每次 push/list/delete 时
# 拼到 `<remote>:<bucket>/<filename>`)。bucket 是 S3/B2 等对象存储的概念,
# rclone s3 backend 不在 conf 里存 bucket — 它是路径的一部分。
PATH_PREFIX_FIELDS = {"bucket"}


def _conf_field_keys(backend_type: str) -> set[str]:
    """这个 backend 真正写到 rclone.conf 的 key 集合(allowed - path-prefix)。"""
    return ALLOWED_BACKEND_FIELDS.get(backend_type, set()) - PATH_PREFIX_FIELDS


def remote_path(remote, filename: str) -> str:
    """给定 BackupRemote 和文件名,返回 rclone 命令行用的完整 path。

    形如 `<section>:<bucket>/<filename>`,bucket 没设置则
    `<section>:<filename>`。

    `<section>` 是 `section_name_for(remote)`(per-user 命名空间,见
    `user_namespace` 的注释)—— 与 `rewrite_from_db` 写进 conf 的段名**必须**
    是同一个来源,否则 rclone 会报「didn't find section in config file」。
    rclone.conf 里永远是单段 backend,encrypted 标志不影响 path 格式 —
    加密由 age 在 backup runner 里完成,rclone 看到的就是普通 .tar.gz.age 文件。
    """
    section = section_name_for(remote)
    cfg = remote.config_summary or {}
    if remote.backend_type == "local":
        root = get_settings().local_backup_dir.rstrip("/")
        return f"{section}:{root}/{filename}"
    bucket = cfg.get("bucket") if isinstance(cfg, dict) else None
    if isinstance(bucket, str) and bucket.strip():
        return f"{section}:{bucket.strip()}/{filename}"
    return f"{section}:{filename}"


def remote_root(remote) -> str:
    """`<section>:` 或 `<section>:<bucket>/` —— 用于 lsjson / 路径 root 操作。"""
    section = section_name_for(remote)
    cfg = remote.config_summary or {}
    if remote.backend_type == "local":
        root = get_settings().local_backup_dir.rstrip("/")
        return f"{section}:{root}/"
    bucket = cfg.get("bucket") if isinstance(cfg, dict) else None
    if isinstance(bucket, str) and bucket.strip():
        return f"{section}:{bucket.strip()}/"
    return f"{section}:"


# ============================================================================
# Age passphrase 在 _secrets 里的 key 名(不是 backend 字段,不写入 rclone.conf)
# ============================================================================

AGE_PASSPHRASE_KEY = "age_passphrase"


def get_age_passphrase(remote: BackupRemote) -> str | None:
    """从 BackupRemote.config_summary._secrets 拿 age passphrase。"""
    cfg = remote.config_summary or {}
    secrets = cfg.get("_secrets") if isinstance(cfg, dict) else None
    if not isinstance(secrets, dict):
        return None
    val = secrets.get(AGE_PASSPHRASE_KEY)
    if isinstance(val, str) and val:
        return val
    return None


class RcloneConfigManager:
    """共享 rclone.conf 管理(多 admin 合写)。

    用法:
        mgr = RcloneConfigManager(conf_path, rclone_binary)
        mgr.rewrite_from_db(db, user_id)        # 合并重写(保留他人 section)
        mgr.read_text()                         # 读当前 conf 全文
        mgr.read_text_for_user(db, user_id)     # 只含该 user 的 section

    历史缺陷:conf 是按 user_id 全量重写单文件 —— adminB 的一次常规操作会把
    adminA 的 remote 从共享 conf 里抹掉,adminA 的定时备份静默失效。现在
    rewrite 先把 conf 里**已有**的 section 原样保留,再用 DB 覆盖 caller
    自己的 remote,等价于「合并写」。
    """

    def __init__(self, conf_path: str | Path, rclone_binary: str = "rclone"):
        self.conf_path = Path(conf_path)
        self.rclone_binary = rclone_binary

    @property
    def _owners_path(self) -> Path:
        """section → user_id 的 sidecar。

        共享 conf 要能既「保留别人的 section」又「删掉自己已删 remote 的
        section」,必须知道每个 section 的归属。用同目录 sidecar 记录
        (0600),不放进 ini 本身(rclone 会把它当 backend 字段)。
        """
        return self.conf_path.with_name(self.conf_path.name + ".owners.json")

    def _read_owners(self) -> dict[str, str]:
        try:
            raw = json.loads(self._owners_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        if not isinstance(raw, dict):
            return {}
        return {str(k): str(v) for k, v in raw.items() if isinstance(k, str)}

    def _write_owners(self, owners: dict[str, str]) -> None:
        self.ensure_dir()
        tmp = self._owners_path.with_suffix(self._owners_path.suffix + ".tmp")
        tmp.write_text(json.dumps(owners, ensure_ascii=False, sort_keys=True), encoding="utf-8")
        os.chmod(tmp, 0o600)
        os.replace(tmp, self._owners_path)

    def ensure_dir(self) -> None:
        self.conf_path.parent.mkdir(parents=True, exist_ok=True)

    def read_text(self) -> str:
        if not self.conf_path.exists():
            return ""
        return self.conf_path.read_text(encoding="utf-8")

    def _parse_existing(self) -> ConfigParser:
        """读现有 conf(保留其它 admin 的 section)。读不动/损坏 → 空 parser。

        损坏时**不**把旧内容原样带过去(可能含历史注入串),让 caller 从 DB
        重建自己的 section,其余丢失属可接受降级(下一次各自 rewrite 会补回)。
        """
        parser = ConfigParser()
        if not self.conf_path.exists():
            return parser
        try:
            parser.read_string(self.conf_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError) as exc:
            logger.warning("rclone.conf unreadable (%s); rebuilding from DB", exc)
            return ConfigParser()
        except Exception as exc:  # configparser.Error 及其它
            logger.warning("rclone.conf unparsable (%s); rebuilding from DB", exc)
            return ConfigParser()
        # 清掉历史上可能已被注入进来的非法 section 名。
        # 合法 section 名 = per-user 命名空间形态(`sb_<ns>_<name>`),
        # `_REMOTE_NAME_RE` 是它的子集(纯名字仍匹配),两者都接受 ——
        # 老 conf(本改动前写入的、无命名空间)里的段名也过 `_REMOTE_NAME_RE`,
        # 不会在升级瞬间被误删(rename 由 rewrite 按 DB 重写完成)。
        for name in list(parser.sections()):
            if not _SECTION_SAFE_RE.match(name):
                logger.warning("dropping unsafe rclone.conf section name %r", name)
                parser.remove_section(name)
        return parser

    def read_text_for_user(self, db: Session, user_id: str) -> str:
        """当前 conf 里只属于该 user 的 section(下载端点用,避免跨 admin 泄密)。

        **归属判定基于 section 名 = `section_name_for(row)`(per-user 命名
        空间)**,而不是「DB 里的裸 remote name ∈ conf 的 section 名集合」:

        历史实现用后者,两个 admin 各有一个同名 remote 时,双方的 section
        名完全相同 → 后来的 rewrite 覆盖前者的段,前者下载到的却是**后者**
        的 secret(对抗缺陷 4,跨租户泄密)。命名空间化后 section 名全局
        唯一,集合匹配不再可能串号。

        额外防御:即使 conf 因历史原因残留了别的 owner 的同名段(老文件),
        也只输出与 `section_name_for(row)` **逐字相等**的段 —— 段的归属由
        我方的确定性派生决定,不由文件内容决定,因此下载路径**不可能**
        返回别人的 backend 配置。

        **输出时把 section 名还原成用户可见的 remote name**(`sb_<ns>_<name>`
        → `<name>`):下载的这份 conf 是**单用户产物**(只含 caller 自己的
        remote),而 UI 的 CLI 步骤(`BackupRestoreGuideDialog`)打印的命令是
        `rclone ls <source_remote_name>:` —— 都是 caller 自己的名字。若不还原,
        用户在浏览器里下载 conf 后照提示敲命令会得到
        "didn't find section in config file"。

        还原是安全的:同一个 user 的 remote name 有 `(user_id, name)` 唯一
        约束,单用户产物内不会撞名(跨用户的同名段根本不在这份产物里)。
        """
        rows = db.query(BackupRemote).filter(BackupRemote.user_id == user_id).all()
        # section 名 → 用户可见名(单用户产物内的还原表)
        display_by_section = {
            section_name_for(r): str(r.name) for r in rows
        }
        wanted = set(display_by_section)
        parser = self._parse_existing()
        out = ConfigParser()
        for name in parser.sections():
            if name in wanted:
                # 用用户可见名写出(见 docstring);值原样搬运。
                out[display_by_section[name]] = dict(parser[name])
        buf = StringIO()
        out.write(buf)
        return buf.getvalue()

    # ----------------------------------------------------------------- write
    def rewrite_from_db(self, db: Session, user_id: str, *, repair_secrets: bool = True) -> None:
        """合并重写 rclone.conf:保留现有 section,DB 覆盖 caller 自己的 remote。

        DB 的 `_secrets` 里**统一存明文**。rewrite 时:
          - backend secrets(s3 secret_access_key / b2 key / drive token 等)
            明文写入 conf
          - age_passphrase **不写入 conf**(它不是 rclone 字段,只用于
            backup runner 调 age 加密 tarball)
          - 值做白名单过滤(禁控制字符/换行),非法值丢弃并告警 —— 防止
            换行注入伪造 section 头(go-ini 会把续行里的 `[x]` 当新 section)

        repair_secrets=True 时(默认):兼容老数据 — 如果 `_secrets` 里
        是历史的 obscured 形式(老版本对 s3 secret 也 obscure 过),reveal
        后回写 DB 为明文。

        **section 名是 per-user 命名空间形态**(`section_name_for(r)`),不再
        等于裸 remote name —— 两个 admin 各有一个 `shared` 时,两者的段名
        不同,不会再互相覆盖 / 串号(对抗缺陷 4)。老 conf 里无命名空间的
        段名(本改动前写入的)会在首次 rewrite 时被逐出:它们不在
        `stale_own`(sidecar 里记的是旧名),但也不在我方新 section 集合里;
        由 `_parse_existing` 保留、`owners` 台账按「conf 里还活着」裁剪时
        一并清理,并由各自 owner 的下一次 rewrite 覆盖。
        """
        remotes = (
            db.query(BackupRemote)
            .filter(BackupRemote.user_id == user_id)
            .order_by(BackupRemote.id.asc())
            .all()
        )
        parser = self._parse_existing()
        # 我方在本命名空间下应有的 section 名(全局唯一)。
        ours = {section_name_for(r) for r in remotes}
        # 归属台账:只删「caller 自己」且已不在 DB 的 section(remote 被删),
        # 别人的 section 一律原样保留。
        owners = self._read_owners()
        # 历史 conf(本改动之前写入的)没有 sidecar —— 对无归属记录的 section
        # 保守保留,避免误删他人配置。首次 rewrite 后 caller 的 section 会有
        # 记录,此后删除才生效。
        #
        # 额外:老命名空间(裸 remote name)下属于本用户、但现在已被命名空间
        # 化的段(owner 记录的旧名),也要清掉 —— 否则它们会作为「无主段」
        # 永久留在共享 conf 里,既占空间又可能被本用户的下载路径之外的东西
        # 引用。判据:sidecar 记的 owner == 本 user 且该名已不在 `ours`。
        stale_own = {
            name
            for name, owner in owners.items()
            if owner == user_id and name not in ours
        }
        # 老 conf 没有 sidecar 时,用「裸名形态」兜底识别本用户的历史段。
        # **保守判据**:仅当该裸名 **没有任何其它用户** 在用(无歧义 → 它就是
        # 本用户的历史段)才清。若两个用户曾同名(本缺陷的触发条件),则保留
        # 老段不动 —— 删了可能毁掉对方的存量备份路径,而保留只是无害残留
        # (双方的下一次 rewrite 都会写出各自的命名空间段)。
        legacy_own: set[str] = set()
        if remotes:
            other_names = {
                str(name)
                for (name,) in db.query(BackupRemote.name)
                .filter(BackupRemote.user_id != user_id)
                .all()
            }
            legacy_own = {
                r.name
                for r in remotes
                if r.name in parser.sections()
                and r.name not in ours
                and r.name not in other_names
            }
        for name in stale_own | legacy_own:
            logger.info("dropping stale/legacy section %r from rclone.conf", name)
            parser.remove_section(name)
            owners.pop(name, None)
        for r in remotes:
            cfg = dict(r.config_summary or {})
            secrets = cfg.pop("_secrets", {}) if isinstance(cfg.get("_secrets"), dict) else {}

            # secrets 老数据迁移到明文
            cleaned_secrets: dict[str, str] = {}
            plain_secrets: dict[str, str] = {}
            for k, v in (secrets or {}).items():
                stored = str(v)
                if repair_secrets and stored:
                    revealed = reveal_password(
                        stored, rclone_binary=self.rclone_binary
                    )
                    if revealed and revealed != stored:
                        cleaned_secrets[k] = revealed
                        stored = revealed
                        logger.info(
                            "remote %s field %s migrated obscured->plain in DB",
                            r.name, k,
                        )
                    else:
                        clean = stored.strip()
                        if clean != stored:
                            cleaned_secrets[k] = clean
                            stored = clean
                plain_secrets[k] = stored

            # 单段 backend(s3 / r2 / webdav / ...)。crypt 段已移除。
            # section 名带 per-user 命名空间 → 同名 remote 跨用户不冲突。
            section = section_name_for(r)
            if not _REMOTE_NAME_RE.match(r.name):
                logger.warning("skip remote %r: name is not a safe conf section name", r.name)
                continue
            if section in parser.sections() and section not in ours:
                # 正常不可能(ours 含 caller 全部 section);说明命名空间撞了
                # (namespace 由 user_id 派生,实际不可达)—— 后写者覆盖,告警留痕。
                logger.warning(
                    "rclone.conf section %r collides across users; overwriting", section
                )
            parser[section] = {"type": r.backend_type}
            for k, v in cfg.items():
                if k.startswith("_") or k in SENSITIVE_FIELDS or k in PATH_PREFIX_FIELDS:
                    continue
                clean = str(v).strip() if isinstance(v, str) else v
                value = sanitize_conf_value(str(clean))
                if value is None:
                    logger.warning("remote %s field %s dropped: control characters", r.name, k)
                    continue
                parser[section][k] = value
            for k, v in plain_secrets.items():
                # age_passphrase 不写入 conf,它由 backup runner 直接读
                if k == AGE_PASSPHRASE_KEY:
                    continue
                # 老 DB 可能留着 password / password2 历史字段,跳过
                if k in {"password", "password2"}:
                    continue
                value = sanitize_conf_value(str(v))
                if value is None:
                    logger.warning("remote %s secret field %s dropped: control characters", r.name, k)
                    continue
                # 对 pass 字段调用 rclone obscure 加密（WebDAV/SFTP/FTP backend需要）
                if k == "pass" and r.backend_type in {"webdav", "sftp", "ftp"}:
                    try:
                        value = obscure_password(value, rclone_binary=self.rclone_binary)
                    except Exception:
                        pass  # 保持明文(旧行为)
                parser[section][k] = value

            # 回写迁移过的 secrets
            if cleaned_secrets:
                new_summary = dict(r.config_summary or {})
                old_secrets = dict(new_summary.get("_secrets") or {})
                old_secrets.update(cleaned_secrets)
                new_summary["_secrets"] = old_secrets
                r.config_summary = new_summary
                db.flush()

        out = StringIO()
        parser.write(out)

        # 原子 rewrite + 更新归属台账(先 conf 后台账;下次 rewrite 自愈)
        self.ensure_dir()
        for r in remotes:
            if _REMOTE_NAME_RE.match(r.name):
                # 台账记**实际写进 conf 的 section 名**(命名空间形态),
                # 否则 stale 判定(`owner == user_id and name not in ours`)
                # 永远对不上,remote 删除后段会残留。
                owners[section_name_for(r)] = user_id
        # 台账只保留 conf 里还在的 section,避免无界增长
        live = set(parser.sections())
        owners = {k: v for k, v in owners.items() if k in live}
        tmp = self.conf_path.with_suffix(self.conf_path.suffix + ".tmp")
        tmp.write_text(out.getvalue(), encoding="utf-8")
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.conf_path)
        self._write_owners(owners)
        logger.info(
            "rclone.conf rewritten: %d own remotes, %d sections total",
            len(remotes), len(parser.sections()),
        )

    # ----------------------------------------------------------------- test
    def test_path(self, path: str) -> tuple[bool, str | None, list[str] | None]:
        """跑 `rclone lsd <path>` 验证连通性。返回 (ok, error, listing)。"""
        cmd = [
            self.rclone_binary,
            "--config",
            str(self.conf_path),
            "lsd",
            path,
            "--max-depth",
            "1",
            "-vv",
        ]
        logger.info("rclone test: cmd=%s", " ".join(cmd))
        try:
            conf_content = self.conf_path.read_text(encoding="utf-8") if self.conf_path.exists() else ""
            logger.info(
                "rclone test: conf summary:\n%s",
                _mask_conf(conf_content),
            )
        except OSError as exc:
            logger.warning("rclone test: failed to read conf: %s", exc)

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=30,
            )
        except subprocess.TimeoutExpired:
            return False, "rclone timed out (30s)", None
        except FileNotFoundError:
            return False, f"rclone binary not found: {self.rclone_binary}", None

        if result.stderr:
            logger.info("rclone test stderr (rc=%d):\n%s", result.returncode, result.stderr)
        if result.stdout:
            logger.info("rclone test stdout:\n%s", result.stdout)

        if result.returncode != 0:
            err = (result.stderr or "rclone failed").strip()
            return False, err[-1500:], None
        listing = [
            line.strip().split(maxsplit=4)[-1] if line.strip() else ""
            for line in result.stdout.splitlines()
            if line.strip()
        ]
        return True, None, listing[:50]

    # 兼容旧调用(测试用),内部走 test_path。
    #
    # **入参是 section 名,不是 remote name**:命名空间化(对抗缺陷 4)之后
    # 两者不再相同,新代码请用 `test_path(remote_root(row).rstrip("/"))`
    # (见 routers/admin_backup.py:test_remote)。此处保留仅为不破坏历史调用。
    def test_remote(self, name: str) -> tuple[bool, str | None, list[str] | None]:
        return self.test_path(f"{name}:")
