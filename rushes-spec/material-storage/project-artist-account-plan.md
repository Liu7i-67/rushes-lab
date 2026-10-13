# 组长建项目内嵌创建艺人账号（artist account inline）· 实施方案

> Status: **已定稿待实施**（2026-10-13；经 qplan 13 轮独立盲审，累计修复 16 项 P1 / 66 项 P2，末轮 0 P0 / 0 P1 / 3 项 P2 已采纳）
> 范围：material-storage（后端 `api/` + 前端 `web/`）
> 关联：`permissions-model-v4.md`（模型正本，收尾须同步）、`folder-templates-plan.md`（组开关第 3 flag 与服务抽取先例）、`project-grant-templates-plan.md`
> 实施形态：单批次，后端/前端两工作包可并行（契约=本文档 §4）

---

## 0. 背景与目标

| # | 现状问题 | 目标 |
|---|---|---|
| A | 组长（组级 `project_creator`）已可为艺人建项目，但艺人账号须管理员先在管理后台手工开通——流程绕经管理员，一个业务动作被切成两段两个人 | 新建项目时组长可直接填「艺人登录名 + 姓名」同步开通账号：自动加入「艺人」用户组（不存在则自动创建，默认零权限），并自动获得该项目的**上传/下载/查看**权限；创建成功后一次性展示登录名与默认密码（可复制） |
| B | 组管理页开关渐多，每条开关的长描述文案（extra）挤压布局 | 组管理页全部开关的描述文案统一收拢进 label 旁的 tooltip 问号图标 |

命名对齐：FGA relation 用 `artist_account_creator`；组管理 API 字段用 `can_create_artist_account`（对齐 `can_create_project` 命名族）；前端 `/me` 字段 `is_artist_account_creator`。

## 1. 总体设计决策

| # | 决策 | 理由 |
|---|---|---|
| D1 | 授权走**组级 FGA flag**（organization 新 relation `artist_account_creator`，组管理页第 4 个开关「允许组成员新建项目时创建艺人账号」），全套照 `can_manage_folder_templates` 先例（tuple 即状态，DB 无列） | 账号创建权从系统管理员下放给组长是显式扩权，必须可授权、可收回、可审计；照 project_creator/project_deleter/folder_template_manager 三先例，管理员在组管理页一处管控 |
| D2 | 子开关与父开关（`can_create_project`）**后端正交**：API 允许任意组合，父关子开 = 惰性（子开关本身不产生任何能力，能力判定永远 = 「能建项目」∧「能内嵌建号」两层相与）；「父关时子开关隐藏并复位」只是前端交互行为 | 后端强制蕴含会把简单 flag 校验变成组合约束，且与既有三 flag 的正交惯例不一致；惰性组合语义简单自明 |
| D3 | **扩展现有 `POST /api/v1/projects`**（可选字段 `artist_account`），不建新端点、不做前端多接口编排 | 复用该端点全部既有校验/initial_grants/默认模板直通/目录模板/审计；前端编排（先建号后建项目）会留孤儿账号窗口，网络中断时状态漂移；新端点则要复制整套项目校验 |
| D4 | 端内执行顺序：**能力校验 → 用户名预检 → 建项目 → 确保「艺人」组 → 建用户 → 加组 → 授项目角色 → 响应**。最常见的失败（登录名冲突）被预检挡在「零副作用」阶段（项目未建）；预检后仍撞 unique 的极小竞态窗口：**同字面竞态由 DB 约束兜底**（`uq_users_username` 拦截→409 带 project_id）；**大小写变体并发不受约束拦截**（该约束区分大小写、无 lower 表达式索引，`evan`/`Evan` 双双通过 lower 预检后可同时落库——彻底解法为 `lower(username)` 函数唯一索引，需 alembic 迁移，v1 不做、留待后续），此时项目已建、艺人未加（首次时「艺人」组可能也已建——零成员零权限，下次复用无害）——可恢复状态，409 响应体带 `project_id` 供前端引导 | 同讨论定稿：宁可留「项目在、成员缺」也不留孤儿账号（孤儿账号散在艺人组里无法自清理，缺成员的项目可在成员管理补授权）；账号只在项目建成后才创建 |
| D5 | 「艺人」组按名 get-or-create：`select(Group).where(name=="艺人")`，未命中则 `Group(name="艺人", description="系统自动创建：新建项目时内嵌开通的艺人账号默认归入此组")`；撞 name unique（并发自建竞态）→ rollback → 回查复用（回查路径不写审计不警告——赢家请求同链路刚建并已写审计）；**`group_created`（含 source）仅在实际新建组成功时写，命中既有组/回查复用一律不写**。三条路径的观测口径：首次 insert 成功 → audit `group_created` details 增 `source: "project_artist_inline"`；select 命中既有组 → `log.warning`（见下）；竞态回查复用 → 静默。**组默认零权限**（不写任何 org flag tuple），只是组织归类桶——艺人的访问能力全部来自项目级 tuple。**零权限论证只对「本次自建」的组成立**：若命中**既有**同名组（管理员把带 flag 的组改名成「艺人」、或预建过同名组），该组可能带权限面——命中既有组时读该组四个 org flag 的置位状态并**分级记日志**：全空 → `log.info`（常规复用，防 WARNING 常态噪音）；任一置位 → `log.warning`（真风险才告警），把静默风险变成可观测（无告警通道的现状下，日志是唯一抓手） | 讨论定稿：组的权限面为零时，按名查找的最坏失效后果只是多一个桶，无安全影响，不值得做组 ID 配置化（YAGNI）；「命中既有组」分支以日志观测兜底 + §10 运维指引（勿改名成「艺人」/勿预建同名组）双保险 |
| D6 | 建用户逻辑**抽共享服务** `services/user_provisioning.py`：`provision_local_user(...)`（重名预检→临时密码→哈希→User 落库→org member tuple→逐组入组→`user_created` 审计）+ `add_user_to_group_audited(...)`（现 directory.py 私有 `_add_membership` 平移为公共函数，3 处调用点改 import，**行为不变**——ip/ua 取法 ctx 化与签名细节以 B4 为准，D6 不另立口径）。`directory.create_directory_user` 薄壳化为「加载组 → 调服务」（除 D7 additive 的 source 键与 lower 预检修复外行为零变化） | 密码生成/哈希/must_change_password/入组/审计这段逻辑必须单一实现，否则两处漂移（密码策略改一处漏一处）；平移而非复制避免双份 `_add_membership` |
| D7 | `user_created` audit details **增补 `source` 键**（`"admin_create"` / `"project_artist_inline"`）， additive 变更。**入组审计 source 分开写死**：admin 链路 `group_member_added` 的 source 保持既有 `"user_create"` 原值不变；内嵌链路的三类审计（`user_created` / `group_created` / `group_member_added`）**统一用同一常量 `"project_artist_inline"`**——运维过滤口径如实声明：按 `source=project_artist_inline` 拉出三类事件 + 按 `via=artist_inline` 另拉 `project_member_added`（D8 的 via 形状对齐 initial_grants 是实现约束，不改），合计覆盖整条内嵌链路。provision 仍收**两个**参数（`source` 落 user_created、`membership_source` 落逐组入组审计），防实现把单值直通造成 admin 链路 source 静默从 `user_create` 变 `admin_create`（test_directory 无 source 断言，测试钉不住，必须正文写死） | 操作者字段只区分「谁操作」，不区分「哪条链路」；org admin 也可能走内嵌链路，source 补齐可溯性 |
| D8 | 艺人项目角色**固定** `["uploader","downloader","viewer"]`（=上传/下载/查看），不走 SubjectPicker、不接受入参指定；实现**照 initial_grants 同款循环**（projects.py:219-243，:215-218 为注释）：`roles = [r for r in PROJECT_ROLES if r in set(...)]` 归一后**逐角色**调 `add_project_subject(project_id=…, subject=fmt_subject("user", str(new_user.id)), role=role)`（该函数签名为单角色，permissions.py:303-318，签名在 :303-305），幂等跳过 `is_already_exists_error`；审计**每角色一条** `project_member_added`，detail `{subject, role, kind:"user", via:"artist_inline"}`（形状与既有 `via:"initial_grants"` 路径逐点对齐，projects.py:232-243） | 组长无角色分配决策需求，固定面最小化权限；逐角色循环+单条审计形状与既有 initial_grants 路径同构，零新语义 |
| D9 | **不做「选择已有艺人」**：登录名冲突时明确报错引导（预检 409 / 提交 409），不提供检索已有用户复用入口 | 业务定稿：一艺人一项目、项目名=艺人名，艺人已存在则不会再建第二个项目；该判断由 409 报错文案兜底（防打错字与非艺人职员登录名撞名） |
| D10 | 一次性密码：仅 `POST /projects` 201 响应体 `ProjectCreatedOut.artist_account.temporary_password` 回显，不落 audit/log；响应模型与 GET 列表/详情的 `ProjectOut` 分离 | 照 `UserCreateOut`「只回显一次」语义；复用 ProjectOut 会让 GET 也带出可空密码字段，泄漏面与语义都不对 |
| D11 | 前端艺人区闸门 `me.is_artist_account_creator ?? me.is_system_admin`（照 `is_project_creator` 回落惯例）；登录名与姓名**两项全空 = 不创建艺人账号**（纯项目创建，现状行为）；项目名自动跟随艺人姓名（项目名一旦被手动编辑即脱钩） | flag 关闭者弹窗与现状行为一致（零回归）；全空跳过避免「只想建项目的人被迫填艺人」 |
| D12 | 用户名可用性预检端点 `GET /api/v1/users/username-available`（守门 = `require_inline_artist_creator`，与内嵌建号真实能力同构：`is_org_admin` ∨ (`is_org_project_creator` ∧ `is_org_artist_account_creator`)），前端在登录名输入停顿后调用，冲突即表单报错 | 把 409 尽量挡在提交前（讨论定稿）；合取守门使「能预检者必能提交」成立，availability 的信息量 ≯ 提交期 409，且整个 username 枚举面不大于既有 `GET /api/v1/users` 弱门列表（users.py:37-76） |
| D13 | 组管理页全部开关的 extra 长文案收拢为 label 旁 Tooltip 问号图标（antd Tooltip + QuestionCircleOutlined），文案内容不变 | 用户明确要求：开关渐多影响布局 |

## 2. 数据库修改方案

**无**。不新增表、不新增列、无 alembic 迁移：

- 新开关状态 = FGA org flag tuple（`_sync_group_org_flag` 既有机制，DB 无列）；
- 「艺人」组 = `groups` 表普通行 + `GroupMembership` 既有行；
- 艺人用户 = `users` 表普通行；
- 项目授权 = 既有 project 级 FGA tuple。

## 3. FGA 权限模型变更

### 3.1 `poc/openfga/store.fga.yaml`

- model 段 `type organization` 增加（与三个既有 relation 并列）：

```fga
define artist_account_creator: [user, group#member]
```

- 文件头模型变更史注释追加**第 9 条**（:26-31 编号惯例）：`9. 2026-10-13(艺人账号内嵌):organization 增 artist_account_creator: [user, group#member]——组级「新建项目时创建艺人账号」开关,与 project_creator 同款模式;改后须重推 model`。
- tuples 段补 1 条测试 tuple（如 `group:grp_editors#member artist_account_creator organization:tenant_demo`，照 project_deleter 先例）。
- tests 段补断言（照 :347-427 先例，**四档对齐** project_deleter :380-402 形态，org admin ✗ 档在 :397-402）：组成员 check `artist_account_creator` ✓ / 非组员 ✗ / **仅部门身份（dave，department#member）✗**（钉住不随 department 递归扩散，model 中 department 仍在）/ org admin 不自动蕴含 ✗。

### 3.2 部署顺序（硬性）

模型先推（`api/scripts/openfga_write_model.sh`，hh2 远端步骤）→ 代码 rsync →（本次**无** alembic 迁移）→ restart。与 deploy-hh2 技能口径一致。

**回滚方向**：model 只前滚不回退——代码回滚后旧代码不读新 relation，多出的 relation 无害；反之回推旧 model 会使新代码 check `artist_account_creator` 报 unknown relation。故回滚场景 = 仅回滚代码、model 保留。

### 3.3 后端权限接入

- `api/app/services/permissions.py`：新增 `is_org_artist_account_creator`（照 `is_org_project_creator` :563-576 风格）；`USER_DIRECT_RELATIONS`（:43-69）补防御项 **两笔**：`("organization", "artist_account_creator")`（照 project_creator 先例 :49）+ `("organization", "project_deleter")`（**顺带补齐既有缺口**——project_deleter relation 自 2026-10-10 上线以来一直无防御项，folder-templates 方案当时明确「不扩大范围处理」遗留至今，本次触达同一常量，一行补齐恢复「每个组级 flag 都有防御项」不变量）。
- `api/app/deps.py`：仅新增 **`require_inline_artist_creator`**（组合弱门 = `is_org_admin` ∨ (`is_org_project_creator` ∧ `is_org_artist_account_creator`)，照 `require_folder_templates_reader` :402-439 组合门先例，挂 §4.2 username-available 端点）。**不另建零挂载的单 flag dep**——POST /projects 的能力校验依赖 payload 只能端点内加验（§4.1），/me 走内联计算，单 flag 形态的 `require_artist_account_creator` 全方案无消费点，照 deps.py:413-415「不新增零调用 helper」惯例砍掉。守门 403 不写 audit（deps 惯例）。
- `api/app/routers/auth.py` /me：内联计算并暴露 `is_artist_account_creator`（口径 = `bool(is_system_admin)`，非 system admin 时 `is_org_artist_account_creator`，try/except 回 False——照 `is_folder_template_manager` :173-180 同款写法）。

## 4. 接口定义

### 4.1 扩展：`POST /api/v1/projects`（projects.py:66-308）

**入参**：`ProjectCreateIn` 增可选字段（models/__init__.py）：

```python
class ArtistAccountIn(BaseModel):
    """内嵌开通艺人账号(组长建项目同步建号)。字段约束与 UserCreateIn 同款。"""
    username: str = Field(..., min_length=2, max_length=64, pattern=r"^[a-zA-Z0-9._-]+$")
    name: str = Field(..., min_length=1, max_length=128)

    @field_validator("name")
    @classmethod
    def _name_format(cls, v: str | None) -> str | None:
        # 复用 UserCreateIn 同款校验器(models/__init__.py:482-493/:526-529):
        # strip + 拒绝全空白,防止纯空格姓名过 422
        return _validate_name_format(v)

# ProjectCreateIn 增:
artist_account: ArtistAccountIn | None = None
```

不传/null → 行为与现状一致（响应仅多一个恒为 `null` 的 `artist_account` 键，见响应段；零回归锚点按语义断言——项目建成、无新用户）。

**守门**：既有 `require_project_creator` 不变；`artist_account` 存在时**端点内加验**：`is_org_admin(user) ∨ is_org_artist_account_creator(user)`，不过 → 403（不写 audit，照 deps 惯例；因依赖 payload 内容，无法用声明式 dep）。

**执行顺序与错误码**：

| 阶段 | 失败 | 结果 |
|---|---|---|
| 1. Pydantic 校验（artist_account 字段约束） | 422 | 零副作用 |
| 2. artist 能力校验（上；**放在 org/tenant_key 解析之后**（:109-125 既有段后、预检之前，仍零副作用），**check 打在 default org 上（`get_default_organization` 口径，与 require_project_creator deps.py:256-264 及全部既有组 flag 门同构；项目 org 仅用于建项目本身**——org flag tuple 只写在 default org，用项目 org 会使非 default org 的存量用户在 dep 通过后被此处误吃 403）。**排序理由：权限拒绝优先于 DB 前置深校验**——403 尽早抛可省后续至多 4 次前置 DB 查询（Pydantic 422 在框架层必然最先，无法也无需后置；此处的「尽早」仅相对 :127-186 深校验段而言）；与阶段 3「既有 400/422 优先于 409」的口径不同属有意为之） | 403 `artist account creation not allowed / 无内嵌创建艺人账号权限`（双语，照 deps.py:212/270/362 惯例） | 零副作用 |
| 3. **用户名预检**（`select(User).where(func.lower(User.username) == username.lower()).limit(1)` + `.first()` 命中即占用——**消费语义写死：limit(1)+first 或 EXISTS，多行命中一律视为已占用 409**，勿抄现状 `scalar_one_or_none()`（directory.py:216-218）：库内可能已存在 `evan`/`Evan` 大小写共存对（PG 约束区分大小写+旧 exact 预检的历史产物），对第三种变体建号时 lower 命中 2 行会 MultipleResultsFound 500；**必须 lower 匹配，与登录口径对齐**（local_auth.py:113-140 登录即 `func.lower` + 多行命中拒绝登录；若按精确匹配预检，`Evan` 会在库内已有 `evan` 时建号成功，随后**两个账号的登录一并锁死**）；**锚点：插在既有 initial_grants/目录模板前置校验段（:127-186）之后、Project 构造（:188）之前**——使既有 400/422 校验优先于 409，与现状错误优先级最接近） | 409 `detail={code:"username_taken", username}` | 零副作用（项目未建） |
| 4. 建项目（既有流程原样：项目行 commit → initial_grants → 默认模板 → 目录模板 → `project_created` audit） | 既有错误码（如 code 撞名 409） | 零新增 |
| 5. 确保「艺人」组（D5 get-or-create；唯一异常路径 = 撞 unique 已回查兜底） | DB 故障 → 500 | 项目已建（可补） |
| 6. `provision_local_user`（source=`project_artist_inline`） | 用户名竞态（内部预检 409 或 insert 撞 unique，**两类都捕获**；provision 内部预检是纯文本 detail，端点捕获时按 `e.status_code == 409 and str(e.detail).startswith("登录名已存在")` 收窄识别，勿裸捕一切 409；**捕获分支先 `await db.rollback()` 再重抛**，照 projects.py:198-204 先例；**IntegrityError 分支按约束名收窄——核对 `str(e.orig)` 含 `uq_users_username` 才归类 username_taken**（该约束实名见迁移 0009:28 `op.create_unique_constraint("uq_users_username",…)`；勿照抄 projects.py 的 `projects_code_key`——那是无名约束由 PG 自动命名的机制，users.username 走的是显式命名约束，两者命名机制不同），provision 内多次 commit（用户行+逐组 GroupMembership），不收窄会把其他唯一冲突误报成「登录名占用」）→ 统一重抛 409 `detail={code:"username_taken", username, project_id}`；admin 链路的纯文本 409「登录名已存在:{username}」语义不变，仅内嵌链路重抛结构化 detail | 项目已建、艺人未建（可补；首次时「艺人」组可能已建，零成员零权限复用无害） |
| 7. 加组（provision 内含，`group_member_added` source=`"project_artist_inline"`）+ 授项目角色：照 D8 逐角色循环 `add_project_subject`（uploader/downloader/viewer 各一次，幂等跳过 `is_already_exists_error`）+ 每角色一条 `project_member_added`（detail 带 `via:"artist_inline"`） | 与既有 initial_grants 同语义（不单独兜底） | 同左 |
| 8. 响应 | — | 201 |

**响应**：`response_model` 由 `ProjectOut` 改为 **`ProjectCreatedOut(ProjectOut)`**，唯一新增字段：

```python
class ArtistAccountCreatedOut(BaseModel):
    """一次性回显,不落 audit/log(照 UserCreateOut 注释惯例)。"""
    user_id: uuid.UUID
    username: str
    name: str
    temporary_password: str

class ProjectCreatedOut(ProjectOut):
    artist_account: ArtistAccountCreatedOut | None = None
```

不带 artist_account 时该字段序列化为 `null`（创建响应恒多一个 `"artist_account": null` 键——结构兼容、无功能影响；**勿用 response_model_exclude_none**，那会连 `description` 等既有可空键一并剥掉，反而改变现状响应形状）。GET 列表/详情仍返回 ProjectOut，不受影响。

**前端对结构化 409 的处理**：`web/src/api/client.ts` 的 `errorMessage`（:53-61）只认字符串 detail，且全局 `mutationCache.onError`（App.tsx:46-52，只跳过 401）会把 409 喂给 `antMessage.error(errorMessage(err))`——对象 detail 原样返回会触发 React「Objects are not valid as a React child」渲染异常，且该全局路径与 F3 本地 catch **同时触发**，只做本地特判拦不住。**修复：`errorMessage` 最小增量兜底——`detail` 非字符串时返回 fallback 文案**（`typeof d.detail === "string" ? d.detail : fallback`，对既有全部字符串 detail 行为零影响；顺手免疫未来一切对象 detail）；F3 提交 catch 中再按 `detail.code` 特判给精确文案（全局 toast 兜底显示 fallback、本地文案给引导，双通道都安全）。

**⚠ ORM 安全细节（folder-templates D3 同雷，两条硬规）**：阶段 5/6 存在 rollback 路径（unique 回查是**继续执行**而非失败，竞态捕获是失败），rollback 会过期 identity_map 中全部 ORM 对象（session.py:23 只豁免 commit 不豁免 rollback）：
1. **艺人段所有 FGA 写与 audit 的 project_id 一律使用既有物化局部 `project_id_v`（projects.py:261，该段即为同雷物化惯例），禁止回读 `project` ORM 属性**——否则阶段 5 回查续行后，阶段 7 的 `add_project_subject`/`audit.write` 读 `project.id` 即 MissingGreenlet 500，恰落在竞态路径上；
2. `db.refresh(project)` 仅作响应构造（:307-308 `ProjectOut.model_validate`）前的兜底。失败路径直接 raise HTTPException，不触碰 ORM 属性，天然安全。

**org 备注**：阶段 2 与 `require_inline_artist_creator` 统一走 default org 口径（见阶段 2），与全部既有 dep 同构、无多租户悬案；provision 把新用户 `organization_id` 绑 default org（照 create_directory_user :224-225 语义）——多租户启用时如有项目 org ≠ default org 的场景再议。

### 4.2 新增：`GET /api/v1/users/username-available`（routers/users.py，:37 既有 GET 旁）

| 项 | 定义 |
|---|---|
| 守门 | **`require_inline_artist_creator`（新组合弱门，照 `require_folder_templates_reader` deps.py:402-439 先例）= `is_org_admin` ∨ (`is_org_project_creator` ∧ `is_org_artist_account_creator`)**——与内嵌建号的真实能力判定同构；合取堵住「仅有 artist flag、无 project_creator」持有者把它当纯账号存在性 oracle 用（此类用户提交 POST /projects 会在 require_project_creator 先吃 403，永远到不了提交期 409，availability 端点对其是严格增量信息）；users.py 现仅一条列表路由、无路径参数，无路由顺序冲突 |
| 入参 | query `username: str`（FastAPI Query 约束与 UserCreateIn 同款：2-64、`^[a-zA-Z0-9._-]+$`，不合 → 422） |
| 返回 | 200 `{available: true|false}`（available=false 即已占用；不返回占用者信息；**查询用 `func.lower(User.username) == username.lower()`，与 §4.1 阶段 3 预检/登录口径一致**） |
| audit | 不写（读操作，deps 403 惯例亦不写） |

### 4.3 改动：组管理（directory.py，照 `can_manage_folder_templates` 全套先例）

- `DirectoryGroupOut`（:523-535）增 `can_create_artist_account: bool`（回显走 `_read_flag_group_ids(permissions, db, "artist_account_creator")`；**三处消费点各加一支**：`list_directory_groups` 构造段 :692-704、POST 建组响应构造 :751-757（显式逐字段、按入参回填 `can_create_artist_account=payload.can_create_artist_account`——漏掉则建组置 true 的响应谎报 false，:529-531 契约注释「create/update 响应按入参 flag 回填」）、PATCH 未传字段回显分支 :828-841——漏任一处该 flag 恒回显 False）。
- `GroupCreateIn`（:538-546）增 `can_create_artist_account: bool = False`；POST 建组置位走 `_sync_group_org_flag`（:726-737 区域加一支 relation `"artist_account_creator"`）；audit `group_created` details 增该键（:738-747）。
- PATCH（:760-852）入参增 `can_create_artist_account: bool | None`（tri-state：None=不动/true=写 tuple/false=删 tuple）；audit `group_updated` details 带 `{old,new}`（:810-818 模式）。
- 删组清理（:877-889 flag 清理循环，循环体 :882）加一项 `artist_account_creator`。

### 4.4 改动：`GET /api/v1/auth/me`

增 `is_artist_account_creator` 字段（§3.3 口径）。

## 5. 后端改动点（文件级）

| # | 文件 | 改动 |
|---|---|---|
| B1 | `poc/openfga/store.fga.yaml` | §3.1：relation + 变更史第 9 条 + 测试 tuple + 成对断言 |
| B2 | `api/app/services/permissions.py` | `is_org_artist_account_creator`；`USER_DIRECT_RELATIONS` 补两笔防御项（artist_account_creator + project_deleter 既有缺口，§3.3） |
| B3 | `api/app/deps.py` | 仅 `require_inline_artist_creator`（组合弱门，§3.3；不建零挂载单 flag dep） |
| B4 | `api/app/services/user_provisioning.py`（**新**） | ① `add_user_to_group_audited(db, permissions, audit, *, group, user, actor_user_id, ctx, source: str | None = None)` —— 现 directory.py `_add_membership`（:69-100）平移为公共函数，逻辑逐行不变（GroupMembership → commit → `permissions.add_user_to_group` → audit `group_member_added`）；**source 默认 None 保持**——三调用点中 :354（改用户组）与 :976（组加成员）现状不传 source（审计无该键），迁移后照旧不传，仅 create_directory_user :252-256 传 `"user_create"`；**ip/ua 取法由 `request: Request` 参数改为 `ctx: dict`（`audit.write(**ctx)` 形态，对齐 projects.py:299 惯例）**——directory.py 三处调用端点（:252/:354/:976 所属）需机械补 `ctx: dict = Depends(get_request_context)` 注入并改传 ctx；**同文件 `_remove_membership`（:103-132）不在平移范围、保持 `request: Request` 形态——新函数 docstring 注明「remove 侧未平移，勿对称统一」，防顺手改动引入无测试覆盖的变更**；② `provision_local_user(db, permissions, audit, *, username, name, email, groups: list[Group], actor_user_id, ctx, source: str, membership_source: str = "user_create") -> tuple[User, str]` —— 重名预检（409 `登录名已存在:{username}`，语义照 :216-218 但**匹配改 `func.lower(User.username) == username.lower()` 且消费用 limit(1)+first（多行命中=已占用 409，勿 scalar_one_or_none——存量 case 变体共存对会 500，见 §4.1 阶段 3）**——与登录口径对齐（local_auth.py:113-140），顺带修复管理后台旧口径「case 变体建号成功→两账号登录互锁」的既有缺陷，属有意改进非回归；作为竞态兜底，admin 链路壳内另有前置预检。**注：这是 services 层首例 HTTPException**——现状 `api/app/services/` 无抛 HTTPException 先例，此处有意引入（平移保行为的最低成本路径，优于「领域异常+路由转换」的双层样板），实施时在函数 docstring 注明）→ `generate_temp_password()` → `hash_password` → `User(must_change_password=True, organization_id=default org)` 落库（**commit 后保留原 `db.refresh(new_user)`——directory.py:239 平移，`UserCreateOut.created_at` 依赖 server_default 回填，漏掉则 admin 链路构造响应即 ValidationError 500**） → `add_user_to_organization`（尽力而为，失败仅 log.warning）→ 逐组 `add_user_to_group_audited(source=membership_source)` → audit `user_created` details `{user_id, username, name, group_ids, source}`（source 为增补键；两参数语义见 D7：admin 调用 `source="admin_create"`（membership_source 默认 `"user_create"` 原值）；内嵌调用 `source="project_artist_inline", membership_source="project_artist_inline"`）→ 保留既有建号 ops 日志 `log.info("user created …")`（directory.py:266-267 平移，薄壳化后不得丢失）→ 返回 `(new_user, temp_password)`。create_project 已有 `ctx: dict = Depends(get_request_context)`（projects.py:74）可直传。组加载（`_load_groups_for_ids` 校验 >50/不存在→422）**留在 directory.py**：调用方先加载再传 `groups` |
| B5 | `api/app/models/__init__.py` | 仅四项：`ArtistAccountIn`（含 `_validate_name_format` 复用，§4.1；validator 本体 :482-493）/ `ArtistAccountCreatedOut` / `ProjectCreatedOut`；`ProjectCreateIn` 增 `artist_account`。**组模型三项不在本文件**——`DirectoryGroupOut`/`GroupCreateIn`/`GroupUpdateIn` 实际定义于 directory.py（:523-535/:538-546/:549-559），改动归口 B7③/§4.3 |
| B6 | `api/app/routers/projects.py` | create_project 挂接 §4.1：能力校验（org/tenant_key 解析后，`is_org_admin` ∨ `is_org_artist_account_creator`，注入现有 perms 服务）→ 用户名预检 → 既有建项目流程原样 → 艺人段（ensure 艺人组——**命中既有同名组时读四 flag 分级记日志（全空 `log.info` / 任一置位 `log.warning`，D5，防 WARNING 常态噪音），实现在 projects.py 就地：`permissions.read_all_tuples(object_type="organization", object_id=tenant_key, relation=…)` 定向读四次（`object_id` 为该函数必填参数，permissions.py:192-198，传 default org 的 tenant_key，与阶段 2 口径一致；勿搬 directory.py 私有的 `_read_flag_group_ids`，路由私有跨层 import 方向反了）** → `provision_local_user(source="project_artist_inline", membership_source="project_artist_inline")` → 照 D8 逐角色循环 `add_project_subject(project_id=str(project_id_v), subject=fmt_subject("user", str(new_user.id)), role=role)` 三次 + 每角色 audit，**project_id 一律用物化局部 `project_id_v`（projects.py:261，形参注解为 str，直传 UUID 撞 mypy），禁读 project ORM 属性**）→ `db.refresh(project)`（仅响应构造前）→ 返回 `ProjectCreatedOut`（artist_account 仅在创建时填充）。艺人组名常量 `ARTIST_GROUP_NAME = "艺人"` **单点定义于 user_provisioning.py，projects.py 就地 import**（勿二处定义漂移；ensure 逻辑本身在 projects.py，常量归属只论单点） |
| B7 | `api/app/routers/directory.py` | ① `create_directory_user`（:200-273）薄壳化：**壳内先保留原重名预检（409，:216-218 原位）再 `_load_groups_for_ids`**（保持「重名 409 优先于组校验 422」的现状顺序），然后 `provision_local_user(source="admin_create")`（`membership_source` 取默认 `"user_create"`，入组审计 source 原值不变）→ `UserCreateOut`；provision 内部预检作为竞态兜底（双查无害），**除 D7 additive 的 `source` 键与 lower 预检修复（case 变体从 201 变 409，§4.1 阶段 3）外行为与错误码零变化**（勿按字面「零变化」漏掉这两项、也勿反向连 membership source 一并改掉）；② `_add_membership` 删除，3 调用点改服务函数；③ 组管理第 4 flag 全套（§4.3，含 directory.py 内 `DirectoryGroupOut` :523-535 / `GroupCreateIn` :538-546 / `GroupUpdateIn` :549-559 三模型增字段） |
| B8 | `api/app/routers/auth.py` | /me 增 `is_artist_account_creator`（内联三段式） |
| B9 | `api/app/routers/users.py` | `GET /api/v1/users/username-available`（§4.2，守门 `require_inline_artist_creator`） |
| B10 | `api/tests/test_project_artist_account.py`（**新**） | §7 |

依赖序（建议）：B1→(B2→B3)；B4→(B5,B6,B7)；B8 依赖 B2（消费 is_org_artist_account_creator）；B9 依赖 B3（消费 require_inline_artist_creator）；B10 最后。

## 6. 前端改动点（文件级）

| # | 文件 | 改动 |
|---|---|---|
| F1 | `web/src/api/types.ts` | `Me` 增可选 `is_artist_account_creator?`（回落注释惯例）；`ArtistAccount{username,name}` / `ArtistAccountCreated{user_id,username,name,temporary_password}`；**新增 `ProjectCreated` 类型（= Project + `artist_account?: ArtistAccountCreated \| null`）并让 `useCreateProject` 返回类型从 `Project` 改为 `ProjectCreated`**（hooks.ts:181-202 现 `http.post<Project>`，不改则 F3 读 `res.artist_account` 编译失败；GET 列表/详情仍用 Project，不带该字段）；CreateProjectBody 增 `artist_account?`（**注：该命名类型现状不存在**——body 是 useCreateProject 内的匿名内联类型 hooks.ts:183-192，实施时提名为 `CreateProjectBody` 导出或直接改内联类型，二选一）组类型与建组/改组 body 增 `can_create_artist_account?` |
| F2 | `web/src/api/hooks.ts` | `useUsernameAvailable`（新，`enabled` 条件 + debounce 由调用侧控制；**enabled 须前置正则+长度约束**（与输入 rules 同款），避免停顿在半截非法值时打 422；静默口径如实声明：全局 `queryCache.onError` 本就只跳过 401/403（App.tsx:39-45），401/403 静默、其余错误（网络/422）以全局 toast 兜底——预检只是尽力挡，不影响提交期 409 兜底；react-query v5 已移除 per-query onError，勿照字面写）；`useCreateProject` 返回泛型随 F1 更新；组 hooks 建组/改组 body 增字段（useCreateGroup ≈:653-666 / useUpdateGroup ≈:668-688） |
| F3 | `web/src/components/NewProjectModal.tsx` | ① **艺人账号区**（基本信息区之后、右栏权限区之前）：闸门 `me.is_artist_account_creator ?? me.is_system_admin`，关闭时不渲染（零回归）；「艺人登录名」Input（rules 同步后端正则与 2-64 长度）+「艺人姓名」Input（1-128）；两项**全空=不创建**（提交不带 artist_account），填一项则两项都必填（前端校验）；登录名输入停顿（debounce ~500ms）且有值时调 `useUsernameAvailable`，冲突 → 该字段表单错误「该登录名已被占用；若属于该艺人本人（此前已开通），请勿重复开通，可联系管理员将其加入本项目成员」（409/available=false 无法区分「撞职员账号」与「该艺人已被开通」，必须给出区分性引导——只引导「换登录名重试」会诱导给同一真人开第二个账号，违背 D9）；**项目名联动**：姓名变更时若项目名未被手动编辑过（touched 标志）则同步写入，项目名手动编辑后脱钩；提交 body 带 `artist_account: {username, name}`。② **成功结果 Modal**（提交成功且 `res.artist_account` 存在时，替代现状 message.success 路径）：`closable=false / maskClosable=false / keyboard=false`（防误关丢密码）；内容：项目「{name}（{code}）」创建成功；艺人姓名；登录名（Typography.Text copyable）；初始密码（Typography.Text copyable）；警示文案「密码仅展示这一次，关闭后无法再查；请复制并转交艺人，首次登录将要求修改密码」；唯一按钮「我已保存，进入项目」→ `onCreated(p.id)` + `onClose()`。无 artist_account 时维持现状 message.success 流（:147-151）。③ **提交失败特判**（配合 §4.1 的 `errorMessage` 非字符串 detail 兜底——全局 mutationCache toast（App.tsx:46-52）与本地 catch 同时触发，兜底保证全局通道不炸，本地 catch 决定精确文案）：catch 中 axios 409 且 `detail.code === "username_taken"` 时按 `detail.project_id` 分支——无 project_id（预检阶段，项目未建）→「登录名已被占用；若该艺人此前已开通请勿重复开通（可联系管理员将其加入本项目成员），否则请更换登录名重试」；有 project_id（竞态阶段，项目已建）→「项目已创建，但艺人账号未能建立（登录名刚被占用）；可联系管理员在后台开通账号后在项目成员中添加；或由管理员删除该项目后用新登录名重建」（组长大概率无 `project_deleter` flag，删除须管理员执行——文案勿引导组长自行删除）；500（艺人段或既有项目段异常，密码未返回）→「创建过程中出现异常，请到项目列表确认项目是否已创建；若已创建，联系管理员确认艺人账号状态或重置密码」（不指向性地提"艺人密码未生成"，防阶段 4 失败时误导）；其余错误走现状 errorMessage |
| F4 | `web/src/pages/AdminGroupsPage.tsx` | ① **tooltip 收拢**（D13）：三个既有开关 + 新开关的 Form.Item 去掉 extra 长文案，label 旁加 `<Tooltip title={原文案}><QuestionCircleOutlined/></Tooltip>`，文案内容不变；② **第 4 开关**「允许组成员新建项目时创建艺人账号」：`Form.useWatch('can_create_project')` 为 true 才渲染（建组态与编辑态均适用）；**复位触发时机写死：仅父开关 Switch onChange 由 true→false 的转变瞬间**执行 `form.setFieldValue('can_create_artist_account', false)` 并置 touched——确保该次 PATCH 显式发 `can_create_artist_account: false` 清 tuple；**弹窗挂载时父开关已是 false 不触发**（watch+effect 形态会把「仅改名保存」也带上子开关 false，静默清掉 §11 声称接受的存量残留，属 directory.py:549-559 tri-state 注释明确防范的静默撤权模式，禁止）；编辑态回 initialValues 增 `can_create_artist_account: group.can_create_artist_account ?? false`（:270-276）；建组 initialValues 增 false；PATCH body 照 :240-243 只带改动字段模式加一支；建组 POST body（:247-252）加 `can_create_artist_account: v.can_create_artist_account === true` |
| F5 | `web/src/lib/labels.ts` + `AdminAuditPage.tsx` | **无改动**（内嵌链路复用 user_created / group_created / group_member_added / project_member_added 既有事件与中文映射；写明防误加） |

前端不做艺人区的 org 切换（单 org 现状）；不改动「新建项目」入口闸门（ProjectsPage.tsx:42 维持 is_project_creator 口径——艺人能力只影响弹窗内区块）。

## 7. 测试功能点（`api/tests/test_project_artist_account.py`）

fixture 与辅助函数照 test_project_creator.py（:50-150：`_create_group/_create_user/_add_group_member/_archive_project/_default_org`，`_project_code()` 防撞 pattern）；前置 seed_demo_data + 本地栈 `bash api/scripts/local_up.sh --refresh-model`（含 `artist_account_creator` 的 model；勿跑 openfga_write_model.sh——远端部署脚本）。

**组开关与 /me**
- 建组 `can_create_artist_account=true` → **POST 响应与列表两态均回显 true**（钉住 §4.3 三处消费点之 POST 响应 :751-757 与列表 :692-704）；PATCH tri-state：不传字段 → 不动；false → 回显 false 且组成员失去能力；audit `group_updated` details 含 `{old,new}`（照 test_project_soft_delete.py:258-306 范式）
- 组成员 GET /me → `is_artist_account_creator: true`；移出组 → false；EVAN（org admin）→ true；OUTSIDER → false
- 删组 → org flag tuple 清理（照既有删组测试形态）

**组合流（201 全链）**
- 建组（`can_create_project` + `can_create_artist_account` 双 true）→ 组长 POST /projects 带 `artist_account` → 201，断言：
  - users 表新行：username/name、`must_change_password=True`、password_hash 为 argon2 串、organization_id=default org
  - groups 表自动出现名为「艺人」的组（首次），description 如 §1-D5；audit `group_created` details 含 `source: "project_artist_inline"`；第二次走流程 → 复用同一「艺人」组（groups 计数不增）。**跨 run 卫生**：「艺人」组在共享 feat-ms 栈上持久，第二轮跑「首次自动建组」断言必挂——用例 setup 先 `DELETE /admin/directory/groups/{id}` 清理同名组（directory.py:855-917，连带清 tuple；**清理须容忍 404**——首轮栈上组不存在，directory.py:869-871），或断言兼容「已存在/新建」两态，二选一写明
  - GroupMembership（艺人组,新用户）就位；FGA read_all_tuples 含该 user 对该 project 的 `uploader/downloader/viewer` 三 relation；**「艺人」组无任何 org 级 flag tuple**（project_creator/project_deleter/folder_template_manager/artist_account_creator 四 relation 全无——钉住 D5 零权限论点）
  - audit：`user_created`（actor=组长，group_ids=[艺人组]，`source: "project_artist_inline"`）+ `group_member_added`（source=`"project_artist_inline"`）+ `project_member_added` **3 条**（uploader/downloader/viewer 各一条，detail `{subject, role, kind:"user", via:"artist_inline"}`，与 initial_grants 路径形状对齐）+ `project_created`（既有，不因艺人段变化）；**403 与预检 409 路径不新增任何 audit 事件**（窗口前后 audit 计数不变，钉住「守门/预检不写审计」；竞态 409 不在此列——其项目段既有审计允许且应当保留）
  - 响应体 `artist_account.temporary_password` 非空 12 位、字符集无易混淆字符；**全库 audit_events 无该密码串**（一次性语义）
  - 既有链路不回归：initial_grants / 默认模板 / 目录模板照常
- org admin 带 artist_account 建项目 → 201（直通）

**权限与失败路径**
- 仅 `can_create_project`（无 artist flag）组长带 artist_account → 403（detail 含 `无内嵌创建艺人账号权限`，与 require_project_creator 的 403 文案可区分），且**零副作用**（projects/users/groups 表无新行）
- username 冲突（预建同名用户）→ 409 `detail.code=username_taken`；断言项目未建（projects 表无该 code 行）；**大小写变体（预建 `evan`、提交 `Evan`）→ 同样 409**（钉住 lower 匹配口径，防「case 变体建号成功→两账号登录互锁」回归）；**存量共存对（预建 `evan`+`Evan` 两行、提交 `EVAN`）→ 409 而非 500**（钉住 limit(1)+first 消费语义，防 scalar_one_or_none 的 MultipleResultsFound；**共存对构造须绕过 API 直写 users 表**——`get_sessionmaker` 直插，照 `_archive_project` 先例 test_project_creator.py:122-143——lower 预检上线后 API 路径造不出共存对，注释写明防后人「顺手改掉」）
- **竞态阶段 409（detail 带 project_id）**：黑盒需并发提交同名才能构造，集成测试不做；**必做两层单测**——① monkeypatch `provision_local_user` 抛 409 / IntegrityError，断言组合端点重抛 `detail={code:"username_taken", username, project_id}` 形状且 **`detail.project_id` 非空**（证明项目段已提交、非预检 409）；**patch 目标写死 = `app.routers.projects` 命名空间内的符号**（B6 若 from-import，patch services 模块无效；打错会响亮失败而非假绿）；② **用真实异常文案形状构造 IntegrityError（`duplicate key value violates unique constraint "uq_users_username"`）钉住收窄判据常量本身**（判据写错则该路径变 500 死代码且 ① 验证不到）。该形状是 F3-③ 前端分支路由的唯一依据，无此回归保护则引导文案永远裸奔；dev 验收时再手工验证一次
- ArtistAccountIn 非法：username 撞正则/长度边界、name 空/**全空白**（钉住 `_validate_name_format` 复用）/129 字符 → 422
- 两项全空（不传 artist_account 字段）→ 与现状一致（项目建成、无新用户；响应含恒 null 的 `artist_account` 键）——零回归锚点（语义断言，不断言字节）
- `GET /users/username-available`：flag 组长查未占用名 → `{available:true}`；查 EVAN → false；OUTSIDER → 403；**仅有 artist flag、无 project_creator 的用户 → 403（钉住合取守门）**；非法 username → 422

**服务薄壳化回归**
- POST /admin/directory/users（管理后台建号原路径）：201 + temporary_password 回显 + `user_created` details 含 `source:"admin_create"`；重名 409 文案不变；**admin 链路 lower 预检有意变更钉住：预建 `evan` 后经管理后台提交 `Evan` → 409**（防后人「顺手改回 exact」无回归保护）；带 group_ids 建号入组照旧（test_directory.py 既有用例全绿）
- directory 三处 `add_user_to_group_audited` 迁移点行为不变（改用户组 / 组加成员端点既有用例全绿）

**回归**
- 全量 `api/tests` pytest 绿（记录当前 liuqi 基线数）；重点：test_directory / test_project_creator / test_grant_templates / test_default_template / test_folder_templates / test_project_soft_delete

## 8. 实施批次与工作包

单批次交付（qdev 一个周期）：

| 包 | 角色 | 内容 | 依赖 |
|---|---|---|---|
| WP-1 后端 | 后端 | B1-B9 全部（含 FGA model yaml） | 无 |
| WP-2 前端 | 前端 | F1-F4（契约=§4/§6） | 无（可与 WP-1 并行） |
| WP-3 用例 | 测试 | B10 新测试文件（按 §7；开发阶段照 qdev 惯例只写不跑，**但执行是硬验收门**——见下行验收顺序） | 无 |
| 收尾 | 任一 | `scripts/changelog.md` 当天分节追加；`rushes-spec/material-storage/permissions-model-v4.md` 补 `artist_account_creator` relation 与守门口径 | WP 全部 |

验收顺序：WP-1 隔离栈（feat-ms，`--refresh-model`）pytest 全绿 → WP-2 `npm run build` 过 + 本地联调 → **B10 合入后隔离栈再跑一轮 `test_project_artist_account.py` 全绿（含竞态 409 形状单测——它是 F3-③ 前端分支路由的唯一回归保护，不得跳过）** → dev 部署验证（**模型先推**）。

## 9. 验收标准（用户可见）

1. 组管理页：开启「允许组成员新建项目」后出现子开关「允许组成员新建项目时创建艺人账号」；全部开关描述收进 label 旁问号图标 tooltip，布局收紧
2. 被授权组长新建项目弹窗出现「艺人账号」区；填登录名+姓名后项目名自动带出（可手改）；登录名冲突即时提示
3. 创建成功弹窗展示 项目+艺人登录名+初始密码（均可复制），点「我已保存，进入项目」进入新项目；密码关闭后不可再查
4. 新艺人自动进入「艺人」用户组（首次自动建组），进入项目即具备上传/下载/查看能力（上传/下载/浏览文件全通）
5. 艺人首次登录被强制改密；改密后正常使用
6. 审计页可查 `user_created`（操作者=组长）/ `group_created`（艺人组自建）/ `project_member_added` 等事件，中文映射正常
7. 未开 flag 的组长与普通用户：弹窗与现状完全一致；管理后台建号流程与现状完全一致（零回归）

## 10. 风险与边界

| 风险 | 应对 |
|---|---|
| FGA model 未先推 → check 报 unknown relation | 部署硬顺序 §3.2；`USER_DIRECT_RELATIONS` 防御项在 model 未部署时被容错跳过（既有先例） |
| 预检通过后并发撞 username unique（极小窗口） | 阶段 6 捕获（先 rollback 再重抛，照 projects.py:198-204 先例）409 带 `project_id`；残留态=项目已建+艺人未建（首次时「艺人」组可能已建，零权限复用无害）；前端文案「项目已创建，但艺人账号未能建立（登录名刚被占用）；可联系管理员在后台开通账号后在项目成员中添加；或由管理员删除该项目后用新登录名重建」（组长大概率无 project_deleter，删除须管理员）；audit 可溯 |
| 「艺人」组被管理员改名 → 下次内嵌建号再建一个同名新组；或反向：既有带 flag 的组被改名为「艺人」/预建同名组 → 内嵌建号把艺人塞进有权限面的组 | 改名方向：零权限桶无安全影响（D5），运维交接注明勿改名，真发生时可手工并组（GroupMembership 平移）；反向：D5 的命中既有组分支 `log.warning`（记 group_id+四 flag 状态）可观测，运维指引**勿将其他组改名为「艺人」、勿预建同名组** |
| 一次性密码丢失（弹窗误关/未复制） | Modal 三重防误关（F3）；兜底=管理员重置密码（`user_password_reset` 既有链路） |
| 艺人段 rollback 过期 ORM 对象 → 响应构造 500 | §4.1 落尾：成功路径艺人段后 `db.refresh(project)` 再构造响应（folder-templates D3 同雷对策） |
| `username-available` 账号枚举面 | 枚举面**不大于既有面**：`GET /api/v1/users`（users.py:37-76，弱门 require_admin_or_project_creator）本就向全部 project creator 返回全量 username 列表，是既有且更强的枚举通道；本端点经合取守门（能预检者必能提交）后信息量 ≯ 提交期 409 ≯ 既有 GET /users |
| 建号成功但授角色/FGA 写失败 | 与既有 initial_grants 同语义（projects.py:215-218 既有注释口径：500、项目行已提交、授权部分缺失、成员抽屉手动补授）；此时 500 响应失败、temporary_password 无人知晓 → 前端文案引导联系管理员确认账号状态或重置密码（F3-③，user_password_reset 既有链路）；audit/艺人组内可查账号确已建 |
| 服务薄壳化动 directory.py 三处调用点 | 平移不改逻辑；test_directory 既有用例全绿为验收门；diff 逐行核对 |
| 组长无限开号滥用 | 小规模内部系统，审计兜底（user_created actor=组长）；v1 不做配额（§11） |

## 11. 明确不做（v1 边界）

- **选择已有艺人**复用入口（D9：业务一艺人一项目；冲突走 409 引导）
- 单项目多艺人（入参单对象；一艺人一项目业务下无需求）
- 「艺人」组 ID 配置化 / 改名适配（按名 get-or-create + 零权限桶，D5）
- 艺人 email / 手机号字段（登录名+姓名够用；需要时管理后台补编辑）
- 密码二次展示 / 找回入口（只此一次；兜底=管理员重置）
- 开号频控 / 配额
- user 直授 `artist_account_creator` 的管理 UI（模型留口，UI 只做组开关，同三先例）
- 后端强制「子开关蕴含父开关」约束（D2：正交，UI 层级仅前端行为）
- 编辑态「父开关已关 + 子开关 tuple 历史残留开」的存量态清理（D2 正交下该残留惰性——组成员无 project_creator 即无整体能力，无安全影响；回显以 GroupOut 为准，UI 不渲染该开关属接受行为；如需清理可临时开父开关再关子开关）
- 本次内嵌新建的艺人不可能同时出现在 `initial_grants` 里——主体存在性校验（projects.py:144-167）先于建号，会 400「主体不存在」，文案自解释，非 bug
- 项目被逻辑删除（DELETE /projects 仅置 deleted_at）后艺人账号的残留生命周期（账号留在艺人组、项目级 tuple 不动、永久无项目权限）——v1 不做联动清理，管理员可后台禁用兜底，防后续当 bug 报
