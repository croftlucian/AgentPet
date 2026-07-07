#!/usr/bin/env python3
"""生成桌宠身体向四面八方散开的 GIF 预览。

只依赖 Python 标准库和系统 ffmpeg。脚本先调用当前 AgentPet
二进制渲染一帧快照,再按像素相对中心的方向分组,让外围突出块向外散开再收回。
"""

from __future__ import annotations

import math
import os
import shutil
import struct
import subprocess
import zlib
from collections import Counter


ROOT = os.path.dirname(os.path.dirname(__file__))
BIN = os.path.join(ROOT, "AgentPet.app", "Contents", "MacOS", "AgentPet")
OUT_DIR = os.path.dirname(__file__)
SRC = os.path.join(OUT_DIR, "agent-pet-burst-source.png")
FRAME_DIR = os.path.join(OUT_DIR, "burst-frames")
GIF_PATH = os.path.join(OUT_DIR, "agent-pet-burst-preview.gif")
SHEET_PATH = os.path.join(OUT_DIR, "agent-pet-burst-preview-sheet.png")

CANVAS = 320
PET_SIZE = 178
BG = (30, 30, 30, 255)
TRANSPARENT = (0, 0, 0, 0)


def paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def read_png_rgba(path: str) -> tuple[int, int, list[tuple[int, int, int, int]]]:
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("不是 PNG 文件")
    pos = 8
    width = height = color_type = bit_depth = None
    idat = bytearray()
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            if bit_depth != 8 or color_type != 6 or interlace != 0 or compression != 0 or filtering != 0:
                raise ValueError("仅支持 8-bit RGBA 非交错 PNG")
        elif kind == b"IDAT":
            idat.extend(payload)
        elif kind == b"IEND":
            break
    assert width is not None and height is not None
    raw = zlib.decompress(bytes(idat))
    bpp = 4
    stride = width * bpp
    rows: list[bytes] = []
    prev = bytearray(stride)
    idx = 0
    for _ in range(height):
        filter_type = raw[idx]
        idx += 1
        cur = bytearray(raw[idx:idx + stride])
        idx += stride
        for i in range(stride):
            left = cur[i - bpp] if i >= bpp else 0
            up = prev[i]
            up_left = prev[i - bpp] if i >= bpp else 0
            if filter_type == 1:
                cur[i] = (cur[i] + left) & 0xFF
            elif filter_type == 2:
                cur[i] = (cur[i] + up) & 0xFF
            elif filter_type == 3:
                cur[i] = (cur[i] + ((left + up) // 2)) & 0xFF
            elif filter_type == 4:
                cur[i] = (cur[i] + paeth(left, up, up_left)) & 0xFF
            elif filter_type != 0:
                raise ValueError("未知 PNG 过滤器")
        rows.append(bytes(cur))
        prev = cur
    pixels = []
    for row in rows:
        for i in range(0, len(row), 4):
            pixels.append((row[i], row[i + 1], row[i + 2], row[i + 3]))
    return width, height, pixels


def write_png_rgba(path: str, width: int, height: int, pixels: list[tuple[int, int, int, int]]) -> None:
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(pixels[y * width + x])

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def pixel_visible(pixel: tuple[int, int, int, int], bg: tuple[int, int, int, int]) -> bool:
    if pixel[3] <= 10:
        return False
    return sum(abs(pixel[i] - bg[i]) for i in range(3)) > 18


def alpha_bbox(width: int, height: int, pixels: list[tuple[int, int, int, int]], bg: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    xs: list[int] = []
    ys: list[int] = []
    for y in range(height):
        for x in range(width):
            if pixel_visible(pixels[y * width + x], bg):
                xs.append(x)
                ys.append(y)
    return min(xs), min(ys), max(xs) + 1, max(ys) + 1


def sample_nearest(src_w: int, src_h: int, pixels: list[tuple[int, int, int, int]], x: float, y: float) -> tuple[int, int, int, int]:
    sx = max(0, min(src_w - 1, int(round(x))))
    sy = max(0, min(src_h - 1, int(round(y))))
    return pixels[sy * src_w + sx]


def paste_pixel(dst: list[tuple[int, int, int, int]], x: int, y: int, color: tuple[int, int, int, int]) -> None:
    if not (0 <= x < CANVAS and 0 <= y < CANVAS) or color[3] == 0:
        return
    r, g, b, a = color
    if a >= 250:
        dst[y * CANVAS + x] = (r, g, b, 255)
        return
    br, bg, bb, ba = dst[y * CANVAS + x]
    alpha = a / 255.0
    inv = 1.0 - alpha
    dst[y * CANVAS + x] = (
        int(r * alpha + br * inv),
        int(g * alpha + bg * inv),
        int(b * alpha + bb * inv),
        255 if ba else a,
    )


def visible_palette(pixels: list[tuple[int, int, int, int]], bg: tuple[int, int, int, int]) -> tuple[tuple[int, int, int, int], tuple[int, int, int, int], tuple[int, int, int, int]]:
    colors = [p for p in pixels if pixel_visible(p, bg)]
    dominant = Counter(colors).most_common(12)
    fill = dominant[0][0]
    orange_colors = [c for c, _ in dominant if c[0] > c[1] > c[2]]
    if orange_colors:
        fill = max(orange_colors, key=lambda c: c[0] + c[1] + c[2])
    outline = min(orange_colors or [fill], key=lambda c: c[0] + c[1] + c[2])
    darks = [c for c in colors if c[0] + c[1] + c[2] < 170]
    ink = Counter(darks).most_common(1)[0][0] if darks else outline
    return fill, outline, ink


def draw_rect(dst: list[tuple[int, int, int, int]], x: int, y: int, w: int, h: int, color: tuple[int, int, int, int]) -> None:
    for yy in range(y, y + h):
        for xx in range(x, x + w):
            paste_pixel(dst, xx, yy, color)


def draw_ellipse(dst: list[tuple[int, int, int, int]], cx: float, cy: float, rx: float, ry: float, color: tuple[int, int, int, int]) -> None:
    min_x = int(cx - rx)
    max_x = int(cx + rx)
    min_y = int(cy - ry)
    max_y = int(cy + ry)
    for y in range(min_y, max_y + 1):
        for x in range(min_x, max_x + 1):
            if ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1:
                paste_pixel(dst, x, y, color)


def draw_line(dst: list[tuple[int, int, int, int]], x1: float, y1: float, x2: float, y2: float, color: tuple[int, int, int, int], thickness: int = 1) -> None:
    steps = max(1, int(round(math.hypot(x2 - x1, y2 - y1))))
    radius = max(0, thickness // 2)
    for i in range(steps + 1):
        t = i / steps
        x = int(round(x1 + (x2 - x1) * t))
        y = int(round(y1 + (y2 - y1) * t))
        for yy in range(-radius, radius + 1):
            for xx in range(-radius, radius + 1):
                paste_pixel(dst, x + xx, y + yy, color)


def draw_polygon(dst: list[tuple[int, int, int, int]], points: list[tuple[float, float]], color: tuple[int, int, int, int]) -> None:
    if len(points) < 3:
        return
    min_y = int(math.floor(min(y for _, y in points)))
    max_y = int(math.ceil(max(y for _, y in points)))
    count = len(points)
    for y in range(min_y, max_y + 1):
        nodes: list[float] = []
        for i in range(count):
            x1, y1 = points[i]
            x2, y2 = points[(i + 1) % count]
            if (y1 < y <= y2) or (y2 < y <= y1):
                nodes.append(x1 + (y - y1) * (x2 - x1) / (y2 - y1))
        nodes.sort()
        for i in range(0, len(nodes), 2):
            if i + 1 >= len(nodes):
                break
            for x in range(int(math.ceil(nodes[i])), int(math.floor(nodes[i + 1])) + 1):
                paste_pixel(dst, x, y, color)


def draw_piece_polygon(
    dst: list[tuple[int, int, int, int]],
    points: list[tuple[float, float]],
    fill: tuple[int, int, int, int],
    outline: tuple[int, int, int, int],
) -> None:
    cx = sum(x for x, _ in points) / len(points)
    cy = sum(y for _, y in points) / len(points)
    outer = [(cx + (x - cx) * 1.12, cy + (y - cy) * 1.12) for x, y in points]
    inner = [(cx + (x - cx) * 0.86, cy + (y - cy) * 0.86) for x, y in points]
    draw_polygon(dst, outer, outline)
    draw_polygon(dst, inner, fill)


def draw_core(dst: list[tuple[int, int, int, int]], cx: float, cy: float, scale: float, fill: tuple[int, int, int, int], outline: tuple[int, int, int, int], ink: tuple[int, int, int, int]) -> None:
    # 中心主体是为“分裂”动作临时设计的干净内核,只使用当前桌宠源图里采到的颜色。
    draw_ellipse(dst, cx, cy + 2 * scale, 42 * scale, 48 * scale, outline)
    draw_ellipse(dst, cx, cy - 1 * scale, 36 * scale, 41 * scale, fill)
    draw_ellipse(dst, cx, cy + 27 * scale, 26 * scale, 8 * scale, outline)
    draw_ellipse(dst, cx, cy + 25 * scale, 22 * scale, 5 * scale, fill)

    eye_w = max(2, int(round(5 * scale)))
    eye_h = max(5, int(round(14 * scale)))
    draw_ellipse(dst, cx - 18 * scale, cy - 11 * scale, eye_w / 2, eye_h / 2, ink)
    draw_ellipse(dst, cx + 18 * scale, cy - 11 * scale, eye_w / 2, eye_h / 2, ink)
    mouth_w = max(16, int(round(31 * scale)))
    mouth_h = max(2, int(round(4 * scale)))
    draw_rect(dst, int(round(cx - mouth_w / 2)), int(round(cy + 14 * scale)), mouth_w, mouth_h, ink)


def direction_from(dx: float, dy: float) -> tuple[float, float]:
    length = math.hypot(dx, dy)
    if length <= 0.001:
        return 0.0, 0.0
    return dx / length, dy / length


def protrusion_direction(dx: float, dy: float, draw_w: int, draw_h: int) -> tuple[float, float] | None:
    """把源图外伸像素分到稳定方向,让整块突起一起飞散。"""
    arm_y = draw_h * 0.10
    if abs(dx) > draw_w * 0.34 and abs(dy) < arm_y:
        return (-1.0, 0.0) if dx < 0 else (1.0, 0.0)
    if dy < -draw_h * 0.31 and abs(dx) < draw_w * 0.18:
        return 0.0, -1.0
    if dy > draw_h * 0.28 and abs(dx) > draw_w * 0.06:
        return direction_from(dx * 0.55, draw_h * 0.48)
    if dy < -draw_h * 0.17 and abs(dx) > draw_w * 0.16:
        return direction_from(dx, -draw_h * 0.44)
    if dy > draw_h * 0.12 and abs(dx) > draw_w * 0.19:
        return direction_from(dx, draw_h * 0.36)
    return None


def draw_crack(
    dst: list[tuple[int, int, int, int]],
    cx: float,
    cy: float,
    points: list[tuple[float, float]],
    color: tuple[int, int, int, int],
    strength: float,
) -> None:
    if strength <= 0.08:
        return
    for start, end in zip(points, points[1:]):
        x1, y1 = start
        x2, y2 = end
        steps = max(1, int(round(math.hypot(x2 - x1, y2 - y1))))
        for i in range(steps + 1):
            t = i / steps
            x = cx + x1 + (x2 - x1) * t
            y = cy + y1 + (y2 - y1) * t
            size = 1 if strength < 0.58 else 2
            for yy in range(size):
                for xx in range(size):
                    paste_pixel(dst, int(round(x)) + xx, int(round(y)) + yy, color)


def paste_source_scaled(
    dst: list[tuple[int, int, int, int]],
    src_w: int,
    src_h: int,
    src_pixels: list[tuple[int, int, int, int]],
    bg: tuple[int, int, int, int],
    min_x: int,
    min_y: int,
    draw_w: int,
    draw_h: int,
    scale: float,
    ox: int,
    oy: int,
) -> None:
    for y in range(draw_h):
        for x in range(draw_w):
            sx = min_x + x / scale
            sy = min_y + y / scale
            color = sample_nearest(src_w, src_h, src_pixels, sx, sy)
            if pixel_visible(color, bg):
                paste_pixel(dst, ox + x, oy + y, color)


def draw_capsule(
    dst: list[tuple[int, int, int, int]],
    cx: float,
    cy: float,
    w: float,
    h: float,
    fill: tuple[int, int, int, int],
    outline: tuple[int, int, int, int],
) -> None:
    r = h / 2
    draw_rect(dst, int(round(cx - w / 2)), int(round(cy - h / 2 - 3)), int(round(w)), int(round(h + 6)), outline)
    draw_ellipse(dst, cx - w / 2, cy, r + 3, r + 3, outline)
    draw_ellipse(dst, cx + w / 2, cy, r + 3, r + 3, outline)
    draw_rect(dst, int(round(cx - w / 2)), int(round(cy - h / 2)), int(round(w)), int(round(h)), fill)
    draw_ellipse(dst, cx - w / 2, cy, r, r, fill)
    draw_ellipse(dst, cx + w / 2, cy, r, r, fill)


def shifted(cx: float, cy: float, dx: float, dy: float, burst: float, distance: float) -> tuple[float, float]:
    ux, uy = direction_from(dx, dy)
    return cx + dx + ux * burst * distance, cy + dy + uy * burst * distance


def draw_stylized_burst(
    pixels: list[tuple[int, int, int, int]],
    cx: float,
    cy: float,
    scale: float,
    burst: float,
    fill: tuple[int, int, int, int],
    outline: tuple[int, int, int, int],
    ink: tuple[int, int, int, int],
) -> None:
    s = scale
    distance = 42 * s

    # 先画外伸块,中心主体盖在上面,组装时仍接近原始桌宠轮廓。
    lx, ly = shifted(cx, cy, -67 * s, -2 * s, burst, distance)
    rx, ry = shifted(cx, cy, 67 * s, -2 * s, burst, distance)
    draw_capsule(pixels, lx, ly, 52 * s, 16 * s, fill, outline)
    draw_capsule(pixels, rx, ry, 52 * s, 16 * s, fill, outline)

    tx, ty = shifted(cx, cy, 0, -52 * s, burst, distance)
    draw_ellipse(pixels, tx, ty, 17 * s, 28 * s, outline)
    draw_ellipse(pixels, tx, ty + 1 * s, 12 * s, 23 * s, fill)

    ulx, uly = shifted(cx, cy, -39 * s, -34 * s, burst, distance)
    urx, ury = shifted(cx, cy, 39 * s, -34 * s, burst, distance)
    draw_piece_polygon(pixels, [(ulx - 18 * s, uly - 12 * s), (ulx + 17 * s, uly - 3 * s), (ulx + 4 * s, uly + 25 * s), (ulx - 19 * s, uly + 14 * s)], fill, outline)
    draw_piece_polygon(pixels, [(urx + 18 * s, ury - 12 * s), (urx - 17 * s, ury - 3 * s), (urx - 4 * s, ury + 25 * s), (urx + 19 * s, ury + 14 * s)], fill, outline)

    llx, lly = shifted(cx, cy, -34 * s, 35 * s, burst, distance)
    lrx, lry = shifted(cx, cy, 34 * s, 35 * s, burst, distance)
    draw_piece_polygon(pixels, [(llx - 18 * s, lly + 20 * s), (llx - 1 * s, lly - 20 * s), (llx + 20 * s, lly + 2 * s)], fill, outline)
    draw_piece_polygon(pixels, [(lrx + 18 * s, lry + 20 * s), (lrx + 1 * s, lry - 20 * s), (lrx - 20 * s, lry + 2 * s)], fill, outline)

    for leg_dx in (-18 * s, 18 * s):
        leg_x, leg_y = shifted(cx, cy, leg_dx, 67 * s, burst, distance * 0.86)
        draw_rect(pixels, int(round(leg_x - 8 * s)), int(round(leg_y - 23 * s)), int(round(16 * s)), int(round(43 * s)), outline)
        draw_rect(pixels, int(round(leg_x - 4 * s)), int(round(leg_y - 17 * s)), int(round(8 * s)), int(round(28 * s)), fill)
        draw_rect(pixels, int(round(leg_x - 8 * s)), int(round(leg_y + 8 * s)), int(round(18 * s)), int(round(12 * s)), fill)

    body_rx = 46 * s * (1.0 - 0.12 * burst)
    body_ry = 48 * s * (1.0 - 0.10 * burst)
    draw_ellipse(pixels, cx, cy + 2 * s, body_rx + 5 * s, body_ry + 5 * s, outline)
    draw_ellipse(pixels, cx, cy, body_rx, body_ry, fill)

    if burst > 0.55:
        draw_ellipse(pixels, cx - 20 * s, cy - 10 * s, 5 * s, 11 * s, ink)
        draw_line(pixels, cx + 14 * s, cy - 10 * s, cx + 27 * s, cy - 13 * s, ink, max(3, int(4 * s)))
        draw_line(pixels, cx - 15 * s, cy + 12 * s, cx - 3 * s, cy + 18 * s, ink, max(3, int(4 * s)))
        draw_line(pixels, cx - 3 * s, cy + 18 * s, cx + 16 * s, cy + 13 * s, ink, max(3, int(4 * s)))
    else:
        draw_ellipse(pixels, cx - 20 * s, cy - 10 * s, 4 * s, 10 * s, ink)
        draw_ellipse(pixels, cx + 20 * s, cy - 10 * s, 4 * s, 10 * s, ink)
        draw_line(pixels, cx - 14 * s, cy + 14 * s, cx + 14 * s, cy + 14 * s, ink, max(3, int(4 * s)))


def frame_pixels(src_w: int, src_h: int, src_pixels: list[tuple[int, int, int, int]], progress: float) -> list[tuple[int, int, int, int]]:
    bg = src_pixels[0]
    fill, outline, ink = visible_palette(src_pixels, bg)
    min_x, min_y, max_x, max_y = alpha_bbox(src_w, src_h, src_pixels, bg)
    bw = max_x - min_x
    bh = max_y - min_y
    scale = PET_SIZE / max(bw, bh)
    draw_w = int(round(bw * scale))
    draw_h = int(round(bh * scale))
    ox = (CANVAS - draw_w) // 2
    oy = (CANVAS - draw_h) // 2 + 8
    cx = ox + draw_w / 2
    cy = oy + draw_h / 2
    core_rx = draw_w * 0.30
    core_ry = draw_h * 0.33
    burst = math.sin(progress * math.pi)
    pixels = [BG for _ in range(CANVAS * CANVAS)]

    # 落地阴影跟随主体中心,避免散开时画面飘。
    for sy in range(-3, 4):
        for sx in range(-30, 31):
            if (sx / 30) ** 2 + (sy / 5) ** 2 <= 1:
                x = int(cx + sx)
                y = int(oy + draw_h * 0.78 + sy)
                if 0 <= x < CANVAS and 0 <= y < CANVAS:
                    paste_pixel(pixels, x, y, (0, 0, 0, 55))

    if burst < 0.02:
        paste_source_scaled(pixels, src_w, src_h, src_pixels, bg, min_x, min_y, draw_w, draw_h, scale, ox, oy)
    else:
        draw_stylized_burst(pixels, cx, cy, draw_w / PET_SIZE, burst, fill, outline, ink)
    return pixels


def write_contact_sheet(frame_paths: list[str]) -> None:
    chosen = [round(i * (len(frame_paths) - 1) / 5) for i in range(6)]
    sheet_w = CANVAS * 3
    sheet_h = CANVAS * 2
    sheet = [BG for _ in range(sheet_w * sheet_h)]
    for i, idx in enumerate(chosen):
        _, _, fp = read_png_rgba(frame_paths[idx])
        col = i % 3
        row = i // 3
        for y in range(CANVAS):
            for x in range(CANVAS):
                sheet[(row * CANVAS + y) * sheet_w + col * CANVAS + x] = fp[y * CANVAS + x]
    write_png_rgba(SHEET_PATH, sheet_w, sheet_h, sheet)


def main() -> None:
    subprocess.run([BIN, "--render-test", SRC], check=True)
    src_w, src_h, src_pixels = read_png_rgba(SRC)
    if os.path.isdir(FRAME_DIR):
        shutil.rmtree(FRAME_DIR)
    os.makedirs(FRAME_DIR, exist_ok=True)
    frame_paths: list[str] = []
    frame_count = 28
    for i in range(frame_count):
        progress = i / (frame_count - 1)
        path = os.path.join(FRAME_DIR, f"burst-{i:02d}.png")
        write_png_rgba(path, CANVAS, CANVAS, frame_pixels(src_w, src_h, src_pixels, progress))
        frame_paths.append(path)
    write_contact_sheet(frame_paths)

    palette = os.path.join(FRAME_DIR, "palette.png")
    ffmpeg = "/opt/homebrew/bin/ffmpeg"
    subprocess.run([
        ffmpeg, "-y", "-framerate", "10", "-i", os.path.join(FRAME_DIR, "burst-%02d.png"),
        "-vf", "palettegen", palette,
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run([
        ffmpeg, "-y", "-framerate", "10", "-i", os.path.join(FRAME_DIR, "burst-%02d.png"),
        "-i", palette, "-lavfi", "paletteuse=dither=none", "-loop", "0", "-gifflags", "-transdiff", GIF_PATH,
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"已输出动图:{GIF_PATH}")
    print(f"已输出分镜:{SHEET_PATH}")


if __name__ == "__main__":
    main()
