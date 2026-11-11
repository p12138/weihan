#!/usr/bin/env python3
"""融合 App · 工程静态自检（无需 Flutter SDK）

补上原工程缺失的 scripts/verify_project.py，使 selfuse-android.yml /
selfuse-ios.yml 里的 `python3 scripts/verify_project.py --scope all` 能直接跑。

仅用 Python 标准库，可在 Windows / Linux / macOS / CI 上执行。
检查内容：工程结构、pubspec 合法性、双端壳与权限声明、密钥硬编码、gitignore。

用法：
  python3 scripts/verify_project.py --scope all
  python3 scripts/verify_project.py --root /path/to/project --scope security --strict-secrets
  python3 scripts/verify_project.py --scope all --json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

VALID_NAME = re.compile(r"^[a-z][a-z0-9_]*$")
PLACEHOLDER_HINTS = (
    "REPLACE_WITH", "YOUR_", "CHANGEME", "PLACEHOLDER", "EXAMPLE",
    "TODO", "DUMMY", "XXXX", "<", "${", "String.fromEnvironment",
    "Platform.environment", "dotenv", "secrets.",
)
SECRET_PATTERNS = [
    ("硬编码密钥赋值", re.compile(
        r"(?i)\b(api[_-]?key|api[_-]?secret|app[_-]?secret|secret[_-]?key|"
        r"access[_-]?token|appid)\b\s*[:=]\s*['\"][A-Za-z0-9_\-]{16,}['\"]")),
    ("云厂商密钥前缀", re.compile(
        r"\b(sk-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_\-]{20,}|AKIA[0-9A-Z]{16})\b")),
    ("PEM 私钥", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
]
SCAN_EXT = {".dart", ".kt", ".java", ".gradle", ".swift", ".m", ".mm", ".plist", ".yaml", ".yml", ".xml"}
SCAN_SKIP_PARTS = {"build", ".dart_tool", ".git", "Pods", "DerivedData", "test", "tests"}


class Report:
    def __init__(self) -> None:
        self.items: list[dict[str, str]] = []

    def add(self, level: str, name: str, detail: str = "") -> None:
        self.items.append({"level": level, "name": name, "detail": detail})

    def count(self, level: str) -> int:
        return sum(1 for i in self.items if i["level"] == level)


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""


def pubspec_field(text: str, field: str) -> str:
    m = re.search(rf"^{re.escape(field)}:\s*(.+?)\s*$", text, re.M)
    return m.group(1).strip().strip("'\"") if m else ""


def check_structure(root: Path, rep: Report) -> None:
    pub = root / "pubspec.yaml"
    if not pub.is_file():
        rep.add("FAIL", "pubspec.yaml 存在", "工程根目录找不到 pubspec.yaml")
        return
    rep.add("PASS", "pubspec.yaml 存在")

    text = read(pub)
    name = pubspec_field(text, "name")
    if not name:
        rep.add("FAIL", "pubspec name", "缺少 name 字段")
    elif not VALID_NAME.match(name):
        rep.add("FAIL", "pubspec name",
                f'"{name}" 不是合法 Dart 包名（只能小写字母/数字/下划线，且以字母开头）')
    else:
        rep.add("PASS", "pubspec name", name)

    # 只看 environment: 段落，避免把 dependencies 里的 "sdk: flutter" 误当成 SDK 约束
    env_block = re.search(r"(?m)^environment:[ \t]*\n((?:[ \t]+[^\n]*\n)*)", text)
    sdk = (re.search(r"^\s*sdk:\s*(.+?)\s*$", env_block.group(1), re.M)
           if env_block else None)
    rep.add("PASS" if sdk else "WARN", "environment.sdk 约束",
            sdk.group(1).strip().strip("'\"") if sdk else "建议锁定 Dart SDK 范围，避免插件版本漂移")

    dart_files = sorted((root / "lib").rglob("*.dart")) if (root / "lib").is_dir() else []
    rep.add("PASS" if dart_files else "FAIL", "lib/ Dart 源码",
            f"{len(dart_files)} 个 .dart 文件" if dart_files else "lib/ 为空或不存在")

    test_files = sorted((root / "test").rglob("*.dart")) if (root / "test").is_dir() else []
    rep.add("PASS" if test_files else "WARN", "test/ 测试用例",
            f"{len(test_files)} 个测试文件" if test_files else "没有单元测试，首次编译门禁会跳过测试覆盖")

    for label, rel in (("analysis_options.yaml", "analysis_options.yaml"),
                       ("README", "README.md"),
                       (".gitignore", ".gitignore")):
        rep.add("PASS" if (root / rel).exists() else "WARN", f"{label} 存在")

    flows = sorted((root / ".github/workflows").glob("*.y*ml")) if (root / ".github/workflows").is_dir() else []
    rep.add("PASS" if flows else "WARN", "GitHub Actions 工作流",
            f"{len(flows)} 个" if flows else "未发现工作流，CI 不会自动跑")

    rep.add("PASS" if (root / "pubspec.lock").is_file() else "WARN", "pubspec.lock 已提交",
            "建议提交以锁定插件版本" if not (root / "pubspec.lock").is_file() else "")

    has_android = (root / "android/build.gradle").is_file() or (root / "android/build.gradle.kts").is_file()
    has_ios = (root / "ios/Podfile").is_file() or (root / "ios/Runner.xcworkspace").is_dir()
    rep.add("PASS" if (has_android and has_ios) else "WARN", "android/ + ios/ 原生壳",
            "已存在" if (has_android and has_ios) else "缺失，CI 会用 scripts/bootstrap.sh 补齐")

    if has_android:
        manifest = read(root / "android/app/src/main/AndroidManifest.xml")
        missing = [p for p in ("RECORD_AUDIO", "INTERNET") if p not in manifest]
        rep.add("PASS" if not missing else "WARN", "Android 权限声明",
                "RECORD_AUDIO / INTERNET 齐全" if not missing else f"缺 {', '.join(missing)}，bootstrap.sh 会补")
    if has_ios:
        plist = read(root / "ios/Runner/Info.plist")
        missing = [k for k in ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription")
                   if f"<key>{k}</key>" not in plist]
        rep.add("PASS" if not missing else "WARN", "iOS 权限用途说明",
                "齐全" if not missing else f"缺 {', '.join(missing)}，bootstrap.sh 会补")

    ignore = read(root / ".gitignore")
    lacks = [p for p in ("*.jks", "key.properties", "*.p12", "*.mobileprovision")
             if p not in ignore]
    rep.add("PASS" if not lacks else "WARN", ".gitignore 排除签名资产",
            "齐全" if not lacks else f"建议补 {', '.join(lacks)}")


def check_deps(root: Path, rep: Report) -> None:
    text = read(root / "pubspec.yaml")
    if "dependencies:" not in text:
        rep.add("FAIL", "pubspec dependencies", "缺少 dependencies 段")
        return
    rep.add("PASS", "pubspec dependencies")
    if "flutter_test:" not in text:
        rep.add("WARN", "flutter_test 开发依赖", "没有 flutter_test，flutter test 将无测试可跑")
    else:
        rep.add("PASS", "flutter_test 开发依赖")
    if "flutter_lints:" not in text:
        rep.add("WARN", "flutter_lints 开发依赖", "建议引入以统一 analyze 规则")
    else:
        rep.add("PASS", "flutter_lints 开发依赖")


def check_security(root: Path, rep: Report, strict: bool) -> None:
    hits: list[tuple[str, str, str]] = []
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in SCAN_EXT:
            continue
        if any(part in SCAN_SKIP_PARTS for part in path.parts):
            continue
        if path.name.endswith((".example", ".template")):
            continue
        text = read(path)
        for lineno, line in enumerate(text.splitlines(), 1):
            if any(h in line for h in PLACEHOLDER_HINTS):
                continue
            for label, pattern in SECRET_PATTERNS:
                if pattern.search(line):
                    hits.append((label, str(path.relative_to(root)), str(lineno)))
    level = "FAIL" if strict else "WARN"
    if hits:
        sample = "; ".join(f"{label} @ {path}:{line}" for label, path, line in hits[:5])
        rep.add(level, "硬编码凭证扫描",
                f"发现 {len(hits)} 处疑似硬编码：{sample}"
                + ("；自用可接受，但不要提交到公开仓库" if not strict else ""))
    else:
        rep.add("PASS", "硬编码凭证扫描", "未发现明显硬编码密钥")


def main() -> int:
    ap = argparse.ArgumentParser(description="Flutter 工程静态自检（无需 Flutter SDK）")
    ap.add_argument("--root", default=".", help="工程根目录，默认当前目录")
    ap.add_argument("--scope", default="all", choices=["all", "structure", "deps", "security"])
    ap.add_argument("--strict-secrets", action="store_true", help="把疑似硬编码密钥从 WARN 提升为 FAIL")
    ap.add_argument("--strict", action="store_true", help="WARN 也视为失败")
    ap.add_argument("--json", action="store_true", help="以 JSON 输出")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    rep = Report()
    if not root.is_dir():
        rep.add("FAIL", "工程根目录", f"不存在：{root}")
    else:
        if args.scope in ("all", "structure"):
            check_structure(root, rep)
        if args.scope in ("all", "deps"):
            check_deps(root, rep)
        if args.scope in ("all", "security"):
            check_security(root, rep, args.strict_secrets)

    if args.json:
        print(json.dumps({"root": str(root), "scope": args.scope,
                          "summary": {k: rep.count(k) for k in ("PASS", "WARN", "FAIL")},
                          "items": rep.items}, ensure_ascii=False, indent=2))
    else:
        print(f"== 工程静态自检  root={root}  scope={args.scope} ==")
        for i in rep.items:
            line = f"[{i['level']:<4}] {i['name']}"
            if i["detail"]:
                line += f"  — {i['detail']}"
            print(line)
        print(f"汇总：PASS {rep.count('PASS')} / WARN {rep.count('WARN')} / FAIL {rep.count('FAIL')}")

    failed = rep.count("FAIL") > 0 or (args.strict and rep.count("WARN") > 0)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
