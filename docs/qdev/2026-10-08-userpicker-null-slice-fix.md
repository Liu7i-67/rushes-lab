# 需求文档:UserPicker 本地账号双 null 崩溃(open_id.slice)修复

- 日期:2026-10-08
- 来源:生产环境(hh2 prod)bug 报告 —— 「管理员」用户组开启组级「新建项目」权限后,组内本地账号 liuqi 点击「新建项目」报错 `TypeError: Cannot read properties of null (reading 'slice')`
- 分支/工作区:`fix/userpicker-null-slice`(worktree `E:\qbb\github_not_me\rushes-lab-fix-userpicker-null-slice`,基于 `liuqi` @ dab817d)

## 1. 背景与根因

65a264f 合并的「组级新建项目权限(project_creator)」上线后,prod 给「管理员」用户组开启该权限,组内**本地账号**(无飞书身份:`username=None` 且 `feishu_open_id=None`)liuqi 打开新建项目弹窗即崩。

崩溃链路(已核实到代码行):

1. `NewProjectModal.tsx:242` 打开弹窗时「项目管理员」默认值 = 自己,并向 UserPicker 注入 preset `{ id: me.id, username: null, open_id: me.open_id, ... }`;
2. antd Select 单选模式渲染选中项的 option label → `UserPicker.tsx` `UserRow`;
3. `UserPicker.tsx:148` 小字行 `{user.username || user.open_id.slice(0, 18)}` —— username 为 null 时求值 `open_id.slice(0,18)`,本地账号 open_id 亦为 null → **TypeError: Cannot read properties of null (reading 'slice')**;
4. 即便不 preset,展开下拉 prefetch `GET /api/v1/users` 返回的用户列表中任何「username 与 open_id 双 null」的本地账号(liuqi 本人即在列表中)同样触发。

后端事实(佐证,不改):`api/app/routers/users.py:28-34` `UserBrief.username: str | None`、`open_id: str | None = None  # 飞书遗留,本地新用户为 None`。

dev 未复现原因:hh2 dev 验收账号 open_id 非空,`username || open_id.slice(...)` 短路后仍落到有值的 open_id。

影响面:`UserPicker` 共 8 处使用(NewProjectModal / SubjectPicker / ProjectMembersDrawer / FolderInvitePanel / RequestLinkCreateModal / AdminGroupsPage / AdminAuditPage 等),凡渲染到双 null 用户行均可能崩;本 bug 报告链路为新建项目弹窗。

## 2. 功能点明细(逐条可验收)

1. **F1 空值保护**:`UserPicker.tsx` UserRow 小字行在 `username`、`open_id` 双双为 null 时不抛异常,显示兜底文案「本地账号」;优先级:username > open_id 前 18 位(现状保留)> 「本地账号」。
2. **F2 类型修正**:`UserPicker.tsx` 内 `UserBrief` 接口 `open_id: string` 改为 `string | null`(与后端真实返回一致);`web/src/api/types.ts` 中 `Me.open_id: string` 同步改为 `string | null`(auth.py:160 返回 `user.feishu_open_id` 可空)。
3. **F3 不引入行为变化**:有 username / 有 open_id 的账号显示逻辑与修复前完全一致(回归项)。

## 3. 数据库修改方案

不涉及。

## 4. 接口定义

不涉及(纯前端修复;后端 `UserBrief` 字段可空性为既有事实,本需求不改后端)。

## 5. 前端改动点 / 后端改动点

- 前端(全部改动):
  - `material-storage/web/src/components/UserPicker.tsx`:148 行小字行加空值保护(F1);接口 `open_id` 类型修正(F2)。
  - `material-storage/web/src/api/types.ts`:`Me.open_id` 类型修正(F2),仅类型标注,无运行时影响。
- 后端:不涉及。

## 6. 测试功能点

1. **T1 新场景(修复目标)**:构造 me 为 `username=null, open_id=null` 的本地账号,打开新建项目弹窗:不抛 TypeError;「项目管理员」默认选中自己;小字显示「本地账号」。
2. **T2 列表含双 null 用户**:UserPicker 下拉(含 prefetch 列表)中存在双 null 用户,渲染不崩,该用户行小字显示「本地账号」。
3. **T3 回归-显示优先级**:username 非空 → 显示 username;username 空但 open_id 非空 → 显示 open_id 前 18 位;与修复前一致。
4. **T4 回归-其余使用方**:SubjectPicker 的用户分支、ProjectMembersDrawer、FolderInvitePanel、AdminGroupsPage、AdminAuditPage 等使用 UserPicker 的页面正常渲染(类型检查 + 构建 + 关键页面冒烟)。
5. **T5 回归-新建项目主流程**:正常账号(有 open_id)打开弹窗、选模板、指派 admin、提交创建,行为不变。
6. **T6 全链路空值审计**:新建项目弹窗渲染路径上其余对可空字段(`.slice`/属性访问)的点(SubjectPicker、GrantRowCard、ApplyDefaultModal 相关 name/description 等)确认有保护,无同类双 null 崩溃点;发现问题按 P 级上报。

## 7. 模糊点与决策记录

| 模糊点 | 选项 | 决策(自行拍板)与理由 |
|---|---|---|
| 双 null 时小字兜底显示什么 | a)「本地账号」文案 b) id 前 18 位(UUID) c) 留空 | **a「本地账号」**:与后端注释「本地新用户」语义一致,对用户可读;id 前缀对运营人员无意义;留空会出现视觉空行。name 上一行已展示,不丢识别信息。 |
| 是否顺带修 `Me.open_id` 类型标注 | 只修 UserPicker / 连 types.ts 一起修 | **一起修**:同一根因(后端可空、前端标注过严),纯类型层零运行时风险,防止未来再次误导开发。 |
| 是否全量防御前端所有 `.slice` 空值(如 AppHeader user_labels) | 只修本链路 / 全仓治理 | **只修本链路 + T6 审计上报**:本需求是阻断 bug 的最小修复,全仓治理范围失控;T6 由测试角色审出问题单列 P 级,后续另立需求。 |

(本次为生产阻断 bug 修复,模糊点均为微小实现细节,按自主模式拍板;如对「本地账号」文案有异议,改动成本一个词。)

## 8. 验收基准

- `git diff` 仅含第 5 节两文件;
- `web` 构建 + 类型检查(tsc)通过;
- T1-T6 由测试角色执行并在复验轮复跑 T1/T2。
