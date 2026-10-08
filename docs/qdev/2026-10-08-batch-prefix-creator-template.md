# 批量文件名前缀 + 组级「新建项目」权限 + 默认模板直通 · 需求文档

> qdev 实施文档(2026-10-08)。**权威技术方案**:`rushes-spec/material-storage/netdisk-import-batch-rename-roles-plan.md`
> (定稿 `25fe00a`,经 8 轮独立盲审收敛,末轮 P0/P1 清零)——本文档只做契约抽取与工作包划分,
> 实现细节(行号锚点、语义论证、边界取舍)一律以方案为准,两者冲突时以方案为准。
> 分支 `feat/batch-prefix-creator-template`(自 `25fe00a` 切出),worktree `rushes-lab-qplan-import-rename-roles`。

## 背景与目标

三批独立可上线的功能,全部在方案中定稿:

- **PR-1 批量文件名前缀**(方案 §1):新端点 `POST /api/v1/assets/batch-prefix`(加/去前缀,NFC 两侧归一,单事务逐 id UPDATE+对账);前端跨页保留选中、自绘全选改并/差集、三个既有批量操作切全量口径、`labels_mode=merge` 后端化、批量前缀 Modal。
- **PR-2 组级「新建项目」权限**(方案 §2):FGA `organization#project_creator` relation;用户组管理开关(tri-state PATCH);`create_project` 守门换 `require_project_creator`(口径 = is_org_admin ∨ project_creator) + organization_id/minio_bucket 服务端收口;弱门放宽(GET /users、GET /groups、GET /admin/grant-templates 读);/me 加 `is_project_creator`;前端闸门回落式替换。
- **PR-3 默认模板直通 + 刷新默认权限 + 弹窗重排**(方案 §3):create_project 完成后调共享 helper 合并默认模板授权(read 差集+翻页+分块批量写+块级降级逐条);管理页「刷新默认权限」按钮+Transfer+`apply-default` 端点(叠加不删、预检 400、部分成功);NewProjectModal 去默认预选+双栏限高重排+nameById 数据源改 /users(配套 GET /users 加 offset+tiebreaker)。

## 功能点明细(逐条可验收)

### PR-1
1. `POST /api/v1/assets/batch-prefix`:add/remove 语义、五类 skipped_reasons、NFC 两侧归一、403 笼统文案+access_denied audit、asset.batch_renamed 聚合 audit、MinIO key 不动。
2. `AssetMetaUpdateIn.labels_mode`(merge=DB 现值在前并集,默认 replace 行为不变,仍过 50 条上限)。
3. 前端:翻页保留选中(删两处清空)、切 folder 仍清空、antd 表头全选不动、自绘全选并/差集+派生式改交集口径、下载/删除/打标切 selectedIds 全量、占位名规则、BulkTagModal merge 化、AssetSummaryPanel 批量态加注、批量前缀按钮(桌面+compact)+预览+分批提交、labels.ts 补点号键+batch_renamed 映射。
### PR-2
4. store.fga.yaml 加 `project_creator: [user, group#member]` + tuples/tests 用例。
5. 组 CRUD `can_create_project`(Create bool=False / Update tri-state)、定向 read 读回、DirectoryGroupOut 回显(按入参 flag)、tuple 读写走 PermissionsService 小方法、写失败尽力而为+log、组删除顺手删 tuple、audit details。
6. `require_project_creator`/`get_is_project_creator`(deps.py)、create_project 守门+非 admin 强制忽略 organization_id 与 minio_bucket。
7. 弱门:GET /users、GET /groups 并入 is_project_creator;GET /admin/grant-templates 读放宽(写保持 system admin)。
8. /me `is_project_creator`(try/except 回 False);前端 ProjectsPage/NewProjectModal 闸门 `?? is_system_admin` 回落+禁用文案改写;AppHeader/MobileTabBar 不动。
9. USER_DIRECT_RELATIONS 补 ("organization","project_creator")。
### PR-3
10. `app/services/default_grants.py` helper(读默认模板→stale 直查过滤→read 差集(翻页聚合 read_all_tuples)→分块批量写(块级 already_exists 降级逐条)→逐条 audit via: "default_template")。
11. create_project 直通写完成后调 helper;前端删默认预选+提交区明示合并+管理页副标题文案核改。
12. `POST /api/v1/admin/grant-templates/apply-default`(预检 400 指明第几个、部分成功 results 含 error、20-30/批建议、勾选上限 100);AdminGrantTemplatesPage 按钮+Transfer(循环分页拉全量、归档天然过滤)。
13. NewProjectModal PC 双栏(≈1040,左字段右权限组)、body 限高滚动、主体行内滚、移动端单栏;nameById 改 /users(offset 分页拉全);GET /users 加 `offset: int = Query(0, ge=0)` + `order_by(User.name, User.id)`。

## 数据库修改方案

**不涉及**——无表/字段/索引变更、无 alembic 迁移。唯一 schema 级改动是 OpenFGA authorization model 加一个 relation(随 PR-2 部署时 push,代码内只改 `store.fga.yaml`)。

## 接口定义(契约,前后端以此为准)

| 方法+路径 | 入参 | 返回 | 错误 |
|---|---|---|---|
| POST /api/v1/assets/batch-prefix | `asset_ids: list[uuid](1..1000)`、`action: "add"|"remove"`、`prefix: str(1..128,禁"/"与控制字符,strip 非空,服务端 NFC 归一后复检≤128)` | `{renamed:int, skipped:int, skipped_reasons:{too_long,no_match,already_prefixed,empty_result,deleted}}` | 403(笼统文案)/422(形状) |
| PATCH /api/v1/assets/{id}/meta(既有) | 增 `labels_mode: "merge"|"replace"="replace"` | 不变 | 不变 |
| GET /api/v1/users(既有) | 增 `offset: int=Query(0,ge=0)`;排序改 `User.name, User.id` | 不变 | 不变 |
| POST /api/v1/groups(既有) | 增 `can_create_project: bool=False` | DirectoryGroupOut 增 `can_create_project` | 不变 |
| PATCH /api/v1/groups/{id}(既有) | 增 `can_create_project: bool\|None=None`(None=不动) | 同上(按入参回填) | 不变 |
| POST /api/v1/projects(既有) | 不变 | 不变 | 守门 403 文案与 require_system_admin 区分 |
| GET /api/v1/me(既有) | — | 增 `is_project_creator: bool` | — |
| GET /api/v1/admin/grant-templates(既有) | — | 不变 | 守门放宽(system admin ∨ project creator) |
| POST /api/v1/admin/grant-templates/apply-default | `project_ids: list[uuid](1..100)` | `{results:[{project_id, applied?:int, skipped_stale?:int, error?:str}], total_applied:int, total_skipped:int}` | 400(预检:不存在/跨 org/归档/无默认,指明第几个)/403/422 |

## 前端改动点 / 后端改动点(工作包文件边界)

- **WP-1 后端 PR-1**:`api/app/routers/assets.py`、`api/app/models/__init__.py`(仅 AssetBatchPrefixIn+labels_mode)。
- **WP-2 前端 PR-1**:`web/src/pages/ProjectDetailPage.tsx`、`web/src/components/BulkTagModal.tsx`、`web/src/api/types.ts`、`web/src/api/hooks.ts`、`web/src/lib/labels.ts`、可新建 `web/src/components/BatchPrefixModal.tsx`。
- **WP-4 后端 PR-2+3**:`api/app/routers/{projects,directory,users,groups,admin,auth}.py`、`api/app/deps.py`、`api/app/services/{permissions,default_grants}.py`(新)、`poc/openfga/store.fga.yaml`;**不碰 assets.py 与 models 里 WP-1 的类**。
- **WP-5 前端 PR-2+3**:`web/src/components/{NewProjectModal,AdminGrantTemplatesPage 引用页}.tsx`、`web/src/pages/{AdminGrantTemplatesPage,AdminGroupsPage,ProjectsPage}.tsx`、`web/src/api/{types,hooks}.ts`、可新建 Transfer 弹层组件。
- **WP-3/WP-6 测试用例**:`api/tests/test_batch_prefix.py`(新)、PR-2/PR-3 测试(新文件或既有扩展)。

## 测试功能点

见方案 §1.4 / §2.6 / §3.4(逐条断言已列),回归基线:既有全量 pytest 除已知 3 例遗留失败(test_notifications_e2e×2 + test_trash_and_purge::test_sensitive_trash_visible_only_to_system_admin);前端 pnpm lint/build 基线为零告警。

## 模糊点与决策记录

- 业务模糊点**零**——全部在方案 8 轮盲审中拍板(方案 §0 范围决策、§3.2 叠加不删、只管未来项目等)。
- 本次组织性决策(PM 拍板,业界常规做法):①单分支按 PR-1→PR-2/3 分批 commit,不拆三个分支(三批部署独立性由部署流程保证);②PR-2 与 PR-3 都动 NewProjectModal/admin 域,按方案 §4 建议合为同批(WP-4/WP-5);③apply-default 的请求/响应 Pydantic 模型定义在 `admin.py` 内(避免与 WP-1 的 models/__init__.py 并发冲突);④开发子智能体不 git commit,由 PM 验收后统一提交;⑤后端质量门(ruff/mypy/pytest)走容器,宿主机只做 py_compile 语法自检,前端 pnpm lint/build 宿主机直跑。

## 质量门与容器测试配方

- 后端:容器内 `python -m pytest tests/ -q`(隔离栈 feat-ms-* 配方见团队备忘:override compose 复用镜像勿 build、MSYS_NO_PATHCONV=1、docker cp tests、alembic upgrade+seed+redis FLUSHALL);ruff/mypy 容器内跑。
- 前端:`pnpm lint` + `pnpm build`(宿主机,零告警基线)。
- 部署注意(交付后由用户执行):PR-1 两段式发布、PR-2 先 push FGA model 再放代码(hh2 目标机本地跑)、PR-3 前后端同批——详见方案 §4。
