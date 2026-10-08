# qdev 需求文档 · 成员权限三项改动实施

> 日期:2026-09-30 · 需求来源:**`rushes-spec/material-storage/project-grant-templates-plan.md`(qplan 7 轮盲审定稿版,commit a8eba64)** —— 本文档是实施派发口径;**方案文档是唯一需求权威**,本文档与其冲突时以方案为准。
> 分支:`feat/project-grant-templates`(自 `qplan/project-grant-templates` a8eba64 检出)
> worktree:`E:\qbb\github_not_me\rushes-lab-feat-project-grant-templates`

## 背景与目标

用户已确认三项决策(2026-09-30):①放开用户组授项目管理;②成员界面显示用户组名称;③新建项目自动授权(initial_grants 直通 + 权限模板模块)。方案经 qplan 7 轮独立盲审定稿(末轮 0 P0/0 P1)。本次 qdev 按方案**全部三批**实施,单分支按批次分 commit。

## 功能点明细(逐条可验收)

### 批次一(PR-1,方案 §1+§2)

| # | 功能点 | 验收标准 |
|---|---|---|
| F1 | 删组 admin guard | `POST /projects/{id}/members {group_id, roles:["admin"]}` → 204;组成员获得 can_admin |
| F2 | admin 不变量加固(幸存 tuple 投影) | 唯一 admin 来源的组撤 admin → 409;有直授/其他 admin 幸存时撤组 → 204(重叠场景必须放行,禁止「leaf−贡献集」减法) |
| F3 | add/remove 入口校验 | `group_id`/`user_id` 非 UUID → 400;DELETE `subject` 非 `user:<uuid>`/`group:<uuid>#member` 形态 → 400 |
| F4 | 组名解析 helper | 新建 `services/subject_names.py`;4 处列表接口(项目成员/授权总览/夹成员/夹授权)用户组显示 `groups.name`;未命中回退 `sid[:12]+"…"`(无「用户组」前缀) |
| F5 | 前端删警告 | InviteModal 无「用户组不能授管理」警示;管理角色 hint 含组语义 |

### 批次二(PR-2,方案 §3)

| # | 功能点 | 验收标准 |
|---|---|---|
| F6 | `initial_grants` API | `POST /projects` 可选 `initial_grants:[{kind,id,roles}]`;前置校验(存在性 400/重复 400/形状 422/上限 50);写入幂等;audit 带 via |
| F7 | RoleChipGroup 抽取 | 从 InviteModal 抽公共组件,InviteModal 行为不变 |
| F8 | NewProjectModal 初始权限区 | **主体行列表 × 每行独立角色**(非共享单套);提交组装 initial_grants;不选=兼容现行为 |

### 批次三(PR-3,方案 §4)

| # | 功能点 | 验收标准 |
|---|---|---|
| F9 | 模板两张表 + migration | `2026_09_30_0012_grant_templates.py`(revision `20260930_0012`,down `20260809_0011`);partial unique index 落地 |
| F10 | 模板 CRUD | 4 端点(见接口定义);重名 409、重复主体 400、items≤50、PATCH/DELETE 404、非 system admin 403 |
| F11 | 模板管理页 | `/admin/grant-templates`,门控同 AdminGroupsPage |
| F12 | NewProjectModal 模板 Select | 默认选中 org 默认模板,onChange 逐条预填主体行;预填后可增删改 |
| F13 | 事件映射 | `labels.ts` 补 `grant_template_changed` 中文映射 |

## 数据库修改方案(方案 §4.1 为准)

- 新表 `project_grant_templates`(id/organization_id/name(128,同 org 唯一)/description(1024)/is_default/timestamps;partial unique index `uq_pgt_default_per_org` on (organization_id) where is_default)
- 新表 `project_grant_template_items`(id/template_id CASCADE/subject_kind(8)/subject_id UUID/roles JSONB/created_at;UniqueConstraint(template_id, subject_kind, subject_id))
- alembic:`2026_09_30_0012_grant_templates.py`,revision `"20260930_0012"`,down_revision `"20260809_0011"`
- 存量数据迁移:无(新表)

## 接口定义

### 改动:`POST /api/v1/projects`(方案 §3.1)

- 入参新增可选 `initial_grants: [{kind: "user"|"group", id: UUID, roles: ["admin"|"uploader"|"downloader"|"viewer", …]}]`,条数 ≤50,payload 内 (kind,id) 不得重复
- 错误:主体不存在/不 active → 400(指明第几条);重复主体 → 400;超 50 条/roles 空/角色非法 → 422;成功行为不变 201
- audit:真正写入的每条角色记 `project_member_added`(details 含 `"via": "initial_grants"`);幂等跳过不记;`project_created` details 增 `initial_grants_count`

### 改动:`POST/DELETE /api/v1/projects/{id}/members`

- admin+group 放行;`user_id`/`group_id` 非 UUID → 400;DELETE `subject` 形态校验 → 400;admin 撤销不变量按幸存 tuple 投影(409 文案沿用)

### 新增:`/api/v1/admin/grant-templates`(require_system_admin,方案 §4.2)

| 方法+路径 | 入参 | 返回/错误 |
|---|---|---|
| GET `/api/v1/admin/grant-templates` | 无 | `[{id, name, description, is_default, items: [{kind, id, roles, name, missing}]}]`;`missing=true` 仅当主体已删(found=False) |
| POST `/api/v1/admin/grant-templates` | `{name, description?, is_default?, items:[{kind,id,roles}]}` | 201;重名 409 / 重复主体 400 / 主体不存在 400 / 超 50 条 422 / roles 非法 422;organization_id 服务端取 default org |
| PATCH `/api/v1/admin/grant-templates/{id}` | 同 POST(均可选,items 全量替换) | 200;id 不存在 404;改名撞名 409(排除自身);is_default true→false = 取消默认 |
| DELETE `/api/v1/admin/grant-templates/{id}` | 无 | 204;id 不存在 404;级联删 items |

audit:增删改各记 `grant_template_changed`。

## 前端改动点

`RoleChipGroup.tsx`(新)、`ProjectMembersDrawer.tsx`(删警示/改用公共组件/hint)、`NewProjectModal.tsx`(初始权限区+模板 Select)、`AdminGrantTemplatesPage.tsx`(新)+`App.tsx`(路由+入口)、`hooks.ts`/`types.ts`(API 封装)、`labels.ts`(事件映射,归后端包)。**不碰** `labels.ts` 以外前端文件的归属边界见派发。

## 后端改动点

见功能点 F1-F4、F6、F9-F10;文件清单在方案 §1.2/§2.2/§3/§4 逐条列明(行号级)。

## 测试功能点(方案 §1.4/§2.3/§3.3/§4.6 为准)

- PR-1:group_admin_cycle / lockout_guard(5 步编排)/ 重叠回归(直授+组授撤组→204)/ UUID 入口 400 / 组名断言(members+grants+folder×2)/ grp_editors 兜底 `"grp_editors…"` / 组删除残留兜底
- PR-2:initial_grants 生效(组 uploader+user downloader)/ 不带字段兼容 / 未知 user 400 / 组不存在 400 / roles 空 422 / 超 50 条 422 / 重复主体 400 / admin_user_id 重复幂等 201
- PR-3:模板 CRUD cycle / default 唯一性+取消 / 重名 409(POST+PATCH,PATCH 自身原名放行)/ 重复主体 400 / 超 50 条 422 / kind 非法 422 / 404 / 级联删 / 403 / 主体不存在 400
- 全部容器内跑(ms-api),fixture 照 `test_v4_permissions.py:50-61`,建组照 `test_directory.py:124-133`;前置 seed_demo_data + redis FLUSHALL

## 工作包拆分与依赖

| 包 | 角色 | 内容 | 依赖 |
|---|---|---|---|
| WP-1 后端A | 后端 | PR-1 全部后端 + test_v4_permissions.py 增补 | 无 |
| WP-2 前端 | 前端 | 三批全部前端(labels.ts 除外) | 无(契约在文档) |
| WP-3 用例 | 测试 | 新文件 tests/test_initial_grants.py + tests/test_grant_templates.py(只写不跑) | 无 |
| WP-4 后端B | 后端 | PR-2/PR-3 后端(models/create_project/tables/migration/admin.py/labels.ts) | WP-1(subject_names helper) |

## 模糊点与决策记录

1. **实施范围**:全部三批一次做完(用户指令「实施该方案」,方案即三项已确认决策;批次拆 commit 保留独立回滚性)。
2. **批次一含不变量加固**:方案 §1.2 改动 2 是放开组 admin 的前置必要条件,不可拆(否则引入锁死回归)。
3. **测试基建**:本地已有停摆的项目栈 bind mount 主仓代码;为不弄脏主仓,验收阶段用独立 compose project 起隔离第二栈(feat-ms-*,独立卷/端口 8201,复用 poc-net 上的 openfga/minio),容器内跑 pytest。开发子智能体只跑 ruff/mypy,不跑 pytest。
4. **前端共享角色的 InviteModal 保持现状**:只抽组件不改交互;「每主体独立角色」仅用于 NewProjectModal(方案 §3.2)。
5. **labels.ts 归后端B**(事件映射与后端 event_type 同源,避免与前端包并发冲突)。
6. 其余一切(算法、错误码、表结构、预填方式)以方案文档为准,不再另行决策。

## 验收与完成标准

- 每个 WP:`git diff` 逐文件核对与方案一致、无越界改动;ruff/mypy 与基线零新增;前端 pnpm build/lint 过
- 集成测试:隔离栈容器内 pytest 全绿(含存量回归 56+ 例)
- 用户可见验收对照方案 §5 清单 5 条
