# new-api 运维 · 一键部署

目标机默认：`work@43.155.195.115`，数据与日志统一在 `/home/work/data/`：

```
/home/work/data/
├── postgres/    # PostgreSQL 数据
├── redis/       # Redis 数据
├── log/         # new-api 应用日志 + edge-nginx/ 访问日志
├── app-data/    # new-api /data 卷
└── runtime/edge-proxy/upstreams.conf
```

公网入口：**edge-nginx** `80/443` → `https://aiapi.thyseed.com` → 容器 **new-api:3000**（前后端同源，不再暴露宿主机 3000）。

详见 [edge-proxy/README.md](edge-proxy/README.md)。

---

## 首次一键部署（新机）

**本机**需已安装 `sshpass`（mac：`brew install hudochenkov/sshpass/sshpass`）。

```bash
cd /path/to/new-api
chmod +x devops/one_click_deploy.sh devops/init_new_node/*.sh devops/deployment/*.sh
./devops/one_click_deploy.sh
```

流程：

1. `init_new_node/create_new_machine.sh`：用 `passwd.txt` 里的 ubuntu 密码登录 → 创建 `work` 用户（NOPASSWD sudo）→ 装 Docker → 配置本机 SSH 免密 → 拉回 `work` 公钥到 `keys/<ip>/`
2. `deployment/deploy.sh` → 远端 `deploy-online.sh`：`git pull` + compose 起 postgres / redis / new-api + **edge-nginx**

**GitHub 私库**：把 `devops/init_new_node/keys/43.155.195.115/work_id_rsa.pub` 加到 GitHub SSH Keys，否则远端 `git clone` 会失败。

完成后访问：**https://aiapi.thyseed.com**（edge-nginx :443；需 DNS 与证书 `devops/cert`）

直连调试（仅 Docker 内网）：`docker exec edge-nginx wget -qO- http://new-api:3000/api/status`

---

## 远程部署（本机执行，推荐日常）

代码 push 到 GitHub 后，在本机跑：

```bash
cd /path/to/new-api
./devops/deployment/deploy-remote.sh
# 或
./devops/deploy-remote.sh
```

仅重启、不重新编译：`./deploy-remote.sh --skip-build`

| 变量 | 默认 |
|------|------|
| `REMOTE_HOST` | `43.155.195.115` |
| `REMOTE_USER` | `work` |
| `GIT_BRANCH` | `main` |

流程：本机 SSH → 同步 `deploy-online.sh` → 远端 `git pull` + `docker compose build/up` + `edge-nginx`。

## 仅部署应用（机器已初始化、跳过 init）

```bash
./devops/one_click_deploy.sh --skip-init
# 等价于
./devops/deploy-remote.sh
```

## 登录远端手动部署

```bash
ssh work@43.155.195.115
cd ~/new-api/devops/deployment && ./deploy-online.sh
```

---

## 仅初始化机器（不部署应用）

```bash
cd devops/init_new_node
./create_new_machine.sh              # 按 machine.list + passwd.txt 批量
./create_new_machine.sh --single 43.155.195.115 ubuntu 'your_password'
./loginwork.sh                       # 免密 ssh work@
```

---

## 远端常用命令

```bash
ssh work@43.155.195.115
cd ~/new-api/devops/deployment

docker compose -f docker-compose.infra.yml --env-file .env ps
docker compose -f docker-compose.app.yml --env-file .env ps
docker logs -f new-api
docker logs -f edge-nginx
ls -la /home/work/data/log /home/work/data/log/edge-nginx
```

---

## 本地库同步到远端（覆盖）

```bash
cd devops/deployment/sync-db
./01-dump-local.sh              # 步骤1：导出本地 PG + Redis
./02-restore-remote.sh          # 步骤2：上传并覆盖远端（会确认）
# 或一键：./sync-db-to-remote.sh
```

详见 [deployment/sync-db/README.md](deployment/sync-db/README.md)。

---

## 配置文件

| 文件 | 说明 |
|------|------|
| `init_new_node/passwd.txt` | ubuntu 初始密码（**已 gitignore**） |
| `init_new_node/machine.list` | 要初始化的 IP 列表 |
| `deployment/.env` | 远端生产配置（首次由 bootstrap 自动生成随机密钥） |

---

## 安全提示

- `passwd.txt` 含明文密码，勿提交 git。
- 生产环境请在部署后修改 ubuntu 密码、轮换 `.env` 中的数据库与 `SESSION_SECRET`。
- 腾讯云安全组需放行 **80、443**（edge-nginx）和 **22**（SSH）；**不必**再对公网开放 3000。
