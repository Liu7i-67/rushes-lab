# 方案：账号邮箱自助绑定/换绑/解绑 + 邮箱找回密码（Web + App）

- 状态：待评审
- 日期：2026-10-31
- 涉及层：api / web / app / 运维
- 目标环境：hh2 dev → hh2 prod（局域网 + 公网 `bucket.taoxiplan.com` 双入口）

## 0. 一句话

给每个账号加一条「可自证」的邮箱：登录后凭**当前密码 + 邮箱验证码**绑定/换绑/解绑；绑定并验证后，可在 Web/App 登录页走「忘记密码」→ 邮件链接 → 回站内设置新密码，重置成功即**踢掉该账号全部现有会话**。

## 1. 背景与目标

### 1.1 需求拆解（逐条对齐）

| # | 用户需求 | 本方案落点 |
| --- | --- | --- |
| R1 | 每个人可以修改自己的邮箱账号 | §5.3：`POST /auth/email/code` + `POST /auth/email/confirm`（绑定/换绑/验证三态复用） |
| R2 | 修改时需输入账号密码 + 邮箱验证码 | §5.3：第一步校验当前密码，第二步校验发往目标邮箱的 6 位验证码 |
| R3 | 绑定邮箱后可通过邮箱修改密码 | §5.4：`POST /auth/password-reset/request|verify|confirm` |
| R4 | 发送链接到邮箱，点击链接回系统改密 | §5.4 + §6.2/§7.2：链接指向 Web SPA `/reset-password#token=...`；App 点击链接走系统浏览器 |
| R5 | 改完需重新登录 | §5.5：`users.session_version` + JWT `ver`，重置成功即失效该用户全部旧 JWT |
| R6 | Web 与 App 登录页都要有「忘记密码」入口 | §6.1 / §7.1：入口显隐读公开配置端点 |
| R7 | 邮箱不存在绑定账号时提示发送失败 | §5.4：显式 400 文案（与业界「防枚举」做法相反，按需求执行并在 §8 记录风险） |
| R8 | 连续失败五次，当前 IP 触发封控，不允许继续发信 | §5.7：`pwreset:fail:ip:*` + `pwreset:lock:ip:*`，默认 5 次 → 锁 15 分钟（可配）。**失败 = 邮箱不存在 / 账号停用**；SMTP 失败与成功申请不计入/清零（「连续」语义，成功即清零） |
| R9 | 一个邮箱只能绑定一个系统账号 | §4：`lower(email)` 部分唯一索引 + 应用层预检 + 冲突 409 |
| R10 | 允许解除邮箱绑定 | §5.3：`POST /auth/email/unbind`（需密码）。**例外**：没有可用非邮箱登录方式（`username` 为空且 OIDC 未启用/无 `oidc_sub`）的账号拒绝解绑（邮箱是唯一登录标识），返回明确指引（§5.3.4） |

### 1.2 目标

1. 邮箱成为**可自证的账号恢复通道**：只有通过验证码验证过的邮箱才可用于找回密码。
2. 邮箱归属唯一、可换绑、可解绑；换绑/解绑对旧邮箱发告知邮件。
3. 找回密码全链路可用：申请 → 邮件链接 → 校验 → 设新密码 → 全部会话下线。
4. 全链路有审计、有频控、有灰度开关，SMTP 未就绪时功能整体隐藏而非半死状态。

### 1.3 非目标

- 不做自助注册、不做用户名修改（`username` 仍仅管理员可建）。
- 不做短信/OTP 认证器/双因素登录；邮箱是恢复通道，不是第二登录因子。
- 不改登录方式：用户名 / 邮箱 + 密码登录保持不变（**未验证邮箱仍可用于登录，也可用于找回密码**；验证状态只用于展示/告知，D4）。
- 不做 App 深链（`huanhuashijie://` / Universal Links）；邮件链接统一落 Web（§3 D9）。
- 不做 HTML 邮件模板；v1 用纯文本（与现有 SMTP 实现一致）。
- 不做邮件发送队列/重试；失败由用户重试。

## 2. 现状事实（代码依据）

> 行号为 2026-10-31 写作时快照；实施时以 `grep` 为准（仓库并行开发会漂移）。

### 2.1 认证与会话

- 本地登录 `POST /api/v1/auth/local/login`（`api/app/routers/auth.py:287-380`）：username（lower）→ 含 `@` 时 email（lower）→ name 兜底；任一层多命中返回 None（`api/app/services/local_auth.py:240-267`）。
- 登录失败限流：`auth:fail:ip:{ip}` / `auth:fail:user:{username}`，5 次 → `auth:lock:ip|user`，默认 900 秒（`local_auth.py:115-158`，`settings.py:86-87`）。
- 密码：argon2id；策略 ≥8 位 + 含字母 + 含数字（`local_auth.py:104-112`）。
- Session：无状态 HS256 JWT，cookie `ms_session`，TTL 7 天，`httponly`、`secure` 默认 true、`samesite=lax`；payload 仅 `sub/name/iat/exp`，**无 jti / 黑名单 / 版本号**（`api/app/services/auth.py:211-233`，`settings.py:75-81`）。
- `get_current_user`：cookie → Bearer PAT → dev `X-User-Id`；每请求一次 PK 查询取 `id/name/is_active/must_change_password/password_hash`（`api/app/deps.py:80-173`）。
- 改密 `POST /auth/change-password`（`routers/auth.py:383-456`）：校验原密码；成功后**不失效已有 session**（stateless JWT），只吊销全部 PAT。
- 管理员重置 `POST /admin/directory/users/{id}/reset-password`（`routers/directory.py:494-542`）：生成临时密码、`must_change_password=true`、吊销 PAT，同样不失效 session。

### 2.2 用户与邮箱

- `users`（`api/app/db/tables.py:59-82`）：`email String(255)` **可空、无索引、无唯一约束**；`password_hash` 可空；`must_change_password` 默认 true。
- email 写入点：管理员建号（`routers/directory.py:234` → `services/user_provisioning.py:144`）、管理员编辑（`directory.py:315`）、OIDC 登录同步（`services/auth.py:198`）、seed 脚本。
- email 校验：轻量正则 `^[^@\s]+@[^@\s]+\.[^@\s]+$`，不引依赖（`models/__init__.py:652-667`）。
- `GET /auth/me` 返回 `Me`（`routers/auth.py:129-250`）；**无** `PATCH /users/me`，无任何自助资料编辑入口。

### 2.3 邮件

- `api/app/services/notifications.py` 已有 SMTP：stdlib `smtplib` + `asyncio.to_thread`，15s 超时，无重试，异常仅 log；纯文本；模板拼字符串（47-114）。
- SMTP settings：`smtp_host=None` / `smtp_port=587` / `smtp_username` / `smtp_password` / `smtp_from_email` / `smtp_use_tls=True` / `smtp_use_ssl=False`；`smtp_enabled = host && from_email`（`settings.py:104-119`）。
- `.env.example` 的 SMTP 段全是注释；`.env.production.example` **没有 SMTP 段**；ops-manual 的生产口径是「局域网单机、可完全离线运行」；`.env` 不进 git、`deploy_lan` 不覆盖 `.env`。

### 2.4 前端

- Web：`BrowserRouter basename="/ms-static/web"`（`web/src/App.tsx:328`）；`AppShell` 未登录时只放行 `/login`、`/change-password`（`App.tsx:118,134-142`）；`client.ts` 的 401 拦截器只豁免 `/login`、`/change-password`、`/dev-login`（`client.ts:33-50`）。设置页只有 PAT（`pages/SettingsPage.tsx`）。登录页无忘记密码入口。
- App：纯 cookie 会话 + `PersistCookieJar`；冷启动按 dart-define → `192.168.110.221` → `bucket.taoxiplan.com` 探活 `/api/v1/maintenance/banner`（`app/lib/core/session.dart:24-44`）；401 全局清会话回登录（`ms_api.dart:127-135`，`session.dart:239-247`）；**完全无深链能力**（Android 无 VIEW/BROWSABLE，iOS 无 CFBundleURLTypes/Associated Domains，无 app_links）；`Me` 模型无 email 字段（`app/lib/models/me.dart`）。

### 2.5 其他硬约束

- 迁移 head = `20261031_0020`（`api/app/db/migrations/versions/2026_10_31_0020_mcp_service.py`）。
- `tests/test_db_schema.py` 用集合断言 metadata 表名（新增表必须同步）。
- 审计事件前端三处映射需同步：`web/src/pages/AdminAuditPage.tsx` 的 `EVENT_TYPES`、`web/src/lib/labels.ts` 的 `EVENT_TYPE_LABEL`、`app/lib/features/admin/audit_labels.dart`。
- prod 部署顺序：代码同步 → `alembic upgrade head` → restart → SPA；改 `.env` 后必须 `up -d --force-recreate`（`restart` 不重读 env_file）。
- 真实员工邮箱不得进日志/审计明文；`audit.py` 已有 UA 截断收口，本方案新增的日志一律脱敏。

## 3. 关键决策记录

| # | 决策 | 理由 / 代价 |
| --- | --- | --- |
| D1 | 复用 `users.email` 作为「绑定邮箱」，新增 `email_verified_at` 标记是否已验证 | 登录、管理员目录、OIDC 关联都已用这一列；新开列会造成两套邮箱口径 |
| D2 | 唯一性用 `UNIQUE INDEX ON users (lower(email)) WHERE email IS NOT NULL AND email <> ''` | 大小写不敏感、允许 NULL、允许空串归 NULL；应用层预检给友好 409，索引兜底并发；**所有写入点（用户确认、管理员建号/编辑）都要捕获 `IntegrityError` 映射 409**，不能只靠预检 |
| D3 | 存量邮箱一律视为**未验证**（`email_verified_at=NULL`），不自动回填 | 管理员录入的邮箱从未验证过；若直接当作已验证，审计/展示会失真。**未验证不再阻塞找回密码**（D4），用户登录后可自助「验证当前邮箱」；运维只能逐条核对后显式标记（D16） |
| D4 | 找回密码**不要求预先验证**；重置链接本身就是邮箱控制权证明；重置成功即标记已验证 | 原「只认已验证」会让存量用户在忘记密码时死锁：未验证 + 无法登录 → 无法自助验证、也无法找回，只能管理员重置。验证链接与重置链接发往同一邮箱、安全强度相同；管理员录错邮箱的风险靠审计/告知/管理员纠错兜底，前置验证并不能降低该风险 |
| D5 | 邮箱绑定/换绑/解绑都要求**当前密码**；换绑另加**新邮箱验证码**；解绑不要求验证码 | 需求原文；解绑要求验证码会把「邮箱已失效」的用户锁死，密码足以证明是本人在操作 |
| D6 | 新增 `users.session_version` + JWT `ver`，改密/管理员重置/邮箱重置都自增 | stateless JWT 无法撤销；版本号是业界标准做法，无需 Redis 黑名单。存量 JWT 无 `ver` 按 0 处理，迁移后不会全站掉线 |
| D7 | 忘记密码对「邮箱不存在 / 账号停用」显式报错 | 用户明确要求 R7。代价是账号枚举面（§8.1），用 IP 频控 + 审计监控兜底 |
| D8 | 重置链接 token 放 **URL fragment**（`#token=...`），DB 只存 SHA-256，30 分钟、单次 | fragment 不进 nginx access log / Referer；DB 泄露也拿不到明文 token |
| D9 | 邮件链接只落 Web，不做 App 深链 | App 当前无任何 scheme/AASA 基建；自定义 scheme 在 QQ/企业邮箱里常不可点，https 链接永远可用。App 内提供「忘记密码」入口，邮件里明确写「在浏览器中打开」 |
| D10 | 验证码/链接的邮件**同步发送**（`to_thread`，socket 15s / 总预算 20s），失败向用户报错 | 异步 BackgroundTask 无法告诉用户「没发出去」；交互式场景必须可感知。站内通知邮件保持原 best-effort |
| D11 | 邮箱功能只有一个**有效开关** `mail_ready = EMAIL_AUTH_ENABLED && smtp_enabled` | 配置不齐时前端隐藏入口、后端全部 503，避免「显示入口但每一步都失败」的半死状态；`mail_ready=false` 时把 `EMAIL_LINK_BASE_URL` 校验也跳过 |
| D12 | 邮箱重置成功后 `must_change_password=False` | 用户自己设的新密码，不应再被强制改一次 |
| D13 | 换绑/解绑成功后向**旧且已验证**的邮箱发告知邮件；**任何邮箱变更**（用户换绑/解绑、管理员编辑、OIDC 同步）与改密、**禁用账号**都作废该用户未用的重置 token 与 `email:code` | 旧邮箱是安全告警通道；作废 token 防止「旧邮箱里的链接还能用」。管理员/OIDC 改邮箱本批**不发**旧邮箱告知（只审计 + 清验证/ token），避免后台批量操作触发大量邮件 |
| D14 | 邮箱失败锁与登录失败锁**分命名空间** | 复用 `auth:lock:ip` 会让「忘记密码刷 5 次」连带锁登录，反之亦然 |
| D15 | 邮件链接基址 `EMAIL_LINK_BASE_URL` **必填（开启功能时）**，不回落到 `WEB_APP_BASE_URL` | 生产 `WEB_APP_BASE_URL` 是内网地址，回落会让邮件链接在 4G 下打不开且无任何报错。启动时校验：必填、`https://`（生产）、以 `/ms-static/web/` 结尾、非内网/环回主机；**不合法 → 记 ERROR 并令 `mail_ready=false`（功能隐藏），不拖垮登录** |
| D16 | 存量邮箱的「批量标记已验证」**不提供**，只允许逐账号显式确认 | 批量档会一次性兑现「管理员录错邮箱」的全部风险，与 D3 自相矛盾；运维手段只保留逐条 `--username/--user-id` + `--confirm-email` 二次核对 |

## 4. 数据模型与迁移 0021

### 4.1 `users` 新增列

```python
# api/app/db/tables.py — User
from sqlalchemy import Integer   # 现有 import 列表没有 Integer，漏了会 NameError
email_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
session_version: Mapped[int] = mapped_column(
    Integer, nullable=False, default=0, server_default="0"
)
```

索引（写进模型 `__table_args__`，便于 metadata 测试断言）：

```python
Index(
    "uq_users_email_lower",
    func.lower(email),
    unique=True,
    postgresql_where=text("email IS NOT NULL AND email <> ''"),
)
```

> 说明：SQLite 测试库也支持表达式/部分索引；若个别环境不支持，`test_db_schema` 只断言 metadata，不建表，不受影响。

### 4.2 新表 `password_reset_tokens`

| 列 | 类型 | 约束 |
| --- | --- | --- |
| `id` | UUID | PK, default uuid4 |
| `user_id` | UUID | FK `users.id` ON DELETE CASCADE, NOT NULL, index |
| `token_hash` | String(64) | NOT NULL, unique index（sha256 hex） |
| `expires_at` | DateTime(tz) | NOT NULL |
| `used_at` | DateTime(tz) | NULL |
| `email_hash` | String(64) | NULL（签发时 `sha256(lower(email))` 快照；改邮箱后即使并发删除漏掉，confirm 也会拒绝；不复制完整邮箱） |
| `request_ip` | String(64) | NULL |
| `user_agent` | String(512) | NULL（写库前截断 `[:512]`） |
| `created_at` | DateTime(tz) | NOT NULL, server_default now() |

> 只存哈希；明文 token 只出现在邮件正文里，不落库、不写日志。
> **正常路径**同一用户只保留最新一条有效 token：冷却键用 `SET NX EX 60` 在签发前原子占位（同一用户 60s 内只能有一次申请），插入后发送成功只删更旧的未用行。**例外**：SMTP 结果未知时保留「本次新行 + 最近一条旧行」，删除更早的未用行（仍 ≤2 条，各自单次、30 分钟过期，后续成功申请会收敛）。`email_hash` 快照兜住并发改邮箱的窗口。SQLite 单测按方言跳过 advisory lock（测试串行执行）。
> `request_ip` / `user_agent` 在申请时写入，便于风控排查（脱敏展示）。
> **清理**：每次签发前顺带删除该用户 `used_at IS NOT NULL OR expires_at < now() - interval '30 days'` 的旧行（**不动未用且未过期的有效行**）；`expires_at` 建索引；ops-manual 提供一条按月清理全表的 SQL（§9.5），避免表与索引长期膨胀。

### 4.3 迁移步骤（`2026_10_31_0021_email_account_reset.py`）

```python
revision = "20261031_0021"
down_revision = "20261031_0020"
```

1. `UPDATE users SET email = lower(btrim(email, E' \t\n\r\f\v')) WHERE email IS NOT NULL;`
2. `UPDATE users SET email = NULL WHERE email = '';`
   > 归一化是**单向**的：downgrade 不会恢复原大小写/首尾空白。需要原始值对账的，迁移前先 `backup_prod.sh` 或单独导出 `id,email` 留档。
3. **重复/冲突检测**（全部用 `text()`，不 import User 模型）：
   - 重复邮箱：`SELECT lower(email), array_agg(id::text) FROM users WHERE email IS NOT NULL GROUP BY 1 HAVING count(*) > 1`；
   - 跨列冲突：`SELECT a.id, b.id FROM users a JOIN users b ON lower(btrim(a.username, E' \t\n\r\f\v'))=lower(btrim(b.email, E' \t\n\r\f\v')) AND a.id<>b.id`（btrim 口径与 §4.4 预检 #2 一致；否则重置成功却登不进去）。
   - 有输出 → `raise RuntimeError("duplicate/conflicting emails, resolve before migration: <用户 id 列表>")`（只打印用户 id，不打印邮箱）。
4. `ADD COLUMN email_verified_at TIMESTAMPTZ NULL`（不回填）。
5. `ADD COLUMN session_version INTEGER NOT NULL DEFAULT 0`。
6. 建 `uq_users_email_lower` 部分唯一索引。
7. 建 `password_reset_tokens` 表 + 索引。
   > `users` 表很小（百级），普通 `CREATE UNIQUE INDEX` 的 SHARE 锁是毫秒级，迁移按单事务执行即可；若未来用户量上万，照 0020 的 `autocommit_block()` + `CREATE INDEX CONCURRENTLY` 写法，并处理失败留下的 INVALID 索引。
8. downgrade：删表、删索引、删两列。

### 4.4 迁移前置检查（不依赖新代码）

**必须用纯 SQL 预检，不能用会 import `app.db.tables` 的脚本** —— 代码同步后容器内已是新代码，任何 `select(User)` 都会 SELECT 新列而撞旧 schema（ops-manual 记录的 0020 同款失败面）。

部署 runbook 的预检命令（在宿主上直接打 PG，代码同步**之前/之后**都能跑）：

```bash
# 1) 重复邮箱（只输出计数与用户 id，不把完整邮箱打到终端）
docker exec ms-db psql -U msuser -d material_storage -c "
SELECT count(*) AS n, string_agg(id::text, ',') AS user_ids
FROM users WHERE email IS NOT NULL AND btrim(email, E' \t\n\r\f\v') <> ''
GROUP BY lower(btrim(email, E' \t\n\r\f\v')) HAVING count(*) > 1;"

# 2) 跨列冲突:某人的 username 等于另一人的 email（btrim 与迁移口径一致）
docker exec ms-db psql -U msuser -d material_storage -c "
SELECT a.id AS username_user_id, b.id AS email_user_id
FROM users a JOIN users b
  ON lower(btrim(a.username, E' \t\n\r\f\v')) = lower(btrim(b.email, E' \t\n\r\f\v')) AND a.id <> b.id;"
```

- 有输出 → 先由管理员清空其一（`PATCH /admin/directory/users/{id}` 传 `email=null`），再迁移。
  - **优先清空有 `username` 的账号**；`username IS NULL` 的账号邮箱是唯一登录标识，直接清空会让它永久无法登录 —— **迁移前**用纯 SQL 补登录名（`UPDATE users SET username=... WHERE id=...`，先查唯一/格式）；**迁移后**才用 `set_password.py --username <新名> --username-only`。已停用/离职账号可直接清（§5.3.5 的守卫只拦在职）。不要用脚本「顺手清」。
- 跨列冲突：人工决定改哪一边。**迁移前**改 username 用纯 SQL（旧 schema 安全，不 import 新模型）：
  ```sql
  UPDATE users SET username = '<新名>' WHERE id = '<user_id>';
  ```
  执行前先查 `lower(username)` 唯一性与格式（禁 `@`）；改 email 走管理员 PATCH。**不要**在迁移前用本批新脚本（新 ORM 会 SELECT 新列）。部署后日常维护才用 `set_password.py --username-only`。不要自动清。
- 同时统计：非空邮箱数、空串数、大写数、疑似格式非法数。
- `api/scripts/check_email_duplicates.py` 作为**代码同步后、`alembic upgrade` 前**的便利脚本：实现必须用 `sqlalchemy.text()` 显式列查询、不 import ORM 模型（否则 SELECT 新列撞旧 schema）；输出脱敏值 + 用户 id，不输出完整邮箱。也可以只用上面的 psql，不跑脚本。

## 5. 后端设计

### 5.1 模块划分

| 新文件 | 职责 |
| --- | --- |
| `api/app/services/mailer.py` | 统一 SMTP 发送：`send_mail(settings, *, to, subject, body, timeout)`（keyword-only，§5.6.1）；`MailSendError(definite)`；脱敏日志；`Address` 构造防头注入 |
| `api/app/services/email_verification.py` | 验证码生成/校验（Redis）、密码校验失败锁、邮箱规范化/占用检查、绑定/换绑/解绑的业务逻辑 |
| `api/app/services/password_reset.py` | 重置 token 签发/校验/原子消费、重置密码、会话版本自增、PAT 吊销 |
| `api/app/routers/account_security.py` | 7 个新端点（含 `public-config`），挂 `/api/v1/auth` 前缀（`main.py` 增加 `app.include_router(account_security.router, prefix="/api/v1/auth", tags=["auth"])`） |
| `api/app/services/email_utils.py` | `normalize_email` / `strict_validate_email` / `strict_normalize_email`（strip+lower+严格校验，Pydantic 用）/ `email_fingerprint`（**唯一哈希口径**：`(value or "").strip().lower()`）/ `mask_email` / `is_email_format_ok` |
| `api/app/services/rate_limit.py` | 通用 Redis 计数：Lua 原子 `INCR + 首次 EXPIRE`（照 `services/mcp_limiter.py:37-52` 的 Lua 形态），返回计数与 TTL；供验证码/重置/IP 锁共用 |

- `email_verification.py` / `password_reset.py` / `mailer.py` 都是**无状态模块函数**（与 `notifications.py` 同风格），`db` / `redis` / `settings` 由 router 从 `get_db` / `request.app.state.redis` / `get_settings()` 注入；不新建 app.state 单例，也不在模块顶层建 client（符合 CLAUDE.md「服务实例走 app.state」的实质：外部 client 只从 state 取）。
- `notifications._maybe_send_email` 改为调用 `send_mail`，行为保持 best-effort；**但站内通知邮件必须走独立开关 `NOTIFY_EMAIL_ENABLED`（默认 false）**——现有 `create_notification` 只看 `smtp_enabled`，一旦为邮箱功能填了 SMTP，审批/邀请通知邮件会立刻开始发给管理员手填的（可能未验证/录错的）地址，这是本批引入的新数据暴露面。`create_notification` 改为 `if not (settings.notify_email_enabled and settings.smtp_enabled): return`；`mail_ready` 不受它影响。开启通知邮件前由产品确认，建议只发给 `email_verified_at` 非空的用户。顺带把失败日志里的完整收件人改成脱敏值（现在 `notifications.py:88` 打了完整邮箱）。

### 5.2 公开配置端点

`GET /api/v1/auth/public-config`（无需鉴权，不泄露秘密）：

```json
{
  "email_auth_enabled": true,
  "password_reset_enabled": true,
  "password_min_length": 8
}
```

`password_min_length` 返回 `settings.auth_password_min_length`（既有可配置项，默认 8），不要新造配置。

- 先定义**有效开关** `mail_ready = settings.email_auth_enabled and settings.smtp_enabled`，并在 **lifespan 计算一次挂到 `app.state.mail_ready`**（配置不合法时降级为 false）；端点通过 `request.app.state.mail_ready` 读取。**不要**每次请求重算（非法配置会每请求刷 ERROR），也**不要**往 `Settings` 上挂临时属性（pydantic v2 会拒绝未声明字段）。
- `email_auth_enabled = mail_ready`（前端据此显隐「设置 → 账号安全」邮箱区）。
- `password_reset_enabled = mail_ready`（前端据此显隐登录页「忘记密码」）。
- 所有**会发信**的端点（`/email/code`、`/email/confirm`、`/password-reset/request|verify|confirm`）用 `mail_ready`；**`/email/unbind` 例外**：只做密码校验 + DB，SMTP 关闭时仍可用（告知邮件 best-effort 跳过）。
- 该端点不写审计（高频轮询）。

### 5.3 邮箱验证码：绑定 / 换绑 / 验证当前邮箱 / 解绑

#### 5.3.1 状态机

```
[未绑定] --绑定(密码+新邮箱验证码)--> [已验证]
[未验证] --验证当前邮箱(密码+验证码)--> [已验证]
[未验证] --换绑(密码+新邮箱验证码)--> [已验证(新邮箱)]（旧邮箱未验证，不发告知）
[已验证] --换绑(密码+新邮箱验证码)--> [已验证(新邮箱)] + 旧邮箱告知
[未绑定/未验证/已验证] --解绑(密码)--> [未绑定]
```

#### 5.3.2 `POST /api/v1/auth/email/code`（session-only）

入参：

```json
{ "email": "New.Address@Example.com", "password": "当前密码" }
```

处理顺序（**顺序即安全**）：

1. `require_session_auth`（PAT 一律 403，与改密同口径）。**强制改密期间（`must_change_password=true`）这些端点会被 `deps.py:77` 的 403 拦下**（白名单只有 me/change_password/logout），这是预期行为：用户必须先改密才能进设置页；不要把邮箱端点加进白名单。
2. 有效开关 `mail_ready`（D11）否则 503「邮箱功能未启用」。
3. 密码失败锁检查（`email:chg:lock:user:{id}`）→ 429。
4. 校验当前密码：
   - `password_hash is None` → 400「该账号尚未设置本地密码，请先联系管理员初始化」。
   - 错误 → INCR `email:chg:fail:user:{id}`（首次才 EXPIRE 900s），≥5 写锁 900s；审计 `email_verification_requested`（`ok=false, reason=wrong_password`）；返回 400「账号密码不正确」。
   - 正确 → DEL 失败计数；**随后才 `incr_with_ttl` 每用户 code 请求预算**（`email:code:req:user:{id}:{epoch_hour}`，>30 → 429）——预算必须放在密码校验通过**之后**（连续输错密码不能烧预算，否则用户改对密码也 429，自锁 1 小时）。
5. 规范化邮箱：`strip().lower()`，长度 ≤254；**统一走 `strict_validate_email`（Pydantic `field_validator`，422）**——它实际在**请求解析期**执行（先于本流程第 1 步），格式错 422 的请求根本进不了处理流程，**不消耗第 4 步的请求预算**（409 占用尝试计数是有意的，422 不计）。不做「宽松地址验证」兼容分支——过不了严格正则的存量地址本身大概率无法收信，应通过「更换邮箱」改成合法地址（§13.12）。
6. 判定 `purpose`：
   - 当前邮箱为空 → `bind`
   - 目标 == 当前邮箱 → `verify`（若 `email_verified_at` 非空 → 400「该邮箱已验证，无需重复验证」）
   - 目标 != 当前邮箱 → `change`
7. `purpose in ("bind","change")` 时查占用（`purpose=verify` 不查：目标就是本人当前值，存量冲突应由 §4.4 预检清理，而不是在验证时拒绝）：
   - `SELECT 1 FROM users WHERE lower(email)=:e AND id<>:me` → 409「该邮箱已被其他账号使用；如该邮箱属于你，请联系管理员解除其它账号的占用」。
   - **跨列冲突**：`SELECT 1 FROM users WHERE lower(username)=:e AND id<>:me` → 409「该邮箱与某个登录名冲突，请联系管理员处理」。登录匹配是 username 优先（`local_auth.py:250-258`），不拦会让「用邮箱登录」命中别人的 username；排除本人是为了兼容「username 本身是邮箱」的历史账号。
   - 两个 409 分支都写审计 `email_verification_requested`（`ok=false, reason=email_taken|username_taken, purpose, email_masked`），让安全人员能看到登录用户的占用枚举（受每用户 30/h 预算约束）。
8. IP 验证码配额：读 `email:code:ip:{ip}:{epoch_hour}`，≥200 → 429「操作过于频繁，请稍后再试」；**发送成功后**才 INCR（首次 EXPIRE 3600s）。先读后加允许极小并发超限，可接受。200/h 是按「同 NAT 全公司首日集中验证」留的余量（每用户还有 10/天 + 30/h 请求预算）。
9. 日配额：读 `email:code:quota:{id}:{yyyymmdd}`，≥10 → 429「今日验证码发送次数已达上限」；**发送成功后**才 INCR（首次 EXPIRE 到当日 24:00）。**先查日配额再占冷却**：否则第 11 次会先占 60s 冷却、再报日配额，用户看到的倒计时语义混乱。
10. 冷却（**原子占位，只此一次**）：`SET email:code:cooldown:{id} 1 NX EX 60`；返回 false → 429「发送过于频繁，请 N 秒后再试」。占位成功即视为本次请求的发送窗口，避免双击并发各自发一封。**冷却从占位时刻起算 60s，第 13 步所有分支（成功/失败/未知）都不再触碰冷却键、不续期**——续期会让「冷却窗口」随发送时长漂移，语义不统一。
11. 生成 6 位数字码（`secrets.randbelow(1_000_000):06d`）与 `code_hash`；**先不写 Redis**（见第 13 步）。`current_email_hash = sha256(email_fingerprint(user.email))`，确认时用它兜住「发码后管理员改了邮箱/解绑」的窗口。
12. **发信前结束 DB 事务**：`/email/code` 前面只做了读，`get_db` 的 session 会一直持有连接；在校验完密码/占用后 `await db.commit()`（或改用短 session 读完即关），再进入 20s 的 SMTP 发送。否则每个在途请求都把一条连接占满 20s，30+ 个并发就能耗尽连接池（`pool_size=10 + max_overflow=20`）。
13. 同步发送邮件（§5.6）：
    - 成功 → **用单条 Lua 写 `email:code:{id}`**：`{code_hash, email, purpose, current_email_hash, attempts:0}` + `EXPIRE 600s`；INCR 第 8/9 步配额（第 10 步冷却已在占位时定档，此处不动）。**若 Redis 写失败**（邮件已发出）：log.error + 审计 `email_verification_requested`（`ok=false, reason=store_failed`），返回 503「邮件已发送但系统繁忙，请稍后重新获取」——不要返回 200 让用户拿一个服务端无法验证的码。
    - **结果未知**（wait_for 超时）→ **同样写入哈希**（邮件可能已送达，验证码必须可用）；审计 `email_verification_requested`（`ok:false, reason:"smtp_timeout"`）；返回 502「发送结果未知，请稍后检查邮箱；若未收到可重新获取」；不消耗配额。
    - **确定失败**（未发出）→ **不写 Redis**（若有旧码，旧码继续有效，不会被这次失败覆盖掉）；审计 `email_verification_requested`（`details={"ok":false,"purpose","email_masked","reason":"smtp_failed"}`）、返回 502「验证码发送失败，请稍后重试」；不消耗配额。
    > 不能「先覆盖旧码再发信」：发信失败会把用户手里原本可用的旧验证码一并作废（重置 token 那边已经避免了这个坑）。
14. 审计 `email_verification_requested`（`details={"ok":true,"purpose","email_masked"}`；不含验证码）。
15. 返回 `{status:"sent", masked_email:"n***@example.com", expires_in:600}`。

> 发信成功后（或结果未知）才写 Redis；确定失败不写、旧码保留。用 hash 而不是三个 key，便于一次性取/删；attempts 用 `HINCRBY`。

#### 5.3.3 `POST /api/v1/auth/email/confirm`（session-only）

入参 `{ "code": "123456" }`。

1. 有效开关 `mail_ready` 检查。
2. 读 `email:code:{id}`；不存在 → 400「请先获取验证码」。
3. `attempts >= 5` → 删 key + 400「验证码错误次数过多，请重新获取」。
4. `hmac_sha256(settings.session_jwt_secret, f"{user_id}:{code}")` 与 `code_hash` 用 `hmac.compare_digest` 比较；**先检查 `code_hash` 字段存在**（Lua 自增若在 key 过期后造出只含 attempts 的 hash，缺字段按「请先获取验证码」400，而不是「验证码错误」）；不等 → `HINCRBY attempts 1` + 400「验证码错误或已失效」；达到 5 次立即删 key。**`HINCRBY` 与 `EXPIRE` 用 Lua 原子执行**：若 key 在读取与自增之间恰好过期，裸 `HINCRBY` 会造出一个只含 `attempts` 的永久 hash。Lua 里 key 不存在时返回「missing」（按「请先获取验证码」400，不要再造 key）；**`EXPIRE 600` 仅在 `TTL < 0` 时补**（与 `rate_limit.incr_with_ttl` 同型）——错误尝试**不续期**，否则有效期会从「签发起 10 分钟」漂成「最后一次错误起 10 分钟」，与 §5.7.1 键表和 §5.6.2 邮件文案的 `{ttl//60}` 口径冲突。用密钥 HMAC（而不是裸 SHA-256），Redis 泄露时 6 位码不能离线穷举；**建议用 HKDF 从 `session_jwt_secret` 派生 `info="email-code"` 的专用 key**（可选，不是阻塞项）。
5. 取出 Redis 里的 `email`/`purpose`/`current_email_hash`：
   - `current_email_hash != sha256(email_fingerprint(user.email))` → 删 key + 400「邮箱已变更，请重新获取验证码」（兜住「发码后管理员改邮箱/解绑」的窗口）。
   - **仅 `purpose in ("bind","change")`** 再次查占用（并发窗口，排除本人 `id<>:me`）：邮箱被他人占用，或与某个 `lower(username)` 冲突 → 删 key + 409，**并写审计 `email_verification_requested`（`ok=false, reason=email_taken|username_taken, purpose`，与 §5.3.2 第 7 步同口径）**——这是唯一能观测「并发抢占」的窗口，不写就只能靠 DB 反推。`purpose=verify` 不查（见 5.3.2 第 7 步）。
6. 写库（单事务）。**先保存 `old_email = user.email` / `old_verified = email_verified_at is not None` 快照**（第 8/9 步的告知与审计要用；不能先赋值再读）：
   - `user.email = target`
   - `user.email_verified_at = now()`
   - **仅 `purpose in ("bind","change")` 且邮箱值确实变化时**（变化判定与第 8 步同口径：`(old_email or '').strip().lower() != target`；大小写-only 归一化不算变化，`email_hash` 也不变，无需作废用户手里的重置链接），作废该用户全部**未用**重置 token（`DELETE FROM password_reset_tokens WHERE user_id=:id AND used_at IS NULL`）；`purpose=verify` 不改邮箱，保留用户手里已有的重置链接。
   - commit
   - **`try/except IntegrityError`**：并发场景下「预检查通过、写库时被另一账号抢先」会命中唯一索引；`await db.rollback()`、删 Redis key、写审计 `email_verification_requested`（`ok=false, reason=email_taken`）、返回 409。不能让它冒成 500。
7. 删除 Redis key。
8. 若 **`purpose == "change"`** 且用户原来有**已验证**旧邮箱且 `(old_email or '').strip().lower() != target.lower()`：把告知邮件注册为 `BackgroundTasks`（`mailer.send_mail`），失败只 log，不影响已成功的响应。`verify` 不改邮箱值，不发告知；大小写-only 的归一化不发告知。
9. 审计：
   - `purpose=verify` → `email_verified`（`details={"action":"verify","email_masked"}`）
   - `purpose=bind` → `email_verified`（`details={"action":"bind","email_masked"}`）
   - `purpose=change` → `email_changed`（`details={"old_masked","new_masked"}`）
10. 返回 `{status:"ok", email, email_verified:true, action:"bind|change|verify"}`。

> `session_version` **不变**：邮箱变更不需要踢会话（用户仍在本人会话内，且知道密码）。

#### 5.3.4 `POST /api/v1/auth/email/unbind`（session-only）

入参 `{ "password": "..." }`。

1. **不依赖 `mail_ready`**：解绑只需密码 + DB，SMTP 关闭时仍可用；告知邮件 best-effort（SMTP 关闭则跳过）。前端在有邮箱时即使邮箱功能关闭也显示「解除绑定」入口（§6.4/§7.3）。
2. 密码失败锁 / 校验（同 5.3.2 第 3-4 步，共用 `email:chg:fail:user` 计数）。
3. `user.email is None` → 400「当前未绑定邮箱」。
4. **没有当前可用的非邮箱登录方式 → 400**「当前账号没有独立登录名，解除邮箱后将无法登录；请联系管理员先设置登录名」。判定统一用 `has_non_email_login(user, oidc_enabled: bool)`：`username` 非空（空串与 NULL 同等对待），**或** `oidc_enabled` 且 `user.oidc_sub` 非空。`oidc_enabled` **由 router 注入 `request.app.state.auth`（OIDCService 实例）的 `.enabled` 属性**（它读构造时缓存的 `settings.oidc_provider` 四字段，`services/auth.py`）；不要在函数内从 settings 重算一份（会出现第三份 OIDC 判定逻辑）。**注意 `oidc_sub` 非空 ≠ 能登录**：生产当前是纯本地登录，存量飞书用户即使有 `oidc_sub` 也不能走 IdP；只看 `oidc_sub` 会把这些账号的邮箱解绑掉、锁死账号。姓名兜底不可靠（同名多命中会被拒绝登录，`local_auth.py:264-267`）。本批不开放管理员改 username，故直接拒绝（§13.9）。
5. **先保存 `old_email`（用于告知与审计快照）**，再清空 `email`、`email_verified_at`；作废该用户全部**未用**重置 token（`used_at IS NULL`）；**`DEL email:code:{id}`**（残留验证码不能把邮箱重新绑上）；commit。
6. 告知邮件（仅旧邮箱已验证时）：注册为 `BackgroundTasks`，best-effort。
7. 审计 `email_unbound`（`details={"old_masked"}`）。
8. 返回 `{status:"ok"}`。

#### 5.3.5 邮箱规范化与校验

- 用户侧邮箱（含「验证当前邮箱」的目标）：统一走 `strict_validate_email`：
  - 长度 ≤ 254；`strip()` 后非空；`lower()` 落库。
  - 正则：`^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$`（比现有宽松规则更严，禁止 `<`, `>`, `,`, `;`, 引号、空白，杜绝邮件头注入）。
  - 过不了严格正则的存量地址不允许自助验证/找回，用户需先「更换邮箱」；见 §13.12。
- **统一入口 `normalize_email(value) -> str | None`**（strip + lower + 空串→None）：OIDC 新建/同步、`set_initial_admin --email`、seed、管理员建号/编辑全部走它，避免 `''` / 空白写进 `users.email`（SQLite 唯一索引会把 `''` 当重复）。
- 管理员侧（建号/编辑）：**新增/变更的 email 值也走 `strict_validate_email`**（避免管理员继续制造「用户永远无法自助验证」的地址）；只读/未变更的存量值不回溯校验。**严格校验、`email_verified_at` 清理、删未用 token、`DEL email:code`、`username` 守卫全部放在既有 `if "email" in payload.model_fields_set and payload.email != target.email:` 块内（`directory.py:314`）**；**不要**写成只判断 `payload.email != target.email`（`PATCH {}` 时缺省 None 会恒真，把邮箱清空），也不要放进 `UserUpdateIn` 的 field_validator——Pydantic v2 的 field_validator 对**提供了 email 键**的请求在路由前无条件执行：管理页若把未变更的存量非法邮箱原样回显提交，会被严格校验 422（只改姓名/组、不带 email 键的请求不受影响，风险在「键存在」而非「任何 PATCH」）。`UserCreateIn`（无存量值）可以严格。前端 `AdminUsersPage` 未改邮箱时不要发送该键。写入前 `strip().lower()`；**任何 email 值变化都 `email_verified_at=NULL` + 删除该用户未用重置 token + `DEL email:code:{user_id}`**（防止发码后管理员改邮箱、用户又用旧码改回去）；**清空 email 且 `is_active=true` 且 `not has_non_email_login(target, oidc_enabled)` → 400（在职账号没有任何可用登录标识；`oidc_enabled` 同样取 `request.app.state.auth.enabled`）**；停用/离职账号允许清空（回收邮箱给新员工的常规场景）。先预检占用（含与 `lower(username)` 的跨列冲突，排除本人），写库再捕获唯一索引 `IntegrityError` → 409（`provision_local_user` 与 `update_directory_user` 两处都要做，并 `rollback`）。
- OIDC 登录（`services/auth.py:158-198`）：
  - **新建用户分支**（`:170-185`）与同步分支（`:196-198`）都先 `strip().lower()`；
  - **新建/同步前查占用**：`lower(email)` 已属他人 **和** `lower(username)` 跨列冲突都要查；冲突时跳过写入（新建走 `email=None`，已有用户保留旧邮箱），不 500；
  - 任何 email 值变化都 `email_verified_at=NULL` + 删除未用重置 token + `DEL email:code`，并写 `email_changed`（`details` 加 `source=oidc`）；D4/D13：IdP 改邮箱不能让新地址自动成为恢复通道；
  - **接线落点**：`routers/auth.py` 的 `callback` 增加 `request: Request`；`upsert_user_from_userinfo` 在 email 变化时返回 `(user, email_changed: bool, old_email)`；DB 清理（verified_at/未用 token）在 service 内完成，`DEL email:code` 与 `email_changed` 审计在 callback 里做（那里有 `request.app.state.redis` 与 `AuditService`），并 `try/except` best-effort。`tests/test_oidc_service.py` 的 FakeSession 需补 `rollback`（service 捕获 `IntegrityError` 时用）。
  - **OIDC 告警日志里的完整邮箱改 `mask_email`**：`services/auth.py:139`（email 命中多账号）与 `:164-167`（email 被 oidc_sub 占用）两处都打完整邮箱；用 `grep -rn "log\..*email" app/services/auth.py` 收口。否则 §10.4 的「日志无完整邮箱」验收不成立。
  - 是否把可信 IdP 邮箱直接标记已验证，留到 §13.6。
- seed 脚本（`dev_bootstrap` / `seed_demo_data` / **`seed_onboarding_project.py:128`（绕过 ORM 的 `insert(User).values(email=...)`）**）写入前同样 `lower()`；**seed 也必须捕获唯一索引 `IntegrityError` 并给可读错误（或冲突时跳过 email 写入）**——否则 dev 库残留数据会让脚本在唯一索引上直接崩。`dev_bootstrap` **仅在 `settings.env == "dev"` 时**给种子账号置 `email_verified_at`（`dev_bootstrap.py:59` 已有 settings，可直接判 env）——ops-manual 的生产 bootstrap 也会执行该脚本，不能无条件置已验证。prod 种子保持未验证。**已有 dev 库的 `on_conflict_do_nothing` 不会补验证**：dev 分支改用 `on_conflict_do_update` 设置 `email_verified_at`，否则本地验收会假红。**`seed_demo_data` 的 `on_conflict_do_update(set_={"email": ...})` 重跑会改邮箱**：只在 `lower(email)` 实际变化时清 `email_verified_at` 并删未用重置 token / `DEL email:code`（值没变不要清，否则与 dev 验证互相打架）。
- **`scripts/set_password.py --username`**：增加与 `UserCreateIn.username` 相同的格式校验（禁 `@`、长度上限）与跨列占用检查；**新增 `--username-only`**：只改登录名，不写 `password_hash`、不清 `must_change_password`、不吊销 PAT、不自增 `session_version`。存量冲突/解绑前置必须用 `--username-only` —— 现有 `set_password.py:95-106` 的 `--username` 会无条件重置密码并踢会话，不能拿它当「只改登录名」用。`set_initial_admin.py --username` 的格式校验只作用于新建/新设值，不能拦「按旧 `@` 登录名查找」。
- **`scripts/set_initial_admin.py`**（`--email` / `--username`）：初始化管理员的必经入口；`--email` 同样 `strip().lower()`、查 email 与跨列占用、捕获 `IntegrityError` 给可读错误；`--username` 与 `UserCreateIn.username` 同口径（禁 `@`）。
- `DirectoryUserOut` 增加 `email_verified: bool = False`（= `bool(user.email and user.email_verified_at)`；**给默认值**，漏构造点只显示「未验证」而不是 Pydantic 500），管理员用户列表/详情显示「未验证」Tag；否则支持工单只能靠 CLI 查。Web `AdminUsersPage` 同步。`Me.email_verified` 同口径（`bool(email and verified_at)`），避免「邮箱已清空但 verified_at 残留」显示成已验证。
  - **四处构造点都要补**：`routers/directory.py:178`（列表）、`:240`（`UserCreateOut`）、`:269`（`DirectoryUserDetailOut`）、`:357`（编辑返回）。默认值 `False` 只防「漏改时 500」，不能当漏改的借口；测试要四个端点逐一断言真值。Web `api/types.ts` 的 `DirectoryUser` 建议标可选（灰度期旧后端不返回）。
- `mask_email("alice@example.com")` → `"a***@example.com"`；审计/日志统一用它。**返回值截断到 255**（`actor_email_snapshot` 列宽），或只保留「首字符 + 域名」并限长——254 字符的合法邮箱加 `***` 会溢出 `String(255)`。

### 5.4 忘记密码：申请 → 验证 → 重置

#### 5.4.1 流程

```
登录页「忘记密码」→ 输入邮箱
  → POST /auth/password-reset/request {email}
      ├ 400 邮箱未绑定 / 账号停用（计入 IP 失败）
      ├ 429 IP 封控 / 冷却 / 配额
      ├ 502 邮件发送失败
      └ 200 已发送
  → 邮件里的链接：https://<公网入口>/ms-static/web/reset-password#token=<43字符>
  → 打开 SPA → POST /auth/password-reset/verify {token} → 显示脱敏邮箱
  → 输入新密码 + 确认 → POST /auth/password-reset/confirm {token,new_password}
      ├ 400 token 无效/过期/已用/密码策略/与原密码相同
      └ 200 成功 → 全部会话失效 → 回登录页
```

#### 5.4.2 `POST /api/v1/auth/password-reset/request`（公开）

入参 `{ "email": "..." }`。

1. 有效开关 `mail_ready` 否则 503。
2. 严格校验/规范化邮箱（格式错 422，不参与任何计数）。
3. IP 封控：`pwreset:lock:ip:{ip}` 存在 → 429「尝试次数过多，请 N 分钟后再试」。
4. **请求预算**（防「不存在邮箱」探测与审计刷屏）：用 `incr_with_ttl(pwreset:req:ip:{ip}:{epoch_hour}, 3600)` **原子自增后检查**（不是先读后写，避免并发超限）；返回计数 >120 → 429「操作过于频繁，请稍后再试」（超预算不写审计）。单 IP 每小时最多 120 次探测/写 120 条审计；120/h 是为共享 NAT 留的余量，真正的封控是 5 次失败锁。
5. 查询用户：`lower(email)=:e`，**取 `id/email/is_active/password_hash`**（`email` 必须取——第 11 步要算 `email_hash`，漏选会 500/空哈希；不要用 `select(User)` 全列）。
6. 判定「不可用」（只有两类计入 R8 的 IP 失败）：
   - **不存在 / `is_active=false`** → 记 IP 失败（Lua 原子 INCR + 首次 EXPIRE = `PASSWORD_RESET_LOCK_SECONDS`；≥5 写 `pwreset:lock:ip:{ip}`）；审计 `password_reset_failed`（`reason=not_found|inactive`）；**若本次触发锁，再写一条 `password_reset_failed`（`reason=ip_locked`，`details={ip, lock_seconds}`）**，让审计页能定位封控（对齐 `local_login_locked` 补盲区的做法，不新增事件类型）；400「该邮箱未绑定任何账号」。停用与不存在同文案，不暴露账号状态。
   - **未验证邮箱照常发送重置链接**：链接发到该邮箱，点击即证明控制权；重置成功后置 `email_verified_at=now()`（D4）。「未验证」不是失败，不计 IP 失败、也不返回错误。
7. IP 发信配额：读 `pwreset:send:ip:{ip}:{epoch_hour}`，≥60 → 审计 `password_reset_failed`（`reason=send_quota_ip`）+ 429「操作过于频繁，请稍后再试」；**发送成功后**才 INCR（首次 EXPIRE 3600s）。
8. 用户配额：读 `pwreset:send:user:{id}:{epoch_hour}`，≥5 → 审计 `password_reset_failed`（`reason=send_quota_user`）+ 429「该账号重置邮件发送过于频繁（每小时 5 次），请稍后再试」；**发送成功后**才 INCR（首次 EXPIRE 3600s）。
9. 冷却（**原子占位，必须在签发之前，只此一次**）：`SET pwreset:cooldown:user:{id} 1 NX EX 60`；返回 false → 429「发送过于频繁，请 N 秒后再试」。占位成功后即使 SMTP 失败也保留 60s 冷却（防连击），因此同一用户 60s 内不可能有第二个 token 插入——这是消除「并发申请互相删光」竞态的关键。**冷却从占位时刻起算，第 13 步所有分支不再触碰冷却键、不续期。**
10. 生成 token：`secrets.token_urlsafe(32)`（43 字符）；`token_hash=sha256(token)`。
11. 事务级 advisory lock（`pg_advisory_xact_lock(hashtext('pwreset:user:<uid>'))`，与 `tokens.py` 同款）→ 插入新行（`expires_at=now+1800s`，写 `email_hash=sha256(email_fingerprint(user.email))` / `request_ip` / `user_agent[:512]`）→ commit。**先不删旧行**（见第 13 步）。
12. 构造链接：`base = settings.email_link_base_url`（D15，**必填、不回落到 `web_app_base_url`**）；`f"{base.rstrip('/')}/reset-password#token={token}"`。
13. 同步发信（§5.6）：
    - 成功 → **删除该用户其它未用 token（保留本次新行）**（冷却 `SET NX` 已保证 60s 内无并发插入，直接用 `id<>:new_id AND used_at IS NULL`，不要依赖进程时钟比较 `created_at`）；DEL `pwreset:fail:ip`（成功即清零失败链）；INCR 第 7/8 步配额（冷却已在第 9 步占位时定档，此处不动）；审计 `password_reset_requested`（`details={"ok":true,"user_id":str(user.id),"email_masked":...}`）；返回 200 `{status:"sent"}`。**删除旧行失败只 log + metric，不改 200**（新 token 已可用，旧行 30 分钟自然过期）。
    - **确定失败**（连接/认证失败，未发出）→ 只删除**本次新行**（旧行保留，用户之前的链接仍可用）；审计 `password_reset_requested`（`details={"ok":false,"user_id":...,"email_masked":...,"reason":"smtp_failed"}`）；502「邮件发送失败，请稍后重试」。
    - **结果未知**（`asyncio.wait_for` 超时，线程可能已发出）→ **保留本次新行 + 最近一条旧行**（按 `ORDER BY created_at DESC, id DESC` 取，同微秒用 id 兜底），删除更早的未用行（仍 ≤2 条；新链接可能已送达，旧链接也还可用）；审计 `details={"ok":false,"user_id":...,"email_masked":...,"reason":"smtp_timeout"}`；502「邮件发送结果未知，请稍后检查邮箱；若未收到可重新申请」。
14. 响应**不返回 token**，也不返回剩余次数；429 响应带 `Retry-After` 头（§5.7.4）。

> 注意：**不把 5 次失败锁做成全局**，只锁该 IP 的 `password-reset/request`；不影响登录、也不影响已登录用户的邮箱绑定。

#### 5.4.3 `POST /api/v1/auth/password-reset/verify`（公开）

入参 `{ "token": "..." }`；返回 `{valid:true, email_masked:"a***@example.com", expires_at:"..."}` 或 400「链接已失效，请重新申请」。

- 有效开关 `mail_ready` 否则 503（关闭后存量链接也一并失效，回滚彻底）。
- 查 `sha256(token)`；不存在 / `used_at` 非空 / `expires_at <= now()` / 用户 `is_active=false` / `email_hash` 与当前邮箱不一致 → 400。verify 与 confirm 用同一套校验，避免「页面显示正在为 old@x 重置、点确认却 400」。无效 token 也写 `password_reset_failed`（`reason=bad_token|expired_token|used_token|email_changed`），受 `pwreset:confirm:ip` 150/h 约束；否则安全排查看不到探测行为。
- 只读，不消费 token；用于重置页先行展示「正在为 a***@example.com 重置密码」。
- verify 与 confirm 共用每 IP `pwreset:confirm:ip:{ip}:{hour}` 计数：**每次进入时 `incr_with_ttl`**（不是只读），>150/h → 429 + `Retry-After`；防止拿它当 token 探测器。150 是按「共享 NAT + 每次重置至少 verify+confirm 两次」留的余量（≥ 2× 发信配额 60）。StrictMode 下页面可能重复 verify，计入配额（余量足够）。

#### 5.4.4 `POST /api/v1/auth/password-reset/confirm`（公开）

入参 `{ "token": "...", "new_password": "..." }`。

1. 有效开关 `mail_ready` 否则 503（与 verify 一致）。
2. 每 IP `pwreset:confirm:ip:{ip}:{hour}` 配额检查：**进入时 `incr_with_ttl`**，>150/h → 429 + `Retry-After`（verify/confirm 共用）。
3. 校验密码策略（复用 `validate_password_policy`）；不通过 → 审计 `password_reset_failed`（`reason=password_policy`）+ 400。
4. 查 token 行（含 `user_id/expires_at/used_at`）；基础校验同 verify；失败审计 `password_reset_failed` + 400。
5. 读用户：
   - `is_active=false` → 400。
   - **`email_hash` 与当前 `sha256(email_fingerprint(user.email))` 不一致，或 `user.email is None` → 400「邮箱已变更，链接已失效」**（兜住「邮箱变更与签发并发」的窗口，D13 不依赖删除时机；空值必须先兜底，否则公开端点会 500）。
   - **`password_hash is None` → 允许「首次设密」**：跳过「与原密码相同」比较，直接写入新密码（D4：重置链接本身即证明控制权；成功后置 `email_verified_at`，无需预先验证）。
   - 否则 `verify(new_password, user.password_hash)` 为真 → 审计 `password_reset_failed`（`reason=same_password`）+ 400「新密码不能与原密码相同」。
6. **同一次 `db.commit()` 之前**完成：
   - 原子消费 token（防并发双花）：

```sql
UPDATE password_reset_tokens
   SET used_at = now()
 WHERE id = :id AND used_at IS NULL AND expires_at > now()
 RETURNING id
```

   返回 0 行 → 400「链接已失效，请重新申请」。
   - `user.password_hash = hash(new_password)`
   - `user.must_change_password = False`
   - **`user.email_verified_at = now()`**（重置链接证明了对该邮箱的控制权；未验证邮箱借此完成验证，D4）
   - `user.session_version += 1`
   - 吊销全部 PAT（`revoke_user_tokens(db, user_id, reason="password_reset")`）
   - 删除该用户其它未用重置 token
   - `commit()`
   > token 消费与密码写入必须同一事务：否则密码写失败会留下「token 已作废、密码未改」的黑洞。
7. 审计（commit 之后，**try/except + log.warning**：重置已生效，审计失败不能把成功变成 500）：
   - `password_reset_completed`（`actor_user_id=None`，`details={"user_id": ..., "email_masked": ...}`）
   - 逐条 `token_revoked`（reason=`password_reset`，`auth_method="anonymous"`，与改密同款但认证方式显式匿名）
8. **解锁（只清 user 维度的 username/email 两形态）**：
   - 给 `LocalAuthService.clear_locks` 增加 `*, include_name: bool = True`（默认 True 保持 `directory.py:517/572` 现有三形态行为）；重置 confirm 显式传 `include_name=False`，只清 `auth:fail:user:{username|email}` 与 `auth:lock:user:{username|email}`。
   - **不要清 `name` 形态**：`name` key 跨同名用户共享（`local_auth.py:161-175`），匿名重置不该影响别人。
   - 目的：用户「试了几次被锁 → 邮箱重置成功 → 新密码登录仍 429」是必然投诉；管理员重置的既有语义包含「重置即解锁」（`directory.py:517`），这里对齐 user 维度。
   - **绝对不要清 `auth:lock:ip:*`**：匿名重置若能清 IP 锁，任何持有一个已验证账号的人都能「重置自己 → 解 IP 锁 → 继续换用户名爆破」，把 IP 维度封控变成无限刷新。
   - IP 锁按 15 分钟自然过期。**本批不在风控页提供 `pwreset:lock:ip` 的查询/解锁**（现有 `risk.py` 只扫 `auth:*`，别写成已有能力）；应急用 ops-manual §13 的 `redis-cli DEL pwreset:lock:ip:<ip>` + `DEL pwreset:fail:ip:<ip>`（执行后该 IP 的 R8 封控短暂失效，慎用）。纳入风控页列为 §13.13 二期。
   - 解锁同样 `try/except + log.warning`，失败不影响响应。顺带清 `email:chg:fail/lock:user:{id}`（用户之前可能在邮箱操作里输错密码被锁，重置成功后应能继续改邮箱）。
9. 返回 `{status:"ok"}`。

> token 单次、30 分钟、DB 哈希；并发双花靠 `UPDATE ... WHERE used_at IS NULL` 原子收口。
> 改密/管理员重置/邮箱重置都删除该用户的未用 token（D13）。
> `password_hash IS NULL` 的账号：只要邮箱存在且格式合法，重置链接即可用；重置成功会同时置 `email_verified_at`（D4），随后可设置首个本地密码。管理员兜底仍是 `set_password.py`；这条路径可自助（前提是邮箱可收信）。

### 5.5 会话失效（session_version）

#### 5.5.1 改动点

1. `settings.py` 不动 TTL；`services/auth.py::encode_session` payload 增加
   `"ver": getattr(user, "session_version", 0) or 0`。
   - 必须容忍 **transient/未持久化 User**（`session_version` 为 `None`）：`tests/test_directory.py:207` 就用 `User(id=..., name=...)` 直接签 JWT；不兜底会写出 `ver: null`，解码后 `int(None)` 抛 `TypeError` → 500。
2. `deps.py::load_active_user(uid, *, expected_session_version: int | None = None)`：
   - 单次查询多取 `User.session_version`。
   - `expected_session_version is not None and row.session_version != expected` →
     `HTTPException(401, "会话已失效，请重新登录")`。
   - **用关键字参数**，旧 monkeypatch（`tests/test_mcp_auth_chain.py:138-141` 的单参 `_load(uid)`）只需改签名时一眼可见；文档要求测试同步改。
3. `deps.py::get_current_user`：session 分支传 `int(payload.get("ver") or 0)`（`ver` 缺失或为 `null` 都按 0）；dev `X-User-Id` 分支传 `None`（不校验）。
4. `services/mcp_auth.py:242` 调 `load_active_user(resolved.user_id)` 保持默认 `None`（PAT 走吊销，不走版本）。
5. 自增点（同一事务、commit 之前）：
   - `POST /auth/change-password`
   - `POST /admin/directory/users/{id}/reset-password`
   - `POST /auth/password-reset/confirm`
   - `scripts/set_password.py`（应急改密，`scripts/set_password.py:105-109`）
   - `scripts/set_initial_admin.py`（初始化管理员，`scripts/set_initial_admin.py:131-135`）
   - 以上五处同时删除该用户未用的重置 token，并 **`DEL email:code:{user_id}`**（改密/重置后旧验证码不能继续用于换绑邮箱）；同时 best-effort 清 `email:chg:fail/lock:user:{id}`（否则重置后邮箱操作仍被 15 分钟锁挡）。
   - **Redis 清理必须 commit 之后 best-effort**：`try/except + log.warning`，不能因 Redis 抖动让改密/管理员重置/禁用失败或“密码已改却返回 500”。CLI 脚本（`set_password.py` / `set_initial_admin.py`）没有现成 Redis：要么用 `redis.asyncio.from_url` 短连接 `aclose()`，要么跳过（验证码 600s TTL 自然过期）；**不要**裸调用未连接的 `Redis()`。
   - **transient 对象**（`set_initial_admin.py` 的 `User(...)` 未 flush 时 `session_version` 是 `None`）统一写
     `user.session_version = (user.session_version or 0) + 1`，不要直接 `+= 1`。
   - `services/tokens.py` 顶部的「吊销挂钩钉子」注释同步改成 **6 个**生产写点（现有 5 个含两个脚本；新增 `password-reset/confirm`），否则下一批按 5 去 grep 又会漏。
6. 不自增：邮箱绑定/换绑/解绑。
7. **禁用账号**（`directory.py` disable）也 `session_version += 1`（安全动作：重新启用后旧 JWT 不复活），并删除该用户未用重置 token + `DEL email:code:{id}`。
8. 既有测试会被连带打红（实施时必须同步改）：
   - `tests/test_local_auth_integration.py:395-401`：改密后同一 cookie 的 `/auth/me` 现在是 200，要改成 401。
   - `tests/test_local_auth_integration.py:501-527`（`test_forced_change_blocks_other_endpoints`）：改密成功后同一 cookie 访问 `/api/v1/projects` 现在断言 200，版本自增后会变 401，要同步改。
   - `tests/test_mcp_auth_chain.py:138-141,250-255`：monkeypatch `load_active_user` 的单参签名。
   - `tests/test_directory.py:207`：transient User 签 JWT（见第 1 步）。
   - `tests/test_oidc_service.py`：`upsert_user_from_userinfo` 返回值从 `User` 改为 `(user, email_changed, old_email)` 后，**四处解包（`:115/132/149/167`）都要改**；FakeSession 补 `rollback`。

#### 5.5.2 兼容与后果

- 迁移后所有用户 `session_version=0`；存量 JWT 无 `ver` 按 0 → 全部继续有效（不制造全站掉线）。
- 用户第一次改密/被重置后版本变 1，本人所有旧 JWT（含当前请求用的那个）失效；下一次请求 401。
- **前端必须配合**：改密成功不再依赖刷新 `me`（会 401 触发跳转），而是主动清会话并回登录页（§6/§7）。
- 管理员重置后：目标用户下一次请求 401，用临时密码重新登录 → 强制改密流程不变。
- **已知 UX 变化**：新建账号首次改密后会回登录页（版本自增），不再留在站内；管理员重置同理。这是 R5「改完整登录」的必然结果，上线公告要写明。

### 5.6 邮件发送基础设施

#### 5.6.1 `mailer.py`

```python
class MailSendError(RuntimeError): ...

async def send_mail(
    settings: Settings, *, to: str, subject: str, body: str,
    timeout: float | None = None,
) -> None:
    """同步 smtplib -> to_thread;失败抛 MailSendError;日志只出现脱敏收件人。"""
```

- `From` 用 `email.headerregistry.Address(display_name=settings.smtp_from_name or "", addr_spec=settings.smtp_from_email)`；`To` 同样用 `Address(addr_spec=to)`，防头注入。**`display_name` 不能传 `None`**（CPython 3.12 的 `Address` 会对 None 迭代抛 `TypeError`；未配置显示名时用空串）。`smtp_from_name` 不得含 CR/LF（启动校验检查）；`smtp_from_email` 必须通过与收件人相同的头部安全校验。
- **`send_mail` 自己校验收件人**（不能信任调用方）：拒绝含 `, ; < > " \s` 或控制字符的地址，抛 `MailSendError(definite=True)`（未发出）。notifications 路径遇到不安全地址时跳过并 log（脱敏）；验证码路径遇到库存地址不安全时返回 400「当前邮箱格式不受支持，请更换邮箱」。
- 端口/TLS 逻辑沿用现有：`smtp_use_ssl` → `SMTP_SSL`；否则 `SMTP` + 可选 `starttls`。
- **两层超时**：socket 层 `settings.smtp_timeout_seconds=15`（保持既有 notification 行为）；交互路径外层再用
  `asyncio.wait_for(..., settings.smtp_total_timeout_seconds=20)` 卡**总时长**——`smtplib` 的 `timeout` 只管单次 socket 操作，连接 + starttls + login + send 各自可耗满，最坏 4×15s 会超过前端 30s 超时。
- **异常要区分「确定失败」与「结果未知」**：`MailSendError(definite: bool)`。
  - **连接 / 认证 / RCPT 阶段失败**（邮件未被接受）→ `definite=True`（可以安全地删 token/验证码并报失败）。
  - **DATA 阶段开始后**（`send_message()` 已发出）的任何 `TimeoutError` / `SMTPServerDisconnected`，以及外层 `asyncio.wait_for` 超时 → `definite=False`（服务器可能已接受；调用方保留 token/验证码，提示「结果未知，请稍后检查邮箱」）。
  - `wait_for` 取消 future 不会终止底层线程，所以不能在超时后假定未发送。
- 日志：`log.info("mail sent to=%s subject=%r in %.1fs", mask_email(to), subject, ...)`；异常日志同样脱敏。
- `notifications.py` 改为调用 `send_mail`；原有 best-effort 语义与调用点不变。

#### 5.6.2 邮件内容（纯文本）

| 用途 | 主题 | 正文要点 |
| --- | --- | --- |
| 验证码 | `【素材库】邮箱验证码` | 「你的验证码是 123456，`{ttl//60}` 分钟内有效。用于绑定/更换/验证邮箱。若非本人操作请忽略。」 |
| 重置链接 | `【素材库】重置密码` | 「点击链接重置密码（`{ttl//60}` 分钟内有效，仅可使用一次）：<URL>。若非本人操作请忽略；如担心账号安全请联系管理员。」 |
| 换绑告知 | `【素材库】账号邮箱已变更` | 「你的账号邮箱已由 a***@x.com 变更为 b***@y.com。若非本人操作，请立即联系管理员。」 |
| 解绑告知 | `【素材库】账号邮箱已解绑` | 「你的账号已解除邮箱 a***@x.com 的绑定，将无法再通过邮箱找回密码。」 |

- 链接必须使用配置的**公网**入口（`email_link_base_url`），不能按请求 Host 动态生成：App 走内网入口时请求 Host 是 `192.168.110.221`，用户手机在 4G 下打不开。
- **如果配置了 `EMAIL_LINK_BASE_URL_LAN`**，正文里同时给出两条链接并标注「公网访问 / 内网访问」；未配置则只给公网。**LAN 链接只是双入口兜底，不能单独使 `mail_ready` 变 true**：本功能要求至少一个收件人可达的入口（通常公网 HTTPS）；纯离线部署不支持（§8.6），上线前由产品确认。
- 正文里给出完整 URL 文本（客户端会自动识别为链接）；不依赖 HTML。

#### 5.6.3 同步发送的边界

- 交互路径（验证码、重置申请）：同步发送，20s 总预算；失败明确报错。客户端超时（Web 30s）后仍可能收到邮件，以最新一封为准（旧 token 已被新申请作废）。
- **并发上限（两段预算，不能合并）**：在 lifespan 创建 `app.state.mail_semaphore = asyncio.Semaphore(4)`。
  1. **拿槽**：`asyncio.timeout(2)` 只包 `semaphore.acquire()`；拿不到 → 429/503（带 `Retry-After`）且**确定未发送**（不写码/不保留新 token）。**拿槽位置钉死在冷却占位之前**（§5.3.2 第 9/10 步之间、§5.4.2 第 8/9 步之间）：拿不到槽直接返回，不占冷却、不插 token、不消耗任何配额。acquire 成功后立刻置 `acquired=True`，后续（链接构造等）若抛异常按标志 `release()` + 从强引用集合移除，防边界泄漏。
  2. **发送**：拿到槽后把发送放进**独立 task** 并 `await asyncio.wait_for(asyncio.shield(send_task), 20)`；超时 → `definite=False`（可能已发），按 §5.6.1 走「保留 token/码 + 结果未知」。**必须 `shield`**：裸 `wait_for(send_mail(...))` 在超时会 cancel 掉 task 本身——task 立刻以 cancelled 完成、触发 done_callback 提前放槽，而底层 SMTP 线程仍在跑，Semaphore 就失去并发上限作用。
  3. **释放**：`send_task.add_done_callback(...)`；shield 保证超时路径 send_task 不被 cancel，**线程真正结束后才释放槽**。事件循环对 task 只持弱引用，超时后 handler 返回、send_task 成为孤儿——必须保强引用，否则 task 被 GC 时 done_callback 不会跑、槽位永久泄漏：
     ```python
     async with asyncio.timeout(2):
         await sem.acquire()
     send_task = asyncio.create_task(send_mail(...))
     request.app.state.mail_tasks.add(send_task)          # 强引用集合
     def _release(t: asyncio.Task) -> None:
         request.app.state.mail_tasks.discard(t)
         if not t.cancelled() and t.exception() is not None:   # 超时路径异常无人取回
             log.warning("mail send failed after timeout: %r", t.exception())
         sem.release()
     send_task.add_done_callback(_release)
     try:
         await asyncio.wait_for(asyncio.shield(send_task),
                                settings.smtp_total_timeout_seconds)
     except TimeoutError:   # definite=False：send_task 仍在运行
         ...
     ```
     lifespan 里 `app.state.mail_tasks: set[asyncio.Task] = set()`（与 semaphore 一起建）。
  配额是小时窗口，**不是**并发上限。
- 告知邮件（换绑/解绑）：注册为 FastAPI `BackgroundTasks`（仓库既有惯例，`notifications.py:259-318`），best-effort；不要用 `asyncio.create_task`（无强引用，进程退出即丢）。
- 站内通知邮件：保持现有 BackgroundTask + best-effort。
- 同步发送占用默认线程池；靠 §5.7 的频控把并发压在可控范围。

### 5.7 限流与风控

#### 5.7.1 Redis 键

| 键 | TTL | 作用 |
| --- | --- | --- |
| `email:code:{user_id}` (hash) | 600s | `code_hash` / `email` / `purpose` / `attempts` |
| `email:code:cooldown:{user_id}` | `EMAIL_CODE_RESEND_SECONDS`（默认 60s） | 验证码重发冷却 |
| `email:code:quota:{user_id}:{yyyymmdd}` | 到当日 24:00（UTC+8） | 每用户每日 10 条验证码 |
| `email:code:req:user:{user_id}:{epoch_hour}` | 3600s | 每用户每小时 30 次验证码请求预算（**密码校验通过后、占用查询前** INCR；勿放密码校验前，见 §5.3.2 第 4 步「正确」分支） |
| `email:code:ip:{ip}:{epoch_hour}` | 3600s | 每 IP 每小时 200 条验证码（共享 NAT 余量；防批量骚扰） |
| `email:chg:fail:user:{user_id}` | `EMAIL_CHANGE_PASSWORD_LOCK_SECONDS` | 邮箱操作密码错误计数 |
| `email:chg:lock:user:{user_id}` | `EMAIL_CHANGE_PASSWORD_LOCK_SECONDS` | 邮箱操作密码错误锁（5 次） |
| `pwreset:fail:ip:{ip}` | `PASSWORD_RESET_LOCK_SECONDS` | 重置申请失败计数（不存在/停用） |
| `pwreset:lock:ip:{ip}` | `PASSWORD_RESET_LOCK_SECONDS` | **需求 R8 的 IP 封控**（5 次失败） |
| `pwreset:req:ip:{ip}:{epoch_hour}` | 3600s | 每 IP 每小时 120 次「格式合法的重置申请」预算（查库前 INCR，兜住不存在邮箱探测与审计刷屏） |
| `pwreset:send:ip:{ip}:{epoch_hour}` | 3600s | 每 IP 每小时 60 条重置邮件（共享 NAT 余量） |
| `pwreset:send:user:{user_id}:{epoch_hour}` | 3600s | 每账号每小时 5 条重置邮件 |
| `pwreset:cooldown:user:{user_id}` | 60s | 重置邮件冷却 |
| `pwreset:confirm:ip:{ip}:{epoch_hour}` | 3600s | verify/confirm 每 IP 每小时 150 次（≥ 2× 发信配额 60） |

> `ip` 一律取 `request.client.host or "unknown"`（与登录路由同口径）；`"unknown"` 是一个桶，测试清理要覆盖它。

#### 5.7.2 计数实现钉子

- **不要每次请求都 EXPIRE**：否则 429 会不断续期把用户永远锁住（`baidu` 频控踩过的坑）。
- **也不要裸写 `INCR` 后再 `EXPIRE`**：两步之间进程被 kill/OOM 会留下永不过期的计数键，累积到 5 后该 IP 永久封控。统一走 `services/rate_limit.py` 的 Lua：`INCR` + `TTL < 0` 时 `EXPIRE`，单脚本原子（照 `mcp_limiter.py:37-52`）。
- 先查锁再计数；**失败计数只记真正失败**（邮箱不存在 / 账号停用），格式错误、冷却拒绝、SMTP 失败不计数。
- 发信配额（每 IP/每用户）用「先读后写」：校验阶段 `GET` 当前值，**发送成功后才 INCR**；SMTP 失败不烧额度（吸取百度「INCR 在校验前，失败也烧额度」的教训）。极小并发窗口可接受。
- **配额 ≠ 并发**：上述都是小时窗口计数，挡不住同一秒的并发；交互式发信另有 `app.state.mail_semaphore`（§5.6.3），两者都要有。
- **Redis 故障**：`rate_limit` 抛 `RateLimitUnavailable`，路由统一映射 503「服务暂不可用」——**fail-closed**（与 MCP 链一致），不要裸抛 500，也不要静默放行绕过限流。
- 成功即清零对应的 fail 计数（登录限流的同款语义）。
- 锁的剩余时间用 `PTTL` 换算成分钟/秒写进错误文案。

#### 5.7.3 与登录限流的关系

- 完全独立命名空间（D14）：忘记密码刷 5 次不会锁登录；登录失败也不会锁忘记密码。
- 共享 NAT 连坐：`pwreset:lock:ip` 默认锁 15 分钟（与登录一致），并保留 `PASSWORD_RESET_LOCK_SECONDS` 可调；运维若发现公司出口只有一个公网 IP，可评估调到 5 次/5 分钟或后续改为 `(ip,email)` 双维度（§13 遗留）。**每小时 IP 配额按共享 NAT 留余量**：验证码 200/h、重置申请 120/h、重置邮件 60/h、verify/confirm 150/h（`§5.10` 可调）；上线首日建议按部门分批验证邮箱，避免全公司同一小时撞配额。

#### 5.7.4 429 的机器可读剩余时间

- 所有 429 响应统一带 `Retry-After: <秒>` 头（FastAPI `HTTPException(429, detail, headers={"Retry-After": ...})`）。
- Web/App 有该头时按它做倒计时；没有时退回文案解析。避免前端靠中文文案猜时间。
- 每日配额按 **UTC+8** 计算日界：用 `timezone(timedelta(hours=8))` 固定偏移（中国无夏令时），**不要用 `ZoneInfo("Asia/Shanghai")`**——`python:3.12-slim` 未装 tzdata，会抛 `ZoneInfoNotFoundError`。小时窗口用 UTC epoch hour，只要求稳定不要求对齐自然小时。

### 5.8 接口契约总表

| 方法 | 路径 | 鉴权 | 入参 | 成功 | 主要失败 |
| --- | --- | --- | --- | --- | --- |
| GET | `/api/v1/auth/public-config` | 公开 | — | `{email_auth_enabled,password_reset_enabled,password_min_length}` | — |
| POST | `/api/v1/auth/email/code` | session | `{email,password}` | `{status,masked_email,expires_in}` | 400/409/422/429/502/503 |
| POST | `/api/v1/auth/email/confirm` | session | `{code}` | `{status,email,email_verified,action}` | 400/409/422/503 |
| POST | `/api/v1/auth/email/unbind` | session | `{password}` | `{status}` | 400/422/429（**无 SMTP 503**；Redis 故障仍 503，fail-closed） |
| POST | `/api/v1/auth/password-reset/request` | 公开 | `{email}` | `{status:"sent"}` | 400/422/429/502/503 |
| POST | `/api/v1/auth/password-reset/verify` | 公开 | `{token}` | `{valid,email_masked,expires_at}` | 400/422/429/503 |
| POST | `/api/v1/auth/password-reset/confirm` | 公开 | `{token,new_password}` | `{status:"ok"}` | 400/422/429/503 |

**既有端点改动**：`GET /api/v1/auth/me` 增加 `email_verified?: bool`（= `bool(email and email_verified_at)`；前端按 `?? false` 处理，兼容灰度/回滚时旧后端不返回），Web `Me` 类型与 App `Me.fromJson` 同步；`serialize` 点在 `routers/auth.py:220-250`。

**状态码铁律**：这些端点的**业务失败**（认证失败 401 / PAT 403 除外）一律用 400/409/422/429/502/503，**不要用 401/403**——Web 的 axios 401 拦截器会整页跳登录，App 的 401 钩子会清会话，会把「验证码错了」误判成「登录过期」。session 端点未登录时由 `require_session_auth` 抛 401、PAT 调用抛 403，这两种是认证语义，不适用上面的铁律。

Pydantic 模型（`models/__init__.py`）：

```python
class EmailCodeIn(BaseModel):
    email: str = Field(..., max_length=254)
    password: str = Field(..., min_length=1, max_length=128)
    @field_validator("email")
    def _norm(cls, v): return strict_normalize_email(v)

class EmailCodeConfirmIn(BaseModel):
    code: str = Field(..., pattern=r"^\d{6}$")

class EmailUnbindIn(BaseModel):
    password: str = Field(..., min_length=1, max_length=128)

class PasswordResetRequestIn(BaseModel):
    email: str = Field(..., max_length=254)
    @field_validator("email")
    def _norm(cls, v): return strict_normalize_email(v)

class PasswordResetTokenIn(BaseModel):
    token: str = Field(..., min_length=20, max_length=128)

class PasswordResetConfirmIn(PasswordResetTokenIn):
    new_password: str = Field(..., min_length=1, max_length=128)
```

### 5.9 审计事件（7 个新增）

| event_type | actor | details（脱敏） |
| --- | --- | --- |
| `email_verification_requested` | 本人 | `{ok, purpose, email_masked, reason?}` |
| `email_verified` | 本人 | `{action:"bind"|"verify", email_masked}` |
| `email_changed` | 本人 | `{old_masked, new_masked}` |
| `email_unbound` | 本人 | `{old_masked}` |
| `password_reset_requested` | `None` | `{ok, user_id?, email_masked, reason?}` |
| `password_reset_completed` | `None` | `{user_id, email_masked}` |
| `password_reset_failed` | `None` | `{reason, email_masked}` |

- 重置链路全部**未认证**，`actor_user_id` 一律 `None`（与 `local_login_failed` 的「已证明是本人」口径对齐；避免审计呈现「本人请求重置本人」并污染 actor 快照列）。
- **`auth_method` 必须显式写 `"anonymous"`**：`audit.py:74-79` 的 `_default_auth` 对非 PAT 请求一律回落 `"session"`，不覆盖会让匿名重置在审计页看起来像会话行为。要改的不只是写入侧：
  - `api/app/routers/admin.py` **三处** `Literal["all","session","pat"]`（`:265` / `:301` / `:358`）加 `"anonymous"`；并在 `_build_audit_query`（`:283-289`）增加 `elif auth_method == "anonymous": stmt = stmt.where(AuditEvent.auth_method == "anonymous")` —— 只改类型不加分支会让筛选返回全量；
  - web `AdminAuditPage.tsx` 的 `AUTH_METHOD_OPTIONS`、`authMethodParam` 白名单、行内 label（现在 `e.auth_method ?? 'session'` 会显示裸 `anonymous`）；
  - **扩** `tests/test_audit_auth_method_filter.py`（文件已存在，覆盖 all/session/pat 三态与 CSV）：`anonymous` 只回 anonymous，`session` 不含 anonymous；现有 `_seed` 的 `len(...)` 断言同步调整；
  - **App 端没有 auth_method 筛选/展示，这个维度不需要改 `audit_labels.dart`；但事件/详情键映射仍按第 4-6 项同步**。
- **details 契约**（测试按分支断言**必需键**；失败/运营分支允许附加键，不要求所有事件同构）：
  - `email_verification_requested`: 成功必需 `{ok, purpose, email_masked}`；`wrong_password` 失败分支允许只带 `{ok:false, reason}`（此时 purpose 尚未判定，不要为凑键提前查库）
  - `email_verified`: 必需 `{email_masked}`；`action`（用户流程 `bind`/`verify`；ops 脚本可不带，用 `source=ops` 区分）、`source?`、`verified_by?`
  - `email_changed`: `{old_masked, new_masked}`
  - `email_unbound`: `{old_masked}`
  - `password_reset_requested`: 必需 `{ok, email_masked}`；`user_id?`、`reason?`
  - `password_reset_completed`: `{user_id, email_masked}`
  - `password_reset_failed`: 必需 `{reason}`；`email_masked?`（token 无效时可能不知道邮箱）、`ip?`/`lock_seconds?`（`reason=ip_locked` 时）
  - `reason` 按事件分组：`email_verification_requested` → `wrong_password` / `smtp_failed` / `smtp_timeout` / `store_failed` / `email_taken` / `username_taken`；`password_reset_failed` → `not_found` / `inactive` / `ip_locked` / `send_quota_ip` / `send_quota_user` / `bad_token` / `expired_token` / `used_token` / `email_changed` / `password_policy` / `same_password`。
- 审计 details 里的邮箱用 `mask_email`；**本批新增的事件禁止**出现验证码、token、完整邮箱。
- **actor 快照脱敏**：`audit.write` 增加可选 `actor_email_snapshot` 覆盖参数；`email_verification_requested` 传**当前**邮箱的 `mask_email(...)`，`email_verified` / `email_changed` 传新邮箱的 `mask_email(...)`，`email_unbound` 传**清空前**旧邮箱的 `mask_email(...)`，避免新事件把完整邮箱写进 `actor_email_snapshot`（`audit.py:85-95` 现在无条件取 `user.email`）。
- 既有例外（本批不改，§13 记录）：管理员 `user_updated` 的 `changes.email` 仍是完整新旧值；其他既有事件的 `actor_email_snapshot` 保持原样。本批只保证**新增事件**不写完整邮箱。
- `audit.write` 自带 commit：业务事务 commit 之后再写；不要写在事务中间。
- **成功响应路径上的审计写入统一 `try/except + log.warning`**：`audit.write` 走独立 session（`audit.py:97-147`），DB 抖动不能把「邮件已发/密码已重置」变成 500。发信成功、重置成功、绑定成功三处都要包。
- **八处必须逐项勾选同步**（硬编码数组/映射不会「自动出现」）：
  1. `web/src/pages/AdminAuditPage.tsx` 的 `EVENT_TYPES` 数组（Select 未开 tags，不加就选不到）；
  2. `web/src/lib/labels.ts` 的 `EVENT_TYPE_LABEL` 映射；
  3. `web/src/pages/AdminAuditPage.tsx` 的 `DETAIL_KEY_LABEL`（补 `ok`/`email_masked`/`old_masked`/`new_masked`/`purpose`/`reason`/`source`/`verified_by`，缺省会回落裸键；**不要加 `delivery`**，方案统一用 `reason`）；
  4. `app/lib/features/admin/audit_labels.dart` 的 `kAuditEventTypes` 数组；
  5. `app/lib/features/admin/audit_labels.dart` 的 `kAuditEventLabels`（事件→中文；缺 key 回落裸 token）；
  6. `app/lib/features/admin/audit_labels.dart` 的 `kAuditDetailKeyLabels`（details 键→中文；缺 key 回落裸键）；
  7. 两处计数注释（`AdminAuditPage.tsx` 顶部、`audit_labels.dart` 顶部）与 `labels.ts` 顶部口径注释；
  8. `rushes-spec/material-storage/prod-observability-fix-plan.md` 附录 A。
- 当前基线（以实施时 `grep` 为准）：web `EVENT_TYPES` 64 事件 + 全部 = 65；`labels.ts` 头部注释为 68 键（64 真实 + 4 历史死键）；App 65 项 = 64 事件 + 全部。本批 +7 → web 71 事件 + 全部 = 72；labels 约 75 键；App 72 项。**旧注释可能过期，实施时逐文件 grep 实数后回填**。
- 登录事件 `local_login_*` 不动；审计 CSV 导出按事件列自动工作。

### 5.10 配置项

| env | 默认 | 说明 |
| --- | --- | --- |
| `EMAIL_AUTH_ENABLED` | `false` | 邮箱绑定/找回密码总开关（只影响邮箱功能，不影响站内通知邮件） |
| `NOTIFY_EMAIL_ENABLED` | `false` | 站内通知邮件独立开关（审批/邀请）；填 SMTP **不会**自动打开它。**仅管站内通知**——换绑/解绑的安全告知邮件不受此开关约束（只要 SMTP 可用即 best-effort 发送），`mail_ready=false` 时跳过 |
| `EMAIL_LINK_BASE_URL` | 无（功能开启时**必填**） | 邮件链接的公网 SPA 基址（含 `/ms-static/web/`）；**不回落** `WEB_APP_BASE_URL` |
| `EMAIL_LINK_BASE_URL_LAN` | `None` | 可选内网 SPA 基址；非空时邮件同时给内网链接（内部 SMTP 中继/公网不可用场景），允许私网 host |
| `SMTP_FROM_NAME` | `None` | 发件人显示名（可选） |
| `SMTP_TIMEOUT_SECONDS` | `15` | 单次 socket 操作超时（与既有 notification 行为一致） |
| `SMTP_TOTAL_TIMEOUT_SECONDS` | `20` | 交互式发信总预算（`asyncio.wait_for`；< 前端 30s） |
| `EMAIL_CODE_TTL_SECONDS` | `600` | 验证码有效期 |
| `EMAIL_CODE_MAX_ATTEMPTS` | `5` | 单码最多错误次数 |
| `EMAIL_CODE_RESEND_SECONDS` | `60` | 重发冷却 |
| `EMAIL_CODE_DAILY_PER_USER` | `10` | 每用户每日验证码上限 |
| `EMAIL_CODE_HOURLY_PER_IP` | `200` | 每 IP 每小时验证码上限（共享 NAT 余量） |
| `EMAIL_CODE_REQUEST_PER_USER` | `30` | 每用户每小时验证码请求预算（含 409 占用尝试） |
| `EMAIL_CHANGE_MAX_PASSWORD_FAILURES` | `5` | 邮箱操作密码错误上限 |
| `EMAIL_CHANGE_PASSWORD_LOCK_SECONDS` | `900` | 密码错误锁时长 |
| `PASSWORD_RESET_TOKEN_TTL_SECONDS` | `1800` | 重置链接有效期 |
| `PASSWORD_RESET_MAX_FAILURES` | `5` | **R8：IP 失败上限** |
| `PASSWORD_RESET_LOCK_SECONDS` | `900` | **R8：IP 封控时长**（可调 3600） |
| `PASSWORD_RESET_COOLDOWN_SECONDS` | `60` | 重置邮件冷却 |
| `PASSWORD_RESET_HOURLY_PER_USER` | `5` | 每账号每小时重置邮件 |
| `PASSWORD_RESET_HOURLY_PER_IP` | `60` | 每 IP 每小时重置邮件（共享 NAT 余量） |
| `PASSWORD_RESET_HOURLY_CONFIRM_PER_IP` | `150` | 每 IP 每小时 verify/confirm（≥ 2× 发信配额） |
| `PASSWORD_RESET_HOURLY_REQUEST_PER_IP` | `120` | 每 IP 每小时格式合法的重置申请（请求预算） |

`.env.example` / `.env.production.example` 同步补段（注释形式），真实 `.env` 由运维手工填、不进 git。

> **通知邮件并发**：站内通知邮件保持 Best-effort，但也走 `app.state.mail_semaphore`（拿不到槽直接跳过 + log，不排队）——否则审批批量操作会占满默认线程池，交互式找回密码在 20s 预算内拿不到线程。配额只管交互式端点，不覆盖通知；不要把「频控」当成通知的并发上限。

> **配置驱动**：§5.3/§5.4 流程里的 200/120/60/10/150/600/1800 等数字都是**默认值**；实现一律读 `settings.*`（或传入 service），不要硬编码。至少补两条测试：把每日验证码上限设为 1、把重置锁时长设为 1 秒，断言行为随配置变化。

**启动校验与降级**（新增 `Settings.resolve_mail_ready(*, detail: bool = False)`，在 lifespan 构造外部 client 之前调用；`detail=True` 返回 `(bool, reason)` 供 runbook 预检打印原因）：

- `EMAIL_AUTH_ENABLED=false` → `mail_ready=false`，跳过全部校验。
- `EMAIL_AUTH_ENABLED=true` 时校验：
  - `smtp_enabled` 必须为 true（host + from_email 齐备）；
  - `smtp_username` 与 `smtp_password` 必须同时有或同时无（有用户名、空密码 = 认证必失败，别让入口可见）；
  - `smtp_use_ssl` 与 `smtp_use_tls` 互斥；**`smtp_port==465` 必须 `use_ssl=true` 且 `use_tls=false`；`smtp_port==587` 必须 `use_tls=true` 且 `use_ssl=false`**（只写“互斥”挡不住 465 忘开 SSL 的半死状态）；
  - `smtp_from_email` 必须通过头部安全校验（不含 `,;<>"\s` 与控制字符），`smtp_from_name` 不含 CR/LF；
  - `EMAIL_LINK_BASE_URL` 非空、`http(s)://` 开头、路径以 `/ms-static/web/` 结尾；用 `urllib.parse.urlsplit` 校验 `username/password/fragment/query` 都为空（防止把凭据/查询串写进邮件正文）；
  - `EMAIL_LINK_BASE_URL_LAN` 若配置，同样必须是合法 http(s) SPA 基址（允许私网 host），用于邮件正文的第二条链接；
  - `env == "production"` 时：scheme 必须是 `https`，host 必须含 `.` 且不以 `.local` 结尾；用 `ipaddress.ip_address` 解析（含 IPv6）并拒绝 `is_private` / `is_loopback` / `is_link_local` / `is_unspecified`（覆盖 `169.254.*`、`0.0.0.0`、`::1`、IPv6 ULA），同时也拒绝 `localhost` / `10.*` / `192.168.*` / `172.16-31.*`；
- **不合法时不抛异常、不拖垮登录**：`log.error("email auth disabled: invalid config: <原因>")`，`mail_ready=false`，公开配置返回 false、端点 503。理由：邮箱找回是**非核心功能**，一个链接基址拼写错误不应该让全站（含登录）进入容器重启循环。
- runbook 提供预检命令（§9.3 第 6 步），在 force-recreate 前就能看到配置是否合法。

## 6. Web 端设计

### 6.1 登录页（`web/src/pages/LoginPage.tsx`）

- 密码框下方（或按钮下方右侧）加「忘记密码？」链接 → `/forgot-password`。
- 显隐读 `usePublicConfig()`：**只有明确拿到 `password_reset_enabled=false` 才隐藏**；请求失败/加载中（unknown）时保留链接——登录页是匿名用户唯一入口，一次配置请求抖动不应该把恢复入口藏掉。点进去若功能未开，由后端 503 文案说明。
- 登录页支持 `?reset=1`：显示绿色 Alert「密码已更新，请重新登录」（与改密/重置两种来源统一文案）。
- 保留现有「连续 5 次登录失败将锁定 15 分钟」提示；不混入重置锁定文案。

### 6.2 忘记密码页（新 `web/src/pages/ForgotPasswordPage.tsx`）

- 路由 `/forgot-password`，公开页（AppShell 放行，见 §6.5）。
- 表单：邮箱（`autoFocus`，`type=email`）。
- 提交 → `POST /auth/password-reset/request`：
  - 200 → 成功面板：「重置链接已发送至 <输入的邮箱>。链接 30 分钟内有效，仅可使用一次；请同时检查垃圾邮件。」
  - 400 → 直接显示后端文案（「该邮箱未绑定任何账号」）。
  - 429 → 显示封控/冷却文案，按钮倒计时。
  - 502 → 「邮件发送失败，请稍后重试」。
  - 503 → 「邮箱找回密码功能暂未开启，请联系管理员」（与 §6.3 重置页 503 文案统一）。
- 成功后 60 秒内禁用提交按钮（本地倒计时，服务端仍有冷却兜底）。
- 文案里的「30 分钟」按默认 `PASSWORD_RESET_TOKEN_TTL_SECONDS=1800` 书写；**若运维改了 TTL，Web/App 两处文案同步改**（邮件正文是动态 `{ttl//60}`，不受影响）。不为此扩 `public-config` 契约。
- 底部链接「返回登录」。

### 6.3 重置密码页（新 `web/src/pages/ResetPasswordPage.tsx`）

- 路由 `/reset-password`，公开页。
- 读取 token：**只读 `window.location.hash`（`#token=...`）**；读完立即 `history.replaceState` 清掉 URL 里的 token。
  - **不支持 `?token=`**：query 会进 nginx access log / 代理日志 / 浏览器历史，破坏 D8 的全部保护。
  - **StrictMode 安全**：用 `useState(() => 从 window.location.hash 捕获 token)` 在渲染期一次性拿到内存副本，再在 `useEffect` 里 `replaceState`；不要“先清 hash 再 setState”，开发态 effect 双执行会读到空值。
  - 若地址栏没有 fragment（用户手工复制/邮件客户端截断）：显示「粘贴重置链接或 token」输入框，token 只留在组件内存，不写回 URL。
- 挂载时 `POST /auth/password-reset/verify`：
  - 表单的最小长度/提示用 `public-config.password_min_length`（**拉取失败/unknown 时回落 8**——仅默认值，后端实际可配）；**抽 `web/src/lib/password-policy.ts`（`buildPasswordRe(minLength)` + 提示文案），改密页与重置页共用**（`ChangePasswordPage.tsx:17` 的 `PW_RE` 未导出且硬编码 8，不能直接复用）。「含字母 + 含数字」规则与后端保持一致。
  - 成功 → 显示「正在为 a\*\*\*@example.com 重置密码」+ 新密码/确认密码表单（用上文抽出的 `password-policy.ts` 的 `buildPasswordRe(minLength)` 与校验文案；改密页后续也迁移到同一份）。
  - 400 → 失效面板：「链接已失效或已被使用」+「重新申请」按钮 → `/forgot-password`。
  - 429 → 显示频控/冷却文案（有 `Retry-After` 时倒计时）。
  - **503 → 独立文案「邮箱找回密码功能暂未开启，请联系管理员」**，不要伪装成「链接失效」。
- 提交 `POST /auth/password-reset/confirm`：
  - 200 → **在本页展示成功面板**：「密码已重置，请用新密码登录」+「去登录」按钮 → `/login`。成功后先 `queryClient.clear()`（或 `removeQueries({queryKey:['me']})`），否则旧 `me` 缓存还在，已登录浏览器点「去登录」会先被 AppShell 弹回首页再被 401 踢回登录。
  - 400 → 表单错误提示（策略/相同密码/失效）。
  - 503 → 同上的「功能未开启」文案。
- 成功面板留在本页而不是 `navigate('/login?reset=1')`：若浏览器里还有旧会话，`AppShell` 会把已登录访问 `/login` 的人直接重定向到 `/`，提示会丢失。登录页的 `?reset=1` Alert 仅作为匿名场景的补充。
- **无壳渲染**：`/forgot-password`、`/reset-password` 必须在 `AppShell` 里**无条件**返回 `<RouterRoutes />`（像 `/dev-login` 那样），不能只在 `isError || !me` 分支放行；否则在「浏览器里已有旧会话」时重置页会带顶栏。
- 页面不渲染顶栏（同登录页），样式复用 Card + tokens。

### 6.4 设置页（`web/src/pages/SettingsPage.tsx`）

- 在 PAT 区域上方新增「账号安全」卡片组件 `web/src/components/settings/EmailSecuritySection.tsx`。
- 展示：
  - **邮箱功能关闭（`mail_ready=false`）且 `me.email` 为空**：整块隐藏（不显示一个必然失败的「绑定邮箱」）。
  - **邮箱功能关闭（`mail_ready=false`）但 `me.email` 非空**：只显示「解除绑定」（解绑不依赖 SMTP），绑定/验证/换绑隐藏并提示「邮箱功能暂未开启」。
  - `me.password_set=false` → 邮箱区禁用并提示「该账号尚未设置本地密码，请联系管理员初始化后再绑定邮箱」（后端 `/email/code` 同样 400，前端不要给一个必然失败的入口）。
  - `me.email` 为空 → 「未绑定邮箱」+「绑定邮箱」按钮。
  - 有邮箱且 `email_verified=false` → 邮箱 + 橙色「未验证」Tag +「验证邮箱」「更换邮箱」「解除绑定」。
  - `email_verified=true` → 邮箱 + 绿色「已验证」Tag +「更换邮箱」「解除绑定」。
- 绑定/换绑弹窗 `EmailBindDialog`：
  - 第一步：新邮箱 + 当前密码 → 「发送验证码」；成功后进入第二步并显示脱敏目标邮箱 + 60s 倒计时。
  - 第二步：6 位验证码 → 「确认」。
  - 取消/关闭清空状态；重新打开从第一步开始。
- 解绑弹窗：当前密码 + 二次确认文案（「解除后将无法通过邮箱找回密码」）。
- 所有失败用 `message.error(errorMessage(err, ...))`；422 数组由现有 `errorMessage` 兼容。
- **成功后刷新当前用户**：绑定/换绑/解绑成功后 `queryClient.invalidateQueries({queryKey:['me']})`（`session_version` 未变，安全），否则设置页仍显示旧邮箱/旧 Tag。
- `me.email_verified` 为新增字段；`useMe` 返回后自动带入。
- 管理员侧：`AdminUsersPage` 列表/详情增加 `email_verified` Tag（后端 `DirectoryUserOut.email_verified`），支持排查「为什么用户说没验证」。

### 6.5 路由与会话放行

- `App.tsx`：
  - 新增懒加载路由 `/forgot-password`、`/reset-password`。
  - `onAuthPage` 扩展为 `['/login','/change-password','/forgot-password','/reset-password']`。
  - **`/forgot-password`、`/reset-password` 在 `AppShell` 里先于 `me` 判断无条件 `return <RouterRoutes />`**（同 `/dev-login`），保证已登录浏览器里点邮件链接也不渲染顶栏。
  - 已登录访问 `/login` 的现有重定向不变；`/forgot-password` 登录态访问也允许（不强制跳走）。
- `api/client.ts` 401 拦截器豁免列表加 `/forgot-password`、`/reset-password`（匿名页 `useMe` 401 不应触发整页跳转循环）。
- `api/hooks.ts` 新增：
  - `usePublicConfig()` — `GET /auth/public-config`，`staleTime: 5min`，`retry:false`。
  - `useSendEmailCode()` / `useConfirmEmailCode()` / `useUnbindEmail()`
  - `useRequestPasswordReset()` / `useVerifyResetToken()` / `useResetPassword()`
- **全局 toast 去重**：这些新 hook 统一带 `meta: { silent: true }`；`App.tsx:45-61` 的 QueryCache/MutationCache `onError` 增加 `if (meta?.silent) return;`。否则 400/409/422/502 会在页面本地提示之外再弹一次全局 toast（`usePublicConfig` 失败还会在登录页弹「数据加载失败」）。
- `api/types.ts`：`Me` 增加 `email_verified?: boolean`（`?? false` 渲染，兼容灰度/回滚）；新增请求/响应类型。

### 6.6 改密后的行为（配合 §5.5）

- `useChangePassword` 的 `onSuccess` 不再 `invalidateQueries(['me'])`（会 401）。
- `ChangePasswordPage` 成功后：
  ```ts
  queryClient.clear();
  message.success(forced ? '密码已设置，请重新登录' : '密码已修改，请重新登录');
  navigate('/login?reset=1', { replace: true });
  ```
  **同时删除页面上原有的 `navigate('/')`（`ChangePasswordPage.tsx:40`）**：导航只保留一处，否则会出现「先回首页、再回登录」的双重跳转。
- 登录页对 `?reset=1` 的 Alert 文案统一写「密码已更新，请重新登录」（覆盖改密/重置两种来源）。

## 7. App 端设计（Flutter）

### 7.1 登录页

- `login_form.dart` 在登录按钮下方加「忘记密码？」`TextButton`：**只有明确 `session.passwordResetEnabled == false` 才隐藏**；`null`（配置未拉到/失败）与 `true` 都显示，点进去由后端 503 文案兜底。
- `login_page.dart` 在 `_onReady` 里拉 `GET /auth/public-config`（加 `_configLoaded` 守卫），**fire-and-forget / 3s 短超时**，不要 `await` 到 `restore()` 之前——配置请求挂起会拖慢会话恢复；三态：`null=unknown`、`true`、`false`。
- 入口显隐：**只有明确 `false` 才隐藏**；`null/true` 都显示（点进去由后端 503 文案兜底），避免一次配置请求失败把恢复入口藏掉。
- 点击 → `Navigator.pushNamed('/forgot-password')`。

### 7.2 忘记密码页（新 `lib/features/auth/forgot_password_page.dart`）

- 输入邮箱 → 提交 → 成功/失败卡片式反馈（复用登录页的暖色错误卡风格）。
- 成功文案必须写明：「重置链接已发送。请在**浏览器**中打开邮件里的链接完成重置；链接 30 分钟内有效。」（「30 分钟」按默认 TTL 书写，改 TTL 时与 Web 同步改，见 §6.2。）
- 提供「返回登录」。

### 7.3 「我的 → 账号与安全 → 邮箱」

- `me_page.dart` 账号与安全区新增 `邮箱` 行（在「修改密码」上方），副标题显示当前邮箱或「未绑定/未验证」；显隐：**只有 `session.emailAuthEnabled == false` 且 `me.email` 为空才隐藏**；已有邮箱时始终显示，页面内只渲染「解除绑定」（解绑不依赖 SMTP）。
- 新页面 `lib/features/me/account_email_page.dart`：
  - 邮箱功能关闭（`emailAuthEnabled == false`）但已有邮箱：只保留「解除绑定」（不依赖 SMTP），其余操作隐藏并提示「邮箱功能暂未开启」。
  - 顶部卡片：当前邮箱 + 状态 Tag（已验证/未验证/未绑定）。
  - 未绑定：主按钮「绑定邮箱」。
  - 未验证：主按钮「验证邮箱」（目标=当前邮箱）+ 次按钮「更换邮箱」「解除绑定」。
  - 已验证：主按钮「更换邮箱」+「解除绑定」。
  - 绑定/换绑：底部弹层或二级页（照 `change_password_page.dart` 的表单风格）：新邮箱 + 当前密码 → 发送验证码 → 6 位验证码 → 确认；发送成功后 60s 倒计时。
  - 解绑：密码 + 确认对话框。
- `Me` 模型增加 `email`、`emailVerified`、`passwordSet`；`Me.fromJson` 用 `?? ''` / `?? false` 兼容旧后端。`passwordSet=false` 时邮箱入口禁用并提示「需管理员先初始化密码」（与 Web 同口径）。
- `Session` 增加 `emailAuthEnabled` / `passwordResetEnabled`（`bool?`，null=unknown）：由登录页 `_onReady` 的 public-config 拉取（§7.1）写入；§7.1/§7.3 的显隐判定都读这两个字段（`null/true` 显示、仅明确 `false` 隐藏）。
- API：`lib/core/api/auth_api.dart` 增加 `sendEmailCode` / `confirmEmailCode` / `unbindEmail` / `requestPasswordReset` / `verifyResetToken` / `resetPassword` / `publicConfig`。
- **429 倒计时**：`ApiException` 增加 `retryAfterSeconds`（`MsApi.err` 从 `r.headers.value('retry-after')` 填）；页面优先用它，中文文案解析兜底。现有 `ApiException` 只有 `status/message/raw/method/path`（`ms_api.dart:38-55`），不扩就兑现不了 §5.7.4。
- **绑定/换绑/解绑成功后刷新 `Session.me`**（`await session.restore()` 或 `session.me = await api.auth.me()`），否则「我的」页/邮箱页仍显示旧状态。
- **路由表要接线**：`lib/app.dart` 的 `onGenerateRoute` 增加 `/forgot-password` 与 `/account/email` 两个 case（`app.dart:117-227` 目前没有）；只写 `pushNamed` 不接线会运行期报「Could not find a generator」。
- **所有新方法（含 public-config）必须传 `Options(extra: {'noErrorReport': true})`**：`ms_api.dart:178-185` 对 status≥500 会触发全局 `onApiError`，`error_report_controller.dart` 会整页跳 `/error-report`；SMTP 失败（502）与功能关闭（503）正是需要页面内提示的场景，不关掉就永远看不到失败卡片。参考 `assets_api.dart:119` 的既有写法。

### 7.4 改密后的行为（配合 §5.5）

- `Session.changePassword` 成功后不再调用 `me()` 刷新（会 401 触发全局过期钩子），改为：
  ```dart
  await api!.auth.changePassword(...);
  await logout();   // 清 me / cookie / 清缓存钩子；不在这里导航
  ```
- 改密页 toast 改为「密码已更新，请重新登录」，**强制流与普通流统一** `pushNamedAndRemoveUntil('/', ...)` 回登录页；**删除页面里原有的 `pushNamedAndRemoveUntil('/home')` 与 `pop()`（`change_password_page.dart:70-75`）**，导航只保留一处，避免双重跳转。
- 更新 `test/core/session_change_password_stale_test.dart`（`meStale` 逻辑不再适用于改密成功路径；若保留字段则改为仅测试兜底语义）。
- **旧版 App（未升级）**：改密成功后会调 `me()` 刷新，`session_version` 已自增 → 401 → 既有 `handleSessionExpired` 清会话回 `/`。结果是「强制回登录页」，可接受；§9.3 的兼容说明按此口径写，不能承诺「旧版无感」。

### 7.5 深链（明确不做，v1）

- App 不注册 scheme / Universal Links；邮件里的 https 链接由系统浏览器打开。
- App 内文案明确提示「在浏览器中打开」。
- 二期若要做：`app_links` + Android intent-filter + iOS `CFBundleURLTypes`/Associated Domains + AASA 文件 + 签名指纹，工作量独立（§13）。

### 7.6 发版

- 当前 `pubspec.yaml` 已是 **0.1.13+17**（2026-11-03 随「安卓实况图适配」发版）；本批版本由 `tool/release.mjs` 自动 bump（预期 0.1.14+18），**以脚本输出为准**，勿手动预 bump。
- 发版后验证线上固定名/版本化 APK SHA256 三份一致（沿用既有流程）。

## 8. 安全分析与取舍

### 8.1 账号枚举（需求明确接受）

- `password-reset/request` 对「邮箱未绑定」返回显式错误 → 可枚举系统内邮箱。
- 缓解：IP 失败锁（5 次/15 分钟）、每 IP 每小时 60 条发信上限、每 IP 每小时 120 条申请预算、审计 `password_reset_failed` 可按 IP 监控；系统是内部系统、账号由管理员创建，枚举收益有限。
- 注意「成功即清零 IP 失败计数」是按需求字面（**连续**失败 5 次）实现的：枚举者可以用自己的有效邮箱穿插成功请求来重置失败链，此时剩下的硬上限是每 IP 每小时 120 次请求预算（**前 120 次落审计，超预算的 429 只计数不落审计**），不是 5 次锁。这是 R7 显式报错的必然代价，已在 §8.6 记录。
- **已登录枚举面**：`/email/code` 的 409「该邮箱已被其他账号使用」可被登录用户用来探测某邮箱是否已绑定/与用户名冲突；由每用户 30/h 请求预算约束（每次 409 都计数）。内部系统收益有限，文案可保留具体原因以便自助纠错。
- 若未来要求改为防枚举：把「不存在/停用」统一改成 200 + 「如果该邮箱已绑定，链接已发送」，只在审计里记真实原因（前端不需要改）。这是 §13 的备选。

### 8.2 Token / 验证码

- 重置 token：32 字节随机（256 bit）、SHA-256 落库、30 分钟、单次、原子消费；放 URL fragment，不进 access log/Referer；页面读取后立即从地址栏清除。
- 验证码：6 位数字、10 分钟、5 次尝试、60s 重发、每日 10 条；Redis 存 `hmac_sha256(session_jwt_secret, user_id:code)` + 目标邮箱 + purpose（10 分钟 TTL），**不存明文验证码**。
  - **目标邮箱明文是必要例外**（确认时要写库），且只活 600s；token 表则用 `email_hash`（不需要回读邮箱）。两处口径不同，理由已写明，不是遗漏。
- 不在任何日志/审计中出现 token、验证码、完整邮箱。

### 8.3 邮箱冒用

- 只有验证码验证过的邮箱才可用于找回密码（D4）。
- 换绑需密码 + 新邮箱验证码；解绑需密码；两者都通知旧邮箱。
- 唯一索引保证一个邮箱只属于一个账号；管理员改邮箱也受约束。
- 管理员把邮箱填错的风险：**收件人确实可以重置该账号**——这是任何邮箱恢复通道的固有风险，前置「验证」并不能降低（验证链接也发到同一地址）。处置靠管理员录入准确性 + 审计 + 旧邮箱告知（若旧邮箱已验证）+ 用户/管理员发现后换绑；不能靠 D4 的旧口径假装解决。
- 未验证邮箱仍占用唯一索引：若管理员把 A 的邮箱录到了 B（未验证），A 自助绑定会 409；409 文案明确「如该邮箱属于你，请联系管理员解除其它账号的占用」，处置动作是管理员把 B 的 `email` 置空（`PATCH /admin/directory/users/{id}` 传 `email=null`）。
- **停用/离职账号的邮箱仍占唯一索引**：新员工绑不上被前员工占用的邮箱时，管理员先清空旧账号的 `email`（PATCH `email=null`；停用/离职账号可以直接清）。**在职且 `username IS NULL`** 的账号不能直接清：先用 `scripts/set_password.py --username <新名> --username-only` 补登录名（只改登录名，不重置密码），再 PATCH `email=null`（§13.9）。

### 8.4 会话失效

- 改密/重置后 `session_version++`，全部旧 JWT 立即失效；PAT 同时吊销。
- 邮箱换绑/解绑不踢会话（仍在密码保护下），但作废未用重置 token。

### 8.5 频控

- 登录锁与找回密码锁命名空间分离（D14）。
- 计数「首次才 EXPIRE」，避免越点越锁（§5.7.2）。
- 交互式 SMTP 同步发送 + socket 15s / 总预算 20s + 频控，控制线程池压力；另有进程级 `asyncio.Semaphore(4)` 限制在途发信数（配额是小时窗口，不是并发上限）。

### 8.6 仍存在的风险（如实记录）

| 风险 | 说明 | 处置 |
| --- | --- | --- |
| 邮箱本身被攻破 | 攻击者控制已验证邮箱 → 可重置密码 | 这是邮箱恢复通道的固有风险；换绑/重置都有审计与告知邮件；管理员可解绑/重置 |
| 共享 NAT 连坐 | 同一公网出口 5 次失败会锁整个出口 15 分钟 | 默认与登录锁一致；可调；后续可改 `(ip,email)` 双维度 |
| 存量邮箱未验证 | 不再阻塞找回密码（D4）；未验证只影响「已验证」Tag 与旧邮箱告知 | 上线公告引导用户登录后验证邮箱（可选）；运维逐条标记脚本（§9.3）仍可用于需要「已验证」状态的通知场景 |
| SMTP 出口/送达率 | 局域网环境可能封 25/465/587；QQ/163 可能进垃圾箱 | 上线前实测（§9.1）+ SPF/DKIM；失败时用户看到 502，不会假成功 |
| 公网入口不可用 | 邮件里的公网链接打不开 | 配 `EMAIL_LINK_BASE_URL_LAN` 作为双入口兜底；本功能要求公网/收件人可达入口，纯离线部署不支持（§9.1） |
| 同步 SMTP 延迟 | 最坏 20s 总预算（socket 15s × 多次操作，外层 wait_for 卡 20s） | 前端 30s 超时；频控限并发 |
| 回滚代码但保留唯一索引 | 老代码不捕获 IntegrityError，管理员改重邮箱会 500 | 回滚时同步 drop 索引或保留新代码（§9.4） |
| 回滚再前滚 | 旧代码签发的 JWT 无 `ver`，前滚后按 0 校验；已自增版本的用户会 401 一次 | 用户重登即可；不要在回滚期间把所有 `session_version` 归零（会削弱旧代码期间的安全性） |
| 邮件头注入 | 存量宽松地址/OIDC/notifications 可能带 `,;<>` | `send_mail` 自校验 + `Address` 构造；不安全地址拒绝发送（§5.6.1） |
| 重置后仍被登录锁挡住 | 用户试错 5 次后即使重置成功也可能 429 | 重置成功清 **user 维度**锁；IP 维度不清（否则匿名重置成为 IP 锁后门），按 15 分钟自然过期，应急用 `redis-cli DEL pwreset:lock:ip:<具体IP>` + `DEL pwreset:fail:ip:<具体IP>`（**带具体 IP，勿写 `pwreset:lock:ip:*`——`DEL` 不支持 glob 会静默无效**，见 §9.4；本批无风控页入口，§13.13）。另：重置只清 user 维度，某共享 IP 的 fail 计数若已达 4，重置后该 IP 首次口误会立即再锁 15 分钟（双维计数固有语义） |
| 重置链接“发送结果未知” | `wait_for` 超时后线程仍可能发出 | 超时保留 token、提示检查邮箱；用户重试会作废旧 token（§5.4.2 第 13 步） |
| 共享 NAT 小时配额 | 全公司同 IP 首日集中验证/重置可能撞 200/120/60 的每小时上限 | 值按 NAT 余量配置且可调（§5.10）；上线首日分批验证；真正的封控是 5 次失败锁（§5.7.3） |
| 枚举者用有效邮箱穿插成功请求 | 「成功清零 IP 失败链」会让 5 次锁失效 | 请求预算 120/h + 审计监控；R7 显式报错的必然代价（§8.1） |
| 已登录用户向任意未绑定邮箱发码 | 有密码的登录用户可把 `/email/code` 当发信器（10/天/人、200/h/IP） | 频控 + 审计 `email_verification_requested` 监控；若产品不接受，需收敛为「仅公司域/管理员预录」（会改变 R1 自助范围，另行确认） |
| 站内通知邮件随 SMTP 一起上线 | 填 SMTP 后审批/邀请通知会发给管理员手填的未验证地址 | `NOTIFY_EMAIL_ENABLED` 默认 false；开启前产品确认，建议只发给已验证邮箱；误发时单独关该开关 |

## 9. 部署与运维

### 9.1 SMTP 前置（阻断项）

> **开工前书面确认（硬前置）**：产品/运维确认 ① SMTP 服务商与发件地址；② hh2 → 465/587 出口实测；③ 公网 HTTPS 入口与证书（非自签）；④ SPF/DKIM/DMARC；⑤ 站内通知邮件是否同期上线（`NOTIFY_EMAIL_ENABLED`，默认 false）；⑥ 入口链路真实 IP 复验（W2a，ops-manual §11：三入口各打一条失败请求，确认审计/Redis 里 IP 是真实客户端 IP——R8 的 IP 封控以此为基础，未激活时 IP 维度退化为共享桶连坐）。未确认前不启动 R3/R4/R6/R7/R8 的开发与验收；若无法确认，本批范围降级为「仅邮箱绑定/解绑」（R1/R2/R9/R10），找回密码另立期。
>
> **产品前置确认**：本功能要求一个**收件人可达的 HTTPS 入口**（当前是公网 `bucket.taoxiplan.com`）；纯离线/无公网入口部署**不支持**，上线前由产品确认接受。LAN 链接只是双入口兜底，不能替代。

1. 选定服务商与发件邮箱（建议腾讯企业邮 / 阿里云邮件推送；发件地址须与 SMTP 登录账号同域）。
2. 配置域名 SPF/DKIM（按服务商控制台），必要时 DMARC；否则重置邮件大概率进垃圾箱。**HTTPS 证书必须被邮件客户端信任（非自签）**：自签证书会让链接被浏览器/客户端拦截。
3. **出口实测**（hh2 生产容器内）：

```bash
# 端口可达性（docker exec 默认不接 stdin，必须 -i）
docker exec -i ms-api python - <<'PY'
import socket
for host, port in [("smtp.exmail.qq.com", 465), ("smtpdm.aliyun.com", 465)]:
    try:
        s = socket.create_connection((host, port), timeout=10); s.close()
        print(host, port, "OK")
    except Exception as e:
        print(host, port, "FAIL", e)
PY
```

真实发信脚本 `send_test_mail.py` 依赖本方案的新代码；**只在 §9.3 第 2 步代码同步之后使用**（同步前它不存在）。选型阶段若必须在同步前验证，用一次性 `docker exec -i ms-api python -c '...smtplib 读 os.environ 发信...'`，不要把「脚本不存在」误判为「端口不通」。

4. 若 465/587 被封：优先申请出口放行；否则在局域网部署内部 SMTP 中继（`SMTP_HOST` 指向内网中继），并**同时配置 `EMAIL_LINK_BASE_URL_LAN`**（否则邮件能收到、链接在内网/公网不可用时打不开）；再否则改用服务商 HTTPS API（需另写一个 `mailer` 后端，超出本方案 v1）。

### 9.2 配置步骤（`.env` 不进 git）

路径按 `deploy_lan.sh:22-23` 的 `REMOTE_DIR` 口径：

| 环境 | `.env` 实际路径 |
| --- | --- |
| prod | `/home/huanhua/ms/api/.env` |
| dev | `/home/msdev/ms/api/.env` |

（`/root/ms/...`、`/root/material-storage-api/...` 是更早的旧路径，不要按它操作。）

```dotenv
EMAIL_AUTH_ENABLED=false            # 先关，迁移+重启后再开
NOTIFY_EMAIL_ENABLED=false          # 站内通知邮件独立开关；填 SMTP 不会自动打开
# 功能开启时必填；不回落 WEB_APP_BASE_URL；生产不得是内网地址（校验不通过则 mail_ready=false + ERROR，不阻断登录）
EMAIL_LINK_BASE_URL=https://bucket.taoxiplan.com/ms-static/web/
SMTP_HOST=smtp.exmail.qq.com
SMTP_PORT=465
SMTP_USE_SSL=true
SMTP_USE_TLS=false
SMTP_USERNAME=noreply@example.com
SMTP_PASSWORD=***
SMTP_FROM_EMAIL=noreply@example.com
SMTP_FROM_NAME=素材库
```

- dev 的 `EMAIL_LINK_BASE_URL` 用 `http://192.168.110.221:8090/ms-static/web/`（或公网 dev 入口）。
- **纯内网部署**：主链接仍填公网 https（本功能依赖公网入口可达）；同时配 `EMAIL_LINK_BASE_URL_LAN` 兜底内网。完全没有公网入口时本功能不可用（§8.6）。
- **`SMTP_FROM_EMAIL` 只填纯地址**（如 `noreply@example.com`）；显示名走 `SMTP_FROM_NAME`。不要把 `Name <addr>` 塞进 `SMTP_FROM_EMAIL`（启动校验会拒绝，功能降级为隐藏）。
- 改 `.env` 后必须 `docker compose up -d --force-recreate ms-api ms-worker`（`restart` 不重读 env_file）。

### 9.3 上线顺序（dev → prod）

0. **备份与对账**：SSH 到 hh2-prod 的 `/home/huanhua/ms/api`，在那里执行
   `COMPOSE_DIR=/home/huanhua/ms/api bash scripts/backup_prod.sh`
   （默认落 `${COMPOSE_DIR}/backups/pg`；要放 `/ssd/pg-backups` 先 `mkdir -p` 并 `chown huanhua`，否则脚本 `set -e` 会直接退出；脚本默认 `COMPOSE_DIR=/root/material-storage-api` 是旧路径，prod 必须显式覆盖；dev 用 `/home/msdev/ms/api`；**在开发机跑会打到本机 docker**）；
   再 `docker compose exec -T ms-api alembic current` 与 `docker compose exec -T ms-api alembic heads` 对账（宿主机不装 alembic/DB 驱动），确认线上在 `20261031_0020`（落后先补，不跨版本上代码）。
1. **纯 SQL 预检（代码同步之前）**：用 §4.4 的 `docker exec ms-db psql ...` 查重复邮箱；有重复先由管理员清空其一（`PATCH /admin/directory/users/{id}` 传 `email=null`）。**不要**在这一步跑依赖新代码的 Python 脚本。
2. 代码同步（`deploy_lan.sh <env>`，不带 `--restart`）；此时运行中的进程仍是旧代码，新文件只是落盘。
3. **先迁移**：`docker compose exec ms-api alembic upgrade head`（0021）。迁移内部的重复检测用 `text()`，不 import 新模型。
   - ⚠ 迁移完成到第 4 步 restart 之间，运行中的仍是旧代码：**窗口内暂停一切 email 写入**（管理员建号/编辑、CLI/seed、OIDC 登录）。旧代码不捕获 `IntegrityError`，此时写入重复邮箱会撞新唯一索引 → 500。
4. 重启 API/worker：`docker compose restart ms-api ms-worker`。
5. 构建/替换 SPA（`pnpm build` + tar 单独同步；`deploy_lan` 不同步 `static/web`）。
6. 填 `.env`（SMTP/EMAIL_*，**`NOTIFY_EMAIL_ENABLED=false`**）。**先预检再 recreate**（必须用 `docker compose run`，它会按当前 `.env` 新建一次性容器；**`docker exec` 继承的是运行中容器的旧环境，读不到刚改的 `.env`**）。注意：`.env` 里开关还是 false 时 `resolve_mail_ready()` 会直接返回 false 并跳过校验，所以要**显式覆盖开关**才有诊断意义：
   ```bash
   docker compose run -e EMAIL_AUTH_ENABLED=true --rm --no-deps ms-api python -c \
     "from app.settings import get_settings; print('mail_ready=', get_settings().resolve_mail_ready(detail=True))"
   ```
   输出 false 时看日志 `email auth disabled: invalid config: <原因>`，别急着 recreate → `up -d --force-recreate ms-api ms-worker`（不是 restart）。
7. 容器内发测试邮件：`docker exec -i ms-api python -m scripts.send_test_mail`（收件人从 stdin/交互输入，见 §9.5）→ 确认收到；此时 `EMAIL_AUTH_ENABLED=false`，`GET /auth/public-config` 的 `password_reset_enabled` **应为 false**（若为 true，说明开关提前打开了，回退第 6 步）。
8. `EMAIL_AUTH_ENABLED=true` → 再次 `up -d --force-recreate ms-api ms-worker`；检查日志**没有** `email auth disabled: invalid config`（有则是配置不合法，功能被降级隐藏，登录不受影响）。
9. 三入口指纹一致 + `GET /auth/public-config` 返回 `password_reset_enabled=true`；登录页刷新可见「忘记密码」。
10. 存量邮箱处理：
    - **默认**：保持未验证；发布公告「邮箱已可用于找回密码；建议登录后在 设置 → 账号安全 中验证邮箱（用于接收变更告知）」；**同 NAT 的办公室按部门分批，避免首日集中验证撞每 IP 每小时配额**。
    - **逐条标记**（仅当已线下核对归属）：
      `docker exec -i ms-api python -m scripts.mark_email_verified --username <u>`
      执行后在 stdin 输入完整邮箱确认（避免进 shell history）；比较按 `strip().lower()`；每次只处理一个账号；脚本写 `email_verified` 审计，`details={"source":"ops","verified_by":...,"email_masked":...}`。**不提供**按日期/通配批量档（D16）。
11. App 发版（本批版本，预期 0.1.14+18，以 `release.mjs` 输出为准）。旧版 App 仍可登录/使用；改密后会被强制回登录页（§7.4），不能承诺「无感」。

### 9.4 回滚

| 场景 | 动作 |
| --- | --- |
| SMTP 故障/误发 | `.env` 设 `EMAIL_AUTH_ENABLED=false` → `up -d --force-recreate`；前端发信入口消失，**发信类**端点全部 503（含 verify/confirm，存量链接一并作废）；`/email/unbind` 仍可用。**若是站内通知邮件误发**：设 `NOTIFY_EMAIL_ENABLED=false`（或清空 `SMTP_HOST`/`SMTP_FROM_EMAIL`）再 force-recreate——只关 `EMAIL_AUTH_ENABLED` 止不住通知邮件 |
| 代码回滚 | 先设开关 false，再回退代码。**回退前必须轮换 `SESSION_JWT_SECRET`**：新代码已把改密/重置用户的旧 JWT 作废，旧代码不校验 `ver`，不轮换会让被作废（可能被窃）的 cookie 在 7 天内重新有效。轮换代价=所有人重登一次。**若保留 0021 迁移，唯一索引仍在**：老代码管理员改重邮箱会 500；要么保留新代码，要么执行 `alembic downgrade 20261031_0020`（会删新列/表/索引） |
| 数据修复 | 重置 token 表可整体清空（`DELETE FROM password_reset_tokens`）；Redis 键用 `docker exec ms-redis redis-cli --scan --pattern 'pwreset:*' \| xargs -r -I{} docker exec ms-redis redis-cli DEL {}`（`DEL` 不支持 glob，直接写 `pwreset:*` 什么都不会删；宿主机不一定装 redis-cli，所以两端都在容器内）；`email:*` 同理，确认不误删其他命名空间。 |

**上线后 24h 内做一次回滚演练**：开关置 false → 确认公开配置返回 false、现有链接 verify 返回 503 → 再打开。确认开关链路真的能止血，而不是只在文档里存在。

**回滚硬顺序**（若需要 downgrade）：设开关 false → **`docker compose stop ms-api ms-worker`** → 用新代码/迁移文件执行 `docker compose run --rm --no-deps ms-api alembic downgrade 20261031_0020` → 回退代码 → 轮换 `SESSION_JWT_SECRET` → `up -d --force-recreate ms-api ms-worker`。
- **必须先停 API/worker 再 downgrade**：downgrade 会删 `session_version` / `email_verified_at`，新代码还在线时任意认证请求会 500（`load_active_user` / `/me`）。`EMAIL_AUTH_ENABLED=false` 不会停掉 `get_current_user`。
- 不要先回退代码再 downgrade（旧代码里没有 0021 迁移文件，alembic 找不到 revision）。
- 24h 回滚演练要覆盖「需要 downgrade」这一分支，而不只是开关置 false。

### 9.5 运维脚本

| 脚本 | 用途 |
| --- | --- |
| `api/scripts/check_email_duplicates.py` | 只读：重复/空串/大写/非法邮箱统计（脱敏输出） |
| `api/scripts/send_test_mail.py` | 用当前 settings 真实发一封测试邮件；收件人从 **stdin/交互输入**（`--to` 仅作可选、文档示例用占位符），日志脱敏 |
| `api/scripts/mark_email_verified.py` | 运维逐条标记已验证：`--username`/`--user-id`；**交互式提示输入完整邮箱**（不带 flag，或 `--confirm-email -` 从 stdin 读，避免完整邮箱进 shell history），与库里当前值按 `strip().lower()` 完全一致才执行；**执行前用 `strict_validate_email` 校验，不合法直接报错并提示先换绑**（否则置了已验证也过不了 reset 的 Pydantic 校验）；写审计 `email_verified`（`source=ops`、`verified_by`、`email_masked`）。**无批量/日期范围档**（D16） |

月度清理（ops-manual 收录；低量环境也可不跑，但表会长期增长）：

```sql
DELETE FROM password_reset_tokens
 WHERE expires_at < now() - interval '30 days';
```

> `scripts/set_password.py` 新增 `--username-only`（只改登录名，不动密码/PAT/会话版本）；改登录名/清邮箱的运维路径见 §4.4/§8.3。

### 9.6 文档

- `rushes-spec/material-storage/ops-manual.md` 新增 §13「邮箱与找回密码」：SMTP 配置、出口测试、SPF/DKIM、开关、回滚、常见故障（502/进垃圾箱/链接打不开）。
- `scripts/changelog.md` 记录本批用户可感知变更。

## 10. 测试与验收

### 10.1 API 测试（新增 `tests/test_email_account.py`、`tests/test_password_reset.py`，改造既有 auth 测试）

> **测试前置**：默认测试环境没有 SMTP 配置，`app.state.mail_ready=false` 会让所有新端点 503。新测试的 fixture 必须显式 `app.state.mail_ready = True`、monkeypatch `settings.email_link_base_url` 并注入 FakeMailer；「开关 false → 503」单独作为一条用例（覆盖 `mail_ready=false`）。
> 三个易踩点：(a) `make_user` 默认 `must_change_password=True`，新 `/email/*` 会先被 403，测试用户必须显式 `must_change_password=False`；(b) `app.state.mail_ready` 是 session 级 app fixture 上的可变状态，赋值后要 `try/finally` 恢复，避免跨模块污染；(c) 现有 `test_local_auth.py` 的 FakeRedis 没有 `eval`，Lua 计数测试要么扩展 FakeRedis，要么用真 Redis。
> (d) **Redis 键隔离**：新测试必须加 autouse fixture，在用例前后清 `pwreset:*` / `email:*`（至少 `127.0.0.1`、`testclient` 与本用例用户 id）；否则「5 次失败锁」会以 900s TTL 污染同容器后续所有 reset 用例。触发锁的用例放最后并在 `finally` 清理。

**邮箱绑定/换绑/解绑**
- 正常绑定：正确密码 + 正确验证码 → `email` 落库（小写）、`email_verified_at` 非空、审计 `email_verified`。
- 密码错误 → 400、计数 +1；连续 5 次 → 429；成功一次后计数清零。
- 验证码错误 5 次 → key 删除、正确码也 400；重新获取后可继续。
- 验证码过期（手动删 key / 改 TTL）→ 400。
- 目标邮箱被他人占用 → 409；并发窗口（确认前被抢）→ 409 且不改库。
- **两个账号并发 confirm 同一邮箱 → 一个 200、一个 409（唯一索引 + IntegrityError 兜底）**。
- 目标与当前相同且已验证 → 400；未验证 → 走验证流程成功；**存量非法格式邮箱 → 422/400，要求先更换邮箱（不做宽松兼容）**。
- **`purpose=bind` 的目标已被他人占用/与别人 username 冲突 → 409（发码阶段就拦，不向陌生人发码）**；`purpose=verify` 即使与别人 username 冲突也不 409（存量问题由预检处理）。
- **`purpose=verify` 不会作废手里已有的重置 token**（邮箱值没变）。
- **目标与某个账号的 `lower(username)` 相同 → 409（跨列冲突）**。
- 管理员建号/编辑把邮箱设成他人已占用（含大小写变体）→ 409，不是 500；管理员改邮箱后 `email_verified_at` 清空、未用重置 token 被删。
- `set_password.py --username` 传含 `@` 或与别人 email 冲突 → 拒绝（不写入）。
- OIDC 新建/同步把邮箱改成新值 → `email_verified_at` 清空；目标被他人占用 → 跳过写入/建号用 NULL，不 500。
- 换绑成功 → 旧邮箱收到告知（FakeMailer 断言）、旧邮箱已验证时才有；审计 `email_changed`。
- 解绑：密码错误 400；成功清空 + 审计 + 告知；未绑定 → 400；**`username IS NULL` → 400 拒绝**。
- 功能开关：`mail_ready=false` 时 `/email/code`、`/email/confirm`、`/password-reset/*` → 503；**`/email/unbind` 仍 200**（仅 Redis 故障 503）。`purpose` 在 bind/change/verify 三种场景取值正确；每 IP 验证码配额 `EMAIL_CODE_HOURLY_PER_IP`（默认 200）生效且成功才计数。
- 每用户 code 请求预算 30/h：第 31 次 429；**409 占用尝试也计数**（防高速枚举）；confirm 复核占用时排除本人（`id<>:me`），未验证用户点「验证邮箱」不会误 409。
- 60s 冷却（`SET NX`）：60s 内第二次 → 429；日配额 10 条：第 11 条 → 429；SMTP 结果未知 → 写入新码、可继续用新码确认；**确定失败 → 不写新码、旧码保留**（若之前有码）。

**忘记密码**
- 不存在邮箱 → 400 + `pwreset:fail:ip` +1；第 5 次后第 6 次 429；成功申请后 fail 清零。
- **未验证邮箱也能申请重置并成功**：确认后 `email_verified_at` 由空变非空（D4）。
- 正常申请 → DB 有 1 条 token（只存 hash，`request_ip`/`user_agent` 已写）、邮件捕获的链接含 fragment token、审计 `password_reset_requested`（`actor_user_id=None`）。
- **并发/交错申请**：双击/两个标签页同时申请 → 冷却 `SET NX` 只放行一个，另一个 429；用阻塞 FakeMailer 让 A 的发送悬停、期间发起 B，最终恰好 1 条有效 token（B 被冷却挡下）。
- verify：有效 token → 200 + 脱敏邮箱；过期/已用/不存在 → 400；开关关闭 → 503。
- confirm：成功 → 密码可登录、`must_change_password=false`、`session_version` +1、旧 cookie 401、PAT 全部吊销、token `used_at` 非空、审计 `password_reset_completed`；开关关闭 → 503。
- 二次 confirm → 400。
- 密码策略失败/新旧相同 → 400，token 未被消费；**`password_hash IS NULL` 的账号 → 允许首次设密并成功登录（不是 400/500）**。
- **重置成功立即解锁（仅 username/email 两形态）**：先用错误密码把 user 锁打出来，再走邮箱重置 → 新密码登录立刻成功；**同时断言匿名重置不会清 `auth:lock:ip`**（IP 锁仍在），也不会清同名用户的 `name` 形态锁。
- 请求预算：同一 IP 每小时**第 121 条**格式合法的申请 → 429，且不写审计、不查库；同一 IP 每小时**第 61 条发信**（已查库、已过请求预算）→ 429 并写审计；停用账号与不存在同文案、计入 IP 失败。
- 并发 confirm（两请求）→ 只有一个成功。
- SMTP 确定失败 → 502、token 行被删、发信配额未消耗；**超时（结果未知）→ 502 但 token 保留**；两种情况冷却都生效。
- 429 响应带 `Retry-After` 头。
- IP 锁只影响 reset 端点：同一 IP 被锁后登录仍可用。
- 改密/管理员重置/`set_password.py` 后，未用 token 被删除。
- `email_hash` 与当前邮箱不一致（模拟申请后换绑/解绑）→ 400「邮箱已变更」。
- 4KB `User-Agent` 申请 → 200（落库截断 `[:512]`，不 500）。
- 确定 SMTP 失败只删**本次新 token**，旧 token 仍可用；成功后旧 token 被删；结果未知新旧都保留。

**审计**
- `auth_method="anonymous"` 的重置事件：管理端选 `anonymous` 能筛到、选 `session` 不含它；CSV 原样输出。
- `email_verification_requested` / `email_verified` / `email_changed` / `email_unbound` 的 `actor_email_snapshot` 是脱敏值（新增 override 参数生效；`email_verification_requested` 用当前邮箱），不是完整邮箱。
- 新事件的 details key 集符合 §5.9；`password_reset_failed` 在 token 无效时允许无 `email_masked`。

**会话版本**
- `GET /auth/public-config` 在 `mail_ready=true/false` 两种状态下的返回正确；`mail_ready=false` 时发信端点 503、`/email/unbind` 仍 200。
- `pwreset:confirm:ip` 第 151 次 verify/confirm → 429（含 `Retry-After`）。
- `disable` 后 `session_version` +1、未用 reset token 被删、`email:code` 被删；重新启用后旧 JWT 仍 401。
- `set_initial_admin` / `set_password.py` 改密后自增版本并删未用 token。
- OIDC 同步改邮箱后 `email:code` 被删、审计有 `email_changed(source=oidc)`、`email_verified_at=NULL`；`test_oidc_service.py` 的 FakeSession 补 `rollback`。
- `AdminUsersPage` 未改邮箱时不发送 `email` 键（`PATCH {"name":...}` 不触发校验/清理）。
- 旧 JWT（无 `ver`）在迁移后仍可用；**`ver` 为 `null` 也按 0**（transient User 签的 JWT 不 500）。
- 改密后同一 cookie 401；管理员重置目标密码 → 目标旧 cookie 401；管理员自己不受影响。
- `scripts/set_password.py` / `set_initial_admin.py` 改密后目标旧 cookie 401。
- dev `X-User-Id` 通道不受版本影响。
- `GET /auth/me` 返回 `email_verified`，绑定/换绑/解绑/管理员改邮箱后值正确。
- 既有测试同步（§5.5.1 第 8 步）：`test_local_auth_integration.py` 改密后 `/me` 断言与 `test_forced_change_blocks_other_endpoints`、`test_mcp_auth_chain.py` monkeypatch 签名、`test_directory.py` transient User、`test_oidc_service.py` 的 FakeSession 查询顺序。

**Schema**
- `test_db_schema.py` 表名集合加入 `password_reset_tokens`；断言 `users.session_version/email_verified_at` 与 `uq_users_email_lower` 存在（metadata 级）。
- `tests/test_local_auth.py:206-211` 用 `Base.metadata.create_all(tables=[User.__table__])` 在 SQLite 真实建表：索引可建；注意 SQLite 忽略 `postgresql_where`（空串 `''` 会被纳入唯一索引），所有写入路径必须把空串归 NULL，测试不要插入两条 `email=''`。

**补充分支（易漏）**
- `must_change_password=true` 时 `/email/code`、`/email/confirm`、`/email/unbind` → 403（白名单不放行）。
- OIDC-only（`password_hash IS NULL`、`oidc_sub` 非空）：不能自助验证/解绑；管理员清空其邮箱允许（有 IdP 登录）。
- `mark_email_verified.py`（严格正则/大小写比较）、`check_email_duplicates.py`（纯 text、脱敏）。
- 迁移跨列冲突（`lower(username)==lower(email)`）→ `RuntimeError`。
- `EMAIL_LINK_BASE_URL_LAN` 配置后邮件正文含两条链接；非法 `resolve_mail_ready` 配置 → `mail_ready=false` + 原因。
- `change-password` / 管理员重置后 `email:chg:fail/lock` 被清、`email:code` 被删。
- 254 字符邮箱的 `mask_email` 不超 255。
- `mail_semaphore` 占满后第 5 个请求 → 20s 内 429/503，FakeMailer 未被调用（不补发）；**发送超时后槽不提前释放**：用阻塞 FakeMailer 让 4 个在途发送超时，第 5 个请求立刻 429/503，直到 FakeMailer 线程真正结束、槽释放后才放行（验证 shield + done_callback 语义）。
- 新端点 Redis 故障 → 503（`RateLimitUnavailable`），不是 500/静默放行。
- 每账号每小时第 6 条重置邮件 → 429（`send_quota_user`）；锁/计数 TTL 到期后恢复。
- `set_password.py --username-only`：只改登录名，密码/PAT/`session_version` 不变。
- 重置 confirm 后 `email:chg:fail/lock` 被清。
- **PG 实测改为必测（不是可选）**：在容器内跑 `alembic upgrade head` 后，验证 `lower(email)` 唯一索引对「大小写重复」「NULL 多行」「空串归 NULL」三种插入的行为。
- 迁移重复检测：构造两条同邮箱数据 → 迁移抛 `RuntimeError` 且 DB 停在 0020（不建索引）。

**邮件**
- `mailer` 单测：`From` 显示名、中文主题、`To` 含 `, ; < > "` / 控制字符被 `MailSendError(definite=True)` 拒绝、`From`/`To` 都经 `Address` 构造、日志不含完整邮箱。
- 确定失败 vs 超时：连接拒绝 → `definite=True`；`wait_for` 超时 → `definite=False`；调用方按两者决定删不删 token。
- notifications 路径遇到不安全地址 → 跳过 + 脱敏 log，不影响主流程。
- **既有 `tests/test_notifications_service.py:181-238` 直接测 `_smtp_send_sync`**：B1 改走 `mailer.send_mail` 时同步迁移/重写（TLS/SSL/login 三个分支），否则这两条会红。
- 全部测试用 FakeMailer / monkeypatch，不连真实 SMTP。

### 10.2 Web

- `pnpm build` + `pnpm lint` 通过。
- 手工验收：
  1. 功能关闭：登录页无「忘记密码」；**无邮箱用户的设置页无邮箱区；已有邮箱用户仅显示「解除绑定」**（解绑不依赖 SMTP）。
  2. 功能开启：登录页入口可见；未绑定邮箱 → 400 文案；**未验证邮箱也能收到链接，重置成功后变为已验证**；已验证 → 收到邮件。
  3. 5 次不存在邮箱 → 第 6 次 429 + 倒计时。
  4. 邮件链接打开 → 显示脱敏邮箱 → 设新密码 → 成功 → 回登录 → 新密码可登录。
  5. 链接二次打开 → 失效。
  6. 重置后原浏览器旧会话下一次点击被踢回登录（`?next=` 保留）。
  7. 设置页：绑定 → 未验证 → 验证 → 换绑 → 解绑 全链路；Tag 状态正确。
  8. 移动端 compact 布局不溢出（卡片/弹窗/按钮）。
  9. 改密成功 → 回登录并提示，不再自动停留在站内。
  10. **部署态验收**：`EMAIL_AUTH_ENABLED=true` 但 `EMAIL_LINK_BASE_URL` 缺失/内网/非 https（生产）或 SMTP 未配 → 后端**不崩**，日志出现 `email auth disabled: invalid config`，公开配置返回 false、端点 503，**登录仍正常**；合法配置 → 公开配置 true。
  11. 重置页地址栏只有 `#token=...` 被清理后的 URL；`?token=` 不被读取；手工粘贴 token 可用。
  12. **会话失效验收必须用账号密码登录，不能用 `/dev-login`**：dev 的 `X-User-Id` 通道不校验 `session_version`（`deps.py:160-169`），用它验收「改密/重置后被踢出」会得到假绿。
  13. **dev 种子邮箱**：`dev_bootstrap.py` 给 alice/bob 的邮箱直接置 `email_verified_at=now()`（dev-only），本地验收不必先跑 `mark_email_verified`；prod 种子仍保持未验证。

### 10.3 App

- `flutter analyze` 0 issue；`flutter test` 全绿。
- 新增 widget 测试：
  - 登录页「忘记密码」显隐（config true/false）。
  - 忘记密码页提交成功/失败文案。
  - 邮箱页三态按钮 + 验证码流程（FakeMsApi staged）。
  - 改密成功 → `logout()` 被调用且回到 `/`（改造既有 `session_change_password_stale_test.dart`）。
- 新增用例：
  - **502/503 不跳全局报错页**：忘记密码页提交 SMTP 失败/功能关闭 → 页面内失败卡片出现（靠 `noErrorReport`），`/error-report` 不被 push。
  - `/forgot-password` 与 `/account/email` 路由可达（`app.dart` 已接线）。
  - 绑定/换绑/解绑成功后 `Session.me` 刷新，「我的」页状态变化。
- 真机验收（Android + iOS 至少各一台）：
  1. 登录页入口 → 忘记密码 → 收到邮件 → 浏览器完成重置 → 回 App 用新密码登录。
  2. 重置后 App 旧会话下一次请求自动回登录页。
  3. 绑定/换绑/解绑全链路 + 未验证状态展示。
  4. 内网入口与公网入口各走一遍（邮件链接始终是公网 URL）。

### 10.4 跨端验收硬项

- 同一邮箱两个账号：第二个绑定 409；DB 唯一索引实测。
- 重置后：Web 其他标签页、App、MCP PAT 全部失效（PAT 用一次请求验证 401）。
- 审计页（Web + App）能看到 7 个新事件，筛选正常，CSV 导出正常；计数注释与新实数一致。
- 本批新增日志/审计无完整邮箱、无验证码、无 token（既有本地登录日志里的 username 输入不在本批范围；OIDC 告警日志本批一并脱敏）。
- `NOTIFY_EMAIL_ENABLED=false` 时**不发送**站内通知邮件（审批/邀请）；置 true 后才发。开启前确认收件地址可信。
- **真实 IP 验收**：三入口（内网 / 公网 HTTPS / 跳板机端口）各产生一条 `local_login_failed`，审计 `request_ip` 是真实客户端 IP，不是容器/网关 IP。R8 的 IP 封控完全建立在这个前提上（W2a 已于 2026-10-19 激活并过 §11.6 四条验收，状态正本=ops-manual §11；**每次入口链路变更（反代/隧道/端口）后必须复验**，上线前置见 §9.1 ⑥；未激活时 IP 维度退化为共享桶连坐，见 §8.6）。

## 11. 实施顺序（建议拆 6 包）

| 包 | 内容 | 依赖 |
| --- | --- | --- |
| B1 基建 | settings + `mailer.py` + `notifications.py` 改造 + 迁移 0021 + 模型 + `test_db_schema` + **最小写入守卫（管理员/OIDC 的 `lower()` + `IntegrityError→409`）** | 无。**B1 不可单独发布**：只上唯一索引而没有守卫，会让旧/新代码的管理员改重邮箱 500 |
| B2 邮箱绑定 | `email_utils.py` + `email_verification.py` + 3 个 session 端点 + 测试 | B1 |
| B3 找回密码 | `password_reset.py` + 3 个公开端点 + `session_version`（deps/auth/directory 改造 + **`set_password.py`/`set_initial_admin.py` 两脚本的自增+删 token 改造**）+ 测试 | B1 |
| B4 Web | 登录页/忘记页/重置页/设置页 + 路由豁免 + hooks/types + 改密行为 + **AdminUsersPage `email_verified` Tag（含「未改邮箱不发送 `email` 键」与 types.ts `email_verified` 标可选，§5.3.5/§6.4）** | B2/B3 |
| B5 App | 登录页入口 + 忘记页 + 邮箱页 + Me 模型 + 改密行为 + 测试/发版 | B2/B3 |
| B6 运维 | 三个脚本 + ops-manual §13 + `.env.*` 模板 + changelog + 部署验收 | B1-B5 |

依赖关系：B2 与 B3 可并行（共用 `mailer`/`email_utils`），但 B3 的 `session_version` 会改 `deps.py`/`auth.py`，与 B2 不冲突。

## 12. 风险与实施钉子

1. **先测迁移**：`0021` 会在生产真实数据上建唯一索引；线上必须**先**跑 `check_email_duplicates`，有重复先清。迁移里重复即 `RuntimeError`，不会半途建索引。
2. **生产迁移顺序**：代码同步 → `alembic upgrade head` → restart。新代码打旧 schema 会 500（`session_version` 列缺失）。
3. **改 `.env` 必须 force-recreate**：`restart` 不重读 env_file；否则 SMTP 永远不生效。
4. **SPA 单独部署**：`deploy_lan` 不同步 `static/web`；忘记密码/重置页是新增路由，必须单独 tar 替换，且三入口指纹一致。
5. **前端 401 豁免**：新公开页必须加入 `AppShell.onAuthPage` 与 `client.ts` 的 401 白名单，否则匿名访问会整页跳登录循环。
6. **业务失败别用 401**：验证码错/密码错/邮箱被占都用 400/409/422，否则两端拦截器会误判会话过期。
7. **改密后别刷新 `me`**：版本已自增，刷新必 401；Web 清缓存回登录，App 主动 logout。
8. **计数不要每次 EXPIRE**：只在 INCR 返回 1 时设 TTL，否则 429 自续锁（百度频控旧坑）。
9. **邮箱一律小写入库**：登录按 lower 匹配、唯一索引按 lower；管理员/OIDC/seed 三条写入路径都要归一。
10. **审计脱敏**：`details` 与日志禁止完整邮箱/验证码/token；`notifications.py` 现有失败日志要顺手改脱敏。
11. **审计映射三处同步**：web `AdminAuditPage.tsx`、`labels.ts`、App `audit_labels.dart`；计数注释与附录 A 一起改。
12. **`test_db_schema.py` 表集合**：新增表必须同步，否则 CI/容器测试红。
13. **重置 token 单次**：必须用 `UPDATE ... WHERE used_at IS NULL RETURNING` 原子消费，不能先 SELECT 再 UPDATE。
14. **换绑通知旧邮箱只在旧邮箱已验证时发**：避免把告知邮件发给管理员录错/未验证的地址。
15. **`email_link_base_url` 必须公网可达**：App 走内网入口时请求 Host 不可用于拼链接；链接固定用配置值。
16. **回滚与唯一索引**：老代码不捕获 `IntegrityError`，回滚代码但保留索引会让管理员改重邮箱 500；按 §9.4 处理。
17. **同步 SMTP 的线程池**：两段预算——拿槽 `timeout(2)`（拿不到=确定未发，429/503）、发送 `wait_for(asyncio.shield(send_task), 20)`（超时=结果未知，保留 token；**裸 wait_for 会 cancel 掉发送 task → done_callback 提前放槽**，见 §5.6.3）；槽在发送线程真正结束后释放（`add_done_callback`）；**发送 task 进 `app.state.mail_tasks` 强引用集合**（事件循环对 task 只持弱引用，孤儿 task 被 GC 会永久泄漏槽位）。`app.state.mail_semaphore = Semaphore(4)`；不要把它改成无界重试。配额是小时窗口，不能当并发上限。
18. **存量非法格式邮箱**：上线后仍可能有少量管理员录入的非法地址（严格正则不过）无法自助验证/找回；提前准备公告与管理员换绑话术（未验证/未格式化不再阻塞合法邮箱的找回，D4）。
19. **配置不合法要降级，不要拖垮全站**：`mail_ready=false` + ERROR 日志 + 入口隐藏，登录保持可用；`raise` 会让一个链接拼写错误把全站打进容器重启循环。runbook 用 `resolve_mail_ready()` 预检。
20. **Lua 原子计数**：裸 `INCR` 后再 `EXPIRE` 会留永不过期的孤儿键（进程中途死），累积到阈值即永久封 IP；统一走 `rate_limit.incr_with_ttl`。
21. **并发 token 收口**：冷却键 `SET NX EX 60` 必须在签发前占位（同一用户 60s 内只有一次申请）；advisory lock 只负责 INSERT 串行；成功后只删**更旧**的未用行。不要让两个并发申请各自“删旧+插新”，否则会互相删光。
22. **总预算**：`smtplib` 的 socket timeout 不是总时长；必须 `asyncio.wait_for` 卡总预算（20s < 前端 30s），否则会出现「前端报超时、后端仍发信、用户重试导致重复邮件」。
23. **CLI 改密**：`scripts/set_password.py` / `scripts/set_initial_admin.py` 也要 `session_version += 1` 并删除未用重置 token；否则应急重置后旧 JWT 仍可用 7 天，正好是 D6 要消灭的场景。
24. **老 App 改密**：版本自增后，旧版改密成功会调 `me()` → 401 → 清会话回登录，属预期；不要把它当 bug 去回滚 `session_version`。
25. **预检不能 import 新模型**：代码同步后容器内已是新代码，`select(User)` 会 SELECT 新列撞旧 schema；预检用 psql/纯 `text()`。
26. **迁移前备份 + 回滚演练**：§9.3 步骤 0；上线 24h 内验证开关真的能止血（§9.4）。
27. **公开配置与端点同源**：所有显隐与 503 都读 `mail_ready`，不要一处读 env、一处读 `smtp_enabled`，否则又会出现半死入口。
28. **mailer 自己校验收件人**：不能信任调用方（notifications 的 `user.email`、OIDC 写入、存量宽松地址都可能带 `,;<>`）；`To` 必须用 `Address` 构造并拒绝头部危险字符。
29. **不存在邮箱探测要有请求预算**：失败计数只记 not_found/inactive，但查库前的 `pwreset:req:ip` 上限必须存在，否则公开端点可被无限探测/刷审计。
30. **重置成功只清 user 维度锁**：给 `LocalAuthService.clear_locks` 增加 `*, include_name: bool = True`（默认保持现有三形态调用；共享方法，别改坏 `directory.py`），重置 confirm 显式传 `False`。**绝不清 `auth:lock:ip`**（匿名重置清 IP 锁 = 给登录爆破开后门）；IP 维度按 15 分钟过期或 ops `redis-cli` 应急。
31. **`.env` 路径**：prod `/home/huanhua/ms/api/.env`、dev `/home/msdev/ms/api/.env`；不要照旧路径 `/root/...` 操作。
32. **`password_hash IS NULL`**：允许邮箱重置首次设密；不要直接拿 `None` 去 argon2 verify（会抛非预期异常变 500）。
33. **transient 对象的 `session_version`**：`scripts/set_initial_admin.py` 的 `User(...)` 未 flush 时是 `None`；统一 `(or 0) + 1`。
34. **验证码 hash 的 TTL**：`HINCRBY attempts` 后若 key 恰好过期会造出只含 attempts 的永久 hash；用 Lua 把 `HSET/HINCRBY` 与 `EXPIRE` 原子化，且 **EXPIRE 仅在 TTL<0 时补 600s、错误尝试不续期**（key 不存在返回 missing，不造新 key）。
35. **重置页无壳**：`/forgot-password`、`/reset-password` 要在 `AppShell` 无条件放行，不能只在 `!me` 时放行；否则已登录浏览器点邮件链接会看到顶栏。
36. **配置请求失败不要藏入口**：只有明确 `false` 才隐藏，`unknown` 保留链接，避免登录页唯一恢复入口因一次网络抖动消失。
37. **App 5xx 不跳全局报错页**：新 AuthApi 方法（含 public-config）必须 `Options(extra: {'noErrorReport': true})`，否则 502/503 会整页跳 `/error-report`，页面失败卡片永远不出现。
38. **UA 截断**：`password_reset_tokens.user_agent` 写库前 `[:512]`；4KB UA 必须 200。
39. **`email_hash` 快照**：confirm 必须比较 token 签发时的邮箱哈希与当前邮箱哈希；并发改邮箱/解绑后旧链接要失效，不能只靠 DELETE 的时序。不存完整邮箱（PII 最小化）。
40. **跨列预检**：`lower(username)` 与 `lower(email)` 的跨用户冲突必须在迁移前查；`set_password.py --username` 禁 `@` 并查跨列占用。
41. **auth_method 筛选链**：`admin.py` 的 `Literal` + web `AUTH_METHOD_OPTIONS`/`authMethodParam`/行内 label 一起改；App 无此筛选，别照抄。
42. **token 替换顺序**：先插新行（旧行暂留）→ 发信 → 成功再删旧行；确定失败只删新行；结果未知新旧都留。
43. **actor 快照脱敏**：`audit.write` 加 `actor_email_snapshot` override；**四个**新邮箱事件（`email_verification_requested` / `email_verified` / `email_changed` / `email_unbound`）都传 masked，避免快照列写完整邮箱。
44. **Web 全局 toast 去重**：新 hooks 带 `meta.silent`，全局 onError 跳过；否则 400/409/422/502 双弹。

## 13. 遗留项（不在本批）

1. **App 深链**：`app_links` + Android intent-filter（`https://bucket.taoxiplan.com` 的 App Links 需 `/assetlinks.json` + 签名 SHA256）或自定义 scheme（QQ/企业邮箱可能不可点）+ iOS Universal Links（AASA + Team ID）。工作量大，单独立项。
2. **防枚举模式**：把「不存在/停用」统一成 200 泛化文案，只在审计记原因；改一个分支即可，前端无需改 UI。
3. **共享 NAT 的 IP 锁改良**：改为 `(ip,email)` 双维度或提高阈值；需先观测真实出口 IP 分布。
4. **邮件 HTML 模板 / 品牌化**：需要模板引擎与转义，v1 纯文本足够。
5. **（本批已并入，保留编号防引用漂移）** 管理员目录显示邮箱验证状态：`DirectoryUserOut.email_verified` + `AdminUsersPage` 列表/详情 Tag。
6. **OIDC 可信标记**：本批只做最小改造（lower、冲突跳过/捕获 `IntegrityError`、改邮箱清 `email_verified_at` + 删 token，§5.3.5）；把可信 IdP 邮箱直接标记已验证留到后续。**注意**：若把最小改造也推迟，唯一索引会让 OIDC 的大小写重复写入 500，所以 OIDC 开启期间必须先做最小改造。**OIDC-only 用户**（`password_hash IS NULL`）无法通过 `/email/code`（要求当前密码）自助验证邮箱、也无法自助解绑；**但可以走邮箱重置**（D4：重置即验证 + 首次设密），重置成功后即可用本地密码登录，再用密码走邮箱操作。公告/支持话术按此写。
7. **登录名/邮箱双因子**：不在本期。
8. **重置邮件退信处理**：当前无退信（bounce）解析；SMTP 层失败可见，异步退信不可见。量小可暂不处理。
9. **管理员编辑 `username`**：没有可用非邮箱登录方式的账号（`username` 为空且 OIDC 未启用/无 `oidc_sub`）解绑邮箱会被 §5.3.4 拒绝；本批用 `scripts/set_password.py --username <新名> --username-only` 作为运维路径（不重置密码）。管理后台的 username 编辑入口仍留到后续，避免把「改登录名」做成日常自助操作。
10. **收敛既有审计里的完整邮箱**：`audit_events.actor_email_snapshot` 与管理员 `user_updated` 的 `changes.email` 仍是明文；本批只保证新增事件脱敏，存量口径另批处理。
11. **重置结果页的「去登录」在已登录其它账号时**：`AppShell` 会把已登录访问 `/login` 的人送回 `/`；重置成功页本身已展示结果，不影响主流程。
12. **存量非法格式邮箱**：管理员历史上录入的、过不了严格正则的地址（如含 `,;<>`、单字符 TLD）无法自助验证/找回；用户需先「更换邮箱」为合法地址。`username IS NULL` 的这类账号若还要解绑，须先由管理员设置登录名（§13.9）。**不要**为兼容它们放宽用户侧校验（会重新打开邮件头注入面）。本批只接受标准 ASCII 邮箱：IDN 需先转 punycode，单标签内部域（`user@corp`）不支持。
13. **`pwreset:lock:ip` 纳入风控页**：本批只提供 ops-manual 的 `redis-cli DEL` 应急；二期在 `/admin/risk` 增加 pwreset IP 锁列表/解锁（新审计事件 `pwreset_ip_unlocked`），避免共享 NAT 误锁时只能进容器。
