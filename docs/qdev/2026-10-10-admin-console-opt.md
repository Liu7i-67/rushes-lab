# 管理后台优化六项(复制降级/组成员弹窗/建用户带组/编辑用户/用户分页/项目逻辑删除)

> qdev 周期需求文档(正本)。分支 `feat/admin-console-opt`,worktree `E:\qbb\github_not_me\rushes-lab-feat-admin-console-opt`,基线 liuqi@4970d55。
> 本文是本次开发所有子任务的**唯一需求依据**;与代码现状冲突时以本文+决策记录为准。

## 背景与目标

系统部署于内网(纯 HTTP、无域名),管理后台在日常运维中暴露六项体验/功能缺口:

1. HTTP 非安全上下文下 `navigator.clipboard` 不可用,系统内复制操作大面积失败;
2. 用户组成员接近 100 人时,"成员"弹窗被撑开过高,且无法检索组内已有成员;
3. 新建用户后还需二次到用户组里加人,操作割裂;
4. 无法编辑用户的姓名/邮箱/所属用户组;
5. 用户列表无分页、无总数显示;
6. 项目只能 DB 手工"归档"(is_archived+visibility 两笔直改),无产品化的逻辑删除能力。

目标:一次迭代补齐上述六项,且**所有新增操作全部落审计事件**可追溯。

## 决策记录

| # | 模糊点 | 决策 | 理由 |
|---|---|---|---|
| D1 | 项目逻辑删除语义 | **深隐藏+可恢复**:新增 `deleted_at`/`deleted_by` 字段;删除后列表/搜索/直链详情对**所有人**(含 system admin)404;数据/FGA tuple/minio 桶/分享链接全保留;"已删除项目"页可一键恢复 | 语义最接近用户口中的"逻辑删除";可逆降低误删风险;不动 tuple 保证恢复零成本 |
| D2 | 删除权限模型 | **新增组级开关 `can_delete_project`**,照搬 `can_create_project` 模式(FGA `organization#project_deleter`,组 tuple `group:<gid>#member @ organization:<tenant>#project_deleter`);system admin 恒可删 | 与用户描述"管理员可操作+支持给用户组配置该权限"精确对齐;与既有组级建项目开关同款交互,认知零成本 |
| D3 | 编辑用户的组同步语义 | **全量同步**:编辑弹窗回显当前组,保存以勾选集为准,后端 diff 自动加入/移出 | 常见后台语义,一步到位;移出操作同样记审计 |
| D4 | 用户列表分页返回结构 | 直接改为 `{items,total,limit,offset}`(破坏性),前端同批改 | 前后端同仓同发,无兼容负担 |
| D5 | 分页 pageSize | 前端默认 20(antd Pagination,showTotal 显示总数);后端 limit 默认 20、上限 200 不变语义 | 卡片式列表 20/屏合适 |
| D6 | 编辑用户 email | 允许显式传 `null` 清空;仅格式校验(表无唯一约束,不发验证邮件) | 内网目录,轻量 |
| D7 | username 不可编辑 | 建后即定(前端已注明"提交后不可改") | 与现状一致 |
| D8 | 审计被操作用户 | 进 `details` JSONB(现状惯例,如 user_created),不加 target_user 专列 | 避免无谓迁移;审计页现可按 details 检索 |
| D9 | 建用户 group_ids 上限 | ≤50,超出 422 | 与权限模板 50 条上限对齐,防误操作 |
| D10 | 删除项目是否动 FGA/桶 | 全不动(可恢复性前提);分享链接/申请链接行为不变 | 范围收敛,只做可见性 |
| D11 | 恢复接口语义 | restore 只作用于 `deleted_at IS NOT NULL` 的项目;否则 404 | 端点语义自洽 |

> 注:2026-10-10 AskUserQuestion 未获答复,PM 按"最通用合理"原则拍板 D1-D3(均为当时推荐项),用户后续可推翻,推翻点仅影响 D1/D2/D3 对应模块。

## 功能点明细(逐条可验收)

### F1 复制降级(copy-to-clipboard)
- F1.1 引入 `copy-to-clipboard` 库(依赖已由 PM 预装进 package.json),新建统一工具 `web/src/utils/copy.ts`:`copyToClipboard(text: string): boolean`。
- F1.2 替换全部 7 处 `navigator.clipboard.writeText` 调用点(见「前端改动点」清单),删除 ShareModal 手写 execCommand 降级,为 AssetSummaryPanel.tsx:176 无兜底调用点补失败提示。
- F1.3 验收标准:纯 HTTP 环境下 7 个复制入口全部成功复制并提示;失败(如极旧浏览器)时给出手动复制提示文案。

### F2 用户组「成员」弹窗(高度约束+组内搜索)
- F2.1 成员列表容器限高 `min(420px, 60vh)` 且 overflow 滚动,弹窗不再被成员数撑开。
- F2.2 成员列表上方新增搜索框(allowClear+搜索图标),对已加成员按 `username/name/email` 不区分大小写子串过滤。
- F2.3 过滤时标题计数变为"成员—{组名}({匹配数}/{总数} 人)",清空搜索恢复"N 人"。

### F3 新建用户支持指定用户组
- F3.1 CreateUserModal 新增"用户组(可选)"多选 Select(远程组列表可搜索),不选可提交。
- F3.2 后端 `POST /admin/directory/users` 入参加 `group_ids?: UUID[]`(默认 [],≤50);创建成功后逐组执行与现有加成员接口完全一致的双写(DB `group_memberships` 行 + FGA tuple)。
- F3.3 原子性:任一 group_id 无效→422,用户不创建;组 id 全部预先校验。
- F3.4 审计:user_created(details 增 group_ids)+ 每成功一组 group_member_added(details 增 source:"user_create")。

### F4 编辑用户(姓名/邮箱/用户组)
- F4.1 用户行新增「编辑」操作 → EditUserModal:回显 username(只读)/name/email/当前组多选;提交 `PATCH /admin/directory/users/{id}`。
- F4.2 name 非空才更新;email 显式 null 清空;group_ids 全量同步(D3):diff 出 added/removed,分别走现有加/移成员双写逻辑。
- F4.3 原子性:group_ids 中无效组→422 整体失败(先全量校验组存在再落库)。
- F4.4 审计:user_updated(details:user_id/username/changes{name,email,groups_added,groups_removed})+ 每组 group_member_added/group_member_removed。

### F5 用户列表分页+总数
- F5.1 `GET /admin/directory/users` 返回改 `{items,total,limit,offset}`,total=同条件(q/is_active)count。
- F5.2 前端列表头部显示"共 {total} 名用户",底部 antd Pagination(pageSize 20、响应 limit/offset、筛选变化重置回第 1 页)。
- F5.3 现有 q 搜索/is_active 筛选行为不变;Picker 用的 `GET /api/v1/users` 不动。

### F6 项目逻辑删除(深隐藏+恢复)与组级权限
- F6.1 FGA 模型(store.fga.yaml)organization 增 relation `project_deleter: [user, group#member]`;部署/测试需重推模型。
- F6.2 组编辑接口 PATCH /admin/directory/groups/{id} 增 `can_delete_project: bool|null`(tri-state 同 can_create_project);组列表/详情返回增 `can_delete_project: bool`;审计 group_updated 带变更。
- F6.3 `DELETE /api/v1/projects/{id}`:守门=system admin ∨ organization#project_deleter(不要求该项目 admin);动作=置 deleted_at/deleted_by;不动 tuple/桶/分享;审计 project_deleted。对已删除项目重复删除→404。
- F6.4 可见性收紧:`GET /api/v1/projects`(含 system admin 分支与 FGA list_objects ∪ public 兜底分支)与 `GET /api/v1/projects/{id}` 一律排除 deleted_at 非空;已删除项目详情→404。
- F6.5 `GET /api/v1/projects/deleted`(守门同 6.3):q(code/name)+limit/offset,返回 {items,total},按 deleted_at 倒序,带 deleted_by_name。
- F6.6 `POST /api/v1/projects/{id}/restore`(守门同 6.3):清空 deleted_at/deleted_by;非已删除→404;审计 project_restored。
- F6.7 `/me` 返回增 `is_project_deleter: bool`。
- F6.8 前端:项目页头部「已删除项目」入口(权限=is_project_deleter||is_system_admin)→ Modal 分页列表+「恢复」;项目卡片操作区与项目详情页头部增「删除项目」(同权限,Popconfirm 二次确认,文案说明深隐藏+可恢复);组管理页组编辑弹窗增 can_delete_project 开关、组行展示该 flag(与 can_create_project 同样式)。

### F7 审计全覆盖(横切)
- F7.1 本次新增可变更状态的操作全部落审计:F3.4/F4.4/F6.2/F6.3/F6.6 列出的事件;查询类(列表/详情/已删除列表)不审计(与现状一致)。

## 数据库修改方案

**迁移文件:`api/app/db/migrations/versions/2026_10_10_0015_project_soft_delete.py`**(down_revision=`20261009_0014`,保持单链,命名与惯例一致)

| 表 | 变更 | 类型/默认 | 存量数据 |
|---|---|---|---|
| projects | + `deleted_at` | DateTime(timezone=True), NULL, nullable, index(部分场景按 deleted_at 排序查询) | 全 NULL(未删除) |
| projects | + `deleted_by` | UUID, nullable, FK users.id ON DELETE SET NULL | 全 NULL |

- users/groups/group_memberships/audit_events **无表结构变更**(编辑用户/组开关/审计均复用现有列与 details JSONB)。
- downgrade:drop 两列(先 drop constraint 再 drop column,按 0014 惯例)。

## 接口定义

契约版本:v1 路径前缀 `/api/v1`。错误响应沿用现有 `{"detail": "..."}` 惯例;鉴权守门沿用 deps.py。

### 1. POST /api/v1/admin/directory/users(修改:入参扩展)
入参 UserCreateIn:
| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| username | string | 是 | 2-64,`^[a-zA-Z0-9._-]+$`,唯一 |
| name | string | 是 | ≤128 |
| email | string\|null | 否 | email 格式校验 |
| group_ids | UUID[] | 否 | 默认 [],≤50,须全部存在 |

返回 201:DirectoryUserOut(结构不变:id/username/name/email/is_active/must_change_password/created_at/resigned_at)。
错误:422 `invalid_group_ids`(组不存在或超 50)/其余同现状。
审计:`user_created`(details 增 `"group_ids":[...]`)、每组 `group_member_added`(details 增 `"source":"user_create"`)。

### 2. GET /api/v1/admin/directory/users/{user_id}(新增)
守门:system admin。
返回 200 DirectoryUserDetailOut:
| 字段 | 类型 |
|---|---|
| id / username / name / email / is_active / must_change_password / created_at | 同 DirectoryUserOut |
| group_ids | UUID[] |
| group_names | string[](与 group_ids 同序) |

错误:404 `user_not_found`。

### 3. PATCH /api/v1/admin/directory/users/{user_id}(新增)
守门:system admin。
入参 UserUpdateIn(全部可选键,缺省=不改):
| 字段 | 类型 | 说明 |
|---|---|---|
| name | string | ≤128,提供则须非空 |
| email | string\|null | null=清空;string 须 email 格式 |
| group_ids | UUID[] | 全量同步终态,≤50,须全部存在 |

返回 200:DirectoryUserOut(更新后)。
行为:先校验(用户存在/组 id 全存在)→ name/email 更新 → group diff(以 group_memberships 现状为基线):added 走加成员双写,removed 走移成员双写。
错误:404 `user_not_found`;422 `invalid_group_ids`/校验失败;403 非 system admin。
审计:`user_updated`(details:`{user_id, username, changes:{name:{old,new}?, email:{old,new}?, groups_added:[{group_id,group_name}], groups_removed:[...]}}`)+ 每组 `group_member_added`/`group_member_removed`。

### 4. GET /api/v1/admin/directory/users(修改:返回结构)
入参不变:q/is_active/limit(默认 20,≤200)/offset。
返回 200 DirectoryUsersPageOut:
| 字段 | 类型 |
|---|---|
| items | DirectoryUserOut[] |
| total | int(同条件 count) |
| limit / offset | int |

### 5. PATCH /api/v1/admin/directory/groups/{group_id}(修改:入参扩展)
入参加 `can_delete_project: boolean|null`(tri-state,语义同 can_create_project:null/缺省=不变)。
返回:组对象增 `can_delete_project: boolean`。
行为:同 `_sync_group_project_creator` 模式同步 FGA tuple(group:<gid>#member @ organization:<tenant>#project_deleter 的写入/删除);GET /admin/directory/groups 列表与 PATCH/POST 返回同样带该字段(读回逻辑照 `_read_creator_group_ids`)。
审计:`group_updated` details 增 `"can_delete_project": {old,new}`(有变更时)。

### 6. DELETE /api/v1/projects/{project_id}(新增)
守门:新 deps 依赖 `require_project_deleter`(=is_org_admin ∨ FGA check user project_deleter organization:<tenant>);**不要求目标项目 admin**。
行为:`deleted_at=now()`,`deleted_by=actor.id`;不动 FGA/桶/资产/分享。
返回 200:`{"ok": true, "project_id": "...", "deleted_at": "..."}`。
错误:404 `project_not_found`(不存在**或已删除**);403。
审计:`project_deleted`(details:{project_id, code, name, deleted_by})。

### 7. GET /api/v1/projects/deleted(新增)
守门:require_project_deleter。
入参:q(code/name 不区分大小写子串)、limit(默认 20,≤200)、offset。
返回 200:
| 字段 | 类型 |
|---|---|
| items | {id, code, name, description, visibility, deleted_at, deleted_by, deleted_by_name:string\|null}[] |
| total / limit / offset | int |

排序 deleted_at DESC。

### 8. POST /api/v1/projects/{project_id}/restore(新增)
守门:require_project_deleter。
行为:仅作用于 deleted_at 非空者;清空 deleted_at/deleted_by。
返回 200:`{"ok": true, "project_id": "..."}`。
错误:404 `project_not_found`(未删除或不存在)。
审计:`project_restored`(details:{project_id, code, name, restored_by})。

### 9. GET /api/v1/projects / GET /api/v1/projects/{id}(修改:过滤)
两接口一律追加 `deleted_at IS NULL`;已删除项目详情(含 system admin 直访)→404 `project_not_found`。

### 10. GET /api/v1/auth/me(修改:返回扩展)
返回对象增 `is_project_deleter: boolean`(is_org_admin ∨ organization#project_deleter)。

### 11. FGA 模型(poc/openfga/store.fga.yaml)
organization type 增:`project_deleter: [user, group#member]`。不改既有 relation;版本号/注释按文件现状惯例递增。
> 部署与集成测试前置:需重推 FGA authorization model(沿用现有 seed/push 流程,后端 B 负责查清并在交付说明中写明命令)。

## 前端改动点

| # | 文件 | 改动 |
|---|---|---|
| W1 | `web/src/utils/copy.ts`(新) | copyToClipboard(text):boolean,内部 copy-to-clipboard 库 |
| W2 | `web/src/components/ShareModal.tsx` | 删手写 execCommand 降级,改用 W1 |
| W3 | `web/src/components/RequestLinkCreateModal.tsx` | 替换 clipboard 调用 |
| W4 | `web/src/components/UserMenu.tsx` | 替换 clipboard 调用 |
| W5 | `web/src/components/BaiduBindModal.tsx` | 替换 clipboard 调用 |
| W6 | `web/src/components/AssetSummaryPanel.tsx` | 两处替换,补无兜底点的失败提示 |
| W7 | `web/src/pages/AdminGroupsPage.tsx` | GroupMembersDrawer:列表限高滚动+搜索过滤+计数(F2);组编辑弹窗+组行增 can_delete_project 开关/展示(F6.8) |
| W8 | `web/src/pages/AdminUsersPage.tsx` | TempPasswordModal 复制改用 W1;CreateUserModal 增组多选(F3.1);行增「编辑」+EditUserModal(F4.1);分页+总数(F5.2) |
| W9 | `web/src/pages/ProjectsPage.tsx` | 「已删除项目」入口+Modal(分页列表+恢复);项目卡片增「删除项目」(Popconfirm) |
| W10 | `web/src/pages/ProjectDetailPage.tsx` | 详情页头部增「删除项目」入口(同权限) |
| W11 | `web/src/api/hooks.ts` | 新增/修改:useDirectoryUsers(分页参数+新返回结构)、useDirectoryUserDetail、useUpdateUser、useCreateUser(group_ids)、useGroupMembers(不变)、useAdminGroups(带 can_delete_project)、useUpdateGroup、useDeleteProject、useRestoreProject、useDeletedProjects |
| W12 | `web/src/api/types.ts` | DirectoryUsersPageOut/DirectoryUserDetailOut/UserUpdateIn/Me.is_project_deleter/Group.can_delete_project/DeletedProject 等类型 |
| W13 | `web/package.json` | 已由 PM 预装 copy-to-clipboard + @types/copy-to-clipboard |

前端约定:antd v6(`App.useApp()` 取 message,禁静态方法)、lucide 图标、inline style+`--ms-*` tokens、react-query mutation onSuccess invalidate 相关 key;构建命令 `pnpm build`(含 tsc 类型检查)、`pnpm lint`。

## 后端改动点

| # | 文件 | 改动 |
|---|---|---|
| B1 | `api/app/routers/directory.py` | 用户创建 group_ids(原子校验+循环双写)、GET users/{id} 详情、PATCH users/{id}(D3 全量同步)、users 列表分页返回、组 PATCH/列表/详情 can_delete_project(仿 creator 开关)、审计事件 |
| B2 | `api/app/models/__init__.py` | UserCreateIn 扩展、UserUpdateIn/DirectoryUserDetailOut/DirectoryUsersPageOut 等新 schema |
| B3 | `api/app/db/tables.py` | Project + deleted_at/deleted_by |
| B4 | `api/app/db/migrations/versions/2026_10_10_0015_project_soft_delete.py`(新) | 见数据库方案 |
| B5 | `api/app/routers/projects.py` | DELETE/restore/deleted-list 三接口+主列表与详情 deleted 过FGA list 分支同样过滤) |
| B6 | `api/app/deps.py` | require_project_deleter |
| B7 | `api/app/services/permissions.py` | is_project_deleter check(仿 is_org_admin)+restore/deleted 需要的辅助(尽量复用既有通用 API) |
| B8 | `api/app/routers/auth.py` | /me 增 is_project_deleter |
| B9 | `poc/openfga/store.fga.yaml` | organization 增 project_deleter relation;交付说明写明模型重推命令 |
| B10 | 审计 | 全部按 F3.4/F4.4/F6.2/F6.3/F6.6 落 AuditService.write(沿用幂等/快照惯例) |

> 文件独占边界:后端 A(directory.py+models)与后端 B(B3-B9)零交集;permissions.py/deps.py/tables.py/迁移归 B 独占。

## 测试功能点

后端(pytest 集成测试,X-User-Id 模拟身份,沿用 test_directory.py 惯例):
- T1 建用户带 2 组:用户创建成功+两组各含该成员(DB 成员接口返回)+审计 user_created(group_ids)与 2 条 group_member_added
- T2 建用户 group_ids 含不存在 UUID → 422,用户不存在(原子)
- T3 建用户 group_ids>50 → 422
- T4 PATCH 改 name+email → 生效;审计 user_updated.details.changes 含 old/new
- T5 PATCH email=null → 清空
- T6 PATCH group_ids 全量同步(换 1 加 1 移)→ 组成员终态正确(含 FGA 生效:组内可见性类 check)+2 条成员审计
- T7 PATCH 不存在用户 → 404;PATCH group_ids 含无效组 → 422 且不变更
- T8 GET users 分页:total 正确;limit/offset 翻页正确;q 过滤后 total=过滤值;is_active 过滤 total 一致
- T9 非 system admin 调 PATCH/建用户/用户详情 → 403
- T10 deleter 用户 DELETE 项目 → deleted_at/deleted_by 落库;主列表(其可见范围内)不再出现;详情 404;system admin 主列表同样不见
- T11 无 deleter 权限(含项目 admin)DELETE → 403(守门层拦截,不落业务审计——与 require_project_creator 既有惯例一致;PM 裁定 2026-10-10)
- T12 DELETE 已删除项目 → 404
- T13 GET projects/deleted:含 T10 项目、分页/total、q 过滤、deleted_by_name 正确
- T14 restore → 主列表/详情恢复可见;再 restore → 404;审计 project_restored
- T15 组 PATCH can_delete_project=true → 组内普通成员 DELETE 成功(T10 前置);false → 403;GET 组返回字段正确
- T16 /me:deleter 用户返回 is_project_deleter=true;普通用户 false;org admin true
- T17 迁移可 upgrade/downgrade(alembic 冒烟:upgrade head 后 downgrade -1 再 upgrade head)

前端(构建+手工用例清单):
- T18 `pnpm build`+`pnpm lint` 通过
- T19 HTTP 环境 7 个复制点全部成功(重点:临时密码/分享链接/Asset ID/minio_key/open_id/百度授权链接/申请链接)
- T20 100+ 人组:弹窗限高滚动;搜索命中子串(用户名/姓名/邮箱,忽略大小写);计数 3/97;清空恢复
- T21 新建用户不选组可提交;选 2 组后用户直接入组;临时密码弹窗仍正常
- T22 编辑用户:回显正确;改名/邮箱/组保存生效;列表即时刷新
- T23 用户分页:翻页/总数/筛选重置第 1 页;总数文案显示
- T24 删除项目:权限显隐正确;Popconfirm;删除后列表消失;已删除项目页可见+恢复后回列表;组管理页开关生效
- T25 回归:登录/项目列表/项目成员管理/上传下载/审计查询/权限模板/组 CRUD 原功能不受影响

## 模糊点与决策记录

见「决策记录」D1-D11。

## 部署注意事项(交付后提示用户)

1. 后端:alembic upgrade head(0015);**FGA authorization model 需重推**(store.fga.yaml 变更,命令以后端 B 交付说明为准);镜像重建后 `docker compose up -d`。
2. 前端:pnpm build 产物在 api/app/static/web,随镜像/卷发布(部署按 deploy-hh2 流程)。
3. 存量数据:deleted_at 全 NULL,无迁移数据;历史 is_archived=true 的项目行为不变(本次不动 is_archived)。
