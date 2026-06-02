#!/usr/bin/env python3
"""
Split Prism Icon v4 — larger prism (~50% canvas), proper colors, macOS squircle mask.
"""

from PIL import Image, ImageDraw, ImageFilter
import math
import os

SIZE = 1024
OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))


def rounded_rect_mask(size, radius_ratio=0.225):
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    r = int(size * radius_ratio)
    draw.rounded_rectangle([(0, 0), (size - 1, size - 1)], radius=r, fill=255)
    return mask


def create_gradient(size, color1, color2, angle=135):
    grad = Image.new("RGBA", (size, size))
    pixels = grad.load()
    rad = math.radians(angle)
    cx, cy = size / 2, size / 2
    diag = size * math.sqrt(2)

    for y in range(size):
        for x in range(size):
            proj = (x - cx) * math.cos(rad) + (y - cy) * math.sin(rad)
            t = (proj / diag) + 0.5
            t = max(0, min(1, t))
            r = int(color1[0] + (color2[0] - color1[0]) * t)
            g = int(color1[1] + (color2[1] - color1[1]) * t)
            b = int(color1[2] + (color2[2] - color1[2]) * t)
            pixels[x, y] = (r, g, b, 255)
    return grad


def create_icon(is_dark: bool) -> Image.Image:
    if is_dark:
        bg_color1, bg_color2 = (20, 20, 42), (28, 28, 58)
        ur_color, ur_color2 = (255, 170, 60), (255, 105, 100)
        ll_color, ll_color2 = (72, 210, 200), (105, 90, 235)
        glow_color = (255, 255, 255, 35)
        accent_dot = (255, 255, 255, 200)
        border_color = (255, 255, 255, 30)
        center_dot = (255, 255, 255, 150)
    else:
        bg_color1, bg_color2 = (232, 232, 242), (248, 248, 255)
        ur_color, ur_color2 = (255, 145, 45), (255, 85, 75)
        ll_color, ll_color2 = (48, 185, 178), (88, 68, 222)
        glow_color = (0, 0, 0, 14)
        accent_dot = (85, 85, 125, 180)
        border_color = (0, 0, 0, 22)
        center_dot = (65, 65, 105, 170)

    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # Background
    bg = create_gradient(SIZE, bg_color1, bg_color2, angle=135)
    img.paste(bg, (0, 0))
    draw = ImageDraw.Draw(img)

    # Prism — 50% of canvas
    prism_size = int(SIZE * 0.50)
    cx, cy = SIZE // 2, SIZE // 2
    half = prism_size // 2

    # Four triangles
    ur = [(cx, cy - half), (cx + half, cy), (cx, cy)]  # upper-right (warm)
    ll = [(cx, cy + half), (cx - half, cy), (cx, cy)]  # lower-left (cool)
    ul = [(cx, cy - half), (cx - half, cy), (cx, cy)]  # upper-left (warm accent)
    lr = [(cx, cy + half), (cx + half, cy), (cx, cy)]  # lower-right (cool accent)

    # Upper-right warm
    draw.polygon(ur, fill=ur_color)
    for i in range(3):
        s = 1.0 - i * 0.08
        pts = [(cx, cy - int(half * s)), (cx + int(half * s), cy), (cx, cy)]
        overlay = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
        odraw = ImageDraw.Draw(overlay)
        odraw.polygon(pts, fill=ur_color2 + (40 - i * 10,))
        img = Image.alpha_composite(img, overlay)
        draw = ImageDraw.Draw(img)

    # Lower-left cool
    draw.polygon(ll, fill=ll_color)
    for i in range(3):
        s = 1.0 - i * 0.08
        pts = [(cx, cy + int(half * s)), (cx - int(half * s), cy), (cx, cy)]
        overlay = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
        odraw = ImageDraw.Draw(overlay)
        odraw.polygon(pts, fill=ll_color2 + (40 - i * 10,))
        img = Image.alpha_composite(img, overlay)
        draw = ImageDraw.Draw(img)

    # Accent triangles
    draw.polygon(ul, fill=(ur_color[0] + 30, ur_color[1] + 30, ur_color[2] + 20, 200))
    draw.polygon(lr, fill=(ll_color[0] - 20, ll_color[1] - 20, ll_color[2] + 20, 200))

    # Diamond outline
    diamond_pts = [(cx, cy - half), (cx + half, cy), (cx, cy + half), (cx - half, cy)]
    draw.polygon(diamond_pts, outline=border_color, width=3)

    # Diagonal split
    draw.line([(cx - half, cy - half), (cx + half, cy + half)], fill=border_color, width=2)

    # Corner dots
    dot_r = int(SIZE * 0.018)
    for px, py in diamond_pts:
        draw.ellipse(
            [(px - dot_r, py - dot_r), (px + dot_r, py + dot_r)],
            fill=accent_dot
        )

    # Outer glow
    glow_extra = int(SIZE * 0.04)
    glow = [
        (cx, cy - half - glow_extra), (cx + half + glow_extra, cy),
        (cx, cy + half + glow_extra), (cx - half - glow_extra, cy),
    ]
    overlay = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    odraw = ImageDraw.Draw(overlay)
    odraw.line(glow + [glow[0]], fill=glow_color, width=int(SIZE * 0.016))
    overlay = overlay.filter(ImageFilter.GaussianBlur(radius=SIZE * 0.02))
    img = Image.alpha_composite(img, overlay)
    draw = ImageDraw.Draw(img)

    # Center dot
    center_r = int(SIZE * 0.025)
    draw.ellipse(
        [(cx - center_r, cy - center_r), (cx + center_r, cy + center_r)],
        fill=center_dot
    )

    # Apply rounded rect mask
    mask = rounded_rect_mask(SIZE)
    result = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    result.paste(img, (0, 0), mask)

    return result


def main():
    print("Generating Split Prism v4 icons...")

    dark = create_icon(is_dark=True)
    dark.save(os.path.join(OUTPUT_DIR, "AppIcon-dark.png"), "PNG")
    print("  Created: AppIcon-dark.png")

    light = create_icon(is_dark=False)
    light.save(os.path.join(OUTPUT_DIR, "AppIcon-light.png"), "PNG")
    print("  Created: AppIcon-light.png")

    print("Done!")


if __name__ == "__main__":
    main()
