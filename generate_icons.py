#!/usr/bin/env python3
"""
ChangeIcon App Icon — Dual Orb Design
Two overlapping translucent orbs (gold/warm + indigo/cool) 
representing the light/dark cycle. Clean, modern, distinctive.
"""

from PIL import Image, ImageDraw
import math, os, subprocess, shutil

SIZE = 1024
OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))

def squircle_mask(size, radius_ratio=0.225):
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    r = int(size * radius_ratio)
    draw.rounded_rectangle([(0, 0), (size - 1, size - 1)], radius=r, fill=255)
    return mask

def create_dual_orb_icon(size, is_dark):
    if is_dark:
        bg_color = (20, 21, 25, 255)
    else:
        bg_color = (245, 246, 250, 255)
    
    cx, cy = size // 2, size // 2
    orb_radius = int(size * 0.28)
    overlap = int(size * 0.18)
    
    # Orb 1 (Warm/Gold) - left
    orb1_cx = cx - overlap
    orb1_cy = cy
    orb1 = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    orb1_draw = ImageDraw.Draw(orb1)
    for y in range(size):
        for x in range(size):
            dx = x - orb1_cx
            dy = y - orb1_cy
            dist = math.sqrt(dx*dx + dy*dy)
            if dist < orb_radius:
                ratio = dist / orb_radius
                alpha = int(255 * (1 - ratio ** 2.5))
                r_val = int(255 * (1 - ratio * 0.3))
                g_val = int(200 * (1 - ratio * 0.4))
                b_val = int(80 * (1 - ratio * 0.5))
                orb1_draw.point((x, y), fill=(r_val, g_val, b_val, alpha))
    
    # Orb 2 (Cool/Indigo) - right
    orb2_cx = cx + overlap
    orb2_cy = cy
    orb2 = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    orb2_draw = ImageDraw.Draw(orb2)
    for y in range(size):
        for x in range(size):
            dx = x - orb2_cx
            dy = y - orb2_cy
            dist = math.sqrt(dx*dx + dy*dy)
            if dist < orb_radius:
                ratio = dist / orb_radius
                alpha = int(255 * (1 - ratio ** 2.5))
                r_val = int(100 * (1 - ratio * 0.3))
                g_val = int(130 * (1 - ratio * 0.4))
                b_val = int(240 * (1 - ratio * 0.3))
                orb2_draw.point((x, y), fill=(r_val, g_val, b_val, alpha))
    
    # Glow rings
    glow_radius = orb_radius + int(size * 0.04)
    glow1 = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow1_draw = ImageDraw.Draw(glow1)
    glow2 = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow2_draw = ImageDraw.Draw(glow2)
    for y in range(size):
        for x in range(size):
            for (gcx, gcy, glow, gdraw, clr) in [
                (orb1_cx, orb1_cy, glow1, glow1_draw, (255,200,80)),
                (orb2_cx, orb2_cy, glow2, glow2_draw, (100,130,255))
            ]:
                dx = x - gcx
                dy = y - gcy
                dist = math.sqrt(dx*dx + dy*dy)
                if orb_radius <= dist < glow_radius:
                    ratio = (dist - orb_radius) / (glow_radius - orb_radius)
                    alpha = int(80 * (1 - ratio))
                    gdraw.point((x, y), fill=(*clr, alpha))
    
    # Build composite
    base = Image.new("RGBA", (size, size), bg_color)
    result = Image.new("RGBA", (size, size), (0,0,0,0))
    result = Image.alpha_composite(result, base)
    result = Image.alpha_composite(result, glow1)
    result = Image.alpha_composite(result, glow2)
    result = Image.alpha_composite(result, orb2)
    result = Image.alpha_composite(result, orb1)
    
    # Apply squircle
    mask = squircle_mask(size)
    final = Image.new("RGBA", (size, size), (0,0,0,0))
    bg_layer = Image.new("RGBA", (size, size), bg_color)
    final = Image.composite(bg_layer, final, mask)
    final = Image.composite(result, final, mask)
    
    # Subtle border
    border_draw = ImageDraw.Draw(final)
    r = int(size * 0.225)
    border_draw.rounded_rectangle(
        [(2, 2), (size - 3, size - 3)],
        radius=r - 2,
        outline=(255, 255, 255, 30) if is_dark else (0, 0, 0, 20),
        width=2
    )
    
    return final

def create_iconset(icon_img, output_dir):
    os.makedirs(output_dir, exist_ok=True)
    sizes = {
        "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
    }
    for name, sz in sizes.items():
        icon_img.resize((sz, sz), Image.LANCZOS).save(os.path.join(output_dir, name))
    print(f"  Created iconset: {output_dir}")

def make_icns(iconset_dir, output_path):
    subprocess.run(
        ["iconutil", "-c", "icns", "-o", output_path, iconset_dir],
        check=True, capture_output=True
    )
    print(f"  Created: {output_path}")

if __name__ == "__main__":
    print("🎨 Generating Dual Orb icons...\n")
    
    print("[Light Icon]")
    light_icon = create_dual_orb_icon(SIZE, is_dark=False)
    light_png = os.path.join(OUTPUT_DIR, "AppIcon-light.png")
    light_icon.save(light_png)
    print(f"  Saved: {light_png}")
    create_iconset(light_icon, os.path.join(OUTPUT_DIR, "AppIcon-light.iconset"))
    make_icns(os.path.join(OUTPUT_DIR, "AppIcon-light.iconset"),
              os.path.join(OUTPUT_DIR, "AppIcon-light.icns"))
    
    print("\n[Dark Icon]")
    dark_icon = create_dual_orb_icon(SIZE, is_dark=True)
    dark_png = os.path.join(OUTPUT_DIR, "AppIcon-dark.png")
    dark_icon.save(dark_png)
    print(f"  Saved: {dark_png}")
    create_iconset(dark_icon, os.path.join(OUTPUT_DIR, "AppIcon-dark.iconset"))
    make_icns(os.path.join(OUTPUT_DIR, "AppIcon-dark.iconset"),
              os.path.join(OUTPUT_DIR, "AppIcon-dark.icns"))
    
    shutil.copy(os.path.join(OUTPUT_DIR, "AppIcon-light.icns"),
                os.path.join(OUTPUT_DIR, "AppIcon.icns"))
    print("\n✅ Done! Dual Orb icons ready.")
