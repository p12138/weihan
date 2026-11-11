#!/usr/bin/env python3
"""从 brand/ 的母版生成 Android / iOS 全平台图标与启动页资源。

只用 Python 标准库：本机没有 Pillow（也装不上），CI runner 不该为了裁几张图
多装一个依赖。这里自带 8-bit PNG 读写 + separable Lanczos3 重采样。

    python3 scripts/generate_brand_assets.py            # 生成全部资源
    python3 scripts/generate_brand_assets.py --check    # 只校验产物齐全、尺寸正确

设计源文件（只作母版，不会被打进 APK —— pubspec.yaml 未声明 assets）：
    brand/app-icon-1024.png      图标母版，1024 方形不透明
    brand/splash-1080x1920.png   启动页成图
    brand/app-icon.svg           矢量源文件，留给以后改设计，脚本不直接用

跨平台一致性：
    * Android legacy / iOS AppIcon —— 整张母版缩放，系统负责加圆角遮罩。
    * Android adaptive（8+）—— 单独生成透明底 foreground 与渐变 background，
      图形严格落在中心 66dp 安全区内，避免被圆形/方形遮罩裁掉交织环。
    * 启动页 —— 先裁掉成图里的「假状态栏 9:41」和底部 Home 指示条，
      再按密度出图；这两样由系统绘制，留着会出现两份。
"""

from __future__ import annotations

import json
import math
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "brand"
ICON_MASTER = BRAND / "app-icon-1024.png"
SPLASH_MASTER = BRAND / "splash-1080x1920.png"

# 启动页成图 1080x1920：状态栏占 0..140，Home 指示条约在 1860 之后。
SPLASH_CROP_TOP = 140
SPLASH_CROP_BOTTOM = 1850

# 自适应图标：108dp 画布里只有中心 66dp 一定可见。
ADAPTIVE_SAFE_RATIO = 66.0 / 108.0

ANDROID_DENSITIES = (
    # 目录后缀, 相对 mdpi 倍率, legacy 图标边长, adaptive 画布边长, 启动图宽度
    ("mdpi", 1.0, 48, 108, 360),
    ("hdpi", 1.5, 72, 162, 540),
    ("xhdpi", 2.0, 96, 216, 720),
    ("xxhdpi", 3.0, 144, 324, 1080),
    ("xxxhdpi", 4.0, 192, 432, 1440),
)

IOS_ICONSET = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
IOS_LAUNCHSET = ROOT / "ios/Runner/Assets.xcassets/LaunchImage.imageset"


# ---------------------------------------------------------------------------
# PNG：8-bit RGB / RGBA、非隔行，足够覆盖设计工具导出的母版
# ---------------------------------------------------------------------------

def _chunks(data: bytes):
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "不是 PNG 文件"
    pos = 8
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + length]
        yield kind, payload
        pos += 12 + length


def read_png(path: Path) -> tuple[int, int, bytearray]:
    """返回 (宽, 高, RGB bytearray)，alpha 会被合成到白底。"""
    raw = path.read_bytes()
    width = height = color_type = None
    idat = bytearray()
    for kind, payload in _chunks(raw):
        if kind == b"IHDR":
            width, height, depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            if depth != 8 or color_type not in (2, 6) or interlace != 0:
                raise ValueError(
                    "%s: 只支持 8-bit RGB/RGBA 非隔行 PNG（实际 depth=%s type=%s）"
                    % (path.name, depth, color_type)
                )
        elif kind == b"IDAT":
            idat.extend(payload)
        elif kind == b"IEND":
            break
    if width is None:
        raise ValueError("%s: 缺少 IHDR" % path.name)

    channels = 3 if color_type == 2 else 4
    stride = width * channels
    inflated = zlib.decompress(bytes(idat))
    rows: list[bytearray] = []
    prev = bytearray(stride)
    pos = 0
    for _ in range(height):
        filter_type = inflated[pos]
        pos += 1
        line = bytearray(inflated[pos:pos + stride])
        pos += stride
        if filter_type == 1:  # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filter_type == 3:  # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filter_type == 4:  # Paeth
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                predictor = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + predictor) & 0xFF
        elif filter_type != 0:
            raise ValueError("%s: 未知 filter %s" % (path.name, filter_type))
        rows.append(line)
        prev = line

    rgb = bytearray(width * height * 3)
    for y, line in enumerate(rows):
        if channels == 3:
            rgb[y * stride:(y + 1) * stride] = line
        else:
            for x in range(width):
                r, g, b, a = line[x * 4:x * 4 + 4]
                if a != 255:  # 合成到白底；母版本身不透明，这里只是兜底
                    r = (r * a + 255 * (255 - a)) // 255
                    g = (g * a + 255 * (255 - a)) // 255
                    b = (b * a + 255 * (255 - a)) // 255
                o = (y * width + x) * 3
                rgb[o], rgb[o + 1], rgb[o + 2] = r, g, b
    return width, height, rgb


def _chunk(kind: bytes, payload: bytes) -> bytes:
    return (struct.pack(">I", len(payload)) + kind + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))


def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def _filter_row(line: bytearray, prev: bytearray, bpp: int,
                kind: int) -> bytearray:
    out = bytearray(len(line))
    for i, value in enumerate(line):
        a = line[i - bpp] if i >= bpp else 0
        b = prev[i]
        c = prev[i - bpp] if i >= bpp else 0
        if kind == 0:
            delta = value
        elif kind == 1:
            delta = value - a
        elif kind == 2:
            delta = value - b
        elif kind == 3:
            delta = value - ((a + b) >> 1)
        else:
            delta = value - _paeth(a, b, c)
        out[i] = delta & 0xFF
    return out


def write_png(path: Path, width: int, height: int, pixels: bytearray,
              channels: int = 3) -> None:
    """pixels 为 RGB/RGBA 交错字节；逐行挑压缩率最高的 PNG filter。

    渐变类图片用 filter 0 会比 Up/Paeth 大两三倍 —— 启动图有 1700 行，
    这一步直接决定 APK 里多出几 MB。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    stride = width * channels
    scan = bytearray()
    zero = bytearray(stride)
    prev = zero
    for y in range(height):
        line = pixels[y * stride:(y + 1) * stride]
        best_kind, best = 0, None
        best_score = None
        for kind in (0, 1, 2, 3, 4):
            candidate = _filter_row(line, prev, channels, kind)
            # libpng 的标准启发式：过滤后字节当作有符号数，绝对值和最小者最优
            score = sum(min(v, 256 - v) for v in candidate)
            if best_score is None or score < best_score:
                best_score, best_kind, best = score, kind, candidate
        scan.append(best_kind)
        scan.extend(best)
        prev = line
    ihdr = struct.pack(">IIBBBBB", width, height, 8,
                       2 if channels == 3 else 6, 0, 0, 0)
    blob = (b"\x89PNG\r\n\x1a\n"
            + _chunk(b"IHDR", ihdr)
            + _chunk(b"IDAT", zlib.compress(bytes(scan), 9))
            + _chunk(b"IEND", b""))
    path.write_bytes(blob)


# ---------------------------------------------------------------------------
# Lanczos3 重采样
# ---------------------------------------------------------------------------

def _lanczos(x: float) -> float:
    if x == 0:
        return 1.0
    if abs(x) >= 3:
        return 0.0
    px = math.pi * x
    return 3.0 * math.sin(px) * math.sin(px / 3.0) / (px * px)


def _weights(src_n: int, dst_n: int) -> list[tuple[int, list[float]]]:
    scale = src_n / dst_n
    kernel = max(1.0, scale)  # 缩小时加宽 kernel，等效低通，避免锯齿
    support = 3.0 * kernel
    table: list[tuple[int, list[float]]] = []
    for d in range(dst_n):
        center = (d + 0.5) * scale - 0.5
        left = max(0, int(math.floor(center - support)))
        right = min(src_n - 1, int(math.ceil(center + support)))
        ws = [_lanczos((s - center) / kernel) for s in range(left, right + 1)]
        total = sum(ws)
        if total > 0:
            ws = [w / total for w in ws]
        else:  # 理论不可达；兜底取最近邻
            nearest = min(src_n - 1, max(0, int(round(center))))
            left, ws = nearest, [1.0]
        table.append((left, ws))
    return table


def _clamp_byte(v: float) -> int:
    return 0 if v < 0 else (255 if v > 255 else int(v + 0.5))


def resize_rgb(src: bytearray, sw: int, sh: int, dw: int, dh: int) -> bytearray:
    if (sw, sh) == (dw, dh):
        return bytearray(src)
    xw = _weights(sw, dw)
    tmp = bytearray(dw * sh * 3)
    for y in range(sh):
        row = y * sw * 3
        for dx, (left, ws) in enumerate(xw):
            r = g = b = 0.0
            for k, w in enumerate(ws):
                i = row + (left + k) * 3
                r += src[i] * w
                g += src[i + 1] * w
                b += src[i + 2] * w
            o = (y * dw + dx) * 3
            tmp[o], tmp[o + 1], tmp[o + 2] = (
                _clamp_byte(r), _clamp_byte(g), _clamp_byte(b))

    yw = _weights(sh, dh)
    out = bytearray(dw * dh * 3)
    for dy, (top, ws) in enumerate(yw):
        for x in range(dw):
            r = g = b = 0.0
            for k, w in enumerate(ws):
                i = ((top + k) * dw + x) * 3
                r += tmp[i] * w
                g += tmp[i + 1] * w
                b += tmp[i + 2] * w
            o = (dy * dw + x) * 3
            out[o], out[o + 1], out[o + 2] = (
                _clamp_byte(r), _clamp_byte(g), _clamp_byte(b))
    return out


def resize_rgba(src: bytearray, sw: int, sh: int, dw: int, dh: int) -> bytearray:
    """RGBA 缩放。alpha 走预乘，避免透明边缘渗出一圈白边。"""
    xw, yw = _weights(sw, dw), _weights(sh, dh)
    tmp = [0.0] * (dw * sh * 4)
    for y in range(sh):
        row = y * sw * 4
        for dx, (left, ws) in enumerate(xw):
            r = g = b = a = 0.0
            for k, w in enumerate(ws):
                i = row + (left + k) * 4
                alpha = src[i + 3] / 255.0
                wa = w * alpha
                r += src[i] * wa
                g += src[i + 1] * wa
                b += src[i + 2] * wa
                a += wa
            o = (y * dw + dx) * 4
            if a > 0:
                tmp[o:o + 4] = [r / a, g / a, b / a, a * 255]
    out = bytearray(dw * dh * 4)
    for dy, (top, ws) in enumerate(yw):
        for x in range(dw):
            r = g = b = a = 0.0
            for k, w in enumerate(ws):
                i = ((top + k) * dw + x) * 4
                wa = w * tmp[i + 3] / 255.0
                r += tmp[i] * wa
                g += tmp[i + 1] * wa
                b += tmp[i + 2] * wa
                a += wa
            o = (dy * dw + x) * 4
            if a > 0:
                out[o], out[o + 1], out[o + 2], out[o + 3] = (
                    _clamp_byte(r / a), _clamp_byte(g / a),
                    _clamp_byte(b / a), _clamp_byte(a * 255))
    return out


# ---------------------------------------------------------------------------
# 素材加工
# ---------------------------------------------------------------------------

def _smoothstep(edge0: float, edge1: float, x: float) -> float:
    t = min(1.0, max(0.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3.0 - 2.0 * t)


def cut_out_foreground(icon: bytearray, size: int) -> bytearray:
    """把不透明母版变成透明底的「交织环 + 星芒」。

    母版背景是低亮度深青渐变（V≈0.42），环与星明显更亮（V>0.65），用亮度
    做软阈值即可分离；再叠一层径向淡出，把外围织锦暗纹压干净。
    """
    out = bytearray(size * size * 4)
    center = (size - 1) / 2.0
    for y in range(size):
        for x in range(size):
            i = (y * size + x) * 3
            r, g, b = icon[i], icon[i + 1], icon[i + 2]
            v = max(r, g, b) / 255.0
            alpha = _smoothstep(0.46, 0.68, v)
            radius = math.hypot(x - center, y - center) / center
            alpha *= 1.0 - _smoothstep(0.62, 0.86, radius)
            o = (y * size + x) * 4
            out[o], out[o + 1], out[o + 2] = r, g, b
            out[o + 3] = _clamp_byte(alpha * 255)
    return out


def compose_adaptive(fg: bytearray, fg_size: int, canvas: int) -> bytearray:
    inner = round(canvas * ADAPTIVE_SAFE_RATIO)
    scaled = resize_rgba(fg, fg_size, fg_size, inner, inner)
    out = bytearray(canvas * canvas * 4)
    offset = (canvas - inner) // 2
    for y in range(inner):
        s = y * inner * 4
        d = ((y + offset) * canvas + offset) * 4
        out[d:d + inner * 4] = scaled[s:s + inner * 4]
    return out


def gradient_background(size: int) -> bytearray:
    """自适应图标底层：与母版一致的深青对角渐变。"""
    top, bottom = (0x15, 0x53, 0x6A), (0x07, 0x2A, 0x40)
    out = bytearray(size * size * 3)
    for y in range(size):
        for x in range(size):
            t = min(1.0, max(0.0, (x + y) / (2.0 * (size - 1))))
            o = (y * size + x) * 3
            for c in range(3):
                out[o + c] = int(top[c] + (bottom[c] - top[c]) * t + 0.5)
    return out


def crop_splash(splash: bytearray, sw: int, sh: int) -> tuple[int, int, bytearray]:
    height = SPLASH_CROP_BOTTOM - SPLASH_CROP_TOP
    start = SPLASH_CROP_TOP * sw * 3
    return sw, height, bytearray(splash[start:start + sw * height * 3])


# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()[:33]
    return struct.unpack(">II", data[16:24])


def main() -> int:
    check = "--check" in sys.argv
    if not ICON_MASTER.exists() or not SPLASH_MASTER.exists():
        print("::error::缺少 brand/ 设计母版")
        return 1

    iw, ih, icon = read_png(ICON_MASTER)
    sw, sh, splash = read_png(SPLASH_MASTER)
    if (iw, ih) != (1024, 1024) or (sw, sh) != (1080, 1920):
        print("::error::母版尺寸不符：图标 %sx%s，启动页 %sx%s" % (iw, ih, sw, sh))
        return 1

    cw, ch, cropped = crop_splash(splash, sw, sh)
    fg1024 = cut_out_foreground(icon, 1024)
    expected: list[tuple[Path, int, int]] = []
    written = 0

    def emit(path: Path, w: int, h: int, pixels: bytearray,
             channels: int = 3) -> None:
        nonlocal written
        expected.append((path, w, h))
        if not check:
            write_png(path, w, h, pixels, channels)
            written += 1

    # ---- Android：legacy 图标 / 圆形图标 / 自适应图标 / 启动页 ----
    # 启动图只留一份 xxhdpi：Android 会自动按屏幕密度缩放，渐变 + 文字对缩放
    # 不敏感，而五个密度各存一张会让 APK 平白多出约 4MB。
    launch_density = "xxhdpi"
    stale_launch: list[Path] = []
    for density, _scale, legacy, adaptive, launch_w in ANDROID_DENSITIES:
        res = ROOT / "android/app/src/main/res"
        mipmap = res / ("mipmap-" + density)
        emit(mipmap / "ic_launcher.png", legacy, legacy,
             resize_rgb(icon, iw, ih, legacy, legacy))
        emit(mipmap / "ic_launcher_round.png", legacy, legacy,
             resize_rgb(icon, iw, ih, legacy, legacy))
        emit(mipmap / "ic_launcher_foreground.png", adaptive, adaptive,
             compose_adaptive(fg1024, 1024, adaptive), 4)
        emit(mipmap / "ic_launcher_background.png", adaptive, adaptive,
             gradient_background(adaptive))
        stale = res / ("drawable-" + density) / "launch_logo.png"
        if density == launch_density:
            launch_h = round(launch_w * ch / cw)
            emit(stale, launch_w, launch_h,
                 resize_rgb(cropped, cw, ch, launch_w, launch_h))
        else:
            # 旧版在其它密度也放过启动图；留着会被系统优先选中，覆盖新设计。
            stale_launch.append(stale)
            if not check and stale.exists():
                stale.unlink()

    # ---- iOS AppIcon：直接按 Contents.json 的 size × scale 出图 ----
    contents = json.loads((IOS_ICONSET / "Contents.json").read_text("utf-8"))
    ios_px: dict[str, int] = {}
    for item in contents["images"]:
        side = float(item["size"].split("x")[0])
        scale = int(item["scale"].rstrip("x"))
        ios_px[item["filename"]] = int(round(side * scale))
    for filename, px in sorted(ios_px.items()):
        emit(IOS_ICONSET / filename, px, px,
             resize_rgb(icon, iw, ih, px, px))

    # ---- iOS LaunchImage：1x/2x/3x 与 Android 同一张裁切图 ----
    for scale in (1, 2, 3):
        lw = 360 * scale
        lh = round(lw * ch / cw)
        name = "LaunchImage.png" if scale == 1 else "LaunchImage@%dx.png" % scale
        emit(IOS_LAUNCHSET / name, lw, lh,
             resize_rgb(cropped, cw, ch, lw, lh))

    # ---- 校验 ----
    missing = [p for p, _, _ in expected if not p.exists()]
    leftover = [p for p in stale_launch if p.exists()]
    bad = []
    for path, w, h in expected:
        if path.exists():
            got = png_size(path)
            if got != (w, h):
                bad.append("%s 期望 %dx%s 实际 %dx%s"
                           % (path.relative_to(ROOT), w, h, got[0], got[1]))
    if missing or bad or leftover:
        for path in missing:
            print("::error::缺少资源 %s" % path.relative_to(ROOT))
        for line in bad:
            print("::error::尺寸不符 %s" % line)
        for path in leftover:
            print("::error::残留其它密度的旧启动图 %s（会盖住新设计）"
                  % path.relative_to(ROOT))
        return 1

    if check:
        print("品牌资源校验通过：%d 个文件尺寸全部正确，无旧启动图残留"
              % len(expected))
    else:
        print("已生成 %d 个品牌资源（Android 图标 %d 个 + 启动图 1 张 / "
              "iOS 图标 %d 个 + 启动图 3 张）"
              % (written, len(ANDROID_DENSITIES) * 4, len(ios_px)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
