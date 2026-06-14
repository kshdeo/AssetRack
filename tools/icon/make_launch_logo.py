#!/usr/bin/env python3
"""
Generate the launch-screen logo.

This is the app icon's neon donut on a TRANSPARENT background, so it sits
cleanly on the LaunchScreen storyboard's dark navy. It reuses
`make_icon.make_donut()` so the launch logo can never drift from the app icon —
re-run both scripts together after any palette/geometry change.

Writes `AssetRack/Assets.xcassets/LaunchLogo.imageset/LaunchLogo.png` in place.

Requires Pillow (`pip3 install Pillow`).
"""

import os
from PIL import Image
import make_icon

OUT_SIZE = 512                 # plenty for a launch-screen glyph

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_PATH = os.path.join(
    REPO_ROOT, "AssetRack", "Assets.xcassets", "LaunchLogo.imageset", "LaunchLogo.png"
)


def main():
    donut = make_icon.make_donut()                      # transparent, CANVAS-sized
    donut = donut.resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS)
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    donut.save(OUT_PATH, "PNG")
    print(f"wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
