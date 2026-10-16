# 方案:盲搜跳转定位落地(方案 A + B 实施计划)

> 依据:[search-jump-locate-investigation.md](./search-jump-locate-investigation.md)(2026-10-16 调研)。
> 目标:消除「搜索命中点击后,跳到的文件夹第一页没有目标文件、翻很多页也找不到」的体验问题。
> 范围:**方案 A(搜索结果原地开详情,纯前端)+ 方案 B(服务端定位页码 + 深链高亮)**,
> A 先行、B 跟进,两者组合成交互闭环(调研报告推荐组合)。
> 无 DB migration、无 FGA model 变更、无新外部依赖。

## 1. 总体设计

交互闭环(改造后):

```
⌘K 面板命中 / SearchPage 行点击
        │ 点击 = 直接看文件(方案 A)
        ▼
  /search?q=…&focus=<asset_id>   ←─ Drawer 内容复用 AssetSummaryPanel(+预览/下载/分享)
        │ Drawer 内「在文件夹中查看」按钮(方案 B)
        ▼
  /folders/:folderId?asset=<asset_id>
        │ locate_index → 页码 → 取该页 → 滚动 + 高亮 + 自动开详情 Drawer
        ▼
  用户看到目标文件及其上下文(可 ‹ n/N › 浏览同页邻居)
```

两条原则:

- **URL 承载状态**:`focus` / `asset` 都是 query 参数,刷新、分享、回退均可重放;
  不引入 sessionStorage 等隐藏状态。
- **落点页不知晓 asset 数据也能工作**:方案 B 的落点页只靠 `locate_index` +
  分页窗口内按 id 找卡片,不需要新增单文件 GET 端点(响应窗口里本来就有完整
  `AssetOut`)。

## 2. 后端改动(方案 B):`GET /api/v1/assets` 加 `locate` 参数

### 2.1 API 契约

`GET /api/v1/assets?folder_id=…&locate=<asset_id>[&limit&offset]`
(`api/app/routers/assets.py` `list_assets`;`locate` 参数类型
`uuid.UUID | None = Query(None)` —— 与 `folder_id` 同惯例,非法格式由
FastAPI 直接 422;缺省行为完全不变)

响应 `AssetListOut`(`api/app/models/__init__.py`)新增可选字段:

```json
{ "items": [...], "total": 123, "locate_index": 87 }
```

- `locate_index: int | null = None` — 目标 asset 在**与列表完全相同的排序**
  (`created_at DESC, id DESC`,`WHERE deleted_at IS NULL`,本 folder 内)下的
  0 基序号;`locate` 缺省时恒 `null`。
- 返回 `null` 的情形:目标 id 不存在 / 已软删 / 不属于该 folder / `locate` 缺省。
  **不区分原因**——调用方只需「能定位 / 不能定位」两种结果,同时避免向已能
  list 该 folder 的用户之外泄露任何 asset 存在性(权限判定就是 list 自己的判定,
  locate 不构成新的权限面)。

> 取舍说明:也曾考虑独立端点 `GET /assets/locate?folder_id&asset_id`。不采纳:
> 复用 list 端点少一条 API 面,权限/过滤逻辑零重复;响应多回一个 `limit=1` 的
  items 窗口(前端首次探测调用用 `limit=1`)开销可忽略。字段可选,旧调用方零感知。

### 2.2 实现

`list_assets` 内,权限判定与 total 计算之后、窗口查询之前:

```python
locate_index: int | None = None
if locate is not None:
    # 单列 scalar:db.scalar 只回首行第一列(多列 select 是 Row,取 .created_at 必炸)
    target_created = await db.scalar(
        select(Asset.created_at).where(
            Asset.id == locate,
            Asset.folder_id == folder_id,
            Asset.deleted_at.is_(None),
        )
    )
    if target_created is not None:
        # 与列表同元组 (created_at DESC, id DESC):严格"更靠前"的行数 = 0 基序号。
        # id tiebreaker 不能省:批量上传 created_at 全并列,只比 created_at 会漂位;
        # target id 就是入参 locate 本身,无需回查。
        newer = await db.scalar(
            select(func.count()).select_from(Asset).where(
                Asset.folder_id == folder_id,
                Asset.deleted_at.is_(None),
                or_(
                    Asset.created_at > target_created,
                    and_(Asset.created_at == target_created, Asset.id > locate),
                ),
            )
        )
        locate_index = newer or 0
return AssetListOut(items=..., total=total or 0, locate_index=locate_index)
```

(`and_` 需补 import;`or_` / `func` 文件内已有。)

正确性不变式(测试锚点):对任意 folder 与目标 X,按 `locate_index` 反查
X 所在页窗口(`limit=页大小, offset=locate_index//页大小*页大小`)时,
返回的 items 里必含 `X.id` —— locate_index 与窗口排序天然自洽(此断言
与夹规模无关,>500 条的夹同样可验)。

### 2.3 测试(pytest,容器内;沿用 seed_demo_data 既有夹具模式)

新增 `api/tests/test_asset_locate.py`:

1. 正常定位:夹内多文件,`locate_index` 落在预期位置;并用 §2.2 不变式自检
   (断言按对齐窗口公式写:取 `offset = locate_index//页大小*页大小` 的窗口,
   `items[locate_index % 页大小].id == 目标 id`,与夹规模无关)。
2. created_at 并列(同秒批量):tiebreaker 生效,不变式仍成立。
3. `locate` 指向:已软删资产 → `null`;他夹资产 → `null`;随机 UUID → `null;
   缺省不传 → `null`;**malformed 非 UUID 字符串 → FastAPI 422**(类型声明兜底)。
4. 权限:无 can_view 用户带 locate 调用 → 与现状一致的 403(不是 404/null,
   权限判定先于一切);public 项目非敏感夹 / 系统 admin 直通路径各一条。
5. 分页窗口与 locate 共存:带 `limit/offset` 时 `locate_index` 仍是全量序号
   (不受窗口影响)。

## 3. 前端改动 — 方案 A:搜索结果原地开详情

### 3.1 SearchPage(`web/src/pages/SearchPage.tsx`)

- Drawer 开关改为 **URL 驱动**:`focusId = sp.get('focus')`;
  `focused = results?.find(r => r.id === focusId)`;
  Drawer `open = focused != null`。
  - 行点击:`setSearchParams({ q, focus: r.id })`(追加 focus,保留 q);
  - Drawer onClose:`setSearchParams({ q }, { replace: true })`(移除 focus;
    回退/刷新不再莫名重开)。
- Drawer 内容:`AssetSummaryPanel selected={[focused]} me={me} folder={focusFolder}`。
  - `me`:SearchPage 增挂 `useMe()`(AppShell 已取过,react-query 缓存命中,零额外请求)。
  - `focusFolder`:`useFolder(focused?.folder_id)`(hook 顶层无条件调用,
    `enabled` 由 focused 存在与否自然控制)——提供 `my_can_download` 等 gating,
    与 FolderDetailPage 的 Drawer 同构。
  - **抽屉形态复用 FolderDetailPage 底部抽屉同款**:`placement="bottom"` +
    **接入 `useKeyboardViewportHeight()`**(同 `FolderDetailPage.tsx:37,43`:
    键盘弹起时 `height = kbViewportHeight - 56`,否则 `min(72vh, 72dvh)`)。
    只写静态 `min(72vh, 72dvh)` 会让移动端软键盘盖住抽屉,compact 验收
    (§6.2-6)过不了。PC/compact 行为一致,不另造形态。
  - **单文件态:不做 ‹ n/N › 切换**(搜索结果跨夹遍历是二期可选,本期不扩)。
- Drawer `extra` 放「在文件夹中查看」按钮:
  `navigate(\`/folders/${focused.folder_id}?asset=${focused.id}\`)`(方案 B 深链)。
- 回归不变:命中高亮(`Highlight` 组件)、标签 chips、截断提示全部不动;
  `goFolder` 函数删除(整行点击语义已改)。

### 3.2 ⌘K 命令面板(`web/src/components/AppHeader.tsx` CommandPalette)

- 命中文件项的 action 从 `navigate(\`/folders/${r.folder_id}\`)` 改为
  `navigate(\`/search?q=${encodeURIComponent(debounced)}&focus=${r.id}\`)`
  —— 一步直达「文件详情」,同时把完整结果列表留在背后供继续浏览。
- 「搜全部文件」项(`/search?q=…`)不变。
- **存量缺陷顺带修(一行)**:面板 `onSelect` 目前以 `options.find(o => o.value === v)`
  按 value 反查(`AppHeader.tsx:441-445`),文件项 value = `文件 ${r.filename}`
  不含 id —— 同名文件多条时回车命中第一条(现行为跳错 folder,改造后会 focus
  到错资产)。本周期动 AppHeader,顺手把反查改为按 `opt.key` 匹配。

## 4. 前端改动 — 方案 B:落点页定位 + 高亮

### 4.1 hooks 与类型(`web/src/api/hooks.ts` / `types.ts`)

- `AssetList` 接口加 `locate_index?: number | null`。
- 新增独立 hook(不复用 `useAssets`,避免污染 `['assets', folderId, page, pageSize]` 页缓存):

```ts
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const useLocateAsset = (folderId?: string, assetId?: string | null) =>
  useQuery({
    queryKey: ['assets-locate', folderId, assetId],
    queryFn: async () =>
      (await http.get<AssetList>('/api/v1/assets', {
        params: { folder_id: folderId, locate: assetId, limit: 1 },
      })).data,
    // UUID 格式前置校验:手工改坏的链接不发起请求,走 §4.2 失败兜底
    // (否则 FastAPI 422 → 全局 queryCache.onError 弹「数据加载失败」)
    enabled: !!folderId && !!assetId && UUID_RE.test(assetId),
  });
```

- 缓存失效:现有删除/恢复/上传走 `['assets']` 前缀,不命中 `['assets-locate']`;
  在 `useDeleteAsset` / `useRestoreAsset` / `usePurgeAsset`(彻底删除同样让
  目标消失)的 onSuccess 里补
  `qc.invalidateQueries({ queryKey: ['assets-locate'] })`(目标被删后定位缓存不过夜)。
  上传成功会使同夹所有 `locate_index` 整体 +1,不额外失效——由 30s staleTime
  + §5 并发漂移兜底吸收,影响有界(见 §5 表)。

### 4.2 FolderDetailPage(`web/src/pages/FolderDetailPage.tsx`)

- 读参:`const [sp] = useSearchParams(); const focusAssetId = sp.get('asset');`
  **参数不主动清除**(刷新可重放;防重复触发靠下述一次性消费标记)。
- `const { data: locateData } = useLocateAsset(folderId, focusAssetId);`
- 定位页(沿用本页既有的 render 期比较惯例,不写 setState-in-effect):

```ts
const targetPage = locateData?.locate_index != null
  ? Math.floor(locateData.locate_index / ASSETS_PAGE_SIZE) + 1 : null;
// render 期比较:定位结果到达 → 跳页;幂等(同值 no-op)。
// 第二个条件:已消费后 locate 缓存失效重取(index 漂移)不再把用户拉回目标页
const [prevTarget, setPrevTarget] = useState<number | null>(null);
if (targetPage !== prevTarget && consumedAsset !== focusAssetId) {
  setPrevTarget(targetPage);
  if (targetPage) setPage(targetPage);
}
```

- 一次性消费(防 refetch 重弹抽屉)。**失败标记单列 `consumeOutcome`**,
  失败提示(toast)是跨组件副作用,严禁放 render 期 —— render 期只 setState
  本组件,toast 由下面的 effect 发:

```ts
const [consumedAsset, setConsumedAsset] = useState<string | null>(null);
const [consumeOutcome, setConsumeOutcome] = useState<'failed' | null>(null);
const [highlightId, setHighlightId] = useState<string | null>(null);
// 目标页数据到达后,在本页 items 里按 id 找。
// 门禁用 !isFetching(比 !isLoading 严格):keepPreviousData 下跳页首取
// isPending+isFetching → isLoading 其实为 true,但同 key 的后台 refetch
// 窗口只有 isFetching 能拦住 —— 用更严的口径,别「优化」回 !isLoading
const hitIndex = items.findIndex(a => a.id === focusAssetId);
if (focusAssetId && hitIndex >= 0 && consumedAsset !== focusAssetId && !isFetching) {
  setConsumedAsset(focusAssetId);   // 只消费一次,永不清空(防重弹的唯一闸)
  setHighlightId(focusAssetId);     // 视觉高亮,翻页/切夹时清 null
  setDetailIndex(hitIndex);         // Drawer 自动开(现有 open = detailAsset != null)
}
// 翻页 onChange / 切 folder 重置处:setHighlightId(null)(不动 consumedAsset)
```

  > 实现注意:上述 state/ref(consumedAsset / consumeOutcome / highlightId /
  > prevTarget / scrolledFor / notifiedFor)**全部置于组件顶部声明区**(本页
  > 现有惯例,`FolderDetailPage.tsx:26-36`),§4.2 各片段按主题分段仅是文档
  > 叙述顺序,照抄排版会踩 `const` 时间死区;`UUID_RE` 在 hooks.ts 定义处
  > 须 `export`(本页与 §4.1 hook 两处共用)。

- **定位失败兜底的完整守卫**(三层口径,缺一层都有确定性反例):

```ts
const locateFailed =
  focusAssetId != null && consumedAsset !== focusAssetId && (
    !UUID_RE.test(focusAssetId)          // ① 格式非法:enabled 拦下不发请求,locateData 恒 undefined,
                                         //    必须在这里显式判格式,否则永不提示
    || (locateData !== undefined         // ② 已返回但无法定位:null 或键不存在
        && typeof locateData.locate_index !== 'number')
  );
if (locateFailed) {
  setConsumedAsset(focusAssetId);        // 与成功分支共用一次性标记(串可能是任意
  setConsumeOutcome('failed');           // URL 原文,安全性由下方 effect 的格式门禁兜住)
}
```

  失败 toast 单独一个 effect(`message` 取 `App.useApp()`,本页增挂):
  render 期调 `message.info` 会触发 React「updating a component while
  rendering a different component」,且 StrictMode 双调用 render 弹两次 ——
  ref 去重保证只出一次:

```ts
const notifiedFor = useRef<string | null>(null);
useEffect(() => {
  if (consumeOutcome !== 'failed' || !consumedAsset) return;
  if (notifiedFor.current === consumedAsset) return;
  notifiedFor.current = consumedAsset;
  message.info('目标文件可能已被删除或移动');   // 停留当前页,不开 Drawer
}, [consumeOutcome, consumedAsset]);
```

  - ①②之外(**query 出错**:网络/5xx,`locateData === undefined` 且
    `error` 有值)→ **静默停留当前页,不判失败**:非 401/403 的错误全局
    `queryCache.onError` 已弹 toast,页面再补提示是重复;403 本就是无权限
    场景,整页行为与现状一致。
  - 失败判断②用「`locate_index` 是不是 number」而非 `== null`:区分
    「还没返回」(undefined,继续等),并兼容老后端忽略 locate 参数、响应里
    根本没有该键的混合部署窗口。
- 并发漂移兜底(目标页 items 里找不到该 id):不弹抽屉、不报错,停留该页
  (用户可就近翻页;locate 与取页之间有上传/删除才会发生,概率低,不做二次探测)。
- **滚动必须在 DOM 提交后执行,不能放在上述 render 期消费分支里**:
  ① render 期 setState 同遍 DOM 尚未提交,`querySelector` 看不到新卡片;
  ② 跳页取数期间 `AssetCardList` 收到 `loading={isFetching}` 会整列渲染
  Skeleton,`[data-asset-id]` 根本不在 DOM。因此滚动放副作用 effect:

```ts
// 纯 DOM 副作用(无 setState),不违反本页「不写 setState-in-effect」惯例。
// 一次性 ref:置位后任何 ['assets'] 前缀失效引发的 refetch(isFetching 翻转)
// 都不再重滚 —— 否则用户此后在本页打标/上传都会被反复拖回目标卡片。
const scrolledFor = useRef<string | null>(null);
useEffect(() => {
  if (!consumedAsset || isFetching || scrolledFor.current === consumedAsset) return;
  if (!UUID_RE.test(consumedAsset)) {      // 失败路径的 consumedAsset 是未消毒的
    scrolledFor.current = consumedAsset;   // URL 原文,含引号等字符直接拼选择器
    return;                                // 会 SyntaxError 打穿 ErrorBoundary
  }
  const el = document.querySelector(`[data-asset-id="${consumedAsset}"]`);
  if (!el) return;                    // 骨架屏刚结束的极端时序:未置位,下轮重试
  el.scrollIntoView({ block: 'center', behavior: 'smooth' });
  scrolledFor.current = consumedAsset;
}, [consumedAsset, isFetching]);
```

  (PC window 滚动与 compact main 滚动容器均天然适配,无需分支。)
- **高亮与一次性消费是两个独立 state,不可共用**(共用则「翻页清空高亮」
  会同时清掉消费标记,翻回目标页时 Drawer 违背承诺再次自动弹出):
  - `consumedAsset`:一次性消费标记,**永不清空**(只在定位成功/失败时赋值),
    只负责「不重弹 Drawer / 不重复提示」;
  - `highlightId`:消费**成功**时赋值 = `focusAssetId`,负责卡片描边高亮;
    用户翻页 onChange / 切 folder 时清 `null`(纯视觉态)。
  高亮是状态驱动渲染,无提交时机问题。
- 既有行为全部不动:分页器 sticky 钉底、翻页回顶、Drawer ‹ n/N ›(index 态,
  边界=当前页)、切 folder 重置第 1 页。**机制如实的描述:`page` state 仍从
  1 起,locate 响应到达后 render 期跳到目标页**——第 1 页有一个短暂闪现窗口
  (有缓存时更明显),属可接受代价,不做加载期 gating;跳页后的翻页、‹ ›
  等交互与手工浏览完全一致。

### 4.3 AssetCardList(`web/src/components/AssetCardList.tsx`)

- 新增可选 prop `highlightId?: string`;卡片根节点加 `data-asset-id={a.id}`;
  命中卡片描边高亮(`border: 1px solid var(--ms-accent)` +
  `boxShadow: 0 0 0 3px var(--ms-accent-soft)`,风格对齐 SearchPage 命中高亮)。
- 缺省不传 = 现状零变化(ProjectDetailPage 等其他调用方不感知)。

## 5. 边界与异常汇总

| 场景 | 行为 |
| --- | --- |
| locate 目标已软删 / 不在本夹 / 不存在 | `locate_index=null` → 前端提示一次,停留第 1 页 |
| 定位与取页之间目标被上传挤位(漂移) | 目标页找不到 id → 静默不弹抽屉,停留该页 |
| 上传成功使同夹 locate_index 整体 +1 | 不额外失效缓存;30s staleTime + 漂移兜底吸收(影响有界) |
| `asset` 参数非 UUID 格式(手工改坏链接) | `useLocateAsset` enabled 前置校验拦下请求(不发注定 422 的调用);§4.2 失败守卫①按格式直接判失败,提示一次 |
| locate 请求本身出错(网络 / 5xx) | 静默停留当前页不判失败;非 401/403 已有全局 toast,页面不重复提示 |
| `/search?…&focus=` 的 focus 目标不在前 50 结果窗口(分享链接/数据变化) | `focused` 未命中 → Drawer 静默不开(与搜索结果默认 50 截断的现状语义一致) |
| SearchPage 输入框改搜索词 | 现有 `setSearchParams({q})` 整表替换 → 丢 `focus` 关抽屉(**有意**:新搜索语境,旧 focus 失效) |
| locate 往返期间用户手动翻页 | 定位结果到达会覆盖翻到目标页(窗口 <1s,接受,不加防抖) |
| 老 backend + 新前端混合窗口(响应无 locate_index 键) | 失败判断按「键存在且为 number」口径,同走兜底(§7 顺序已规避,双保险) |
| 无 folder can_view 的用户带 asset 参数直访 | 沿用列表 403(权限判定先于 locate,无新泄露面) |
| sensitive folder 命中 | 搜索结果本身已按 can_view 过滤;深链定位同权限,语义不变 |
| 刷新 / 分享 `?asset=` 链接 | 完整重放:定位 → 跳页 → 高亮 → 自动开 Drawer |
| Drawer 关闭后再翻页 | 不重弹(consumedAsset 一次性消费;URL 参数保留无害) |
| 旧链接 `/folders/:id`(无参数) | 完全走现状:第 1 页起 |
| locate 缓存过期目标已删 | 删除/恢复/彻底删除 onSuccess 已补 invalidate,30s staleTime 兜底 |

## 6. 验收清单

### 6.1 后端(容器内 pytest 全绿)

§2.3 五组用例;`ruff check .` + `mypy app`(strict)零新告警。

### 6.2 前端手工(dev 部署后真机)

1. ⌘K 搜 `.heic` → 点命中 → 落 `/search?q=…&focus=…`,Drawer 自动开,
   预览(HEIC 走缩略图)/下载/分享可用;
2. SearchPage 行点击 = 开 Drawer;关闭后 focus 参数移除,回退不重开;
3. Drawer「在文件夹中查看」→ `/folders/:id?asset=…`:落**正确页**、
   Drawer 自动开;**关闭 Drawer 后**目标卡片位于视口内且高亮描边可见
   (抽屉 72vh 会遮挡视口中央,滚动效果以关抽屉后的视口为准验收);
   ‹ n/N › 在本页正常切换;
4. 同链接直接刷新 → 完整重放定位;
5. 构造目标软删 → 提示「可能已被删除或移动」**只弹一次**(dev StrictMode
   下验证无双弹),停留第 1 页;
6. 手工把 `?asset=` 改成非法串(如 `x"y`)→ 提示一次,页面不崩
   (选择器格式门禁);
7. compact(<1024)移动壳层:⌘K 面板、SearchPage Drawer(含软键盘收缩)、
   落点页滚动高亮同验;
8. 回归:无参数进 folder 浏览/翻页/上传/回收站、PC ProjectDetailPage、
   ⌘K 项目跳转与内置命令不受影响;SearchPage 改搜索词 = 丢弃 focus 关抽屉
   (有意行为,§5 表)。

## 7. 实施顺序与部署

1. 后端 locate 参数 + 测试(先行,前端可并行开发,契约定死后互不阻塞);
2. 前端方案 A(SearchPage + ⌘K,纯前端即可独立上);
3. 前端方案 B(hooks + FolderDetailPage + AssetCardList);
4. 联调 + dev 真机验收 → 合并 liuqi → prod。
   部署:`deploy_lan.sh` + SPA tar(无 migration/FGA,容器 restart 即生效);
   回滚:代码回退 + SPA 换回 `web.bak` 备份,无数据残留。
5. 收尾记账:用户可感知的交互变更,实施与部署当日按仓库约定追加
   `scripts/changelog.md`(按天分节,最新在前)。

## 8. 工作量估算

后端 + 测试 ~0.5d;前端 A ~0.5d;前端 B ~1d;联调部署验收 ~0.5d;合计 ~2.5d。

## 9. 本期不做(遗留)

- 搜索结果 Drawer 的 ‹ n/N › 跨结果遍历(二期可选);
- 方案 C(folder 内文件名筛选)——待用户另行拍板;
- ⌘K 面板 `onSelect` 按 value 反查的存量缺陷(同名文件回车选错)——本周期
  随 §3.2 顺手按 key 匹配修复;若实施时未动该文件则以本条为准回归处理;
- ⌘K 面板「N 条命中」50 截断不提示、PC Table sorter 仅排当前页
  (调研报告顺带发现,独立小问题,不在本周期);
- `GET /assets/{asset_id}` 单文件端点(当前两方案都不需要,不新增 API 面)。
