#!/usr/bin/env python3
"""Generates the app icon PNGs (1024×1024) without external dependencies.

Design: deep indigo-to-violet gradient with a soft "voice orb" and a bright
aperture ring — the two ideas the app is built on (speak, and edit pixels).
"""
import math, struct, zlib, pathlib

SIZE = 1024
OUT = pathlib.Path(__file__).resolve().parent.parent / "App/Assets.xcassets/AppIcon.appiconset"

def png(path, pixels):
    raw = b"".join(b"\x00" + bytes(row) for row in pixels)
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

def lerp(a, b, t): return a + (b - a) * t

def render(variant):
    rows = []
    cx = cy = SIZE / 2
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            t = (x + y) / (2 * SIZE)
            if variant == "tinted":
                r, g, b = lerp(20, 60, t), lerp(20, 60, t), lerp(24, 70, t)
            elif variant == "dark":
                r, g, b = lerp(12, 40, t), lerp(10, 30, t), lerp(30, 90, t)
            else:
                r, g, b = lerp(30, 120, t), lerp(60, 70, t), lerp(200, 255, t)
            dx, dy = x - cx, y - cy
            d = math.hypot(dx, dy)
            # Aperture ring.
            ring = math.exp(-((d - 330) ** 2) / (2 * 22 ** 2))
            # Voice orb glow.
            orb = math.exp(-(d ** 2) / (2 * 150 ** 2))
            # Waveform bars inside the orb.
            bar = 0.0
            for i, h in enumerate([0.35, 0.7, 1.0, 0.6, 0.4]):
                bx = cx + (i - 2) * 58
                if abs(x - bx) < 18 and abs(dy) < 150 * h:
                    bar = 1.0
            white = min(1.0, ring * 0.9 + bar)
            r = lerp(r, 255, orb * 0.55)
            g = lerp(g, 255, orb * 0.35)
            b = lerp(b, 255, orb * 0.45)
            r, g, b = lerp(r, 255, white), lerp(g, 255, white), lerp(b, 255, white)
            row += [int(min(255, r)), int(min(255, g)), int(min(255, b)), 255]
        rows.append(row)
    return rows

OUT.mkdir(parents=True, exist_ok=True)
for name, variant in [("AppIcon.png", "light"), ("AppIcon-Dark.png", "dark"), ("AppIcon-Tinted.png", "tinted")]:
    png(OUT / name, render(variant))
    print("wrote", name)
