# 成员权限三项改动:用户组授管理 + 组名显示 + 新建项目自动授权 · 实施方案

> Status: **已定稿待实施**(2026-09-30 与用户对齐三项决策;同日经 qplan 7 轮独立盲审,末轮 0 P0 / 0 P1)
> 范围:material-storage(后端 `api/` + 前端 `web/`)
> 关联:`permissions-model-v4.md`(模型依据)、ROADMAP「已知坑」(#106 admin 不变量)
> 实施形态:3 个独立可上线的批次(见 §5),适合 qdev 按批拆包

---

## 0. 背景与已确认决策

| # | 问题(2026-09-30 反馈) | 根因 | 决策 |
|---|---|---|---|
| A | 【成员】-【邀请】-【用户组】不能批量授【管理】 | API 层 guard 意外收紧(#162 重构回归),非模型限制 | **放开限制** |
| B | 【成员】界面显示「用户组ef94e20c-be0…」而非组名 | 后端 4 处列表接口没 join `groups.name`,走了 id 兜底 | **修复,展示组名** |
| C | 新建项目后要手动逐批授权,希望创建时自动给指定用户组/员工配权限 | `POST /projects` 只 bootstrap 单个 admin,无初始授权机制 | **先做 initial_grants 直通,再做权限模板模块**(两步走) |

---

## 1. 批次一(A):放开「用户组授管理」

### 1.1 依据(为什么可以直接放开)

- OpenFGA 模型 v4 本来就支持:`poc/openfga/store.fga.yaml:52-53`
  ```fga
  # admin 仅个人 / 群(部门级 admin 太宽泛,不允许)
  define admin: [user, group#member]
  ```
  排除的只是部门;`fmt_subject('group', id)` 生成的 `group:{id}#member` 正是模型接受的形式。
- #162(P4 飞书下线重构)把原本只拦 department 的嵌套 if 压平成了拦所有非 user 主体——原报错文案甚至是「请改给 user **或 group**」,证明 group admin 原本被允许。
- 下游代码当年就按 group-admin 存在设计:`remove_project_member` 的「至少保留 1 个管理员」兜底注释明确写了「group-admin 间接 user 也计入,接受 OpenFGA list_users 透传 leaf users 的语义」(`api/app/routers/projects.py:519-520`;该 leaf 计数兜底对「撤整组授权」场景不成立,批次一同步加固,见 §1.2 改动 2);`_fill_project_admins` 走 `list_users_with_relation`,group#member 自动展开为成员用户,项目卡 admin 列表无需改动。

**放开后的语义(需在 UI hint 中写明)**:用户组授管理后,组成员**当时与日后加入的成员**都自动获得项目管理员(可管成员/可建敏感目录),直到撤回该组的 admin 授权或移出该组。这与 viewer/uploader/downloader 的组授权语义一致。

### 1.2 改动点

**后端改动 1:删 guard** — `api/app/routers/projects.py` `add_project_member`:

```python
# 删除 projects.py:466-468
if "admin" in roles and chosen[0][0] != "user":
    # model v4 限 admin: [user, group#member]
    raise HTTPException(400, "admin 不允许直接给 group;请改给 user")
```
连同 guard 处「model v4 限 admin」的注释一并清理(`add_project_member` 的 docstring 本就没有 admin 仅 user 的表述,不用动)。写入路径零改动:`fmt_subject('group', id)` → `add_project_subject(role='admin')` 天然合法。

**后端改动 2(必须,放开引出的新风险):加固 `remove_project_member` 的 admin 不变量(#106)**

现行判定(`projects.py:521-534`)用 `list_users_with_relation('admin')` 数 **leaf user**:当项目唯一 admin 来源是一个 ≥2 人的组时,撤销该组的 admin——`subject != user.subject` 不触发自撤拦截、`len(current_admins) >= 2` 通过——撤销后项目 admin **归零**且无人能恢复(仅 system admin 可救)。该路径原本被「API+UI 双拦组 admin」掩盖,批次一放开后重新可达,必须同批加固:

- `role == "admin"` 时改为按**撤销后幸存 tuple 的 leaf 投影**判定。**不要用「当前 leaf 集合 − 被撤主体贡献集」的减法**:当组成员同时持有直授 admin(或另一 admin 组)时,减法会把差集错算成空,把本应 204 的撤销错杀成 409——「创建者直授 admin + 给创建者所在组授 admin」就是最常见重叠。算法:
  1. read 一次项目 admin tuples(`ReadRequestTupleKey(object=f"project:{pid}")` 过滤 relation == "admin",写法照 `list_project_members` 的 `projects.py:365-369`);
  2. 剔除本次要撤的 subject 那条 tuple;
  3. 幸存 leaf 集 = 幸存 `user:` tuple 的 id ∪ 各幸存 `group:<gid>#member` tuple 经 `list_group_member_tuples(gid)`(`permissions.py:478-492` 现成)展开的 `user:` 型成员 id;
  4. 幸存 leaf 集为空 → 409(沿用现有文案「项目至少需要保留 1 个管理员…」)。
- leaf 数据源**一律 FGA tuple,不用 DB `group_memberships`**(两类可达背离:① 用户停用会撤销其全部 FGA tuple 但 DB 组成员行保留(`directory.py:222` 注释),按 DB 展开会把禁用用户计成幽灵 admin;② 存量非 UUID 组主体如 `grp_editors` 在 FGA 有 member tuple 但无 DB 行,按 DB 展开会误判 0 成员)。
- 死组 tuple(组已删,member tuple 已被 directory 清理,`directory.py:439,460`)作为唯一 admin 来源时:幸存集为空 → 409,与现状(`len(current_admins)=0 ≤ 1` → 409)行为一致——**本方案不改变 #106「项目至少保留 1 个管理员」的语义**,只是把计数基准从「当前 leaf」修正为「撤销后幸存 leaf」,使重叠授权场景不再误判。
- **配套入口校验**:`add_project_member` 对 `user_id` / `group_id` 补 UUID 形状校验(非 UUID → 400),封掉「任意字符串当 group 主体」的历史入口(现状 `projects.py:459-468` 无格式校验);`remove_project_member` 的 `subject` Query 参数同样补形态校验——必须是 `user:<uuid>` 或 `group:<uuid>#member`,否则 400(防客户端漏 `#member` 后缀时投影匹配不到 → 204 假成功 + audit 记了 removed 但真实 tuple 残留)。folder 侧同类入口本期不收口,见 §6。
- 自撤拦截(`subject == user.subject` → 409)原样保留。**顺带语义微变(声明非回归)**:被撤 subject 本就无 admin tuple(stale 客户端重复撤销)时,现状在剩余 admin ≤1 的情况下会误 409,新算法幸存集非空即 204 幂等 no-op——更合理的幂等语义。
- 原「接受 leaf 透传语义」注释(`projects.py:519-520`)随之退役,替换为上述投影语义说明。
- 代价:1 次 admin tuple read;撤组场景再加 K 次组 member tuple 读,PoC 量级可忽略。
- **已知局限(声明接受,与现状同病非回归)**:① 判定与随后的 tuple 删除非原子,两个 admin 并发互撤仍可能竞态归零——现状同样如此,PoC 量级接受;② 幸存集只展开一层 `user:` 型 member tuple,嵌套组/department#member 型成员不计入(模型允许嵌套但全库无写入路径);**幸存主体侧**理论上若有 `department:<id>#member` 型遗留 admin tuple 也被算法忽略——但该形态实际可达性极低(v4 模型 `admin: [user, group#member]` 在 FGA 层就拒写 department admin;API 侧 #56 起也一直显式拦;seed 只写过 department viewer/uploader,从未写过 admin),仅当作 v3 时代/脚本直写残留防御:实现对幸存 tuple 的未知 kind 记 log 便于排查,**不为此写测试**;③ 相邻的 admin 清零路径**不在本批加固**:`remove_group_member` / `delete_directory_group`(`directory.py:564-607` / `:439-484`)与用户停用(`directory.py:190-207`)都可能把「组是唯一 admin 来源」的项目清零——三者均 `require_system_admin` 才可达、且 system admin 直通可自救,声明接受;④ admin tuple read 照 `projects.py:365-369` 的写法是**单页读取不翻页**(continuation_token 不处理,`list_group_member_tuples` 同型)——项目 tuple 数超单页上限时幸存集可能漏算,与 `list_project_members` 同病,继承限制;实现时若 SDK 顺手可翻页,不强求。

**前端(1 处)** — `web/src/components/ProjectMembersDrawer.tsx`:

- 删除 InviteModal 中 `hasGroupSubject` 警告块(`:563-567`「⚠ 用户组主体不能授『管理』…」)及 `hasGroupSubject` 变量。
- 角色 hint 里管理一条补充组语义:「管理:全部权限 + 可管成员 + 可建敏感目录(用户组授权 = 组成员均获管理)」。

### 1.3 无需改动但必须回归的点

| 点 | 原因 |
|---|---|
| `remove_project_member` admin 不变量(#106) | **经 §1.2 改动 2 加固后成立**(原 leaf 计数对组授权场景失效,见该节);MemberCard 撤销传完整 subject(含 `#member`),删除 tuple 匹配 |
| `list_project_members` 展示 | subject 解析已 `rsplit('#', 1)` 剥后缀(`projects.py:380`),组 admin 正常聚合出「管理」徽章 + 🛡 图标 |
| `_fill_project_admins`(项目卡 admin 列表) | leaf user 展开,组成员会以其个人名出现在 admin 列表,符合预期 |
| OpenFGA model | **不 push 新 model**,现网模型已含 `admin: [user, group#member]` |

### 1.4 测试

容器内集成测试(`tests/test_v4_permissions.py`,沿用 Evan/outsider/PROJECT_EVENT 常量;建组走 `POST /api/v1/admin/directory/groups` + 挂成员,写法照 `tests/test_directory.py:124-133`——seed 脚本不建 groups 表数据,不存在现成 fixture 组):

- 新增 `test_project_member_group_admin_cycle`:建组(Evan+outsider)→ `POST /members {group_id, roles:["admin"]}` 204 → 组内非创建者用户调用 list_members/加成员成功(can_admin 生效)→ `GET /members` 该组带 admin 徽章 → DELETE 撤回 → can_admin 消失。
- 新增 `test_group_admin_lockout_guard`(对应 §1.2 改动 2)。setup 编排(项目天生 ≥1 个 user admin——bootstrap 必写创建者 admin 且 admin 不可自撤,「组为唯一来源」需多步到达):① Evan 建项目(或复用 PROJECT_EVENT,Evan 是 admin);② 授 2 人组(Evan+outsider)admin;③ **outsider**(组成员,已具 can_admin)撤掉 Evan 的 user admin → 204(此时组是唯一 admin 来源);④ 撤该组 admin → 409;⑤ 重新授一个 user admin 后再撤该组 → 204(授给组内成员亦可——直授 tuple 独立于组 tuple 幸存,这正是 §1.2 改动 2 放弃减法改用幸存 tuple 投影的原因)。
- 新增重叠回归用例:Evan 直授 admin + 给含 Evan 的组授 admin → 撤**组的** admin → 204 且 Evan 仍 can_admin(直授 tuple 幸存;该场景是减法算法的误杀反例,必须直拍)。
- 新增 UUID 入口校验用例:`POST /members {group_id: "grp_editors", roles:["viewer"]}` → 400(§1.2 配套入口校验)。
- 回归:现有 `test_project_member_add_remove_cycle` 不动应全绿。

---

## 2. 批次一(B):主体名称解析 —— 用户组显示 id → 名称

### 2.1 现状:4 处同款兜底

「用户组 {id[:12]}…」fallback 分散在 4 个列表接口,均只对 `user` 批量查了 `users.name`,group 从未 join `groups.name`(表里有该列,`api/app/db/tables.py:322`):

| 接口 | 位置 | 前端落点 |
|---|---|---|
| `GET /projects/{id}/members` | `api/app/routers/projects.py:399-402` | 成员抽屉「直接成员」 |
| `GET /projects/{id}/grants` | `api/app/services/grant_overview.py:182-184` | 成员抽屉「授权总览」 |
| `GET /folders/{id}/members` | `api/app/routers/folders.py:585-587` | 夹成员列表 |
| `GET /folders/{id}/grants` | `api/app/routers/folders.py:719-720` | 夹授权面板 |

### 2.2 方案:统一 helper 收敛 4 处

新建 `api/app/services/subject_names.py`:

```python
class SubjectNameInfo(TypedDict):
    name: str
    found: bool   # True=users/groups 表命中;False=已删/存量非 UUID(走 id 兜底)

async def resolve_subject_names(
    db: AsyncSession, subjects: list[str],
) -> dict[str, SubjectNameInfo]:
    """OpenFGA subject 串 → {name, found}。批量查 users + groups;
    未命中(主体已删/存量非 UUID)name 回退 sid[:12]+"…"、found=False。

    subject 形如 user:<uuid> / group:<uuid>#member(部门存量按原样走 id 兜底)。
    """
```

返回 `{subject: {"name": str, "found": bool}}`:列表类调用方只取 `name`(`found` 忽略);需要区分「主体已删」的调用方(§4.2 模板列表的 `missing` 标记)用 `found`——模板 items 写入时已校验存在且只收 UUID,故 `found=False` 即主体已删,不会与存量非 UUID 主体混淆。

- 解析 kind/sid(复用各处现有 `split(':', 1)` + `rsplit('#', 1)` 逻辑);
- user ids 与 group ids 各一次 `WHERE id IN (...)`(`_parse_uuids` 容错非法 UUID 的写法搬进来,存量飞书 open_id tuple 不炸);
- **兜底在 helper 内统一完成**:未命中(主体已删 / 存量非 UUID)直接填 `name = sid[:12] + "…"`,调用方拿到的 dict 必含该 subject、不再二次兜底。注意兜底格式变化:不再拼「用户组/部门」前缀——主体类型由 UI 的 KindTag(用户/群组/部门)展示,前缀冗余;§2.3 断言按新格式写。

4 个调用点改为:先收集 subjects → 一次 `resolve_subject_names` → 回填,删除各自的 inline 查询与「用户组/部门 label 前缀」逻辑。返回体结构不变(仍填 `name` 字段),**前端零改动**。

### 2.3 测试

注意:seed 脚本**不写 groups 表**(`seed_demo_data.py` 的 OpenFGA 组 tuple 用的是非 UUID 字符串 `GRP_EDITORS = "grp_editors"`),不存在现成「seed 组」可用;测试内现建组,写法照 `tests/test_directory.py:128-133`:

- `test_v4_permissions.py` 新增:`POST /api/v1/admin/directory/groups` 现建组(真实 UUID + name)→ 给项目授该组 viewer → `GET /members` 断言 `name == 组名`(不再是 `用户组 xxx`)。
- `grant_overview` / folder 两接口各加一条同型断言(同样用现建组)。
- 边界①存量非 UUID 主体:seed 写入的 `group:grp_editors#member` tuple 本来就在 PROJECT_EVENT 的成员列表里 → 断言其 name 为 id 兜底值 `"grp_editors…"`(新格式,无「用户组」前缀)且接口不 500,`_parse_uuids` 容错路径有直拍用例。
- 边界②组删除后 tuple 残留 → name 回退 `id[:12]…`,接口不 500。

---

## 3. 批次二(C-Step1):`initial_grants` 创建时直通

### 3.1 API

`ProjectCreateIn`(`api/app/models/__init__.py:15`)增加可选字段:

```python
from app.services.permissions import ProjectRole   # 现 Literal 定义处;已核实无循环依赖
                                                   # (permissions.py 只 import settings/openfga_sdk)

class InitialGrantIn(BaseModel):
    kind: Literal["user", "group"]
    id: uuid.UUID                      # user: users.id(需 active);group: groups.id(需存在)
    roles: list[ProjectRole]           # 非空、去重;admin 允许 group(批次一已放开)

class ProjectCreateIn(BaseModel):
    ...  # 现有字段不动
    initial_grants: list[InitialGrantIn] | None = None   # 不传/空 = 现行为
```

实现注记:`fmt_subject` 收 `str`,`id` 传参时写 `fmt_subject(g.kind, str(g.id))`;roles 的**非空/非法校验放 Pydantic 层**(`min_length=1`),**去重落点在 `create_project` 路由内**用本文件的 `PROJECT_ROLES` 常量(`projects.py:317`)——不要在 models 层做顺序去重(`PROJECT_ROLES` 在 routers 里,models import routers 会成环;`ProjectRole` Literal 的声明顺序与 `PROJECT_ROLES` 不同,勿混用)。

`create_project`(`projects.py:40`)流程:

1. **前置校验(建项目之前,原子无半吊子;400 = 业务存在性/重复,422 = Pydantic 形状)**:`initial_grants` 条数上限 **50**(超出 422,防超大 payload 串行写 OpenFGA 拖垮请求);payload 内 `(kind,id)` 重复 → 400;逐条查 user(active)/group 存在性,任一不满足 → 400 指明第几条、什么主体;roles 空数组 / 非法值 → 422(Pydantic `min_length=1` + Literal)。
2. 建项目行 + `bootstrap_project`(现状不动)。
3. 循环 `add_project_subject(fmt_subject(kind, id), role)`;`is_already_exists_error` 幂等跳过(**必须**:admin_user_id 与 initial_grants 重复授 admin 是合理输入)。
4. audit:**仅真正写入的**记一条 `project_member_added`(details 加 `"via": "initial_grants"`),复用下游按 event_type 过滤的查询;幂等跳过分支**不写 audit**(与 `add_project_member` 现状一致,`:483-485` 的 continue 在 audit 之前);`project_created` 的 details 增 `initial_grants_count`。

**错误语义(明确写死)**:OpenFGA 中途失败 = 项目行已提交但授权部分缺失 → 500,与现状 bootstrap 失败同类同治(OpenFGA 挂 = 整站挂);修复路径 = 成员抽屉手动补授。不做部分成功响应体。

### 3.2 前端

- **抽公共组件**:`InviteModal` 里的角色多选 chips(`ProjectMembersDrawer.tsx:524-547`)抽成 `web/src/components/RoleChipGroup.tsx`(props: `value/onChange/disabled?`),InviteModal 与 NewProjectModal 共用,角色 hint 文案随迁。
- `NewProjectModal.tsx` 增加「初始权限(可选)」区,**结构 = 主体行列表,每行独立角色**(与 `initial_grants` 的每条目自带 roles 一一对应,也为批次三模板预填留好数据形状——模板条目就是每主体各自角色,共享单套角色的 UI 表达不了异构模板,预填时取并集还会静默放大授权):
  - `SubjectPicker`(复用,多选 user+group)选主体;选中后下方渲染**每主体一行**:主体名/类型 + 该行自己的 `RoleChipGroup`;
  - 任一行选了主体但没选角色 → 提交前 `message.warning('请至少勾选一个角色')` + 行内提示(文案与 InviteModal 现状一致,`:552-553`;载体在抽组件时顺手统一);
  - submit:每行组装成一条 `{kind, id, roles}` 拼进 `initial_grants` 传给 `useCreateProject`(hooks.ts body 类型同步扩展);
  - 成功 toast:「项目已创建,已为 N 个主体授予初始权限」;创建后打开成员抽屉即可核对。
- 不选任何主体 = 完全兼容现行为。

### 3.3 测试

- 建 project 带 `initial_grants=[{group, uploader}, {user, downloader}]` → 组成员 `can_upload` ✓、user `can_download` ✓(走既有 check 断言写法);
- 兼容:不带 initial_grants 的旧调用不变;
- 校验:未知 user 400、组不存在 400、roles 空数组 422、超过 50 条 422、payload 内 `(kind,id)` 重复 400、admin_user_id 重复出现在 initial_grants(幂等,201);
- 前端 `pnpm build` + 手工冒烟。

---

## 4. 批次三(C-Step2):项目权限模板模块

> 模板 = **保存的授权组合预设**(一组 {主体, 角色});新建项目时选模板预填,降低管理员重复操作。落地方式:**前端预填,后端不感知模板**(见 4.3 决策)。

### 4.1 DB(需 alembic migration)

`api/app/db/tables.py` 新增两张表(风格对齐 `Group`/`GroupMembership`):

```python
class ProjectGrantTemplate(Base, TimestampMixin):
    __tablename__ = "project_grant_templates"
    id            # UUID PK default uuid4
    organization_id  # FK organizations.id, not null
    name: str(128)
    description: str(1024) | None
    is_default: bool = False
    # UniqueConstraint("organization_id", "name", name="uq_pgt_org_name")   # 同 org 内唯一
    # Index("uq_pgt_default_per_org", "organization_id", unique=True,
    #       postgresql_where=text("is_default"))   # 每 org 至多 1 个 default

class ProjectGrantTemplateItem(Base):
    __tablename__ = "project_grant_template_items"
    id           # UUID PK
    template_id  # FK → project_grant_templates.id, ondelete CASCADE
    subject_kind: str(8)   # 'user' | 'group'
    subject_id: UUID
    roles: JSONB            # list[ProjectRole];全库 ORM 惯例 JSONB,不用 JSON
    created_at              # server_default,对齐 GroupMembership(tables.py:325-337)
    # UniqueConstraint(template_id, subject_kind, subject_id)
```

migration:文件 `2026_09_30_0012_grant_templates.py`,revision `"20260930_0012"`、down_revision `"20260809_0011"`(接 `2026_08_09_0011_asset_labels_trgm_expr.py` 之后;照 `2026_08_09_0006_identity_wave0.py` 的 groups 建表写法)。两个注意:① partial unique index 是全库首例,ORM 侧写法如上,alembic 侧用 `op.create_index(..., unique=True, postgresql_where=sa.text("is_default"))` 显式落,downgrade `op.drop_index`;② 合入前若并行分支先落了 0012,按 CLAUDE.md 提示重排号避撞。

### 4.2 API(模板 CRUD,`api/app/routers/admin.py`,`require_system_admin`)

> 落位取舍:放 `admin.py` 而非 `directory.py`——后者是「组织目录」域(用户/用户组 CRUD),模板属项目授权域;`admin.py` 的 `require_system_admin` 惯例与 audit 端点同在,不新增 router 文件。

| 端点 | 行为 |
|---|---|
| `GET /api/v1/admin/grant-templates` | 列表(含 items + 解析后的主体名称,**复用 §2 的 `resolve_subject_names`**;`found=False` 即主体**已删**,item 标 `missing: true`。注意停用/离职用户 DB 行仍在、`found=True` 不标 missing——离职场景靠建项目时的 active 校验 400 兜底,本期不在模板列表区分) |
| `POST /api/v1/admin/grant-templates` | `{name, description?, is_default?, items:[{kind,id,roles}]}`;校验主体存在(user 需 active)、roles 合法、**items 条数上限 50(与 §3.1 initial_grants 同一常量,超出 422——模板预填后提交建项目不能被 50 上限卡住)**;payload 内 `(kind,id)` 重复 → 400(预检,勿裸抛 IntegrityError);**name 与同 org 现有模板重复 → 409**(预检照 `routers/directory.py:379-381` 的 create_directory_group,并发漏检兜底捕获 `IntegrityError` → 409,写法参照 `projects.py:98-105` 对 projects_code_key 的处理);`is_default=true` 时同事务清掉旧 default(先 UPDATE 旧行再写新行,**同一事务提交**,勿分两次 commit) |
| `PATCH .../grant-templates/{id}` | 改名/描述/替换 items/设默认(items 全量替换,id 不存在 → 404);**改名撞同 org 已有 name → 409(预检需排除自身)**;items 的条数/重复主体/name 校验同 POST;`is_default` true→false = 直接取消默认(不产生新 default),合法输入 |
| `DELETE .../grant-templates/{id}` | 级联删 items(id 不存在 → 404) |

`organization_id` **不由 body 传入**:服务端取 `get_default_organization`(单租户,`deps.py:199-205` 同款)回填。并发双 POST 同时设 default 撞 partial unique index → 捕获 `IntegrityError` 返 409「并发设置默认,请重试」,不裸 500。

audit:模板增删改各记一条 `grant_template_changed`(details 带操作与 name);按 CLAUDE.md 约定**同步在 `web/src/lib/labels.ts` 补该 event_type 的中文映射**(缺 key 会回落英文 raw token),PR-3 一并带上。

### 4.3 应用方式(已定):前端预填,不做服务端 `template_id`

理由:

1. **单一事实源**:`POST /projects` 只认 `initial_grants`,模板不进入授权链路,模板事后修改不影响任何已建项目;
2. **所见即所得**:预填后管理员仍可在弹窗里增删主体/改角色再提交,提交的就是看到的;
3. 后端零模板解析逻辑,批次二先行上线后批次三对其**零改动**。

若未来脚本/第三方建项目需服务端套模板,再加 `POST /projects` 可选 `template_id`(写入 §6 留口,本期不做)。

### 4.4 前端

- **新页面** `web/src/pages/AdminGrantTemplatesPage.tsx`,路由 `/admin/grant-templates`(App.tsx + admin 菜单入口,门控与 AdminGroupsPage 一致);布局照 AdminGroupsPage:模板列表 + 新建/编辑 Modal(名称/描述/is_default 开关 + 条目编辑器 = `SubjectPicker` + `RoleChipGroup`,即批次二抽出的两个复用件)。
- **NewProjectModal** 顶部加「权限模板」Select:选项 = `不使用模板` + 模板列表(带描述);**默认值 = org 的 is_default 模板**(有则预选中);onChange 将 items **逐条**预填进「初始权限」区(每个 item → 一个主体行 + 该行自己的角色勾选,§3.2 的行式结构天然承载异构模板);预填后可自由增删行/改角色。

### 4.5 边界情况

| 情况 | 处理 |
|---|---|
| 模板条目主体**已删** | 列表接口标 `missing` → 模板编辑页提示清理;新建项目预填后提交会 400(存在性校验),toast 指明条目 |
| 模板条目用户**离职**(is_active=False,行仍在) | 不标 `missing`(found=True);建项目提交时被 §3.1 前置校验 400 拦下,toast 指明条目 |
| org 无任何模板 | Select 只有「不使用模板」,初始权限区照常手选 |
| 删除 is_default 模板 | 允许;org 无默认,Select 回落「不使用模板」 |

### 4.6 测试

前置(既有约定,勿在宿主机直接 pytest):容器内跑 + `scripts/seed_demo_data.py` 已 seed + 先 `redis-cli FLUSHALL` 清登录限流。

- 新 `tests/test_grant_templates.py`(容器内;`tests/` 无 conftest,session 级 `app_with_lifespan`/`client` fixture 照抄 `test_v4_permissions.py:50-61` 的形态):CRUD 全 cycle、default 唯一性(设第二个 default → 第一个自动取消;true→false 取消默认不产生新 default)、**同 org 重名 → 409(POST 与 PATCH 改名各一条,PATCH 改回自身原名应放行)**、payload 内重复主体 400、items 超 50 条 422、items `kind` 非法 422、PATCH/DELETE 不存在 id 404、items 级联删除、非 system admin 403、主体不存在 400;
- 端到端:建模板 → NewProjectModal 选中预填 → 提交 → 成员抽屉核对授权与模板一致(手工冒烟)。

---

## 5. 实施顺序与验收清单

### 顺序(3 个独立可上线批次,依赖关系:二依赖一A,三依赖二)

| 批次 | 内容 | 部署注意 |
|---|---|---|
| PR-1 | §1 放开组管理(**含 admin 不变量加固**,见 §1.2 改动 2)+ §2 组名解析(纯代码,无 migration) | rsync 生效即可,**不需要** push FGA model、无 alembic |
| PR-2 | §3 initial_grants 直通 + RoleChipGroup 抽取 | 同上 |
| PR-3 | §4 模板模块(含 `labels.ts` event_type 映射) | **有 alembic migration**,deploy 流程含 `alembic upgrade head` |

每批独立走:ruff + mypy(strict)+ 容器内 pytest + `pnpm build/lint` + server2 dev 部署 tester 验证;三批均为用户可见更新,**每批合入当天在 `scripts/changelog.md` 记账**(AGENTS.md 约定)。

### 用户可见验收清单

1. 【邀请】选用户组 + 勾「管理」→ 提交成功,成员列表该组带「管理」徽章 + 🛡;组内其他成员立即能管理该项目。
2. 撤销「唯一 admin 来源的用户组」的管理授权 → 409 拒绝(项目不失去管理入口);已有其他 admin 时撤组授权正常成功。
3. 成员抽屉两区、夹成员、夹授权——**有 groups 表行的用户组一律显示组名**;存量非 UUID 主体(如 seed 的 grp_editors)显示无前缀短 id(`grp_editors…`,KindTag 已标类型),不再是「用户组xxxxxxxx-xxx…」。
4. 新建项目弹窗:可选模板(默认模板自动预填)或手选主体+角色 → 创建完成成员抽屉里授权已就位,零手动补授。
5. 管理后台「权限模板」页可增删改模板、设默认;默认模板对后续新建项目自动生效(预填);模板增删改在审计页显示中文事件名。

---

## 6. 明确不做 / 留口

- **不改 OpenFGA model**:现网模型已支持组 admin,`openfga_write_model.sh` 不需要跑。
- **不做服务端 `template_id` 建项目**(理由 §4.3;接口留口:未来 `POST /projects` 加可选 `template_id`,服务端展开为 initial_grants)。
- **不动 department 轴存量 tuple**(照 ADR-0007 原样保留,name 兜底路径保留)。
- **folder 侧 group 入口本期不收口 UUID 校验**(`folders.py` 的 invite / sensitive invite / grants 写入口 `group_id` 仍收任意字符串)——folder 无 admin 关系、无锁死风险;由此产生的幽灵组 tuple 由 §2 helper 的 id 兜底承接显示,留待后续批次统一收口。
- **不做模板审计报表**(`grant_template_changed` 只进 audit 流,不做专门查询页)。
