"""Draws the VENWhispr app icon: a rounded "VW" with a red recording dot on a black macOS tile.

Usage, from the repo root:  python3 Resources/make_icon.py
Writes Resources/AppIcon-1024.png and Resources/AppIcon.icns (needs Pillow: pip3 install pillow).
"""
import os
import shutil
import subprocess
import tempfile
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
K = 4                                   # supersampling for smooth edges
S, INSET, RADIUS = 1024, 100, 185       # Apple's macOS icon grid
T = S - 2 * INSET
TT = T * K
WHITE = (255, 255, 255, 255)
RED = (255, 59, 48, 255)                # system red, like the recording light


def art():
    im = Image.new("RGBA", (TT, TT), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    f = ImageFont.truetype("/System/Library/Fonts/SFNSRounded.ttf", 330 * K)
    f.set_variation_by_axes([400, 800])  # grade, weight (heavy)

    # Letters kerned 36 px into each other, the pair centred slightly left to balance the dot.
    boxes = [f.getbbox(ch) for ch in "VW"]
    widths = [b[2] - b[0] for b in boxes]
    overlap = 36 * K
    top, bottom = min(b[1] for b in boxes), max(b[3] for b in boxes)
    x = (T / 2 - 34) * K - (sum(widths) - overlap) / 2
    y = TT / 2 - (bottom - top) / 2 - top
    for ch, b, w in zip("VW", boxes, widths):
        d.text((x - b[0], y), ch, font=f, fill=WHITE)
        x += w - overlap
    # The red dot sits on the baseline just after the W, like a full stop.
    r, cy, left = 30, T / 2 + 96, x / K + 22
    d.ellipse((left * K, (cy - r) * K, (left + 2 * r) * K, (cy + r) * K), fill=RED)
    return im


def icon():
    mask = Image.new("L", (TT, TT), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, TT - 1, TT - 1), RADIUS * K, fill=255)
    tile = Image.new("RGBA", (TT, TT), (0, 0, 0, 255))
    tile.alpha_composite(art())
    # Hairline edge so the black tile doesn't melt into dark Docks and backgrounds.
    edge = Image.new("RGBA", (TT, TT), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle((0, 0, TT - 1, TT - 1), RADIUS * K, outline=(255, 255, 255, 46), width=2 * K)
    tile.alpha_composite(edge)
    tile.putalpha(mask)
    tile = tile.resize((T, T), Image.LANCZOS)

    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 110), (INSET, INSET + 12), mask.resize((T, T), Image.LANCZOS))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(14)))
    canvas.alpha_composite(tile, (INSET, INSET))
    return canvas


def main():
    big = icon()
    big.save(os.path.join(HERE, "AppIcon-1024.png"))
    work = tempfile.mkdtemp()
    try:
        iconset = os.path.join(work, "AppIcon.iconset")
        os.mkdir(iconset)
        for size in (16, 32, 128, 256, 512):
            big.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
            big.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(HERE, "AppIcon.icns")], check=True)
    finally:
        shutil.rmtree(work)
    print("Wrote Resources/AppIcon-1024.png and Resources/AppIcon.icns")


if __name__ == "__main__":
    main()
