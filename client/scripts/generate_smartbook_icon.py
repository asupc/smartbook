#!/usr/bin/env python3
"""Generate the 智记 SmartBook app icon and platform derivatives.

Design language:
- an open ledger/book for "记" / bookkeeping;
- a mint check and small gold coin for automatic, completed records;
- an indigo-to-night background and a single smart sparkle for "智".

The generated icon contains no bee imagery.  The script is deterministic and
keeps Android adaptive, Android legacy, iOS, SVG, and review-preview outputs in
sync.

Usage:
  python scripts/generate_smartbook_icon.py
  python scripts/generate_smartbook_icon.py --apply
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Iterable, Sequence

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
ASSET_DIR = ROOT / "assets" / "icon"
ANDROID_RES = ROOT / "android" / "app" / "src" / "main" / "res"
IOS_ICON_DIR = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"

# 智记 SmartBook palette.
INK = (12, 23, 56, 255)              # deep ink / ledger lines
BG_TOP = (47, 61, 151, 255)         # indigo
BG_BOTTOM = (9, 17, 52, 255)        # night blue
PAGE_LEFT_TOP = (255, 246, 218, 255)
PAGE_LEFT_BOTTOM = (255, 205, 103, 255)
PAGE_RIGHT_TOP = (239, 244, 255, 255)
PAGE_RIGHT_BOTTOM = (184, 203, 255, 255)
COVER = (28, 45, 104, 255)
COVER_HIGHLIGHT = (57, 77, 160, 255)
GOLD = (255, 202, 91, 255)
MINT = (102, 226, 207, 255)
MINT_LIGHT = (185, 255, 237, 255)
WHITE = (255, 255, 255, 255)

BASE = 1024
SS = 4  # supersample for crisp launcher-size edges


def S(value: float) -> int:
    return int(round(value * SS))


def point(x: float, y: float) -> tuple[float, float]:
    return x * SS, y * SS


def bbox(x0: float, y0: float, x1: float, y1: float) -> tuple[int, int, int, int]:
    return S(x0), S(y0), S(x1), S(y1)


def cubic(
    p0: tuple[float, float],
    p1: tuple[float, float],
    p2: tuple[float, float],
    p3: tuple[float, float],
    steps: int = 24,
) -> list[tuple[float, float]]:
    result: list[tuple[float, float]] = []
    for index in range(steps + 1):
        t = index / steps
        mt = 1 - t
        result.append(
            (
                mt**3 * p0[0]
                + 3 * mt**2 * t * p1[0]
                + 3 * mt * t**2 * p2[0]
                + t**3 * p3[0],
                mt**3 * p0[1]
                + 3 * mt**2 * t * p1[1]
                + 3 * mt * t**2 * p2[1]
                + t**3 * p3[1],
            )
        )
    return result


def path_points(commands: Sequence[tuple]) -> list[tuple[float, float]]:
    """Sample a tiny SVG-like M/L/C/Z path into supersampled points."""
    result: list[tuple[float, float]] = []
    current = (0.0, 0.0)
    start = (0.0, 0.0)
    for command in commands:
        op = command[0]
        if op == "M":
            current = (float(command[1]), float(command[2]))
            start = current
            result.append(current)
        elif op == "L":
            current = (float(command[1]), float(command[2]))
            result.append(current)
        elif op == "C":
            p1 = (float(command[1]), float(command[2]))
            p2 = (float(command[3]), float(command[4]))
            p3 = (float(command[5]), float(command[6]))
            curve = cubic(current, p1, p2, p3)
            result.extend(curve[1:])
            current = p3
        elif op == "Z":
            if current != start:
                result.append(start)
            current = start
        else:
            raise ValueError(f"Unsupported path operation: {op}")
    return [point(x, y) for x, y in result]


def path_mask(size: int, commands: Sequence[tuple]) -> Image.Image:
    mask = Image.new("L", (size * SS, size * SS), 0)
    ImageDraw.Draw(mask).polygon(path_points(commands), fill=255)
    return mask


def gradient_image(size: int, top, bottom) -> Image.Image:
    image = Image.new("RGBA", (size, size), top)
    draw = ImageDraw.Draw(image)
    for y in range(size):
        ratio = y / max(1, size - 1)
        color = tuple(
            round(top[channel] * (1 - ratio) + bottom[channel] * ratio)
            for channel in range(4)
        )
        draw.line((0, y, size, y), fill=color)
    return image


def composite_masked_gradient(canvas: Image.Image, mask: Image.Image, top, bottom) -> None:
    gradient = gradient_image(canvas.size[0], top, bottom)
    transparent = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    canvas.alpha_composite(Image.composite(gradient, transparent, mask))


def draw_round_line(
    draw: ImageDraw.ImageDraw,
    coords: Iterable[tuple[float, float]],
    fill,
    width: float,
) -> None:
    points = [point(x, y) for x, y in coords]
    scaled_width = S(width)
    draw.line(points, fill=fill, width=scaled_width, joint="curve")
    radius = scaled_width / 2
    for x, y in (points[0], points[-1]):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=fill)


def draw_path(
    canvas: Image.Image,
    commands: Sequence[tuple],
    fill,
    outline=None,
    outline_width: float = 0,
) -> None:
    draw = ImageDraw.Draw(canvas)
    points = path_points(commands)
    draw.polygon(points, fill=fill)
    if outline is not None and outline_width:
        draw.line(points, fill=outline, width=S(outline_width), joint="curve")


def draw_gradient_path(
    canvas: Image.Image,
    commands: Sequence[tuple],
    top,
    bottom,
    outline=None,
    outline_width: float = 0,
) -> None:
    mask = path_mask(canvas.size[0] // SS, commands)
    composite_masked_gradient(canvas, mask, top, bottom)
    if outline is not None and outline_width:
        ImageDraw.Draw(canvas).line(
            path_points(commands), fill=outline, width=S(outline_width), joint="curve"
        )


def left_page() -> list[tuple]:
    return [
        ("M", 512, 356),
        ("C", 426, 294, 310, 279, 201, 326),
        ("C", 169, 340, 151, 366, 155, 402),
        ("L", 186, 682),
        ("C", 190, 716, 216, 737, 251, 729),
        ("C", 350, 706, 430, 731, 512, 794),
        ("Z",),
    ]


def right_page() -> list[tuple]:
    return [
        ("M", 512, 356),
        ("C", 598, 294, 714, 279, 823, 326),
        ("C", 855, 340, 873, 366, 869, 402),
        ("L", 838, 682),
        ("C", 834, 716, 808, 737, 773, 729),
        ("C", 674, 706, 594, 731, 512, 794),
        ("Z",),
    ]


def book_cover() -> list[tuple]:
    return [
        ("M", 150, 700),
        ("C", 278, 735, 395, 786, 512, 850),
        ("C", 629, 786, 746, 735, 874, 700),
        ("L", 845, 821),
        ("C", 714, 889, 609, 919, 512, 938),
        ("C", 415, 919, 310, 889, 179, 821),
        ("Z",),
    ]


def bookmark() -> list[tuple]:
    return [
        ("M", 480, 270),
        ("L", 544, 270),
        ("L", 544, 456),
        ("L", 512, 426),
        ("L", 480, 456),
        ("Z",),
    ]



def draw_spark(draw: ImageDraw.ImageDraw, cx: float, cy: float, radius: float, fill) -> None:
    import math

    points = []
    for index in range(8):
        angle = -math.pi / 2 + index * math.pi / 4
        length = radius if index % 2 == 0 else radius * 0.34
        points.append(point(cx + length * math.cos(angle), cy + length * math.sin(angle)))
    draw.polygon(points, fill=fill)


def draw_mark(canvas: Image.Image, *, monochrome: bool = False) -> None:
    draw = ImageDraw.Draw(canvas)
    if monochrome:
        solid = (255, 255, 255, 255)
        transparent = (0, 0, 0, 0)
        draw_path(canvas, bookmark(), solid)
        draw_path(canvas, book_cover(), solid)
        draw_path(canvas, left_page(), solid)
        draw_path(canvas, right_page(), solid)
        draw_spark(draw, 770, 210, 46, solid)
        draw.ellipse(bbox(826, 258, 842, 274), fill=solid)
        draw.ellipse(bbox(718, 156, 730, 168), fill=solid)

        # Page text and check are negative space in Android themed mode.
        for coords in (
            [(252, 431), (426, 414)],
            [(260, 507), (431, 493)],
            [(270, 581), (416, 574)],
            [(598, 414), (772, 431)],
            [(593, 493), (764, 507)],
            [(608, 574), (754, 581)],
        ):
            draw_round_line(draw, coords, transparent, 18)
        draw_round_line(draw, [(447, 644), (502, 698), (602, 572)], transparent, 19)
        draw_round_line(draw, [(512, 372), (512, 783)], transparent, 10)
        draw.ellipse(bbox(643, 434, 717, 508), fill=transparent)
        draw.ellipse(bbox(666, 457, 694, 485), fill=solid)
        return

    # Bookmark sits behind the pages and gives the mark a small warm center tab.
    draw_path(canvas, bookmark(), GOLD, outline=INK, outline_width=18)

    # Cover first: it acts as a strong silhouette at small sizes.
    draw_path(canvas, book_cover(), COVER, outline=INK, outline_width=22)
    draw_round_line(
        draw,
        [(166, 708), (292, 741), (402, 790), (512, 850), (622, 790), (732, 741), (858, 708)],
        COVER_HIGHLIGHT,
        14,
    )

    # Warm left page / cool right page: finance + smart assistant in one mark.
    draw_gradient_path(canvas, left_page(), PAGE_LEFT_TOP, PAGE_LEFT_BOTTOM, INK, 22)
    draw_gradient_path(canvas, right_page(), PAGE_RIGHT_TOP, PAGE_RIGHT_BOTTOM, INK, 22)

    # Center spine and light page-edge glints.
    draw_round_line(draw, [(512, 368), (512, 793)], INK, 16)
    draw_round_line(draw, [(205, 382), (233, 654)], (255, 255, 255, 100), 8)
    draw_round_line(draw, [(819, 382), (791, 654)], WHITE[:3] + (96,), 8)

    # Ledger rows, kept thick enough for 20–48 px launcher renders.
    row_color = INK[:3] + (210,)
    for coords in (
        [(252, 431), (426, 414)],
        [(260, 507), (431, 493)],
        [(270, 581), (416, 574)],
        [(598, 414), (772, 431)],
        [(593, 493), (764, 507)],
        [(608, 574), (754, 581)],
    ):
        draw_round_line(draw, coords, row_color, 18)

    # Small coin cue on the right page, intentionally abstract and language-free.
    draw.ellipse(bbox(643, 434, 717, 508), fill=GOLD, outline=INK, width=S(14))
    draw_round_line(draw, [(666, 471), (694, 471)], INK, 9)
    draw_round_line(draw, [(680, 458), (680, 484)], INK, 7)

    # Completion / automation check, with a dark under-stroke for contrast.
    draw_round_line(draw, [(447, 644), (502, 698), (602, 572)], INK, 42)
    draw_round_line(draw, [(447, 644), (502, 698), (602, 572)], MINT_LIGHT, 25)

    # "Smart" sparkle and small supporting dot.
    draw_spark(draw, 770, 210, 46, MINT_LIGHT)
    draw.ellipse(bbox(826, 258, 842, 274), fill=MINT)
    draw.ellipse(bbox(718, 156, 730, 168), fill=MINT)


def render_full(size: int = BASE) -> Image.Image:
    hi = size * SS
    canvas = gradient_image(hi, BG_TOP, BG_BOTTOM)

    glow = Image.new("RGBA", (hi, hi), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.ellipse(bbox(130, 130, 890, 890), fill=(138, 132, 255, 50))
    glow_draw.ellipse(bbox(640, 90, 900, 350), fill=(112, 241, 218, 38))
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(S(64))))

    inner = Image.new("RGBA", (hi, hi), (0, 0, 0, 0))
    ImageDraw.Draw(inner).rounded_rectangle(
        bbox(24, 24, 1000, 1000),
        radius=S(220),
        outline=(255, 255, 255, 24),
        width=S(2),
    )
    canvas.alpha_composite(inner)

    # Soft book shadow; kept subtle so the icon remains flat and crisp.
    shadow = Image.new("RGBA", (hi, hi), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.ellipse(bbox(164, 768, 860, 960), fill=(0, 0, 0, 105))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(S(32))))
    draw_mark(canvas)
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def render_foreground(size: int = BASE) -> Image.Image:
    hi = size * SS
    canvas = Image.new("RGBA", (hi, hi), (0, 0, 0, 0))
    draw_mark(canvas)
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def render_monochrome(size: int = BASE) -> Image.Image:
    hi = size * SS
    # Render the single-color glyph on RGBA, then keep only its alpha channel
    # so Android 13+ can apply the system tint.
    rgba = Image.new("RGBA", (hi, hi), (255, 255, 255, 0))
    draw_mark(rgba, monochrome=True)
    alpha = rgba.getchannel("A").resize((size, size), Image.Resampling.LANCZOS)
    output = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    output.putalpha(alpha)
    return output


def hex_color(color: tuple[int, int, int, int]) -> str:
    return "#" + "".join(f"{channel:02X}" for channel in color[:3])


def svg_source() -> str:
    # 品牌图标源唯一权威:docs/icon/icon-a.svg(闪电票据)。
    # 不再内嵌图形(历史版本为账本+对勾),读取源文件避免"脚本里的 svg 与
    # 设计稿两份"互相覆盖;改设计只需改 docs/icon/icon-a.svg。
    icon_src = ROOT.parent / "docs" / "icon" / "icon-a.svg"
    if not icon_src.exists():
        raise FileNotFoundError(
            f"图标源缺失:{icon_src}\n请将设计稿以 icon-a.svg 放回后重试。"
        )
    return icon_src.read_text(encoding="utf-8")


def save_png(image: Image.Image, path: Path, *, opaque: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image = image.convert("RGB") if opaque else image
    image.save(path, "PNG", optimize=True)


def make_preview(full: Image.Image, foreground: Image.Image, monochrome: Image.Image) -> Image.Image:
    cell = 512
    pad = 32
    sheet = Image.new("RGBA", (cell * 3 + pad * 4, cell * 2 + pad * 3), (246, 247, 244, 255))
    draw = ImageDraw.Draw(sheet)
    labels = ["full icon", "adaptive layers", "themed silhouette"]
    for index, label in enumerate(labels):
        x = pad + index * (cell + pad)
        draw.rounded_rectangle((x, pad, x + cell, pad + cell), radius=28, fill=(235, 238, 233, 255))
        if index == 0:
            preview = full.resize((cell, cell), Image.Resampling.LANCZOS)
        elif index == 1:
            preview = Image.new("RGBA", (cell, cell), BG_BOTTOM)
            preview.alpha_composite(foreground.resize((cell, cell), Image.Resampling.LANCZOS))
        else:
            themed_bg = Image.new("RGBA", (cell, cell), (232, 226, 211, 255))
            tint = Image.new("RGBA", (cell, cell), (69, 62, 91, 255))
            tint.putalpha(monochrome.resize((cell, cell), Image.Resampling.LANCZOS).getchannel("A"))
            preview = Image.alpha_composite(themed_bg, tint)
        sheet.alpha_composite(preview, (x, pad))
        draw.text((x + 18, pad + cell + 14), label, fill=(25, 35, 53, 255))

    # Launcher-size samples on light and dark surfaces.
    y = pad * 2 + cell + 52
    sample_size = cell // 2
    icon = full.resize((sample_size - 48, sample_size - 48), Image.Resampling.LANCZOS)
    for index, background in enumerate(((250, 250, 248, 255), (21, 29, 47, 255))):
        x = pad + index * (sample_size + pad)
        draw.rounded_rectangle((x, y, x + sample_size, y + sample_size), radius=26, fill=background)
        sheet.alpha_composite(icon, (x + 24, y + 24))
    return sheet.convert("RGB")


def apply_platform_assets(full: Image.Image, foreground: Image.Image, monochrome: Image.Image) -> list[Path]:
    changed: list[Path] = []

    active = {
        ASSET_DIR / "adaptive_foreground.png": foreground,
        ASSET_DIR / "adaptive_monochrome.png": monochrome,
        ASSET_DIR / "launcher_legacy.png": full,
        ASSET_DIR / "preview_themed.png": make_preview(full, foreground, monochrome),
    }
    for path, image in active.items():
        save_png(image, path, opaque=path.name == "launcher_legacy.png")
        changed.append(path)

    android_adaptive_sizes = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
    for density, size in android_adaptive_sizes.items():
        for name, source in (("ic_launcher_foreground", foreground), ("ic_launcher_monochrome", monochrome)):
            path = ANDROID_RES / f"drawable-{density}" / f"{name}.png"
            save_png(source.resize((size, size), Image.Resampling.LANCZOS), path)
            changed.append(path)

    android_legacy_sizes = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for density, size in android_legacy_sizes.items():
        path = ANDROID_RES / f"mipmap-{density}" / "ic_launcher.png"
        save_png(full.resize((size, size), Image.Resampling.LANCZOS), path, opaque=True)
        changed.append(path)

    ios_sizes = {
        "Icon-App-1024x1024@1x.png": 1024,
        "Icon-App-20x20@1x.png": 20,
        "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-50x50@1x.png": 50,
        "Icon-App-50x50@2x.png": 100,
        "Icon-App-57x57@1x.png": 57,
        "Icon-App-57x57@2x.png": 114,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-72x72@1x.png": 72,
        "Icon-App-72x72@2x.png": 144,
        "Icon-App-76x76@1x.png": 76,
        "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
    }
    for filename, size in ios_sizes.items():
        path = IOS_ICON_DIR / filename
        save_png(full.resize((size, size), Image.Resampling.LANCZOS), path, opaque=True)
        changed.append(path)

    colors_path = ANDROID_RES / "values" / "colors.xml"
    colors_text = colors_path.read_text(encoding="utf-8")
    colors_text = re.sub(
        r'(<color\s+name="ic_launcher_background">)[^<]*(</color>)',
        r"\g<1>#091134\g<2>",
        colors_text,
    )
    colors_path.write_text(colors_text.rstrip() + "\n", encoding="utf-8")
    changed.append(colors_path)
    return changed


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true", help="refresh active Android/iOS launcher assets")
    args = parser.parse_args()

    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    full = render_full()
    foreground = render_foreground()
    monochrome = render_monochrome()
    preview = make_preview(full, foreground, monochrome)

    save_png(full, ASSET_DIR / "smartbook_icon.png", opaque=True)
    (ASSET_DIR / "smartbook_icon.svg").write_text(svg_source(), encoding="utf-8")
    save_png(preview, ASSET_DIR / "smartbook_preview.png", opaque=True)

    print("Generated SmartBook design assets:")
    for path in (
        ASSET_DIR / "smartbook_icon.svg",
        ASSET_DIR / "smartbook_icon.png",
        ASSET_DIR / "smartbook_preview.png",
    ):
        print(f"  {path}")

    if args.apply:
        changed = apply_platform_assets(full, foreground, monochrome)
        print(f"Applied {len(changed)} active Android/iOS assets.")
    else:
        print("Preview only. Re-run with --apply to refresh active launcher assets.")


if __name__ == "__main__":
    main()
