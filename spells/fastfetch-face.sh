#!/usr/bin/env bash
# fastfetch-face.sh — regenerate the fastfetch logos from nebula_glyph (the mark's master).
#   rabble-portals.txt          default: the face at distro-logo size (38x18), one-line block wordmark "RaBbLE-OS" beneath, palette gradient
#   rabble-portals.compact.txt  the TUI header face (24x6) + "RaBbLE OS" label
#   rabble-portals.micro.txt    the 10x3 micro mark + label
# Output is checked in so OS installs need no Rust build. The old hand-drawn logo
# (rabble-portals.base.txt + spells/fastfetch-fx.py) is legacy; only its wordmark rows are reused here.
# RABBLE_CELL_ASPECT = terminal cell height / width (default 2.3, measured on Mark's kitty); it makes the sphere round.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tui=$here/../RaBbLE-sCoRE/tui
out=$here/config/fastfetch
aspect=${RABBLE_CELL_ASPECT:-2.3}
(cd "$tui" && cargo build -q --release --offline -p nebula_glyph --example export)
exe=$tui/target/release/examples/export
"$exe" micro "label=RaBbLE-OS" > "$out/rabble-portals.micro.txt"
python3 - "$exe" "$aspect" "$out" <<'PY'
import subprocess, sys
exe, aspect, out = sys.argv[1:]
face = subprocess.run([exe, "38x18", f"aspect={aspect}"], capture_output=True, text=True, check=True).stdout.rstrip("\n").split("\n")
base = open(f"{out}/rabble-portals.base.txt", encoding="utf-8").read().split("\n")
import re
word = [re.sub(r"\x1b\[[0-9;]*m", "", l).replace("◆", " ").rstrip().ljust(34) for l in base[20:24]]  # RaBbLE, plain
# "OS" in the same block letters, set on the same rows with a hyphen: one line, "RaBbLE-OS"
O = ["█▀▀▀█", "█   █", "█   █", "█▄▄▄█"]
S = ["█▀▀▀▀", "█▄▄▄ ", "    █", "▄▄▄▄█"]
H = ["     ", " ▄▄▄ ", " ▀▀▀ ", "     "]  # the hyphen: a one-cell bar at mid height
line = [w + h + o + " " + s for w, h, o, s in zip(word, H, O, S)]
width = max(len(l) for l in line)
# palette ramp (RaBbLE-Palette.md): cyan -> violet -> pink -> magenta, truecolor, by column
ramp = [(0, 245, 255), (191, 95, 255), (255, 121, 198), (255, 45, 120)]
def col(x):
    t = x / max(width - 1, 1) * (len(ramp) - 1)
    i = min(int(t), len(ramp) - 2)
    f = t - i
    return tuple(round(a + (b - a) * f) for a, b in zip(ramp[i], ramp[i + 1]))
def paint(l):
    o = ""
    for x, ch in enumerate(l):
        o += ch if ch == " " else "\x1b[38;2;%d;%d;%dm%s" % (*col(x), ch)
    return o + "\x1b[0m"
pad = " " * max((width - 38) // 2, 0)  # centre the face over the wordmark
face = [pad + f if f.strip() else f for f in face]
open(f"{out}/rabble-portals.txt", "w", encoding="utf-8").write("\n".join(face + [""] + [paint(" " + l) for l in line]) + "\n")

# compact: the mini face over a 3-row wordmark (3x5 pixel letters, half-block cells), same ramp
G = {
 "R": ["##.", "#.#", "##.", "#.#", "#.#"],
 "a": ["...", "###", "#.#", "###", "#.#"],
 "B": ["##.", "#.#", "##.", "#.#", "##."],
 "b": ["#..", "#..", "##.", "#.#", "##."],
 "L": ["#..", "#..", "#..", "#..", "###"],
 "E": ["###", "#..", "##.", "#..", "###"],
 "-": ["...", "...", "###", "...", "..."],
 "O": ["###", "#.#", "#.#", "#.#", "###"],
 "S": ["###", "#..", "###", "..#", "###"],
}
text = "RaBbLE-OS"
px = [" ".join(G[c][r] for c in text) for r in range(5)] + ["." * (len(text) * 4 - 1)]
cells = []
for r in (0, 2, 4):
    row = ""
    for x in range(len(px[0])):
        up, lo = px[r][x] == "#", px[r + 1][x] == "#"
        row += "█" if up and lo else "▀" if up else "▄" if lo else " "
    cells.append(row)
width = len(cells[0])
mini = subprocess.run([exe, "mini"], capture_output=True, text=True, check=True).stdout.rstrip("\n").split("\n")
mpad = " " * max((width - 24) // 2, 0)
mini = [mpad + m if m.strip() else m for m in mini]
open(f"{out}/rabble-portals.compact.txt", "w", encoding="utf-8").write("\n".join(mini + [""] + [paint(" " + c) for c in cells]) + "\n")
PY
echo "wrote rabble-portals{,.compact,.micro}.txt (aspect $aspect)"
