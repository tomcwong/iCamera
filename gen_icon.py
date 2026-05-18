#!/usr/bin/env python3
"""
Generate iCamera app icon:
  - Camera body outline (c01 style: body + viewfinder bump + lens ring)
  - AI chip inside lens (c02 style: outer box + inner border + 4 pins/side, no text)
  All in blue on dark-navy background.
"""
import math
from pathlib import Path
from PIL import Image, ImageDraw

# ── Colours ───────────────────────────────────────────────────────────────────
BG   = (8,  20,  60)      # deep navy   #08143C
BLUE = (50, 140, 255)     # vivid blue  #328CFF

# ── Master canvas ─────────────────────────────────────────────────────────────
S = 1024

# ── Camera body (matches c01 proportions) ─────────────────────────────────────
BL, BT, BR, BB = 55, 230, 969, 875   # left, top, right, bottom
BRX = 85                               # body corner radius

# ── Viewfinder bump (centered, on top of body) ────────────────────────────────
VL, VR = 390, 634          # bump left / right
VT     = 100               # bump top  (bump bottom == BT)
VRX    = 50                # bump corner radius

# ── Lens ring (centred in body) ───────────────────────────────────────────────
LCX = S // 2               # 512
LCY = (BT + BB) // 2       # 552
LR  = 186                  # lens radius

# ── Chip (centred inside lens, no text) ──────────────────────────────────────
CS   = 206          # chip outer side length
CL   = LCX - CS//2
CT   = LCY - CS//2
CR   = CL + CS
CB   = CT + CS
CRX  = 22           # chip corner radius
CSW  = 18           # chip body stroke
ISW  = 11           # inner border stroke
CIM  = 26           # inner border inset from chip edge

# ── Chip pins ─────────────────────────────────────────────────────────────────
PN    = 4    # pins per side
PLEN  = 32   # protrusion length
PW    = 11   # pin width
PRX   = 3    # pin tip radius

# ── Viewfinder indicator dot (top-left of camera body, like c01) ──────────────
VFX, VFY, VFR = 148, 305, 20

# ── Arc helper ────────────────────────────────────────────────────────────────
def arc(cx, cy, r, a0, a1, n=40):
    return [
        (cx + r * math.cos(math.radians(a0 + (a1-a0)*i/n)),
         cy + r * math.sin(math.radians(a0 + (a1-a0)*i/n)))
        for i in range(n+1)
    ]

# ── Build camera polygon ──────────────────────────────────────────────────────
#
#          ┌──────┐
#     ┌────┘      └────────────────────────┐
#     │  [dot]                             │
#     │            ┌──────────────┐        │
#     │            │  ┌────────┐  │        │
#     │            │  │ [chip] │  │        │
#     │            │  └────────┘  │        │
#     │            └──────────────┘        │
#     └────────────────────────────────────┘
#
pts  = arc(BL+BRX, BT+BRX, BRX, 180, 270)    # body top-left corner
pts += [(VL, BT), (VL, VT+VRX)]               # across top -> up bump-left
pts += arc(VL+VRX, VT+VRX, VRX, 180, 270)    # bump top-left corner
pts += [(VR-VRX, VT)]                          # across bump top
pts += arc(VR-VRX, VT+VRX, VRX, 270, 360)    # bump top-right corner
pts += [(VR, BT), (BR-BRX, BT)]               # down bump-right -> across body top
pts += arc(BR-BRX, BT+BRX, BRX, 270, 360)    # body top-right corner
pts += [(BR, BB-BRX)]                          # down right side
pts += arc(BR-BRX, BB-BRX, BRX, 0, 90)       # body bottom-right corner
pts += [(BL+BRX, BB)]                          # across bottom
pts += arc(BL+BRX, BB-BRX, BRX, 90, 180)     # body bottom-left corner
pts += [(BL, BT+BRX)]                          # up left side -> closes to first arc

# ── Render ────────────────────────────────────────────────────────────────────
RESAMPLER = getattr(Image, 'Resampling', Image).LANCZOS

img  = Image.new('RGBA', (S, S), (*BG, 255))
draw = ImageDraw.Draw(img)

SW = 24   # camera / lens stroke width

# Camera body fill + outline
draw.polygon(pts, fill=(*BG, 255))
try:
    draw.line(pts + [pts[0]], fill=(*BLUE, 255), width=SW, joint='curve')
except TypeError:
    draw.line(pts + [pts[0]], fill=(*BLUE, 255), width=SW)

# Viewfinder indicator dot
draw.ellipse(
    [VFX-VFR, VFY-VFR, VFX+VFR, VFY+VFR],
    fill=(*BG, 255), outline=(*BLUE, 255), width=SW-10
)

# Lens ring
draw.ellipse(
    [LCX-LR, LCY-LR, LCX+LR, LCY+LR],
    fill=(*BG, 255), outline=(*BLUE, 255), width=SW
)

# Chip outer body
draw.rounded_rectangle(
    [CL, CT, CR, CB],
    radius=CRX, fill=(*BG, 255), outline=(*BLUE, 255), width=CSW
)

# Chip inner border
draw.rounded_rectangle(
    [CL+CIM, CT+CIM, CR-CIM, CB-CIM],
    radius=max(CRX-8, 4), fill=(*BG, 255), outline=(*BLUE, 255), width=ISW
)

# Chip pins  (4 per side, evenly spaced)
gap = CS / (PN + 1)
xs  = [CL + gap*(i+1) for i in range(PN)]
ys  = [CT + gap*(i+1) for i in range(PN)]
hw  = PW / 2

for px in xs:
    draw.rounded_rectangle([px-hw, CT-PLEN, px+hw, CT],       radius=PRX, fill=(*BLUE,255))  # top
    draw.rounded_rectangle([px-hw, CB,      px+hw, CB+PLEN],  radius=PRX, fill=(*BLUE,255))  # bottom
for py in ys:
    draw.rounded_rectangle([CL-PLEN, py-hw, CL, py+hw],       radius=PRX, fill=(*BLUE,255))  # left
    draw.rounded_rectangle([CR,      py-hw, CR+PLEN, py+hw],  radius=PRX, fill=(*BLUE,255))  # right

# ── Save master preview ───────────────────────────────────────────────────────
BASE   = Path(r'C:\Users\tomcw\App_tcw3\iCamera')
master = BASE / 'icamera_icon_master.png'
img.save(str(master))
print(f'Master saved: {master}')

# ── Export Android mipmap sizes ───────────────────────────────────────────────
res_dir = BASE / 'android' / 'app' / 'src' / 'main' / 'res'
android_densities = [
    ('mipmap-mdpi',    48),
    ('mipmap-hdpi',    72),
    ('mipmap-xhdpi',   96),
    ('mipmap-xxhdpi',  144),
    ('mipmap-xxxhdpi', 192),
]
for density, sz in android_densities:
    out = res_dir / density / 'ic_launcher.png'
    img.resize((sz, sz), RESAMPLER).convert('RGB').save(str(out))
    print(f'  Android {density:20s}: {sz}×{sz}  -> {out.name}')

# ── Export adaptive icon foreground (correct canvas size: 108dp × density) ───
# Safe zone = 72dp of 108dp total (66.7%). Content scaled to 90% of safe zone
# so the full camera body is visible with a small margin inside the safe area.
adaptive_densities = [
    ('mipmap-mdpi',    108),
    ('mipmap-hdpi',    162),
    ('mipmap-xhdpi',   216),
    ('mipmap-xxhdpi',  324),
    ('mipmap-xxxhdpi', 432),
]
SAFE_RATIO  = 72 / 108          # safe zone = 72 dp of 108 dp total
FILL_RATIO  = 0.88              # fill 88% of the safe zone for a comfortable margin

for density, canvas_sz in adaptive_densities:
    safe_px    = int(canvas_sz * SAFE_RATIO)          # e.g. 288 px for xxxhdpi
    content_px = int(safe_px * FILL_RATIO)            # e.g. 253 px — icon drawing
    offset     = (canvas_sz - content_px) // 2        # centre on canvas

    icon_scaled = img.resize((content_px, content_px), RESAMPLER)
    canvas = Image.new('RGBA', (canvas_sz, canvas_sz), (*BG, 255))
    canvas.paste(icon_scaled, (offset, offset))

    out = res_dir / density / 'ic_launcher_foreground.png'
    canvas.convert('RGB').save(str(out))
    print(f'  Foreground {density:20s}: canvas={canvas_sz}×{canvas_sz}  '
          f'icon={content_px}×{content_px}  offset={offset}')

# ── Export iOS AppIcon sizes ───────────────────────────────────────────────────
ios_dir = BASE / 'ios' / 'Runner' / 'Assets.xcassets' / 'AppIcon.appiconset'
ios_sizes = [
    ('Icon-App-20x20@1x',      20),
    ('Icon-App-20x20@2x',      40),
    ('Icon-App-20x20@3x',      60),
    ('Icon-App-29x29@1x',      29),
    ('Icon-App-29x29@2x',      58),
    ('Icon-App-29x29@3x',      87),
    ('Icon-App-40x40@1x',      40),
    ('Icon-App-40x40@2x',      80),
    ('Icon-App-40x40@3x',     120),
    ('Icon-App-60x60@2x',     120),
    ('Icon-App-60x60@3x',     180),
    ('Icon-App-76x76@1x',      76),
    ('Icon-App-76x76@2x',     152),
    ('Icon-App-83.5x83.5@2x', 167),
    ('Icon-App-1024x1024@1x', 1024),
]
for name, sz in ios_sizes:
    out = ios_dir / f'{name}.png'
    img.resize((sz, sz), RESAMPLER).convert('RGB').save(str(out))
    print(f'  iOS {name:30s}: {sz}×{sz}')

print('\nAll icons generated.')
