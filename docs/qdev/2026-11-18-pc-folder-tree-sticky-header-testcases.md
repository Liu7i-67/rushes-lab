# PC 端项目详情页 · 左栏 FolderTree「头部固定 + 树区独立滚动」— 结构化测试用例清单

- 日期:2026-11-18
- 依据:`docs/qdev/2026-11-18-pc-folder-tree-sticky-header.md`(需求文档为唯一依据,§8 测试功能点 + §2 功能点明细)
- 被测 worktree:`E:\qbb\github_not_me\rushes-lab-pc-folder-tree-sticky`(分支 `feat/pc-folder-tree-sticky`,基线 157154d)
- 用例编写时的代码状态:基线 157154d、工作区无 diff(开发可能尚未合入)。所有「基线锚点」行号以 157154d 为准:
  - `FolderTree.tsx` 350 行:Props 声明 :23-50;解构 :132-136;`Header` 常量 :217-272;空态分支 :274-306;主 return :308-326(`.ms-folder-tree` 容器 :311,`<Tree>` props :312-323);逻辑函数 `isDescendant` :61-69、`hasSensitiveAncestry` :72-80、`buildTree` :82-130、`renderNodeOps` :145-176、`allowDrop` :179-188、`handleDrop` :190-200、`defaultExpanded` :202-215
  - `ProjectDetailPage.tsx` 1582 行:compact 左树 Drawer :1047-1068(FolderTree 调用 :1055);桌面三栏 Layout :1135-1144(固高 + `overflow:'hidden'` :1139-1142);桌面左 Sider :1146-1166(`overflow:'auto'` :1149,FolderTree 调用 :1151-1165)
- 环境事实(已实证,写死进用例,免得执行人重查):
  - web 依赖为主仓 junction(`material-storage/web/node_modules`),**勿 install**;antd 锁 6.4.2;vite 8.0.13
  - antd 6.4.2 默认样式已含 `.ant-layout-sider-children { height:100% }`(`node_modules/antd/es/layout/style/sider.js` :36-37;`dist/antd.css` 中为 `height:100%;margin-top:-0.1px;padding-top:0.1px;`)
  - `vite preview` 会继承 `server.proxy`(vite 8 源码 `preview.proxy ?? server.proxy`),即 `/api → http://localhost:8200` 在 preview 下同样生效
  - `vite.config.ts`:`base:'/ms-static/web/'`,build 输出 `../api/app/static/web`;scripts:`lint=eslint .`、`build=tsc -b && vite build`、`preview=vite preview`
  - `.ms-folder-tree` 既有 CSS 规则位于 `src/styles/tokens.css` :254、:261-263(边界文件,不许动)

## 用例域索引

| 域 | 内容 | 用例 |
|---|---|---|
| a | fillHeight 默认关闭路径 | UC-01 ~ UC-03 |
| b | fillHeight 启用路径(三要素 + 空态) | UC-04 ~ UC-06 |
| c | PC 左 Sider overflow hidden + 高度传导 | UC-07 |
| d | 交互回归(代码层面,逻辑层零改动) | UC-08 ~ UC-10 |
| e | 构建(lint / build) | UC-11 ~ UC-12 |
| f | 越界检查(文件集合 / 行数红线) | UC-13 ~ UC-14 |
| g | 运行时冒烟(构建产物静态服,人工/浏览器) | UC-15 ~ UC-20 |

共 **20** 条。域 a/b/c/d/e/f 为代码/构建核查(可交测试子智能体直接执行),域 g 供 PM/用户真机验收(需求 §8.6)。

命令约定:以下 git/npm 命令均在 worktree 根 `E:\qbb\github_not_me\rushes-lab-pc-folder-tree-sticky` 执行(npm 命令在 `material-storage/web` 下);路径用 `/` 正斜杠(Git Bash)。

---

## 域 a — fillHeight 默认关闭路径

### UC-01 新 prop 为可选且默认关闭

- **类型**:代码核查(静态)
- **前置**:改造已合入 worktree;基线锚点见文首。
- **操作**:
  1. `git diff -- material-storage/web/src/components/FolderTree.tsx`,只看两处:
     - `interface Props { ... }`(基线 :23-50):预期仅**新增**一个可选成员,形如 `fillHeight?: boolean;`(命名允许按代码习惯微调,语义 = 填满父容器高度/头部固定),带一句 JSDoc;不删除、不改名、不改类型任何既有 prop(`folders`/`projectName`/`activeFolderId`/`onSelect`/`onCreateChild`/`onCreateRoot`/`canUpload`/`selectMode`/`disabledIds`/`disabledSelfIds`/`nodeActions`/`onRenameFolder`/`onMoveFolder`/`enableDrag`/`onMoveDrop` 共 15 个逐一核对仍在且签名未变)。
     - 组件参数解构(基线 :132-136):预期仅新增解构出该 prop,无既有标识符变动。
  2. `grep -n "fillHeight" material-storage/web/src/components/FolderTree.tsx`:预期命中点仅限 prop 声明、解构、以及**条件为真才生效**的分支;全文件不存在 `fillHeight = true` / 解构默认值 `= true` 之类使其默认开启的写法。
- **预期**:prop 可选、默认 falsy(关闭);既有 Props 契约零破坏。
- **证据采集**:两处 diff 片段 + grep 输出原样粘贴进测试记录。

### UC-02 不传 fillHeight 时 JSX 结构与改造前语义一致

- **类型**:代码核查(diff 审查)
- **前置**:同 UC-01。
- **操作**:
  1. `git diff -- material-storage/web/src/components/FolderTree.tsx`,按 hunk 逐块审查,基线锚点:
     - 空态分支根 `<div>`(基线 :275,**无 style**);
     - 主分支根 `<div>`(基线 :309,**无 style**);
     - `.ms-folder-tree` 容器(基线 :311,style 仅 `{{ padding: '6px 4px 12px' }}`);
     - `Header` 块(基线 :218-223,style 含 `display/alignItems/padding/gap/borderBottom` 五键)。
  2. 对 diff 中每一个**新增的 style 键**,确认其仅在 `fillHeight` 为真时才进入渲染:允许的两种实现形态——
     - 形态 1:条件展开,如 `style={{ ...(fillHeight ? { height:'100%', display:'flex', flexDirection:'column' } : {}) }}`;
     - 形态 2:`fillHeight ? <根容器A>…</根容器A> : <根容器B>…</根容器B>` 双分支。
     凡新增键**无条件**合入 style 对象(无三元、无条件),即判 FAIL——默认路径渲染产物就会带上新布局。
  3. 断言 grep:`git diff -- material-storage/web/src/components/FolderTree.tsx | grep -E "^\+.*(height: ?'100%|flexDirection|flexShrink|overflowY|minHeight|flex: ?1|background: ?'var\(--ms-surface\)')"` 对每条命中行回看上下文,确认全部处于 `fillHeight` 条件之内。
- **预期**:不传 `fillHeight` 时,两个 return 分支渲染出的 DOM 结构与内联 style 与基线**逐字段一致**(基线语义:根容器普通块级、Header 五键、树容器仅 padding;整页滚动由调用方容器负责)。
- **证据采集**:全量 diff 文本存档;上条 grep 输出 + 每条命中的条件归属标注。

### UC-03 四个既有使用方调用处无任何实参变化

- **类型**:代码核查(grep + git diff 审查,逐一核查)
- **前置**:同 UC-01。注意防混淆:`src/` 中 `grep "<FolderTree"` 共 7 处 JSX,其中 `MobileTabBar.tsx:69` 与 `AdminFolderTemplatesPage.tsx:111` 是 **lucide-react 同名图标**(`FolderTree size=…`),不是本组件使用方,不纳入本用例,但其文件不应出现在 diff 中(归 UC-13)。
- **操作**(对四个使用方逐一执行,四个都要留痕):
  1. **compact Drawer(ProjectDetailPage.tsx :1055)**:
     - `git diff -U3 -- material-storage/web/src/pages/ProjectDetailPage.tsx` 中,基线 :1046-1068 区间(Drawer 声明 + `<FolderTree folders=… nodeActions={folderNodeActions} onRenameFolder={setRenameTarget} onMoveFolder={setMoveTarget} />`)无任何 `-`/`+` 行;该调用处 props 集合(`folders/projectName/activeFolderId/onSelect/onCreateRoot/onCreateChild/canUpload/nodeActions/onRenameFolder/onMoveFolder`)与逐值表达式不变,**不得出现 `fillHeight`**。
  2. **MoveFolderModal.tsx :120**:
     - `git diff --stat -- material-storage/web/src/components/MoveFolderModal.tsx` → 预期**空输出**(文件零改动);
     - `grep -n "fillHeight" material-storage/web/src/components/MoveFolderModal.tsx` → 预期 0 命中;
     - 该调用处既有 props(`folders/projectName/selectMode/disabledIds/activeFolderId/onSelect`)抽查仍原样(与基线比对)。
  3. **BatchMoveAssetsModal.tsx :118**:同上两条(`git diff --stat` 空 + grep 0 命中 + props 抽查 `folders/projectName/selectMode/disabledIds/disabledSelfIds/activeFolderId/onSelect` 原样)。
  4. **BaiduNewTaskModal.tsx :238**:同上两条(`git diff --stat` 空 + grep 0 命中 + props 抽查 `folders/projectName/selectMode/disabledIds/activeFolderId/onSelect` 原样)。
  5. 汇总断言:`grep -rn "fillHeight" material-storage/web/src/` → 预期仅 2 个文件命中:`FolderTree.tsx`(声明+内部使用)与 `ProjectDetailPage.tsx`(桌面 Sider 调用处,恰好 1 次);上述四个既有使用方文件中 0 命中。
- **预期**:四处既有调用处实参零变化;三弹窗文件整体零 diff。
- **证据采集**:逐条命令输出 + ProjectDetailPage compact 区间 diff(应无该区间 hunk)存档。

---

## 域 b — fillHeight 启用路径(三要素 + 空态)

### UC-04 三要素逐项核查(根容器 / Header / 树区)

- **类型**:代码核查(逐项 grep + diff 定位)+ DevTools 运行时佐证
- **前置**:同 UC-01;`fillHeight` 在桌面 Sider 调用处已传入。
- **操作**(三要素逐项,每项独立留痕):
  1. **要素① 根容器**:diff 中 fillHeight 生效分支的根 `<div>` style 新增 `height:'100%'`、`display:'flex'`、`flexDirection:'column'`(三键缺一即 FAIL)。空态分支与主分支两个根容器都要有(见 UC-05)。
  2. **要素② Header(基线 :217-272)**:diff 中 Header 的 style 新增 `flexShrink:0` 与不透明背景 `background:'var(--ms-surface)'`(与 Sider 同色,需求 §6 点名);既有 `borderBottom: '1px solid var(--ms-hairline-soft)'`、`padding:'12px 14px 10px'` 等键**保留未删**。断言 grep:`grep -n "flexShrink" material-storage/web/src/components/FolderTree.tsx`(注:基线 :341 的 `nodeOpsBtn.flexShrink:0` 是既有命中,需区分新增命中点在 Header style)。
  3. **要素③ 树区(`.ms-folder-tree` 容器,基线 :311)**:fillHeight 分支下该 div style 在保留 `padding:'6px 4px 12px'` 基础上新增 `flex:1`、`minHeight:0`、`overflowY:'auto'`(三键缺一即 FAIL;`minHeight:0` 缺失的后果 = flex 子项被内容撑开、头部照样被推走,需求 §6 已提示,审查时重点盯)。
  4. `<Tree>` 元素本体(基线 :312-323)不在本用例范围(归 UC-09),确认三要素只落在容器 style 层。
- **预期**:三要素齐备且只加在容器 style 上,不影响任何业务逻辑。
- **证据采集**:三要素各自的 diff 片段;可选运行时佐证——浏览器 DevTools 选中根 div 与 `.ms-folder-tree`,截图 computed style(height=100%、display=flex;flex=1 1 0%、min-height=0、overflow-y=auto)。

### UC-05 空态分支同骨架,内容样式不变

- **类型**:代码核查
- **前置**:同 UC-01。
- **操作**:
  1. diff 中 `if (tree.length === 0)` 分支(基线 :274-306):根容器在 fillHeight 时套用与主分支相同的骨架(height 100% + flex column;空态内容区 `flex:1` + `overflowY:'auto'`——需求 §3.1 原文口径)。
  2. 空态**内容**样式逐键不变:内容 div `padding:'40px 16px'`、`textAlign:'center'`、`color:'var(--ms-ink-subtle)'`,图标 `FolderIcon size=28`、文案「{projectName ?? '项目'}<br/>还没有文件夹」、`onCreateRoot` 的「+ 新建文件夹」按钮样式(marginTop:16 / accent 背景 / fontSize:12.5 等)全部保留;`Header` 仍渲染在空态分支顶部(基线 :277)。
- **预期**:空态与有树两分支共用同一布局骨架,空态视觉与基线一致,不因骨架套用产生额外滚动条或空白(运行时由 UC-17 验证)。
- **证据采集**:空态分支 diff 片段 + 空态内容样式对照表(基线值 vs diff 后值)。

### UC-06 头部不透明背景与下缘分隔线

- **类型**:代码核查 + 运行时复核
- **前置**:同 UC-01。
- **操作**:
  1. 代码层:UC-04 要素② 已查 `background:'var(--ms-surface)'`;本条补充确认该背景值**不透明**(var(--ms-surface) 在 `src/styles/tokens.css` 的定义应为不透明色值,`grep -n "\-\-ms-surface" material-storage/web/src/styles/tokens.css` 核对;若为 rgba/带 alpha 值即 FAIL,树内容会透出);`borderBottom: '1px solid var(--ms-hairline-soft)'` 仍在 Header style 中(fixed 后分隔线仍位于固定头部下缘)。
  2. 运行时(可并入 UC-16 步骤 b/c 执行):滚动树时,头部下缘始终有一条分隔线;树节点行从分隔线**下方穿过**,头部文字/按钮背后**不透出**节点内容。
- **预期**:头部不透明、分隔线恒在头部下缘。
- **证据采集**:tokens.css 中 `--ms-surface` 色值记录;滚动中截图 1 张(能看到节点行穿过分隔线下方且头部不透明)。

---

## 域 c — PC 左 Sider overflow hidden + 高度传导

### UC-07 Sider overflow hidden + 高度链传导核查(含额外措施最小性)

- **类型**:代码核查
- **前置**:同 UC-01;基线锚点 `ProjectDetailPage.tsx` :1135-1166。
- **操作**:
  1. **overflow 改向**:diff 中基线 :1149 `overflow: 'auto'` → `overflow: 'hidden'`(只改 Sider 这一处 overflow;桌面 Layout :1142 的 `overflow:'hidden'` 与 compact Drawer 的 `styles={{ body: { padding:0, overflowY:'auto' } }}` :1053 **不得被改动**)。
  2. **fillHeight 传递**:桌面 `<FolderTree …>`(基线 :1151)新增 `fillHeight`(恰一次;compact :1055 处无,见 UC-03)。
  3. **高度链逐环核查**(Layout 固高 → Sider → sider-children → FolderTree 根 → 树区):
     - 环 1 Layout:基线 :1139 `height:'calc(100vh - 56px - 32px - 80px)'` + :1142 `overflow:'hidden'` 保持不变(diff 无该两行变动);
     - 环 2 Sider:环 1 之下 Sider 默认 flex 拉伸占满 Layout 高(antd 默认,不要求改动);
     - 环 3 `.ant-layout-sider-children`:antd 6.4.2 **默认即 `height:100%`**(实证:`node_modules/antd/es/layout/style/sider.js` :36-37)。执行 `grep -rn "ant-layout-sider-children" material-storage/web/src/` 记录命中(基线为 0):
       - 若 **0 命中** → 传导完全依赖 antd 默认,达标,无需任何补丁;同时确认 diff 里没有为补高度而引入的全局 CSS/全局选择器;
       - 若有命中 → 核查额外传导措施的**存在性与最小性**:只允许一行 CSS 或一处内联样式,作用域仅限该 Sider 链(如内联在 Sider/包裹层上的 `height:'100%'`),不得出现全局 `*`/`body`/`.ant-layout-sider-children` 裸全局规则改动、不得波及 compact Drawer 或其他页面的 Sider;超出「一行、局部」即判违反最小性,记 FAIL 并要求说明。
     - 环 4/5 FolderTree 根与树区:已由 UC-04 覆盖,不重复。
- **预期**:Sider 改 overflow hidden + fillHeight 传递;高度链闭环(依赖 antd 默认或最小补丁),无全局副作用。
- **证据采集**:Sider hunk diff;`ant-layout-sider-children` grep 输出;若有补丁,附补丁代码 + 作用域说明。

---

## 域 d — 交互回归(代码层面核查,头部固定后行为不变)

### UC-08 逻辑层零改动(diff 只含容器/style 层)

- **类型**:代码核查(hunk 行号定位法)
- **前置**:同 UC-01。
- **操作**:
  1. `git diff -U0 -- material-storage/web/src/components/FolderTree.tsx` 列出全部 hunk 头(`@@ -a,b +c,d @@`)。预期所有改动行(基线侧行号 a)只落在以下容器/style 区间:Props 声明(:23-50)、解构(:132-136)、`Header` JSX/style(:217-272)、空态分支根容器与包裹层(:274-276 附近的容器行)、主 return 根容器与 `.ms-folder-tree` 容器行(:308-311)。
  2. 逻辑函数区(基线行号)**零改动**白名单逐个确认:`isDescendant` :61-69、`hasSensitiveAncestry` :72-80、`buildTree` :82-130、`renderNodeOps` :145-176、`allowDrop` :179-188、`handleDrop` :190-200、`defaultExpanded` :202-215、节点 ⋯ 菜单 Dropdown 与 onClick(:152-175)。区间内不允许出现 `-`/`+` 行。
  3. 快捷断言(应空输出,解构/参数行的 fillHeight 新增除外):`git diff -- material-storage/web/src/components/FolderTree.tsx | grep -E "^[+-].*(buildTree|isDescendant|hasSensitiveAncestry|allowDrop|handleDrop|defaultExpanded|renderNodeOps|dropToGap|is_sensitive|localeCompare)"` → 若命中,逐条人工确认是否仅为解构签名行的连带改行;函数体内命中即 FAIL。
  4. **allowDrop 三句式**专项确认(diff 中不允许出现对以下语义的任何增删改):①源 sensitive 禁移(基线 :183 `if (src.is_sensitive) return false`);②目标 sensitive 及其子树禁入(:184 `hasSensitiveAncestry`);③禁入自身后代防环(:185-186 `src.id === dst.id` / `isDescendant`)。
- **预期**:diff 仅容器/style 层;拖拽换父(三句式)、菜单、展开推导逻辑逐行未触碰。
- **证据采集**:hunk 头行号清单(标注每 hunk 所属区间)+ 步骤 3 grep 输出。

### UC-09 `<Tree>` 七个 props 表达式逐字符不变

- **类型**:代码核查(grep 断言)
- **前置**:同 UC-01;基线锚点 `<Tree>` 块 :312-323。
- **操作**:`git diff -U1 -- material-storage/web/src/components/FolderTree.tsx` 确认 `<Tree …>` 元素块无改动行;辅助断言:`git diff -- material-storage/web/src/components/FolderTree.tsx | grep -E "^[+-].*(defaultExpandAll|defaultExpandedKeys|selectedKeys|onSelect=|draggable|allowDrop=|onDrop=|treeData)"` → 预期 **0 命中**。逐项核对基线语义:
  - `defaultExpandAll={tree.length < 30}`(树 <30 全展开)
  - `defaultExpandedKeys={defaultExpanded}`(activeFolderId 祖先链展开)
  - `selectedKeys={activeFolderId ? [activeFolderId] : []}` 与 `onSelect={(keys) => keys[0] && onSelect(keys[0] as string)}`
  - `draggable={enableDrag ? { icon: false } : false}`(隐藏拖拽把手语义)
  - `allowDrop={enableDrag ? allowDrop : undefined}` / `onDrop={enableDrag ? handleDrop : undefined}`
- **预期**:七组 props 表达式与基线逐字符一致(选中/展开/拖拽行为在自定义滚动容器内不受影响,rc-tree 非虚拟滚动 DOM 直渲染,需求 §6)。
- **证据采集**:grep 断言空输出截图;`<Tree>` 块无 diff 的确认记录。

### UC-10 「新建子」按钮 activeFolderId 依赖链不变

- **类型**:代码核查
- **前置**:同 UC-01。
- **操作**:
  1. FolderTree 侧:diff 中 Header 内「新建子」按钮区(基线 :254-270)逻辑不变——渲染条件仍为 `canUpload && onCreateChild && activeFolderId`(未选中夹不显示),`onClick={onCreateChild}`、aria-label「新建子文件夹」、accent 色「子」徽标样式保留;「新建一级」按钮(基线 :240-253,条件 `canUpload && onCreateRoot`)同理不变。断言 grep:`git diff -- material-storage/web/src/components/FolderTree.tsx | grep -E "^[+-].*(onCreateChild|onCreateRoot|activeFolderId)"` → 命中行须逐一人工确认仅为容器/style 连带(如 Header style 对象整体重写导致的上下文行),条件表达式与 onClick 绑定不得变。
  2. ProjectDetailPage 侧:桌面接线(基线 :1156-1157)`onCreateRoot={canUploadProject ? () => setNewFolderMode('root') : undefined}`、`onCreateChild={canUploadProject ? () => setNewFolderMode('child') : undefined}` 在 diff 中不变;`setNewFolderMode('child')` 的下游消费(新建子文件夹 Modal 打开)不在 diff 触及范围。
- **预期**:头部固定改造后「新建子」依赖链(选中夹 → 按钮出现 → 点按开 Modal)代码层零变化。
- **证据采集**:grep 输出 + 两处调用点 diff 对照记录。

---

## 域 e — 构建

### UC-11 lint 通过(0 error)

- **类型**:构建核查
- **前置**:node_modules junction 完好指向主仓(**勿 npm/pnpm install**);命令在 worktree 的 `material-storage/web` 下执行。
- **操作**:`npm run lint`(即 `eslint .`)。
- **预期**:退出码 0,**0 error**;warning 允许存量但需记录条数与归属文件;按需求 §3.3,若报错仅允许出现在本次触碰两文件的相关行且开发已修——凡出现**其他文件**的 lint 报错,判 FAIL(不得以「无关存量」放行本次合入引入的报错)。
- **证据采集**:完整 stdout/stderr + 退出码;若非零,附报错全文。

### UC-12 build 成功

- **类型**:构建核查
- **前置**:同 UC-11;UC-11 已通过。
- **操作**:`npm run build`(即 `tsc -b && vite build`)。
- **预期**:tsc 无类型错误;vite build 成功(输出含 `✓ built in …`);产物写出至 `material-storage/api/app/static/web/`(vite.config outDir `../api/app/static/web`)且含 `index.html` 与 `assets/`;chunk 划分正常(antd/react/uppy/vendor 独立 chunk,manualChunks 未被改动——该文件不在允许触碰集合)。
- **证据采集**:build 输出尾部(含产物清单与体积表)+ `ls material-storage/api/app/static/web` 结果。

---

## 域 f — 越界检查

### UC-13 diff 触及文件集合恰为两文件

- **类型**:代码核查(git 审计)
- **前置**:改造完成、UC-11/12 已过。
- **操作**:
  1. `git status --short` + `git diff --name-only` + `git diff --cached --name-only`(若有 staged)。
  2. 集合断言:**代码文件集合 == { `material-storage/web/src/components/FolderTree.tsx`, `material-storage/web/src/pages/ProjectDetailPage.tsx` }**,不多不少。允许出现的非代码条目仅限 `.md` 文档(如本用例文件、需求文档);`scripts/changelog.md` 记账按仓库约定另行周期,若本次分支出现需在报告中单列说明(不算代码越界)。
  3. 边界文件专项反断言(出现即 FAIL):`src/styles/tokens.css`、`src/components/folderNodeTitle.tsx`、`vite.config.ts`、`package.json`、`package-lock.json`、`MobileTabBar.tsx`、`AdminFolderTemplatesPage.tsx`、三个 Modal 文件、`src/` 下其他任何文件。
- **预期**:无越界改动。
- **证据采集**:三条 git 命令完整输出。

### UC-14 行数红线(FolderTree ≤500;ProjectDetailPage ±8 行级)

- **类型**:代码核查(度量)
- **前置**:同 UC-13。
- **操作**:
  1. `wc -l material-storage/web/src/components/FolderTree.tsx` → **≤500 为硬红线**(需求 §3.4);参考预警线 ≤400(需求 §3.1 预估 ~380):介于 401-500 记「红线内、超预估」,需在报告中说明膨胀原因,不自动 FAIL。
  2. `git diff --numstat -- material-storage/web/src/pages/ProjectDetailPage.tsx` → 输出 `新增行数 删除行数`。判定口径(需求 §3.4「本次净变化 ±8 行级别」):`新增+删除 ≤ 16` 达标;`17~30` 记「超量级」,需开发逐行说明用途;`>30` FAIL。另核对净变化 `|新增-删除|` 应远小于总量(典型形态:overflow 一删一增 + fillHeight 一增,预期净 +1~+2 行)。
  3. FolderTree 增量旁证:`git diff --numstat -- material-storage/web/src/components/FolderTree.tsx`,预期落在需求预估 +20~35 行区间(大幅偏离同样需说明)。
- **预期**:FolderTree ≤500(争取 ≤400);ProjectDetailPage 净变化 ±8 行级别。
- **证据采集**:wc -l 输出、两条 numstat 输出、判定结论。

---

## 域 g — 运行时冒烟(构建产物静态服,供 PM/用户人工执行)

### UC-15 构建产物静态服启动

- **类型**:运行时(环境步骤)
- **前置**:UC-12 build 成功(产物在 `material-storage/api/app/static/web/`);本地后端 `ms-api` 可用(监听 8200,能登录、能列出项目/文件夹——纯静态无后端时树区无数据,布局类断言仍可做但交互类断言需后端);node_modules junction 完好。
- **操作**:
  1. 在 worktree 的 `material-storage/web` 下执行 `npm run preview`(等价 `pnpm vite preview`;vite 8 preview **继承** dev 的 `/api → http://localhost:8200` 代理,已实证)。
  2. 浏览器访问 **`http://localhost:4173/ms-static/web/`**——注意 base 为 `/ms-static/web/`,裸 `http://localhost:4173/` 打不开属正常;端口冲突时 `npm run preview -- --port 4174` 换端口(URL 同步换)。
  3. 登录,进入任一项目详情页;DevTools Network 确认 `/api/...` 请求经 preview 代理返回 200。
  4. 备选对照环境:`npm run dev`(5173,同样有代理)——仅用于交互问题排查对照,**验收以 4173 构建产物为准**。
- **预期**:静态服可启动、页面可登录可进项目详情、三栏布局正常渲染。
- **证据采集**:preview 启动日志、访问 URL 截图、Network 面板 `/api` 200 截图。

### UC-16 头部固定 + 树区独立滚动(功能点 §2.1/2.2/2.3)

- **类型**:运行时(人工)
- **前置**:UC-15 完成;准备一个文件夹**多于一屏**的测试项目(≥2 屏;建议 25 个顶层夹 + 每个下 3~5 个子夹——顶层 <30 保证 defaultExpandAll 全展开,若 ≥30 需手动展开以制造高度)。
- **操作**(逐项核对,逐项留痕):
  - a. 滚动树区到最底:头部区(Folders 小标、项目名、右上「+」新建一级按钮、选中夹后的「+子」按钮)**全程固定可见**,不随滚动上移出视野;反向滚回顶部确认无跳动。
  - b. 头部下缘分隔线恒在(同 UC-06 运行时部分);滚动中树节点行从分隔线下方穿过,头部背后不透出节点(不透明)。
  - c. 滚动条**只出现在树区**(Sider 260px 内、Header 以下);Header 高度带与 Sider 右边缘无第二条滚动条;左 Sider 自身(`.ant-layout-sider`)不滚。
  - d. **短树无滚动条无空白**:切到文件夹少于一屏的项目——树区无 Y 轴滚动条、Sider 底部无大块空白塌陷(树内容自然顶齐,分隔线以下即是内容),整页高度行为与改造前观感一致。
  - e. DevTools 佐证:`.ms-folder-tree` computed `overflow-y:auto`、`min-height:0`;根容器 `height:100%` + `display:flex`。
- **预期**:满足需求功能点 1/2/3 全部表述。
- **证据采集**:长树滚动中截图 1 张(头部可见+分隔线+树区滚动条)、短树截图 1 张、computed style 截图;录屏更佳。

### UC-17 空项目空态(功能点 §2.4)

- **类型**:运行时(人工)
- **前置**:UC-15 完成;准备一个无任何文件夹的新项目(或用无可见夹权限的账号看已有项目)。
- **操作**:进入空项目详情页,观察左栏;随后点空态「+ 新建文件夹」建第一个夹,观察切换;再删除该夹回到空态(如权限允许)。
- **预期**:空态完整渲染(项目名 +「还没有文件夹」+ 新建文件夹按钮),布局不破;左栏与页面**无异常滚动条**、无多余空白;建夹后正常切到树视图,删空后正常回空态。
- **证据采集**:空态截图 + 建夹后截图。

### UC-18 窄窗口(<1024)Drawer 与三弹窗逐像素零变化(功能点 §2.6)

- **类型**:运行时(人工,与基线对照)
- **前置**:UC-15 完成;建议留存一份**改造前基线构建**(基线 commit `git worktree` 或 `git stash` 前产物)截图作对照;DevTools 设备模拟或直接拖窄浏览器。
- **操作**:
  1. 窗口宽 **<1024**(建议 375×812 与 900×700 各测一轮):项目详情页切为 compact 分支,开左树 Drawer(宽 `min(320px, 84vw)`);滚动 Drawer 内树——预期头部**随内容整体滚走**(与基线一致,Drawer 内**不**固定头部;若出现固定头部即 FAIL,属超范围副作用)。
  2. Drawer 内选中夹 → Drawer 关闭并定位中栏列表,行为不变;Drawer body 滚动条样式与基线一致。
  3. 三弹窗(桌面与窄屏各看一眼):「移动到」(MoveFolderModal,树区 maxHeight 300 内滚)、「批量移动」(BatchMoveAssetsModal,maxHeight 320)、「百度网盘新建任务」(BaiduNewTaskModal,maxHeight 300)——树滚动、选中、视觉与基线一致,无 fillHeight 生效迹象(头部未固定、无 height:100% 撑裂)。
- **预期**:四处默认路径场景(1 Drawer + 3 弹窗)滚动与视觉**逐像素零变化**。
- **证据采集**:窄屏 Drawer 滚动中截图(改造前/后各 1 张并排)、三弹窗截图;如有条件用像素对比工具(如 Chrome DevTools「capture full size screenshot」前后叠加)。

### UC-19 中栏表格与三栏结构不回归(功能点 §2.7)

- **类型**:运行时(人工)
- **前置**:UC-15 完成;桌面宽窗口(≥1024),项目内有文件数据。
- **操作**:
  1. 滚动中栏 AssetTable:预期仅表格区滚动;顶部 folder header + actions bar **不**随滚走(#134 既有行为);右栏 AssetSummaryPanel 不滚、不闪动;左侧 Sider(含固定头部)完全不动。
  2. 检查页面整体:body 无新增滚动条,三栏 Layout 固高(`calc(100vh - 56px - 32px - 80px)`)、圆角阴影、左 260px 宽度与右分隔线与基线一致。
  3. 左树滚动与中栏表格滚动**互不影响**(各滚各的,无联动、无抢滚动)。
- **预期**:中栏/右栏/整体结构与基线完全一致,唯一可见变化 = 左栏头部固定。
- **证据采集**:中栏滚动中截图;三栏整体截图与基线对比。

### UC-20 交互运行时冒烟(功能点 §2.5,头部固定后的行为复核)

- **类型**:运行时(人工)
- **前置**:UC-15 完成;项目含 ≥2 层文件夹、普通夹与 sensitive 夹(锁标)混合,账号具 `my_can_admin`(菜单)+ `my_can_upload`(新建按钮+拖拽);此用例与 UC-08~10 代码核查互为印证。
- **操作**(逐项):
  1. **选中**:点击树节点 → 高亮 + 中栏列表切到该夹;未选状态(点项目名/清除)时「+子」按钮消失。
  2. **展开**:树 <30 顶层夹时默认全展开(defaultExpandAll);含 activeFolderId 进入页面时祖先链自动展开(defaultExpandedKeys);手动收起/展开再滚动树,展开状态稳定。
  3. **新建子**:选中某夹 → 点「+子」→ 弹新建框 → 创建 → 新夹出现在该夹下且树区滚动位置不重置错乱(新夹不可见时滚到可见)。
  4. **新建一级**:头部「+」→ 创建根夹正常。
  5. **拖拽换父(allowDrop 三句式)**:a) 普通夹拖入另一普通夹 → 弹确认 → 移动成功;b) 拖 sensitive 夹(源)→ 无放入响应/被拒;c) 拖普通夹到 sensitive 夹及其子树 → 被拒;d) 拖夹到自身后代 → 被拒;e) gap 落点(同层)按现有语义放行。
  6. **节点 ⋯ 菜单**:hover 节点 → 点「⋯」→ 重命名/移动到两项可用且各自弹窗正常;selectMode 场景(备份目标选择)无菜单、行为不变。
  7. 每项交互在**滚动到树中部**(头部已固定状态)下重复一次,确认固定头部不遮挡右键/hover 菜单与 Tooltip。
- **预期**:全部与基线行为一致,零回归。
- **证据采集**:每子项 1 张截图(拖拽拒绝场景录屏或截图);异常项记 BUG 单。

---

## 用例 ↔ 需求功能点映射(验收对照表)

| 需求条目 | 覆盖用例 |
|---|---|
| §8.1 默认关闭路径 + 四使用方 | UC-01、UC-02、UC-03 |
| §8.2 fillHeight 三要素 + 空态 | UC-04、UC-05、UC-06 |
| §8.3 Sider overflow hidden + 高度传导 | UC-07 |
| §8.4 lint / build | UC-11、UC-12 |
| §8.5 diff 越界 | UC-13、UC-14 |
| §8.6 运行时冒烟 | UC-15 ~ UC-20 |
| §2.1 头部固定 | UC-16a |
| §2.2 树区滚动条/无多余空白 | UC-16c、UC-16d |
| §2.3 分隔线 + 不透明 | UC-06、UC-16b |
| §2.4 空态 | UC-05、UC-17 |
| §2.5 交互不回归 | UC-08、UC-09、UC-10(代码)+ UC-20(运行时) |
| §2.6 compact/弹窗零变化 | UC-03、UC-18 |
| §2.7 中栏/右栏/整体不变 | UC-19 |
| §3.3 不许碰的边界 | UC-13(反断言)+ UC-08(逻辑层) |
| §3.4 行数红线 | UC-14 |

## 执行顺序建议

1. 合入后先跑 **UC-13**(越界)→ 不满足直接打回,后续免做;
2. **UC-01 ~ UC-10、UC-14**(代码核查,静态)→ **UC-11、UC-12**(构建);
3. 构建产物出来后执行 **UC-15**(启动)→ **UC-16 ~ UC-20**(人工冒烟,预计 30~45 分钟);
4. 汇总判定:全部 PASS = 验收通过;UC-14 参考线(≤400)越线但红线(≤500)内、UC-07 存在最小补丁,均需在报告中说明后由 PM 裁量。
