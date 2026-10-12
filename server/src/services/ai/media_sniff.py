"""媒体容器魔数校验(不只信 MIME / 文件名后缀)。

背景:relay 的 vision / stt 校验原先只看 multipart 的 `Content-Type`,缺失或
不在白名单时**只用文件后缀兜底** —— 于是「`<html><script>` 改名 `.png`」、
「zip(`PK\\x03\\x04`)改名 `.png`」、「`application/octet-stream` 塞 HTML」
都能一路通过校验并被 base64 转发给上游 LLM。文件名是客户端完全可控的,
把类型判定交给它等于没有校验。

本模块提供**纯字节级**的容器识别(只读文件头,不解码、不依赖第三方库):

- `sniff_image_mime` / `sniff_audio_mime` → 识别出的规范 MIME,识别不出返回 None;
- `is_plausible_image` / `is_plausible_audio` → 供校验点使用的布尔判据。

设计取舍:

1. **0 字节放行** —— 空载荷没有魔数可言,现行行为是放行(交给上游报错),
   这是既有 HARDENING 断言锁定的行为,这里保持一致,不改变;
2. **同类放行、跨类拒绝** —— 判据是「必须能识别出属于该大类(图片/音频)」,
   而不是「识别结果必须逐字等于声明的 MIME」。真图被客户端标错 CT
   (JPEG 标成 PNG)仍放行并告警 —— 客户端 MIME 漂移不该误伤正常记账,
   而本模块要拦的是**根本不是图片/音频**的载荷;
3. **共享位置** —— 附件上传侧(`routers/attachments.py`)需要同一份图片魔数
   判据时从这里 import(记在 FINDINGS 的 handoff 里),避免两套实现漂移。

用法::

    from ...services.ai.media_sniff import is_plausible_image, sniff_image_mime

    if not is_plausible_image(image_bytes):
        raise HTTPException(400, {"error_code": "AI_IMAGE_TYPE_INVALID", ...})
"""
from __future__ import annotations

import logging

logger = logging.getLogger(__name__)

__all__ = [
    "sniff_image_mime",
    "sniff_audio_mime",
    "is_plausible_image",
    "is_plausible_audio",
    "IMAGE_MIMES",
    "AUDIO_MIMES",
]

IMAGE_MIMES = frozenset({"image/jpeg", "image/png", "image/webp", "image/gif"})
AUDIO_MIMES = frozenset(
    {
        "audio/wav",
        "audio/x-wav",
        "audio/mpeg",
        "audio/mp3",
        "audio/mp4",
        "audio/x-m4a",
        "audio/aac",
        "audio/ogg",
        "audio/opus",
        "audio/webm",
        "audio/flac",
        "audio/amr",
        "audio/aiff",
        "audio/x-aiff",
        "audio/caf",
    }
)

# 至少要有这么多字节才够判容器头(RIFF/WEBP、ftyp 都在前 12 字节内)。
_MIN_PROBE = 12


def _head(data: bytes | bytearray | memoryview | None) -> bytes:
    if not data:
        return b""
    return bytes(data[:64])


def _is_iso_bmff(data: bytes) -> bool:
    """MP4 / M4A / MOV / 3GP 等 ISO-BMFF:`....ftyp<brand>`。"""
    return len(data) >= 12 and data[4:8] == b"ftyp"


def sniff_image_mime(data: bytes | bytearray | memoryview | None) -> str | None:
    """识别图片容器,返回规范 MIME;识别不出(或太短)返回 None。"""
    head = _head(data)
    if not head:
        return None
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    # JPEG:SOI marker 是 2 字节(常见表写 `FF D8 FF`,但第三个字节属于
    # 后续 segment marker,不是 SOI 的一部分 —— 只认 2 字节既符合规范又
    # 不放过非图片载荷)。
    if head.startswith(b"\xff\xd8"):
        return "image/jpeg"
    if head.startswith(b"GIF87a") or head.startswith(b"GIF89a"):
        return "image/gif"
    if len(head) >= _MIN_PROBE and head.startswith(b"RIFF") and head[8:12] == b"WEBP":
        return "image/webp"
    return None


def sniff_audio_mime(data: bytes | bytearray | memoryview | None) -> str | None:
    """识别常见音频容器(容器级,不解析编码细节),识别不出返回 None。

    覆盖 App 录音/上传会遇到的形态:wav / mp3(ID3 或帧同步)/ ogg / flac /
    m4a(mp4 家族)/ webm / aac(ADTS)/ amr / aiff / caf。
    """
    head = _head(data)
    if not head:
        return None
    if len(head) >= _MIN_PROBE:
        if head.startswith(b"RIFF") and head[8:12] == b"WAVE":
            return "audio/wav"
        if head.startswith(b"FORM") and head[8:12] == b"AIFF":
            return "audio/aiff"
    if head.startswith(b"ID3") or head.startswith(b"OggS") or head.startswith(b"fLaC"):
        if head.startswith(b"ID3"):
            return "audio/mpeg"
        return "audio/ogg" if head.startswith(b"OggS") else "audio/flac"
    if head.startswith(b"#!AMR"):
        return "audio/amr"
    if head.startswith(b"caff"):
        return "audio/caf"
    if head.startswith(b"\x1aE\xdf\xa3"):
        return "audio/webm"
    if _is_iso_bmff(head):
        return "audio/mp4"
    # MPEG 帧同步 0xFFEx(11 个 1)+ ADTS AAC 0xFFFx:两者都是「裸帧音频」。
    if len(head) >= 2 and head[0] == 0xFF and (head[1] & 0xE0) == 0xE0:
        return "audio/aac" if (head[1] & 0x10) else "audio/mpeg"
    return None


def is_plausible_image(
    data: bytes | bytearray | memoryview | None, *, declared_mime: str | None = None
) -> bool:
    """载荷像不像图片。空载荷放行(既有行为,交给上游报错)。

    `declared_mime` 只用于「识别结果与声明不一致」的告警,不改变放行结果 ——
    拦的是「根本不是图片」,不是「标错子类型」。
    """
    if not data:
        return True
    sniffed = sniff_image_mime(data)
    if sniffed is None:
        logger.warning(
            "ai.media.image_magic_mismatch declared=%s sniffed=none bytes=%d",
            declared_mime, len(data),
        )
        return False
    if declared_mime and sniffed != declared_mime:
        logger.info(
            "ai.media.image_mime_drift declared=%s sniffed=%s bytes=%d",
            declared_mime, sniffed, len(data),
        )
    return True


def is_plausible_audio(
    data: bytes | bytearray | memoryview | None, *, declared_mime: str | None = None
) -> bool:
    """载荷像不像音频。空载荷放行(与图片同口径)。

    只在「没有可信音频 MIME(octet-stream / 缺失)」时才是硬判据;声明了
    明确 `audio/*` 的调用方可以选择信任声明(见 relay_stt 的注释)。
    """
    if not data:
        return True
    sniffed = sniff_audio_mime(data)
    if sniffed is None:
        logger.warning(
            "ai.media.audio_magic_mismatch declared=%s sniffed=none bytes=%d",
            declared_mime, len(data),
        )
        return False
    if declared_mime and sniffed != declared_mime:
        logger.info(
            "ai.media.audio_mime_drift declared=%s sniffed=%s bytes=%d",
            declared_mime, sniffed, len(data),
        )
    return True
