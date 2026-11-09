#!/usr/bin/env bash
# 在 Android 模拟器上自动安装并启动 debug APK，验证「能装、能开、不闪退」。
#
# 由 .github/workflows/auto-device-smoke.yml 在 emulator 启动后调用。
# 本机不需要安装 Flutter / Android SDK / adb —— SDK 全在 GitHub 托管 runner 上。
# 本机手工跑（需自备 SDK）：bash scripts/device_smoke_android.sh

set -euo pipefail

PKG="com.selfuse.uyghur.weihan"
APK="$(find build/app/outputs/flutter-apk -name '*debug*.apk' -type f | head -n 1)"
if [ -z "$APK" ]; then
  echo "::error::找不到 debug APK，请先执行 flutter build apk --debug"
  exit 1
fi
echo "[smoke] APK=$APK"

adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done'
adb install -r -t "$APK"
adb logcat -c
adb shell am start -W -n "$PKG/.MainActivity"
sleep 8

PID="$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}' || true)"
if [ -z "$PID" ]; then
  echo "::error::应用进程已退出（启动后 8 秒内闪退）"
  adb logcat -d -v brief | tail -n 60
  exit 1
fi
echo "[smoke] 进程存活 PID=$PID"

if adb logcat -d -v brief | grep -q 'FATAL EXCEPTION'; then
  echo "::error::模拟器日志出现 FATAL EXCEPTION："
  adb logcat -d -v brief | grep -A 12 'FATAL EXCEPTION' | tail -n 40
  exit 1
fi

mkdir -p dist
adb exec-out screencap -p > dist/smoke-android.png
if [ ! -s dist/smoke-android.png ]; then
  echo "::error::截图为空，模拟器可能未正常渲染"
  exit 1
fi
adb shell am force-stop "$PKG"
echo "[smoke] Android 模拟器冒烟通过：安装 / 启动 / 8 秒存活 / 无崩溃 / 截图成功"
