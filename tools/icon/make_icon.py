#!/usr/bin/env python3
"""
Generate the AssetRack app icon.

The shipped icon is a four-segment donut (matching the dashboard's category
colours — cash & bank · investments · pension · real estate) on a quiet dark
navy background with subtle glows in each corner. The corner glows use the
donut palette so the whole image hangs together as one piece of art.

The donut and the corner glows are both configurable below. Re-running this
script overwrites `AssetRack/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
in place.

Requires Pillow (`pip3 install Pillow`).
"""

from PIL import Image, ImageDraw
import math
import os
import sys

# ── Output ───────────────────────────────────────────────────────────────────
OUT_SIZE = 1024                # final PNG size (Apple's required marketing size)
SUPER    = 4                   # supersample factor for anti-aliasing
CANVAS   = OUT_SIZE * SUPER

# ── Donut geometry ───────────────────────────────────────────────────────────
OUTER_F = 0.38                 # outer radius as fraction of canvas
INNER_F = 0.21                 # inner radius (hole)
GAP_DEG = 3                    # angular gap between segments
PROPS   = [0.25] * 4           # equal quarters
START_DEG = -90                # 12 o'clock

# ── Palette ──────────────────────────────────────────────────────────────────
# Neon-full — electric versions of the dashboard's teal/blue/purple/indigo.
CYAN, BLUE, PINK, VIOL = (
    (0x00, 0xF5, 0xFF),
    (0x1E, 0x90, 0xFF),
    (0xE5, 0x40, 0xFF),
    (0x8A, 0x2B, 0xFF),
)
DONUT_COLOURS = [CYAN, BLUE, PINK, VIOL]

# Dark navy base — quiet, lets the donut glow.
BG_BASE = (0x0E, 0x14, 0x28)

# Corner glows. Each entry is (x_fraction, y_fraction, rgb). Glows have a
# quadratic falloff (see CORNER_RADIUS_F) and the brightest source wins per
# pixel so overlapping glows don't blow out.
CORNER_GLOWS = [
    (0.0, 0.0, BLUE),          # top-left      → blue
    (1.0, 0.0, BLUE),          # top-right     → blue
    (0.0, 1.0, VIOL),          # bottom-left   → violet
    (1.0, 1.0, VIOL),          # bottom-right  → violet
]
CORNER_RADIUS_F = 0.45         # how far a glow reaches, as fraction of canvas
CORNER_INTENSITY = 0.5         # 0–1, peak strength of the glow at the corner

# ── Output path ──────────────────────────────────────────────────────────────
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ICON_PATH = os.path.join(
    REPO_ROOT, "AssetRack", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png"
)


# ── Rendering ────────────────────────────────────────────────────────────────
def _lerp(a, b, t):
    return (
        int(a[0] + (b[0] - a[0]) * t),
        int(a[1] + (b[1] - a[1]) * t),
        int(a[2] + (b[2] - a[2]) * t),
    )


def make_background():
    """Dark navy + quadratic-falloff glows at each configured corner."""
    img = Image.new("RGB", (CANVAS, CANVAS), BG_BASE)
    px = img.load()
    glow_r = CANVAS * CORNER_RADIUS_F

    sources = [(cx_f * CANVAS, cy_f * CANVAS, rgb)
               for cx_f, cy_f, rgb in CORNER_GLOWS]

    for y in range(CANVAS):
        for x in range(CANVAS):
            best_t = 0.0
            best_colour = BG_BASE
            for cx, cy, rgb in sources:
                dist = math.hypot(x - cx, y - cy)
                t = max(0.0, 1 - dist / glow_r) ** 2 * CORNER_INTENSITY
                if t > best_t:
                    best_t = t
                    best_colour = _lerp(BG_BASE, rgb, t)
            px[x, y] = best_colour
    return img


def make_donut():
    """Donut on a transparent canvas with the hole already cut."""
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    cx = cy = CANVAS // 2
    outer_r  = int(CANVAS * OUTER_F)
    inner_r  = int(CANVAS * INNER_F)
    center_r = (outer_r + inner_r) / 2
    cap_r    = (outer_r - inner_r) / 2

    outer_box = [cx - outer_r, cy - outer_r, cx + outer_r, cy + outer_r]
    inner_box = [cx - inner_r, cy - inner_r, cx + inner_r, cy + inner_r]

    angle = START_DEG
    for prop, colour in zip(PROPS, DONUT_COLOURS):
        seg_deg = prop * 360
        start = angle + GAP_DEG / 2
        end   = angle + seg_deg - GAP_DEG / 2
        fill = colour + (255,)
        d.pieslice(outer_box, start=start, end=end, fill=fill)
        for cap_angle in (start, end):
            theta = math.radians(cap_angle)
            x = cx + center_r * math.cos(theta)
            y = cy + center_r * math.sin(theta)
            d.ellipse([x - cap_r, y - cap_r, x + cap_r, y + cap_r], fill=fill)
        angle += seg_deg

    # Ring-shaped alpha mask — outer disk filled, inner disk empty.
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    md = ImageDraw.Draw(mask)
    md.ellipse(outer_box, fill=255)
    md.ellipse(inner_box, fill=0)
    layer.putalpha(mask)
    return layer


def main(out_path: str):
    bg = make_background()
    donut = make_donut()
    bg.paste(donut, (0, 0), donut)
    bg = bg.resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS)
    bg.save(out_path, "PNG")
    print(f"wrote {out_path}")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else ICON_PATH
    main(out)
