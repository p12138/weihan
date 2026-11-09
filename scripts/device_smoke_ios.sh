#!/usr/bin/env bash
# 在 iOS Simulator 上自动安装并启动 debug .app，验证「能装、能开、不闪退」。
#
# 由 .github/workflows/auto-device-smoke.yml 在 macos-15 runner 上调用。
# 模拟器构建不需要证书、不需要 Apple 账号、不需要真机，也不需要你手动装包。
# 本机手工跑（仅 macOS + Xcode）：bash scripts/device_smoke_ios.sh

set -euo pipefail

BUNDLE="com.selfuse.uyghur.weihan"
APP="$(find build/ios/iphonesimulator -maxdepth 1 -name '*.app' -type d | head -n 1)"
if [ -z "$APP" ]; then
  echo "::error::找不到 simulator .app，请先执行 flutter build ios --simulator --debug --no-codesign"
  exit 1
fi
echo "[smoke] APP=$APP"

UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, items in devices.items():
    for item in items:
        if not item.get("isAvailable") or "iPhone" not in item["name"]:
            continue
        key = (runtime, item["name"])
        if best is None or key > best[0]:
            best = (key, item["udid"])
print(best[1] if best else "")
')"
if [ -z "$UDID" ]; then
  echo "::error::runner 上没有可用的 iPhone 模拟器"
  exit 1
fi
echo "[smoke] Simulator=$UDID"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

DIAG="$HOME/Library/Logs/CoreSimulator/$UDID/Diagnostics"
mkdir -p "$DIAG" 2>/dev/null || true
crash_count() {
  find "$DIAG" -type f \( -name '*.crash' -o -name '*.ips' \) 2>/dev/null | wc -l | tr -d ' '
}
BEFORE="$(crash_count)"

xcrun simctl install "$UDID" "$APP"
LAUNCH="$(xcrun simctl launch "$UDID" "$BUNDLE")"
echo "[smoke] $LAUNCH"
sleep 8

AFTER="$(crash_count)"
if [ "$AFTER" -gt "$BEFORE" ]; then
  echo "::error::启动后产生新的崩溃报告（$BEFORE -> $AFTER）："
  ls -lt "$DIAG" | head -n 10
  exit 1
fi

mkdir -p dist
xcrun simctl io "$UDID" screenshot dist/smoke-ios.png
if [ ! -s dist/smoke-ios.png ]; then
  echo "::error::截图为空，模拟器可能未正常渲染"
  exit 1
fi
if ! xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -qF "$BUNDLE"; then
  echo "::warning::launchctl 中未查到应用服务标签（部分 Xcode 版本行为不同），截图与崩溃报告仍已校验"
fi
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl shutdown "$UDID" 2>/dev/null || true
echo "[smoke] iOS 模拟器冒烟通过：安装 / 启动 / 8 秒无崩溃 / 截图成功"
