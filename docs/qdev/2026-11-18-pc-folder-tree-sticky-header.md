# PC 端项目详情页 · 左侧文件夹树「头部固定 + 树区独立滚动」

- 日期:2026-11-18
- 基线:liuqi @ 157154d,分支 `feat/pc-folder-tree-sticky`(worktree `rushes-lab-pc-folder-tree-sticky`)
- 类型:纯前端布局改动(视觉样式零变化)

## 1. 背景与目标

PC 桌面端项目详情页为三栏 Layout(`ProjectDetailPage.tsx:1134` 起):左 `Layout.Sider`(260px)内嵌 `FolderTree` 组件,中 AssetTable,右 AssetSummaryPanel。左 Sider 整体 `overflow: 'auto'`,即 `FolderTree` 的头部区(「Folders」小标 + 项目名 + 新建一级/新建子按钮,`FolderTree.tsx:217` 的 `Header`)与下方文件夹树**作为一个整体滚动**。

文件夹一多,用户向下滚树时头部(含「新建文件夹」入口)被滚出视野,要回到顶部才能新建/看项目名。

**目标**:左栏头部区固定(fixed/sticky),仅文件夹树内容参与 Y 轴滚动。仅限 PC 桌面分支;compact(<1024)窄屏 Drawer 与其他弹窗使用方行为零变化。

## 2. 功能点明细(逐条可验收)

1. PC 桌面项目详情页左栏:`FolderTree` 头部区(Folders 标 + 项目名 + 两个新建按钮)在树滚动时**保持固定可见**,不随树滚走。
2. 仅文件夹树列表区域出现 Y 轴滚动条;树内容不超过可视高度时无滚动条、无多余空白。
3. 左栏头部底部的分隔线(`borderBottom`)仍在固定头部下缘,滚动时树内容从分隔线下方穿过(头部不透明,不透出底层树节点)。
4. 树为空(空项目/无可见夹)时左栏显示既有空态,布局不破、无异常滚动条。
5. 头部固定后,「新建子文件夹」按钮(依赖 activeFolderId)行为、树选中/展开/拖拽换父/节点菜单交互**全部不回归**。
6. compact(<1024)窄屏:左树 Drawer、MoveFolderModal、BatchMoveAssetsModal、BaiduNewTaskModal 四处 `FolderTree` 使用方的滚动与视觉行为**逐像素零变化**(默认不启用新布局)。
7. 中栏 AssetTable、右栏 summary 滚动行为不变;页面整体(#134 固高三栏)结构不变。

## 3. 组件拆分方案

### 3.1 组件清单

| 组件/文件 | 职责 | 复用映射 | 预估改动 |
|---|---|---|---|
| `src/components/FolderTree.tsx` | 新增可选 prop `fillHeight?: boolean`(命名可按代码习惯调整,语义=「填满父容器高度,头部固定、树区独立滚动」)。启用时:根容器 `height:100%` + `display:flex; flexDirection:column`;`Header` 块 `flexShrink:0`(加不透明背景 `var(--ms-surface)`,防树内容穿透);树容器 div(`.ms-folder-tree`)`flex:1; minHeight:0; overflowY:'auto'`。空态分支同步套用同一布局骨架(空态内容区 `flex:1; overflowY:'auto'`,内容样式不变)。默认 false → 既有使用方零变化 | 改造复用(共享组件加默认关闭的能力位) | 约 +20~35 行,总行数 ≤400(现 350) |
| `src/pages/ProjectDetailPage.tsx` | 桌面左 Sider(:1146):`overflow: 'auto'` → `'hidden'`;传 `fillHeight`;保证高度链传导到 FolderTree 根(antd `Layout.Sider` 内部有 `.ant-layout-sider-children` 包裹层,需确认其高度为 100%——antd 默认样式即 `height:100%`,如不成立用一行 CSS 或内联样式补齐,方案自定,验收以功能点为准) | 直接复用 FolderTree 新能力 | 约 ±8 行 |

### 3.2 依赖与数据流

无新数据流、无新接口:纯布局改动。`fillHeight` 只改容器布局,`FolderTree` 全部既有 props(树数据/选中/拖拽/菜单)语义不变。

### 3.3 不许碰的边界

- `FolderTree.tsx` 中 `buildTree`/拖拽/菜单/展开逻辑逻辑层零改动(仅 JSX 容器与 style)。
- compact Drawer(:1055)调用处、`MoveFolderModal`、`BatchMoveAssetsModal`、`BaiduNewTaskModal` 四处不传 `fillHeight`,文件其余部分不动(若 lint 因无关问题报错也仅限本次触碰文件内的相关行)。
- `folderNodeTitle.tsx`、`src/styles/tokens.css` 的 `.ms-folder-tree` 既有规则不动。
- 中栏/右栏/顶栏布局不动。

### 3.4 预估新增/修改文件清单

- 修改:`src/components/FolderTree.tsx`(≤400 行)
- 修改:`src/pages/ProjectDetailPage.tsx`(现 1582 行,本次净变化 ±8 行;该文件本身超 500 行属存量现状,本次不新增功能代码,不打回重拆——只做布局参数级修改)
- 单文件硬上限 500 行:FolderTree.tsx 改后必须 ≤500 行(预估 ~380 行,达标)

## 4. 数据库修改方案

不涉及。

## 5. 接口定义

不涉及。

## 6. 前端改动点

见 §3.1。技术要点提示(非强约束,验收以 §2 功能点为准):

- 高度链:Layout(固高 overflow hidden)→ Sider(overflow hidden)→ `.ant-layout-sider-children`(需 100% 高)→ FolderTree 根(height 100% flex column)→ 树区(flex:1 minHeight:0 overflowY auto)。`minHeight:0` 是 flex 子项可滚动的关键,漏掉则树区被内容撑开、头部照样被推走。
- 头部不透明背景必须显式声明(sticky/flex 固定后下层内容会穿过);与 Sider 同色 `var(--ms-surface)`。
- `Tree` 的 `defaultExpandAll`(树 <30 全展开)与拖拽行为在自定义滚动容器内不受影响(rc-tree 非虚拟滚动模式 DOM 直渲染);若发现拖拽时滚动容器边缘自动滚异常属存量行为,不在本次范围。

## 7. 后端改动点

不涉及。

## 8. 测试功能点

web 无单测框架(仅 `npm run lint` + `npm run build`),测试功能点以**结构化人工/检查清单**为主,专职测试子智能体按此逐条核查代码与构建:

1. 【代码核查】`FolderTree` 新 prop 默认关闭路径:不传 `fillHeight` 时 JSX 结构与改造前一致(diff 审查,四个既有使用方调用处无任何实参变化)。
2. 【代码核查】`fillHeight` 路径:根容器 height/flex、Header flexShrink+背景、树区 flex+minHeight+overflowY 三要素齐备;空态分支同骨架。
3. 【代码核查】PC 左 Sider overflow hidden + 高度传导措施存在。
4. 【构建】`npm run lint` 0 error;`npm run build`(tsc -b + vite build)成功。
5. 【回归核查】本次 diff 仅触及 §3.4 清单两文件;`git diff` 无越界改动。
6. 【运行时验收(构建产物静态服)】worktree build 产物本地静态服(pnpm vite preview 或等价)人工冒烟:头部固定、树滚动、空态、窄屏 Drawer 不变——此项由 PM/用户做真机验收,测试子智能体产出产物并报告启动方式即可。

## 9. 模糊点与决策记录

| # | 模糊点 | 决策 | 理由 |
|---|---|---|---|
| 1 | compact 窄屏 Drawer 是否同步固定头部 | 不同步,仅 PC 桌面 | 用户明说「PC 端」;Drawer 高度场景不同,另行周期 |
| 2 | 实现选型:组件受控 `fillHeight` prop vs Header `position:sticky` | 受控 prop 方案 | sticky 会连带改变 Drawer/Modal 四个使用方的滚动表现(超范围副作用);prop 方案默认关闭,严格圈定影响面,与中栏「滚动收敛到内部区」(#134)模式一致 |
| 3 | 树区是否启用 rc-tree 虚拟滚动 | 不启用 | 树规模(单项目文件夹数)远低于虚拟滚动收益阈值;保持存量行为 |
| 4 | 可行性/成本红线评估 | 通过:纯布局小改,两文件 ±40 行,无架构影响 | 调研实证 |

## 10. 项目约定(派发用)

- 工作目录:worktree `E:\qbb\github_not_me\rushes-lab-pc-folder-tree-sticky`(所有改动仅在此路径)。
- web 依赖:`material-storage/web/node_modules` 为指向主仓的 junction,**勿删勿 npm/pnpm install**;lint/build 用主仓 junction 依赖(锁 antd 6.4.2)。
- 命令(worktree 的 `material-storage/web` 下):`npm run lint`;`npm run build`。
- 结束时汇报:改动文件清单 + 每处改动说明 + lint/build 真实输出结论。
