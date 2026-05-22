#!/usr/bin/env bash
# 从仓库 devops/ 目录快捷调用 deployment/deploy-remote.sh
exec "$(cd "$(dirname "$0")/deployment" && pwd)/deploy-remote.sh" "$@"
