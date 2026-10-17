#!/bin/bash
# 把本地代码推送到一个**已创建的空仓库**。
# 用法: scripts/publish_new_repo.sh git@github.com:<user>/<repo>.git [分支名]
# 说明: 脚本不会替你创建远程仓库;请先在 GitHub 网页创建一个空仓库(不要初始化 README)。
set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE="${1:-}"
BRANCH="${2:-main}"
if [ -z "$REMOTE" ]; then
  echo "用法: scripts/publish_new_repo.sh git@github.com:<user>/<repo>.git [分支名]"
  exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "⚠️ 工作区有未提交改动,请先提交。"
  exit 1
fi

git remote remove origin 2>/dev/null || true
git remote add origin "$REMOTE"
git push -u origin "HEAD:$BRANCH"
echo "✅ 已推送到 $REMOTE ($BRANCH)"
