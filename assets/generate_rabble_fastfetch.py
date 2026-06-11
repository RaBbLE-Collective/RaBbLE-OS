#!/usr/bin/env python3
"""
generate_rabble_fastfetch.py — RaBbLE-OS fastfetch logo generator
Produces: config/fastfetch/rabble-portals.txt

Design:
  - Dual portals: LEFT=cyan (ring above), RIGHT=magenta (ring below)
  - Violet accent inner ring on both portals
  - "RaBbLE" in banner font (proper mixed case): R=white, a=violet, B=magenta, b=magenta, L=cyan, E=cyan
  - Palette separator line (all five neon colors)
  - "Episode 1 Preview" tagline in violet
  - "Low Entropy. Infinite Resonance." in dim

Run from the RaBbLE-OS repo root:
  python3 assets/generate_rabble_fastfetch.py
"""
import math, re, sys
import pyfiglet

# ── Palette (RaBbLE Synthwave Outrun) ─────────────────────────────────
CY = "\033[38;5;51m"    # Electric Cyan    #00f5ff
MG = "\033[38;5;197m"   # Hot Magenta      #ff2d78
VT = "\033[38;5;135m"   # Soft Violet      #bf5fff
PK = "\033[38;5;205m"   # Outrun Pink      #ff79c6
WH = "\033[97m"          # Bright White
DM = "\033[38;5;60m"    # Muted/Dim        #2a2840
RS = "\033[0m"           # Reset

# ── Portal canvas ─────────────────────────────────────────────────────
COLS, ROWS = 52, 18
canvas = [[" "] * COLS for _ in range(ROWS)]
colors  = [[RS]   * COLS for _ in range(ROWS)]

def plot(r, c, ch, col):
    if 0 <= r < ROWS and 0 <= c < COLS:
        canvas[r][c] = ch
        colors[r][c]  = col

def draw_portal(cx, cy, rx, ry, color, inner_col):
    """Flat orbital ring: outer halo dots, main ring, inner ring (violet accent)."""
    steps = rx * 16
    for i in range(steps):
        a = 2 * math.pi * i / steps
        plot(int(round(cy+(ry+1)*math.sin(a))), int(round(cx+(rx+2)*math.cos(a))), "·", color)
    for i in range(steps):
        a = 2 * math.pi * i / steps
        plot(int(round(cy+ry*math.sin(a))), int(round(cx+rx*math.cos(a))), "#", color)
    irx, iry = int(rx*0.6), max(1, int(ry*0.45))
    for i in range(steps):
        a = 2 * math.pi * i / steps
        plot(int(round(cy+iry*math.sin(a))), int(round(cx+irx*math.cos(a))), "-", inner_col)

def draw_diamond(cx, cy, hw, hh, color, exp=0.52):
    """Rounded vertical ellipse (orb body) with white fill."""
    n = hh * 2 + 1
    for i in range(n):
        w = int(round(hw * (math.sin(i/(n-1)*math.pi) ** exp)))
        r = cy - hh + i
        if w == 0:
            plot(r, cx, "◆", color)
            continue
        plot(r, cx-w, "║", color)
        plot(r, cx+w, "║", color)
        for c in range(cx-w+1, cx+w):
            plot(r, c, "█", WH)

# ── Layout: LEFT=CYAN, RIGHT=MAGENTA ─────────────────────────────────
hw, hh   = 4, 6
gap_cols = 4
gap_ring = -2   # overlap rows between orb tip and portal ring

total_w  = hw*2+1 + gap_cols + hw*2+1
lo       = (COLS - total_w) // 2

cy_cx    = lo + hw
mg_cx    = cy_cx + hw + gap_cols + hw + 1
mid_y    = ROWS // 2

prx, pry = hw+3, 2
cy_ring_y = mid_y - hh - pry - gap_ring  # cyan ring ABOVE diamond
mg_ring_y = mid_y + hh + pry + gap_ring  # magenta ring BELOW diamond

draw_portal(cy_cx, cy_ring_y, prx, pry, CY, VT)
draw_portal(mg_cx, mg_ring_y, prx, pry, MG, VT)
draw_diamond(cy_cx, mid_y, hw, hh, CY)
draw_diamond(mg_cx, mid_y, hw, hh, MG)

# ── Render portal section ─────────────────────────────────────────────
strip = lambda s: re.sub(r'\033\[[0-9;]*m', '', s)

portal_lines = []
for r in range(ROWS):
    line, cur = "", ""
    for c in range(COLS):
        co, ch = colors[r][c], canvas[r][c]
        if co != cur:
            line += co; cur = co
        line += ch
    portal_lines.append((line + RS).rstrip())

while portal_lines and not strip(portal_lines[0]).strip():  portal_lines.pop(0)
while portal_lines and not strip(portal_lines[-1]).strip(): portal_lines.pop()

# ── "RaBbLE" block text (banner font — proper mixed case, # → █) ─────
# banner font: uppercase = 7 rows, lowercase = 6 rows (1 blank top row)
# This gives visually distinct mixed case: RaBbLE reads as mixed, not RABBLE
LETTER_COL = {'R': WH, 'a': VT, 'B': MG, 'b': MG, 'L': CY, 'E': CY}

def get_art(ch):
    raw = pyfiglet.figlet_format(ch, font='banner').replace('#', '█')
    lines = raw.rstrip().split('\n')
    while lines and not lines[-1].strip():
        lines.pop()
    w = max(len(l) for l in lines)
    return [l.ljust(w + 1) for l in lines]  # +1 letter gap

arts = {ch: get_art(ch) for ch in 'RaBbLE'}
text_h = max(len(v) for v in arts.values())

text_rows = []
for ri in range(text_h):
    row = []
    for ch in 'RaBbLE':
        lines  = arts[ch]
        pad    = text_h - len(lines)
        if ri < pad:
            row.append(LETTER_COL[ch] + ' ' * len(lines[0]) + RS)
        else:
            row.append(LETTER_COL[ch] + lines[ri - pad] + RS)
    text_rows.append(''.join(row))

# Center text under portals
text_w   = max(len(strip(r)) for r in text_rows)
portal_w = max(len(strip(l)) for l in portal_lines)
indent   = max(0, (portal_w - text_w) // 2)
text_rows = [' ' * indent + r for r in text_rows]

# ── Separator + taglines (centered) ───────────────────────────────────
full_w = max(portal_w, text_w + indent)

def center(s, width):
    return ' ' * max(0, (width - len(strip(s))) // 2) + s

sep = center(f"{WH}━━{RS}{MG}━━━━━{RS}{PK}━━━{RS}{VT}━━━{RS}{CY}━━━━━{RS}{WH}━━{RS}", full_w)
ep1 = center(f"{VT}Episode 1 Preview{RS}", full_w)
ler = center(f"{DM}Low Entropy.  Infinite Resonance.{RS}", full_w)

# ── Final output ──────────────────────────────────────────────────────
output = (
    '\n'.join(portal_lines) + '\n'
    + '\n'.join(text_rows)  + '\n'
    + sep + '\n'
    + ep1 + '\n'
    + ler + '\n\n'
)

out_path = 'config/fastfetch/rabble-portals.txt'
with open(out_path, 'w') as f:
    f.write(output)

plain = [strip(l) for l in output.split('\n')]
print(f"Saved {out_path} — {len(plain)} lines, max width {max(len(l) for l in plain)}")
print("Deploy: cp config/fastfetch/rabble-portals.txt ~/.config/fastfetch/rabble-portals.txt")
