"""SPA catch-all 静态文件解析的路径穿越防护(2026-09 修复)。

回归背景:serve_spa 曾把未清洗的 `{full_path:path}` 直接与 _static_dir 拼接,
而 uvicorn 会把 %2F 解码进 scope["path"]、Path 拼接也不清洗 `..`/绝对段
(`static_dir / "/etc/x"` 会整体替换基准)→ `GET /..%2F..%2Fdata%2F.jwt_secret`
能读静态目录外任意文件(该路由无认证依赖,可泄漏 JWT 密钥等容器内文件)。
修复后 resolve + 包含校验,越界一律返回 None 落回 index.html 兜底。
"""

from __future__ import annotations

from pathlib import Path

from src.main import _resolve_static_file


def _make_static(tmp_path: Path) -> tuple[Path, Path]:
    static = tmp_path / "static"
    static.mkdir()
    (static / "index.html").write_text("<html></html>", encoding="utf-8")
    (static / "app.js").write_text("console.log(1)", encoding="utf-8")
    secret = tmp_path / "secret.txt"
    secret.write_text("jwt-secret-value", encoding="utf-8")
    return static, secret


def test_normal_files_resolve(tmp_path: Path) -> None:
    static, _secret = _make_static(tmp_path)
    resolved = _resolve_static_file(static, "index.html")
    assert resolved == (static / "index.html").resolve()
    assert _resolve_static_file(static, "app.js") is not None


def test_dot_segments_cannot_escape(tmp_path: Path) -> None:
    static, _secret = _make_static(tmp_path)
    # uvicorn 对 %2F 解码后,handler 收到的即 "../" 形态
    assert _resolve_static_file(static, "../secret.txt") is None
    assert _resolve_static_file(static, "subdir/../../secret.txt") is None
    # Windows 分隔符形态
    assert _resolve_static_file(static, "..\\secret.txt") is None


def test_absolute_path_cannot_replace_base(tmp_path: Path) -> None:
    static, secret = _make_static(tmp_path)
    # Path 拼接遇绝对段会整体替换基准(pathlib 行为),包含校验必须兜住
    assert _resolve_static_file(static, str(secret)) is None


def test_missing_and_directory_fall_back(tmp_path: Path) -> None:
    static, _secret = _make_static(tmp_path)
    (static / "assets").mkdir()
    assert _resolve_static_file(static, "missing.js") is None
    assert _resolve_static_file(static, "assets") is None
