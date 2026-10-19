# 测试用例:目录树拖拽图标移除 + 批量移动弹窗「幽灵成功」修复

> qdev 测试角色 · 用例先行(2026-10-19)。需求依据:`docs/qdev/2026-10-19-drag-icon-move-fix.md`
> (F1-F4 / T1-T2)。被测分支 `feat/drag-icon-move-fix`(worktree 本仓库),基线 cc4aee3;
> dev 改动当前为工作区未提交状态(`git status` 仅 3 个 web 文件 M)。
> web 层无单测基建:本文件 A 节 = 可直接复制执行的静态检查命令;B 节 = GUI 手工用例
> (浏览器 DevTools / 真机,归测试执行角色与 tester)。所有命令在 worktree 根目录 Git Bash 执行。

## 通用前置(B 节共用)

- 夹具项目 P,目录结构(均由有权限账号预先建好):
  - `A`(普通根夹,内含文件 f1、f2、f3),子夹 `A1`(普通,空);
  - `C`(普通根夹,空);`T`(普通根夹,空);
  - `S`(sensitive 根夹,内含子夹 `S1`);
  - `L…`(名称足够长的普通根夹,验证省略号)。
- 账号:u1 = 项目 uploader(可进 A/C/T 上传与批量操作);sensitive 相关步骤需
  项目 admin(或被邀请可见 sensitive 的成员)执行。
- 视口:B1/B2/B3/B4/B6/B7/B8 默认 PC(≥1024px);B5 为 compact(<1024px,DevTools
  设备工具栏或真机)。
- 基线对照(可选但推荐):改动前构建的旧版本截图一张(含 ⠿ 把手与幽灵弹窗现象),
  供 B1/B4 直观比对。

---

## A. 静态检查项(可执行命令 + 预期)

| # | 检查项 | 命令(Git Bash,worktree 根执行) | 预期 |
|---|---|---|---|
| A1 | 越界检查(T1) | `git status --short && git diff --name-only cc4aee3 -- material-storage` | 代码改动仅 3 文件:`web/src/components/FolderTree.tsx`、`web/src/components/BatchMoveAssetsModal.tsx`、`web/src/pages/ProjectDetailPage.tsx`;`api/`、迁移、FGA 雵触碰(`git diff --name-only cc4aee3 -- material-storage/api` 输出为空) |
| A2 | lint | `cd material-storage/web && pnpm lint` | 退出码 0,零 error(含 react-hooks 规则;useMemo 依赖已补 selfDisabledSet) |
| A3 | build(T1,含 tsc) | `cd material-storage/web && pnpm build` | `tsc -b` 零错误;vite 产物输出 `../api/app/static/web/`(日志可见该路径,不跑偏到 `dist/`);`ls -la ../api/app/static/web/index.html` mtime 更新 |
| A4 | F1:draggable 三元 | `grep -n "draggable={" material-storage/web/src/components/FolderTree.tsx` 且 `grep -n "enableDrag ?? false" material-storage/web/src/components/FolderTree.tsx; echo "exit=$?"` | 前者仅 1 行命中:`draggable={enableDrag ? { icon: false } : false}`;后者无命中(exit=1) |
| A5 | F1:icon:false 附注释 | `grep -n "隐藏把手" material-storage/web/src/components/FolderTree.tsx` | 命中 draggable 行上方注释,含「拖拽能力挂在节点内容 wrapper 上……抓节点标题即可拖」语义 |
| A6 | F1:零 CSS 残留 | `grep -rn "ant-tree-draggable-icon" material-storage/web/src` | 无任何命中(不新增 CSS 抑制,整段把手 span 不渲染) |
| A7 | F4:disabledSelfIds prop 及语义注释 | `grep -n -B3 "disabledSelfIds?: string\[\]" material-storage/web/src/components/FolderTree.tsx` | Props 新增该可选 prop;其 JSDoc 写明「仅命中节点**自身**禁选,**不级联子树**」与「不得改用 disabledIds 误伤子夹」的语义区别 |
| A8 | F4:buildTree 级联/自身拆分(核心) | `grep -n "selfDisabledSet\|const disabled = ancestorDisabled\|const sub = build(f.id" material-storage/web/src/components/FolderTree.tsx` | ① buildTree 新增第三参 `selfDisabledSet`;② 节点 disabled = `ancestorDisabled \|\| disabledSet.has(f.id) \|\| selfDisabledSet.has(f.id)`;③ **递归级联行 `const sub = build(f.id, ancestorDisabled \|\| disabledSet.has(f.id))` 不含 selfDisabledSet**(红线:selfDisabledSet 不进级联源);④ useMemo 依赖数组含 `selfDisabledSet` |
| A9 | F4:弹窗接线 | `grep -n "sourceFolderId\|disabledSelfIds={" material-storage/web/src/components/BatchMoveAssetsModal.tsx` | Props 新增 `sourceFolderId?: string \| null`(JSDoc 注明 null/缺省 = 无禁选);FolderTree 上有 `disabledSelfIds={sourceFolderId ? [sourceFolderId] : undefined}`(null 安全) |
| A10 | F4:红线——源夹未塞进 disabledIds | `grep -n "disabledIds=" material-storage/web/src/components/BatchMoveAssetsModal.tsx` 且 `grep -n "disabledIds={[^}]*sourceFolderId" material-storage/web/src/components/BatchMoveAssetsModal.tsx; echo "exit=$?"` | 前者仅 1 处:`disabledIds={sensitiveIds}`(原语义零变化);后者无命中(sourceFolderId 未混入整子树级联入参) |
| A11 | F2:条件挂载 | `grep -n -A3 "batchMoveOpen && (" material-storage/web/src/pages/ProjectDetailPage.tsx` 且 `grep -n "open={batchMoveOpen}" material-storage/web/src/pages/ProjectDetailPage.tsx; echo "exit=$?"` | 前者命中 `{batchMoveOpen && (<BatchMoveAssetsModal open …)}`,且该 JSX 含 `sourceFolderId={activeFolderId}`;后者无命中(常挂载写法已移除);onClose/onMoved 回调语义不变 |
| A12 | F2:destroyOnHidden 保留 | `grep -n "destroyOnHidden" material-storage/web/src/components/BatchMoveAssetsModal.tsx` | 仍 1 处命中(防御未来改回常挂载,不删) |
| A13 | F3:结果 Alert 三态 | `grep -n -A6 "<Alert" material-storage/web/src/components/BatchMoveAssetsModal.tsx` | ① `type={pendingCount > 0 \|\| result.moved_count === 0 ? 'warning' : 'success'}`;② message 为二分支三元:`moved_count === 0` → `本次未移动任何文件(共提交 ${submitted} 个)`,否则原「成功移动 N 个文件(共提交 M 个)」;③ description 对账恒等式行未变(`成功 X + 跳过 Y[+ 待同步 Z] = M`) |
| A14 | 既有 disabledIds 使用点零变化 | `git diff cc4aee3 --stat -- material-storage/web/src/components/MoveFolderModal.tsx material-storage/web/src/components/BaiduNewTaskModal.tsx` | 两文件零 diff(F4 既有级联语义使用点不受影响) |

---

## B. GUI 用例(T2 八组,编号对应需求 T2.1-T2.8)

### B1【F1】PC 侧栏树无拖拽把手图标,目录名左移、长名省略号不回归(T2-1)

- 【前置条件】PC 视口 ≥1024px;u1 登录进入项目 P 详情页;夹具已建(含长名夹 L…);基线截图在手(可选)。
- 【步骤】
  1. 观察左侧目录树每一行:确认不再出现 ⠿(HolderOutlined)把手图标;
  2. DevTools Console 执行:`document.querySelectorAll('.ant-tree-draggable-icon').length`;
  3. 对比改动前基线截图:目录名起始位置是否左移(回收把手占宽);
  4. 观察长名夹 L…:名称超宽时是否仍以省略号截断,行高/缩进/sensitive 竖条与锁图标无错位;
  5. 展开含子夹的节点、hover 节点(出现 … 操作菜单按钮):布局无跳动。
- 【预期】步骤 2 结果为 `0`(零残留);目录名相对基线左移;长名省略号正常;无 CSS 错位。
- 【附注】本项仅 PC 分支:compact 分支 FolderTree 本就不传 `enableDrag`(移动端从未有把手),无需单独验图标。

### B2【F1】拖拽换父完整保留:抓标题拖动 + allowDrop 三句式 + 落点确认框(T2-2)

- 【前置条件】同 B1;需项目 admin(或可见 sensitive 的成员)以覆盖三句式;夹具 A/A1/C/S/S1 就位。
- 【步骤】
  1. 抓「A」的**标题文字**拖到「C」节点上松手 → 应弹确认框「将「A」移动到「C」?」(含权限/前缀提示文案,okText=「移动」)→ 点「取消」→ 树无变化;
  2. 抓「A1」拖到根层「C」与相邻节点之间的 **gap**(dropToGap)松手 → 弹确认框「将「A1」移动到「项目根」?」→ 取消;
  3. (三句式①)抓 sensitive 夹「S」的标题拖动 → 无法完成任何放置,松手无确认框;
  4. (三句式②)抓「C」拖到「S」上、再拖到「S1」上 → 均无可放置反馈,松手无确认框(sensitive 及其子树禁入);
  5. (防环)抓「A」拖到其子夹「A1」上 → 拒绝放置,无确认框;
  6. 正向收尾:抓「A1」拖到「C」上 → 确认框 → 点「移动」→ toast「文件夹「A1」已移动到「C」」,树刷新,A1 出现在 C 之下。
- 【预期】确认框仅在三句式放行时出现且文案不变;拖拽发起方式为抓标题(icon 隐藏不影响);成功后树刷新。

### B3【F2/F3/F4】批量移动完整流:选 2 文件 → 移动 → 结果计数 → 完成清选中(T2-3)

- 【前置条件】PC;u1(对 A 有 my_can_upload);A 内有 f1、f2;目标夹 T 为空。
- 【步骤】
  1. 进入 A,表格勾选 f1、f2 → 工具栏出现「移动 2」→ 点击;
  2. 弹窗标题应为「移动 2 个文件」;目标项目 Select 固定当前项目且禁切换;
  3. 目标树中点「T」→ 底部「已选目标:目录「T」」;同时观察「A」节点为置灰禁选(详见 B7);
  4. 点「移动」提交 → 切结果视图:Alert 为**绿色 success**,message「成功移动 2 个文件(共提交 2 个)」,对账行「成功 2 + 跳过 0 = 2」;
  5. 点「完成」→ 弹窗关闭;A 表格选中已清空且 f1/f2 消失;
  6. 切到 T:f1、f2 均在。
- 【预期】计数、对账恒等式、清选中、文件落位全部正确;全程无「批量移动结果」字样的残留视图。

### B4【F2】幽灵弹窗核心回归:同会话二次/三次打开必为干净选择视图(T2-4)

- 【前置条件】**紧跟 B3 之后、同一页面会话内(全程不刷新/不跳路由)**;A 内仍有 ≥1 个其他文件(如 f3);这是复现修复前幽灵态的必要前置——曾完成过一次成功移动(result 状态已产生)。
- 【步骤】
  1. 在 A 勾选 f3 → 点「移动 1」→ 观察弹窗**初始**视图;
  2. 检查:标题应为「移动 1 个文件」(而非「批量移动结果」);无上次成功 Alert;「已选目标:未选择」(无预选目标目录);
  3. 选 T2(或 T)提交成功 →「完成」;
  4. 再勾选任意文件打开弹窗后**直接点右上角 X(取消)**→ 观察表格勾选是否被清;
  5. 第三次打开 → 仍应为干净选择视图。
- 【预期】每次打开都是目标选择视图,结果只反映本次提交;步骤 4 取消后**勾选保留**(修复顺带消除的次生症状:基线幽灵态下因残留 result,X 会误走 onMoved 清空本次勾选);取消重开同样干净。
- 【基线对照】修复前:步骤 1 直接显示上一次「成功移动 2 个文件」结果弹窗,本次文件从未提交;步骤 4 勾选被误清。

### B5【F2/F3/F4】compact 布局(<1024px)同验完整流与幽灵回归(T2-5)

- 【前置条件】视口 <1024px(DevTools 设备工具栏或真机);u1;A 内有 ≥2 文件;目标 T。
- 【步骤】
  1. 左滑打开树 Drawer 选 A → 卡片列表多选 2 个文件 → 底部批量栏点「移动」;
  2. 按 B3 步骤 2-6 走完整流(选 T → 提交 → 绿色结果 → 完成 → 选中清空 → 文件落位 T);
  3. 完成后再次多选其他文件 → 再开移动弹窗 → 按 B4 步骤 1-2 验证无残留;
  4. 按 B6 语义在 compact 下复验「选择态取消 / 结果态完成」各一次。
- 【预期】compact 与 PC 共用 modals 单实例,弹窗行为两分支同愈;入口门控一致(源夹 sensitive 需 admin,按钮禁用态文案同 PC);移动端树无拖拽(F1 不涉及)。

### B6【F2】取消/完成语义不回归:选择态取消保留选中,结果态关闭清选中(T2-6)

- 【前置条件】PC;A 内有 ≥2 文件(f1、f2);目标 T 为空。
- 【步骤】
  1. 勾选 f1 → 打开移动弹窗 → 不选目标,直接点 X(取消)→ 弹窗关;检查表格:勾选仍在;
  2. 保持勾选再次打开 → 标题仍为「移动 1 个文件」、无预选目标;
  3. 勾选 f2 → 选 T → 提交 → 结果视图出现后点 X(onCancel)→ 弹窗关;检查表格:f2 的勾选已清;
  4. 重勾选任一文件 → 选 T 提交 → 结果视图点「完成」→ 同样清选中。
- 【预期】选择态取消 = onClose(保留选中,可重开);结果态 X 与「完成」等价,均走 onMoved(关闭并清空已移动/跳过选中)。

### B7【F4】P2-2 防级联误伤红线:源夹自身置灰,子夹仍可选;既有 disabledIds 零变化(T2-7)

- 【前置条件】PC;u1 在 A 内;夹具含 A 的子夹 A1、根夹 T、sensitive S/S1(u1 对 S 不可见时本条敏感部分换 admin 执行)。
- 【步骤】
  1. A 内勾选 f1 → 打开移动弹窗 → 观察目标树:「A」节点**置灰 disabled**,点击无响应、不高亮,「已选目标」保持「未选择」,「移动」按钮保持禁用;
  2. 点「A1」(A 的子夹)→ **可正常选中高亮**,已选目标显示「目录「A1」」→ 提交 → 成功,f1 出现在 A1(红线:允许 A 夹文件移入 A/B 子夹);
  3. 重开弹窗验证:「A」仍置灰而「A1」及无关节点可选(源夹禁选不随 target 变化);
  4. 观察「S」及其子树(可见者执行):仍整子树置灰禁选(sensitive 级联语义零变化),点 S1 不可选;
  5. 既有使用点抽测(级联语义回归):① 目录树节点菜单「移动到」(MoveFolderModal)打开,sensitive 及其子树禁选照旧;② 百度备份新建任务选目标(BaiduNewTaskModal)同样照旧。
- 【预期】仅源夹自身被禁(A10 静态断言的同义真机验证);A→A1 移动全流程可用(红线);sensitive 整子树禁选与既有 disabledIds 使用点行为零变化。
- 【附注】若源夹本身为 sensitive(admin 合法源):目标树中其置灰为两集合命中叠加(sensitiveIds ∪ 源夹自身),属预期,不另设失败分支。

### B8【F3】P2-1 结果三态:全 skip 黄色 warning / moved>0 绿色 / fga_pending warning 不回归(T2-8)

- 【前置条件】PC;u1。为构造全 skip,预置:**T 内已存在与 A 中 f1、f2 同名的文件**(同名冲突 → duplicate_filename「目标已有同名文件」)。注意:修复后源夹自身在目标树禁选(B7),「同夹自移」(duplicate_location)路径在 GUI 已不可构造,造数一律走同名冲突。
- 【步骤】
  1. (全 skip)A 内勾选 f1、f2(T 已有同名)→ 移动 → 选 T → 提交 → 观察结果 Alert 颜色与文案、skipped 明细;
  2. (moved>0)A 内勾选 f3 与一个 T 中无同名的文件(共 2 个,其中 0 个冲突则为全成功绿色,亦可混入 1 个同名造成部分成功)→ 移动 → 选 T → 提交;
  3. (fga_pending>0)真机难以稳定注入权限同步失败——**条件用例**:若可由后端配合注入(临时使 FGA 同步失败)则执行:moved>0 且 pending>0 → Alert 应为 warning 且 message 仍为「成功移动 N 个文件(共提交 M 个)」+「权限同步待完成」区块渲染、对账行含「+ 待同步 Z」;若无法注入,降级为对照静态项 A13 的代码走查并在执行记录中注明。
- 【预期】
  - 步骤 1:Alert **黄色 warning**,message「本次未移动任何文件(共提交 2 个)」,对账行「成功 0 + 跳过 2 = 2」,skipped 列表逐条中文原因;
  - 步骤 2:`moved_count > 0` 时 Alert 仍**绿色 success**,message「成功移动 N 个文件(共提交 M 个)」不变;
  - 步骤 3:pending>0 → warning 且「权限同步待完成」文案与 shortId 列表不回归(既有语义)。

---

## 用例统计(按功能点)

| 功能点 | 静态检查项 | GUI 用例组 |
|---|---|---|
| F1 图标隐藏保拖拽 | A4、A5、A6 | B1、B2 |
| F2 幽灵弹窗修复(条件挂载) | A11、A12 | B3(主干)、B4、B5、B6 |
| F3 全 skip 降级 warning | A13 | B8(B3 兼验 moved>0 绿色) |
| F4 禁选源夹自身(不级联) | A7、A8、A9、A10、A14、A1(越界)、A2/A3(构建) | B7(B3/B5 兼验选目标) |
| **合计** | 静态 14 项 | GUI 8 组(对应 T2.1-T2.8) |

## 读代码时发现(供 PM 注意,非阻塞)

1. **命名与需求文档的差异**:需求「前端改动点」写 `selfSet`,实现命名为 `selfDisabledSet`;语义一致(buildTree 拆「级联源」与「节点自身 disabled」,递归子级联第二参不含 selfDisabledSet)。静态断言 A8 已按实现名书写。
2. **幽灵态的次生症状(修复顺带消除,建议记入验收叙事)**:基线 `close()` 以 `result` 是否为 null 路由 onClose/onMoved,幽灵态残留 result 时点 X 会走 onMoved **误清本次勾选**——即幽灵弹窗不止是"看到假结果",还会丢勾选。B4 步骤 4 已加此断言。
3. **注释先于事实**:基线 `BatchMoveAssetsModal` 内 state 注释早已写「组件由调用方条件挂载,重开自动复位」,但调用方实为常挂载(脱节正是幽灵根因);本次修复后注释成真,dev 未改该注释,现在语义自洽。
4. **P2-1 与 P2-2 的联动效应**:源夹自身禁选后,「同夹自移」(duplicate_location 已在目标位置)在 GUI 不可再构造,全 skip 只能靠同名冲突(duplicate_filename)造数——B8 前置已按此设计;若 PM 此前依赖同夹自移造数需改口径。
5. **fga_pending 真机不可稳定注入**,B8 步骤 3 为条件用例,静态 A13 已覆盖三态代码事实,建议执行记录允许"代码走查兜底"。
6. `sourceFolderId={activeFolderId}` 理论可为 null,但批量移动入口仅在存在文件夹与表格的页面可达;接线处 `sourceFolderId ? [sourceFolderId] : undefined` 已含 null 防御(A9),无额外风险。
