# 生产环境外网映射操作流程(runbook)

> 状态:**待实施**(本文档只记录流程,不含任何已执行动作)。
> 记录日期 2026-09-04。总方案与设计论证见 [public-fallback-entry.md](./public-fallback-entry.md),
> 本文是其中"prod 复制 dev 试点"的操作化,dev 侧(8080)已于 2026-09-04 全链路验收通过。

---

## 0. 前置事实(已具备 / 尚缺)

**已具备:**

| 项 | 状态 |
| --- | --- |
| 阿里云安全组 `18080/TCP` | **已放行**(2026-09-04 用户控制台操作)。当前阿里云侧无人监听该端口,外网访问超时,无风险 |
| hh2 prod 环境 | nginx 监听 `:80`,compose 目录按 dev 同构为 `/home/huanhua/ms/api`(步骤 0.3 确认),容器名 `ms-api` / `ms-worker` / `poc-nginx`(无后缀,dev 带 `-dev`) |
| 反向隧道基础设施 | msdev 的用户级 systemd `jump-tunnel` 在线,当前承载 `12222→hh2:22` + `8080→hh2:8090(dev)`;阿里云 sshd `GatewayPorts clientspecified` 已生效(备份 `/etc/ssh/sshd_config.bak-20260904`) |
| prod 机器账号 | **huanhua**,私钥 `scripts/env/rusheslab-server-main`(该目录已被 `scripts/.gitignore` 忽略,不会进公开仓库);用于读写 `/home/huanhua/ms` 下的 prod 配置与 compose 操作 |
| 干线吞吐 | dev 期间实测 ≈75Mbps,承载 prod 流量无需重新评估 |

**尚缺(实施前必须补齐或明确取舍):**

| 项 | 说明 |
| --- | --- |
| 阶段 3 代码(签名 host 请求驱动) | **prod 强烈建议先上**,否则只能退化为"改 .env"临时形态(副作用见步骤 2B) |
| 阶段 4 代码(真实 IP 限流) | 同上;prod 有真实用户,"公网失败 5 次锁全入口 15 分钟"会从测试小坑变真事故 |

---

## 1. 身份与入口速查

| 干什么 | 用哪个身份 |
| --- | --- |
| 改隧道 unit(msdev 名下)、hh2 通用探查 | `ssh hh2`(= msdev,密钥 `~/.ssh/rusheslab-server`,经 12222 隧道) |
| 改 prod `.env`、重启 prod compose | **huanhua**(见下方别名,密钥 `scripts/env/rusheslab-server-main`) |
| 安全组规则 | 阿里云控制台(人工) |

建议在 `~/.ssh/config` 加 huanhua 别名(与既有 `hh2` 并列):

```
Host hh2-prod
  HostName 127.0.0.1
  Port 12222
  User huanhua
  IdentityFile E:/qbb/github_not_me/rushes-lab/scripts/env/rusheslab-server-main
  IdentitiesOnly yes
  ServerAliveInterval 30
  ProxyJump aliyun-jump
```

**prod 公网入口(完成后)**:`http://47.108.119.221:18080`

---

## 2. 操作流程

### 步骤 0:前置确认(全部只读,随时可做)

```bash
# 0.1 huanhua 首次连接验证(经既有 12222 隧道;若失败先检查 hh2 上
#     /home/huanhua/.ssh/authorized_keys 是否配了该公钥)
ssh -i scripts/env/rusheslab-server-main -p 12222 \
    -o ProxyJump=aliyun-jump -o IdentitiesOnly=yes huanhua@127.0.0.1 'whoami; echo $HOME'

# 0.2 确认阶段 3/4 代码已随 deploy_lan.sh prod 上线(看 DEPLOYED.md 的 commit
#     是否包含"请求驱动签名";没上就先做代码,别直接进步骤 2B)
ssh hh2-prod 'cat /home/huanhua/ms/DEPLOYED.md | head -20'

# 0.3 探 prod compose 项目(确认目录/服务名/当前健康)
ssh hh2-prod 'cd /home/huanhua/ms/api && docker compose ps --format "{{.Name}} {{.Status}}"'
```

### 步骤 1:隧道加 prod 转发(msdev 身份;照 dev 已验证的流程)

⚠ 自锁风险同 dev:重启隧道会杀掉脚下连接,回滚兜底必须用 hh2 本地定时器。

```bash
ssh hh2 '
set -e
# 备份 + 预埋 180s 自动还原定时器
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
# 在 ExecStart 的 -R 0.0.0.0:8080:127.0.0.1:8090 之后追加:
#   -R 0.0.0.0:18080:127.0.0.1:80
sed -i "s|-R 0.0.0.0:8080:127.0.0.1:8090|-R 0.0.0.0:8080:127.0.0.1:8090 -R 0.0.0.0:18080:127.0.0.1:80|" \
  /home/msdev/.config/systemd/user/jump-tunnel.service
systemctl --user daemon-reload && systemctl --user restart jump-tunnel
'   # 本会话掉线属预期

# 验证(新开会话):
ssh aliyun-jump 'ss -tlnp | grep 18080'                 # 期望 sshd 监听 *:18080
ssh aliyun-jump 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18080/ms-static/web/'   # 期望 200
curl -s -o /dev/null -w "%{http_code}" -m 8 http://47.108.119.221:18080/ms-static/web/            # 外网 200(安全组已开)

# 成功后立刻取消回滚定时器(否则 180s 后配置被自动还原!):
ssh hh2 'export XDG_RUNTIME_DIR=/run/user/1003; systemctl --user stop tunnel-rollback.timer; systemctl --user list-timers | grep -c tunnel-rollback'
```

失败处理:什么都不用做,180 秒后定时器自动还原;事后 `journalctl --user -u jump-tunnel` 查因。

### 步骤 2A:点亮 prod 公网签名(正式路径,前置 = 阶段 3 已上线)

```bash
ssh hh2-prod '
set -e
cp /home/huanhua/ms/api/.env /home/huanhua/.env.bak-prod-$(date +%Y%m%d)   # 备份先行
# 追加允许列表(请求驱动签名的开关;阶段 3 上线后 prod 内网默认行为不变)
grep -q "^ALLOWED_PUBLIC_BASES=" /home/huanhua/ms/api/.env \
  && sed -i "s|^ALLOWED_PUBLIC_BASES=.*|ALLOWED_PUBLIC_BASES=http://47.108.119.221:18080|" /home/huanhua/ms/api/.env \
  || echo "ALLOWED_PUBLIC_BASES=http://47.108.119.221:18080" >> /home/huanhua/ms/api/.env
cd /home/huanhua/ms/api && docker compose up -d --force-recreate ms-api
'
```

### 步骤 2B:应急路径(仅当阶段 3 未上线且业务等不了;副作用大,不推荐)

与 dev 2026-09-04 做法相同:备份 `.env` → 把 `MINIO_ENDPOINT_PUBLIC` /
`MINIO_THUMBNAIL_ENDPOINT_PUBLIC` 从内网地址改为 `http://47.108.119.221:18080` →
`--force-recreate ms-api`。**副作用(在 prod 被放大)**:内网主力用户的缩略图/上传下载全部
绕公网一圈;公网登录失败 5 次锁全公网入口 15 分钟。做完 2B 的,阶段 3 上线后应回切 2A 形态
(恢复 .env 的 endpoint,改用 ALLOWED_PUBLIC_BASES)。

### 步骤 3:验收(照 dev 验收清单)

```bash
# 外网全链路(登录→搜索→缩略图实际拉取→原片 Range 拉取)
#   参照 dev 验收脚本口径:POST /api/v1/auth/local/login → GET /assets/search
#   → GET /assets/{id}/thumbnail-url 且 URL host=47.108.119.221:18080 → curl 该 URL = 200
#   → POST /assets/{id}/download-link → curl -r 0-1048575 = 206
# 内网回归(必须全绿):
curl -s -o /dev/null -w "%{http_code}" http://192.168.110.221/ms-static/web/        # prod 直连 200
curl -s -o /dev/null -w "%{http_code}" http://192.168.110.221:8090/ms-static/web/   # dev 200
ssh hh2 'systemctl --user is-active jump-tunnel'                                    # active
```

阶段 3 形态的内网核心验收:内网浏览器开 prod,Network 面板确认缩略图 URL host 仍是
`192.168.110.221`(不绕公网)——这是 2A 与 2B 的本质区别。

### 步骤 4:收尾建议

- 安全组 `18080` 授权对象从 `0.0.0.0/0` 收敛为团队出口 IP(prod 有真实客户照片,比 dev 更要紧);
- 已知遗留(与 dev 同构):MinIO Console 路径(`/console` `/login`)经 18080 亦可达,如需屏蔽
  用纯 HTTP 反代做路径 404(见总方案 §4.5);
- `deploy_lan.sh prod` 流程不受影响(走 12222,不动)。

---

## 3. 回滚总表(每层独立,顺序任意)

| 层 | 动作 | 效果 |
| --- | --- | --- |
| 允许列表(2A 形态) | `.env` 删 `ALLOWED_PUBLIC_BASES` 行 → `--force-recreate ms-api` | 公网签名失效(回落内网 host),内网无感 |
| .env endpoint(2B 形态) | `cp /home/huanhua/.env.bak-prod-YYYYMMDD .../.env` → recreate | 恢复内网签名,公网图挂 |
| 隧道 | hh2 跑 `/home/msdev/tunnel-rollback.sh`(还原 unit 并重启;若后来又做了 dev 改动,注意备份新鲜度) | 18080 转发消失,12222/8080 保留 |
| 安全组 | 控制台删 18080 规则 | 公网彻底不可达(最外层闸门) |

> 隧道层回滚注意:`tunnel-rollback.sh` 还原的是 `jump-tunnel.service.bak`——若步骤 1 之后又有
> 其他人对 unit 做过变更,先确认备份内容是否仍为期望的"上一个已知好状态",必要时手动编辑 ExecStart
> 只删 `-R 0.0.0.0:18080:127.0.0.1:80` 一段。
