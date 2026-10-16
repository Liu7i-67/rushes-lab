# 需求文档：删除文件/文件夹权限可授予用户组

- 日期：2026-10-16
- 分支：`feat/group-delete-perm`（基线 liuqi @ e792be0）
- 状态：已定稿（用户已拍板 3 项口径，见「模糊点与决策记录」）

## 背景与目标

当前「删除文件」「删除文件夹」操作的授权只有两条路：系统管理员直通，或对象级 FGA 权限（文件软删/恢复/彻底删除=`asset#can_admin`；删除空文件夹=普通夹 `folder#can_upload`、敏感夹 `sensitive_folder#can_admin`）。组织管理员无法把删除能力下放给某个用户组。

目标：在管理后台「用户组」编辑中新增组级开关「允许删除文件与文件夹」，与既有 `project_deleter`（允许删除项目）组级授权先例同构：FGA 组织级 relation → 目录接口写 tuple → `/me` 回显 → 前端按钮闸门。

**已拍板口径（用户 2026-10-16 决策）**：

1. **单开关**：文件与文件夹合成一个开关（删空夹要求回收站先清空，拆开会出现"能删夹却不能删文件"的死锁组合）。
2. **仅可见范围**：组员只能删除自己**有权浏览**（`can_view`）的文件夹中的文件/空文件夹。授权 ∧ 可见，二者同时满足才放行。
3. **软删+回收站闭环**：软删、回收站查看/恢复、彻底删除（非敏感）全部对组员放开；**敏感区（sensitive）完全维持现状**（仅系统管理员与对象级管理员），组织开关不穿透 sensitive。

## 功能点明细（逐条可验收）

### 后端

- F1 组织级 relation：organization 对象新增 `define file_deleter: [user, group#member]`（与 `project_deleter` 同款写法），model 断言同步补充（org admin `file_deleter: false`；授权组员 true）。
- F2 组开关读写：管理后台组创建/编辑支持 `can_delete_files` 布尔（tri-state PATCH：不传不改）；组列表回显；删除组时清理该 flag tuple。真实态存 FGA tuple，groups 表**不加列**。
- F3 文件软删放行：`DELETE /api/v1/assets/{asset_id}`（默认软删）守门扩为 `is_system_admin or asset#can_admin or (is_org_file_deleter and asset#can_view)`；其中组织开关分支**不适用于 sensitive 资产**（敏感判定与现有 trash/restore 的 sensitive 特判同源，字段以后端现状为准：随所属文件夹 `is_sensitive`）。
- F4 彻底删除放行：`DELETE /api/v1/assets/{asset_id}?hard=true` 非 sensitive 资产对组员放开（同 F3 组合）；sensitive 资产仍仅系统管理员（F1 既有红线不动）。两步制约束（须先软删）不变。
- F5 回收站查看放行：`GET /api/v1/assets/trash?folder_id=` 普通夹对组员放开（`is_org_file_deleter and folder#can_view`）；sensitive 夹仍仅系统管理员。
- F6 恢复放行：`POST /api/v1/assets/{asset_id}/restore` 非 sensitive 资产对组员放开；sensitive 资产仍仅系统管理员。
- F7 删除文件夹放行：`DELETE /api/v1/folders/{folder_id}` 普通夹守门扩为 `... or (is_org_file_deleter and folder#can_view)`；sensitive 夹维持 `sensitive_folder#can_admin`。空夹约束（无子夹+无活跃文件+回收站清空，409）不变；成功后 FGA tuple 清理与审计不变。
- F8 文件夹权限下发：`FolderOut` 新增 `my_delete_grant: boolean` = `is_org_file_deleter(当前用户) and folder#can_view and not folder.is_sensitive`（不含系统管理员直通，与 `my_can_*` 系列口径一致）。
- F9 `/me` 回显：`GET /api/v1/auth/me` 返回新增 `is_file_deleter: boolean` = `is_system_admin or is_org_file_deleter`（注意：**不含** org admin 直通——org admin 删除文件走既有对象级权限，现状即如此，不扩大）。
- F10 审计不回退：软删/恢复/彻底删除/删夹的既有审计记录保留，actor 记实际操作用户（组员操作天然可溯）。

### 前端

- F11 组编辑 UI：AdminGroupsPage 组创建/编辑弹窗新增 Switch「允许删除文件与文件夹」（tri-state PATCH，仿「允许组成员删除项目」），组列表加对应徽标。
- F12 删除入口显隐（ProjectDetailPage）：
  - 批量删除文件按钮：`disabled` 从 `!folder?.my_can_admin` 改为 `!(folder?.my_can_admin || folder?.my_delete_grant)`。
  - 删除文件夹按钮显隐：`folder.is_sensitive ? my_can_admin : (my_can_upload || my_delete_grant)`。
  - 回收站入口 `canSeeTrash`：`(folder?.my_can_admin || folder?.my_delete_grant) && (!folder.is_sensitive || !!me?.is_system_admin)`。
- F13 回收站弹窗（FolderTrashModal）：恢复/彻底删除按钮显隐与新守门口径对齐（组员对非敏感资产可恢复/彻底删除；sensitive 维持仅系统管理员）。
- F14 类型：`Me.is_file_deleter?: boolean`（旧后端回落语义：`?? false`）；`DirectoryGroup.can_delete_files?: boolean`；`Folder.my_delete_grant?: boolean`。
- F15 权限管理页（如有以 my_can_* 显隐的"权限"入口）**不受影响**：本需求不改动 `my_can_admin/my_can_upload/my_can_download/my_can_view` 的取值语义。

## 数据库修改方案

**不涉及**。组级 flag 与 `can_delete_project` 先例一致不落库（groups 表无新列、无迁移）；真实态只存 OpenFGA tuple：`group:<gid>#member, relation: file_deleter, object: organization:<tenant_key>`。

## 接口定义

只列**新增/变更**字段；未列出者一律不变。

1. `POST /api/v1/admin/directory/groups`（系统管理员）
   - 入参新增：`can_delete_files?: boolean`（默认 false）
   - 行为：为 true 时写 file_deleter tuple
2. `PATCH /api/v1/admin/directory/groups/{group_id}`（系统管理员）
   - 入参新增：`can_delete_files?: boolean`（tri-state：字段缺省=不改动）
   - 行为：true 写 / false 删 file_deleter tuple
3. `GET /api/v1/admin/directory/groups`（系统管理员）
   - 返回新增（DirectoryGroupOut）：`can_delete_files: boolean`
4. `GET /api/v1/auth/me`
   - 返回新增：`is_file_deleter: boolean`
5. `GET /api/v1/folders/{folder_id}` 及所有返回 FolderOut 的接口
   - 返回新增：`my_delete_grant: boolean`
6. 行为变更（路径/入参不变，仅 403→200 口径扩展）：`DELETE /assets/{id}`（软删+hard）、`POST /assets/{id}/restore`、`GET /assets/trash`、`DELETE /folders/{id}`
   - 错误码：403 文案沿用现有风格并区分"无删除权限"；409（空夹约束/两步制）不变。

## 前端改动点

- `ms/web/src/api/types.ts`：F14 三处类型。
- `ms/web/src/pages/AdminGroupsPage.tsx`：F11（Switch+tri-state+徽标，仿 `can_delete_project` 既有实现）。
- `ms/web/src/pages/ProjectDetailPage.tsx`：F12 三处闸门。
- `ms/web/src/components/FolderTrashModal.tsx`：F13（核实现状后对齐，最小改动）。

## 后端改动点

- `ms/poc/openfga/store.fga.yaml`：F1 relation + 断言。
- `ms/api/app/services/permissions.py`：`is_org_file_deleter()`（仿 `is_org_project_deleter`）；防御性常量补项（按 `USER_DIRECT_RELATIONS` 现状）。
- `ms/api/app/routers/assets.py`：F3/F4/F5/F6 守门扩展（软删/hard/restore/trash 四处）。
- `ms/api/app/routers/folders.py`：F7 守门扩展 + F8 `my_delete_grant` 下发（复用既有并发 check 模式）。
- `ms/api/app/routers/directory.py`：F2（CreateIn/UpdateIn/Out + `_read_flag_group_ids` + `_sync_group_org_flag` + 删组清理）。
- `ms/api/app/routers/auth.py`：F9。

## 测试功能点

集成测试（pytest，容器内跑，仿 `tests/test_project_soft_delete.py` 先例；跑前须把新 model 推到测试 store）：

- T1 组开关 tri-state：PATCH 缺省不改 / true 写 tuple / false 删 tuple；GET 回显；POST 创建即置位；删组清 tuple。
- T2 组员软删：可见普通夹文件软删 204（进回收站）；无 can_view 的夹 403。（DELETE/restore/删夹均为 204 无响应体）
- T3 组员恢复+彻底删除（非敏感）：restore 204；purge 204；两步制 409 不变。
- T4 组员回收站列表：普通夹 200；sensitive 夹 403。
- T5 sensitive 红线：组员对 sensitive 资产软删/恢复/purge、sensitive 夹删除均 403。
- T6 组员删夹：可见空普通夹 204；非空 409；不可见 403；sensitive 夹 403。
- T7 失权：移出组/关闭开关后上述操作全部 403。
- T8 `/me`：组员 `is_file_deleter=true`；普通用户 false；系统管理员 true；org admin（未授权组）false。
- T9 `FolderOut.my_delete_grant`：组员可见普通夹 true / 不可见 false / sensitive 夹 false；非组员恒 false；仅 public 浏览（无显式 FGA view tuple）也为 false（决策 #9）。
- T10 审计：组员删除操作 audit 落库且 actor 正确。
- T11 回归：对象级 can_admin/can_upload 删除路径不变；系统管理员/org admin 行为不变；`project_deleter` 等四个既有组级 flag 不受影响；model 断言全绿。

前端验收（真机/构建）：

- T12 组编辑弹窗 Switch 回显+tri-state 提交；列表徽标。
- T13 组员视角：可见普通夹出现删除文件/删除文件夹/回收站入口；sensitive 夹无变化；不可见夹不可达。
- T14 `pnpm build` + `pnpm lint` 通过。

## 模糊点与决策记录

| # | 问题 | 决策 | 依据 |
|---|---|---|---|
| 1 | 开关粒度 | 单开关（文件+文件夹合一） | 用户拍板（推荐项）：删夹依赖回收站清空，拆开会死锁 |
| 2 | 作用范围 | 仅可见范围（授权 ∧ can_view） | 用户拍板（推荐项）：防越权删不可见内容 |
| 3 | 能力边界 | 软删+回收站闭环；sensitive 维持现状 | 用户拍板（推荐项） |
| 4 | FGA relation 命名 | `file_deleter`（单开关覆盖文件+文件夹+回收站，语义"文件删除者"广义含夹） | PM：与 `project_deleter` 命名族对齐 |
| 5 | 前端下发设计 | 新增 `FolderOut.my_delete_grant`（组织开关生效态），**不**污染 `my_can_admin/my_can_upload` 取值 | PM：`my_can_*` 被权限管理等多处消费，改动其语义会放大爆炸半径 |
| 6 | `/me` 口径 | `is_file_deleter = is_system_admin or is_org_file_deleter`，不含 org admin 直通 | PM：现状 org admin 删文件本就无直通（走对象级），不借本需求扩大 |
| 7 | sensitive 判定字段 | 随所属文件夹 `is_sensitive`（与 trash/restore 现有特判同源） | PM：后端实施时以现状代码为准核实 |
| 8 | 组 flag 存储 | 不落库，只存 FGA tuple | 既有 `can_delete_project` 先例 |
| 9 | 「可见」的口径（验收裁决 2026-10-16） | `my_delete_grant` 与四个删除守门一律取**裸 FGA can_view**，**不**取 get_folder 对 public 项目非敏感夹的应用层浏览直通（public_browse）。理由：①守门与按钮闸门必须同口径，否则 public 夹出现「亮灯必 403」按钮；②public 对全组织可见，按浏览口径放开 ≈ 组员可删全组织 public 项目内容，接近已否决的「全租户范围」。副作用（接受）：组员对仅靠 public 语义浏览的夹无删除入口，须有显式 view tuple（项目成员/受邀等） | PM：测试 T9 同口径；后端 get_folder 初版误用浏览直通 can_view，已派发修复 |
| 10 | T8「org admin」措辞 | 本代码库 `is_system_admin` 即 default org 的 `organization#admin`（唯一 admin 概念），不存在独立的「未授权组 org admin」主体；F9 公式不变，测试按公式断言 + FGA 层断言 org admin 不自动蕴含 file_deleter relation | PM：澄清 D6 措辞，公式无变化 |

## 部署注意（非本分支工作）

- FGA model 有变更：dev/prod 部署时须先跑 `ms/api/scripts/openfga_write_model.sh` 重推 model（`.env` 不固定 model id，ms-api 重启自动用 latest）。
- 前端构建产物输出到 `api/app/static/web/`。
