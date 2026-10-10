# qdev 需求文档 · 目录模板模块实施

> 日期:2026-10-10 · 需求来源:**`rushes-spec/material-storage/folder-templates-plan.md`(qplan 10 轮盲审定稿版,commit 56658c4)** —— 本文档是实施派发口径;**方案文档是唯一需求权威**,本文档与其冲突时以方案为准。
> 分支:`feat/folder-templates`(自 `qplan/dir-template-module` 56658c4 检出)
> worktree:`E:\qbb\github_not_me\rushes-lab-feat-folder-templates`

## 背景与目标

项目创建后负责人须手工建几十个素材分类目录,耗时且易漏建。本次新增**目录模板**模块:模板 CRUD(每个模板=一组目录相对路径)+ 新建项目时可选模板一键建目录(不选=现状零回归)+ 管理权限放用户组(FGA `organization#folder_template_manager` + 组管理页第 3 个 tri-state 开关)。方案经 qplan 10 轮独立盲审定稿(第 8 轮曾出 1 P0 已修,末轮 0 P0 / 0 P1)。

## 功能点明细(逐条可验收,编号对应方案 §5/§6)

### 后端 B1-B11

| # | 功能点 | 验收标准 |
|---|---|---|
| B1 | 两表模型+event_type 注释 | `project_folder_templates`/`project_folder_template_entries`(tables.py,照 :369-418 先例;约束显式命名 `uq_pft_org_name`/`uq_pft_entry_path`);audit 枚举注释补两事件 |
| B2 | 迁移 0016 | `2026_10_10_0016_folder_templates.py`,rev `20261010_0016`/down `20261010_0015`,含 downgrade(drop 两表) |
| B3 | Pydantic 模型 | FolderTemplateEntryIn/In/Out 族 + ProjectCreateIn 增 `folder_template_id: UUID \| None` |
| B4 | folder-templates 4 端点(admin.py) | GET(require_folder_templates_reader)/POST·PATCH·DELETE(require_folder_template_manager);`_validate_entry_paths` 七条规则(方案 §4.1);PATCH description 显式 null=清空(model_fields_set 先例 admin.py:455-458);entries 未传=不改/空=422/全量替换;409 按约束名映射 |
| B5 | deps 两守门 | `require_folder_template_manager`(两支:is_org_admin ∨ flag)/`require_folder_templates_reader`(is_org_admin ∨ is_org_project_creator ∨ flag,**不含** has_any_project_admin,勿整抄 :304-330);不加 get_* bool helper |
| B6 | permissions | `is_org_folder_template_manager`;USER_DIRECT_RELATIONS 补防御项 |
| B7 | 应用服务(新文件 services/folder_templates.py) | 签名**只收纯值**(template_id/template_name/entry_paths);字典序排序+根夹按首段去重(正常返回后入 memo)+条目独立 memo;except Exception → 先 rollback 再记 failed 继续;created_folder_count=前后 count 差值;**无论 failed 是否为空都记一条** `folder_template_applied`;五项细节见方案 §5-B7 |
| B8 | create_project 挂接 | 校验(不存在/跨 org → 400);**调 apply 前物化六项纯值**(project.id/code/name/visibility + admin_user.id/name);audit details 用局部值;未选模板不写相关键 |
| B9 | 组开关第 3 个 flag | DirectoryGroupOut 回显/POST(`bool = False`)/PATCH tri-state/删组清理 :844 加一项,全套照 can_delete_project |
| B10 | /me 字段 | auth.py 内联计算 `is_folder_template_manager`(照 is_project_creator 内联写法) |
| B11 | FGA model yaml | model 段 organization 加 `folder_template_manager: [user, group#member]`;tuples 段补 1 条测试 tuple+tests 段成对断言+文件头变更史第 8 条 |

### 前端 F1-F8

| # | 功能点 | 验收标准 |
|---|---|---|
| F1 | types.ts | FolderTemplate 族 + Me 增可选 `is_folder_template_manager?`(回落注释惯例) |
| F2 | hooks.ts | 4 个模板 hooks(照 useGrantTemplates :734,支持 enabled)+ 组 hooks body 增字段 + useCreateProject 增 folder_template_id? |
| F3 | AdminFolderTemplatesPage(新) | 列表+编辑 Modal:Form.List 行式路径编辑+只读树预览(paths→treeData 纯函数);前端校验提示 |
| F4 | App.tsx | lazy + Route `/admin/folder-templates` |
| F5 | AppHeader.tsx | NavChip「目录模板」,闸门 `me.is_folder_template_manager ?? me.is_system_admin` |
| F6 | NewProjectModal.tsx | 目录模板 Select(默认「不使用模板」;useFolderTemplates 传 enabled:open)+树预览+提交 folder_template_id(不选不传) |
| F7 | labels.ts + AdminAuditPage | 两事件中文映射 + EVENT_TYPES 预设补两项 |
| F8 | AdminGroupsPage 第 3 开关 | 「管理目录模板」tri-state,**建组态与编辑态均展示**(照 can_create_project 形态,勿照 can_delete_project 仅编辑态) |

## 数据库修改方案

方案 §2 为准:两新表(path String(600)、约束显式命名、PK 无 server default 由 ORM uuid4 兜底)、迁移 0016、无存量迁移。

## 接口定义

方案 §4 为准(4 个新端点+POST /projects 增可选 folder_template_id+组 PATCH 增字段);错误码 400/404/409/422 逐条在方案 §4.1 表。

## 测试功能点

方案 §7 为准,四组:模板 CRUD/权限(含「仅项目管理员 GET 403」「仅持 flag 用户 GET 200+POST 201」/me 字段三态)/项目创建应用(3 夹断言/前缀重叠/400 两例/audit)/回归(全量 pytest,基线 435)。

## 工作包拆分与依赖

| 包 | 角色 | 内容 | 依赖 |
|---|---|---|---|
| WP-1 后端 | 后端 | B1-B11 全部(含 FGA model yaml) | 无 |
| WP-2 前端 | 前端 | F1-F8 全部 | 无(契约=方案 §4/§6,可与 WP-1 并行) |
| WP-3 用例 | 测试 | 新文件 `api/tests/test_folder_templates.py`(按方案 §7,只写不跑) | 无 |
| 收尾 | 任一 | scripts/changelog.md 追加 + permissions-model-v4.md 补 relation(验收通过后) | WP 全部 |

## 模糊点与决策记录

1. **无模糊点**:方案已经 qplan 10 轮盲审定稿,一切口径(算法/错误码/表结构/守门支线/audit 键名/memo 语义/rollback 纯值物化清单)以方案文档为准,本文档不另行决策。
2. **测试基建**:本地隔离栈 `api/docker-compose.feat-ms.yml`(feat-ms-* 前缀,复用 api-ms-api 镜像不 build,bind mount 即时生效);模型重推用 `bash api/scripts/local_up.sh --refresh-model`(⚠ 勿跑 openfga_write_model.sh,那是远端 server2 部署脚本);容器 recreate 后 pip 层丢须重装依赖;docker cp 拷测试进容器跑。
3. **开发子智能体只跑 ruff/mypy 与 pnpm build/lint,不跑 pytest**(集成测试在验收阶段由 PM 起隔离栈统一跑)。
4. **部署不在本周期内**(dev/prod 部署等用户指令,届时按方案 §3.2 模型先推)。

## 验收与完成标准

- 每 WP:`git diff` 逐文件核对与方案一致、无越界改动;ruff/mypy 与基线零新增;前端 `npm run build` 过
- 集成测试:隔离栈容器内 pytest 全绿(含新用例+存量回归,基线 435)
- 用户可见验收对照方案 §9 清单 5 条
