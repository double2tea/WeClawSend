#!/usr/bin/env python3
"""WeClaw Send icons — monochrome ink mark, minimal."""

from __future__ import annotations

import math
import os
import shutil
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RESOURCES = os.path.join(ROOT, "Resources")
ICONSET = os.path.join(RESOURCES, "AppIcon.iconset")

BG_TOP = (48, 48, 52)
BG_BOTTOM = (18, 18, 20)
FG = (255, 255, 255)


def lerp(a: tuple[int, ...], b: tuple[int, ...], t: float) -> tuple[int, ...]:
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def rounded_rect_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def transform(x, y, size, cx, cy, scale, ang):
    cos_a, sin_a = math.cos(ang), math.sin(ang)
    s = size * scale
    return (cx + (x * cos_a - y * sin_a) * s, cy + (x * sin_a + y * cos_a) * s)


def plane_polygon(size, cx, cy, scale):
    ang = math.radians(-14)
    rel = [
        (-0.50, 0.14),
        (-0.22, 0.02),
        (0.46, -0.30),
        (0.10, 0.06),
        (0.18, 0.44),
        (-0.02, 0.12),
        (-0.28, 0.20),
    ]
    return [transform(x, y, size, cx, cy, scale, ang) for x, y in rel]


def draw_plane(draw, size, color, scale=0.58):
    cx, cy = size * 0.50, size * 0.52
    draw.polygon(plane_polygon(size, cx, cy, scale), fill=color)


def make_app_icon(size: int) -> Image.Image:
    render = size * 4
    base = Image.new("RGBA", (render, render), (0, 0, 0, 0))
    px = base.load()
    for y in range(render):
        t = y / max(render - 1, 1)
        c = lerp(BG_TOP, BG_BOTTOM, t)
        for x in range(render):
            px[x, y] = (*c, 255)

    hi = Image.new("RGBA", (render, render), (0, 0, 0, 0))
    ImageDraw.Draw(hi).ellipse(
        [-render * 0.1, -render * 0.55, render * 1.1, render * 0.35],
        fill=(255, 255, 255, 18),
    )
    hi = hi.filter(ImageFilter.GaussianBlur(radius=render * 0.04))
    base = Image.alpha_composite(base, hi)

    radius = int(render * 0.223)
    out = Image.new("RGBA", (render, render), (0, 0, 0, 0))
    out.paste(base, (0, 0), rounded_rect_mask(render, radius))
    draw_plane(ImageDraw.Draw(out), render, FG, scale=0.60)
    return out.resize((size, size), Image.Resampling.LANCZOS)


def make_menu_icon(size: int) -> Image.Image:
    render = size * 4
    img = Image.new("RGBA", (render, render), (0, 0, 0, 0))
    draw_plane(ImageDraw.Draw(img), render, (0, 0, 0, 255), scale=0.70)
    return img.resize((size, size), Image.Resampling.LANCZOS)


def icon_name(size: int, scale: int = 1) -> str:
    suffix = "" if scale == 1 else f"{chr(64)}{scale}x"
    return f"icon_{size}x{size}{suffix}.png"


def main() -> int:
    shutil.rmtree(ICONSET, ignore_errors=True)
    os.makedirs(ICONSET, exist_ok=True)
    make_app_icon(1024).save(os.path.join(RESOURCES, "brand-mark-1024.png"), "PNG")
    for name, px in [
        (icon_name(16), 16),
        (icon_name(16, 2), 32),
        (icon_name(32), 32),
        (icon_name(32, 2), 64),
        (icon_name(128), 128),
        (icon_name(128, 2), 256),
        (icon_name(256), 256),
        (icon_name(256, 2), 512),
        (icon_name(512), 512),
        (icon_name(512, 2), 1024),
    ]:
        make_app_icon(px).save(os.path.join(ICONSET, name), "PNG")
    make_menu_icon(32).save(os.path.join(RESOURCES, "MenuBarIcon.png"), "PNG")
    make_menu_icon(64).save(os.path.join(RESOURCES, "MenuBarIcon@2x.png"), "PNG")
    icns = os.path.join(RESOURCES, "AppIcon.icns")
    subprocess.check_call(["iconutil", "-c", "icns", ICONSET, "-o", icns])
    print(icns)
    return 0


if __name__ == "__main__":
    sys.exit(main())
