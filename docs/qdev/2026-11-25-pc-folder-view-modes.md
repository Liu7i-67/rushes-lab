# PC 文件夹文件列表三视图切换（详情/小图瀑布流/大图瀑布流）

- 需求来源：用户 `/qdev` 指令（2026-11-25）
- 分支/worktree：`feat/pc-folder-view-modes` @ `E:/qbb/github_not_me/rushes-lab-feat-pc-view-modes`（自 liuqi cb30b94 切出）
- 方案出处：本文档；子智能体一律以本文档为唯一需求依据
- web 前端路径：`material-storage/web`（下文相对路径均以 `material-storage/web/src` 为基准）；worktree 内 web/node_modules 已 junction 到主仓，依赖与命令均在 worktree 的 `material-storage/web` 下用 pnpm 跑

## 1. 背景与目标

PC 端浏览文件夹的文件列表当前只有一种「小缩略图 + 详情信息」形态，看图挑片效率低。本次为文件夹文件列表增加三种视图模式：

- **详情**：保持现状不动；
- **小图**：瀑布流，5 列等宽，瓦片高度按图片纵横比自适应，用 240px 规格（size=small）封面图；
- **大图**：瀑布流，2 列等宽，瓦片高度按图片纵横比自适应，用 1024px 规格（size=large）封面图。

切换结果持久化在浏览器 localStorage。**纯前端改动，零后端工作量。**

## 2. 功能点明细（逐条可验收）

1. 两个 PC 入口均可切换视图：`/folders/:id` 独立文件夹页（FolderDetailPage）与 `/projects/:projectId/folders/:folderId` 项目详情页 PC 三栏中栏（ProjectDetailPage 桌面分支）。
2. 切换控件为 antd `Segmented`，三档：详情 / 小图 / 大图；切换即时生效，无需刷新。
3. 详情模式渲染与改造前**完全一致**（回归红线）。
4. 小图模式：5 列等宽网格，瓦片高度 = 列宽 × 图片纵横比（数据源 `asset.tags.thumbnail_width/height`）；缩略图请求 `thumbnail-url?size=small`（240px）。
5. 大图模式：2 列等宽网格，其余同上；缩略图请求 `thumbnail-url?size=large`（1024px）。
6. 刷新页面 / 新开标签后保持上次选择的模式；无缓存或缓存值非法时回落详情模式。
7. 瓦片点击行为与所在页面既有点击语义一致：独立文件夹页 = 打开底部详情 Drawer（`onOpen(index)`，‹n/N› 切张可用）；项目详情页 = 与表格行点击行为一致（选中/取消选中，右栏联动、批量操作栏照常可用）。
8. 项目详情页瀑布流下保留多选：选中瓦片 accent 描边 + 左上角勾选徽标；选中集合与详情模式（表格）互通，切模式不丢选中。
9. 深链定位 `?asset=` 在瀑布流模式下仍生效：瓦片带 `data-asset-id`，定位 + `highlightId` 描边逻辑与 AssetCardList 一致。
10. 图片加载失败 / 无缩略图资产（如未生成封面的文件）：瓦片回落文件图标占位（沿用 AssetThumbnail 的兜底视觉）。
11. 无 `thumbnail_width/height` tags 的资产按 1:1 纵横比兜底，不破版式。
12. 分页在瀑布流模式下正常工作（沿用 useAssets 每页 30 + 钉底 Pagination，翻页不白屏 keepPreviousData）。
13. compact（<1024）视口：两页均不显示切换器、恒为详情模式现状（移动端零改动）。

## 3. 组件拆分方案

### 3.1 组件/模块清单与契约

**A. `hooks/use-view-mode.ts`（新建，~40 行）** — 视图模式持久化

```ts
export type FolderViewMode = 'detail' | 'small' | 'large';
export const FOLDER_VIEW_MODE_KEY = 'ms-pc-folder-view-mode';
export function readViewMode(): FolderViewMode;            // try/catch，非法值→'detail'
export function writeViewMode(m: FolderViewMode): void;    // try/catch 吞异常
export function useViewMode(): readonly [FolderViewMode, (m: FolderViewMode) => void];
// useViewMode = 惰性 useState 初始化 + set 时同步落盘；不做 Context
```

写法跟随 `api/client.ts:9-16` 先例（key 常量 + try/catch get/set 一对函数）。

**B. `components/AssetWaterfallList.tsx`（新建，~180 行）** — 瀑布流列表容器

```ts
interface AssetWaterfallListProps {
  assets: Asset[];
  variant: 'small' | 'large';          // small→5 列+size=small；large→2 列+size=large
  loading?: boolean;                    // true 时渲染等列数灰色占位瓦片
  highlightId?: string | null;
  onOpen?: (index: number) => void;     // 无多选语义时点击回调（与 AssetCardList.onOpen 同形）
  selectable?: boolean;                 // 与 AssetCardList 同名 prop 语义一致
  selectedIds?: /* 与 AssetCardList.selectedIds 完全同形（以 AssetCardList.tsx 实际签名为准） */;
  onToggle?: (id: string) => void;
}
```

- 网格：`display:grid`，`gridTemplateColumns: repeat(5|2, minmax(0,1fr))`，gap 12px；列宽=容器等分（「固定宽度」指列宽不随图片变形，宽度恒定、高度自适应，非 px 钉死，随窗口等分变化）。
- 数据流：容器分列不分块（单 grid + 瓦片 aspect-ratio 占位即天然瀑布流视觉，不需要按列均分数据的 JS masonry；若开发中发现 grid 行对齐导致视觉空洞不可接受，允许改为按列均分的两/五列 flex 实现，但对外 props 不变，且须在汇报中说明）。
- 每瓦片外层 div 必带 `data-asset-id={asset.id}`；`highlightId` 命中时描边样式与 `AssetCardList.tsx:76,:86-87` 同视觉语言（accent 描边）。

**C. `components/AssetWaterfallItem.tsx`（新建，~150 行）** — 单瓦片

- 纵横比盒子：`aspectRatio: w/h`（来源 `asset.tags.thumbnail_width/height`，缺失→1）；img 绝对填充 `objectFit:'cover'`。
- 缩略图 URL：react-query `useQuery`，queryKey `['thumbnail-url', asset.id, size]`、staleTime 25min，**与 `AssetThumbnail.tsx:21-31` 同族共享缓存**（size 按 variant 传 'small' | 'large'）；`loading="lazy" decoding="async"`。
- 失败兜底：onError → 文件图标占位（视觉沿用 AssetThumbnail 的 FileText 兜底）。
- 选中态：accent 描边 + 左上角勾选徽标；hover：底部渐变浮层显示文件名（单行截断）+ `title={filename}`。
- 点击：`selectable` 时调 `onToggle(asset.id)`，否则调 `onOpen(index)`；索引由容器传入。

**D. `pages/FolderDetailPage.tsx`（修改，+~50 行，251→~300 行）**

- 页面顶部操作区（路径行附近）加 Segmented；`compact = useCompactViewport()` 为 true 时不渲染切换器且恒用 AssetCardList（现状分支不动）。
- 视图状态 `useViewMode()`；非 compact 时按 mode 条件渲染 AssetCardList（detail）/ AssetWaterfallList（small/large）。
- Drawer/detailIndex/highlightId/scrollIntoView 深链逻辑原样保留（瀑布流 onOpen 与卡片列表同 index 语义）。

**E. `pages/ProjectDetailPage.tsx`（修改，+~70 行，1586→~1656 行）**

- **存量文件已超 500 行上限（1586 行），本次不做重构**（另案遗留），只做最小增量；新增逻辑若可成块，优先收敛为页面内的小函数/常量，不新建页面级子组件文件。
- 仅桌面分支（:1374-1409 Table 处）接入：actions bar（:1283-1371 区域）加 Segmented；mode≠detail 时中栏渲染 AssetWaterfallList 替代 Table，`selectable` + 现有选中状态 + 现有批量操作栏全部照常工作；瓦片点击行为=表格行点击行为的现有实现（开发时以实际代码为准镜像）。
- compact 分支（AssetCardList :935-951）不动；排序控件在表头，瀑布流模式无表头故不提供列排序（决策 D6）。

### 3.2 依赖关系与数据流

A（hook）→ B/C（组件消费 hook 无依赖，A 只被页面消费）→ D/E（页面消费 A+B+C）。实际开发顺序：**包 A 先行 → 包 B、C 并行**；B、C 不互相依赖。

### 3.3 可复用资产映射

| 资产 | 用法 |
|---|---|
| `api/client.ts:9-16` localStorage 读写模式 | A 照抄写法 |
| `hooks/useProgressiveThumb.ts:31-41` fetchThumbUrl 与 queryKey 族 | C 的 URL 获取直接复用同 queryKey 族（允许在 C 内直接 useQuery 同 key 同 staleTime，与 AssetThumbnail 缓存互通） |
| `components/AssetThumbnail.tsx` 兜底视觉/懒加载属性 | C 参考其 onError 兜底与 loading/decoding 属性 |
| antd `Segmented` | 仓库已有 4 处先例（TaskCenterDrawer 等），直接用 |
| `lib/use-viewports.ts` useCompactViewport | D/E 的视口判定唯一源，禁止页面自写 Grid.useBreakpoint |
| `styles/tokens.css` `--ms-*` 令牌 | 全部样式用 CSS 变量内联 style（仓库无 CSS Modules） |

### 3.4 预估文件清单

| 文件 | 新建/修改 | 预估行数 |
|---|---|---|
| `hooks/use-view-mode.ts` | 新建 | ~40 |
| `components/AssetWaterfallItem.tsx` | 新建 | ~150 |
| `components/AssetWaterfallList.tsx` | 新建 | ~200（修复轮 D9 改按列均分实现） |
| `components/FolderViewModeSwitch.tsx` | 新建（修复轮 D9） | ~35 |
| `pages/FolderDetailPage.tsx` | 修改 | +50 |
| `pages/ProjectDetailPage.tsx` | 修改 | +70（存量 1586 行超限遗留另案） |

单文件硬上限 500 行（新建文件均远低于上限；E 为存量超限文件只做最小增量）。

## 4. 数据库修改方案

不涉及。

## 5. 接口定义

不新增接口。复用既有 `GET /api/v1/assets/{asset_id}/thumbnail-url?size=small|large`（响应 `{url, expires_in, variant}`；small 缺失时后端回落签 1024 主图并标 variant，前端无需特殊处理）。

## 6. 前端改动点 / 后端改动点

- 前端：§3 全部；**后端：无**。
- 不改 `AssetCardList.tsx`、`AssetThumbnail.tsx`、路由、api 层。

## 7. 测试功能点

见 §2 功能点明细 1-13，另加：

14. `pnpm lint`、`pnpm build`（含 tsc -b）全绿。
15. 回归：详情模式下独立文件夹页与项目详情页全部既有功能不受影响（多选/批量/排序/下载/Drawer/深链定位）。
16. 新建文件均 ≤500 行；文件头部有方案出处块注释（仓库惯例）。
17. web 无前端测试框架（无 test script），本周期验证 = build + lint + 本文档功能点人工清单（存档 `docs/qdev/2026-11-25-pc-folder-view-modes-checklist.md`）。

## 8. 模糊点与决策记录

| # | 模糊点 | 决策 | 理由 |
|---|---|---|---|
| D1 | 改动落点：仅独立文件夹页 / 仅项目详情页 / 两处 | **两处都支持**（用户拍板） | PC 所有浏览文件夹入口行为一致 |
| D2 | 瀑布流下项目详情页多选/批量处理 | **保留多选**（用户拍板）：点击瓦片=选中/取消，批量栏照常可用 | 与详情模式交互一致，无学习成本 |
| D3 | 持久化走 localStorage 还是服务端 prefs API（`api/prefs.ts` 已有） | localStorage 直读写（用户明说「保存在本地缓存即可」），key `ms-pc-folder-view-mode` | 用户点名；实现最简，不增后端面 |
| D4 | 「固定宽度」语义 | 列宽=容器等分（5/2 列），宽度不随图片变形，高度按纵横比自适应 | 响应式容器下 px 钉死会留大片空白；等分+高度自适应即通常瀑布流诉求 |
| D5 | 切换器是否在 compact（<1024）视口出现 | 不出现，compact 恒为详情模式 | 需求明确「针对 PC 版」，移动端零改动、回归面最小 |
| D6 | 瀑布流下表格列排序 | 不支持（无表头入口），按数据原顺序渲染；需要排序切回详情模式 | AssetCardList 同口径（排序降级），ProjectDetailPage 表头排序器是 Table 专属 |
| D7 | ProjectDetailPage 存量 1586 行超限 | 本次不重构，只最小增量；超限重构另案 | 重构与功能变更同周期风险过高 |
| D8 | 瀑布流实现选型 | CSS grid + aspect-ratio 占位（零新依赖）；实现不理想才允许按列均分 flex，对外 props 不变 | 每页仅 30 条、无虚拟化诉求，不引第三方 masonry 库 |
| D9 | 修复轮（专职测试 P1×2）：① 单 grid 行对齐不产生瀑布流「上移补位」视觉 → 触发 D8 预留退路，**改为按列均分（贪心最短列优先）+ 列内 flex 堆叠，对外 props 不变**；② `VIEW_MODE_OPTIONS` 两页逐字重复 → 抽共享组件 `components/FolderViewModeSwitch.tsx`，两页换用 | 采纳测试建议全修 | grid 行高=该行最高瓦片会留空洞，不满足瀑布流核心形态；档位定义与类型同源必须单点维护 |

## 9. 红线闸口结论

可行性与成本评估：后端双规格缩略图与宽高 tags 均已就绪，纯前端增量改动，成本合理，无不可行/天价成本问题，无需用户再拍板。
