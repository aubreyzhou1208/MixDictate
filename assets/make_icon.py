#!/usr/bin/env python3
"""生成 App 图标（assets/icon.png，1024×1024）。

用代码画而不是塞一个二进制文件进仓库：想换配色、改形状，改几行重跑就行，
不用去找当初那个设计文件。只用标准库，任何装了 Python 的机器都能跑。

    python3 assets/make_icon.py

生成之后 scripts/build_app.sh 会在 macOS 上把它转成 .icns。
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

SIZE = 1024
# 先按 4 倍画再缩小 —— 这是这个脚本里唯一的抗锯齿手段。
# 不做的话圆角和竖条的边缘全是台阶，在小尺寸下尤其难看。
SS = 4

# 深靛蓝 → 紫。菜单栏图标在深色和浅色背景下都要立得住，
# 所以底色取中等明度，前景用纯白。
TOP = (79, 70, 229)
BOTTOM = (147, 51, 234)
FOREGROUND = (255, 255, 255)

# macOS 图标不占满整个画布，四周要留白，否则跟系统图标摆一起会显得过大
INSET = 0.10
# 圆角的"方形程度"。macOS 用的是超椭圆而不是普通圆角矩形，
# 指数越大越接近方形；5 附近最接近系统那些图标的观感。
SQUIRCLE_N = 5.0


def squircle_mask(size: int) -> list[list[float]]:
    """超椭圆内部为 1、外部为 0 的遮罩。"""
    inset = size * INSET
    half = (size - 2 * inset) / 2
    cx = cy = size / 2

    mask = [[0.0] * size for _ in range(size)]
    for y in range(size):
        ny = abs((y + 0.5) - cy) / half
        if ny > 1:
            continue
        for x in range(size):
            nx = abs((x + 0.5) - cx) / half
            if nx > 1:
                continue
            if nx ** SQUIRCLE_N + ny ** SQUIRCLE_N <= 1.0:
                mask[y][x] = 1.0
    return mask


def draw_bars(pixels: list[list[tuple[int, int, int, int]]], size: int) -> None:
    """中间画一组竖条 —— 声波的最简写法。

    图标最小会被缩到 16×16。那个尺寸下任何细节都糊成一团，
    只有"几根粗竖条"这种结构还能认出来，所以不要画麦克风轮廓。
    """
    # 所有尺寸都相对**超椭圆内部**算，不是相对整个画布。
    # 相对画布算的话最高那根会长出超椭圆之外，把图标从中间劈开。
    inner = size * (1 - 2 * INSET)

    ratios = [0.38, 0.68, 1.0, 0.68, 0.38]
    tallest = inner * 0.62
    heights = [ratio * tallest for ratio in ratios]
    count = len(heights)

    bar_w = inner * 0.088
    gap = inner * 0.066
    total = count * bar_w + (count - 1) * gap
    left = (size - total) / 2
    cy = size / 2
    radius = bar_w / 2

    for index, height in enumerate(heights):
        x0 = left + index * (bar_w + gap)
        x1 = x0 + bar_w
        half_h = height / 2
        y0, y1 = cy - half_h, cy + half_h

        for y in range(int(y0), int(y1) + 1):
            if not 0 <= y < size:
                continue
            for x in range(int(x0), int(x1) + 1):
                if not 0 <= x < size:
                    continue
                # 两端做成半圆，方头竖条看着很生硬
                if y < y0 + radius:
                    dy = (y0 + radius) - y
                elif y > y1 - radius:
                    dy = y - (y1 - radius)
                else:
                    dy = 0
                dx = abs(x + 0.5 - (x0 + x1) / 2)
                if dx * dx + dy * dy > radius * radius:
                    continue
                pixels[y][x] = (*FOREGROUND, 255)


def render(size: int) -> list[list[tuple[int, int, int, int]]]:
    mask = squircle_mask(size)
    pixels = [[(0, 0, 0, 0)] * size for _ in range(size)]

    for y in range(size):
        t = y / (size - 1)
        color = tuple(
            round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)
        )
        row = pixels[y]
        for x in range(size):
            if mask[y][x]:
                row[x] = (*color, 255)

    draw_bars(pixels, size)
    return pixels


def downsample(
    pixels: list[list[tuple[int, int, int, int]]], size: int, factor: int
) -> list[list[tuple[int, int, int, int]]]:
    out_size = size // factor
    out = [[(0, 0, 0, 0)] * out_size for _ in range(out_size)]
    area = factor * factor

    for y in range(out_size):
        for x in range(out_size):
            r = g = b = a = 0
            for dy in range(factor):
                for dx in range(factor):
                    pr, pg, pb, pa = pixels[y * factor + dy][x * factor + dx]
                    # 按 alpha 加权，否则透明像素的黑色会把边缘拉暗
                    r += pr * pa
                    g += pg * pa
                    b += pb * pa
                    a += pa
            if a:
                out[y][x] = (r // a, g // a, b // a, a // area)
    return out


def write_png(path: Path, pixels: list[list[tuple[int, int, int, int]]]) -> None:
    size = len(pixels)
    raw = bytearray()
    for row in pixels:
        raw.append(0)  # 每行的过滤器类型：无
        for r, g, b, a in row:
            raw += bytes((r, g, b, a))

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(
            ">I", zlib.crc32(body) & 0xFFFFFFFF
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def main() -> None:
    big = render(SIZE * SS)
    final = downsample(big, SIZE * SS, SS)
    out = Path(__file__).resolve().parent / "icon.png"
    write_png(out, final)
    print(f"写好了 {out}（{SIZE}×{SIZE}）")


if __name__ == "__main__":
    main()
