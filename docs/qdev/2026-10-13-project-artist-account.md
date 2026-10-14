# qdev 需求文档 · 组长建项目内嵌创建艺人账号实施

> 日期:2026-10-13 · 需求来源:**`rushes-spec/material-storage/project-artist-account-plan.md`(qplan 13 轮盲审定稿版,commit 7c73a02)** —— 本文档是实施派发口径;**方案文档是唯一需求权威**,本文档与其冲突时以方案为准。
> 分支:`feat/project-artist-account`(自 `qplan/project-artist-account` 7c73a02 检出)
> worktree:`E:\qbb\github_not_me\rushes-lab-feat-project-artist-account`

## 背景与目标

组长(组级 project_creator)建项目时须管理员先手工开通艺人账号,流程绕经管理员。本次:组管理页第 4 个开关「允许组成员新建项目时创建艺人账号」(仅父开关开启时显示,描述收拢 tooltip)→ 开启后新建项目弹窗可填「艺人登录名+姓名」同步建号:自动入「艺人」用户组(不存在自动建,零权限)+ 获该项目 上传/下载/查看 权限;成功弹窗一次性展示登录名与初始密码(可复制)。方案经 qplan 13 轮独立盲审定稿(累计修 16 P1/60+ P2,末轮 0 P0 / 0 P1)。

## 功能点明细(编号对应方案 §3-§7;验收标准全部以方案为准)

### 后端 B1-B10

| # | 功能点 | 验收标准(细节以方案为准) |
|---|---|---|
| B1 | FGA model(poc/openfga/store.fga.yaml) | organization 增 `artist_account_creator: [user, group#member]`;变更史第 9 条;tuples 补 1 条测试 tuple;tests 补**四档**断言(组成员✓/非组员✗/仅部门身份 dave ✗/org admin ✗,照 :380-402 project_deleter 先例) |
| B2 | permissions.py | `is_org_artist_account_creator`(照 is_org_project_creator :563-576);`USER_DIRECT_RELATIONS` 补**两笔**:artist_account_creator + project_deleter 既有缺口 |
| B3 | deps.py | **仅** `require_inline_artist_creator` 组合弱门(is_org_admin ∨ (is_org_project_creator ∧ is_org_artist_account_creator),照 require_folder_templates_reader :402-439);不建零挂载单 flag dep |
| B4 | services/user_provisioning.py(**新**) | `add_user_to_group_audited`(=_add_membership 平移,ctx 化+三调用点改 import;source 默认 None;_remove_membership 不动)+ `provision_local_user`(双参 source/membership_source;lower 预检 limit(1)+first;db.refresh(new_user) 保 created_at;log.info 保留;ARTIST_GROUP_NAME 常量单点定义于此);services 层首例 HTTPException(docstring 注明) |
| B5 | models/__init__.py | ArtistAccountIn(复用 _validate_name_format)/ArtistAccountCreatedOut/ProjectCreatedOut(ProjectOut+artist_account?);ProjectCreateIn 增 artist_account。**组模型三项在 directory.py,归 B7** |
| B6 | projects.py create_project | 能力校验(default org 口径,org 解析后 :125 后)→ 用户名预检(lower,:186 后 :188 前)→ 既有流程原样 → 艺人段(ensure 艺人组+命中既有组分级日志 read_all_tuples×4 带 object_id=tenant_key → provision → 逐角色 add_project_subject(str(project_id_v), fmt_subject)×3+每角色 audit via:"artist_inline")→ db.refresh(project) → ProjectCreatedOut;409 结构化两层(预检 {code,username}/竞态 {code,username,project_id});IntegrityError 按 `uq_users_username` 收窄+先 rollback;勿用 exclude_none |
| B7 | directory.py | ① create_directory_user 薄壳化(壳内保序预检 409→load groups→provision admin_create;除 source 键与 lower 预检外零变化);② _add_membership 删除+3 调用点改服务函数(端点机械补 ctx 注入);③ 组第 4 flag 全套:DirectoryGroupOut/GroupCreateIn/GroupUpdateIn(:523-535/:538-546/:549-559)+**三处回显消费点**(:692-704/:751-757/:828-841)+POST 置位/PATCH tri-state/删组清理 :882 |
| B8 | auth.py /me | `is_artist_account_creator` 内联三段式(照 is_folder_template_manager :173-180) |
| B9 | users.py | `GET /api/v1/users/username-available`(守门 require_inline_artist_creator;Query 2-64+正则→422;返回 {available};lower 查询) |
| B10 | api/tests/test_project_artist_account.py(**新**) | 方案 §7 全部用例(本包只写不跑) |

### 前端 F1-F5

| # | 功能点 | 验收标准(细节以方案为准) |
|---|---|---|
| F1 | types.ts + client.ts | Me 增 `is_artist_account_creator?`(回落惯例);ArtistAccount/ArtistAccountCreated;**ProjectCreated 类型(Project+artist_account?)且 useCreateProject 泛型更新**;CreateProjectBody 提名导出或改内联(二选一);组类型/建组改组 body 增字段;**client.ts errorMessage 非字符串 detail 兜底**(typeof check 返回 fallback,字符串行为零变化) |
| F2 | hooks.ts | useUsernameAvailable(enabled 前置正则+长度,防半截值打 422;依赖全局 queryCache 401/403 静默,**勿写 per-query onError**——react-query v5 无此选项);useCreateProject 泛型;组 hooks body 增字段 |
| F3 | NewProjectModal.tsx | ① 艺人区(闸门 `me.is_artist_account_creator ?? me.is_system_admin`;两项全空=不传;填一项则两项必填;登录名 debounce~500ms 预检+区分性冲突文案;项目名跟随姓名(手动编辑脱钩));② 成功 Modal(closable/maskClosable/keyboard 全 false;项目/姓名/登录名/密码 copyable;警示文案;唯一按钮「我已保存，进入项目」);③ 失败特判(409 detail.code=username_taken 按 project_id 分支文案;500 中性文案;其余走 errorMessage) |
| F4 | AdminGroupsPage.tsx | ① **tooltip 收拢**:三个既有开关+新开关 extra 长文案→label 旁 Tooltip+QuestionCircleOutlined,文案不变;② 第 4 开关:Form.useWatch(can_create_project) 为 true 才渲染;**复位仅父开关 onChange true→false 转变瞬间**(setFieldValue false+置 touched;挂载时父已 false 不触发);回填/建组 initialValues;PATCH 只带改动字段;建组 POST body 增字段 |
| F5 | labels.ts + AdminAuditPage | **无改动**(复用 user_created/group_created/group_member_added/project_member_added 既有映射) |

## 数据库修改方案

方案 §2:**无**(不新增表/列/迁移;开关状态=FGA tuple,艺人组=groups 既有行)。

## 接口定义

方案 §4 为准(POST /projects 增 artist_account + ProjectCreatedOut 响应;GET /users/username-available 新增;组管理第 4 flag 全套;/me 增字段;错误码 403/409 两层/422 逐条在 §4.1 表)。

## 测试功能点

方案 §7 为准,五组:组开关与 /me / 组合流 201 全链(含艺人组零权限四 relation 断言、审计形状逐条、密码不入全库审计、跨 run 卫生容忍 404) / 权限与失败路径(403 零副作用、lower 变体 409、**存量共存对 DB 直插构造→409 非 500**、竞态形状两层单测含 patch 目标=routers.projects 命名空间) / 服务薄壳化回归(含 admin 链路 lower 预检 409 钉住) / 全量回归。

## 工作包拆分与依赖

| 包 | 角色 | 内容 | 依赖 |
|---|---|---|---|
| WP-1 后端 | 后端 | B1-B9 全部(含 FGA model yaml) | 无 |
| WP-2 前端 | 前端 | F1-F4(F5 无改动) | 无(契约=方案 §4/§6,可与 WP-1 并行) |
| WP-3 用例 | 测试 | B10 新文件(按方案 §7,只写不跑) | 无 |
| 收尾 | 任一 | scripts/changelog.md 追加 + permissions-model-v4.md 补 relation(验收通过后) | WP 全部 |

## 模糊点与决策记录

1. **无模糊点**:方案已经 qplan 13 轮盲审定稿,一切口径(执行顺序/错误优先级/审计形状与 source 常量/ORM 物化硬规/约束名收窄/开关交互与复位时机/tooltip 收拢)以方案文档为准,本文档不另行决策。
2. **测试基建**:本地隔离栈 `api/docker-compose.feat-ms.yml`(feat-ms-* 前缀,复用 api-ms-api 镜像不 build,bind mount 即时生效);模型重推用 `bash api/scripts/local_up.sh --refresh-model`(⚠ 勿跑 openfga_write_model.sh,那是远端 server2 部署脚本);容器 recreate 后 pip 层丢须重装依赖;docker cp 拷测试进容器跑;Git Bash 传容器路径须 MSYS_NO_PATHCONV=1。
3. **开发子智能体只跑 ruff/mypy 与 npm run build,不跑 pytest**(集成测试在验收阶段由 PM 起隔离栈统一跑)。
4. **开发子智能体不执行 git commit**,改动留在工作区由 PM 验收后统一提交。
5. **部署不在本周期内**(dev/prod 部署等用户指令,届时按方案 §3.2 模型先推)。

## 验收与完成标准

- 每 WP:`git diff` 逐文件核对与方案一致、无越界改动;api 侧 ruff/mypy 与基线零新增;前端 `npm run build` 过
- 集成测试:隔离栈容器内 pytest 全绿(含新用例+存量回归,基线以当前分支跑一次记录)
- 用户可见验收对照方案 §9 清单 7 条
