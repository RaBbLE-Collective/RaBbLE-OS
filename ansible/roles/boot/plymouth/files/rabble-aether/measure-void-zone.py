#!/usr/bin/env python3
# measure-void-zone.py — find ceiling/floor grid pixel extents in bg-liminal.png
#
# Run BEFORE committing y-values to rabble-aether.script. The estimated constants
# (0.28 / 0.63 / 0.58) were derived from the NeBuLA floor-grid VP at H*0.74.
# This script measures the actual rendered image.
#
# Prereq:  pip install Pillow
#
# Usage (from rabble-aether/ directory):
#   python3 measure-void-zone.py
#   python3 measure-void-zone.py /path/to/bg-liminal.png

import sys
from PIL import Image

IMG = sys.argv[1] if len(sys.argv) > 1 else "assets/bg-liminal.png"
img = Image.open(IMG).convert("RGB")
w, h = img.size
print(f"Image: {w}×{h}")

# RaBbLE void color: #0a0010 = (10, 0, 16)
VOID = (10, 0, 16)
THRESHOLD = 30  # deviation from void to count as 'has grid'

def is_grid_row(y):
    xs = [int(w * (i / 8)) for i in range(1, 8)] + [10, w - 10]
    samples = [img.getpixel((x, y)) for x in xs if 0 <= x < w]
    return any(max(abs(px[c] - VOID[c]) for c in range(3)) > THRESHOLD for px in samples)

# Scan top-down: last grid row in top half = ceiling end
ceiling_end = 0
for y in range(h // 2):
    if is_grid_row(y):
        ceiling_end = y

# Scan bottom-up: first grid row in bottom half = floor start
floor_start = h
for y in range(h - 1, h // 2, -1):
    if is_grid_row(y):
        floor_start = y
        break

c_pct = ceiling_end / h
f_pct = floor_start / h
print(f"\nCeiling grid ends at: y={ceiling_end} ({c_pct*100:.1f}%)")
print(f"Floor grid starts at: y={floor_start} ({f_pct*100:.1f}%)")
print(f"Void zone: {c_pct*100:.1f}% – {f_pct*100:.1f}%")
print(f"\nRecommended rabble-aether.script constants (6–11% safety margins):")
print(f"  wm_y           = screen_h * {c_pct + 0.06:.3f}  # 6% below ceiling grid")
print(f"  log_baseline_y = screen_h * {f_pct - 0.09:.3f}  # 9% above floor grid")
print(f"  ready_sprite_y = screen_h * {f_pct - 0.14:.3f}  # 14% above floor grid")
print(f"\nCurrent values in rabble-aether.script: 0.28 / 0.63 / 0.58 (estimates)")
print(f"Update if the measured values differ significantly (>3%).")
