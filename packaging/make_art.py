#!/usr/bin/env python3
"""Generates Fitzrovia Records DAW artwork with Pillow (pip install pillow):
  Resources/StudioForge.icns + Resources/StudioForge.png   app / document / volume icon
  packaging/assets/dmg_background.png (+ @2x)              DMG window background with drag arrow
Run from anywhere: python3 packaging/make_art.py
"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "packaging", "assets")
W, H = 640, 480  # DMG window content size (points)


def font(size, bold=True):
    for name in (["DejaVuSans-Bold.ttf", "Arial Bold.ttf", "Helvetica.ttc"] if bold else ["DejaVuSans.ttf", "Arial.ttf", "Helvetica.ttc"]):
        for d in ("/usr/share/fonts/truetype/dejavu", "/Library/Fonts", "/System/Library/Fonts", "/System/Library/Fonts/Supplemental", ""):
            try:
                return ImageFont.truetype(os.path.join(d, name), size)
            except OSError:
                continue
    return ImageFont.load_default()


def gradient(w, h, top, bottom):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def icon(size=1024):
    s = size
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle([s * .09, s * .09, s * .91, s * .91], radius=s * .19, fill=255)
    bg = gradient(s, s, (255, 120, 40), (150, 30, 90)).convert("RGBA")
    img.paste(bg, (0, 0), mask)
    d = ImageDraw.Draw(img)
    # Waveform bars (an anvil-like "forge" silhouette of sound).
    heights = [.18, .32, .52, .70, .46, .62, .38, .24, .14]
    bw = s * .055
    x0 = s * .5 - (len(heights) * bw * 1.6) / 2 + bw * .3
    for i, hgt in enumerate(heights):
        x = x0 + i * bw * 1.6
        hh = s * hgt * .55
        d.rounded_rectangle([x, s * .5 - hh / 2, x + bw, s * .5 + hh / 2], radius=bw / 2, fill=(255, 255, 255, 235))
    d.rounded_rectangle([s * .24, s * .70, s * .76, s * .735], radius=s * .02, fill=(255, 255, 255, 170))
    return img


def background(scale):
    w, h = W * scale, H * scale
    img = gradient(w, h, (34, 30, 44), (18, 16, 24)).convert("RGBA")
    d = ImageDraw.Draw(img)
    # Soft glow behind icon slots: pkg (320,140) is the main item; app (160,330) and Applications (480,330).
    for cx, cy, rad in ((320, 140, 110), (160, 330, 80), (480, 330, 80)):
        for r in range(rad, 0, -6):
            t = 0.25 * (1 - r / rad)  # opaque blend toward orange (ImageDraw does not alpha-blend)
            base = (28, 25, 36)
            col = tuple(int(base[i] + ((255, 140, 60)[i] - base[i]) * t) for i in range(3))
            d.ellipse([(cx - r) * scale, (cy - r) * scale, (cx + r) * scale, (cy + r) * scale], fill=col)
    y = 330 * scale
    d.line([(235 * scale, y), (390 * scale, y)], fill=(255, 150, 70, 255), width=6 * scale)
    d.polygon([(405 * scale, y), (380 * scale, y - 16 * scale), (380 * scale, y + 16 * scale)], fill=(255, 150, 70, 255))
    texts = (("Install Fitzrovia Records DAW", font(24 * scale), 16, (255, 255, 255)),
             ("Recommended: double-click \u201cInstall Fitzrovia Records DAW.pkg\u201d", font(14 * scale), 250, (255, 190, 140)),
             ("Or drag Fitzrovia Records DAW onto Applications", font(13 * scale, False), 405, (210, 210, 220)),
             ("Unsigned build? Control-click the item \u203a Open \u203a Open", font(12 * scale, False), 440, (160, 160, 175)))
    for text, fnt, yy, col in texts:
        tw = d.textlength(text, font=fnt)
        d.text(((w - tw) / 2, yy * scale), text, font=fnt, fill=col)
    return img.convert("RGB")


def main():
    os.makedirs(ASSETS, exist_ok=True)
    ic = icon()
    ic.save(os.path.join(ROOT, "Resources", "StudioForge.png"))
    ic.save(os.path.join(ROOT, "Resources", "StudioForge.icns"),
            sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    background(1).save(os.path.join(ASSETS, "dmg_background.png"), dpi=(72, 72))
    background(2).save(os.path.join(ASSETS, "dmg_background@2x.png"), dpi=(144, 144))
    print("Artwork written to Resources/ and packaging/assets/")


if __name__ == "__main__":
    main()
