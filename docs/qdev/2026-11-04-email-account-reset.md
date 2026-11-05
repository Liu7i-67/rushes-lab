# 需求:账号邮箱自助绑定/换绑/解绑 + 邮箱找回密码(Web + App)

- 日期:2026-11-04
- 分支:`feat/email-account-reset`(基于 `qplan/email-reset` aa54218 = liuqi 6424abb + 定稿方案)
- **需求正本(唯一依据)**:`rushes-spec/material-storage/email-account-and-password-reset-plan.md`(qplan 前期 14 轮 + 本周期 5 轮盲审定稿)
- 本文档只是派发包装:拆包、环境约束、决策记录。**方案与本文冲突时以方案为准。**

## 背景与目标

见方案 §0/§1。一句话:给每个账号加「可自证」邮箱(绑定/换绑/解绑,凭当前密码+邮箱验证码),绑定后可在 Web/App 登录页走「忘记密码」→ 邮件链接 → 回站内设新密码,重置成功踢掉全部旧会话(`session_version`)。

## 硬前置(方案 §9.1,阻断 R3-R8 开发验收)

SMTP 服务商/出口实测/公网 HTTPS 入口/SPF-DKIM/W2a 真实 IP 复验等六项书面确认**尚未完成**。本批按方案继续开发与测试(代码默认 `EMAIL_AUTH_ENABLED=false`,功能整体隐藏);**部署/启用必须等前置确认**,由用户另行拍板。

## 工作包拆分(方案 §11,依赖串行、包内并行)

| 包 | 内容 | 派发时机 |
| --- | --- | --- |
| B1 基建 | settings + mailer.py + notifications 改造 + 迁移 0021 + 模型 + test_db_schema + 最小写入守卫(管理员/OIDC lower()+IntegrityError→409) | 第 1 波(单独) |
| B2 邮箱绑定 | email_utils + email_verification + 3 个 session 端点 + §5.3.5 全部落点 + 测试 | 第 2 波(与 B3 并行) |
| B3 找回密码 | password_reset + 3 个公开端点 + session_version(deps/auth/directory + set_password/set_initial_admin 两脚本) + 测试 | 第 2 波(与 B2 并行) |
| B4 Web | 登录页/忘记页/重置页/设置页 + 路由豁免 + hooks/types + 改密行为 + AdminUsersPage | 第 3 波 |
| B5 App | 登录页入口 + 忘记页 + 邮箱页 + Me/Session 模型 + 改密行为 + 测试 | 第 3 波 |
| B6 运维 | 三个脚本 + ops-manual §13 + .env 模板 + changelog | 第 3 波 |

B2/B3 并行的文件冲突面:方案 §11 已论证不冲突(B3 改 deps.py/services/auth.py/directory.py,B2 的端点在新 router `account_security.py`);两包都会碰 `routers/auth.py`(B2 只动 OIDC callback 签名,B3 只动 change-password)**——各自只许改自己清单内的区域,Edit 前先重读文件当前状态**。

## 环境与构建约束(子智能体必读)

- worktree 根:`E:\qbb\github_not_me\rushes-lab-feat-email-account-reset`(后续所有读写都在这里,**禁止触碰主仓** `E:\qbb\github_not_me\rushes-lab`)。
- **本地 docker 一律禁止**(2026-10-20 立):不跑 `docker compose`、不跑需要真 PG/Redis/MinIO 的集成测试。
- api:`uv run ruff check .`、`uv run mypy app`(strict)、SQLite 可跑单测 `uv run pytest tests/test_xxx.py -o asyncio_mode=auto`(本批新测试按方案设计为 SQLite 兼容;advisory lock 分支按方言跳过)。**不许跑** `tests/test_v4_permissions.py` 等需容器数据的集成测试。
- web:`pnpm build` + `pnpm lint`(node_modules 已 junction 到主仓,**禁止 pnpm install/pnpm add**——会装错 antd 版本)。
- app:Flutter SDK `E:\qbb\soft\flutter`,`JAVA_HOME=E:\qbb\soft\java`;如需网络加 `PUB_HOSTED_URL=https://pub.flutter-io.cn` / `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`(pub cache 已暖,通常离线可用)。`flutter analyze` 0 issue + `flutter test` 全绿。
- **单文件 ≤500 行**硬上限:预判超限先拆子模块(router 端点多就拆 handler/service 文件)。
- **既有功能不得删**;只 format 自己新建/修改的文件,禁止全仓 reformat。
- 提交身份已配 `Evan <kevinfitzroy715@gmail.com>`;子智能体**不执行 git commit**(PM 统一提交),只落盘改动并汇报。
- 真实邮箱/密码/token 不得写进代码、测试、日志、commit message。

## 测试功能点

方案 §10.1(API,按 B2/B3 域分摊)、§10.2(Web 手工验收清单,B4 交付自动化可做部分)、§10.3(App widget/单测)。每包自带测试;第 4 波派专职测试子智能体做全方位+回归。

## 模糊点与决策记录

全部 16 项关键决策(D1-D16)已在方案 §3 由用户拍板定稿;qdev 周期内无新增模糊点——实施细节一律按方案文字执行,方案未覆盖且无法从上下文推断的,子智能体在汇报中列出待 PM 裁决,不自行发明。

## B6 交付记录(2026-11-05)

- `material-storage/api/scripts/check_email_duplicates.py` — 迁移前置只读体检:`docker exec ms-api python -m scripts.check_email_duplicates`;纯 `text()` 显式列、不 import ORM;重复/跨列冲突退出码 1 阻断,空串/大写/疑似非法仅统计;输出脱敏值 + 用户 id。
- `material-storage/api/scripts/send_test_mail.py` — SMTP 出口真实发信:`docker exec -i ms-api python -m scripts.send_test_mail`(收件人 stdin/交互;`--to` 仅可选占位,`--to -` 也可走管道);不要求 mail_ready,只要 SMTP 齐备;输出带 resolve_mail_ready 诊断。
- `material-storage/api/scripts/mark_email_verified.py` — 逐条标记已验证:`docker exec -i ms-api python -m scripts.mark_email_verified --username <u>`(或 `--user-id <uuid>`);完整邮箱走 stdin/交互确认(或 `--confirm-email -`),与库值 strip().lower() 一致才执行;存量地址不合法拒绝并提示先换绑;写 `email_verified` 审计(source=ops/verified_by/email_masked);无批量档(D16)。
- `material-storage/api/tests/test_ops_scripts.py` — 19 条契约测试(纯 text 断言/脱敏输出/stdin 读取/大小写比较/非法拒绝/互斥参数),SQLite+桩,无容器。
- `material-storage/api/.env.example` / `.env.production.example` — 补 SMTP/EMAIL_* 注释段(EMAIL_LINK_BASE_URL 必填/不回落/生产非内网、端口-TLS 互斥、force-recreate 要点)。
- `rushes-spec/material-storage/ops-manual.md` — 新增 §13「邮箱与找回密码」(§13.1 硬前置 ~ §13.10 已知限制;上线 12 步与方案 §9.3 逐条对照),头部「最后更新」同步。
- `scripts/changelog.md` — 新增 `## 2026-11-05` 节(commit hash 待合并回填)。
- 自测:`uv run ruff check <3 脚本+测试>` 0 error;`uv run pytest tests/test_ops_scripts.py -o asyncio_mode=auto` 19 passed;`uv run mypy app` 158 errors(基线不动,脚本不在 mypy 范围);三脚本 `--help` 退出码 0。
