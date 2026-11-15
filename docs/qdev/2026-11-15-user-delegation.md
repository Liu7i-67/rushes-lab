# 用户模块组级授权开放方案（新建用户 + 重置密码 + 账号创建人）

- 日期：2026-11-15
- 分支：`feat/user-delegation`（自 liuqi f837a25 切出）
- worktree：`E:\qbb\github_not_me\rushes-lab-feat-user-delegation`
- 状态：已定稿（模糊点两问用户未作答，按推荐默认拍板，见 §9）

## 1. 背景与目标

管理后台「用户」模块现仅系统管理员（org admin）可用（directory.py 全端点 `require_system_admin`）。需求：把用户模块**开放给部分用户组**——

1. 用户模块显示**账号创建人**（users 表现无 created_by，需加列 + 存量回填）。
2. 管理员在**用户组**处给指定组开放用户模块，开放时指定该组成员**新建用户时可选择的用户组**（多选）。例：存在 ABCD 四组，给 B 组开放并配置可新建 A、C 组类型的用户 → B 组成员可见用户模块，新建用户时只能把用户加入 A 或 C 组。
3. 数据权限：管理员看全部用户；非管理员（被授权组成员）**只能看到自己创建的用户**。
4. 被授权组成员可执行的操作 = **查看自己创建的用户 + 新建用户 + 重置密码**（最小集）。
5. 三端同步：api + web 管理后台 + Flutter App。

## 2. 现状要点（调研结论，已核实）

- 用户/组管理端点全在 `api/app/routers/directory.py`（前缀 `/api/v1/admin/directory`），守门一律 `require_system_admin`（deps.py:226）。
- `users` 表（tables.py:59-83）**无 created_by**；建号走 `services/user_provisioning.provision_local_user`（audit `user_created` 的 actor_user_id 是创建人唯一可靠来源）。
- 组级 bool 开关先例（file_deleter 等 8 个）= organization 上的 FGA relation tuple，`_read_flag_group_ids` / `_sync_group_org_flag` 读写。但「授权组 → 目标组集合」是**组对组关系数据**，FGA org-level relation 表达不了，落 DB 表（见 §4 决策 D2）。
- Web：`AdminUsersPage.tsx` / `AdminGroupsPage.tsx`；菜单门在 `AppHeader.tsx:107-121`（PC）与 `MobileTabBar.tsx:51-59`（移动）；三态门先例 `(me.is_folder_template_manager ?? me.is_system_admin)`。
- App：`app/lib/features/admin/`（admin_users_page / user_form_sheets / admin_user_row / group_form_sheet）；Me 弱门回落先例 `models/me.dart:16-19`；目录模板例外闸门先例 `admin_tiles.dart:15-16` + `admin_home.dart`。
- 迁移链头 `20261031_0020`，本次用 `20261115_0021`。**不改动 FGA model**（store.fga.yaml 零变更，无推模型步骤）。

## 3. 功能点明细（可验收）

| # | 功能点 | 验收标准 |
|---|---|---|
| F1 | users.created_by 列 + 回填 | 迁移后 admin 建号 created_by=本人；存量用户按 audit user_created 最新 actor 回填；无来源=NULL 显示「—」 |
| F2 | 用户列表显示创建人 | Web/App 用户列表每行显示「创建人」；详情同样返回 created_by_name |
| F3 | 组授权配置入口 | Web/App 组表单新增「用户模块」开关 + 目标组多选；开关开时至少选 1 个目标组才允许提交 |
| F4 | 组列表回显授权 | 组行/组列表返回 user_create_group_ids+names；Web 组行显示徽标 |
| F5 | 授权组成员可见用户模块 | /me 返回 is_user_manager + user_create_groups（含名称）；Web/App 菜单按此放行「用户」入口（用户组等其余管理入口仍仅管理员） |
| F6 | 数据权限-列表 | 管理员 GET /users 看全部；被授权非管理员只看 created_by=自己的 |
| F7 | 新建用户-组受限 | 非管理员建号 group_ids ⊆ 授权目标组，违者 422（detail 带 invalid_group_ids）；空组可建（D3） |
| F8 | 新建用户-创建人落库 | 非管理员建号 created_by=操作者；临时密码回显一次流程不变 |
| F9 | 重置密码 | 管理员可重置任意；被授权非管理员仅可重置自己创建的；越权 403 |
| F10 | 其余操作仍管理员专属 | 非管理员对用户 PATCH/停用/启用/解锁/详情(他人) 一律 403；用户组管理全端点不变 require_system_admin |
| F11 | 撤销授权即时生效 | 组授权清空后，原被授权成员用户模块立即 403/不可见（含此前创建的用户不再可见） |
| F12 | 授权配置审计 | 组 PATCH 授权变更落 group_updated 审计（diff 含 user_create_group_ids 增删）；user_created details 增 created_by |
| F13 | 目标组删除级联 | 删除被引用的目标组/授权组 → 授权行级联删除，不孤儿 |

## 4. 数据库修改方案（迁移 20261115_0021）

1. `users.created_by`：`UUID NULL REFERENCES users(id) ON DELETE SET NULL`。
2. **存量回填**（同迁移内一条 UPDATE）：取每个用户 `user_created` 审计事件最新一条的 actor_user_id（`details->>'user_id'` 可转 uuid 且正则防护）写入 created_by，仅填 NULL 行。
3. 新表 `user_create_grants`：

```sql
CREATE TABLE user_create_grants (
    group_id        UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    target_group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (group_id, target_group_id)
);
```

- 语义：`(B, T)` 行 = B 组成员拥有用户模块访问权，且新建用户时可把用户加入 T 组。**授权态 = B 存在 ≥1 行**（无单独 bool 开关；空集合=未授权，D1）。
- ORM：tables.py 加 `UserCreateGrant` 模型 + `User.created_by` 列/FK。

## 5. 接口定义

### 5.1 守门与数据权限（directory.py）

新服务 `app/services/user_module_access.py`（唯一访问判定入口，~80 行）：

```python
@dataclass
class UserModuleAccess:
    is_system_admin: bool
    allowed_group_ids: frozenset[uuid.UUID]   # admin 恒为空集(不限制)

    @property
    def granted(self) -> bool: ...

async def resolve_user_module_access(db, permissions, user_id) -> UserModuleAccess:
    # 1) admin: perms.is_org_admin(照 require_system_admin 的 default org 解析)
    # 2) 非 admin: 一条 SQL —— SELECT DISTINCT g.target_group_id
    #    FROM user_create_grants g JOIN group_memberships m ON m.group_id = g.group_id
    #    WHERE m.user_id = :user_id
```

端点改造（4 个放宽 + 其余不动）：

| 端点 | 现守门 | 新守门 |
|---|---|---|
| GET /users | require_system_admin | get_current_user + resolve；非 granted 403；非 admin 追加 `User.created_by == user.id` 过滤（含 total） |
| POST /users | require_system_admin | get_current_user + resolve；非 granted 403；非 admin 且 group_ids 含非授权组 → 422 `{"invalid_group_ids": [...]}`（与不存在组同 marker，消息区分） |
| GET /users/{id} | require_system_admin | get_current_user + resolve；非 admin 且 target.created_by != user.id → 403（不存在仍 404） |
| POST /users/{id}/reset-password | require_system_admin | get_current_user + resolve；非 admin 且 target.created_by != user.id → 403 |
| PATCH /users/{id}、disable、enable、unlock | require_system_admin | **不变** |
| groups 全族 | require_system_admin | **不变** |

- `group_ids ≤50` / 组存在性校验复用 `_load_groups_for_ids` 既有顺序（409 重名优先于 422 组校验）。

### 5.2 组 CRUD 增量

- `DirectoryGroupOut` + `user_create_group_ids: list[UUID] = []` + `user_create_group_names: list[str] = []`（同序按组名排序，读接口查表真实态）。
- `GroupCreateIn` + `user_create_group_ids: list[UUID] = []`；`GroupUpdateIn` + `user_create_group_ids: list[UUID] | None = None`（**None=不动；list=全量替换终态；[]=撤销授权**，无 tri-state bool）。
- 校验：目标组必须存在（复用 `_load_groups_for_ids`，无效 422）、去重、≤50。
- POST/PATCH 写 `user_create_grants`（diff 加删）；DELETE 靠 FK CASCADE。审计 group_updated details.changes 增 `user_create_group_ids_added/removed`（仿 groups_added 现有结构）。

### 5.3 用户出参与建号

- `DirectoryUserOut` / `UserCreateOut` + `created_by_name: str | None`（列表页批量回显需 join users 别名一次查出，勿 N+1；NULL → 前端显示「—」）。
- `provision_local_user` 内 `User(..., created_by=actor_user_id)`；`user_created` details + `created_by`。admin 与组长链路同构（artist 链路顺带受益，不改其调用方）。
- 建号审计 source 沿用 `admin_create`；非管理员链路 source=`delegated_create`（仅审计区分，行为无差）。

### 5.4 /me 增量（auth.py）

- `is_user_manager: bool`（admin 恒 true；非 admin = resolve 授权态）
- `user_create_groups: list[{"id", "name"}]`（非 admin 被授权时=目标组集合；admin 返回 `[]`，前端 admin 走 directory groups 接口取全量选项）
- DB 直查，不进现有 FGA gather 块（放块后单独一次 SQL）。

## 6. 组件拆分方案与文件清单

| 端 | 文件 | 动作 | 预估行数 |
|---|---|---|---|
| api | app/db/tables.py | +User.created_by、+UserCreateGrant | +25 |
| api | app/db/migrations/versions/20261115_0021.py | 新建 | ~90 |
| api | app/services/user_module_access.py | 新建 | ~80 |
| api | app/services/user_provisioning.py | +created_by 落库/审计 | +8 |
| api | app/models/__init__.py | 用户 schema +created_by_name | +10 |
| api | app/routers/directory.py | 4 端点守门/过滤、组 schema/CRUD 授权同步、列表创建人 join | +130 |
| api | app/routers/auth.py | /me 两字段 | +25 |
| api | tests/test_user_delegation.py | 新建（见 §7） | ~400 |
| web | src/api/types.ts | Me/DirectoryUser/DirectoryGroup 增字段 | +12 |
| web | src/api/hooks.ts | 组 create/update body 透传（类型层） | +4 |
| web | src/components/AppHeader.tsx | 用户 chip 弱门 | +2 |
| web | src/components/MobileTabBar.tsx | 用户管理弱门 | +2 |
| web | src/pages/AdminUsersPage.tsx | 创建人列、非管理员隐藏编辑/停启用/解锁、建号组选项切换 | +45 |
| web | src/pages/AdminGroupsPage.tsx | 用户模块开关+目标组多选+徽标 | +75 |
| app | lib/models/me.dart | isUserManager/userCreateGroups+回落 | +12 |
| app | lib/models/admin_directory.dart | DirectoryUser/DirectoryGroup 增字段+payload | +18 |
| app | lib/core/api/directory_api.dart | 组 create/update 带 userCreateGroupIds | +8 |
| app | lib/features/admin/admin_tiles.dart | 用户 tile 弱门 | +3 |
| app | lib/features/admin/admin_home.dart | 用户磁贴+深链兜底弱门 | +4 |
| app | lib/features/admin/admin_users_page.dart | 创建人行、非管理员仅重置密码 | +25 |
| app | lib/features/admin/user_form_sheets.dart | 建号组选项=授权目标组（受限态禁远程搜索） | +20 |
| app | lib/features/admin/admin_user_row.dart | 创建人行+菜单按权限裁剪 | +18 |
| app | lib/features/admin/group_form_sheet.dart | 用户模块开关+目标组多选 | +55 |
| app | test/features/user_delegation_test.dart | 新建 | ~300 |

复用映射：建号表单/临时密码回显（Web TempPasswordModal / App temp_password_sheet）零改动复用；组多选用 antd Select mode=multiple + useDirectoryGroups（Web）/ GroupMultiSelect（App）；三态门/弱门照目录模板先例；App 表单照 FormSkeleton+AppTextField。单文件均远低于 500 行红线（directory.py 为存量超限文件，仅最小增量，不重构）。

## 7. 测试功能点

后端（容器内 pytest，新文件 tests/test_user_delegation.py）：
- T1 未授权用户对 list/create/detail/reset 全 403；T2 admin 全量可见+created_by_name 正确；T3 被授权者列表仅见自建；T4 建号授权组内成功+created_by 落库+临时密码可登录且 must_change_password；T5 建号含非授权组 422 invalid_group_ids；T6 建号空组 201；T7 重置自建 200+旧密码失效；T8 重置他人 403；T9 PATCH/停用/启用/解锁/他人详情 403；T10 组 PATCH 设/换/清授权 + 出参回显 ids+names；T11 组 DELETE 级联（F13）；T12 /me 三态（admin true+[]、被授权 true+组、撤销后 false）；T13 撤销后原自建用户不可见（F11）；T14 目标组不存在/超 50 422；T15 审计 details（user_created.created_by / group_updated diff）。
- 回归：test_directory.py / test_directory_users_ext.py / test_auth_me_stats_flags.py 现有用例全绿。

App（flutter test，新文件 test/features/user_delegation_test.dart）：
- A1 被授权非 admin：用户磁贴可见、用户组磁贴不可见；A2 用户行显示创建人+仅「重置密码」菜单项；A3 建号表单组选项=me.userCreateGroups 且提交体正确；A4 组表单开关+多选提交体（含 tri-state 不动）；A5 admin 行为不回归（全菜单+全量组选项）。

Web：pnpm lint + pnpm build 绿（无测试框架）。

## 8. 部署与验证（dev）

1. worktree 内 `bash scripts/deploy_lan.sh dev`（代码同步；tar 断流则切 scp 分片，见 ops-manual §6.6）。
2. `ssh hh2-swas` → dev 容器 `alembic upgrade head`（0021）→ restart ms-api ms-worker。
3. `pnpm build` 后 SPA 单独同步替换（deploy_lan 不同步 static/web）。
4. 容器跑 pytest（docker cp tests 先 rm 防嵌套）。
5. API E2E：建 A/B/C 组→授权 B→{A,C}→建 B 用户→B 登录验证 F5-F11 全链。
6. Web UI：浏览器过 dev 入口验证菜单门/创建人列/受限建号/组配置。
7. App：analyze+test 绿 → 裸构建测试 APK（`flutter build apk --release --dart-define=MS_API_BASE=<dev入口>`，勿走 release.mjs）→ adb connect mumu（127.0.0.1:16384 或 7555）→ 安装 → 真机交互验证（登录 B 用户走全流程）。

## 9. 模糊点与决策记录

| # | 模糊点 | 决策（2026-11-15，两问用户未作答按推荐默认） | 理由 |
|---|---|---|---|
| D1 | 授权是否需要独立 bool 开关 | **不设**；授权态=目标组集合非空；开关 UI=集合非空 | 少一处状态一致性维护；空目标授权无意义，表单强制≥1 |
| D2 | 授权数据放 FGA 还是 DB | **DB 表 user_create_grants** | 组对组关系数据，org-level FGA relation 表达不了；免推模型/部署顺序风险；与 created_by 同迁移事务；判定只需一次 SQL join |
| D3 | 非管理员建号可不选组 | **可**（与管理员一致，group_ids 允许空） | 行为一致性 |
| D4 | 非管理员操作范围 | **最小集**：查看自建+新建+重置密码；编辑/停启用/解锁仍管理员 | 忠实需求原文；后续要放宽是纯增量 |
| D5 | 目标组可否含授权组自身 | **可**（不限制，管理员自行决定） | 无危害；例中未用到不等于禁止 |
| D6 | 撤销授权后既有自建用户 | 归属不变、创建者即时失去可见/操作权 | 授权是能力不是所有权转移 |
| D7 | 存量创建人回填 | 从 audit user_created 最新 actor 回填，无来源显示「—」 | 唯一可靠来源 |
| D8 | 用户组模块是否同步开放 | **不**，组配置（含本授权配置）仍仅管理员 | 需求只提用户模块；授权配置是管理员动作 |
| D9 | App admin 其他磁贴 | 仅「用户」磁贴弱门放行，其余不动 | 同 D8 |

## 10. 不涉及

- FGA model（store.fga.yaml）零改动；不新增审计 event_type（复用 user_created/group_updated/user_password_reset，labels.ts 无新 key）；iOS 端逻辑与 Android 同包，本周期只验 Android 测试包；prod 部署不在本周期（dev 验收后等指令）。
