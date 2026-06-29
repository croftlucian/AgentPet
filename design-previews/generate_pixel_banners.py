#!/usr/bin/env python3
"""生成桌宠横幅像素风预览图。

脚本只依赖 Python 标准库，便于在没有图像处理库的环境中复现预览素材。
"""

from __future__ import annotations

import os
import random
import struct
import zlib
from dataclasses import dataclass


W, H = 400, 120
SCALE = 3
OUT_DIR = os.path.dirname(__file__)

Color = tuple[int, int, int, int]


@dataclass(frozen=True)
class Palette:
    ink: Color = (30, 31, 36, 255)
    coal: Color = (18, 20, 29, 255)
    night: Color = (28, 34, 60, 255)
    coral: Color = (229, 105, 72, 255)
    coral_dark: Color = (174, 70, 57, 255)
    cream: Color = (255, 244, 232, 255)
    gold: Color = (255, 203, 79, 255)
    mint: Color = (92, 201, 159, 255)
    cyan: Color = (93, 189, 220, 255)
    lilac: Color = (158, 139, 215, 255)
    rose: Color = (239, 133, 151, 255)
    sky: Color = (111, 202, 231, 255)
    grass: Color = (92, 185, 114, 255)
    wood: Color = (151, 96, 68, 255)
    shadow: Color = (0, 0, 0, 70)


P = Palette()


FONT = {
    "A": ("01110", "10001", "10001", "11111", "10001", "10001", "10001"),
    "B": ("11110", "10001", "10001", "11110", "10001", "10001", "11110"),
    "C": ("01111", "10000", "10000", "10000", "10000", "10000", "01111"),
    "D": ("11110", "10001", "10001", "10001", "10001", "10001", "11110"),
    "E": ("11111", "10000", "10000", "11110", "10000", "10000", "11111"),
    "G": ("01111", "10000", "10000", "10111", "10001", "10001", "01111"),
    "H": ("10001", "10001", "10001", "11111", "10001", "10001", "10001"),
    "I": ("11111", "00100", "00100", "00100", "00100", "00100", "11111"),
    "J": ("00111", "00010", "00010", "00010", "10010", "10010", "01100"),
    "K": ("10001", "10010", "10100", "11000", "10100", "10010", "10001"),
    "L": ("10000", "10000", "10000", "10000", "10000", "10000", "11111"),
    "M": ("10001", "11011", "10101", "10101", "10001", "10001", "10001"),
    "N": ("10001", "11001", "10101", "10011", "10001", "10001", "10001"),
    "O": ("01110", "10001", "10001", "10001", "10001", "10001", "01110"),
    "P": ("11110", "10001", "10001", "11110", "10000", "10000", "10000"),
    "R": ("11110", "10001", "10001", "11110", "10100", "10010", "10001"),
    "S": ("01111", "10000", "10000", "01110", "00001", "00001", "11110"),
    "T": ("11111", "00100", "00100", "00100", "00100", "00100", "00100"),
    "U": ("10001", "10001", "10001", "10001", "10001", "10001", "01110"),
    "V": ("10001", "10001", "10001", "10001", "10001", "01010", "00100"),
    "W": ("10001", "10001", "10001", "10101", "10101", "10101", "01010"),
    "X": ("10001", "01010", "00100", "00100", "00100", "01010", "10001"),
    "Y": ("10001", "01010", "00100", "00100", "00100", "00100", "00100"),
    "0": ("01110", "10001", "10011", "10101", "11001", "10001", "01110"),
    "1": ("00100", "01100", "00100", "00100", "00100", "00100", "01110"),
    "2": ("01110", "10001", "00001", "00010", "00100", "01000", "11111"),
    "3": ("11110", "00001", "00001", "01110", "00001", "00001", "11110"),
    "4": ("10010", "10010", "10010", "11111", "00010", "00010", "00010"),
    "5": ("11111", "10000", "10000", "11110", "00001", "00001", "11110"),
    "6": ("01111", "10000", "10000", "11110", "10001", "10001", "01110"),
    "7": ("11111", "00001", "00010", "00100", "01000", "01000", "01000"),
    "8": ("01110", "10001", "10001", "01110", "10001", "10001", "01110"),
    "9": ("01110", "10001", "10001", "01111", "00001", "00001", "11110"),
    ":": ("00000", "00100", "00100", "00000", "00100", "00100", "00000"),
    "-": ("00000", "00000", "00000", "11111", "00000", "00000", "00000"),
    " ": ("00000", "00000", "00000", "00000", "00000", "00000", "00000"),
}


class Canvas:
    def __init__(self, bg: Color) -> None:
        self.px = [[bg for _ in range(W)] for _ in range(H)]

    def set(self, x: int, y: int, c: Color) -> None:
        if 0 <= x < W and 0 <= y < H:
            self.px[y][x] = c

    def rect(self, x: int, y: int, w: int, h: int, c: Color) -> None:
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                self.set(xx, yy, c)

    def outline_rect(self, x: int, y: int, w: int, h: int, c: Color, t: int = 2) -> None:
        self.rect(x, y, w, t, c)
        self.rect(x, y + h - t, w, t, c)
        self.rect(x, y, t, h, c)
        self.rect(x + w - t, y, t, h, c)

    def line(self, x0: int, y0: int, x1: int, y1: int, c: Color) -> None:
        dx = abs(x1 - x0)
        sx = 1 if x0 < x1 else -1
        dy = -abs(y1 - y0)
        sy = 1 if y0 < y1 else -1
        err = dx + dy
        while True:
            self.set(x0, y0, c)
            if x0 == x1 and y0 == y1:
                break
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy

    def polygon(self, pts: list[tuple[int, int]], c: Color) -> None:
        min_y = max(min(y for _, y in pts), 0)
        max_y = min(max(y for _, y in pts), H - 1)
        for y in range(min_y, max_y + 1):
            nodes: list[int] = []
            j = len(pts) - 1
            for i, (xi, yi) in enumerate(pts):
                xj, yj = pts[j]
                if (yi < y <= yj) or (yj < y <= yi):
                    nodes.append(int(xi + (y - yi) / (yj - yi) * (xj - xi)))
                j = i
            nodes.sort()
            for a, b in zip(nodes[0::2], nodes[1::2]):
                self.rect(a, y, b - a + 1, 1, c)

    def text(self, x: int, y: int, s: str, c: Color, scale: int = 1) -> None:
        cx = x
        for ch in s.upper():
            glyph = FONT.get(ch, FONT[" "])
            for gy, row in enumerate(glyph):
                for gx, bit in enumerate(row):
                    if bit == "1":
                        self.rect(cx + gx * scale, y + gy * scale, scale, scale, c)
            cx += 6 * scale


def write_png_pixels(path: str, pixels: list[list[Color]], scale: int = SCALE) -> None:
    width, height = len(pixels[0]) * scale, len(pixels) * scale
    rows = []
    for y in range(height):
        src_y = y // scale
        row = bytearray([0])
        for x in range(width):
            row.extend(pixels[src_y][x // scale])
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(kind: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def write_png(path: str, canvas: Canvas) -> None:
    write_png_pixels(path, canvas.px)


def write_contact_sheet(path: str, items: list[tuple[str, Canvas]]) -> None:
    gap = 6
    label_h = 12
    cols = 2
    rows = (len(items) + cols - 1) // cols
    sheet_w = cols * W + (cols + 1) * gap
    sheet_h = rows * (H + label_h) + (rows + 1) * gap
    pixels = [[P.ink for _ in range(sheet_w)] for _ in range(sheet_h)]

    def put_rect(x: int, y: int, w: int, h: int, color: Color) -> None:
        for yy in range(max(y, 0), min(y + h, sheet_h)):
            for xx in range(max(x, 0), min(x + w, sheet_w)):
                pixels[yy][xx] = color

    label_canvas = Canvas(P.ink)
    for idx, (label, canvas) in enumerate(items):
        col = idx % cols
        row = idx // cols
        ox = gap + col * (W + gap)
        oy = gap + row * (H + label_h + gap)
        for y in range(H):
            for x in range(W):
                pixels[oy + label_h + y][ox + x] = canvas.px[y][x]
        put_rect(ox, oy, W, label_h, P.coal)
        label_canvas.px = pixels
        label_canvas.text(ox + 4, oy + 3, label, P.cream, 1)

    write_png_pixels(path, pixels, scale=2)


def sparkle(c: Canvas, x: int, y: int, color: Color = P.cream) -> None:
    c.set(x, y, color)
    c.set(x - 1, y, color)
    c.set(x + 1, y, color)
    c.set(x, y - 1, color)
    c.set(x, y + 1, color)


def pet_burst(c: Canvas, cx: int, cy: int, r: int, body: Color = P.cream, glow: Color = P.gold) -> None:
    rays = [
        (0, -r),
        (5, -13),
        (14, -17),
        (12, -5),
        (24, 0),
        (12, 5),
        (17, 16),
        (5, 12),
        (0, 24),
        (-5, 12),
        (-17, 16),
        (-12, 5),
        (-24, 0),
        (-12, -5),
        (-14, -17),
        (-5, -13),
    ]
    for ox, oy in rays[::2]:
        c.line(cx, cy, cx + ox, cy + oy, glow)
        c.line(cx + 1, cy, cx + ox, cy + oy, glow)
    c.rect(cx - 7, cy - 7, 14, 14, body)
    c.rect(cx - 11, cy - 3, 22, 6, body)
    c.rect(cx - 3, cy - 11, 6, 22, body)
    c.set(cx - 3, cy - 2, P.ink)
    c.set(cx + 3, cy - 2, P.ink)
    c.rect(cx - 2, cy + 4, 5, 1, P.coral_dark)


def draw_grid(c: Canvas, color: Color, step: int = 8) -> None:
    for x in range(0, W, step):
        for y in range(0, H, step):
            c.set(x, y, color)


def banner_starry() -> Canvas:
    c = Canvas(P.night)
    for y in range(H):
        shade = (28 + y // 12, 34 + y // 10, 60 + y // 8, 255)
        c.rect(0, y, W, 1, shade)
    rng = random.Random(7)
    for _ in range(95):
        sparkle(c, rng.randrange(8, W - 8), rng.randrange(8, H - 8), rng.choice([P.cream, P.gold, P.cyan]))
    c.rect(22, 22, 18, 18, P.gold)
    c.rect(28, 18, 18, 24, P.night)
    c.polygon([(0, 98), (50, 88), (120, 100), (190, 86), (260, 101), (335, 90), (399, 101), (399, 119), (0, 119)], (20, 23, 39, 255))
    c.text(40, 48, "STAR PET", P.cream, 2)
    c.text(42, 66, "PIXEL NIGHT", P.cyan, 1)
    pet_burst(c, 295, 58, 26)
    c.outline_rect(8, 8, W - 16, H - 16, P.coral, 3)
    return c


def banner_desktop() -> Canvas:
    c = Canvas((247, 189, 154, 255))
    draw_grid(c, (238, 165, 137, 255), 10)
    c.rect(0, 86, W, 34, P.wood)
    c.rect(0, 84, W, 4, (112, 72, 58, 255))
    c.rect(42, 22, 128, 68, P.ink)
    c.rect(48, 28, 116, 54, (54, 76, 103, 255))
    c.rect(53, 34, 80, 6, P.cyan)
    c.rect(53, 46, 98, 5, P.mint)
    c.rect(53, 58, 68, 5, P.rose)
    c.rect(86, 90, 38, 5, P.ink)
    c.rect(66, 98, 78, 8, P.ink)
    c.rect(210, 83, 88, 12, (63, 57, 62, 255))
    for i in range(8):
        c.rect(215 + i * 10, 86, 6, 4, P.cream)
    c.rect(318, 55, 30, 34, (92, 142, 96, 255))
    c.rect(314, 88, 38, 8, (83, 63, 56, 255))
    c.rect(325, 43, 7, 18, P.grass)
    c.rect(336, 41, 8, 17, P.grass)
    c.text(188, 32, "AGENT PET", P.ink, 2)
    c.text(190, 51, "DESKTOP MODE", P.coral_dark, 1)
    pet_burst(c, 190, 79, 20, P.cream, P.gold)
    c.outline_rect(8, 8, W - 16, H - 16, P.cream, 3)
    c.outline_rect(12, 12, W - 24, H - 24, P.coral_dark, 2)
    return c


def banner_hud() -> Canvas:
    c = Canvas((21, 24, 33, 255))
    draw_grid(c, (34, 38, 50, 255), 8)
    c.outline_rect(12, 12, 104, 96, P.coral, 3)
    c.rect(20, 20, 88, 80, (37, 42, 56, 255))
    pet_burst(c, 64, 59, 24)
    c.text(136, 20, "PIXEL PET", P.cream, 2)
    c.text(138, 40, "MOOD", P.cyan, 1)
    c.outline_rect(138, 50, 188, 12, P.cream, 2)
    c.rect(142, 54, 138, 4, P.mint)
    c.text(138, 70, "ENERGY", P.gold, 1)
    c.outline_rect(138, 80, 188, 12, P.cream, 2)
    c.rect(142, 84, 164, 4, P.coral)
    for i in range(5):
        x = 338 + i * 10
        c.rect(x, 22, 7, 7, P.rose)
        c.set(x + 3, 20, P.rose)
    for i in range(7):
        c.rect(338 + i * 8, 82, 5, 7, P.gold)
        c.set(340 + i * 8, 80, P.gold)
    c.outline_rect(8, 8, W - 16, H - 16, P.cyan, 2)
    c.outline_rect(4, 4, W - 8, H - 8, P.ink, 2)
    return c


def banner_rainbow() -> Canvas:
    c = Canvas((119, 211, 235, 255))
    for y in range(72, H):
        c.rect(0, y, W, 1, (108, 190 + (y - 72) // 3, 128, 255))
    for x, y in [(40, 30), (92, 24), (330, 32)]:
        c.rect(x, y, 30, 12, P.cream)
        c.rect(x + 8, y - 6, 18, 8, P.cream)
    for i, color in enumerate([P.rose, P.gold, P.mint, P.cyan, P.lilac]):
        c.rect(74, 78 + i * 4, 178, 4, color)
    c.rect(150, 76, 88, 10, (95, 72, 136, 255))
    c.rect(156, 70, 76, 8, P.cream)
    c.text(48, 50, "JUMP STAR", P.ink, 2)
    c.text(50, 68, "RAINBOW STAGE", (60, 70, 80, 255), 1)
    pet_burst(c, 285, 62, 22, P.cream, P.gold)
    for x in [286, 298, 310]:
        c.rect(x, 86, 8, 6, P.cream)
    c.outline_rect(8, 8, W - 16, H - 16, P.cream, 3)
    return c


def banner_title() -> Canvas:
    c = Canvas((35, 28, 44, 255))
    for y in range(0, H, 6):
        c.rect(0, y, W, 3, (43, 33, 55, 255))
    c.outline_rect(30, 20, 340, 80, P.cream, 4)
    c.outline_rect(36, 26, 328, 68, P.coral, 3)
    c.rect(52, 39, 182, 42, (24, 25, 34, 255))
    c.text(68, 45, "STAR PET", P.gold, 3)
    c.text(72, 74, "PRESS START", P.cyan, 1)
    c.rect(268, 38, 54, 42, P.coral)
    c.outline_rect(264, 34, 62, 50, P.cream, 2)
    pet_burst(c, 295, 59, 20, P.cream, P.gold)
    c.rect(338, 43, 8, 8, P.mint)
    c.rect(342, 51, 8, 8, P.mint)
    c.rect(338, 59, 8, 8, P.mint)
    return c


def banner_badge() -> Canvas:
    c = Canvas((250, 236, 219, 255))
    for y in range(0, H, 8):
        for x in range(0, W, 8):
            if (x // 8 + y // 8) % 2 == 0:
                c.rect(x, y, 8, 8, (244, 217, 199, 255))
    c.rect(0, 92, W, 28, P.coral)
    c.rect(36, 24, 92, 72, P.ink)
    c.rect(42, 30, 80, 60, P.cream)
    pet_burst(c, 82, 60, 24, P.cream, P.coral)
    c.text(152, 36, "AGENT PET", P.ink, 2)
    c.text(154, 56, "MINI BADGE", P.coral_dark, 1)
    for x in [246, 264, 282, 300, 318]:
        sparkle(c, x, 52, P.gold)
    c.outline_rect(8, 8, W - 16, H - 16, P.ink, 3)
    c.outline_rect(14, 14, W - 28, H - 28, P.coral, 2)
    return c


def main() -> None:
    banners: list[tuple[str, Canvas]] = [
        ("01 STARRY", banner_starry()),
        ("02 DESKTOP", banner_desktop()),
        ("03 HUD", banner_hud()),
        ("04 RAINBOW", banner_rainbow()),
        ("05 TITLE", banner_title()),
        ("06 BADGE", banner_badge()),
    ]
    files = [
        "01-pixel-starry-banner.png",
        "02-pixel-desktop-banner.png",
        "03-pixel-hud-banner.png",
        "04-pixel-rainbow-banner.png",
        "05-pixel-title-banner.png",
        "06-pixel-badge-banner.png",
    ]
    for name, (_, canvas) in zip(files, banners):
        path = os.path.join(OUT_DIR, name)
        write_png(path, canvas)
        print(path)
    contact_path = os.path.join(OUT_DIR, "00-pixel-banner-contact-sheet.png")
    write_contact_sheet(contact_path, banners)
    print(contact_path)


if __name__ == "__main__":
    main()
