#!/usr/bin/env python3
"""
ChangeIcon App Icon Generator — macOS System Style
Fast vectorized version using PIL built-in operations.
"""

from PIL import Image, ImageDraw, ImageFilter
import math, os, subprocess, shutil

SIZE = 1024
OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))

def make_gradient(w, h, c_tl, c_tr, c_bl, c_br):
    """4-corner bilinear gradient as an RGBA image (fast stripe-based)."""
    img = Image.new("RGBA", (w, h))
    for y in range(h):
        ty = y / max(1, h - 1)
        top = lerp(c_tl, c_tr, ty)
        bot = lerp(c_bl, c_br, ty)
        stripe = [lerp(top, bot, x / max(1, w - 1)) for x in range(w)]
        flat = [v for rgba in stripe for v in (*rgba, 255)]
        img.putpixel((0, y), (0,0,0,0))  # placeholder
    # Actually use a simpler approach: draw gradient as horizontal strips
    del img
    img = Image.new("RGBA", (w, h))
    for y in range(h):
        ty = y / max(1, h - 1)
        top_c = lerp(c_tl, c_tr, ty)
        bot_c = lerp(c_bl, c_br, ty)
        r1, g1, b1 = top_c
        r2, g2, b2 = bot_c
        line = []
        for x in range(w):
            tx = x / max(1, w - 1)
            r = int(r1 + (r2 - r1) * tx)
            g = int(g1 + (g2 - g1) * tx)
            b = int(b1 + (b2 - b1) * tx)
            line.extend([r, g, b, 255])
        img.putpixel((0, y), (0,0,0,0))  # placeholder
    return img

def fast_gradient(w, h, c_tl, c_tr, c_bl, c_br):
    """Faster gradient using putdata."""
    from itertools import accumulate
    pixels = []
    for y in range(h):
        ty = y / max(1, h - 1)
        r_top, g_top, b_top = lerp(c_tl, c_tr, ty)
        r_bot, g_bot, b_bot = lerp(c_bl, c_br, ty)
        for x in range(w):
            tx = x / max(1, w - 1)
            r = int(r_top + (r_bot - r_top) * tx)
            g = int(g_top + (g_bot - g_top) * tx)
            b = int(b_top + (b_bot - b_top) * tx)
            pixels.append((r, g, b, 255))
    img = Image.new("RGBA", (w, h))
    img.putdata(pixels)
    return img

# ---------------------------------------------------------------------------
# Main icon generation
# ---------------------------------------------------------------------------
def create_icon(size):
    print(f"  Generating {size}x{size} icon...")
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # ---- 1. Base squircle with diagonal gradient ----
    c_tl = (255, 180, 80)
    c_tr = (255, 140, 60)
    c_bl = (90, 120, 240)
    c_br = (70, 90, 220)

    print("  Computing gradient...")
    base = fast_gradient(size, size, c_tl, c_tr, c_bl, c_br)

    print("  Creating squircle mask...")
    # macOS-style rounded rect (close enough to squircle for dock sizes)
    r = int(size * 0.225)
    mask = Image.new("L", (size, size), 0)
    mdraw = ImageDraw.Draw(mask)
    mdraw.rounded_rectangle([(0, 0), (size - 1, size - 1)], radius=r, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(radius=1.5))

    img.paste(base, (0, 0), mask)

    # ---- 2. Inner shadow edge ----
    print("  Adding depth...")
    inner_r = int(size * 0.22)
    inner_mask = Image.new("L", (size, size), 0)
    idraw = ImageDraw.Draw(inner_mask)
    idraw.rounded_rectangle([(0, 0), (size - 1, size - 1)], radius=inner_r, fill=255)
    inner_mask = inner_mask.filter(ImageFilter.GaussianBlur(radius=size * 0.015))

    # Create soft edge shadow by subtracting inner from outer
    edge_mask = Image.new("L", (size, size), 0)
    for y in range(size):
        for x in range(size):
            outer_v = mask.getpixel((x, y))
            inner_v = inner_mask.getpixel((x, y))
            v = max(0, outer_v - inner_v)
            if v > 0:
                edge_mask.putpixel((x, y), min(255, int(v * 0.4)))
    img.paste((0, 0, 0, 255), (0, 0), edge_mask)

    # ---- 3. Top highlight ----
    print("  Adding highlight...")
    hl = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    hldraw = ImageDraw.Draw(hl)
    hldraw.ellipse(
        [size * 0.12, -size * 0.10, size * 0.88, size * 0.45],
        fill=(255, 255, 255, 50),
    )
    hl = hl.filter(ImageFilter.GaussianBlur(radius=size * 0.04))
    img.paste(hl, (0, 0), inner_mask)

    # ---- 4. Central graphic ----
    print("  Drawing central graphic...")
    center_size = int(size * 0.55)
    icon_size = int(center_size * 0.48)
    icon_r = int(icon_size * 0.2)
    offset = int(icon_size * 0.38)
    cx, cy = size // 2, size // 2

    # Left icon (warm/light)
    lx = cx - icon_size // 2 - offset
    ly = cy - icon_size // 2
    left_icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ld = ImageDraw.Draw(left_icon)
    ld.rounded_rectangle(
        [lx, ly, lx + icon_size, ly + icon_size],
        radius=icon_r, fill=(255, 245, 235, 235),
    )
    ld.rounded_rectangle(
        [lx, ly, lx + icon_size, ly + icon_size],
        radius=icon_r, outline=(255, 255, 255, 70), width=max(3, int(size*0.004)),
    )
    img.paste(left_icon, (0, 0), left_icon)

    # Right icon (cool/dark)
    rx = cx - icon_size // 2 + offset
    ry = cy - icon_size // 2
    right_icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    rd = ImageDraw.Draw(right_icon)
    rd.rounded_rectangle(
        [rx, ry, rx + icon_size, ry + icon_size],
        radius=icon_r, fill=(30, 35, 65, 235),
    )
    rd.rounded_rectangle(
        [rx, ry, rx + icon_size, ry + icon_size],
        radius=icon_r, outline=(255, 255, 255, 35), width=max(3, int(size*0.004)),
    )
    img.paste(right_icon, (0, 0), right_icon)

    # ---- 5. Swap arrow ----
    print("  Drawing swap arrow...")
    arrow_cx = cx
    arrow_cy = cy + int(icon_size * 0.62)
    arrow_len = int(icon_size * 0.50)
    arrow_w = max(4, int(size * 0.011))
    arrow_color = (255, 255, 255, 235)

    arrow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arrow)

    # Left arc
    l_bbox = [arrow_cx - arrow_len, arrow_cy - arrow_len * 0.55,
              arrow_cx, arrow_cy + arrow_len * 0.55]
    ad.arc(l_bbox, -10, 180, fill=arrow_color, width=arrow_w)

    # Right arc
    r_bbox = [arrow_cx, arrow_cy - arrow_len * 0.55,
              arrow_cx + arrow_len, arrow_cy + arrow_len * 0.55]
    ad.arc(r_bbox, 0, 190, fill=arrow_color, width=arrow_w)

    # Arrowheads
    head_s = int(arrow_w * 2.8)
    # Left arrowhead
    l_tx = arrow_cx - arrow_len + int(arrow_w * 0.5)
    l_ty = arrow_cy - arrow_len * 0.52
    ad.polygon([(l_tx, l_ty), (l_tx + head_s, l_ty - head_s//2), (l_tx + head_s, l_ty + head_s//2)], fill=arrow_color)
    # Right arrowhead
    r_tx = arrow_cx + arrow_len - int(arrow_w * 0.5)
    r_ty = arrow_cy - arrow_len * 0.52
    ad.polygon([(r_tx, r_ty), (r_tx - head_s, r_ty - head_s//2), (r_tx - head_s, r_ty + head_s//2)], fill=arrow_color)

    img.paste(arrow, (0, 0), arrow)

    # Center dot
    dot_r = max(6, int(size * 0.017))
    dot = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dot)
    dd.ellipse([arrow_cx - dot_r, arrow_cy - dot_r, arrow_cx + dot_r, arrow_cy + dot_r],
               fill=(255, 255, 255, 210))
    img.paste(dot, (0, 0), dot)

    print(f"  Done.")
    return img


# ---------------------------------------------------------------------------
# Generate iconset and .icns
# ---------------------------------------------------------------------------
def generate_iconset():
    iconset_dir = os.path.join(OUTPUT_DIR, "AppIcon.iconset")
    if os.path.exists(iconset_dir):
        shutil.rmtree(iconset_dir)
    os.makedirs(iconset_dir)

    master = create_icon(SIZE)

    sizes = {
        16:   ("icon_16x16.png",       "icon_16x16@2x.png"),
        32:   ("icon_32x32.png",       "icon_32x32@2x.png"),
        128:  ("icon_128x128.png",     "icon_128x128@2x.png"),
        256:  ("icon_256x256.png",     "icon_256x256@2x.png"),
        512:  ("icon_512x512.png",     "icon_512x512@2x.png"),
    }

    print("\nGenerating iconset sizes...")
    for px_size, (name_1x, name_2x) in sizes.items():
        img_1x = master.resize((px_size, px_size), Image.LANCZOS)
        img_1x.save(os.path.join(iconset_dir, name_1x), "PNG")
        img_2x = master.resize((px_size * 2, px_size * 2), Image.LANCZOS)
        img_2x.save(os.path.join(iconset_dir, name_2x), "PNG")
        print(f"  {px_size}px ✓")

    icns_path = os.path.join(OUTPUT_DIR, "Resources", "AppIcon.icns")
    print(f"\nConverting to .icns...")
    subprocess.run(
        ["iconutil", "-c", "icns", iconset_dir, "-o", icns_path],
        check=True,
    )
    print(f"✅ AppIcon.icns → {icns_path}")

    preview_path = os.path.join(OUTPUT_DIR, "AppIcon_preview.png")
    master.save(preview_path, "PNG")
    print(f"✅ Preview → {preview_path}")

    shutil.rmtree(iconset_dir)


if __name__ == "__main__":
    generate_iconset()
