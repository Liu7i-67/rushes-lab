---
name: deploy-hh2
description: 内网 hh2 服务器（dev/prod）部署注意事项与踩坑手册。凡是要把 material-storage 部署/同步到内网测试或生产环境、运行 deploy_lan.sh、或部署中出现"卡死不动"、同步断流、SPA 没更新、部署后版本没变等问题时使用——即使用户没说"部署"这个词，或只说"发到测试环境/内网环境/给 tester 看"。
---

# 内网 hh2 部署 —— 环境事实、标准流程与踩坑手册

先读 `CLAUDE.md` 的「部署 D」一节。本技能是其展开版：收录已实踩过的坑和验证过的替代通道。动手前按 §1 预检，部署完按 §5 验证清单逐项过。

## 1. 环境事实（先对号入座）

| | dev（测试环境） | prod |
| --- | --- | --- |
| SSH | `hh2`（msdev） | `hh2`（huanhua） |
| 远端目录 | `/home/msdev/ms` | `/home/huanhua/ms` |
| 入口 | `http://192.168.110.221:8090`（外网 `http://47.108.196.211:8080`） | `http://192.168.110.221`（外网 `:18080`） |
| 容器 | `ms-api-dev` / `ms-worker-dev` / `ms-db-dev` | `ms-api` / `ms-worker` / `ms-db` |

- ssh 走跳板反向隧道，**会抖动也会中途断流**（§3 是重点）。
- 同机双环境并存，靠三层隔离（COMPOSE_PROJECT_NAME / container_name 后缀 / ports `!override`）互不干扰——**别动这套隔离，exec/重启前先看清容器名后缀**。
- `.env` 与 `docker-compose.override.yml` 在目标机上从不随部署覆盖。
- dev 的 nginx 把 `/healthz` 路由到 MinIO（既有配置），**API 存活用 `/api/v1/auth/me`（未登录 401）判断**。

## 2. 部署前预检（每次都做）

1. 工作区干净（`git status --short` 为空）。deploy 同步的是**工作区**，不是纯 commit；脏工作区会被记进 DEPLOYED.md 的"源端未提交改动"。
2. 本次有没有改 `.env`？→ 没有就不用 `--force-recreate`；**有则必须 `docker compose up -d --force-recreate`（`restart` 不重读 env_file）**。
3. 有没有新 migration？→ 有则在重启后 `alembic upgrade head`；没有就**别跑**。
4. `.py` 是 bind mount 但容器无 `--reload` → **后端有改动就必须 restart**；仅 SPA 改动不用重启。

## 3. 标准流程与两个大坑

```bash
cd material-storage
pnpm --dir web build            # SPA 不随脚本同步,单独推(§4)
bash scripts/deploy_lan.sh dev --restart
```

### 坑 A：「看着卡死 ≠ 没完成」（假挂起）
脚本末尾 `cat DEPLOYED.md` 经隧道可能无限挂起，且输出经管道缓冲**连中间进度都看不到**。
**不要只等回显**，另开探针判断进度：

```bash
ssh hh2 'grep -E "git commit" ~/ms/DEPLOYED.md'      # 版本变了吗
ssh hh2 'ls -d /tmp/ms-sync-dev 2>/dev/null'          # 暂存目录还在 = 还在同步
docker ps --format "{{.Names}}\t{{.Status}}" | grep ms-   # 重启了吗
```

### 坑 B：真断流（tar 流 ~800KB 处死亡）
`deploy_lan.sh` 的 tar 流式同步在跳板隧道上实测两次于 ~800KB 处中途断流。`ssh_r` 的 8×6s 重试**只覆盖建连失败，管不了已建立流的中途死亡**。
**判死**（别猜）：对远端暂存目录做 KB 级两次采样，15-30s 零增长即真死：

```bash
ssh hh2 'du -sk /tmp/ms-sync-dev | cut -f1'   # 隔 15s 再跑一次,数字不动 = 死了
```

**确认死了就别再重试整脚本**，直接走分片通道（§4）。

## 4. 分片通道（断流后的可靠替代，2026-09-10 实战验证）

原理：每片 ≤512KB（低于断流阈值），每片一条新 ssh 流 + 失败重试；远端拼接后 md5 校验。

**推送单个文件**（SPA 包、代码包都用它）：

```bash
bash .agents/skills/deploy-hh2/scripts/chunked-push.sh <本地文件> <远端绝对路径>
# 例: chunked-push.sh /tmp/ms-spa.tgz /tmp/ms-spa.tgz
```

**代码同步的完整替代流程**（等价 deploy_lan.sh 的全部效果）：

1. 本地打包（排除项与 deploy_lan.sh 对齐，**排除项一律用裸名**——`./data` 这种带 `./` 的写法锚定根路径，拦不住 `poc/minio/data` 深层同名目录，历史事故就是把本地 MinIO 数据同步进了内网机）：

   ```bash
   cd material-storage
   tar czf /tmp/ms-sync.tgz --exclude='.git' --exclude='.env' --exclude='node_modules' \
     --exclude='uv.lock' --exclude='__pycache__' --exclude='*.pyc' --exclude='.venv' \
     --exclude='static/web' --exclude='data' --exclude='data-dev' --exclude='data-thumbs' \
     --exclude='backup-mirror' --exclude='poc/minio/data' --exclude='poc/minio/data-dev' \
     --exclude='poc/minio/data-thumbs' --exclude='docker-compose.override.yml' .
   ```

2. `chunked-push.sh /tmp/ms-sync.tgz /tmp/ms-sync.tgz`（脚本自带远端建目录、分片重试、md5 校验）。
3. 远端解压 → rsync 到目标 → 写 DEPLOYED.md → 重启，一段 ssh 批量发完（减少往返）：

   ```bash
   ssh -o ConnectTimeout=8 hh2 'bash -s' <<'EOF'
   set -euo pipefail
   rm -rf /tmp/ms-sync-dev && mkdir -p /tmp/ms-sync-dev
   tar xzf /tmp/ms-sync.tgz -C /tmp/ms-sync-dev/
   rsync -a --inplace \
     --exclude .env --exclude docker-compose.override.yml --exclude 'static/web' \
     --exclude 'poc/minio/data' --exclude 'poc/minio/data-dev' --exclude 'poc/minio/data-thumbs' \
     /tmp/ms-sync-dev/ /home/msdev/ms/
   rm -rf /tmp/ms-sync-dev /tmp/ms-sync.tgz
   cat > /home/msdev/ms/DEPLOYED.md <<'DEP'
   (照 deploy_lan.sh 的模板手写:git commit/分支/commit 信息/部署时间/部署者,务必填对)
   DEP
   cd /home/msdev/ms/api && docker compose restart ms-api ms-worker
   EOF
   ```

4. `--inplace` 别去掉：nginx conf 等是 bind mount，换 inode 会让容器内看到 stale 文件。
5. 小坑：scp 报 `No such file or directory` 多半是**远端目标目录没建**，先 `ssh hh2 'mkdir -p <dir>'`。

**SPA 原子替换**（先备份再换名，防半包状态）：

```bash
cd /home/msdev/ms/api/app/static
[ -d web ] && mv web web.bak-<日期>
mv /tmp/ms-spa-new/web ./web     # 解压到临时目录后整体 mv
rm -rf web.bak-<日期>             # 确认入口指纹正确后再删
```

## 5. 部署后验证清单（全部在 hh2 上实测，逐项过）

```bash
ssh hh2 'grep -E "git commit|分支" ~/ms/DEPLOYED.md'                        # ① 版本 = 预期 commit
ssh hh2 'curl -s http://127.0.0.1:8090/ms-static/web/ | grep -o "index-[^\"]*\.js" | head -1'   # ② 指纹 = 本地 build
ssh hh2 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8090/api/v1/auth/me'         # ③ 401 = API 活着
ssh hh2 'docker exec ms-api-dev grep -c <本次新代码的特征串> /app/app/<文件>'                     # ④ 容器吃到新代码
```

⑤ 业务语义抽测一条（例：本次的 download-link 附件语义，用 X-User-Id dev 通道 + 库内真实 asset 实测响应头）。本地 build 指纹获取：`grep -o 'index-[^"]*\.js' api/app/static/web/index.html | head -1`。

## 6. 回滚

工作区 `git checkout <目标commit>` → 重复 §4（或 `deploy_lan.sh`，能通就通）→ restart。`.env` 与数据目录全程不动。回滚后同样过 §5 清单。

## 7. 与 server2 的区别（别混用）

- `deploy_server2.sh`（公网 8.156.34.238，tester 入口）才有 `MAINTENANCE_ISSUES` 弹窗机制；hh2 没有弹窗通道，tester 通知走 issue / 群里附回归清单。
- server2 是 rsync 直连（无跳板断流问题）；hh2 必经跳板隧道，长流不可靠，**优先考虑分片通道**。
