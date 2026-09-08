#!/usr/bin/env python3
"""PicShop app icon — rendered with Pillow + numpy at 4× supersampling.

Concept: a glass camera lens with a luminous aperture ring and a voice
waveform at its heart, on a deep indigo → violet → magenta ground. One idea,
bold silhouette, rich but restrained lighting — the way Apple's own icons read
at 60 px and at 1024 px alike.
"""
import math, pathlib
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = pathlib.Path(__file__).resolve().parent.parent / "App/Assets.xcassets/AppIcon.appiconset"
SIZE = 1024
SS = 4
S = SIZE * SS  # working resolution


def lerp(a, b, t):
    return a + (b - a) * t


def hexc(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float32) / 255


def gradient(stops, angle_deg, size):
    """Linear gradient across the square: stops = [(t, colour)]."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float32) / (size - 1)
    a = math.radians(angle_deg)
    t = (x * math.cos(a) + y * math.sin(a))
    t = (t - t.min()) / (t.max() - t.min())
    out = np.zeros((size, size, 3), dtype=np.float32)
    for i in range(len(stops) - 1):
        t0, c0 = stops[i]
        t1, c1 = stops[i + 1]
        m = (t >= t0) & (t <= t1)
        k = ((t[m] - t0) / max(1e-6, t1 - t0))[:, None]
        out[m] = c0 * (1 - k) + c1 * k
    return out


def radial(center, radius, size, inner=1.0, outer=0.0, power=1.0):
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    d = np.hypot(x - center[0], y - center[1]) / radius
    d = np.clip(d, 0, 1) ** power
    return inner * (1 - d) + outer * d


def ellipse_mask(cx, cy, rx, ry, size, feather=0):
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    d = np.hypot((x - cx) / rx, (y - cy) / ry)
    if feather <= 0:
        return (d <= 1).astype(np.float32)
    return np.clip((1 - d) * (rx / max(1, feather)) + 0.5, 0, 1)


def rounded_rect_mask(x0, y0, x1, y1, r, size):
    img = Image.new("L", (size, size), 0)
    ImageDraw.Draw(img).rounded_rectangle([x0, y0, x1, y1], radius=r, fill=255)
    return np.asarray(img, dtype=np.float32) / 255


def polygon_mask(points, size):
    img = Image.new("L", (size, size), 0)
    ImageDraw.Draw(img).polygon(points, fill=255)
    return np.asarray(img, dtype=np.float32) / 255


def blur(mask, radius):
    img = Image.fromarray((np.clip(mask, 0, 1) * 255).astype(np.uint8))
    return np.asarray(img.filter(ImageFilter.GaussianBlur(radius)), dtype=np.float32) / 255


def composite(base, colour, alpha):
    a = np.clip(alpha, 0, 1)[..., None]
    return base * (1 - a) + colour * a


def star_points(cx, cy, r, inner, n=4, rotation=-90):
    pts = []
    for i in range(n * 2):
        ang = math.radians(rotation + i * 180 / n)
        rad = r if i % 2 == 0 else inner
        pts.append((cx + math.cos(ang) * rad, cy + math.sin(ang) * rad))
    return pts


def render(variant="light"):
    s = S
    c = lambda v: v * s  # noqa: E731
    palettes = {
        "light": dict(bg=[(0.0, hexc("1A1B4B")), (0.45, hexc("3B2FB8")), (0.78, hexc("8A35C9")), (1.0, hexc("E24A8A"))],
                      ring=[hexc("FFE29A"), hexc("FF8A5C"), hexc("FF4D8D"), hexc("8C5BFF"), hexc("4FC3FF")],
                      glass=hexc("0B0C2A"), wave=hexc("FFFFFF")),
        "dark": dict(bg=[(0.0, hexc("0A0B22")), (0.5, hexc("1C1660")), (0.8, hexc("4B1D7A")), (1.0, hexc("7A1F52"))],
                     ring=[hexc("FFD27A"), hexc("FF7A4C"), hexc("F0407C"), hexc("7C4DFF"), hexc("3FB6FF")],
                     glass=hexc("06071A"), wave=hexc("FFFFFF")),
        "tinted": dict(bg=[(0.0, hexc("2A2A2E")), (1.0, hexc("515158"))],
                       ring=[hexc("FFFFFF"), hexc("D9D9DE"), hexc("FFFFFF"), hexc("C8C8CF"), hexc("FFFFFF")],
                       glass=hexc("18181C"), wave=hexc("FFFFFF")),
    }
    pal = palettes[variant]

    # ---- Ground: diagonal gradient + soft top-left bloom + faint vignette.
    img = gradient(pal["bg"], 58, s)
    bloom = radial((c(0.18), c(0.12)), c(0.9), s, inner=1, outer=0, power=1.6)
    img = composite(img, hexc("9AA6FF") if variant != "tinted" else hexc("8A8A92"), bloom * 0.22)
    vignette = radial((c(0.5), c(0.55)), c(0.95), s, inner=0, outer=1, power=2.2)
    img = composite(img, hexc("06061A"), vignette * 0.28)

    cx, cy = c(0.5), c(0.52)
    R = c(0.335)  # lens outer radius

    # ---- Lens shadow (grounds the object).
    shadow = blur(ellipse_mask(cx, cy + c(0.06), R * 1.05, R * 1.0, s), c(0.045))
    img = composite(img, hexc("05051A"), shadow * 0.55)

    # ---- Aperture ring: angular light sweep through the palette.
    y, x = np.mgrid[0:s, 0:s].astype(np.float32)
    ang = (np.arctan2(y - cy, x - cx) + math.pi) / (2 * math.pi)  # 0…1 around
    ring_col = np.zeros((s, s, 3), dtype=np.float32)
    stops = pal["ring"] + [pal["ring"][0]]
    seg = len(stops) - 1
    pos = ang * seg
    idx = np.clip(pos.astype(np.int32), 0, seg - 1)
    frac = (pos - idx)[..., None]
    stops_arr = np.stack(stops)
    ring_col = stops_arr[idx] * (1 - frac) + stops_arr[idx + 1] * frac
    # Radial shading so the ring reads as a bevelled metal/glass torus.
    rdist = np.hypot(x - cx, y - cy)
    outer_r, inner_r = R, R * 0.80
    ring_mask = ((rdist <= outer_r) & (rdist >= inner_r)).astype(np.float32)
    ring_mask = blur(ring_mask, c(0.0012))
    tube = np.clip(1 - np.abs((rdist - (outer_r + inner_r) / 2) / ((outer_r - inner_r) / 2)), 0, 1)
    shade = 0.55 + 0.6 * tube ** 1.5
    light_dir = np.clip(((cx - x) * 0.6 + (cy - y) * 0.8) / R, -1, 1)  # brighter top-left
    shade = shade * (1 + 0.25 * light_dir)
    ring_rgb = np.clip(ring_col * shade[..., None], 0, 1)
    img = composite(img, ring_rgb, ring_mask)
    # Ring outer glow.
    glow = blur(ellipse_mask(cx, cy, R * 1.02, R * 1.02, s), c(0.03)) * (1 - ellipse_mask(cx, cy, R, R, s))
    img = composite(img, np.clip(ring_col * 1.1, 0, 1), glow * 0.35)

    # ---- Glass interior: deep disc with a diagonal reflection and inner rim shadow.
    inner = ellipse_mask(cx, cy, inner_r, inner_r, s)
    inner_soft = blur(inner, c(0.0012))
    glass = np.zeros_like(img) + pal["glass"]
    depth = radial((cx - R * 0.25, cy - R * 0.25), inner_r * 1.4, s, inner=1, outer=0, power=1.3)
    glass = composite(glass, hexc("2B2E7A") if variant != "tinted" else hexc("34343A"), depth * 0.9)
    rim = np.clip((rdist - inner_r * 0.82) / (inner_r * 0.18), 0, 1) ** 1.6
    glass = composite(glass, hexc("000010"), rim * 0.75)
    img = composite(img, glass, inner_soft)
    # Reflection: crescent highlight top-left, faint.
    refl = ellipse_mask(cx - R * 0.16, cy - R * 0.22, inner_r * 0.86, inner_r * 0.62, s) * (1 - ellipse_mask(cx - R * 0.02, cy - R * 0.02, inner_r * 0.86, inner_r * 0.66, s))
    refl = blur(refl, c(0.01)) * inner
    img = composite(img, hexc("FFFFFF"), refl * 0.16)

    # ---- Voice waveform: five capsule bars, white with a soft glow.
    bars = [0.30, 0.62, 1.0, 0.72, 0.42]
    bar_w = inner_r * 0.135
    gap = inner_r * 0.20
    total = len(bars) * bar_w + (len(bars) - 1) * (gap - bar_w) 
    xs = [cx - (len(bars) - 1) / 2 * gap + i * gap for i in range(len(bars))]
    wave = np.zeros((s, s), dtype=np.float32)
    layer = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(layer)
    for xb, h in zip(xs, bars):
        half = inner_r * 0.62 * h
        d.rounded_rectangle([xb - bar_w / 2, cy - half, xb + bar_w / 2, cy + half], radius=bar_w / 2, fill=255)
    wave = np.asarray(layer, dtype=np.float32) / 255
    img = composite(img, pal["wave"], blur(wave, c(0.02)) * 0.45)  # glow
    img = composite(img, pal["wave"], wave)

    # ---- AI sparkle riding the ring at the top-right.
    sx, sy = cx + R * 0.72, cy - R * 0.72
    spark = polygon_mask(star_points(sx, sy, R * 0.30, R * 0.085), s)
    spark_small = polygon_mask(star_points(sx - R * 0.30, sy + R * 0.30, R * 0.11, R * 0.035), s)
    sparkle = np.clip(spark + spark_small, 0, 1)
    img = composite(img, hexc("FFFFFF"), blur(sparkle, c(0.03)) * 0.55)
    img = composite(img, hexc("FFFFFF"), sparkle)

    # ---- Film grain for a print-like finish (very subtle).
    rng = np.random.default_rng(7)
    grain = rng.normal(0, 0.012, (s, s, 1)).astype(np.float32)
    img = np.clip(img + grain, 0, 1)

    out = Image.fromarray((img * 255 + 0.5).astype(np.uint8), "RGB").resize((SIZE, SIZE), Image.LANCZOS)
    return out


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for name, variant in [("AppIcon.png", "light"), ("AppIcon-Dark.png", "dark"), ("AppIcon-Tinted.png", "tinted")]:
        render(variant).save(OUT / name, optimize=True)
        print("wrote", name)
