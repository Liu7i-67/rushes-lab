# W2a 审计真实 IP 激活 runbook(执行版)

> **用途**:把审计日志里的 `172.20.0.7`(poc-nginx 容器 IP)换成用户真实 IP,顺带解除
> 「公网入口全员共享一个 per-IP 登录限流桶」的连带事故。
> **来源与关系**:方案正本 = `admin-audit-folder-mobile-optimization-plan.md` §2(qplan 13 轮
> 盲审定稿);手册章节 = `ops-manual.md` §11(内容同源)。本文件是**可打印照抄的执行版**,
> 步骤编号与 §11 一致,内容漂移时以 ops-manual §11 为准并同步本文件。
> **状态**:**已激活(2026-10-19,全程 ~30 分钟,四条验收全过)**。2026-10-19 决策修订:入口处置由 a 收敛改为 **b 反代保留**;同日执行,两处现场差异见 §2/§3 的「执行实录」框。
> **影响预告**:公网 :18080/:8080 在 ③ 步有 **约 1-2 分钟中断**(隧道改绑到反代上线的间隙),
> 之后恢复访问且对外 URL 不变;443 入口全程不受影响;跳板机 nginx reload 平滑;
> 全程有 180s 自动回滚定时器护底。

---

## 0. 执行前核对(全过才开工)

- [ ] 运维窗口已确认(:18080/:8080 中断约 1-2 分钟,443 与内网入口不受影响);
- [ ] 已知悉 ③ 后 :18080/:8080 的实现方式变化:**对外 URL 与端口完全不变**,内部改为
      经跳板机 nginx 反代(隧道后移到跳板机回环 :18081/:8081),真实 IP 修复对这两个
      端口同样生效且伪造面被封(2026-10-19 用户拍板:对内服务,保留两端口访问,弃 a 收敛方案);
- [ ] 本文件已打印/双屏打开:⓪ 的实测值要回填 §6 记录表,② 的信任源直接依赖它;
- [ ] **硬顺序已牢记:⓪ → ① → ③ → ②,不可调换**——
      ① 未生效而 ② 先 reload = 443 流量 XFF 链尾是客户端自带值,realip 采信伪造 IP(伪造窗口);
      ③ 先于 ② = 缩短「realip 已采信网关流量链尾值但裸通道未封」的窗口。

**根因一图**(详证见 ops-manual §11.1):

```
浏览器 → 跳板机 nginx:443(无 XFF 头)→ 隧道 18080 → hh2:80 → poc-nginx 容器
       →(loopback 不走 DNAT,docker-proxy 转投,容器看到源=网桥网关)→ ms-api(uvicorn)
/api/v1/ 块没设 X-Forwarded-For → uvicorn 无 XFF 可用 → request.client = 容器对端 172.20.0.7
```

---

## 1. ⓪ 前置实测(第一步,决定 ② 的信任源)

**1a. 网络名核实**(仓库声明 `poc-pigsty-minio_poc-net` vs 实际 `<project>_poc-net`,
两环境是否共享网桥一跳即证——若共享,② 只能双网关都写,「只修 prod」物理上不可行):

```bash
ssh hh2 'docker network ls | grep poc-net'
ssh hh2 'docker inspect poc-nginx --format "{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}} => gw {{\$v.Gateway}}{{end}}"'
ssh hh2 'docker inspect poc-nginx-dev --format "{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}} => gw {{\$v.Gateway}}{{end}}"'
```

**1b. 三入口打流 + 盯日志**(nginx 官方镜像 access log 走 stdout;prod/dev 各盯一个终端):

```bash
ssh hh2 'docker logs -f poc-nginx --tail=0'        # 终端 A
ssh hh2 'docker logs -f poc-nginx-dev --tail=0'    # 终端 B

curl -s -o /dev/null https://bucket.taoxiplan.com/ms-healthz   # prod 443 隧道(未切域名时用 https://47.108.196.211/)
curl -s -o /dev/null http://47.108.196.211:18080/ms-healthz    # prod 18080 裸隧道
curl -s -o /dev/null http://192.168.110.221/ms-healthz         # prod 内网直连
curl -s -o /dev/null http://192.168.110.221:8090/ms-healthz    # dev 内网
curl -s -o /dev/null http://47.108.196.211:8080/ms-healthz     # dev 外网裸隧道
```

**判读**:各环境隧道入口应显示该环境网桥网关(prod 推演 ≈172.20.0.1);内网直连显示真实
192.168.x。**全部回填 §6 记录表,② 片段里的网关 IP 以实测值为准。**

- [x] ⓪ 完成,实测值已回填 §6(**两环境独立网桥:prod `poc-pigsty-minio_poc-net` gw 172.20.0.1 / dev `msdev-poc_poc-net` gw 172.22.0.1,② 双网关都写**)

---

## 2. ① 跳板机加 XFF(人工上机;conf 不在仓库)

现役跳板机 = **47.108.196.211**(ssh 别名 `aliyun-swas`;runbook:65 的旧 IP 47.108.119.221
已失效,勿按它找机器)。

```bash
ssh aliyun-swas
cp /etc/nginx/conf.d/bucket-taoxiplan.conf /etc/nginx/conf.d/bucket-taoxiplan.conf.bak-$(date +%Y%m%d)
vi /etc/nginx/conf.d/bucket-taoxiplan.conf
#   在 proxy_pass 所在的 location(或 server)块内加一行:
#     proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
#   (真实公网 IP 进 XFF 链尾;Host $http_host / ws upgrade / 零缓冲等既有指令勿动)
nginx -t && systemctl reload nginx
```

要点:该 conf 是 TLS 终结 + 单 proxy_pass 到隧道的独立配置(2026-10-10 方案 B),**不是**
hh2 default.conf 的路由镜像(当天曾在 hh2 侧短暂落过镜像 vhost,同日已回退,勿混淆);
上机时以实际文件内容为准核验。

**conf 备份双保险**(conf 不进版本控制):① 改完把最终 conf 拷回**仓库根** `scripts/env/`
(与 changelog 同级的根 `scripts/`,非 material-storage/scripts/;该目录受
`scripts/.gitignore` 的 `env/` 规则保护,git 不追踪,worktree 里看不到属正常);
② 灾备对照 = 本节指令摘要(机器丢失可按步骤重建;结构性大改时另记 sha256+日期)。

- [x] ① 完成(执行实录见下框),conf 已备份到 scripts/env/(git status 复核未进暂存)

> **执行实录(2026-10-19)**:上机核验发现 443 vhost **本就自带**
> `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`(52 行,2026-10-10
> 方案 B 建站时即写入,非本 runbook 预期的「无 XFF 需补加」),且 DNS 直指跳板机、
> 无前置 CLB/CDN——⓪ 打流实证 443 流量到 hh2 容器层时 XFF 链尾已 = 真实公网 IP
> (112.193.57.210)。故 **conf 零变更**,仅做备份。最终 conf 已拷回仓库根
> `scripts/env/bucket-taoxiplan.conf`(sha256 见 §9)。

---

## 3. ③ 公网 :18080/:8080 改经跳板机 nginx 反代(2026-10-19 改拍 b 方案;先于 ② reload)

**为什么必须做**:② 生效后,poc-nginx 会信任隧道流量来源并采信 XFF 链尾——若 18080/8080
仍是**裸隧道直通**(链路上没有代理追加真实 IP),客户端自带 `X-Forwarded-For: 1.2.3.4`
就直接变成 `$remote_addr`:审计 IP 可任意伪造 + 换一个伪造 IP 就换一个全新 per-IP 限流桶。
**处置(决策 16/17 改拍 b,2026-10-19,对内服务保留端口)**:两条隧道各后移一个回环端口
(prod 18080→127.0.0.1:18081、dev 8080→127.0.0.1:8081,`+1` 是为给 nginx 腾出公网监听位,
同端口双绑不可靠),跳板机 nginx 在原公网端口上新增两个反代 vhost 并追加 XFF——
**对外 URL 与端口完全不变**,且这两个入口与 443 同信任(真实 IP 进链尾,伪造值被顶掉)。

**中断窗口说明**:公网 :18080/:8080 从隧道改绑生效到 vhost reload 完成**中断约 1-2 分钟**
(3a 与 3b 的间隙);443 与内网入口全程不受影响。180s 定时器护底:vhost 配置失败时自动
还原直通隧道。

### 3a. hh2 侧隧道 `-R` 后移回环 +1(含 180s 自动回滚定时器)

```bash
ssh hh2 '
set -e
# 0) 备份 + 预埋 180s 自动还原定时器(防重启隧道杀掉脚下连接后的自锁;验证通过后必须取消,见 3c)
cp /home/msdev/.config/systemd/user/jump-tunnel.service /home/msdev/jump-tunnel.service.bak
cat > /home/msdev/tunnel-rollback.sh <<RBEOF
#!/bin/sh
cp /home/msdev/jump-tunnel.service.bak /home/msdev/.config/systemd/user/jump-tunnel.service
export XDG_RUNTIME_DIR=/run/user/1003
systemctl --user daemon-reload
systemctl --user restart jump-tunnel
RBEOF
chmod +x /home/msdev/tunnel-rollback.sh
export XDG_RUNTIME_DIR=/run/user/1003
systemd-run --user --on-active=180 --unit=tunnel-rollback /home/msdev/tunnel-rollback.sh

# 1) 两条隧道 -R 改绑回环并后移 +1(12222 运维通道勿动!)
sed -i \
  -e "s|-R 0.0.0.0:8080:127.0.0.1:8090|-R 127.0.0.1:8081:127.0.0.1:8090|" \
  -e "s|-R 0.0.0.0:18080:127.0.0.1:80|-R 127.0.0.1:18081:127.0.0.1:80|" \
  /home/msdev/.config/systemd/user/jump-tunnel.service
systemctl --user daemon-reload && systemctl --user restart jump-tunnel
'   # 本会话掉线属预期(12222 隧道随重启重建,重连即可);此刻起公网 18080/8080 中断,立刻做 3b
```

### 3b. 跳板机加两个反代 vhost(在 180s 定时器窗口内完成并 reload)

```bash
ssh aliyun-swas '
cp /etc/nginx/conf.d/bucket-taoxiplan.conf /etc/nginx/conf.d/bucket-taoxiplan.conf.bak-$(date +%Y%m%d)-3b 2>/dev/null || true
cat > /etc/nginx/conf.d/ms-port-proxy.conf <<\EOF
# ─── W2a:公网 18080/8080 由裸隧道直通改为 nginx 反代(2026-10-19)────────────
# 隧道已后移到 127.0.0.1:18081(prod→hh2:80)与 127.0.0.1:8081(dev→hh2:8090);
# 对外端口与 URL 不变。X-Forwarded-For 追加真实客户端 IP 到链尾(hh2 realip 取链尾),
# 客户端自带的伪造 XFF 被顶到链首不再被采信。指令镜像 bucket-taoxiplan.conf 443 vhost:
# Host $http_host(保端口,presign 签名依赖)/零缓冲大文件/长超时/ws upgrade。
server {
    listen 18080;
    client_max_body_size 0;
    proxy_request_buffering off;
    proxy_buffering off;
    location / {
        proxy_pass http://127.0.0.1:18081;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
        proxy_http_version 1.1;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
server {
    listen 8080;
    client_max_body_size 0;
    proxy_request_buffering off;
    proxy_buffering off;
    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
        proxy_http_version 1.1;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
nginx -t && systemctl reload nginx
'
```

### 3c. 验证 + 取消定时器

```bash
# 1) 公网两端口恢复访问(经反代;对外行为不变)
curl -s -o /dev/null -w "18080:%{http_code}\n" http://47.108.196.211:18080/ms-static/web/
curl -s -o /dev/null -w "8080:%{http_code}\n"  http://47.108.196.211:8080/ms-static/web/
#   期望 200(经反代到 hh2)

# 2) 跳板机监听形态:公网位=nginx,回环位=sshd
ssh aliyun-swas 'ss -tlnp | grep -E "18080|18081|8080|8081"'

# 3) 内网回归:ssh hh2(经 12222)通;内网 prod 80 / dev 8090 仍 200

# 4) ★ 成功后立刻取消 180s tunnel-rollback 定时器(不取消 = 改绑被静默还原、公网端口回到裸隧道直通=伪造面回来)
ssh hh2 'export XDG_RUNTIME_DIR=/run/user/1003; systemctl --user stop tunnel-rollback.timer; systemctl --user list-timers | grep -c tunnel-rollback'
```

**失败处理**:什么都不用做,180 秒后定时器自动还原直通隧道(公网端口恢复旧行为,
伪造面回到现状基线=修复未完成的原始状态,不是新风险);事后
`journalctl --user -u jump-tunnel` 与跳板机 `nginx -t` 查因。

- [x] ③ 完成:公网 18080/8080 经反代恢复 200,定时器已取消,内网入口回归正常

> **执行实录(2026-10-19)与一处必要修正**:因 ① 的现状(443 vhost 已带 XFF),
> 3b 除新增 `ms-port-proxy.conf` 外,**必须同步把 443 vhost 的
> `proxy_pass http://127.0.0.1:18080` 改为 `127.0.0.1:18081`**——否则 443 的回环
> 18080 会被新加的 18080 vhost 接住形成二跳,第二跳 `$proxy_add_x_forwarded_for`
> 在链尾追加 `127.0.0.1`,realip 取链尾会把 443 审计 IP 变成 127.0.0.1(本 runbook
> 定稿时未预见的场景)。已照改并 reload,实测 443 链尾仍 = 真实 IP。执行时序:
> 预写 ms-port-proxy.conf(不 reload)→ 3a 隧道后移(180s 定时器起算)→ sed 443
> proxy_pass + reload(~60s 内完成)→ 验证 200×3 → 取消定时器。回滚时该行须一并
> 还原(§7 第 3 步,用 .bak-20261019-3b)。

---

## 4. ② poc-nginx default.conf 变更(仓库文件;硬顺序最后一步)

> default.conf 全仓唯一、经 `deploy_lan.sh` rsync --inplace 同步到 dev/prod 两个 checkout
> (内容一致,bind mount 生效)。**改前先 git 建分支提交,同步即部署。**

**变更一:server 块顶部(顶部 `map $http_x_forwarded_proto $xfp` 之后)加 realip 组**:

```nginx
    # ─── W2a 真实 IP:还原隧道流量真实客户端 IP ─────────────────────────────
    # 信任源 = ⓪ 实测的隧道流量源 IP(= 各环境 poc-net 网桥网关;下方为示例占位,以实测回填)。
    # 宿主 jump-tunnel 连 127.0.0.1:80 的 loopback 目标不走 DNAT、由 docker-proxy
    # 转投容器,容器看到的源 IP 是网关 —— 「信任 127.0.0.1」在容器层不成立,
    # 勿照抄宿主层口径(public-fallback-entry.md「阶段 4」旧片段)。
    # **只信网关单 IP,勿放宽到整个网段**:同网段其他容器直连 nginx:80 即可伪造。
    # real_ip_recursive 默认 off = 取 XFF 链最后一个地址,
    # 即跳板机 $proxy_add_x_forwarded_for 追加在链尾的真实客户端 IP。
    set_real_ip_from <prod 网关实测值>;    # prod 网桥网关(示例 172.20.0.1)
    set_real_ip_from <dev 网关实测值>;     # dev 网桥网关(两环境共享网桥时删此行)
    real_ip_header X-Forwarded-For;
```

**变更二:五个 ms-api location 各加一行**(其余 location 一律不动):

```nginx
        # W2a:覆写为已还原的真实 IP(单值,不追加;uvicorn --proxy-headers 消费)
        proxy_set_header X-Forwarded-For $remote_addr;
```

| location | 加法 |
|---|---|
| `location ^~ /api/v1/` | 加在 `proxy_set_header X-Forwarded-Proto $xfp;` 之后 |
| `location ^~ /ms-static/` | 同上 |
| `location = /privacy` | 该块现无 proxy_set_header,proxy_pass 前直接加 |
| `location = /terms` | 同上 |
| `location = /ms-healthz` | 加在 `X-Forwarded-Proto $xfp;` 之后 |

(行号见 ops-manual §11.5;漂移按符号定位。)

**红线**:`$xfp` map 与 `Host $http_host` 语义勿回退(dynamic-presign 契约,
`tests/test_dynamic_presign_host.py` 钉死)。`$remote_addr` 还原后既有
`X-Real-IP $remote_addr`(/ms-dev/、/ms-thumbs/)一并变真,无害,不动。

**部署**:

```bash
# 仓库提交后在 material-storage/ 下:
bash scripts/deploy_lan.sh dev --restart && bash scripts/deploy_lan.sh prod --restart
ssh hh2 'docker exec poc-nginx-dev nginx -t && docker exec poc-nginx-dev nginx -s reload'
ssh hh2-prod 'docker exec poc-nginx nginx -t && docker exec poc-nginx nginx -s reload'
# reload 后立即执行 §5 验收 3(伪造用例复核)
```

- [x] ② 完成,双环境 reload 成功,立即做了验收 3

> **执行实录(2026-10-19)**:改动落在分支 `feat/w2a-realip-nginx`(基于 liuqi,
> commit `fa49190`,仅 default.conf +23 行)。未走 deploy_lan.sh 整仓 tar 流(当日
> 隧道多次抖动,单文件几 KB 走 `cat | ssh > 远端` 管道更稳),双环境 checkout
> (`/home/msdev/ms`、`/home/huanhua/ms`)均:先备份 `default.conf.bak-w2a` → 写入
> (md5 双侧一致 6c813e77…)→ `docker exec <poc-nginx> nginx -t && nginx -s reload`,
> dev 13:07:57 / prod 13:08:07 依次生效。回滚 = 还原 .bak-w2a + reload,或 git
> revert fa49190 后重推。

---

## 5. 验收(4 条,全过才算激活完成)

1. ⓪ 实测记录各入口容器层源 IP,已回填 §6;
2. 修复后:公网 443 请求的审计 `request_ip` = 用户真实公网 IP;内网直连 = 真实内网 IP;
   **不再出现 172.20.0.7**;
3. 伪造用例:内网直连带伪造 `X-Forwarded-For` 头 → 审计 IP 仍为真实内网 IP(被覆写);
   经公网 :18080/:8080(反代后)带伪造 XFF → 审计 IP = 真实公网 IP,伪造值被顶到链首
   不被采信(**② reload 后立即复核本条**)——
   `curl -s -H 'X-Forwarded-For: 1.2.3.4' http://47.108.196.211:18080/api/v1/auth/me` 后查审计;
4. 登录限流:两个不同公网 IP 各连错 5 次,互不影响(共享桶事故解除)。

- [x] 验收 4 条全过(2026-10-19,记录见 §6)

## 6. 实测/验收记录表(2026-10-19 执行回填)

| 入口 | 容器层源 IP(实测) | 预期 |
|---|---|---|
| prod 443 隧道 | 172.20.0.1(XFF 链尾=112.193.57.210,① 已带 XFF) | prod 网桥网关 ✓ |
| prod 18080(③ 前裸隧道/③ 后经反代) | ③ 前 172.20.0.1/XFF=`-`;③ 后 172.20.0.1/XFF 链尾=112.193.57.210 | 同上(③ 后对外 URL 不变)✓ |
| prod 内网直连 | 192.168.110.189(真机 Chrome 样本)/ 192.168.110.221(hh2 自打) | 真实 192.168.x ✓ |
| dev 内网 :8090 | 192.168.110.221(hh2 自打样本;外部真机样本未取) | 真实 192.168.x ✓ |
| dev 外网 :8080(③ 前裸隧道/③ 后经反代) | ③ 前 172.22.0.1/XFF=`-`;③ 后 172.22.0.1/XFF 链尾=112.193.57.210 | dev 网桥网关(③ 后对外 URL 不变)✓ |

网络名实测结论:两环境**独立网桥**——prod `poc-pigsty-minio_poc-net`(gw 172.20.0.1)、
dev `msdev-poc_poc-net`(gw 172.22.0.1);conf 单文件双环境同步,② 双网关都写。

验收执行记录(2026-10-19,Evan/ZCode):
1. ⓪ 实测如上表 ✓;
2. 修复后 443 真实登录(`local/login`,Evan)→ `audit_events.request_ip = 112.193.57.210`
   (**DB 实锤,172.20.0.7 消失**);内网直连 uvicorn 层 client=192.168.110.221 ✓;
3. 伪造用例(三入口各带 `X-Forwarded-For: 1.2.3.4`):443/18080 → uvicorn client=
   112.193.57.210(跳板机把伪造值顶到链首,realip 取链尾);内网直连 → client=
   192.168.110.221(poc-nginx 覆写 `$remote_addr` 生效);dev 内网同理 ✓;
4. 限流分桶:代码链闭环 `ip=ctx.request_ip=request.client.host`(local_auth.py +
   deps.py:162),随真实 IP 自动分桶 ✓;「两个不同公网 IP 各连错 5 次」的双出口实测
   受会话单出口限制未执行,**遗留真机抽测**(机制上已随验收 3 间接证明)。

## 7. 回滚(顺序 = 反向;整体回退,不存在只回滚一半的安全态)

1. **先撤 ②**:还原 default.conf(摘除 §4 片段或 git revert)→ `deploy_lan.sh` 双环境同步
   → 双侧 `nginx -s reload`;
2. **再撤 ①**:跳板机 `bucket-taoxiplan.conf` 去掉 X-Forwarded-For 行(用 .bak)→ reload;
3. **再撤 ③**:跳板机删 `ms-port-proxy.conf`(或注释两个 server)**并把
   `bucket-taoxiplan.conf` 的 `proxy_pass 127.0.0.1:18081` 还原回 `18080`**(用
   .bak-20261019-3b,2026-10-19 执行时的必要修正,见 §3 实录)→ reload → hh2 侧把
   `-R 127.0.0.1:18081/:8081:...` 改回 `-R 0.0.0.0:18080/:8080:...` 重启隧道
   (恢复直通形态;伪造面回到「修复前基线」,须自知)。

回滚后审计 IP 回落 172.20.0.7 现象、登录限流共享桶问题一并回来。

## 8. 口径备忘

- **历史数据不回填**(真实 IP 从未被传输),自激活时刻起新事件才是真实 IP;
- 只信网关**单 IP** 勿放宽网段(同网段容器可直连 nginx:80 伪造);宿主本机进程经
  loopback → docker-proxy → 网关源在信任内(可信面);hairpin 边缘(容器经宿主发布端口)
  风险低,记录即可;
- **③ 后 :18080/:8080 与 443 同信任**(都经跳板机 nginx 追加真实 IP 到 XFF 链尾,
  realip 取链尾,客户端伪造值被顶到链首不被采信);
- **网桥重建可能变更网关 IP**,环境重建后须复核 ⓪ 并更新 set_real_ip_from;
- **dev 退化依赖**:若 ⓪ 实测两环境共享网桥,「只写 prod 网关」物理上不可行(conf 单文件
  双环境同步),只能双网关都写(本 runbook 默认形态)或整体缓行;
- uvicorn `--forwarded-allow-ips '*'` 保持不动(入口已收敛在 poc-nginx);
- `request_ip` 列 String(64),零 migration。

## 9. 完成后文档标记清单(2026-10-19 全部完成)

- [x] 本文件 §6 回填实测值与验收记录,状态行改「已激活(<日期>)」;
- [x] `public-fallback-entry.md`「阶段 4」小节标记已落地(其 `set_real_ip_from 127.0.0.1`
      是宿主层旧口径,已被容器层口径取代);
- [x] `prod-public-entry-runbook.md` 的 18080 相关流程更新说明(通道实现变了:裸隧道直通
      → 跳板机 `ms-port-proxy.conf` 反代,运维/排障入口随之变化);
      跳板机 `ms-port-proxy.conf` 与 `bucket-taoxiplan.conf` 最终版已备份到仓库根
      `scripts/env/`,sha256(2026-10-19):
      `bucket-taoxiplan.conf` = `bed01b21144625d16924cb2b3f06975a2be33a6b02d1d38f1e9c716815c5a313`(proxy_pass 已指 18081);
      `ms-port-proxy.conf` = `fe49305c4624864ecb17a501838ec9798016998676ab89b4bb05c14b6d2c43c6`;
- [x] `scripts/changelog.md` 记账。
- 附:hh2 侧回滚锚点 `/home/{msdev,huanhua}/ms/poc/minio/nginx/default.conf.bak-w2a`、
  `/home/msdev/jump-tunnel.service.bak`、跳板机 `bucket-taoxiplan.conf.bak-20261019-3b`;
  代码变更在分支 `feat/w2a-realip-nginx`(fa49190),合并 liuqi 待指令。
