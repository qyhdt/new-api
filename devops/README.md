# new-api 运维 · 一键部署

目标机默认：`work@43.155.195.115`，数据与日志统一在 `/home/work/data/`：

```
/home/work/data/
├── postgres/    # PostgreSQL 数据
├── redis/       # Redis 数据
├── log/         # new-api 应用日志（--log-dir /app/logs）
└── app-data/    # new-api /data 卷
```

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
2. `deployment/deploy.sh`：推送 `remote_bootstrap.sh` → 远端 `git clone` + `docker compose` 起 postgres / redis / new-api

**GitHub 私库**：把 `devops/init_new_node/keys/43.155.195.115/work_id_rsa.pub` 加到 GitHub SSH Keys，否则远端 `git clone` 会失败。

完成后访问：**http://43.155.195.115:3000**

---

## 仅部署应用（机器已初始化）

```bash
./devops/one_click_deploy.sh --skip-init
# 或
HOST=43.155.195.115 ./devops/deployment/deploy.sh
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
ls -la /home/work/data/log
```

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
- 腾讯云安全组需放行 **3000**（new-api）和 **22**（SSH）。
