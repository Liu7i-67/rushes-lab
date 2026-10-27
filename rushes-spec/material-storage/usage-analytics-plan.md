# 方案:客户端使用统计(三端占比 + 内外网占比)——依托审计模块拓展

> 目标:回答两个运营问题——
> ① **web 端 / Android App / iOS App 的使用占比**;
> ② **经内网访问与经外网访问的人数占比**。
> 路线:**不新建埋点体系**,在既有 `audit_events`(已带 `request_ip` / `user_agent` / `actor_user_id`,业务与登录事件全量落库)之上补三块:App 端可识别 User-Agent、后端聚合统计端点、admin「使用统计」页。
> 改动量:1 个轻量索引迁移(0018)+ 后端 1 个只读聚合端点 + 1 处审计调用补 ctx(§4.2 伴随项)+ App 一处 header + web 一个 admin 页;**不新增 event_type、无 FGA 变更、无新外部依赖**。

## 1. 现状盘点(结论:基建已 80% 就绪)

| 事实 | 证据 |
| --- | --- |
| `audit_events` 已有 `request_ip`(String64)、`user_agent`(String512,write 侧截断)、`actor_user_id`、`details` JSONB | `api/app/db/tables.py:240` `AuditEvent` |
| 绝大多数用户主动操作的审计写入**均带 IP/UA**(`**ctx` 展开或直读 header——directory.py 有 9 处直读、admin.py 显式取键,形态不一,结果一致) | `api/app/deps.py:159` `get_request_context()`;auth/assets/folders/projects/admin/baidu_backup/share/approvals/directory |
| **例外**:`share_link_created` 走 service 层签名无 ctx(`services/share_service.py:37` 起,调用点 `routers/share.py:105/:152`),UA 为 NULL;后台/worker 事件(`notification_sent` ×3、**worker 侧** asset_purged(router 侧用户硬删除带 `**ctx`,正常计入)、approval ctx=None 分支)同样无 IP/UA | `services/share_service.py:64-78`、`services/notifications.py:151-253`、`services/asset_purge.py:154-161`、`services/approval_service.py:196-199` |
| 登录事件已存在且带 IP/UA | `local_login_success` / `local_login_failed` / `local_login_locked`(`routers/auth.py`) |
| W2a(2026-10-19)后 request_ip=真实客户端 IP:外网经跳板机 nginx(XFF)→hh2 poc-nginx(realip,`set_real_ip_from 172.20.0.1/172.22.0.1`)→ uvicorn `--proxy-headers` → `request.client.host`;内网直达 hh2:80 同链路 | `poc/minio/nginx/default.conf:26-45`;`Dockerfile:33`;ops-manual §11;DB 已实证公网 IP、docker 网关 172.20.0.7 消失 |
| **内外网天然可判**:外网访问 request_ip=公网 IP;内网直达=私有网段 IP | 上行链路推论(§4.2 network 解析) |
| App 主 Dio **未设自定义 UA**(默认 `Dart/x.y (dart:io)`,iOS/Android 不可区分) | `app/lib/core/api/ms_api.dart:102` `BaseOptions` 无 headers |
| admin 已有审计明细查询 + CSV,**无聚合** | `routers/admin.py:257` `/admin/audit`、`:307` `/audit/export.csv` |
| `event_time` 无独立索引:仅作为两个复合索引的第二列存在(`ix_audit_event_type_time` / `ix_audit_actor_time`,`tables.py:285-288`),纯时间范围扫描(active_users 主查询)无可用索引;logins 口径(event_type + 时间)已被复合索引覆盖 | `tables.py:278-288`;迁移链最新 **0017**(revision id `20261019_0017`) |

**差距只有三点**:App 端 UA 无法区分平台;无聚合统计端点;`event_time` 无索引。

## 2. 选型:依托审计 vs 独立埋点表

| | 依托 audit_events(本方案) | 独立埋点表 / 心跳事件 |
| --- | --- | --- |
| 数据 | 业务动作 + 登录已全量带 IP/UA/actor,历史数据立即可溯 | 需新增事件类型/表、双写、迁移 |
| 能回答 | 三端占比、内外网占比(本次两问) | 额外可答浏览 PV、会话时长、留存 |
| 成本 | 聚合端点 + App UA header | 埋点 SDK 语义、采样、噪声治理、存储 |
| 风险 | 无写入路径改动 | 心跳高频写入、审计表语义稀释 |

**结论:依托审计**。本次两问不涉及 PV/时长;若未来要做页面级埋点,再议 `session_touch` 低频心跳事件(见 §9 遗留)。

## 3. 口径定义

### 3.1 维度枚举

- **platform**(`user_agent` 解析):
  `android_app` / `ios_app` / `app_legacy`(存量 App ≤0.1.10,Dart UA,平台未知)/ `web_desktop` / `web_mobile`。
  (`unknown` 仅当 UA 为空时出现——`audit.write` 把空串归一为 None(`services/audit.py:73`,C2 后补),**新写入数据不可达**;C2 归一化之前的历史空串行若存在则可达,故保留 SQL 兜底分支与 UI 兜底文案,枚举不设。)
- **network**(`request_ip` 解析):`lan`(私有网段)/ `wan`(公网)/ `unknown`(NULL、空串、或哨兵字符串 `'unknown'`——`routers/auth.py:293` 在 ctx 缺 IP 时写的就是这个字符串)。

### 3.2 指标口径(端点同时返回,页面可切换)

- **active_users(主口径)**:时间范围内 `audit_events` 中**真实客户端发起**的事件(`user_agent IS NOT NULL`,天然排除 worker 侧 sidecar/百度任务事件;并显式排除 `local_login_failed` / `local_login_locked` ——用户名存在但密码错的失败尝试**带 actor 且 UA 非空**(`routers/auth.py:315`),尝试不算使用,爆破流量更不该计入人数)按 `actor_user_id` 去重。一个用户用两台设备 → 两端各计 1。
- **logins(辅口径)**:仅 `event_type = 'local_login_success'`,同样按 actor 去重 + 附登录次数。
  存在意义:口径最干净(每次登录必带 IP/UA);但 App cookie 7 天免登,会低估 App 活跃,故不作默认。
  边界:仅覆盖本地账号登录;OIDC `/auth/callback`(`routers/auth.py:77-117`)签发同一 session 但无登录审计——当前未配置 OIDC 时不可达(`settings.oidc_provider` 为空直接 400),如未来启用须先补该事件(§9)。
- **人数占比分母** = 周期内去重用户总数(actor 维);多端用户计入多个端,**各端占比之和可 >100%**,页面标注「多端用户重复计数」。「web 端」合计人数用 `by_platform_class` 的 `web` 行(粗粒度分组内去重),**不是** by_platform 两行求和。actor 为 NULL 的匿名事件(若未来放开匿名分享访问)不计人数;**带 actor 的失败登录已被口径显式排除**(§3.2 active_users 定义)。
- **按天序列**分桶时区固定 `Asia/Shanghai`(中国单一时区团队,避免 UTC 跨天歧义)。

## 4. 改动设计

### 4.1 App:主 Dio 注入可识别 User-Agent

- 格式(业界惯例 `product/version (comment)`):**`msapp/<version> (<platform>)`**,如 `msapp/0.1.11 (android)` / `msapp/0.1.11 (ios)`。
- 实现:`ms_api.dart` 主 Dio `BaseOptions` 增加 `headers: {'User-Agent': kClientUserAgent}`;
  - platform:`dart:io` `Platform.isIOS` 同步判定(`android` / `ios`);
  - version:走 **dart-define 编译期注入**(与 `main.dart:29` `kAppBuildStamp` 同款模式),**注入值取 release 链 bump 后的目标版本**(release.mjs 先改 pubspec 再 build——若在脚本开头读 pubspec 旧值会永久滞后一版;`--no-bump` 路径取当前版本),未注入时为空串 `msapp/ (android)` —— 解析只依赖 `(android)`/`(ios)` 段,版本缺失可接受。**不用** `PackageInfo.fromPlatform()` 异步回填(MsApi 构造是同步的,回填存在竞态窗口,不值得)。
- 不挂 UA 的通道(均为有意):`_put` 裸 Dio(直连 MinIO presigned,不经 ms-api、不产生审计)、`session.dart` 探活 Dio(匿名 GET,无审计)、缩略图静态 HttpClient(同前)。
- 存量兼容:≤0.1.10 的已装 App UA 仍是 `Dart/…`,解析归 `app_legacy`,随版本升级自然消亡(stats 持续输出 legacy 占比可观察覆盖进度)。

### 4.2 后端:聚合服务 `services/usage_stats.py`

- **解析逻辑单点**:platform / network 的解析**只在 SQL 聚合表达式里实现**(CASE WHEN),不做 Python/SQL 双实现(漂移风险)。正确性由集成测试保证:造多组 UA/IP 样本数据,断言分桶结果(§7)。
- platform SQL 规则序(自上而下首中即归,顺序是语义的一部分——**App 标记优先于浏览器 Mobile 标记**;匹配一律用 `ILIKE` 免 casing 依赖):

  | 序 | 条件(user_agent) | 归类 |
  | --- | --- | --- |
  | 1 | `ILIKE '%msapp%'` 且 `ILIKE '%(android)%'` | `android_app` |
  | 2 | `ILIKE '%msapp%'` 且 `ILIKE '%(ios)%'` | `ios_app` |
  | 3 | `ILIKE '%msapp%'` 或 `ILIKE '%Dart%'` | `app_legacy`(App 但平台未知:存量 Dart UA,或未来 msapp UA 漏平台段的变体——平台段匹配收紧到带括号形态后,如 `msapp/bios` 这类子串误命中落此兜底) |
  | 4 | 含 `Android` / `iPhone` / `iPad` / `iPod`(Android 平板无 Mobile 标记亦归此) | `web_mobile` |
  | 5 | 非空 | `web_desktop` |
  | 6 | NULL/空 | `unknown` |

  注:Dart 默认 UA `Dart/3.x (dart:io)` 不含 Mobile 标记,规则 4 不会抢走;msapp 标记为自定义值,浏览器 UA 不会自然命中;规则 6 在本查询(UA 非空过滤)下恒不可达,仅作 CASE 兜底分支保留。
- network SQL 规则(`request_ip` 文本正则,覆盖 RFC1918 + loopback + link-local + IPv6 ULA):

  | 序 | 条件 | 归类 |
  | --- | --- | --- |
  | 1 | NULL / 空串 / `'unknown'`(auth.py 的哨兵字符串) | `unknown` |
  | 2 | `~*` 正则 `^(10\.|192\.168\.|172\.(1[6-9]\|2[0-9]\|3[01])\.|127\.|169\.254\.|::1$|::ffff:(10\.\|192\.168\.\|172\.(1[6-9]\|2[0-9]\|3[01])\.)|f[cd][0-9a-f]{2}:|fe80:)`(大小写不敏感,兼容 IPv6 文本大写;`::1` loopback 与 **IPv4-mapped 私网 `::ffff:10.0.0.1` 形态**显式覆盖) | `lan` |
  | 3 | 其余 | `wan` |

  注:172.15/172.32 等非 /12 段不得误配(正则分段写死);`172.20.x`/`172.22.x`(docker 网关,XFF 意外缺失时的兜底表现)归 `lan`,语义上「未经过公网入口」,可接受。
- 聚合形态(**一条查询,`GROUPING SETS` 多粒度并出**,禁止拉明细到内存;`count(DISTINCT)` **跨组不可加**——这是本节核心不变量):

```sql
SELECT <platform_case> AS platform, <network_case> AS network,
       count(DISTINCT actor_user_id) AS users, count(*) AS events
FROM audit_events
WHERE event_time >= :from AND event_time < :to
  AND actor_user_id IS NOT NULL
  AND user_agent IS NOT NULL            -- active_users 口径
  AND event_type NOT IN ('local_login_failed', 'local_login_locked')
  [-- AND event_type = 'local_login_success']  -- logins 口径
GROUP BY GROUPING SETS (
  (),               -- totals:全窗口一行,users=去重用户总数
  (platform),       -- by_platform:每端独立去重
  (platform_class), -- by_platform_class:粗粒度三端(web / android_app / ios_app / app_legacy)
  (network),        -- by_network
  (platform, network)  -- cross
)
```

  每个 grouping set 内 `count(DISTINCT actor_user_id)` 独立去重,**by_platform / by_platform_class / by_network 的 users 值由各自分组直接产出,严禁从 cross 行或彼此求和推导**(同一用户跨 network 计两次时,cross 行求和 ≠ by_platform 值;与 D4 多端语义同理)。**`platform_class` 粗粒度分组**(目标①的直接产出):`web_desktop`/`web_mobile` 归并为 `web`,其余原值——同一用户 PC + 手机浏览器双用时,`by_platform` 两行各自去重、求和会虚增,`by_platform_class` 的 `web` 行才是"web 端去重人数"的正确单一数字。日序列单独一条查询,分组固定为 `(date_trunc('day', event_time AT TIME ZONE 'Asia/Shanghai'), platform, network)` 的**完整三元组合行**(不做日粒度的部分合计行;daily 分组的 platform/network 由 CASE else 兜底恒非 NULL,unknown 作为合法枚举值正常输出)。实现用 **raw SQL(`text()` + 绑定参数,asyncpg)**——SQLAlchemy ORM 的生成式 `group_by()` 不支持 GROUPING SETS。

### 4.2b 伴随补齐:`share_link_created` 传入 ctx

`create_share`(`services/share_service.py:37` 起)当前签名无 ctx,写出的 `share_link_created` UA/IP 为 NULL,会被 active_users 口径排除——这是**用户主动操作**,不应漏计。修法:函数加 `ctx: dict[str, str | None]` 形参,`audit.write(..., request_ip=ctx.get("request_ip"), user_agent=ctx.get("user_agent"))`(照 `services/folder_templates.py:131-132` 既有写法),调用点 `routers/share.py:105` 与 :152(folder 分支)由 router 的 `get_request_context` 依赖传入。后台/worker 事件(notification_sent、asset_purged 等)**不加**:它们本来就该被口径排除。

### 4.3 端点:`GET /api/v1/admin/usage/stats`

- 权限:`require_system_admin`(与 `/admin/audit` 一致)。
- 参数:`from` / `to`(**tz-aware** ISO 时间,naive 值 422)、`metric=active_users|logins`(默认 `active_users`)、`daily=true|false`(默认 true)。时间规则写死(四种组合均可服务):双缺省 → `from=now-30d, to=now`;仅缺 `to` → `to=now`;仅缺 `from` → `from=to-30d`;校验 `from >= to` → 422;窗口 `> 366 天` → 422(无界/超长窗口拒绝)。**两口径统一保留 `user_agent IS NOT NULL` 过滤**(与「真实客户端」语义一致,过滤条件单处定义;客户端不带 UA 头的登录极罕见,丢弃可接受)。
- 响应示例:

```json
{
  "metric": "active_users", "from": "2026-10-01T00:00:00+08:00", "to": "2026-10-28T00:00:00+08:00",
  "totals": {"users": 42, "events": 1832},
  "by_platform": [{"platform": "ios_app", "users": 18, "events": 821}, ...],
  "by_platform_class": [{"platform_class": "web", "users": 27, "events": 910}, ...],
  "by_network":  [{"network": "lan", "users": 25, "events": 1021}, ...],
  "cross":       [{"platform": "ios_app", "network": "lan", "users": 12, "events": 430}, ...],
  "daily":       [{"date": "2026-10-20", "platform": "ios_app", "network": "lan", "users": 9, "events": 120}, ...]
}
```

- 只读端点,无写入副作用;不导出个人级 IP/UA 明细(明细需求走既有 `/admin/audit`,权限同为 system admin)。

### 4.4 迁移 0018:`audit_events.event_time` 索引

- 新迁移 `2026_10_27_0018_audit_event_time_index.py`:`down_revision` 指向 **0017 的 revision id `"20261019_0017"`**(`versions/2026_10_19_0017_baidu_multi_task_concurrency.py:31`;勿把文件名当 revision id),`create_index("ix_audit_event_time", "audit_events", ["event_time"])`(索引名对齐既有 `ix_audit_event_type_time` / `ix_audit_actor_time` 无表名尾 s 的风格),down 为 drop。**`tables.py` 模型元数据同批改**(`AuditEvent.__table_args__` 加同名 `Index`)——沿 0017 惯例(其文件头注释明确该约定,`tests/test_db_schema.py:65-69` 读模型元数据断言索引,须补成员断言)。
- active_users 主查询是纯 `event_time` 范围谓词,现有复合索引(event_time 均为第二列)用不上;当前几十万行级 seq scan 代价尚低,索引属低成本防患、表增长后收益放大。非 CONCURRENTLY 的 `CREATE INDEX` 建索引期间持锁短暂阻塞审计写入——几十万行亚秒级,沿 0017 plain `create_index` 惯例即可;表显著增长后再议 CONCURRENTLY。**⚠ hh2 部署链无 alembic 步骤**(`material-storage/scripts/deploy_lan.sh` 只 rsync + 写 DEPLOYED.md + 可选 restart,`api/scripts/deploy_server2.sh:175` 才有 alembic)——0018 须部署后在目标机显式执行 `docker compose exec ms-api alembic upgrade head`,否则索引静默漏建(§8 步骤已含)。
- ⚠ 并行分支各写迁移会撞 revision/双头,merge 后改后合入方的 `down_revision`(既有惯例)。

### 4.5 web admin:「使用统计」页

- 位置:admin console 新页(与审计页并列);`web/src/api/hooks.ts` 新增一个 react-query hook(每 endpoint 一 hook 的既有惯例)。
- 展示:两块占比条(platform / network;**platform 主展示用 `by_platform_class`**——web/android_app/ios_app/app_legacy 四行直接回答目标①,by_platform(web_desktop/web_mobile 拆分)作下钻明细;标注多端用户重复计数)+ 交叉表格 + 按天趋势(**antd 核心无图表组件**;趋势用条形——Progress / 自绘简版色条即可,**不引图表库**,与 D6 一致);日期范围选择(默认 30 天)+ metric 切换。日趋势数据用 `events`(跨行可加);**daily 的 `users` 跨行不可加**(同日跨 network 求和会重复计数),若按日展示 users 须只取单一完整维度切片,禁止对 daily 行求和。`platform` / `network` 的 `unknown` 值给兜底文案(历史空串行的理论来源,§3.1)。
- 响应解析直接用端点聚合值,前端不做 UA/IP 二次解析(与 §4.2 单点原则一致)。

## 5. 决策记录

| # | 决策 | 理由 |
| --- | --- | --- |
| D1 | 依托 audit_events,不建独立埋点表/心跳 | 所需维度(IP/UA/actor)已全量存在,历史可溯;无新事件类型、无表/列变更(§4.4 仅新增只读索引;§4.2b 仅给既有写入补上下文参数) |
| D2 | active_users 为主口径,logins 为辅 | App cookie 7 天免登,登录口径低估 App;业务事件随真实使用发生 |
| D3 | App UA 格式 `msapp/<version> (<platform>)`;版本走 dart-define 注入 | 业界 UA 惯例;编译期注入零竞态(kAppBuildStamp 同款先例) |
| D4 | 多端用户占比重复计数(分母=去重用户,各端占比和可 >100%) | 简单诚实;「主端」归一口径需要额外定义且信息量低,不做 |
| D5 | 解析逻辑只在 SQL 实现,无 Python 双实现 | 防漂移;正确性靠集成测试样本断言 |
| D6 | admin 页本期做简版(占比条+表格+antd 内置趋势) | 满足「了解情况」即可,不为图表引依赖 |
| D7 | 0018 event_time 单列索引随本期上 | active_users 纯时间范围扫描现无可用索引;低成本防患,表增长后收益放大 |
| D8 | 日分桶时区固定 Asia/Shanghai | 单一时区团队,消除 UTC 跨天歧义 |

## 6. 风险与已知局限

1. **存量 App UA 不可分平台**(`app_legacy`):随用户升级消亡;stats 输出 legacy 占比可观察;不在服务端猜测补救。
2. **XFF 伪造面(机制澄清)**:外网链路上伪造实际无效——hh2 poc-nginx realip `recursive off` 取 XFF **最后一个**地址(`poc/minio/nginx/default.conf:26`),而跳板机 `$proxy_add_x_forwarded_for` 把真实客户端 IP 追加在链尾,客户端自带的前缀伪造值恰好被忽略。真正残余的伪造面仅剩「直连 hh2:80 且源 IP 恰好等于信任地址 172.20.0.1/172.22.0.1(docker-proxy 路径)」的流量,而内网直达实测源 IP 为客户端私网地址,该面近乎为零。占比统计影响可忽略;运维侧仍可改跳板机为覆盖式 `$remote_addr` 进一步收敛,不在本期(§9)。
3. **匿名事件不计人数**(actor NULL,如未来放开匿名分享访问时;当前分享解析端点始终 require login,`share_link_accessed` 均带 actor):口径如此;**带 actor 的失败登录/锁定事件**(`routers/auth.py:315` user 存在但密码错时 actor 非空)已由 §3.2 显式排除出 active_users(尝试不算使用);如需「匿名访问量/失败尝试量」可后续在 stats 加 events-only 维度。
4. **「真实客户端事件」= `user_agent IS NOT NULL` 过滤**:这是**有意排除**——UA NULL 的是 worker/后台事件(§1 例外清单),本就不该计入使用统计;唯一被误伤的用户主动事件 `share_link_created` 由 §4.2b 补齐。依赖「业务 router 全带 ctx、service/worker 层不带」的既有约定;未来新增 service 层审计若忘带 ctx,该事件不进统计(静默少计而非错计),集成测试覆盖现状即可,不额外加防线。
5. **性能**:30 天窗口 + event_time 索引下聚合为单范围扫;端点仅 system admin 可达、低频;无分页(聚合本身就是全量归并)。
6. **隐私**:输出仅聚合计数,无个人级 IP/UA;仓库公开,文档与测试不使用真实用户数据。
7. **App 发版节奏**:App UA 随下一版 App 发布(0.1.11+)才生效;期间 stats 已可用(web/legacy/网络维度立即有数)。
8. **W2a 历史数据界限(2026-10-19)**:真实 IP 链路 W2a 生效于 2026-10-19;此前外网访问的 `request_ip` 量产为 docker 网关 172.20.0.x,全部落 `lan`。回看窗口跨该日时 network 维度会系统性高估内网占比——页面文案提示「网络维度自 2026-10-19 起可信」,统计端不做历史改写。
9. **platform/network 维度的已知噪声**:iPadOS 13+ Safari 默认报桌面 UA → 归 `web_desktop`(iPad 无法从 web 维度识别);curl/脚本等非浏览器 UA 按规则 5 归 `web_desktop`(验收用的 curl 须带 `-A`,量级极小);零压缩 IPv6 ULA(如 `fd::1`)不匹配私网正则误归 `wan`(hh2 内网为 IPv4 私网,真实流量不会出现)。均不修规则,如实记为口径边界。

## 7. 测试与验收

- **单测/集成**(容器内 `pytest -o asyncio_mode=auto`):
  - platform:各 platform 类别至少 1 个 UA 样本 + 边界(`msapp/0.1.11 (android)`、`msapp/ (android)` 无版本、`msapp/0.2.0` 漏平台段(须 app_legacy)、`Dart/3.5 (dart:io)`、含 `Android` 的 Android 平板 UA(无 Mobile 标记,须 web_mobile)、iPhone Safari、桌面 Chrome;空 UA 行须**绕过 `audit.write` 直插**(服务层已把空串归一 None,直插才能覆盖历史空串行→unknown 的兜底分支);
  - network 正则边界:`172.15.x`/`172.32.x`/`172.168.x`(须 wan)、`172.20.x`(须 lan)、`10.x`/`192.168.x`/`127.0.0.1`/`::1`/`FD00::`(大写)/`fe80::`(须 lan)、**`::ffff:10.0.0.1`(须 lan)/`::ffff:8.8.8.8`(须 wan,IPv4-mapped 形态)**、公网 IP(wan)、NULL / `''` / `'unknown'` 哨兵(须 unknown);零压缩 ULA(如 `fd::1`,正则要求前两组两位 hex)误归 wan——**接受的口径边界**(hh2 内网为 IPv4 私网,真实流量不会出现该形态,记入 §6.9 同款噪声清单);
  - 端点时间参数:四分支(双缺省默认 30 天/仅 from→to=now/仅 to→from=to-30d)、乱序 from≥to(422)、naive datetime(422)、窗口 >366 天(422);
  - 聚合端点:seed 多用户多 UA/IP 事件 → 断言 by_platform/by_platform_class/by_network/cross/daily 数值与去重语义;**by_platform_class 对账断言**:构造同一用户 web_desktop+web_mobile 双用样本,断言 `by_platform_class.web.users = 1` 而 `by_platform 两行 users 各为 1(求和=2 虚增)`;**失败登录排除断言**(带 actor 的 `local_login_failed` 不进 active_users);**对账断言**(count DISTINCT 跨组不可加):存在跨 network 用户时 `by_platform.users ≠ 该 platform 的 cross 行 users 求和`,存在多端用户时 `totals.users ≠ by_platform 行 users 求和`;logins 口径只计登录事件;worker 事件(UA NULL)不进 active_users;`share_link_created` 补 ctx 后出现在 active_users(端点回归该事件 UA 非空)。
  - 权限:非 system admin 403;未认证 401。
- **dev 端到端验收**:
  1. 浏览器(dev 内网入口)登录操作一次 → stats 出现 `web_desktop` + `lan`;
  2. 经跳板机公网域名访问一次 → `wan`;
  3. `curl -A 'msapp/0.1.11 (android)'` 打登录 → `android_app`;
  4. 旧 UA `curl -A 'Dart/3.5 (dart:io)'` → `app_legacy`。
- **App 侧**:analyze 0;既有测试全绿(UA header 不影响行为断言);真机抓一次登录请求核对 UA 落库(`admin/audit` 明细可见)。

## 8. 实施顺序与回滚

1. 后端:0018 迁移 + `usage_stats` 服务 + `/admin/usage/stats` + `share_link_created` 补 ctx(§4.2b)+ 测试;
2. App:主 Dio UA header + release 构建链 dart-define;
3. web:「使用统计」页;
4. dev 部署(**rsync 后在 hh2 显式执行 `docker compose exec ms-api alembic upgrade head`——deploy_lan.sh 无 alembic 步骤,勿依赖**)跑 §7 端到端四组 → prod 同样补迁移步骤。

回滚:端点/页面纯只读,下线无副作用;索引 down 一条 drop;App UA 无行为耦合,回退无感。

## 9. 遗留项

- 跳板机 nginx XFF 改覆盖式根治伪造(运维人工,低优先);
- PV 级页面埋点 / 会话时长 / 留存:如未来需要,议 `session_touch` 低频心跳(每小时每用户至多一条)或独立 analytics 通道;
- OIDC `/auth/callback` 无登录审计:当前未配置 OIDC 不可达;若启用须补事件,否则 logins 口径漏计 OIDC 用户;
- App 版本号 dart-define 注入:Android 随 `app/tool/release.mjs` 构建链加 `--dart-define=APP_VERSION=<版本>`,**取 bump 后的目标版本**(release.mjs 先改 pubspec 再 build,读旧值会永久滞后一版;`--no-bump` 取当前;release.mjs 自带 bump 勿手动预 bump);**iOS 构建为手工命令**(参考 `main.dart` 头部注释),需同步带上等价参数,或首版接受 iOS UA 版本段为空(解析只依赖平台段,不影响分桶);
- `app_legacy` 占比监控:无需专门动作,stats 本身即可观察消亡。
