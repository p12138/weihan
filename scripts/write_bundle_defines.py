#!/usr/bin/env python3
"""生成 --dart-define-from-file 用的 JSON（自带凭证自用包专用）。

只在 GitHub Actions runner 上执行：从环境变量读 Secrets / Variables，写一份
临时 JSON 供 `flutter build --dart-define-from-file` 使用。

安全约束：
  * 不打印任何凭证值，只打印键名；
  * 不把值拼进命令行（避免出现在进程列表 / 构建日志里）；
  * 文件权限 0600，用完由工作流删除；
  * 源码仓库里只有键名映射，永远没有任何真实凭证。

用法：python3 scripts/write_bundle_defines.py /tmp/weihan_bundle_defines.json
"""

from __future__ import annotations

import json
import os
import stat
import sys
from pathlib import Path

# dart-define 名 -> 环境变量名。缺任意一个都直接判失败，
# 绝不允许静默产出一个「看起来免配置、实则没凭证」的包。
REQUIRED: dict[str, str] = {
    "NIUTRANS_APP_ID": "NIUTRANS_APP_ID",
    "TRANSLATOR_API_KEY": "NIUTRANS_API_KEY",
    "XFYUN_APP_ID": "XFYUN_APP_ID",
    "XFYUN_API_KEY": "XFYUN_API_KEY",
    "XFYUN_API_SECRET": "XFYUN_API_SECRET",
}

# dart-define 名 -> (环境变量名, 缺省值)。空值用缺省值，保证 App 侧可用。
OPTIONAL: dict[str, tuple[str, str]] = {
    "NIUTRANS_UG_CODE": ("NIUTRANS_UG_CODE", "uy"),
    "XFYUN_UG_VCN": ("XFYUN_UG_VCN", ""),
    "XFYUN_ZH_VCN": ("XFYUN_ZH_VCN", "x4_xiaoyan"),
    "TRANSLATOR_ENDPOINT": ("TRANSLATOR_ENDPOINT", ""),
    "XFYUN_SPEECH_ENDPOINT": ("XFYUN_SPEECH_ENDPOINT", ""),
}


def main() -> int:
    dest = Path(sys.argv[1] if len(sys.argv) > 1
                else "/tmp/weihan_bundle_defines.json")
    defines: dict[str, str] = {}
    missing: list[str] = []

    for define_name, env_name in REQUIRED.items():
        value = (os.environ.get(env_name) or "").strip()
        if value:
            defines[define_name] = value
        else:
            missing.append(env_name)

    if missing:
        for env_name in missing:
            print("::error::缺少必需的 Secret：" + env_name)
        print("::error::请到 Settings → Secrets and variables → Actions 补齐后重跑；"
              "本轮不产出半成品安装包")
        return 1

    for define_name, (env_name, default) in OPTIONAL.items():
        value = (os.environ.get(env_name) or "").strip() or default
        if value:
            defines[define_name] = value

    if not defines.get("XFYUN_UG_VCN"):
        print("::warning::未配置 XFYUN_UG_VCN：维语朗读不可用，"
              "识别与文字翻译不受影响")

    # 让 App 走「凭证已内置」分支：设置页不回显密钥、留空保存不清空。
    defines["BUNDLED_SELFUSE"] = "true"

    dest.write_text(json.dumps(defines, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8")
    try:
        os.chmod(dest, stat.S_IRUSR | stat.S_IWUSR)  # 0600
    except OSError:
        pass  # Windows 本地调试时 chmod 无意义

    print("已生成 %d 项编译期配置（只列键名，不含任何值）：" % len(defines))
    for key in sorted(defines):
        print("  - " + key)
    return 0


if __name__ == "__main__":
    sys.exit(main())
