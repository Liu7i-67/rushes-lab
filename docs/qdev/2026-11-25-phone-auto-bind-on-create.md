# 建号自动绑定大陆手机号 + 编辑界面手机号回显 — 需求文档

- 日期:2026-11-25
- 分支:feat/phone-auto-bind-on-create(自 liuqi=858060e 切出)
- 状态:已定稿(模糊点已用户拍板)

## 背景与目标

上一周期(2026-11-20,合并 a9b26f7)交付了手机号绑定 + 短信找回密码,并用
`api/scripts/bind_user_phones.py` 把存量「登录名=大陆手机号」的用户批量自动绑定
(dev 9 账号 / prod 216 账号),减少用户手动操作、节约短信发送次数。

本次把该口径固化为**建号时自动行为**:

1. 后续新建的账号,只要 username 归一化后是大陆手机号,创建时即自动绑定同名手机号
  (不发短信、不验证码,直接落 `users.phone`);
2. 上线后**复跑一次** `bind_user_phones.py --apply --yes`,兜住「上次批量跑完之后、
   本次代码上线之前」新键的账号(幂等,已绑的自动 skip);
3. Web 管理后台「用户编辑」弹窗**只读回显**目标用户已绑定的手机号(完整号码,
   不可编辑;新建用户弹窗不展示该字段)。

App 端不涉及(本人视角的绑定状态已有「账号与安全」页,保持不变)。

## 现状(调研结论)

- 建号唯一主体 = `app/services/user_provisioning.py::provision_local_user`
  (admin 建号 `POST /admin/directory/users` 与组长内嵌建号 `POST /projects` 带
  `artist_account` 两链路共用;改这一处即全覆盖)。
- `users.phone` 字段 + `uq_users_phone` 唯一约束已存在(迁移 0024,dev/prod 均落库)。
- 归一化/脱敏单点 = `app/services/phone_verification.py::normalize_phone /
  mask_phone / InvalidPhone`(绑定端点与批量脚本已共用,D5 口径)。
- 批量脚本 = `api/scripts/bind_user_phones.py`(幂等可重跑,冲突绝不写库)。
- 用户编辑回显 = `GET /admin/directory/users/{user_id}` →
  `DirectoryUserDetailOut`(app/models/__init__.py,现无 phone);
  Web `AdminUsersPage.tsx` 的 `EditUserModal` 用 `useDirectoryUserDetail` 回显。
- `UserCreateIn.username` pattern=`^[a-zA-Z0-9._-]+$`(可含 `.`/`-`,无空格无 `+`),
  归一化仅去 `.`/`-` 后匹配 `^1[3-9]\d{9}$` 即命中。

## 功能点明细(可验收)

- F1 建号自动绑定:`provision_local_user` 落库后,若 `normalize_phone(username)`
  合法命中大陆手机号且无冲突,直接写 `users.phone`(不发码、无 Redis 交互)。
- F2 冲突即跳过、建号照常成功:候选号已被其他用户 phone 持有,或**归一化折叠**
  (其他用户 username 去掉 `.`/`-` 后同号)→ 不绑定,账号照常创建成功;跳过原因
  进 ops 日志(不 raise,建号响应 201)。
- F3 竞态兜底:预检通过但写入撞 `uq_users_phone` → rollback 该 UPDATE(DB 中
  phone 保持 NULL,账号完好),视为跳过,记日志。
- F4 自动绑定成功写一条 `phone_bound` 审计(actor=建号人,details 带
  `source="auto_bind"`、`old_masked=null`、`new_masked`),与既有 backfill/cli、
  用户自主 bind 三链路可区分;`user_created` 审计 details 增
  `auto_phone_bound: true/false` 键,单事件即可对账。
- F5 schema 回显:`DirectoryUserOut`(基类)增 `phone: str | None`;列表 /
  详情 / 创建 / PATCH 四处响应构造点机械补齐 `u.phone`(编辑弹窗回显走既有
  detail 接口,**零新增端点**)。
- F6 Web 编辑弹窗:`EditUserModal` 增「绑定手机号」只读展示(完整号码,与
  「登录名」同款 disabled Input 形态;未绑定显示「—」);**新增用户弹窗不加该字段**。
- F7 新建用户弹窗在登录名 extra 增加一句提示:「登录名为大陆手机号时,将自动
  绑定为该账号的登录手机号」,让建号人可预期该行为。
- F8 上线动作(部署阶段执行,非代码):dev/prod 各跑
  `docker exec ms-api[-dev] python -m scripts.bind_user_phones --apply --yes`
  (先 dry-run 核对),兜住代码上线前新建的未绑账号。

## 组件拆分方案

改动面小,两包(后端 / Web)+ 测试用例包,可全部并行。

### 后端(app)

| 文件 | 职责 | 预估改动 |
|---|---|---|
| `api/app/services/user_provisioning.py` | 建号后自动绑定段:归一化判定 → 占用/折叠一条 SQL 预检 → 单独 UPDATE+commit(撞唯一约束 rollback 跳过)→ `phone_bound` 审计;`user_created` details 增 `auto_phone_bound` | +~60 行(185→~245,远低于 500 上限) |
| `api/app/models/__init__.py` | `DirectoryUserOut` 增 `phone: str \| None = None` 字段(列表/详情/创建/PATCH 响应全继承) | +~5 行 |
| `api/app/routers/directory.py` | 四处 `DirectoryUserOut`/`DirectoryUserDetailOut` 构造点机械补 `phone=u.phone`(list / create / get / update) | +~8 行 |
| `api/tests/test_phone_auto_bind.py`(新) | 自动绑定行为用例(照 test_directory.py 既有 PG 模式) | 新文件 ~150 行 |

自动绑定不抽新模块:`normalize_phone` 已是单点,绑定段内聚在 provision 内
(与重名预检同级),无需新文件。

### Web(material-storage/web)

| 文件 | 职责 | 预估改动 |
|---|---|---|
| `src/api/types.ts` | `DirectoryUser` 增 `phone?: string \| null`(Detail/CreateOut 继承) | +~3 行 |
| `src/pages/AdminUsersPage.tsx` | `EditUserModal` 增只读手机号 Form.Item;`CreateUserModal` 登录名 extra 增提示 | +~10 行(576→~586,原有文件超 500 属存量,本次仅小增量且新增为弹窗内展示行,不再引入大块逻辑,不触发重拆) |

### 测试用例

- 后端用例随测试包写在 `test_phone_auto_bind.py`(见「测试功能点」)。
- Web 无组件测试框架(既有约定 lint+build),用例以人工核验清单形式并入文档。

## 数据库修改方案

**不涉及**(无新迁移)。`users.phone` / `uq_users_phone` 已随 0024 存在;
存量回补走既有脚本(F8)。

## 接口定义

**零新增端点,零入参变更**;仅响应体增字段:

- `GET /api/v1/admin/directory/users` — items[] 增 `phone: string | null`
- `GET /api/v1/admin/directory/users/{id}` — 增 `phone: string | null`
- `POST /api/v1/admin/directory/users` — 响应增 `phone: string | null`
  (自动绑定成功=归一化号;跳过=null)
- `PATCH /api/v1/admin/directory/users/{id}` — 响应增 `phone: string | null`
  (编辑不改 phone,原值透传)

错误码无变化;F2/F3 冲突跳过不产生任何新错误码。

## 前端改动点

见组件拆分方案 Web 表(F6/F7)。

## 后端改动点

见组件拆分方案后端表(F1-F5)。

## 测试功能点

- T1 username=纯手机号(13800138000)→ 建号成功且 phone=该号,审计
  `phone_bound`(source=auto_bind)+ `user_created`(auto_phone_bound=true)。
- T2 username=带 `.`/`-` 变体(138-0013-8000)→ 归一化命中,同 T1。
- T3 username 非手机号(zhangsan / 138001380001 长了一位 / 邮箱形态)→ 建号
  成功,phone=null,无 phone_bound 审计。
- T4 候选号已被他人 phone 持有 → 建号照常 201,phone=null,日志记跳过,
  user_created auto_phone_bound=false。
- T5 归一化折叠:既有 username=13800138000 的用户,新建 username=138-0013-8000
  → 照常建号,不绑(注意:该场景 username 本身不撞唯一约束,折叠检测生效)。
- T6 detail/list 响应带 phone(绑定/未绑定两态)。
- T7 回归:建号链路既有行为不回归(user_created 审计原字段、组入组、临时密码、
  409 重名、内嵌建号同款)。
- T8 Web:`pnpm lint` + `pnpm build` 绿;编辑弹窗展示与「登录名」一致的只读形态。

## 模糊点与决策记录

| # | 问题 | 决策 | 依据 |
|---|---|---|---|
| D1 | 编辑回显明文 vs 脱敏 | **完整号码**(用户拍板) | 管理员核对/联系需要;同号登录名场景列表本就明文可见,脱敏无增益 |
| D2 | 自动绑定撞冲突时建号行为 | **照常建号,跳过绑定**(用户拍板) | 建号是主操作,附带优化不得成为阻断条件;与脚本「冲突绝不写库」同口径 |
| D3 | phone 字段挂哪层 schema | `DirectoryUserOut` 基类 | 与 username/email 同级基础字段;四处构造点机械补齐,PATCH 后缓存更新自然带新值 |
| D4 | 内嵌建号(组长建项目带艺人账号)是否覆盖 | 覆盖 | 共用 provision 单点;「后续新建的账号」字面即全部建号链路 |
| D5 | 折叠预检实现 | 一条 SQL:`phone=candidate OR replace(replace(username,'-',''),'.','')=candidate` | username pattern 保证无空格无 `+`,仅 `.`/`-` 需折叠;`replace()` 为 PG/SQLite 双方言通用(勿用 regexp_replace,本地内存 SQLite 测试跑不动) |
| D6 | 自动绑定的审计口径 | `phone_bound` + details `source="auto_bind"`;`user_created` details 增 `auto_phone_bound: bool` | 与 backfill(cli)/用户自主 bind 可区分;user_created 单事件对账 |
| D7 | UserCreateIn 是否加 phone 入参 | 不加 | 需求口径=自动绑定;显式指定走既有管理动作,勿开新面 |
| D8 | AdminUsersPage.tsx 已 576 行(超 500 存量) | 本次仅 +~10 行展示性小增量,不触发重拆 | 重拆属独立重构议题,与本次需求解耦;新增不堆逻辑 |

## 上线(部署阶段备忘)

1. 常规 deploy_lan(alembic 对账 head=0024 无新迁移,直接 restart 即可)。
2. 部署后各环境跑:`docker exec <ms-api> python -m scripts.bind_user_phones`
  (dry-run 核对)→ `--apply --yes`(F8,兜最近新建账号)。
3. prod 窗口惯例照旧(百度活动任务 0 等)。
