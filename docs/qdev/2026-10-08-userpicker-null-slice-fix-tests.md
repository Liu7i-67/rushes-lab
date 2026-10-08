# 测试用例:UserPicker 本地账号双 null 崩溃(open_id.slice)修复

- 日期:2026-10-08
- 需求依据:[2026-10-08-userpicker-null-slice-fix.md](./2026-10-08-userpicker-null-slice-fix.md)(以其第 1 节根因链路、第 6 节 T1-T6 为唯一依据)
- 分支/工作区:`fix/userpicker-null-slice`(worktree `E:\qbb\github_not_me\rushes-lab-fix-userpicker-null-slice`)
- 说明:前端无测试框架,本文档全部为**人工执行用例**,不含可执行代码。步骤中「控制台」指浏览器 DevTools Console——本 bug 的失败形态是 `TypeError: Cannot read properties of null (reading 'slice')`,复验时以「Console 无 TypeError + 页面不白屏/不弹错误」为硬性观测点。

---

## 1. 结构化用例清单(17 条)

> 用例编号 TC-xx;「双 null 账号」构造方法见第 3 节。各用例的账号前置均在第 3 节字段级要求之上。

### T1 新场景(修复目标)

**TC-01|双 null 账号打开新建项目弹窗不崩,默认管理员=自己,小字显示「本地账号」**
- 对应功能点:T1
- 优先级:P0
- 前置条件:账号 liuqi 满足 `users.username IS NULL AND users.feishu_open_id IS NULL`(`feishu_union_id` 建议同为 NULL,复刻 prod);`is_active=true`;已设本地密码且知道密码(`must_change_password=false`);name 全表唯一;已加入开启「允许组成员新建项目」的用户组(`/me.is_project_creator=true`)。
- 操作步骤:
  1. 以 liuqi 本地账号密码登录;
  2. 打开 DevTools Console 清空;
  3. 首页点击「新建项目」打开弹窗;
  4. 观察「项目管理员」下拉框选中项(NewProjectModal.tsx:242 向 UserPicker 注入 preset `{username: null, open_id: null}` 的单选选中项渲染路径,即原崩溃点);
  5. 观察弹窗其余区域(基础字段、权限区)渲染。
- 预期结果:
  1. 弹窗正常打开,Console 无任何 TypeError;
  2. 「项目管理员」默认选中「liuqi(自己)」;
  3. 选中项小字行显示「本地账号」(不显示 email 后缀——前置里 email 为 NULL 时);
  4. 下方显示「你本人将作为项目管理员」提示条。

**TC-02|双 null 账号在「项目管理员」切换人选再切回自己,选中项重渲染不崩**
- 对应功能点:T1(覆盖单选选中项 label 的二次渲染路径,与首次 preset 渲染不同代码路径)
- 优先级:P1
- 前置条件:同 TC-01;列表中另有一名有 username 或有 open_id 的普通账号 B。
- 操作步骤:
  1. 同 TC-01 打开弹窗;
  2. 在「项目管理员」搜索并改选账号 B;
  3. 再清空搜索、重新选中「liuqi(自己)」(preset 项);
  4. 观察 Console 与选中项小字。
- 预期结果:全程无 TypeError;选中 B 时小字按 T3 规则显示(B 的 username 或 open_id 前 18 位);切回自己时小字恢复「本地账号」。

### T2 列表含双 null 用户

**TC-03|下拉 prefetch 列表含双 null 用户,展开渲染不崩,该行小字显示「本地账号」**
- 对应功能点:T2
- 优先级:P0
- 前置条件:同 TC-01(liuqi 本身在 `GET /api/v1/users` 全量列表中);另构造第二个双 null 账号 liuqi2(或直接用 liuqi 以有 open_id 的账号操作,使「自己」不在 preset、双 null 用户只出现在列表里——两选一,推荐后者以隔离 preset 因素)。
- 操作步骤:
  1. 以有 open_id 的管理员账号登录(其本人非双 null);
  2. 打开「新建项目」弹窗;
  3. 点击「项目管理员」下拉框展开(prefetch `GET /api/v1/users?limit=20` 列表);
  4. 逐行观察含双 null 用户(liuqi / liuqi2)的行。
- 预期结果:下拉正常展开,无 TypeError;双 null 用户行:头像首字 = name 首字、主行 = name、小字 = 「本地账号」;其他行显示不受影响。

**TC-04|搜索命中双 null 用户(q 过滤列表)渲染不崩**
- 对应功能点:T2(query 非空时 preset 不注入,列表为纯后端命中结果)
- 优先级:P1
- 前置条件:同 TC-03。
- 操作步骤:
  1. 同 TC-03 展开下拉;
  2. 在搜索框输入 `liuqi`(或双 null 账号的 name / email 关键字);
  3. 观察过滤后的结果列表。
- 预期结果:无 TypeError;命中的双 null 用户行小字显示「本地账号」;若输入无匹配关键字显示「无匹配」而非崩溃。

### T3 回归-显示优先级(与修复前一致)

**TC-05|username 非空 → 小字显示 username**
- 对应功能点:T3
- 优先级:P1
- 前置条件:账号 C 满足 `username` 非空(如管理后台建的账号;可同时有 open_id 或没有,均不影响)。
- 操作步骤:在任一 UserPicker 下拉(推荐「项目管理员」)展开并找到账号 C 的行。
- 预期结果:小字 = username 原文 + ` · email`(有 email 时),与修复前显示逐字一致。

**TC-06|username 为空但 open_id 非空 → 小字显示 open_id 前 18 位**
- 对应功能点:T3
- 优先级:P1
- 前置条件:账号 D 满足 `username IS NULL` 且 `feishu_open_id` 非空(存量飞书老账号,或 DB 手工构造)。
- 操作步骤:在任一 UserPicker 下拉展开并找到账号 D 的行。
- 预期结果:小字 = open_id 的前 18 个字符(截断,无省略号追加),与修复前一致(`user.username || user.open_id?.slice(0, 18)` 短路次序未变)。

**TC-07|email 显示后缀回归**
- 对应功能点:T3(细化:三元守卫分支)
- 优先级:P1
- 前置条件:TC-05 的账号 C(有 email)与某 email 为 NULL 的账号。
- 操作步骤:分别观察两账号在 UserPicker 行的小字。
- 预期结果:有 email → ` · email` 后缀存在;email 为 NULL → 小字以「本地账号」/username/open_id 前缀结尾,无悬挂 ` · ` 分隔符,无 `null`/`undefined` 字样。

### T4 回归-其余使用方冒烟(共 7 个使用方)

> UserPicker 直接/间接使用方全量:NewProjectModal(本需求主链路,见 T1/T5)、SubjectPicker、ProjectMembersDrawer、FolderInvitePanel、RequestLinkCreateModal、AdminGroupsPage、AdminAuditPage。以下冒烟均要求:页面/弹窗正常打开、下拉可展开、含双 null 用户行时渲染不崩、Console 无 TypeError。

**TC-08|SubjectPicker 用户分支(双 null me 注入 preset)**
- 对应功能点:T4(SubjectPicker.tsx:68-69 与 NewProjectModal 同样向 UserPicker 注入 `{username: null, open_id: me.open_id}` 的 preset)
- 优先级:P1
- 前置条件:双 null 账号 liuqi 可登录(同 TC-01)。
- 操作步骤:
  1. liuqi 登录,打开「新建项目」弹窗,定位右侧「权限(可选)」区;
  2. 在 SubjectPicker 切到「用户」tab,展开下拉;
  3. 任选一名用户,观察「已选 N 项」汇总 Tag。
- 预期结果:无 TypeError;preset 的「liuqi(自己)」行小字 =「本地账号」;选中行的汇总 Tag 正常显示 name(Tag 显示 name,id 短 id 仅在 name 缺失时兜底)。

**TC-09|SubjectPicker 用户组 tab + GroupPicker**
- 对应功能点:T4(SubjectPicker.tsx:185 `g.id.slice(0, 18)`)
- 优先级:P1
- 前置条件:任意可登录账号;系统内至少有 1 个用户组。
- 操作步骤:任一 SubjectPicker(新建项目弹窗或成员邀请弹窗)切「用户组」tab,展开下拉。
- 预期结果:无 TypeError;组行小字 = groups.id 前 18 位 + `…` + 成员数(groups.id 主键非空,恒安全)。

**TC-10|ProjectMembersDrawer 邀请弹窗**
- 对应功能点:T4
- 优先级:P1
- 前置条件:任一项目的 admin 账号;项目内含/可达用户列表含 1 个双 null 用户更佳。
- 操作步骤:打开项目成员抽屉 → 「邀请成员」→ SubjectPicker 展开用户 tab;勾选主体 + RoleChipGroup 勾角色后关闭(不要求提交)。
- 预期结果:无 TypeError;下拉行显示规则与 TC-03/05/06 一致;Tag 汇总正常。

**TC-11|FolderInvitePanel 邀请弹窗**
- 对应功能点:T4
- 优先级:P1
- 前置条件:可进入某 folder 的账号(invite 面板可见)。
- 操作步骤:进入 folder → 打开邀请面板(InviteModal)→ SubjectPicker 展开用户 tab。
- 预期结果:同 TC-10,无 TypeError。

**TC-12|RequestLinkCreateModal(无 preset 的单选 UserPicker)**
- 对应功能点:T4(RequestLinkCreateModal.tsx:130,单选、无 preset,双 null 用户只会出现在列表)
- 优先级:P1
- 前置条件:可创建请求链接的账号;用户列表含双 null 用户。
- 操作步骤:打开「请求链接创建」弹窗 → 展开「限定接收者」UserPicker 下拉。
- 预期结果:无 TypeError;双 null 用户行小字 =「本地账号」;选中该行后单选选中项渲染不崩。

**TC-13|AdminGroupsPage 添加成员 + AdminAuditPage 操作者筛选**
- 对应功能点:T4(两个页面级使用方合并冒烟)
- 优先级:P1
- 前置条件:系统 admin 账号(可进 /admin 页);用户列表含双 null 用户。
- 操作步骤:
  1. AdminGroupsPage:打开某用户组「成员」弹窗,展开添加成员 UserPicker 下拉;
  2. AdminAuditPage:展开「操作者」筛选 UserPicker 下拉。
- 预期结果:两处均无 TypeError;双 null 用户行小字 =「本地账号」;单选/多选选中渲染均正常。

### T5 回归-新建项目主流程

**TC-14|正常账号(有 open_id)新建项目全流程不变**
- 对应功能点:T5
- 优先级:P0
- 前置条件:有 open_id 且有新建权限的账号(如 dev 验收原账号);至少 1 个权限模板(可选含 1 个 `is_default=true` 的)。
- 操作步骤:
  1. 打开「新建项目」弹窗,确认「项目管理员」默认=自己、小字为其 open_id 前 18 位(修复前一致);
  2. 填项目名称/编码,选择一个模板(确认权限行预填、可增删改角色);
  3. 指派另一账号为项目管理员;
  4. 提交创建;
  5. 重新打开弹窗确认表单已重置(admin 恢复默认=自己)。
- 预期结果:全流程与修复前行为一致:模板预填正确、提交成功提示含项目名与授权条数、项目列表可见新项目、无 Console 报错。

**TC-15|双 null 账号(经组授权)完整创建项目**
- 对应功能点:T5(T1 的端到端延伸:原 bug 使该类账号完全无法使用组级「新建项目」功能)
- 优先级:P0
- 前置条件:同 TC-01(liuqi 有组级 project_creator 权限)。
- 操作步骤:
  1. liuqi 登录,打开「新建项目」弹窗(不崩,同 TC-01);
  2. 填名称/编码,手选一个主体授「查看」角色(或直接不选权限);
  3. 保持项目管理员=自己,提交。
- 预期结果:创建成功提示;新项目在项目列表可见且 liuqi 具备相应权限;「你本人将作为项目管理员」逻辑不受影响;无 Console 报错。

### T6 空值审计的可执行复核点(静态审计结论见第 2 节)

**TC-16|权限模板引用已删除主体:GrantRow 短 id 兜底 + 「已删除」徽标**
- 对应功能点:T6(NewProjectModal.tsx:87 `rowName` 三级兜底 `r.name ?? nameById.get(id) ?? shortId(id)`;GrantRowCard.tsx:339 `(name || '?').slice`)
- 优先级:P1
- 前置条件:系统 admin;存在一个 items 引用已删除/不存在主体的权限模板(或 DB 临时删一个被模板引用的用户)。
- 操作步骤:
  1. 系统 admin 打开「新建项目」弹窗;
  2. 选中该模板,观察预填的权限行;
  3. 展开模板 Select 观察其 option 副行(description)。
- 预期结果:主体名显示为 12 位短 id + `…`(nameById 未命中走 shortId),行内出现「已删除」琥珀色徽标;无 TypeError、无 `undefined` 字样;模板 option 的 description 为 NULL 时副行整体不渲染(不显示 `null`)。

**TC-17|「不使用模板」与默认模板并存时的空值路径**
- 对应功能点:T6(NewProjectModal.tsx:187 `{t.description && …}` 守卫、73 `defaultTemplate` 查找)
- 优先级:P2
- 前置条件:存在 `is_default=true` 且 `description IS NULL` 的模板。
- 操作步骤:打开「新建项目」弹窗,观察模板 Select 各 option 与底部默认模板 Alert;切回「不使用模板」清空权限行。
- 预期结果:description 为 NULL 的模板 option 无副行但主行正常;底部 Alert 正常显示模板名;切回「不使用模板」权限行清空,无报错。

---

## 2. T6 静态空值审计(已按当前工作区代码逐点核验)

> 审计对象:「新建项目弹窗渲染路径」上所有对后端可空字段的 `.slice` / 属性访问点。核验基线 = 当前工作区(修复已以未提交 diff 形式存在于 `UserPicker.tsx` 与 `api/types.ts`,与需求第 5 节改动点一致)。
>
> 后端可空性参照(均已在源码核实):
> - `api/app/routers/users.py:28-34` `UserBrief`:`username` / `open_id`(=`users.feishu_open_id`)/ `union_id` / `email` 均 `str | None`;`name` 必有(序列化自 `users.py:69-77`,`users.name` 列 `nullable=False`,tables.py:68)。
> - `api/app/routers/auth.py:158-166` `/me`:`open_id = user.feishu_open_id`(可空)、`union_id`(可空)、`email`(可空);`name` 必有。
> - 模板条目 `name`:后端 `subject_names.py:35-` `resolve_subject_names` 对未命中主体预填 `sid[:12]+"…"`(永不为 None),`admin.py:310` 原样取用。

| # | 位置 | 访问的可空字段 | 是否已有保护 | 结论 |
|---|---|---|---|---|
| A1 | UserPicker.tsx:148 小字行 | `username`(可空)、`open_id`(可空) | 本需求修复:`user.username \|\| user.open_id?.slice(0, 18) \|\| '本地账号'`(`?.` + 三级兜底);类型已改 `string \| null` | **安全(修复后)** —— 原 P0 崩溃点,dev 未复现原因即短路落到非空 open_id |
| A2 | UserPicker.tsx:137 / 118 头像首字 | `name`(后端非空;118 处对象本身可 undefined) | `(user.name \|\| '?').slice(0,1)`、`(u?.name …)` 有 `\|\|` 兜底与可选链 | 安全 |
| A3 | UserPicker.tsx:148 email 后缀 | `email`(可空) | 三元守卫 `user.email ? \` · ${email}\` : ''` | 安全 |
| A4 | NewProjectModal.tsx:242-243 preset 注入 | 注入字面量 `username: null` + `me.open_id`(可空,经 F2 类型修正后已显式可空) | 无本地解引用,值流向 A1 由其兜底;`me.union_id` / `me.email` 同为透传 | **安全(修复后)** —— 风险承接点,回归看 TC-01/TC-02。备注:preset 硬编码 `username: null`(因 `/me` 不返回 username,Me 类型无该字段),「(自己)」行即使本人有 username 也显示 open_id 前缀/「本地账号」——显示层既有行为、非崩溃点,不在本需求范围 |
| A5 | NewProjectModal.tsx:38 + 87 shortId/rowName | `GrantRow.name?`(可缺省)、`nameById.get()`(可能 undefined) | `??` 链兜底到 `shortId(r.id)`;`r.id` / 模板 `it.id` 为后端必填 UUID(GrantEntry.id 必填) | 安全 |
| A6 | NewProjectModal.tsx:40-48 templateRows + 171-195 templateOptions | `it.name`(后端必回非空,见 subject_names.py)、`t.description`(可空)、`t.name`(必填) | `it.name` 直接用(后端永不为 null);`{t.description && …}` 条件渲染 | 安全 |
| A7 | NewProjectModal.tsx:339 GrantRowCard 头像 | `name` prop(来自 rowName,恒为 string) | `(name \|\| '?').slice(0,1)` 仍有兜底 | 安全 |
| A8 | SubjectPicker.tsx:68-69 preset 注入 | `me.open_id` / `me.union_id`(可空) | 同 A4,值流向 A1 由其兜底 | **安全(修复后)** —— 回归看 TC-08 |
| A9 | SubjectPicker.tsx:101 已选 Tag | `s.name?`(可缺省)、`s.id` | `s.name \|\| s.id.slice(0, 12) + '…'`;`id` 由 UserPicker/GroupPicker 选中值构造,恒为非空 UUID | 安全 |
| A10 | SubjectPicker.tsx:185 GroupPicker 组行 | `g.id`(groups.id 主键,非空) | 无守卫但字段非空(后端 groups 表主键) | 安全 |
| A11 | ApplyDefaultModal.tsx:129 结果行名 | `r.project_id`(后端 apply-default 结果行必含)、`nameById.get()` 可能 undefined | `nameById.get(r.project_id) ?? r.project_id.slice(0, 12) + '…'` 兜底 | 安全(注:该弹窗不在新建项目渲染路径上,按需求点名纳入审计) |
| A12 | hooks.ts:100-106 useAllUsers | UserBrief 各可空字段 | 纯透传 `fetchAllPages`,无运行时字段变换;空值兜底全部下沉到消费侧(A1/A5) | 安全 |
| A13 | hooks.ts:626-631 useGrantTemplates、74-85 fetchAllPages | GrantTemplate.description 等 | 纯透传;403/失败由调用方降级(templates ?? []) | 安全 |
| A14 | RoleChipGroup.tsx(权限行角色 chips) | 无可空字段 `.slice` 访问点(grep 证实无 `.slice(`) | — | 安全 |

**审计结论摘要**:共核验 14 个点,14 安全、0 风险点。其中 A1 为本修复的直接目标;A4/A8 为修复的风险承接点(preset 注入路径),已由修复覆盖。新建项目弹窗渲染路径上未发现修复范围外的同类双 null 崩溃点。

### 范围外上报(不纳入本次修复,仅记录)

| 位置 | 现象 | 核验结果 | 风险评估 |
|---|---|---|---|
| AppHeader.tsx:353 `r.user_labels.slice(0, 2)`(全局搜索结果行) | 需求 §7 决策表点名的全仓治理示例 | 后端 `Asset.user_labels` 列为 `nullable=False, server_default='{}'`(tables.py:147-149),序列化恒为数组;前端类型 `string[]` 一致 | **低(实际安全)** —— 依赖「列非空」这一 DB 事实而非前端守卫,若未来该列改可空才会成风险;按需求决策留待后续全仓治理另立需求 |

(另核实一处相邻点:UserMenu.tsx 对 `me.open_id` 的复制/显示已有 `if (!me.open_id)` / `{me.open_id && …}` 守卫,安全,无需上报。)

---

## 3. 用例执行说明(第 4 步测试执行参考)

### 3.1 双 null 账号的构造(字段级要求)

**为什么不能走管理后台建号**:管理后台建用户 `POST /api/v1/admin/directory/users` 的 `username` 为必填(`directory.py:61` `Field(..., min_length=2)`),经 UI 建出的账号必有 username。**双 null 账号必须直接改库**(prod 的 liuqi 即此类存量)。

字段级要求(以 `users` 表为准,tables.py:57-81):

| 字段 | 要求 | 原因 |
|---|---|---|
| `username` | **必须 NULL** | 崩溃条件之一;也是 `UserBrief.username` 为 null 的唯一来源 |
| `feishu_open_id` | **必须 NULL** | 崩溃条件之二(`UserBrief.open_id` 取自该列,users.py:73) |
| `feishu_union_id` | 建议同步 NULL | 复刻 prod 本地账号形态;union_id 在前端仅透传无解引用 |
| `name` | 非空,且**全表唯一** | `nullable=False`;本地登录的 name 兜底匹配若命中多行会被歧义拒绝(local_auth.py:113-),登录名冲突会直接 401 |
| `email` | 建议设 NULL(至少一条用例如此) | 覆盖「无 ` · email` 后缀」分支;如设非空则登录可走 email 维度 |
| `is_active` | 必须 true | `GET /api/v1/users` 只回 active 用户(users.py:55),false 会导致 T2 列表场景看不到该账号 |
| `password_hash` | 已设且测试者知晓密码 | 本地账号密码登录(`POST /api/v1/auth/local/login`) |
| `must_change_password` | 设 false(或首次登录后按提示改密) | true 时登录后会被强制改密流程拦截,干扰用例 |

推荐构造步骤(dev/测试环境,容器名以 `api/docker-compose.yml` 为准:`ms-db` / 库 `material_storage` / 用户 `msuser`):

1. 先经管理后台正常建号(得到合法 password_hash),或复用 `scripts/dev_bootstrap.py` 的基础数据;
2. 改库抹掉飞书身份与登录名:
   ```bash
   docker compose exec ms-db psql -U msuser -d material_storage -c \
     "UPDATE users SET username = NULL, feishu_open_id = NULL, feishu_union_id = NULL, email = NULL, must_change_password = false WHERE name = 'liuqi';"
   ```
3. 授组级新建项目权限:系统 admin 在 AdminGroupsPage 把 liuqi 加入某用户组并开启该组「允许组成员新建项目」;以 liuqi 登录后可用 `/api/v1/auth/me` 响应校验 `is_project_creator: true`(false 则 T1 只会看到「暂无新建项目权限」Alert,属前置不满足而非 bug);
4. 登录方式:liuqi 双 null 后 `POST /api/v1/auth/local/login` 按 **username → email(含@)→ name** 优先级匹配(local_auth.py),只能以 **name(或 email,若保留)** 作为登录名。
5. 替代通道(仅 env=dev):`/ms-static/web/dev-login` 走 `X-User-Id` header 可免密模拟任意 user id,适合只验前端渲染;但与 prod 的本地登录链路不同,验收 T1 建议 §8 验收基准下仍走真实密码登录。

TC-06 需要的「username NULL 但 open_id 非空」账号 D 可用同样方式构造(只清 username、保留 feishu_open_id),或直接使用存量飞书老账号。

### 3.2 无浏览器自动化时的人工执行顺序

前置一次性准备:

1. `cd material-storage/web && pnpm install && pnpm build`(产物进 `api/app/static/web/`);或 `pnpm dev` + `docker compose up -d`(dev proxy 指向 8200,注意 5173 直连取不到 /api);
2. 按 §3.1 构造:双 null 账号 liuqi(+ 可选 liuqi2)、username-only 账号 C、open_id-only 账号 D、含 project_creator 权限的用户组、一个引用已删除主体的模板(TC-16 用);
3. 每个用例执行时开 DevTools Console 并保持可见——本 bug 的失败形态是 Console TypeError(页面可能白屏或错误边界),「页面看着正常」不构成通过依据。

推荐执行顺序(账号切换次数最少):

| 轮次 | 账号 | 用例 |
|---|---|---|
| 1 | liuqi(双 null) | TC-01 → TC-02 → TC-08 → TC-09 → TC-15 |
| 2 | 有 open_id 管理员 | TC-03 → TC-04 → TC-14 → TC-16 → TC-17 |
| 3 | 有 open_id 项目 admin | TC-10 → TC-11 |
| 4 | 可建请求链接账号 | TC-12 |
| 5 | 系统 admin | TC-13 |
| 6(穿插) | 任意 | TC-05 / TC-06 / TC-07(在任何展开的 UserPicker 下拉里观察 C、D 两行即可) |

复验轮(按需求 §8):重点复跑 **TC-01、TC-03**;若 T4 冒烟有失败,修复后加跑对应条目。

通过标准汇总:① 全部用例 Console 零 TypeError;② TC-01/03/15 确认「本地账号」文案;③ TC-05/06/07 显示与修复前逐字一致;④ `web` 构建 + tsc 通过(由开发/复验侧执行,用例不覆盖构建命令本身)。
