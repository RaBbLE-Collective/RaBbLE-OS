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
ffmpeg -loglevel error -ss 0.5 -i "$VIDEO" \
  -vf "fps=$FPS,crop=$CROP:$CROP:$X:$Y,scale=$OUT_SIZE:$OUT_SIZE" \
  -frames:v "$FRAMES" "$THEME_DIR/frames/entity-%04d.png"

# Optional size crush if pngquant is available
if command -v pngquant >/dev/null; then
  pngquant --force --ext .png --quality=60-80 "$THEME_DIR"/frames/entity-*.png || true
fi

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

echo "── done: $(ls "$THEME_DIR"/frames | wc -l) frames, $(du -sh "$THEME_DIR/frames" | cut -f1)"
