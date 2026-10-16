# qdev 需求文档:盲搜跳转定位落地(方案 A + B)

> 2026-10-16。**唯一需求依据 = 本文档 + 定稿方案**
> [rushes-spec/material-storage/search-jump-locate-plan.md](../../rushes-spec/material-storage/search-jump-locate-plan.md)
> (qplan 4 轮盲审定稿,已合并 liuqi `3550a6a`;两文冲突时以定稿方案的「实现钉子」细则为准)。
> 上游调研:[search-jump-locate-investigation.md](../../rushes-spec/material-storage/search-jump-locate-investigation.md)。

## 背景与目标

现状:⌘K 面板 / 搜索页点击盲搜命中,只带 folder_id 裸跳 `/folders/:id`,落点页恒从
第 1 页开始(列表固定 created_at DESC 30/页),大文件夹老文件沉在深页,用户翻很多页
也找不到刚搜到的文件。

目标(方案 A+B 组合):

1. **A**:搜索结果**原地开单文件详情 Drawer**(URL `?focus=` 驱动),点击即见文件;
2. **B**:落点页深链 `/folders/:id?asset=<id>` 由后端 `locate_index` 定位**正确页码**,
   滚动到卡片 + 高亮 + 自动开详情 Drawer。

## 功能点明细(逐条可验收)

### 后端

- **F1** `GET /api/v1/assets` 加可选 `locate` 查询参数,响应 `AssetListOut` 加可选
  `locate_index`;语义/SQL/边界按定稿方案 §2.1–§2.2 逐字实现(含 `db.scalar` 单列、
  `(created_at, id)` 同元组 tiebreaker、null 不区分原因、权限沿用 list 判定)。

### 前端 — 方案 A

- **F2** SearchPage(`/search`):Drawer 开关 URL 驱动(`focus` 参数);行点击 =
  追加 focus 开 Drawer,onClose 移除 focus;Drawer 复用 `AssetSummaryPanel`
  (+`useMe`/`useFolder`),形态 = FolderDetailPage 底部抽屉同款(placement bottom +
  `useKeyboardViewportHeight` 键盘收缩);Drawer `extra` 放「在文件夹中查看」按钮 →
  `/folders/:id?asset=`;删除 `goFolder`。定稿方案 §3.1。
- **F3** ⌘K 命令面板(AppHeader CommandPalette):命中文件项 action 改跳
  `/search?q=…&focus=<id>`;「搜全部文件」项不变;**存量缺陷顺手修**:`onSelect`
  反查从按 `value` 改为按 `key` 匹配(同名文件回车选错)。定稿方案 §3.2。

### 前端 — 方案 B

- **F4** hooks/types:types.ts `AssetList` 加 `locate_index?: number | null`;
  hooks.ts 新增 `useLocateAsset`(独立 queryKey `['assets-locate', …]`,`limit=1`,
  enabled 含 **export 的 UUID_RE** 格式前置);`useDeleteAsset`/`useRestoreAsset`/
  `usePurgeAsset` 的 onSuccess 补 `['assets-locate']` 失效。定稿方案 §4.1。
- **F5** FolderDetailPage:读 `?asset=`;render 期跳页(prevTarget 模式 + 已消费
  不再拉页);一次性消费(consumedAsset 永不清空 / highlightId 翻页切夹清 /
  consumeOutcome 仅 `'failed'|null`);门禁 `!isFetching`;失败三层守卫 + toast 走
  effect(ref 去重);滚动 useEffect 提交后执行(一次性 ref + UUID 格式门禁防
  querySelector 注入);高亮描边样式按方案 §4.3。定稿方案 §4.2 **全部实现钉子**。
- **F6** AssetCardList:可选 prop `highlightId?`,卡片根节点 `data-asset-id`,命中卡片
  描边高亮;缺省零变化。定稿方案 §4.3。

## 数据库修改方案

**不涉及**(无 migration、无 FGA model、无新依赖)。

## 接口定义

`GET /api/v1/assets?folder_id=<uuid>&locate=<uuid>[&limit&offset]`(唯一改动):

- 入参:`folder_id: uuid.UUID` 必填;`locate: uuid.UUID | None = Query(None)` 可选
  (非法格式 FastAPI 422);`limit/offset` 现状不变。
- 返回:`AssetListOut { items: AssetOut[]; total: int; locate_index?: int | null }`
  —— `locate_index` = 目标在列表同排序(`created_at DESC, id DESC`,
  `deleted_at IS NULL`,本夹)下的 **0 基全量序号**;`locate` 缺省/目标不存在/已软删/
  他夹 → `null`。窗口 `limit/offset` 不影响 `locate_index` 语义。
- 错误码:权限沿用现状(无 can_view → 403;folder 不存在 → 404;locate 非法 → 422)。

## 前端改动点 / 后端改动点

- 后端:`api/app/routers/assets.py`(list_assets)、`api/app/models/__init__.py`
  (AssetListOut)、新增 `api/tests/test_asset_locate.py`。
- 前端:`web/src/pages/SearchPage.tsx`、`web/src/pages/FolderDetailPage.tsx`、
  `web/src/components/AppHeader.tsx`、`web/src/components/AssetCardList.tsx`、
  `web/src/api/hooks.ts`、`web/src/api/types.ts`。
- 其余文件一律不许碰(含 changelog,由 PM 收尾统一记)。

## 测试功能点

### 后端(pytest,可执行;定稿方案 §2.3)

- T1 正常定位 + 不变式自检(按对齐窗口断言 `items[locate_index % 页大小].id == 目标`);
- T2 created_at 并列(同事务批量)tiebreaker 生效;
- T3 已软删 → null;他夹 → null;随机 UUID → null;缺省 → null;malformed → 422;
- T4 权限:无 can_view → 403;public 非敏感夹直通 + 系统 admin 直通各一条;
- T5 带 `limit/offset` 时 locate_index 仍是全量序号。

### 前端(无自动化基建 → 结构化手工用例清单,定稿方案 §6.2 八条)

⌘K→focus 直达详情 / 行点击开关语义 / 深链落页+滚动高亮+自动开 / 刷新重放 /
软删提示一次(StrictMode 双弹检查)/ 非法 asset 串不崩页 / compact 全链 /
回归(无参浏览、翻页、‹ n/N ›、PC ProjectDetailPage、改词丢 focus)。

## 模糊点与决策记录

本需求**无待决模糊点**——方案经 qplan 4 轮盲审定稿,实现层钉子已全部写死。
实施层决策(按仓库惯例拍板):

- 分支 `feat/search-jump-locate` 基于 liuqi(144c509)切出;
- 测试文件名 `api/tests/test_asset_locate.py`(方案 §2.3);
- 前端无自动化测试基建:前端验证 = lint + build + 专职测试手工用例清单;
- `scripts/changelog.md` 记账由 PM 收尾统一追加,开发子智能体不动 changelog;
- 部署不在本周期(dev/prod 部署待用户另行指令)。
