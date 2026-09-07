# 公网兜底入口方案 —— 经阿里云反向隧道访问内网生产

> 状态:**dev 试点已上线并验收**(2026-09-04:阿里云 8080 → hh2 dev 8090,外网全链路通过 ——
> 登录/搜索/缩略图 200/原片 206,内网 dev+prod 回归 200,隧道吞吐 ≈75Mbps)。
> 当前 dev 用的是".env 切公网 host"的**临时形态**(副作用:内网 dev 用户图片绕公网;公网登录限流共享
> 127.0.0.1 桶)—— 待阶段 3(请求驱动签名)/ 阶段 4(真实 IP)上线后根治。
> **HTTPS 已裁决不做(2026-09-04 用户决策:系统定位内部人员使用)**,域名/ICP 备案/Caddy 相应取消,
> 替代控制与遗留暴露见 §4.5。现状盘点为 2026-09-04 实机探测结果;落地细则为操作级步骤。
> 定位:内网直连(192.168.110.221)仍是**主路径且行为完全不变**;本文档设计的公网入口只是
> 给"无法接入内网的人"用的**兼容通道**。与 jump-kit(SSH 运维跳板)是同一隧道的两种用途,互不替代。

---

## 1. 背景与目标

**痛点**:内网服务器(hh2)必须连接指定网线才能访问。远程用户目前要看 Web 只有两条笨路:

1. `ssh file_service_web`(DynamicForward 11080)+ 浏览器 SwitchyOmega 代理规则;或
2. `ssh -L 18080` 本地端口转发。

两者都要求:**每人持有服务器私钥 + 保持一条 SSH 会话 + 配置浏览器代理** —— 无法交给普通业务用户。

**目标**:

| 目标 | 说明 |
| --- | --- |
| 内网主路径零变化 | 内网用户继续 `http://192.168.110.221` 直连,配置、流量、行为与今天一致 |
| 公网兜底入口 | 浏览器打开一个公网地址即可用全部功能(登录/浏览/上传/下载/分享),无需任何客户端配置 |
| 不拆前端 | 前端不单独部署到云端或用户本地(理由见 §4.2) |

**非目标**:dev 环境(8090)不做公网化;不引入新组件栈(frp / VPN)作为第一版。

---

## 2. 现状盘点(2026-09-04 实机探测)

### 2.1 链路与机器

| 组件 | 事实 |
| --- | --- |
| 内网生产 hh2 | `192.168.110.221`,prod nginx 监听 **:80**,dev 监听 **:8090**;251G 内存,负载正常 |
| 反向隧道 | hh2 上用户级 systemd 服务 `jump-tunnel`(linger 保活),`ssh -N -R 12222:127.0.0.1:22 tunnel@47.108.119.221`,探测时 active 运行近 4h,断线自动重连 |
| 阿里云跳板 | `47.108.119.221`(root 登录,`scripts/env/xys.pem`),2核 / 1.7G 内存,负载 ≈0;12222 绑定在 127.0.0.1;**8080 空闲**;`sshd_config` 的 `GatewayPorts` 为默认值(no,注释状态) |
| 部署通道 | `deploy_lan.sh dev\|prod` 走 ssh 别名 `hh2`(即经隧道),已带抖动重试 |
| 运维跳板 | `jump-kit` 部署的 12222 SSH 通道,本次方案**原样保留不动** |

### 2.2 关键耦合(决定方案形态的三个事实)

1. **nginx :80 是全站唯一入口**(`poc/minio/nginx/default.conf`):业务 SPA(`/ms-static/`)、业务 API(`/api/v1/`)、
   原片直传直下(`/ms-dev/`)、缩略图(`/ms-thumbs/`)全部同源挂在 80 下。
   → **穿透一个端口 = 全功能可用**,不存在"前端单独部署"的必要。
2. **presigned URL 的 host 写死在后端配置**:`presign.py` 启动时按 `MINIO_ENDPOINT_PUBLIC` /
   `MINIO_THUMBNAIL_ENDPOINT_PUBLIC`(api/.env)签 URL,host 必须等于浏览器实际访问的 host
   (S3v4 签名含 host,nginx 已用 `$http_host` 透传,P-10 坑有注释)。→ 双入口下不能写死(见 §4.3)。
3. **分享/申请/通知链接的 base 也写死**:`web_app_base_url`(settings)被 `share.py:235` /
   `request_links.py:76` / `notifications.py:373` 使用,`main.py:107` 还从它 derive CORS origin。
   → 属于"创建时固定"的链接,处理方式与 presigned 不同(见 §5 阶段 6)。

### 2.3 安全现状(与公网化直接相关)

- 登录:本地账号密码,argon2id + Redis 双维限流(per IP + per username,5 次锁 15 分钟);
- 会话:cookie `ms_session`(HS256 JWT),同源发布,禁用用户立即下线;
- 敏感数据:医美客户照片,敏感目录受邀制(OpenFGA enforce),缩略图 1024px 模糊免 enforce;
- 同机还有 MinIO Console(占 `/console` `/api/` `/ws/` `/static/` 等路径)——**公网化时必须在边缘挡掉**。

---

## 3. 方案总览

```
 内网用户(主路径,不变)              公网用户(兜底,新增)
        │                                  │
        ▼                                  ▼
 http://192.168.110.221          https://<域名>(阿里云 Caddy :443)
        │                                  │ 同机回源 127.0.0.1:8080
        │                                  ▼
        │                        sshd GatewayPorts 绑定 :8080
        │                                  │  ← hh2 主动出站的反向隧道(复用现有 jump-tunnel)
        │                                  ▼
        └──────────────► hh2 nginx :80 ◄───┘
                            │ 同一套容器(ms-api / MinIO / PG …)
```

一句话:**hh2 继续只出不进;阿里云只做一个"公网门牌";两边访问的是同一个后端,靠"签名 host 跟随访问入口"保证互不串味。**

---

## 4. 设计决策与理由(为什么这样做)

### 4.1 为什么只能是"hh2 主动连出的反向隧道"

hh2 在内网 NAT 之后,公网无法主动连入;探测已证明 hh2 **出站**到阿里云 :22 可用且稳定(现有隧道即证据)。
所以数据通道只能是 hh2 发起的持久连接,外部流量经它"带回来"。这是拓扑约束,不是选型偏好。

### 4.2 为什么前端不单独部署在云端/本地

- 前端由后端**同源发布**(`pnpm build` → `api/app/static/web/` → mount 在 `/static/web` → nginx rewrite
  为 `/ms-static/web/`),登录 cookie、presigned 路径(`/ms-dev/` `/ms-thumbs/`)全部与同一个 origin 耦合;
- 拆开部署 = 引入 CORS、cookie SameSite、presigned 跨源签名一整串坑,还要额外维护一份前端发布流程,
  而收益是零 —— 反正数据都得回 hh2 拿。
- 结论:**穿透一个端口就是全功能**,前端不动是成本最低且风险最小的形态。

### 4.3 为什么 presigned 签名 host 必须改成"请求驱动",而不是改 .env

- 双入口共享同一后端,presigned URL 的 host 却只能签一个。若按最初思路把 `.env` 的
  `MINIO_ENDPOINT_PUBLIC` 改成公网地址,内网用户的缩略图/上传/下载也会被指到公网地址,
  流量"出内网再绕回来" —— **这直接违背"内网主路径不变"的目标**。
- 正确形态:签名 host 跟随**本次请求的入口**(nginx 透传 `X-Forwarded-Host`/`X-Forwarded-Proto`,
  后端按请求取 host 签名,配一份允许列表防伪造)。两边各签各的,互不影响;
- settings 现值保留为 fallback + 灰度开关:允许列表为空时行为与今天完全一致(见 §5 阶段 3)。

### 4.4 为什么第一版继续用 SSH 而不上 frp

- 隧道已部署且带自愈(systemd + linger + 断线重连),增量改动只有"多穿一条端口";
- 已知短板:SSH 隧道会周期性抖动(`deploy_lan.sh` §6.6 已记录)。Web 场景对单次连接抖动的容忍度
  比 rsync/ssh 高(浏览器自己会重试),先用它验证需求;
- 若实测抖动/吞吐影响体验,升级路径是阿里云跑 frps + hh2 跑 frpc(心跳/重连更专业、支持 kcp/quic 传输
  绕开 SSH 的 TCP 套 TCP 劣化、还能做多端口),届时 Caddy/签名 host 等上层改动**全部复用**,只换传输层。

### 4.5 HTTPS:**不做**(2026-09-04 用户决策,系统定位内部人员使用)

- 原设计:传输内容是客户照片 + 账号密码,曾建议 Caddy(:443)+ 域名 + ICP 备案;
- **决策:仅内部人员使用,明文 HTTP 可接受**。替代控制:
  - 建议把安全组 8080 授权对象从 `0.0.0.0/0` 收敛为团队出口 IP —— 让"内部使用"在**网络层**成立,
    这是与 TLS 定位等价的门(是否收紧由维护者定);
  - 密码面由既有 argon2id + 双维限流兜底;
  - 已知遗留暴露:MinIO Console 管理面(`/console` `/login` 等)在公网入口**同样可达**(2026-09-04 实测
    200),仅剩 Console 密码一道门;要屏蔽的话用**纯 HTTP 反代**(不带 TLS)做路径 404 即可,见 §5 阶段 5 附注;
- 若将来对外开放或分享给外部人员,重启 HTTPS 议题,按本节原方案执行(域名 + ICP 备案 + Caddy)。

### 4.6 为什么内网访问完全不受影响(论证)

- 隧道是 hh2 的**出站**连接的增量;nginx 监听、内网路由、防火墙、DNS 全都不动;
- 签名 host 请求驱动后,内网请求拿到的仍是 `192.168.110.221` 签名的 URL;
- 故障单向隔离:阿里云宕机/隧道断/证书过期 → 只影响公网兜底入口,内网照常;
- 既有 SSH 运维通道(12222)与 `deploy_lan.sh` 流程原样保留。

---

## 5. 落地细则

> 执行顺序有依赖:**阶段 1 必须先于阶段 2**(否则隧道扩容后绑定失败 → `ExitOnForwardFailure`
> 让整条隧道 crash-loop,连 SSH 运维通道一起断)。
> 阶段 3(代码)可独立先发 —— 允许列表为空时行为不变,是刻意的灰度设计。

### 阶段 0:前置条件

| 项 | 内容 |
| --- | --- |
| 凭据 | 阿里云 root(`scripts/env/xys.pem`);hh2 msdev(`~/.ssh/rusheslab-server`,即别名 `hh2`) |
| 人工步骤 | 阿里云**控制台**安全组放行端口(阶段 1 表格);带宽计费模式确认(见 §8) |
| 待业务确认 | 素材允许经公网传输(HTTPS 加密前提下)—— 见 §9 决策点 |

### 阶段 1:阿里云侧(先做)

1. `sshd_config` 追加一行并 reload(**对现有连接无影响**,不会掉线):

   ```bash
   ssh aliyun-jump
   echo 'GatewayPorts clientspecified' >> /etc/ssh/sshd_config
   sshd -t && systemctl reload sshd
   ```

   为什么是 `clientspecified` 而不是 `yes`:只允许客户端**显式**要求绑公网地址的转发绑公网,
   现有 `-R 12222:127.0.0.1:22`(未写绑定地址)仍只绑 loopback,行为不变。

2. 控制台安全组放行(人工):

   | 时期 | 端口 | 来源限制 |
   | --- | --- | --- |
   | 过渡(HTTP 裸奔期) | 8080/TCP | 建议先只放团队出口 IP |
   | HTTPS 上线后 | 80/TCP + 443/TCP 放行 0.0.0.0/0(80 仅用于证书签发跳转);**同时删除 8080/TCP 公网规则(硬性,见阶段 5 第 4 步)** | — |

   > Caddy 回源 `127.0.0.1:8080` 走阿里云**本机回环**,不经过安全组 —— 删除 8080 公网规则不影响回源链路。

### 阶段 2:hh2 隧道扩容(多穿一条 HTTP)

> **2026-09-04 已执行(dev 试点)**:`-R 0.0.0.0:8080:127.0.0.1:8090`,回滚定时器方案按上文实操,
> 端到端验证过(SPA 200 / API 401 / healthz 200),定时器未触发已取消;unit 备份与回滚脚本
> 留在 hh2(`/home/msdev/jump-tunnel.service.bak`、`/home/msdev/tunnel-rollback.sh`)作回滚预案。

⚠ **自锁风险**:本操作是"透过隧道改隧道",改坏 = 远程访问全断(内网同事仍可登 hh2 救援)。
防护:先备份 unit;保留一条已建立的 ssh 会话不动;重启用带回滚兜底的方式做。

**关键认知**:`systemctl --user restart jump-tunnel` 会杀掉隧道进程 —— 我们自己脚下的 `ssh hh2` 会话
就是被它带走的,所以**回滚兜底不能依赖当前会话**,必须用 hh2 本地的定时器在无连接状态下自救:

```bash
ssh hh2    # 走现有 12222 通道

# 1) 备份 + 预埋"90 秒后自动还原"的兜底定时器(hh2 本地执行,隧道断了也会触发)
#    ⚠ transient service 一律用绝对路径:systemd --user 环境的 HOME 不保证齐全,~ 有展不开的风险
export XDG_RUNTIME_DIR=/run/user/$(id -u)
cp /home/msdev/.config/systemd/user/jump-tunnel.service /home/msdev/jump-tunnel.service.bak
systemd-run --user --on-active=90 --unit=tunnel-rollback sh -c \
  'cp /home/msdev/jump-tunnel.service.bak /home/msdev/.config/systemd/user/jump-tunnel.service && \
   export XDG_RUNTIME_DIR=/run/user/$(id -u) && \
   systemctl --user daemon-reload && systemctl --user restart jump-tunnel'
#    unit 名由 --unit 固定为 tunnel-rollback.{service,timer};步骤 5 取消前可先
#    systemctl --user list-timers 双确认

# 2) 编辑 ExecStart:在 -R 12222:127.0.0.1:22 之后追加(其余参数原样保留):
#      -R 0.0.0.0:8080:127.0.0.1:80

# 3) 应用改动(本会话会随隧道重启掉线,属预期)
systemctl --user daemon-reload && systemctl --user restart jump-tunnel
```

```bash
# 4) 从本机(或新开的 ssh hh2)验证;90 秒内完成即可
sleep 8 && ssh aliyun-jump "ss -tlnp | grep ':8080'"   # 期望:sshd 监听 *:8080

# 5) 确认成功后取消兜底定时器(否则 90 秒一到会被还原回旧配置!)
ssh hh2 'export XDG_RUNTIME_DIR=/run/user/$(id -u); systemctl --user stop tunnel-rollback.timer tunnel-rollback.service 2>/dev/null; systemctl --user list-timers'
```

若步骤 4 失败(8080 没起来):什么都不用做,90 秒后兜底定时器自动还原旧配置并重启,隧道恢复,
事后从 `journalctl --user -u jump-tunnel` 查失败原因(最常见:阶段 1 的 GatewayPorts 没生效)。

**go / no-go:干线吞吐实测(先于阶段 3-6 的投入)**

SSH 隧道是 **TCP 套 TCP**:外层 SSH 连接与内层 HTTP 流量各自拥塞控制,高丢包/高延迟链路上吞吐劣化明显
(TCP-over-TCP meltdown)。医美原片几十 MB 一张,这是本方案最可能翻车的点,所以把实测提前为闸门:

```bash
# hh2 上造 100MB 文件,从本机经隧道拉回(与将来的 HTTP 通道共享同一条 SSH 干线,代表性足够)
ssh hh2 'dd if=/dev/urandom of=/tmp/100m.bin bs=1M count=100'
time scp hh2:/tmp/100m.bin /tmp/ && ssh hh2 'rm -f /tmp/100m.bin'
```

多测几次取中位数,折算 Mbps:**低于 ~5 Mbps(约 625 KB/s,阈值按业务容忍度调)→ 停,先按 §4.4 切 frp
复测,通过再回来继续**;可接受 → 记录基准值,阶段 5 上线后用真实 HTTPS 下载复测对比(传输层换 frp 后基准重测)。

**验证**:

```bash
curl -I http://47.108.119.221:8080/ms-static/web/     # 期望 200(SPA index)
curl -I http://47.108.119.221:8080/api/v1/auth/me     # 期望 401(端点存在)
```

**回滚**:还原 `~/jump-tunnel.service.bak` → daemon-reload → restart;阿里云侧 `GatewayPorts`
行可保留(无副作用),安全组规则删掉即可。

### 阶段 3:签名 host 请求驱动(代码,随 deploy_lan.sh 发布)

| # | 改动 | 位置 |
| --- | --- | --- |
| 1 | nginx `/api/v1/` location 增加 `X-Forwarded-Host` 透传 + proto 用 header 的 map(HTTPS 阶段必需,否则 https 页面里混入 http 的缩略图 URL 会被浏览器按 mixed content 拦掉) | `poc/minio/nginx/default.conf` |

   ```nginx
   # http 块:转发头只信任"隧道回源"这个唯一合法来源(nginx 眼里的直连源 127.0.0.1)。
   # ⚠ 必须用 $realip_remote_addr 而不是 $remote_addr:阶段 4 的 real_ip 会把 $remote_addr
   #   改写成真实客户端 IP,隧道请求在它眼里是公网 IP —— 用 $remote_addr 当闸门会把合法流量一起拒掉
   geo $realip_remote_addr $ms_via_tunnel {
       127.0.0.1 1;
       default   0;
   }
   map $http_x_forwarded_proto $ms_fwd_hdr {
       default "";
       "https" "https";
       "http"  "http";
   }
   map "$ms_via_tunnel:$ms_fwd_hdr" $ms_fwd_proto {
       default   $scheme;   # 非隧道来源一律用本机 scheme:内网直连伪造 X-Forwarded-* 无效
       "1:https" "https";
       "1:http"  "http";
   }
   # location ^~ /api/v1/ 内:
   proxy_set_header X-Forwarded-Host $http_host;     # $host 会剥端口,:8080 下签名必错
   proxy_set_header X-Forwarded-Proto $ms_fwd_proto;
   ```

   纵深防御说明:host/proto 伪造的后果本已被后端允许列表兜底(最坏 = 伪造者给自己签出公网 URL,
   自伤自了,伤不到他人);这道 nginx 层闸门把"来源不对 → 转发头无效"变成确定性规则,不依赖上层判断正确。

| 2 | settings 新增允许列表,如 `allowed_public_bases: str = ""`(逗号分隔,空 = 关闭新逻辑) | `api/app/settings.py` |
| 3 | deps 新增 helper:取 `X-Forwarded-Host` + `X-Forwarded-Proto` 拼出 base,**命中允许列表才采用**,否则回落 `minio_endpoint_public` 现值 | `api/app/deps.py` |
| 4 | `PresignService.sign_get_url / sign_put_url / sign_part_url / sign_thumbnail_url` 增加可选 `public_base` 参数;signer boto3 client 按 base 缓存(不能每次请求建 client) | `api/app/services/presign.py` |
| 5 | 5 个调用点把 helper 结果传进去 | `routers/assets.py:103,599,637,809`、`routers/share.py:198` |

**实现注意**:① 允许列表比较前先规范化 —— host 统一小写、按 scheme 剥默认端口,否则
`ms.example.com:443` vs `https://ms.example.com` 这类错配是必然事故;② 阶段 3 开发时顺手确认
`share.py:235` 的 base 拼接时机(创建时固化还是解析时拼),提前关闭阶段 6 标注的未验证项,
别拖到最后才发现分享链接公网打不开。

**灰度与回滚**:部署后允许列表为空 → 一切照旧;之后给 prod 配置
`ALLOWED_PUBLIC_BASES=http://47.108.119.221:8080`(经 `.env` + `--force-recreate ms-api`)即点亮公网入口;
删掉该值即回滚。内网侧**无任何配置变化**。

**明确不改**:`.env` 里 `MINIO_ENDPOINT_PUBLIC` / `MINIO_THUMBNAIL_ENDPOINT_PUBLIC` 保持内网现值(fallback 用);
nginx 的 `$http_host` 透传(MinIO 签名校验侧)已就绪,不动。

### 阶段 4:真实 IP 与登录限流(公网入口上线前必须做)

问题:经隧道进来的请求在 hh2 nginx 眼里源 IP 全是 `127.0.0.1` → per-IP 登录限流把**所有公网用户塞进同一个桶**,
任何人输错 5 次密码 = 全体公网用户锁 15 分钟;审计日志也丢真实 IP。

```nginx
# hh2 nginx server/http 块:只信任隧道回源路径带来的 XFF
set_real_ip_from 127.0.0.1;
real_ip_header X-Forwarded-For;
```

Caddy 反代默认会带 `X-Forwarded-For`;上线后用一个公网登录(成功+失败各一次)核对 audit/日志里的 IP 是否为真实出口。
只影响隧道来源连接,内网直连的 `$remote_addr` 语义不变。

### 阶段 5:HTTPS 与边缘收敛(**暂缓:2026-09-04 决策不做 HTTPS**,本节留档备用)

> 只取本节"路径屏蔽"思路的话,可以不引 Caddy/TLS:在阿里云放一个**纯 HTTP** nginx/Caddy 反代
> (:8080 收口 → 反代监听公网端口 → 回源隧道),对 Console 路径 404。以下证书/备案细节仅将来对外时启用。

1. 域名解析到 `47.108.119.221`;**ICP 备案**(阿里云大陆机开 80/443 的硬要求,提前办,周期以周计)。
   未备案过渡期:裸 IP `:8080` HTTP + 安全组来源白名单,仅限小范围内测。
2. 阿里云装 Caddy(静态二进制即可),Caddyfile(原则:**业务前缀放行,Console 相关一律 404**):

   ```caddyfile
   ms.example.com {
       # MinIO Console 面板与其静态资源
       @console path /console /console/* /login /ws/* /static/* /styles/* /Loader.svg /manifest.json
       # /api/* 但放行业务 API /api/v1/*(两个条件取交集)
       @console_api {
           path /api/*
           not path /api/v1/*
       }
       respond @console 404
       respond @console_api 404
       reverse_proxy 127.0.0.1:8080 {
           # 防御性显式声明:Caddy v2 默认透传原始 Host(与 nginx 相反),写明不依赖默认行为。
           # ⚠ header_up 只能写在 reverse_proxy 块内 —— 放 site 层是无效语法,站点起不来
           header_up Host {http.request.host}
           header_up X-Forwarded-Proto {http.request.scheme}
       }
   }
   ```

   根路径 `/` 放行(带 `Authorization: AWS4-…` 的请求是桌面 S3 客户端走 STS 临时凭据的入口,
   保留这个远程能力;无认证访问会由 hh2 nginx 302 到业务 SPA)。写法以 Caddy 实测为准,原则不变。

   **Host 透传为什么值得盯**:hh2 nginx 的 `X-Forwarded-Host` 取自 `$http_host`(收到的原始 Host 头),
   这一跳若把 Host 换成上游地址,签名 base 会变成 `127.0.0.1:8080`,全站缩略图/上传/下载 403。
   上线验证:临时给 hh2 nginx 的 `/api/v1/` 加回显响应头(或看 ms-api access log 的 Host),
   确认收到的是 `ms.example.com` 而非 `127.0.0.1:8080`。

3. 允许列表追加 https 域名:`ALLOWED_PUBLIC_BASES=http://47.108.119.221:8080,https://ms.example.com`。
4. **8080 收口(硬性)**:HTTPS 验证通过后**立即删除安全组 8080/TCP 公网入方向规则** ——
   只要它还开着,就存在"绕过 TLS + 绕过 Console 边缘拦截"的明文旁路(路径 404 只配在 Caddy 上,
   `:8080` 直达 hh2 nginx,Console 管理面原样暴露)。Caddy 回源走本机回环不经安全组,删除不影响链路。
   验证:外网 `curl -m 5 http://47.108.119.221:8080` 必须超时。
5. 可观测性:Caddy 开 access log;日常盯两类信号 —— Caddy 侧 404 路径分布(扫描/误配探测),
   后端登录失败日志里的真实 IP 是否正确(验证阶段 4 真实生效)。

### 阶段 6:分享/申请/通知链接的 base(决策点,可最后做)

`web_app_base_url` 是"创建时写进链接"的固定值。分享链接的受众本来就是**没有内网的人**,建议最终指向
公网 HTTPS 入口;代价是内网用户点开分享/申请链接会走一次公网绕行(可接受,后续可做双值)。
注意 `main.py` 的 CORS origin 从它 derive —— 两个入口都是同源,不受影响;改值走 `.env` + `--force-recreate`。
**未验证项**:存量分享链接的 base 是创建时固化还是解析时拼接(`share.py:235` 的调用时机),改值前先确认存量链接行为。

---

## 6. 验证清单(全绿才算落地)

**内网回归(主路径不变)**:登录 → 列表缩略图显示 → 任取一张原片下载 → 上传一个新文件 → 确认
浏览器 network 里缩略图/上传/下载 URL 的 host 仍是 `192.168.110.221`(阶段 3 的核心验收)。

**公网功能(兜底入口)**:外网环境浏览器打开入口 → 登录 → 缩略图 → 下载原片 → multipart 大文件上传
→ 敏感目录无授权不可见;登录失败 5 次确认锁定只作用于该真实 IP(阶段 4 验收);分享链接可打开(阶段 6 后);
HTTPS 后外网探 `:8080` 必须超时(阶段 5 收口验证);大文件 HTTPS 下载吞吐复测并与阶段 2 的 scp 基准对比。

**故障演练**:

| 演练 | 期望 |
| --- | --- |
| hh2 重启 | linger 拉起 jump-tunnel,两个转发(12222/8080)自愈 |
| hh2 断网 30s 再恢复 | 隧道自动重连(现服务已带 `ServerAliveInterval=30` + Restart=always) |
| 阿里云重启 | sshd 配置持久;hh2 侧重连回建隧道 |
| `deploy_lan.sh prod` | 不受影响(走 12222 通道) |

---

## 7. 回滚总表

| 层 | 回滚动作 | 影响 |
| --- | --- | --- |
| 允许列表 | `.env` 删 `ALLOWED_PUBLIC_BASES` + force-recreate | 公网入口立即失效(签名回落内网 host),内网无感 |
| 隧道 | 还原 unit 备份 → daemon-reload → restart | 8080 转发消失,12222 保留 |
| 阿里云 sshd | 删 `GatewayPorts` 行 + reload | 远端转发回到 loopback-only |
| Caddy | 停服务/删 Caddyfile | HTTPS 入口下线 |
| 安全组 | 控制台删规则 | 公网彻底不可达(最外层闸门) |

---

## 8. 风险与限制

| 风险 | 说明 | 对策 |
| --- | --- | --- |
| **带宽是体验上限** | 所有公网流量过两道瓶颈:hh2 上行出口 + 阿里云公网带宽(轻量机常见 3~5Mbps 固定带宽)。缩略图列表可接受,原片批量下载会慢;且 SSH 隧道是 **TCP 套 TCP**,高丢包/高延迟链路上吞吐劣化加剧 | 阶段 2 即做 scp 100MB go/no-go 实测,不达标先切 frp 再继续(§4.4);按流量计费则评估费用;重下载场景引导走内网 |
| SSH 隧道抖动 | 已知周期性抖动(§6.6),Web 表现为偶发卡顿/失败重试 | 先上线观察;体验不达标升级 frp(§4.4,上层改动全复用) |
| 攻击面扩大 | 登录接口 + MinIO Console 管理面(`/console` `/login`)都暴露公网(实测 200) | 定位内部使用:建议安全组收敛授权对象为团队出口 IP;Console 屏蔽可用纯 HTTP 反代路径 404(§4.5);argon2 + 双维限流既有 |
| 合规 | 客户照片走公网明文通道 | 已定内部使用(2026-09-04 用户决策);若对外分享需重启合规评估 + HTTPS(§4.5) |
| 单点 | 阿里云机宕机 = 兜底入口不可用 | 可接受(主路径在内网);关键在于**不影响内网**(已由设计保证) |

---

## 9. 待确认决策点

1. ~~合规确认~~ **已定(2026-09-04):仅内部人员使用,明文 HTTP 通道可接受**;若将来对外开放或分享给
   外部人员,重启合规评估 + HTTPS(§4.5)。
2. ~~域名与备案~~ **已关闭**:不做 HTTPS,不需要域名与 ICP 备案。
3. **dev 环境**:**已定,dev 先行试点**(2026-09-04 隧道侧上线);prod 待 dev 外网验收 + 阶段 3 代码上线后再跟进,避免先用"改 .env"的临时形态碰生产。
   **prod 复制的端口账(2026-09-04 核过)**:只需新开 **1 个**公网端口 —— 安全组放行 `18080/TCP`(对应 hh2 prod :80,
   沿用既有 18080=prod 的别名惯例),隧道 unit 再加一条 `-R 0.0.0.0:18080:127.0.0.1:80`(同一 SSH 连接承载,
   操作同阶段 2 的备份+回滚定时器流程);**无需任何其他端口** —— hh2 保持只出不进(nginx 走 127.0.0.1 回环),
   MinIO 上传下载/缩略图/STS 全在 nginx 80 同源之后,运维 12222 不动;Console 专属端口(6102/6202 等)永远不开。
   **安全组 18080 已放行(2026-09-04);prod 已于 2026-09-07 实施上线(代码推进 662754f + 步骤 2B 形态),
   操作细节与实施备注见 [prod-public-entry-runbook.md](./prod-public-entry-runbook.md) 顶部状态区。**
4. **分享链接 base**(阶段 6):`web_app_base_url` 切公网入口的时机,及存量链接行为确认。
5. **阿里云带宽计费模式**:固定带宽多大 / 按流量付费 —— 决定重下载场景的现实体验与成本。

---

## 10. 与现有资产的关系

| 资产 | 是否变动 |
| --- | --- |
| `scripts/jump-kit`(12222 SSH 运维跳板) | 不动,原样保留 |
| `deploy_lan.sh` / ssh 别名 `hh2` | 不动 |
| ssh 别名 `file_service_web`(SOCKS/端口转发) | 保留过渡,公网入口稳定后可归档 |
| prod `.env` | 只**新增** `ALLOWED_PUBLIC_BASES`(及阶段 6 的 `WEB_APP_BASE_URL`),端点类现值不动 |
| 存储 / 认证 / 权限逻辑 | 零改动 |
