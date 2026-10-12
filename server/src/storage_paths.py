"""磁盘存储路径的包含性校验 —— 附件域所有落盘点的**唯一**权威实现。

根因与用途
----------
账本 ``external_id``(以及 user_id 等 DB 字段)会被直接拼进磁盘路径。创建
点虽已有字符集白名单(``schemas.LEDGER_EXTERNAL_ID_PATTERN`` / ``/sync/push``
的宽松判据),但**存量脏行**(加固前落库的历史数据)绕过创建点,所以每个
落盘点在写盘前都必须再做一次 ``Path.resolve()`` + ``is_relative_to`` 包含性
检查(纵深防御)。

为什么要抽成共享模块
--------------------
附件域有多个落盘点。历史上只给 ``routers/attachments.py`` 加了检查,
``routers/write/transactions_batch.py`` 的 ``attach_image_id`` 路径仍在裸拼
路径 —— 同一根因的第四个写点漏网。把检查收敛到本模块,新增落盘点只要调用
``resolve_within_root``,不会再出现「只改一个入口」的漏点。

失败语义:400(不落盘、不建目录)+ ERROR 级审计日志(admin 日志面板默认
筛 ERROR,日志里直接可见)。
"""
from __future__ import annotations

import logging
from pathlib import Path

from fastapi import HTTPException, status

logger = logging.getLogger(__name__)


def attachment_storage_root(*, create: bool = True) -> Path:
    """``ATTACHMENT_STORAGE_DIR`` 解析为根目录(附件域唯一根)。

    ``create=False`` 供**只读判据**用(扫描 / 判定路径是否可删)—— 读路径
    不应有建目录的副作用。
    """
    from .config import get_settings

    root = Path(get_settings().attachment_storage_dir).expanduser()
    if create:
        root.mkdir(parents=True, exist_ok=True)
    return root


def attachment_storage_root_if_configured() -> Path | None:
    """配置了附件根时返回它,否则 ``None``(**fail-closed** 判据用)。

    `ATTACHMENT_STORAGE_DIR=` 空串是**文档化的「关闭附件存储」开关**
    (config.py 的 `_derive_storage_paths`:显式给空串就以给值为准)。此时
    ``Path("") == Path(".")``,若把它当根,则 cwd 之下的一切都「在根内」——
    包含性检查形同虚设。因此空配置一律视为「没有附件根」:删除判据拒绝
    一切物理文件清理(宁可不删,不可误删)。
    """
    from .config import get_settings

    raw = get_settings().attachment_storage_dir
    if raw is None or not str(raw).strip():
        return None
    return Path(raw).expanduser()


def path_within_root(root: Path, *parts: str) -> Path | None:
    """``resolve_within_root`` 的**非抛出**版本(纯判定,按片段拼接)。

    命中返回解析后的绝对路径(保证在 root 之内),逃逸 / 解析失败返回 None。

    - ``Path.resolve()`` 会消解 ``..`` / 绝对路径片段 / 符号链接(Windows 下
      大小写不敏感、盘符切换同样由 is_relative_to 兜住);
    - ``OSError`` / ``RuntimeError``(Windows 上 resolve 可能抛)/ ``ValueError``
      一律按「不可信」处理返回 None。

    用途是**落盘点**(root + 各片段)。「已经是一个完整路径」的判定
    (DB / 客户端给的 ``storage_path``、``file_path``)用
    [resolve_path_within_root][src.storage_paths.resolve_path_within_root],
    那里不能再拼 root(相对路径拼上去会变成 root 的子路径,与 ``os.remove``
    的 cwd 语义脱节)。
    """
    try:
        root_resolved = root.resolve()
        candidate = root_resolved.joinpath(*parts).resolve()
    except (OSError, RuntimeError, ValueError):
        return None
    if not candidate.is_relative_to(root_resolved):
        return None
    return candidate


def resolve_path_within_root(root: Path, raw_path: str | Path) -> Path | None:
    """**完整路径**(DB / 客户端输入)的包含性判定 —— 与 ``os.remove`` 同语义。

    与 [path_within_root][src.storage_paths.path_within_root] 的区别:本函数
    **不**把 root 与输入拼接,而是把输入**原样** ``resolve()``(相对路径按
    cwd 解析 —— 与 ``os.remove`` 完全一致),再要求落在 root 之内。

    必要性:data_cleanup 的删除目标是 DB ``storage_path`` 与客户端回传的
    ``file_path``(可指向任意绝对路径)。若用拼接版判据,一个相对路径
    (如 ``victim.txt``)会被当成 ``root/victim.txt`` 而「看起来合法」,
    但删除语义其实指向 cwd —— 判据与行为必须一致,否则要么漏拦、要么
    把合法清理拒掉。

    命中返回解析后的绝对路径(可安全 ``os.remove``),否则 None。
    """
    if raw_path is None:
        return None
    raw = str(raw_path)
    if not raw.strip():
        return None
    try:
        root_resolved = root.resolve()
        candidate = Path(raw).expanduser().resolve()
    except (OSError, RuntimeError, ValueError):
        return None
    if not candidate.is_relative_to(root_resolved):
        return None
    return candidate


def resolve_within_root(root: Path, *parts: str, component: str = "storage") -> Path:
    """root 与各路径片段拼接后做包含性检查,逃出 root → 400 + 审计日志。

    - ``Path.resolve()`` 会消解 ``..`` / 绝对路径片段 / 符号链接;
    - 解析结果不在 root 之内 → 400(不落盘、不建目录);
    - ``component`` 只用于日志前缀,标出是哪个落盘点被拦(审计可追溯)。

    合法返回值保证在 root 之内,调用方可直接 ``mkdir`` + 写文件。
    判据实现收敛到 [path_within_root][src.storage_paths.path_within_root],
    本函数只负责「抛 400 + 审计日志」这一层。
    """
    candidate = path_within_root(root, *parts)
    if candidate is None:
        root_resolved = root.resolve()
        logger.error(
            "%s.path_escape_blocked root=%s candidate=%s parts=%s",
            component,
            root_resolved,
            root_resolved.joinpath(*parts),
            parts,
        )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid attachment storage path",
        )
    return candidate
