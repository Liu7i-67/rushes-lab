# PC 文件夹三视图切换 — web 端验收清单(D 包)

> 配套需求:`docs/qdev/2026-11-25-pc-folder-view-modes.md`(唯一需求依据,重点 §2 功能点 1-13、
> §7 测试功能点 14-17、§8 决策 D1-D8)。
> 被测实现:`material-storage/web/src/hooks/use-view-mode.ts`(新建)、
> `material-storage/web/src/components/AssetWaterfallList.tsx`(新建)、
> `material-storage/web/src/components/AssetWaterfallItem.tsx`(新建)、
> `material-storage/web/src/pages/FolderDetailPage.tsx`(修改)、
> `material-storage/web/src/pages/ProjectDetailPage.tsx`(修改)。
> web 无自动化测试框架(package.json 无 test script),本周期验证 = `pnpm build`(含 tsc -b)
> + `pnpm lint` + 本清单。`[devtools]` = Chrome DevTools 可完整验证;所有命令在 worktree 的
> `material-storage/web` 目录下执行(下文相对路径以 `material-storage/web` 为基准)。
> **编写时实现尚未合入(worktree @ cb30b94 仅需求文档)**:S 类条目按需求文档 §3.1 契约书写,
> 实现落地后逐条核对;契约与实现有偏差时在文末「偏差记录」补记,按实现实际行为测,勿按旧契约误报。

## 通用准备

- 构建:dev 栈部署(或本地 `pnpm dev`);后端无需改动(双规格缩略图与宽高 tags 已就绪)。
- 视口:PC 验收用 ≥1024 宽窗口(建议 1440×900);compact(<1024)用例用 DevTools 设备模拟
  或直接缩小窗口(antd lg 断点,判定源 `lib/use-viewports.ts` useCompactViewport = `!screens.lg`)。
- 素材(同一个文件夹内,数量 >30 以覆盖分页):a) 横图 jpg((tags 含
  `thumbnail_width`/`thumbnail_height`/`thumbnail_key`));b) 竖图;c) 方图/极端纵横比图
  (如 3:1 全景);d) 无 `thumbnail_width`/`thumbnail_height` tags 的资产(改 tags 或找老数据);
  e) 无缩略图资产(tags 无 `thumbnail_key`,如缩略图失败/`.svg`);
  f) 视频带封面 1 个(对照非图片资产瓦片表现)。
- 查 tags:Network 中 assets 列表接口响应 JSON 的 `tags` 字段。
- 规格判别:签名 URL 含 `thumbnails/{id}_s.jpg` = small(240px);`thumbnails/{id}.jpg` =
  large(1024px);响应 `variant` 字段同义;图片实际尺寸 = Elements 选中 img 后 Console 执行
  `$0.naturalWidth`。
- localStorage 查看:Application → Local Storage → key `ms-pc-folder-view-mode`。
- DevTools 技巧:失败模拟 = Network 面板右键缩略图字节请求 →「Block request URL」
  (解除:右侧 Blocking 页签);react-query 签名缓存(staleTime 25min)与 HTTP 字节缓存独立,
  验证签名请求是否重发时勿混淆两者。

## 一、可执行静态检查(专职测试智能体可直接跑/查证;实现合入后执行)

- [ ] **S-01** 三个新建文件存在且均 ≤500 行
  - 命令:`wc -l src/hooks/use-view-mode.ts src/components/AssetWaterfallItem.tsx src/components/AssetWaterfallList.tsx`
  - 期望:三个文件都存在,每行数 ≤500(预估 ~40 / ~150 / ~180,远低于上限)。
- [ ] **S-02** 新建文件头部有方案出处块注释(仓库惯例,参照 `AssetCardList.tsx:1-6` 先例)
  - 命令:`head -n 12 src/hooks/use-view-mode.ts src/components/AssetWaterfallItem.tsx src/components/AssetWaterfallList.tsx`
  - 期望:每个新文件文件头块注释提到本需求文档(`docs/qdev/2026-11-25-pc-folder-view-modes.md`
    或其 § 编号);两个修改页面的头部注释也保留/更新出处。
- [ ] **S-03** localStorage key 精确为 `ms-pc-folder-view-mode`
  - 命令:`grep -rn "ms-pc-folder-view-mode" src/`
  - 期望:仅 `src/hooks/use-view-mode.ts` 命中,且以常量形式定义
    (`FOLDER_VIEW_MODE_KEY = 'ms-pc-folder-view-mode'`,契约 §3.1 A 一字不差);
    全仓库无第二个 key 变体(无前缀后缀差异)。
- [ ] **S-04** 读写函数 try/catch + 非法值回落 + hook 形态符合契约
  - 命令:`cat src/hooks/use-view-mode.ts`(对照需求文档 §3.1 A)
  - 期望:`export type FolderViewMode = 'detail' | 'small' | 'large'`;
    `readViewMode(): FolderViewMode` 内 try/catch,解析结果非三值之一(含 JSON 异常/键不存在)→
    返回 `'detail'`;`writeViewMode(m): void` try/catch 吞异常;`useViewMode()` 返回
    `readonly [FolderViewMode, (m: FolderViewMode) => void]`,惰性 useState 初始化,
    set 时同步落盘;无 Context。
- [ ] **S-05** 瓦片带 `data-asset-id`
  - 命令:`grep -n "data-asset-id" src/components/AssetWaterfallList.tsx src/components/AssetWaterfallItem.tsx`
  - 期望:每瓦片外层 div 带 `data-asset-id={asset.id}`(深链 `document.querySelector` 定位依赖此属性,
    与 `AssetCardList.tsx:80` 同形)。
- [ ] **S-06** 缩略图 queryKey 与 AssetThumbnail 同族、staleTime 25 分钟
  - 命令:`grep -n "thumbnail-url\|staleTime" src/components/AssetWaterfallItem.tsx`,对照 `src/components/AssetThumbnail.tsx:21-31`
  - 期望:react-query `useQuery` 的 queryKey 为 `['thumbnail-url', asset.id, size]`(size 按
    variant 传 `'small' | 'large'`),staleTime `25 * 60 * 1000`(25 min,presigned 30 min 留余量),
    `retry: false`;与 AssetThumbnail / useProgressiveThumb(`hooks/useProgressiveThumb.ts:31-41`
    fetchThumbUrl)同 key 族共享缓存。
- [ ] **S-07** variant→size 映射正确且带 enabled 门控
  - 命令:`grep -n "size\|thumbnail_key\|enabled" src/components/AssetWaterfallItem.tsx`
  - 期望:variant `small` → 请求 `/api/v1/assets/{id}/thumbnail-url?size=small`(240px);
    variant `large` → `?size=large`(1024px);无 `tags.thumbnail_key` 的资产不发请求
    (enabled 门控,同 AssetThumbnail 口径)。
- [ ] **S-08** img 懒加载属性与失败兜底
  - 命令:`grep -n "loading=\|decoding=\|onError\|FileText" src/components/AssetWaterfallItem.tsx`
  - 期望:`loading="lazy" decoding="async"`;onError → 文件图标占位(视觉沿用 AssetThumbnail 的
    FileText 兜底,`AssetThumbnail.tsx:62-66` 同语言)。
- [ ] **S-09** 纵横比兜底逻辑
  - 命令:`grep -n "aspectRatio\|thumbnail_width\|thumbnail_height" src/components/AssetWaterfallItem.tsx`
  - 期望:纵横比盒子 `aspectRatio: w/h`(来源 `asset.tags.thumbnail_width/height`),任一缺失 → 1
    (1:1 兜底);img 绝对填充 `objectFit: 'cover'`。
- [ ] **S-10** 网格列数与列宽契约
  - 命令:`grep -n "gridTemplateColumns\|repeat(" src/components/AssetWaterfallList.tsx`
  - 期望:`display: grid`,`gridTemplateColumns: repeat(5, minmax(0, 1fr))`(variant=small)/
    `repeat(2, minmax(0, 1fr))`(variant=large),gap 12px;列宽 = 容器等分,不随图片变形(决策 D4)。
- [ ] **S-11** loading 占位
  - 命令:`grep -n "loading" src/components/AssetWaterfallList.tsx`
  - 期望:`loading` 为 true 时渲染与列数一致的灰色占位瓦片(small→5 个、large→2 个)。
- [ ] **S-12** compact 门控:两页面切换器仅在非 compact 渲染
  - 命令:`grep -n "useCompactViewport\|Segmented" src/pages/FolderDetailPage.tsx src/pages/ProjectDetailPage.tsx`
  - 期望:两页面均消费 `useCompactViewport()`(唯一定义在 `lib/use-viewports.ts`,页面内**不得**出现
    `Grid.useBreakpoint`/`innerWidth` 自写判定);Segmented 切换器与瀑布流渲染分支均在
    `!compact` 条件内;compact 分支沿用 AssetCardList 现状(FolderDetailPage:176、
    ProjectDetailPage:935-951 不动)。
- [ ] **S-13** 项目页瀑布流复用现有选中状态
  - 命令:`grep -n "selectedIds\|toggleSelect\|AssetWaterfallList" src/pages/ProjectDetailPage.tsx`
  - 期望:瀑布流 `selectable` + `selectedIds` + `onToggle` 与桌面 Table
    (`ProjectDetailPage.tsx:1383-1389` rowSelection)消费**同一** selectedIds state,
    瓦片点击镜像 Table 行点击(选中/取消切换,:1390-1396);右栏 `selectedAssets`(:126 派生)
    与批量操作栏照常联动。
- [ ] **S-14** highlightId 描边视觉与 AssetCardList 一致
  - 命令:`grep -n "ms-accent" src/components/AssetWaterfallList.tsx src/components/AssetWaterfallItem.tsx`
  - 期望:`highlightId` 命中瓦片用 accent 描边,与 `AssetCardList.tsx:86-87` 同视觉语言
    (`border: 1px solid var(--ms-accent)` + `boxShadow: 0 0 0 3px var(--ms-accent-soft)` 或等效令牌组合)。
- [ ] **S-15** 选中态与 hover 契约
  - 命令:`grep -n "ms-accent\|Checkbox\|Check\|title=\|filename" src/components/AssetWaterfallItem.tsx`
  - 期望:选中瓦片 accent 描边 + 左上角勾选徽标;hover 底部渐变浮层显示文件名(单行截断)+
    `title={filename}`;点击:`selectable` 时 `onToggle(asset.id)`,否则 `onOpen(index)`(索引由容器传入)。
- [ ] **S-16** 零新增依赖
  - 命令:`git diff --stat HEAD -- package.json pnpm-lock.yaml`(worktree 根,路径前缀 material-storage/web)
  - 期望:diff 为空(决策 D8:零新依赖,CSS grid + aspect-ratio 实现)。
- [ ] **S-17** 保护清单未被改动
  - 命令:`git diff --stat HEAD -- src/components/AssetCardList.tsx src/components/AssetThumbnail.tsx src/api src/App.tsx src/main.tsx`
  - 期望:diff 为空(需求 §6:不改 AssetCardList.tsx、AssetThumbnail.tsx、api 层、路由)。
- [ ] **S-18** ProjectDetailPage 最小增量(决策 D7)
  - 命令:`git diff --stat HEAD -- src/pages/ProjectDetailPage.tsx src/pages/FolderDetailPage.tsx`
  - 期望:增量量级与预估相当(+~70 / +~50 行);无既有代码块搬迁/重排(存量 1586 行超限本次不重构);
    FolderDetailPage 深链相关 state/effect(:33-139)未被改动语义。
- [ ] **S-19** `pnpm lint` 全绿
  - 命令:`pnpm lint`
  - 期望:退出码 0,无 error/warning 新增。
- [ ] **S-20** `pnpm build` 全绿(含 tsc -b)
  - 命令:`pnpm build`
  - 期望:`tsc -b && vite build` 退出码 0,无类型错误。

## 二、人工功能验收(部署到 dev 后人工过;编号对应需求 §2 功能点 1-13)

### 入口与切换(功能点 1-2)

- [ ] **M-01** 独立文件夹页切换器出现
  - 入口:`/folders/:id`(FolderDetailPage);前置:PC 窗口 ≥1024,文件夹内有 ≥1 个文件。
  - 步骤:打开任意文件夹页,观察页顶操作区(路径行/上传按钮附近)。
  - 期望:出现 antd `Segmented` 切换器,三档文案 = 详情 / 小图 / 大图;不遮挡既有上传按钮与路径行。
- [ ] **M-02** 项目详情页切换器出现
  - 入口:`/projects/:projectId/folders/:folderId` PC 三栏中栏(ProjectDetailPage 桌面分支)。
  - 步骤:打开项目详情页,观察 actions bar(全选 Checkbox / 上传 / 打标 那一行)。
  - 期望:同款三档 Segmented 出现在 actions bar;既有按钮(上传/打标/前缀/移动/刷新/下载/回收站/删除)
    功能与布局不受挤压异常。
- [ ] **M-03** 三档切换即时生效
  - 步骤:在任一入口依次点 小图 → 大图 → 详情 → 小图,每次点击后立即观察列表形态。
  - 期望:详情 = 表格/卡片列表原样;小图 = 5 列瀑布流;大图 = 2 列瀑布流;切换**无需刷新**,
    无白屏/闪烁报错;列表数据不重新请求(切模式不发新的 assets 列表请求)。

### 详情模式回归红线(功能点 3)

- [ ] **M-04** 详情模式渲染与改造前完全一致
  - 前置:可与改造前版本(主仓)同页面对照截图。
  - 步骤:独立文件夹页与项目详情页均切回「详情」档,逐块比对页顶、列表、分页器、Drawer。
  - 期望:DOM 结构、样式、交互与改造前一致(回归红线,零视觉漂移)。

### 小图模式(功能点 4)

- [ ] **M-05** 小图 5 列瀑布流视觉
  - 前置:素材 a(横图)+ b(竖图)+ c(方图)同夹;窗口最大化(列宽足够区分)。
  - 步骤:切「小图」,观察列数与瓦片高度。
  - 期望:5 列等宽(列宽 = 容器均分,缩放窗口列宽随之等分变化但列数不变);
    瓦片高度按各自图片纵横比自适应,同一行内高度参差、下一列瓦片上移补位(瀑布流视觉);
    图片不变形、不裁切失真(cover 裁切仅发生在纵横比兜底的异常数据上)。
- [ ] **M-06** [devtools] 小图缩略图规格 = small(240px)
  - 步骤:切「小图」→ Network 过滤 `thumbnail-url` → 打开请求看 URL 与响应;Elements 选 img 查
    `$0.naturalWidth`。
  - 期望:请求 `GET /api/v1/assets/{id}/thumbnail-url?size=small`;响应 `variant:"small"`、
    url 含 `{id}_s.jpg`;img naturalWidth ≤240;首次进入该模式时签名请求按瓦片挂载发出,
    25min 内重复进出不重发(react-query 缓存)。

### 大图模式(功能点 5)

- [ ] **M-07** 大图 2 列瀑布流视觉
  - 步骤:切「大图」,观察列数与瓦片(对照 M-05)。
  - 期望:2 列等宽,其余同小图(高度纵横比自适应、瀑布流补位)。
- [ ] **M-08** [devtools] 大图缩略图规格 = large(1024px)
  - 步骤:切「大图」→ Network 过滤 `thumbnail-url` → 核对 URL/响应/naturalWidth。
  - 期望:请求 `?size=large`;url 含 `{id}.jpg`(无 `_s`);naturalWidth ≤1024;
    同一资产在 small/large 两种 queryKey 下各自缓存,互不串。

### 持久化与回落(功能点 6)

- [ ] **M-09** [devtools] 刷新 / 新标签保持模式
  - 步骤:① 切「小图」→ F5 刷新;② 切「大图」→ 复制 URL 到新标签打开;③ Application 面板查看
    Local Storage。
  - 期望:①② 刷新/新标签后仍停留在切换后的模式;③ key `ms-pc-folder-view-mode` 的值随切换
    实时更新(small/large/detail)。
- [ ] **M-10** [devtools] 非法值 / 无缓存回落详情
  - 步骤:① 删除该 key → 刷新;② Console 执行
    `localStorage.setItem('ms-pc-folder-view-mode','hacker')` → 刷新;③ 私密模式禁 storage
    (或手写坏 JSON)→ 打开页面。
  - 期望:三种情况均回落详情模式,页面正常渲染无 crash,控制台无未捕获异常(try/catch 生效)。

### 瓦片点击语义(功能点 7)

- [ ] **M-11** 独立文件夹页瓦片点击 = Drawer
  - 前置:独立文件夹页,切「小图」(大图重复一遍)。
  - 步骤:点击第 3 个瓦片 → 观察底部详情 Drawer → 点 ‹ › 切张 → 关闭 Drawer。
  - 期望:Drawer 从底部弹出,标题 ‹n/N› 显示点击瓦片在当前页的序位(如 3 / 30);
    ‹ › 前后切张内容正确、首尾按钮正确禁用;关闭后瓦片列表无状态残留。
- [ ] **M-12** 项目详情页瓦片点击 = 表格行点击语义
  - 前置:项目详情页 PC 三栏,切「小图」。
  - 步骤:① 点击瓦片 A;② 再点瓦片 A;③ 点瓦片 B 后观察右侧栏与批量入口。
  - 期望:① 瓦片 A 进入选中态(见 M-13),右栏 AssetSummaryPanel 显示该文件;② 再点取消选中,
    右栏联动清空;③ 批量按钮(打标/前缀/移动/下载/删除)按选中数启用并显示计数,
    与详情模式表格行点击行为完全一致。

### 选中态与跨模式互通(功能点 8)

- [ ] **M-13** 选中描边 + 勾选徽标
  - 前置:项目详情页瀑布流模式(小图/大图各验一次)。
  - 步骤:选中 1-2 个瓦片,观察其视觉;再观察未选中瓦片。
  - 期望:选中瓦片 accent 描边 + 左上角勾选徽标;未选中瓦片无描边;视觉不遮挡文件名 hover 浮层。
- [ ] **M-14** 跨模式选中互通
  - 步骤:① 详情模式表格勾选 2 行 → 切「小图」;② 瀑布流中再点选 1 个瓦片(共 3)→ 切回「详情」;
    ③ 切「大图」看一眼 → 切「详情」。
  - 期望:① 两瓦片在瀑布流中仍带描边+徽标;② 表格中 3 行勾选齐全,批量计数 = 3;
    ③ 大图同样保留 3 个选中;全程选中集合不丢(与表格同一 state)。

### 深链定位(功能点 9)

- [ ] **M-15** 深链 `?asset=` 在瀑布流模式生效
  - 前置:独立文件夹页切「小图」;从盲搜/其它页面取得某文件的 `?asset=<id>` 深链
    (该文件位于第 2 页,验跳页)。
  - 步骤:新标签打开 `.../folders/:id?asset=<id>`;分别在小图、大图模式各验一次。
  - 期望:自动定位跳到正确页码 → 滚动到目标瓦片 → 目标瓦片 accent 描边高亮
    (data-asset-id 命中)→ 详情 Drawer 自动打开;一次性消费:刷新同 URL 可重放,
    但翻页/切夹后不重复弹 Drawer;目标已删时 toast「目标文件可能已被删除或移动」并停留当前页。

### 兜底与异常(功能点 10-11)

- [ ] **M-16** 加载失败 / 无缩略图兜底
  - 步骤:① [devtools] Block 某瓦片的缩略图字节 URL(签名放行)→ 刷新 → 观察该瓦片 → 解除 Block;
    ② 打开含素材 e(无 `thumbnail_key`)的文件夹,切瀑布流。
  - 期望:① 字节失败瓦片回落文件图标占位(沿用 AssetThumbnail 的 FileText 视觉),布局不跳动,
    不无限重试;② 无缩略图资产直接显示文件图标占位,瓦片占位不破格。
- [ ] **M-17** 无宽高 tags 1:1 兜底
  - 前置:素材 d(无 `thumbnail_width`/`thumbnail_height`)。
  - 步骤:切「小图」与「大图」,观察该瓦片及相邻瓦片。
  - 期望:该瓦片按 1:1 纵横比渲染,不破版式、不把相邻瓦片挤出网格;其余瓦片不受影响。

### 分页与 compact(功能点 12-13)

- [ ] **M-18** 瀑布流模式分页正常
  - 前置:文件夹内文件 >30(至少 2 页);Network 开启。
  - 步骤:切「小图」→ 翻到第 2 页 → 翻回第 1 页;「大图」重复一遍;观察翻页瞬间。
  - 期望:沿用 useAssets 每页 30 + 钉底 Pagination;翻页期间旧内容保留不白屏(keepPreviousData),
    翻页后页码/总数正确,滚动回顶,Drawer 若开着则关闭;瓦片重新挂载时缩略图按缓存命中率
    正常显示。
- [ ] **M-19** compact(<1024)视口无切换器、恒详情
  - 步骤:窗口缩到 <1024(或 DevTools 设备模拟),分别打开两个入口页面;再放大回 ≥1024。
  - 期望:compact 下两页面均**不出现** Segmented,恒为详情模式现状(独立页 AssetCardList、
    项目页 AssetCardList 分支);放大后切换器恢复出现,localStorage 里的模式在 PC 生效;
    移动端交互零改动。
- [ ] **M-20** hover 文件名浮层
  - 步骤:瀑布流模式下鼠标悬停任一瓦片,再用超长文件名素材验证。
  - 期望:底部渐变浮层显示文件名,单行截断不换行;原生 tooltip(title)显示完整文件名;
    移开鼠标浮层消失。

## 三、回归清单(详情模式下两入口既有功能不受影响;需求 §7 功能点 15)

> 全部在「详情」档下操作;每条做完顺手切一次瀑布流再切回,确认模式切换不残留副作用。

- [ ] **R-01** 独立文件夹页 Drawer 与预览
  - 步骤:点卡片打开 Drawer → ‹ › 切张 → 点预览进 Modal → 关闭。
  - 期望:与改造前一致(AssetSummaryPanel 单选态、预览 Modal 在 Drawer 内叠层正常)。
- [ ] **R-02** 独立文件夹页深链定位
  - 步骤:用 `?asset=` 深链打开(目标在第 2 页)。
  - 期望:跳页 + 滚动 + 高亮 + 自动开 Drawer;失败 toast 分支同现状(与 M-15 同链路,详情档回归)。
- [ ] **R-03** 独立文件夹页分页 / 上传 / 空态
  - 步骤:翻页、上传 1 个文件、看空文件夹文案。
  - 期望:分页钉底回顶、翻页清高亮/关 Drawer;上传权限门控(无权限禁用 + tooltip);
    空态文案两种(有/无上传权限)不变。
- [ ] **R-04** 项目详情页多选 / 全选 / 跨页保留
  - 步骤:表头全选 → 翻页再翻回;手动勾 2 行 + 翻页勾 1 行。
  - 期望:全选只动当前页;跨页保留选中(preserveSelectedRowKeys);已选计数正确。
- [ ] **R-05** 项目详情页批量操作五件套
  - 步骤:选中多行依次走 打标 / 前缀 / 移动 / 下载 / 删除(Popconfirm 确认)。
  - 期望:五个操作全部成功,权限禁用态与 tooltip 不变;删除后列表刷新、回收站计数 +1。
- [ ] **R-06** 项目详情页表头排序
  - 步骤:按「大小」「创建时间」列头点击排序(升/降)。
  - 期望:排序正常(详情模式 Table 专属能力;瀑布流无表头不提供排序,属决策 D6,不算回归缺陷)。
- [ ] **R-07** 项目详情页单行下载与行点击
  - 步骤:行内下载按钮、行点击选中/取消。
  - 期望:下载链路与 403 申请弹窗不变;行点击切换选中语义不变。
- [ ] **R-08** 项目详情页切夹 / 刷新
  - 步骤:左侧 FolderTree 切换文件夹;点「刷新」按钮。
  - 期望:切夹清空选中(现状语义)、页码回 1;刷新重新拉取;两行为与改造前一致。
- [ ] **R-09** compact 移动端整体回归
  - 步骤:<1024 视口走一遍两页面:卡片列表、Drawer(项目页 ‹n/N› 切张)、批量栏 2×2 网格、分页。
  - 期望:与改造前完全一致(需求红线:移动端零改动);localStorage 中已存的模式值不影响 compact 渲染。
- [ ] **R-10** 权限门控回归
  - 步骤:用无 uploader / 无删除权限账号查看两页面详情模式与瀑布流模式。
  - 期望:上传/打标/删除等禁用态与 tooltip 与改造前一致;瀑布流模式不引入新的权限旁路
    (瓦片点击仅选中/打开,不触发需权限的操作)。

## 功能点映射(需求 §2 功能点 1-13 + §7 14-17 → 用例)

1 两入口 → M-01/M-02;2 Segmented 即时生效 → M-03;3 详情一致 → M-04;
4 小图 5 列+small → M-05/M-06;5 大图 2 列+large → M-07/M-08;6 持久化/回落 → M-09/M-10;
7 点击语义 → M-11/M-12;8 多选互通 → M-13/M-14;9 深链 → M-15;10 失败兜底 → M-16;
11 无宽高 1:1 → M-17;12 分页 → M-18;13 compact → M-19;
14 lint/build → S-19/S-20;15 回归 → R-01~R-10;16 行数/注释 → S-01/S-02;
17 本清单存档 → 本文档。
静态契约覆盖:S-03(key)、S-04(hook 契约)、S-05(data-asset-id)、S-06(queryKey/staleTime)、
S-12(compact 门控)、S-16/S-17(零依赖/保护清单)、S-18(最小增量)。

## 待实现后核对项(编写清单时实现未合入,契约来源 = 需求文档 §3.1)

1. S-01~S-15 的具体写法(常量命名、props 形态、样式令牌组合)以实现代码为准;若实现采用
   需求文档允许的备选方案(如「按列均分的两/五列 flex 实现」替代 CSS grid,决策 D8 允许),
   S-10 应按实现实际结构调整断言,对外 props 不变的前提下不算偏差。
2. `selectedIds` 的实际类型签名以 `AssetCardList.tsx` 实现为准(契约写「完全同形」;
   现核实为 `selectedIds?: string[]`)。
3. 偏差记录:实现合入后,任何与需求文档 §3.1 契约不一致处在此补记(格式参照
   `docs/qdev/2026-10-27-thumb-variant-web-checklist.md` 文末「偏差记录」),相关用例按实现改写。
