#!/usr/bin/env python3
"""
generate_wallpaper.py — RaBbLE-OS synthwave wallpaper generator
Produces a 1920x1080 PNG: deep void background, horizon glow, scanlines,
perspective grid, and the RaBbLE palette throughout.

Usage:
    python3 assets/generate_wallpaper.py [--output assets/wallpaper.png]
"""

import argparse
import math
from PIL import Image, ImageDraw, ImageFilter

# ── Palette ───────────────────────────────────────────────────────────────────
BG        = (10,  0,  16)    # #0a0010 deep void
SURFACE   = (18,  0,  37)    # #120025 elevated surface
PRIMARY   = (255, 45, 120)   # #ff2d78 hot magenta
ACCENT    = (0,  245, 255)   # #00f5ff electric cyan
VIOLET    = (191, 95, 255)   # #bf5fff soft violet
TEXT      = (232, 213, 255)  # #e8d5ff off-white purple tint
MUTED     = (136, 96, 170)   # #8860aa muted purple

W, H = 1920, 1080
HORIZON_Y = int(H * 0.58)   # Where the grid meets the sky


def lerp_color(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def hex_to_rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))


def draw_background(img):
    """Vertical gradient: deep void top → slightly lighter surface near horizon."""
    draw = ImageDraw.Draw(img)
    for y in range(H):
        t = y / H
        # Sky: void fading toward a very dark violet near horizon
        sky_top    = BG
        sky_bottom = (28, 4, 52)
        color = lerp_color(sky_top, sky_bottom, t ** 0.6)
        draw.line([(0, y), (W, y)], fill=color)


def draw_horizon_glow(img):
    """Soft magenta/cyan glow band at the horizon line."""
    glow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)

    # Wide magenta glow
    for i, (color, alpha_peak, spread) in enumerate([
        (PRIMARY, 80,  120),
        (ACCENT,  40,  60),
        (VIOLET,  30,  200),
    ]):
        for dy in range(-spread, spread):
            y = HORIZON_Y + dy
            if 0 <= y < H:
                t = 1.0 - abs(dy) / spread
                alpha = int(alpha_peak * (t ** 2))
                r, g, b = color
                draw.line([(0, y), (W, y)], fill=(r, g, b, alpha))

    img.paste(Image.alpha_composite(img.convert('RGBA'), glow).convert('RGB'))


def draw_perspective_grid(img):
    """Receding grid on the floor plane below the horizon."""
    draw = ImageDraw.Draw(img)
    cx = W // 2  # Vanishing point x

    # ── Horizontal lines (recede toward horizon) ──────────────────────────────
    n_horiz = 18
    for i in range(n_horiz + 1):
        t = (i / n_horiz) ** 1.8          # Power curve — denser near horizon
        y = H - int((H - HORIZON_Y) * t)
        if y >= HORIZON_Y:
            fade = t ** 0.5
            r = int(lerp_color(MUTED, PRIMARY, fade * 0.4)[0])
            g = int(lerp_color(MUTED, PRIMARY, fade * 0.4)[1])
            b = int(lerp_color(MUTED, PRIMARY, fade * 0.4)[2])
            alpha_line = int(30 + 120 * fade)
            # Draw as a thin semi-transparent line by blending
            line_img = Image.new('RGBA', (W, H), (0, 0, 0, 0))
            line_draw = ImageDraw.Draw(line_img)
            line_draw.line([(0, y), (W, y)], fill=(r, g, b, alpha_line), width=1)
            img.paste(Image.alpha_composite(img.convert('RGBA'), line_img).convert('RGB'))

    # ── Vertical lines (fan out from vanishing point) ─────────────────────────
    n_vert = 24
    for i in range(n_vert + 1):
        t = i / n_vert                    # 0 = far left, 1 = far right
        # At the horizon: lines converge to cx
        # At the bottom: spread across full width + overshoot
        x_bottom = int(-W * 0.3 + t * W * 1.6)
        x_horiz  = cx

        fade = abs(t - 0.5) * 2           # Brighter at edges
        color = lerp_color(ACCENT, VIOLET, fade)
        alpha_line = int(25 + 55 * (1 - abs(t - 0.5)))

        line_img = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        line_draw = ImageDraw.Draw(line_img)
        line_draw.line(
            [(x_horiz, HORIZON_Y), (x_bottom, H)],
            fill=(*color, alpha_line),
            width=1
        )
        img.paste(Image.alpha_composite(img.convert('RGBA'), line_img).convert('RGB'))


def draw_scanlines(img):
    """Subtle horizontal scanlines across the whole image — CRT feel."""
    overlay = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    for y in range(0, H, 2):
        draw.line([(0, y), (W, y)], fill=(0, 0, 0, 18))
    img.paste(Image.alpha_composite(img.convert('RGBA'), overlay).convert('RGB'))


def draw_stars(img):
    """Sparse stars in the sky portion."""
    import random
    random.seed(42)
    overlay = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    for _ in range(320):
        x = random.randint(0, W - 1)
        y = random.randint(0, HORIZON_Y - 20)
        brightness = random.randint(60, 200)
        size = random.choices([1, 2], weights=[0.85, 0.15])[0]
        # Tint stars toward violet/white
        r = min(255, brightness + random.randint(-10, 30))
        g = min(255, brightness - random.randint(0, 20))
        b = min(255, brightness + random.randint(0, 40))
        alpha = random.randint(120, 220)
        draw.ellipse(
            [(x - size, y - size), (x + size, y + size)],
            fill=(r, g, b, alpha)
        )
    img.paste(Image.alpha_composite(img.convert('RGBA'), overlay).convert('RGB'))


def draw_sun(img):
    """Retro synthwave sun bisected by the horizon — magenta to violet gradient."""
    overlay = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    cx, cy = W // 2, HORIZON_Y
    r_outer = 160
    r_inner = 0

    # Draw concentric rings from outside in, gradient magenta → violet → cyan
    for radius in range(r_outer, r_inner, -1):
        t = 1.0 - radius / r_outer
        color = lerp_color(PRIMARY, VIOLET, t)
        if t > 0.7:
            color = lerp_color(VIOLET, ACCENT, (t - 0.7) / 0.3)
        alpha = 200
        draw.ellipse(
            [(cx - radius, cy - radius), (cx + radius, cy + radius)],
            outline=(*color, alpha),
            width=1
        )

    # Stripes cutting through the lower half of the sun (classic synthwave look)
    stripe_count = 7
    for i in range(stripe_count):
        t = (i + 1) / (stripe_count + 1)
        y_stripe = cy + int(r_outer * t * 0.95)
        half_w = int(math.sqrt(max(0, r_outer**2 - (y_stripe - cy)**2)))
        if half_w > 0:
            draw.rectangle(
                [(cx - half_w, y_stripe - 3), (cx + half_w, y_stripe + 3)],
                fill=(10, 0, 16, 220)  # BG color — cuts into sun
            )

    img.paste(Image.alpha_composite(img.convert('RGBA'), overlay).convert('RGB'))


def main():
    parser = argparse.ArgumentParser(description="Generate RaBbLE-OS synthwave wallpaper")
    parser.add_argument('--output', default='assets/wallpaper.png', help='Output PNG path')
    parser.add_argument('--width',  type=int, default=1920)
    parser.add_argument('--height', type=int, default=1080)
    args = parser.parse_args()

    global W, H, HORIZON_Y
    W, H = args.width, args.height
    HORIZON_Y = int(H * 0.58)

    print(f"Generating RaBbLE-OS wallpaper {W}x{H}...")

    img = Image.new('RGB', (W, H), BG)

    draw_background(img)
    draw_stars(img)
    draw_sun(img)
    draw_horizon_glow(img)
    draw_perspective_grid(img)
    draw_scanlines(img)

    # Final vignette — darken corners
    vignette = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    vdraw = ImageDraw.Draw(vignette)
    for i in range(min(W, H) // 3):
        t = i / (min(W, H) // 3)
        alpha = int(90 * (1 - t) ** 2)
        vdraw.rectangle([(i, i), (W - i, H - i)], outline=(0, 0, 0, alpha))
    img = Image.alpha_composite(img.convert('RGBA'), vignette).convert('RGB')

    img.save(args.output, 'PNG', optimize=True)
    print(f"Saved: {args.output}")


if __name__ == '__main__':
    main()
