#!/usr/bin/env python3
"""
rabble_logo_gen.py — RaBbLE ANSI logo generator
Display with: cat rabble_logo.ansi

Tuning knobs:
  half_h    — diamond height (rows, half)
  half_w    — diamond width (cols, half)
  gap_cols  — space between the two diamonds
  portal_rx — portal horizontal radius
  portal_ry — portal vertical radius (keep small for flat ring)
  gap       — rows of clear space between diamond tip and portal ring
  exponent  — tip rounding (lower = rounder, 1.0 = pure sine/pointy)
"""
import math

MAGENTA = "\033[38;5;197m"
CYAN    = "\033[38;5;51m"
WHITE   = "\033[97m"
RESET   = "\033[0m"

COLS = 110
ROWS = 64

canvas = [[" "] * COLS for _ in range(ROWS)]
colors  = [[RESET]   * COLS for _ in range(ROWS)]

def plot(r, c, ch, col):
    if 0 <= r < ROWS and 0 <= c < COLS:
        canvas[r][c] = ch
        colors[r][c] = col

def draw_diamond(cx, cy, half_w, half_h, color, exponent=0.52):
    """Elliptical diamond. exponent < 1.0 rounds the tips."""
    n = half_h * 2 + 1
    for i in range(n):
        t = i / (n - 1)
        sin_val = math.sin(t * math.pi)
        w = int(round(half_w * (sin_val ** exponent)))
        r = cy - half_h + i
        lft = cx - w
        rgt = cx + w
        if w == 0:
            plot(r, cx, "◆", color)
            continue
        plot(r, lft, "║", color)
        plot(r, rgt, "║", color)
        for c in range(lft + 1, rgt):
            plot(r, c, "█", WHITE)

def draw_portal(cx, cy, rx, ry, color):
    steps = rx * 16
    for i in range(steps):
        a = 2 * math.pi * i / steps
        c = int(round(cx + (rx+3) * math.cos(a)))
        r = int(round(cy + (ry+1) * math.sin(a)))
        plot(r, c, "·", color)
    for i in range(steps):
        a = 2 * math.pi * i / steps
        c = int(round(cx + rx * math.cos(a)))
        r = int(round(cy + ry * math.sin(a)))
        plot(r, c, "#", color)
    irx, iry = int(rx * 0.60), max(1, int(ry * 0.45))
    for i in range(steps):
        a = 2 * math.pi * i / steps
        c = int(round(cx + irx * math.cos(a)))
        r = int(round(cy + iry * math.sin(a)))
        plot(r, c, "-", color)

# ── Layout ────────────────────────────────────────────────────
half_h   = 18
half_w   = 16
gap_cols = 6
gap      = -4   # rows clear between diamond tip and portal ring edge

total_cols  = half_w * 2 + 1 + gap_cols + half_w * 2 + 1
left_offset = (COLS - total_cols) // 2

m_cx = left_offset + half_w
c_cx = m_cx + half_w + gap_cols + half_w + 1
cy   = ROWS // 2

portal_rx = half_w + 4
portal_ry = 3

c_portal_cy = cy - half_h - portal_ry - gap   # above cyan, clear of tip
m_portal_cy = cy + half_h + portal_ry + gap   # below magenta, clear of tip

draw_portal(c_cx, c_portal_cy, portal_rx, portal_ry, CYAN)
draw_portal(m_cx, m_portal_cy, portal_rx, portal_ry, MAGENTA)
draw_diamond(m_cx, cy, half_w, half_h, MAGENTA)
draw_diamond(c_cx, cy, half_w, half_h, CYAN)

# ── Render ────────────────────────────────────────────────────
output_lines = []
for r in range(ROWS):
    line = ""
    cur  = ""
    for c in range(COLS):
        co = colors[r][c]
        ch = canvas[r][c]
        if co != cur:
            line += co
            cur   = co
        line += ch
    line += RESET
    output_lines.append(line.rstrip())

while output_lines and output_lines[0].replace(RESET,"").strip()  == "": output_lines.pop(0)
while output_lines and output_lines[-1].replace(RESET,"").strip() == "": output_lines.pop()

out = "\n".join(output_lines) + "\n"

with open("rabble_logo.ansi", "w") as f:
    f.write(out)

print(out)
print("=== saved to rabble_logo.ansi ===")
