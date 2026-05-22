# new-api Edge Nginx（`aiapi.thyseed.com`、`aicenter.thyseed.com`）

生产机 **独占 80/443** 的入口容器 **`edge-nginx`**，通过 Docker 网络 **`new_api_edge_net`** 反代到 **`new-api:3000`**。

## 和 thyseed-platform 的对比

| | thyseed-platform | new-api |
|---|------------------|---------|
| 前端 | 独立容器 `thyseed-*-web:80` | **Go 单体**内置静态页 |
| 后端 | Java `:8080` | **同一容器** `:3000` |
| 路由 | `/` → 前端，`/api/` → Java | **`/` 全部 → new-api:3000** |
| 网络 | `thyseed_edge_net` | `new_api_edge_net` |

## 端口说明

| 位置 | 端口 | 说明 |
|------|------|------|
| 公网 | **80 / 443** | `edge-nginx` 映射到宿主机 |
| 容器内 | **3000** | `new-api` 监听（前后端同源） |
| 宿主机 | ~~3000~~ | **不再**对公网暴露（已去掉 compose 的 `ports: 3000:3000`） |
| 本机调试 | 127.0.0.1:5432 / 6379 | postgres / redis 仅本机 |

## 架构

```text
Internet :443 / :80
        │
   edge-nginx  (aiapi.thyseed.com, TLS)
        │  new_api_edge_net
        ▼
   new-api:3000  ──►  new_api_infra_net ──► postgres / redis
        │
   /home/work/data/log          ← 应用日志
   /home/work/data/log/edge-nginx  ← edge 访问日志
```

## 文件

```text
devops/edge-proxy/
├── docker-compose.yml
├── nginx-main.conf
├── nginx.conf
├── proxy_params.inc
├── upstreams.conf.example
└── README.md

/home/work/data/runtime/edge-proxy/upstreams.conf   # 运行时（不进 git）
/home/work/data/log/edge-nginx/                     # proxy.log
devops/cert/thyseed.com.pem|.key                    # *.thyseed.com 证书
```

## 部署

随应用一键脚本自动拉起：

```bash
cd ~/new-api/devops/deployment && ./deploy-online.sh
```

仅更新 edge：

```bash
cd ~/new-api/devops/edge-proxy
docker compose up -d
docker exec edge-nginx nginx -t && docker exec edge-nginx nginx -s reload
```

修改 upstream / 蓝绿：编辑 `/home/work/data/runtime/edge-proxy/upstreams.conf` 后 `nginx -s reload`。

## DNS / 防火墙

- **A 记录**：`aiapi.thyseed.com`、`aicenter.thyseed.com` → 服务器公网 IP（如 `43.155.195.115`）
- **安全组**：放行 **80、443**（可关闭公网 **3000**）
