#!/usr/bin/env python3
"""
Piper OS - Alien Image Background Remover
Run this after placing alien images in the same directory.
Removes solid-color backgrounds and saves as transparent PNGs.

Usage: python3 process_aliens.py
"""

import os
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Installing Pillow...")
    os.system("pip3 install Pillow")
    from PIL import Image

ALIENS_DIR = Path(__file__).parent
OUTPUT_DIR = ALIENS_DIR / "processed"
OUTPUT_DIR.mkdir(exist_ok=True)

def get_bg_color(img, tolerance=30):
    """Sample corners to determine background color."""
    w, h = img.size
    corners = [
        img.getpixel((0, 0)),
        img.getpixel((w-1, 0)),
        img.getpixel((0, h-1)),
        img.getpixel((w-1, h-1)),
        img.getpixel((w//2, 0)),
    ]
    # Average corner colors
    r = sum(c[0] for c in corners) // len(corners)
    g = sum(c[1] for c in corners) // len(corners)
    b = sum(c[2] for c in corners) // len(corners)
    return (r, g, b)

def color_distance(c1, c2):
    return sum((a - b) ** 2 for a, b in zip(c1[:3], c2[:3])) ** 0.5

def remove_background(img_path, tolerance=40):
    """Remove the background color from a cartoon alien image."""
    img = Image.open(img_path).convert("RGBA")
    w, h = img.size

    bg_color = get_bg_color(img, tolerance)
    print(f"  Background color detected: rgb{bg_color}")

    data = img.getdata()
    new_data = []

    for pixel in data:
        r, g, b, a = pixel
        dist = color_distance((r, g, b), bg_color)

        if dist < tolerance:
            # Fully transparent
            new_data.append((r, g, b, 0))
        elif dist < tolerance * 1.5:
            # Semi-transparent edge feathering
            alpha = int(255 * (dist - tolerance) / (tolerance * 0.5))
            new_data.append((r, g, b, min(alpha, 255)))
        else:
            new_data.append(pixel)

    result = Image.new("RGBA", img.size)
    result.putdata(new_data)
    return result

def main():
    supported = {".jpg", ".jpeg", ".png", ".webp"}
    images = [f for f in ALIENS_DIR.iterdir()
              if f.suffix.lower() in supported and f.stem != "process_aliens"]

    if not images:
        print("No images found in", ALIENS_DIR)
        print("Place alien images (JPG/PNG) in this folder and re-run.")
        return

    print(f"Processing {len(images)} alien image(s)...\n")

    for img_path in sorted(images):
        print(f"[→] {img_path.name}")
        try:
            result = remove_background(img_path)
            out = OUTPUT_DIR / (img_path.stem + ".png")
            result.save(out, "PNG")
            print(f"  ✓ Saved → {out.name}\n")
        except Exception as e:
            print(f"  ✗ Failed: {e}\n")

    print(f"Done! {len(list(OUTPUT_DIR.glob('*.png')))} aliens processed.")
    print(f"Output folder: {OUTPUT_DIR}")

if __name__ == "__main__":
    main()
