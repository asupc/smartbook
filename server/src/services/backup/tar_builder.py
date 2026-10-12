"""把 staging 目录打包成 tar.gz / encrypted-zip(本地落盘),供 rclone
copyto 推到远端。

格式选择:
  - encrypted=False: tar.gz(标准 unix 打包)
  - encrypted=True : AES-256 password-protected zip(WinZip AES,macOS Archive
    Utility / Keka / 7-Zip / The Unarchiver / WinRAR 都原生支持自动弹出
    密码框),用 pyzipper 库实现。用户从 R2 下载 .zip 双击 → 输密码 → 解压 → 文件
    直接铺平,无中间 tar 层。

第一版选 "本地落文件" 而不是 "stream 进 rclone rcat" 的原因:
  - 同一份打包要 fan-out 到 N 个 remote(stream 单消费者)
  - 简单可观测 + 出错可回看

local copy of attachments 走 hardlink(`os.link`),零空间占用 —— attachments
是内容寻址 immutable 的,hardlink 拷贝跟原文件指向同一 inode。
"""
from __future__ import annotations

import logging
import os
import tarfile
from dataclasses import dataclass
from pathlib import Path

import pyzipper

from ...config import get_settings


logger = logging.getLogger(__name__)

# 解包读写的分块大小。比这小是为了在触发压缩比上限时把超写的字节数
# 控制在 1 个分块以内(上限按「写之前判断」执行,所以只会小于等于上限)。
_EXTRACT_CHUNK_BYTES = 64 * 1024

# 压缩比检查的绝对下限:展开量不到这个量级时压缩比无意义(小文本文件动辄
# 数百倍),此时只靠绝对体积上限兜底 —— 避免把正常的小备份误判成炸弹。
_RATIO_CHECK_MIN_BYTES = 16 * 1024 * 1024


class ArchivePathTraversalError(ValueError):
    """归档条目名试图逃出目标目录(zip slip)。"""


@dataclass(frozen=True)
class ExtractionOutcome:
    """解包结果。

    ``limit_exceeded`` 非 None 表示解包被上限**中止**,已写内容已回滚,
    目录内没有任何本次解出的文件。调用方(restore)必须据此报错,**不得**
    把解包目录当成完整数据使用。
    """

    entries: int
    written_bytes: int
    limit_exceeded: str | None = None

    @property
    def ok(self) -> bool:
        return self.limit_exceeded is None


def _resolve_extract_limits(
    max_entries: int | None,
    max_total_bytes: int | None,
    max_ratio: int | None,
) -> tuple[int, int, int]:
    settings = get_settings()
    entries = max_entries if max_entries is not None else settings.backup_extract_max_entries
    total = (
        max_total_bytes
        if max_total_bytes is not None
        else settings.backup_extract_max_total_bytes
    )
    ratio = max_ratio if max_ratio is not None else settings.backup_extract_max_ratio
    return max(1, int(entries)), max(1, int(total)), max(1, int(ratio))


def _limit_reason(
    *,
    entries: int,
    bytes_seen: int,
    archive_bytes: int,
    limits: tuple[int, int, int],
) -> str | None:
    """三重上限判定;返回 None 表示未超限,否则返回可读的原因。"""
    max_entries, max_total, max_ratio = limits
    if entries > max_entries:
        return f"entry count {entries} exceeds limit {max_entries}"
    if bytes_seen > max_total:
        return f"uncompressed size {bytes_seen} bytes exceeds limit {max_total}"
    # 压缩比只对「展开量已到炸弹量级」的归档生效 —— 小归档的比值天然很高
    # (几百字节的 txt 也能有百倍比值),不该据此拒正常备份。
    if bytes_seen >= _RATIO_CHECK_MIN_BYTES:
        ratio_cap = max(1, archive_bytes) * max_ratio
        if bytes_seen > ratio_cap:
            return (
                f"compression ratio exceeds {max_ratio}:1 "
                f"({bytes_seen} bytes from {archive_bytes} compressed)"
            )
    return None


def _safe_extract_target(root: Path, member_name: str) -> Path:
    """把归档条目名映射到 root 内的目标路径;任何逃逸尝试直接抛错。"""
    name = (member_name or "").replace("\\", "/")
    parts = [p for p in name.split("/") if p not in ("", ".")]
    if not parts or any(p == ".." for p in parts) or ":" in parts[0]:
        raise ArchivePathTraversalError(f"unsafe archive member path: {member_name!r}")
    target = root.joinpath(*parts)
    if target != root and not target.is_relative_to(root):
        raise ArchivePathTraversalError(f"unsafe archive member path: {member_name!r}")
    return target


def _cleanup_files(paths: list[Path]) -> None:
    for p in paths:
        try:
            p.unlink(missing_ok=True)
        except OSError:
            logger.warning("failed to remove partial extraction artifact: %s", p)


def hardlink_tree(src: str | Path, dst: str | Path) -> int:
    """把 src 目录 hardlink 拷贝到 dst。返回处理的文件数。

    跨文件系统会失败 —— caller 自己判断,失败时回退到 shutil.copytree。
    """
    src_p = Path(src)
    dst_p = Path(dst)
    dst_p.mkdir(parents=True, exist_ok=True)
    n = 0
    for root, _dirs, files in os.walk(src_p):
        rel_root = Path(root).relative_to(src_p)
        target_root = dst_p / rel_root
        target_root.mkdir(parents=True, exist_ok=True)
        for f in files:
            src_file = Path(root) / f
            dst_file = target_root / f
            if dst_file.exists():
                continue
            os.link(src_file, dst_file)
            n += 1
    return n


def build_targz(src_dir: str | Path, output_path: str | Path) -> int:
    """把 src_dir 整棵打包成 output_path (tar.gz)。返回 output 大小。

    arcname 用 `.` 让解压时根目录就是 src_dir 内容,便于 rsync 替换。
    """
    src_p = Path(src_dir)
    out_p = Path(output_path)
    out_p.parent.mkdir(parents=True, exist_ok=True)
    if out_p.exists():
        out_p.unlink()
    with tarfile.open(out_p, "w:gz", compresslevel=6) as tf:
        # arcname='.' 让 tar 内的根是 ./db.sqlite3 ./attachments/...
        # 解压后没有多余的 timestamp 父目录。
        tf.add(src_p, arcname=".", recursive=True)
    size = out_p.stat().st_size
    logger.info("tar.gz built: %s (%d bytes)", out_p, size)
    return size


def build_encrypted_zip(
    src_dir: str | Path,
    output_path: str | Path,
    passphrase: str,
) -> int:
    """把 src_dir 整棵打包成 AES-256 加密 zip(WinZip AES extension)。

    用户期望:macOS Archive Utility / Keka / 7-Zip / The Unarchiver /
    WinRAR 这类常见工具能识别并弹出密码框。pyzipper 输出的 WZ_AES zip
    格式正是这套。passphrase 错时打开会报错(各家 UI 自己处理)。
    """
    if not passphrase:
        raise ValueError("passphrase is empty")
    src_p = Path(src_dir)
    out_p = Path(output_path)
    out_p.parent.mkdir(parents=True, exist_ok=True)
    if out_p.exists():
        out_p.unlink()
    with pyzipper.AESZipFile(
        out_p,
        "w",
        compression=pyzipper.ZIP_DEFLATED,
        encryption=pyzipper.WZ_AES,
    ) as zf:
        zf.setpassword(passphrase.encode("utf-8"))
        for path in src_p.rglob("*"):
            if path.is_file():
                arcname = str(path.relative_to(src_p))
                zf.write(path, arcname=arcname)
    size = out_p.stat().st_size
    logger.info("encrypted zip built: %s (%d bytes)", out_p, size)
    return size


def extract_zip(
    zip_path: str | Path,
    dst_dir: str | Path,
    passphrase: str | None = None,
    *,
    max_entries: int | None = None,
    max_total_bytes: int | None = None,
    max_ratio: int | None = None,
) -> ExtractionOutcome:
    """解 AES-256 加密(或不加密)zip 到 dst_dir。restore 流程用。

    三重上限防 zip bomb(条目数 / 总展开字节 / 压缩比)。任一超限即**中止**
    并回滚本次已写出的文件,返回带 ``limit_exceeded`` 的 outcome;调用方
    (restore)必须检查 ``outcome.ok`` 并报错,不得把目录当完整数据。
    同时拒绝逃出 ``dst_dir`` 的条目名(zip slip)。
    """
    zp = Path(zip_path)
    dst = Path(dst_dir)
    dst.mkdir(parents=True, exist_ok=True)
    limits = _resolve_extract_limits(max_entries, max_total_bytes, max_ratio)
    max_entries_int = limits[0]
    # 压缩后大小作为压缩比分母;读不到就退化到绝对上限(不放大 false positive)。
    try:
        archive_bytes = max(1, zp.stat().st_size)
    except OSError:
        archive_bytes = 0

    written_files: list[Path] = []
    entries = 0
    written_bytes = 0

    def _abort(reason: str) -> ExtractionOutcome:
        _cleanup_files(written_files)
        logger.warning("zip extraction aborted: %s (archive=%s)", reason, zp)
        return ExtractionOutcome(
            entries=entries, written_bytes=0, limit_exceeded=reason
        )

    with pyzipper.AESZipFile(zp) as zf:
        if passphrase:
            zf.setpassword(passphrase.encode("utf-8"))
        infos = zf.infolist()
        # 预检:利用 zip 目录里的声明大小,不写盘就能拒掉高压缩比炸弹。
        declared_total = sum(max(0, int(i.file_size or 0)) for i in infos)
        if len(infos) > max_entries_int:
            return _abort(
                f"entry count {len(infos)} exceeds limit {max_entries_int}"
            )
        pre_reason = _limit_reason(
            entries=0,
            bytes_seen=declared_total,
            archive_bytes=archive_bytes,
            limits=limits,
        )
        if pre_reason is not None:
            return _abort(f"declared {pre_reason}")

        for info in infos:
            entries += 1
            reason = _limit_reason(
                entries=entries,
                bytes_seen=written_bytes,
                archive_bytes=archive_bytes,
                limits=limits,
            )
            if reason is not None:
                return _abort(reason)
            target = _safe_extract_target(dst, info.filename)
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            written_files.append(target)
            with zf.open(info) as src, open(target, "wb") as out:
                while True:
                    chunk = src.read(_EXTRACT_CHUNK_BYTES)
                    if not chunk:
                        break
                    written_bytes += len(chunk)
                    # 流式再判一次:即使目录里声明的大小撒了谎也拦得住。
                    reason = _limit_reason(
                        entries=entries,
                        bytes_seen=written_bytes,
                        archive_bytes=archive_bytes,
                        limits=limits,
                    )
                    if reason is not None:
                        out.close()
                        return _abort(reason)
                    out.write(chunk)

    logger.info(
        "zip extracted: %s -> %s (%d entries, %d bytes)",
        zp, dst, entries, written_bytes,
    )
    return ExtractionOutcome(entries=entries, written_bytes=written_bytes)


def extract_targz(
    tar_path: str | Path,
    dst_dir: str | Path,
    *,
    max_entries: int | None = None,
    max_total_bytes: int | None = None,
    max_ratio: int | None = None,
) -> ExtractionOutcome:
    """解 tar.gz 到 dst_dir(restore 流程用)。三重上限同 extract_zip。

    条目名安全仍交给 tarfile 的 ``filter='data'``(Python 3.12+);
    上限在解之前按 member header 声明大小预检 —— tar 头不可撒谎(谎报长度
    会让流解析错位直接报错),因此预检 + ``filter='data'`` 已覆盖整包。
    """
    tp = Path(tar_path)
    dst = Path(dst_dir)
    dst.mkdir(parents=True, exist_ok=True)
    limits = _resolve_extract_limits(max_entries, max_total_bytes, max_ratio)
    try:
        archive_bytes = max(1, tp.stat().st_size)
    except OSError:
        archive_bytes = 0

    with tarfile.open(tp, "r:gz") as tf:
        members = tf.getmembers()
        declared_total = sum(max(0, int(m.size or 0)) for m in members)
        reason = _limit_reason(
            entries=len(members),
            bytes_seen=declared_total,
            archive_bytes=archive_bytes,
            limits=limits,
        )
        if reason is not None:
            logger.warning("tar extraction aborted: %s (archive=%s)", reason, tp)
            return ExtractionOutcome(
                entries=len(members), written_bytes=0, limit_exceeded=reason
            )
        try:
            tf.extractall(dst, filter="data")
        except TypeError:
            # Python < 3.12 没有 filter 参数(平台相关风险,行为如旧)。
            tf.extractall(dst)  # noqa: S202

    logger.info(
        "tar extracted: %s -> %s (%d entries, %d bytes)",
        tp, dst, len(members), declared_total,
    )
    return ExtractionOutcome(entries=len(members), written_bytes=declared_total)
