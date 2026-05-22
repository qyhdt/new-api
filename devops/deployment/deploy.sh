#!/usr/bin/env bash
# 兼容入口 → deploy-remote.sh
exec "$(cd "$(dirname "$0")" && pwd)/deploy-remote.sh" "$@"
