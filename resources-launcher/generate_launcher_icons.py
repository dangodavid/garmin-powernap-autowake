#!/usr/bin/env python3
"""Draw the Power Nap launcher icon at every native size the supported devices use.

Run with Python 3 + Pillow:  python3 resources-launcher/generate_launcher_icons.py

The design (navy disc, lavender crescent moon, teal ECG trace) is defined once in a
60-unit space, fitted to the original 60 px artwork, and redrawn at each size:

  * 16-bit AMOLED (54, 56, 60, 65, 70 px): drawn at 4x and downsampled with LANCZOS;
    the ECG is a 2 px stroke with its baseline snapped to whole pixels.
  * 40 px, 8-bit MIP (ARGB2222 palette, no alpha blending): palette colours only,
    binary alpha, the ECG as pixel art, so the compiler has nothing to dither.
  * 62 px, 1-bit Instinct 3 Solar (black / white / transparent): white moon and
    2 px white ECG, a black gap where they meet, a 1 px black keyline, no grey.

monkey.jungle maps each device to its folder. This script is not on any resource
path, so the resource compiler never reads it.
"""
import os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---------------------------------------------------------------------------
# Design, in a 60 x 60 unit space (fitted to the original launcher_icon.png)
# ---------------------------------------------------------------------------
NAVY = (11, 18, 34)
MOON = (210, 218, 255)
ECG = (49, 214, 164)

DISC = (30.0, 30.0, 30.0)                      # centre x, centre y, radius
MOON_OUTER = (30.2, 25.9, 14.65)               # crescent = this circle ...
MOON_CUT = (38.7, 23.95, 14.9)                 # ... minus this one
ECG_BASE_Y = 40.8
ECG_POINTS = [                                 # baseline, P, Q, R, S, T, baseline
    (8.05, ECG_BASE_Y), (21.7, ECG_BASE_Y),
    (24.5, 38.5), (28.0, 44.3), (30.1, 31.0), (32.3, 42.6), (36.1, 38.7),
    (38.4, ECG_BASE_Y), (52.25, ECG_BASE_Y),
]
ECG_WIDTH_PX = 2   # the original's 1.9-unit stroke, drawn as a crisp 2 px line at every size

SS = 4  # supersampling factor for the 16-bit icons


def _seg_d2(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    ll = dx * dx + dy * dy
    t = 0.0 if ll == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / ll))
    qx, qy = ax + t * dx - px, ay + t * dy - py
    return qx * qx + qy * qy


class Geometry:
    """The design scaled to `size` px, ECG baseline centred on a pixel boundary."""

    def __init__(self, size):
        s = size / 60.0
        self.disc = tuple(v * s for v in DISC)
        self.moon_outer = tuple(v * s for v in MOON_OUTER)
        self.moon_cut = tuple(v * s for v in MOON_CUT)
        dy = round(ECG_BASE_Y * s) - ECG_BASE_Y * s
        self.ecg = [(x * s, y * s + dy) for x, y in ECG_POINTS]
        h = ECG_WIDTH_PX / 2.0
        self.ecg_half2 = h * h
        xs, ys = [p[0] for p in self.ecg], [p[1] for p in self.ecg]
        self.ecg_box = (min(xs) - h, min(ys) - h, max(xs) + h, max(ys) + h)

    def in_disc(self, x, y):
        cx, cy, r = self.disc
        return (x - cx) ** 2 + (y - cy) ** 2 <= r * r

    def in_moon(self, x, y):
        ox, oy, orad = self.moon_outer
        cx, cy, crad = self.moon_cut
        return (x - ox) ** 2 + (y - oy) ** 2 <= orad * orad and (x - cx) ** 2 + (y - cy) ** 2 > crad * crad

    def in_ecg(self, x, y):
        x0, y0, x1, y1 = self.ecg_box
        if x < x0 or x > x1 or y < y0 or y > y1:
            return False
        pts = self.ecg
        return any(_seg_d2(x, y, pts[k][0], pts[k][1], pts[k + 1][0], pts[k + 1][1]) <= self.ecg_half2
                   for k in range(len(pts) - 1))


def coverage_map(size, test, n=8):
    """Fraction of each pixel inside `test`, from n x n samples."""
    return [[sum(1 for j in range(n) for i in range(n) if test(x + (i + 0.5) / n, y + (j + 0.5) / n)) / (n * n)
             for x in range(size)] for y in range(size)]


def brush_path(verts, brush):
    """Pixels covered by a brush x brush square stepped along each segment (pixel-art stroke)."""
    px = set()
    for (x0, y0), (x1, y1) in zip(verts, verts[1:]):
        n = max(abs(x1 - x0), abs(y1 - y0))
        for k in range(n + 1):
            t = k / n if n else 0
            bx, by = round(x0 + (x1 - x0) * t), round(y0 + (y1 - y0) * t)
            px.update((bx + dx, by + dy) for dx in range(brush) for dy in range(brush))
    return px


# ---------------------------------------------------------------------------
# 16-bit AMOLED (alpha blending supported, so the disc edge keeps soft alpha)
# ---------------------------------------------------------------------------
def render_colour(size):
    """Point-sample the design at SS x size, then LANCZOS-downsample to size."""
    g = Geometry(size)
    big = size * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    px = img.load()
    for j in range(big):
        y = (j + 0.5) / SS
        for i in range(big):
            x = (i + 0.5) / SS
            if not g.in_disc(x, y):
                continue
            if g.in_ecg(x, y):
                px[i, j] = ECG + (255,)
            elif g.in_moon(x, y):
                px[i, j] = MOON + (255,)
            else:
                px[i, j] = NAVY + (255,)
    out = img.resize((size, size), Image.LANCZOS)
    # Snap the faint LANCZOS ringing in the alpha channel (a few units around the disc edge).
    op = out.load()
    for y in range(size):
        for x in range(size):
            r, g_, b, a = op[x, y]
            if a < 8:
                op[x, y] = (0, 0, 0, 0)
            elif a > 247:
                op[x, y] = (r, g_, b, 255)
    return out


# ---------------------------------------------------------------------------
# 40 px, 8-bit MIP (ARGB2222: channel levels 00/55/AA/FF, no alpha blending)
# ---------------------------------------------------------------------------
# The original navy would quantise to black or dither, so the disc uses the
# palette's navy; the moon is white with a lavender edge ramp; the ECG is mint
# pixel art (2 px baseline, 1 px spike legs: 2 px legs merge into a blob here).
MIP_NAVY = (0x00, 0x00, 0x55)
MIP_MOON_RAMP = [(0x55, 0x55, 0xAA), (0xAA, 0xAA, 0xFF), (0xFF, 0xFF, 0xFF)]  # >= 25 / 50 / 75 % moon
MIP_ECG = (0x55, 0xFF, 0xAA)
MIP_ECG_TOP = 19
MIP_ECG_ROWS = [
    #         1111111111222222222233333
    # 234567890123456789012345678901234
    "                    EE",                 # 19  R
    "                    EE",                 # 20
    "                    EE",                 # 21
    "                    EE",                 # 22
    "                   E E",                 # 23
    "                   E  E",                # 24
    "               EEE E  EEEE",             # 25  P, T
    "    EEEEEEEEEEEEEEEE  EEEEEEEEEEEEEE",   # 26  baseline
    "    EEEEEEEEEEE   EE  E   EEEEEEEEEE",   # 27  baseline
    "                  EE  E",                # 28  Q, S
    "                  EE",                   # 29
]
MIP_MOON_CLEAR = {(x, y) for x in (20, 21) for y in range(23, 28)}  # horn tip between the spike legs


def render_mip(size=40):
    g = Geometry(size)
    disc = coverage_map(size, g.in_disc)
    moon = coverage_map(size, g.in_moon)
    ecg = {(x, MIP_ECG_TOP + j) for j, row in enumerate(MIP_ECG_ROWS) for x, ch in enumerate(row) if ch == "E"}
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    op = out.load()
    for y in range(size):
        for x in range(size):
            if disc[y][x] < 0.5:
                continue
            m = 0.0 if (x, y) in MIP_MOON_CLEAR else moon[y][x]
            if (x, y) in ecg:
                c = MIP_ECG
            elif m >= 0.25:
                c = MIP_MOON_RAMP[min(2, int(m * 4) - 1)]
            else:
                c = MIP_NAVY
            op[x, y] = c + (255,)
    return out


# ---------------------------------------------------------------------------
# 62 px, 1-bit (Instinct 3 Solar: black, white, transparent)
# ---------------------------------------------------------------------------
# White moon and a 2 px white ECG (pixel-art stroke through the scaled P, Q, R,
# S, T), a 1 px black gap where the ECG meets the moon, and a 1 px black keyline
# so the icon still reads if it is ever drawn on a white (highlighted) row.
MONO_ECG_VERTS = [(8, 41), (22, 41), (24, 39), (26, 39), (28, 45), (30, 30), (33, 43),
                  (36, 39), (37, 39), (39, 41), (52, 41)]   # top-left corner of the 2 x 2 brush


def render_mono(size=62):
    g = Geometry(size)
    moon_cov = coverage_map(size, g.in_moon)
    ecg = brush_path(MONO_ECG_VERTS, 2)
    n8 = [(dx, dy) for dx in (-1, 0, 1) for dy in (-1, 0, 1) if dx or dy]
    n4 = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    moon = {(x, y) for y in range(size) for x in range(size)
            if moon_cov[y][x] >= 0.5 and not any((x + dx, y + dy) in ecg for dx, dy in n8 + [(0, 0)])}
    # Prune the spurs the gap leaves on the lower horn (pixels with at most one neighbour).
    while True:
        spurs = {p for p in moon if sum((p[0] + dx, p[1] + dy) in moon for dx, dy in n4) <= 1}
        if not spurs:
            break
        moon -= spurs
    white = moon | ecg
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    op = out.load()
    for y in range(size):
        for x in range(size):
            if (x, y) in white:
                op[x, y] = (255, 255, 255, 255)
            elif any((x + dx, y + dy) in white for dx, dy in n8):
                op[x, y] = (0, 0, 0, 255)
    return out


def save(img, *parts):
    path = os.path.join(ROOT, *parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)
    print("wrote", os.path.relpath(path, ROOT), img.size)


if __name__ == "__main__":
    save(render_colour(60), "resources", "drawables", "launcher_icon.png")
    for s in (54, 56, 65, 70):
        save(render_colour(s), "resources-launcher", f"{s}x{s}", f"launcher_icon_{s}.png")
    save(render_mip(40), "resources-launcher", "mip-40x40", "launcher_icon_40_mip.png")
    save(render_mono(62), "resources-launcher", "mono-62x62", "launcher_icon_62_mono.png")
