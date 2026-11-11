#!/usr/bin/env python3
"""fastfetch-fx.py — layer compositor for the RaBbLE-OS fastfetch logo.

The fastfetch logo is built from layers, like image editing software:

    Layer 0  BASE       config/fastfetch/rabble-portals.base.txt  (hand-edited art)
    Layer 1  PARTICLES  dust motes scattered in empty space around the portals
    Layer 2  GLOW       one bright glint next to each ◆ diamond

This script reads the base, applies the requested layers, and writes the
composed result to config/fastfetch/rabble-portals.txt — the file fastfetch
actually displays. NEVER edit rabble-portals.txt by hand; edit the base and
re-run this script. Deploy afterwards (see RaBbLE-OS-Desktop-Fastfetch.md).

Usage:
    python3 spells/fastfetch-fx.py                      # all layers on
    python3 spells/fastfetch-fx.py --layers none        # clean base, no fx
    python3 spells/fastfetch-fx.py --layers particles   # particles only
    python3 spells/fastfetch-fx.py --layers glow        # glow only
    python3 spells/fastfetch-fx.py --seed 7             # different dust pattern

Output is deterministic for a given seed: re-running produces an identical
file, so git stays quiet unless something actually changed.

Rules baked in (do not break):
  * Colors are RaBbLE palette only (RaBbLE-Palette.md): 51 cyan, 135 violet,
    205 pink, 197 magenta, 60 muted, 97 bright white.
  * Color escapes are raw SGR params — 256-color is "38;5;N", never bare "N".
  * Effects never overwrite art and never extend the logo's max line width
    (fastfetch sizes the logo column by its widest line).
"""

import argparse
import random
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------- constants

CONFIG_DIR = Path(__file__).resolve().parent.parent / "config" / "fastfetch"
BASE_FILE = CONFIG_DIR / "rabble-portals.base.txt"
OUT_FILE = CONFIG_DIR / "rabble-portals.txt"

ESC = "\x1b["
SGR_RE = re.compile(r"\x1b\[([0-9;]*)m")

# Palette (256-color indexes from RaBbLE-Palette.md mapping)
CYAN, VIOLET, PINK, MAGENTA = "38;5;51", "38;5;135", "38;5;205", "38;5;197"
MUTED, BRIGHT = "38;5;60", "97"

# Particle layer: (glyph, color, relative weight). Mostly muted dust,
# occasional tinted mote, rare violet spark.
PARTICLE_KINDS = [
    ("·", MUTED, 5),
    ("·", CYAN, 2),
    ("·", MAGENTA, 2),
    ("✦", VIOLET, 1),
]
PARTICLE_COUNT = 12
PARTICLE_MIN_GAP = 3  # chebyshev distance between particles (sparse = classy)

# Glow layer: one glint placed in the first empty diagonal around each ◆.
GLOW_GLYPH, GLOW_COLOR = "·", BRIGHT
GLOW_OFFSETS = [(-1, -1), (-1, 1), (1, 1), (1, -1)]  # UL, UR, LR, LL

# --------------------------------------------------------------- grid model
# The art is held as a grid of cells; each cell is (char, color) where color
# is the SGR param string ("38;5;51", "97", or "" for default/space).


def parse(text):
    """ANSI text -> list of rows, each row a list of (char, color) cells."""
    grid = []
    for line in text.split("\n"):
        row, color, pos = [], "", 0
        for m in SGR_RE.finditer(line):
            for ch in line[pos : m.start()]:
                row.append((ch, color))
            params = m.group(1)
            color = "" if params in ("", "0") else params
            pos = m.end()
        for ch in line[pos:]:
            row.append((ch, color))
        grid.append(row)
    return grid


def emit(grid):
    """Grid -> ANSI text. Trailing spaces are stripped (they widen the logo)."""
    out = []
    for row in grid:
        while row and row[-1][0] == " ":
            row = row[:-1]
        line, color = "", None
        for ch, c in row:
            cell_color = "" if ch == " " else c
            if cell_color != color:
                line += f"{ESC}0m" if cell_color == "" else f"{ESC}{cell_color}m"
                color = cell_color
            line += ch
        if color:  # leave every line reset so fastfetch's info column is safe
            line += f"{ESC}0m"
        out.append(line)
    return "\n".join(out)


def cell(grid, r, c):
    if 0 <= r < len(grid) and 0 <= c < len(grid[r]):
        return grid[r][c][0]
    return " "


def empty_around(grid, r, c, dist=1):
    """True if every neighbor within `dist` is empty space."""
    return all(
        cell(grid, r + dr, c + dc) == " "
        for dr in range(-dist, dist + 1)
        for dc in range(-dist, dist + 1)
        if (dr, dc) != (0, 0)
    )

# ------------------------------------------------------------------- layers


def layer_particles(grid, rng):
    """Scatter dust motes in open space inside the portal region.

    Eligible cells: empty, not touching any art (1-cell gap), inside the
    portal block (rows 0..last dotted row), and within the canvas width so
    the logo never gets wider. Placement is rng-driven but seeded.
    """
    last_portal_row = max(
        i for i, row in enumerate(grid) if any(ch == "·" for ch, _ in row)
    )
    width = max((len(r) for r in grid), default=0)
    spots = [
        (r, c)
        for r in range(0, last_portal_row + 1)
        for c in range(1, width - 1)
        if cell(grid, r, c) == " " and empty_around(grid, r, c)
    ]
    rng.shuffle(spots)
    glyphs = [k for g, col, w in PARTICLE_KINDS for k in [(g, col)] * w]
    placed = []
    for r, c in spots:
        if len(placed) >= PARTICLE_COUNT:
            break
        if any(max(abs(r - pr), abs(c - pc)) < PARTICLE_MIN_GAP for pr, pc in placed):
            continue
        while len(grid[r]) <= c:  # pad short rows out to the target column
            grid[r].append((" ", ""))
        grid[r][c] = rng.choice(glyphs)
        placed.append((r, c))


def layer_glow(grid, rng):
    """Put one bright glint beside every ◆ diamond (first free diagonal)."""
    diamonds = [
        (r, c)
        for r, row in enumerate(grid)
        for c, (ch, _) in enumerate(row)
        if ch == "◆"
    ]
    for r, c in diamonds:
        for dr, dc in GLOW_OFFSETS:
            gr, gc = r + dr, c + dc
            if gr < 0 or gr >= len(grid) or gc < 1:
                continue
            if cell(grid, gr, gc) == " ":
                while len(grid[gr]) <= gc:
                    grid[gr].append((" ", ""))
                grid[gr][gc] = (GLOW_GLYPH, GLOW_COLOR)
                break

# --------------------------------------------------------------------- main

LAYERS = {"particles": layer_particles, "glow": layer_glow}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument(
        "--layers",
        default="particles,glow",
        help="comma list of layers to apply, or 'none' (default: particles,glow)",
    )
    ap.add_argument("--seed", type=int, default=1, help="rng seed (default: 1)")
    ap.add_argument("--base", type=Path, default=BASE_FILE)
    ap.add_argument("--out", type=Path, default=OUT_FILE)
    args = ap.parse_args()

    wanted = [] if args.layers == "none" else args.layers.split(",")
    unknown = [w for w in wanted if w not in LAYERS]
    if unknown:
        sys.exit(f"unknown layer(s): {', '.join(unknown)} — have: {', '.join(LAYERS)}")

    grid = parse(args.base.read_text())
    rng = random.Random(args.seed)
    for name in wanted:
        LAYERS[name](grid, rng)

    args.out.write_text(emit(grid))
    on = ", ".join(wanted) if wanted else "none (clean base)"
    print(f"composed {args.out.name}  [layers: {on}]  seed={args.seed}")


if __name__ == "__main__":
    main()
