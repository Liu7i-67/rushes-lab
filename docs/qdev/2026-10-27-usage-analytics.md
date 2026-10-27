# 需求:客户端使用统计(三端占比 + 内外网占比)——依托审计模块拓展

> 唯一方案依据:[rushes-spec/material-storage/usage-analytics-plan.md](../../rushes-spec/material-storage/usage-analytics-plan.md)(qplan 六轮盲审定稿,fb5eb54 带入本分支)。本文档是它的**实施落地契约**:接口/文件/口径以此为准,口径语义冲突时以方案文档为准。
> 目标:① web / Android App / iOS App 使用占比;② 内网访问与外网访问人数占比。
> 红线:**不新增 event_type、不改既有审计写入语义、无 FGA 变更、无新外部依赖**。

## 1. 功能点明细(逐条可验收)

| # | 功能点 | 验收标准 |
| --- | --- | --- |
| F1 | 聚合统计端点 `GET /api/v1/admin/usage/stats` | 按本文档 §4 契约返回 totals/by_platform/by_platform_class/by_network/cross/daily;仅 system admin 可达;时间参数四分支+三类 422 |
| F2 | App 主 Dio 注入可识别 User-Agent | UA=`msapp/<version> (<platform>)`,平台段 android/ios;版本 dart-define 注入(取 release.mjs bump 后值),未注入为空串;App 行为零变化 |
| F3 | `share_link_created` 补传 ctx | service 签名加 ctx,审计行 UA/IP 非空;既有 share 行为不变 |
| F4 | 0018 迁移:`ix_audit_event_time` 单列索引 | 迁移可 up/down;`tables.py` 元数据同批改;`test_db_schema` 补断言 |
| F5 | web admin「使用统计」页 | 路由 `/admin/usage` + NavChip「使用统计」(仅 system admin);占比条+交叉表+日趋势;metric/日期范围切换 |
| F6 | 集成测试 | `tests/test_usage_stats.py` 覆盖本文档 §6 全部断言点 |

## 2. 口径(实现必须逐字遵守,来自方案 §3)

- **维度解析只在 SQL 实现**(单点,无 Python 双实现;SQLAlchemy ORM 不支持 GROUPING SETS,用 `sqlalchemy.text()` + 绑定参数)。
- **platform CASE 规则序**(自上而下首中即归,一律 `ILIKE`):

  | 序 | 条件(user_agent) | 归类 |
  | --- | --- | --- |
  | 1 | `ILIKE '%msapp%'` 且 `ILIKE '%(android)%'` | `android_app` |
  | 2 | `ILIKE '%msapp%'` 且 `ILIKE '%(ios)%'` | `ios_app` |
  | 3 | `ILIKE '%msapp%'` 或 `ILIKE '%Dart%'` | `app_legacy`(平台段收紧到带括号形态后,子串误命中如 `msapp/bios` 落此兜底) |
  | 4 | 含 `Android` / `iPhone` / `iPad` / `iPod` | `web_mobile` |
  | 5 | 非空 | `web_desktop` |
  | 6 | else | `unknown`(兜底分支,新数据不可达) |

- **platform_class**:`web_desktop`/`web_mobile` → `web`,其余原值(`android_app`/`ios_app`/`app_legacy`/`unknown`)。
- **network 规则**:`request_ip` 为 NULL/空串/`'unknown'` → `unknown`;匹配大小写不敏感正则(`~*`)`^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|169\.254\.|::1$|::ffff:(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)|f[cd][0-9a-f]{2}:|fe80:)` → `lan`(IPv4-mapped 私网 `::ffff:10.0.0.1` 显式覆盖);其余 → `wan`。
- **口径过滤**:
  - active_users(默认):`actor_user_id IS NOT NULL AND user_agent IS NOT NULL AND event_type NOT IN ('local_login_failed','local_login_locked')`
  - logins:`event_type = 'local_login_success'`(其余过滤同上保留)
- **聚合不变量**:`count(DISTINCT actor_user_id)` 跨组不可加——by_platform / by_platform_class / by_network / cross / totals 的 users 值**必须各自独立分组产出**(GROUPING SETS 的每个分组集内独立去重),**严禁任何行间求和推导**。
- **日分桶**:`date_trunc('day', event_time AT TIME ZONE 'Asia/Shanghai')`;daily 只输出 (date, platform, network) 完整三元组行(unknown 是合法枚举值,正常输出)。
- **多端用户重复计数**:占比之和可 >100%,页面标注;web 端合计看 `by_platform_class.web` 单行。

## 3. 组件拆分方案

### 3.1 后端(material-storage/api)

| 文件 | 新建/修改 | 职责与内容 | 预估行数 |
| --- | --- | --- | --- |
| `app/services/usage_stats.py` | 新建 | `UsageStatsService`:SQL CASE 常量(platform/platform_class/network)+ GROUPING SETS 主查询 + daily 查询 + 参数校验辅助;对外仅一个方法 `async def stats(self, *, from_time, to_time, metric, daily) -> dict` | ~220 |
| `app/routers/usage_stats.py` | 新建 | 独立 router(不碰 1150+ 行的 admin.py):`GET /stats` + 参数解析(四分支时间规则)+ `require_system_admin` | ~90 |
| `app/models/__init__.py` | 修改 | 追加 `UsageStatsOut` 响应模型族(Totals/PlatformRow/PlatformClassRow/NetworkRow/CrossRow/DailyRow),风格照既有 `AuditOut` | +~45 |
| `app/main.py` | 修改 | include 新 router:`app.include_router(usage_stats.router, prefix="/api/v1/admin/usage", tags=["usage-stats"])`(照 :127-141 惯例) | +2 |
| `app/services/share_service.py` | 修改 | `create_share` 加 `ctx: dict[str, str | None]` 形参,`audit.write(..., request_ip=ctx.get("request_ip"), user_agent=ctx.get("user_agent"))`(照 folder_templates.py:131-132 写法) | +8 |
| `app/routers/share.py` | 修改 | 两处调用点(:105 附近与 :152 附近 folder 分支)把 router 已有的 ctx 依赖传入 | +4 |
| `app/db/tables.py` | 修改 | `AuditEvent.__table_args__` 加 `Index("ix_audit_event_time", "event_time")`(对齐既有 `ix_audit_event_type_time` 命名,无表名尾 s) | +2 |
| `app/db/migrations/versions/2026_10_27_0018_audit_event_time_index.py` | 新建 | `down_revision = "20261019_0017"`(**revision id,勿写文件名**);`revision = "20261027_0018"`;up=plain `create_index`(沿 0017 惯例,不用 CONCURRENTLY),down=drop_index;文件头注释说明 tables.py 同批改 | ~35 |
| `tests/test_db_schema.py` | 修改 | 补 `ix_audit_event_time` 成员断言 | +3 |

### 3.2 App(material-storage/app)

| 文件 | 新建/修改 | 职责与内容 | 预估行数 |
| --- | --- | --- | --- |
| `app/lib/core/api/user_agent.dart` | 新建 | 纯函数 `String buildClientUserAgent(String? version)` → `msapp/${version ?? ''} (${Platform.isIOS ? 'ios' : 'android'})`(dart:io Platform 同步判定);可注入 platform 参数便于单测 | ~25 |
| `app/lib/main.dart` | 修改 | 加 `const kAppVersion = String.fromEnvironment('APP_VERSION', defaultValue: '')`(照 kAppBuildStamp 模式) | +5 |
| `app/lib/core/api/ms_api.dart` | 修改 | 主 Dio `BaseOptions` 加 `headers: {'User-Agent': buildClientUserAgent(kAppVersion)}`;`_put` 裸 Dio/探活 Dio/缩略图 HttpClient **不挂**(有意,见方案 §4.1) | +4 |
| `app/tool/release.mjs` | 修改 | build apk 命令追加 `--dart-define=APP_VERSION=${targetVersion}`(**bump 之后**的值;`--no-bump` 时取当前 pubspec 版本) | +4 |
| `app/test/user_agent_test.dart` | 新建 | 纯函数单测:有/无版本、双平台注入参数 | ~40 |

### 3.3 web(material-storage/web)

| 文件 | 新建/修改 | 职责与内容 | 预估行数 |
| --- | --- | --- | --- |
| `web/src/api/hooks.ts` | 修改 | `useAdminUsageStats(params)`(react-query,每 endpoint 一 hook 惯例) | +~35 |
| `web/src/pages/AdminUsageStatsPage.tsx` | 新建 | 页面骨架:日期范围(默认 30 天)+ metric 切换 + 数据编排;**超 300 行必须拆子组件** | ~280 |
| `web/src/components/admin/UsageStatBars.tsx` | 新建 | 占比条组件(platform 主展示用 by_platform_class,by_platform 下钻;network;多端重复计数标注;unknown 兜底文案) | ~120 |
| `web/src/components/admin/UsageStatsTable.tsx` | 新建 | 交叉表(antd Table)+ 日趋势(条形,Progress/自绘色条,**不引图表库**;日趋势用 events 可加,daily users 跨行不可加只在单一维度切片展示) | ~140 |
| `web/src/App.tsx` | 修改 | `<Route path="/admin/usage" element={<AdminUsageStatsPage />} />`(lazy 惯例照相邻 admin 页) | +2 |
| `web/src/components/AppHeader.tsx` | 修改 | `me.is_system_admin` 块内加 `<NavChip to="/admin/usage" label="使用统计" .../>` | +2 |

### 3.4 复用资产(必须复用,禁止重写)

- 后端:`get_request_context`(deps.py)、`AuditService`、models 惯例、`get_sessionmaker`/DB 依赖、require_system_admin、tests 的 httpx ASGITransport + `create_app()` + lifespan fixture 模式(照 `tests/test_boundary_ext.py` 头部)、seed 契约账号(EVAN_ID=system admin)。
- App:kAppBuildStamp dart-define 模式、release.mjs targetVersion 流程。
- web:NavChip、既有 admin 页布局惯例(AdminAuditPage)、hooks.ts react-query 模式、antd v6(注意仓库 antd 钉 6.4.2,`web/package.json`)。

### 3.5 数据流

```
客户端(浏览器原生 UA / App msapp UA)
  → nginx 链(XFF,勿动)
  → ms-api 各业务端点 → audit.write(ctx)【既有,不改】
  → GET /admin/usage/stats → UsageStatsService(GROUPING SETS SQL)→ 响应
  → web 使用统计页(纯展示,前端不做二次解析)
```

## 4. 接口定义

`GET /api/v1/admin/usage/stats` — 仅 system admin(`require_system_admin`)。

Query 参数:

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| from | datetime(tz-aware ISO) | 否 | 见时间规则 |
| to | datetime(tz-aware ISO) | 否 | 见时间规则 |
| metric | `active_users`\|`logins` | 否(默认 active_users) | 口径见 §2 |
| daily | bool | 否(默认 true) | false 时 daily 返回 `[]` |

时间规则(写死):双缺省 → `from=now-30d, to=now`;仅缺 to → `to=now`;仅缺 from → `from=to-30d`;**naive datetime → 422**;`from >= to` → 422;窗口 > 366 天 → 422。

响应 200:

```json
{
  "metric": "active_users",
  "from": "2026-09-27T00:00:00+00:00",
  "to": "2026-10-27T00:00:00+00:00",
  "totals": {"users": 42, "events": 1832},
  "by_platform": [{"platform": "ios_app", "users": 18, "events": 821}],
  "by_platform_class": [{"platform_class": "web", "users": 27, "events": 910}],
  "by_network": [{"network": "lan", "users": 25, "events": 1021}],
  "cross": [{"platform": "ios_app", "network": "lan", "users": 12, "events": 430}],
  "daily": [{"date": "2026-10-20", "platform": "ios_app", "network": "lan", "users": 9, "events": 120}]
}
```

排序(定死便于断言):by_platform/by_platform_class/by_network 按 users DESC,再按 key 字典序升序;cross 按 users DESC 再 (platform, network) 字典序;daily 按 date ASC 再 (platform, network) 字典序。

错误码:422(参数,含 naive/乱序/超窗);401(未认证);403(非 system admin)。

## 5. 改动点摘要

- 后端:见 §3.1;**禁止**改动 audit.py 写入语义、既有端点行为、poc/nginx 配置。
- App:见 §3.2;**禁止**触碰 _put/探活/缩略图通道、上传下载逻辑。
- web:见 §3.3;**禁止**引入图表库/新依赖。

## 6. 测试功能点(tests/test_usage_stats.py,容器内跑)

1. **platform 分桶表驱动**(直插 audit 行绕过 audit.write 构造样本):`msapp/0.1.11 (android)`→android_app;`msapp/ (android)`(无版本)→android_app;`msapp/0.1.11 (ios)`→ios_app;`msapp/0.2.0`(漏平台段)→app_legacy;**`msapp/bios`(子串陷阱,平台段须带括号)→app_legacy**;`Dart/3.5 (dart:io)`→app_legacy;含 `Android` 的平板 UA(无 Mobile 标记)→web_mobile;`Mozilla/5.0 (iPhone; …)`→web_mobile;桌面 Chrome UA→web_desktop;空串 UA 行(直插)→**落 unknown 兜底桶**(`'' IS NOT NULL` 为真、CASE 规则 5 排除空串;历史空串行语义,与方案 §3.1 一致——本条初稿误写"被过滤",以方案口径为准)。
2. **network 分桶**:`172.15.x`/`172.32.x`/`172.168.x`→wan;`172.20.0.7`→lan;`10.1.2.3`/`192.168.1.5`/`127.0.0.1`/`::1`/`FD00::`(大写)/`fe80::1`→lan;**`::ffff:10.1.2.3`→lan / `::ffff:8.8.8.8`→wan(IPv4-mapped 形态)**;`8.8.8.8`→wan;NULL/`''`/`'unknown'`→unknown(哨兵来自 auth.py:293)。
3. **时间参数**:双缺省(默认 30 天窗口断言 from/to 差值)/仅 from(to=now)/仅 to(from=to-30d)/乱序 from≥to→422/naive→422/窗口 367d→422。
4. **口径过滤**:带 actor 的 `local_login_failed` 不进 active_users;UA NULL 的 worker 事件不进;actor NULL 事件不进;logins 口径只计 `local_login_success`;UA NULL 的登录也不进(两口径统一 UA 非空)。
5. **对账断言**(count DISTINCT 跨组不可加):构造同一用户 web_desktop+web_mobile 双用 → `by_platform_class` 的 web 行 users=1,而 by_platform 两行 users 各 1;构造同一用户跨 lan/wan → `by_platform.users ≠ 该 platform 的 cross 行 users 求和`;多端用户 → `totals.users ≠ by_platform 行 users 求和`。
6. **排序断言**:by_platform 顺序符合 §4 排序规则。
7. **权限**:未认证 401;普通用户(bob,X-User-Id)403;Evan(system admin)200。
8. **排序 daily**:daily=false → `[]`;含跨天事件时 date 按 Asia/Shanghai 分桶正确。
9. **回归**:既有测试套件全绿(尤其 share 相关:`create_share` 签名变更后既有调用/测试适配)。

App:`flutter analyze` 0 issue;`user_agent_test.dart` 通过;全量既有测试绿。web:`pnpm lint` + `pnpm build` 通过。

## 7. 模糊点与决策记录

方案文档 D1-D8 全部沿用(引用,不重述)。本实施新增 PM 决策:

| # | 决策 | 理由 |
| --- | --- | --- |
| P1 | 新端点放**独立 router `routers/usage_stats.py`**(prefix `/api/v1/admin/usage`),不写进 admin.py | admin.py 已 1150+ 行超单文件上限,不再堆叠;qdev 组件化铁律 |
| P2 | 测试走 HTTP 层(httpx ASGITransport 模式),不测 service 内部函数 | 与 B 包并行开发的契约边界;覆盖端到端 |
| P3 | web 页面拆 Page+两个子组件(Bars/Table),防单文件超限 | qdev 500 行铁律 |
| P4 | App 版本 dart-define 常量 `kAppVersion` 放 main.dart(与 kAppBuildStamp 同址) | 集中管理编译期注入常量 |
| P5 | platform/network 枚举中文文案在 web 页面组件内映射(不进 labels.ts) | labels.ts 惯例服务 event_type 文案,统计枚举是页面私有 |
