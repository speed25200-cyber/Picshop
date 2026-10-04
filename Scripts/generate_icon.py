#!/usr/bin/env python3
"""PicShop's fallback app icon (W3): the PNG twin of App/AppIcon.icon, rendered with Pillow + numpy at 4× supersampling.

The design is the Icon Composer icon's, flattened: PicShop's mark (PSMark), the two crop corners in white with a soft
specular and a neutral shadow, and the spectral orb (#4285FF → #9A6BFF → #F5619E → #FF9E4D, PSTheme.intelligence) on a
graphite ground (#1E1E21 → #0A0A0C, top to bottom). Geometry, on the 1024-pixel canvas: the mark box is 640 px,
centred; each corner is inset 5 % of the box, its arms 42 %, its stroke 10 % with round caps; the orb's disc is 38 % of
the box at the mark's offset (0.47, 0.15).

It writes App/Assets.xcassets/AppIconLegacy.appiconset (light, dark, tinted 1024 px): the icon the app falls back to
when CI cannot compile the `.icon` (project.yml: set ASSETCATALOG_COMPILER_APPICON_NAME to AppIconLegacy).

    python3 Scripts/generate_icon.py                          # render the PNGs (numpy, Pillow)
    python3 Scripts/generate_icon.py --check-project <pbxproj> # standard library only

`--check-project` runs after `xcodegen generate` (GitHub CI, Codemagic): App/AppIcon.icon must be one file reference
of type `folder.iconcomposer.icon`, or actool will not compile it; the reference is patched when XcodeGen wrote another
type, and the run fails when the icon is missing from the project.
"""
import pathlib
import re
import sys

try:
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:  # --check-project needs neither
    np = None

OUT = pathlib.Path(__file__).resolve().parent.parent / "App/Assets.xcassets/AppIconLegacy.appiconset"
SIZE = 1024
SS = 4
S = SIZE * SS  # working resolution

# The mark on the canvas (fractions of SIZE), as in App/AppIcon.icon/Assets/*.svg.
BOX = 640 / SIZE
BOX_ORIGIN = (1 - BOX) / 2
INSET = 0.05 * BOX
ARM = 0.42 * BOX
STROKE = 0.10 * BOX
ORB_DIAMETER = 0.38 * BOX
ORB_ORIGIN = (BOX_ORIGIN + 0.47 * BOX, BOX_ORIGIN + 0.15 * BOX)
SPECTRUM = ["4285FF", "9A6BFF", "F5619E", "FF9E4D"]


def hexc(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float32) / 255


def vertical(top, bottom, size):
    t = np.linspace(0, 1, size, dtype=np.float32)[:, None, None]
    return np.broadcast_to(top * (1 - t) + bottom * t, (size, size, 3)).copy()


def composite(base, colour, alpha):
    a = np.clip(alpha, 0, 1)[..., None]
    return base * (1 - a) + colour * a


def blur(mask, radius):
    img = Image.fromarray((np.clip(mask, 0, 1) * 255).astype(np.uint8))
    return np.asarray(img.filter(ImageFilter.GaussianBlur(radius)), dtype=np.float32) / 255


def brackets_mask(size):
    """The two crop corners: round-capped strokes, as PSMarkBracket draws them."""
    px = lambda v: v * size  # noqa: E731
    layer = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(layer)
    width = px(STROKE)
    left, top = px(BOX_ORIGIN + INSET), px(BOX_ORIGIN + INSET)
    right, bottom = px(BOX_ORIGIN + BOX - INSET), px(BOX_ORIGIN + BOX - INSET)
    arm = px(ARM)
    corners = [[(left, top + arm), (left, top), (left + arm, top)], [(right, bottom - arm), (right, bottom), (right - arm, bottom)]]
    for points in corners:
        draw.line(points, fill=255, width=int(round(width)), joint="curve")
        for x, y in (points[0], points[1], points[2]):
            draw.ellipse([x - width / 2, y - width / 2, x + width / 2, y + width / 2], fill=255)
    return np.asarray(layer, dtype=np.float32) / 255


def orb(size, colours):
    """The orb's colour (a diagonal sweep through `colours`) and its disc mask."""
    radius = ORB_DIAMETER * size / 2
    cx, cy = (ORB_ORIGIN[0] + ORB_DIAMETER / 2) * size, (ORB_ORIGIN[1] + ORB_DIAMETER / 2) * size
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    t = np.clip(((x - (cx - radius)) + (y - (cy - radius))) / (4 * radius), 0, 1)
    stops = np.linspace(0, 1, len(colours))
    colour = np.zeros((size, size, 3), dtype=np.float32)
    for i in range(len(colours) - 1):
        k = np.clip((t - stops[i]) / (stops[i + 1] - stops[i]), 0, 1)[..., None]
        inside = ((t >= stops[i]) & (t <= stops[i + 1]))[..., None]
        colour = np.where(inside, colours[i] * (1 - k) + colours[i + 1] * k, colour)
    disc = np.clip(radius - np.hypot(x - cx, y - cy) + 0.5 * SS, 0, SS) / SS
    # Specular: a soft bloom toward the top left of the disc.
    bloom = np.clip(1 - np.hypot(x - (cx - radius * 0.3), y - (cy - radius * 0.35)) / (radius * 1.1), 0, 1) ** 2
    colour = colour * (1 - 0.28 * bloom[..., None]) + 0.28 * bloom[..., None]
    return colour, disc, (cx, cy, radius)


def render(variant="light"):
    s = S
    if variant == "tinted":
        # A grayscale icon: the system tints it. Black ground, white mark, a light gray orb.
        img = vertical(hexc("1A1A1A"), hexc("000000"), s)
        orb_colours = [hexc("F2F2F2"), hexc("D6D6D6"), hexc("BDBDBD"), hexc("A8A8A8")]
    else:
        top, bottom = (hexc("1E1E21"), hexc("0A0A0C")) if variant == "light" else (hexc("161618"), hexc("050506"))
        img = vertical(top, bottom, s)
        orb_colours = [hexc(c) for c in SPECTRUM]

    marks = brackets_mask(s)
    colour, disc, (cx, cy, radius) = orb(s, orb_colours)

    # Neutral shadows under both groups.
    shadow = blur(np.clip(marks + disc, 0, 1), 0.012 * s)
    shadow = np.roll(shadow, int(0.012 * s), axis=0)
    img = composite(img, hexc("000000"), shadow * 0.45)

    # The orb: its colour sweep, a soft glow, a thin rim of light.
    if variant != "tinted":
        glow = blur(disc, 0.03 * s)
        img = composite(img, colour, glow * 0.35)
    img = composite(img, colour, disc)
    y, x = np.mgrid[0:s, 0:s].astype(np.float32)
    rim = np.clip(1 - np.abs(np.hypot(x - cx, y - cy) - radius * 0.97) / (radius * 0.04), 0, 1) * disc
    upper = np.clip((cy - y) / radius, 0, 1)
    img = composite(img, hexc("FFFFFF"), rim * upper * 0.35)

    # The corners: white, with a specular gradient (brighter at the top) like Liquid Glass's highlight.
    specular = np.clip(1.0 - 0.10 * (y / s), 0.85, 1.0)[..., None]
    white = np.broadcast_to(hexc("FFFFFF"), (s, s, 3)) * specular
    img = composite(img, white, marks)

    out = Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB").resize((SIZE, SIZE), Image.LANCZOS)
    return out


CONTENTS = {
    "images": [
        {"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "AppIcon-Dark.png", "idiom": "universal",
         "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": "AppIcon-Tinted.png", "idiom": "universal",
         "platform": "ios", "size": "1024x1024"},
    ],
    "info": {"author": "xcode", "version": 1},
}


ICON_TYPE = "folder.iconcomposer.icon"


def check_project(pbxproj):
    """Makes AppIcon.icon's file reference a `folder.iconcomposer.icon`; False when the project has no such reference."""
    path = pathlib.Path(pbxproj)
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    found = False
    for index, line in enumerate(lines):
        if "isa = PBXFileReference" not in line or not re.search(r'path = "?AppIcon\.icon"?;', line):
            continue
        found = True
        if ICON_TYPE in line:
            continue
        if "lastKnownFileType = " in line:
            line = re.sub(r"lastKnownFileType = [^;]+;", f"lastKnownFileType = {ICON_TYPE};", line)
        else:
            line = line.replace("isa = PBXFileReference;", f"isa = PBXFileReference; lastKnownFileType = {ICON_TYPE};")
        lines[index] = line
        print("patched:", line.strip())
    if found:
        path.write_text("".join(lines), encoding="utf-8")
        print(f"AppIcon.icon: {ICON_TYPE}")
    return found


if __name__ == "__main__":
    import json

    if len(sys.argv) == 3 and sys.argv[1] == "--check-project":
        if not check_project(sys.argv[2]):
            print("::error::App/AppIcon.icon is not in the project: set ASSETCATALOG_COMPILER_APPICON_NAME to "
                  "AppIconLegacy in project.yml to ship the PNG icon")
            sys.exit(1)
        sys.exit(0)
    if np is None:
        sys.exit("rendering needs numpy and Pillow: pip install numpy pillow")
    OUT.mkdir(parents=True, exist_ok=True)
    for name, variant in [("AppIcon.png", "light"), ("AppIcon-Dark.png", "dark"), ("AppIcon-Tinted.png", "tinted")]:
        render(variant).save(OUT / name, optimize=True)
        print("wrote", name)
    (OUT / "Contents.json").write_text(json.dumps(CONTENTS, indent=2) + "\n", encoding="utf-8")
    print("wrote Contents.json")
