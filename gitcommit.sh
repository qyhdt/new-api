#!/usr/bin/env bash
# 快速提交并推送到 origin/main
# 用法: ./gitcommit.sh "提交说明"   # 不传则默认 update

set -euo pipefail

MSG="${1:-update}"
BRANCH="${GIT_BRANCH:-main}"

git add -A
if git diff --cached --quiet; then
    echo "没有可提交的变更。"
    exit 0
fi

git commit -m "$MSG"
git push origin "${BRANCH}"
