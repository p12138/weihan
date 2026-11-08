#!/usr/bin/env bash
# 把当前工程推到一个「完全空的」GitHub 仓库，用于首次触发 CI。
# Token 只从环境变量读取，不写入任何文件、不留在 .git/config、不进提交历史。
#
# 用法：
#   export GITHUB_TOKEN=ghp_xxx        # 勾选 repo 权限，用完立即在 GitHub 撤销
#   export GITHUB_REPO=用户名/仓库名
#   bash scripts/push_to_github.sh
#
# 前提：仓库必须是完全空的（不要勾 README / .gitignore / license），否则 push 会被拒。

set -euo pipefail

: "${GITHUB_TOKEN:?请先 export GITHUB_TOKEN（勾选 repo 权限的 PAT，用完撤销）}"
: "${GITHUB_REPO:?请先 export GITHUB_REPO=用户名/仓库名}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[push] 初始化 git 仓库（分支 main）"
  git init -b main
fi

# 无论是否已有提交，都要把刚拷进来的 scripts/ 与 workflows/ 纳入版本控制，
# 否则仓库推上去后 CI 仍会报「文件不存在」。
git add -A
if git diff --cached --quiet; then
  echo "[push] 无待提交改动"
else
  git -c user.name="selfuse" -c user.email="selfuse@localhost" \
      commit -m "chore: add self-use build tooling (verify / bootstrap / workflows)"
fi

if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "[push][error] 仓库里没有任何提交，无法推送" >&2
  exit 1
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
echo "[push] 推送分支 $branch → $GITHUB_REPO"

# 直接用带凭证的 URL 推送，不设置 upstream，避免 token 落进 .git/config
git push "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git" \
    "HEAD:refs/heads/${branch}"

# 单独配置一个干净 remote，供后续日常 pull / push 使用
clean_url="https://github.com/${GITHUB_REPO}.git"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$clean_url"
else
  git remote add origin "$clean_url"
fi

echo "[push] 完成。remote 已设为不带凭证的 $clean_url"
echo "[push] 请立刻到 GitHub 撤销这个 PAT，然后查看 Actions 里的 verify-first-build 结果。"
