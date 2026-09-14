#!/usr/bin/env python3
"""Generate WhisperSubtitler.ico (subtitle-themed app icon, multi-res 16-256px)."""
from PIL import Image, ImageDraw

SS = 8
S = 256
W = S * SS

def rr(d, box, radius, fill):
    d.rounded_rectangle(box, radius=radius, fill=fill)

img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# Rounded dark tile with vertical gradient
tile = Image.new("RGBA", (W, W), (0, 0, 0, 0))
td = ImageDraw.Draw(tile)
top, bot = (30, 32, 48), (15, 16, 26)
for y in range(W):
    t = y / W
    c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
    td.line([(0, y), (W, y)], fill=c + (255,))
mask = Image.new("L", (W, W), 0)
md = ImageDraw.Draw(mask)
md.rounded_rectangle([SS // 2] * 2 + [W - SS // 2] * 2, radius=58 * SS, fill=255)
img.paste(tile, (0, 0), mask)
d = ImageDraw.Draw(img)
d.rounded_rectangle([SS // 2] * 2 + [W - SS // 2] * 2, radius=58 * SS,
                    outline=(120, 130, 170, 70), width=SS)

# Gold subtitle bar (upper-left)
rr(d, [52 * SS, 62 * SS, 186 * SS, 122 * SS], 24 * SS, (232, 184, 76, 255))
for i, (x0, x1) in enumerate([(66, 84), (92, 148), (156, 172)]):
    rr(d, [x0 * SS, (76 + i * 15) * SS, x1 * SS, (80 + i * 15) * SS], 6 * SS, (25, 26, 38, 255))

# White subtitle bar (lower-right)
rr(d, [66 * SS, 152 * SS, 208 * SS, 212 * SS], 24 * SS, (238, 240, 248, 255))
for i, (x0, x1) in enumerate([(80, 96), (104, 160), (168, 180), (186, 194)]):
    rr(d, [x0 * SS, (166 + i * 14) * SS, x1 * SS, (170 + i * 14) * SS], 6 * SS, (35, 37, 52, 255))

# Blue play triangle accent
px, py = 196 * SS, 46 * SS
d.polygon([(px, py), (px, py + 34 * SS), (px + 30 * SS, py + 17 * SS)], fill=(91, 141, 239, 255))

# Multi-resolution ICO
sizes = (256, 128, 64, 48, 32, 24, 16)
frames = [img.resize((s, s), Image.Resampling.LANCZOS) for s in sizes]
frames[0].save("assets/WhisperSubtitler.ico", format="ICO",
               sizes=[(s, s) for s in sizes], append_images=frames[1:])

print("assets/WhisperSubtitler.ico written")
