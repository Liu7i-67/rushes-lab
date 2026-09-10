# 移动端显示适配实施方案（v3.1 · 已定稿）

> 状态：**终审通过（第 3 轮双视角审查均 APPROVE），可开工**。
> 目标：全站从 PC-only 到"移动端可用、平板竖屏可用、PC 零回归"。
> 核心思想：尽可能共用同一页面与路由，CSS 层适配为主；只有布局骨架级差异才用
> JS 按屏幕宽度切换；不用 UA 嗅探做布局（UA 仅一处功能性降级使用，见 §3.6）。
>
> **v3 修订记录**（相对 v2，依据第 2 轮复审）：
> ①JS 断点统一为单一 `useCompactViewport()`(<1024)：壳层跟随工作区，
> 消除 iPad 竖屏"PC 顶栏 + 无 TabBar"割裂态（v2 壳层仍 <768 是错的）；
> ②§3.5 下载链路补后端 presign `ResponseContentDisposition`（否则 jpg/mp4/pdf
> 内联打开而非下载、SPA 被顶掉），前端直连改 `target=_blank` + 任务记录 + toast，
> 移动端批量栏不放"下载"（浏览器拦截多下载）；③键盘隐藏清单去掉 Drawer
> （自败），Drawer 改收缩 + 加非键盘 resize 守卫；④详情 Drawer 加 `‹ n/N ›`
> 切换；⑤`--ms-tabbar-h` 单一常量、批量栏出现时列表补 padding；
> ⑥移动端顶栏收掉 Bell（通知 tab 唯一正门）。
>
> v2 修订记录：工作区断点 md→lg；下载改系统下载器直连；资产卡片 tap=open +
> checkbox 多选；TabBar 构成调整；触控规则限定 `pointer:coarse and hover:none`
> + `.ms-ghost-btn`；Grid.useBreakpoint 首帧行为修正 + hooks 置顶硬约定；
> isIOS 正则修 iPadOS 13+；z 阶梯与键盘交互；PR1 拆分；验收补 iPad/大文件/内网。

## 0. 现状调研结论

### 0.1 技术事实（已经代码核实）

- React 19 + antd 6.4.2 + react-router 7 + Vite，CSR（无 SSR）。
- 样式形态：**全站 inline style**（`style={{...}}`）+ `styles/tokens.css` 设计令牌；
  无 CSS 框架、无 CSS Modules。
- `index.html` 已有 viewport meta（无 `viewport-fit=cover`）。
- **src 内视口类 `@media` 为 0 处**（唯一 `@media` 是暗色模式 `prefers-color-scheme`）。
  唯一的 JS 响应式是 `ProjectDetailPage.tsx:43` 的 `Grid.useBreakpoint()`
  （`isMobile = !screens.md`），mobile 分支是半成品（文件夹选择 Modal
  `open={false /* 留 hamburger 触发,iter2 */}`）。
- antd 6 实测行为（已查 node_modules 源码确认）：
  - **Modal** 宽度自动钳制：`maxWidth: calc(100vw - 32px)`，≤767px 时
    `calc(100vw - 16px)` —— 固定 px 宽的 Modal 不会硬溢出，只会内容变挤；
  - **Drawer 无视口钳制** —— `ProjectMembersDrawer.tsx:144` 的 `width={480}`
    在 375px 屏上右侧约 105px 被裁切且无法滚动看到，是**唯一一处 Drawer 硬伤**；
  - **`Grid.useBreakpoint` 首帧**：实现是 `useRef({})` + `useLayoutEffect` 内
    subscribe + forceUpdate —— **首个 render pass 返回空对象**（此时
    `!screens.md` 为 true，即首过判为 mobile），subscribe 同步 dispatch 后在
    paint 前强制重渲染，故"无可见闪烁"结论成立，但"首帧即有值"不成立，
    由此引出 §2.1 的 hooks 置顶硬约定。
- **下载链路**（`lib/download-store.tsx` `start()`）只有两条路：
  File System Access API（仅桌面 Chromium 支持）或 fetch 全量读进内存 chunks →
  `new Blob()` → blobUrl `a.click()`。移动端只能走后者 —— GB 级原片会把移动
  Safari 单 tab 顶爆直接崩页。
- **presign 无附件语义**：`api/app/services/presign.py` `sign_get_url()` Params
  只有 `Bucket/Key`，全仓库无一处 `ResponseContentDisposition`；对象以真实
  content-type（`video/mp4`、`image/jpeg`…）存储。直接导航 presigned URL 时，
  可渲染类型（图片/视频/PDF——素材库主体）会被浏览器**内联打开而非下载**。
- Uppy Dashboard 自带响应式，无需处理。

### 0.2 页面布局形态盘点（15 路由 + 全局组件）

| 形态 | 页面 | 窄屏现状 | 结论 |
| --- | --- | --- | --- |
| A. 流体纵向列表/表单 | SearchPage、NotificationsPage、LoginPage、ChangePasswordPage、ShareLandingPage、RequestLinkLandingPage | maxWidth 流体 + 纵向排布 | 天然自适应，微调 padding 即可 |
| B. flex/网格卡片行 | ProjectsPage（卡片网格 `auto-fill minmax(320px,1fr)`，窄屏自动单列）、ApprovalsPage、MyPermissionsPage、AdminUsersPage、AdminGroupsPage、AdminAuditPage | 部分行内"文本+日期+按钮"单行不换行、Segmented 固定 4 选项 | 需逐页微调（wrap / 换行 / 控件替换） |
| C. 复杂工作区 | ProjectDetailPage 三栏 workspace（FolderTree 260 + Table + SummaryPanel 320）、AppHeader 横条、各 Drawer/Modal | 三栏挤压、Header 溢出、Table 横滚 | **必须做布局级切换** |

### 0.3 高危问题清单（行号已核实）

| # | 位置 | 问题 | 严重度 |
| --- | --- | --- | --- |
| H1 | `AppHeader.tsx` | 6 个 nav chip + `minWidth:220` 搜索框 + 3 个 icon + 头像，375px 必然溢出（PC 顶栏约需 880px 宽，iPad 竖屏全系 768-834 同样放不下） | 高 |
| H2 | `ProjectDetailPage.tsx:492` 资产 Table | `scroll.x=600` + 行点击选中交互，375px 下横向滚动 + 列挤 | 高 |
| H3 | `ProjectMembersDrawer.tsx:144` | `width={480}` 固定 px，Drawer 无钳制，窄屏内容被裁 | 高 |
| H4 | `MyPermissionsPage.tsx:169` / `TaskCenterDrawer.tsx:126` | Segmented 4 个长标签选项（带计数）单行不换行，360-375px 溢出 | 高 |
| H5 | `AdminUsersPage.tsx:152` / `AdminGroupsPage.tsx:115` | 行内"信息(flex1) + 日期(nowrap) + 2-3 个 small 按钮"，360px 下信息列只剩几十 px | 高 |
| H6 | `ApprovalsPage.tsx:79` | `gridTemplateColumns:'1fr auto'` 不换行，操作列固定，左列被压扁 | 高 |
| H7 | `AdminAuditPage.tsx:145` | `RangePicker showTime` 双月+时间面板手机不可用；UserPicker 固定 `width:280` | 高 |
| H8 | `ProjectDetailPage.tsx:316` | `height: calc(100vh - 56px - 32px - 80px)` 内滚模式 + iOS 动态地址栏，移动端体验差 | 中 |
| H9 | `lib/download-store.tsx start()` | 移动端唯一可用路径是 fetch→Blob 全量内存，GB 级原片必崩 | 高 |
| H10 | presign 无 `Content-Disposition`（§0.1） | 移动端"下载"可渲染素材 = 内联打开而非落盘 | 高（v3 新增） |
| M1-M8 | AppBreadcrumb 无折叠、FolderTree 新建按钮 24px、AssetTagEditor 确认按钮 22px、UserMenu 复制按钮 22px、SearchPage 三段 meta 行、UploadFloatingIndicator 无 safe-area、AssetPreviewModal 72vh + iOS iframe PDF、FolderInvitePanel 双列 Select | 中/低 |

## 1. 总体策略

三原则（对应"共用页面、CSS 适配为主、必要时单独适配"）：

1. **共用页面、共用路由**：不做 m 站、不复制路由树、不按 UA 出两套组件树。
   所有适配在**同一组件内**完成；新增的只有共享子组件（`AssetCardList`、
   `MobileTabBar`、移动端壳层分支）。
2. **CSS 优先**：间距、字号、换行、安全区、触控目标、hover 降级——能用 media
   query 解决的一律不上 JS。
3. **JS 只管骨架级切换**：**唯一** JS 判定源 `useCompactViewport()`（§2.1），
   切换的是页面骨架（Header 形态、三栏↔单栏、Table↔卡片列表、控件替换），
   业务逻辑/数据层（react-query hooks、权限门控、上传 store）**零改动**。

### 1.1 断点：JS 单一 <1024 + CSS 精修层 <768（v3 统一）

v2 的"壳层 <768 / 工作区 <1024"双阈值在 iPad 竖屏（768-834）产生割裂混合态：
工作区单栏但 PC 顶栏原样溢出（H1 的 PC 顶栏约需 880px）。因此统一：

| 层 | 阈值 | 管什么 |
| --- | --- | --- |
| JS 骨架切换：`useCompactViewport()` | `<1024`（antd lg） | **全部** JS 级切换：移动壳层（AppHeader 形态/TabBar/AppShell padding）、工作区单栏骨架、B 类控件替换（ApprovalsPage 单列、AdminAudit 单 DatePicker 等） |
| CSS 精修层 | `max-width: 767.98px` | 仅"手机构图"微调：输入 16px 防缩放、面包屑横滚、`.ms-hscroll` 等（平板上不需要这些） |
| CSS 触控层 | `pointer: coarse and hover: none`（与视口正交） | 触控目标地板、hover 降级（iPad 横屏同样受益） |

- 为什么 JS 阈值取 1024 而不是 768：三栏工作区（Sider 260+320）和 PC 顶栏在
  768-1023 物理放不下；A/B 类页面是流体单列，壳层/控件替换提前到 1024 对它们
  无副作用。平板竖屏（768/810/820/834）获得与手机一致的移动壳层。
- iPad 横屏（≥1024）= PC 骨架 + 触控层 CSS。
- 判定源**只有一个 hook、一个模块**，页面禁止自写 breakpoints / innerWidth。

### 1.2 UA 的定位

不参与布局切换（屏幕尺寸已覆盖；resize / 调试 / 平板横竖插拔场景 UA 会误判）。
唯一使用点：PDF 内嵌预览的 iOS 功能性降级（§3.6）。

## 2. 基建（PR1a 先行合入，后续都依赖）

### 2.1 `web/src/lib/use-viewports.ts`（新增，唯一判定源模块）

```ts
import { Grid } from 'antd';

/**
 * 视口判定唯一源。页面禁止自写 Grid.useBreakpoint / innerWidth 判断。
 * <1024（antd lg）切换移动壳层与单栏骨架——iPad 竖屏(768-834)含在内：
 * PC 三栏与 PC 顶栏在该区间物理放不下(见方案 §1.1)。
 * ⚠ antd useBreakpoint 首个 render pass 返回空对象(mobile 分支先渲染)——
 * 硬性约定:消费组件的 hooks 全部置顶调用,mobile/PC 分支只允许切 JSX,
 * 不允许分支内挂不同数量的 hook(桌面端首挂载即崩)。
 */
export function useCompactViewport(): boolean {
  const screens = Grid.useBreakpoint();
  return !screens.lg;
}
```

`ProjectDetailPage.tsx:43-44` 改为调用此 hook（原 md 语义修正为 lg）。

### 2.2 `tokens.css` 增加"移动端层"（集中管理，禁止散落）

```css
:root {
  /* 固定层几何:单一常量来源(TabBar 总高,含内 padding;
     bottom 偏移一律 calc(var(--ms-tabbar-h) + env(safe-area-inset-bottom))) */
  --ms-tabbar-h: 56px;
  /* z 阶梯(antd Drawer/Modal 自带 z 1000+,浮于全部常驻层之上,不冲突) */
  --ms-z-header: 50;     /* 现有 sticky header */
  --ms-z-batchbar: 60;   /* 批量操作栏 */
  --ms-z-tabbar: 70;     /* 底部 TabBar(最上的常驻层) */
  --ms-z-float: 80;      /* UploadFloatingIndicator */
}

/* ── 手机构图精修层:唯一断点 = max-width 767.98px(低于 antd md)──────── */
@media (max-width: 767.98px) {
  /* iOS 聚焦自动放大防护:输入字号 ≥16px(含 DatePicker/AutoComplete 内 input) */
  .ant-input, .ant-select-selection-search-input,
  .ant-picker-input > input, .ant-input-number-input { font-size: 16px !important; }
  /* 长路径面包屑:横向滚动而非撑破布局 */
  .ms-breadcrumb { overflow-x: auto; scrollbar-width: none; flex-wrap: nowrap; }
  /* Segmented 溢出场景:横向滚动 + 右缘渐隐提示"还有更多"
     (已知小瑕疵:无溢出时末项右缘也虚化,先接受;tester 反馈再改溢出检测挂 mask) */
  .ms-hscroll { overflow-x: auto; scrollbar-width: none;
                -webkit-mask-image: linear-gradient(to right, #000 92%, transparent); }
  .ms-hscroll .ant-segmented { white-space: nowrap; }
}

/* ── 触控目标:primary pointer 为触屏且无 hover 才生效
      (不误伤触屏 Windows 笔记本,主 pointer 是鼠标时 pointer:fine)────────── */
@media (pointer: coarse) and (hover: none) {
  /* 旧 small 控件地板:antd 系 */
  .ant-btn-sm { min-height: 34px; }
  .ant-btn-icon-only { min-width: 38px; min-height: 38px; }
  /* 旧自定义 ghost 小按钮(24px/22px 系)统一套此 class 抬到 38 */
  .ms-ghost-btn { min-width: 38px; min-height: 38px; }
  /* hover 反馈在触屏无意义,去掉位移留边框变化 */
  .ms-card-hover:hover { transform: none; }
}

/* ── 安全区 ─────────────────────────────────────────────────────────── */
.ms-safe-bottom { padding-bottom: max(12px, env(safe-area-inset-bottom)); }
```

### 2.3 `index.html`

```html
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover" />
<meta name="theme-color" content="#FAFAF7" />
```

（`interactive-widget=resizes-content` 仅 Android Chrome 108+ 生效、iOS 无效，
收益有限，**不加**；iOS 键盘问题走 §3.1 的 visualViewport 方案。）

### 2.4 AppShell（`App.tsx`）

- `main` 的 padding 由 `useCompactViewport()` 切换：PC `32px 24px 80px` →
  compact `16px 12px calc(var(--ms-tabbar-h) + env(safe-area-inset-bottom) + 32px)`
  （TabBar 实际占位 = 56px + 安全区 inset，预留必须含 inset，否则末端 2-4px
  被盖；32px 是内容与 TabBar 的呼吸位）。
- `PersistentUploadDrawer` / `TaskCenterDrawer` 不动（已响应式）。

### 2.5 AppHeader + MobileTabBar

**顶栏（56px 不变，compact 分支）**：logo（只留几何方块；可选优化：仅首页
显示 wordmark，做不做均可）+ 右侧图标组：**任务收件箱、头像 UserMenu**。
**不渲染**：nav chips、⌘K 文本框、CommandPalette 触发器（Palette 是键盘优先的
PC 形态，触屏走 TabBar"搜索"tab 进 `/search` 页，一屏不出现两个搜索入口；
CommandPalette 保留 PC 专属，`⌘K` 快捷键不变）、**通知 Bell（v3 收掉——
通知 tab 是唯一正门，30s 未读轮询的 badge 挂在 TabBar"通知"上，避免双入口
双 badge 让 tester 困惑）**。

**新增 `components/MobileTabBar.tsx`**（fixed bottom，`z: var(--ms-z-tabbar)`，
仅 compact 渲染，`padding-bottom: env(safe-area-inset-bottom)`，总高
`var(--ms-tabbar-h)`）：

| tab | 去向 | 说明 |
| --- | --- | --- |
| 项目 | `/` | `/projects/*`、`/folders/*` 都归属此 tab 高亮 |
| 搜索 | `/search` | 盲搜是产品重心，黄金位 |
| 审批 | `/approvals` | 手机上顺手的微任务（收到通知→批准） |
| 通知 | `/notifications` | 未读 badge——AppHeader 保留 `useNotificationsUnread`（PC Bell 需要），MobileTabBar 对**同一 query key 另挂 observer**（react-query 共享缓存，无双重轮询），**不拆 AppHeader 的 hook** |
| 更多 | bottom Drawer | 我的权限、审计、用户管理、用户组管理（后三者仅 `is_system_admin` 可见；非 admin 不出现 403 死链） |

- active 态：`useLocation()` 派生，映射表写死在组件内：
  `/` + `/projects/*` + `/folders/*` → 项目；`/search` → 搜索；`/approvals` → 审批；
  `/notifications` → 通知；其余（admin/my-permissions）→ 不高亮（"更多"打开时
  高亮"更多"）。（不复用 NavChip 的 `pathname.includes` 写法。）
- "更多" bottom Drawer 规格：`placement="bottom"`、`height: auto`（内容撑开，
  max-height 60vh）、顶部 36×4 grip 条、点遮罩/条目关闭，不做拖拽手势。
- **PC 零回归红线**：PC 顶栏渲染逻辑一行不动（PC 端"审计 chip 对非 admin 可见
  但点击 403"是既有 wart，本次不修，避免超出移动端范围的 PC 行为变化）。

## 3. 逐页动作表

### 3.1 P0 — ProjectDetailPage（核心工作区）

`useCompactViewport()` 时单栏骨架，替代三栏：

| 现三栏元素 | compact 去处 |
| --- | --- |
| 左栏 FolderTree(260) | **左滑 Drawer**（`min(320px, 84vw)`），触发按钮在 folder header 最左（hamburger icon + 当前 folder 名 + chevron-down） |
| 中栏 folder header / actions bar | 保留单列；actions bar 允许 wrap；"刷新"收进 wrap 第二行 |
| 资产 Table | **新组件 `AssetCardList`**（交互见下） |
| 右栏 AssetSummaryPanel(320) | 不设独立"详情"入口——单文件内容经卡片 tap 打开；folder 级管理面板经 header"管理"按钮 |

**AssetCardList 交互模型（tap=open，checkbox 多选）**：

- 每卡：左侧 checkbox（44px 命中区）+ `AssetThumbnail` 44px + 文件名
  （两行省略）+ 副行（size · 日期）+ 标签独立第三行（flexWrap，封顶 3 个 +
  "+N"）+ 行尾下载 icon 按钮（44px 命中区，`stopPropagation`）。
- **点卡片主体 → 单文件详情 bottom Drawer**（`height: min(72vh, 72dvh)`）：
  内容 = AssetSummaryPanel 单选态原样复用（预览 / 下载 / 分享 / 打标 / 元信息）；
  **Drawer 头部加 `‹ 3/12 ›` 行内切换**（state 存当前页 `assetItems` 的 index
  而非 id；切张只换内容，Drawer 常驻——"批量过图选片"是素材管理真实工作方式，
  不做原生滑动 pager，留下轮）。预览 Modal 在 Drawer 内叠层：两者同为 antd
  z 1000，靠 DOM 挂载顺序后者在上——**实现时不要改 `getContainer`**。
- 批量操作：checkbox 勾选 ≥1 时底部浮出**批量操作栏**（sticky，
  `bottom = calc(var(--ms-tabbar-h) + env(safe-area-inset-bottom))`，
  `z: var(--ms-z-batchbar)`）：已选 N · 打标 / 删除 / 清空选择。
  **移动端批量栏不放"下载"**：iOS/Android 只放行首个自动下载、后续静默拦截，
  批量下载在移动端不可靠——勾选仅服务打标/删除，下载走每卡行内按钮
  （§6 清单注明，防 tester 误报）。PC 批量下载不变。
  勾选态下**列表容器追加批量栏高度的 padding-bottom**，避免末端卡片/分页器
  被"批量栏 + TabBar"双层盖住。
- **排序降级（显式声明）**：PC Table 的 size/created_at sorter 是纯客户端、
  只作用于当前页（`useAssets` 无排序参数），卡片列表**不做排序**，此为接受的
  降级而非遗漏。
- folder 级管理面板（0 选中态的 FolderInvitePanel / FolderGrantsPanel）：
  folder header 在 `my_can_admin` 时显示"管理"按钮 → bottom Drawer 内渲染
  AssetSummaryPanel 空选态（其内部本来就按 `selected===0` 条件渲染这两个面板，
  原样复用，不新写 UI）。
- **滚动模型**：compact 分支**放弃** `height: calc(100vh-…)` 内滚 +
  `overflow:hidden`（H8），改**自然文档流滚动**；外层 Layout 固定高、
  `borderRadius`、`boxShadow` 仅 PC 分支保留；分页器为文档流普通块。
- **全选语义**：actions bar 的全选 Checkbox 保留（作用于当前页，语义与 PC 一致）；
  它与卡片 checkbox 共用同一 `selectedIds` state。
- **键盘交互**：`focusin` + `visualViewport.resize`（键盘弹起）时只隐藏
  **TabBar / 批量操作栏 / UploadFloatingIndicator**（详情 Drawer **不在隐藏
  清单**——它内部就有打标输入框，隐藏聚焦者所在容器是自败；Drawer 改为键盘期
  `height: visualViewport.height - 顶栏` 收缩）。resize 守卫：仅当存在聚焦的
  输入类元素（`activeElement` 为 input/textarea/contenteditable）时才视为键盘，
  捏合缩放触发的 resize 忽略。键盘收起恢复。封装为一个共享小 hook，PR2 实现。

### 3.2 P0 — FolderDetailPage（盲搜实际落点，规格显式化）

`/folders/:id` 是 SearchPage 与 CommandPalette 盲搜命中的跳转目标，属于核心流：

- 上传按钮区、List → 复用 `AssetCardList`（**不带 checkbox**——该页无批量操作，
  选中 props 设为可选；tap=open 详情 Drawer 同 3.1，含 `‹ n/N ›` 切换）；
- 分页器保持现有钉底实现（该页分页器本来就是 `position: sticky, bottom: 0`）；
- `AssetCardList` props 设计：`assets / onOpen / selectable? / selectedIds? /
  onToggle?`，两页共用一套渲染。

### 3.3 P1 — B 类页面微调（compact = <1024 生效，与 §1.1 一致）

| 页面 | 动作 | 量级 |
| --- | --- | --- |
| `MyPermissionsPage` | Segmented 外包 `.ms-hscroll`（横滚 + 渐隐提示，不换控件、保留计数） | 小 |
| `TaskCenterDrawer` | 同上；`文件名 maxWidth:280` → `maxWidth:'60%'` | 小 |
| `ApprovalsPage` | compact 下 `'1fr auto'` → 单列（操作按钮组换行到卡片底部，按钮抬到常规尺寸）；padding 收敛 `'14px 16px'` | 小 |
| `AdminUsersPage` | 行容器 `flexWrap:'wrap'`，日期 compact 下 `flexBasis:'100%'` 换行；搜索框/Select 固定宽 → `flex:1, minWidth:0` | 小 |
| `AdminGroupsPage` | 同 UsersPage；成员 Modal `width={560}` → `min(560px, calc(100vw - 16px))` | 小 |
| `AdminAuditPage` | compact 下 RangePicker → 单个 `DatePicker`（去 showTime，文案注明"按日期筛选"）+ UserPicker 改 `flex:1, minWidth:0` + EventRow 加 wrap。**注：这是带分支的中等改动，非一行** | 中 |
| `SearchPage` | 结果行三段 meta：compact 下 folder/project 信息换行到文件名下方；Enter kbd 不渲染 | 小 |
| `ProjectMembersDrawer` | `width={480}` → `min(480px, 100vw)`（H3 一行修复，放 PR1a） | 一行 |
| `AppBreadcrumb` | 容器加 `.ms-breadcrumb`（横滚 + 末项完整显示） | 小 |
| `ProjectDetailPage` 桌面态 | 不动（PC 零回归红线） | - |

管理后台页（Users/Groups/Audit）是低频系统 admin 场景，投入止步于"可用"级，
不在手机上追求管理效率——有意为之的投入产出判断。

### 3.4 P2 — 触控目标与细节

- 新组件直接按 **44px** 命中区设计：AssetCardList 行内下载按钮、批量操作栏按钮、
  MobileTabBar（`--ms-tabbar-h: 56px`）；TabBar "更多"内条目高度 ≥44px。
- 旧控件经 §2.2 CSS 地板抬到 34-38px；三个自定义 ghost 按钮
  （`FolderTree.tsx:224` / `UserMenu.tsx:70` / `AssetTagEditor.tsx:70`）**改 JSX
  统一套 `.ms-ghost-btn` class**（纯 CSS 打不中自定义 button）。
- `UploadFloatingIndicator`：
  `bottom = calc(var(--ms-tabbar-h) + env(safe-area-inset-bottom))`；批量操作栏
  可见时再叠加批量栏高度。
- `AssetPreviewModal`：`72vh/68vh/65vh` → `min(72vh, 72dvh)` 系列；工具栏按钮
  compact 加大。
- **分享动线（核心场景）**：tap=open 详情 Drawer 后，分享 = 点卡片 → 点"分享"
  两步。ShareModal 移动端增强：①结果态把 Input.Group 换成全宽"复制链接"大按钮；
  ②可用时优先 `navigator.share()`（拉起系统/微信转发面板）；③剪贴板兜底：
  `navigator.clipboard` 仅 HTTPS 可用（现状 ShareModal 只用
  `navigator.clipboard`，`ShareModal.tsx:62`），**内网生产若走 HTTP** 需
  `execCommand('copy')` 兜底（§6 真机清单含内网环境验证项）。
- Login / ChangePassword / ShareLanding / RequestLink：`margin/padding` 微调
  （64px 纵向 margin → 24px；Hero padding 收敛），CSS 优先。
- FolderInvitePanel 双列 Select：grid 模板 `repeat(2, minmax(0, 1fr))` +
  外层允许 wrap，Modal 钳制后自动单列，无需 JS。
- 触屏"粘住 hover"（inline `onMouseEnter` 在 iOS tap 时先触发，导航后颜色卡住）：
  **接受降级**不改（组件量大、影响仅视觉残留），真机回归若 tester 反馈再统一处理。

### 3.5 P0 — 移动端下载直连系统下载器（v3 重写）

**后端（唯一豁免项，约 10 行）**：`PresignService.sign_get_url()` 增加可选
`response_content_disposition` 参数透传进 presign Params；
`POST /assets/{id}/download-link` 增加可选请求参数 `as_attachment: bool = False`
（**默认 False，预览路径零变化**——预览弹窗复用同一端点的 URL，无条件加
attachment 会破坏桌面 PDF iframe 预览）：为 true 时签

```
Content-Disposition: attachment; filename="<ASCII 兜底>"; filename*=UTF-8''<RFC 5987 百分号编码>
```

（中文文件名必须 RFC 5987；`DownloadLinkOut` 响应结构不变——这是签名参数，
不是 API 契约变化。`share.py` 的分享下载签发同改。审计逻辑不动。）

**前端**（`download-store.tsx start()`）：无 File System Access API 时
（即移动端）→ 请求 `as_attachment=true` 的链接后直连系统下载器：

```ts
if (!('showSaveFilePicker' in window)) {
  const link = await dlLink(assetId, /* as_attachment */ true);
  // ↑ useDownloadLink 需加可选 as_attachment 参数(hooks.ts 小改,DownloadLinkOut 不变)
  const a = document.createElement('a');
  a.href = link.url;
  a.target = '_blank';           // 防御:attachment 失效时不顶掉 SPA
  a.rel = 'noopener';
  document.body.appendChild(a); a.click(); a.remove();
  // 仍登记一条立即完成的任务记录(文件名 + "已交给系统下载")并 toast 提示,
  // 保持 start(): Promise<string> 契约(调用方/任务中心依赖 task id);
  // 直连路径无 blob,原 blobUrl 清理逻辑对该路径自然不触发,勿引用
  return newTaskId;
}
```

（`target='_blank'` 的已知副作用：attachment 生效时 iOS Safari 会在标签切换器
留一个空白 tab；attachment 响应本身不发生导航，真机回归确认后可去掉 target。）

- attachment 头 + 附件响应使浏览器直接进下载（iOS 存"文件"、Android 进下载
  管理），不离开页面、无 JS 内存占用、系统下载器自带断点；
- fetch→Blob 路径**删除**（移动端崩页元凶；小文件系统下载器体验也更好）；
- 应用内任务中心 / 进度 / 取消仅保留 FSA 路径（桌面）。

### 3.6 功能性降级（唯一 UA 使用点）

`AssetPreviewModal` 的 PDF iframe：iOS（含 iPadOS 13+ 桌面 UA）替换为提示卡
（"iOS 内嵌预览受限，点击下载后用系统预览打开" + 下载按钮）。图片/视频预览
不受影响。

`lib/ua.ts`（新增）：

```ts
export function isIOS(): boolean {
  const ua = navigator.userAgent;
  return /iP(hone|od)/.test(ua)
    || (/Mac/.test(ua) && navigator.maxTouchPoints > 1);  // iPadOS 13+ 伪装 Mac UA
}
```

## 4. 明确不做（scope 边界）

- 不做独立 m 站 / 独立移动路由树 / UA 快照出两套页面。
- 不做 PWA、离线、推送、下拉刷新（回上一夹/刷新走现有按钮，§6 清单注明防
  tester 误报）。
- 平板（768-1023）**复用移动壳层与单栏骨架**（<1024 统一判定），不做平板专属
  布局/双栏 App 形态；iPad 横屏（≥1024）= PC 骨架 + 触控层。
- **后端改动仅限一处豁免**：§3.5 的 presign `ResponseContentDisposition` +
  download-link `as_attachment` 可选参数（签名参数，接口契约不变）。
  除此之外不改后端。
- 不动暗色模式、不动设计令牌体系（新增的只有"移动端层" media query、
  `--ms-tabbar-h`/z 阶梯变量）。
- 不重构 inline style 为 CSS Modules / styled-components（遵循现状，控制 diff）。
- 不修 PC 端既有 wart（如审计 chip 对非 admin 可见），保持 PC 零回归红线。
- 不做原生滑动式图片 pager（微信图片式）——动共享 AssetPreviewModal、触 PC
  红线，留下轮。

## 5. 风险与对策

| 风险 | 对策 |
| --- | --- |
| PC 端回归 | 红线：所有 JS 分支以唯一判定 hook 收敛，PC 分支 diff 为零；验收含 1440/1920 截图对比 |
| `useBreakpoint` 首个 render pass 返回空对象（mobile 分支先渲染） | §2.1 硬约定：hooks 全部置顶、分支只切 JSX 不挂不同数量的 hook；paint 前完成二次渲染，无可见闪烁 |
| inline style 与 media query 混用失控 | media query 只进 tokens.css 移动层；组件内只允许唯一判定 hook 的条件表达式 |
| iOS 键盘顶起 fixed 层 | §3.1：只隐藏 TabBar/批量栏/浮窗；Drawer 收缩 + 非键盘 resize 守卫；真机清单专项 |
| iOS `100vh` / 动态地址栏 | compact 分支弃用固定高内滚；预览 Modal 与详情 Drawer 用 dvh |
| 浏览器拦截连续多次自动下载（批量下载） | 移动端批量栏不放"下载"（§3.1），下载逐个走行内按钮；§6 注明防误报 |
| Modal 钳制后内容二次溢出（Segmented/双列 grid） | 逐 Modal 手测清单（§6）；`minmax(0,1fr)` 兜底 |
| 触屏 Tooltip 不可达（antd hover 触发） | 接受降级：关键操作都有可见文字/图标语义；不引入触屏长按 |
| 触屏"粘住 hover"视觉残留 | 接受降级（§3.4），tester 反馈再统一处理 |
| 触屏 Windows 笔记本被 coarse 规则误伤 | 规则限定 `pointer: coarse and hover: none`（主 pointer 为鼠标时不触发） |
| 大文件下载 | §3.5 系统下载器直连；验收含 >500MB 文件真机项 |
| 内网 HTTP 下剪贴板 API 不可用 | §3.4 execCommand 兜底；验收含内网环境项 |
| 无真机开发环境 | Chrome DevTools 设备仿真（375×667 / 390×844 / 768×1024）日常用；server2 部署后 tester 真机回归 |

## 6. 验收标准

1. **375×667 与 768×1024（iPad 竖屏）均无横向页面滚动**，无裁切/重叠；
   两尺寸下均为移动壳层（TabBar）+ 单栏工作区；另做 1024 宽度点抽查
   （iPad 横屏临界，中栏 396-472px，Table 允许保留表内横滚——与现状等同）。
2. 核心流真机全通：登录 → 项目列表 → 进项目 → 切文件夹 → 盲搜 → **看素材
   （tap=open 详情 → 预览，含 `‹ n/N ›` 切张）** → 下载（**jpg 与 mp4 各一个
   真正落盘**到"文件"/下载管理 + **>500MB 大文件一个**）→ 上传 → 打标 →
   **分享（含 navigator.share 与复制链接）** → 审批 → 通知。
3. 移动端批量行为符合 §3.1 设计：批量栏无"下载"按钮（逐个下载），勾选服务
   打标/删除——验收按此口径，防 tester 误报。
4. 触控目标：新组件 ≥44px、旧控件地板 ≥38px（`pointer:coarse and hover:none`
   下）；表单聚焦不触发 iOS 缩放（含 DatePicker）。
5. 键盘弹起不遮挡输入框；TabBar/批量栏/浮窗正确隐藏恢复；详情 Drawer 键盘期
   收缩可继续打标。
6. **内网生产环境**：HTTP 下分享链接复制可用（execCommand 兜底生效）；
   附件下载头生效（jpg/mp4 落盘而非内联打开）。
7. PC 1440 / 1920 逐页截图对比零回归；预览弹窗（图片/PDF/视频）桌面行为不变。
8. 每页过 §3 动作表对应检查项（checklist 附 PR 描述）。

## 7. 实施切分（PR 序列）

| PR | 内容 | 依赖 |
| --- | --- | --- |
| PR1a | 纯基建：use-viewports 模块 + tokens.css 移动层/常量/z 阶梯 + index.html + AppShell padding + ProjectMembersDrawer 宽度一行修复 + `.ms-ghost-btn` 套用 | - |
| PR1b | 移动壳层：AppHeader compact 分支（收 nav chips/Palette/Bell）+ MobileTabBar + "更多"Drawer + 未读 badge 挂 tab | PR1a |
| PR2 | 工作区：ProjectDetailPage compact 单栏（Drawer 树 + AssetCardList tap=open + `‹ n/N ›` 切张 + 批量栏 + 管理入口 + visualViewport hook）+ FolderDetailPage 复用 + §3.5 下载直连（含后端 presign 豁免，约 10 行，单独 commit 便于回滚）+ ShareModal 移动端增强 | PR1a |
| PR3 | B 类页面微调批量（§3.3 全表；AdminAuditPage 为中等改动单独提交） | PR1a |
| PR4 | 打磨：预览 dvh + UA/iOS PDF 降级 + Landing 页 padding + 真机回归清单执行（部署 server2 时用 `MAINTENANCE_ISSUES` modal 告知 tester 本轮移动端回归范围与"请用手机访问"提示；checklist 附 PR 描述） | PR1-3 |

每个 PR 合入后按 `AGENTS.md` 约定追加 `scripts/changelog.md` 当日条目。
