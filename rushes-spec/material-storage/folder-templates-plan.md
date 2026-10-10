# 目录模板（folder templates）模块 · 实施方案

> Status: **已定稿待实施**(2026-10-10;经 qplan 10 轮独立盲审,第 8 轮曾出 1 P0 已修,末轮 0 P0 / 0 P1)
> 范围:material-storage(后端 `api/` + 前端 `web/`)
> 关联:`permissions-model-v4.md`(模型依据)、`project-grant-templates-plan.md`(结构先例)
> 实施形态:单批次,后端/前端两工作包可并行(契约=本文档 §4)

---

## 0. 背景与目标

| # | 现状问题 | 目标 |
|---|---|---|
| A | 项目创建后负责人须按规范手工逐个建几十个素材分类文件夹(每次几十次 NewFolderModal 操作),耗时且易漏建/建错 | 新增**目录模板**模块:可维护多个模板,每个模板是一组目录结构;**新建项目时可选一个模板**(可选字段),一键建出指定目录树;不选模板行为与现状完全一致 |
| B | 模板维护权须收敛到少数人 | 目录模板的**管理权限放在用户组上**(与 can_create_project/can_delete_project 同款组级开关),能建项目的人都能浏览选择模板 |

命名对齐:代码/接口族用 `folder` 术语(与 `folders` 表、`folder_created` 事件、`bootstrap_folder` 对齐);UI 文案叫「目录模板」。

## 1. 总体设计决策

| # | 决策 | 理由 |
|---|---|---|
| D1 | 条目存**相对路径字符串**(`素材/视频/原始`),非自引用树 | 应用端直接复用 `ensure_folder_chain`/`ensure_root_folder_at_project` 的路径段建链;`(template_id, path)` 唯一约束天然防重;编辑器=行编辑+树预览,实现简单可靠。模板内树与 folders 邻接表不同构没关系——应用时逐级物化 |
| D2 | **应用即快照**:建项目时把条目物化为 folders 行,project 表不存模板引用(仅 audit 记 template_id) | 模板后续修改/删除不影响存量项目;无反向依赖,删模板零风险。与权限模板「叠加不删」不同——目录是一次性物化,语义更简单 |
| D3 | 应用在 `create_project` 流程内**同步执行**,位于 initial_grants 与默认模板直通之后、audit 之前;**逐条容错**(单条失败:rollback → 记 failed → 继续下一条,不炸项目创建)。**容错的前置条件:调用侧先把 audit 所需 ORM 属性拍局部变量(project.id/code/name/visibility + admin_user.id/name,六项,见 §4.2),apply 函数入口把 template 物化为纯值(见 B7)——循环与 audit 全程只摸纯值,不持任何同 session 的 ORM 对象**。机理:rollback 会无条件过期 identity_map 中的对象(session.py:23 `expire_on_commit=False` 只豁免 commit 不豁免 rollback,SQLAlchemy 2.0 `_restore_snapshot` 对全部状态 `_expire`),project/admin_user/template 均同 session 加载,任一条目 rollback 后这些对象的同步属性读都 MissingGreenlet → 500 → 两条 audit 全丢 → 用户重试撞 code 唯一约束 409 死局 | 与现有「项目行先 commit、FGA 后写」的非单事务语义一致(projects.py:194-197 注释);部分失败可凭 audit 手工补建。规模上限 200 条/400 节点,根夹按首段去重(见 B7),同步时延数百 ms~秒级可接受(与 initial_grants 50 条同量级放大;若未来超上限或要求低时延再评估 arq 异步,v1 不引入) |
| D4 | 权限:FGA model `organization` 新增 `define folder_template_manager: [user, group#member]`;组管理页加第 3 个 tri-state 开关 `can_manage_folder_templates`(tuple 即状态,DB 无列);写守门 `require_folder_template_manager`(org admin ∨ flag ∨ system admin);**读列表守门 `require_folder_templates_reader`(org admin ∨ project_creator ∨ folder_template_manager flag ∨ system admin,新增组合弱门)**——必须覆盖 flag 面,否则仅持 flag 的组成员「能写不能读」(require_admin_or_project_creator 不含该 flag,deps.py:304-330,grant-templates 先例的读放宽不可平移,因其写门是 system admin 天然被读门覆盖);/me 暴露 `is_folder_template_manager`(与 is_project_creator 同口径,前端单字段搞定入口) | 组开关全套照抄 can_delete_project 先例(directory.py:606-649 参数化 `_sync_group_org_flag`);读门用组合弱门而非照抄 grant-templates,理由如左 |
| D5 | 模板编辑器 = **行式路径编辑**(antd Form.List,每行一条相对路径)+ 只读树预览(antd Tree,由 paths 实时构建) | 与 AdminGrantTemplatesPage 行式交互一致;行式即数据,所见即所存;.gitignore/codeowners 同款业界形态。不做拖拽树编辑器(v1 复杂度不划算,antd v6 Tree 增删节点交互成本高) |
| D6 | **v1 不支持敏感目录**(条目全部普通目录) | 素材分类模板无敏感目录需求证据;敏感夹涉及「创建者自动 invited_downloader」语义(谁是创建者:项目 admin?模板应用者?)语义模糊。后续需要时加 `is_sensitive` 列+根级限制+授权决策即可,迁移成本低(YAGNI) |
| D7 | 模板归属 org(`organization_id` 列);建项目选用时校验模板 org 与项目 org 一致 | 多租户隔离防未来;当前单 default org 不受影响,服务端取 default org 同 grant templates 先例 |
| D8 | 上限:条目 ≤200/模板;**去重后节点总数 ≤400**(封顶最坏同步时延,见 §4.1 规则 7);路径深度 ≤10 段(本方案新引入口径,folder_chain 无深度常量,闭环靠 API 校验);单段 ≤255 字符/字节;整条 path ≤600 字符 **且 ≤900 UTF-8 字节**(字节限拦在保存期,防 CJK 长路径过字符校验却在应用期 key_too_long;详见 §4.1 规则 5) | 用户场景「几十个」×2 倍余量;长度护栏复用 `folder_chain.py` 既有常量口径(check_segment_name/REL_PATH_MAX_CHARS),深度/字节/节点数为方案补齐 |

## 2. 数据库修改方案

### 2.1 新表 `project_folder_templates`(头表)

| 列 | 类型 | 约束 |
|---|---|---|
| id | UUID | PK(无 server default,ORM 侧 `default=uuid.uuid4` 兜底,照 0012 先例 :31) |
| organization_id | UUID | FK organizations.id,NOT NULL |
| name | String(128) | NOT NULL;**UniqueConstraint `uq_pft_org_name`(organization_id, name)**(约束显式命名,IntegrityError→409 按名匹配,照 admin.py:320-327 先例) |
| description | String(1024) | NULL |
| created_at / updated_at | DateTime(timezone) | server_default now() / onupdate |

### 2.2 新表 `project_folder_template_entries`(条目表)

| 列 | 类型 | 约束 |
|---|---|---|
| id | UUID | PK(无 server default,同上) |
| template_id | UUID | FK project_folder_templates.id **ON DELETE CASCADE**,NOT NULL |
| path | String(600) | NOT NULL;**UniqueConstraint `uq_pft_entry_path`(template_id, path)**;相对路径,如 `素材/视频/原始`(无前后 `/`) |
| created_at | DateTime(timezone) | server_default now() |

照 `project_grant_templates` 两表写法(tables.py:369-418)。

### 2.3 迁移

- `api/app/db/migrations/versions/2026_10_10_0016_folder_templates.py`:revision `"20261010_0016"`,down_revision `"20261010_0015"`(当前链头,0015_project_soft_delete.py)
- 两表 + 两个唯一约束;downgrade = drop 两表(纯建表,照 0012 迁移惯例含 downgrade);无存量数据迁移

## 3. FGA 权限模型变更

### 3.1 `poc/openfga/store.fga.yaml` model 段

`type organization` 增加(与 project_creator/project_deleter 并列):

```fga
define folder_template_manager: [user, group#member]
```

不新增 object type、不动 condition。**tuples 段补 1 条测试 tuple**(如 `group:grp_editors#member folder_template_manager organization:tenant_demo`,照 project_deleter 先例 :163-165)+ **tests 段补断言**(组成员 check ✓/非组员 ✗,照 :367-389 成对先例;两者都补——若只补断言不补 tuple,fga test 无数据支撑必挂)+ **文件头模型变更史注释补第 8 条**(:26-27 编号惯例)。

### 3.2 部署顺序(硬性)

模型先推(`api/scripts/openfga_write_model.sh`)→ 代码 rsync → `alembic upgrade head` → restart。与 deploy-hh2 技能口径一致。

### 3.3 后端权限接入

- `api/app/deps.py`:新增 `require_folder_template_manager`(照 `require_project_deleter` :333 两支形态:is_org_admin ∨ check(user, folder_template_manager, organization);「system admin 直通」由 is_org_admin 蕴含——本仓 system admin 即 default org 的 organization#admin,require_system_admin/get_is_system_admin 同源 deps.py:194-238,勿写成三条独立支)与 **`require_folder_templates_reader`**(写法参照 `require_admin_or_project_creator` :304-330 的组合弱门形态,但**支线显式枚举,勿整抄**——其真实三支含 `has_any_project_admin`(deps.py:328,任意项目管理员),照抄会把读门扩大到全部项目 admin;新门 = is_org_admin ∨ is_org_project_creator ∨ check(user, folder_template_manager, organization),**不含** has_any_project_admin;用途:模板列表 GET,使仅持 flag 的组成员管理页可用且不外溢)。不新增 `get_is_folder_template_manager` bool 门 helper——先例 `get_is_project_creator`(deps.py:275-301)全仓零调用属死代码,project_deleter 也未加;`is_folder_template_manager` 的 /me 计算直接内联(照 auth.py is_project_creator 内联先例 :136-156),不加第三个无人消费的 helper
- `api/app/services/permissions.py`:新增 `is_org_folder_template_manager`(照 `is_org_project_creator` :559-572 风格);`USER_DIRECT_RELATIONS`(:43-65)补防御项 `("organization", "folder_template_manager")`(照 project_creator 防御性补项先例 :49;注:最近的 project_deleter(2026-10-10)未加防御项属既有不一致,本方案不扩大范围处理,仅照 creator 先例)
- `api/app/routers/auth.py` /me(:119-190,is_project_creator 内联计算 :136-156):内联计算并暴露 `is_folder_template_manager`(口径 = system admin ∨ is_org_folder_template_manager,照 is_project_creator 同款写法)

## 4. 接口定义

### 4.1 新增:`/api/v1/admin/folder-templates`(挂 admin.py,main.py 已 include)

| 方法+路径 | 守门 | 入参 | 返回/错误 |
|---|---|---|---|
| GET `/api/v1/admin/folder-templates` | require_folder_templates_reader(见 §3.3,覆盖 org admin ∨ project_creator ∨ folder_template_manager ∨ system admin) | 无 | 200 `[{id, name, description, entry_count, entries: [{path}]}]`(按 name 排序;**带全量 entries** 供 NewProjectModal 预览,模板数量少无压力);organization_id 服务端取 default org 过滤 |
| POST `/api/v1/admin/folder-templates` | require_folder_template_manager | `{name(1-128), description?(≤1024), entries: [{path}]}`(1..200 条) | 201 返回与列表项同形的单对象;重名 409;entries 空/超 200 条/路径非法/重复 path → 422(错误信息指明第几条、何因) |
| PATCH `/api/v1/admin/folder-templates/{id}` | require_folder_template_manager | 同 POST,name/description/entries 均可选;**description 显式传 null=清空**(照 admin.py:455-458 `model_fields_set` 先例,勿写成 None=不改,否则前端「清空描述」永不生效);**entries 未传=不改(对齐 grant-templates items=None 不改先例 admin.py:441-443),传则全量替换且至少 1 条** | 200;404;改名撞名 409(排除自身);entries 校验同 POST |
| DELETE `/api/v1/admin/folder-templates/{id}` | require_folder_template_manager | 无 | 204;404;级联删 entries;**不影响已建项目**(快照语义) |

**路径校验**(POST/PATCH 共用 `_validate_entry_paths`,逐条;**不做静默归一化**,非法即 422;**以 strip 后的值作为唯一校验与持久化对象**):

1. 整条 path 先 strip(仅首尾空白,strip 后的值即入库值);**以 `/` 开头或结尾 → 422**(显式拒绝首尾斜杠,不做「去首尾 /」归一化——归一化会与唯一键语义打架,`素材/` 与 `素材` 必须判非法而非等价)
2. 按 `/` 切段;**空段(连续 `//`)/段为 `.` 或 `..`/段含 `\` → 422**(复用 `folder_chain.check_segment_name` 语义,folder_chain.py:70-79)
3. 任一段首尾含空白(如 `"素材 "`)→ 422(防外观异常目录名;拒绝而非静默 strip,报错可定位)
4. 单段 >255 字符或 >255 UTF-8 字节 → 422(字符口径=Folder.name String(255) 列限;字节口径=MinIO 每 `/` 段 255B 硬限,folder_chain.py:42)
5. 段数 >10 → 422(本方案新引入的深度护栏口径,folder_chain 仅有总长护栏无深度常量;闭环依赖:条目只能经本校验过的 API 写入 DB);path 总长 >600 字符或 **>900 UTF-8 字节 → 422**(字符口径对齐 String(600)/REL_PATH_MAX_CHARS;字节口径为拦在保存期——folder_chain.check_prefix_budget 是 1024 字符/字节双口径,600 个 CJK 字符≈1800 字节能过字符校验却必在应用期 key_too_long,故保存期以 900B 设限,低于 1024B 留分隔符余量)
6. payload 内 path 重复 → 422(指明重复值)
7. **该模板全部条目去重后节点总数 >400 → 422**(各 path 按段展开去重的节点集,单模板口径非跨模板合计;封顶最坏同步时延:200 条 × 深度 10 互不共享=2000 节点≈4000 次串行 DB/FGA 往返会阻塞 POST 数十秒,400 节点内为数百 ms~秒级;满额 400 节点≈400 次串行 commit+400 次 FGA 写,FGA 单次抖到 10ms 即 4-8s——验收时对满额模板实测一次 POST 耗时确认可接受)

audit:增删改各记 **`folder_template_changed`**(details: `action`: create/update/delete、name;**create/update 额外带 entry_count**(有意增强:先例仅 create 记 items_count,admin.py:412,update/delete 只 action/name(:498/:528));键名按条目语义类比,不强求与先例同名)。守门 403 不写 audit(deps require_* 现状从不写 audit,保持惯例)。

### 4.2 改动:`POST /api/v1/projects`(projects.py:64-250)

- `ProjectCreateIn`(models/__init__.py:34-45)新增可选 `folder_template_id: UUID | None`；**不传/null → 与现状逐字节一致(零回归;未选模板时 project_created audit details 不写入 folder_template_id 等相关键——省略而非 null,防 details 恒 null 噪音)**
- 校验(在 initial_grants 校验段之后、DB 写入之前):模板不存在 → 400 `folder template not found`;模板 organization_id ≠ 项目 org → 400 `folder template belongs to another organization`
- 应用(在 `apply_default_template_grants` :229-233 之后、audit :235 之前):**先把 audit 与响应所需的 ORM 属性全部读入局部变量——清单:`project.id`(target_project_id :238)/`project.code`/`project.name`/`project.visibility`(:240-241)/`admin_user.id`(:242)/`admin_user.name`(:243),六项缺一不可**(apply 内 rollback 会过期 identity_map 中**全部**持久态对象,project 与 admin_user 同 session 加载,audit 处任一同步属性读都 MissingGreenlet,见 D3),再调 `apply_folder_template`(见 §5-B7);结果并入 `project_created` audit details(用局部值):`folder_template_id` / `created_folder_count` / `failed`(数组,每项 `{path, code}`,最多记前 10 条+`failed_count` 总数)
- 201 响应体不变(ProjectOut 不加字段;目录树前端进入项目自然可见)

### 4.3 改动:组管理(directory.py,照 can_delete_project 全套)

- GroupOut(`DirectoryGroupOut`,directory.py:523-533)增 `can_manage_folder_templates: bool`(回显走 `_read_flag_group_ids(permissions, db, "folder_template_manager")`)
- POST 建组(directory.py:698 起,:718-736 为置位+audit 段;入参与既有两 flag 统一为 `can_manage_folder_templates: bool = False`,tri-state `bool | None` 语义仅用于 PATCH)与 PATCH(:755-787)入参增 `can_manage_folder_templates: bool | None`(PATCH tri-state:None=不动/true=写 tuple/false=删 tuple);audit details 记 old/new
- 删组清理(:817-879,:844 flag 清理循环加一项)同步清 `folder_template_manager` 的 org flag tuple

## 5. 后端改动点(文件级)

| # | 文件 | 改动 |
|---|---|---|
| B1 | `api/app/db/tables.py` | ProjectFolderTemplate / ProjectFolderTemplateEntry 两模型(照 :369-418);audit event_type 枚举注释(:245-249)补 `folder_template_changed` / `folder_template_applied` |
| B2 | `api/app/db/migrations/versions/2026_10_10_0016_folder_templates.py` | §2.3 |
| B3 | `api/app/models/__init__.py` | FolderTemplateEntryIn{path} / FolderTemplateIn{name,description?,entries} / FolderTemplateEntryOut{path} / FolderTemplateOut{id,name,description,entry_count,entries};ProjectCreateIn 增 folder_template_id |
| B4 | `api/app/routers/admin.py` | folder-templates 4 端点 + `_validate_entry_paths`(照 grant-templates :330-640 就近放);403 由 deps 守门抛,端点内不写 access_denied audit(deps 惯例) |
| B5 | `api/app/deps.py` | require_folder_template_manager / require_folder_templates_reader(§3.3;不新增 get_* bool 门 helper) |
| B6 | `api/app/services/permissions.py` | is_org_folder_template_manager;USER_DIRECT_RELATIONS 补防御项 |
| B7 | `api/app/services/folder_templates.py`(**新**) | `apply_folder_template(db, permissions, audit, *, project_id, template_id, template_name, entry_paths: list[str], actor_user_id, ctx)`(audit 显式入参,照 apply_default_template_grants 先例 projects.py:229-233;**签名只收纯值**——不收 template/entry ORM 对象:rollback 过期 identity_map 后 entry.path/template.name 的属性读会 MissingGreenlet,与 D3 同雷;函数入口即持有全部纯值,循环与 audit 全程不摸 ORM):①条目按 path 字典序排序(父路径天然在前),**根夹按首段去重**(同首段只调一次 `ensure_root_folder_at_project`,folder_chain.py:292-333;结果仅在其**正常返回后**入轮内 memo——正常返回=tuple 已就位;首段失败不入 memo,**同首段后续条目各自重试 ensure(自愈语义)并各自进 failed,不做连坐跳过**);②逐条:余段用 `ensure_folder_chain`(:204-289,root_folder_id=根节点,rel_dir_parts=余段,**memo=每条目独立新建**——勿跨条目共享:folder_chain 是先写 memo 后补 tuple(folder_chain.py:271-278),本方案「失败续跑」语义下跨条目共享会在 folder_tuple_error 后留下「memo 声称就位但 tuple 缺失」的脏命中;条目独立 memo 则失败即随本条目作废,不变量不破;百度导入的跨轮共享前提是「异常即整轮作废」,与本案语义不同);③**单条任意异常捕获**(`except Exception`)→ **先 `await db.rollback()` 再记 failed 继续下一条**(rollback 必须做:session 处于 pending-rollback 态时后续条目连环 PendingRollbackError;rollback 亦会过期 identity_map 中全部对象——故调用侧与函数入口均已物化纯值,见 §4.2/D3;code 字段:FolderChainError 取其 .code,其余记 `"error"`);④`created_folder_count` 口径=应用前后各 `count(folders where project_id=…)` 差值(ensure 返回 ChainNode 不区分新建/复用,直接计数会误计;**差值=实际净增夹数,含失败条目已建成的浅层父夹(与⑤ 有意保留语义一致)**,不含被回滚的未提交写入);**应用执行完毕即记一条** audit `folder_template_applied`——**无论 failed 是否为空**(全失败也记,凭 audit 才能手工补建;勿按字面「成功后」漏记;details: template_id/template_name/created_folder_count/failed;批量操作记汇总,不逐夹记 folder_created——与百度导入批量不逐夹记 audit 同风格);⑤深层条目失败时其已建成的浅层父夹有意保留(独立 commit,便于手工补建,验收时不视为脏数据;若 failed 含 folder_tuple_error,手工补建应**整模板重跑**(ensure 幂等),不能只补 failed 路径——tuple 缺失不总在 failed 条目自身) |
| B8 | `api/app/routers/projects.py` | create_project:payload 校验 + §4.2 挂接(:229-233 后) |
| B9 | `api/app/routers/directory.py` | 组开关第 3 个 flag 全套(§4.3) |
| B10 | `api/app/routers/auth.py` | /me 增 is_folder_template_manager |
| B11 | `api/tests/test_folder_templates.py`(**新**) | §7 |

依赖链(建议实施序,非硬约束;B4 实际还依赖 B1/B5/B6,B8 依赖 B7):B1→B2→B3→(B4,B7,B8);B6→(B5,B9,B10);B11 依赖全部。B7 复用 folder_chain 既有函数,**不改动 folder_chain.py 本身**(新项目无 sensitive 夹、无并发,既有断言天然满足;深度护栏在 API 校验层闭环,folder_chain 不复检深度,前提=条目只能经校验过的 API 写入 DB)。

## 6. 前端改动点(文件级)

| # | 文件 | 改动 |
|---|---|---|
| F1 | `web/src/api/types.ts` | FolderTemplate/FolderTemplateEntry 类型;Me 增可选 `is_folder_template_manager?`(照 is_project_deleter? types.ts:15-17 注释+回落惯例) |
| F2 | `web/src/api/hooks.ts` | useFolderTemplates/useCreateFolderTemplate/useUpdateFolderTemplate/useDeleteFolderTemplate(照 useGrantTemplates :734);useCreateProject body 增 folder_template_id?(hooks.ts:178-200) |
| F3 | `web/src/pages/AdminFolderTemplatesPage.tsx`(**新**) | 照 AdminGrantTemplatesPage(403 行):列表(name/description/entry_count/操作)+编辑 Modal——基本信息 + **条目区 Form.List**(每行 Input 相对路径+删除,底部「添加目录」)+右侧/下方**只读树预览**(纯函数 paths→treeData,按 `/` 切裂,antd Tree);前端校验提示(空行/重复行/段非法);权限:页面路由可达即渲染,写操作失败按 403 提示 |
| F4 | `web/src/App.tsx` | lazy import + Route `/admin/folder-templates`(:28-31,:68-71) |
| F5 | `web/src/components/AppHeader.tsx` | NavChip「目录模板」(:101-115 NavChip 区块),闸门 `me.is_folder_template_manager ?? me.is_system_admin`(与 NewProjectModal 入口闸门同款回落写法) |
| F6 | `web/src/components/NewProjectModal.tsx` | 目录模板区(初始权限区之后):Select 可选项=「不使用模板(默认)」+模板列表(**useFolderTemplates 传 `enabled: open`**,照 useGrantTemplates(NewProjectModal.tsx:65)关闭态不取数,免无谓 403);选中模板显示**树预览+条目数**;提交带 folder_template_id(不选不传);提示文案:目录将在项目创建后自动建立 |
| F7 | `web/src/lib/labels.ts` + `web/src/pages/AdminAuditPage.tsx` | labels 补 `folder_template_changed: '目录模板变更'` / `folder_template_applied: '目录模板应用'`(:33 风格);AdminAuditPage 的 EVENT_TYPES 预设下拉(:39-49 硬编码)同步补这两个事件(否则只能手输检索) |
| F8 | `web/src/pages/AdminGroupsPage.tsx` + `web/src/api/hooks.ts` + `web/src/api/types.ts` | 组管理页第 3 个 tri-state 开关「管理目录模板」:编辑 Modal 照现有 can_create_project/can_delete_project 开关全套(:211-226 只带改动字段的 PATCH、:255-257 回填、:264-273 Switch Form.Item);**建组态与编辑态均展示**(对齐 §4.3 POST 契约,照 can_create_project 形态,勿照 can_delete_project 的仅编辑态 `{isEdit && …}` 形态);hooks.ts 建组/改组 body(hooks.ts:648-673)与 types.ts 组镜像类型同步加 `can_manage_folder_templates?` |

前端不做模板管理页的 org 切换(单 org 现状);F3 编辑 Modal 的树预览与 F6 共用一个 paths→treeData 纯函数(放 `web/src/utils/`)。

## 7. 测试功能点(`api/tests/test_folder_templates.py` + 增补)

fixture 照 test_v4_permissions.py:50-61;建组照 test_directory.py:124-133;容器内跑,前置 seed_demo_data + **本地栈 `bash api/scripts/local_up.sh --refresh-model` 重推含 `folder_template_manager` 的 model**(feat-ms 复用同一 store;local_up.sh:111-113 已有 model 时默认跳过,不 refresh 不生效)。⚠ 勿用 `api/scripts/openfga_write_model.sh`——那是 §3.2 的 hh2 远端部署步骤,默认 HOST 即 server2,本地测试期误跑会把未随版模型推上远端。

**模板 CRUD**
- CRUD cycle:POST→201 / GET 列表含条目 / PATCH 全量替换 entries→200 / DELETE→204 且级联删
- 重名 409(POST 撞名;PATCH 改名撞名;PATCH 原名放行)
- entries 空 → 422;超 200 条 → 422;重复 path → 422;**去重后节点总数 >400 → 422**(构造:150 条首段互异的三段路径=450 节点,≤200 条不触条数规则;勿用 201 条一级路径——会先撞「超 200 条」且 201 节点本就 ≤400);路径非法逐项 422:`..` 段/空段(`a//b`)/**首或尾 `/`**(`素材/`、`/素材`)/段含 `\`/段首尾空白/单段 256 字符/深度 11 段/总长 601 字符(多段构造,单段 601 会先撞段长规则)/**总长超 900 字节**(多段构造:4 段×76 个 CJK 字符=304 字符≤600、4×228=912 字节>900、每段≤255、深度 4≤10——勿用单段 301 个 CJK,单段 >255 字符会先撞段长规则,字节分支根本没测到)
- PATCH 不传 entries → 条目不变;PATCH 传空 entries → 422(§11:清空=删模板);**PATCH description 三态:不传 → 不变 / 显式 `"description": null` → 清空 / 传值 → 更新**(钉死 §4.1 的 model_fields_set 语义,防实现写成 None=不改)
- PATCH/DELETE 不存在 id → 404

**权限**
- 无 flag 的普通 project_creator:GET 200 / POST·PATCH·DELETE → 403(deps 守门抛,不写 audit——deps 惯例,勿断言 access_denied 事件)
- **仅项目管理员**(某项目 admin,非 org admin 非 project_creator 无 flag):GET → 403(钉死读门不含 has_any_project_admin)
- **仅持 flag 用户**(被置 can_manage_folder_templates 的组成员,非 org admin 非 project_creator):GET 200 + POST 201(读门 require_folder_templates_reader 覆盖 flag 面,防「能写不能读」)
- **/me 字段**:flag 置位组成员 GET /me → `is_folder_template_manager: true`;同组撤销后 → false;无关联用户恒 false(照 test_me_evan 先例仿写;auth.py /me 返回 dict 手拼无 schema 约束,漏写不报错,故必须显式测)
- 组开关:建组置 can_manage_folder_templates=true → 组成员 POST 201;PATCH tri-state None → flag 不动;false → 组成员写 403
- org admin / system admin 写直通 201

**项目创建应用**
- 带 folder_template_id 建项目 → 201;folders 表逐级就位(parent_folder_id 链+minio_prefix 拼接正确);FGA parent tuple 可查(read_all_tuples)
- 模板含前缀重叠条目(`素材` + `素材/视频/原始`)→ **只建 3 个夹**(去重节点集:素材、素材/视频、素材/视频/原始),无重复无报错(ensure 幂等复用);断言 parent 链与 minio_prefix(`素材/`、`素材/视频/`、`素材/视频/原始/`)
- 不带 folder_template_id → 项目无额外 folders(现状回归)
- folder_template_id 不存在 → 400;跨 org 模板 → 400(测试构造:先插第二个 organizations 行,再直改模板 organization_id 指向它——organization_id 是 FK,跳过插行会违反外键;**此直改是必须的**:POST/PATCH 模板服务端只取 default org,第二个 org 无法经 API 产生,测试注释写明原因防后人「顺手修掉」)
- audit:project_created details 含 folder_template_id/created_folder_count;folder_template_applied 一条;folder_template_changed 各操作一条

**回归**
- 全量集成测试绿(`api/tests` 全跑,基线 435 个测试函数);重点回归文件:test_grant_templates / test_default_template / test_project_creator / test_v4_permissions / test_directory / test_project_soft_delete
- 手工建夹 POST /folders 行为不变

## 8. 实施批次与工作包

单批次交付(qdev 一个周期):

| 包 | 角色 | 内容 | 依赖 |
|---|---|---|---|
| WP-1 后端 | 后端 | B1-B11 全部(含 FGA model yaml 改动+测试) | 无 |
| WP-2 前端 | 前端 | F1-F8 全部(含 AdminGroupsPage 第 3 开关) | 无(契约=§4/§6,可与 WP-1 并行) |
| 收尾 | 任一 | 仓库根 `scripts/changelog.md` 当天分节追加本功能条目(AGENTS.md 变更记录约定);`rushes-spec/material-storage/permissions-model-v4.md` 补 `folder_template_manager` relation 与读写两守门口径(CLAUDE.md 钦定改权限代码必同步的正文) | WP-1+WP-2 完成 |

验收顺序:WP-1 隔离栈(feat-ms)pytest 全绿 → WP-2 `npm run build` 过 + 本地 vite 联调 → dev 部署验证(模型先推!)。

## 9. 验收标准(用户可见)

1. 管理后台出现「目录模板」入口(org admin/被授权组可见);可新建模板(名称+若干目录路径),编辑区所见即所得(行编辑+树预览)
2. 组管理页组编辑出现第 3 个开关「管理目录模板」;置位后组成员可维护模板,未置位不可
3. 新建项目弹窗出现「目录模板」下拉(默认「不使用模板」);选中后显示目录树预览;创建成功进入项目,目录树一次到位
4. 不选模板新建项目:与改动前行为完全一致
5. 审计页可检索「目录模板变更/目录模板应用」事件,中文映射正常

## 10. 风险与边界

| 风险 | 应对 |
|---|---|
| FGA model 变更未先推 → check 报 unknown relation | 部署硬顺序 §3.2;`USER_DIRECT_RELATIONS` 防御项在 model 未部署时被 continue 容错(既有先例) |
| 目录应用部分失败 | 逐条容错 §1-D3(audit 依赖值先拍局部变量,防 rollback 过期炸 audit);failed 明细进 audit;项目已建可手工补建;不回滚(与现有非单事务语义一致) |
| 条目间前缀重叠/乱序 | 字典序排序保证父先子后;ensure 幂等复用兜底一切重叠 |
| 深层条目失败残留浅层父夹 | 有意保留(逐夹独立 commit,便于手工补建);failed 明细含 path+code 可定位;验收时不视为脏数据 |
| 手工补建撞 sensitive 同名夹 | 整模板重跑时 ensure 会因同名 sensitive 夹抛 target_sensitive_chain(folder_chain.py:164-170),该条目进 failed;需先改名/移除冲突夹再重跑(概率极低:模板应用后短期内手工建同名敏感夹) |
| 并发建项目同名夹竞态 | 新项目目录为空无竞态;ensure 的 IntegrityError 改查复用兜底(folder_chain.py:253-267) |
| 模板删除影响存量 | 快照语义零影响(§1-D2) |
| 200 条上限的同步时延 | 数百 ms 级,与 initial_grants 同量级放大;如未来超上限需求再评估异步(arq),v1 不引入 |
| 超长路径击穿 minio_key 列限 | 段 255B/prefix 1024 双口径护栏(ensure 内部 check_prefix_budget 兜底,失败条目进 failed 列表) |

## 11. 明确不做(v1 边界)

- 敏感目录条目(D6)
- 模板默认项/项目后补应用(仅创建时应用一次;存量项目不回溯——需要时另做「按模板补建」入口)
- 模板复制/导入导出、条目拖拽排序、组织级模板共享市场
- user 直授 folder_template_manager 的管理 UI(模型留口,UI 只做组开关,同 project_creator 现状)
- **entries 清空**:PATCH 的 entries 至少 1 条(空 → 422);「清空模板」语义 = 删模板重建,不提供空条目模板
