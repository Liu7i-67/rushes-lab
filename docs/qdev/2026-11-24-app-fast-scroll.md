# App 快速滚动条(大文件夹快速定位)需求文档

> qdev 需求正本。本文档是唯一需求依据,所有派发 prompt 引用本文。
> 基线:liuqi @ 38b6c09;分支 feat/app-fast-scroll;worktree `E:\qbb\github_not_me\rushes-lab-feat-app-fast-scroll`。

## 背景与目标

一个文件夹内可能有 2000+ 个文件,App 素材宫格页当前只能顺序滚动(每页 200 条追加),
想看列表尾部的内容要滚很久。列表接口已返回 `total` 全量计数且支持任意 `offset` 取数,
本期用它实现「正确高度的列表 + 右侧可拖动快速滚动条」:拖动滑块实时跟手跳转,
松手后按需加载当前视口数据,拖动中显示「~1250 / 2000」位置气泡。

覆盖页面(用户拍板):**素材宫格页 AssetsPage + 回收站页 TrashPage**。后端零改动。

## 功能点明细(逐条可验收)

### F1 分页窗口模型(lib/core/paged_window.dart,新建)
- 封装「显示序 ↔ 后端 offset 序」映射的纯 Dart 类 `PagedWindow`:
  - 字段:`total`(后端全量计数)、`loaded`(已加载条数)、`descending`(显示是否为后端原始 DESC 序)。
  - `Asset? assetAt(int displayIndex, List<Asset> items)`:显示序 index 命中已加载区返回数据,未命中返回 null(渲染骨架)。
    - DESC:已加载区 = 显示序 `[0, loaded)`(骨架在尾部)。
    - ASC(宫格页本地升序切换):已加载区 = 显示序 `[total-loaded, total)`(骨架在头部)。
  - `(int start, int end)? offsetWindowFor(int displayStart, int displayEnd)`:
    把显示序区间换算成后端 offset 窗口(ASC 时反转:`offset = total - displayEnd` 起),越界 clamp;区间无未加载部分返回 null。
  - `int displayIndexOf(int offset)`(气泡/定位用,clamp 到 [0, total-1])。
- 不依赖 Flutter,可纯单测。

### F2 快速滚动条组件(lib/widgets/fast_scroll_bar.dart,新建)
- `FastScrollBar`:Stack 内右缘覆盖的竖向拖动条,输入:
  - `controller`(列表的 ScrollController,读 offset/maxScrollExtent 与 jumpTo)、
  - `total`、`visible`(显隐由外部决定)。
- 行为:
  - thumb 高度 = viewport/maxScrollExtent 比例映射到轨道高,最小 40dp;位置实时跟随列表滚动(监听 controller)。
  - `GestureDetector.onVerticalDragUpdate`:拖动中按 thumb 在轨道中的比例 `f` 实时 `controller.jumpTo(f × maxScrollExtent)`(实时跟手);列表落入未加载区显示骨架(由 F3/F4 负责)。
  - 拖动中在滑块左侧显示气泡「~N / M」(N=f×total 取整,M=total);松手(`onVerticalDragEnd`)回调 `onSeek(int displayIndex)` 给页面触发补齐加载。
  - 拖动区热区宽度 ≥ 28dp(便于手指命中),视觉条宽 ~4dp,风格走 `context.tk` 令牌(参考 `TkColors.lineStrong` 注释:拖拽把手适用;thumb 用 `tk.gold` 或 `tk.ink2`,以暗亮两色都可辨认为准)。
  - 气泡自动避开:位置按 thumb 位置 clamp 在视口内。
- 纯 UI 组件,不含任何加载逻辑。

### F3 宫格页接入(assets_page.dart / assets_body.dart / asset_tile.dart 修改)
- `AssetsBody` 的 `GridView.builder` `itemCount` 从 `items.length` 改为 `total`(=「正确的高度」,
  maxScrollExtent 按全量撑满);`itemBuilder` 经 `PagedWindow.assetAt` 取数,未命中渲染骨架格子
  (新建 `AssetTileSkeleton`:灰底圆角块,与 `AssetGridTile` 同尺寸结构,复用 `ListSkeleton` 的骨架色风格)。
- 数据流:`AssetsPage` 持有 `PagedWindow`;`_loadMore` 泛化为 `_ensureVisibleLoaded(int displayEnd)`:
  - 目标=补齐显示序 `[0, displayEnd + 一页余量]` 覆盖的 offset 窗口;缺口按后端上限分批
    (`limit=500`,批间 offset 累进,`Future.wait` 并行),按 offset 序 append 后按 id 去重、
    再按当前 `_sortDesc` 全量重排(`sortAssetsByCreatedAt`)。
  - 在途守卫:`_loadingMore` 期间记录 `pendingTarget`,完成后继续补;`_fetchEpoch` 代际照旧。
  - 滚动触发现有 `extentAfter < 200` 逻辑保留;另在 itemBuilder 命中骨架时触发一次
    `_ensureVisibleLoaded(当前视口末尾)`(内部自带去重守卫,不会风暴)。
- `AssetsBody` 右缘叠加 `FastScrollBar`(F2);`selecting`(多选态)隐藏;
  `total < 100` 不显示;`loading/error/empty` 态不显示。
- 骨架格子不可点击/长按;`onOpen(i)` 只对已加载项生效(现状语义保持)。
- 升序切换 `_toggleSort`:重排 `_items` 后 `PagedWindow.descending` 同步翻转(骨架区从尾部换到头部,滚动位置允许跳动,不做动画)。

### F4 回收站接入(trash_page.dart 修改)
- 同 F3 模式:`ListView.separated` `itemCount=_total` + `PagedWindow`(恒 `descending=true`,无排序切换)+
  骨架行(灰条占位,行高近似 `AppCard` 行)+ `FastScrollBar`(同显隐阈值)。
- 补齐加载 `_ensureVisibleLoaded` 同款(单批 `limit=500`, trash 后端上限即 500);
  `_restore` 恢复后 `_total-1`、`_items.removeWhere`,窗口模型随之更新(前后端同步移除,offset 天然对齐)。

### F5 回归保持(全部现状行为不得变)
- 滚到底自动加载、底部 LinearProgressIndicator、失败重试条、下拉刷新、RefreshBus 静默刷新、
  上传 FAB 底部留白、多选/全选/批量动作、预览传参、缩略图 small 变体与预热,全部保持。
- `trash_page` 的恢复流、`canSeeTrash` 闸门不动。

## 组件拆分方案

| 组件/文件 | 动作 | 职责边界 | 预估行数 |
|---|---|---|---|
| `lib/core/paged_window.dart` | 新建 | 显示序↔offset 纯映射,无 UI | ~110 |
| `lib/widgets/fast_scroll_bar.dart` | 新建 | 滚动条 UI+手势+气泡,无数据逻辑 | ~230 |
| `lib/features/assets/assets_page.dart`(现 304) | 修改 | PagedWindow 接线、_ensureVisibleLoaded 并行补齐、升序翻转 | +~100 → ~400 |
| `lib/features/assets/assets_body.dart`(现 199) | 修改 | itemCount=total、骨架 tile、叠 FastScrollBar | +~70 → ~270 |
| `lib/features/assets/asset_tile.dart` | 修改 | 新增 AssetTileSkeleton(同文件小骨架件) | +~30 |
| `lib/features/assets/trash_page.dart`(现 291) | 修改 | 同款接入(ListView 版) | +~80 → ~370 |
| `test/core/paged_window_test.dart` | 新建 | F1 纯函数全分支 | ~150 |
| `test/features/assets_fast_scroll_test.dart` | 新建 | F3 行为+回归 | ~250 |
| `test/features/trash_fast_scroll_test.dart` | 新建 | F4 行为+回归 | ~200 |

依赖关系:包 B(宫格页)/包 C(回收站)依赖包 A(paged_window+fast_scroll_bar)的**接口**(本表+F1/F2 已定死),
按契约并行开发,互不等待。可复用资产:`ListSkeleton`(骨架色风格)、`HandleStrip`(onVerticalDrag 手势参考)、
`context.tk` 主题令牌、`test/helpers/api_harness.dart` Fake 体系(`FakeAssetsApi`/`FakeOpsApi`)、
`sortAssetsByCreatedAt`、`_fetchEpoch` 代际模式。

## 数据库修改方案

不涉及(后端 `AssetListOut.total` + offset 分页已具备,api/app/routers/assets.py:434,472)。

## 接口定义

不新增。既有接口用法变化:
- `AssetsApi.list(folderId, {limit, offset})`:`limit` 补齐批次用 500(后端 le=500);
- `AssetsOpsApi.listTrash(folderId, {limit, offset})`:同上,单批 500。

## 前端改动点 / 后端改动点

前端:见组件拆分方案。后端:无。

## 测试功能点

1. PagedWindow:DESC/ASC 两侧 assetAt/offsetWindowFor/displayIndexOf,边界(total=0、loaded=0、
   loaded=total、displayIndex 越界 clamp、ASC 反转窗口正确)。
2. 宫格页:total≥100 渲染出 FastScrollBar(find.byKey);<100 不渲染;多选态隐藏。
3. 宫格页:拖动释放(onSeek 回调/手势模拟)后 FakeAssetsApi 收到的 offset/limit 批次正确(缺口并行补齐)。
4. 宫格页:itemCount=total,未加载区渲染 AssetTileSkeleton;已加载区正常 tile。
5. 宫格页:快速滚动进入骨架区触发补齐(无风暴:在途只挂 pendingTarget)。
6. 宫格页回归:滚到底自动加载、失败重试条、下拉刷新、RefreshBus 静默刷新 swap、升序切换数据正确(ASC 下骨架在头部)。
7. 回收站:同 2/3/4;恢复一条后 total-1、滚动条随之更新;空态/错误态无滚动条。
8. 气泡:拖动中显示「~N / M」(widget 测试断言文本)。
9. analyze 0 issues + 全量既有测试不红。

## 模糊点与决策记录

| # | 决策 | 依据 |
|---|---|---|
| D1 | 范围=宫格页+回收站 | 用户拍板(2026-11-24) |
| D2 | 拖动实时跟手(jumpTo),释放后才补齐加载 | 用户拍板 |
| D3 | 拖动显示「~N / M」序号气泡 | 用户拍板 |
| D4 | 显示阈值 total≥100;loading/error/empty/多选态隐藏 | PM 定(小列表滚动条是噪音) |
| D5 | 不做稀疏窗口:保持 [0,n) 连续 append 模型,跳转缺口分批并行(limit=500)拉齐 | 改动最小、内存可控(2000 条 JSON ≈ MB 级),稀疏模型回归风险不成比例 |
| D6 | merge 按 id 去重兜底 | 静默刷新/恢复与补齐并发时防重复行 |
| D7 | 骨架=灰块格子/灰条,复用 ListSkeleton 风格,不做 shimmer 动画 | 简洁、与首载骨架一致 |
| D8 | ASC 升序时骨架在头部,由 PagedWindow 统一换算 | 宫格页有本地排序切换,offset 域是 DESC,必须换算 |
| D9 | 红线评估:可行、成本合理(后端零改动,3 新文件+4 改文件) | PM 评估 2026-11-24 |
| D10 | 气泡底端口径=「~total-1 / total」(N 是 0 基显示序,与 onSeek 同口径);取整用 round | 专职测试 T17 抓出未回写,PM 拍板 2026-11-24 保持现实现 |
| D11 | ASC 升序下「滚到底/任何补齐」= 从 loaded 邻接扩展直至覆盖目标(头部 seek 代价是近乎补满余量)——D5 连续前缀模型的固有约束 | P0-1 修复引入,PM 拍板 2026-11-24 |
| D12 | trash 恢复×补齐并发的 offset 天然对齐,前提=「在途响应反映请求时点的后端状态」;后端若恢复提交后才切片则会缺一行(未观测到,记前提) | 专职测试 P2-4 记录,暂不改码 |

## 项目约定(派发必带)

- Flutter SDK:`E:/qbb/soft/flutter`(PATH 无 flutter 时用绝对路径);`JAVA_HOME=E:/qbb/soft/java`。
- 命令(worktree `material-storage/app/` 下):`flutter analyze`、`flutter test`。
- 只 format 自己改的文件;既有功能不得删;代码风格贴现有文件(中文注释、library 头注释)。
- 单文件硬上限 500 行。
- 测试用 `test/helpers/api_harness.dart` 的 Fake 注入模式(`session.api = api`,addTearDown 清理);
  widget 测试里拖动可用 `WidgetTester.dragFrom`/`tester.startGesture+move` 模拟,时间相关禁 fakeAsync 混异步 IO。
