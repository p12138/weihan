#!/usr/bin/env bash
# 在开发者本机生成 Android 自用签名密钥。
# 产物（.jks）与密码绝不提交进仓库；本脚本不打印、不保存、不传输任何密码或私钥。
set -euo pipefail

OUT_DIR="${1:-./android/app}"
ALIAS="${ANDROID_KEY_ALIAS:-selfuse}"
KEYSTORE="$OUT_DIR/selfuse.jks"

if ! command -v keytool >/dev/null 2>&1; then
  echo "未找到 keytool，请先安装 JDK 17 并确保它在 PATH 中" >&2
  exit 1
fi

if [ -f "$KEYSTORE" ]; then
  echo "已存在 $KEYSTORE，为避免覆盖已有签名密钥，直接退出" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
echo "即将生成自用签名密钥： $KEYSTORE"
echo "接下来 keytool 会交互式询问密码与证书信息；密码请存进密码管理器，不要写进任何文件。"

keytool -genkeypair -v \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 2048 -validity 10000

cat <<'NOTE'

生成完成，接下来四件事：
  1. 确认 .gitignore 已包含：*.jks / *.keystore / android/key.properties / dist/
  2. 本机构建：把 android/key.properties.example 复制为 android/key.properties 并填写
  3. CI 构建：把 keystore 转成 base64 存进 GitHub Secret ANDROID_KEYSTORE_B64
       Linux:  base64 -w0 android/app/selfuse.jks
       macOS:  base64 -i android/app/selfuse.jks | tr -d '\n'
  4. 离线备份 keystore 与两个密码。丢失后无法覆盖升级已装的自用包，只能卸载重装。

提醒：密码只进密码管理器 / CI Secrets，绝不写进脚本、README 或提交记录。
NOTE
