#!/usr/bin/env python3
"""保证 pubspec.yaml 与 lib/app_version.dart 的版本号一致。

App 内比较「有没有新版」用的是 `kAppVersion` 这个编译期常量，它不会跟着
pubspec 自动变。两处写岔的后果很隐蔽：界面显示 0.4.6、实际装的是 0.5.0，
更新检查会一直判错。这个脚本把它变成一次显式的门禁。
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PUBSPEC = ROOT / "pubspec.yaml"
VERSION_DART = ROOT / "lib" / "app_version.dart"

PUBSPEC_RE = re.compile(r"^version:\s*(\S+)\s*$", re.MULTILINE)
DART_RE = re.compile(r"kAppVersion\s*=\s*'([^']+)'")


def main() -> int:
    pubspec_text = PUBSPEC.read_text(encoding="utf-8")
    dart_text = VERSION_DART.read_text(encoding="utf-8")

    pub_match = PUBSPEC_RE.search(pubspec_text)
    if not pub_match:
        print("::error::pubspec.yaml 里找不到 version:")
        return 1
    pub_version = pub_match.group(1).strip()

    dart_match = DART_RE.search(dart_text)
    if not dart_match:
        print("::error::lib/app_version.dart 里找不到 kAppVersion")
        return 1
    dart_version = dart_match.group(1).strip()

    if pub_version != dart_version:
        print(
            "::error::版本号不一致：pubspec.yaml 是 %s，"
            "lib/app_version.dart 是 %s" % (pub_version, dart_version)
        )
        return 1

    print("::notice::版本号一致：%s" % pub_version)
    return 0


if __name__ == "__main__":
    sys.exit(main())
