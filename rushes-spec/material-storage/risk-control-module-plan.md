# 风控模块 + App 端管理入口方案

> 状态:**qplan 定稿**(2026-10-28,五轮盲审收敛:0 P0,末轮 0 P1/6 P2 已顺手落实;实施待用户指令)
> 日期:2026-10-28 · 分支 `qplan/risk-module`
> 范围:后端 2 个新端点 + Web 新「风控」页 + App 新「风控」「使用统计」两页两入口

## 1. 背景与目标

登录风控现状:本地账号密码登录失败 5 次(per username / per IP 双维度,窗口 15 分钟)锁 15 分钟
(`app/settings.py:86-87`,`app/services/local_auth.py`)。W1(2026-10-17)已交付用户维度解锁
(`POST /api/v1/admin/directory/users/{id}/unlock`,连带清该用户近 24h 失败来源 IP 的锁),但存在三个缺口:

1. **IP 锁不可见**:用户列表「登录已锁定」pill 只反映 user 维度(`directory.py` 列表端点调用
   `users_login_locked`,注释明示 IP 维度不在内)——IP 被锁时管理界面可能一行都不亮。
2. **IP 锁无独立解除入口**:锁定来源用户名「查无此人」(敲错用户名 / 外部探测)时,没有任何用户行可点解锁,
   只能等 15 分钟自然过期或手工 `redis-cli DEL`。
3. **管理员在 App 端无法处置**:App 管理区没有风控视角;「使用统计」页也只有 Web 端有,管理员同样会在 App 上看。

目标:

- **G1** Web + App 新增「风控」页:实时列出当前被锁账号与被锁 IP(含失败计数、剩余锁定时间),
  支持①解锁账号(复用既有端点,**连带清 IP 的既有行为保留**)、②单独解除某个 IP 的锁。
- **G2** App 端管理区新增「使用统计」入口与页面(消费既有 `GET /api/v1/admin/usage/stats`,纯新增展示)。

非目标(明确不做):

- 不改锁的触发机制 / 阈值 / 维度(如「IP+用户名组合维度」防办公网连坐,属机制改造,另行立项);
- 不做实时推送 / WebSocket,列表为拉取快照;
- 不动 W1 已上线的用户列表 pill 与行内解锁按钮(风控页是补充视角,非迁移);
- 不引入 App 图表库。

## 2. 现状事实(方案依据)

| 事实 | 位置 |
| --- | --- |
| 限流参数:5 次 / 900 秒,双维度 | `api/app/settings.py:86-87` |
| 四类 Redis key:`auth:fail:{ip,user}:*` 计数(TTL 15min 滚动刷新)+ `auth:lock:{ip,user}:*` 锁(ex=15min) | `api/app/services/local_auth.py:37-40` |
| 每次失败同时 INCR 两维度,IP 桶跨用户名共享 | `local_auth.py:102-129` |
| 锁判定只在 `/auth/local/login` 一处,其他接口不受影响;session 为 7 天无状态 JWT | `routers/auth.py:298` |
| 登录成功清当前 IP 整桶计数 + 该用户名计数 | `local_auth.py:131-137` |
| W1 解锁端点:清 user 三形态(username/email/name,lower)锁与计数 + 连带清近 24h 失败来源 IP | `routers/directory.py:508-573`;`local_auth.py:140-196` |
| 审计反查先例:`details['username']` 存**原始输入未 lower**,比对须 lower | `directory.py:539-551` |
| Redis client `decode_responses=True`,SCAN 直接返回 str | `api/app/main.py:58` |
| 服务实例挂 `app.state.local_auth` / `app.state.redis`,router 经 deps 取 | `main.py:56-62` |
| `/admin/*` 统一 `require_system_admin` | `api/app/deps.py` |
| 独立小 router 先例(不堆进 1400+ 行 admin.py,实测 1459 行) | `routers/usage_stats.py` |
| 使用统计契约:`totals / by_platform / by_platform_class / by_network / cross / daily`,各分组独立去重 | `routers/usage_stats.py:27-63`;`models/__init__.py` `UsageStatsOut` |
| Web admin 路由 / 菜单挂点 | `web/src/App.tsx:72-80`;`web/src/components/AppHeader.tsx:107-118` |
| Web hook / 类型 / 文案惯例 | `web/src/api/hooks.ts`;`web/src/api/types.ts`;`web/src/lib/labels.ts` |
| App 管理区:磁贴宫格 + 深链二次闸(非 admin 锁定 EmptyState) | `app/lib/features/admin/admin_home.dart:34-48,87-127` |
| App 用户管理已有「解锁」行操作(交互范式可照抄) | `app/lib/features/admin/admin_user_row.dart` |
| App 路由表(命名路由,无 go_router) | `app/lib/app.dart:115-219` |
| App API 层:域薄封装注册进 `MsApi`;403/429 detail 透传页面 toast | `app/lib/core/api/ms_api.dart:206-223` |
| App 无使用统计页;`Me.isSystemAdmin` 已存在,无需新增权限字段 | `app/lib/models/me.dart:21-38` |
| App 测试范式:FakeMsApi 记录式 + `test/features/admin_pages_test.dart` | `app/test/helpers/api_harness.dart` |

## 3. 后端设计(新 router `routers/risk.py`,挂 `/api/v1/admin/risk`)

### 3.1 `GET /api/v1/admin/risk/locks` — 列出当前全部锁

权限 `require_system_admin`;只读,不写审计(照 `usage_stats.py` 只读先例,D6)。

流程:

1. `LocalAuthService` 新增 `scan_locks()`:对 `auth:lock:user:*` 与 `auth:lock:ip:*` 各做一次
   `scan_iter`(keyspace 极小,单实例 Redis),剥前缀得 `(user_forms: list[str], ips: list[str])`。
2. `LocalAuthService` 新增 `lock_details(forms, ips)`:一次 pipeline 对每个锁 key 取 `PTTL` +
   对应 `auth:fail:*` 计数 key `GET`,返回每个 form / ip 的 `(lock_ttl_seconds, fail_count)`。
   **`lock_ttl_seconds = ceil(PTTL / 1000)`**(redis PTTL 返回毫秒,漏换算会显示 742000 秒)。
   守卫:`PTTL == -2`(枚举与读取之间已过期)该行丢弃;`-1`(无过期,理论不出现)按 0 处理;
   fail key 不存在时 `fail_count = 0`(锁尾段计数先过期属正常,如实展示)。
3. **user 维度账号反查(router 内,DB 单查询)**:

   ```python
   select(User).where(
       func.lower(User.username).in_(forms)
       | func.lower(User.email).in_(forms)
       | func.lower(User.name).in_(forms)
   )
   ```

   对每个 form 归类(命中 = 该行任一列 lower 等于 form,同一行命中多列只算一次):
   0 命中 → `match="none"`(**未匹配账号**,即「想解都没入口」的 typo / 探测场景,原样展示);
   1 命中 → `"unique"`;≥2 命中 → `"ambiguous"`(name 重名歧义,标注展示)。
   与登录三级匹配同构但不复用 `find_user_by_username`(后者单 form 三连查,这里必须批量)。
4. **ip 维度富化(router 内,DB 单查询)**:近 24h 失败用户名去重集

   ```python
   select(AuditEvent.request_ip, func.lower(AuditEvent.details["username"].astext))
   .where(AuditEvent.event_type == "local_login_failed",
          AuditEvent.event_time >= now - 24h,
          AuditEvent.request_ip.in_(ips))
   .distinct()
   ```

   Python 侧按 ip 分组(过滤 NULL username)。口径与 W1 解锁连带清的反查完全一致(lower 比对,`directory.py:539-551` 先例)。

响应契约(新增 pydantic 模型,进 `models/__init__.py`):

```jsonc
{
  "users": [
    {
      "form": "zhangsan",                    // 锁 key 的登录名形态(小写)
      "match": "unique" | "none" | "ambiguous",
      "matched_users": [                     // unique=1 条;ambiguous=全部命中;none=[]
        {"id": "uuid", "username": "zhangsan", "name": "张三"}
        // ⚠ username 可空(老飞书用户无本地登录名,tables.py:69 username 列 nullable);
        //   pydantic 须 str | None、TS string | null、Dart String?,声明成 str 会在
        //   name 形态锁命中老用户时让整个端点 ValidationError 500
      ],
      "fail_count": 3,                       // 当前窗口失败计数(滚动窗口,非累计)
      "lock_ttl_seconds": 742                // 锁剩余秒数
    }
  ],
  "ips": [
    {
      "ip": "112.193.57.210",
      "fail_count": 5,
      "lock_ttl_seconds": 711,
      "recent_failed_userforms": ["zhangsan", "zhansa"]  // 近 24h 该 IP 失败用户名去重(小写)
    }
  ]
}
```

排序:users 按 `lock_ttl_seconds` 降序(新触发的在前),ips 同。两列表为空 = 当前无任何锁。

三个已知口径说明:

- **无条数上限(暂定)**:锁 key 只能由真实登录失败产生,且单 IP 5 次即封,自然规模极小;
  分布式探测理论上可造大量 `auth:lock:user:*`,属极端场景——admin-only 快照语义下**暂不加
  软上限**,列为遗留观察项(真需要时在 scan 后截断并加 `truncated` 标记)。

- **哨兵 IP `unknown`**:登录链路 `request_ip` 缺失时回落 `"unknown"`(`routers/auth.py:293`),
  因此可能出现 `auth:lock:ip:unknown`。列表**如实展示但标注**「未知 IP(链路异常,IP 缺失)」,
  允许解锁(该锁会拦住所有无 IP 请求,必须可解),不做静默过滤。
- **反查口径与登录三级匹配的已知偏差**:登录匹配是分层短路(`find_user_by_username`,
  `local_auth.py:220-247`,username 命中即停不查 name);本端点的批量 OR 单查询会让
  「同一 form 命中 A.username 又命中 B.name」判为 `ambiguous`(登录语义下是 unique)。
  属**刻意保守**(歧义展示不给解锁入口,防误伤重名用户),非 bug,前端文案按此渲染。

### 3.2 `POST /api/v1/admin/risk/locks/ips/{ip}/unlock` — 单独解 IP 锁

权限 `require_system_admin`。调既有 `LocalAuthService.clear_ip_locks([ip])`
(`local_auth.py:180-196`,DEL `auth:lock:ip` + `auth:fail:ip`,幂等)。
**`was_locked` 取严格语义 = 锁 key 曾存在**:`clear_ip_locks` 返回非空只代表「锁或计数任一被清」
(残留失败计数也会命中),不够准——照 W1 `ClearLocksResult.was_locked` 只认锁的口径
(`local_auth.py:43-54`),服务层补一个小查询 `ip_lock_exists(ip)`(GET `auth:lock:ip:{ip}`),
端点**先预判再清除**,`was_locked` 以预判为准。**已知可接受竞态**:预判与 DEL 之间锁自然过期时,
`was_locked=true` 但实际未清任何 key(审计落一条「空解锁」)——幂等无害,不另加锁;审计 `details`
顺带记 `clear_ip_locks` 实际返回的清除结果备查。返回:

```json
{"ip": "1.2.3.4", "was_locked": true}
```

- `ip` 路径参数**不做格式校验**(透传 Redis key 组装;DEL 不存在的 key 是幂等 no-op;admin-only 面,D3),
  仅 strip 空白。
- 写审计:新事件 `ip_login_unlocked`,`details = {"ip": ..., "was_locked": ..., "cleared": [...]}`
  (`cleared` = `clear_ip_locks` 实际清到 key 的返回清单,备查;调用形态照 `user_login_unlocked`,
  `directory.py:554-566`)。
- **审计事件设施三处回补**(新增 event_type 的仓库级义务,漏一处就有裸 token / 无法筛选):
  ① `web/src/lib/labels.ts`:`ip_login_unlocked: '解除 IP 登录锁定'`;
  ② `web/src/pages/AdminAuditPage.tsx`(:31 起 `EVENT_TYPES`)筛选全集;
  ③ `app/lib/features/admin/audit_labels.dart`:`kAuditEventTypes`(声明于 :11;文件头注释明言
  「新增写入点须回补」)+ 中文 label map(:91 附近,文案同①);
  ④ 两处「全集 N 项」计数注释同步:`AdminAuditPage.tsx:26` 与 `audit_labels.dart:2`。
  **实施回填(2026-10-28)**:基线注释本就过期——W1/W4/W5/W6 五事件回填时未同步,加
  `ip_login_unlocked` 前两数组实数已达 60 事件,机械「+1」会写出与数组不符的数字,故**按实数更正**:
  web = 61 事件 + 『全部』= 62 行,app = 62 项(含『』空串占位),两侧集合已程序化核对一致;
  `prod-observability-fix-plan.md` 附录 A 保持历史数字、加时点括注「当前实数以
  AdminAuditPage 计数注释为准」。**后续新增事件:改数组必须同步两侧计数注释(勿再让基线漂移)。**
- 活跃用户口径核对:`services/usage_stats.py` 的 `_ACTIVE_USERS_PREDICATE` 只排除
  `local_login_failed / local_login_locked`;`ip_login_unlocked` 是 admin 主动行为,**与
  `user_login_unlocked` 同口径计入活跃**,`usage_stats.py` 零改动(D9,写入核对项)。

### 3.3 账号解锁:零改动复用

风控页(Web / App)的账号解锁直接调既有 `POST /api/v1/admin/directory/users/{user_id}/unlock`,
**连带清近 24h 失败来源 IP 锁的行为保留不变**(用户明确要求)。`local_auth.py` / `directory.py` 既有逻辑一行不动。

### 3.4 usage_stats:零改动

`GET /api/v1/admin/usage/stats` 已满足 App 端需要,不动。

### 3.5 main.py 接线

`include_router(risk.router, prefix="/api/v1/admin/risk", tags=["risk"])`,照 `usage_stats` 挂法(`main.py:142`)。

## 4. Web 端设计

### 4.1 入口与路由

- `web/src/App.tsx`:lazy `AdminRiskPage` + `<Route path="/admin/risk">`(照 :72-80 既有 admin 路由)。
- `web/src/components/AppHeader.tsx`:admin 块(`:107-118`)加 `<NavChip to="/admin/risk" label="风控">`。

### 4.2 页面 `web/src/pages/AdminRiskPage.tsx`

- 标题「登录风控」+ **刷新按钮(必要交互)**;两张卡片 / 两个 Table:**被锁账号**、**被锁 IP**;空态 Empty。
  注:项目 QueryClient 全局 `refetchOnWindowFocus: false` + `staleTime: 30_000`(`web/src/App.tsx:41`),
  窗口聚焦**不会**自动刷新,列表更新只靠挂载拉取与手动刷新。
- 被锁账号表列:登录名形态(`form`,等宽字体)/ 账号(`match` 渲染:unique → `matched_users[0]` 的
  name + username(**username 为 null 只显示 name**,老飞书用户场景,见 §3.1);none → 灰字「未匹配账号」;
  ambiguous → 橙字「重名歧义」+ Tooltip 列命中名单)/
  当前窗口失败次数 / 剩余时间(`mm:ss`,静态换算)/ 操作。
  操作列:unique 行「解锁」按钮(Popconfirm 二次确认,mutate 复用既有 `useUnlockUser` hook,
  `hooks.ts:806`;hook 的 onSuccess 已 invalidate `['directory-users']`,风控页在 `mutateAsync`
  返回后**自行 invalidate `['risk-locks']` 并自行 toast**——toast 归页面层,文案照
  `AdminUsersPage.tsx:192-194` 既有格式「已解锁 …(清 N 个登录名形态 / N 个 IP 锁)」,hook 本身不带 toast);
  none / ambiguous 行**不提供解锁**
  (无 user_id 可走既有端点;引导文案「该锁定无对应账号,可解除相关 IP 锁」,D4)。
- 被锁 IP 表列:IP / 失败次数 / 剩余时间(`mm:ss`)/ 近 24h 失败用户名(小 tag 列表,超 5 个折叠 +
  Tooltip)/ 操作:「解除锁定」按钮(Popconfirm 二次确认,`useUnlockIp`)。
- 剩余时间为**静态快照**,不做前端倒计时(D2);刷新只靠挂载拉取 + 手动刷新按钮,
  **不加轮询、不开窗口聚焦刷新**(D1:锁 15 分钟自动过期,列表会自然清空)。
- 非 admin 手输 URL 直达的兜底:照 `AdminUsageStatsPage` 既有**双层**模式(`:86-98`):
  先 `me && !me.is_system_admin` 渲染 Alert 提示层,后端 403 再走 QueryCache 静默
  (`App.tsx:42-48`)+ 页面空态。

### 4.3 hooks / types / labels

- `web/src/api/hooks.ts`:`useRiskLocks()`(GET `/api/v1/admin/risk/locks`,queryKey `['risk-locks']`,
  照文件内既有 kebab-case key 风格如 `['directory-users']`)、
  `useUnlockIp()`(POST,成功 invalidate `['risk-locks']`)。账号解锁复用既有 `useUnlockUser`(`hooks.ts:806`),不改该 hook。
- `web/src/api/types.ts`:补 §3.1 契约的 TS 类型(照文件内既有风格)。
- `web/src/lib/labels.ts`:补 `ip_login_unlocked`。

## 5. App 端设计(Flutter,`material-storage/app/`)

### 5.1 入口与路由

- `lib/features/admin/admin_home.dart`:磁贴宫格加两枚——「风控」(`Icons.shield_outlined`)、
  「使用统计」(`Icons.insights`),样式照既有磁贴(金浅底图标 + 标题 + 副标题,`admin_home.dart:150-177`)。
  **导航机制照既有磁贴:`_open(context, const XxxPage())` 直推 widget**(`admin_home.dart:27-29, 49-86`),
  不走 pushNamed。
- `lib/app.dart` `onGenerateRoute`(:115-219)**另注册**两条命名路由 `/admin/risk`、`/admin/usage`
  → 新页(深链用,照既有 admin 子页路由段 :194-212)。
- 权限零新增:管理区入口已由 me_page `adminSectionTiles`(`me.isSystemAdmin`)与 admin_home 深链二次闸
  把守。**两个新页各自再加一道页面级 EmptyState 闸(照 `admin_home.dart:34-48` 同款)属刻意加严**:
  既有六个 admin 子页并无页面级闸、靠后端 403 detail 透传兜底(`admin_users_page.dart:124` 同款注释),
  新页加闸与既有口径不同,是本方案的有意选择(风控/统计页数据敏感,深链直达时直接给锁定态体验更好)。

### 5.2 `lib/features/admin/admin_risk_page.dart`

- 结构:PageHeader(标题「登录风控」+ 刷新动作)+ `RefreshIndicator` 包 `ListView`,两个
  `SectionCard`:「被锁账号」「被锁 IP」;空态文案「当前无任何登录锁定」。
- 被锁账号行(`AppRow` 或近似既有 admin 行组件):主标题 = 账号名(unique;**username 为 null 的
  老用户只显示 name**,Dart 模型 `String?`)/ form 原文 +「未匹配账号」
  副标注(none)/ form +「重名歧义」副标注(ambiguous);副标题 = `form` + 失败次数 + 剩余约 N 分钟。
  unique 行的「解锁」**交互完全照抄 `admin_user_row.dart` 既有范式**:行(或行尾动作)→ 底部 actions
  弹层(:26-71)→ `showAppConfirm` 确认(unlock 先例 :117-137,`toast()` 反馈 :129-136);
  none / ambiguous 行无动作(D4)。
- 被锁 IP 行:主标题 = IP(`unknown` 哨兵照 §3.1 标注);副标题 = 失败次数 + 剩余约 N 分钟 + 近 24h
  失败用户名(逗号拼接,超长省略);「解除锁定」走同款底部弹层 + `showAppConfirm` 确认 →
  `risk_api.unlockIp(ip)` → toast + 刷新。
- 剩余时间纯文本「约 N 分钟」(`lock_ttl_seconds / 60` 上取整),刷新时更新,不做秒级倒计时(D2)。
- 403 / 429 / 5xx 错误处理走既有约定:detail 透传 `toast`(App 端 403/429 无全局处理,`ms_api.dart` 惯例)。

### 5.3 `lib/features/admin/admin_usage_page.dart`

- 参数区:窗口 chip 轨(「近 7 天」/「近 30 天」,默认 30 天)+ metric 切换(「活跃用户」/「登录次数」)。
  **窗口算法照抄 Web 端**(`AdminUsageStatsPage.tsx:36-37,68-72`):本地时区「今日-(N-1) 天零点 → now」
  锚定(非 UTC 滚动窗),保证两端默认窗口一致、数字可直接对读;序列化为 **tz-aware ISO**
  (naive 会被后端 422,`routers/usage_stats.py:53-54`)。
- 内容自上而下:
  1. `StatRow`(既有组件,1~4 格统计数字)展示 `totals`;
  2. 分组卡片:`by_platform_class`(三端占比:web / android_app / ios_app / …)、`by_platform`、
     `by_network`(内外网)、`cross` —— 每组一行一条的 ListView 行(名称 + 数值),**不引图表库**(D7);
  3. `daily`:后端是 `(date, platform, network)` **三元组多行、date 升序**
     (`services/usage_stats.py:95-114, 204-206`;跨行 users 不可加、events 可加,`hooks.ts:1372-1378`
     同口径注释)。App 端**按日期聚合 events(跨行可加)取最近 14 个「有数据的日期」倒序**
     (后端 ASC 需自行反转;**缺日不补零**——后端 daily 仅产出有事件的日期),行 = 日期 + events 合计;
     逐日 users 不展示(跨三元组不可加,逐日求和会虚高)。
- 各分组独立去重、跨组不可加:页脚固定说明文案(照 Web 使用统计页口径注释)。

### 5.4 API 层与模型

- `lib/core/api/risk_api.dart`:`fetchRiskLocks()` / `unlockIp(ip)`,`MsApi` 域注册(`ms_api.dart:206-223`);
- `lib/core/api/usage_api.dart`:`fetchUsageStats({from, to, metric})`;
- Dart 模型:`RiskLocks`(users / ips 两列表,`match` 枚举)/ `UsageStats`(照后端 `UsageStatsOut`
  字段,fromJson 容错缺省字段,照 `me.dart` 风格)。

### 5.5 版本与发版

功能开发不触 `pubspec.yaml` 版本;发版时 `tool/release.mjs` 自动 bump(0.1.11+15 → 下一版)。
钉子沿用:shell 无 flutter PATH 时 release.mjs build 失败但版本已 bump,须 `--no-bump` 重跑。

## 6. 权限与安全

- 两个新端点均 `require_system_admin`,与 `/admin/*` 全部既有端点同口径;App 双闸(磁贴 + 深链)与
  Web `me.is_system_admin` 菜单块同口径。
- `GET /locks` 返回被锁登录名与来源 IP,属管理敏感数据,admin-only 面与既有审计 / 用户列表同级。
- 解 IP 会短暂削弱该 IP 15 分钟窗口内的暴力破解防护,与 W1「解锁连带清 IP」已接受的风险同级
  (`directory.py:522-528` 论述),系统 admin 门槛下接受。
- 只读端点无写副作用;写端点幂等(DEL no-op)且有审计。

## 7. 测试计划

### 7.1 api(`tests/test_risk_locks.py` 新文件)

照 `test_admin_unlock.py`(444 行)的锁布置手法,新增:

- 列表契约:布置 user 锁(username 形态 / email 形态 / name 形态各一)+ IP 锁 → 断言三形态各自
  `match=unique`;typo 形态 → `none`;布置重名两用户 + name 形态锁 → `ambiguous` 且
  `matched_users` 含两行;**name 形态命中 username=NULL 的老飞书用户(无本地登录名)→ 响应 200 且
  该行 `username: null`**(回归 §3.1 可空性,声明成 str 会整单 500);`fail_count` / `lock_ttl_seconds`
  数值正确(0 ≤ ttl ≤ 900)。
- IP 富化:预写 `local_login_failed` 审计(不同 username / 大小写差异)→ 断言
  `recent_failed_userforms` 小写去重;24h 外事件不计。
- 哨兵 IP:直接 SET `auth:lock:ip:unknown` 布置(ASGI client 下 request_ip 恒存在,不会自然产生,
  `tests/test_admin_unlock.py:63-65` ASGI_IPS 注释)→ 列表如实展示且带「链路异常」标注 →
  对其解锁成功。
- 解 IP:锁布置 → unlock → `was_locked=true` 且 Redis key 消失;再次 unlock → `was_locked=false`(幂等);
  审计 `ip_login_unlocked` 落库。
- 权限:非 system admin GET / POST → 403。
- 空态:无锁 → 两列表为空。
- 钉子:跑测前 `redis-cli FLUSHALL` 清限流锁(既有约定,防限流用例把 IP 锁掉连坐后续登录用例 429 假红);
  表驱动用例每样本独立 actor(既有钉子);测试在 hh2 dev 容器内跑(docker cp 先 rm 防嵌套)。

### 7.2 web

- **Web 端没有测试设施**(现状核实:`web/package.json` 仅 dev/build/lint/preview 四个 script,
  无 vitest/jest/testing-library 依赖,`web/src` 下无任何 `*.test.*` 文件),本需求**不引入**——
  引 runner 属基建决策,不夹带进功能需求。Web 验收 = `pnpm lint` + `pnpm build` 通过 + §9 真机抽测。

### 7.3 app

- `test/features/admin_pages_test.dart` 增两页用例:非 admin 深链 → 锁定 EmptyState;admin 下磁贴渲染、
  风控页三态账号行渲染、解锁动作走 FakeMsApi 记录断言(`api.unlockIpCalls`)、使用统计页数字渲染
  (FakeMsApi 桩数据)。
- 契约层:`risk_api` / `usage_api` 照 `ms_api_test.dart` 本地 HttpServer 模式各补 1~2 条。
- 全量 `flutter analyze`(0 issue)+ `flutter test` 全绿(当前 169 文件基线)。

## 8. 部署

| 端 | 动作 | 钉子 |
| --- | --- | --- |
| api | 新路由文件 + models 改动,rsync 后**须 restart 容器** | `deploy_lan.sh` 同步代码;无迁移、无 FGA model、无 .env 改动 |
| web | SPA **build 后单独 tar 推送** | `deploy_lan.sh` 不同步 `static/web`(既有钉子);worktree 构建须主仓 node_modules |
| app | 随下次发版 | release.mjs 自动 bump;勿手动预 bump |

收工按仓库约定在 `scripts/changelog.md` 当天分节追加(带 commit hash)。

**回滚**:改动全为增量(新 router / models / 两端页面),无迁移、无 Redis 结构变更、无 FGA——
回滚 = 回退 api 镜像内代码 + 回退 SPA 静态资源(App 端回退发版或等下次覆盖),无数据回滚动作。

## 9. 验收清单(dev 环境)

1. **同用户名**连续失败 5 次 → Web 风控页出现该 user 行 + IP 行(双行,fail_count=5,
   剩余时间递减刷新可见);App 风控页一致。
   **混用户名**再验一案:同一 IP 下 4 个不同用户名各失败 1~2 次(合计 ≥5)→ **只出现 IP 行、
   无任何 user 行**(IP 桶跨用户名共享的实证;此时 user 维度计数均 <5 不落锁)。
2. 用**不存在的用户名**失败 5 次 → user 行 `match=none` 展示「未匹配账号」且无解锁操作;对该 IP
   「解除锁定」→ 该 IP 上正常账号立即可登录;审计出现 `ip_login_unlocked`,审计页文案为「解除 IP 登录锁定」。
3. App 端重复验收 2 的解 IP 路径。
4. 对 unique 行「解锁」→ user 行消失,**连带 IP 行消失**(既有行为保留;前置:该 IP 须在该用户
   近 24h 失败来源集内——验收 1 场景①天然满足);用户列表页 pill 同步熄灭。
5. 重名账号场景:两个同 name 用户,锁 name 形态 → 展示「重名歧义」+ 命中名单,无解锁操作。
6. 权限:非 admin Web 菜单无「风控」入口 + API 403;App 非admin 无磁贴 + 深链锁定态。
7. App 使用统计页:窗口算法与 Web 端一致(本地时区今日零点锚定),默认「近 30 天」totals /
   三端占比数字与 Web 使用统计页默认视图一致(**容差**:两端 `to=now` 取的是各自加载时刻,
   允许尾部事件数小幅差异;精确比对时用相同 from/to 显式传参 curl 验证);切「近 7 天」
   「登录次数」正常,daily 展示最近 14 天按日 events 合计。
8. 无任何锁时两端展示空态。

## 10. 决策记录

| # | 决策 | 理由 |
| --- | --- | --- |
| D1 | 列表为拉取快照:不轮询、不推送、不开聚焦自动刷新 | 锁 15 分钟自动过期;项目全局 QueryClient 已设 `refetchOnWindowFocus: false`(`App.tsx:41`),手动刷新足够,轮询收益低 |
| D2 | 剩余时间静态展示,不做倒计时 | 免每秒 setState / re-render;刷新即更新 |
| D3 | 解 IP 参数不校验格式,key 透传 | DEL 幂等,admin-only 面;校验反而堵「异常形态 key」的清理 |
| D4 | `none` / `ambiguous` 的 user 行不提供解锁 | 既有账号解锁端点以 user_id 为锚,两态无锚点;解 IP 已可达同样效果 |
| D5 | 不改锁触发机制 / 阈值 / 维度 | 本需求只补可视化与解除入口;机制改造(如组合维度)另立项 |
| D6 | `GET /locks` 不写审计 | 只读照 `usage_stats` 先例;解锁写审计 |
| D7 | App 使用统计不引图表库;daily 按日聚合 events(可加口径)只展示最近 14 天 | 单需求引依赖不划算(pubspec 现无图表库);daily 是 (date,platform,network) 三元组,users 跨行不可加、逐日求和会虚高 |
| D8 | W1 用户列表 pill / 行内解锁保留不动 | 已上线行为,风控页是补充视角;避免双入口语义漂移 |
| D9 | `ip_login_unlocked` 计入活跃用户口径 | 与 `user_login_unlocked` 同为 admin 主动行为;`usage_stats.py` 零改动 |

## 11. 改动面清单与工作量

| 层 | 文件 | 性质 |
| --- | --- | --- |
| api | `app/routers/risk.py`(新,~140 行) | GET /locks + POST ips/{ip}/unlock |
| api | `app/services/local_auth.py`(+~70 行) | `scan_locks` / `lock_details`(Redis 只读)+ `ip_lock_exists`(GET 锁 key,§3.2 was_locked 预判用) |
| api | `app/models/__init__.py`(+~40 行) | `RiskLocksOut` / `RiskUserLock` / `RiskMatchedUser` / `RiskIpLock` / `RiskIpUnlockOut` 共 5 个(`match` 用 `Literal`;`RiskMatchedUser.username: str | None`,见 §3.1) |
| api | `app/main.py`(+2 处) | `from app.routers import` 块加 risk(:18-33,usage_stats 先例 :32)+ `include_router` |
| api | `tests/test_risk_locks.py`(新,~250 行) | §7.1 |
| web | `src/pages/AdminRiskPage.tsx`(新,~280 行) | §4.2 |
| web | `src/api/hooks.ts` / `types.ts` / `lib/labels.ts`(+~60 行) | §4.3 |
| web+app | 审计事件设施回补:`web/src/pages/AdminAuditPage.tsx` EVENT_TYPES(:31 起)、`app/lib/features/admin/audit_labels.dart`(kAuditEventTypes + label map) | §3.2 |
| web | `src/App.tsx` / `components/AppHeader.tsx`(+~6 行) | 路由 + 菜单 |
| app | `lib/features/admin/admin_risk_page.dart`(新,~220 行) | §5.2 |
| app | `lib/features/admin/admin_usage_page.dart`(新,~200 行) | §5.3 |
| app | `lib/core/api/risk_api.dart` / `usage_api.dart`(新,~80 行)+ `ms_api.dart` 注册 | §5.4 |
| app | Dart 模型(新或并入既有,~80 行)+ `app.dart` 路由 + `admin_home.dart` 磁贴(~20 行) | §5.1 |
| app | `test/features/admin_pages_test.dart` 等(+~200 行) | §7.3 |

无 DB 迁移、无 OpenFGA model 改动、无 .env 改动。总量约 api 550 / web 350 / app 800 行(含测试),
qdev 预计 2~3 包(api / web / app 各一,或 api+web 合包)。

## 12. 风险与实施钉子

- SCAN 与 pipeline 不能混用(`scan_iter` 单独迭代,pipeline 只做 GET/PTTL 批量)。
- **Web 端无测试设施**(package.json 无 test script、无任何测试框架依赖),实施时勿虚构
  「照既有 web 测试先例」;Web 侧验收就是 lint + build + 真机抽测。
- `unknown` 哨兵 IP 的展示与可解口径见 §3.1(勿静默过滤,也勿当真实 IP 无标注展示)。
- usage_stats `daily` 为三元组多行且 date ASC,App 侧聚合与反转口径见 §5.3。
- App `from/to` 必须带时区(tz-aware ISO),naive 会被 `usage_stats.py:53-54` 422;窗口算法
  照抄 Web(本地时区今日零点锚定),两端默认视图才可比。
- **Dart 时区钉子**:序列化必须 `DateTime.toUtc().toIso8601String()`——本地 DateTime 直接
  `toIso8601String()` 产出**无 offset 后缀的 naive 串**,必吃 422;Web 的 `toISOString()`
  恒 UTC「Z」形,「照抄 Web」指窗口**算法**而非该序列化细节。
- **D3 边界补充(实施实证)**:含 `/` 的畸形 key 形态(`%2F`、`..`)在路由层即 404,到不了解锁
  端点——真实锁形态(IPv4 / `unknown` 哨兵)不含 slash,不受影响;若真出现含 slash 的异常
  key,只能手工 `redis-cli DEL`,端点无法触达。
- `PTTL` 返回**毫秒**,`lock_ttl_seconds = ceil(PTTL / 1000)`;`-1`(无过期)/ `-2`(不存在)守卫见 §3.1。
- `fail_count` 是滚动窗口计数(每次失败刷新 TTL),展示文案统一「当前窗口失败次数」,勿写「累计」。
- 审计 `details.username` 为原始输入未 lower,反查与展示统一 lower 口径(既有钉子,`directory.py:539-551`)。
- Web worktree 构建须用主仓 node_modules(worktree 内 `pnpm install` 会装错 antd 版本)。
- `deploy_lan.sh` 不同步 SPA;api 新路由须 restart 容器;App 发版钉子见 §5.5。
- 验收用例 1 连续失败 5 次会把测试者自己 IP 锁 15 分钟——验收脚本用可解 IP 的风控页自愈,或等过期。
