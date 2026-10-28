# 移动端批量操作栏补充「下载」

- 日期:2026-10-21
- 分支:`feat/mobile-batch-download`(基线 liuqi@a98aa43,worktree `../rushes-lab-feat-mobile-batch-download`)
- 需求来源:用户原话「移动端,在一个项目中同时选中多个素材时,批量操作中没有下载操作,需要补充上」

## 背景与目标

web 端 ProjectDetailPage 的 compact(手机视口)批量操作栏(`ProjectDetailPage.tsx:840-908`)现有
打标/前缀/移动/删除 四个动作,**刻意未放「下载」**(旧决策 §3.1:移动端浏览器拦截连续多下载,
下载走每卡行内按钮)。桌面布局的批量栏(`ProjectDetailPage.tsx:1204-1207`)有「下载」按钮,
复用 `confirmBulkDownload` → `handleBulkDownload`(逐 id presign + `downloads.start`)。

用户现要求推翻旧决策,在移动端批量操作中补上下载。本需求**只改 web 前端**,不动后端、不动数据库。

> 范围澄清:Flutter App(`material-storage/app`)目前无多选 UI(代码注释明确「多选/批量操作按
> §16 B5 批交付」,尚未实现),用户描述的「已有批量操作但缺下载」唯一对应 web compact 布局,故
> 本需求落 web 端。

### 现状关键事实(代码实证)

- 下载双路径(`web/src/lib/download-store.tsx`):桌面(有 File System Access API)流式写盘;
  移动端(无 FSA)换 `as_attachment=true` presigned 链接后 `<a target=_blank>` 直连系统下载器,
  每文件登记一条立即完成任务 + toast「已交给系统下载」。
- `handleBulkDownload`(ProjectDetailPage.tsx:211-234)已兼容双端:逐 selectedIds 全量口径(含
  跨页未加载 id,占位名 `asset_<id 前 8>.bin`);403 分流=已加载项弹申请弹窗/未加载项聚合计数;
  其余失败=已加载逐条报错/未加载聚合。
- `confirmBulkDownload`(237-248):>20 个文件弹确认,文案已含「浏览器可能拦截连续下载,建议分批
  (每批 ≤20)操作」。
- compact 批量栏行2 为 2×2 等宽网格,注释写明扩展约定:「行2 已占满 4 格,后续新按钮按行内追加
  或改 3×2 网格(轻操作可移入行1)」。

## 功能点明细(逐条可验收)

1. compact 视口(≤960px,`useCompactViewport` 判定)下选中 ≥1 个素材时,批量操作栏在行2 之下
   新增**整行「下载」按钮**(高度 44、icon Download、文案带计数 `下载 N`),遵循代码内已写明的
   「按行内追加」扩展约定;行2 的 2×2 网格与既有四按钮不动。
2. 点击「下载」走既有 `confirmBulkDownload`:≤20 个直接发起;>20 个弹确认(文案沿用并补一句
   移动端口径提醒)。
3. 移动端直连路径(无 FSA)逐文件之间加 **500ms 间隔节流**,降低浏览器对连续自动下载的拦截
   (首个立即发起,保留用户手势链路);桌面 FSA 路径不节流,行为不变。
4. 批量发起期间下载按钮进入 loading 态(`bulkDownloading` state),防重复点击;循环结束恢复。
5. toast 聚合:批量路径逐文件的「已交给系统下载」toast 抑制(`downloads.start` 新增 `opts.silent`),
   循环结束输出一条汇总(`已发起 N 个下载`);单文件路径(卡片行内按钮、桌面行内按钮)toast
   行为不变。
6. 403/失败分流口径与现状完全一致(申请弹窗、聚合计数),不新增权限门控(下载按钮不做 disabled,
   与桌面批量栏口径一致,权限由后端 presign 403 兜底)。
7. 桌面布局回归不受影响:桌面批量下载按钮、行内下载、FSA 流式路径行为均不变(仅结束时新增一条
   汇总 toast,属可接受改善)。

## 数据库修改方案

不涉及。

## 接口定义

不涉及新接口/入参变更。复用既有 `useDownloadLink`(GET presigned 下载链接,`as_attachment`
可选)与 `downloads.start(url, filename, { assetId })` 契约;后者仅新增可选字段 `silent?: boolean`
(纯前端 store 内部契约,不触网)。

## 前端改动点

### A. `web/src/lib/download-store.tsx`

1. `start()` 的 `opts` 增加可选 `silent?: boolean`:仅移动端直连分支生效,为 true 时不弹单文件
   `message.success` toast(任务登记保留)。FSA 分支本无 toast,传 silent 无副作用。
2. 导出 `hasFSA()`(现私有函数改 `export`),供 ProjectDetailPage 判断是否走节流。

### B. `web/src/pages/ProjectDetailPage.tsx`

1. `handleBulkDownload`:新增 `bulkDownloading` state 包裹 try/finally;循环逐文件调用
   `downloads.start(..., { assetId: id, silent: true })`;`!hasFSA()` 且非最后一个文件时
   `await` 500ms 间隔;累计成功数,循环结束 `message.success(\`已发起 ${ok} 个下载\`)`
   (ok>0 时);异常分流逻辑不动。
2. `confirmBulkDownload` 确认弹窗 content 补移动端口径一句(如「手机浏览器可能拦截部分自动
   下载,未完成的请逐个或分批重试」)。
3. compact 批量操作栏:行2 网格之后追加行3 整行下载按钮(`<Button style={{height:44}}`
   `icon={<Download size={14}/>}` block 占满、`loading={bulkDownloading}`、无 disabled 门控、
   onClick=`confirmBulkDownload`),同步更新该处布局注释(扩展约定已兑现的口径)。

### 不许碰

- 行2 四按钮的布局/门控/文案;桌面 actions bar;AssetCardList;后端 api;Flutter App。

## 后端改动点

不涉及。

## 测试功能点

1. compact 视口多选 ≥1 → 批量栏出现整行下载按钮,文案带计数;行2 仍为 2×2 四按钮。
2. 选 2 个可下载文件点下载 → 逐个发起;移动端直连路径两次 `<a>` 点击间隔 ≥500ms;结束时一条
   「已发起 2 个下载」汇总;无逐文件 toast 刷屏。
3. 选 >20 个 → 弹确认,确认后才发起;取消则不发。
4. 批量发起期间按钮 loading,不可重复触发。
5. 含 403 资产:已加载项弹申请弹窗;未加载项出现「N 个未加载文件无下载权限」warning。
6. 含普通失败资产:已加载项逐条 error;未加载项出现聚合计数。
7. 单文件下载(卡片行内/桌面行内)toast 行为不变(silent 仅批量路径传入)。
8. 桌面视口回归:桌面批量栏/行内下载可用,FSA 路径无 500ms 节流,无越界 UI 变化。
9. `npm run build`(tsc -b && vite build)与 `npm run lint` 通过。
10. 320px 最小视口下批量栏三行布局不横向溢出(下载整行按钮全宽)。

## 模糊点与决策记录(自主决策,用户未在线)

| 模糊点 | 选项与决策 |
| --- | --- |
| 「移动端」指 web compact 还是 Flutter App | **web compact**。Flutter App 无多选 UI(B5 未交付),「已有批量操作但缺下载」唯一匹配 web compact;App 侧批量属另期。 |
| 移动端连续下载被浏览器拦截的对策 | **节流循环(500ms)+确认弹窗提醒**,不做服务端 ZIP 打包。ZIP 需后端新端点+GB 级流式打包,属范围扩大的新方案;先按用户原话「补充上」以最小改动复用既有链路,ZIP 作为后续建议记入遗留。 |
| 第 5 个按钮布局 | **行3 整行追加**,遵循代码注释既有扩展约定(「后续新按钮按行内追加」),不动已实证的 2×2 溢出钉子;整行按钮同时给新能力更好的触达。 |
| 批量 toast 刷屏 | **silent 抑制 + 结束一条汇总**;单文件路径不变。 |
| 下载按钮权限门控 | **不加 disabled**,与桌面批量栏一致(presign 403 → 申请弹窗兜底)。 |

## 验收与测试证据

(执行后回填)
