#!/usr/bin/env python3
"""
ChangeIcon — macOS System Style Icon Generator
Generates polished light and dark mode app icons in .icns format.
"""

from PIL import Image, ImageDraw, ImageFilter, ImageChops
import math, os, subprocess, shutil

SIZE = 1024
OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))
RESOURCES_DIR = os.path.join(OUTPUT_DIR, "Resources")

# ── macOS standard squircle mask ──────────────────────────────────────────────
def squircle_mask(size, radius=None):
    """Create a smooth macOS-style squircle mask using supersampling."""
    if radius is None:
        radius = size * 0.225
    ss = 4  # supersample factor
    big = size * ss
    big_r = radius * ss
    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)
    # Start with rounded rect, then apply distortion for squircle effect
    draw.rounded_rectangle([0, 0, big - 1, big - 1], radius=big_r, fill=255)
    # Blur slightly then threshold to get the squircle curve
    mask = mask.filter(ImageFilter.GaussianBlur(radius=ss * 1.8))
    # Threshold to tighten edges
    mask = mask.point(lambda p: 255 if p > 100 else 0)
    mask = mask.resize((size, size), Image.LANCZOS)
    # Final slight blur for anti-aliasing
    mask = mask.filter(ImageFilter.GaussianBlur(radius=0.5))
    return mask


def fast_gradient_pixels(w, h, c_tl, c_tr, c_bl, c_br):
    """4-corner bilinear gradient as flat pixel list."""
    pixels = []
    for y in range(h):
        ty = y / max(1, h - 1)
        r_top = int(c_tl[0] + (c_tr[0] - c_tl[0]) * ty)
        g_top = int(c_tl[1] + (c_tr[1] - c_tl[1]) * ty)
        b_top = int(c_tl[2] + (c_tr[2] - c_tl[2]) * ty)
        r_bot = int(c_bl[0] + (c_br[0] - c_bl[0]) * ty)
        g_bot = int(c_bl[1] + (c_br[1] - c_bl[1]) * ty)
        b_bot = int(c_bl[2] + (c_br[2] - c_bl[2]) * ty)
        for x in range(w):
            tx = x / max(1, w - 1)
            r = int(r_top + (r_bot - r_top) * tx)
            g = int(g_top + (g_bot - g_top) * tx)
            b = int(b_top + (b_bot - b_top) * tx)
            pixels.append((r, g, b, 255))
    return pixels


# ── Icon creation ─────────────────────────────────────────────────────────────
def create_icon(size, mode="light"):
    """
    Create a macOS system-style app icon.
    Design: Blue gradient squircle with two overlapping app-icon silhouettes
    and a curved swap arrow — clean, professional.
    """
    print(f"  Creating {mode} {size}x{size}...")
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # ── 1. Squircle mask ──
    sqr = squircle_mask(size)

    # ── 2. Base gradient ──
    if mode == "light":
        # Vibrant blue gradient
        c_tl = ( 80, 140, 235)
        c_tr = ( 60, 110, 220)
        c_bl = ( 40,  70, 195)
        c_br = ( 30,  55, 175)
    else:
        # Richer, deeper blue for dark mode
        c_tl = (100, 150, 240)
        c_tr = ( 80, 120, 230)
        c_bl = ( 50,  80, 200)
        c_br = ( 35,  60, 180)

    base_px = fast_gradient_pixels(size, size, c_tl, c_tr, c_bl, c_br)
    base = Image.new("RGBA", (size, size))
    base.putdata(base_px)
    img.paste(base, (0, 0), sqr)

    # ── 3. Inner shadow / edge depth ──
    inner_r = size * 0.217
    inner = Image.new("L", (size, size), 0)
    idraw = ImageDraw.Draw(inner)
    idraw.rounded_rectangle([(0, 0), (size - 1, size - 1)], radius=int(inner_r), fill=255)
    inner = inner.filter(ImageFilter.GaussianBlur(radius=max(1, size * 0.008)))

    edge_shadow = ImageChops.subtract(sqr, inner)
    edge_shadow = edge_shadow.point(lambda p: min(255, int(p * 0.55)))
    img.paste((0, 0, 0, 255), (0, 0), edge_shadow)

    # ── 4. Top highlight (glossy macOS look) ──
    hl = Image.new("L", (size, size), 0)
    hldraw = ImageDraw.Draw(hl)
    hldraw.ellipse(
        [size * 0.08, -size * 0.08, size * 0.92, size * 0.42],
        fill=255,
    )
    hl = hl.filter(ImageFilter.GaussianBlur(radius=size * 0.035))
    hl = ImageChops.multiply(hl, inner)
    hl = hl.point(lambda p: int(p * 0.30))
    img.paste((255, 255, 255, 255), (0, 0), hl)

    # ── 5. Bottom subtle reflection ──
    refl = Image.new("L", (size, size), 0)
    rdraw = ImageDraw.Draw(refl)
    rdraw.ellipse(
        [size * 0.15, size * 0.60, size * 0.85, size * 1.08],
        fill=255,
    )
    refl = refl.filter(ImageFilter.GaussianBlur(radius=size * 0.04))
    refl = ImageChops.multiply(refl, inner)
    refl = refl.point(lambda p: int(p * 0.10))
    img.paste((255, 255, 255, 255), (0, 0), refl)

    # ═══════════════════════════════════════════════════════════════════
    # ── 6. Central graphic: Two app icons + swap arrow ──
    # ═══════════════════════════════════════════════════════════════════
    cx, cy = size // 2, size // 2

    # App icon dimensions
    app_icon_size = int(size * 0.32)
    app_icon_r = int(app_icon_size * 0.21)
    gap = int(size * 0.12)  # horizontal gap between icons

    # Left icon position
    lx = cx - app_icon_size - gap
    ly = cy - app_icon_size // 2

    # Right icon position
    rx = cx + gap
    ry = cy - app_icon_size // 2

    # ── 6a. Left app icon (warm/light) ──
    left_bg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    lbg = ImageDraw.Draw(left_bg)

    # Subtle inner gradient for left icon
    licon_grad = fast_gradient_pixels(app_icon_size, app_icon_size,
                                       (255, 230, 200), (255, 220, 190),
                                       (255, 210, 170), (245, 200, 160))
    licon_img = Image.new("RGBA", (app_icon_size, app_icon_size))
    licon_img.putdata(licon_grad)

    # Rounded rect mask for left icon
    lmask = Image.new("L", (app_icon_size, app_icon_size), 0)
    lmask_d = ImageDraw.Draw(lmask)
    lmask_d.rounded_rectangle(
        [0, 0, app_icon_size - 1, app_icon_size - 1],
        radius=app_icon_r, fill=255
    )

    # Apply to main image
    licon_with_mask = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    licon_with_mask.paste(licon_img, (lx, ly), lmask)
    left_bg.paste(licon_with_mask, (0, 0), licon_with_mask)

    # Border
    lbg.rounded_rectangle(
        [lx, ly, lx + app_icon_size - 1, ly + app_icon_size - 1],
        radius=app_icon_r,
        outline=(255, 255, 255, 100),
        width=max(3, int(size * 0.005)),
    )

    # Shadow under left icon
    lshadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ls_r = int(app_icon_r * 0.9)
    ls_x = lx + int(size * 0.008)
    ls_y = ly + int(size * 0.012)
    lsd = ImageDraw.Draw(lshadow)
    lsd.rounded_rectangle(
        [ls_x, ls_y, ls_x + app_icon_size - 1, ls_y + app_icon_size - 1],
        radius=ls_r, fill=(0, 0, 0, 40),
    )
    lshadow = lshadow.filter(ImageFilter.GaussianBlur(radius=size * 0.015))
    img.paste(lshadow, (0, 0), lshadow)
    img.paste(left_bg, (0, 0), left_bg)

    # ── 6b. Small grid dots inside left icon (representing "app") ──
    dot_color = (200, 170, 110, 90)
    dot_r = max(2, int(app_icon_size * 0.035))
    dot_spacing = int(app_icon_size * 0.18)
    dot_start_x = lx + int(app_icon_size * 0.22)
    dot_start_y = ly + int(app_icon_size * 0.22)
    dots = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dots)
    for row in range(3):
        for col in range(3):
            dx = dot_start_x + col * dot_spacing
            dy = dot_start_y + row * dot_spacing
            dd.ellipse([dx - dot_r, dy - dot_r, dx + dot_r, dy + dot_r], fill=dot_color)
    img.paste(dots, (0, 0), dots)

    # ── 6c. Right app icon (cool/dark) ──
    right_bg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    rbg = ImageDraw.Draw(right_bg)

    ricon_grad = fast_gradient_pixels(app_icon_size, app_icon_size,
                                       (35, 45, 90), (30, 40, 80),
                                       (25, 35, 70), (20, 30, 60))
    ricon_img = Image.new("RGBA", (app_icon_size, app_icon_size))
    ricon_img.putdata(ricon_grad)

    rmask = Image.new("L", (app_icon_size, app_icon_size), 0)
    rmask_d = ImageDraw.Draw(rmask)
    rmask_d.rounded_rectangle(
        [0, 0, app_icon_size - 1, app_icon_size - 1],
        radius=app_icon_r, fill=255
    )

    ricon_with_mask = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ricon_with_mask.paste(ricon_img, (rx, ry), rmask)
    right_bg.paste(ricon_with_mask, (0, 0), ricon_with_mask)

    rbg.rounded_rectangle(
        [rx, ry, rx + app_icon_size - 1, ry + app_icon_size - 1],
        radius=app_icon_r,
        outline=(255, 255, 255, 80),
        width=max(3, int(size * 0.005)),
    )

    # Shadow under right icon
    rshadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    rs_r = int(app_icon_r * 0.9)
    rs_x = rx + int(size * 0.008)
    rs_y = ry + int(size * 0.012)
    rsd = ImageDraw.Draw(rshadow)
    rsd.rounded_rectangle(
        [rs_x, rs_y, rs_x + app_icon_size - 1, rs_y + app_icon_size - 1],
        radius=rs_r, fill=(0, 0, 0, 40),
    )
    rshadow = rshadow.filter(ImageFilter.GaussianBlur(radius=size * 0.015))
    img.paste(rshadow, (0, 0), rshadow)
    img.paste(right_bg, (0, 0), right_bg)

    # Small rounded rect inside right icon
    inner_rect_margin = int(app_icon_size * 0.22)
    inner_dots = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    idd = ImageDraw.Draw(inner_dots)
    idd.rounded_rectangle(
        [rx + inner_rect_margin, ry + inner_rect_margin,
         rx + app_icon_size - inner_rect_margin, ry + app_icon_size - inner_rect_margin],
        radius=int(app_icon_r * 0.6),
        fill=(255, 255, 255, 25),
    )
    img.paste(inner_dots, (0, 0), inner_dots)

    # ── 7. Swap arrow ──
    arrow_y = cy + int(app_icon_size * 0.68)
    arrow_span = int(app_icon_size * 0.55)
    arrow_w = max(5, int(size * 0.014))

    arrow_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arrow_layer)

    arrow_color = (255, 255, 255, 220)

    # Left arc
    l_bbox = [cx - arrow_span, arrow_y - arrow_span * 0.5,
              cx, arrow_y + arrow_span * 0.5]
    ad.arc(l_bbox, -5, 185, fill=arrow_color, width=arrow_w)

    # Right arc
    r_bbox = [cx, arrow_y - arrow_span * 0.5,
              cx + arrow_span, arrow_y + arrow_span * 0.5]
    ad.arc(r_bbox, -5, 185, fill=arrow_color, width=arrow_w)

    # Arrowheads
    head_s = int(arrow_w * 3.2)
    # Left arrowhead (pointing up-left)
    l_tx = int(cx - arrow_span + arrow_w * 0.5)
    l_ty = int(arrow_y - arrow_span * 0.48)
    ad.polygon([
        (l_tx, l_ty),
        (l_tx + head_s, l_ty - head_s // 2),
        (l_tx + head_s, l_ty + head_s // 2),
    ], fill=arrow_color)

    # Right arrowhead (pointing up-right)
    r_tx = int(cx + arrow_span - arrow_w * 0.5)
    r_ty = int(arrow_y - arrow_span * 0.48)
    ad.polygon([
        (r_tx, r_ty),
        (r_tx - head_s, r_ty - head_s // 2),
        (r_tx - head_s, r_ty + head_s // 2),
    ], fill=arrow_color)

    img.paste(arrow_layer, (0, 0), arrow_layer)

    # Center dot on the arrow
    dot_radius = max(5, int(size * 0.016))
    center_dot = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    cdd = ImageDraw.Draw(center_dot)
    cdd.ellipse([cx - dot_radius, arrow_y - dot_radius,
                 cx + dot_radius, arrow_y + dot_radius],
                fill=(255, 255, 255, 200))
    img.paste(center_dot, (0, 0), center_dot)

    # ── 8. Overall subtle drop shadow ──
    # Apply shadow outside the squircle
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # Create slightly offset, blurred squircle
    shadow_offset = int(size * 0.012)
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        [shadow_offset, shadow_offset + int(size * 0.02),
         size - 1 - shadow_offset, size - 1 - shadow_offset + int(size * 0.02)],
        radius=int(size * 0.225), fill=(0, 0, 0, 120),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=size * 0.03))
    # Composite: shadow behind, icon on top
    result = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    result.paste(shadow, (0, 0), shadow)
    result.paste(img, (0, 0), img)

    print(f"  Done.")
    return result


# ═══════════════════════════════════════════════════════════════════════════════
# Generate iconset and .icns
# ═══════════════════════════════════════════════════════════════════════════════

SIZES_MAP = {
    16:   ("icon_16x16.png",       "icon_16x16@2x.png"),
    32:   ("icon_32x32.png",       "icon_32x32@2x.png"),
    128:  ("icon_128x128.png",     "icon_128x128@2x.png"),
    256:  ("icon_256x256.png",     "icon_256x256@2x.png"),
    512:  ("icon_512x512.png",     "icon_512x512@2x.png"),
}


def generate_iconset(mode="light"):
    """Generate .iconset directory and convert to .icns."""
    label = "light" if mode == "light" else "dark"
    iconset_dir = os.path.join(OUTPUT_DIR, f"AppIcon-{label}.iconset")
    if os.path.exists(iconset_dir):
        shutil.rmtree(iconset_dir)
    os.makedirs(iconset_dir)

    master = create_icon(SIZE, mode)

    print(f"\nResizing {label} iconset...")
    for px_size, (name_1x, name_2x) in SIZES_MAP.items():
        img_1x = master.resize((px_size, px_size), Image.LANCZOS)
        img_1x.save(os.path.join(iconset_dir, name_1x), "PNG")
        img_2x = master.resize((px_size * 2, px_size * 2), Image.LANCZOS)
        img_2x.save(os.path.join(iconset_dir, name_2x), "PNG")
        print(f"  {px_size}px ✓")

    # Convert to .icns
    icns_name = f"AppIcon-{label}.icns"
    icns_path = os.path.join(RESOURCES_DIR, icns_name)
    print(f"  Converting to .icns...")
    subprocess.run(
        ["iconutil", "-c", "icns", iconset_dir, "-o", icns_path],
        check=True,
    )
    print(f"  ✅ {icns_name}")

    # Also save full-size PNG for runtime use
    png_name = f"AppIcon-{label}.png"
    png_path = os.path.join(RESOURCES_DIR, png_name)
    master.save(png_path, "PNG")
    print(f"  ✅ {png_name}")

    shutil.rmtree(iconset_dir)

    # Copy light to default AppIcon.icns
    if mode == "light":
        default_icns = os.path.join(RESOURCES_DIR, "AppIcon.icns")
        shutil.copy2(icns_path, default_icns)
        print(f"  ✅ AppIcon.icns (default)")

    return master


if __name__ == "__main__":
    os.makedirs(RESOURCES_DIR, exist_ok=True)

    print("═" * 50)
    print("ChangeIcon — macOS System Style Icon Generator")
    print("═" * 50)

    print("\n🌞 Generating LIGHT mode icon...")
    light_master = generate_iconset("light")

    print("\n🌙 Generating DARK mode icon...")
    dark_master = generate_iconset("dark")

    # Save previews
    light_master.save(os.path.join(OUTPUT_DIR, "AppIcon-light-preview.png"), "PNG")
    dark_master.save(os.path.join(OUTPUT_DIR, "AppIcon-dark-preview.png"), "PNG")

    print("\n" + "═" * 50)
    print("✅ All icons generated successfully!")
    print(f"   Light: {RESOURCES_DIR}/AppIcon-light.icns")
    print(f"   Dark:  {RESOURCES_DIR}/AppIcon-dark.icns")
    print(f"   Default: {RESOURCES_DIR}/AppIcon.icns")
    print("═" * 50)
