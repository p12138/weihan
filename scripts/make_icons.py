#!/usr/bin/env python3
"""生成「融合」双端图标与启动图，零第三方依赖（numpy + zlib 即可）。

设计：两枚对话气泡上下叠放——白色气泡（中文侧，两行字）压在上方，
沙金气泡（维文侧，一行连写）压在下方。取色自艾德莱斯绸的松石绿与沙金，
深底浅标，48px 的小图标上仍能读出「两个人在说话」。

用法：
    python scripts/make_icons.py                     # 写入 android/ 与 ios/ 资源
    python scripts/make_icons.py --preview out.png   # 额外导出 512px 预览

为什么手写光栅化：CI 与本机都没有 Pillow / ImageMagick / rsvg，
但都保证有 Python 3 与 numpy。用有向距离场（SDF）逐像素算覆盖率做抗锯齿，
任何尺寸都能直接渲染，不必先生成 1024 再缩（缩放在纯 Python 里又慢又糊）。
"""

from __future__ import annotations

import argparse
import math
import pathlib
import struct
import sys
import zlib

import numpy as np

# ----------------------------------------------------------------- 调色板
MID = (0x16 / 255, 0x5E / 255, 0x56 / 255)  # 松石绿（背景上沿）
DEEP = (0x0B / 255, 0x3A / 255, 0x36 / 255)  # 深松石绿（背景下沿）
INK = (0x10 / 255, 0x3D / 255, 0x39 / 255)  # 气泡内文字条
WHITE = (1.0, 1.0, 1.0)
SAND = (0xE8 / 255, 0xB4 / 255, 0x5C / 255)  # 沙金
SAND_DEEP = (0x7A / 255, 0x50 / 255, 0x14 / 255)


# ----------------------------------------------------------------- PNG 写出
def write_png(path: pathlib.Path, rgb: np.ndarray, alpha: np.ndarray | None) -> None:
    """rgb: HxWx3 float 0..1；alpha: HxW float 0..1 或 None（不写 alpha 通道）。"""
    height, width, _ = rgb.shape
    data = np.clip(np.rint(rgb * 255.0), 0, 255).astype(np.uint8)
    if alpha is None:
        color_type = 2  # truecolour：iOS AppIcon 不接受 alpha 通道
        raw = b"".join(b"\x00" + data[y].tobytes() for y in range(height))
    else:
        color_type = 6
        a = np.clip(np.rint(alpha * 255.0), 0, 255).astype(np.uint8)[..., None]
        merged = np.concatenate([data, a], axis=2)
        raw = b"".join(b"\x00" + merged[y].tobytes() for y in range(height))

    def chunk(tag: bytes, payload: bytes) -> bytes:
        body = tag + payload
        return (
            struct.pack(">I", len(payload))
            + body
            + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


# ----------------------------------------------------------------- 几何工具
def grid(width: int, height: int) -> tuple[np.ndarray, np.ndarray]:
    """像素中心坐标（单位为像素）。"""
    xs = np.arange(width) + 0.5
    ys = np.arange(height) + 0.5
    return np.meshgrid(xs, ys)


def rounded_rect(
    x: np.ndarray, y: np.ndarray, cx: float, cy: float, hw: float, hh: float, r: float
) -> np.ndarray:
    """圆角矩形的有向距离（内部为负）。"""
    r = max(0.0, min(r, hw, hh))
    dx = np.abs(x - cx) - (hw - r)
    dy = np.abs(y - cy) - (hh - r)
    outside = np.hypot(np.maximum(dx, 0.0), np.maximum(dy, 0.0))
    inside = np.minimum(np.maximum(dx, dy), 0.0)
    return outside + inside - r


def triangle(
    x: np.ndarray,
    y: np.ndarray,
    p0: tuple[float, float],
    p1: tuple[float, float],
    p2: tuple[float, float],
) -> np.ndarray:
    """凸三角形（三条边半平面取交集），内部为负。"""
    pts = (p0, p1, p2)
    cx = sum(p[0] for p in pts) / 3.0
    cy = sum(p[1] for p in pts) / 3.0
    planes = []
    for i in range(3):
        ax, ay = pts[i]
        bx, by = pts[(i + 1) % 3]
        nx, ny = by - ay, -(bx - ax)
        norm = math.hypot(nx, ny) or 1.0
        nx, ny = nx / norm, ny / norm
        # 让质心这一侧为负
        if (cx - ax) * nx + (cy - ay) * ny > 0:
            nx, ny = -nx, -ny
        planes.append((ax, ay, nx, ny))
    sdf = None
    for ax, ay, nx, ny in planes:
        d = (x - ax) * nx + (y - ay) * ny
        sdf = d if sdf is None else np.maximum(sdf, d)
    return sdf


def coverage(sdf: np.ndarray) -> np.ndarray:
    """像素单位的 SDF → 覆盖率 0..1（1px 抗锯齿）。"""
    return np.clip(0.5 - sdf, 0.0, 1.0)


def paint(img: np.ndarray, color: tuple[float, float, float], cov: np.ndarray) -> None:
    for i in range(3):
        img[..., i] = img[..., i] * (1.0 - cov) + color[i] * cov


def box_blur(a: np.ndarray, radius: int) -> np.ndarray:
    """可分离盒式模糊（累积和实现），用来做柔和投影。"""
    if radius <= 0:
        return a
    out = a
    for axis in (0, 1):
        pad = [(radius + 1, radius) if i == axis else (0, 0) for i in (0, 1)]
        cum = np.cumsum(np.pad(out, pad, mode="edge"), axis=axis)
        n = out.shape[axis]
        hi = np.take(cum, np.arange(2 * radius, 2 * radius + n), axis=axis)
        lo = np.concatenate(
            [np.zeros_like(np.take(cum, [0], axis=axis)), np.take(cum, np.arange(0, n - 1), axis=axis)],
            axis=axis,
        )
        out = (hi - lo) / (2 * radius + 1)
    return out


# ----------------------------------------------------------------- 背景
def background(x: np.ndarray, y: np.ndarray, height: int) -> np.ndarray:
    t = np.clip(y / max(height, 1), 0.0, 1.0) ** 0.9
    img = np.zeros((*x.shape, 3), dtype=np.float64)
    for i in range(3):
        img[..., i] = MID[i] + (DEEP[i] - MID[i]) * t
    # 左上角一层极柔的光，避免纯色底发死；不做织纹，48px 下会变噪点。
    w = max(x.shape[1], 1)
    glow = np.clip(1.0 - np.hypot((x - w * 0.18) / w, (y / height) - 0.05) * 1.5, 0.0, 1.0) ** 2
    paint(img, WHITE, glow * 0.07)
    return img


# ----------------------------------------------------------------- 主体标记
def draw_mark(
    img: np.ndarray,
    x: np.ndarray,
    y: np.ndarray,
    cx: float,
    cy: float,
    size: float,
    with_shadow: bool,
) -> np.ndarray:
    """以 (cx, cy) 为中心、以 size 为整体宽度画标记，返回覆盖率的并集（即 alpha）。"""

    def at(dx: float, dy: float) -> tuple[float, float]:
        return cx + dx * size, cy + dy * size

    # 白色气泡（上）：中文侧，左下角带一个小尾巴
    ax, ay = at(-0.16, -0.14)
    a_body = rounded_rect(x, y, ax, ay, 0.28 * size, 0.185 * size, 0.085 * size)
    # 白气泡左下角的小尖角尾巴（指向对方）
    a_tail = triangle(x, y, at(-0.38, 0.015), at(-0.19, 0.015), at(-0.365, 0.185))
    a_cov = coverage(np.minimum(a_body, a_tail))

    # 沙金气泡（下）：维文侧
    bx, by = at(0.17, 0.17)
    b_cov = coverage(rounded_rect(x, y, bx, by, 0.27 * size, 0.18 * size, 0.085 * size))

    if with_shadow:
        shadow = box_blur(a_cov, max(1, int(size * 0.024)))
        paint(img, (0.0, 0.0, 0.0), np.roll(shadow, max(1, int(size * 0.010)), axis=0) * 0.18)

    paint(img, WHITE, a_cov)
    for bar_dy, bar_w in ((-0.195, 0.30), (-0.075, 0.21)):
        bcx, bcy = at(-0.245, bar_dy)
        bar = coverage(rounded_rect(x, y, bcx, bcy, bar_w * size * 0.5, 0.026 * size, 0.026 * size))
        paint(img, INK, bar * a_cov)

    if with_shadow:
        shadow = box_blur(b_cov, max(1, int(size * 0.028)))
        paint(img, (0.0, 0.0, 0.0), np.roll(shadow, max(1, int(size * 0.012)), axis=0) * 0.22)

    paint(img, SAND, b_cov)
    bcx, bcy = at(0.19, 0.165)
    bar = coverage(rounded_rect(x, y, bcx, bcy, 0.15 * size, 0.026 * size, 0.026 * size))
    paint(img, SAND_DEEP, bar * b_cov)

    return np.maximum(a_cov, b_cov)


def render(
    width: int,
    height: int | None = None,
    *,
    corner: float = 0.0,
    with_background: bool = True,
    mark_scale: float = 0.92,
) -> tuple[np.ndarray, np.ndarray | None]:
    """渲染一张图。

    corner: 外框圆角（相对短边的比例），0 表示直角；
    with_background=False 时背景全透明（自适应前景 / 启动 logo）。
    """
    height = height or width
    x, y = grid(width, height)
    short = min(width, height)

    if with_background:
        img = background(x, y, height)
        alpha = np.ones((height, width), dtype=np.float64)
        if mark_scale > 0:
            draw_mark(img, x, y, width / 2.0, height / 2.0, mark_scale * short, True)
    else:
        img = np.zeros((height, width, 3), dtype=np.float64)
        if mark_scale > 0:
            alpha = draw_mark(img, x, y, width / 2.0, height / 2.0, mark_scale * short, False)
        else:
            alpha = np.zeros((height, width), dtype=np.float64)

    if corner > 0:
        r = corner * short
        mask = coverage(rounded_rect(x, y, width / 2.0, height / 2.0, width / 2.0, height / 2.0, r))
        alpha = alpha * mask

    return img, alpha


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preview", type=str, default="")
    parser.add_argument("--root", type=str, default=".")
    args = parser.parse_args(argv)

    root = pathlib.Path(args.root)
    if not (root / "pubspec.yaml").exists():
        print("[icons][error] 请在仓库根目录执行（找不到 pubspec.yaml）", file=sys.stderr)
        return 1

    # ------------------------------------------------ Android legacy 图标
    for folder, px in {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }.items():
        img, alpha = render(px, corner=0.22, mark_scale=0.94)
        write_png(root / "android/app/src/main/res" / folder / "ic_launcher.png", img, alpha)

    # ------------------------------------------------ Android 自适应图标
    for folder, px in {
        "mipmap-mdpi": 108,
        "mipmap-hdpi": 162,
        "mipmap-xhdpi": 216,
        "mipmap-xxhdpi": 324,
        "mipmap-xxxhdpi": 432,
    }.items():
        bg, _ = render(px, mark_scale=0.0)
        write_png(root / "android/app/src/main/res" / folder / "ic_launcher_background.png", bg, None)
        fg, fg_alpha = render(px, with_background=False, mark_scale=0.60)
        write_png(
            root / "android/app/src/main/res" / folder / "ic_launcher_foreground.png",
            fg,
            fg_alpha,
        )

    # ------------------------------------------------ Android 启动 logo
    for folder, px in {
        "drawable-mdpi": 96,
        "drawable-hdpi": 144,
        "drawable-xhdpi": 192,
        "drawable-xxhdpi": 288,
        "drawable-xxxhdpi": 384,
    }.items():
        img, alpha = render(px, with_background=False, mark_scale=0.96)
        write_png(root / "android/app/src/main/res" / folder / "launch_logo.png", img, alpha)

    # ------------------------------------------------ iOS AppIcon
    icon_dir = root / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for name, px in {
        "Icon-App-20x20@1x.png": 20,
        "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76,
        "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }.items():
        img, _ = render(px, mark_scale=0.92)
        write_png(icon_dir / name, img, None)  # iOS 不接受 alpha 通道，也不自己切圆角

    # ------------------------------------------------ iOS 启动图
    launch_dir = root / "ios/Runner/Assets.xcassets/LaunchImage.imageset"
    for name, px in (
        ("LaunchImage.png", 168),
        ("LaunchImage@2x.png", 336),
        ("LaunchImage@3x.png", 504),
    ):
        img, alpha = render(px, height=int(round(px * 185 / 168)), with_background=False, mark_scale=0.66)
        write_png(launch_dir / name, img, alpha)

    print("[icons] 已生成 Android mipmap/drawable 与 iOS AppIcon/LaunchImage")

    if args.preview:
        img, _ = render(512, mark_scale=0.92)
        write_png(pathlib.Path(args.preview), img, None)
        print(f"[icons] 预览已写出：{args.preview}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
