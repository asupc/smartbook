import json
import math
import re
from datetime import datetime, timezone
from typing import Annotated, Any, Literal

from pydantic import (
    AfterValidator,
    BaseModel,
    BeforeValidator,
    Field,
    field_serializer,
    field_validator,
)

# 6 位 hex，开头必须有 #；字母大小写都接受，validator 会归一化成大写。
_HEX6_PATTERN = re.compile(r"^#[0-9A-Fa-f]{6}$")

MemberRole = Literal["owner", "editor", "viewer"]
SyncAction = Literal["upsert", "delete"]

# ══════════════════════════════════════════════════════════════════════
# 可复用的输入加固 helper（对抗批次 S1）
#
# 这些类型别名 / helper 集中在 schemas.py，所有写 schema 复用同一套口径；
# 其它批次（S2 同步 payload / S3 业务 API）应收敛到这里的
# `FiniteFloat` / `OptionalFiniteFloat` / `SafeName` / `SafeNote`，
# 不要再各写一份 `math.isfinite` 判断或控制字符正则。
#
# 为什么是「BeforeValidator 先脱敏」而不是「AfterValidator 报错」：
# 422 的响应体由 pydantic 的 `errors()` 组成，其中 `input` 字段会回显
# **原始输入**。当原始输入是 NaN / Infinity（Starlette JSONResponse 用
# `json.dumps(allow_nan=False)`）或 lone surrogate（`.encode("utf-8")`
# 抛 UnicodeEncodeError）时，**422 响应本身序列化失败** → 全局兜底 500。
# 所以在校验之前就把不可安全回显的输入换成哨兵对象：随后的类型检查失败，
# `input` 记录的是哨兵（`str()` 结果是安全 ASCII），422 因此可以正常返回。
# ══════════════════════════════════════════════════════════════════════


class _ScrubbedInput:
    """替代「不可安全回显的原始输入」的哨兵（非 str / 非 float）。

    必须是**非字符串对象**：这样 str/float 字段的类型检查会失败并记录哨兵，
    而不是接受它。同时 `str()` 与 `repr()` 都返回安全 ASCII，保证错误负载
    一定能被 JSON 序列化。
    """

    __slots__ = ()

    def __repr__(self) -> str:
        return "<input redacted>"

    __str__ = __repr__


SCRUBBED_INPUT = _ScrubbedInput()
"""pydantic 错误负载里替代不可安全回显输入的占位符。"""

# 账本 `external_id` 白名单：只允许 ASCII 字母 / 数字 / `_` / `-`。
# 该值会被拼进磁盘路径（attachments.py / admin.py 备份产物），也必须能
# 安全地出现在 URL path 段里；任何 `.` / `/` / `\` / 空白 / 控制字符都会
# 打开路径穿越或路径歧义面。
#
# 审核记录 建议-2 的处理（决定了「只用在创建点」而非全局收紧）：
#   - 存量 `ledgers.external_id` 列宽 String(128)（models.py:475），
#     历史客户端/存量数据可能带着非白名单形态的值（`L1` / `L` 这类 1~2
#     字符 id 在存量测试里就有，老 seed 时代还可能更长）。全局套用白名单
#     会让这些旧账本的附件**永久不可达**（写路径 404）；
#   - 因此本正则只用在**创建点**（POST /write/ledgers）；`/sync/push`
#     auto-create 用下面的宽松判据 `is_path_safe_ledger_external_id`；
#     读取 / 上传路径不收紧，由 attachments.py 的 `resolve()` 包含性检查
#     兜底（纵深防御）；
#   - 上限 128 与列宽一致（不是计划原文的 64），避免把 128 字符的合法新
#     账本挡在门外。
LEDGER_EXTERNAL_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{3,128}$")

# 自由文本字段（备注）允许的最大长度 = 128 KB。
#
# note 会被复制到 sync_changes.payload_json（append-only，只增不减）+
# read_tx_projection + CSV 导出，必须有上限（对抗 F-10：无上限即低成本
# 存储耗尽面）。
#
# 取值为什么是 128 KB 而不是计划的「如 8 KB」或 evidence body 的 64 KB：
# 修复原则 2 要求「修完不许新增失败」。`test_tx_write_adversarial.py` 的
# `test_very_long_note_accepted_without_limit` 是**另一个 lane 的 HARDENING
# 锁**，断言 100_000 字符 → 200；上限设在 100 KB 以下会让那条绿测翻红
# （需要该 lane 配合改测试）。选 131072 可同时满足：
#   - 1 MB / 10 MB 仍被拒（本 lane 的两条红测转绿）；
#   - 100 KB 的既有 HARDENING 锁保持绿；
#   - 相对真实备注长度（KB 级）仍有三个数量级的富余，且真正堵死了「无界」。
MAX_NOTE_LENGTH = 131072

# 名称类字段的长度上限（与列宽 / schema Field 一致，用于哨兵脱敏阈值）。
MAX_NAME_LENGTH = 255

# 交易金额的数量级上限（round-3 中-2 跨端对齐）。口径与 mobile 端
# `LocalTransactionRepository.maxWriteAmount`(= 1e12)**严格一致**:
# `|amount| < 1e12` 通过(999999999999 合法),`>= 1e12` 拒绝 —— mobile
# 的 pull 守卫(`_pullAmountViolation` 的 `exceeds_magnitude`)会把
# `>= 1e12` 的行**永远跳过**,web/导入若放行会造成「web 有、手机无」的
# 静默分叉(只留一条 PulledValueSkipped 错误行)。因此 web 写路径与 CSV
# 导入在**源头**收窄;sync push 路径**刻意不受此限**(存量 mobile 行
# >1e12 必须继续同步,mobile pull 守卫仍是兜底)。
MAX_TX_WRITE_AMOUNT = 1e12

# 密码长度上限 = passlib 自己的处理上限（默认 4096；可由环境变量
# `PASSLIB_MAX_PASSWORD_SIZE` 覆盖）。
#
# 为什么不写死 4096：passlib 抛 `PasswordSizeError` 的阈值就是它，写死会在
# 运维调大/调小该环境变量时与真实边界脱节（写死 4096 而 passlib 上限被调到
# 2048 → 3000 字符密码通过 schema 却在 passlib 炸成 500，等于没修）。
# 超限的输入在**schema 层**就 422，不进 handler；handler 侧
# `security.require_password_size` 用同一常量做二次兜底。
# 见 2026-10-11 缺陷 3（`/admin/users` 的 passlib 调用点曾把超长密码打成 500）。
try:
    from passlib.utils import MAX_PASSWORD_SIZE as MAX_PASSWORD_LENGTH
except ImportError:  # pragma: no cover — passlib 是硬依赖，仅防御性兜底
    MAX_PASSWORD_LENGTH = 4096

# 自由 dict 字段的**写侧**深度与序列化体积上限（appearance）。
# 深度 8 足够覆盖 mobile/web 现有配置形态；99 层以前能让响应序列化递归
# 爆栈 → profile 自锁（对抗 F-04）。
MAX_FREE_DICT_DEPTH = 8
MAX_FREE_DICT_BYTES = 65536

# `ai_config` 的**写侧**体积上限必须比 appearance 宽松得多，因为
# `ai_config.providers[]` 是重配置结构：`/ai/providers` CRUD
# （routers/ai/providers.py `_MAX_PROVIDERS = 32`，只数自建）允许每个服务商
# apiKey 4096 + baseUrl 512 + 三个 model 128 + name/id 各 64 字符。
#
# **单位口径（缺陷 3）**：上限数的是 **UTF-8 字节**，而上面那些 `max_length`
# 数的是**字符**。ASCII 下二者相同：单个满配 provider 序列化 ≈ 5.3 KB，
# 32 个自建（+ 5 内置，内置字段短）≈ **170 KB** → 256 KB 覆盖最坏合法 ASCII
# 配置还有 ~1.5x 余量。CJK 下字符 = 3 字节，同一份满配配置膨胀到
# ≈ **488 KiB**（32 × 12.2 KB）—— 超出上限本身不违规（存量行），但新写入
# 会被拒。为此 `ai_config_store.enforce_ai_config_bounds` 有**缩容豁免**
# （结果 ≤ 库内现存字节数即放行），保证超限账户仍能自助删 provider 回到
# 上限之内（2026-10-11 缺陷 2）；真增长仍受 256 KB 硬上界约束。
#
# 注意：读侧**不用**这个值判「畸形」（见 routers/profile.py）——把写侧上限
# 当读侧判据会在 2026-10-11 之前静默清空合法的大配置（对抗缺陷 1）。
MAX_AI_CONFIG_BYTES = 262144

# `ai_config` 的写侧深度上限。结构与 appearance 同量级（dict → list →
# dict → 标量），8 层足够；比读侧容错判据严格，防深层结构落库。
MAX_AI_CONFIG_DEPTH = 8

# **读侧**（GET /profile/me 容错）认为「仍可正常服务」的最大深度。
# 它不是写侧上限的复用：读侧只负责挡住**真的无法序列化**的行。实测
# pydantic 在 90 层仍可 `model_dump_json`，100 层抛
# `PydanticSerializationError: Circular reference detected` → 这里取 64，
# 留出余量，同时远高于任何合法配置形态。
MAX_SERVABLE_JSON_DEPTH = 64

# `sha256_list` 之类的批量入参条数上限。
# 取值 10_000 的约束：`tests/adversarial/test_attachment_adversarial.py`
# 的 HARDENING 用例锁定了「5000 条重复 sha → 200」的现状，因此上限必须
# 高于 5000；同时 6 万条曾把端点打成 500（SQLite 变量上限），必须低于 6 万。
# 另外 attachments.py 对该列表做「去重 + 分块 IN 查询」，即使 999 变量的
# 老 SQLite 构建也不会溢出。
MAX_BATCH_LOOKUP_ITEMS = 10_000

# 分页 offset / 整型 path 参数（log_id）的上界 = int64 最大值。
#
# 为什么不是更小的「合理界」（例如 1e9）：`test_ai_relay_adversarial.py`
# 的 HARDENING 用例锁定「`/ai/logs?offset=99999999999999`(1e14) → 200 空页」
# 的现状，收紧到 1e9 会让那条绿测翻红。而 500 的真实根因是 Python int
# 无界 → SQLite/Postgres INTEGER/int8 转换 OverflowError，只有超过 int64
# 才会触发（`OverflowError: Python int too large to convert to SQLite INTEGER`）。
# 因此上界取 int64 max：> int64 → 422，≤ int64 仍走正常空页（对抗 F-09）。
MAX_INT64 = 2**63 - 1

# 宽松的「路径安全」判据 —— 给**非创建点**(存量数据通路)用。
#
# 为什么需要第二套判据:附件路径穿越的第二个入口是 `POST /sync/push` 的
# 账本 auto-create,而该出口历史上接受任意长度的 external_id(老客户端
# 有 `L1` / `L` 这类 1~2 字符 id,存量测试也在用)。直接套用创建点的
# `{3,128}` 白名单会让这些老客户端**再也同步不上**(数据分裂)。
#
# 因此该出口只拦截「能拼出路径逃逸」的形态:
#   - 路径分隔符 `/` `\`;
#   - 控制字符(含 NUL);
#   - 纯 `.` / `..`(相对路径段);
#   - 首尾空白 / 结尾 `.`(Windows 会静默 strip,造成路径歧义);
#   - `:`(Windows 盘符 / NTFS 备用数据流)。
PATH_UNSAFE_LEDGER_ID_CHARS = re.compile(r"[\\/\x00-\x1f\x7f:]")


def is_path_safe_ledger_external_id(value: str | None) -> bool:
    """存量/auto-create 出口的宽松判据:只挡「能拼出路径逃逸」的形态。"""
    if not value or len(value) > 128:
        return False
    if value != value.strip():
        return False
    if value in {".", ".."} or value.endswith("."):
        return False
    if PATH_UNSAFE_LEDGER_ID_CHARS.search(value):
        return False
    return True


def _scrub_non_finite(value: Any) -> Any:
    """非有限 float（NaN / ±Infinity）→ 哨兵，让类型检查失败并 422。

    直接依赖 `Field(allow_inf_nan=False)` 也能拒绝，但错误负载会回显
    `nan` / `inf` 本身，`json.dumps(allow_nan=False)` 抛错 → 422 变 500。
    """
    if isinstance(value, float) and not math.isfinite(value):
        return SCRUBBED_INPUT
    return value


def finite_float(value: float) -> float:
    """金额 / 汇率等数值必须是有限数（拒 NaN / ±Infinity）。

    对抗 F-08：NaN 写 projection 撞 NOT NULL → 500；Infinity 静默入库后
    聚合与 CSV 导出全部污染（`inf` / `null`）。schema 层统一用
    `FiniteFloat` / `OptionalFiniteFloat` 别名。
    """
    if not math.isfinite(value):
        raise ValueError("value must be a finite number")
    return value


def bounded_tx_amount(value: float) -> float:
    """web 写路径交易金额的数量级上限（round-3 中-2）。

    `|value| < MAX_TX_WRITE_AMOUNT`(1e12,与 mobile `maxWriteAmount` 同
    口径)通过,否则 422。只用于 **web create/batch** 路径;PATCH / 余额
    调整 / sync push 刻意不套(见 `MAX_TX_WRITE_AMOUNT` 常量注释)。
    有限性由 `FiniteFloat` 的其它层保证;这里假定输入已是有限数。
    """
    if abs(value) >= MAX_TX_WRITE_AMOUNT:
        raise ValueError(
            f"amount magnitude must be < {MAX_TX_WRITE_AMOUNT:.0f}"
        )
    return value


def _scrub_single_line(value: Any, *, max_length: int = MAX_NAME_LENGTH) -> Any:
    """单行文本脱敏：lone surrogate / 控制字符 / 超长 → 哨兵。"""
    if not isinstance(value, str):
        return value
    if len(value) > max_length:
        return SCRUBBED_INPUT
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return SCRUBBED_INPUT
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        return SCRUBBED_INPUT
    return value


def _scrub_multiline(value: Any, *, max_length: int = MAX_NOTE_LENGTH) -> Any:
    """多行文本（备注）脱敏：只处理 **长度** 与 **lone surrogate**。

    刻意**不**拒控制字符：对抗 F-11 的控制字符口径只覆盖名称类字段
    （tag / category / account name），备注是自由文本，`note` 里的 `\\x00`
    有既有 HARDENING 用例锁定「原样存取」（`test_tx_write_adversarial.py`
    的 `test_nul_byte_in_note_survives_roundtrip`），本批不改变该行为。
    lone surrogate 仍必须拒 —— 它会让落库 encode('utf-8') 炸成 500。
    """
    if not isinstance(value, str):
        return value
    if len(value) > max_length:
        return SCRUBBED_INPUT
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return SCRUBBED_INPUT
    return value


def _scrub_name_input(value: Any) -> Any:
    return _scrub_single_line(value, max_length=MAX_NAME_LENGTH)


def _scrub_note_input(value: Any) -> Any:
    return _scrub_multiline(value, max_length=MAX_NOTE_LENGTH)


def _reject_control_chars(value: str) -> str:
    """拒绝 C0 控制字符与 DEL（纵深防御，正常被 `_scrub_*` 提前拦下）。

    名称类字段落库后会进日志 / CSV 导出 / 文件名拼接；NUL 之类控制字符在
    下游会被截断或产生不可见污染（对抗 F-11）。`\\t` / `\\n` / `\\r` 一并
    拒绝 —— 它们会破坏 CSV 列结构与日志行。
    """
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        raise ValueError("value contains control characters")
    return value


def _reject_lone_surrogate(value: str) -> str:
    """拒绝无法 UTF-8 编码的 lone surrogate（`\\ud800`）。

    JSON 解析器（Python json）允许 lone surrogate 进 str，SQLAlchemy 写库
    时 encode('utf-8') 才抛 UnicodeEncodeError → 500（对抗 F-12）。
    `SafeName` / `SafeNote` 的 BeforeValidator 已在校验前把这类输入换成
    哨兵；本函数是事后断言，供未走别名的调用点使用。
    """
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise ValueError("value is not valid UTF-8") from exc
    return value


def safe_text(value: str) -> str:
    """自由文本（备注等）：拒绝控制字符 + lone surrogate。

    允许 `\\n`/`\\t` 的字段（备注可以多行）请用 `safe_multiline_text`。
    """
    return _reject_lone_surrogate(_reject_control_chars(value))


def safe_multiline_text(value: str) -> str:
    """多行自由文本（备注）：允许 `\\n`/`\\t`，仍拒 NUL 等其余控制字符。"""
    if any(ord(ch) < 32 and ch not in "\n\t" for ch in value):
        raise ValueError("value contains control characters")
    return _reject_lone_surrogate(value)


def safe_name(value: str) -> str:
    """名称类字段（账本/分类/账户/标签名）：单行 + 无控制字符。"""
    return safe_text(value)


FiniteFloat = Annotated[
    float, BeforeValidator(_scrub_non_finite), Field(allow_inf_nan=False)
]
"""有限 float —— 拒 NaN / ±Infinity，且 422 负载可安全序列化。"""

OptionalFiniteFloat = FiniteFloat | None
"""可空的有限 float。

必须写成「有限 float 与 None 的 union」而不是
`Annotated[float | None, Field(allow_inf_nan=False)]` —— 后者在 pydantic 2
里会让 `allow_inf_nan` 的检查对 `None` 直接 `math.isfinite(None)` →
`TypeError`（对可空字段传 null 就 500）。
"""

SafeName = Annotated[
    str,
    BeforeValidator(_scrub_name_input),
    Field(min_length=1, max_length=MAX_NAME_LENGTH),
]
"""单行名称：无控制字符 / 无 lone surrogate / 长度 ≤ 255。"""

SafeNote = Annotated[
    str, BeforeValidator(_scrub_note_input), Field(max_length=MAX_NOTE_LENGTH)
]
"""多行备注：允许 `\\n`/`\\t`，长度 ≤ 64 KB。"""

OptionalSafeNote = SafeNote | None
"""可空的多行备注。"""

BoundedTxAmount = Annotated[FiniteFloat, AfterValidator(bounded_tx_amount)]
"""web 写路径交易金额：有限（沿用 `FiniteFloat` 的 NaN/∞ 拒绝）+ `|amount| < 1e12`
（round-3 中-2 跨端对齐）。

只用于 `WriteTransactionCreateRequest.amount` 与 batch 项 —— PATCH / 余额
调整 / sync push 见 `MAX_TX_WRITE_AMOUNT` 常量注释,刻意不套。"""


def _check_json_depth(value: Any, *, max_depth: int) -> None:
    """迭代式深度检查（不用递归，避免自身爆栈）。"""
    stack: list[tuple[Any, int]] = [(value, 1)]
    while stack:
        node, depth = stack.pop()
        if depth > max_depth:
            raise ValueError(f"json nesting too deep (max {max_depth})")
        if isinstance(node, dict):
            for child in node.values():
                stack.append((child, depth + 1))
        elif isinstance(node, list):
            for child in node:
                stack.append((child, depth + 1))


def json_depth_ok(value: Any, *, max_depth: int) -> bool:
    """**读侧**深度判据（纯判定，不做任何序列化 / 分配整串）。

    只统计 dict / list 容器节点的嵌套层数，标量不占层级 —— 与
    `_check_json_depth`（写侧，标量也计数、因此实际边界是 max_depth - 1 层
    容器）有意不同：读侧是**容错**判据，只要判断「这行还能不能安全序列化」，
    不做逐层精确对齐。配合 64 层阈值（pydantic 序列化实测 90 层仍可、
    100 层抛错），合法配置（容器 ≤ 3~4 层）离边界极远。

    实现上只遍历容器、不递归、超限立即短路；对每行 profile JSON 是
    O(容器数) 的遍历，**不会** `json.dumps` 整串（大配置下那是 O(字节) 的
    额外分配，且随配置大小线性增长 —— 对抗缺陷 1 的性能面）。
    """
    stack: list[tuple[Any, int]] = [(value, 1)]
    while stack:
        node, depth = stack.pop()
        if depth > max_depth:
            return False
        if isinstance(node, dict):
            children: Any = node.values()
        elif isinstance(node, list):
            children = node
        else:
            continue
        for child in children:
            if isinstance(child, (dict, list)):
                stack.append((child, depth + 1))
    return True


def _check_json_size(value: Any, *, max_bytes: int | None = None) -> None:
    """序列化体积上限，超限即 422（**UTF-8 字节**口径）。

    判据与 `ai_config_store` 的落库边界同口径（字节，不是字符）——这点对
    pydantic 的 `max_length` 是**有意不同**：`max_length` 数的是字符，
    CJK 下 1 字符 = 3 字节，两者混用会让「schema 允许」与「存储上限」
    差出 3 倍（2026-10-11 缺陷 3）。这里统一按字节判。

    `max_bytes` 缺省为 appearance 的 64 KB；ai_config 走更宽松的
    `MAX_AI_CONFIG_BYTES`（见该常量的注释）。
    """
    limit = MAX_FREE_DICT_BYTES if max_bytes is None else max_bytes
    dumped = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if len(dumped.encode("utf-8")) > limit:
        raise ValueError(f"json payload too large (max {limit} bytes)")


def bounded_free_dict(value: Any) -> Any:
    """自由 dict 字段（appearance）：深度 ≤ 8 + 体积 ≤ 64 KB。

    写入侧先卡住，畸形结构就不会落库，也不会在响应序列化时把 profile
    打成永久 500（对抗 F-04）。
    """
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError("value must be a JSON object")
    _check_json_depth(value, max_depth=MAX_FREE_DICT_DEPTH)
    _check_json_size(value)
    return value


def bounded_ai_config(value: Any) -> Any:
    """`ai_config` 写侧限制：深度 ≤ 8 + 体积 ≤ 256 KB。

    体积上限比 appearance 宽松，因为 `providers[]` 是重配置结构：
    `/ai/providers` CRUD 允许 32 个自建服务商 × ~5.3 KB（ASCII 满配）≈ 170 KB
    合法（见 `MAX_AI_CONFIG_BYTES` 注释里的字节/字符换算）。上限与
    `providers._save_config` 的校验同源，保证经任何入口写入的 ai_config 都有界。
    """
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError("value must be a JSON object")
    _check_json_depth(value, max_depth=MAX_AI_CONFIG_DEPTH)
    _check_json_size(value, max_bytes=MAX_AI_CONFIG_BYTES)
    return value


BoundedFreeDict = Annotated[dict, AfterValidator(bounded_free_dict)]
"""深度/体积受限的自由 dict（appearance 口径）。"""

BoundedFreeDictOptional = Annotated[dict | None, AfterValidator(bounded_free_dict)]
"""可空的深度/体积受限自由 dict。"""

BoundedAIConfigOptional = Annotated[dict | None, AfterValidator(bounded_ai_config)]
"""可空的深度受限 + 256 KB 体积受限 ai_config。"""


class AuthRegisterRequest(BaseModel):
    email: str
    password: str = Field(min_length=6)
    device_id: str | None = None
    device_name: str | None = None
    platform: str | None = None
    app_version: str | None = None
    os_version: str | None = None
    device_model: str | None = None
    client_type: Literal["app", "web"] = "app"

    @field_validator("email")
    @classmethod
    def validate_email(cls, value: str) -> str:
        normalized = value.strip().lower()
        if "@" not in normalized or "." not in normalized.split("@")[-1]:
            raise ValueError("Invalid email format")
        return normalized


class AuthLoginRequest(BaseModel):
    email: str
    password: str
    device_id: str | None = None
    device_name: str | None = None
    platform: str | None = None
    app_version: str | None = None
    os_version: str | None = None
    device_model: str | None = None
    client_type: Literal["app", "web"] = "app"

    @field_validator("email")
    @classmethod
    def validate_email(cls, value: str) -> str:
        normalized = value.strip().lower()
        if "@" not in normalized or "." not in normalized.split("@")[-1]:
            raise ValueError("Invalid email format")
        return normalized


class AuthRefreshRequest(BaseModel):
    refresh_token: str


class AuthLogoutRequest(BaseModel):
    refresh_token: str | None = None


class UserOut(BaseModel):
    id: str
    email: str
    is_admin: bool = False


class UserProfileOut(BaseModel):
    user_id: str
    email: str
    display_name: str | None = None
    avatar_url: str | None = None
    avatar_version: int = 0
    # 对齐 mobile `incomeExpenseColorSchemeProvider`。Nullable = 未设置过，web
    # 视为默认（红色收入）。
    income_is_red: bool | None = None
    # 主题色 hex（#RRGGBB），mobile 设置后推上来；web 把它当作"初始偏好"，
    # 用户在 web 本地改色会写 localStorage 优先生效。
    theme_primary_color: str | None = None
    # 外观类设置 JSON 对象（解析后的 dict）。mobile 推上来，web 只读展示。
    # 目前约定的 key：
    #   header_decoration_style (str) / compact_amount (bool) / show_transaction_time (bool)
    # 将来加新 key 不需要加 schema 字段。None = 没设置过。
    appearance: dict | None = None
    # AI 配置 JSON 对象。mobile 推上来,web 只读展示,另一台 mobile 设备也会拉。
    # key: providers (list) / binding (dict) / custom_prompt (str) /
    # strategy (str) / bill_extraction_enabled (bool) / use_vision (bool)
    ai_config: dict | None = None
    # 用户主币种,ISO 4217 大写代码(如 CNY / USD / JPY)。None = 未设置。
    primary_currency: str | None = None


class UserProfilePatchRequest(BaseModel):
    # 所有字段都可选：mobile 改配色时只送 `income_is_red`，web 改昵称时只送
    # `display_name`。handler 只更新非 None 字段。
    display_name: str | None = None
    income_is_red: bool | None = None
    theme_primary_color: str | None = None
    # 自由 dict：深度 ≤ 8 / 体积 ≤ 64 KB。超限 422 —— 否则深嵌套 JSON 会
    # 落库并在响应序列化时递归爆栈，让 GET /profile/me 永久 500（对抗 F-04）。
    appearance: BoundedFreeDictOptional = None
    # ai_config：深度 ≤ 8 / 体积 ≤ 256 KB（providers[] 是重配置结构，
    # 32 个自建服务商 ASCII 满配 ≈ 170 KB 合法；CJK 满配可达 ~488 KiB ——
    # 字节口径见 MAX_AI_CONFIG_BYTES）。
    ai_config: BoundedAIConfigOptional = None
    primary_currency: str | None = Field(default=None, pattern=r"^[A-Za-z]{3,8}$")

    @field_validator("display_name")
    @classmethod
    def validate_display_name(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip()
        if not normalized:
            raise ValueError("Display name cannot be empty")
        if len(normalized) > 32:
            raise ValueError("Display name too long")
        return safe_text(normalized)

    @field_validator("theme_primary_color")
    @classmethod
    def validate_theme_primary_color(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip().upper()
        # 只接受 #RRGGBB 格式；太宽松会被当任意文本写入
        if not _HEX6_PATTERN.match(normalized):
            raise ValueError("theme_primary_color must be #RRGGBB hex")
        return normalized


class UserProfileAvatarUploadOut(BaseModel):
    avatar_url: str
    avatar_version: int


class AuthTokenResponse(BaseModel):
    user: UserOut
    access_token: str
    refresh_token: str
    expires_in: int
    device_id: str
    scopes: list[str] = Field(default_factory=list)


class AuthLoginResponse(AuthTokenResponse):
    """密码登录响应(等价老 AuthTokenResponse)。"""


class DeviceOut(BaseModel):
    id: str
    name: str
    platform: str
    app_version: str | None = None
    os_version: str | None = None
    device_model: str | None = None
    last_ip: str | None = None
    last_seen_at: datetime
    created_at: datetime
    session_count: int = 1


class SyncChangeIn(BaseModel):
    # user-global change(category/account/tag)在新协议下不依附 ledger,这里
    # 允许 None。老 mobile 会发当前 ledger_id —— server 按 entity_type 强制
    # 路由(参考 .docs/user-global-refactor/plan.md §3.2),不依赖 client 一定
    # 填对。
    ledger_id: str | None = None
    entity_type: str
    entity_sync_id: str
    action: SyncAction
    payload: dict[str, Any]
    updated_at: datetime
    # 'user' = category/account/tag 等 user-global 资源(server 端 SyncChange.scope)
    # 'ledger' = budget/transaction/ledger 等 ledger-scoped
    # 老 mobile 不发该字段;server 兜底按 entity_type 推断,不依赖 client 一定填对。
    scope: str | None = None

    @field_validator("ledger_id")
    @classmethod
    def _validate_ledger_channel(cls, value: str | None) -> str | None:
        """账本 external_id 走的是「宽松路径安全」判据,不是创建点的白名单。

        `/sync/push` 的账本 auto-create 是附件路径穿越的**第二入口**:它会拿
        `change.ledger_id` 直接建 Ledger 行,此后该 external_id 就参与附件落盘
        路径拼接(对抗 F-01)。因此这里必须挡掉路径分隔符 / 控制字符 / 纯点段
        / 盘符冒号等「能拼出路径逃逸」的形态。

        不用创建点的 `^[A-Za-z0-9_-]{3,128}$`:存量老客户端发过 1~2 字符
        (`L`/`L1`)与含 `.` 的 id(见 `is_path_safe_ledger_external_id`
        注释),一刀切会让它们再也同步不上 → 数据分裂。
        """
        if value is None:
            return None
        if not is_path_safe_ledger_external_id(value):
            raise ValueError("ledger_id is not a safe path segment")
        return value


class SyncPushRequest(BaseModel):
    device_id: str
    changes: list[SyncChangeIn]


class SyncPushResponse(BaseModel):
    accepted: int
    rejected: int
    conflict_count: int = 0
    conflict_samples: list[dict[str, Any]] = Field(default_factory=list)
    # 0031(批次3):apply 抛异常的 change 被隔离跳过(不再整批 500 死循环),
    # 每条带 entity/action/sync_id/error。客户端应把这些 change 标记为
    # poisoned 并提示用户,不再重推同一批。
    failed_count: int = 0
    failed_samples: list[dict[str, Any]] = Field(default_factory=list)
    server_cursor: int
    server_timestamp: datetime


class SyncChangeOut(BaseModel):
    change_id: int
    # user-scope change(scope='user')的 ledger_id 是 sentinel '__user_global__';
    # ledger-scope 是真实账本 external_id。mobile 按 scope 字段决定 apply 路径,
    # ledger_id 仅做日志 / cursor 标识。
    ledger_id: str
    entity_type: str
    entity_sync_id: str
    action: SyncAction
    payload: dict[str, Any]
    updated_at: datetime
    updated_by_device_id: str | None
    # 'user' / 'ledger'。SyncChange.scope 直接 round-trip。
    scope: str = "ledger"


class SyncPullResponse(BaseModel):
    changes: list[SyncChangeOut]
    server_cursor: int
    has_more: bool


class SyncFullResponse(BaseModel):
    ledger_id: str
    snapshot: SyncChangeOut | None
    latest_cursor: int


class SyncLedgerOut(BaseModel):
    ledger_id: str
    path: str
    updated_at: datetime | None
    size: int
    metadata: dict[str, Any]
    role: MemberRole


BackupArtifactKind = Literal["db", "snapshot"]


class AdminBackupCreateRequest(BaseModel):
    ledger_id: str
    note: str | None = None


class AdminBackupCreateResponse(BaseModel):
    snapshot_id: str
    ledger_id: str
    created_at: datetime


class AdminBackupRestoreRequest(BaseModel):
    snapshot_id: str
    device_id: str | None = None


class AdminBackupRestoreResponse(BaseModel):
    restored: bool
    ledger_id: str
    change_id: int


class AdminBackupUploadSnapshotRequest(BaseModel):
    ledger_id: str
    payload: dict[str, Any]
    note: str | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)


class AdminBackupArtifactOut(BaseModel):
    id: str
    ledger_id: str
    kind: BackupArtifactKind
    file_name: str
    content_type: str | None
    checksum: str
    size: int
    created_at: datetime
    created_by: str
    note: str | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)


class AdminBackupArtifactUploadResponse(AdminBackupArtifactOut):
    snapshot_id: str | None = None


class UserAdminOut(BaseModel):
    id: str
    email: str
    is_admin: bool
    is_enabled: bool
    created_at: datetime
    display_name: str | None = None
    avatar_url: str | None = None
    avatar_version: int = 0


class UserAdminListOut(BaseModel):
    total: int
    items: list[UserAdminOut]


class UserAdminPatchRequest(BaseModel):
    # 允许改邮箱 / 启用状态。角色(is_admin)不在这里 —— 建用户时定好后
    # 就不能在 UI 改,想变更只能走 `make grant-admin EMAIL=` 之类的运维路径。
    # 密码改走独立端点 POST /admin/users/{id}/password,需要管理员自己的
    # 当前密码二次验证,避免 PATCH 这种"顺手改一下"造成密码误改。
    email: str | None = None
    is_enabled: bool | None = None

    @field_validator("email")
    @classmethod
    def _validate_email(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip().lower()
        if not normalized:
            return None
        if "@" not in normalized or "." not in normalized.split("@")[-1]:
            raise ValueError("Invalid email format")
        return normalized


class UserAdminPasswordChangeRequest(BaseModel):
    """修改目标用户密码。admin_password 是**当前操作 admin 自己的**密码,
    用于二次验证 —— 防止 session 被挟持或 UI 误操作把别人密码改掉。
    new_password 至少 6 位,跟 register / create-user 对齐。

    `max_length=MAX_PASSWORD_LENGTH`:超长密码会在 passlib 层抛
    `PasswordSizeError` → 500(对抗缺陷 3)。422 是更准确的语义(输入校验
    失败),比「先接受再在 handler 里拒」少一次请求体透传。handler 侧还有
    `require_password_size` 兜底(此处与 passlib 的常量保持同步)。
    """

    admin_password: str = Field(min_length=1, max_length=MAX_PASSWORD_LENGTH)
    new_password: str = Field(min_length=6, max_length=MAX_PASSWORD_LENGTH)


class UserAdminCreateRequest(BaseModel):
    email: str
    password: str = Field(min_length=6, max_length=MAX_PASSWORD_LENGTH)
    is_admin: bool = False
    is_enabled: bool = True

    @field_validator("email")
    @classmethod
    def validate_email(cls, value: str) -> str:
        normalized = value.strip().lower()
        if "@" not in normalized or "." not in normalized.split("@")[-1]:
            raise ValueError("Invalid email format")
        return normalized


class AdminOverviewOut(BaseModel):
    users_total: int
    users_enabled_total: int
    ledgers_total: int
    transactions_total: int
    accounts_total: int
    categories_total: int
    tags_total: int


class AdminLogEntryOut(BaseModel):
    """Ring buffer 一条日志;字段对应 RingBufferLogHandler.emit 的 dict。"""

    seq: int
    ts: str
    level: str
    logger: str
    message: str
    ledger_id: str | None = None
    user_id: str | None = None
    device_id: str | None = None


class AdminLogListOut(BaseModel):
    items: list[AdminLogEntryOut]
    capacity: int
    latest_seq: int


# ────────── AI 分析日志(admin 全局查询)─────────────────────────


class _AIBaseOut(BaseModel):
    """AI 日志 admin 字段公共形状(ser: SQLite 读回 naive → 统一打 UTC 标记)。"""

    id: int
    entry_type: str
    status: str
    provider_id: str | None = None
    model: str | None = None
    ledger_id: str | None = None
    error_message: str | None = None
    duration_ms: int = 0
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    total_tokens: int | None = None
    client_ip: str | None = None
    dedup_hit: str | None = None
    called_at: datetime

    @field_serializer("called_at")
    def _ser_dt(self, v: datetime | None) -> str | None:
        if v is None:
            return None
        if v.tzinfo is None:
            v = v.replace(tzinfo=timezone.utc)
        return v.isoformat()


class AdminAIAnalysisLogItem(_AIBaseOut):
    """admin 列表项 — 带 user 身份;内容只返截断预览(全文走详情)。"""

    user_id: str
    user_email: str
    input_preview: str | None = None
    output_preview: str | None = None


class AdminAIAnalysisLogDetail(_AIBaseOut):
    """任意用户单条全文。"""

    user_id: str
    user_email: str
    input_text: str | None = None
    output_text: str | None = None


class AdminAIAnalysisLogListOut(BaseModel):
    total: int
    items: list[AdminAIAnalysisLogItem]


# ────────── 数据清理(替代旧 IntegrityScan)─────────────────────────


class DataCleanupRequest(BaseModel):
    """POST /admin/data-cleanup/clean 请求体 — records 直接来自 scan 接口。"""

    records: list["DataCleanupRecord"]


class DataCleanupResult(BaseModel):
    success_count: int
    failures: list["DataCleanupFailure"] = []


class DataCleanupFailure(BaseModel):
    record_key: str
    error: str


class DataCleanupRecord(BaseModel):
    """单条孤儿数据 — 直接复用 services.data_cleanup.OrphanRecord 形态,但作为
    schema 出现避免 router 依赖 services 类型。"""

    type: str  # OrphanType 枚举字符串值
    title: str
    subtitle: str
    user_id: str | None = None
    row_id: str | None = None
    sync_id: str | None = None
    file_path: str | None = None
    size_bytes: int | None = None
    extra: dict[str, Any] | None = None


class DataCleanupScanReport(BaseModel):
    db_orphans: list[DataCleanupRecord] = []
    file_orphans: list[DataCleanupRecord] = []
    sync_orphans: list[DataCleanupRecord] = []
    total_count: int = 0
    total_size_bytes: int = 0


DataCleanupRequest.model_rebuild()
DataCleanupResult.model_rebuild()


# ────────── 重复交易检测 / 清理 ─────────────────────────


class DuplicateRecord(BaseModel):
    """重复交易组里的一笔。is_keeper=True 表示建议保留的那笔(最小 change_id)。"""

    ledger_id: str
    ledger_name: str | None = None
    sync_id: str
    amount: float
    happened_at: datetime
    # 记录时间(服务端首次落库时刻);存量行可能为 NULL。
    created_at: datetime | None = None
    tx_type: str
    note: str | None = None
    account_name: str | None = None
    category_name: str | None = None
    tags_csv: str | None = None
    source_change_id: int = 0
    is_keeper: bool = False


class DuplicateGroup(BaseModel):
    """同一账本内 (金额 + 时间) 相同的交易聚成一组(不区分收支类型)。"""

    ledger_id: str
    ledger_name: str | None = None
    amount: float
    happened_at: datetime
    count: int
    keep_sync_id: str
    items: list[DuplicateRecord]


class DuplicateDeleteItem(BaseModel):
    ledger_id: str
    sync_id: str


class DuplicateCleanRequest(BaseModel):
    items: list[DuplicateDeleteItem]


class DuplicateCleanFailure(BaseModel):
    record_key: str
    error: str


class DuplicateCleanResult(BaseModel):
    success_count: int
    failures: list[DuplicateCleanFailure] = []


# ────────── M6-6 重复交易原始证据对比 ──────────
# 列表/扫描保持轻量;只有主动打开对比抽屉时才加载证据(正文/图片均为懒加载)。


class DuplicateEvidenceItemKey(BaseModel):
    """对比请求里的一笔交易,以 (ledger_id, sync_id) 唯一定位。

    不信任前端传的 keeper 标记,服务端重新从 projection 读取。
    """

    ledger_id: str
    sync_id: str


class DuplicateCompareRequest(BaseModel):
    items: list[DuplicateEvidenceItemKey] = []  # 最多 20 笔,通常是一组重复组


class DuplicateEvidenceAssetOut(BaseModel):
    """asset 元数据(不含 binary/绝对路径)。"""

    id: str
    kind: str
    mime_type: str
    size_bytes: int
    sha256: str
    width: int | None = None
    height: int | None = None


class DuplicateEvidenceOut(BaseModel):
    """原始证据摘要(与一笔交易关联的)。正文全文走 detail 接口。"""

    id: str
    source: str
    source_channel: str | None = None
    external_id: str | None = None
    title: str | None = None
    body_preview: str | None = None  # 截断预览,不进列表全文
    content_hash_short: str | None = None
    captured_at: datetime | None = None
    occurred_at: datetime | None = None
    expires_at: datetime | None = None
    # available / none / not_linked / expired / not_retained / asset_missing
    status: str = "available"
    assets: list[DuplicateEvidenceAssetOut] = []


class DuplicateCompareItemOut(BaseModel):
    """对比抽屉里的一栏交易:已落库交易 + 原始输入摘要。"""

    ledger_id: str
    sync_id: str
    is_keeper: bool = False
    amount: float | None = None
    happened_at: datetime | None = None
    created_at: datetime | None = None
    tx_type: str | None = None
    note: str | None = None
    account_name: str | None = None
    category_name: str | None = None
    tags_csv: str | None = None
    attachment_count: int = 0
    raw_evidence_status: str = "none"
    raw_evidence_count: int = 0
    evidences: list[DuplicateEvidenceOut] = []


class DuplicateCompareResponse(BaseModel):
    items: list[DuplicateCompareItemOut]


class DuplicateEvidenceDetailRequest(BaseModel):
    transaction_ledger_id: str
    transaction_sync_id: str
    evidence_id: str


class DuplicateEvidenceDetailResponse(BaseModel):
    evidence: DuplicateEvidenceOut
    asset_ids: list[str] = []
    body_full: str | None = None  # 单条正文全文(≤ 65,536 字符),detail 才返回


class DuplicateEvidenceLinkRequest(BaseModel):
    """为一条证据补确定性关联(客户端上传后补 link)。"""

    evidence_id: str
    transaction_ledger_id: str
    transaction_sync_id: str
    event_item_index: int | None = None



class ReadLedgerOut(BaseModel):
    ledger_id: str
    ledger_name: str
    currency: str
    month_start_day: int = 1
    transaction_count: int
    income_total: float
    expense_total: float
    balance: float
    exported_at: datetime | None
    updated_at: datetime
    role: MemberRole
    is_shared: bool = False
    member_count: int = 1


class ReadLedgerDetailOut(ReadLedgerOut):
    source_change_id: int


class ReadTransactionOut(BaseModel):
    id: str
    tx_index: int
    tx_type: str
    amount: float
    happened_at: datetime
    # 记录时间(服务端首次落库时刻)。存量行/旧版本可能为 NULL,前端显示 "-"。
    created_at: datetime | None = None
    note: str | None
    category_name: str | None
    category_kind: str | None
    account_name: str | None
    from_account_name: str | None
    to_account_name: str | None
    category_id: str | None = None
    account_id: str | None = None
    from_account_id: str | None = None
    to_account_id: str | None = None
    tags: str | None
    tags_list: list[str] = Field(default_factory=list)
    tag_ids: list[str] = Field(default_factory=list)
    attachments: list[dict[str, Any]] | None
    # 账单标记(.docs/transaction-flags)。exclude_from_stats=不计入收支统计;
    # exclude_from_budget=不计入预算用量。两者独立,旧数据 default False。
    exclude_from_stats: bool = False
    exclude_from_budget: bool = False
    # 交易级多币种(0018):currency_code=原币种(null 视作账本本位币);
    # native_amount=折账本本位币快照(null 时前端 fallback 用 amount)。
    currency_code: str | None = None
    native_amount: float | None = None
    last_change_id: int
    ledger_id: str | None = None
    ledger_name: str | None = None
    created_by_user_id: str | None = None
    created_by_email: str | None = None
    created_by_display_name: str | None = None
    created_by_avatar_url: str | None = None
    created_by_avatar_version: int | None = None
    # §7 共享账本:tx 创建/编辑分离显示 — last_edited 跟 created 不同时,UI
    # 显示 "X 创建 · Y 编辑";相同时只显示创建者。
    last_edited_by_user_id: str | None = None
    last_edited_by_email: str | None = None
    last_edited_by_display_name: str | None = None
    last_edited_by_avatar_url: str | None = None
    last_edited_by_avatar_version: int | None = None


class ReadAccountOut(BaseModel):
    id: str
    name: str
    account_type: str | None
    currency: str | None
    initial_balance: float | None
    last_change_id: int
    ledger_id: str | None = None
    ledger_name: str | None = None
    created_by_user_id: str | None = None
    created_by_email: str | None = None
    # 扩展字段(mobile sync_engine 一直在 push 这些,server 现在落库 + round-trip,
    # web 编辑也能完整保存):
    note: str | None = None
    credit_limit: float | None = None
    billing_day: int | None = None
    payment_due_day: int | None = None
    bank_name: str | None = None
    card_last_four: str | None = None
    # 账户隐藏(issue #240):只影响前端选择器/列表呈现,服务端不做任何统计
    # 过滤(D1)。WorkspaceAccountOut 继承本字段,不单独重复声明。
    hidden: bool = False


class ReadCategoryOut(BaseModel):
    id: str
    name: str
    kind: str
    level: int | None
    sort_order: int | None
    icon: str | None
    icon_type: str | None
    custom_icon_path: str | None = None
    icon_cloud_file_id: str | None = None
    icon_cloud_sha256: str | None = None
    parent_name: str | None
    last_change_id: int
    ledger_id: str | None = None
    ledger_name: str | None = None
    created_by_user_id: str | None = None
    created_by_email: str | None = None


class ReadTagOut(BaseModel):
    id: str
    name: str
    color: str | None
    last_change_id: int
    ledger_id: str | None = None
    ledger_name: str | None = None
    created_by_user_id: str | None = None
    created_by_email: str | None = None


class ReadBudgetOut(BaseModel):
    """预算只读视图。mobile 同步上来的 snapshot.budgets 逐条 map 过来。
    category_name 不进 snapshot,这里从 categoryId 反查填上,跟 tx/account
    同一套 id→name 映射思路。"""
    id: str
    """`total` = 总预算(全账本),`category` = 分类预算"""
    type: str
    category_id: str | None = None
    category_name: str | None = None
    amount: float
    """`monthly` / `weekly` / `yearly`"""
    period: str
    start_day: int
    enabled: bool
    last_change_id: int
    ledger_id: str | None = None
    ledger_name: str | None = None


class ReadBudgetUsageItemOut(BaseModel):
    """单个 budget 当前周期的已用金额。分类预算的 used 包含该分类自身 + 所有
    parent_sync_id 指向它的子分类支出(跟手机端 local_budget_repository 的
    OR c.parent_id = ? 语义对齐)。"""
    budget_id: str
    used: float


class ReadBudgetUsageOut(BaseModel):
    """`/ledgers/{id}/budgets/usage` 返回。周期窗口统一取账本 month_start_day
    (设计 D5:budget.start_day 弃用,所有 budget 共享同一周期),前端只用 used 数字。"""
    items: list[ReadBudgetUsageItemOut] = Field(default_factory=list)


class WorkspaceTransactionOut(ReadTransactionOut):
    pass


class WorkspaceTransactionPageOut(BaseModel):
    items: list[WorkspaceTransactionOut] = Field(default_factory=list)
    total: int
    limit: int
    offset: int


class WorkspaceAccountOut(ReadAccountOut):
    # 跨 workspace 对该账户聚合后的统计，列表接口一次性给，无需前端再聚合。
    # balance 包含 initialBalance + (income - expense)；income/expense 只统计本
    # 账户作为 accountId 的收支条目（不含 transfer 的对手方）。
    tx_count: int | None = None
    income_total: float | None = None
    expense_total: float | None = None
    balance: float | None = None


class AccountAdjustmentOut(BaseModel):
    """余额调整记录(0028)。amount 带符号:正=调增,负=调减。"""

    id: str
    account_id: str
    account_name: str | None = None
    amount: float
    balance_before: float | None = None
    balance_after: float | None = None
    happened_at: datetime
    created_at: datetime | None = None
    note: str | None = None
    created_by_user_id: str | None = None


class WorkspaceCategoryOut(ReadCategoryOut):
    # 跨账本按该分类聚合的笔数。Web 列表展示用,跟 tags 的 tx_count 对齐。
    # 不带 expense/income total — 分类本身已经按 kind 区分(支出/收入),
    # 累计金额可在分类详情页另行查询。None = 历史接口可选不提供。
    tx_count: int | None = None


class WorkspaceTagOut(ReadTagOut):
    # 跨所有账本按该标签聚合的交易统计，列表接口一次性给。
    # 全部 None = list_workspace_tags 可选择不提供（legacy 调用）。
    tx_count: int | None = None
    expense_total: float | None = None
    income_total: float | None = None


AnalyticsScope = Literal["month", "year", "all"]
AnalyticsMetric = Literal["expense", "income", "balance"]


class WorkspaceLedgerCountsOut(BaseModel):
    """单账本全量记账统计，对齐 mobile `getCountsForLedger`：笔数 + 首次记账到
    今天的天数（`julianday(now) - julianday(MIN(happened_at)) + 1`）+ 有数据的天数
    （distinct DATE，备用）。首页"记账笔数 / 记账天数"读这里，不依赖 analytics scope。"""

    tx_count: int
    # "记账天数"：从首次记账那天算到今天（含当天），对应 mobile 的 dayCount。
    days_since_first_tx: int
    # 有数据的天数：只计入有 tx 的日期数，保留给别处使用。
    distinct_days: int
    first_tx_at: datetime | None = None


class WorkspaceAnalyticsSummaryOut(BaseModel):
    transaction_count: int
    income_total: float
    expense_total: float
    balance: float
    # 记账天数：distinct(DATE(happened_at))。前端首页用来做"已记账 X 天"卡片。
    distinct_days: int = 0
    # 首次记账时间：min(happened_at)。配合 distinct_days 算"持续记账时长"。
    first_tx_at: datetime | None = None
    last_tx_at: datetime | None = None


class WorkspaceAnalyticsSeriesItemOut(BaseModel):
    bucket: str
    expense: float
    income: float
    balance: float


class WorkspaceAnalyticsCategoryRankOut(BaseModel):
    category_name: str
    total: float
    tx_count: int


class WorkspaceAnalyticsAnomalyAttributionOut(BaseModel):
    """异常月份的归因 — 某分类在该月超出"该分类其他月份中位数"的部分。"""

    category_name: str
    amount: float  # 该分类在异常月的总支出
    # 该分类在其他月份的中位数(本月独有时为 0)
    median_others: float
    # amount / median_others;median_others=0(本月独有)时为 None,前端显示"本月独有"。
    multiplier: float | None = None


class WorkspaceAnalyticsAnomalyMonthOut(BaseModel):
    """异常月份 — expense 显著高于已发生月份的 baseline。算法见
    `.docs/dashboard-anomaly-budget/plan.md`:
      baseline = median(已发生月份的 expense)
      异常判定:expense > baseline × 1.2 AND expense - baseline > ¥200
    """

    bucket: str  # "2026-05"
    expense: float
    baseline: float
    # (expense - baseline) / baseline,前端展示百分比
    deviation_pct: float
    # top 1-2 个归因分类,按 diff 降序
    top_attributions: list[WorkspaceAnalyticsAnomalyAttributionOut] = Field(
        default_factory=list
    )


class WorkspaceAnalyticsRangeOut(BaseModel):
    scope: AnalyticsScope
    metric: AnalyticsMetric
    period: str | None
    start_at: datetime | None
    end_at: datetime | None


class WorkspaceAnalyticsOut(BaseModel):
    summary: WorkspaceAnalyticsSummaryOut
    series: list[WorkspaceAnalyticsSeriesItemOut] = Field(default_factory=list)
    category_ranks: list[WorkspaceAnalyticsCategoryRankOut] = Field(default_factory=list)
    # 仅在 scope=year 填;月份数 < 3 时返回空 list(baseline 不稳)。
    anomaly_months: list[WorkspaceAnalyticsAnomalyMonthOut] = Field(default_factory=list)
    range: WorkspaceAnalyticsRangeOut
    # 批次4:多账本多币种且有币种缺汇率 → 折算不完整,前端复用净值页
    # needsBase 引导(设主币种/补汇率),避免与净值数字互相打架。
    multi_currency_incomplete: bool = False


class ReadSummaryOut(BaseModel):
    ledger_id: str
    transaction_count: int
    income_total: float
    expense_total: float
    balance: float
    latest_happened_at: datetime | None


class WriteCommitMeta(BaseModel):
    ledger_id: str
    base_change_id: int
    new_change_id: int
    server_timestamp: datetime
    idempotency_replayed: bool = False
    entity_id: str | None = None


class WriteBaseRequest(BaseModel):
    base_change_id: int = Field(ge=0)
    request_id: str | None = Field(default=None, max_length=128)


class WriteLedgerCreateRequest(BaseModel):
    # external_id 会拼进磁盘路径（附件 / 备份产物）→ 创建点必须过白名单。
    # 存量行不受影响（见 LEDGER_EXTERNAL_ID_PATTERN 注释：只收紧创建点）。
    ledger_id: str | None = Field(
        default=None,
        min_length=3,
        max_length=128,
        pattern=LEDGER_EXTERNAL_ID_PATTERN.pattern,
    )
    ledger_name: SafeName = Field(min_length=1, max_length=255)
    currency: str = Field(default="CNY", min_length=1, max_length=16)
    month_start_day: int = Field(default=1, ge=1, le=28)


class WriteLedgerMetaUpdateRequest(WriteBaseRequest):
    ledger_name: SafeName | None = Field(default=None, min_length=1, max_length=255)
    currency: str | None = Field(default=None, min_length=1, max_length=16)
    month_start_day: int | None = Field(default=None, ge=1, le=28)


class WriteTransactionCreateRequest(WriteBaseRequest):
    tx_type: Literal["expense", "income", "transfer"] = "expense"
    # 有限 float（拒 NaN / Infinity → 422，对抗 F-08）。负数放行（记账语义
    # 允许冲正）；round-3 中-2 起 `|amount| >= 1e12` 也拒（BoundedTxAmount,
    # 与 mobile `maxWriteAmount` 对齐 —— pull 守卫会把 ≥1e12 的行永远跳过,
    # 源头放行只会造成 web↔mobile 静默分叉）。sync push 不受此限。
    amount: BoundedTxAmount
    happened_at: datetime
    # note 会被复制进 sync_changes.payload_json（append-only）+ projection + CSV
    # 导出，必须有长度上限（对抗 F-10）；多行允许 `\n`/`\t`，其余控制字符拒。
    note: OptionalSafeNote = None
    category_name: SafeName | None = None
    category_kind: Literal["expense", "income", "transfer"] | None = None
    account_name: SafeName | None = None
    from_account_name: SafeName | None = None
    to_account_name: SafeName | None = None
    category_id: str | None = None
    account_id: str | None = None
    from_account_id: str | None = None
    to_account_id: str | None = None
    tags: str | list[str] | None = None
    tag_ids: list[str] | None = None
    attachments: list[dict[str, Any]] | None = None
    # 账单标记(.docs/transaction-flags)。新建默认 False。
    exclude_from_stats: bool = False
    exclude_from_budget: bool = False
    # 交易级多币种(0018):Web 币种录入。currency_code=原币种;native_amount=
    # 折账本本位币快照(前端按汇率算好传入)。不传 → item 不产生字段(旧行为)。
    currency_code: str | None = None
    native_amount: OptionalFiniteFloat = None


class WriteTransactionUpdateRequest(WriteBaseRequest):
    tx_type: Literal["expense", "income", "transfer"] | None = None
    # S3:非有限浮点不在这里 422 —— 对抗 A4 把 PATCH 路径锁成 400
    # (`test_amount_nan_in_patch_batch_and_adjustment_all_500` 断言三元组
    # (400,400,400)),有限性守卫由 mutator `update_transaction`
    # (`_require_finite_number`)做,ValueError → 400 WRITE_VALIDATION_FAILED。
    # POST 路径的 422(schema 层 FiniteFloat)由另一条验收测试锁定,两者都
    # 是 4xx,只是错误通道不同(见 schemas 顶部 FiniteFloat 说明)。
    amount: float | None = None
    happened_at: datetime | None = None
    note: OptionalSafeNote = None
    category_name: SafeName | None = None
    category_kind: Literal["expense", "income", "transfer"] | None = None
    account_name: SafeName | None = None
    from_account_name: SafeName | None = None
    to_account_name: SafeName | None = None
    category_id: str | None = None
    account_id: str | None = None
    from_account_id: str | None = None
    to_account_id: str | None = None
    tags: str | list[str] | None = None
    tag_ids: list[str] | None = None
    attachments: list[dict[str, Any]] | None = None
    # 账单标记(.docs/transaction-flags)。None = 不变(沿用 update 其它字段语义)。
    exclude_from_stats: bool | None = None
    exclude_from_budget: bool | None = None
    # 交易级多币种(0018):显式传入优先(mutator 不再联动);None = 不变。
    currency_code: str | None = None
    native_amount: OptionalFiniteFloat = None



class WriteEntityDeleteRequest(WriteBaseRequest):
    pass


class WriteAccountAdjustmentCreateRequest(WriteBaseRequest):
    """余额调整记录(0028):不落交易、不进收支统计,只改账户余额口径。

    amount 带符号差额(正=调增,负=调减);balance_before/after 审计快照,
    由前端本地算好传入(可空)。
    """

    account_id: str = Field(min_length=1, max_length=255)
    # S3:刻意**不用** `FiniteFloat`,让非有限值(NaN / Infinity)通过 schema
    # 落到 mutator(`create_account_adjustment` 的 `_require_finite_number`),
    # 由 ValueError → 400 WRITE_VALIDATION_FAILED。
    # 为什么不是 schema 的 422:对抗 A4 把 PATCH / batch / adjustment 三条路径
    # 统一锁成 400(见 `test_amount_nan_in_patch_batch_and_adjustment_all_500`),
    # 而 POST /transactions 的 422 由另一条测试锁定 —— 一个端点族两条通道,
    # 但这是现有验收契约;写入口的有限性守卫本身在 mutator 层是权威实现。
    amount: float = Field(allow_inf_nan=True)
    happened_at: datetime
    account_name: str | None = None
    balance_before: OptionalFiniteFloat = None
    balance_after: OptionalFiniteFloat = None
    note: Annotated[str | None, Field(max_length=MAX_NOTE_LENGTH)] = None


class WriteAccountCreateRequest(WriteBaseRequest):
    name: SafeName = Field(min_length=1, max_length=255)
    account_type: str | None = None
    currency: str | None = None
    initial_balance: OptionalFiniteFloat = None
    # 扩展字段:跟 mobile lib/data/db.dart Account 表对齐,跨端可编辑。
    note: Annotated[str | None, Field(max_length=MAX_NOTE_LENGTH)] = None
    credit_limit: OptionalFiniteFloat = None
    billing_day: int | None = Field(default=None, ge=1, le=31)
    payment_due_day: int | None = Field(default=None, ge=1, le=31)
    bank_name: str | None = None
    card_last_four: str | None = Field(default=None, max_length=8)
    # 账户隐藏(issue #240):新建一般为 false,留字段以备批量导入。写路径接线
    # (mutator / write handler)是 Task 4,本字段暂不生效。
    hidden: bool = False


class WriteAccountUpdateRequest(WriteBaseRequest):
    name: SafeName | None = Field(default=None, min_length=1, max_length=255)
    account_type: str | None = None
    currency: str | None = None
    # deprecated:初始值仅创建时可设,更新请求里的该字段被 mutator 忽略(mutate
    # / push 两条路径都锁定旧值)。保留字段仅为兼容旧客户端传值,不生效。
    initial_balance: OptionalFiniteFloat = None
    note: Annotated[str | None, Field(max_length=MAX_NOTE_LENGTH)] = None
    credit_limit: OptionalFiniteFloat = None
    billing_day: int | None = Field(default=None, ge=1, le=31)
    payment_due_day: int | None = Field(default=None, ge=1, le=31)
    bank_name: str | None = None
    card_last_four: str | None = Field(default=None, max_length=8)
    # None = 不改(PATCH exclude_unset)。写路径接线是 Task 4,本字段暂不生效。
    hidden: bool | None = None


class WriteBudgetCreateRequest(WriteBaseRequest):
    type: Literal["total", "category"]
    category_id: str | None = None
    amount: float = Field(gt=0)
    period: Literal["monthly", "weekly", "yearly"] = "monthly"
    # deprecated:预算周期已统一跟随账本 month_start_day(D5),该字段仅作兼容保留
    start_day: int = Field(default=1, ge=1, le=28)
    enabled: bool = True


class WriteBudgetUpdateRequest(WriteBaseRequest):
    amount: float | None = Field(default=None, gt=0)
    period: Literal["monthly", "weekly", "yearly"] | None = None
    # deprecated:预算周期已统一跟随账本 month_start_day(D5),该字段仅作兼容保留
    start_day: int | None = Field(default=None, ge=1, le=28)
    enabled: bool | None = None


class WriteCategoryCreateRequest(WriteBaseRequest):
    name: SafeName = Field(min_length=1, max_length=255)
    kind: Literal["expense", "income", "transfer"]
    level: int | None = None
    sort_order: int | None = None
    icon: str | None = None
    icon_type: str | None = None
    custom_icon_path: str | None = None
    icon_cloud_file_id: str | None = None
    icon_cloud_sha256: str | None = None
    parent_name: str | None = None


class WriteCategoryUpdateRequest(WriteBaseRequest):
    name: SafeName | None = Field(default=None, min_length=1, max_length=255)
    kind: Literal["expense", "income", "transfer"] | None = None
    level: int | None = None
    sort_order: int | None = None
    icon: str | None = None
    icon_type: str | None = None
    custom_icon_path: str | None = None
    icon_cloud_file_id: str | None = None
    icon_cloud_sha256: str | None = None
    parent_name: str | None = None


class WriteTagCreateRequest(WriteBaseRequest):
    name: SafeName = Field(min_length=1, max_length=255)
    color: str | None = None


class WriteTagUpdateRequest(WriteBaseRequest):
    name: SafeName | None = Field(default=None, min_length=1, max_length=255)
    color: str | None = None


class AdminDeviceOut(BaseModel):
    id: str
    name: str
    platform: str
    app_version: str | None = None
    os_version: str | None = None
    device_model: str | None = None
    last_ip: str | None = None
    created_at: datetime
    last_seen_at: datetime
    is_online: bool
    user_id: str
    user_email: str


class AdminDeviceListOut(BaseModel):
    total: int
    items: list[AdminDeviceOut]


class AttachmentUploadOut(BaseModel):
    file_id: str
    ledger_id: str
    sha256: str
    size: int
    mime_type: str | None = None
    file_name: str | None = None
    created_at: datetime


class AttachmentExistsItem(BaseModel):
    sha256: str
    exists: bool
    file_id: str | None = None
    size: int | None = None
    mime_type: str | None = None


class AttachmentBatchExistsRequest(BaseModel):
    ledger_id: str = Field(min_length=1, max_length=128)
    # 条数上限防 DoS：6 万条曾在 SQLite 上把端点打成 500（SQLAlchemy 变量
    # 上限），Postgres 侧对应 65535 bind 参数上限（对抗 F-03）。
    # 元素走 sha256 字符集校验（64 位 hex），避免任意长字符串进 IN 查询。
    sha256_list: Annotated[
        list[Annotated[str, Field(max_length=64, pattern=r"^[0-9a-fA-F]{64}$")]],
        Field(max_length=MAX_BATCH_LOOKUP_ITEMS),
    ] = Field(default_factory=list)


class AttachmentBatchExistsResponse(BaseModel):
    items: list[AttachmentExistsItem] = Field(default_factory=list)


# ============================================================================
# Backup schemas — Web UI 写入 / 读取请求和响应。详见 .docs/backup-rclone-plan.md
# ============================================================================


class BackupRemoteCreateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9_\-]+$")
    backend_type: str = Field(min_length=1, max_length=32)
    # rclone 配置字段(类型不同而异):s3 用 access_key_id/secret_access_key/...;
    # gdrive 用 client_id/client_secret/token。server 不在此校验具体字段,直接
    # 交给 rclone — 写完后立刻调 `rclone lsd <name>:` 测连通性,失败回写
    # last_test_error。
    config: dict[str, str] = Field(default_factory=dict)
    # 是否对 backup tarball 做 age passphrase 加密。开启时 age_passphrase 必填
    # (一旦丢失,该 remote 上的所有备份永久不可恢复)。
    encrypted: bool = False
    age_passphrase: str | None = None


class BackupRemoteUpdateRequest(BaseModel):
    config: dict[str, str] | None = None
    age_passphrase: str | None = None
    # 用户在编辑时切换 encrypted 状态(开/关) — 必须能持久化。
    encrypted: bool | None = None


class BackupRemoteOut(BaseModel):
    id: int
    name: str
    backend_type: str
    encrypted: bool
    config_summary: dict | None = None
    last_test_at: datetime | None = None
    last_test_ok: bool | None = None
    last_test_error: str | None = None
    created_at: datetime


class BackupRemoteTestResponse(BaseModel):
    ok: bool
    error: str | None = None
    listing: list[str] | None = None


class BackupScheduleCreateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=128)
    cron_expr: str = Field(min_length=1, max_length=64)
    retention_days: int = Field(ge=1, le=3650, default=30)
    include_attachments: bool = True
    enabled: bool = True
    remote_ids: list[int] = Field(min_length=1)


class BackupScheduleUpdateRequest(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=128)
    cron_expr: str | None = Field(default=None, min_length=1, max_length=64)
    retention_days: int | None = Field(default=None, ge=1, le=3650)
    include_attachments: bool | None = None
    enabled: bool | None = None
    remote_ids: list[int] | None = None


class BackupScheduleOut(BaseModel):
    id: int
    name: str
    cron_expr: str
    retention_days: int
    include_attachments: bool
    enabled: bool
    next_run_at: datetime | None = None
    last_run_at: datetime | None = None
    last_run_status: str | None = None
    remote_ids: list[int] = Field(default_factory=list)
    created_at: datetime


class BackupRunTargetOut(BaseModel):
    id: int
    remote_id: int
    remote_name: str | None = None
    status: str
    started_at: datetime | None = None
    finished_at: datetime | None = None
    bytes_transferred: int | None = None
    error_message: str | None = None


class BackupRunOut(BaseModel):
    id: int
    schedule_id: int | None = None
    schedule_name: str | None = None
    started_at: datetime
    finished_at: datetime | None = None
    status: str
    backup_filename: str | None = None
    bytes_total: int | None = None
    error_message: str | None = None
    log_text: str | None = None
    targets: list[BackupRunTargetOut] = Field(default_factory=list)


class BackupRunListOut(BaseModel):
    items: list[BackupRunOut]
    total: int


# ============================================================================
# Restore schemas (PR3 用)
# ============================================================================


class BackupRestoreOut(BaseModel):
    """`<DATA_DIR>/restore/<run_id>/status.json` 的读视图。"""

    run_id: int
    phase: str  # 'downloading' / 'extracting' / 'done' / 'failed'
    started_at: datetime
    finished_at: datetime | None = None
    bytes_total: int | None = None
    bytes_downloaded: int | None = None
    error_message: str | None = None
    extracted_path: str | None = None
    source_remote_id: int | None = None
    source_remote_name: str | None = None
    backup_filename: str | None = None


class BackupRestoreListOut(BaseModel):
    items: list[BackupRestoreOut]


# Raw automatic-bookkeeping evidence. This is display-only data and is not a
# sync entity. Limits keep accidental SMS/notification dumps bounded.
class RawEvidenceUpsertRequest(BaseModel):
    event_key: str = Field(min_length=1, max_length=255)
    ledger_id: str | None = Field(default=None, max_length=128)
    source: str = Field(min_length=1, max_length=32)
    source_channel: str | None = Field(default=None, max_length=128)
    external_id: str | None = Field(default=None, max_length=255)
    content_hash: str | None = Field(default=None, max_length=128)
    actor: str | None = Field(default=None, max_length=255)
    title: str | None = Field(default=None, max_length=2048)
    body: str | None = Field(default=None, max_length=65536)
    metadata: dict[str, Any] = Field(default_factory=dict)
    captured_at: datetime
    occurred_at: datetime | None = None
    expires_at: datetime | None = None

    @field_validator("event_key", "source")
    @classmethod
    def _trim_required(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("value cannot be empty")
        return value

    @field_validator("metadata")
    @classmethod
    def _limit_metadata(cls, value: dict[str, Any]) -> dict[str, Any]:
        # A shallow JSON-size guard prevents a client from turning this table
        # into an unbounded blob store. The actual JSON column remains typed.
        import json
        if len(json.dumps(value, ensure_ascii=False, separators=(",", ":"))) > 16384:
            raise ValueError("metadata too large")
        return value


class RawEvidenceOut(BaseModel):
    id: str
    event_key: str
    ledger_id: str | None
    source: str
    source_channel: str | None
    external_id: str | None
    content_hash: str | None
    actor: str | None
    title: str | None
    body: str | None
    metadata: dict[str, Any]
    captured_at: datetime
    occurred_at: datetime | None
    expires_at: datetime | None
    created_at: datetime
    updated_at: datetime


class RawEvidenceListOut(BaseModel):
    total: int
    items: list[RawEvidenceOut]


class RawEvidenceCleanupRequest(BaseModel):
    before: datetime | None = None
    source: str | None = Field(default=None, max_length=32)
