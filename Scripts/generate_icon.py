#!/usr/bin/env python3
"""Renders the PicShop app icon (1024×1024, light/dark/tinted) with no dependencies.

Design language: a deep blue-to-violet gradient ground, a softly rounded
white photo card with a warm sun and layered mountains (the universal
"photo" glyph), and a four-point AI sparkle. Shapes are signed-distance
functions rendered with 3×3 supersampling for clean antialiasing.
"""
import math, struct, zlib, pathlib

SIZE = 1024
SS = 2  # supersampling per axis
OUT = pathlib.Path(__file__).resolve().parent.parent / "App/Assets.xcassets/AppIcon.appiconset"

def clamp(v, lo=0.0, hi=1.0): return lo if v < lo else hi if v > hi else v
def lerp(a, b, t): return a + (b - a) * t
def mix(c1, c2, t): return tuple(lerp(a, b, t) for a, b in zip(c1, c2))
def smooth(edge0, edge1, x):
    t = clamp((x - edge0) / (edge1 - edge0)); return t * t * (3 - 2 * t)

def sd_round_rect(px, py, cx, cy, hw, hh, r):
    qx = abs(px - cx) - hw + r; qy = abs(py - cy) - hh + r
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r

def sd_circle(px, py, cx, cy, r): return math.hypot(px - cx, py - cy) - r

def sd_polygon(px, py, verts):
    """Signed distance to a simple polygon (negative inside)."""
    n = len(verts)
    d = float("inf")
    sign = 1.0
    j = n - 1
    for i in range(n):
        ax, ay = verts[i]; bx, by = verts[j]
        ex, ey = bx - ax, by - ay
        wx, wy = px - ax, py - ay
        t = clamp((wx * ex + wy * ey) / (ex * ex + ey * ey))
        d = min(d, math.hypot(wx - t * ex, wy - t * ey))
        # Winding (crossing) test.
        c1 = py >= ay; c2 = py < by; c3 = ex * wy > ey * wx
        if (c1 and c2 and c3) or ((not c1) and (not c2) and (not c3)):
            sign = -sign
        j = i
    return sign * d

def sd_star4(px, py, cx, cy, r, k=0.26):
    verts = []
    for i in range(8):
        ang = i * math.pi / 4
        rad = r if i % 2 == 0 else r * k
        verts.append((cx + math.cos(ang) * rad, cy + math.sin(ang) * rad))
    return sd_polygon(px, py, verts)

def sd_mountain(px, py, apex_x, apex_y, half_base, base_y):
    return sd_polygon(px, py, [(apex_x, apex_y), (apex_x + half_base, base_y), (apex_x - half_base, base_y)])

def coverage(d, aa=1.0): return 1 - smooth(-aa, aa, d)

def shade(variant, x, y):
    u, v = x / SIZE, y / SIZE
    # Ground gradient.
    if variant == "tinted":
        top, bottom = (0.16, 0.16, 0.20), (0.36, 0.36, 0.42)
    elif variant == "dark":
        top, bottom = (0.05, 0.06, 0.16), (0.20, 0.10, 0.40)
    else:
        top, bottom = (0.10, 0.20, 0.72), (0.46, 0.20, 0.86)
    c = mix(top, bottom, clamp(0.15 * u + 0.85 * v))
    # Soft light bloom top-left.
    bloom = math.exp(-((u - 0.28) ** 2 + (v - 0.22) ** 2) / 0.09)
    c = mix(c, (0.55, 0.65, 1.0) if variant != "tinted" else (0.6, 0.6, 0.65), 0.35 * bloom)

    # Photo card (tilted slightly) — drawn as a rounded rect with a subtle shadow.
    cx, cy = SIZE * 0.5, SIZE * 0.53
    ang = -0.09
    rx = math.cos(ang) * (x - cx) - math.sin(ang) * (y - cy) + cx
    ry = math.sin(ang) * (x - cx) + math.cos(ang) * (y - cy) + cy
    card = sd_round_rect(rx, ry, cx, cy, SIZE * 0.30, SIZE * 0.30, SIZE * 0.075)
    shadow = coverage(card - SIZE * 0.02, SIZE * 0.06)
    c = mix(c, (0.02, 0.02, 0.08), 0.35 * shadow * (1 - coverage(card)))
    card_cov = coverage(card)
    white = (0.985, 0.985, 1.0) if variant != "tinted" else (0.92, 0.92, 0.95)
    c = mix(c, white, card_cov)

    # Inside the card: sky gradient, sun, mountains — inset panel.
    inner = sd_round_rect(rx, ry, cx, cy, SIZE * 0.245, SIZE * 0.245, SIZE * 0.05)
    inner_cov = coverage(inner)
    if inner_cov > 0:
        iv = clamp((ry - (cy - SIZE * 0.245)) / (SIZE * 0.49))
        if variant == "tinted":
            sky = mix((0.62, 0.62, 0.68), (0.45, 0.45, 0.52), iv)
        else:
            sky = mix((0.55, 0.78, 1.0), (0.98, 0.72, 0.55), iv)
        panel = sky
        # Sun.
        sun = coverage(sd_circle(rx, ry, cx + SIZE * 0.09, cy - SIZE * 0.13, SIZE * 0.06))
        sun_col = (1.0, 0.90, 0.45) if variant != "tinted" else (0.9, 0.9, 0.95)
        glow = math.exp(-((rx - (cx + SIZE * 0.09)) ** 2 + (ry - (cy - SIZE * 0.13)) ** 2) / (2 * (SIZE * 0.09) ** 2))
        panel = mix(panel, sun_col, 0.35 * glow)
        panel = mix(panel, sun_col, sun)
        # Back mountain.
        m1 = coverage(sd_mountain(rx, ry, cx - SIZE * 0.08, cy + SIZE * 0.0, SIZE * 0.30, cy + SIZE * 0.26))
        col1 = (0.30, 0.42, 0.78) if variant != "tinted" else (0.40, 0.40, 0.46)
        panel = mix(panel, col1, m1)
        # Front mountain.
        m2 = coverage(sd_mountain(rx, ry, cx + SIZE * 0.12, cy + SIZE * 0.07, SIZE * 0.24, cy + SIZE * 0.26))
        col2 = (0.16, 0.24, 0.55) if variant != "tinted" else (0.28, 0.28, 0.34)
        panel = mix(panel, col2, m2)
        c = mix(c, panel, inner_cov)

    # AI sparkle, top-right, overlapping the card edge.
    sx, sy = SIZE * 0.79, SIZE * 0.23
    big = coverage(sd_star4(x, y, sx, sy, SIZE * 0.13), 1.2)
    small = coverage(sd_star4(x, y, sx - SIZE * 0.12, sy + SIZE * 0.11, SIZE * 0.05), 1.2)
    spark_glow = math.exp(-((x - sx) ** 2 + (y - sy) ** 2) / (2 * (SIZE * 0.11) ** 2))
    spark_col = (1.0, 1.0, 1.0)
    c = mix(c, (0.85, 0.9, 1.0), 0.25 * spark_glow)
    c = mix(c, spark_col, max(big, small))
    return c

def render(variant):
    rows = []
    inv = 1.0 / (SS * SS)
    for y in range(SIZE):
        row = bytearray()
        for x in range(SIZE):
            r = g = b = 0.0
            for j in range(SS):
                for i in range(SS):
                    cr, cg, cb = shade(variant, x + (i + 0.5) / SS, y + (j + 0.5) / SS)
                    r += cr; g += cg; b += cb
            row += bytes((int(clamp(r * inv) * 255 + 0.5), int(clamp(g * inv) * 255 + 0.5), int(clamp(b * inv) * 255 + 0.5), 255))
        rows.append(bytes(row))
    return rows

def png(path, rows):
    raw = b"".join(b"\x00" + r for r in rows)
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for name, variant in [("AppIcon.png", "light"), ("AppIcon-Dark.png", "dark"), ("AppIcon-Tinted.png", "tinted")]:
        png(OUT / name, render(variant))
        print("wrote", name)
