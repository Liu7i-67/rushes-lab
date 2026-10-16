# 调研:盲搜(⌘K / 搜索页)点击结果跳转后找不到目标文件

> 2026-10-16 纯调研产物,未动任何代码。现象:⌘K 搜 `.heic` 点一条命中,跳到的文件夹页
> 第一页没有该文件,翻很多页也难找到。根因定位 + 可选修复方案,实施等用户指令。
> 涉及环境:内网素材服务器(dev/prod 同构,按当前 liuqi 分支代码分析)。

## TL;DR

| 事实 | 位置 | 后果 |
| --- | --- | --- |
| 搜索命中点击只带 `folder_id` 裸跳,不带任何 asset 定位信息 | `AppHeader.tsx:365`(⌘K)、`SearchPage.tsx:58-60` | 落点页不知道要看哪个文件 |
| FolderDetailPage 恒从第 1 页开始,不消费任何 URL 参数 | `FolderDetailPage.tsx:26-31` | 落点 = 第 1 页 |
| 文件夹列表固定 `created_at DESC, id DESC`(新→旧),30 条/页服务端分页 | `assets.py:294`、`hooks.ts:320` | 目标文件在夹内的页码 = 它在夹内的新旧排名,夹大文件老 → 深页 |
| 全链路无定位基建:无 scrollIntoView/高亮、后端无单文件 GET、无「定位序号」接口 | 全仓 grep 证实 | 只能肉眼翻页 |

根因一句话:**跳转把「我找到了这个文件」丢掉了,只留下「去这个文件夹」**,而文件夹的
排序(新→旧)与搜索排名毫无关系,大文件夹里老文件天然沉在深处。

## 1. 链路事实

### 1.1 两个搜索入口,同一个裸跳

- **⌘K 命令面板**(`web/src/components/AppHeader.tsx`):盲搜命中显示前 6 条
  (`:350` `.slice(0, 6)`),点击 → `navigate(\`/folders/${r.folder_id}\`)`(`:365`),
  只有 folder_id。「搜全部文件」那条跳 `/search?q=…`(`:348`)。
- **搜索页**(`web/src/pages/SearchPage.tsx`):整行点击 → `goFolder` = 同样的裸跳
  (`:58-60`)。文件头注释写明设计意图就是「点击跳转所在 folder」。

### 1.2 落点页:恒第 1 页

`web/src/pages/FolderDetailPage.tsx`:

- `page` state 初始 1,切 folder 重置 1(`:26-31`);
- `useAssets(folderId, page, 30)` 服务端分页(`:32` → `hooks.ts:321-334`,
  `GET /api/v1/assets?folder_id&limit&offset`);
- 路由 `/folders/:folderId` 不消费任何 query/hash 参数(`App.tsx:66`,全页无
  `useSearchParams`);无 scrollIntoView/高亮逻辑(全仓 grep 仅 LoginPage 用过
  useSearchParams,scrollIntoView 零使用)。

### 1.3 排序口径:落点页位置 = 夹内新旧排名

- 列表接口 `GET /api/v1/assets`(`api/app/routers/assets.py:289-297`):
  `ORDER BY created_at DESC, id DESC` 固定排序,无用户可选排序,无文件名筛选参数。
- 搜索接口 `GET /api/v1/assets/search`(`:489-505`):全局 `created_at DESC`
  取前 50(默认 limit=50),**命中排名与夹内位置无关**。
- 所以:一个 300 文件的夹(10 页),半年前上传的 .heic 大概率在第 8-10 页;
  用户在 ⌘K 里看到它排第 3,落点却在第 1 页,毫无线索它埋在第几页。

### 1.4 加重视知觉找不着的两个因素

1. **搜索匹配三字段,肉眼只看文件名**:搜索命中 `filename / notes / user_labels`
   之一即可(`assets.py:493-500`)。搜 `heic` 可能命中一个叫 `IMG_1234.jpg`、
   但备注/标签里写了 heic 的文件 —— 用户在文件夹里按文件名扫「.heic」永远找不到。
2. **PC 表格排序只排当前页**:`ProjectDetailPage.tsx:403,422` 的 Table sorter 是
   客户端比较函数,只对已加载的 30 条排序,用户可能以为「按创建时间排一下」能把它
   排上来,实际不能(`AssetCardList.tsx:5` 已显式声明 compact 卡片列表连 sorter 都不做)。

### 1.5 缺失的基础设施(为什么「顺手修」修不了)

- 后端**无 `GET /assets/{asset_id}` 单文件接口**(端点清单只有 uploads/search/trash/
  restore/meta/batch-prefix/download-link/thumbnail-url/delete/live-preview-url)。
- 后端**无「定位 asset 在夹内序号」能力**;前端想自己算也没有数据源(分页接口只回窗口)。
- FolderDetailPage 的详情 Drawer 是 **index 态**(当前页 items 的下标,
  `FolderDetailPage.tsx:36`),不是 id 态 —— 深链打开详情需要适配这个模型。
- 好消息:`SearchResult extends Asset`(`types.ts:281`),搜索结果自带开详情
  Drawer 的全部字段,纯前端方案有数据基础。

## 2. 修复方案(供决策,未实施)

### 方案 A(纯前端,最小改动):搜索结果原地开详情,不再裸跳

点击搜索命中 → 直接打开单文件详情(复用 `AssetSummaryPanel` + `AssetPreviewModal`,
数据 SearchResult 全有,零新增请求)。这是主流网盘(Google Drive / 百度网盘)的交互
范式:搜索页本身就是浏览上下文,「去文件夹」降级为次要动作。

- SearchPage:行点击改开 Drawer;附「在文件夹中查看」按钮(暂仍跳第 1 页,待方案 B)。
- ⌘K 面板:命中点击 → 跳 `/search?q=…&focus=<asset_id>`(面板自身是 Modal,不便
  承载 Drawer),由 SearchPage 落地后自动开该文件详情。
- FolderDetailPage 的 Drawer ‹ n/N › 上下文切换模型在这里不适用(无翻页上下文),
  需单文件态(只有关闭,无前后切换)。

优点:零后端改动,当天可上,立刻消除「看不到搜到的文件」。局限:想看它「在文件夹
里的邻居」仍无定位能力。

### 方案 B(完整解,建议与 A 组合):服务端定位页码 + 深链高亮

- 后端:`GET /api/v1/assets` 加可选 `locate=<asset_id>` 参数,响应附
  `locate_index`(该 asset 在**与列表完全相同的** `(created_at DESC, id DESC)` 排序
  下的 0 基序号,用 count 比它新的行数即可算出)。权限判定沿用列表现有的
  can_view(folder / sensitive_folder 两型),语义零变化,无新增暴露面。
- 前端:跳转改 `/folders/:id?asset=<asset_id>`;FolderDetailPage 读参数 → 先发一次
  locate 请求得 index → `setPage(floor(index/30)+1)` 取对应页 → 渲染后在返回的
  items 里按 id 找到卡片 → scrollIntoView + 短暂高亮 +(可选)自动开详情 Drawer。

优点:真正解决「跳转后找不到」,URL 可分享/刷新保持。注意点:

- **排序元组必须与列表逐字一致**(含 `id DESC` tiebreaker):批量上传 created_at
  全并列,少一个 tiebreaker 定位会漂 1-2 位(搜索端点自己的排序就没带 id,别照抄)。
- **并发漂移**:locate 计算与取页之间若有新上传/删除,index 会偏。工程上可接受;
  兜底 = 按 id 在返回页 items 里找,找不到就退化为只开详情 Drawer(方案 A 数据兜底)。
- Drawer 的 index 态需适配「按 id 定位到当前页 index」;‹ n/N › 边界行为不变。

### 方案 C(缓解型,可并入 B):文件夹内文件名筛选

FolderDetailPage 加「本夹筛选」输入框(后端给列表接口加 `filename` ILIKE 参数,
或给 search 接口加可选 `folder_id` 过滤),跳转时带 `?filter=.heic` 落地即过滤。
顺带解决「大文件夹找文件」的通用问题,但引入第二套列表 UI,单独做性价比一般。

### 推荐组合

**A 先行(纯前端、当天见效),B 跟进(完整定位)**;C 视 B 周期余量顺手或独立排期。
A 与 B 不冲突:A 改搜索侧交互,B 改落点页能力,B 上线后 A 的「在文件夹中查看」
按钮自动升级为定位跳转。

## 3. 顺带发现(仅记录,不处理)

1. ⌘K 面板命中数显示 `searchHits.length`(上限 50,后端截断)——「50 条命中」
   实为「≥50」,SearchPage 底部有截断提示文案,面板没有(`AppHeader.tsx:344`)。
2. PC Table 客户端 sorter 只排当前页 30 条,对用户有「全夹排序」的误导性
   (`ProjectDetailPage.tsx:403,422`;服务端排序 + sorter 远程化是另一件事)。
