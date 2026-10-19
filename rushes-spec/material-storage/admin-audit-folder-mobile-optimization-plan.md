# 六项优化调研方案:管理员解锁登录锁定 / 审计真实 IP 与项目名 / 移动端备份入口 / 目录改名 / 目录拖拽层级 / 文件批量移动

> 2026-10-16 调研定稿,同日经 13 轮独立盲审修订定稿(末轮无 P0/P1)。调研全程未动代码;
> **行号引用为 e792be0 基线快照**——此后 liuqi 已并入并行会话增量(组级删除授权/百度频控放宽等,
> assets/folders/auth/directory/permissions 等 18 文件 +1784 行,相关文件行号已漂移),
> 实施时一律按符号名/端点名 + grep 定位,勿按行号盲跳(W2b 的写入面清单本就以此为对账口径)。
> 代码/配置文本层面的论断
> (nginx conf、Redis key、MobileTabBar、Dockerfile 等)均已逐一亲验,但**网络运行时行为
> (poc-nginx 容器实际看到的隧道流量源 IP)无法在调研期实测,已列为实施前第一步必测项(§2.2②)**。
> 六项按用户原始编号拆为六个工作包 W1–W6(W2 拆 a/b 两个子项),互相独立可并行;
> 唯 W2a(真实 IP)建议最先做,它顺带修复「公网入口所有用户共用一个 per-IP 登录限流桶」的连带事故。
> 实施等待用户明确指令。

---

## 0. 调研结论摘要

| # | 需求 | 根因 | 性质 | 建议工作量 |
|---|------|------|------|-----------|
| W1 | 管理员重置登录锁定 | 锁定是纯 Redis key(`auth:lock:ip/user:*`,15 分钟 TTL),无 DB 字段、无任何管理端点/脚本能清,唯一解锁途径=等 TTL 过期 | 后端+前端新功能,**零 migration** | ~1 天 |
| W2a | 审计显示真实 IP(现为 172.20.0.7) | `poc-nginx → ms-api` 一跳的 `location ^~ /api/v1/` **没设 `X-Forwarded-For`**(default.conf:22-34,其余头都设了,唯独漏它);跳板机 nginx 大概率也没传;uvicorn 无 XFF 可用 → `request.client.host` = nginx 容器 IP | **纯配置层**(nginx ×2),代码零改动 | ~0.5 天 + 跳板机人工 |
| W2b | 审计只显示文件 key 看不到项目名 | ① 列表端点只回裸列不解析名字;② `target_project_id` 在约一半资产事件写入点漏传(下载/分享/删除等) | 后端+前端 | ~1 天 |
| W3 | 移动端无【备份任务】入口 | 纯前端导航裁剪遗漏:页面 2026-10-14 上线时只加了桌面 chip,**漏改 MobileTabBar 的 moreItems**;「新管理页要同步补 moreItems」本是既有惯例(权限模板补过) | 前端小改,后端零改动 | ~0.5 天 |
| W4 | 目录改名 | folders.py 无 PATCH/rename 端点;但 FGA tuple 不含 name、全部功能按 DB 行/id 计算 → **改名是低成本 DB 操作** | 后端+前端 | 见 W4/W5 合计 ~2 天 |
| W5 | 目录拖拽改层级 | 同上无 move 端点;FGA 只需改一条 parent tuple;**物理对象可以完全不动**(系统无任何按 prefix 扫 MinIO 的逻辑,grep 实证) | 后端+前端 | 同上 |
| W6 | 文件点选批量移动(含跨项目) | assets.py 无 move 端点;但 `batch-prefix`(2026-10-08)已铺好全部模板:批量框架/权限分组/key 冲突预检/事务边界/MinIO copy 先例 | 后端+前端 | 项目内 ~1.5 天;跨项目 ~+1.5 天(建议拆两期) |

**建议实施顺序**:W2a(真实 IP)→ W3(移动端入口,半天快赢)→ W1(管理员解锁)→ W2b(审计项目名)→ W4/W5(目录改名+拖拽)→ W6 一期(项目内移动)→ W6 二期(跨项目)。

---

## 1. W1:管理员重置登录锁定

### 1.1 现状机制

- Redis 四个 key(`api/app/services/local_auth.py:31-35`):
  `auth:fail:ip:{ip}` / `auth:fail:user:{username}`(计数)/ `auth:lock:ip:{ip}` / `auth:lock:user:{username}`(value="1")。
  **user 维度的 username 是登录输入的 `lower()`**,且用户可用 username / email / 显示名三种形态登录
  (三级匹配 `local_auth.py:113-140`),失败会落到三种不同形态的 key 上。
- 阈值/TTL:`auth_max_failures=5`、`auth_lock_seconds=900`(15 分钟,`settings.py:86-87`);
  第 5 次失败触发锁时独立 `SET` 写锁(pipeline 只含 incr/expire,`local_auth.py:89-102`),
  只打 log **不写审计**。
- 登录入口(`routers/auth.py:255-259`):任一维度命中锁 → 429「登录失败次数过多,账号已锁定 15 分钟」,
  **此分支不写审计**;密码错/禁用走 `record_failure` + 审计 `local_login_failed`
  (details 含 username/reason;request_ip 是独立审计列,auth.py:270-276)。
- users 表(`db/tables.py:58-81`)**无任何锁定字段** → 加解锁功能零 migration。
- 管理端:用户管理全在 `routers/directory.py`(全部 `require_system_admin`),已有
  disable/enable/reset-password 行操作先例;前端 `AdminUsersPage.tsx:217-237` 行按钮组 +
  `hooks.ts:607-694` mutation 模式成熟。
- 现有唯一清理手段 = `redis-cli FLUSHALL` 整库清(测试惯例,CLAUDE.md:81)。

### 1.2 实施方案

**后端**(落点 `routers/directory.py`,与 reset-password 完全同构):

1. `LocalAuthService` 新增 `clear_locks(user)`:对 `{username, email, name}` 三种形态(非空、去重、lower())
   逐一 `DEL auth:lock:user:{u}` + `auth:fail:user:{u}`。**必须 lower()**,否则静默清空(DEL 不存在的 key 不报错)。
2. 新端点 `POST /api/v1/admin/directory/users/{user_id}/unlock`,`Depends(require_system_admin)`:
   - 清 user 维度锁 + 计数;
   - **IP 维度连带清**(推荐默认做):从审计反查该用户名三种形态近 24h `local_login_failed` 的
     `request_ip` 去重集合(`audit_events.request_ip` 是现成列;**匹配口径注意**:
     `details.username` 存的是原始输入未 lower——auth.py:251 只 strip、:275 落 details——反查比对须按
     lower 口径,精确匹配会静默漏清),一并 DEL 对应 `auth:lock:ip/fail:ip` key。
     理由:`is_locked` 任一维度命中即 429(`local_auth.py:76-81`),只解 user 维度时同 IP 锁仍拦;
     尤其 W2a 修复前公网入口全员共用一个 IP 桶,不连带清则解锁大概率无效。
   - 审计 `user_login_unlocked`(details 记清除的 username 形态与 IP 集合)。
3. 状态展示:`DirectoryUserOut` 加 `login_locked: bool`(列表页批量 pipeline MGET 三形态 user 锁 key,
   一次往返,避免每行 N 次 GET)。**该 pill 只反映 user 维度**(IP 维度命中时仍显示未锁——
   登录照样 429),pill 文案/tooltip 标注「用户名维度锁定」。前端状态 pill 增加「登录已锁定」态
   (`AdminUsersPage.tsx:245-267` StatusPill 模式)。
4. 顺带(推荐):`reset-password` 端点内调 `clear_locks`(重置密码语义上伴随解锁);
   `record_failure` 返回是否触发锁,router 据此补写 `local_login_locked` 审计事件(消除「锁定期间零审计」盲区)。

**前端**:`useUnlockUser` hook(照 `useDisableUser`,`hooks.ts:667-683` 同款 invalidate)+
`UserRow` 加「解锁」按钮(建议仅 `login_locked` 时渲染)。

**事件文案回填(硬约定)**:新 event_type 须同步补 `web/src/lib/labels.ts` 的 `EVENT_TYPE_LABEL`
**和** `AdminAuditPage.tsx` 的 `EVENT_TYPES` 下拉数组(:40 起;该处注释明确要求,漏了就是
§8 所述 2026-10-14 历史事故同款 bug)。

### 1.3 风险与注意

- user 维度解锁 ≠ 立刻能登录(IP 维度锁可能仍在)→ 已通过连带清缓解,UI 文案说明即可;
- 连带清 IP 锁会短暂削弱对该 IP 的暴力破解防护(15 分钟窗口)——系统 admin 权限门槛下可接受;
- **name 形态的 key 跨用户共享**:锁/计数 key 按「登录输入 lower()」落,两个显示名相同的用户
  共用同一 `auth:*:user:{name}` key(登录的三级 name 兜底匹配同样会命中多行拒绝,但失败计数
  仍先落 key)——解锁用户 A 会连带清掉同名用户 B 在该形态上的计数。系统 admin 门槛下可接受,
  `user_login_unlocked` 的 details 已要求记录实际清除的形态清单,便于事后解释;
- 锁定状态以实时查 Redis 为准,**不要从审计推断**(锁定期间 429 不写审计,存在天然盲区)。

### 1.4 验收标准

- 测试账号连错 5 次 → 登录 429;管理员调 unlock 后立即用正确密码登录成功(不再 429);
- 审计出现 `user_login_unlocked`(details 含清除的形态与 IP);用户列表「登录已锁定」pill
  出现/消失与 Redis 实际状态一致(**user 维度**;IP 维度锁不在 pill 内,按 §1.3 文案说明);
- 跑登录相关集成测试前 `redis-cli FLUSHALL` 的既有惯例(CLAUDE.md)不受影响。

---

## 2. W2a:审计显示用户真实 IP

### 2.1 根因链(逐跳)

外网链路:`浏览器 → 阿里云跳板机 nginx:443(TLS 终结)→ 反向隧道 18080 → hh2:80 → poc-nginx 容器 → ms-api:8000`

1. **跳板机 nginx**(`/etc/nginx/conf.d/bucket-taoxiplan.conf`,仓库无留存,changelog 2026-10-10 节有记录):
   已知指令里没有 X-Forwarded-For——nginx 默认不添加,大概率没传(需上机核实)。
2. **隧道跳**:纯 TCP 转发,头不丢不改。注意分层:「hh2 nginx 眼里源 IP 恒为 127.0.0.1」
  (`public-fallback-entry.md:301`;runbook:108 只是隧道 sed 命令本身)是**宿主层**事实——
   反向隧道的 ssh 客户端(jump-tunnel)在 hh2 宿主上连 `127.0.0.1:80`(sshd 监听端在跳板机);
   而 80 端口是 docker 端口发布(`poc/minio/docker-compose.yml` 的
   `ports: "80:80"`),宿主 loopback 目标的连接不走 DNAT(docker 的 OUTPUT 链规则显式排除
   127.0.0.0/8 目标),由 docker-proxy 用户态代理转投容器 → **poc-nginx 容器看到的源 IP 是
   poc-net 网桥网关(预计 172.20.0.1),不是 127.0.0.1**;内网直连用户走 DNAT,容器看到的是
   真实 192.168.x。这一跳的实测值决定 §2.2② 的信任源,实施前必须上机确认。
3. **poc-nginx(= hh2 的 nginx,conf 就是仓库里的 `poc/minio/nginx/default.conf`)**:
   `location ^~ /api/v1/`(default.conf:22-34)设了 `Host $http_host`、`X-Real-IP $remote_addr`、
   `X-Forwarded-Proto $xfp`,**唯独没有 `X-Forwarded-For`**(X-Real-IP 设了但 uvicorn 不消费它)。
   `/ms-static/`(:35-40)、`/privacy`、`/terms`、`/ms-healthz` 同样没有。
   根 location `= /`(SPA 分流,:99-122,XFF 在 :120)与兜底 `location /`(MinIO,:193-201)
   反而都有 XFF——说明不是设计排除,是 ms-api 各块漏配。
   `public-fallback-entry.md` 「阶段 4:真实 IP 与登录限流」小节规划的 `real_ip` 配置**从未落地**。
4. **ms-api uvicorn**(`api/Dockerfile:33`):`--proxy-headers --forwarded-allow-ips '*'`,
   语义 = 有 XFF 时用 XFF 还原 client,**没有 XFF 时 client 保持 TCP 对端地址** → 永远是 poc-nginx
   容器地址 172.20.0.7。`deps.py:160-164` 把它写进 `audit.request_ip`。
5. 内网直连(192.168.110.221:80)与外网隧道两条路在 ms-api 眼里完全一样 → **所有人都是 172.20.0.7**。

**连带事故(两条)**:①登录限流 per-IP 维度(`local_auth.py:32`)对公网入口全员共享一个桶——
任一用户输错 5 次,全入口锁 15 分钟(`public-fallback-entry.md:301` 早已预言);
②**现状基线:审计 IP 本就可伪造**——`/api/v1/` 块不覆写 XFF 且 uvicorn 信任 `'*'`
(Dockerfile:33),任何入口的客户端自带 XFF 头都会原样穿透进 `request.client`;本方案是
收敛伪造面(并给验收用例 3 提供前后对照),不是引入新风险。

### 2.2 实施方案(配置四处,含一项前置实测)

**⓪ 前置实测(实施第一步,决定 ② 的信任源)**:上机看 access log 的 `$remote_addr`,
分别从公网 443、公网 18080、内网直连三个入口各打一发请求对比;**dev 环境同款测一遍**
(poc-nginx-dev,入口=内网 :8090/外网 :8080,dev 隧道 `-R 0.0.0.0:8080:127.0.0.1:8090`,
runbook `prod-public-entry-runbook.md:106-108`)。按部署链路推演:
各环境隧道入口都应显示该环境网桥的网关(prod ≈172.20.0.1;dev 网桥预期是独立网关,但
两环境是否共享网络**一跳即证**:`docker network ls` + `docker inspect`——仓库声明名为
`poc-pigsty-minio_poc-net`(api compose 的 external 网络,docker-compose.yml:89-92),
poc compose 侧默认 `<project>_poc-net`,以实测为准),内网直连显示真实 192.168.x。
**以实测值为准**,下文 ② 中的网关 IP 均为推演值。

**① 跳板机(人工上机,conf 不在仓库)**:`bucket-taoxiplan.conf` 的 proxy_pass 块加
`proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`
(真实公网 IP 进链尾;**Host $http_host / ws upgrade / 零缓冲等既有指令勿动**)。
该 conf 是 TLS 终结 + 单 proxy_pass 到隧道的独立配置(changelog 2026-10-10 方案 B),
**不是** hh2 default.conf 的路由镜像——2026-10-10 曾在 hh2 侧短暂落过「default.conf 镜像 443
vhost」同日已回退,勿混淆;上机时仍以实际文件内容为准核验。改完把最终 conf 备份到
**仓库根** `scripts/env/`(与 changelog 同级的根 scripts/,注意 material-storage/scripts/
是另一处;该目录是既有机器本地密钥目录,**受 `scripts/.gitignore` 的 `env/` 规则保护、
git 不追踪**——worktree/新 clone 里看不到它属正常现象,真实机器上存在;落盘后 `git status`
复核一次未进暂存即可。因 conf 不进版本控制,**灾备对照**在 ops-manual 记一份指令清单摘要
或 sha256+日期,防机器丢失后回滚无据可依)。

**② poc-nginx(仓库内 `poc/minio/nginx/default.conf`)**,两层:

```nginx
# server 级:还原隧道流量的真实 IP。
# ⚠ 信任源 = ⓪ 实测的隧道流量源 IP(poc-net 网桥网关,示例写 172.20.0.1,以实测为准)。
# 宿主侧 jump-tunnel(ssh 客户端)连 127.0.0.1:80 的 loopback 目标不走 DNAT,
# 由 docker-proxy 转投容器,源 IP 变为网关——「信任 127.0.0.1」在容器层不成立,勿照抄宿主层口径。
# **只信网关单 IP,勿放宽到整个网段**:同网段其他容器若直连 nginx:80,放宽即开伪造面。
# 默认 real_ip_recursive off = 取 XFF 链最后一个地址,
# 即跳板机 $proxy_add_x_forwarded_for 追加在尾部的真实客户端 IP。
set_real_ip_from 172.20.0.1;    # ← 示例值,以 ⓪ 实测为准
real_ip_header X-Forwarded-For;

# 各 ms-api location(/api/v1/、/ms-static/、/privacy、/terms、/ms-healthz)加,
# 覆写为已还原的真实 IP(单值,不追加):
proxy_set_header X-Forwarded-For $remote_addr;
```

效果:隧道用户 → `$remote_addr` 还原为公网真实 IP;内网直连用户 → DNAT 保留源 IP,
其自带的伪造 XFF 因来源不在信任单 IP 内被忽略并覆写,无法冒充。uvicorn `--proxy-headers`
拿到单值 XFF,与版本取链首/链尾的语义无关,无歧义。`$remote_addr` 变化同时让既有
`X-Real-IP $remote_addr`(/ms-dev/、/ms-thumbs/ 的 MinIO 块)一并变真,无害。

**③ 公网 18080 裸隧道入口必须一并处置,否则修复后反而打开伪造面**:跳板机
`0.0.0.0:18080` 直通 hh2:80,链路上没有任何代理追加真实 IP;② 生效后,18080 流量与
443 隧道流量在 poc-nginx 眼里**同源同信任**,客户端自带 `X-Forwarded-For: 1.2.3.4` 会经
realip(取链尾)直接变成 `$remote_addr` → 审计 IP 可任意伪造,且每换一个伪造 IP 就拿到一个
全新的 per-IP 限流桶——恰好打穿本方案要修的共享桶防线的另一面。三选一(决策点 16;
**2026-10-19 用户改拍 b:对内服务保留两端口,改经跳板机 nginx 反代 + XFF,对外 URL 不变;
实现细节以 ops-manual §11.4 / w2a-realip-activation-runbook §3 为准,下文 a/b/c 为原始选项存档**):

- (a) **改 hh2 侧 jump-tunnel.service 的 `-R` 绑定地址**为 `127.0.0.1:18080:127.0.0.1:80`
  (绑定地址由 hh2 侧 ssh 客户端决定,服务文件在 hh2 的
  `/home/msdev/.config/systemd/user/jump-tunnel.service`,不是去跳板机上改;
  **现役跳板机 = 47.108.196.211**,runbook:65 的旧 IP 47.108.119.221 已失效勿按它找机器),
  公网仅剩 nginx 443 唯一通道(18080 本就是 fallback 手册定位的临时通道;如需保留应急直达,
  改经跳板机 nginx 反代并同加 XFF)。**沿用 runbook 的隧道变更流程时必须取消其自带的
  180s `tunnel-rollback` 自动还原定时器**(创建+sed 在 runbook:95-113,**取消步骤在 :117-119**),
  否则改绑会被静默还原;
- (b) 跳板机为 18080 加一层 nginx/Caddy 反代追加 XFF;
- (c) 明确接受风险并写入 ops-manual(不推荐)。

**④ uvicorn**:保持 `--forwarded-allow-ips '*'` 不动(入口已收敛在 poc-nginx,宿主侧 ms-api 只绑
127.0.0.1:8200)。可选加固:收紧为 compose 网段/nginx 容器固定 IP,防 poc-net 内其他容器直连
ms-api:8000 伪造 XFF——低优先级,拍板点。

**部署(硬顺序,防伪造窗口)**:② 的 prod reload **不得早于 ① 生效**——若 ② 先上而跳板机 ①
未上,443 流量的 XFF 链尾是客户端自带值而非跳板机追加值,realip 会采信伪造 IP。
完整顺序 = ⓪ 实测(含 dev)→ ① 跳板机加 XFF → **③ 18080 处置(先于 ② reload,缩短
「realip 已采信网关流量链尾值但裸通道未封」的窗口)** → ② default.conf(仓库,走既有
`deploy_lan.sh` rsync --inplace 同步 conf,bind mount)+ `docker exec poc-nginx nginx -s reload`
(changelog 2026-10-10 既有流程),reload 后立即从 18080(如未收敛)打伪造 XFF 复核被拒 →
dev 按 §2.3 的 dev 口径处置。default.conf 全仓唯一、经 deploy_lan.sh 同步到 dev/prod 两个
checkout(内容一致),信任源写哪些环境的网关由决策点 17 定。

**红线**:`$xfp` map 与 `$http_host` 语义勿回退(dynamic-presign 契约,
`tests/test_dynamic_presign_host.py` 有测试钉死)。

### 2.3 口径与风险

- **历史数据无法回填**(真实 IP 从未被传输),只能「自某时刻起新事件为真实 IP」;
- `request_ip` 列 String(64),无需 migration;
- 信任面口径(容器层):宿主本机进程经 127.0.0.1:80 → docker-proxy → 网关源,同在信任单 IP 内
  (本机进程属可信面,可接受);poc-net 其他容器直连 nginx:80 的源是自身容器 IP,不在信任单 IP 内
  ——这正是「只信网关单 IP、勿放宽子网」的原因。边缘 hairpin 路径:poc-net 内容器经**宿主发布端口**
  (宿主 IP:80 / 127.0.0.1:80)进 nginx 时,源经 docker-proxy/MASQUERADE 也表现为网关(受信),
  可携带伪造 XFF——与 ④ 的可选加固属同一信任边界(能落容器的攻击者本可直连 ms-api:8000),
  风险低,记录即可;网桥重建可能变更网关 IP,环境重建后需复核 ⓪ 实测值;
- ③ 不做(a/b)则公网伪造面照开——此项与 ② 是同一个修复的两半,不可只做 ②;
- **dev 环境口径(勿留半修状态)**:dev 的外网 :8080 是同款裸隧道直通 poc-nginx-dev;
  若把 dev 网关也加进 `set_real_ip_from` 而不处置 :8080,dev 立即获得与 ③ 同款的伪造面。
  两个自洽选项(决策点 17):(a) dev :8080 同款收敛(隧道改绑 127.0.0.1)+ conf 双写两环境
  网关——**注意后果:改绑后 dev 外网 :8080 入口即关闭**(dev 没有跳板机 443 vhost,bucket-taoxiplan.conf
  只服务 prod;dev 如需保留外网入口,须在跳板机为 dev 新增反代 vhost 并同加 XFF,或明示接受关闭
  并写入 ops-manual——「dev 是否还需要外网入口」本身是显式拍板项,不是真实 IP 修复的附带动作);
  (b) 信任源只写 prod 网关,dev 真实 IP 修复暂不生效(dev 审计 IP 仍为
  容器/网关 IP),结论写入 ops-manual。**禁止**只加 dev 网关不收敛 :8080;
- 修完后 ops-manual 与 `public-fallback-entry.md` 的「阶段 4:真实 IP 与登录限流」小节
  标记落地(含 18080 与 dev 处置结论);若 16(a) 落地,`prod-public-entry-runbook.md` 的
  18080 全套流程与回滚节(:65/:96-119/:177-178)整体过时须标记取代,阿里云安全组的 18080
  放行规则(runbook:29/:164/:178)一并收敛(纵深防御);
- **回滚顺序 = 反向**:先撤 ②(还原 default.conf 并 reload),再撤 ①(跳板机去 XFF 头);
  回滚后审计 IP 回落为容器 IP(172.20.0.7 现象复现),登录限流共享桶问题一并回来——回滚是
  整体回退,不存在只回滚一半的安全态。

### 2.4 验收标准

1. ⓪ 实测记录三入口的容器层源 IP,落盘到 ops-manual(443 隧道/18080 隧道/内网直连各一行);
2. 修复后:公网 443 请求的审计 `request_ip` = 用户真实公网 IP;内网直连 = 真实内网 IP;
   不再出现 172.20.0.7;
3. 伪造用例:内网直连带伪造 `X-Forwarded-For` 头 → 审计 IP 仍为真实内网 IP(被覆写);
   ③ 处置后经公网裸通道带伪造 XFF → 审计 IP 同样不可伪造;
4. 登录限流:两个不同公网 IP 各连错 5 次,互不影响(共享桶事故解除)。

---

## 3. W2b:审计显示所属项目名称

### 3.1 根因(三层叠加)

1. **API 不解析**:`GET /api/v1/admin/audit`(`routers/admin.py:118-152`)返回裸列,
   `target_project_id` 是裸 UUID,无名字;
2. **前端不解析**:`AdminAuditPage.tsx:303-316` 收起态只显示 project/asset UUID 前 8 位 + ip
   (key 仅展开态显示),展开态同无名字;过滤参数只有 event_type/actor/from/to
   (**后端已支持 project_id 过滤,admin.py:109-110,前端没暴露**);
3. **写入面不齐**(对账口径:**实施时以全仓 grep `target_asset_id=` 重新拉清单为准**,
   本文档清单是调研期核对结果、不保证穷尽——两轮审查各补出过遗漏点):
   已带 `target_project_id` 的:upload assets.py:213、上传/改元数据/批量改名权限拒绝
   (:85/:581/:749)、`asset.tag_updated`(:611-614,带点号前缀)、`asset.batch_renamed`(:943-944,
   注意既有事件名带点号前缀)、
   baidu_file_imported(`workers/baidu_backup.py:1706-1709`);**漏传**的有:
   - restore 两处 access_denied(:410-415 / :422-427)、asset_restored(:443-448);
   - download_denied(:1039-1045)、signed_url_issued 下载(:1064-1068);
   - delete 两处 access_denied(:1137-1142 / :1150-1156)、asset_deleted(:1225-1228);
   - live-preview 组:download_denied(:1266-1271)、signed_url_issued(:1278-1284);
   - 审批两处:approval_submitted(`routers/approvals.py:150-163`)、
     approval_state_changed(`services/approval_service.py:170-182`)
     (均为 `target_asset_id=… if target_type=="asset"`,不带 target_project_id);
   - 分享:share_asset 权限拒绝(`routers/share.py:91-97`)、share_link_accessed(:193-196)、
     share_link_created(`services/share_service.py:49-61`);
   - asset_purged 两处:assets.py purge 分支(:1205 起)与 `services/asset_purge.py:149-155`
     (均为行将物理删、不能带 target_asset_id——依据 assets.py:1202-1203 的注释口径,
     asset_purge.py:140 注释里的旧交叉引用 814-822 已过时——但
     `target_project_id` 可在删行前先查好补上)。

   注意:缩略图端点(get_thumbnail_url,assets.py:1076-1103)**本来就不写任何审计**;
   若希望缩略图签发也留痕属新增强化,单列拍板,不在本补全清单内。

### 3.2 实施方案

**后端**:

1. 列表端点批量补名:收集页内 `target_asset_id` 集合,一条独立反查
   `assets JOIN folders JOIN projects WHERE assets.id IN (...)`(无 N+1;**反查侧用 LEFT JOIN
   或对集合差集回填 null**——INNER JOIN 只是查不到已 purge 资产的名字,事件行本身不受影响:
   `audit_events.target_asset_id` 是 ondelete SET NULL,行不丢;此提示仅约束补名查询的写法,
   不要在主列表查询上做 JOIN)→ `AuditOut` 增加
   `target_asset_filename` / `target_project_name`;purge 后 asset 行已删的回 null,前端回落显示 key。
   现成参照:`services/target_resolve.py:15-39` 的产出形状(approvals/request_link/notifications
   在用——`services/notifications.py:134/178` 也消费它,补名 helper 的产出形状若变化须知会通知文案面),
   但那是单条反查,审计列表要新写批量版。
2. 写入面补全:上述漏传点逐一补 `target_project_id`(asset_deleted 软删时行还在,事务内先取
   folder.project_id 即可;purge 是物理删,**写审计前**先查好)。**非 asset 分支须单独点名扫描**
   (grep 口径 `target_asset_id=` 只能**定位写入点**,定位不了同一写入点的 folder/sensitive/project
   分支语义——审批两处的三元式本身含该 grep 串,share 的 folder 分支则连 kwarg 都没有,
   须逐点核对分支):① 审批两处(approvals.py:150-163 /
   approval_service.py:170-182)的 folder/sensitive_folder/project 分支,取法复用
   `target_resolve.py:27-39` 的分派;② 分享的 folder 形态——`share_link_accessed` 有**两个**
   写入点(asset 分支 share.py:193-196 已列,folder 分支 share.py:224-230 未列,
   `folder.project_id` 就在手边)与 `share_link_created` 的 `kind != "asset"` 分支
   (share_service.py:52 三元式);
3. **CSV 导出面同用补名 helper**:`GET /api/v1/admin/audit/export.csv`(admin.py:155-215)是独立的
   流式序列化,同样输出裸 `target_project_id/target_asset_id`——批量补名逻辑应同时服务于 CSV 行
   (或明确豁免并记录为遗留项)。注意 CSV 单次 `limit(50000)`(admin.py:170),**不能照搬列表页的
   一条大 `IN`**:按 500–1000 一批分批反查拼装,或明确豁免;
4. 零 migration(`target_project_id` 列已存在,tables.py:264-266)。

**前端**:

1. 收起态元信息行把 `project <UUID>` / `asset <UUID>` 换成「项目名 · 文件名」,key/UUID 保留在展开态;
2. 过滤栏加项目 Select(选项来自现有项目列表接口),透传 `project_id` 参数——
   注意该过滤只命中「写入时带了 target_project_id」的行,历史行无值按 null 容错,不误导;
3. 顺带(拍板点,推荐做):`AppHeader.tsx:105` 的「审计」chip 移入 `is_system_admin` 块内
   (现在所有登录用户可见,点进去 403)。

审计页数据面是 `require_system_admin`(admin.py:129),补名不扩大暴露面,盲搜红线不适用。

### 3.3 验收标准

- 新触发的下载/分享/审批/软删/恢复/purge 事件带 `target_project_id`(按 §3.1 的 grep 口径
  全量对账,不是抽点);
- 审计列表收起态显示「项目名 · 文件名」;purge 后无 asset 行的历史事件回落显示 key,不报错;
- 项目筛选命中新写入的事件;CSV 导出行与列表补名口径一致。

---

## 4. W3:移动端补【备份任务】入口

### 4.1 根因

- 页面与路由都在:`AdminBaiduTasksPage.tsx` + `/admin/baidu-tasks`(App.tsx:76),后端三端点全部
  `require_system_admin`(admin.py:1156/1211/1244),手机直连 URL 可正常打开——**不是权限问题**。
- 移动端导航 = 底部 TabBar + 「更多」Drawer,条目集合硬编码在 `MobileTabBar.tsx:45-51`,
  `/admin/baidu-tasks` 不在其中。该页 2026-10-14(commit 02a12fd)上线时只加了桌面 chip
  (AppHeader.tsx:114),漏改 MobileTabBar——而「新管理页同步补 moreItems」本是既有惯例
  (权限模板 2026-09-30 补过,commit 51c6615)。移动适配方案文档(grep baidu/备份 = 0 次)
  定稿早于该页上线,从未纳入范围。

### 4.2 实施方案(前端小改,后端零改动)

1. `MobileTabBar.tsx` moreItems 的 `is_system_admin` 展开数组内追加
   `{ to: '/admin/baidu-tasks', label: '备份任务', icon: <CloudDownload …/> }`(排「权限模板」后,
   与桌面 AppHeader 顺序一致);`activeTabOf` 无需改;同 PR 顺手更新 moreItems 上方
   「后三个仅系统管理员可见」注释(条目数变化后已过时)。
2. **页面本体必须同 PR 修一处**:主 Table(AdminBaiduTasksPage.tsx:236-254)与 Drawer 文件明细
   Table(:483 起)按 compact 条件注入横向滚动(`scroll={compact ? { x: 'max-content' } : undefined}`,
   hooks 置顶)——固定列合计 806px+ 两弹性列,而 compact 下 main 是 `overflowX:'hidden'`,
   375-834px 视口右侧列(目标/创建时间/失败原因)被裁切且无法横滚。注意 `scroll.x` 是全端属性,
   无条件加会让 PC 窄窗口也出现滚动条,违背零回归验收,故须条件注入。
   只加入口不修这个,手机上打开是半张表,tester 必报新 bug。
3. 顺带(拍板点,推荐):`/admin/folder-templates`(目录模板)是同类遗漏,同 PR 补上。
   **注意不能塞进 `is_system_admin` 展开数组**:该入口是独立三态门
   `is_folder_template_manager ?? is_system_admin`(PC 端 AppHeader.tsx:119 同款口径),
   须在 moreItems 里单独按此三态条件展开,否则仅持 folder_template_manager 的非系统 admin
   组员在移动端看不到入口;
4. 红线:不动 AppHeader PC 分支(PC 零回归);MobileTabBar 改动只动数组数据与 import,
   不得增删 hook(hooks 置顶硬约定)。

### 4.3 验收标准

- <1024 视口「更多」Drawer 里出现「备份任务」;非系统 admin 不出现(无 403 死链);
- 375px 宽视口打开页面,主表与详情 Drawer 文件表可横向滚动看到全部列;
- PC(≥1024)顶栏与页面行为零变化。

---

## 5. W4+W5:目录改名 / 拖拽修改层级

### 5.1 关键前提结论(决定成本)

**全部功能按 DB 行计算,不依赖 prefix 与 key 的相等性**(grep 全部 `minio_prefix` 读取点实证):

- 下载/分享/缩略图/purge 全部读 `assets.minio_bucket/minio_key` 行值;
- 缩略图是独立 bucket + `thumbnails/{asset_id}.jpg`,与 prefix 无关;
- 盲搜/子树计数按 `folder_id IN` / `parent_folder_id` 结构链实时计算(badge 红线保护的不变量);
- **系统内没有任何「按 prefix 扫 MinIO」的逻辑**;百度任务枚举源是网盘目录非 MinIO;
- FGA tuple 只含 parent/explicit/invited 关系引用,**不含 name**。

→ 改名/移动目录**可以不动物理对象**,成本 = DB UPDATE + 一条 FGA tuple。
物理功能层「漂移」无消费方(下载/分享/缩略图/purge 全按 DB 行值),但**展示层有两处用户可见偏差**:
① 目录列表排序(按 minio_prefix order_by,folders.py:192/:204,纯展示层);
② 百度任务文件明细的「预计导入路径」列(web/src/components/BaiduTaskDetail.tsx:105-119,
runtime 按文件夹**当下**
prefix 拼装,routers/baidu_backup.py manifest 端点两级回退)——D1-B/W6 一期 key 不迁后,
**历史成功行会显示新前缀而对象实际在旧 key**(新导入行一致),属已知偏差需知会/文案;
③ 若不同步重算 prefix,新导入对象的落盘前缀与显示名漂移(百度 worker 按当下 prefix 拼 key,
baidu_backup.py:571/:851)。另有资产摘要 Key 面板(AssetSummaryPanel.tsx:176/:198 显示并复制
`assets.minio_key`)——key 不迁时它显示的仍是真实对象位置(与 DB 一致,不构成漂移,但用户会
看到 key 前缀与目录树路径不一致,知会口径应覆盖)。

### 5.2 实施方案

**端点**:`PATCH /api/v1/folders/{id}`,body `{name?, parent_folder_id?}`(改名与移动同端点;
前端两个入口:重命名弹窗 / 拖拽或「移动到」)。权限:普通夹 `can_upload`(与创建对称,
uploader 自主管理目录结构;**注意删除门槛已于 2026-10-16 组级删除授权周期改走
`file_deleter∧can_view` 闸门——移动是重组不是删除,不复用该闸门,是否复用属新增拍板项,
决策点 19**)、sensitive 夹 `can_admin`(删除侧同款理由仍在,folders.py:367-368
「sensitive 的 can_upload 实为 downloader 级…邀请配置价值高」)。

**校验清单**:

- name:复用 `check_segment_name`(folder_chain.py:70-79:禁 `/` `\` `.` `..`、≤255B)——
  现 name 未禁 `/`,新端点必须加段名校验;**并须对齐目录模板的段名口径:拒段首尾空白**
  (`name != name.strip()` → 422,模板入库校验 admin.py:717-719 明确「拒绝而非静默 strip」,
  复用 check_segment_name 单打独斗会造出 `" foo "` 这类模板建链永不允许的段名);
- **新 prefix 长度预算**:改名/移动后子树各夹的新 minio_prefix 须逐夹过 `check_prefix_budget`
  (folder_chain.py:82-87,>1024 字符/字节抛错)→ 违规 400;列宽 String(1024)(tables.py:123),
  超长直接落库会 PG DataError → 500;
- 同父同名 → 409(uq 语义,文案照 folders.py:115-119);
- reparent:目标夹存在且**同项目**(目录跨项目移动 MVP 不做,拍板点);**`parent_folder_id=null`
  (移为项目一级)是合法方向**——校验同上(新一级名不与既有根夹撞 409;**带** grant 一级夹禁移的
  决策点 10 仅约束"移出"一级,移"入"一级无 grant 语义问题),前端「移动到」目标集合须包含项目根
  ——**项目根以树外独立选项/伪节点呈现**(FolderTree 无根节点,buildTree 自 parent=null 起,
  先例 BaiduNewTaskModal.tsx:207-219 的「项目根」即树外选项);
- 目标不能是自身或自身后代(沿 parent_folder_id 链检测防环);
- **sensitive 与目录移动的三句式规则(统一口径,勿散落歧义)**:
  ① 源为 sensitive 夹 → 禁(sensitive 必须挂 project 一级,FGA `parent: [project]`);
  ② 目标为 sensitive 夹或其子树 → 禁(敏感父下的普通子夹是 FGA 断链孤儿,除系统 admin 外恒不可见,
  badge 方案 §6.3,允许移入 = 批量制造不可见资产);
  ③ 普通夹**移出**敏感子树 → **允许**(历史上已存在于敏感子树内的普通夹,移出到正常位置属
  修复性操作:源门槛按普通夹 can_upload,FGA parent tuple 换挂后断链反而修复)。
  sensitive 夹改名允许(一级内改名无结构变化);
- **目标夹权限门槛(reparent 特有,删除没有的一侧)**:目标夹(非敏感)一律 `can_upload` check
  (系统 admin 直通),无权限 403(文案照反探测惯例)——否则仅对某子树有 can_upload 的用户
  可把子树嫁接到项目内任意位置,改变其他成员可见结构;
- **对向并发 reparent 的成环防护(行锁须覆盖双端)**:并发场景「T1 把 A 移入 B、T2 把 B 移入 A」
  若各自只锁被移动夹,后代检测读到的是对方提交前快照,双双通过后成环(A.parent=B 且 B.parent=A)。
  成环后果:后端子树回累有 `seen` 防环兜底(folders.py:229,环内夹变不可达孤儿、计数归 0,
  **不会**死循环),但**前端 FolderTree 的 defaultExpanded 链上溯 while 循环无防环会挂死**
  (FolderTree.tsx:124-133);环约束 DB 层拦不住(自引用 FK 双更新均合法)。
  防护:事务内按固定顺序(如 uuid 排序)对**源夹与目标夹两行同时 `FOR UPDATE`** 后再做后代检测;
  或 UPDATE 后同事务内递归 CTE 自源夹上溯到 project 根做终检,有环即回滚 409。
  **上溯/子树/敏感子树检测一律显式栈迭代,禁递归**(本仓递归深度前科:链深 >~960 即
  RecursionError,folders.py:231-234 注释,建夹无深度限制)。
  (删除先例 folders.py:361-365 的单行锁只挡并发子引用 INSERT,覆盖不了本场景);
- 带 explicit grant 的一级夹禁 reparent(MVP,防 grant 管理能力语义漂移:一级夹才有 grants API,
  folders.py:684-690 `_enforce_level1_folder`;拍板点);
- `SELECT … FOR UPDATE` 行锁防并发(删除先例 folders.py:361-365;reparent 场景的锁范围见上条)。

**FGA(仅一条 tuple,形态随移动方向分派;单请求原子交换)**:reparent =
**单次 `ClientWriteRequest(writes=[新 parent tuple], deletes=[旧 parent tuple])`**(OpenFGA
Write API 单请求事务生效——先例的删/写分两次调用在 move 场景不适用:写新失败 = 子树按旧图
授权或失 parent 不可见,删旧失败 = 双父残留,均是静默权限漂移;删除先例 folders.py:414-432
的「清理失败只留无害孤儿」容错论不适用于 move),DB commit 成功后执行;失败重试并在
`folder_moved` 审计 details 记录交换结果,辅以后台幂等巡检(参照 folder_chain.py:133-150
的幂等 ensure 模式)。子孙 tuple 不动,权限语义随图自动跟随
(can_* from parent,permissions-model-v4.md:83-86)。
**旧 tuple 的 user 形态必须按写入时的实际形态,推荐 read-then-delete 精确匹配**
(先例 assets.py:1186-1197),按方向分派:① 一级夹移入深层(旧父为空)→ 删
`project:<project_id>`(根夹 bootstrap 的 parent 就是 project,folders.py:141-147 else 分支);
② 嵌套夹 → 删 `folder:<旧 parent_folder_id>`(即便旧父是 sensitive 也按 `folder:` 拼——建嵌套
子夹时 parent_type 恒写 `"folder"`,folders.py:137-147,这正是断链孤儿成因;按旧父 is_sensitive
改拼 `sensitive_folder:` 会删空,配合吞错惯例(directory.py:610-611)即静默残留授权);
③ 移为一级(parent_folder_id=null)→ 删 `folder:<旧父>`,写 `project:<pid>`。
OpenFGA 删不存在的 tuple 报 is_not_exists,吞错 + 错形态 = 静默残留第二父。

**minio_prefix 策略(核心拍板点 D1,推荐 B)**:

- A. 只改 name,prefix 漂移:最省,与「prefix 非结构真源」红线自洽;但新导入对象落盘前缀与
  显示名漂移、列表排序随旧前缀漂移,**不推荐**;
- **B. DB 重算整棵子树的 minio_prefix(不动物理对象)——推荐**:新上传/新导入按新路径落盘、
  `folder_chain`「key=prefix+filename」不变量对新对象继续成立;
  既有对象 key 留在旧前缀仅影响 MinIO 控制台人工视角(系统内无消费方)。工程注意:
  ① 子树批量 UPDATE 可能瞬时撞 `uq_folder_project_prefix`(tables.py:132)→ 两段式 UPDATE
  (先改临时前缀再改目标)或按拓扑序,实施时定;② **自拟 prefix 夹**(创建时 `payload.minio_prefix`
  直传、非 `parent_prefix+name` 规则形态,folders.py:95-102)——推荐跟随规则式重算(自拟形态视为
  历史遗留,重算后统一),且重算终态须逐夹预检:与**无结构关系的存量自拟 prefix 行**相撞不是瞬时
  撞 uq,会持久冲突 → 预检命中给明确 409 文案(与 `check_prefix_budget` 同批做);③ 重算窗口内
  并发新建的子夹/百度在途 reserved_key/并发在途的 batch-prefix(以 SELECT 快照的旧 prefix
  算新 key 落库)会按旧前缀落库(prefix 链与父短暂不一致)——被
  「prefix 非结构真源」论吸收,无功能影响,勿当 bug 修;
- C. prefix + 物理对象全对齐(照 batch-prefix 的 copy_object→UPDATE→commit 后 delete 先例):
  大目录(GB 级原片)成本高,不推荐默认。

**D1-B 的语义变化须知(同名唯一性)**:现状「一夹内同名文件不可能」是由 key 唯一
(`uq_asset_minio_object_version`,tables.py:170-171)+ 上传拼 key 规则间接保证的;D1-B 后
新上传按新前缀拼 key,不再与旧前缀下的既有 key 相撞 → 该保证静默丢失。需拍板是否在上传侧补
`(folder_id, filename)` 应用层查重(决策点 14);W6 一期「key 不迁」会进一步扩大同一缺口(见 §6.2)。

**缓存失效**:前端补 `['folders', projectId]`(list 全量返回,一次失效覆盖子树重算)+
`['folder', id]`;`['assets']` 不需要(folder_id 不变)。

**审计**:`folder_renamed` / `folder_moved`,details 记 old/new name、old/new parent_folder_id、
old/new minio_prefix;labels.ts + AdminAuditPage EVENT_TYPES 两处回填。

**前端**:

- PC `FolderTree.tsx`:节点操作加「重命名」「移动到」;`draggable` + `onDrop` + `allowDrop`
  (禁 drop 进自身后代;sensitive 按三句式规则——源/目标涉 sensitive 禁,**移出**敏感子树放行)→
  确认弹窗。antd v6 Tree 原生支持(现未启用,
  FolderTree.tsx:228-236);
- 移动端 Drawer 树不适合拖拽 → 走「移动到」菜单 + FolderTree 既有 `selectMode`/`disabledIds`
  选择目标(BaiduNewTaskModal 已在用同款机制),目标集合含项目根(§5.2 校验);
  **sensitive 三句式的规则③(移出敏感子树)在 GUI 几乎不可达**:孤儿夹不进 FolderTree 拼树
  (badge 方案真根迭代口径),拖拽与「移动到」都选不到它——该方向的入口实际只有系统 admin
  直链目录详情/API,验收正例按此路径执行,不为它做 GUI 入口(MVP);
- 重命名入口挂 ProjectDetailPage 现有 folder 操作区(:585-601 删除按钮旁)。

**连带模块影响清单(全部零连带,附证据)**:分享(token 按 asset id 解析,share.py:186-241)、
审批(决策时动态 check,approval_service.py:47-56;pending 审批决策权随新位置变化属预期,
建议知会)、盲搜(folder_id IN,自动跟随)、子树计数(parent_folder_id 回累,自动跟随)、
百度备份任务(target_folder_id 跟随,prefix 动态拼装)、目录模板(建项目一次性物化,不追踪)。

**唯一竞速窗口——在途 multipart 上传**:改名/移动(D1-B)生效瞬间,已 initiate 未 complete 的
上传在 complete 时会因 key 前缀校验失败被拒(assets.py:140-149「key 与 folder 不匹配」→ 400),
且 MinIO 侧留下未 abort 的 multipart 会话。MVP 处理:complete 的 400 文案明确提示「目录刚被移动/
改名,请重新发起上传」;可选增强=rename/move 前检查活动上传(成本高,不建议默认)。

### 5.3 验收标准

- 改名后:目录树/列表显示新名;新上传对象的 key 落在新 prefix 下;同父重名返回 409;
  **超 prefix 预算(>1024)的改名/移动返回 400;重算终态与无结构关系的存量自拟 prefix 相撞
  返回 409 且文案可定位**;
- reparent 后:子树内资产的 can_view/can_upload 随新位置生效(FGA 图推导);sensitive 按
  三句式:源/目标涉 sensitive 的移动被拒(409/400,文案照反探测惯例),**普通夹移出敏感子树
  成功(正例)**;**对目标夹无 can_upload 的用户 reparent 被拒
  (403 拒绝用例)**;**并发用例:两连接同时执行互为目标的 reparent,恰一个成功一个 409,无环**;
- 前端树在 `['folders']` 失效后刷新正确;`folder_renamed`/`folder_moved` 审计事件文案两处回填。

---

## 6. W6:点选文件批量移动(A→B,支持跨项目)

### 6.1 现状基础(几乎全部已铺好)

- 资产表有 `folder_id`(tables.py:141-143),**无独立 project_id**(项目归属由 folder 链推导);
- `POST /assets/batch-prefix`(assets.py:647-961,2026-10-08)是完整模板:asset_ids ≤1000、
  按 folder 分组逐组权限 check(:730-757)、尽力而为 + skipped_reasons 严格对账(:623-644)、
  key 冲突预检含软删行(:804-813)、单事务 + commit 后物理动作(:884-933)、MinIO 操作
  `asyncio.to_thread` 串行(:792-794);
- 前端多选已有:PC Table `rowSelection` + 跨页保留(ProjectDetailPage.tsx:1053-1060)、
  批量操作栏(:726-764)、移动端 AssetCardList checkbox(:27-31);
- 目标选择弹窗可直接复用 FolderTree `selectMode`。

### 6.2 实施方案

**端点**:`POST /api/v1/assets/batch-move`,body `{asset_ids ≤1000, target_folder_id, cross_project?: bool}`。

**一期(项目内移动,推荐先做)**:

- 物理:**object_key 不动**,只 UPDATE `folder_id` + FGA per-asset parent tuple 删旧写新
  (permissions.py:292-309)——与 W4/W5 的 D1-B 口径一致(系统不信 prefix,功能全按 DB 行);
  可选「对齐模式」迁 key(复用 batch-prefix 同 bucket copy 流程)留作开关,默认关;
  **FGA 写性能与失败语义(一期必须定义)**:每资产恰一对 write+delete tuple(同请求内原子交换,
  同 W5 口径),按 OpenFGA 服务端 per-write tuple 上限(默认 100/请求,**约 50 资产/批**,
  每资产占 2 tuple)分 ~20 批提交,接口设耗时上限(实施实测标定,验收含此项)。
  红线决定 FGA 必然在 DB commit 之后(§8)→ 分批中第 k 批失败时该批资产 **DB 已在新夹、
  FGA parent 仍指旧夹**(看得见打不开 403 / 旧位置成员残留可达),处置:
  单批重试 N 次 → 仍失败则该批计入响应体与审计的 `fga_pending` 清单(**对账恒等式扩展为
  成功 + skipped + fga_pending = 提交数**),后台幂等巡检兜底(读 `object=asset:<id>
  relation=parent` 与 DB 推导形态比对,删错写正,参照 folder_chain.py:133-150 ensure 模式);
  DB 已 commit 后 FGA 失败**不得以 500 掩盖**,返回 200 + 分叉清单。
  **删旧 tuple 的 user 形态须按资产现有 parent tuple 实际形态精确匹配**(read-then-delete,先例
  assets.py:1186-1198):资产的 parent_type 随源夹敏感性而异(`sensitive_folder:<id>` 或
  `folder:<id>`,bootstrap assets.py:203-207),一律按 `folder:` 拼 → 源为敏感夹时删空,旧 tuple
  残留成第二父,旧敏感夹受邀者仍可达该资产(OpenFGA 删不存在的 tuple 会报 is_not_exists,
  directory.py:610-611 有吞错先例——吞错+错形态 = 静默残留授权);
- 权限:逐源夹 `can_upload` + 目标夹 `can_upload`(batch-prefix 同款分组 check);
  **sensitive 源/目标一律 `can_admin`**(删除侧同款理由仍在:敏感夹 can_upload 实为 downloader 级,
  folders.py:367-368);
  目标=敏感夹本身 → 允许(资产本就可存于敏感夹,上传 bootstrap 即 parent_type=sensitive_folder,
  assets.py:203-207),门槛 can_admin;目标=敏感夹后代的普通子夹(孤儿位,badge 方案 §6.3)→ 一律禁;
- 软删行不迁(batch-prefix 先例,assets.py:715);
- **同名策略(一期必须明确)**:key 不迁 → 同名资产进同夹**不撞 uq**(现状「一夹一名」正是靠
  key 唯一间接保证,batch-prefix 的 (bucket,key) 冲突预检同样拦不住)→ 需拍板(决策点 15,推荐:
  目标夹已有同 filename 的资产时 skip,新增 skipped_reason=`duplicate_filename`,与百度导入按
  (folder_id, filename) 查重的既有语义对齐——**查重同样排除软删行**(baidu_backup.py:861-866
  的 `deleted_at.is_(None)` 口径),否则回收站恢复后语义冲突);
- 校验:目标夹存在;**源夹=目标夹 no-op**——整批同夹全 skip,多源夹批次中单资产
  `folder_id == target_folder_id` 亦逐条 skip=`duplicate_location`,不产生 FGA 交换与审计噪音;
  **一期整批必须恰属一个项目**,跨项目混批 400(batch-prefix 的 project_ids
  归集先例可复用,assets.py:726-728);**且显式断言 `target_folder.project_id == 批次 project_id`,
  不等 400**——漏了这条,「项目内」端点就成了事实上的跨项目移动入口,而 FGA/bucket 语义只按
  二期口径设计过。

**二期(跨项目移动,单独一期)**:

- **必须物理迁移**:bucket 每项目一个(`Project.minio_bucket`,tables.py:94),资产 bucket
  = folder 项目 bucket 是系统不变量(上传时强校验,assets.py:147-149)→ 需 `presign.copy_object`
  扩展跨 bucket(同一 `_s3_internal` client 即可,presign.py:224-239 现只支持同 bucket);
  新 key = 目标夹 prefix + filename,冲突加随机后缀(**先例 = 百度导入 reserved_key F2b**,
  `workers/baidu_backup.py:852-855`、表注释 tables.py:626-628;batch-prefix 的冲突语义是
  skip 不加后缀,勿混用——跨项目物理迁移中 skip 会把资产滞留原项目,故用后缀);
  **copy 失败须定义 skip 桶**(照 batch-prefix 的 `key_copy_failed` 语义,assets.py:818-824:
  行不动滞留原项目,计入 skipped_reasons,对账恒等式才闭合);
  **单对象 >5GiB 超 S3 CopyObject 上限**(医美原片视频可能超)→ multipart copy
  (UploadPartCopy/compose)或显式 skip(决策点 18);MinIO server-side copy
  是集群内操作,不走应用带宽,但 GB 级原片大批量仍建议分批(≤1000 上限沿用);
- FGA per-asset tuple 改写 = **权限面突变**(原项目授权者失访、目标项目角色获权)→ 前端二次确认
  (明示「移动后原项目成员将无法访问」)+ 审计 details 记 from/to project + `target_project_id`;
  **目标项目必须排除已逻辑删除项目**(projects.deleted_at 深隐藏,tables.py:103;前端项目 Select
  与后端校验都过滤,口径同项目列表);
- 审批临时 grant(asset 级 explicit_downloader,approval_service.py:84-131)随迁保留(拍板点,
  推荐:asset 级授权与项目无关);
- 缩略图不受影响(全局 thumbs bucket + asset-id 基 key)。

**审计**:`asset_batch_moved`(details:from/to folder、from/to project、成功数、skipped_reasons);
两处事件文案回填同前。

**缓存**:`['assets']` 广域失效 + `['folders', 源/目标 projectId]`(subtree_file_count 两端变化)。

**前端**:批量操作栏加「移动」;弹窗 = 项目 Select(默认当前项目;列出可选项目,server 端最终权限
把关)+ FolderTree selectMode 选目标(禁 sensitive);移动端 AssetCardList 选中后操作栏同款入口。

### 6.3 风险与注意

- 移动后 object_key 留在旧 folder 前缀下:**物理功能无消费方**(下载/分享/缩略图全按 DB 行,
  grep 实证),但展示层有两处用户可见偏差(百度任务「预计导入路径」列按当下 prefix 重拼、
  资产 Key 面板显示旧 key——详见 §5.1),知会/文案须覆盖,否则 tester 会报「路径对不上」;
  若用户在意可与 D1-C 的「对齐模式」合并做;
- 跨项目移动后,原项目 pending 审批的决策权随新位置变化(approval 动态 check)——预期行为,知会;
- 批量上限 1000 与串行 copy 的耗时:跨项目大批量建议 arq 异步化(可选增强,拍板点);
- **二期是数据不可逆操作**:沿用 batch-prefix 先例,commit 成功后旧 bucket 中的原对象被物理删除
  ——代码回滚只回退逻辑,已迁移对象不回迁,恢复只能靠备份镜像兜底。上线窗口选择与
  备份镜像核对(ops-manual 备份节)应纳入二期实施前置。

### 6.4 验收标准

- 对账照 batch-prefix 语义:成功数 + skipped_reasons 条目数 = 提交数,逐条可解释;
- 一期同名策略生效(决策点 15):目标夹同名 → skip 并出现在 skipped_reasons,不产生同夹同名行;
- 二期跨项目:移动后下载 presign 指向新 bucket;原项目成员访问 403、目标项目角色可访问;
  审计 `asset_batch_moved` details 含 from/to project;旧对象在 commit 成功后被删除(失败悬挂引用
  有重验防线,照 batch-prefix 先例)。

---

## 7. 决策点汇总(实施前需拍板)

| # | 决策 | 推荐 |
|---|------|------|
| 1 | W1 解锁是否连带清 IP 维度锁 | 是,按审计近 24h 失败 IP 连带清(W2a 落地前反查到的 IP 恒为 172.20.0.7,该连带清实际等价于清共享桶;真实 IP 反查自 W2a 生效起可用) |
| 2 | W1 重置密码时顺带解锁 | 是 |
| 3 | W1 补 `local_login_locked` 审计事件(消盲区) | 是 |
| 4 | ~~跳板机 conf 备份落点是否安全~~ **已消解,非决策**:`scripts/env/` 受 `scripts/.gitignore`(`env/` 规则)保护,直接落盘 + `git status` 复核即可 |
| 5 | W2 uvicorn `forwarded-allow-ips '*'` 是否收紧为网段 | 暂不(入口已收敛),留加固 backlog |
| 6 | W2b 审计 chip 收进 is_system_admin 块 | 是 |
| 7 | W3 目录模板移动端入口是否顺带补 | 是 |
| 8 | W4/W5 prefix 策略 A/B/C(即 §5.2 的拍板点 D1) | **B:DB 重算子树 prefix,不动物理对象** |
| 9 | 目录移动是否限同项目 | MVP 限同项目(用户需求仅文件要跨项目) |
| 10 | 带 explicit grant 的一级夹禁移 | MVP 禁 |
| 11 | W6 跨项目移动是否拆二期 | 拆:一期项目内,二期跨项目 |
| 12 | W6 项目内移动是否迁 object_key | 不迁(D1-B 同口径);「对齐模式」留开关 |
| 13 | W6 跨项目大批量是否 arq 异步化 | 二期视实测耗时定 |
| 14 | D1-B 后上传侧是否补 (folder_id, filename) 同名查重 | 建议补轻量应用层查重;**本项是决策点 8 选 B 的同 PR 前置**——8=B 而 14=否 = 「一夹一名」语义静默丢失带病上线,除非显式接受并写入 ops-manual |
| 15 | W6 一期目标夹同名处置 | skip(新增 skipped_reason=duplicate_filename),与百度导入语义对齐 |
| 16 | W2a 公网 18080 裸隧道入口处置 | ~~a:收敛关闭~~ → **2026-10-19 用户改拍 b:保留端口,改经跳板机 nginx 反代**(+XFF,隧道后移回环 :18081,对外 URL 不变;实现=ops-manual §11.4/w2a runbook §3) |
| 17 | W2a dev 环境口径(:8080 + dev 网关) | **2026-10-19 随 16 改拍 b:dev :8080 同款反代保留**(隧道后移 :8081,dev 外网入口不再关闭)+ conf 双写两网关。禁止半修(加 dev 网关而不处置 8080)。退化依赖不变:若 ⓪ 实测两环境共享网桥,只能双网关都写或整体缓行 |
| 18 | W6 二期单对象 >5GiB(超 CopyObject 上限)处置 | multipart copy(UploadPartCopy/compose)或显式 skip 计入 skipped_reasons;推荐 MVP 先显式 skip + 提示,大对象迁移按需再开 multipart |
| 19 | W4/W5 目录移动门槛是否复用组级删除授权闸门(file_deleter∧can_view) | MVP 不复用,仍按 can_upload(移动是重组不是删除,与创建对称);复用与否留待组级授权语义稳定后再议 |

## 8. 通用硬约定(实施时勿踩)

- 新 event_type 必须同步回填 **两处**:`web/src/lib/labels.ts` 的 `EVENT_TYPE_LABEL` +
  `AdminAuditPage.tsx` 的 `EVENT_TYPES` 下拉数组(:40 起;2026-10-14 曾发生过「审计有事件但下拉没有」
  的历史事故,与本方案工作包编号无关,同源教训);
- **每个工作包交付须带最小 pytest 用例**(容器内跑,CLAUDE.md 既有惯例),最小集合:
  W1=锁定→解锁→登录 429→200;W2b=补名/过滤;W3=前端项(tsc+lint 即可);W4/W5=环检测 409、
  sensitive 三句式、prefix 预算 400、同名 409;W6=对账恒等式(成功+skipped+fga_pending=提交数)
  与同名/同夹 skip;
- **用户可感知的更新当天写 `scripts/changelog.md` 记账**(AGENTS.md 约定,六个 WP 全部用户可感知);
- 改任何权限相关代码,一次 grep 所有 `permissions.check` **和** `list_objects` 调用点
 (「有权限但看不见」陷阱,CLAUDE.md 既定);
- 子树计数回累只走 `parent_folder_id`,**禁 minio_prefix 前缀匹配**(badge 红线);
- FGA tuple 改写一律放 DB commit 成功之后(删除先例);
- nginx `$xfp` map 与 `$http_host` 语义勿回退(dynamic-presign 契约测试钉死);
- 移动端改动:PC 分支零回归、hooks 置顶、MobileTabBar 只动 moreItems 数据。
