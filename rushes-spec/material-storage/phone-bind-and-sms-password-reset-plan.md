# 方案:账号手机号自助绑定/换绑 + 短信找回密码(Web + App)

- 日期:2026-11-20
- 状态:qplan 盲审中
- 需求来源:用户 2026-11-20 口述需求(设置页手机号绑定/换绑 + 登录页忘记密码,阿里云短信验证码,双端)
- 依赖技能:`aliyun-sms-integration`(2026-11-19/20 三运营商实测闭环,签名报备已全通过)

## 0. 一句话

给每个账号加**唯一手机号**(设置页绑定/换绑,凭短信验证码+当前密码),登录页新增「忘记密码」入口:输入手机号→短信验证码→验证通过后系统**直接重置密码**并把**账号+新密码一次性展示**给用户;附存量自动绑定脚本(登录账号即中国大陆手机号的用户自动绑定)。

## 1. 背景与目标

### 1.1 需求拆解(逐条对齐)

| # | 需求原文要点 | 方案落点 |
| --- | --- | --- |
| R1a | 设置界面展示当前绑定手机号,允许修改;没有则允许新增 | §6.4 / §7.3 双端设置页「手机号」入口;`GET /auth/me` 回传 phone |
| R1b | 一个手机号只允许绑定一个系统账号 | `users.phone` 唯一约束(§4);占用预检 409 + IntegrityError 兜底 |
| R1c | 开发完毕后提供批量设置脚本;登录账号是中国大陆手机号的用户自动绑定 | §9.4 `scripts/bind_user_phones.py`(dry-run 默认+`--apply`) |
| R1d | 绑定/换绑:签名【成都讨喜未来文化传媒】模板 SMS_512538915,验证码 15 分钟有效,2 分钟内只能发一条,验证通过则允许绑定 | §5.3 绑定状态机;TTL 900s / 冷却 120s |
| R2a | 登录页新增忘记密码入口,输入手机号,模板 SMS_512523885 发动态码 | §6.2 / §7.2 双端登录页入口 + 忘记密码页 |
| R2b | 发送前校验手机号是否已绑定账号;不存在则不发,提示「无法发送验证码」 | §5.4 send-code 存在性校验(需求明确接受枚举信号,§8.1) |
| R2c | 验证码 15 分钟有效,2 分钟内只能发一条 | 同 R1d 参数 |
| R2d | 验证通过后直接重置密码,并显示对应账号和密码 | §5.4 confirm:系统生成随机密码→返回 `{username, email, name, new_password}` 一次性展示 |
| R3 | 涉及 App 端和 PC(Web)端 | §6 / §7 |
| R4 | 凭证:AK/SK/SignName 由用户提供 | §5.6/§5.8/§9.2:只进服务器 `.env` + 本地 `scripts/env/aliyun-sms.env`(gitignored),**不进仓库** |

### 1.2 目标

1. 用户可在 Web/App 设置页自助完成手机号绑定与换绑,全程无需管理员介入。
2. 忘记密码的用户凭手机号+短信验证码自助找回:拿到可立即登录的账号+新密码。
3. 存量用户中「登录账号=手机号」的自动完成绑定,一次脚本收口。
4. 短信通道按实测技能接入(httpx 自签名 ACS3-HMAC-SHA256,零新依赖)。

### 1.3 非目标(明确不做)

- **手机号登录**:登录名匹配链(username→email→name)不动,手机号只是绑定属性+找回通道。
- **解绑手机**:无产品诉求;手机号是找回通道,解绑会制造「无凭证账号」。
- **换绑时验证旧手机**:短信只发新号(D16,当前密码已把关)。
- **国际手机号**:签名与模板均国内;只接受中国大陆号段。
- **管理后台展示/编辑手机号**:脚本已满足运营诉求,管理端另行周期。
- **重置后踢旧 session(session_version)**:与现行 `change-password` 行为对齐(改密也不踢 session,只吊销 PAT);会话失效机制是横切改造,列遗留(§13)。
- **MNS 回执回调/送达状态入库**:排障用 `QuerySendDetails` 手工查(技能已验证),不做常驻监听。
- **深链/URL scheme 跳转**(App 从短信直接唤起):v1 不做。

## 2. 现状事实(代码依据)

### 2.1 用户与数据模型

- `users` 表(`material-storage/api/app/db/tables.py:59-88`):**没有 phone/mobile 字段**;`username` 可空且 unique,`email` 可空且**无唯一约束**,`password_hash` 可空(NULL=未设密码),`must_change_password` 默认 true。
- 唯一约束坑(仓库已知):迁移 0008/0010 用列定义 `unique=True` 只发普通 ALTER 不渲染 UNIQUE,0009 曾专门补建——**新列唯一性必须显式 `op.create_index(..., unique=True)`**。
- Alembic head=`20261119_0023`(`app/db/migrations/versions/`,user_prefs);新迁移编号 **0024**。
- `GET /api/v1/auth/me`(`app/routers/auth.py:148-331`)现返回用户字段+flags+`password_set`/`must_change_password`/`baidu_backup_enabled`,加 `phone` 顺理成章。

### 2.2 认证与会话

- 本地登录 `POST /auth/local/login`(`app/routers/auth.py:368-461`):argon2 校验;Redis 双维限流(per IP + per username,5 次失败锁 15 分钟,key 模式 `auth:fail:ip:{ip}` / `auth:lock:user:{username}`,`app/services/local_auth.py:40-43`);登录名匹配 `find_user_by_username`(username lower→含 @ 才试 email→name 兜底,多行命中拒登)。
- 会话:cookie `ms_session`(HS256 JWT,TTL 7 天,SameSite=**lax**,`app/settings.py:79-81`);`get_current_user` 每请求查库,`is_active=false` 即 401;`must_change_password` 且已设密码时非白名单路由 403(白名单只有 me/change_password/logout,`app/deps.py:77`)。
- `POST /auth/change-password`(`app/routers/auth.py:464-537`):旧密码校验,成功**同事务吊销全部 PAT**,审计 `password_changed`——重置流程对齐此行为(D8)。
- 未登录可访问端点现状:/healthz、/auth/local/login、/auth/logout、/auth/login 与 /auth/callback(OIDC)、/maintenance/banner、SPA 静态(`app/routers/maintenance.py:37-40` 注释明确公开模式)——忘记密码两端点加入此列,模式一致。

### 2.3 服务实例与 Redis

- 外部服务一律 `app.state` 挂载(`app/main.py` lifespan),router 经 deps 取;**禁止模块级单例**。httpx 外呼先例:OIDCService、BaiduNetdiskClient(`app/main.py:74-79`)。
- `app.state.redis` = `redis_asyncio.from_url(...)`(`app/main.py:62-64`,decode_responses=True);业务 key 先例:`auth:*`、`maintenance:banner`、`mcp:flag`、`mcp:rl:ip:*`(Lua 原子)、`backfill:lock`(SET NX EX)。
- 配置模式(`app/settings.py`):Optional Field + 开关 property(SMTP 组 `smtp_enabled`=host+from 齐备,即本模式);百度组另有启动断言先例 `validate_baidu_settings()`。

### 2.4 短信通道(技能实测事实)

- 签名「成都讨喜未来文化传媒」已过审,**三运营商(移动/联通/电信)端口报备 2026-11-20 全部验证通过**,实测送达 5-16 秒——无阻断前置。
- 模板 SMS_512538915(绑定)与 SMS_512523885(密码重置)均已过审;**模板变量 ${code} 只允许「数字+字母组合或仅字母」**——验证码必须含字母,不能纯数字。
- 已验证接入路径:V3 `ACS3-HMAC-SHA256` 自签名(POST+query string+空 body,RFC3986 编码),技能脚本以纯标准库跑通;后端以 httpx 等价实现(D10),零新依赖。
- 接口钉子:`Code=OK` 只是提交成功;`TemplateParam` 必须是 JSON **串**;`BizId` 带 `^0` 后缀;**SendSms 无幂等,禁止盲目重试**;回执查询 `QuerySendDetails` 的 `SendDate` 必须 `yyyyMMdd`。

### 2.5 前端

- Web(`material-storage/web/`):登录页 `src/pages/LoginPage.tsx` **无忘记密码链接**;设置页 `src/pages/SettingsPage.tsx` 只有「偏好」+「MCP / AI 接入」两区块;改密页有 `PW_RE` 正则与依赖校验范式;react-query hooks 集中 `src/api/hooks.ts`;`client.ts` 401 拦截对认证页有豁免名单(须手动加新页);`App.tsx` 的 `AppShell` 对 `/login`、`/change-password` 判 onAuthPage 不套外壳。全站无验证码/倒计时按钮组件。
- App(`material-storage/app/`):命名路由表 `lib/app.dart:120-241`;登录页 `lib/features/auth/login_page.dart`+`login_form.dart` **无忘记密码入口**;「我的」页已有「账号与安全」分组(`lib/features/me/me_page.dart:112-124`,现只有修改密码+退出);设置页 `lib/features/settings/settings_page.dart`(MeGroup 分组范式);API 域封装 `lib/core/api/auth_api.dart`(四端点,文件头注明与后端契约对齐);倒计时先例 `GrantCountdown`(Timer.periodic 每 1s setState);表单组件 AppTextField(isDense:false 钉子);**单文件 ≤500 行硬上限**。
- 双端 `Me` 模型均无 phone 字段。

### 2.6 审计与脚本

- `audit.write()`(keyword-only,snake_case event_type,内部自带 commit);`local_login_failed` 证明无登录态也可写审计。**用户可见文案须同步 `web/src/lib/labels.ts` 与 App `audit_labels.dart`,两侧计数基线注释必须一起更新**(2026-10-31 踩过整体过期坑)。
- 脚本范式:`api/scripts/set_password.py`(容器内 `python -m`,临时密码打印一次,审计 details actor="cli");`backfill_thumbnails.py`(默认 dry-run、`--apply`、非交互 `--yes`、Redis 跑批锁);根 `scripts/create_accounts.sh`(批量建号先例)。

## 3. 关键决策记录

| # | 决策 | 理由 |
| --- | --- | --- |
| D1 | **绑定/换绑需同时提供「当前密码」,且仅限已设密码的用户**;`password_hash` 为 NULL(未设密码)的用户**不允许自助绑定**,提示「请先联系管理员设置密码后再绑定手机号」 | 超出需求字面的安全加固:若只验短信码,拿到会话(借用的手机/被窃 cookie)者可绑定自己的手机,再走忘记密码重置密码,**形成完整账号接管链**。加当前密码关隘切断该链;未设密码账号无密码可验、免验即重新敞开该链,故直接禁绑——与 `change-password` 对未设密码用户「拒绝盲改」的既有口径一致(`app/routers/auth.py:486-488`)。此类账号可由管理员经批量脚本 `--csv` 绑号(§9.4)。密码错 5 次锁 15 分钟(对齐登录锁参数) |
| D2 | 忘记密码=**系统重置随机密码并一次性展示**(不让用户自设);`must_change_password` 置 **false** | 需求原文「直接使用重置密码操作…显示给他对应的账号和密码」。置 false 才能拿来即用;否则登录即被强制改密,与「刚拿到密码」的语境冲突。随机密码仅展示一次,风险可控 |
| D3 | 验证码 **6 位字母数字组合,首位强制从字母子集抽取(保证 ≥1 个字母)**,整体去除易混淆字符(I/L/O/0/1);**HMAC-SHA256 哈希后存 Redis**(HKDF 从 `session_jwt_secret` 派生专用 key,info=`b"sms-code"`),比对用 `hmac.compare_digest` | 模板变量约束「数字+字母组合或仅字母」**排除纯数字**,纯随机有 (8/31)⁶≈0.03% 概率全数字被阿里云 `isv.SMS_TEMPLATE_ILLEGAL` 拒;首位置定字母根除(同思路先例:`app/services/passwords.py::generate_temp_password` 的三类各取一保底)。哈希存储使 Redis 泄露时无法离线穷举(沿用 email 分支 5 轮盲审定稿口径) |
| D4 | 一号一账号 = DB 唯一约束 `uq_users_phone`;占用时绑定侧**明确 409**「该手机号已绑定其他账号」;忘记密码侧按需求报「无法发送验证码」 | 绑定是登录态操作,明确报错体验最好;忘记密码侧文案遵需求原文 |
| D5 | 手机号归一化(绑定端点与批量脚本**共用同一函数规格**):strip 空格/连字符/点号 → 去 `+86`/`86` 前缀 → 校验 `^1[3-9]\d{9}$` | 兼容用户带前缀/分隔符输入;username pattern 允许连字符与点号(`app/models/__init__.py:37`),归一化必须覆盖点号,否则端点与脚本对同一 username 产出不同候选集;其余一律 400「手机号格式不正确」 |
| D6 | 频控三层:①同号同场景 2 分钟冷却(需求);②同号同场景每日 10 条(到 UTC+8 当日 24:00);③reset 场景每 IP 每小时 20 条 + bind 场景每用户每小时 10 条 | 2 分钟是需求;日配额防短信轰炸资损;阿里云自身同号频控(1 条/min、5 条/h 量级)是天然上限。**内网全员同一出口 IP**,reset 场景 IP 配额取 20/h 宽松值并做成可配置(env 可调),防误伤办公并发 |
| D7 | 验证码错误 **5 次作废**(须重新发码);TTL 900s(=15 分钟,需求) | 防穷举;首位定字母后实际空间 23×31⁵≈6.6 亿,5 次/码 + 2 分钟冷却,穷举不可行 |
| D8 | 重置成功**吊销该用户全部 PAT**(对齐 change-password);**不踢旧 session** | 吊销 PAT 是现行改密行为,对齐;踢 session 需 session_version 横切改造(邮箱方案曾设计未上),列遗留 §13 |
| D9 | 短信发送失败**不自动重试**;**处理统一:保留冷却键 + 回滚本次新增配额计数**,两类都透出 502「短信发送失败,请稍后重试」。失败分类仅用于审计与日志:**确定失败**(响应体可解析出阿里云 `Code` 且非 OK,如频控/余额/模板拒/凭证错)/ **结果未知**(本地超时/连接异常/HTTP 响应无可解析 Code——如网关空 502,请求可能已被受理) | SendSms 无幂等(技能钉子):超时≠未受理,立即允许重发可能让用户收到两条码;而确定失败(频控/余额/模板/凭证错)立即重试也**不可能成功**,回滚冷却只会形成「无节流重试环路」(每次都白打 4 次 Redis+1 次查库+1 次阿里云 HTTPS+1 行审计)。故失败一律保留冷却 2 分钟;配额回滚避免「码没发成还扣额度」。**冷却键通用原则:未真正走到「调阿里云发送」的拒绝路径(格式/409/400-denied/配额 429)一律 DEL 冷却键,发送失败(两类)一律保留** |
| D10 | 发送服务用 **httpx 自签名 ACS3-HMAC-SHA256**(移植技能已实测代码),httpx.AsyncClient 挂 `app.state.sms` | httpx 已是依赖;技能路径三运营商实测通过;零新依赖零 SDK |
| D11 | AK/SK **只进**服务器 `.env`(dev/prod)+ 本地 `scripts/env/aliyun-sms.env`(gitignored);不进代码/测试/日志/commit | 仓库公开;技能与仓库红线一致 |
| D12 | 场景隔离:Redis key 带 `scene`(bind/reset),验证码不跨场景使用 | 绑定码不能拿去重置密码,反之亦然 |
| D13 | `GET /auth/me` 回传**完整手机号**(自己可见);管理端列表/详情**不**回传 phone(本批) | 设置页需确认完整号码;管理端展示属非目标 |
| D14 | 批量脚本默认 dry-run,容器内跑,幂等,冲突名单人工裁决后二跑 | 仓库脚本安全范式(backfill 先例) |
| D15 | dev 与 prod 配同一套真实凭证 | 签名报备已全通过,dev 必须能真实送达才能验收;测试用指定真实手机号(短信计费可忽略) |
| D16 | 换绑**不需要旧手机验证码**(短信只发新号) | 当前密码已把关(D1);省一条短信与一个交互步骤 |
| D17 | 短信服务未配置(AK/SK/签名缺任一)时:相关端点返回 **503**「短信服务未配置」;**前端入口不做隐藏条件,常驻+503 文案原样透出** | 沿用 SMTP `smtp_enabled` 开关模式。设置页技术上可仿 `baidu_backup_enabled` 加能力 flag,但登录页/忘记密码页属未认证态无法先知——为双端入口行为一致+省一个探测接口,统一常驻,503 文案已足够指引 |
| D18 | 绑定两端点挂 `require_session_auth`:**PAT 一律 403**,仅交互会话可操作(与 change-password 同口径);公开的重置两端点不挂任何闸 | 手机号是账号找回通道,变更属账号安全级操作,与改密同级;仓库惯例:PAT 可直调的 router 才需要 mcp_gate,本路由直接禁 PAT(`app/deps.py:176-188` 先例),无须挂闸 |

## 4. 数据模型与迁移 0024

### 4.1 `users` 新增列

```python
# app/db/tables.py User
phone: Mapped[str | None] = mapped_column(String(20), nullable=True)  # 中国大陆手机号(11 位),一号一账号
# User.__table_args__ 补 UniqueConstraint("phone", name="uq_users_phone") —— 与迁移对齐,模型元数据与 DB 不漂移
```

### 4.2 迁移(`app/db/migrations/versions/2026_11_20_0024_user_phone.py`)

- `revision="20261120_0024"`,`down_revision="20261119_0023"`(当前 head,提交前复核单头)。
- upgrade:`op.add_column("users", sa.Column("phone", sa.String(20), nullable=True))` + **显式** `op.create_unique_constraint("uq_users_phone", "users", ["phone"])`(对齐 0009 的补建惯例,`tests/test_db_schema.py:277-308` 的 `pg_constraint contype='u'` 防假绿断言对 unique constraint 生效——用 unique index 则不在该断言覆盖内)。
- downgrade:`op.drop_constraint("uq_users_phone", "users", type_="unique")` + `op.drop_column`(0009 的 downgrade 同款;PG 唯一约束的背书索引归约束所有,**不能 `op.drop_index`**,会报依赖错误)。仅建议在未写入数据时使用;有数据后回滚走「保留列只回代码」。
- 纯增量列:旧代码不读 phone,新 schema 对旧代码无影响;**无须数据回填即可上线**(回填是独立脚本步骤)。

### 4.3 迁移前置检查(合入批量脚本 dry-run)

- 同手机号候选冲突检测:username 唯一约束只保证**原始值**唯一——username pattern `^[a-zA-Z0-9._-]+$`(允许连字符/点号,`app/models/__init__.py:37`),`13800138000` 与 `138-0013-8000` 是两个合法 username 但 **D5 归一化后折叠为同一手机号**;`--csv` 双给同理。**默认扫描必须做候选集内归一化后的同号去重检测**,冲突名单输出并跳过(人工裁决后 `--csv` 指定归属);候选号已被其他用户占用同样进名单跳过。
- 存量 `email`/`username` 与 phone 无交叉校验需求(phone 是新列,无历史数据)。

## 5. 后端设计

### 5.1 模块划分

| 模块 | 职责 |
| --- | --- |
| `app/services/aliyun_sms.py`(新) | 短信发送:ACS3-HMAC-SHA256 签名 + httpx.AsyncClient(挂 `app.state.sms`);`send(phone, template_code, code)`;`Code != "OK"` 抛 `SmsSendError(code, message)` |
| `app/services/phone_verification.py`(新) | 验证码状态机(无状态模块函数;结构先例见 `feat/email-account-reset` 分支的 `email_verification.py`,该分支未合入,仅作参照):生成/HMAC 存储/校验/尝试计数/三层频控;场景 `Literal["bind", "reset"]` |
| `app/routers/account_security.py`(新) | 登录态 + `require_session_auth`(PAT 403,D18):`/account/phone/send-code`、`/account/phone/bind` |
| `app/routers/password_reset.py`(新) | 公开:`/auth/phone/reset/send-code`、`/auth/phone/reset/confirm` |
| `app/settings.py` | 新增 `aliyun_sms_*` 配置组 + `sms_*` 频控参数组 + `aliyun_sms_enabled` property |
| `app/main.py` | lifespan 构造 `app.state.sms`(未配置时为 None)+ 挂新 router |

### 5.2 接口契约总表

| 端点 | 方法/鉴权 | 入参 | 出参/错误 |
| --- | --- | --- | --- |
| `/api/v1/account/phone/send-code` | POST,登录态(get_current_user + require_session_auth) | `{phone}` | `200 {retry_after:<冷却秒数,取 sms_send_cooldown_seconds>}`;400 格式;403 PAT/未设密码用户;409 已被占用;429 冷却/配额(带 retry_after);502 短信发送失败(`isv.BUSINESS_LIMIT_CONTROL` 时文案「操作过于频繁,请一小时后再试」,body 带 retry_after);503 未配置 |
| `/api/v1/account/phone/bind` | POST,登录态(同上) | `{phone, code, current_password}` | `200 {phone}`;400 验证码错误 / 验证码已过期,请重新获取 / **密码错=400「当前密码不正确」**(对齐 change-password 旧密码错 400 口径,`auth.py:490-498`;**不可用 401**——双端 401 全局语义是会话失效,会把输错密码的已登录用户整页踢回登录页/强制登出);403 PAT/未设密码用户;429 码已作废(5 次)或密码锁;409 并发占用;503 未配置 |
| `/api/v1/auth/phone/reset/send-code` | POST,公开 | `{phone}` | `200 {retry_after:<冷却秒数,取 sms_send_cooldown_seconds>}`;400 格式;**400 detail=「无法发送验证码」**(未绑定/已禁用);429 冷却/配额;502 短信发送失败(频控文案差异化同 bind 侧,body 带 retry_after);503 未配置 |
| `/api/v1/auth/phone/reset/confirm` | POST,公开 | `{phone, code}` | `200 {username, email, name, new_password}`(**一次性返回,不落日志**);400 码错/过期;429 已作废;503 未配置 |

- 绑定两端点还会被既有 `must_change_password` 403 白名单机制拦截(deps.py:152-153,设计内,§12.8):强制改密用户先改密;前端不另造逻辑,依赖既有路由守卫。
- 所有入参先过 D5 规范化;验证码入参服务端统一 `strip().upper()` 再比对(D3 字母表全大写,手输小写/带空格不烧 attempts);错误 `detail` 一律中文字符串(双端直接展示,FastAPI detail 语义)。
- `bind` 的 `current_password` **必填**;未设密码(`password_hash IS NULL`)用户两个绑定端点均 403 detail=「请先联系管理员设置密码后再绑定手机号」(D1)。
- 429/502 的响应体形状:**`{"detail": "<中文文案>", "retry_after": <秒>}`**(仅部分 429 携带,见下)——detail 保持字符串(双端 errorMessage 兼容),retry_after 为顶层并列字段;**Web 读取 `err.response.data.retry_after`,App 读取 `r.data['retry_after']`,无该字段的 429 不启动倒计时**。retry_after 按 429 类型分型:**冷却 429=冷却键 PTTL 毫秒上取整为秒**(仓内先例 `local_auth.py:293-310`,漏换算会把 12 分钟显示成 742000 秒);**配额 429(小时/日)=回填 `sms_send_cooldown_seconds` 配置值**(冷却键已 DEL,倒计时只是前端防抖,真实解锁由后端配额管);**码作废 429 与密码锁 429 不带 retry_after**(码作废须重新发码、受冷却管;密码锁文案自带时长)。502=冷却配置值(冷却保留)。
- `reset/confirm` 返回 `username`(可空)、`email`(可空)、`name`;前端展示优先级 username → email → name,`username` 与 `email` 皆空时附「显示名重复可能无法登录,请联系管理员」提示(§6.2/§7.2)。

### 5.3 绑定/换绑状态机(bind 场景)

**send-code 步骤顺序(router 钉死):**

1. 登录态(`get_current_user` + `require_session_auth`,PAT 403);强制改密用户会被既有 403 白名单机制拦下,符合预期;**未设密码用户(`password_hash IS NULL`)403** detail=「请先联系管理员设置密码后再绑定手机号」(D1);**503 守卫:`settings.aliyun_sms_enabled` 为假 → 503「短信服务未配置」**(四端点统一首步守卫,防 `app.state.sms=None` 走到 AttributeError 500)。
2. 规范化+格式校验 → 400。
3. 冷却 `SET NX EX sms_send_cooldown_seconds` 未抢到 → 429 `{retry_after}`(PTTL 上取整)。
4. 每用户每小时 ≤ `sms_bind_user_hourly` → 429 + DEL 冷却键(**先于占用预检**:409 探测同样消耗探测者自己的小时配额,登录态枚举「该号是否已绑定」被 10/h 兜住,§8.1)。
5. 占用预检:`SELECT id FROM users WHERE phone = :phone AND id != :me` 命中 → 409「该手机号已绑定其他账号」+ **DEL 冷却键**(未产生发送不占冷却,D9 通用原则)。
6. 每号每日 ≤ `sms_daily_per_phone` → 429 + DEL 冷却键(**后置于占用预检**,与 reset 侧对称:探测已占用号不会烧目标号的日配额——否则内部用户可无短信痕迹地把某号全天的绑定额度耗尽)。
7. 生成 6 位码:**首位从字母子集 `ABCDEFGHJKMNPQRSTUVWXYZ` 抽取,其余 5 位从全表 `ABCDEFGHJKMNPQRSTUVWXYZ23456789` 抽取**(保证 ≥1 字母,D3),HMAC 哈希写 Redis hash `{code_hash, attempts:0, user_id}` TTL `sms_code_ttl_seconds`,**覆盖旧码**(旧码自然失效)。
8. 调 `app.state.sms.send(phone, settings.aliyun_sms_template_bind, code)`;失败按 D9 统一处理(保留冷却键+回滚配额,分类仅进审计/日志),审计 `sms_send_failed`,抛 502「短信发送失败,请稍后重试」。
9. 审计 `phone_code_sent`(details: scene=bind, phone_masked, biz_id, template_code)→ 200。

**bind 步骤顺序:**

1. 登录态 + `require_session_auth` + 未设密码 403 + 503 守卫(同上);规范化;取 Redis 码 hash,缺失 → 400「验证码已过期,请重新获取」;**校验 hash 里 user_id == 当前用户,不一致 → 400「验证码已过期,请重新获取」**(发码与提交之间换账号登录的边角,与 reset 侧口径一致)。
2. `hmac.compare_digest` 比对;不符 → `HINCRBY attempts`;≥5 → DEL 码键,429「错误次数过多,请重新获取」;否则 400「验证码错误」。
3. 验 `current_password`(argon2,必填):先查锁 `sms:pwlock:{user_id}` 存在 → 429「尝试次数过多,请 {sms_bind_password_lock_seconds//60} 分钟后重试」(动态拼,登录锁 `auth.py:391` 同款);不符 → **400「当前密码不正确」** + `INCR sms:pwfail:{user_id}` 并**每次补 `EXPIRE sms_bind_password_lock_seconds`**(滑动窗口=锁时长,对齐 `local_auth.record_failure` 用同一 `auth_lock_seconds` 做窗口与锁的口径);计数 ≥5 → **同一原子操作里写锁 EX `sms_bind_password_lock_seconds` 并 DEL 计数**(锁到期后从零开始,不会一次锁死终身循环)+ **审计 `phone_bind_locked`**(锁触发瞬间留痕,对齐登录锁 W1 补审计先例),429 同动态文案;验过 → 清计数与锁残留。
4. 单事务:`UPDATE users SET phone=:phone WHERE id=:me`;`IntegrityError` → 409「该手机号已绑定其他账号」(并发窗口由唯一约束兜底)。写库成功后 DEL 码键(消费;重放窗口内二次提交同值幂等,无危害)。
5. 审计 `phone_bound`(details: old_masked/new_masked);DEL 计数键;返回 `{phone}`。
6. 换绑即覆盖旧值,无额外流程(D16);不吊销 PAT、不动 session(手机号与凭证无关)。

### 5.4 忘记密码(reset 场景)

**send-code 步骤顺序:**

1. **503 守卫**(同 §5.3);规范化+格式 → 400「手机号格式不正确」(纯格式错不消耗任何计数)。
2. 同号冷却 `SET NX EX sms_send_cooldown_seconds` → 429(**先冷却后 IP 计数**:同一号码的重复点击在冷却层就被拦,不烧 IP 配额)。
3. **IP 配额**:`INCR sms:ip:reset:{ip}:{epoch_hour}`(+EXPIRE 3600)超 `sms_reset_ip_hourly` → 429 + DEL 冷却键——**在查库之前计数,「未绑定号」的 denied 请求同样消耗 IP 配额**(枚举者换不同不存在号码打库也会烧光配额;IP 计数不因 denied 回滚,枚举防护保留),防全速枚举;内网同出口 IP 的真实办公并发按 20/h 校准(env 可调,§12.10)。
4. 查库:`SELECT ... FROM users WHERE phone = :phone AND is_active = true`(单行;唯一约束保证至多一行)。**未命中 → 400 detail=「无法发送验证码」** + **DEL 冷却键**(D9 通用原则)+ 审计 `phone_reset_denied`(details: phone_masked;request_ip 走独立审计列)——需求 R2b 原文行为。
5. 日配额(同号 ≤ `sms_daily_per_phone`)→ 429 + DEL 冷却键。
6. 生成码+HMAC 存储(同 §5.3 第 7 步,scene=reset,hash 里记发码时归属 user_id)。
7. 发送模板 `SMS_512523885`;失败处理同 D9(保留冷却键+回滚配额,分类仅进审计/日志)。
8. 审计 `phone_code_sent`(actor=命中用户,details 冗余 user_id/scene/phone_masked/biz_id/template_code)→ 200。

**confirm 步骤顺序:**

1. **503 守卫**;规范化;**原子消费式验码**:**Python 侧计算提交码的 HMAC digest → digest 作为 ARGV 传入 Lua,Lua 内做定长字符串比较 + DEL/HINCRBY,读-比-删一原子**:「读 stored hash → **key 不存在(missing/过期)直接返回 expired,不做 HINCRBY、不重建键(§5.5 口径,email 分支 `_ATTEMPT_INCR_LUA` 的 EXISTS 守卫同款)** → 等长比较 → 命中即 DEL 码键并返回 stored user_id / 未命中 HINCRBY attempts(≥5 连码键一起 DEL)并返回失败原因」。验码通过即消费,并发双提交只有一次能走到改密,**杜绝两个随机密码先后覆盖、用户拿到的展示密码与生效密码不一致**。(Lua 内等值比较非常数时间,此场景可接受:digest 由服务端密钥计算,攻击者无法借比较耗时反推;先例:email 分支的 Python 比对+独立 Lua `_ATTEMPT_INCR_LUA` 两段式,本设计在其上加 DEL 原子化。)
2. 再查归属用户:`phone → active user` 未命中,或**发码时归属(码 hash 里的 user_id)≠ 当前归属**(15 分钟窗口内换绑/二次放号的镜像场景)→ 400「验证码已过期,请重新获取」(不泄露差异)。
3. 生成 12 位临时密码(`secrets`,复用 `app/services/passwords.py::generate_temp_password` 的三类保底思路);argon2 哈希。
4. 单事务:`UPDATE users SET password_hash=:hash, must_change_password=false WHERE id=:uid` + **吊销该用户全部 PAT**(对齐 change-password,`app/routers/auth.py:512-513` 同款)。
5. 审计 `password_reset_via_phone`(actor=该用户,request_ip 走审计列,details: phone_masked;**绝不落密码材料**);**commit 后对每个被吊销 PAT 逐令牌写既有 `token_revoked`**(details reason="phone_reset",对齐 change-password 的逐令牌审计 `auth.py:522-535`——否则审计页无法追溯「哪些 PAT 因手机重置而失效」;复用既有事件,labels 不加项)。
6. 返回 `{username, email, name, new_password}`——**一次性返回,不存明文、不进日志**;响应头加 `Cache-Control: no-store`。

### 5.5 限流与风控(Redis key 总表)

| key | 类型/TTL | 含义 |
| --- | --- | --- |
| `sms:code:{scene}:{phone}` | hash `{code_hash, attempts, user_id}` EX 900 | 当前验证码(HMAC 哈希;user_id=发码时归属,confirm 归属复核用,§5.4) |
| `sms:cd:{scene}:{phone}` | string EX 120 | 发送冷却(SET NX) |
| `sms:day:{scene}:{phone}:{yyyymmdd}` | int EX 至 UTC+8 当日 24:00 | 每号每日 ≤10 |
| `sms:u:{user_id}:{epoch_hour}` | int EX 3600 | bind 场景每用户每小时 ≤10 |
| `sms:ip:reset:{ip}:{epoch_hour}` | int EX 3600 | reset 场景每 IP 每小时 ≤20(可配置,内网同出口 IP 注意余量) |
| `sms:pwfail:{user_id}` / `sms:pwlock:{user_id}` | int EX `sms_bind_password_lock_seconds`(每次 INCR 续 EXPIRE,滑动窗=锁时长)/ 锁 EX 同配置 | bind 密码错 5 次锁 15 分钟;**写锁同操作 DEL 计数**,锁到期从零开始 |

- 尝试计数沿用 email 分支定稿口径(先例在 `feat/email-account-reset` 分支,未合入):Lua/管道原子 HINCRBY,仅 TTL<0 时补 EXPIRE(不续期,防止有效期漂移);key 过期竞态按 missing 处理不重建。
- 日界用固定偏移 `timezone(timedelta(hours=8))`,不用 ZoneInfo(slim 镜像无 tzdata,已知坑)。

### 5.6 短信发送基础设施(`app/services/aliyun_sms.py`)

- 构造:`AliyunSmsService(settings)`;`main.py` lifespan 里 `app.state.sms = AliyunSmsService(...) if settings.aliyun_sms_enabled else None`,关闭时 `aclose()`。
- `async send(phone: str, template_code: str, code: str) -> str`(返回 BizId):
  - V3 签名 `ACS3-HMAC-SHA256`:POST dysmsapi.aliyuncs.com `/?Action=SendSms&Version=...`,canonical query 按 key 排序 RFC3986 编码;头 `x-acs-action/x-acs-version/x-acs-date(ISO8601 UTC)/x-acs-signature-nonce/x-acs-content-sha256(空 body 哈希)`;`Authorization: ACS3-HMAC-SHA256 Credential={AK},SignedHeaders=...,Signature=HMAC-SHA256(SK, ...)`。**逐行对照技能 `scripts/sms_api.py` 已实测代码移植**,不凭记忆重写。
  - 参数:PhoneNumbers/SignName/TemplateCode/TemplateParam(`json.dumps({"code": code})`——必须是 JSON **串**)。
  - httpx.AsyncClient 复用(挂服务实例内),timeout=5s(connect/read);**不重试**(D9)。
  - 失败分两类异常(D9):**响应体可解析出阿里云 `Code` 且非 OK** → `SmsSendError(code, message)`(**确定失败**,含 `isv.BUSINESS_LIMIT_CONTROL` 频控、`isv.AMOUNT_NOT_ENOUGH` 余额等);**无响应/本地超时/连接异常,或收到 HTTP 响应但无可解析 Code(如网关空 502——请求可能已被受理)** → `SmsTransportError`(**结果未知**)。router 层统一 502 文案,错误码进审计 details。
  - 结构化日志:phone_masked/Code/BizId/TemplateCode;**AK/SK/验证码明文永不落日志**。
- 排障(不入服务):管理员按技能用 `QuerySendDetails`(SendDate=yyyyMMdd,BizId 去留 `^0` 均可)手工查送达;本批不做常驻回执。

### 5.7 审计事件(新增 6 个)

| event_type | actor | details 要点 |
| --- | --- | --- |
| `phone_code_sent` | bind=当前用户 / reset=归属用户 | scene、phone_masked、biz_id、template_code、user_id(冗余,reset 侧) |
| `sms_send_failed` | 同上 | scene、phone_masked、err_code、err_message(阿里云原文;**transport 类无阿里云原文,err_code 用哨兵值 `transport_timeout`/`transport_unparseable`,err_message 落本地异常摘要**) |
| `phone_bound` | 当前用户 | old_masked、new_masked(首次绑定 old 为 null) |
| `phone_bind_locked` | 当前用户 | phone_masked(bind 密码锁触发瞬间留痕,W1 先例;审计列 request_ip) |
| `phone_reset_denied` | 无(未认证) | phone_masked(R2b 枚举面留痕;request_ip 走独立审计列) |
| `password_reset_via_phone` | 归属用户 | phone_masked(无密码材料;request_ip 走独立审计列) |

- **phone_masked 脱敏规格全文统一:前 3 位 + `****` + 后 4 位(如 138****8000)**——router×3 与批量脚本多写入点共用同一工具函数,双端审计页按此显示。
- **公开端点(reset send-code/confirm/denied)的审计写入显式传 `auth_method=None`**:`_default_auth` 对带 request 且非 PAT 的调用一律落 `("session", None)`(`app/services/audit.py:74-79`),公开端点上从未执行 `get_current_user`,不覆盖会把无认证事件误标 session。**现有 `write()` 的 `auth_method=None` 是默认值、无法表达「显式落 NULL」——B2 须给 `write()` 加模块级哨兵(如 `_UNSET` 默认值,`None` 变成可表达的覆盖值),这是本批对 audit.py 的一处小改造**。
- **同步义务(四处,同在 B2 包落地)**:①`web/src/lib/labels.ts::tlabel` 映射;②`web/src/pages/AdminAuditPage.tsx` 的 `EVENT_TYPES` 过滤下拉数组**及其计数基线注释**(Select 未开 tags 模式,漏了就选不了新事件);③`AdminAuditPage.tsx` 的 `DETAIL_KEY_LABEL`(本批新 details 键 scene/phone_masked/biz_id/template_code/err_code/err_message/old_masked/new_masked/source,漏了按键名裸显英文,`labels.ts:89-91` 注释明示此义务);④App `audit_labels.dart` 映射+计数注释。四处计数一律按当时代码实数,勿沿用文档里的过时数字(2026-10-31 整体过期坑)。

### 5.8 配置项(`app/settings.py`)

```python
# 阿里云短信(凭证不进仓库,服务器 .env / scripts/env/aliyun-sms.env)
aliyun_sms_ak: str | None = None
aliyun_sms_sk: str | None = None
aliyun_sms_sign_name: str | None = None            # 成都讨喜未来文化传媒
aliyun_sms_template_bind: str = "SMS_512538915"
aliyun_sms_template_reset: str = "SMS_512523885"

@property
def aliyun_sms_enabled(self) -> bool: ...          # ak+sk+sign 齐备

# 验证码/频控(默认值可被 .env 覆盖,便于不动代码调余量)
sms_code_ttl_seconds: int = 900                    # 需求:15 分钟
sms_send_cooldown_seconds: int = 120               # 需求:2 分钟一条
sms_daily_per_phone: int = 10
sms_bind_user_hourly: int = 10
sms_reset_ip_hourly: int = 20
sms_code_max_attempts: int = 5
sms_bind_password_max_fails: int = 5
sms_bind_password_lock_seconds: int = 900          # 密码锁时长(默认对齐 auth_lock_seconds,env 可调)
```

- `.env.example` / `.env.production.example` 补注释段(必填项、force-recreate 提示);未启用时四端点 503(D17)。

## 6. Web 端设计

### 6.1 登录页(`web/src/pages/LoginPage.tsx`)

- 密码输入框下方右侧加「忘记密码?」`Button(type="link", size="small")` → `navigate('/forgot-password')`;保留既有锁定文案行。

### 6.2 忘记密码页(新 `web/src/pages/ForgotPasswordPage.tsx`)

- 单页三态(antd Form,卡片布局与 LoginPage 同款):
  1. **输手机号**:`Input`(前置说明「请输入绑定的手机号」)+「获取验证码」按钮(提交 send-code;成功后进入态 2 并**以响应 `retry_after` 为初值启动倒计时**,默认 120s;按钮倒计时内 disabled 显示「重新获取(119s)」;502/429 透出 detail 文案,**响应带 `retry_after` 时以之为初值启动倒计时,不带(码作废/密码锁类 429)则不启动**(冷却/配额类拒绝的冷却键在后端存活或由配额管,立即可点只会再吃同码);400「无法发送验证码」用 `message.error` 原样透出,不解释原因(遵需求文案)。
  2. **输验证码**:`Input`(6 位,`maxLength=6`)+「重置密码」提交 confirm;附「换一个手机号」链接回态 1。
  3. **结果态**:`Result(status="success")` 展示 **账号 + 新密码**(`Typography.Text copyable`,一键复制);账号显示优先级 username → email → name,`username`/`email` 皆空(仅 name)时附提示「若显示名重复导致无法登录,请联系管理员」;提示「请妥善保管,建议登录后在设置中修改为自己易记的密码」+「去登录」按钮回 /login。
- 失败/过期文案统一透出后端 detail;倒计时用 `useState+useEffect setInterval` 每秒递减(GrantCountdown 同款,cleanup 清除)。

### 6.3 路由与会话放行

- `App.tsx`:lazy 挂载 + `<Route path="/forgot-password">`;`AppShell` 的 onAuthPage 判断加 `/forgot-password`(与 /login、/change-password 同列,**未登录时不套外壳、可直达**;已登录访问则落在带 AppHeader 的完整外壳里,与已登录访问 /change-password 的现状一致,属预期行为非 bug)。
- `client.ts`:401 整页跳转的认证页豁免名单加 `/forgot-password`。
- 已登录用户访问 /forgot-password:允许(不 Navigate 回首页)——改密场景已登录也可能用;保持简单。

### 6.4 设置页(`web/src/pages/SettingsPage.tsx`)

- 新区块「账号与安全」(BlockTitle + 卡片,置于「偏好」之上):展示「手机号」当前值(完整号,D13;未绑定显示「未绑定」+ 灰色 Tag)+ 按钮「绑定手机」/「更换手机」。
- 点击开 `Modal`(antd Form):
  - 新手机号 Input(必填,前端 D5 正则预校验);
  - 验证码 Input(`maxLength=6`,防粘贴长串白烧 attempts)+ 行内「获取验证码」按钮(以响应 `retry_after` 为初值启动倒计时,200/502/部分 429 带该字段;409 占用/429 冷却文案透出,409 后按钮立即可再点——冷却已回滚;502/429 透出 detail,**带 `retry_after` 则启动倒计时,码作废/密码锁类 429 无此字段则不启动**;
  - 当前密码 `Input.Password`(必填);**`me.password_set` 为 false 时整个入口禁用**,按钮置灰+提示「请先联系管理员设置密码后再绑定手机号」(D1,与后端 403 对应);
  - 提交 bind → 成功 `message.success` + 关 Modal + `queryClient.invalidateQueries(['me'])`。
- hooks(`src/api/hooks.ts` 新增四个 mutation,模式照 useChangePassword):`useSendPhoneCode` / `useBindPhone` / `useResetSendCode` / `useResetConfirm`(send-code 按 **200** 判定,勿引入 202——App 侧 auth_api 的 `statusCode != 200` 判错惯例会误伤);`src/api/types.ts` 的 `Me` 加 `phone?: string | null`(可选+`??` 回落,沿用该文件「旧后端无此字段」的既有惯例,SPA 先于 API 上线不炸)。

## 7. App 端设计(Flutter)

### 7.1 登录页

- `lib/features/auth/login_form.dart`:密码框与登录按钮之间右对齐「忘记密码?」`TextButton` → `Navigator.pushNamed('/forgot-password')`;`login_page.dart` 路由注册在 `lib/app.dart` switch 加 case。

### 7.2 忘记密码页(新 `lib/features/auth/forgot_password_page.dart`)

- 三态页面(照 login_page 品牌壳+表单区+固定错误区范式):
  1. 手机号 `AppTextField(keyboardType: TextInputType.phone)` +「获取验证码」按钮(倒计时 `GrantCountdown` 同款 Timer.periodic 模式,以响应 `retry_after` 为初值(200 必带;502/部分 429 带,**码作废/密码锁类 429 无则不启动**);「无法发送验证码」落固定错误区);
  2. 验证码 `AppTextField(maxLength: 6)` +「重置密码」+「换个手机号」;
  3. 结果视图:账号(大字,显示优先级 username → email → name,仅 name 时附「若显示名重复导致无法登录,请联系管理员」小字)+ 新密码(等宽字体 + 复制图标,`Clipboard.setData`+就地 toast)+「去登录」(`pushNamedAndRemoveUntil('/')`)。
- 错误处理:`ApiException` 透传 detail(errorMessage),其余中文 fallback;`/forgot-password` 加入 `app.dart` 路由表。

### 7.3 「我的 → 账号与安全 → 手机号」

> 映射说明:需求原文「设置界面」在 App 侧落位于「我的→账号与安全」而非 settings_page(后者是偏好/MCP 页)——安全类操作与「修改密码」同分组,符合既有信息架构,属**有意映射**而非缺失;Web 侧无此歧义(设置页即承载)。

- `me_page.dart`「账号与安全」分组(现有「修改密码」行上方)加 `AppRow(手机号, subtitle: me.phone ?? '未绑定')` → `pushNamed('/account-phone')`。
- 新页 `lib/features/me/account_phone_page.dart`(预估 ~300 行,超 500 拆 sheets 子文件,照 account_email_page 先例):
  - 顶部当前绑定展示(完整号;未绑定提示文案);
  - 换绑/绑定表单:手机号 + 验证码(`AppTextField(maxLength: 6)`,「获取验证码」倒计时按钮,倒计时初值取响应 `retry_after`——**App 侧非 200 响应抛 `ApiException`,retry_after 经既有 `ApiException.raw` 字段读取 `raw['retry_after']`,勿另造返回通道**)+ 当前密码 `PasswordField`(必填);**`me.password_set` 为 false 时表单禁用**+同款提示(D1);
  - 提交成功:toast + 刷新 me——`Session` 门面新增 `refreshMe()` 方法(把 `changePassword()` 内联的 `me = await api!.auth.me()` + 通知,抽成公共方法,`lib/core/session.dart` 现无此方法,属本批新增;**须保留失败→日志留痕+`_meStale=true` 标脏、下次 restore 强制重拉的兜底分支**(`session.dart:210-226` 现行为),changePassword 改为委托调用)+ pop;
  - 409/429/502 文案透出;`session.me` 变更后「我的」页 subtitle 同步(invalidate 等价:页面可见时重取 me)。
- `lib/core/api/auth_api.dart` 加四端点(与后端契约 §5.2 对齐,文件头注释同步);`lib/models/me.dart` 加 `phone`,**并补解析 `password_set`**(可空 bool,`?? false` 回落)——后端 `/auth/me` 已回传该字段(`auth.py:327`)但 App 模型从未解析,§7.3 的 D1 前端闸门(`me.password_set` 为 false 禁绑)依赖它。

### 7.4 测试与发版

- widget/单测:登录页忘记入口存在与跳转;忘记页三态流转+「无法发送验证码」错误区;account_phone_page 倒计时按钮状态机(注入 clock);auth_api 四端点契约(fake dio 照 api_harness 先例);me.phone 解析。
- `flutter analyze` 0 issue;发版走 release.mjs 七牛链路(本批是否发版由用户拍板,不阻塞合并)。

## 8. 安全分析与取舍

### 8.1 账号枚举

- reset send-code 对未绑定号明确报「无法发送验证码」=**需求拍板接受**的枚举信号(比通用文案弱一档,但 11 位号空间大、且发送侧有频控);每次 denied 留审计 `phone_reset_denied` 供风控页回看。
- bind send-code 的占用预检 409(§5.3 第 5 步)**也是一个「该号是否已绑定」的枚举信号**,已如实评估:预检后置于配额,探测同样消耗每用户 10/h 小时配额;且仅登录态可调、内网环境(bind 侧拒绝路径**不写审计**,防护=配额+登录态,弱于 reset 侧的 denied 审计——按渠道风险对齐:登录态探测者身份可经登录审计关联)——与 reset 侧强度按渠道风险对齐。

### 8.2 接管链分析

- **会话劫持者**(借用手机/窃取 cookie):绑自己手机被 D1 当前密码关隘拦住;密码错 5 次锁 15 分钟(滑动窗计数+锁到期归零,不会一次锁死终身循环)。
- **未设密码账号的会话持有者**:D1 直接禁绑(403),无免验旁路——该类账号自助绑定通道整体关闭,只能管理员经脚本绑号;§5.4 忘记密码对其生效的前提是管理员已主动绑号,属受控运营动作。
- **PAT 通道**:绑定两端点 `require_session_auth` 一律 403(D18),泄漏的 MCP 令牌不能改绑定关系。
- **手机持有者**(拿到别人手机+知道其手机号):reset send-code 会真发短信到机主手机(机主可察觉);confirm 需要码且验码即原子消费;审计全程留痕。
- **并发竞态**:两账号同时绑同一号 → 唯一约束兜底,后写者 IntegrityError→409。
- **码穷举**:6 位 31 字母表 + 5 次作废 + 2min 冷却 + 日 10 条(§5.5),计算上不可行;HMAC 存储防 Redis 泄露离线穷举。

### 8.3 凭证与传输

- AK/SK 只在服务器 `.env` 与本地 `scripts/env/aliyun-sms.env`(gitignored);代码/测试/日志/commit 零出现(测试用 FakeSms 注入)。可选加固(运维项,不阻塞):为短信单独建 RAM 子账号,只授 `dysms:SendSms`+`dysms:QuerySendDetails`。
- 短信内容只含验证码;绑定模板语义「变更重要信息」,重置模板语义「密码重置」,与实际操作一致。

### 8.4 CSRF / 会话

- bind 端点登录态 POST:cookie SameSite=lax(跨站 POST 不携带)+ JSON body,与 change-password 同暴露面,无新增面;PAT 一律 403(D18)。
- reset 端点公开无 cookie 依赖,无 CSRF 面;confirm 响应 `Cache-Control: no-store` 防中间层缓存凭据;枚举打库被 IP 配额前置兜住(§5.4 第 3 步,查库之前计数)——**但 IP 维度是「尽力而为」防线**:uvicorn 以 `--proxy-headers --forwarded-allow-ips '*'` 运行(`Dockerfile:33`),若 nginx 对 /api 的 XFF 是追加而非覆盖,客户端可伪造 XFF 旋转 IP 桶(§12 钉子 13 上线前核实);真实兜底=同号冷却+日配额+审计留痕。

### 8.5 仍存在的风险(如实记录)

- reset 后旧 session 存活至自然过期(≤7 天)——与改密现状一致(D8,遗留 §13)。
- 运营商二次放号:新机主可对旧号走忘记密码——行业共性风险,兜底=账号另有 username+密码,且 reset 有审计可回溯。
- **reset 冷却/短信骚扰面**:知道他人手机号者可对其触发 reset send-code,令该号 120s 内冷却(本人合法重置被 429)+ 向其手机发真实短信(≤10 条/日,可感知);危害有界、当日自愈,审计有痕;与二次放号同列为已接受的低危面。
- **号码占用死锁面**:占用预检不过滤 `is_active`——离职/禁用账号占用的号码对自助绑定永远 409,而本批无解绑(§1.3)、管理端编辑属遗留(§13),该号无释放通道,须管理员走 DB/临时脚本处理;列为已接受的运营面,遗留项 §13 收录。
- **bind 侧骚扰/资损面**:任一已登录用户可对任意「格式合法且未占用」的手机号触发 bind send-code 发真实短信(≤10 条/日/号,消耗的是发起者自己的 10/h 与目标号日配额);属已接受面,防线=D6 三层配额+短信计费可忽略的内部用量。
- `must_change_password=false`(D2):系统生成的随机密码可能被用户长期使用;结果页已引导修改,不强制。

## 9. 部署与运维

### 9.1 配置(`.env` 不进 git)

- dev/prod `.env` 追加:`ALIYUN_SMS_AK` / `ALIYUN_SMS_SK` / `ALIYUN_SMS_SIGN_NAME=成都讨喜未来文化传媒`(模板两码走默认值,可不配);频控参数按需覆盖。
- 本地备份:`scripts/env/aliyun-sms.env`(AK/SK/SignName,同 qiniu.env 先例)。
- 改 `.env` 后必须 `docker compose up -d --force-recreate ms-api ms-worker`(restart 不重读 env_file);**force-recreate ms-api 后容器 IP 变,poc-nginx 静态 proxy_pass 持旧解析会全站 502,须连带 `docker restart poc-nginx`**(2026-11-18 实锤钉子)。

### 9.2 上线顺序(dev → prod)

1. 合并 feat 分支 → `deploy_lan.sh <env>`(不带 --restart,同步代码)。
2. **alembic 对账**:`alembic current` vs `head`(prod 两次踩过跨版本上代码没带迁移)→ `alembic upgrade head`(0024 纯增量,秒级)。
3. `.env` 补凭证 → force-recreate ms-api ms-worker → restart poc-nginx。
4. SPA build 后单独 tar 同步(deploy_lan 不同步 static/web)。
5. 验证:三入口 SPA 指纹一致;/healthz;登录正常;`/auth/me` 含 phone:null;dev 真实手机发码送达(技能已验三运营商);忘记密码全链(拿到的新密码可登录且 PAT 已吊销)。
6. prod 同序;发版窗口注意 prod 活动任务(百度备份)清零判据(仓库惯例)。

### 9.3 回滚

- 代码回滚:0024 是纯增量列,旧代码不读 phone,**直接回代码不须 downgrade**;已绑定的 phone 数据保留在列里,再次上线即恢复。
- 仅当 0024 未写任何数据且确需回收时才 `alembic downgrade -1`。

### 9.4 批量绑定执行手册(`scripts/bind_user_phones.py`)

- 位置:`material-storage/api/scripts/bind_user_phones.py`,容器内跑:`docker exec ms-api python -m scripts.bind_user_phones [--apply] [--csv /path/to/pairs.csv] [--yes]`。
- 默认扫描**只认 username**(email 形态如 `13800138000@139.com` 不自动绑:邮箱本地部分归一化会引入跨账号折叠歧义,且该形态存量极少,确有需要走 `--csv` 人工指定——口径已定,如有异议可在实施前提出):username **先做 D5 同款归一化**(strip 空格/连字符/点号、去 `+86`/`86` 前缀)再匹配 `^1[3-9]\d{9}$`(归一化后仍是 11 位合法号才命中,写入归一化值)→ 候选 phone;已有 phone 的跳过;**归一化折叠出的同号多候选**(§4.3:username pattern 允许连字符/点号,唯一约束不防归一化折叠)与候选号已被他人占用、`--csv` 双给,一律进冲突名单跳过;**`--csv` 二跑对「占用冲突」同样拒绝并输出名单(绝不覆盖唯一约束,须先人工解除原绑定)**。
- `--csv`:额外人工指定对(格式 `identifier,phone`,identifier 支持 username/email/name/UUID,同 set_password 匹配口径;**phone 同样走 D5 归一化后写入**),用于冲突裁决与补充。**对未设密码用户经 csv 绑号时输出提示**:该用户绑定后即可走「忘记密码」自助获得登录密码(这是该类 dormant 账号回到本地登录的正路,也说明 D1 的自助禁绑不影响运营通道)。
- dry-run 默认输出表格(用户/username/phone/动作:bind|skip|conflict);`--apply --yes` 实跑(幂等,可重跑);逐条写审计 `phone_bound`(details actor="cli",source="backfill",old/new masked,照 set_password.py 的独立 session 模式)。
- 执行序:dev dry-run 核对 → dev apply → prod dry-run 核对 → prod apply;冲突名单人工裁决后 `--csv` 二跑。

### 9.5 文档

- `rushes-spec/material-storage/ops-manual.md` 新增「手机号与短信找回」节:配置项/上线顺序/回滚/排障(QuerySendDetails 手工查法+常见错误码表指引技能)/批量脚本手册。
- `.env.example` / `.env.production.example` 补段;`scripts/changelog.md` 按仓库约定记账。

## 10. 测试与验收

### 10.1 API 测试(两层:本地纯单元 + 容器内路由级)

**分层依据(勿混)**:现有 FakeRedis+aiosqlite 范式(`test_local_auth.py`)只测**服务函数**、不经 FastAPI app;本地无 DB 的路由级测试仅 `dependency_overrides`+stub 先例(`test_notifications_router.py`),覆盖不了本方案必需的真 SQL(占用 409/唯一约束竞态)与审计写入——`audit.py` 的 `pg_insert(...).on_conflict_do_nothing` 是 PG 方言(SQLite 编译失败)+ `get_sessionmaker` 模块级缓存(`app/db/session.py:17`)。故路由级按 `test_local_auth_integration.py` 范式跑 ms-api 容器(create_app()+lifespan+真实 PG/Redis,无 DB 自动 skip):

**本地纯单元(无 DB,照 test_local_auth.py 范式):**

- `tests/test_aliyun_sms.py`:签名串构造纯函数(canonical query/头排序/TemplateParam JSON 串);SmsSendError/SmsTransportError 分类。(不发真实请求。)
- `tests/test_phone_verification.py`(服务函数直调,FakeRedis 注入):码字符集与长度 + **1000 次采样无一纯数字(首位置定字母保底)**;HMAC 写读循环;attempts 5 次作废;冷却/日配额/小时配额边界;TTL 不续期口径;**密码锁到期后计数从零恢复**。
- B5 脚本测试(`tests/test_bind_user_phones.py`,SQLite+桩,照 `test_backfill_script.py` 先例(monkeypatch 隔离+固定钟+内存 redis 替身)):D5 归一化折叠冲突名单/已有 phone 跳过/**候选号已被他人占用进冲突名单跳过**/`--csv` 双给冲突/**`--csv` 二跑对占用冲突拒绝(不覆盖唯一约束)**/幂等重跑零变更/审计 details(source=backfill,phone_masked 前3后4规格)/dry-run 不写库。
- **FakeRedis 前置基建**:现有手写 FakeRedis/FakePipeline 只覆盖 get/set(ex)/delete/incr/expire/pipeline;本设计还需要 **SET NX EX(冷却)、HSET/HGET/HINCRBY(码 hash)、PTTL、条件 EXPIRE、eval**——B2 须先补齐命令面。「实现 Lua 解释器」不现实,采用**注入路径**:原子消费/计数 Lua 收敛为可注册的 Python 回调,FakeRedis.eval 按 key/argv 分派到回调(真 Redis 走真 Lua),两侧同一语义。

**容器内路由级(照 test_local_auth_integration.py 范式,本地无 DB 自动 skip):**

- FakeSms:测试 app 里以假实现替换 `app.state.sms`,记录调用参数(模板/手机号/码长度);**真实凭证零出现、零真实发送**。
- `tests/test_phone_bind_api.py`:send-code 快乐路/格式 400/占用 409(409 后冷却键已回滚,同号再试不会翻成 429)/冷却 429/**配额 429 后冷却键已回滚(D9 通用原则)**/日配额 429(仅在占用预检通过后才计数)/未配置 503/PAT 403;bind 验码错/过期/作废 429/**发码后换账号登录再 bind → 400 过期(user_id 复核)**/密码错与锁(含锁到期恢复)/**未设密码用户 403**/并发 IntegrityError 409;me 回传 phone;**D9 失败统一语义自动化**:FakeSms 抛 `SmsSendError` 或 `SmsTransportError`(含「HTTP 响应无可解析 Code」)→ 断言**冷却键均保留**+配额均回滚。
- `tests/test_phone_reset_api.py`:未知号 400「无法发送验证码」+冷却键已回滚+审计 denied(auth_method 显式 None)+ **denied 消耗 IP 配额(第 21 次/h 连合法号也 429)**/同号日配额 429(§5.4 步骤 5,冷却键已回滚);**同号重复点击在冷却层被拦且不烧 IP 配额(换号枚举才烧)**;未配置 503;D9 失败统一语义同 bind 侧;confirm 快乐路返回 {username,email,name,new_password} 且**新密码可登录**、`must_change_password=false`、PAT 全吊销、审计写入;错码 5 次作废;**并发双 confirm 只有一次生效(原子消费验码)**;**发码后换绑再 confirm → 400 过期(归属复核)**;confirm 后码键已删。
- 容器集成与真机链路在 dev 部署后验证(本地 docker 禁跑,2026-10-20 立)。

### 10.2 Web 手工清单

忘记密码入口可达;三态流转;「无法发送验证码」文案原样;结果页账号+密码可复制且复制反馈;倒计时按钮状态;设置页绑定 Modal 全字段校验;409/429/502 文案;me 刷新后手机号显示;已登录/未登录访问 /forgot-password 均正常;审计页新事件中文文案与计数基线一致;短信未配置时 503 文案原样透出(D17 常驻入口的关键行为)。

### 10.3 App

widget 测试见 §7.4;真机:收码(移动/联通/电信各一)→ 绑定 → 换绑 → 忘记密码全链 → 新密码登录;倒计时与错误态;审计标签页显示。

### 10.4 跨端硬项

- 同一手机号在 A 账号绑定后,B 账号(登录态)send-code 返回 409 文案。
- 忘记密码重置后:旧密码失效、新密码可登录、PAT 全失效(MCP 令牌页验证)。
- 2 分钟内重复点发送,两端按钮态与后端 429 一致。
- 短信失败(D9 统一语义):502 文案 + 冷却保留(2 分钟后才可重发)+ 配额已回滚;FakeSms 两类异常(SmsSendError/SmsTransportError)行为一致。

## 11. 实施顺序(建议拆 5 包:B1→B2→(B3∥B4)→B5)

| 包 | 内容 | 备注 |
| --- | --- | --- |
| B1 后端基建 | settings 配置组+`aliyun_sms.py`(签名移植)+迁移 0024+tables/models+`/auth/me` phone+**test_db_schema 补 `uq_users_phone` 防假绿断言**+`main.py` lifespan 接线(`app.state.sms`,未配置为 None)+服务单测 `test_aliyun_sms.py` | 独立可合,端点未上无行为变化 |
| B2 后端端点 | `phone_verification.py`+`account_security.py`+`password_reset.py`+审计 6 事件(§5.7)+**audit.write() auth_method 哨兵改造**+**labels 四处与计数基线**(labels.ts+AdminAuditPage EVENT_TYPES+DETAIL_KEY_LABEL+audit_labels.dart,事件同包落地,基线只改一次)+**FakeRedis eval 基建+`test_phone_verification.py`**(被测模块同包,依赖 B2 的 FakeRedis 扩建)+**两套容器级 API 测试**(test_phone_bind_api/test_phone_reset_api,覆盖四端点;本地单测分布:B1=aliyun_sms、本包=phone_verification、B5=脚本) | 依赖 B1 |
| B3 Web | types/hooks+设置「账号与安全」+忘记密码页+登录入口+路由与 401 豁免 | 依赖 B2 契约 |
| B4 App | auth_api/me 模型+account_phone_page+forgot_password_page+登录入口+widget 测试 | 依赖 B2 契约(可与 B3 并行) |
| B5 脚本与运维 | `bind_user_phones.py`+其测试+.env example+ops-manual 节+changelog | 依赖 B1+B2(脚本写 `phone_bound` 审计,事件与标签须先就位,合并不早于 B2) |

- qdev 派发约束沿用仓库惯例:worktree 基于 liuqi、子智能体不 commit、单文件 ≤500 行、只 format 自己的文件、本地 docker 禁跑。

## 12. 风险与实施钉子

1. **唯一约束渲染坑**:列定义 `unique=True` 不可靠,必须显式 `op.create_unique_constraint`(0008/0010/0009 前科;且用 constraint 而非 unique index,`test_db_schema.py` 的 contype='u' 断言才能覆盖,§4.2)。
2. **TemplateParam 必须 JSON 串**、BizId 带 `^0` 后缀、SendSms 无幂等勿重试——签名实现**逐行对照技能脚本移植**,不凭记忆。
3. **审计标签四处计数基线**必须同步更新(labels.ts + AdminAuditPage.tsx EVENT_TYPES + AdminAuditPage DETAIL_KEY_LABEL + audit_labels.dart),并按当时代码实数,勿抄本文档数字。
4. **force-recreate ms-api → poc-nginx 502** 连坐,上线步骤已内置 restart poc-nginx。
5. **prod 先 alembic 对账再 restart**(两次前科);deploy_lan 尾部回显假挂起看 DEPLOYED.md 再判。
6. 验证码必须**含字母**(模板变量约束),纯数字会被 `isv.SMS_TEMPLATE_ILLEGAL` 拒。
7. dev 验收用真实手机号,短信真实计费;阿里云/运营商同号频控(1 条/min、**5 条/h 量级**)与 2 分钟冷却兼容,但**同号一小时内第 6 次发码会吃 `isv.BUSINESS_LIMIT_CONTROL` → 502(先于自家日配额 10 触发;运营商限按签名×手机号跨场景计数,D12 场景隔离不覆盖它)**——router 层对该错误码给差异化文案「操作过于频繁,请一小时后再试」;ops-manual 错误码表收录释义。
8. bind 端点会被 `must_change_password` 403 白名单机制拦截(设计内):强制改密用户先改密;**前端不另造显隐逻辑**——Web 端 AppShell 的 mustChange 路由守卫(`App.tsx:165-166`)使 /settings 不可达,App 端登录后 mustChange 即被引去改密页,天然不可达。
9. App 单文件 500 行上限:account_phone_page 若超限拆 page+sheets(先例见 `feat/email-account-reset` 分支的 account_email_page/sheets,该分支未合入,仅作参照)。
10. `sms:ip:reset` 按内网同出口 IP 取 20/h;若 prod 出现误伤(真实办公并发),仅调 env 不动代码。
11. Web `client.ts`/`AppShell` 两处豁免名单都要加 /forgot-password,漏一处=未登录访问被 401 跳转打死。
12. 迁移链并行冲突:合入前 `alembic heads` 确认单头(0024 的 down_revision 以合入时实际 head 为准)。
13. **上线前核实 hh2 nginx 对 /api 的 X-Forwarded-For 写法**:uvicorn 以 `--proxy-headers --forwarded-allow-ips '*'` 全信任运行(`Dockerfile:33`),若 nginx 是 `$proxy_add_x_forwarded_for` 追加而非覆盖,客户端可伪造 XFF 旋转 `sms:ip:reset` 与 `auth:fail:ip` 的 IP 桶——须确认覆盖写法(或改取 rightmost-untrusted);在此之前 IP 配额按「尽力而为」理解,真实防线=同号冷却+日配额+审计。

## 13. 遗留项(不在本批)

- **session_version 会话踢出**(重置/改密后全端下线):邮箱方案曾完整设计未上,待独立周期。
- 管理后台展示/编辑手机号(**含禁用账号占号的释放通道**,§8.5)、风控页纳入 phone_reset_denied 维度。
- 手机号登录(登录名匹配链扩展)。
- MNS 回执队列送达状态落库与失败自动告警。
- RAM 子账号收敛 AK 权限(仅 dysms 两 action)。
- 国际手机号支持。
- 忘记密码结果页引导用户改密后,可考虑下次登录弱提醒(非强制)。
