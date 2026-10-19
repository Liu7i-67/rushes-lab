# 目录树拖拽图标移除 + 批量移动弹窗「幽灵成功」修复方案

> 2026-10-19 调研定稿。**调研全程未动代码,实施等用户明确指令。**
> 两个独立小改,均纯前端:①PC 侧栏目录树每行拖拽把手图标占宽移除(拖拽功能保留);
> ②W6 批量移动弹窗重开时直接显示上一次成功结果的「幽灵成功弹窗」bug(组件状态残留)。
> 背景:六项优化(2899dcd,2026-10-17 合并 liuqi)交付的 W4/W5 拖拽与 W6 批量移动上线后用户反馈。

---

## 0. 结论摘要

| 维度 | 结论 |
|---|---|
| 成本 | **极低**:前端 **2 文件 ~5 行改动**,0.5 人时含自验 |
| DB 迁移 / FGA / 依赖 | **全无**(纯 web 层,后端零触碰) |
| 部署 | 仅 SPA 替换(`pnpm build` → 分片同步,照既有 deploy_lan 通道);api 不动 |
| 回滚 | SPA 换回备份目录即可,无数据面影响 |
| 风险 | 低;①为组件库声明式配置,②与姊妹弹窗(Rename/MoveFolderModal)既有模式对齐 |

改动两处:①`FolderTree.tsx` 一行——`draggable` 由布尔改 `{ icon: false }` 配置,
拖拽把手图标不再渲染;②`ProjectDetailPage.tsx` 的 `BatchMoveAssetsModal` 由常挂载改
条件挂载——重开即全新实例,`result`/`target` 状态自动复位。

---

## 1. 问题一:移除目录前的拖拽图标

### 1.1 现状与证据

- PC 三栏布局左栏目录树(`<FolderTree>`,`ProjectDetailPage.tsx:994`)独传 `enableDrag`,
  移动端 Drawer 树与各 selectMode 树(批量移动弹窗/备份目标选择)均不传——图标只在 PC 侧栏出现。
- `FolderTree.tsx:349`:`draggable={enableDrag ?? false}`——布尔 `true`。
- antd 6.4.2 的 Tree 对布尔 draggable 注入默认把手图标 `HolderOutlined`(⠿),渲染在
  每行节点最左、indent 之后——即用户看到的「目录前的拖拽图标」,固定占一列宽,挤压目录名展示空间。

### 1.2 根因与修法

antd 的 `draggable` prop 接受 `boolean | DraggableConfig`,其中 `icon` 字段可传 `false`
显式关闭把手。两级源码已核验(antd 6.4.2 + @rc-component/tree 1.3.1):

- antd `es/tree/Tree.js`:对象形态原样透传,`mergedDraggable.icon !== false` 时才注入
  默认 `HolderOutlined`;
- rc-tree `es/TreeNode.js`:`if (!context.draggable?.icon) return null`——`icon` 为
  falsy(含显式 `false`)时**整段 `.ant-tree-draggable-icon` span 不渲染**,无空占位、
  无残留 padding,目录名左移完整回收宽度。

**改法**(`FolderTree.tsx:349`,一行 + 注释):

```tsx
// icon:false 隐藏 antd 默认拖拽把手(⠿)回收占宽;拖拽功能不变——rc-tree 的
// draggable 属性挂在节点内容 wrapper 上,把手只是视觉提示,隐藏后抓节点标题即可拖
draggable={enableDrag ? { icon: false } : false}
```

### 1.3 行为影响评估

- **拖拽功能完全保留**:rc-tree 将拖拽能力挂在 `.ant-tree-node-content-wrapper`
  (节点标题区),把手图标仅是视觉提示。隐藏后按住目录名拖动即可,`allowDrop`
  三句式预判(sensitive 源/目标及其子树/自身后代)与落点确认弹窗全部不变。
- **可发现性代价(接受)**:图标是拖拽唯一的显性提示,移除后新用户可能不知道能拖。
  目录树节点菜单里仍有「移动到」入口兜底(W4/W5 同批交付),功能可达性不受损。
- 备选(不推荐):CSS 隐藏 `.ant-tree-draggable-icon`——依赖组件库内部类名,脆弱;
  或连拖拽功能一并移除(`draggable` 回 `false`)——超出「图标占空间」的诉求,不默认做。

---

## 2. 问题二:批量移动弹窗「幽灵成功弹窗」

### 2.1 现象与技术复现路径

用户报告:「移动文件,操作成功后弹出成功弹窗;之前移动其他文件后(再移动别的文件)
会直接弹出成功弹窗,但文件并未移动。」

同一页面会话内的确定性复现:

1. 选中若干文件 → 点「移动 N 个文件」→ 选目标目录 → 提交 → 结果视图
   (绿色成功 Alert「成功移动 X 个文件」)→ 点「完成」关闭,选中被清空;
2. 再选中**其他**文件 → 点「移动 N 个文件」→ **bug:弹窗直接落在上一次的
   「批量移动结果」视图**——没有目标选择界面,标题即「批量移动结果」,footer 只有「完成」;
3. 点「完成」→ 弹窗关闭且当前选中被清空——本次这批文件**从未提交任何请求**,自然没有移动。

即:弹出的「成功」是上一次移动的真实残留结果,用户误以为本次已成功。

### 2.2 根因链(证据)

1. `BatchMoveAssetsModal.tsx:46-48`:`target`/`result` 两个 `useState` 是**组件级状态**,
   且注释自述设计假设——「非 null = 已提交,切结果视图;**组件由调用方条件挂载,重开自动复位**」;
2. `ProjectDetailPage.tsx:604-616`:调用方实际**常挂载、只切 `open` prop**
   (`<BatchMoveAssetsModal open={batchMoveOpen} …>` 常在 JSX 里)——上述「条件挂载」假设
   被违反,qd 交付时接线与组件注释脱节;
3. 弹窗内的 `destroyOnHidden`(BatchMoveAssetsModal.tsx:89)只销毁 **Modal 的 children**,
   救不了 `BatchMoveAssetsModal` 组件自身的 state——关闭后 `result` 仍为上次结果;
4. 重开时 `result` 非 null,三处三元全部落结果视图:title(BatchMoveAssetsModal.tsx:78)、
   footer(:83)、内容(:93)——直接呈现上次成功弹窗。

对照组:同文件 `modals` 片段里的 `RenameFolderModal`/`MoveFolderModal`
(ProjectDetailPage.tsx:585-600)都是 `{target && <Modal open …>}` 条件挂载,无此问题。

缓存与刷新侧无嫌疑:`useBatchMoveAssets`(hooks.ts:528)onSuccess 已失效
`['assets']`+`['folders']`,真实提交过的移动列表会刷新;本 bug 是**请求根本没发出**。

### 2.3 修法(决策点 D2,推荐 A)

**A(推荐):调用方改条件挂载**,与姊妹弹窗同款模式:

```tsx
{batchMoveOpen && (
  <BatchMoveAssetsModal
    open
    onClose={() => setBatchMoveOpen(false)}
    onMoved={() => { setBatchMoveOpen(false); setSelectedIds([]); }}
    …
  />
)}
```

- 重开即全新实例,`result` **和 `target`** 一并复位(只修 `result` 不够——`target` 残留
  会让下次打开预选上次目标目录,一键可提交,同样非预期);
- 缺点:关闭无退出动画,与 Rename/MoveFolderModal 完全同款,接受;
- `destroyOnHidden` 留着无害(防御未来被改回常挂载),不删。

**B(等效备选)**:组件内 `useEffect(() => { if (open) { setResult(null); setTarget(null); } }, [open])`
——保挂载保动画,但多 4 行,且未来新增状态须记得同步重置,不如卸载彻底。

### 2.4 顺带发现(P2,默认不做,待拍板)

- 结果视图在 `moved_count === 0 && skipped > 0`(如整批选了当前所在目录,全部
  `duplicate_location`)时 Alert 仍是 success 绿色,文案「成功移动 0 个文件」易误读,
  建议 `moved_count=0` 时降级为 warning;
- 批量移动弹窗的目标树未禁选**源夹自身**,允许构造出上述全 skip 的空操作提交,
  可选把当前夹加入 `disabledIds`。

两项均为体验打磨,不影响正确性,标 P2 待用户拍板,不进本次默认范围。

---

## 3. 测试与验收(GUI 为主;web 层无单测基建,沿用 tester 真机验收通道)

1. **图标**:PC 侧栏目录树每行无 ⠿ 把手图标,目录名左移、可用宽度增加;
   长目录名省略号行为不回归。
2. **拖拽仍可用**:按住目录标题拖到目标夹(实心落点)与行间隙(gap 落点)均弹确认框;
   sensitive 源仍拖不动、sensitive 目标及其子树仍禁入、自身后代仍禁入(三句式不回归);
   确认后 PATCH 成功、子树 prefix 重算、侧栏刷新。
3. **移动完整流**:选 2 个文件 → 移动 → 选目标 → 提交 → 结果视图计数正确(含跳过明细
   中文文案)→ 完成 → 源夹列表即时消失、目标夹可见。
4. **幽灵弹窗回归(核心)**:完成一次移动后再选其他文件点「移动 N 个文件」→
   **必须出现目标选择视图**(标题「移动 N 个文件」、footer「移动/取消」),而非上次结果;
   提交后展示**本次**结果;取消后重开同样干净(无预选目标目录)。
5. **compact 布局**:移动端入口(工具栏)同验 3/4——modals 片段桌面/紧凑两分支共享
   单实例,改一处两态同愈。
6. 结果视图「取消」语义不回归:结果态点 X 或「完成」都走 `onMoved`(清选中),选择态
   取消走 `onClose`(保留选中)。

---

## 4. 改动清单与部署

| 文件 | 改动 | 规模 |
|---|---|---|
| `material-storage/web/src/components/FolderTree.tsx` | `draggable` 改 `{ icon: false }` 三元 + 注释 | ~3 行 |
| `material-storage/web/src/pages/ProjectDetailPage.tsx` | `BatchMoveAssetsModal` 常挂载 → `{batchMoveOpen && …}` 条件挂载 | ~3 行 |

- 纯前端、零 api/迁移/FGA/依赖改动 → dev/prod 均走既有「SPA build → 分片同步 →
  原子替换」通道,api 容器不动;回滚 = SPA 换回部署前备份目录。
- 与在途事项无耦合:不触碰 W2a 激活运维;W6 二期跨项目移动另期,届时 `BatchMoveAssetsModal`
  的挂载方式照 A 模式保持即可。

## 5. 决策点

| # | 问题 | 推荐 | 备选 |
|---|---|---|---|
| D1 | 拖拽图标移除方式 | `{ icon: false }` 隐藏图标、保留拖拽(antd 声明式配置,零残留) | 连拖拽功能一并关(若用户本意是不要拖拽);CSS 隐藏(不推荐) |
| D2 | 幽灵弹窗修法 | A:调用方条件挂载(与姊妹弹窗模式对齐,顺带复位 `target`) | B:`open` 翻转时 useEffect 重置(保动画,多状态同步负担) |
| D3 | §2.4 两项 P2(0 移动降级 warning / 目标树禁选源夹) | 默认不做,待拍板 | 随本次顺手带上(各 ~3 行) |
