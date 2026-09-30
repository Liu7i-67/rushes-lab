# 成员权限三项改动:用户组授管理 + 组名显示 + 新建项目自动授权 · 实施方案

> Status: **已确认待实施**(2026-09-30 与用户对齐三项决策)
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
- 下游代码当年就按 group-admin 存在设计:`remove_project_member` 的「至少保留 1 个管理员」兜底注释明确写了「group-admin 间接 user 也计入,接受 OpenFGA list_users 透传 leaf users 的语义」(`api/app/routers/projects.py:519-520`);`_fill_project_admins` 走 `list_users_with_relation`,group#member 自动展开为成员用户,项目卡 admin 列表无需改动。

**放开后的语义(需在 UI hint 中写明)**:用户组授管理后,组成员**当时与日后加入的成员**都自动获得项目管理员(可管成员/可建敏感目录),直到撤回该组的 admin 授权或移出该组。这与 viewer/uploader/downloader 的组授权语义一致。

### 1.2 改动点

**后端(1 处)** — `api/app/routers/projects.py` `add_project_member`:

```python
# 删除 projects.py:466-468
if "admin" in roles and chosen[0][0] != "user":
    # model v4 限 admin: [user, group#member]
    raise HTTPException(400, "admin 不允许直接给 group;请改给 user")
```
连同该函数 docstring 中隐含的「admin 仅 user」表述一并清理。写入路径零改动:`fmt_subject('group', id)` → `add_project_subject(role='admin')` 天然合法。

**前端(1 处)** — `web/src/components/ProjectMembersDrawer.tsx`:

- 删除 InviteModal 中 `hasGroupSubject` 警告块(`:563-567`「⚠ 用户组主体不能授『管理』…」)及 `hasGroupSubject` 变量。
- 角色 hint 里管理一条补充组语义:「管理:全部权限 + 可管成员 + 可建敏感目录(用户组授权 = 组成员均获管理)」。

### 1.3 无需改动但必须回归的点

| 点 | 原因 |
|---|---|
| `remove_project_member` admin 不变量(#106) | `group:{id}#member` 的 admin tuple 经 `list_users_with_relation` 展开为 leaf user 计数,「至少 1 个管理员」判定依旧成立;MemberCard 撤销传完整 subject(含 `#member`),删除 tuple 匹配 |
| `list_project_members` 展示 | subject 解析已 `rsplit('#', 1)` 剥后缀(`projects.py:380`),组 admin 正常聚合出「管理」徽章 + 🛡 图标 |
| `_fill_project_admins`(项目卡 admin 列表) | leaf user 展开,组成员会以其个人名出现在 admin 列表,符合预期 |
| OpenFGA model | **不 push 新 model**,现网模型已含 `admin: [user, group#member]` |

### 1.4 测试

容器内集成测试(`tests/test_v4_permissions.py`,沿用 Evan/outsider/PROJECT_EVENT fixture):

- 新增 `test_project_member_group_admin_cycle`:建组(Evan+outsider)→ `POST /members {group_id, roles:["admin"]}` 204 → 组内非创建者用户调用 list_members/加成员成功(can_admin 生效)→ `GET /members` 该组带 admin 徽章 → DELETE 撤回 → can_admin 消失。
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
| `GET /folders/{id}/grants` | `api/app/routers/folders.py:722-724` | 夹授权面板 |

### 2.2 方案:统一 helper 收敛 4 处

新建 `api/app/services/subject_names.py`:

```python
async def resolve_subject_names(
    db: AsyncSession, subjects: list[str],
) -> dict[str, str]:
    """OpenFGA subject 串 → 显示名。批量查 users + groups;未命中回退 id[:12]+…。

    subject 形如 user:<uuid> / group:<uuid>#member(部门存量按原样走 id 兜底)。
    """
```

- 解析 kind/sid(复用各处现有 `split(':', 1)` + `rsplit('#', 1)` 逻辑);
- user ids 与 group ids 各一次 `WHERE id IN (...)`(`_parse_uuids` 容错非法 UUID 的写法搬进来,存量飞书 open_id tuple 不炸);
- 返回 `{subject: name}`;调用方 `dict.get(subject, sid[:12] + "…")` 保持老兜底(组被删时不白屏)。

4 个调用点改为:先收集 subjects → 一次 `resolve_subject_names` → 回填,删除各自的 inline 查询与「用户组/部门 label 前缀」逻辑。返回体结构不变(仍填 `name` 字段),**前端零改动**。

### 2.3 测试

- `test_v4_permissions.py` 新增:给项目授一个 seed 组 viewer → `GET /members` 断言 `name == 组名`(不再是 `用户组 xxx`)。
- `grant_overview` / folder 两接口各加一条同型断言(走已有 fixture 组)。
- 边界:组删除后 tuple 残留 → name 回退 `id[:12]…`,接口不 500。

---

## 3. 批次二(C-Step1):`initial_grants` 创建时直通

### 3.1 API

`ProjectCreateIn`(`api/app/models/__init__.py:15`)增加可选字段:

```python
class InitialGrantIn(BaseModel):
    kind: Literal["user", "group"]
    id: uuid.UUID                      # user: users.id(需 active);group: groups.id(需存在)
    roles: list[ProjectRole]           # 非空、去重;admin 允许 group(批次一已放开)

class ProjectCreateIn(BaseModel):
    ...  # 现有字段不动
    initial_grants: list[InitialGrantIn] | None = None   # 不传/空 = 现行为
```

`create_project`(`projects.py:40`)流程:

1. **前置校验(建项目之前,全量 400,原子无半吊子)**:逐条查 user(active)/group 存在性,任一不满足 → 400 指明第几条、什么主体;roles 空数组 / 非法值 → 422(Pydantic)。
2. 建项目行 + `bootstrap_project`(现状不动)。
3. 循环 `add_project_subject(fmt_subject(kind, id), role)`;`is_already_exists_error` 幂等跳过(**必须**:admin_user_id 与 initial_grants 重复授 admin 是合理输入)。
4. audit:每条角色一条 `project_member_added`(details 加 `"via": "initial_grants"`),复用下游按 event_type 过滤的查询;`project_created` 的 details 增 `initial_grants_count`。

**错误语义(明确写死)**:OpenFGA 中途失败 = 项目行已提交但授权部分缺失 → 500,与现状 bootstrap 失败同类同治(OpenFGA 挂 = 整站挂);修复路径 = 成员抽屉手动补授。不做部分成功响应体。

### 3.2 前端

- **抽公共组件**:`InviteModal` 里的角色多选 chips(`ProjectMembersDrawer.tsx:524-547`)抽成 `web/src/components/RoleChipGroup.tsx`(props: `value/onChange/disabled?`),InviteModal 与 NewProjectModal 共用,角色 hint 文案随迁。
- `NewProjectModal.tsx` 增加「初始权限(可选)」区:
  - `SubjectPicker`(复用,多选 user+group)+ `RoleChipGroup`;
  - 选了主体但没选角色 → 提交前 `message.warning`(与 InviteModal 同文案);
  - submit:subjects 非空时组装 `initial_grants` 传给 `useCreateProject`(hooks.ts body 类型同步扩展);
  - 成功 toast:「项目已创建,已为 N 个主体授予初始权限」;创建后打开成员抽屉即可核对。
- 不选任何主体 = 完全兼容现行为。

### 3.3 测试

- 建 project 带 `initial_grants=[{group, uploader}, {user, downloader}]` → 组成员 `can_upload` ✓、user `can_download` ✓(走既有 check 断言写法);
- 兼容:不带 initial_grants 的旧调用不变;
- 校验:未知 user 400、组不存在 400、roles 空数组 422、admin_user_id 重复出现在 initial_grants(幂等,201);
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
    name: str(128)       # 同 org 内唯一
    description: str(1024) | None
    is_default: bool = False   # 每 org 至多 1 个,partial unique index
    # Index("uq_pgt_default_per_org", "organization_id", unique=True,
    #       postgresql_where=text("is_default"))

class ProjectGrantTemplateItem(Base):
    __tablename__ = "project_grant_template_items"
    id           # UUID PK
    template_id  # FK → project_grant_templates.id, ondelete CASCADE
    subject_kind: str(8)   # 'user' | 'group'
    subject_id: UUID
    roles: JSON             # list[ProjectRole]
    # UniqueConstraint(template_id, subject_kind, subject_id)
```

migration:新 revision `2026_09_30_xx_grant_templates.py`(照 `2026_08_09_0006_identity_wave0.py` 的 groups 建表写法)。

### 4.2 API(模板 CRUD,`api/app/routers/admin.py`,`require_system_admin`)

| 端点 | 行为 |
|---|---|
| `GET /api/v1/admin/grant-templates` | 列表(含 items + 解析后的主体名称,**复用 §2 的 `resolve_subject_names`**;主体已删的 item 标 `missing: true`) |
| `POST /api/v1/admin/grant-templates` | `{name, description?, is_default?, items:[{kind,id,roles}]}`;校验主体存在(user 需 active)、roles 合法;`is_default=true` 时同事务清掉旧 default |
| `PATCH .../grant-templates/{id}` | 改名/描述/替换 items/设默认(items 全量替换) |
| `DELETE .../grant-templates/{id}` | 级联删 items |

audit:模板增删改各记一条 `grant_template_changed`(details 带操作与 name)。

### 4.3 应用方式(已定):前端预填,不做服务端 `template_id`

理由:

1. **单一事实源**:`POST /projects` 只认 `initial_grants`,模板不进入授权链路,模板事后修改不影响任何已建项目;
2. **所见即所得**:预填后管理员仍可在弹窗里增删主体/改角色再提交,提交的就是看到的;
3. 后端零模板解析逻辑,批次二先行上线后批次三对其**零改动**。

若未来脚本/第三方建项目需服务端套模板,再加 `POST /projects` 可选 `template_id`(写入 §6 留口,本期不做)。

### 4.4 前端

- **新页面** `web/src/pages/AdminGrantTemplatesPage.tsx`,路由 `/admin/grant-templates`(App.tsx + admin 菜单入口,门控与 AdminGroupsPage 一致);布局照 AdminGroupsPage:模板列表 + 新建/编辑 Modal(名称/描述/is_default 开关 + 条目编辑器 = `SubjectPicker` + `RoleChipGroup`,即批次二抽出的两个复用件)。
- **NewProjectModal** 顶部加「权限模板」Select:选项 = `不使用模板` + 模板列表(带描述);**默认值 = org 的 is_default 模板**(有则预选中);onChange 将 items 预填进「初始权限」区(转成 SubjectPicker 选中项 + 每主体的角色勾选;预填后可自由增删改)。

### 4.5 边界情况

| 情况 | 处理 |
|---|---|
| 模板条目主体已删/离职 | 列表接口标 `missing` → 模板编辑页提示清理;新建项目预填后提交会 400(存在性校验),toast 指明条目 |
| org 无任何模板 | Select 只有「不使用模板」,初始权限区照常手选 |
| 删除 is_default 模板 | 允许;org 无默认,Select 回落「不使用模板」 |

### 4.6 测试

- 新 `tests/test_grant_templates.py`(容器内):CRUD 全 cycle、default 唯一性(设第二个 default → 第一个自动取消)、items 级联删除、非 system admin 403、主体不存在 400;
- 端到端:建模板 → NewProjectModal 选中预填 → 提交 → 成员抽屉核对授权与模板一致(手工冒烟)。

---

## 5. 实施顺序与验收清单

### 顺序(3 个独立可上线批次,依赖关系:二依赖一A,三依赖二)

| 批次 | 内容 | 部署注意 |
|---|---|---|
| PR-1 | §1 放开组管理 + §2 组名解析(纯代码,无 migration) | rsync 生效即可,**不需要** push FGA model、无 alembic |
| PR-2 | §3 initial_grants 直通 + RoleChipGroup 抽取 | 同上 |
| PR-3 | §4 模板模块 | **有 alembic migration**,deploy 流程含 `alembic upgrade head` |

每批独立走:ruff + mypy(strict)+ 容器内 pytest + `pnpm build/lint` + server2 dev 部署 tester 验证。

### 用户可见验收清单

1. 【邀请】选用户组 + 勾「管理」→ 提交成功,成员列表该组带「管理」徽章 + 🛡;组内其他成员立即能管理该项目。
2. 成员抽屉两区、夹成员、夹授权——凡用户组一律显示组名,无「用户组xxxxxxxx-xxx…」。
3. 新建项目弹窗:可选模板(默认模板自动预填)或手选主体+角色 → 创建完成成员抽屉里授权已就位,零手动补授。
4. 管理后台「权限模板」页可增删改模板、设默认;默认模板对后续新建项目自动生效(预填)。

---

## 6. 明确不做 / 留口

- **不改 OpenFGA model**:现网模型已支持组 admin,`openfga_write_model.sh` 不需要跑。
- **不做服务端 `template_id` 建项目**(理由 §4.3;接口留口:未来 `POST /projects` 加可选 `template_id`,服务端展开为 initial_grants)。
- **不动 department 轴存量 tuple**(照 ADR-0007 原样保留,name 兜底路径保留)。
- **不做模板审计报表**(`grant_template_changed` 只进 audit 流,不做专门查询页)。
