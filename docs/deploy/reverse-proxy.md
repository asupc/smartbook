# 反向代理部署(HTTPS-only 的实现层)

> 适用:仓库根 `docker-compose.yml`(canonical 部署,SmartBook-Cloud + PostgreSQL)。
> server/ 下的 compose 仅本地开发用,不在本文范围。

## 现状与结论

**SmartBook-Cloud 容器本身只跑 HTTP(uvicorn, 8080 端口),不做 TLS。**
"HTTPS-only" 一贯由**外部反向代理**实现:反代终止 TLS 后,把明文流量转给容器
(默认发布端口 `SMARTBOOK_PORT=8869`),对外只暴露反代的 443。应用代码内没有
强制 HTTPS 的中间件 —— 不设反代而直接把 8869 暴露公网,所有流量(含 JWT、
AI API Key 中转)都是明文,属错误部署。

镜像 CMD 已带 `--proxy-headers`,compose 已设 `FORWARDED_ALLOW_IPS: 172.16.0.0/12`
(见根 docker-compose.yml 注释)。两者配合:

- uvicorn 从反代注入的 `X-Forwarded-For` / `X-Forwarded-Proto` 还原真实客户端
  IP —— 登录限流 key(`src/routers/auth.py` 的 `{action}:{client}`)与审计
  `client_ip` 依赖它。不开时所有请求的来源都是反代/网桥网关 IP,限流退化为
  **全站共享桶**(一个来源可打满全站 429)。
- `FORWARDED_ALLOW_IPS` 圈定"谁设置的 X-Forwarded-* 可信":
  - `172.16.0.0/12`(默认):覆盖 Docker 默认 bridge / compose 网络地址池
    (172.17-172.31.x)。宿主机上的 nginx/caddy 经发布端口进容器,源 IP 是
    网桥网关;同 compose 网络的容器反代,源 IP 是容器自身 —— 都在网段内。
    绕过反代直连发布端口的外部来源保留真实 IP,不在网段内,伪造头无效。
  - `*`:信任任何直连来源。**只有**发布端口被防火墙挡住、仅反代可达时才可
    用;否则任何人都能伪造 X-Forwarded-For 绕过限流。
  - 自定义过 daemon.json `default-address-pool` 或启用 IPv6 网络的,按实际
    网段调整(uvicorn 支持逗号分隔多网段 / CIDR / IPv6)。

反代必须注入的请求头(下面样例已含):

| 头 | 作用 |
|---|---|
| `X-Forwarded-For`(或 `X-Real-IP`) | 还原客户端 IP(限流/审计) |
| `X-Forwarded-Proto` | 还原对外 scheme(`request.base_url`,MCP `.well-known` 元数据等用) |
| `Host` | 对外域名(生成绝对 URL) |

WebSocket(同步推送,路径 `/ws`,根路径、不在 `/api/v1` 下)需要升级透传,
样例已含。

## nginx 最小样例

`/etc/nginx/conf.d/smartbook.conf`(证书自备,如 acme.sh / certbot 签发):

```nginx
# 明文 80 只做跳转
server {
    listen 80;
    server_name your-server.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name your-server.example.com;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    # 上传上限与后端一致(附件/备份上传;.env 可经 BACKUP_MAX_UPLOAD_BYTES 调大)
    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:8869;
        proxy_http_version 1.1;

        # 客户端 IP / scheme / Host 还原(见上表)
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket(/ws)+ 长请求(备份导入/AI 中转)超时放宽
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout  300s;
        proxy_send_timeout  300s;
    }
}
```

`/etc/nginx/conf.d/upgrade-map.conf`(配合上面的 `$connection_upgrade`):

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
```

注意:`map` 指令必须在 `http` 上下文 —— conf.d 下的文件都在 http 块内,直接
放同目录即可。

## Caddy 最小样例

Caddy 自动签发/续期证书(需域名解析到本机、80/443 可达),`Caddyfile`:

```caddy
your-server.example.com {
    # 上传上限与后端一致
    request_body {
        max_size 64MB
    }

    reverse_proxy 127.0.0.1:8869 {
        # Caddy 默认即设置 X-Forwarded-For(取真实客户端 IP,忽略入站伪造值)/
        # X-Forwarded-Proto / X-Forwarded-Host,WebSocket 升级自动透传,
        # 这里无需也不应手工改写转发头。
        header_up +X-Real-IP {http.vars.client_ip}

        # 长请求(备份导入/AI 中转)超时放宽
        transport http {
            read_timeout 300s
            write_timeout 300s
        }
    }
}
```

(用容器跑 Caddy 时,把 `127.0.0.1:8869` 换成 `smartbook-cloud:8080` 并与
compose 网络互通,发布端口即可收回不对外暴露。)

## 自查清单

- [ ] 对外仅暴露反代 443;`SMARTBOOK_PORT` 只供本机反代可达(或干脆不发布,
      让反代容器走内部网络)。
- [ ] `curl -k https://your-server/healthz` 通,`curl http://your-server/healthz` 301。
- [ ] 反代日志/服务端日志里的 client IP 是真实来源而非 `172.x.x.x` 网关。
- [ ] `.env` 的 `CORS_ORIGINS` 与对外地址一致(经 env_file 注入,见根 compose)。
