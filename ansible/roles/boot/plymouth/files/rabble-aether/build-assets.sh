#!/usr/bin/env bash
# =============================================================================
# build-assets.sh — regenerate the rabble-aether Plymouth theme assets
#
# Captures the live RaBbLE-Boot.html entity animation with headless Chromium,
# extracts a 96-frame PNG sequence with ffmpeg, and regenerates the small
# static overlay images. Run this from the Collective root whenever the boot
# animation changes — Ansible deploys whatever is committed here; it never
# runs this capture at apply time.
#
# Prereqs:
#   - dev server running:  bash RaBbLE-Grimoire/spells/dev-serve.sh --world
#   - node + npm, ffmpeg
#
# Usage:
#   bash ansible/roles/boot/plymouth/files/rabble-aether/build-assets.sh
#
# cast ~ boot/plymouth >> entity frames distilled from the living animation
# =============================================================================

set -euo pipefail

THEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="${RABBLE_BOOT_URL:-http://localhost:8080/world/RaBbLE-Boot.html}"
WORK="$(mktemp -d /tmp/rabble-plymouth-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

FPS=12
FRAMES=96
CROP=640          # capture crop box (px, square, centred on the entity)
OUT_SIZE=512      # final frame size shipped in the theme

for dep in node npm ffmpeg curl; do
  command -v "$dep" >/dev/null || { echo "missing dependency: $dep" >&2; exit 1; }
done
curl -sf -o /dev/null "$URL" || {
  echo "cannot reach $URL — start the dev server first:" >&2
  echo "  bash RaBbLE-Grimoire/spells/dev-serve.sh --world" >&2
  exit 1
}

# ── 1. Record the animation (Playwright, headless Chromium) ──────────────────
cat > "$WORK/capture.mjs" <<'EOF'
import { chromium } from 'playwright';
import { writeFileSync } from 'node:fs';

const [, , url, outdir] = process.argv;
const browser = await chromium.launch();
const ctx = await browser.newContext({
  viewport: { width: 1920, height: 1080 },
  recordVideo: { dir: outdir, size: { width: 1920, height: 1080 } },
});
const page = await ctx.newPage();
await page.goto(url, { waitUntil: 'load' });
await page.waitForSelector('rabble-entity', { timeout: 10000 });
await page.waitForTimeout(500);
const rect = await page.evaluate(() => {
  const r = document.querySelector('rabble-entity').getBoundingClientRect();
  return { x: r.x, y: r.y, w: r.width, h: r.height };
});
writeFileSync(`${outdir}/entity-rect.json`, JSON.stringify(rect));
await page.waitForTimeout(9000);
await ctx.close();
await browser.close();
EOF

echo "── recording $URL"
(cd "$WORK" && npm init -y >/dev/null 2>&1 && npm install --no-audit --no-fund playwright >/dev/null)
(cd "$WORK" && node capture.mjs "$URL" "$WORK/out")
VIDEO="$(ls "$WORK"/out/*.webm)"

# ── 2. Extract entity frames with ffmpeg ─────────────────────────────────────
# Crop a square centred on the entity element (visual cloud sits ~20px above
# the element's geometric centre), then downscale for the initrd.
read -r CX CY <<< "$(node -e "
  const r = require('$WORK/out/entity-rect.json');
  console.log(Math.round(r.x + r.w / 2), Math.round(r.y + r.h / 2) - 20);
")"
X=$(( CX - CROP / 2 )); Y=$(( CY - CROP / 2 ))
echo "── extracting $FRAMES frames @ ${FPS}fps, crop ${CROP}px @ ($X,$Y)"

mkdir -p "$THEME_DIR/frames"
rm -f "$THEME_DIR"/frames/entity-*.png
# Extract opaque frames first — transparency applied by the Python step below.
ffmpeg -loglevel error -ss 0.5 -i "$VIDEO" \
  -vf "fps=$FPS,crop=$CROP:$CROP:$X:$Y,scale=$OUT_SIZE:$OUT_SIZE" \
  -frames:v "$FRAMES" "$THEME_DIR/frames/entity-%04d.png"

# ── 2b. Alpha pass: background key + radial vignette ─────────────────────────
# The entity canvas bakes in its background (~#02000b). ffmpeg colorkey is too
# coarse here (no clean dist gap between bg and dim particles). Instead:
#   - Background key (SOFT_IN=5, SOFT_OUT=18): removes bg + compression noise,
#     lets dim halos fade naturally.
#   - Radial vignette (R_FULL=215, R_ZERO=255): cosine fade to transparent at
#     the frame edges so the sprite integrates into the Plymouth void with no
#     visible square or circle boundary.
# All real content is within r=215 (verified on entity-0022..0048 frames).
python3 - "$THEME_DIR/frames" <<'PYEOF'
import os, sys, math
from PIL import Image

FRAME_DIR = sys.argv[1]
SIZE = 512
CX, CY = SIZE // 2, SIZE // 2
BG = (2, 0, 11)      # measured background: #02000b
SOFT_IN, SOFT_OUT = 5, 18
R_FULL, R_ZERO = 215, 255

# Pre-compute radial mask
radial = [[0.0]*SIZE for _ in range(SIZE)]
for y in range(SIZE):
    for x in range(SIZE):
        r = math.sqrt((x-CX)**2 + (y-CY)**2)
        if r <= R_FULL:
            radial[y][x] = 1.0
        elif r >= R_ZERO:
            radial[y][x] = 0.0
        else:
            t = (r - R_FULL) / (R_ZERO - R_FULL)
            radial[y][x] = 0.5 * (1.0 + math.cos(math.pi * t))

frames = sorted(f for f in os.listdir(FRAME_DIR) if f.startswith('entity-') and f.endswith('.png'))
for fname in frames:
    path = os.path.join(FRAME_DIR, fname)
    img = Image.open(path).convert('RGBA')
    data = img.load()
    for y in range(SIZE):
        for x in range(SIZE):
            r, g, b, a = data[x, y]
            d = math.sqrt((r-BG[0])**2 + (g-BG[1])**2 + (b-BG[2])**2)
            key = 0.0 if d <= SOFT_IN else (1.0 if d >= SOFT_OUT else (d-SOFT_IN)/(SOFT_OUT-SOFT_IN))
            data[x, y] = (r, g, b, int(a * key * radial[y][x]))
    img.save(path, 'PNG', optimize=False)
print(f'alpha pass: {len(frames)} frames processed')
PYEOF

# ── 3. Static overlay assets ─────────────────────────────────────────────────
# Palette: #0a0010 void · #2a2840 border · #ff2d78 magenta · #00f5ff cyan
# · #1a1b2e raised — RaBbLE-Palette.md only.
A="$THEME_DIR/assets"; mkdir -p "$A"
ffmpeg -loglevel error -f lavfi -i "color=c=black@0.0:s=1920x1080,format=rgba" \
  -vf "geq=r=10:g=0:b=16:a='if(lt(mod(Y\,4)\,2)\,20\,0)'" -frames:v 1 -y "$A/scanlines.png"
ffmpeg -loglevel error -f lavfi -i "color=c=0x2a2840:s=8x6" -frames:v 1 -y "$A/bar-track.png"
ffmpeg -loglevel error -f lavfi -i "color=c=0xff2d78:s=8x6" -frames:v 1 -y "$A/bar-fill.png"
ffmpeg -loglevel error -f lavfi -i "color=c=black@0.0:s=14x14,format=rgba" \
  -vf "geq=r=0:g=245:b=255:a='if(lte(hypot(X-6.5\,Y-6.5)\,5)\,255\,if(lte(hypot(X-6.5\,Y-6.5)\,6.8)\,100\,0))'" \
  -frames:v 1 -y "$A/dot.png"
ffmpeg -loglevel error -f lavfi -i "color=c=black@0.0:s=8x8,format=rgba" \
  -vf "geq=r=26:g=27:b=46:a=230" -frames:v 1 -y "$A/panel.png"

# ── 4. Floor grid (cyan/magenta perspective, transparent PNG) ─────────────────
# Ported from NeBuLA AmbientField._bakeGrid: VP at (W/2, H*0.74), 18 radial
# fan lines alternating cyan/magenta + 11 horizontal power-curved lines.
cat > "$WORK/grid.mjs" <<'EOF'
import { chromium } from 'playwright';
const browser = await chromium.launch();
const ctx     = await browser.newContext({ viewport: { width: 1920, height: 1080 } });
const page    = await ctx.newPage();
await page.setContent('<html style="margin:0;padding:0;background:transparent"><body style="margin:0;padding:0;background:transparent"></body></html>');
await page.addScriptTag({ content: `
  const cv = document.createElement('canvas');
  cv.width = 1920; cv.height = 1080;
  document.body.appendChild(cv);
  const c  = cv.getContext('2d');
  const W  = 1920, H = 1080;
  const vx = W / 2, vy = H * 0.74;
  // Radial fan lines (18) — alternating cyan / magenta, fade to transparent at VP
  for (let i = 0; i <= 18; i++) {
    const tx = i / 18, x = vx + (tx - 0.5) * W * 3.2;
    const col = (i % 2 === 0) ? [0, 245, 255] : [255, 45, 120];
    c.beginPath(); c.moveTo(x, H); c.lineTo(vx, vy);
    const g = c.createLinearGradient(x, H, vx, vy);
    g.addColorStop(0, 'rgba(' + col[0] + ',' + col[1] + ',' + col[2] + ',0.28)');
    g.addColorStop(1, 'rgba(' + col[0] + ',' + col[1] + ',' + col[2] + ',0)');
    c.strokeStyle = g; c.lineWidth = 1.2; c.stroke();
  }
  // Horizontal power-curved lines (11) — alternating magenta / cyan, edge-fade
  for (let j = 0; j <= 11; j++) {
    const ty = Math.pow(j / 11, 1.65), y = vy + (H - vy) * ty, sp = ty * W * 1.6;
    const col = (j % 2 === 0) ? [255, 45, 120] : [0, 245, 255];
    c.beginPath(); c.moveTo(vx - sp, y); c.lineTo(vx + sp, y);
    const g2 = c.createLinearGradient(vx - sp, y, vx + sp, y);
    g2.addColorStop(0,    'transparent');
    g2.addColorStop(0.2,  'rgba(' + col[0] + ',' + col[1] + ',' + col[2] + ',0.22)');
    g2.addColorStop(0.8,  'rgba(' + col[0] + ',' + col[1] + ',' + col[2] + ',0.22)');
    g2.addColorStop(1,    'transparent');
    c.strokeStyle = g2; c.lineWidth = 0.9; c.stroke();
  }
`});
await page.screenshot({ path: process.argv[2], omitBackground: true });
await browser.close();
EOF

echo "── baking floor grid"
(cd "$WORK" && node grid.mjs "$A/floor-grid.png")

# ── 5. Wordmark: 48 Orbitron Bold color-cycle PNGs ───────────────────────────
# Rendered via Playwright with the font embedded as base64 — guarantees Orbitron
# appears in Plymouth without relying on Pango font discovery in the initrd.
# Naming: wm-step-000.png .. wm-step-047.png  (matches rabble-aether.script)
FONT="$THEME_DIR/fonts/Orbitron-Bold.ttf"
cat > "$WORK/wm.mjs" <<'EOF'
import { chromium } from 'playwright';
import { readFileSync } from 'node:fs';

const [,,fontPath, outDir] = process.argv;
const fontB64 = readFileSync(fontPath).toString('base64');

const browser = await chromium.launch();
const ctx     = await browser.newContext({ viewport: { width: 1024, height: 256 } });
const page    = await ctx.newPage();

await page.setContent(`<!DOCTYPE html>
<html><head><style>
  @font-face {
    font-family: 'Orbitron';
    src: url(data:font/truetype;base64,${fontB64}) format('truetype');
    font-weight: 700;
  }
  html, body { margin: 0; padding: 0; background: transparent; }
  #wm {
    display: inline-block;
    font-family: 'Orbitron', monospace;
    font-weight: 700;
    font-size: 64px;
    line-height: 1;
    white-space: nowrap;
    padding: 4px 8px;
  }
</style></head><body><div id="wm">RaBbLE</div></body></html>`);

await page.evaluate(() => document.fonts.ready);

const steps = 48, seg = 16;
const mag = [1.0,   0.1765, 0.4706];
const vio = [0.749, 0.3725, 1.0];
const cya = [0.0,   0.9608, 1.0];
const lerp = (a, b, t) => a.map((v, j) => v + (b[j] - v) * t);
const toRgb = c => `rgb(${Math.round(c[0]*255)},${Math.round(c[1]*255)},${Math.round(c[2]*255)})`;

for (let i = 0; i < steps; i++) {
  const k = i % seg, t = k / seg;
  let c;
  if      (i < seg)     c = lerp(mag, vio, t);
  else if (i < 2 * seg) c = lerp(vio, cya, t);
  else                   c = lerp(cya, mag, t);

  await page.evaluate(col => { document.getElementById('wm').style.color = col; }, toRgb(c));
  const num = String(i).padStart(3, '0');
  await page.locator('#wm').screenshot({
    path: `${outDir}/wm-step-${num}.png`,
    omitBackground: true,
  });
}

await browser.close();
EOF

echo "── rendering 48 Orbitron wordmark steps"
rm -f "$A"/wm-step-*.png
(cd "$WORK" && node wm.mjs "$FONT" "$A")

echo "── done: $(ls "$THEME_DIR"/frames | wc -l) frames, $(du -sh "$THEME_DIR/frames" | cut -f1) · floor-grid $(du -sh "$A/floor-grid.png" | cut -f1) · wordmark PNGs $(ls "$A"/wm-step-*.png 2>/dev/null | wc -l)"
