#!/usr/bin/env bash
# 在 iOS Simulator 上自动安装并启动 debug .app，验证「能装、能开、不闪退」。
#
# 由 .github/workflows/auto-device-smoke.yml 在 macos-15 runner 上调用。
# 模拟器构建不需要证书、不需要 Apple 账号、不需要真机，也不需要你手动装包。
# 本机手工跑（仅 macOS + Xcode）：bash scripts/device_smoke_ios.sh

set -euo pipefail

# macOS 没有 coreutils 的 `timeout`，而 `xcrun simctl bootstatus -b` 在模拟器
# 起不来时会一直等下去，能把整个 job 拖到 GitHub 的 6 小时上限。自己带个看门狗：
# 超时先 TERM 再 KILL，返回命令自己的退出码（被 KILL 时是 143）。
# 注意不能用 `$!` + `kill -0` 轮询判断存活——子进程已退出但未 wait 时是僵尸，
# `kill -0` 仍然成功，会误判成超时；只能直接 wait 真正的 pid。
run_with_timeout() {
  local limit="$1"
  shift
  "$@" &
  local pid=$!
  (
    sleep "$limit"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$pid" 2>/dev/null || true
  ) &
  local watchdog=$!
  local rc=0
  wait "$pid" || rc=$?
  kill -TERM "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$rc"
}

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
# 首次启动新 runtime 可能要 1-2 分钟；给 240 秒上限，超时也不直接判红：
# 后面的 install 会给出真正的失败原因，比一句「等待超时」好排查。
if ! run_with_timeout 240 xcrun simctl bootstatus "$UDID" -b; then
  echo "::warning::bootstatus 未在 240s 内完成，继续尝试安装（失败时会报出真实原因）"
fi

DIAG="$HOME/Library/Logs/CoreSimulator/$UDID/Diagnostics"
mkdir -p "$DIAG" 2>/dev/null || true
crash_count() {
  find "$DIAG" -type f \( -name '*.crash' -o -name '*.ips' \) 2>/dev/null | wc -l | tr -d ' '
}
BEFORE="$(crash_count)"

if ! run_with_timeout 180 xcrun simctl install "$UDID" "$APP"; then
  echo "::error::安装失败（或 180s 超时）：模拟器可能没真正启动起来"
  xcrun simctl list devices | grep -F "$UDID" || true
  exit 1
fi
LAUNCH="$(run_with_timeout 120 xcrun simctl launch "$UDID" "$BUNDLE")" || {
  echo "::error::启动失败（或 120s 超时）"
  exit 1
}
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
# 进程标签出现的时机依 Xcode 版本而异，给 3 次、每次间隔 2 秒的重试上限，
# 仍然查不到只当作提示（不同 Xcode 行为不同，不该据此判红）。
launch_visible=0
for _ in 1 2 3; do
  if xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -qF "$BUNDLE"; then
    launch_visible=1
    break
  fi
  sleep 2
done
if [ "$launch_visible" -ne 1 ]; then
  echo "::warning::launchctl 中未查到应用服务标签（部分 Xcode 版本行为不同），截图与崩溃报告仍已校验"
fi
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl shutdown "$UDID" 2>/dev/null || true
echo "[smoke] iOS 模拟器冒烟通过：安装 / 启动 / 8 秒无崩溃 / 截图成功"
