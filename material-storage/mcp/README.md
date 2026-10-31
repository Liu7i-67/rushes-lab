# ms-mcp — 素材库 MCP 薄代理

material-storage 的第三个客户端渠道:让 AI(ZCode / Claude / 自研 agent)通过
**MCP 协议(Streamable HTTP)**以**用户本人身份**搜索、看缩略图、下载、上传素材。

**架构红线**:本服务是 api 的薄代理——不直连 DB / Redis / MinIO、不持有任何存储凭据;
权限(OpenFGA)、审计、限流、风控全部由 api 负责。唯一的字节穿行是缩略图
(按 api 返回的 presigned URL 取回,以 MCP image content 返回)。

方案正本:`docs/qdev/2026-10-30-mcp-service.md`(本目录对应「包 B」)。

## 结构

```
material-storage/mcp/
├── pyproject.toml / constraints.txt   # Python 3.12 + mcp==1.30.0 + 传递依赖闭包全 pin
├── Dockerfile / .dockerignore         # 非 root,清华 APT/PIP build arg
├── src/ms_mcp/
│   ├── config.py       # env 解析、Host 白名单、XFP 归一
│   ├── session.py      # Mcp-Session-Id ↔ PAT 绑定(内存,TTL + 容量上限)
│   ├── clients.py      # 转发客户端(带 PAT)/ 缩略图字节客户端(裸 URL)
│   ├── middleware.py   # 纯 ASGI 守门:Host 403 / 会话 401 / initialize 先验 /auth/me
│   ├── toolimpl.py     # 11 个工具的 API 映射(可单测)
│   ├── views.py        # 结构化字段白名单 + 文件夹组树
│   ├── tools.py        # FastMCP 工具注册 + 描述 + 按调用粒度的信号量
│   ├── logging_utils.py# Session-Id 日志脱敏(SDK 会打 session id)
│   └── server.py       # FastMCP + 中间件 + /healthz 组装;python -m ms_mcp 启动
└── tests/              # mock api 的工具层单测 + 真实 SDK initialize 冒烟
```

## 环境变量(只有这几个,禁止 `env_file`)

| 变量 | 必填 | 默认(compose) | 说明 |
|---|---|---|---|
| `MS_API_BASE_URL` | 是 | `http://ms-api:8000` | api 根地址(容器内)。dev 覆盖为 dev 服务名 |
| `MS_MCP_ENTRY_ALLOWLIST` | 是 | 见 compose(prod 10 条,无 `:8090`) | 入口白名单 `host=scheme,host=scheme`;按环境裁剪 |
| `MS_MCP_INTERNAL_BASE_URL` | 是 | `http://192.168.110.221` | 取缩略图字节时的固定 Host(启动校验必须命中白名单且 scheme 一致;dev 用 `:8090`) |
| `MS_MCP_SESSION_TTL` | 否 | `1800` | 空闲会话 TTL(秒);同时作为 FastMCP `session_idle_timeout` |
| `MS_MCP_VERIFY_TLS` | 否 | `true` | 两套 httpx 客户端共用的 verify 开关(内网 http 无所谓;公网自签阶段可 `false`) |
| `MS_MCP_CA_BUNDLE` | 否 | 空 | CA 文件路径(优先于 `MS_MCP_VERIFY_TLS`) |
| `MS_MCP_LOG_LEVEL` | 否 | `INFO` | 进程日志级别 |

**不在本服务**:DB / Redis / MinIO 任何凭证、OpenFGA、`MINIO_*`。会话数上限(200)是
编译常量(`config.SESSION_CAP`,仅测试注入),没有 env 调大通道。

## 认证与会话语义(为什么能安全复用 PAT)

- Streamable HTTP 客户端可能只在 `initialize` 带一次 `Authorization: Bearer mspat_...`;
  ms-mcp 在内存里按 `Mcp-Session-Id` 绑定该 PAT,后续请求不带 PAT 时复用。
- `initialize`(无 Session-Id 的 POST)**必须带 Authorization**,且 ms-mcp 先带该 PAT
  调一次 `GET /api/v1/auth/me` 确认有效才放行给 SDK 建会话——匿名者不能反复 initialize
  填满会话表,同时顺带受 api 的通道闸/IP 桶/RPM 约束。
- 绑定缺失 → 401;同一 Session-Id 后续带不同 PAT → 401(**不自动换绑,须重新 initialize**);
  客户端 `DELETE /mcp` 结束会话时立即清绑定,否则空闲 TTL(默认 30min)/ 容量上限淘汰。
- 进程重启/单副本 = 所有会话失效,客户端需重新 initialize(Web/App 不受影响)。

## 入口 Host 白名单(运维重点)

格式:`host=scheme`,逗号分隔;请求 `Host` 与条目均 **lower() 后精确比较(端口算在内)**,
**未命中 403 不回落**(回落会以容器名签出客户端不可达的 URL,还白占动态 signer 名额)。
命中的条目决定该入口的 scheme(供 XFP 归一):客户端自报的 X-Forwarded-Proto 与条目冲突 /
缺失 / 非法时一律以条目为准。

维护要求:

- **按实际可用入口全量枚举拼法**:内网 IP(裸 / `:80`)、公网 IP(`:443`、`:18080`、`:8080`)、
  域名(裸 / `:443`)、`localhost` 与 `127.0.0.1`(含本地调试端口)。漏一种拼法 = 该形态全量 403。
- 当前 prod 入口集合见 `rushes-spec/material-storage/ops-manual.md` §11.2 与
  `.agents/skills/deploy-hh2/SKILL.md`;`rusheslab.taoxiplan.com` 属旧栈,不列入。
- **按环境裁剪**:dev 白名单不得放行 prod Host(反之亦然),否则跨环境签名零成本。
- 条目 ≤14;去重 `scheme://host` 全集 ≤16(api 的动态 signer 缓存按 `scheme://host` 计键、
  全进程共享,与 web/app 是**并集**)。部署前用 `docker compose config` 核对条目数。
- 部署前顺带核对 prod `.env` 的 `MINIO_ENDPOINT_PUBLIC`:动态 signer 打满后新入口回落该
  静态值,若它指向不可达地址,MCP 客户端会拿到坏 URL。

## 工具(11 个)

| 工具 | api 映射 | 要点 |
|---|---|---|
| `whoami()` | `GET /api/v1/auth/me` | 白名单字段,不透 email/open_id/union_id/organization_id |
| `list_projects(page?, limit?)` | `GET /api/v1/projects?limit=&offset=` | limit ≤100(默认 50);无 total,提示可能还有更多 |
| `list_folders(project_id)` | `GET /api/v1/folders?project_id=` | 服务端组 children 树;剔除 minio_prefix/is_sensitive |
| `list_files(folder_id, page?)` | `GET /api/v1/assets?folder_id=&limit=100&offset=` | 每页 100,返回 total/has_more |
| `search_assets(q, limit?)` | `GET /api/v1/assets/search?q=&limit=` | 主路径;limit ≤50 默认 20 |
| `get_thumbnail(asset_id, size)` | `GET /api/v1/assets/{id}/thumbnail-url` → GET 字节 | 固定内网 Host 签 URL;裸客户端取字节(15s);MCP image content |
| `get_download_url(asset_id)` | `POST /api/v1/assets/{id}/download-link` | 15min URL,提示「字节自取、勿反复续签」 |
| `create_upload(folder_id, filename, size_bytes, content_type?)` | `POST /api/v1/assets/uploads` + `GET .../parts/1` | 工具层先拒 >5GiB;>1GiB 提示走内网入口;同名 409 原样透出 |
| `get_part_url(upload_id, key, bucket, part_number)` | `GET /api/v1/assets/uploads/{id}/parts/{n}` | 同 multipart 续传,勿重跑 create |
| `abort_upload(upload_id, key, bucket)` | `DELETE /api/v1/assets/uploads/{id}` | 不留半成品;只传自己的三元组 |
| `complete_upload(upload_id, folder_id, key, bucket, etag, part_number=1)` | `POST /api/v1/assets/uploads/{id}/complete` | body `parts=[{PartNumber, ETag}]`(数组);ETag 取自 PUT 响应头;超时先 search/list 确认 |

转发细节:带 PAT、`User-Agent: msmcp/<ver>`、透传入口 `Host` + 归一后的
`X-Forwarded-Proto` + 单值 `X-Forwarded-For`,**剥离 Cookie 与 X-User-Id**,超时 30s。
工具错误统一 `isError=true` + 可读文案,不透堆栈;日志不记 Authorization / PAT / Session-Id。

## 本地开发与测试

```bash
cd material-storage/mcp
uv sync                                   # Python 3.12 + 依赖(含 dev 组)
uv run ruff check .
uv run pytest -q                          # mock api,不依赖真实后端
```

直接跑本机调试栈(白名单要包含你访问的 Host):

```bash
MS_API_BASE_URL=http://192.168.110.221:8090 \
MS_MCP_ENTRY_ALLOWLIST='192.168.110.221:8090=http,127.0.0.1:8000=http,localhost:8000=http' \
MS_MCP_INTERNAL_BASE_URL=http://192.168.110.221:8090 \
uv run python -m ms_mcp                   # 监听 0.0.0.0:8000
```

MCP 客户端地址 `http://127.0.0.1:8000/mcp`,Header `Authorization: Bearer mspat_...`
(本机调试时签出的 MinIO URL 指向开发机自身,取字节/下载不可用属预期)。

容器构建(独立镜像,不走 api 的 build):

```bash
cd material-storage/api
docker compose build ms-mcp
docker compose up -d ms-mcp
docker compose exec ms-mcp python -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/healthz').read())"
```

## dev 覆盖片段(目标机手工维护,不入库)

`docker-compose.override.yml` 只覆盖差异,**不要重复定义整个 service**(否则 prod 的
`up ms-mcp` 找不到服务)。注意 service 下的 `networks` **不接受 `name`**,网络重映射
写在顶层:

```yaml
# /home/msdev/ms/api/docker-compose.override.yml(dev)
services:
  ms-mcp:
    container_name: ms-mcp-dev
    environment:
      # dev 的 api 服务名/容器名以目标机实测为准(docker network inspect / getent hosts)
      MS_API_BASE_URL: http://ms-api-dev:8000
      # dev 裁剪版(与服务器上现有 override 一致,3 条,均 :8090):
      # 不得放行 prod Host;dev 入口只有内网 8090 与本机 8090 两种拼法。
      MS_MCP_ENTRY_ALLOWLIST: 192.168.110.221:8090=http,localhost:8090=http,127.0.0.1:8090=http
      MS_MCP_INTERNAL_BASE_URL: http://192.168.110.221:8090
networks:
  poc-net:
    name: msdev-poc_poc_net        # 以 docker network ls 实测为准(changelog/runbook 口径不一)
```

YAML `>-` 会把换行折叠成空格,但逗号后若留空格也能被解析(条目内会 strip);若担心
可写成单行。改完跑 `docker compose config` 核对 `ms-mcp.environment` 与网络名。

## 部署 / 重启影响面

1. nginx 侧已在 `poc/minio/nginx/default.conf` 加 `location ^~ /mcp`(**变量 upstream**:
   ms-mcp 未起时 nginx 也能正常启动)。改 conf 后:
   `docker exec poc-nginx nginx -t && docker exec poc-nginx nginx -s reload`
   (dev 容器名 `poc-nginx-dev`)。
2. ms-mcp 是独立镜像:`docker compose restart ms-mcp` **不会**重建镜像;更新代码/依赖用
   `docker compose up -d --build ms-mcp`。
3. **重启 ms-mcp = 断所有 MCP 会话**(绑定表与 SDK 会话都在内存,单副本);Web/App 无感。
   运维择时,客户端重连会自动重新 initialize。
4. 回滚:先在 `/admin/mcp-settings` 关通道 → rsync 回旧 commit → 重启 api/worker →
   `docker rm -f ms-mcp`(dev:`ms-mcp-dev`)→ nginx 回滚后 `nginx -t && nginx -s reload`。
   `docker compose rm` 在 service 已从 compose 文件移除后会报 no such service。
5. 会话数上限 200(编译常量)与 TTL 到顶时淘汰最久未用绑定;若 SDK 侧到顶会对 initialize
   返回 503 —— 属预期保护(单副本容量上限)。

## 安全边界

- 只加入 `poc-net`、**不 publish 宿主端口**:只能经 nginx 到达,否则网内直连可伪造 XFF。
- 不读 `.env` / 不挂 DB/Redis/MinIO 凭证(架构红线,部署时检查 `docker compose config`)。
- 非 root 运行;日志脱敏;token 只在内存,不落盘。
- 本服务**不是** OAuth resource server:没有 `/.well-known/*` 元数据,只支持客户端静态配置
  `Authorization: Bearer mspat_...`(OAuth 托管客户端列二期)。
