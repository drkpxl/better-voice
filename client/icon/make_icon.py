#!/usr/bin/env python3
"""Generate AppIcon.icns for Better Voice: flat deep-purple (#5847d6) rounded square
with the brand's white 5-bar waveform (site height ratios 6/13/9/16/7).

Run with a Python that has Pillow, e.g. the pyannote venv:
    tools/pyannote/.venv/bin/python client/icon/make_icon.py
Produces client/icon/AppIcon.icns (via sips + iconutil, macOS-only). Commit the .icns
so the build doesn't need Python."""

import os
import shutil
import subprocess

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
MASTER = os.path.join(HERE, "icon_1024.png")
ICONSET = os.path.join(HERE, "AppIcon.iconset")
ICNS = os.path.join(HERE, "AppIcon.icns")

SIZE = 1024
PURPLE = (0x58, 0x47, 0xD6, 255)   # #5847d6, --v-deep; white waveform on it = 6.4:1
CORNER = 230                        # ~0.2237 * 1024, Apple continuous-corner approximation
HEIGHTS = [6, 13, 9, 16, 7]         # brand waveform ratios


def draw_master() -> Image.Image:
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=CORNER, fill=PURPLE)

    bar_w = 70
    gap = 46
    max_h = 470  # tallest bar (ratio 16)
    total_w = len(HEIGHTS) * bar_w + (len(HEIGHTS) - 1) * gap
    x = (SIZE - total_w) / 2
    mid = SIZE / 2
    for ratio in HEIGHTS:
        h = ratio / max(HEIGHTS) * max_h
        d.rounded_rectangle(
            [x, mid - h / 2, x + bar_w, mid + h / 2],
            radius=bar_w / 2,
            fill=(255, 255, 255, 255),
        )
        x += bar_w + gap
    return img


def build_icns(master: Image.Image) -> None:
    master.save(MASTER)
    if os.path.isdir(ICONSET):
        shutil.rmtree(ICONSET)
    os.makedirs(ICONSET, exist_ok=True)
    # (size, @2x?) -> iconset filename convention iconutil expects
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            master.resize((px, px), Image.LANCZOS).save(os.path.join(ICONSET, name))
    subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", ICNS], check=True)
    shutil.rmtree(ICONSET)
    os.remove(MASTER)
    print("wrote", ICNS)


if __name__ == "__main__":
    build_icns(draw_master())
