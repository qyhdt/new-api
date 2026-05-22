#!/usr/bin/env bash
# 兼容入口：与 deploy-online.sh 相同（供 deploy.sh / one_click_deploy 从本机 scp 触发）
exec "$(cd "$(dirname "$0")" && pwd)/deploy-online.sh" "$@"
