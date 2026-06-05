#!/usr/bin/env python3
"""
Preview the app icon as it will appear on the home screen — with iOS's
rounded-corner mask and a dark backdrop. Run after editing `make_icon.py`
to see the result before committing.

Writes `tools/icon/preview.png` next to this script.
"""

from PIL import Image, ImageDraw
import os
import sys

HERE      = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ICON_PATH = os.path.join(
    REPO_ROOT, "AssetRack", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png"
)

TILE         = 320                  # rendered size for the preview
CORNER_F     = 0.225                # iOS-ish corner radius (fraction of tile)
BG_COL       = (28, 28, 30)
PAD          = 40


def main(icon_path: str, out_path: str):
    src = Image.open(icon_path).convert("RGB").resize((TILE, TILE), Image.LANCZOS)

    mask = Image.new("L", (TILE, TILE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, TILE - 1, TILE - 1],
        radius=int(TILE * CORNER_F),
        fill=255,
    )

    canvas = Image.new("RGB", (TILE + PAD * 2, TILE + PAD * 2), BG_COL)
    canvas.paste(src, (PAD, PAD), mask)
    canvas.save(out_path, "PNG")
    print(f"wrote {out_path}")


if __name__ == "__main__":
    icon_in = sys.argv[1] if len(sys.argv) > 1 else ICON_PATH
    main(icon_in, os.path.join(HERE, "preview.png"))
