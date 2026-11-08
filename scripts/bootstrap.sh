#!/usr/bin/env bash
# 维汉互译 App · 双端原生壳引导（自用分发补充包）
#
# 用途：在缺少 android/ / ios/ 原生壳的 Flutter 工程上，幂等生成原生壳，
#       并补齐「自用语音翻译」必需的权限声明。
# 依赖：flutter 3.24.x（仅生成壳时需要）、python3（打补丁时需要）。
# 安全：不处理任何证书、keystore、Token；不配置 Xcode Signing。
#
# 用法：bash scripts/bootstrap.sh [工程根目录，默认当前目录]
# 环境变量（可选）：FLUTTER_ORG / FLUTTER_PROJECT_NAME / IOS_DEPLOY_TARGET

set -euo pipefail

ROOT="${1:-.}"
cd "$ROOT"

ORG="${FLUTTER_ORG:-com.selfuse.uyghur}"
PROJECT="${FLUTTER_PROJECT_NAME:-uyghur_interpreter}"
IOS_TARGET="${IOS_DEPLOY_TARGET:-12.0}"

has_android=0
has_ios=0
if [ -f android/build.gradle ] || [ -f android/build.gradle.kts ]; then has_android=1; fi
if [ -f ios/Podfile ] || [ -d ios/Runner.xcworkspace ]; then has_ios=1; fi

if [ "$has_android" = "1" ] && [ "$has_ios" = "1" ]; then
  echo "[bootstrap] android/ 与 ios/ 原生壳已存在，跳过生成"
else
  if ! command -v flutter >/dev/null 2>&1; then
    echo "[bootstrap][error] 未找到 flutter 命令。生成原生壳需要 Flutter SDK 3.24.x，" >&2
    echo "                 请在本机安装，或让 GitHub Actions 执行本脚本。" >&2
    exit 1
  fi
  echo "[bootstrap] 生成缺失的原生壳：org=$ORG project=$PROJECT"
  # 已有 pubspec.yaml 时，flutter create 会沿用其中的 name；
  # 此时强塞 --project-name 可能与 pubspec 冲突，故只在全新目录里传。
  if [ -f pubspec.yaml ]; then
    flutter create --platforms=android,ios --org "$ORG" .
  else
    flutter create --platforms=android,ios --org "$ORG" --project-name "$PROJECT" .
  fi
  echo "[bootstrap] 提示：flutter create 不会覆盖已存在的 lib/ 代码，但仍请检查 git diff"
fi

python3 - "$IOS_TARGET" <<'PY'
import pathlib
import re
import sys

ios_target = sys.argv[1]

# ---------------------------------------------------------------- Android
manifest = pathlib.Path("android/app/src/main/AndroidManifest.xml")
if not manifest.exists():
    print("[bootstrap][warn] 未找到 android/app/src/main/AndroidManifest.xml，跳过 Android 权限补丁")
else:
    text = manifest.read_text(encoding="utf-8")
    wanted = [
        "android.permission.RECORD_AUDIO",  # 按住说话
        "android.permission.INTERNET",     # 云端 ASR / 翻译 / TTS
    ]
    missing = [p for p in wanted if f'android:name="{p}"' not in text]
    if not missing:
        print("[bootstrap] Android 权限声明已齐全")
    else:
        marker = re.search(r"\s*<application\b", text)
        if marker is None:
            print("[bootstrap][error] AndroidManifest.xml 里找不到 <application>，请手动补权限声明", file=sys.stderr)
            sys.exit(1)
        block = "\n".join(f'    <uses-permission android:name="{p}"/>' for p in missing)
        manifest.write_text(text[:marker.start()] + "\n" + block + "\n" + text[marker.start():], encoding="utf-8")
        print("[bootstrap] 已补 Android 权限：" + ", ".join(missing))

# ---------------------------------------------------------------- iOS
info = pathlib.Path("ios/Runner/Info.plist")
if not info.exists():
    print("[bootstrap][warn] 未找到 ios/Runner/Info.plist，跳过 iOS 用途说明补丁")
else:
    text = info.read_text(encoding="utf-8")
    entries = {
        "NSMicrophoneUsageDescription": "用于汉语与维吾尔语语音翻译，录音仅实时处理，不保存原始音频。",
        "NSSpeechRecognitionUsageDescription": "用于把您说的话转成文字后进行翻译。",
    }
    missing = [(k, v) for k, v in entries.items() if f"<key>{k}</key>" not in text]
    if not missing:
        print("[bootstrap] iOS 权限用途说明已齐全")
    else:
        idx = text.rfind("</dict>")
        if idx < 0:
            print("[bootstrap][error] Info.plist 结构异常（找不到 </dict>），请手动补用途说明", file=sys.stderr)
            sys.exit(1)
        block = "\n".join(f"\t<key>{k}</key>\n\t<string>{v}</string>" for k, v in missing)
        info.write_text(text[:idx] + block + "\n" + text[idx:], encoding="utf-8")
        print("[bootstrap] 已补 iOS 用途说明：" + ", ".join(k for k, _ in missing))

podfile = pathlib.Path("ios/Podfile")
if podfile.exists():
    text = podfile.read_text(encoding="utf-8")
    patched = re.sub(
        r"^\s*#\s*platform\s*:\s*ios\s*,\s*'[^']*'",
        f"platform :ios, '{ios_target}'",
        text,
        count=1,
        flags=re.M,
    )
    if patched == text and not re.search(r"^\s*platform\s*:\s*ios", text, re.M):
        patched = f"platform :ios, '{ios_target}'\n" + text
    if patched != text:
        podfile.write_text(patched, encoding="utf-8")
        print(f"[bootstrap] 已显式声明 iOS deployment target = {ios_target}")
    else:
        print("[bootstrap] Podfile 已有 iOS deployment target，保持不变")
PY

cat <<'EOF'

[bootstrap] 完成。仍需人工处理的两件事（脚本刻意不代劳）：
  1) iOS 签名：用 Xcode 打开 ios/Runner.xcworkspace，补 Team / Bundle ID / Signing
  2) 检查 git diff，把新生成的 android/ ios/ 原生壳提交进仓库
EOF
