#!/usr/bin/env python3
"""Renders the Cutline app icon (1024x1024, no alpha)."""
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 1024
img = Image.new("RGB", (S, S))
px = img.load()
top, bottom = (255, 82, 92), (120, 40, 200)
for y in range(S):
    t = y / (S - 1)
    c = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
    for x in range(S):
        px[x, y] = c
d = ImageDraw.Draw(img)
# Film strip
d.rounded_rectangle((170, 300, 854, 724), radius=70, fill=(18, 18, 24))
for i in range(6):
    x = 215 + i * 110
    d.rounded_rectangle((x, 325, x + 55, 360), radius=10, fill=(255, 255, 255))
    d.rounded_rectangle((x, 664, x + 55, 699), radius=10, fill=(255, 255, 255))
# Cut line
shadow = Image.new("L", (S, S), 0)
sd = ImageDraw.Draw(shadow)
sd.line((640, 170, 384, 854), fill=180, width=70)
shadow = shadow.filter(ImageFilter.GaussianBlur(18))
img.paste((0, 0, 0), (0, 0), shadow.point(lambda v: v // 3))
d.line((640, 170, 384, 854), fill=(255, 255, 255), width=56)
d.ellipse((610, 140, 670, 200), fill=(255, 255, 255))
d.ellipse((354, 824, 414, 884), fill=(255, 255, 255))
img.save(os.path.join(ROOT, "Cutline/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
print("icon written")
