#!/usr/bin/env python3
"""把「无密钥控制面 JSON」发布到 deploy/update/ 并 push 到 main。

设计 A（见 README §10 / lib/update_sources.dart）：GitHub 只放无密钥的
`latest-*.json` / `remote-config.json`（匿名可读的控制面），含凭证的 APK/IPA
恒在 NAS、且只发草稿 Release，绝不入库、绝不公开。

用法：
  # 只校验（CI guard 用；有任何敏感键立即失败）
  python3 scripts/publish_control_plane.py --validate-only deploy/update/remote-config.json

  # 校验 + 复制清单 + 提交 push（bundled-apk / bundled-ios 用）
  python3 scripts/publish_control_plane.py \
      --manifest dist/latest-android.json --name latest-android.json --push

流程：
  1. 校验：静态 remote-config.json 与待发布清单都不含 secrets / 凭证键（硬门禁）。
  2. 把清单复制进 deploy/update/<name>，确保 remote-config.json 也在该目录。
  3. 以 github-actions[bot] 身份、commit message 带 [skip ci] 提交，
     git pull --rebase origin main 后 git push origin HEAD:main。

防递归（三重）：
  * [skip ci]：GitHub 对含该标记的 push 不触发任何 workflow（含 verify-first-build，
    它没有 paths 过滤）。
  * selfuse-bundled.yml / auto-device-smoke.yml 的 on.push.paths 不含 deploy/**。
  * 调用方 job 级 if: github.actor != 'github-actions[bot]'。

安全：只发布无密钥 JSON。control-plane push 失败只告警、不阻断出包——
用户的可测自用包（草稿 Release）在本步骤之前就已发布，不能因控制面抖动丢包。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REMOTE_CONFIG = ROOT / "deploy" / "update" / "remote-config.json"

# 公开控制面里绝不允许出现的键（大小写不敏感）。空值不算泄露。
FORBIDDEN_KEYS = {
    "secrets",
    "apikey",
    "api_key",
    "api_secret",
    "appsecret",
    "app_secret",
    "privatekey",
    "private_key",
    "password",
    "token",
    "access_token",
    "credential",
    "credentials",
}


def _find_secret(node: object) -> str | None:
    if isinstance(node, dict):
        for key, value in node.items():
            if str(key).lower() in FORBIDDEN_KEYS and value not in (
                None,
                "",
                {},
                [],
            ):
                return str(key)
            found = _find_secret(value)
            if found:
                return found
    elif isinstance(node, list):
        for value in node:
            found = _find_secret(value)
            if found:
                return found
    return None


def validate(path: pathlib.Path) -> None:
    if not path.is_file():
        print("::error::找不到控制面文件：" + str(path))
        raise SystemExit(1)
    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print("::error::控制面 JSON 解析失败：%s：%s" % (path, exc))
        raise SystemExit(1)
    bad = _find_secret(obj)
    if bad:
        print("::error::%s 含敏感键 %s，拒绝发布到公开控制面" % (path, bad))
        raise SystemExit(1)
    print("::notice::%s 无密钥校验通过" % path)


def _git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        check=check,
    )


def publish(manifest: pathlib.Path, name: str) -> None:
    dest_dir = ROOT / "deploy" / "update"
    dest_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(manifest, dest_dir / name)
    print("::notice::已把 %s 复制到 deploy/update/%s" % (manifest, name))

    _git("config", "user.name", "github-actions[bot]")
    _git("config", "user.email",
         "41898282+github-actions[bot]@users.noreply.github.com")
    _git("add", "deploy/update/" + name, "deploy/update/remote-config.json")
    if _git("diff", "--cached", "--quiet", check=False).returncode == 0:
        print("::notice::控制面无变化，跳过提交")
        return
    _git("commit", "-m",
         "chore(update): 发布控制面 %s [skip ci]" % name)

    # 串行化：另一个 job 或用户可能已经往 main 推了东西，rebase 到最新再推。
    pull = _git("pull", "--rebase", "origin", "main", check=False)
    if pull.returncode != 0:
        print("::warning::git pull --rebase 失败：%s"
              % (pull.stderr or "").strip()[:200])
    push = _git("push", "origin", "HEAD:main", check=False)
    if push.returncode != 0:
        # 控制面是尽力而为：草稿 Release 已发布，不能因这一步失败误判整轮出包。
        print("::warning::控制面 push 失败（不阻断出包）：%s"
              % (push.stderr or "").strip()[:200])
        return
    print("::notice::控制面已 push 到 main（[skip ci]，不会触发新 workflow）")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--validate-only", nargs="+", default=[],
                        metavar="PATH", help="只校验这些控制面 JSON，不发布")
    parser.add_argument("--manifest", help="CI 生成的清单路径（如 dist/latest-android.json）")
    parser.add_argument("--name", help="落到 deploy/update/ 下的文件名")
    parser.add_argument("--push", action="store_true",
                        help="执行 git 提交与 push；不传只校验+复制")
    args = parser.parse_args()

    if args.validate_only:
        for raw in args.validate_only:
            validate(pathlib.Path(raw))
        return 0

    if not args.manifest or not args.name:
        print("::error::需要 --manifest 与 --name（或用 --validate-only）")
        return 1

    # 静态配置是硬门禁；待发布清单同样校验（make_update_manifest 本就不产生密钥，
    # 这里再兜一层，防止以后有人往清单里塞敏感字段）。
    validate(REMOTE_CONFIG)
    manifest = pathlib.Path(args.manifest)
    validate(manifest)
    publish(manifest, args.name) if args.push else _copy_only(manifest, args.name)
    return 0


def _copy_only(manifest: pathlib.Path, name: str) -> None:
    dest_dir = ROOT / "deploy" / "update"
    dest_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(manifest, dest_dir / name)
    print("::notice::未指定 --push：已复制到 deploy/update/%s，跳过 git" % name)


if __name__ == "__main__":
    sys.exit(main())
