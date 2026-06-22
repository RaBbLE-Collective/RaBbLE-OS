#!/usr/bin/env python3
"""build-grub-bg.py — Generate 24bpp GRUB background from RaBbLE assets.

Composites entity + floor grid + wordmark onto the RaBbLE Liminal Background
(or fall back to void color). Output is 24bpp RGB PNG (no alpha) — GRUB
requires <=24bpp for background images.

Usage:
  python3 build-grub-bg.py [--output PATH] [--bg PATH] [--entity PATH] [--grid PATH]

Run from the GRUB theme directory after Plymouth build-assets.sh has run.
The canonical canvas is RaBbLE-BaBbLE/RaBbLE_boot_Liminal_BG.png.
"""
import argparse, math, os, sys
from PIL import Image, ImageDraw, ImageFont

W, H = 1920, 1200
VOID = (10, 0, 16)
MAGENTA = (255, 45, 120)
CYAN = (0, 245, 255)
VIOLET = (191, 95, 255)
MUTED = (107, 104, 128)
SURFACE = (18, 19, 42)
BORDER = (42, 40, 64)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="grub-bg.png")
    parser.add_argument("--bg", default=None, help="Liminal BG canvas (RGBA, will be converted to RGB)")
    parser.add_argument("--entity", default=None)
    parser.add_argument("--grid", default=None)
    args = parser.parse_args()

    if args.bg and os.path.exists(args.bg):
        bg = Image.open(args.bg).convert("RGBA").resize((W, H), Image.LANCZOS).convert("RGB")
    else:
        bg = Image.new("RGB", (W, H), VOID)
    draw = ImageDraw.Draw(bg)

    # Floor grid (from Plymouth assets)
    if args.grid and os.path.exists(args.grid):
        grid = Image.open(args.grid).convert("RGBA")
        grid = grid.resize((W, H), Image.LANCZOS)
        bg = Image.alpha_composite(bg.convert("RGBA"), grid).convert("RGB")
        draw = ImageDraw.Draw(bg)

    # Entity (from Plymouth frames, frame 1)
    if args.entity and os.path.exists(args.entity):
        ent = Image.open(args.entity).convert("RGBA")
        ent_size = 280
        ent = ent.resize((ent_size, ent_size), Image.LANCZOS)
        ent_x = int(W * 0.15 - ent_size / 2)
        ent_y = int(H * 0.38 - ent_size / 2)
        bg = Image.alpha_composite(bg.convert("RGBA"), Image.new("RGBA", (W, H), (0,0,0,0)))
        bg.paste(ent, (ent_x, ent_y), ent)
        bg = bg.convert("RGB")
        draw = ImageDraw.Draw(bg)

    # Wordmark "RaBbLE" — use PIL default font or try Orbitron
    font_large = None
    font_small = None
    font_paths = [
        "/usr/share/fonts/rabble-fonts/Orbitron-Variable.ttf",
        "/usr/share/fonts/rabble-fonts/Orbitron-Bold.ttf",
        "/usr/share/fonts/google-noto/NotoSans-Bold.ttf",
        "/usr/share/fonts/noto/NotoSans-Bold.ttf",
    ]
    for fp in font_paths:
        if os.path.exists(fp):
            try:
                font_large = ImageFont.truetype(fp, 72)
                font_small = ImageFont.truetype(fp, 28)
            except Exception:
                pass
            break
    if font_large is None:
        font_large = ImageFont.load_default()
        font_small = ImageFont.load_default()

    wm_text = "RaBbLE-OS"
    wm_bbox = draw.textbbox((0, 0), wm_text, font=font_large)
    wm_w = wm_bbox[2] - wm_bbox[0]
    wm_x = int(W * 0.42)
    wm_y = int(H * 0.28)
    draw.text((wm_x, wm_y), wm_text, font=font_large, fill=MAGENTA)

    sub_text = "Episode 1 — Genesis"
    sub_bbox = draw.textbbox((0, 0), sub_text, font=font_small)
    sub_w = sub_bbox[2] - sub_bbox[0]
    sub_x = int(W * 0.42)
    sub_y = wm_y + 80
    draw.text((sub_x, sub_y), sub_text, font=font_small, fill=VIOLET)

    # Decorative line
    line_y = sub_y + 50
    for x in range(int(W * 0.35), int(W * 0.80)):
        t = (x - W * 0.35) / (W * 0.45)
        r = int(BORDER[0] + (MAGENTA[0] - BORDER[0]) * math.sin(t * math.pi))
        g = int(BORDER[1] + (MAGENTA[1] - BORDER[1]) * math.sin(t * math.pi))
        b = int(BORDER[2] + (MAGENTA[2] - BORDER[2]) * math.sin(t * math.pi))
        draw.point((x, line_y), fill=(r, g, b))

    bg.save(args.output, "PNG")
    print(f"GRUB background saved: {args.output} ({os.path.getsize(args.output)} bytes, 24bpp RGB)")


if __name__ == "__main__":
    main()
