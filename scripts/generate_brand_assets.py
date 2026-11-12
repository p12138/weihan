#!/usr/bin/env python3
"""从 brand/ 的母版生成 Android / iOS 全平台图标资源（启动页不再出位图）。

只用 Python 标准库：本机没有 Pillow（也装不上），CI runner 不该为了裁几张图
多装一个依赖。这里自带 8-bit PNG 读写 + separable Lanczos3 重采样。

    python3 scripts/generate_brand_assets.py            # 生成全部图标
    python3 scripts/generate_brand_assets.py --check    # 校验图标 + 启动层无缩略位图

设计源文件（只作母版，不会被打进 APK —— pubspec.yaml 未声明 assets）：
    brand/app-icon-1024.png      图标母版，1024 方形不透明
    brand/splash-1080x1920.png   启动页成图（仅作设计参考）
    brand/app-icon.svg           矢量源文件，留给以后改设计，脚本不直接用

跨平台一致性：
    * Android legacy / iOS AppIcon —— 整张母版缩放，系统负责加圆角遮罩。
    * Android adaptive（8+）—— 单独生成透明底 foreground 与渐变 background，
      图形严格落在中心 66dp 安全区内，避免被圆形/方形遮罩裁掉交织环。
    * 启动页（0.4.5 起）—— 原生层只铺渐变 / 纯色底，不再放整页缩略位图：
      360dp 宽的成图居中摆上去，冷启动会先闪一帧「小一号的启动页」，Flutter
      首帧才换成全屏矢量页。名称与标语统一由 lib/splash_page.dart 绘制；
      本脚本只负责校验旧位图和旧引用没有被误恢复。
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

# 自适应图标：108dp 画布里只有中心 66dp 一定可见。
ADAPTIVE_SAFE_RATIO = 66.0 / 108.0

ANDROID_DENSITIES = (
    # 目录后缀, 相对 mdpi 倍率, legacy 图标边长, adaptive 画布边长
    ("mdpi", 1.0, 48, 108),
    ("hdpi", 1.5, 72, 162),
    ("xhdpi", 2.0, 96, 216),
    ("xxhdpi", 3.0, 144, 324),
    ("xxxhdpi", 4.0, 192, 432),
)

ANDROID_RES = ROOT / "android/app/src/main/res"
IOS_ICONSET = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
IOS_LAUNCHSET = ROOT / "ios/Runner/Assets.xcassets/LaunchImage.imageset"

# 旧版把整张启动页成图按密度塞进原生层，冷启动会闪一帧「小一号的启动页」。
# 这些文件必须保持删除状态：--check 命中任意一个就判红。
LEGACY_SPLASH_FILES = tuple(
    [ANDROID_RES / ("drawable-" + row[0]) / "launch_logo.png"
     for row in ANDROID_DENSITIES]
    + [IOS_LAUNCHSET / "Contents.json"]
    + [IOS_LAUNCHSET / name for name in
       ("LaunchImage.png", "LaunchImage@2x.png", "LaunchImage@3x.png")]
)

# 原生配置里也不许再出现对这些位图（或系统小图标）的引用。
# 注意匹配的是资源引用串，注释里提到旧名字不算回归。
SPLASH_BITMAP_REFS = (
    (ANDROID_RES / "drawable/launch_background.xml", "@drawable/launch_logo"),
    (ANDROID_RES / "drawable-v21/launch_background.xml", "@drawable/launch_logo"),
    (ANDROID_RES / "values-v31/styles.xml", "@mipmap/ic_launcher_foreground"),
    (ROOT / "ios/Runner/Base.lproj/LaunchScreen.storyboard",
     'image="LaunchImage"'),
)


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
    # 成图只作设计参考：仍校验尺寸，但不再裁切、不再出位图。
    sw, sh, _ = read_png(SPLASH_MASTER)
    if (iw, ih) != (1024, 1024) or (sw, sh) != (1080, 1920):
        print("::error::母版尺寸不符：图标 %sx%s，启动页 %sx%s" % (iw, ih, sw, sh))
        return 1

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

    # ---- Android：legacy 图标 / 圆形图标 / 自适应图标 ----
    # 不再产出 launch_logo.png：原生启动层只铺渐变底色，冷启动不该先闪
    # 一帧 360dp 宽的「缩小版启动页」。
    for density, _scale, legacy, adaptive in ANDROID_DENSITIES:
        mipmap = ANDROID_RES / ("mipmap-" + density)
        emit(mipmap / "ic_launcher.png", legacy, legacy,
             resize_rgb(icon, iw, ih, legacy, legacy))
        emit(mipmap / "ic_launcher_round.png", legacy, legacy,
             resize_rgb(icon, iw, ih, legacy, legacy))
        emit(mipmap / "ic_launcher_foreground.png", adaptive, adaptive,
             compose_adaptive(fg1024, 1024, adaptive), 4)
        emit(mipmap / "ic_launcher_background.png", adaptive, adaptive,
             gradient_background(adaptive))

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

    # ---- iOS LaunchScreen 也只留纯色底，不再产出 LaunchImage 三件套 ----

    # ---- 校验 ----
    missing = [p for p, _, _ in expected if not p.exists()]
    bad = []
    for path, w, h in expected:
        if path.exists():
            got = png_size(path)
            if got != (w, h):
                bad.append("%s 期望 %dx%s 实际 %dx%s"
                           % (path.relative_to(ROOT), w, h, got[0], got[1]))
    # 冷启动那一帧「小一号的启动页」的回归锚点：位图文件和原生引用都不许回来。
    leftover = [p for p in LEGACY_SPLASH_FILES if p.exists()]
    stale_refs = [
        (path, needle)
        for path, needle in SPLASH_BITMAP_REFS
        if path.exists() and needle in path.read_text("utf-8")
    ]
    if missing or bad or leftover or stale_refs:
        for path in missing:
            print("::error::缺少资源 %s" % path.relative_to(ROOT))
        for line in bad:
            print("::error::尺寸不符 %s" % line)
        for path in leftover:
            print("::error::残留缩略启动页位图 %s（冷启动会先闪一帧小页面）"
                  % path.relative_to(ROOT))
        for path, needle in stale_refs:
            print("::error::原生启动层仍引用旧位图 / 小图标：%s 里的 %s"
                  % (path.relative_to(ROOT), needle))
        return 1

    if check:
        print("品牌资源校验通过：%d 个图标尺寸正确，原生启动层无缩略位图残留"
              % len(expected))
    else:
        print("已生成 %d 个图标资源（Android %d + iOS %d）；启动页由 Flutter 矢量绘制"
              % (written, len(ANDROID_DENSITIES) * 4, len(ios_px)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
