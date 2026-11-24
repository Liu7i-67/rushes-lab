# App 快速滚动条 — 测试用例清单(专职测试执行版)

> 需求正本:`docs/qdev/2026-11-24-app-fast-scroll.md`(唯一需求依据)。
> 基线:liuqi @ 38b6c09;分支 feat/app-fast-scroll;worktree `E:\qbb\github_not_me\rushes-lab-feat-app-fast-scroll`。
> 本文件是**供专职测试执行的结构化用例清单**,不含实现代码与可执行测试代码。
> 用例统计:自动化 T1–T36(36 条)/ 手工真机 H1–H9(9 条)/ 回归 R1–R16(16 条),共 61 条。

## 执行环境与通用编排约定(自动化用例通用,后文不再重复)

- 执行命令:`material-storage/app/` 下 `flutter test`;Flutter SDK `E:/qbb/soft/flutter`。
- widget 测试假 API 体系:`test/helpers/api_harness.dart`(FakeMsApi/FakeAssetsApi/FakeOpsApi,`session.api` 注入 + `addTearDown` 清理);现状 `FakeAssetsApi` **没有** `list` 桩,需仿 `assets_page_refresh_test.dart` 的 `_CountingAssetsApi` 模式自建/扩展「分页记录式假 AssetsApi」。
- **分页假 AssetsApi 编排约定**:生成 `total` 条假资产(id=`a<i>`,createdAt 严格递增:`2026-01-01T00:00 + i 分钟`),任意 `(limit, offset)` 返回后端 DESC 序对应切片(DESC 序 offset=0 是最新一条 a<total>;ASC 显示序 0 = a1 最旧);每次调用记录 `(limit, offset)` 供断言;支持 `Completer` 挂起/放行以编排并发与代际。
- 视口:`tester.view.physicalSize = Size(800, 1200)`、`devicePixelRatio = 1.0`(参照 trash_page_test 用法),收尾 `tester.view.reset`。
- 拖动模拟:`tester.startGesture(右缘轨道坐标)` + `moveTo` + `up`;时间相关禁 fakeAsync 混异步 IO(项目约定)。
- 口径钉死点(实现若不同需先回写需求文档「模糊点与决策记录」再判):
  - 「一页余量」按需求 F3 取 200(与宫格 `_pageSize` 同值);
  - 气泡取整:T17 主断言用 f=0.5(floor=round 无歧义),非整点位默认按 floor 记;
  - 补齐批次切分:缺口按 `limit=500` 从低 offset 到高 offset 依次切批、`Future.wait` 并行。

---

## 一、自动化用例(widget 测试层复验)

### A. PagedWindow 纯单测(`lib/core/paged_window.dart`,不依赖 Flutter)

#### T1 assetAt — DESC 显示序映射
- 前置:`PagedWindow(total=2000, loaded=200, descending=true)`;items=后端 DESC 前 200 条(items[0]=最新)。
- 操作/期望:`assetAt(0, items)` 返回 items[0];`assetAt(199, items)` 返回 items[199];`assetAt(200, items)` 返回 null(骨架区);`assetAt(1999, items)` 返回 null。
- 涉及:paged_window.dart(纯单测)。

#### T2 assetAt — ASC 已加载区在显示序尾部
- 前置:`PagedWindow(total=2000, loaded=200, descending=false)`;items 同上(最新 200 条,items[0] 最新、items[199] 是其中最旧)。
- 操作/期望:`assetAt(1799, items)` 返回 null(骨架在头部 [0,1800));`assetAt(1800, items)` 返回 items[199](ASC 显示序 1800 = 已加载区最旧一条);`assetAt(1999, items)` 返回 items[0](显示序末位=最新一条)。
- 涉及:paged_window.dart。

#### T3 offsetWindowFor — DESC 窗口/clamp/全已加载返 null
- 前置:`PagedWindow(total=2000, loaded=200, descending=true)`。
- 操作/期望:
  - `offsetWindowFor(0, 200)` = null(区间全已加载);
  - `offsetWindowFor(200, 700)` = `(200, 500)`;
  - `offsetWindowFor(150, 300)` 起点不重拉已加载区(期望 `(200, 300)`,或实现返回 `(150,300)` 由加载侧按缺口去重——需求语义是「缺口分批」,判 pass 以「实际请求不覆盖 [0,200)」为准);
  - `offsetWindowFor(1900, 2100)` 终点 clamp → `(1900, 2000)`;
  - `offsetWindowFor(2100, 2200)` 越界无未加载部分 → null。
- 涉及:paged_window.dart。

#### T4 offsetWindowFor — ASC 反转窗口
- 前置:`PagedWindow(total=2000, loaded=200, descending=false)`。
- 操作/期望:
  - `offsetWindowFor(0, 400)` = `(1600, 2000)`(offset = total − displayEnd = 2000−400 起);
  - `offsetWindowFor(1700, 2100)` displayEnd clamp → `(0, 300)`;
  - `offsetWindowFor(1800, 2000)`(全已加载区)→ null;
  - 部分重叠区(如 `offsetWindowFor(1750, 1900)`,已加载覆盖 offset [0,150)):期望返回非 null 窗口,且**实际请求不重复拉已加载部分**(以假 API 请求记录断言 offset ≥ 200 对应段);若实现直接裁剪窗口返回 `(200, 250)` 亦 pass,判据落在「不重复请求」。
- 涉及:paged_window.dart。

#### T5 displayIndexOf — 气泡/定位换算与 clamp
- 前置:`PagedWindow(total=2000, loaded=200)`,各构造 DESC 与 ASC 两实例。
- 操作/期望:
  - DESC:`displayIndexOf(0)`=0;`displayIndexOf(500)`=500;`displayIndexOf(-5)`=0(clamp 下限);`displayIndexOf(2500)`=1999(clamp 上限 total−1)。
  - ASC:`displayIndexOf(0)`=1999(后端最旧 offset 0 ↔ 显示序末位);`displayIndexOf(1999)`=0;越界 clamp 同上。
- 涉及:paged_window.dart。

#### T6 零值与满载边界
- 前置/操作/期望:
  - `total=0`:`assetAt(0)=null`;`offsetWindowFor(0,10)=null`;`displayIndexOf(0)`=0(clamp 下限 0,不得出现 −1 越界)。
  - `total=2000, loaded=0`:任意 `assetAt`=null;`offsetWindowFor(0,200)`=`(0,200)`。
  - `total=200, loaded=200`(满载):`assetAt(0..199)` 全命中 items;`offsetWindowFor(0,200)`=null;`displayIndexOf(199)`=199。
- 涉及:paged_window.dart。

### B. 宫格页接入(assets_page / assets_body / fast_scroll_bar / asset_tile)

#### T7 滚动条显隐四态(total≥100 才显示;loading/error/empty 隐藏)
- 前置:分页假 AssetsApi 可控 total;视口 800×1200。
- 操作/期望(四个子场景,各自 pump `AssetsPage`):
  1. 首拉挂起(Completer 不放行)→ 整页 ListSkeleton,`find.byType(FastScrollBar)`(或实现约定 key,下同)findsNothing;
  2. 首拉注入异常 → ErrorView 态,findsNothing;
  3. total=0 → 空态引导,findsNothing;
  4. total=2000、首拉完成 → findsOneWidget。
- 涉及:assets_body.dart / fast_scroll_bar.dart。

#### T8 阈值边界 total=99/100
- 前置:假 API total=99 → 首拉完成;再换 total=100。
- 操作/期望:total=99 时滚动条 findsNothing;total=100 时 findsOneWidget(≥100 显示,含等于)。
- 涉及:assets_body.dart。

#### T9 多选态隐藏与恢复
- 前置:total=2000、首拉完成、滚动条可见。
- 操作:长按首个格子进入多选;再点页头「取消」退出。
- 期望:进入多选后 `find.byType(FastScrollBar)` findsNothing(此时拖动热区不可命中,对轨道位置 startGesture 无 jumpTo 效果);退出后 findsOneWidget。
- 涉及:assets_page.dart / assets_body.dart。

#### T10 itemCount=total 与骨架/正常分区渲染(DESC 骨架在尾)
- 前置:total=2000、首拉 200。
- 操作/期望:
  1. 首拉完成后显示序 [0,200) 渲染正常 `AssetGridTile`(文件名可见),显示序 ≥200 渲染 `AssetTileSkeleton`(灰底圆角块,`find.byType(AssetTileSkeleton)` findsWidgets);
  2. GridView maxScrollExtent 按全量撑满:经 ScrollController 断言 `maxScrollExtent` 明显大于 200 条模型值(可对比 total=400 时单调增大),拖动到列表末端无 RangeError/越界异常;
  3. 骨架格与 `AssetGridTile` 同尺寸结构(3 列 aspectRatio 0.72 布局不破)。
- 涉及:assets_body.dart / asset_tile.dart。

#### T11 拖动释放 onSeek → 缺口并行补齐批次正确(高危:批次切分口径)
- 前置:total=2000、首拉 200;假 API 记录请求且可挂起。
- 操作:在滚动条轨道 62.5% 高度处 startGesture,moveTo 微调后 up(释放),pump。
- 期望:
  1. 收到 onSeek,目标显示序 ≈1250(f=0.625×2000,允许 ±视口内偏差,以实现换算为准);
  2. 假 API 收到**且仅收到** 3 个补齐请求:`(offset=200, limit=500)`、`(700, 500)`、`(1200, 250)`(目标=补齐 [0, 1250+余量200)=1450;若实现「余量」≠200,本用例暴露差异,先钉死口径再判);
  3. 三批并行:三个请求在任一响应放行前均已发出(用 Completer 挂住全部三批后断言记录数=3);
  4. 全部放行后 `_items.length`=1450、无重复 id、按 createdAt DESC 全序;显示序 1250 附近格子渲染真实文件名;
  5. 首页已加载的 (0,200) 区间**未被重复请求**。
- 涉及:assets_page.dart / fast_scroll_bar.dart。

#### T12 快速滚动进骨架区触发补齐,无请求风暴
- 前置:total=2000、首拉 200;假 API 记录请求。
- 操作:不经滚动条,直接对 GridView 手势连续 fast drag(惯性 fling)跳入显示序 ~600 骨架区;pump 多帧,期间 itemBuilder 多次命中骨架。
- 期望:
  1. 触发补齐:收到 (200,500) 起的缺口请求;
  2. 在途期间继续滚动/重建,同一 offset 窗口请求**不重复出现**(假 API 记录中 (200,500) 恰一次);在途只挂 pendingTarget 不并发第二组;
  3. 补齐落地后原骨架区填充真实 tile。
- 涉及:assets_page.dart / assets_body.dart。

#### T13 pendingTarget 续补链(高危:在途二次 seek)
- 前置:total=2000、首拉 200;假 API 全部请求可挂起(Completer 队列)。
- 操作:①拖动释放 seek 至 ~1250(批次 A 发出并保持挂起);②不等待,立即再拖动释放 seek 至 ~1900;③放行批次 A;pump;④放行后续批次。
- 期望:
  1. 步骤②时 `_loadingMore` 在途,**不并发**发第二组请求(记录数不变,只记 pendingTarget);
  2. 步骤③后自动续补:缺口 [1450, 2000) 发出 `(1450,500)`、`(1950,50)` 两批;
  3. 全部落地后 `_items.length`=2000,请求链完整无重复窗口,全序 DESC 无重复 id。
- 涉及:assets_page.dart。

#### T14 500 上限边界:非整页 total=501 / 999
- 前置/操作/期望(两组):
  1. total=501、首拉 200;拖动释放 seek 到最底 → 缺口 [200,501) 恰一批 `(200, 301)`(limit≤500 不再切);合并后 501 条,末位渲染真实 tile,页头「共 501 个素材」;
  2. total=999、首拉 200;seek 到最底 → 两批 `(200,500)`、`(700,299)`;合并后 999 条,页头「共 999 个素材」,无重复 id。
- 涉及:assets_page.dart。

#### T15 ASC 升序 + 快速滚动条混合 offset 换算(高危:D8 核心路径)
- 前置:total=2000、首拉 200(DESC);点页头排序 chip 切「最早优先」(骨架翻到显示序头部,允许滚动位置跳动)。
- 操作:拖动滚动条到顶部 f≈0(displayIndex≈0)释放;pump。
- 期望:
  1. 请求窗口落在后端**最旧端**:主断言 `offset + limit = 2000`(拉到 offset 0 一侧;按口径期望 `(1600, 400)`,其中 displayEnd=视口末+余量,若实现余量/视口取值不同以 `offset+limit=2000` 为判);
  2. 落地后显示序头部渲染 a1(createdAt 最早),头部不再是骨架;显示序中段仍骨架;
  3. 再点 chip 切回「最新优先」:头部恢复 a2000 等最新数据、骨架回尾部,无重复、无错位。
- 涉及:assets_page.dart / paged_window.dart。

#### T16 RefreshBus 静默刷新与拖动补齐并发(高危:D6 去重兜底)
- 前置:total=2000、首拉 200;拖动释放 seek 1250,补齐三批全部挂起(Completer)。
- 操作:补齐在途时 `RefreshBus.I.invalidate('assets:f1')` 触发静默刷新(其请求立即放行,返回首页 [0,200));随后放行补齐三批。
- 期望(钉死):
  1. 全程无 crash、无越界异常、列表不闪错误态;
  2. 最终列表**无重复 id**(D6);
  3. 补齐完成后 loaded 区仍覆盖 seek 目标(≈1450)——静默刷新 swap 不得把已补齐数据截回首页 200;若实现为「swap 截回+骨架重现」,属口径变更,须先回写需求模糊点表,再按新口径判;
  4. 若静默刷新返回 total 变化(可编排 total=1999),窗口模型与滚动条同步更新、骨架区无越界。
- 涉及:assets_page.dart / refresh_bus.dart。

#### T17 气泡「~N / M」取整与视口 clamp
- 前置:total=2000、首拉 200、滚动条可见。
- 操作/期望(拖动中按住不松手逐点断言):
  1. thumb 停在轨道 50%:气泡文本为 `~1000 / 2000`(f=0.5 时 floor=round=1000,无取整歧义);
  2. thumb 拖到轨道顶端:N≈0(文本含 `~0` 或实现 clamp 最小 1,以钉死口径判),气泡完整可见(y 坐标在视口内,不出屏);
  3. thumb 拖到轨道底端:文本 `~2000 / 2000`,气泡仍 clamp 在视口内;
  4. 松手(onVerticalDragEnd)后气泡消失(`find.textContaining('~')` findsNothing);
  5. 非整点位(可编排 total=2001、f 使 f×total=1000.5):期望 `~1000`(floor)或 `~1001`(round)——默认按 floor 记,开发钉死后二选一,本子项用于暴露未钉死。
- 涉及:fast_scroll_bar.dart。

#### T18 thumb 高度、最小 40dp 生效条件、28dp 热区、实时跟随
- 前置:分页假 API;视口 800×1200。
- 操作/期望:
  1. total=20000(超大,thumb 比例值 <40):thumb 渲染高度 ≥40 逻辑像素(`tester.getSize(thumb finder).height >= 40`,最小高度生效);
  2. total=150(略高于阈值,thumb 比例值 >40):thumb 高度 = 轨道高 × viewport/maxScrollExtent(断言 >40 且与比例值偏差 ≤2px,不被 40 clamp);
  3. 热区:从右缘向内 14dp 处 startGesture 可命中拖动(手势 widget 宽度 ≥28 断言或行为断言);视觉条宽 ~4dp;
  4. 非拖动滚动列表(普通 drag GridView)时 thumb 位置 y 实时跟随(逐帧断言 thumb y 单调变化,方向与滚动一致)。
- 涉及:fast_scroll_bar.dart。

#### T19 骨架格不可交互,onOpen 仅已加载项生效
- 前置:total=2000、首拉 200。
- 操作/期望:
  1. 跳到骨架区,tap 骨架格 → 无预览路由 push(预览页 finder findsNothing)、无异常;longPress 骨架格 → 不进入多选(页头仍显示夹名而非「已选」);
  2. tap 已加载区格子 → 预览打开且首图为该格资产(传参见 T25);
  3. 骨架格无 InkWell 水波/选中勾(不可选中态)。
- 涉及:assets_body.dart / asset_tile.dart。

#### T20 回归-滚到底自动加载保持
- 前置:total=400、首拉 200。
- 操作:普通手势把 GridView 拖到底(extentAfter<200)。
- 期望:自动发出补齐请求(期望 `(200,200)`,或骨架命中与 extentAfter 双路径合一,判据=合并后 400 条、无重复、`(200,200)` 至少一次且无重复窗口);继续滚不再发请求(守卫 `_items.length >= _total`)。
- 涉及:assets_page.dart / assets_body.dart。

#### T21 回归-加载失败重试条保持
- 前置:total=400;补齐请求注入异常。
- 操作:滚到底触发补齐 → 失败;点底部重试条。
- 期望:失败时 toast「加载失败,请重试」+ 底部红字重试条「加载失败,点击重试」;loadingMore 在途时重试条隐藏、显示 LinearProgressIndicator;点重试条重发成功后合并 400 条、重试条消失。
- 涉及:assets_body.dart。

#### T22 回归-下拉刷新三态保持
- 前置:total=2000。
- 操作/期望:
  1. 列表态下拉 → 整页重拉(记录 (0,200) 请求),`_items` 重置为首页 200、窗口模型重置、骨架区恢复正确、滚动条仍显示,无重复;
  2. 首拉挂起(ListSkeleton 态)下拉亦可触发刷新(AlwaysScrollable 包装);
  3. 首拉失败注入 → 整页 ErrorView + 重试按钮,点重试成功恢复。
- 涉及:assets_body.dart。

#### T23 回归-RefreshBus 静默刷新 swap 保持
- 前置:假 API 第 1 次返回 200 条,第 2 次(静默)返回 201 条(新增 a201);total 同步。
- 操作/期望:invalidate('assets:f1') → 无整页 spinner(CircularProgressIndicator findsNothing)、旧列表保留、a201 出现;静默注入异常 → 保留旧列表 + 仅日志,无整页错误;静默后窗口模型 loaded=新 items.length、total=新值,滚动条同步;多选中失效 id 剪枝(长按 a1 后 invalidate 且新页无 a1 → 「已选」计数减一)。
- 涉及:assets_page.dart(既有 assets_page_refresh_test 四用例须保持绿)。

#### T24 回归-升序切换数据正确
- 前置:total=2000、首拉 200。
- 操作/期望:点「最新优先」chip → 文案变「最早优先」;已加载 200 条重排为 ASC(显示序尾部=最新),骨架区移到显示序头部(顶部格子为 AssetTileSkeleton);切回 DESC 头部恢复最新数据、骨架回尾部;来回切换无重复、无越界;PagedWindow.descending 已翻转(T2 行为随之正确)。
- 涉及:assets_page.dart。

#### T25 回归-预览入口传参正确(高危:ASC 下显示序↔_items 下标对齐)
- 前置:total=2000、首拉 200。
- 操作/期望:
  1. DESC:点显示序 5 的格子 → 预览打开,首图=该格显示的同一资产;预览内前后滑顺序=DESC(下一格=显示序 6);
  2. ASC(高危):切「最早优先」后点显示序 1999 格(已加载区首格)→ 预览首图=该格显示的资产;若实现把显示序直接当 `_items` 下标传入 `openAssetPreview` → 此格会错位/越界,本用例抓出;
  3. 从预览返回宫格,滚动位置保持、选中态保持。
- 涉及:assets_page.dart(_open)/ preview 相关。

#### T26 回归-缩略图 small 变体与预热保持
- 前置:total=2000、首拉 200;假 API 记录 thumbnailUrls 调用。
- 操作/期望:
  1. 宫格 cell 缩略图走 small(240px)变体(现状 `variant: ThumbVariant.small` 不回退);
  2. 首拉预热 prewarm small(既有 assets_page_prewarm_test 保持绿);滚到底增量页预热 small 保持;
  3. 补齐批次的增量预热:需求 F5 只要求现状行为不回退,补齐批是否预热以开发口径记录(不判红,但须记录进需求模糊点表)。
- 涉及:assets_body.dart / thumb_prewarm.dart。

#### T27 回归-多选全选与批量动作在 total 模型下语义保持
- 前置:total=2000、首拉 200。
- 操作/期望:进多选 → 点「全选」→ 选中数=200(仅已加载项,**不得**静默扩为 2000;若实现改为全量选择属行为变更,须需求侧确认后判);底部选择栏计数「已选 200 项」、全选态高亮(`allSelected` 条件现状=`selected.length >= _items.length`);批量删除 200 条成功 → invalidate 静默刷新 → total=1800、窗口模型与滚动条同步更新、无重复。
- 涉及:assets_page.dart / asset_selection_bar.dart / selection_actions.dart。

### C. 回收站接入(trash_page)

#### T28 回收站滚动条显隐四态
- 前置:FakeOpsApi trashStaged 可编排 total。
- 操作/期望:pump `TrashPage`:
  1. total=1200、首拉 500 完成 → FastScrollBar findsOneWidget;
  2. total=99 → findsNothing;
  3. total=0 → 空态「回收站是空的」,findsNothing;
  4. 首拉注入异常 → ErrorView,findsNothing。
  另:回收站页无排序切换入口(页头无排序 chip),PagedWindow 恒 descending=true。
- 涉及:trash_page.dart。

#### T29 回收站 itemCount=_total + 骨架行 + 拖动补齐批次
- 前置:total=1200、首拉 500。
- 操作/期望:
  1. 显示序 [0,500) 渲染真实 AppCard 行,≥500 渲染骨架行(灰条,行高≈AppCard 行,布局不跳);ListView 可滚到显示序 1199 无越界异常;
  2. 拖动滚动条 seek 到 ~900 释放 → 缺口 [500,1100) 两批 `(500,500)`、`(1000,100)` 并行发出;落地后无重复 id、显示序 900 附近为真实行;
  3. total=501(非整页):首拉 500,seek 到最底 → 恰一批 `(500,1)`;合并后 501 行,页头「共 501 个已删除文件」。
- 涉及:trash_page.dart。

#### T30 回收站恢复一条后 total−1 与滚动条更新
- 前置:total=1200、首拉 500;滚到显示序 ~300 使中段行可见。
- 操作:点某行「恢复到文件夹」;pumpAndSettle。
- 期望:restore 调用一次;该行移除;`_total`=1199 且 ListView itemCount=1199;滚动条随之更新(总长/位置按新 total),无 RangeError、滚动位置不跳顶;toast「「文件名」已恢复至 夹名」。
- 涉及:trash_page.dart。

#### T31 回收站 _restore 与补齐并发(高危:offset 对齐与去重)
- 前置:total=1200、首拉 500;补齐批次挂起(Completer);已加载区某行可见。
- 操作:补齐在途时点该行「恢复」;restore 成功后再放行补齐批次。
- 期望:
  1. 全程无 crash/越界;最终无重复 id(D6);
  2. `_total`=1199、itemCount=1199、页头计数一致;
  3. 补齐数据合并后窗口自洽:任意已渲染行与假 API 数据一致、无错位(恢复发生在已加载区且后端同步移除,offset 天然对齐——若实现合并后出现错位/重复即红)。
- 涉及:trash_page.dart。

#### T32 回收站回归-滚到底自动加载与重试条保持
- 前置:total=600、首拉 500;第二组注入异常后恢复。
- 操作/期望:ListView 拖到底(extentAfter<200)→ 自动发 `(offset=500, limit=100)`;注入异常时 toast + 红字重试条,点重试成功合并 600 行;不再多发(守卫)。
- 涉及:trash_page.dart(既有 E10 用例语义保持)。

#### T33 回收站回归-恢复流全链保持
- 前置:trashStaged 返回 2 行(含 deletedAt/sizeBytes)。
- 操作/期望:点恢复 → trailing 18×18 spinner(restoringId)期间不可重复点;成功后行移除 + toast;`notifyAssetMutation` 失效 `assets:<folderId>` 与 `folders` 两 scope(挂监听计数均 >0);restore 注入异常 → 行保留 + 「恢复失败,请稍后重试」toast。
- 涉及:trash_page.dart(既有 trash_page_test「列表渲染+恢复」用例保持绿)。

#### T34 回收站回归-下拉刷新/空态/错误态/副标题保持
- 前置/操作/期望:
  1. 列表态下拉刷新 → 重拉 (0,500),total/窗口/滚动条同步;
  2. total=0 → 「回收站是空的」+ 描述文案,页头副标题隐藏(现状 `_total > 0 ? … : null`);
  3. 首拉失败 → ErrorView + 重试,恢复后列表正常;
  4. 行内容:kind 图标(trashKindIcon)、大小、删除于日期渲染不变。
- 涉及:trash_page.dart。

#### T35 回归-canSeeTrash 闸门与菜单入口保持
- 验证方式:既有纯函数三态用例(trash_page_test.dart 首个 test)保持绿;菜单走查:普通夹 my_can_admin 可进、仅 my_delete_grant 可进、两皆无不可进;敏感夹非系统 admin 禁用并显示「仅系统管理员可查看」、系统 admin 可进。本期不得改闸门逻辑。
- 涉及:trash_page.dart / folder_menu。

#### T36 工程闸:analyze 与全量测试
- 期望:`flutter analyze` 0 issues;`flutter test` 全量不红(重点盯既有 `assets_page_refresh_test`、`trash_page_test`、`assets_page_prewarm_test`、`assets_polish_test`、`filmstrip_test`、`preview_*` 族)。
- 涉及:全仓。

---

## 二、手工/真机用例

#### H1 真机拖动手感:实时跟手
- 前置:真机安装本分支包;登录账号可见一个 ≥1000 个素材的文件夹(不足可用脚本造数)。
- 步骤:进该文件夹宫格页;手指按住右缘滑块连续上下拖动全程不松手,往复 3 次;中途停顿观察。
- 期望:列表随手指**实时连续**滚动(jumpTo 跟手,无「松手才跳」「拖动中卡住不动」),无明显跳变/回弹;松手后列表立即停在当前位置;全程不掉帧到肉眼可感知卡顿。

#### H2 拖动中骨架 → 释放后图片出现
- 前置:同 H1 文件夹(total≥1000,首屏仅前 200 已加载)。
- 步骤:拖动滑块到 ~60% 位置,观察拖动中视口内容;松手停在中部骨架区,计时观察填充。
- 期望:拖动进入未加载区时视口显示灰色骨架格(非白屏、非错误);松手后 1–2 秒内骨架被真实缩略图格子替换,文件名/类型角标正确;骨架期间不可误触发出预览。

#### H3 多选态滚动条隐藏
- 前置:≥100 素材文件夹,滚动条可见。
- 步骤:长按任一格子进入多选;再点「取消」退出;重复一次。
- 期望:多选态下右缘滚动条完全消失(不残留轨道/热区,误触右缘不会拖动列表);退出后滚动条恢复且 thumb 位置与当前滚动位置一致。

#### H4 小文件夹无滚动条
- 前置:两个文件夹,total 分别为 99 与 100。
- 步骤:分别进入两个文件夹宫格页。
- 期望:99 个的文件夹不显示滚动条(右缘干净);100 个的显示(阈值 ≥100,D4);回收站页同理。

#### H5 暗/亮色主题 thumb 与气泡可辨性
- 前置:≥100 素材文件夹;设备系统深色/浅色各一遍(或应用内主题切换)。
- 步骤:两主题下各观察滚动条轨道、thumb、拖动气泡;拖到列表最顶/最底看气泡。
- 期望:两种主题下 thumb(gold 或 ink2)与背景、轨道均有可辨对比度(肉眼一找即见);气泡「~N / M」文字在两主题下均清晰可读、不被列表内容吃掉;气泡在最顶/最底被 clamp 在屏幕内不裁切。

#### H6 回收站恢复后滚动条位置正确
- 前置:回收站 total≥200(造数),首拉 500 内。
- 步骤:进入回收站,滚动/拖动到中部某行;点该行「恢复」;观察列表与滚动条。
- 期望:该行消失,总数副标题 −1;滚动条长度/位置随 total−1 更新,列表不跳顶、当前视口附近内容不闪变;连续恢复 3 条后仍稳定无越界。

#### H7 与上传 FAB/上传胶囊/底部选择栏不遮挡
- 前置:有上传权限的 ≥100 素材文件夹;真机竖屏。
- 步骤:①滚到列表最底,检查末行与上传 FAB;②发起一次上传,出现上传进度胶囊后滚到底再拖动滚动条到底;③进入多选(底部选择栏)确认滚动条隐藏;④拖动气泡到最底端。
- 期望:滚动条视觉条不压住 FAB/胶囊(右缘 ~4dp 条与底部浮动件无重叠或重叠但不互损点击);拖到底时末行完整可见(FAB 留白 padding 生效);气泡 clamp 不压 FAB;多选态下选择栏区域无滚动条残影。

#### H8 拖动热区手指可命中
- 前置:同 H1 文件夹。
- 步骤:用手指自然贴右缘上下滑动(不做精确定位),共 5 次;再故意偏内 10dp 滑动 3 次。
- 期望:贴右缘的滑动 5/5 命中拖动(≥28dp 热区);偏内 10dp 的滑动不误触(或命中与否与热区宽度实现一致);拖动不与列表自身滚动手势打架(命中滚动条时不带动列表惯性)。

#### H9 大文件夹端到端性能与稳定性
- 前置:2000+ 素材文件夹(造数);真机。
- 步骤:连续执行「拖到底→等补齐→拖回顶→切升序→拖到底」三轮;期间观察内存/CPU;结束后下拉刷新。
- 期望:无闪退、无 OOM;补齐期间 UI 可响应(并行分批,无长时间冻结);刷新后回到首页 200+骨架态正常;回收站页对 1200 条执行同款拖动一轮,恢复一条后一切正常。

---

## 三、回归清单(基于现状代码,本次改动最可能碰坏的既有行为)

| 编号 | 回归点(现状代码依据) | 验证方式 |
|---|---|---|
| R1 | 滚到底自动加载双保险:`assets_body._maybeLoadMore`(extentAfter<200)+ 页侧守卫 `_loadingMore \|\| _items.length>=_total`(assets_page.dart:154)。itemCount 改 total 后 maxScrollExtent 变大,触发时机可能变早/变晚/连环触发 | T20;真机 H9 滚到底观察请求 |
| R2 | 底部 LinearProgressIndicator(loadingMore 态,assets_body.dart:132-133):显示/隐藏时机 | T21 过程断言;真机滚到底目视 |
| R3 | 失败重试条 `_retryBar`(loadMoreFailed && !loadingMore,点击=onLoadMore):文案、红色 danger 样式、点击重发 | T21;回收站同 T32 |
| R4 | 下拉刷新三态可用:RefreshIndicator + AlwaysScrollable + `_scrollable` 包装(loading/error/empty 态也能拉) | T22;回收站 T34 |
| R5 | RefreshBus 静默刷新 swap:订阅 `assets:<folderId>`、不清旧列表、成功 swap、失败保留旧列表仅日志(assets_page.dart:134-151) | T23 |
| R6 | 代际守卫 `_fetchEpoch`:慢响应落地被丢弃,不覆盖新数据;全屏在途被静默丢弃时 loading 必清(既有 B3 遗留修复用例) | 既有 assets_page_refresh_test「全屏刷新在途+静默先完成」用例保持绿;补齐路径不得破坏代际语义(T13/T16 顺带覆盖) |
| R7 | 升序切换:header 排序 chip「最新优先/最早优先」文案切换 + `_toggleSort` 本地重排(assets_header.dart:99) | T24 |
| R8 | 预览入口传参:`_open(i)` → `openAssetPreview(context, _items, i, …)`(assets_page.dart:202)。新模型下 ASC 显示序 ≠ `_items` 下标,直接透传会错位/越界 | T25(高危);真机 ASC 下点已加载区末格验证预览首图 |
| R9 | 多选/全选/批量动作:`toggleAll(_items)` 只作用已加载项;bar `allSelected` 条件 `selected.length >= _items.length`;批量删除→invalidate 链 | T27 |
| R10 | 上传 FAB 底部留白(GridView padding bottom = `Tk.spaceXl*4`,assets_body.dart:149)+ UploadPillOverlay bottom 避让(assets_page.dart:290-295) | T22 刷新后仍留白;真机 H7 |
| R11 | 缩略图 small 变体与预热:cell `variant: ThumbVariant.small`(assets_body.dart:165)、首拉/增量页 `prewarmThumbUrls(small)`(assets_page.dart:103,175) | T26;既有 assets_page_prewarm_test 保持绿 |
| R12 | 空态引导 UploadEmptyGuide(canUpload=false 时隐藏引导钮,空文件夹文案「空文件夹」) | T7 场景3;既有 assets_page_refresh_test「my_can_upload=false」用例保持绿 |
| R13 | trash 恢复流:restore 调用→行移除→total−1→toast→`notifyAssetMutation` 双 scope 失效;restoringId spinner;失败行保留 | T30/T31/T33 |
| R14 | trash `canSeeTrash` 闸门与文件夹 ⋯ 菜单入口三态(纯函数+菜单禁用文案) | T35 |
| R15 | trash 行渲染与滚到底自动加载:trashKindIcon 分型、fmtBytes/删除时间、`(offset=500)` 自动加载(E10) | T29/T32/T34;既有 E10 用例保持绿 |
| R16 | 首载骨架与错误态文案:宫格 ListSkeleton(columns:3)、ErrorView message+retry、回收站 CircularProgressIndicator→(若改骨架行)加载态口径 | T7 场景1/2、T28 场景4;既有用例保持绿 |

---

## 附:本清单基于现状代码发现的口径钉死点汇总(执行前先与开发确认)

1. 「一页余量」取值(F3,本清单按 200)。
2. 气泡 N 取整 floor/round(T17;需求只写「取整」)。
3. `offsetWindowFor` 部分重叠已加载区时返回整窗还是裁剪窗(T3/T4;判据落在「不重复请求已加载区」)。
4. 静默刷新 swap 与补齐数据的关系:保留已补齐 vs 截回首页+骨架重现(T16;需求 D6 只写了去重,未写此场景)。
5. 补齐批次是否触发缩略图预热(F5 只要求现状不回退,T26 记录口径)。
6. ASC 下 `_open(i)` 的显示序→`_items` 下标换算(T25;现状代码 `_open` 直用下标,这是本次改动最易错点)。
