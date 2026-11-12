#!/usr/bin/env python3
"""生成 NAS 用的更新清单（latest-android.json / latest-ios.json）。

清单只描述「文件叫什么、多大、SHA-256 是多少」，不带域名：App 用
「更新源地址 + file」自己拼出下载地址。这样换域名、换端口都不用重出包。

用法：
  python3 scripts/make_update_manifest.py \
    --platform android \
    --file build/app/outputs/flutter-apk/app-arm64-v8a-release.apk \
    --name weihan-selfuse-arm64.apk \
    --notes "修复…" \
    --out dist/latest-android.json
"""

import argparse
import datetime
import hashlib
import json
import pathlib
import re
import sys

VERSION_RE = re.compile(
    r"^version:\s*([0-9]+(?:\.[0-9]+)*)(?:\+([0-9]+))?", re.MULTILINE
)


def read_pubspec_version(path: pathlib.Path) -> tuple[str, int]:
    text = path.read_text(encoding="utf-8")
    match = VERSION_RE.search(text)
    if not match:
        raise SystemExit("pubspec.yaml 里找不到 version:")
    return match.group(1), int(match.group(2) or 0)


def sha256_of(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True, choices=("android", "ios"))
    parser.add_argument("--file", required=True, help="要分发的安装包路径")
    parser.add_argument("--name", required=True, help="清单里记录的文件名")
    parser.add_argument("--notes", default="", help="更新说明，允许换行")
    parser.add_argument("--out", required=True, help="清单输出路径")
    parser.add_argument(
        "--build",
        type=int,
        default=None,
        help="构建号；不给就用 pubspec 的 +N",
    )
    parser.add_argument(
        "--pubspec",
        default="pubspec.yaml",
        help="用于读取版本号的 pubspec 路径",
    )
    args = parser.parse_args()

    payload = pathlib.Path(args.file)
    if not payload.is_file():
        raise SystemExit(f"找不到安装包：{payload}")
    if "/" in args.name or "\\" in args.name:
        raise SystemExit("--name 只能是文件名，不能带路径")

    version, pubspec_build = read_pubspec_version(pathlib.Path(args.pubspec))
    build = args.build if args.build is not None else pubspec_build

    manifest = {
        "schema": 1,
        "platform": args.platform,
        "version": version,
        "build": build,
        "notes": args.notes.strip(),
        "file": args.name,
        "size": payload.stat().st_size,
        "sha256": sha256_of(payload),
        "requiresResign": args.platform == "ios",
        "publishedAt": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
    }

    out = pathlib.Path(args.out)
    if not out.parent.exists():
        out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    # 只打印元信息，不打印文件内容。
    print(
        "::notice::已生成 %s：%s %s+%d · %.1f MB · sha256 %s…"
        % (
            out,
            args.platform,
            version,
            build,
            manifest["size"] / 1048576,
            manifest["sha256"][:12],
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
