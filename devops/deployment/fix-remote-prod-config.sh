#!/usr/bin/env bash
# 修正远端生产配置：ServerAddress + 前端主题（与本地 dev.sh 的 default/thyseed 一致）
#
# 用法：
#   ./fix-remote-prod-config.sh
#   PUBLIC_URL=https://aiapi.thyseed.com ./fix-remote-prod-config.sh

set -euo pipefail

REMOTE_HOST="${REMOTE_HOST:-43.155.195.115}"
REMOTE_USER="${REMOTE_USER:-work}"
PUBLIC_URL="${PUBLIC_URL:-https://aicenter.thyseed.com}"
FRONTEND_THEME="${FRONTEND_THEME:-default}"

REMOTE="${REMOTE_USER}@${REMOTE_HOST}"

echo "修正 ${REMOTE}：ServerAddress=${PUBLIC_URL}  theme.frontend=${FRONTEND_THEME}"

ssh -o StrictHostKeyChecking=accept-new "${REMOTE}" bash -s <<REMOTE
set -euo pipefail
PGPASS=\$(grep ^POSTGRES_PASSWORD= ~/new-api/devops/deployment/.env | cut -d= -f2)
docker exec -e PGPASSWORD="\$PGPASS" new-api-postgres psql -U root -d new-api -v ON_ERROR_STOP=1 -c \
  "INSERT INTO options (key, value) VALUES ('ServerAddress', '${PUBLIC_URL}') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;"
docker exec -e PGPASSWORD="\$PGPASS" new-api-postgres psql -U root -d new-api -v ON_ERROR_STOP=1 -c \
  "INSERT INTO options (key, value) VALUES ('theme.frontend', '${FRONTEND_THEME}') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;"
docker restart new-api >/dev/null
echo "已重启 new-api，等待就绪..."
for i in \$(seq 1 30); do
  if docker exec new-api wget -qO- http://127.0.0.1:3000/api/status 2>/dev/null | grep -q '${PUBLIC_URL#https://}'; then
    echo "OK"
    exit 0
  fi
  sleep 2
done
echo "WARN: 请手动检查 docker logs new-api"
REMOTE

echo "完成。请刷新 https://aicenter.thyseed.com"
