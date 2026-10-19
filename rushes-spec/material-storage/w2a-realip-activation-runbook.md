# W2a 审计真实 IP 激活 runbook(执行版)

> **用途**:把审计日志里的 `172.20.0.7`(poc-nginx 容器 IP)换成用户真实 IP,顺带解除
> 「公网入口全员共享一个 per-IP 登录限流桶」的连带事故。
> **来源与关系**:方案正本 = `admin-audit-folder-mobile-optimization-plan.md` §2(qplan 13 轮
> 盲审定稿);手册章节 = `ops-manual.md` §11(内容同源)。本文件是**可打印照抄的执行版**,
> 步骤编号与 §11 一致,内容漂移时以 ops-manual §11 为准并同步本文件。
> **状态**:**未激活**(2026-10-17 定稿)。激活须运维窗口,预估总耗时 ~40 分钟(含验证)。
> **影响预告**:公网入口会闪断两次(隧道重启 + nginx reload);prod :18080 与 dev :8080
> 两个外网入口将被**关闭**(决策 16/17 已拍 a);全程有 180s 自动回滚定时器护底。

---

## 0. 执行前核对(全过才开工)

- [ ] 运维窗口已确认(公网入口闪断两次:③ 隧道重启、② nginx reload);
- [ ] 「dev 外网 :8080 随 ③ 关闭」已确认接受(决策 17=a:dev 没有跳板机 443 vhost,
      改绑后 dev 外网不可达;如需保留须先在跳板机为 dev 新增反代 vhost 并同加 XFF);
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

- [ ] ⓪ 完成,实测值已回填 §6

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

- [ ] ① 完成,跳板机 reload 成功,conf 已备份到 scripts/env/(git status 复核未进暂存)

---

## 3. ③ 公网裸隧道入口收敛(hh2 侧 `-R` 改绑 127.0.0.1;先于 ② reload)

**为什么必须做**:② 生效后,18080/8080 裸隧道流量与 443 隧道流量在 poc-nginx 眼里同源同信任,
客户端自带 `X-Forwarded-For: 1.2.3.4` 会经 realip(取链尾)直接变成 `$remote_addr`——
审计 IP 可任意伪造 + 换一个伪造 IP 就换一个全新 per-IP 限流桶。绑定地址由 hh2 侧 ssh
客户端决定,服务文件在 **hh2 的 `/home/msdev/.config/systemd/user/jump-tunnel.service`**,
不是去跳板机上改。

```bash
ssh hh2 '
set -e
# 0) 备份 + 预埋 180s 自动还原定时器(防重启隧道杀掉脚下连接后的自锁;验证通过后必须取消,见第 4 步)
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

# 1) 两条裸隧道 -R 改绑 127.0.0.1(prod 18080 + dev 8080;12222 运维通道勿动!)
sed -i \
  -e "s|-R 0.0.0.0:8080:127.0.0.1:8090|-R 127.0.0.1:8080:127.0.0.1:8090|" \
  -e "s|-R 0.0.0.0:18080:127.0.0.1:80|-R 127.0.0.1:18080:127.0.0.1:80|" \
  /home/msdev/.config/systemd/user/jump-tunnel.service
systemctl --user daemon-reload && systemctl --user restart jump-tunnel
'   # 本会话掉线属预期(12222 隧道随重启重建,重连即可)

# 2) 验证(新开会话):跳板机上两条端口只剩 127.0.0.1 监听,外网访问超时
ssh aliyun-swas 'ss -tlnp | grep -E "18080|8080"'
#   期望 127.0.0.1:18080 / 127.0.0.1:8080,不再是 *:18080
curl -m 5 -o /dev/null http://47.108.196.211:18080/ms-healthz || echo "外网已不可达(预期)"
curl -m 5 -o /dev/null http://47.108.196.211:8080/ms-healthz  || echo "外网已不可达(预期)"

# 3) 内网回归:ssh hh2(经 12222)通;内网 prod 80 / dev 8090 仍 200

# 4) ★ 成功后立刻取消 180s tunnel-rollback 定时器(不取消 = 180s 后改绑被静默还原、裸通道重新对外)
ssh hh2 'export XDG_RUNTIME_DIR=/run/user/1003; systemctl --user stop tunnel-rollback.timer; systemctl --user list-timers | grep -c tunnel-rollback'
```

**失败处理**:什么都不用做,180 秒后定时器自动还原;事后 `journalctl --user -u jump-tunnel` 查因。

- [ ] ③ 完成,定时器已取消,外网 18080/8080 已不可达,内网入口回归正常

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

- [ ] ② 完成,双环境 reload 成功,立即做了验收 3

---

## 5. 验收(4 条,全过才算激活完成)

1. ⓪ 实测记录各入口容器层源 IP,已回填 §6;
2. 修复后:公网 443 请求的审计 `request_ip` = 用户真实公网 IP;内网直连 = 真实内网 IP;
   **不再出现 172.20.0.7**;
3. 伪造用例:内网直连带伪造 `X-Forwarded-For` 头 → 审计 IP 仍为真实内网 IP(被覆写);
   经公网裸通道带伪造 XFF → 不可达/不可伪造(**② reload 后立即复核**);
   `curl -s -H 'X-Forwarded-For: 1.2.3.4' http://192.168.110.221/api/v1/auth/me` 后查审计;
4. 登录限流:两个不同公网 IP 各连错 5 次,互不影响(共享桶事故解除)。

- [ ] 验收 4 条全过

## 6. 实测/验收记录表(⓪ 与验收产物,实施时回填)

| 入口 | 容器层源 IP(实测) | 预期 |
|---|---|---|
| prod 443 隧道 | _(待回填)_ | prod 网桥网关 |
| prod 18080 裸隧道 | _(待回填)_ | 同上(③ 后该入口关闭) |
| prod 内网直连 | _(待回填)_ | 真实 192.168.x |
| dev 内网 :8090 | _(待回填)_ | 真实 192.168.x |
| dev 外网 :8080 裸隧道 | _(待回填)_ | dev 网桥网关(③ 后该入口关闭) |

网络名实测结论(仓库声明 `poc-pigsty-minio_poc-net` vs `<project>_poc-net`、两环境是否
共享网桥):_(待回填)_

验收执行记录(4 条逐条结果 + 日期 + 执行人):_(待回填)_

## 7. 回滚(顺序 = 反向;整体回退,不存在只回滚一半的安全态)

1. **先撤 ②**:还原 default.conf(摘除 §4 片段或 git revert)→ `deploy_lan.sh` 双环境同步
   → 双侧 `nginx -s reload`;
2. **再撤 ①**:跳板机 `bucket-taoxiplan.conf` 去掉 X-Forwarded-For 行(用 .bak)→ reload;
3. ③ 一般不回滚;确需恢复裸通道:把 `-R 127.0.0.1:...` 改回 `-R 0.0.0.0:...` 并重启隧道
   (伪造面随之回来,须自知)。

回滚后审计 IP 回落 172.20.0.7 现象、登录限流共享桶问题一并回来。

## 8. 口径备忘

- **历史数据不回填**(真实 IP 从未被传输),自激活时刻起新事件才是真实 IP;
- 只信网关**单 IP** 勿放宽网段(同网段容器可直连 nginx:80 伪造);宿主本机进程经
  loopback → docker-proxy → 网关源在信任内(可信面);hairpin 边缘(容器经宿主发布端口)
  风险低,记录即可;
- **网桥重建可能变更网关 IP**,环境重建后须复核 ⓪ 并更新 set_real_ip_from;
- **dev 退化依赖**:若 ⓪ 实测两环境共享网桥,「只写 prod 网关」物理上不可行(conf 单文件
  双环境同步),只能双网关 + 双入口收敛(本 runbook 默认形态)或整体缓行;
- uvicorn `--forwarded-allow-ips '*'` 保持不动(入口已收敛在 poc-nginx);
- `request_ip` 列 String(64),零 migration。

## 9. 完成后文档标记清单

- [ ] 本文件 §6 回填实测值与验收记录,状态行改「已激活(<日期>)」;
- [ ] `public-fallback-entry.md`「阶段 4」小节标记已落地(其 `set_real_ip_from 127.0.0.1`
      是宿主层旧口径,已被容器层口径取代);
- [ ] `prod-public-entry-runbook.md` 的 18080 全套流程与回滚节标记过时(被本 runbook 取代);
      阿里云轻量机防火墙的 18080/8080 放行规则一并收敛(纵深防御);
- [ ] `scripts/changelog.md` 记账。
