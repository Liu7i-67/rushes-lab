---
name: deploy-hh2
description: 内网 hh2 服务器（dev/prod）部署注意事项与踩坑手册。凡是要把 material-storage 部署/同步到内网测试或生产环境、运行 deploy_lan.sh、或部署中出现"卡死不动"、同步断流、SPA 没更新、部署后版本没变等问题时使用——即使用户没说"部署"这个词，或只说"发到测试环境/内网环境/给 tester 看"。
---

# 内网 hh2 部署 —— 环境事实、标准流程与踩坑手册

先读 `CLAUDE.md` 的「部署 D」一节。本技能是其展开版：收录已实踩过的坑和验证过的替代通道。动手前按 §1 预检，部署完按 §5 验证清单逐项过。

## 1. 环境事实（先对号入座）

| | dev（测试环境） | prod（正式环境） |
| --- | --- | --- |
| SSH 别名 | `hh2`（登录身份 **msdev**） | **`hh2-prod`（登录身份 huanhua）——prod 必须走这个别名** |
| 远端目录 | `/home/msdev/ms` | `/home/huanhua/ms` |
| 入口 | `http://192.168.110.221:8090`（外网 `http://47.108.196.211:8080`） | `http://192.168.110.221`（外网 `:18080`） |
| 容器 | `ms-api-dev` / `ms-worker-dev` / `ms-db-dev` | `ms-api` / `ms-worker` / `ms-db` |
| OpenFGA 容器 → 宿主 API 端口 | `poc-openfga-dev` → `127.0.0.1:8189` | `poc-openfga` → `127.0.0.1:8089` |
| OpenFGA store id | 各自 `~/ms/api/.env` 的 `OPENFGA_STORE_ID`（**两环境 store 不同，别混**） | 同左 |

- ⚠ **prod 别用 `hh2` 别名**：该身份（msdev）对 `/home/huanhua/ms` 无写权限、也无免密 sudo，rsync 会满屏 chgrp/Permission denied（2026-09-10 实踩）。prod 一律 `ssh hh2-prod`（huanhua 身份可直接 `docker compose restart`，无需 sudo）。
- ssh 走跳板反向隧道，**会抖动也会中途断流**（§3 是重点）。
- OpenFGA 容器内**无 curl/wget**，API 只能走宿主映射端口（§1 表）；推模型/查 store 一律从宿主 curl。
- 同机双环境并存，靠三层隔离（COMPOSE_PROJECT_NAME / container_name 后缀 / ports `!override`）互不干扰——**别动这套隔离，exec/重启前先看清容器名后缀**（`poc-openfga` 是 **prod** 的、`poc-openfga-dev` 才是 dev 的，最容易看错的一对）。
- `.env` 与 `docker-compose.override.yml` 在目标机上从不随部署覆盖。
- dev 的 nginx 把 `/healthz` 路由到 MinIO（既有配置），**API 存活用 `/api/v1/auth/me`（未登录 401）判断**。
- prod 是 `ENV=production`：`X-User-Id` dev 通道**失效**，业务级实测（如 download-link 语义）需要真实账号登录；代码级核验用容器内 grep。

## 2. 部署前预检（每次都做）

1. 工作区干净（`git status --short` 为空）。deploy 同步的是**工作区**，不是纯 commit；脏工作区会被记进 DEPLOYED.md 的"源端未提交改动"。
2. 本次有没有改 `.env`？→ 没有就不用 `--force-recreate`；**有则必须 `docker compose up -d --force-recreate`（`restart` 不重读 env_file）**。
3. 有没有新 migration？→ 有则**restart 之前**先 `docker exec <ms-api 容器> alembic upgrade head`（2026-10-10 起修正旧口径"重启后再跑"：`.py`/迁移脚本都是 bind mount，旧进程 + 新迁移脚本 = 加列零窗口；先 restart 后迁移会有几秒「新代码打旧库」窗口，新代码 SELECT 新列直接炸）；没有就**别跑**。
4. `.py` 是 bind mount 但容器无 `--reload` → **后端有改动就必须 restart**；仅 SPA 改动不用重启。
5. `poc/openfga/store.fga.yaml` 有 diff 吗？→ `git diff <目标机当前commit>..HEAD --stat -- poc/openfga/store.fga.yaml` 非空 = 本次涉及 FGA 模型变更，**必须先走 §2.5 推模型再发代码**（顺序反了，新代码的权限 check 打旧模型会 403/500）。

## 2.5 FGA 模型变更（store.fga.yaml 有 diff 时必读，2026-10-10 双环境实战）

**硬顺序：模型先推 → 代码 → migration → restart。** 推模型是纯增量（新 authorization model 版本并存，旧 tuple 不动），提前推对旧代码零影响；反过来则新代码在模型生效前请求会失败。

1. **本地把 yaml 转 JSON**（本机 docker 有 `openfga/cli:latest` 镜像；hh2 上没有 CLI，别想在那边转）：

   ```bash
   cd material-storage
   TMP=$(mktemp -d)
   awk '/^model: \|/{f=1;next} f && /^[^ ]/{exit} f' poc/openfga/store.fga.yaml | sed 's/^  //' > "$TMP/model.fga"
   HOST_DIR=$(cd "$TMP" && pwd -W 2>/dev/null || pwd)
   MSYS_NO_PATHCONV=1 docker run --rm -v "$HOST_DIR:/work:ro" openfga/cli:latest \
     model transform --input-format fga --file /work/model.fga > /tmp/fga-model.json
   grep -c <新relation名> /tmp/fga-model.json   # 转换产物自检
   ```

2. **推到目标机**：JSON 只有几 KB，远低于 ~800KB 断流阈值，直接单流管道，不必走分片：
   `ssh <hh2|hh2-prod> 'cat > /tmp/fga-model.json && md5sum /tmp/fga-model.json' < /tmp/fga-model.json`（两侧 md5 对上再继续）。
3. **POST 到 store**（宿主端口 + store id 见 §1 表；以 dev 为例）：
   ```bash
   ssh hh2 'curl -s -X POST http://127.0.0.1:8189/stores/<STORE_ID>/authorization-models \
     -H "content-type: application/json" --data-binary @/tmp/fga-model.json'
   ```
4. **验证**：models 列表 `latest` = 刚返回的新 id，且 GET 该 model 内容能 grep 到新 relation；顺手 `rm -f /tmp/fga-model.json`。
5. **生效条件**：目标机 `.env` **没有** `OPENFGA_AUTHORIZATION_MODEL_ID`（未固定）→ 应用自动用 latest，推完即生效，restart 后自然可用；**若固定了** model id，必须改 `.env` + `--force-recreate`（`restart` 不重读 env_file，坑同 §2 第 2 条）。
6. **回滚不需要动模型**：多版本并存，代码回滚后旧代码继续用 latest 模型也没问题（只加 relation 是向后兼容的）。

## 3. 标准流程与两个大坑

```bash
cd material-storage
pnpm --dir web install        # ⚠ 必须先装:坑 C(2026-10-10 实踩,build 静默失败推旧 SPA)
pnpm --dir web build          # SPA 不随脚本同步,单独推(§4)
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

### 坑 C：build 静默失败推了旧 SPA（2026-10-10 prod 实踩）

两个条件叠加就会**把上一次的旧构建当新产物部署上去**：

1. **依赖声明随分支合并进了主仓，但 `node_modules` 不会自动有新包**（在 worktree 里 `pnpm add` 过 ≠ 主仓装过）——缺包时 `tsc -b` 直接失败，`vite build` 根本不跑；
2. **`pnpm build 2>&1 | tail` 会掩盖失败退出码**（bash 管道退出码取最后一个命令，tail 恒成功）——tsc 死了流程照走，`api/app/static/web/` 停留**上一次**的产物，`index.html` 依旧能 grep 出（旧）指纹。

防御三条（部署前逐条过）：
- build 前无条件 `pnpm --dir web install`（幂等，几秒）；
- build 的成败看它自己的退出码，别接管道看：`pnpm --dir web build || echo BUILD_FAILED && exit 1`；
- **指纹必须核对"变化"**：部署新版前 grep 本地 `api/app/static/web/index.html` 的 `index-*.js`，与目标机当前线上指纹比对——**部署新版本时指纹没变 ≈ 没构建成功**；同一 commit 部署 dev/prod 双环境，两环境指纹必须一致（§5②/§6）。

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
5. 小坑四条（都实踩过）：
   - scp 报 `No such file or directory` = **远端目标目录没建**，先 `ssh hh2 'mkdir -p <dir>'`；
   - **chunked-push.sh 的 `HOST=hh2` 是写死的**（推 prod 别想当然它认 hh2-prod）：推 prod 复制一份改 HOST 直推，比"hh2 上传/hh2-prod 消费"中转省事（2026-10-10 实战）：
     ```bash
     sed 's/^HOST=hh2$/HOST=hh2-prod/' .agents/skills/deploy-hh2/scripts/chunked-push.sh > /tmp/chunked-push-prod.sh
     bash /tmp/chunked-push-prod.sh /tmp/ms-sync-prod.tgz /tmp/ms-sync-prod.tgz
     ```
   - **/tmp 粘滞位跨身份残留**（用上一条直推法后基本不触发，留作兜底）：msdev 传的 /tmp 文件 huanhua 删不掉（rm Operation not permitted 会中断远端脚本）——经 hh2 中转文件给 prod 用时，上传方(msdev)事后自己清 `ssh hh2 'rm -f /tmp/xxx.tgz'`；
   - 远端批量脚本里 tar/cp **一律绝对路径**：heredoc 的 cwd 是登录家目录，`tar xzf ms-spa.tgz` 这种相对路径会静默打不开文件。

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

## 6. 正式环境（prod）专项注意

prod 是真实用户环境，除 §1-§5 通用规则外，额外遵守：

**通道（最容易踩的坑）**：prod 只能走 `ssh hh2-prod`（huanhua）。`hh2` 别名身份是
msdev，对 `/home/huanhua/ms` 无写权限、无免密 sudo，rsync 会满屏
`chgrp/Permission denied` 后以 code 23 失败（2026-09-10 实踩，当时 prod 未受影响
是万幸——rsync 被拒的文件一个都没写进去）。`deploy_lan.sh` 的 prod 分支已改为
`HOST=hh2-prod` 且重启去掉 sudo（huanhua 直管 docker，实测无需 sudo）。

**上线前确认（比 dev 多三步）**：
1. 过一遍增量 `git log <prod当前commit>..HEAD --oneline`，心里有数每个 commit
   去哪了；后端契约变更必须向后兼容（additive 可选参数 / 默认行为不变）才可直接上。
2. 无 migration / 无 `.env` 变更的假设要**逐条核实**而不是沿用 dev 的结论。
3. 记录本次 SPA 指纹与回滚备份：SPA 原子替换保留 `web.bak-<日期>` 直到确认稳定。

**部署窗口与告知**：hh2 prod **没有** MAINTENANCE_ISSUES 弹窗通道（那是 server2
的 deploy_server2.sh 机制）；重启 ms-api 有秒级不可用，提前跟真实用户打好招呼。

**验证（双入口都测）**：
```bash
# 内网与外网两个入口的 SPA 指纹必须一致且等于本地 build
ssh hh2-prod 'curl -s http://127.0.0.1:80/ms-static/web/ | grep -o "index-[^\"]*\.js" | head -1'
curl -s http://47.108.196.211:18080/ms-static/web/ | grep -o 'index-[^"]*\.js' | head -1
```
再加 auth/me 401、容器内新代码 grep（§5）。**业务级 API 实测在 prod 不能用
X-User-Id**（仅 dev 生效）——用真实账号登录后抽查（如 download-link 的
attachment 响应头），或引用同源代码在 dev 的实测结论并在汇报中注明。

**回滚**：SPA 用保留的 `web.bak-<日期>` 换回；代码 = 工作区切回旧 commit 重新走
分片通道 + restart。回滚后重过验证清单。

## 7. 回滚（dev/prod 通用）

工作区 `git checkout <目标commit>` → 重复 §4（或 `deploy_lan.sh`，能通就通）→ restart。`.env` 与数据目录全程不动。回滚后同样过 §5 清单。若本次推过 FGA 模型（§2.5），回滚代码**不需要**回滚模型（多版本并存，只加 relation 向后兼容）。

## 7.5 周期收尾：worktree 清理（Windows 长路径，2026-10-10 实踩）

qdev 周期结束后清理开发 worktree 时，`git worktree remove` 常报 `Filename too long`——web 的 `node_modules` 深层路径超 Windows MAX_PATH，git 删不动。用 robocopy 空目录镜像法清空后再删：

```bash
mkdir -p /tmp/empty-dir-4del
MSYS_NO_PATHCONV=1 robocopy "C:\\Users\\<用户>\\AppData\\Local\\Temp\\empty-dir-4del" "E:\\path\\to\\worktree" /MIR /NFL /NDL /NJH /NJS /NP
# robocopy 退出码 0-7 都算正常(2=删了东西)
git worktree remove <路径> 2>/dev/null || (rm -rf <路径>; git worktree prune)   # robocopy 连 .git 元数据一起清掉后 remove 会报 not a working tree,prune 兜底
git branch -d <分支>
rmdir /tmp/empty-dir-4del
```

## 8. 与 server2 的区别（别混用）

- `deploy_server2.sh`（公网 8.156.34.238，tester 入口）才有 `MAINTENANCE_ISSUES` 弹窗机制；hh2 没有弹窗通道，tester 通知走 issue / 群里附回归清单。
- server2 是 rsync 直连（无跳板断流问题）；hh2 必经跳板隧道，长流不可靠，**优先考虑分片通道**。
