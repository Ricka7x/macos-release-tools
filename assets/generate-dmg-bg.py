#!/usr/bin/env python3
"""
Generate Snapback DMG background image.
Output: dmg-background.png (1320x800 @2x Retina, displays at 660x400)

Requires: pip install Pillow
"""

import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

OUT = Path(__file__).parent / "dmg-background.png"

# Canvas @ 1x: 840x524 (window size + padding to avoid white edges)
W, H = 660, 480

# Icon positions match dmg-settings.py:
#   Snapback.app  → (170, 210)
#   Applications  → (490, 210)


def lerp(a, b, t):
    return a + (b - a) * t


def lerp_color(c1, c2, t):
    return tuple(int(lerp(c1[i], c2[i], t)) for i in range(3))


def cubic_bezier(p0, p1, p2, p3, t):
    mt = 1 - t
    x = mt**3*p0[0] + 3*mt**2*t*p1[0] + 3*mt*t**2*p2[0] + t**3*p3[0]
    y = mt**3*p0[1] + 3*mt**2*t*p1[1] + 3*mt*t**2*p2[1] + t**3*p3[1]
    return (x, y)


# ── Background gradient ───────────────────────────────────────────────────────
img = Image.new("RGBA", (W, H))
px = img.load()
top    = (235, 243, 255, 255)
bottom = (215, 230, 255, 255)
for y in range(H):
    c = lerp_color(top, bottom, y / H) + (255,)
    for x in range(W):
        px[x, y] = c

# ── Topographic rings ─────────────────────────────────────────────────────────
ring_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
rd = ImageDraw.Draw(ring_layer)
cx, cy = W // 2, int(H * 0.52)
for i in range(12):
    r = 28 + i * 28
    alpha = max(6, 48 - i * 3)
    rx, ry = r, int(r * 0.68)
    rd.ellipse([cx-rx, cy-ry, cx+rx, cy+ry],
               outline=(150, 185, 235, alpha), width=1)

img = Image.alpha_composite(img, ring_layer)

# ── Smooth gradient arrow via circle-stamping ─────────────────────────────────
# Arrow from just right of app icon to just left of Applications folder.
# Both icon labels sit below the icon, so aim at the icon visual center ~y=400.
start = (245, 210)
end   = (415, 210)
cp1   = (285, 110)
cp2   = (375, 110)

N = 400
pts = [cubic_bezier(start, cp1, cp2, end, i / N) for i in range(N + 1)]

blue   = (59,  130, 246)
orange = (249, 115,  22)

arrow_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
ad = ImageDraw.Draw(arrow_layer)

R = 4   # circle radius = half stroke width

for i, pt in enumerate(pts):
    t = i / len(pts)
    color = lerp_color(blue, orange, t)
    x, y = int(pt[0]), int(pt[1])
    ad.ellipse([x-R, y-R, x+R, y+R], fill=(*color, 210))

# Arrowhead
dx = pts[-1][0] - pts[-3][0]
dy = pts[-1][1] - pts[-3][1]
length = math.hypot(dx, dy) or 1
dx, dy = dx / length, dy / length
px_, py_ = -dy, dx

HEAD = 18
HALF = 10
tip   = (int(end[0] + dx * HEAD),  int(end[1] + dy * HEAD))
base1 = (int(end[0] + px_ * HALF), int(end[1] + py_ * HALF))
base2 = (int(end[0] - px_ * HALF), int(end[1] - py_ * HALF))
ad.polygon([tip, base1, base2], fill=(*orange, 230))

# Slight blur to anti-alias the circle stamps
arrow_layer = arrow_layer.filter(ImageFilter.GaussianBlur(1.2))

img = Image.alpha_composite(img, arrow_layer)

# ── Save ──────────────────────────────────────────────────────────────────────
img = img.convert("RGB")
img.save(OUT, "PNG")
print(f"Saved → {OUT}  ({W}x{H})")
