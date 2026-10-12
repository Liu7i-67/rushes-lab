# 预签名 URL 按请求来源 Host 动态签发（dynamic presign host）

- 日期：2026-10-12
- 状态：已定稿（PM）
- 分支/worktree：`feat/dynamic-presign-host` @ `E:\qbb\github_not_me\rushes-lab-dynamic-presign-host`

## 背景与目标

- 现状：`PresignService.__init__` 用 `settings.minio_endpoint_public` / `minio_thumbnail_endpoint_public` 静态构造 `_s3_signer` / `_s3_thumb_signer`，所有浏览器侧预签名 URL（缩略图 / live-preview / 下载 / 上传分片 / 公开分享下载）的 host 固定为 `MINIO_ENDPOINT_PUBLIC`。
- 问题：多入口部署（新 `https://bucket.taoxiplan.com`（跳板机 TLS→隧道→hh2 nginx）/ 内网 `http://192.168.110.221` / 外网 `http://47.108.196.211:18080`）下，https 入口的页面拿到 `http://47.108.196.211:18080/...` 预签名 URL，被浏览器按**混合内容**拦截，资源预览/上传全部失败（prod 已实锤：download-link 返回 `http://47.108.196.211:18080/ms-dev/...`）。
- 目标：请求上下文内，预签名 URL 的 `scheme://host[:port]` 跟随浏览器实际访问入口；各入口（https 域名 / 内网 IP / 外网 IP:端口）预览、上传原生可用。**.env 零改动**（之前讨论的"切域名 .env"方案作废）。

## 功能点明细（逐条可验收）

### A. 后端（api/app）

1. `PresignService` 4 个签名方法（`sign_get_url` / `sign_put_url` / `sign_thumbnail_url` / `sign_part_url`）新增可选参数 `request_base: str | None = None`（`f"{scheme}://{host}"` 形态）；传入时用该 endpoint 构造/复用**缓存的 signer client** 签名；不传时用现有静态 `_s3_signer` / `_s3_thumb_signer`（零行为变化）。
2. signer client 按 endpoint 缓存（dict，首见创建；入口数量有限无需淘汰，注释说明）。
3. 新增统一 helper `request_base_from(request: Request) -> str | None`（建议放 `services/presign.py`）：
   - `host = request.headers.get("host")`（**含端口**：`192.168.110.221`、`bucket.taoxiplan.com`、`47.108.196.211:18080`、`[::1]:8080` 均合法）；
   - `scheme = request.url.scheme`（uvicorn `--proxy-headers --forwarded-allow-ips '*'` 已启用，nginx 透传 X-Forwarded-Proto 后 https 入口=https）；
   - Host 合法性校验：非空、长度 ≤253、字符集 `^[A-Za-z0-9.\-:\[\]]+$`；不合法 → 返回 `None`（回落静态）；
   - 返回 `f"{scheme}://{host}"`。
4. 5 处调用点接入（handler 增加 `request: Request` 参数，调用处传 `request_base=request_base_from(request)`）：
   - `app/routers/assets.py:112` sign_part_url（上传分片 URL）
   - `app/routers/assets.py:1027` sign_get_url（download-link）
   - `app/routers/assets.py:1068` sign_thumbnail_url（thumbnail-url）
   - `app/routers/assets.py:1240` sign_thumbnail_url（live-preview-url）
   - `app/routers/share.py:201` sign_get_url（公开分享页直链下载）
5. `sign_thumbnail_url` 的动态 endpoint 同样整体替换 host（缩略图与原片同 vhost，nginx 按 `/ms-thumbs/` 路径分流，host 同源）；`MINIO_THUMBNAIL_ENDPOINT_PUBLIC` 仅作无请求上下文的回落。
6. 内部 client（`_s3_internal` / `_s3_thumb_internal` / `_sts`）与全部内部操作（create/complete/abort/head/list/delete/copy/sts）**不动**。
7. `presign.py` 模块 docstring 补一段动态签发说明（多入口/混合内容背景）。

### B. nginx（material-storage/poc/minio/nginx/default.conf，仓库文件）

前置事实：hh2 nginx `/api/v1/` location 现写死 `X-Forwarded-Proto $scheme`（会把跳板机传来的 https 覆写为 http）与 `Host $host`（会剥掉非标准端口，:18080 入口签错 host → MinIO 403）。需改：

1. http 级新增 map：上游带 X-Forwarded-Proto 则透传，缺省回落 `$scheme`：
   ```nginx
   map $http_x_forwarded_proto $xfp { default $http_x_forwarded_proto; '' $scheme; }
   ```
2. `/api/v1/` location：`proxy_set_header X-Forwarded-Proto $xfp;`、`proxy_set_header Host $http_host;`（其余 header 不动）。
3. 其余 proxy 到 ms-api 的 location（`/ms-static/`、`/ms-healthz`）同步改 Host/XFP 为同款（对静态无实际影响，保持一致性；**不碰** MinIO/Console/presigner 的 location）。
4. 443 镜像问题不存在（2026-10-10 起 TLS 在跳板机终结，hh2 只有 80 vhost；跳板机 nginx 已设 `X-Forwarded-Proto https` + `Host $http_host`，无需改）。

## 数据库修改方案

不涉及。

## 接口定义

不涉及新接口/入参出参变更（返回体结构不变，仅其中 URL 的 scheme/host 跟随入口变化）。

## 前端改动点

不涉及。

## 测试功能点

单元（离线，参照 `tests/test_download_attachment.py` 范式：`mk_settings` + `RecordingSigner` 替身）：

1. 传 `request_base` 时签名 client 的 endpoint 正确（URL 前缀断言或 client 缓存断言）；
2. 同一 `request_base` 二次调用复用缓存 client（创建计数/id 断言）；不同 request_base 各自缓存；
3. 不传 `request_base`：与现状完全一致（静态 signer）；
4. `request_base_from`：合法 host 三形态（裸域名 / IP:端口 / IPv6 `[::1]:8080`）→ 正确返回；Host 缺失 / 超长 / 非法字符（`<script>`、空格）→ `None`；`X-Forwarded-Proto: https` → scheme=https（TestClient/starlette Request 构造）；
5. share.py 直链路径传 request_base（router 单元级，stub 依赖）。

容器级（隔离栈 feat-ms，API 直连模拟 nginx 转发头）：带 `Host: bucket.taoxiplan.com` + `X-Forwarded-Proto: https` 请求 download-link / thumbnail-url，断言返回 URL 以 `https://bucket.taoxiplan.com/` 开头；带 `Host: 47.108.196.211:18080`（无 XFP）→ `http://47.108.196.211:18080/` 开头。

回归：`tests/test_download_attachment.py` 全绿（attachment 语义与动态正交）；隔离栈全量不劣化。

## 模糊点与决策记录

- **D1 不加运维开关**：传 `request_base` 才动态，不传即旧行为；调用点全量接入后语义=「跟随入口」，回退=代码回滚。
- **D2 sign_put_url 现无调用方仍加同款参数**：4 个签名方法 API 保持一致。
- **D3 Host 校验失败/缺 Host 回落静态不报错**：可用性优先；防伪造仅影响自身 URL 形态，无提权面（对象访问仍需过权限 + MinIO 签名校验）。
- **D4 prod/dev 的 .env 不改**：动态生效后无需再切域名；`MINIO_ENDPOINT_PUBLIC`/`MINIO_THUMBNAIL_ENDPOINT_PUBLIC` 保留为回落值。
- **D5 web_app_base_url（share/request_links 链接基址）同病不同修**：内网 IP 基址外部不可达是独立问题，遗留另立周期。

## 部署注意（PM 汇总用）

- 纯后端 + nginx conf 改动，无 migration：代码 rsync → `docker compose restart ms-api ms-worker` → nginx conf 为 bind mount，需 `docker exec poc-nginx(-dev) nginx -t && nginx -s reload`（或随容器 restart）。
- dev 验证双入口（内网 :8090 / 外网 :8080）+ 需真机回归 https 域名入口（部署 prod 后）。
