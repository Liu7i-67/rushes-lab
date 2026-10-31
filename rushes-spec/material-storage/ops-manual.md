# material-storage 运维手册

> 适用范围:PoC server2 部署(8.156.34.238)+ 反代 server1;生产内网单机部署见 §10。
> 适用对象:系统管理员 / 维护工程师。
> 最后更新:2026-10-31(新增 §12 MCP 素材服务(ms-mcp)运维;§6.6/§10.3 补交叉引用)

---

## 0. 快速入口

```bash
# SSH 进 PoC server
ssh root@8.156.34.238

# 工作目录(docker compose 项目根)
cd /root/material-storage-api

# 容器一览
docker ps --format "table {{.Names}}\t{{.Status}}"
```

容器清单(全部 Up):

| 容器 | 作用 |
|---|---|
| `ms-api` | FastAPI 业务后端(127.0.0.1:8200) |
| `ms-worker` | arq 后台 worker(缩略图 + 定时任务) |
| `ms-db` | PostgreSQL 16 |
| `ms-redis` | Redis 7(arq queue + cache) |
| `poc-pigsty-minio` | MinIO 对象存储 |
| `poc-openfga` + `poc-openfga-db` | OpenFGA 权限引擎 + Postgres |
| `poc-nginx` | 反代 → 80 端口对外(ms-api + MinIO 静态) |
| `seafile` / `seafile-mysql` / `seafile-minio` | 遗留 PoC,与本应用无关 |

---

## 1. 系统 admin 管理(重点)

系统 admin = `organization#admin` OpenFGA tuple。**只有系统 admin 可创建项目**;UI 不提供 promote/demote(防误操作),只能后台命令。

**关键事实**:
- 系统 admin **数量无硬上限**(可加多个;典型用法见下面"典型场景")
- 系统 admin 在 **所有 project / folder / asset** 上拥有完整权限(view / download / upload / admin / share / delete),无需另外 grant(PR #77 起 backend 全覆盖直通)
- 系统 admin 仍然走 audit(下载 / 删除 / access_denied 等照记)

```bash
# 列当前所有系统 admin(包括所有 ou_*)
docker exec ms-api python -m scripts.grant_org_admin --list

# 添加一个系统 admin(用飞书 open_id;再跑一次 = 加第二个,不冲突)
docker exec ms-api python -m scripts.grant_org_admin ou_xxxxxxxxxxxx

# 撤销
docker exec ms-api python -m scripts.grant_org_admin --revoke ou_xxxxxxxxxxxx
```

### 如何拿到某个 user 的 open_id

让用户先去 web 用飞书 OIDC 登录一次(确保 db 有 user 行),然后:

```bash
docker exec ms-db psql -U msuser -d material_storage \
  -c "SELECT feishu_open_id, name, email FROM users WHERE name LIKE '%张三%';"
```

或者用 admin 自己登录后的 `/api/v1/auth/me` 接口看自己的 open_id。

### 典型场景

| 场景 | 命令 |
|---|---|
| 现任系统 admin 离职,要换人 | `--revoke <旧>` + 不带 flag `<新>` |
| 一个权限太集中,临时多加一个 | 不带 flag `<新>`(共存) |
| 紧急锁定:除当前所有人外 | `--list` 看清单 → 逐个 `--revoke` 保留要保的 |

### 边界规则

- 系统 admin **数量无硬上限**(模型支持多);产品上"默认 1 个"是惯例,不是 enforce
- 撤销自己:命令不阻止 — 撤销后立即无法再调 grant 命令(其他 admin 可救);**谨慎**
- 撤销项目 admin(`project#admin`):走 web ProjectMembersDrawer,不要在这里操作

---

## 2. 部署

### 2.0 推荐:一键 deploy 脚本(2026-05-18 起)

```bash
cd material-storage/api && bash scripts/deploy_server2.sh

# 推荐:带上本次解决的 issue 编号,前端会弹 modal 告诉 tester
cd material-storage/api && MAINTENANCE_ISSUES="101 104" bash scripts/deploy_server2.sh

# 或者 JSON 形式自定义 summary
cd material-storage/api && MAINTENANCE_ISSUES='[{"number":101,"summary":"自定义说明"}]' bash scripts/deploy_server2.sh
```

含:**maintenance banner 开启 (step 0.5, PR #108)** + rsync + docker compose up -d --build(含 ms-worker PR #103)+ alembic migrate + dev_bootstrap(⚠ #69 stale 已知 fail-soft)+ **demo-onboarding seed (step 6.5, PR #97)** + e2e + large file + **forensic log 备份 (step 3.5, PR #95)** + **banner 撤销 (step 9.5, PR #108)**。

**Maintenance banner**(PR #108):deploy 开始前 0.5 步会 SETEX redis `maintenance:banner` 一个 JSON,前端 ≤8s 内弹"系统升级中" modal(不可关 + 倒计时 + issue list);step 9.5 DEL 后前端转 6s "升级完成"自动关。900s TTL 兜底脚本崩了 banner 自然消失。MAINTENANCE_ISSUES 是 bare 数字时脚本会 `gh issue view` 自动拉 title。**注意:只保护已加载的 tab** — 新打开 tab 在 ms-api 重启那 30-60s 拿不到 SPA bundle,看不到 modal,这是 acceptable 取舍。

step 6/7/8 现在用 set -o pipefail + warn 替代假 ok(PR #95)— 看到 ⚠ 不阻塞 deploy,看到红色 ✗ 才需 follow up。

下面 §2.1-2.3 是手动分步,需要 surgical 操作时用。

### 2.1 后端代码更新(改 .py)

```bash
# 本地 rsync(开发机)
rsync -avz material-storage/api/app/ root@8.156.34.238:/root/material-storage-api/app/

# server 内重载
ssh root@8.156.34.238 'docker restart ms-api ms-worker'
```

`docker restart` 即可(不用 `--force-recreate`),因为 `.py` 通过 bind mount 实时生效。
**ms-worker 跟 ms-api 都要 restart**;一键脚本 step 4 已自动包含。

### 2.2 .env 改动

```bash
# 修 .env 后必须 force-recreate(docker restart 不重读 env_file)
ssh root@8.156.34.238 'cd /root/material-storage-api && docker compose up -d --force-recreate ms-api ms-worker'
```

### 2.4 OpenFGA model 升级(2026-05-18 起 / PR #130)

改了 `material-storage/poc/openfga/store.fga.yaml` 后,**必须 push 给 server2 OpenFGA store**(否则 yaml 改了但 live model 没更新,行为不一致):

```bash
cd material-storage/api
bash scripts/openfga_write_model.sh
```

行为:
- 本机 python 从 yaml 抽 `model:` 字段(纯 .fga DSL)
- scp 到 server2 `/tmp/model.fga`
- server2 上 `docker run openfga/cli model transform --input-format fga` 转 JSON
- POST 到 `http://127.0.0.1:8089/stores/{id}/authorization-models` 产新 model_id
- 打印新 model_id

**`.env` 不固定 `OPENFGA_MODEL_ID`** → ms-api 重启自动用 latest:
```bash
ssh root@8.156.34.238 'docker restart ms-api ms-worker'
```

若 `.env` 设了固定 model_id(避免意外漂移),要手动:
```bash
ssh root@8.156.34.238 \
  "sed -i 's/^OPENFGA_MODEL_ID=.*/OPENFGA_MODEL_ID=<新 id>/' /root/material-storage-api/.env && \
   cd /root/material-storage-api && docker compose up -d --force-recreate ms-api ms-worker"
```

**OpenFGA model 改动注意**(advisor #129 经验):
- 给 unconditional relation 加 condition → 老 tuple 在新 model 下行为待 verify(本环境 0 风险因 store 已无该类 tuple)
- 加新 relation 不动旧的 = 零风险
- 改 relation 名 = breaking(老 tuple 失效);避免

### 2.3 前端代码更新

```bash
# 本地 build → dist 自动输出到 api/app/static/web/
cd material-storage/web && pnpm build

# 同步到 server2(bind mount 立即生效,无需重启)
rsync -avz --delete material-storage/api/app/static/web/ \
  root@8.156.34.238:/root/material-storage-api/app/static/web/
```

### 2.4 force-recreate 副作用

`docker compose up -d --force-recreate ms-api`:
- 容器 IP 漂移 → `poc-nginx` 缓存的 upstream DNS 失效 → **502**
- 容器内 `pip install` 的临时依赖丢失(测试用 pytest 等)

修法见 §6。

---

## 2.5 Request-link 申请短链(2026-05-18 起 / PR #127 #128 #130)

完全独立于 share-link(`/s/{token}`,直接授权)。Request link `/r/{token}` 是**申请入口**(链接 = 表单,不是凭证)。

### 数据模型

`request_link_tokens` 独立表(alembic 20260518_0004):

| 列 | 含义 |
|---|---|
| `token` PK | 32 字符 base64url |
| `target_type` | `sensitive_folder` / `asset` / `project` / `folder` |
| `target_id` | uuid |
| `allowed_actions` TEXT[] | `['access']` / `['download']` / 两者 |
| `inviter_user_id` | FK users CASCADE |
| `receiver_open_id` | nullable;非空时仅限定 user 可用 |
| `expires_at` / `created_at` / `used_at` | TTL + 审计 |

### 入口与权限

| 入口 | 适用 | admin 来源 |
|---|---|---|
| ProjectsPage 项目卡片右下角 "🔗 申请链接" | project 级 link | `my_roles` 含 `admin` |
| ProjectDetailPage folder header 旁边 "🔗 申请链接"(PR #130) | folder / sensitive_folder 级 link | `folder.my_can_admin` |

POST `/api/v1/request-links`:system admin 或 target 上 `can_admin` 才能生成。

### Receiver enforce(防转发)

**两层防护**:
1. **frontend**:RequestLinkLandingPage `/r/{token}` 解析后,若 `receiver_restricted && !receiver_match` → 显友好 403 "此链接不是发给你的"
2. **backend**:approvals POST 接 `?via_link=<token>` query;若提交,backend enforce target 匹配 + action ⊂ allowed + receiver_open_id 限定 = current_user。**即使绕过 frontend(curl 直接 POST)也拦得住**(advisor #112 risk #3)

### TTL 默认 3 天,上限 30 天

`MAX_TTL_SECONDS = 30 * 86400`;`DEFAULT_TTL_SECONDS = 3 * 86400`。在 `services/request_link.py` 顶常量。

### Folder 级 grant 实施(#130 Y1 路径)

`folder.explicit_*` 已加 `non_expired_grant` condition,跟 project / asset 一致。**永久 grant**(FolderGrantsPanel 用)由 `grant_duration=100 年` condition 实现,无需独立"无 condition tuple"路径。

approval 批准 folder 级 download 申请 → `grant_explicit_download(object_type='folder', duration_seconds=...)` → 写 conditional folder.explicit_downloader tuple,到期自动失效(non_expired_grant)。

---

## 2.6 Cron 自主 issue 巡检(2026-05-18 起,session-only)

本 session 启动了一个 cron job `cc18eb0d`(每 20 分钟,7 天到期):
- 扫 open issues 找 created_at > 上次扫描 ts 的"新" issue
- 状态文件 `~/.claude/projects/.../memory/autonomous-issue-scan-state.md`
- 用户 2026-05-18 显式授权"一路推到 PR + 自跑 deploy + 关 issue"全自主模式

session 退出 = cron 失效。**重启 cron 需要在新 session 用 CronCreate**(参考之前 prompt 模板,授权由 prompt 自身承担)。

---

## 3. 飞书通讯录同步

### 3.1 冷启动全量同步

新装环境 / OpenFGA store 重建后跑一次:

```bash
docker exec ms-api python -m scripts.sync_feishu_contacts
```

行为:
- 通过 `/open-apis/contact/v3/scopes` 拿 app 可见顶级部门
- BFS 递归拉子部门 + 每部门下 user → DB upsert + OpenFGA org/dept tuples
- 拉用户组成员 → OpenFGA group tuples(若 `contact:group:readonly` 权限未开,优雅 skip)

### 3.2 增量同步(自动,不用手动操作)

飞书后台事件订阅 `https://rusheslab.taoxiplan.com/api/v1/webhooks/feishu`,events:
- `contact.user.created_v3` → DB upsert + dept tuple
- `contact.user.updated_v3` → diff dept_ids → 增/删 tuple
- `contact.user.deleted_v3` → **离职闭环**:revoke 所有 OpenFGA tuple + DB `is_active=false`
- `contact.department.updated_v3` → 重写部门 nesting

如果 webhook 没收到事件,检查:
1. 飞书后台 → 事件订阅 → URL 配的对
2. `docker exec ms-api curl -s http://127.0.0.1:8000/healthz` 通
3. `poc-nginx` 转发 OK(`docker logs poc-nginx --tail=20`)

### 3.3 飞书后台所需权限(检查清单)

| 权限 scope | 用途 | 必需? |
|---|---|---|
| `contact:contact.base:readonly` | 拉 user/dept | ✅ |
| `contact:user.base:readonly` | user 详情 | ✅ |
| `contact:department.base:readonly` | dept 详情 | ✅ |
| `contact:group:readonly` | 用户组同步 | 可选(没开会 skip) |
| `im:message:send_as_bot` | 发 IM 卡片 | ✅(权限/分享/邀请卡片) |
| 应用机器人能力启用 | 同上 | ✅ |
| 消息卡片请求网址 | 卡片回调按钮 | ✅(同 webhook URL) |
| 通讯录授权范围 | 决定 app 可见哪些部门 | 全公司 / 指定部门 |

---

## 4. 缩略图 worker

### 4.1 新上传自动生成

`POST /assets/uploads/{id}/complete` 完成后按 content_type 分流 enqueue arq job:

| content_type | worker function | 库 |
|---|---|---|
| `image/*` | `generate_thumbnail`(PR #57) | Pillow 1024px → JPEG q=80 |
| `video/*` | `generate_video_thumbnail`(PR #102 / issue #101) | ffmpeg `-ss 1` 抽帧 → 1024px JPEG q=3 |

两者都存 `thumbnails/{aid}.jpg` + 写 `asset.tags.thumbnail_key`,前端 AssetThumbnail 零差异显示。

**视频缩略图 50MB cap pilot**:size > 50MB → `status=skip_too_large` 不进 ffmpeg(ROADMAP §63 风险段)。fail-soft:ffmpeg 超时 30s / 抽帧失败 → `asset.tags.thumbnail_failed='...'`,asset 仍可用。

### 4.2 backfill 老 asset 缩略图(image + video)

```bash
# 默认:只补缺缩略图的(image/video;video → generate_video_thumbnail)
docker exec ms-api python -m scripts.backfill_thumbnails
# --force:忽略已有 thumbnail_key 全部重生成(切 ms-thumbs 新 bucket 后存量图重生成,见 §10.4)
docker exec ms-api python -m scripts.backfill_thumbnails --force
```

行为:扫所有 `content_type=image/*` 或 `video/*` 且 `tags` 无 `thumbnail_key` 的 asset → enqueue;
`--force` 时无视已有 thumbnail_key 全部重新 enqueue。失败 / 缺 worker 时 log + 不阻塞。

> 视频 backfill 与图片合并进同一脚本(issue #101 checklist 剩条已并入,见 review fix PR)。

### 4.3 worker 日志

```bash
docker compose -f /root/material-storage-api/docker-compose.yml logs --tail=50 ms-worker
```

启动日志期望:`Starting worker for 4 functions: generate_thumbnail, generate_video_thumbnail, mark_expired_approvals, cron:mark_expired_approvals`(PR #102 起;若看到 `transcode_proxy` 说明跑的是旧 process,需 `docker compose restart ms-worker`)
成功:`0.21s ← <jobid>:generate_thumbnail ● {'status': 'ok', ...}`
失败:`failed asset=<id> err=...`(具体 traceback 在更早行)

### 4.4 cron 定时任务

每 5 分钟自动跑一次 `mark_expired_approvals`(把过期的 approved 申请 status → expired)。

---

## 5. 审计后台

### 5.1 UI 查

打开 https://rusheslab.taoxiplan.com/ms-static/web/admin/audit

权限:**任意 admin**(系统 admin 或任意 project admin)。

### 5.2 CSV 导出

UI 上"导出 CSV"按钮,或直接 curl:

```bash
curl 'https://rusheslab.taoxiplan.com/api/v1/admin/audit/export.csv?from=2026-05-01T00:00:00Z&to=2026-06-01T00:00:00Z' \
  -b 'ms_session=<your-jwt>' \
  -o audit-may.csv
```

最多 50000 行,UTF-8 BOM(Excel 直接打开)。

### 5.3 直接 SQL 查

```bash
docker exec ms-db psql -U msuser -d material_storage -c "
  SELECT event_time, event_type, actor_name_snapshot AS actor, details
  FROM audit_events
  WHERE event_type = 'access_denied' AND event_time > now() - interval '7 days'
  ORDER BY event_time DESC LIMIT 50;
"
```

---

## 6. 排查 cheat sheet

### 6.1 业务挂了 → 外网 502/403

最常见:容器 `force-recreate` 后 IP 漂移,`poc-nginx` upstream DNS 缓存 stale。

```bash
# 一键修
ssh root@8.156.34.238 'docker restart poc-nginx'

# 验证
curl -s -o /dev/null -w "%{http_code}\n" https://rusheslab.taoxiplan.com/healthz
# 应返 200
```

### 6.1.5 forensic — 拿 ms-api 上一轮日志(PR #95 起)

`docker compose up -d --build` recreate ms-api 会丢旧 logs(`docker logs ms-api` 只剩本次启动后的几行)。deploy 脚本 step 3.5 自动备份到 server2 `/tmp/ms-api-{ts}.log`:

```bash
ssh root@8.156.34.238 'ls -lt /tmp/ms-api-*.log | head -5'
# 选要看的 timestamp
ssh root@8.156.34.238 'tail -200 /tmp/ms-api-20260518-160000.log | grep -i error'
```

`/tmp` 重启会丢,但 deploy 间隔够短,排查 bug 时基本能拿到上一轮窗口。

### 6.2 ms-api 启动失败 ImportError

可能 rsync 路径错把 `models/__init__.py` 覆盖到 `app/__init__.py`(都叫 `__init__.py`)。
确保 rsync 时**带完整路径**:

```bash
# ❌ 错(会把多个 __init__.py 平铺到 app/)
rsync -avz app/models/__init__.py app/main.py root@...:/root/material-storage-api/app/

# ✅ 对(分批)
rsync -avz app/main.py root@...:/root/material-storage-api/app/
rsync -avz app/models/__init__.py root@...:/root/material-storage-api/app/models/

# 或用 staging
rsync -avz app/main.py app/models/__init__.py root@...:/tmp/_b/
ssh root@... 'cp /tmp/_b/main.py /root/material-storage-api/app/ && cp /tmp/_b/__init__.py /root/material-storage-api/app/models/'
```

修复:从本地 rsync 正确的 `app/__init__.py` 回去(只有 `__version__`),再 `docker restart ms-api`。

### 6.3 飞书 IM 卡片不发(代码层 best-effort,不阻塞业务)

```bash
# 验 token + 注册的 handler
curl -s 'https://rusheslab.taoxiplan.com/api/v1/admin/feishu/health' \
  -b 'ms_session=<jwt>' | python3 -m json.tool

# 推一张测试卡到自己
curl -X POST 'https://rusheslab.taoxiplan.com/api/v1/admin/feishu/test-card' \
  -H 'Content-Type: application/json' \
  -b 'ms_session=<jwt>' \
  -d '{"template":"approval"}'
```

常见错误:
- `230006 Bot ability is not activated` → 飞书后台启用机器人能力
- `99991672 Access denied … im:message:send_as_bot` → 飞书后台申请权限
- `99992351 invalid open_id` → 用户没在飞书企业内 / open_id 错

### 6.4 OpenFGA tuple 重复 / 不存在错误

`grant_explicit_download` 已自动 delete-then-write 处理重复。其他 grant 如遇 `tuple already existed`:

```bash
# 手动清某 user 全部 tuple(慎用 — 等同离职闭环)
docker exec ms-api python -c "
import asyncio
from app.services.permissions import create_permissions_service
from app.settings import get_settings
async def main():
    p = await create_permissions_service(get_settings())
    n = await p.revoke_user_completely('ou_xxxxxxxxxxxx')
    print('revoked', n)
asyncio.run(main())
"
```

### 6.5 pytest 跑不动 / 数 重复

```bash
# 清干净 + 重 cp
ssh root@8.156.34.238 'docker exec ms-api rm -rf /app/tests && docker cp /root/material-storage-api/tests ms-api:/app/tests && docker cp /root/material-storage-api/pyproject.toml ms-api:/app/pyproject.toml && docker exec ms-api pip install -q pytest pytest-asyncio && docker exec ms-api python -m pytest tests/ -q'
```

`force-recreate` 后 dev 依赖(pytest)需重装。

### 6.6 deploy_lan.sh「卡住不动」— 多半已经部署完了(2026-09-03 实录)

**症状**:脚本长时间无输出、本地任务不退出。当天两次都是这个样子,而远端实际
**早就同步 + 重启完毕**。

**根因(两层叠加)**:

1. `ssh_r()` 的 `ConnectTimeout=8` 只管**建连阶段**。内网反向隧道(经跳板中转)
   会在**建连之后**周期性断流,ssh 没配 `ServerAliveInterval`,session 死了也
   不报错,就永远挂着 —— 通常挂在脚本最后一步 `cat DEPLOYED.md` 的回显上,
   而真实工作(同步 / 版本记录 / restart)早已完成。
2. 若外层再套 `| grep` 过滤输出,管道会缓冲到结束才吐字 —— 脚本明明在正常跑
   也看起来像死了。**跑部署脚本不要套 grep 管道**。

**诊断口诀:不信本地任务状态,直接探远端事实源**:

```bash
ssh hh2 'grep -A1 "git commit" /home/msdev/ms/DEPLOYED.md | head -2; \
         cd /home/msdev/ms/api && docker compose ps --format "{{.Name}}\t{{.Status}}"'
# DEPLOYED.md 已是新 hash + 容器已重启 = 部署完成,挂的只是收尾回显;
# 本地杀掉僵住的任务/ssh 即可,远端不用动。之后补做脚本范围外的 SPA tar 同步。
```

**待办根修**:`ssh_r()` 加 `-o ServerAliveInterval=15 -o ServerAliveCountMax=3`,
让建连后的断流在 ~45s 内显式失败并走既有重试,而不是无限挂起(尚未落地)。

**MCP 渠道与 tar 流断流(2026-10-31 补)**:

- MCP(ms-mcp)**不能套用「deploy_lan --restart 一步到位」**:必须 `deploy_lan.sh <env>`
  (不带 `--restart`)→ `alembic upgrade head` → restart api/worker → `up -d --build ms-mcp`
  → nginx reload。完整顺序与回滚见 §12.5 / §12.9。
- deploy_lan 的 **tar 流式同步**在跳板隧道上实测会在 **~800KB 处中途断流**(与本节
  「回显挂起」不是一回事):先按仓库根 `.agents/skills/deploy-hh2/SKILL.md` §3「坑 B」
  用远端暂存目录 `du -sk` 两次采样判死,确认死了直接走 §4 的 scp 分片通道
  (`.agents/skills/deploy-hh2/scripts/chunked-push.sh`,每片 ≤512KB + 远端 md5;
  prod 按 skill §4 把脚本内 `HOST=hh2` 改为 `hh2-prod`),**不要再重试整脚本**。
  历史实录见仓库根 `scripts/changelog.md` 2026-10-27(「tar 流又在 ~824KB 断流」)及
  2026-10-26 / 2026-10-22 同类条目。

---

## 7. 数据库 / OpenFGA 重置(灾后或开发期清理)

### 7.1 重置 OpenFGA store(常用 — 模型升级时)

```bash
# 删旧 store
ssh root@8.156.34.238 'echo y | docker run --rm -i --network poc-pigsty-minio_poc-net \
  openfga/cli:latest store delete --api-url http://poc-openfga:8080 --store-id <STORE_ID>'

# 推 model-only yaml(本地准备 store-model-only.fga.yaml)
scp store-model-only.fga.yaml root@8.156.34.238:/tmp/
ssh root@8.156.34.238 'docker run --rm --network poc-pigsty-minio_poc-net -v /tmp:/data \
  openfga/cli:latest store import --api-url http://poc-openfga:8080 --file /data/store-model-only.fga.yaml'
# 返回 {"store":{"id":"<NEW>"}, "model":{"authorization_model_id":"<MODEL>"}}

# 更 .env
ssh root@8.156.34.238 "sed -i 's/^OPENFGA_STORE_ID=.*/OPENFGA_STORE_ID=<NEW>/' /root/material-storage-api/.env"

# force-recreate ms-api
ssh root@8.156.34.238 'cd /root/material-storage-api && docker compose up -d --force-recreate ms-api'

# 重跑 seed(项目/folder/asset/tuples)+ 通讯录同步
docker exec ms-api python -m scripts.seed_demo_data
docker exec ms-api python -m scripts.sync_feishu_contacts
docker exec ms-api python -m scripts.grant_org_admin ou_<你的 open_id>   # 重设系统 admin
```

### 7.2 重置 PostgreSQL 表(更激进)

```bash
docker exec ms-db psql -U msuser -d material_storage -c "
  TRUNCATE TABLE assets, folders, projects, approvals CASCADE;
  TRUNCATE TABLE audit_events;
"
# users / organizations 保留;再跑 seed
```

### 7.3 重置 MinIO bucket(更激进 — 删全部文件)

```bash
docker exec poc-pigsty-minio mc rm --recursive --force --dangerous local/ms-dev
docker exec poc-pigsty-minio mc mb local/ms-dev
```

---

## 8. 关键配置 / 服务器清单

### 8.1 域名 / 反代

- **域名**:`rusheslab.taoxiplan.com`
- **server1**(47.109.30.236):Caddy + 域名 → 反代 server2:80
- **server2**(8.156.34.238):
  - `poc-nginx`(80 端口)→ 反代:
    - `/api/v1/*` → `ms-api:8000`
    - `/ms-static/web/*` → `ms-api:8000/static/web/`
    - `/ms-dev/*` → `poc-pigsty-minio:9000/ms-dev/`(MinIO 文件直传/直下)

### 8.2 飞书 app

- `cli_aa8dbee01fb99bb3`
- redirect_uri:`https://rusheslab.taoxiplan.com/api/v1/auth/callback`
- 事件 webhook:`https://rusheslab.taoxiplan.com/api/v1/webhooks/feishu`
- 卡片回调:同上
- web H5 入口:`https://rusheslab.taoxiplan.com/ms-static/web/`

### 8.3 default organization

- DB id:`00000000-0000-0000-0000-0000000000a1`
- 飞书 tenant_key:`dev_tenant_001`(冷启动 seed 用,生产替为真 tenant_key)
- `.env`: `DEFAULT_ORGANIZATION_ID=00000000-0000-0000-0000-0000000000a1`

### 8.4 OpenFGA

- store_id:见 `/root/material-storage-api/.env` `OPENFGA_STORE_ID`
- 当前 model v4(`material-storage/poc/openfga/store.fga.yaml`)
- Playground UI(本地 SSH tunnel):`ssh -L 3001:127.0.0.1:3001 root@8.156.34.238` → http://localhost:3001/playground

### 8.5 MinIO

- bucket:`ms-dev`(PoC 全部 project 共用,通过 key prefix 区分)
- 缩略图:`thumbnails/{asset_id}.jpg`
- 凭证:`MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` in `.env`
- 控制台:`https://rusheslab.taoxiplan.com:9001`(或 host:9001 内网)

### 8.6 .env 关键字段

```
DB_URL=postgresql+asyncpg://msuser:mspass@ms-db:5432/material_storage
REDIS_URL=redis://ms-redis:6379/0
MINIO_ENDPOINT_INTERNAL=http://poc-pigsty-minio:9000
MINIO_ENDPOINT_PUBLIC=https://rusheslab.taoxiplan.com
OPENFGA_API_URL=http://poc-openfga:8080
OPENFGA_STORE_ID=01KRRR86H5HDM0KP0ZKBZC19TN
FEISHU_APP_ID=cli_aa8dbee01fb99bb3
FEISHU_APP_SECRET=<secret>
FEISHU_VERIFICATION_TOKEN=<token>
FEISHU_IM_ENABLED=true
WEB_APP_BASE_URL=https://rusheslab.taoxiplan.com/ms-static/web/
DEFAULT_ORGANIZATION_ID=00000000-0000-0000-0000-0000000000a1
```

---

## 9. 紧急联系流程

1. **业务挂了**(外网 502 / 500)
   - 第一步:`ssh root@8.156.34.238 'docker restart poc-nginx'`(80% 概率好)
   - 第二步:看 `docker compose logs --tail=30 ms-api`,粘报错给开发
2. **某 user 抱怨"看不到 project"**
   - 确认登录的飞书账号(让发 open_id)
   - SQL 查 `users.is_active`;若 false → 检查最近离职事件(audit `users.deleted_v3`)
   - OpenFGA check:`docker exec ms-api python -c "...permissions.check(...)"`(或 Playground)
3. **某 user 抱怨"应该是 admin 但操作 403"**
   - 检查是不是要求**系统** admin(只 1 人):`grant_org_admin --list`
   - 检查项目级 admin:打开 web ProjectMembersDrawer 看是否在列
4. **删错 user / 误撤销**
   - 飞书 user 撤销 tuple 是可逆的 — 重新建项目/邀请即恢复
   - DB `users.is_active=false` 是逻辑删,飞书重新发事件(任意操作)会重 upsert

---

## 10. 内网生产部署(2026-08-09 / issue #152 / ADR-0008)

> 生产形态:局域网单机部署,**可完全离线运行**(egress 有无待定,不依赖公网服务)。
> 依赖 repo 内文件:`api/.env.production.example`(env 模板)、`api/scripts/backup_prod.sh`(备份)、
> 本手册 §10 各小节。

### 10.1 拓扑与存储分层(P0:卷放置)

```
内网用户浏览器 → nginx(80,host 端口)→ 业务容器(docker 网络 poc-pigsty-minio_poc-net)
                                        ├─ ms-api(8000)    ├─ ms-worker
                                        ├─ ms-db(PG16)     ├─ ms-redis
                                        ├─ poc-pigsty-minio(原片 + 缩略图历史)→ /data(HDD)
                                        ├─ poc-minio-thumbs(缩略图)→ /ssd(SSD)
                                        ├─ poc-openfga(+ 其 PG)→ /ssd
                                        └─ poc-nginx(80 对外入口)
```

卷布局(ADR-0008 P0,compose 插值变量,写在各 compose 同目录 `.env`):

| 数据 | 介质 | 变量(compose 插值) | 说明 |
| --- | --- | --- | --- |
| OS / docker root / 镜像 / 日志 | SSD `/ssd` | — | 系统盘本身就在 SSD |
| PG 元数据(ms-db-data) | SSD | `MS_PG_DATA_DIR=/ssd/pg` | api/docker-compose.yml |
| Redis | SSD | `MS_REDIS_DATA_DIR=/ssd/redis` | api/docker-compose.yml |
| 缩略图(ms-thumbs bucket) | SSD | `MINIO_THUMBS_DATA_DIR=/ssd/minio-thumbs` | poc/minio/docker-compose.yml |
| 原片(ms-dev bucket) | HDD | `MINIO_DATA_DIR=/data/minio-originals` | poc/minio/docker-compose.yml |
| 备份镜像挂载点 | 外部盘/异地 | `MINIO_BACKUP_DIR=/mnt/backup` | poc/minio/docker-compose.yml,见 §10.4 |

compose 默认值均保留本地 dev 行为(named volume / `./data`),**只设了上面的变量才会变 bind mount**。
注意:两个 compose 各自读自己目录的 `.env` —— `api/.env` 和 `poc/minio/.env` 都要维护。

### 10.2 内网访问方案(nginx / hosts)

- 生产无域名/证书 → **全站 http**,`SESSION_COOKIE_SECURE=false`(见模板)。
- 浏览器访问统一走**一个内网地址**(IP 或 hosts 名),例如 `http://192.168.1.10/ms-static/web/`。
- **P-10 坑(关键)**:S3v4 签名 host 必须与浏览器实际访问 host 一致 ——
  `MINIO_ENDPOINT_PUBLIC` / `MINIO_THUMBNAIL_ENDPOINT_PUBLIC` / `WEB_APP_BASE_URL`
  全部填**同一个内网地址**(`http://<LAN-HOST>`,不带路径)。内外双入口单值配置不支持。
- 用户机器的 hosts 建议统一加一行(免记 IP):
  `192.168.1.10  ms.local` → 浏览器访问 `http://ms.local/ms-static/web/`;所有 URL 模板跟着填 `http://ms.local`。
- nginx 路由(`poc/minio/nginx/default.conf`)已内置:
  - `/api/v1/*`、`/ms-static/*` → ms-api
  - `/ms-dev/*` → 原片 MinIO(HDD)
  - `/ms-thumbs/*` → 缩略图 MinIO(SSD)
- 安全组/防火墙只开 22 + 80 即可。

### 10.3 env 清单与 bootstrap

1. 全新机器 bootstrap 顺序:
   ```bash
   # 0) 准备磁盘
   mkfs.ext4 /dev/<ssd> && mount /dev/<ssd> /ssd && mkdir -p /ssd/pg /ssd/redis /ssd/minio-thumbs
   mkfs.ext4 /dev/<hdd> && mount /dev/<hdd> /data && mkdir -p /data/minio-originals
   # 1) 部署代码(机器有 egress 时直接 git clone;无 egress 用 U 盘/内网 git 导入)
   git clone git@kevinfitzroy.github.com:kevinfitzroy/rushes-lab.git   # 实际走 SSH alias
   cd rushes-lab/material-storage
   # 2) 配 env:api 与 poc/minio 各一份(模板见 api/.env.production.example)
   cp api/.env.production.example api/.env && vim api/.env
   cp api/.env.production.example poc/minio/.env   # 只保留 MINIO_* 那组插值变量
   # 3) 起栈
   cd poc/minio && docker compose up -d
   cd ../api  && docker compose up -d
   docker compose exec api alembic upgrade head
   # 4) 数据初始化(视部署阶段):dev_bootstrap / seed_demo_data / 飞书通讯录同步(过渡期)
   docker compose exec api python -m scripts.dev_bootstrap
   # 5) 验证(§10.4)
   ```
   > MCP 素材服务(ms-mcp)不在上述 bootstrap 内:部署/回滚见 §12(硬顺序 =
   > 先迁移、后 restart api/worker、再 `up -d --build ms-mcp`、最后 nginx reload)。
2. 环境变量三处一致性自检(§10.2 P-10):
   `MINIO_ENDPOINT_PUBLIC == MINIO_THUMBNAIL_ENDPOINT_PUBLIC == WEB_APP_BASE_URL 的 host`。
3. MinIO root 凭据(两个实例)与 `MINIO_ACCESS_KEY / MINIO_SECRET_KEY` **必须一致**:
   `MINIO_ROOT_USER == MINIO_THUMBS_ROOT_USER == MINIO_ACCESS_KEY`(secret 同理)。

### 10.4 存储分层验证(P1 验收)

```bash
# 1. 上传一张图片,等 worker 生成缩略图(ms-worker 日志见 §4)
docker compose -f /root/material-storage-api/docker-compose.yml logs --tail=20 ms-worker
# 2. 验证缩略图落 SSD bucket(ms-thumbs),原片落 HDD bucket(ms-dev)
docker exec poc-minio-thumbs mc find local --path thumbnails/ | head -3      # SSD 实例
docker exec poc-pigsty-minio mc find local --path thumbnails/ | head -3      # 应为空或只剩历史
docker exec poc-pigsty-minio mc find local --path ./ | head -5               # 原片在 HDD 实例
# 3. 磁盘落点复核
du -sh /ssd/minio-thumbs /data/minio-originals
# 4. 前端 AssetThumbnail 正常出图(缩略图 URL 走 /ms-thumbs/ 路径)
```

> 存量升级(老部署的缩略图在 `ms-dev/thumbnails/`):过渡期在 `.env` 设
> `MINIO_THUMBNAIL_BUCKET=ms-dev` 保持旧图可见;正式切 `ms-thumbs` 前必须跑
> `docker compose exec ms-api python -m scripts.backfill_thumbnails --force` 重新生成到新 bucket
> (**必须 `--force`** —— 存量 asset 已有 `thumbnail_key`,普通 backfill 会全部 skip 成 no-op;
> `--force` 同时覆盖 image 与 video 缩略图)。

### 10.5 备份(脚本 + cron)

`api/scripts/backup_prod.sh` 在**生产服务器**上跑(docker 访问):
- **pg_dump(SSD 侧,高频,建议每日)**:PG 全量 `--no-owner` → gzip → `${COMPOSE_DIR}/backups/pg/`,
  保留 7 天自动清理。
- **mc mirror(HDD 原片,低频,建议每周)**:`mc mirror local/ms-dev → 容器内 /backup-mirror/ms-dev`
  (= host 外部盘/异地挂载点 `MINIO_BACKUP_DIR`,见 §10.1)。
- **⚠️ 缩略图(ms-thumbs bucket)不在备份路径内**(ADR-0008 分层后它在独立实例/独立 bucket):
  缩略图可从原片重生成,不算数据丢失 —— 丢了/坏了靠 §10.4 的 `backfill_thumbnails --force` 重建,
  不要为它加 mirror。凭据经 `MC_HOST_*` env 注入(脚本内),host 上 ps 不可见。

cron 示例(root):
```cron
# 每日 03:00 pg_dump;每周日 03:30 原片 mirror
0 3 * * *   cd /root/material-storage-api && bash scripts/backup_prod.sh        >> /var/log/ms-backup.log 2>&1
30 3 * * 0  cd /root/material-storage-api && bash scripts/backup_prod.sh --mirror >> /var/log/ms-backup.log 2>&1
```

**恢复演练(建议每季度做一次,记录到本手册/issue)**:
```bash
# a) PG 恢复(空库演练)
docker compose exec -T ms-db psql -U msuser -d postgres -c 'CREATE DATABASE material_storage_restore'
gunzip -c backups/pg/material-storage-<TS>.sql.gz | \
  docker compose exec -T ms-db psql -U msuser -d material_storage_restore
#    验证行数:psql -c 'SELECT count(*) FROM assets' 与原库对比
# b) 原片恢复(mc mirror 反向)
docker exec poc-pigsty-minio mc alias set restore-src http://127.0.0.1:9000 "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY"
docker exec poc-pigsty-minio mc mirror /backup-mirror/ms-dev restore-src/ms-dev
```
> 演练注意:先在独立 db 名演练;**不要覆盖生产库**;mc mirror 反向目标用临时 bucket 验证。

### 10.6 降级开关(缩略图故障 / bucket 溢出)

ADR-0008 决策:缩略图 MinIO 故障或 `ms-thumbs` 溢出时,**指回原片 bucket 即回滚,无需数据迁移**:

```bash
# api/.env 改成:
MINIO_THUMBNAIL_BUCKET=ms-dev
# MINIO_THUMBNAIL_ENDPOINT_INTERNAL=   ← 清掉(回落主实例)
# MINIO_THUMBNAIL_ENDPOINT_PUBLIC=     ← 清掉(回落主实例)
cd /root/material-storage-api && docker compose up -d --force-recreate ms-api ms-worker
```
> 注意:`docker restart` 不重读 env_file;改 .env 必须 `--force-recreate`。
> 降级后新缩略图落 HDD 原片 bucket;恢复后重新 backfill 回 SSD 即可。

### 10.7 secret 卫生与轮换

**MinIO root 密码(rotate before prod)**:仓库 compose 默认值是 PoC/dev 专用,生产必须换。
```bash
# 1. 生成新值(SSD 机器上)
NEW=$(openssl rand -hex 16)
# 2. 同时改三处:api/.env(MINIO_ACCESS_KEY/MINIO_SECRET_KEY)、
#    poc/minio/.env(MINIO_ROOT_USER/PASSWORD + MINIO_THUMBS_ROOT_USER/PASSWORD)
# 3. force-recreate:两个 MinIO + ms-api + ms-worker
cd poc/minio && docker compose up -d --force-recreate
cd ../api    && docker compose up -d --force-recreate ms-api ms-worker
# 4. 验证:s3 直连用新凭据 head bucket 成功
```

**飞书 app(过渡期仍用飞书登录)**:老 PoC app(`cli_aa8c58fae5391be7`)的 secret 曾
**泄露在 git history**(旧 deploy heredoc,#152 已清换占位符)→ 到飞书后台**注销该 app**
(线上用的是 `cli_aa8dbee01fb99bb3`,secret 只在本地 server.md,未泄露)。
`#154 cutover` 后整个飞书应用直接注销,本节不再需要。

### 10.8 监控(最低配)

- SSD 水位:`df -h /ssd`—— 缩略图桶接近 2TB SSD 的 80% 时报警(ADR-0008)。
- PG 备份产物大小/时间:`ls -lt backups/pg/ | head`,cron 日志 `/var/log/ms-backup.log`。
- 健康检查:`curl http://127.0.0.1/api/v1/healthz`(经 poc-nginx)。

---

## 11. W2a:审计真实 IP 落地(2026-10-17 方案定稿,配置激活待部署窗口)

> **执行版 runbook** = `w2a-realip-activation-runbook.md`(可打印照抄,含勾选清单/实测记录表,
> 内容与本节同源;内容漂移时以本节为准并同步该文件)。
> 来源:`admin-audit-folder-mobile-optimization-plan.md` §2(13 轮盲审定稿);
> 决策点 16 / 17:原拍 a(裸隧道收敛关闭 18080/8080),**2026-10-19 用户改拍 b(对内服务,
> 保留两端口公网访问:改经跳板机 nginx 反代 + XFF,对外 URL 不变,详见 §11.4)**。
> **2026-10-17 本轮交付物 = 本节文档**:仓库内 `poc/minio/nginx/default.conf` 与跳板机 conf
> 均未改动(防止 routine 部署把 ② 先于跳板机 ① 推上线,打开伪造窗口)。① ③ 为远端机器人工
> 步骤,② 为仓库 conf 变更 + 既有部署流程;激活时机 = 部署窗口,须按 §11.5 硬顺序执行。

### 11.1 根因与目标(方案 §2.1 摘要)

外网链路:`浏览器 → 跳板机 nginx:443(TLS 终结)→ 反向隧道 18080 → hh2:80 → poc-nginx 容器 → ms-api:8000`

1. **跳板机 nginx**(`/etc/nginx/conf.d/bucket-taoxiplan.conf`,2026-10-10 changelog 方案 B
   落地,仓库无留存):已知指令里没有 X-Forwarded-For(nginx 默认不追加),真实客户端 IP
   从第一跳就丢;
2. **隧道跳**:纯 TCP 转发,头不丢不改。注意分层事实:hh2 **宿主**眼里隧道流量源恒为
   `127.0.0.1`(public-fallback-entry.md:301),但 loopback 目标不走 DNAT、由 docker-proxy
   用户态代理转投容器 → **poc-nginx 容器看到的源 IP 是 poc-net 网桥网关(推演 ≈172.20.0.1,
   以 ⓪ 实测为准)**;内网直连走 DNAT,容器看到真实 192.168.x —— 这一跳的实测值决定
   §11.5 ② 的信任源;
3. **poc-nginx**(conf 即仓库 `poc/minio/nginx/default.conf`):`/api/v1/` 等 ms-api location
   设了 `Host $http_host` / `X-Real-IP $remote_addr` / `X-Forwarded-Proto $xfp`,
   **唯独没设 X-Forwarded-For**(uvicorn 不消费 X-Real-IP);
4. **ms-api uvicorn**(`api/Dockerfile`):`--proxy-headers --forwarded-allow-ips '*'` ——
   有 XFF 用 XFF 还原 client,没有就保持 TCP 对端地址 → 审计 `request_ip` 恒为 poc-nginx
   容器 IP(审计里清一色 172.20.0.7 的现象);
5. 内网直连(192.168.110.221:80)与外网隧道两条路在 ms-api 眼里完全一样。

**连带事故(两条)**:① 登录限流 per-IP 维度对公网入口**全员共享一个桶**——任一用户连错
5 次,全入口锁 15 分钟;② **现状基线审计 IP 本就可伪造**——`/api/v1/` 块不覆写 XFF 且
uvicorn 信任 `'*'`,任何入口的客户端自带 XFF 头都会原样穿透进 `request.client`。
本方案是收敛伪造面(修复项②给验收提供前后对照),不是引入新风险。

### 11.2 ⓪ 前置实测(实施第一步,决定 ② 的信任源)

上机看 access log 的 `$remote_addr`,公网 443 / 公网 18080 / 内网直连三个入口各打一发对比;
**dev 环境同款测一遍**(poc-nginx-dev,入口 = 内网 :8090 / 外网 :8080,dev 隧道
`-R 0.0.0.0:8080:127.0.0.1:8090`,runbook:106-108):

```bash
# 网络名核实(仓库声明 vs 实际,以实测为准):仓库声明名 = poc-pigsty-minio_poc-net
# (api compose 的 external 网络),poc compose 侧默认 = <project>_poc-net
ssh hh2 'docker network ls | grep poc-net'
ssh hh2 'docker inspect poc-nginx --format "{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}} => gw {{\$v.Gateway}}{{end}}"'
ssh hh2 'docker inspect poc-nginx-dev --format "{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}} => gw {{\$v.Gateway}}{{end}}"'

# 三入口各打一发,同时盯容器日志(nginx 官方镜像 access log 走 stdout;prod、dev 各盯一个)
ssh hh2 'docker logs -f poc-nginx --tail=0'
ssh hh2 'docker logs -f poc-nginx-dev --tail=0'

curl -s -o /dev/null https://bucket.taoxiplan.com/ms-healthz     # prod 443 隧道(未切域名时用 https://47.108.196.211/)
curl -s -o /dev/null http://47.108.196.211:18080/ms-healthz      # prod 18080 裸隧道(③ 后=经反代,URL 不变)
curl -s -o /dev/null http://192.168.110.221/ms-healthz           # prod 内网直连
curl -s -o /dev/null http://192.168.110.221:8090/ms-healthz      # dev 内网
curl -s -o /dev/null http://47.108.196.211:8080/ms-healthz       # dev 外网裸隧道
```

按部署链路推演:各环境隧道入口都应显示该环境网桥的网关(prod ≈172.20.0.1;dev 网桥预期
独立网关,但**两环境是否共享网络一跳即证** —— 上面 `docker network ls` + `inspect` 输出),
内网直连显示真实 192.168.x。**以实测值为准**:§11.5 片段中的网关 IP 均为推演占位,
实测三行结果回填 §11.7。

### 11.3 ① 跳板机加 XFF(人工上机;conf 不在仓库)

现役跳板机 = **47.108.196.211**(阿里云轻量应用服务器,ssh 别名 `aliyun-swas`;
runbook:65 写的旧 IP 47.108.119.221 已失效,勿按它找机器)。

```bash
ssh aliyun-swas
cp /etc/nginx/conf.d/bucket-taoxiplan.conf /etc/nginx/conf.d/bucket-taoxiplan.conf.bak-$(date +%Y%m%d)
vi /etc/nginx/conf.d/bucket-taoxiplan.conf
#   在 proxy_pass 所在的 location(或 server)块内加一行:
#     proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
#   (真实公网 IP 进 XFF 链尾;Host $http_host / ws upgrade / 零缓冲等既有指令勿动)
nginx -t && systemctl reload nginx
```

该 conf 是 TLS 终结 + 单 proxy_pass 到隧道的独立配置(2026-10-10 方案 B),**不是** hh2
default.conf 的路由镜像(2026-10-10 曾在 hh2 侧短暂落过「default.conf 镜像 443 vhost」
同日已回退,勿混淆);上机时以实际文件内容为准核验。

**conf 备份双保险**(conf 本身不进版本控制):
1. 改完把最终 conf 拷回**仓库根** `scripts/env/`(与 changelog 同级的根 `scripts/`;
   注意 material-storage/scripts/ 是另一处)。该目录是既有机器本地密钥目录,受
   `scripts/.gitignore` 的 `env/` 规则保护、git 不追踪 —— worktree / 新 clone 里看不到属
   正常现象,真实机器上存在;落盘后 `git status` 复核一次未进暂存即可;
2. **灾备对照 = 本节指令摘要**(机器丢失后按上述步骤可重建;conf 做结构性大改时另记
   sha256 + 日期)。

### 11.4 ③ 公网 :18080/:8080 改经跳板机 nginx 反代(决策 16/17=b;先于 ② reload)

**为什么必须做**:② 生效后,poc-nginx 会信任隧道流量来源并采信 XFF 链尾——若 18080/8080
仍是**裸隧道直通**(链路上没有代理追加真实 IP),客户端自带 `X-Forwarded-For: 1.2.3.4`
就直接变成 `$remote_addr`:审计 IP 可任意伪造,且每换一个伪造 IP 拿到一个全新 per-IP
限流桶。**处置(2026-10-19 用户改拍 b:对内服务,保留两端口公网访问)**:两条隧道各后移
一个回环端口(prod 18080→`127.0.0.1:18081`、dev 8080→`127.0.0.1:8081`;`+1` 是为给
nginx 腾出公网监听位,同端口双绑不可靠),跳板机 nginx 在原公网端口新增两个反代 vhost
并追加 XFF——**对外 URL 与端口完全不变**,两入口与 443 同信任(真实 IP 进链尾,客户端
伪造值被顶到链首不被采信)。绑定地址由 hh2 侧 ssh 客户端决定,**服务文件在 hh2 的
`/home/msdev/.config/systemd/user/jump-tunnel.service`,不是去跳板机上改**。

**中断窗口**:公网 :18080/:8080 从隧道改绑生效到 vhost reload 完成**中断约 1-2 分钟**
(3a 与 3b 的间隙);443 与内网入口全程不受影响。180s 定时器护底:vhost 失败自动还原直通。
完整可照抄命令(3a 隧道后移+定时器 / 3b 跳板机 `ms-port-proxy.conf` 两个 vhost(指令镜像
443 vhost:Host $http_host/零缓冲/3600s/ws upgrade) / 3c 验证+取消定时器)见执行版
runbook §3,此处不重复;要点三条:

1. sed 目标改为 `-R 127.0.0.1:18081:127.0.0.1:80` 与 `-R 127.0.0.1:8081:127.0.0.1:8090`
   (12222 运维通道勿动);
2. vhost 反代指向 `127.0.0.1:18081` / `127.0.0.1:8081`,`proxy_set_header X-Forwarded-For
   $proxy_add_x_forwarded_for;` 是伪造面封死的关键,Host/XFP/零缓冲镜像 443 vhost;
3. 验证=公网两端口经反代恢复 200(对外行为不变)+ `ss -tlnp` 监听形态(公网位=nginx、
   回环位=sshd)+ 内网回归,**然后立刻取消 180s tunnel-rollback 定时器**(不取消=改绑被
   静默还原、公网端口回到裸隧道直通=伪造面回来)。

失败处理:什么都不用做,180 秒后定时器自动还原直通隧道(公网端口恢复旧行为,伪造面回到
现状基线=修复未完成的原始状态,不是新风险);事后 `journalctl --user -u jump-tunnel` 与
跳板机 `nginx -t` 查因。

### 11.5 ② poc-nginx default.conf 变更(仓库文件;硬顺序最后一步)

> default.conf 全仓唯一、经 `deploy_lan.sh` rsync --inplace 同步到 dev/prod 两个 checkout
> (内容一致,bind mount 生效),信任源写哪些环境的网关见片段内说明。
> **2026-10-17 本轮未动仓库 conf,以下为部署窗口期的完整变更片段。**

**变更一:server 块顶部(顶部 `map $http_x_forwarded_proto $xfp` 之后)加 realip 组**:

```nginx
    # ─── W2a 真实 IP:还原隧道流量真实客户端 IP(2026-10-17)──────────────────
    # 信任源 = ⓪ 实测的隧道流量源 IP(= 各环境 poc-net 网桥网关;下方为示例占位)。
    # 宿主 jump-tunnel 连 127.0.0.1:80 的 loopback 目标不走 DNAT、由 docker-proxy
    # 转投容器,容器看到的源 IP 是网关 —— 「信任 127.0.0.1」在容器层不成立,
    # 勿照抄宿主层口径(public-fallback-entry.md「阶段 4」旧片段)。
    # **只信网关单 IP,勿放宽到整个网段**:同网段其他容器直连 nginx:80 即可伪造。
    # real_ip_recursive 默认 off = 取 XFF 链最后一个地址,
    # 即跳板机 $proxy_add_x_forwarded_for 追加在链尾的真实客户端 IP。
    set_real_ip_from 172.20.0.1;    # prod 网桥网关(⓪ 实测值,示例占位)
    set_real_ip_from 172.21.0.1;    # dev 网桥网关(⓪ 实测值,示例占位;两环境共享网桥时删此行)
    real_ip_header X-Forwarded-For;
```

**变更二:五个 ms-api location 各加一行**(其余 location 一律不动):

```nginx
        # W2a:覆写为已还原的真实 IP(单值,不追加;uvicorn --proxy-headers 消费)
        proxy_set_header X-Forwarded-For $remote_addr;
```

逐 location 落点(行号为 2026-10-16 快照,漂移按符号定位):

| location | 加法 |
|---|---|
| `location ^~ /api/v1/`(:22-34) | 加在 `proxy_set_header X-Forwarded-Proto $xfp;` 之后 |
| `location ^~ /ms-static/`(:35-40) | 同上(X-Forwarded-Proto 之后) |
| `location = /privacy`(:43-46) | 该块现无 proxy_set_header,proxy_pass 前直接加 |
| `location = /terms`(:47-50) | 同上 |
| `location = /ms-healthz`(:86-90) | 加在 `X-Forwarded-Proto $xfp;` 之后 |

**红线**:`$xfp` map 与 `Host $http_host` 语义勿回退(dynamic-presign 契约,
`tests/test_dynamic_presign_host.py` 有测试钉死)。`$remote_addr` 被还原后,既有
`X-Real-IP $remote_addr`(/ms-dev/、/ms-thumbs/ 的 MinIO 块)一并变真,无害,不需要动。

**效果**:隧道用户 → `$remote_addr` 还原为公网真实 IP;内网直连用户 → DNAT 保留源 IP,
其自带的伪造 XFF 因来源不在信任单 IP 内被忽略并覆写,无法冒充。uvicorn `--proxy-headers`
拿到单值 XFF,与版本取链首/链尾的语义无关,无歧义。

**部署硬顺序(防伪造窗口,方案 §2.2)**:

```
⓪ 实测(含 dev,§11.2)
 → ① 跳板机加 XFF(§11.3)
     ※ ② 的 prod reload 不得早于 ① 生效 —— 若 ② 先上而 ① 未上,443 流量的 XFF 链尾
       是客户端自带值而非跳板机追加值,realip 会采信伪造 IP
 → ③ 18080/8080 改绑(§11.4)
     ※ 先于 ② reload,缩短「realip 已采信网关流量链尾值但裸通道未封」的窗口
 → ② default.conf 改仓库 + deploy_lan.sh 同步(conf bind mount)
     + docker exec poc-nginx nginx -s reload(dev 侧 poc-nginx-dev 同款;既有流程)
 → reload 后立即经公网 18080/8080(反代后)打伪造 XFF 复核被拒(§11.6 验收 3)
```

### 11.6 验收(4 条,方案 §2.4)

1. ⓪ 实测记录各入口的容器层源 IP,回填 §11.7(443 隧道 / 18080 隧道 / 内网直连;dev 两行);
2. 修复后:公网 443 请求的审计 `request_ip` = 用户真实公网 IP;内网直连 = 真实内网 IP;
   不再出现 172.20.0.7;
3. 伪造用例:内网直连带伪造 `X-Forwarded-For` 头 → 审计 IP 仍为真实内网 IP(被覆写);
   经公网 :18080/:8080(③ 反代后)带伪造 XFF → 审计 IP = 真实公网 IP,伪造值被顶到链首不被采信(**② reload 后立即复核本条**);
4. 登录限流:两个不同公网 IP 各连错 5 次,互不影响(共享桶事故解除)。

### 11.7 实测记录(⓪ 产物,实施时回填)

| 入口 | 容器层源 IP(实测) | 预期 |
|---|---|---|
| prod 443 隧道 | _(待回填)_ | prod 网桥网关 |
| prod 18080(③ 前裸隧道/③ 后经反代) | _(待回填)_ | 同上(③ 后对外 URL 不变) |
| prod 内网直连 | _(待回填)_ | 真实 192.168.x |
| dev 内网 :8090 | _(待回填)_ | 真实 192.168.x |
| dev 外网 :8080(③ 前裸隧道/③ 后经反代) | _(待回填)_ | dev 网桥网关(③ 后对外 URL 不变) |

网络名实测结论(仓库声明 `poc-pigsty-minio_poc-net` vs `<project>_poc-net`、两环境是否共享网桥):_(待回填)_。

### 11.8 回滚(顺序 = 反向)

1. **先撤 ②**:还原 default.conf(摘除 §11.5 片段或 git revert)→ `deploy_lan.sh` 同步 →
   `docker exec poc-nginx nginx -s reload`(dev 侧 poc-nginx-dev 同);
2. **再撤 ①**:跳板机 `bucket-taoxiplan.conf` 去掉 X-Forwarded-For 行(bak 见 §11.3)→ reload;
3. ③ 的隧道改绑属通道收敛,一般不随本项回滚;确需恢复裸通道时按 runbook 隧道回滚流程把
   `-R 127.0.0.1:...` 改回 `-R 0.0.0.0:...` 并取消定时器(伪造面随之回来,须自知)。

回滚后审计 IP 回落为容器 IP(172.20.0.7 现象复现),登录限流共享桶问题一并回来 ——
**回滚是整体回退,不存在只回滚一半的安全态**。

### 11.9 口径与风险(方案 §2.3 全量)

- **历史数据无法回填**(真实 IP 从未被传输),只能「自某时刻起新事件为真实 IP」;
- `request_ip` 列 String(64),无需 migration;
- **信任面口径(容器层)**:宿主本机进程经 127.0.0.1:80 → docker-proxy → 网关源,同在信任
  单 IP 内(本机进程属可信面,可接受);poc-net 其他容器直连 nginx:80 的源是自身容器 IP,
  不在信任单 IP 内 —— 这正是「只信网关单 IP、勿放宽子网」的原因。边缘 hairpin 路径:
  poc-net 内容器经**宿主发布端口**(宿主 IP:80 / 127.0.0.1:80)进 nginx 时,源经
  docker-proxy/MASQUERADE 也表现为网关(受信),可携带伪造 XFF —— 与「uvicorn 收紧
  forwarded-allow-ips」的可选加固属同一信任边界(能落容器的攻击者本可直连 ms-api:8000),
  风险低,记录即可(方案决策点 5 = 暂不收紧,留加固 backlog);
- **网桥重建可能变更网关 IP**,环境重建后需复核 ⓪ 实测值(§11.7);
- **dev 退化依赖(决策点 17)**:若 ⓪ 实测两环境共享网桥(网关同 IP),conf 又是单文件双环境
  同步 → 「只写 prod 网关」的 b 选项**物理上不可行**(写 prod 网关即同时信任 dev 隧道)→
  **只能选 a**(双网关 + 双入口同款收敛)或整体缓行。**禁止**只加 dev 网关不收敛 :8080
  (半修 = dev 立即获得与 ③ 同款的伪造面);
- uvicorn `--forwarded-allow-ips '*'` 保持不动(入口已收敛在 poc-nginx,宿主侧 ms-api 只绑
  127.0.0.1:8200)。

### 11.10 落地后的文档标记(实施完做)

- 本节 §11.7 回填实测值,§11.6 验收 4 条打勾;
- `public-fallback-entry.md`「阶段 4:真实 IP 与登录限流」小节(:299 起)标记已落地
  (其 `set_real_ip_from 127.0.0.1` 是宿主层旧口径,已被本节容器层口径取代);
- ③(b) 落地后:`prod-public-entry-runbook.md` 的 18080 相关流程更新说明(通道实现变了:
  裸隧道直通 → 跳板机 `ms-port-proxy.conf` 反代,运维/排障入口随之变化);跳板机
  `ms-port-proxy.conf` 与 `bucket-taoxiplan.conf` 最终版备份到仓库根 `scripts/env/`
  并记 sha256+日期;防火墙 18080/8080 放行规则**保留**(b 方案端口继续对外)。

---

## 12. MCP 素材服务(ms-mcp)运维(2026-10-31)

> 方案正本:`docs/qdev/2026-10-30-mcp-service.md`(决策 D5/D9/D12/D14、部署节、「当前有效值」表);
> 服务实现说明:`material-storage/mcp/README.md`(env / 白名单 / dev override / 重启影响面)。
> 状态(2026-10-31):**dev 已部署**——hh2 `/home/msdev/ms`,代码 `99decab` + ms-mcp 增量修复
> `850cf07`,迁移 `0020` 已落,`ms-mcp-dev` healthy;部署记账的 SPA 指纹为 `index-BzFU94_b.js`。
> **prod 尚未部署**,按 §12.5 执行。ms-mcp 的部署/回滚不套用 §6.6 的「一键 `--restart`」。

### 12.1 入口与双入口

MCP 客户端地址 = `<入口>/mcp`(Streamable HTTP),请求头必须自带
`Authorization: Bearer mspat_...`。**不支持仅 OAuth 的托管 MCP 客户端**——本服务没有
`/.well-known/*` 元数据,OAuth 接入列二期。

| 形态 | 内网直达(主路径) | 公网(跳板机) |
|---|---|---|
| prod | `http://192.168.110.221/mcp`(hosts 名 `ms.local` 同理) | `https://bucket.taoxiplan.com/mcp`、`https://47.108.196.211/mcp`、`http://47.108.196.211:18080/mcp` |
| dev | `http://192.168.110.221:8090/mcp` | `http://47.108.196.211:8080/mcp` |

- 公网 443 / 18080 / 8080 都走跳板机 catch-all vhost → 反向隧道 → hh2 nginx,业务路由全在
  hh2 的 `poc/minio/nginx/default.conf`;**已核实无需改跳板机 conf**(2026-10-31)。
- hh2 nginx `location ^~ /mcp` 的要点:**变量 upstream**(`$mcp_upstream=http://ms-mcp:8000`,
  ms-mcp 未起时 nginx 仍能正常启动,静态写法会 `host not found in upstream` 起不来);
  `Host $http_host`(保端口)+ `X-Forwarded-Proto $xfp`(透传,勿用 `$scheme` 覆盖)+
  单值 `X-Forwarded-For $remote_addr`;SSE `proxy_read_timeout/proxy_send_timeout 1800s`;
  边缘 `limit_req zone=mcp_limit rate=15r/s burst=30`,超限 429。
- ms-mcp 只加入业务网络 `poc-net`、**不 publish 宿主端口**:只能经 nginx 到达
  (网内直连者可自带 XFF 伪造审计 IP)。改 nginx conf 必须提交仓库(dev/prod 共享的
  bind mount 单文件),同步后 `nginx -t` + `nginx -s reload`(见 §12.5 第 5 步)。
- **令牌**:用户在网页 `/settings` 自助签发 / 吊销(`mspat_` 前缀,明文只显示一次,
  默认 90 天,每用户 5 个活跃);管理员在 `/admin/mcp-settings` 查看并吊销全量令牌。
  改密或禁用用户会吊销该用户全部活跃令牌。

### 12.2 入口 Host 白名单(MS_MCP_ENTRY_ALLOWLIST)

格式 `host=scheme`、逗号分隔;请求 `Host` 与条目均 **lower() 后精确比较(端口算在内)**,
未命中直接 403、**不回落**。命中的 scheme 决定透传给 api 的 `X-Forwarded-Proto`
(客户端自报值冲突/缺失/非法时一律以条目为准)。

当前值(2026-10-31):

| 环境 | 条目 |
|---|---|
| prod(compose 默认值;目标机无 override 时生效) | `ms.local=http`、`192.168.110.221=http`、`192.168.110.221:80=http`、`47.108.196.211=https`、`47.108.196.211:443=https`、`47.108.196.211:18080=http`、`bucket.taoxiplan.com=https`、`bucket.taoxiplan.com:443=https`、`localhost=http`、`127.0.0.1=http`(10 条) |
| dev(目标机 override,不入库) | `192.168.110.221:8090=http`、`localhost:8090=http`、`127.0.0.1:8090=http`(3 条) |

维护要求:

1. **按实际可用入口全量枚举拼法**:裸 host、`:80`、`:443`、非标准端口
   (`:18080`/`:8080`/`:8090`)各算一种;**漏一种 = 该形态全量 403**。
2. **按环境裁剪**:dev 白名单不得放行 prod Host(反之亦然),否则跨环境签名零成本。
   dev 的 override 在目标机 `/home/msdev/ms/api/docker-compose.override.yml`,
   **不随 deploy_lan 同步**(deploy_lan 显式排除),改了只在目标机生效。
3. 条目 ≤14;去重后的 `scheme://host` 全集 ≤16(api 的动态 signer 缓存按
   `scheme://host` 计键、全进程与 web/app **共享并集**,打满后新入口回落静态
   `MINIO_ENDPOINT_PUBLIC`)。改完用 `docker compose config` 核对 `ms-mcp.environment`
   与条目数,再 `docker compose up -d ms-mcp` 重建容器(env 变更 `restart` 不生效)。
4. `MS_MCP_INTERNAL_BASE_URL` 必须命中白名单且 scheme 一致(ms-mcp 启动时校验):
   prod `http://192.168.110.221`,dev `http://192.168.110.221:8090`。
5. 若 `/admin/mcp-settings` 出现 `dynamic_signers_cap_hits > 0`,先核对 prod `.env`
   的 `MINIO_ENDPOINT_PUBLIC` 是否指向客户端可达入口(打满后新入口回落到它)。

### 12.3 启停、更新与重启影响面

- 容器:prod `ms-mcp`,dev `ms-mcp-dev`(独立 compose service,容器名由 override 覆盖)。
- **更新代码/依赖必须 build**:`docker compose up -d --build ms-mcp`;
  `docker compose restart ms-mcp` **不会重建镜像**(独立镜像,不走 api 的 build)。
- **重启 ms-mcp = 断所有 MCP 会话**:绑定表与 SDK 会话都在进程内存,单副本;
  会话上限 200、空闲 TTL 1800s。Web/App 无感,客户端重连会自动重新 initialize。
  运维择时,避开 AI 使用高峰。
- 启停/状态/日志:

```bash
# prod(dev 把 hh2-prod→hh2、/home/huanhua/ms→/home/msdev/ms;容器名变 ms-mcp-dev,
#      但 compose service 仍是 ms-mcp,命令里的服务名不要改)
ssh hh2-prod 'cd /home/huanhua/ms/api && docker compose up -d --build ms-mcp && docker ps --filter name=ms-mcp'
ssh hh2-prod 'cd /home/huanhua/ms/api && docker compose logs --tail=100 ms-mcp'
```

- 关停:`docker compose stop ms-mcp`(nginx 变量 upstream 不会因上游缺失而崩,
  `/mcp` 返回 502,整站其它路径不受影响)。**删除容器**只在回滚时用
  `docker rm -f ms-mcp`(dev `ms-mcp-dev`);service 已从 compose 文件移除后
  `docker compose rm` 会报 no such service。

### 12.4 环境变量(ms-mcp 只认这几项)

| 变量 | prod | dev | 说明 |
|---|---|---|---|
| `MS_API_BASE_URL` | `http://ms-api:8000` | `http://ms-api-dev:8000`(以 override 实测为准) | 容器内 api 根地址 |
| `MS_MCP_ENTRY_ALLOWLIST` | 10 条(§12.2) | 3 条 `:8090` | 入口白名单 |
| `MS_MCP_INTERNAL_BASE_URL` | `http://192.168.110.221` | `http://192.168.110.221:8090` | 取缩略图字节的固定入口(须在白名单内) |
| `MS_MCP_SESSION_TTL` | `1800` | `1800` | 空闲会话 TTL(秒) |
| `MS_MCP_VERIFY_TLS` | `true` | `true` | 两套 httpx 客户端共用;公网自签阶段可 `false` 或配 `MS_MCP_CA_BUNDLE` |

可选 `MS_MCP_CA_BUNDLE` / `MS_MCP_LOG_LEVEL` 见 `material-storage/mcp/README.md`。

**红线**:ms-mcp **禁止 `env_file: .env`**,只允许显式 `environment:`;不得出现
DB / Redis / MinIO 任何凭证(部署前用 `docker compose config` 检查)。会话上限 200
是编译常量,没有 env 可调。改 env 后 `docker compose up -d ms-mcp`(`restart` 不重读)。

### 12.5 部署/更新顺序(prod 硬约束)

> **顺序不可反**:新代码 + 旧 schema(0019)时,`AuditService.write` 插入 `auth_method`
> 会 `UndefinedColumn`,upload / download / share 主链路都 await 审计写入
> → **全站审计 500**,不是仅 MCP 不可用。
> `deploy_lan.sh` **没有 alembic 步骤**,必须人工先迁移;且**不要带 `--restart`**
> (带了会立刻加载新代码)。

```bash
# ──【本地】仓库 material-storage/ 目录 ──
# 0) 先对账(目标机命令;prod 别名 hh2-prod)
ssh hh2-prod 'cd /home/huanhua/ms/api && docker compose exec -T ms-api alembic current && docker compose exec -T ms-api alembic heads'
# 1) 同步代码,不带 --restart
bash scripts/deploy_lan.sh prod

# ──【目标机】以下全部在 /home/huanhua/ms/api(dev 用 hh2 / /home/msdev/ms)──
# 2) 迁移(必须在 restart 之前;0020 纯增量)
ssh hh2-prod 'cd /home/huanhua/ms/api && docker compose exec -T ms-api alembic upgrade head'
# 3) 加载新代码(必须含 worker)
ssh hh2-prod 'cd /home/huanhua/ms/api && docker compose restart ms-api ms-worker'
# 4) ms-mcp 构建并启动(独立镜像,restart 不 build)
ssh hh2-prod 'cd /home/huanhua/ms/api && docker compose up -d --build ms-mcp'
# 5) nginx 校验并热载(conf 已随步骤 1 同步;prod=poc-nginx,dev=poc-nginx-dev)
ssh hh2-prod 'docker exec poc-nginx nginx -t && docker exec poc-nginx nginx -s reload'
# 6) SPA 单独替换(deploy_lan 排除 static/web,走既有分片通道)
```

- 步骤 1→2 之间是危险窗口:ms-api 是 `restart: unless-stopped`,若崩溃/宿主机重启会
  自动拉起新代码 + 旧 schema。`deploy_lan` 之后应尽快跑迁移;窗口内发生重启,
  先补 `alembic upgrade head` 再继续。
- dev 差异:SSH 别名 `hh2`、目录 `/home/msdev/ms`、容器 `ms-api-dev`(compose service
  仍是 `ms-api`)、nginx `poc-nginx-dev`;SPA 指纹按当次构建核对。
- **首次上线后必须由管理员在 `/admin/mcp-settings` 把通道置为 `enabled=true`**:
  默认全关,不开则 MCP 请求全 403。

### 12.6 健康检查

- **ms-mcp 自身**:容器内 `/healthz`(与入口的 `/ms-healthz` 不是一回事)。在目标机
  api 目录执行:

```bash
cd /home/huanhua/ms/api   # dev: /home/msdev/ms/api
docker compose exec ms-mcp python -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/healthz').read())"
```

- **入口存活**:`/ms-healthz`(反代到 api `/healthz`,同时验证 nginx + api):

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.110.221/ms-healthz    # prod,应 200
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.110.221:8090/ms-healthz  # dev
```

- **MCP 入口连通**:对 `.../mcp` 发 `POST`(无令牌)应由 ms-mcp 返回 JSON 401/400;
  若响应体是 MinIO 的 S3 XML(403/404),说明 nginx `/mcp` location 未同步 / 未 reload,
  请求落到了默认 location → MinIO(用 `curl -i` 看响应体区分)。
- ⚠ **`/healthz` 在入口不是健康检查**:hh2 nginx 没有该精确 location,会落到默认
  `location /` → MinIO S3,返回 403;判断入口健康一律用 `/ms-healthz`。

### 12.7 指标解读

管理后台 `/admin/mcp-settings`(仅系统管理员)读取 `GET /api/v1/admin/mcp-settings`,
配置体 + 实时指标(指标读失败时字段为 null,配置体正常返回):

| 指标 | 口径 |
|---|---|
| `in_flight` | `ZCOUNT mcp:conc:global now +inf`(在途并发;勿用 ZCARD) |
| `today_success` | `mcp:stats:requests:{yyyyMMdd}`:PAT 请求 2xx |
| `today_rejected_policy` | `mcp:stats:rejected_policy:*`:通道关闭 / 令牌禁用端点 / 强制改密 |
| `today_rejected_quota` | `mcp:stats:rejected_quota:*`:IP 桶 / 每令牌 RPM / 并发闸 / batch 超限 |
| `rejected_infra_since_start` | 进程内:配置读不到(`channel_unavailable`)/ Redis 故障(`redis_down`),**重启清零** |
| `dynamic_signers_cap_hits` | 进程内:动态 presign 缓存打满回落静态的次数,**重启清零**;>0 时页面标红 |

- **日期口径**:`mcp:stats:*` 按 **UTC 日**(`yyyyMMdd`),与使用统计页的
  **北京时间日**不同;两个页面的「今日」不是同一个窗口(页面已分别标注)。
- 拒绝量按 `mcp_reject_reason` 分桶,不按 HTTP 状态码;业务 403 / 401 / 4xx / 5xx
  不计入。边缘 nginx `limit_req` 的 429 到不了 api,**不计入任何指标**。
- 进程内计数(`rejected_infra_since_start` / `dynamic_signers_cap_hits`)是
  api 进程局部值,重启清零;当前 uvicorn 单 worker,若未来加 `--workers` 则各算各的。

### 12.8 常见故障

| 现象 | 原因 / 处置 |
|---|---|
| MCP 全 403,文案「MCP 通道当前已由管理员关闭」 | 通道默认全关;管理员在 `/admin/mcp-settings` 开启 `enabled` |
| 403,拒绝原因 `channel_unavailable` | 配置读不到 / 闸启动自检失败(查 Redis/DB 与 api 日志),**不是**管理员关通道(关闭文案见上一行) |
| 403,拒绝原因 `forced_change` | 用户处于强制改密态(PAT 分支无豁免);先在网页完成改密再使用 |
| 某一入口全量 403,文案「入口 Host 不在 MS_MCP_ENTRY_ALLOWLIST 内」 | 该入口 `Host` 拼法不在 `MS_MCP_ENTRY_ALLOWLIST`(带/不带端口、http/https 都要列);补条目 → `docker compose up -d ms-mcp` |
| 入口 `/healthz` 返回 403 | 正常现象,落到了 MinIO;用 `/ms-healthz`(§12.6) |
| `/mcp` 返回 403/404 且响应体是 MinIO S3 XML | nginx conf 没有 `/mcp` location(未同步 / 未 reload),请求落到了默认 location;正常应返回 ms-mcp 的 JSON 401 |
| `/mcp` 返回 502 | `ms-mcp` 未起 / 容器名解析失败;`docker ps`、`docker compose logs ms-mcp` |
| initialize 后马上 401 | PAT 无效/过期/已吊销/用户被禁用/密码已变更(改密即吊销全部 PAT);重新在 `/settings` 签发。同一 Session-Id 换 PAT 也返回 401,须重新 initialize |
| 429 + `Retry-After` | 配额类:IP 桶 600/min、每令牌 RPM 120/min、全局并发 8、每令牌并发 4(默认值);也可能是边缘 `15r/s` 限流(无 JSON 文案、不入指标) |
| 503 | Redis 故障(fail-closed)或上传会话初始化失败;500 多为 DB 故障 |
| 会话约 30 分钟不用就断 | SSE 空闲上限 hh2 1800s(跳板机 3600s);客户端重连 initialize 即可 |
| 某些操作 PAT 403「令牌不支持该操作」 | 方案刻意排除的七类端点(batch-prefix、彻底删除、审计导出、admin 批量等)与 batch-move >200 项;用 Web 会话完成 |

### 12.9 回滚

```bash
# 1) 先在 /admin/mcp-settings 关通道(enabled=false):MCP 全 403,Web/App 不受影响
# 2) 在旧 commit 的 checkout 里(material-storage/ 目录)跑 deploy_lan 同步代码,再重启 api + worker
bash scripts/deploy_lan.sh <env>
ssh hh2-prod 'cd /home/huanhua/ms/api && docker compose restart ms-api ms-worker'
# 3) 删 ms-mcp 容器(prod ms-mcp / dev ms-mcp-dev)
ssh hh2-prod 'docker rm -f ms-mcp'
# 4) 若 nginx conf 也回滚:同步后 nginx -t && nginx -s reload
ssh hh2-prod 'docker exec poc-nginx nginx -t && docker exec poc-nginx nginx -s reload'
```

- **DB 无须 downgrade**:0020 是纯增量迁移(可空列 + 独立新表),旧代码与新 schema
  兼容共存。仅当迁移本身有错才 `alembic downgrade 20261028_0019`(或 `-1`;
  `0019` 只是后缀,不是唯一前缀)。
- 必须同时重启 **ms-worker**:worker 也挂 bind mount,只重启 api 会让 worker
  继续跑新逻辑。
- dev 执行时把 `hh2-prod`→`hh2`、`/home/huanhua/ms`→`/home/msdev/ms`、
  `docker rm -f ms-mcp`→`docker rm -f ms-mcp-dev`。
- SPA 回滚按既有备份(`web.bak-*`)替换;dev/prod 各自的备份名见 changelog。

### 12.10 已知限制(方案已登记)

- **session cookie 旁路**:MCP 闸只作用于 PAT;把登录 cookie 交给 AI 直调业务端点
  不受任何 MCP 限流约束,本期不解决(二期候选「非浏览器客户端必须 PAT」)。
- **admin PAT 的破坏面**:PAT = 全账号身份,管理员 PAT 可调未排除的 admin 写端点
  (如重置他人密码);非提权,但 AI 误触可造成破坏。
- **孤儿 multipart 无 cron 清扫**:上传失败靠 `abort_upload` 工具;MinIO 侧
  lifecycle abort 曾被拒,存量缺口,列二期候选。
- **ms-mcp 单副本**:会话绑定在进程内存;水平扩展需 sticky 或 Redis session store,
  列二期。
- **worker / 队列不在闸的约束面**:闸只管请求期,缩略图 / 派生 / livp 等 worker
  负载需另行观测。
- **使用统计的 mcp 桶低估读流量**:search / thumbnail 不写审计,mcp 桶只反映审计
  可见操作(上传 / 下载签发等);真实流量看 `/admin/mcp-settings` 指标。
- ⚠ **环境风险(既有配置,本期未改)**:prod 目标机 `.env` 当前为 `ENV=dev`,
  `X-User-Id` 通道在 prod 可用;MCP 方案假设生产为 session-only,建议运维复核
  (改 `ENV` 属另一变更,不在本期射程)。

