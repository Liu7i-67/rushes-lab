# qdev 需求文档 · 移动端显示适配（2026-09-10）

> **唯一需求依据：[rushes-spec/material-storage/mobile-adaptation-plan.md](../../rushes-spec/material-storage/mobile-adaptation-plan.md)（v3.1 定稿，三轮双视角审查 APPROVE）**。
> 本文档只做工作包拆解、角色边界、接口契约摘录与决策记录；功能细节一律以上述方案为准，
> 两者冲突时以方案文档为准。

## 背景与目标

全站按 PC 设计（React 19 + antd 6.4.2 + inline style + tokens.css），需移动端适配。
目标：手机（375×667）与平板竖屏（768×1024）可用、PC（1440/1920）**零回归**。
策略：共用页面路由、CSS 适配为主、JS 只切骨架级差异（唯一判定源 `useCompactViewport`
<1024）。产品重心：储存/下载/分享 + 标签盲搜（核心动线必须全通）。

## 功能点明细

按方案 §3 逐页动作表执行（P0：壳层/TabBar、ProjectDetailPage 单栏工作区、
FolderDetailPage、移动端下载直连；P1：B 类页面微调；P2：触控目标与细节打磨）。
验收口径见方案 §6（7 条）。本任务**不含**真机回归执行（方案 PR4 的人工部分），
但 PR4 的代码项（dvh、iOS PDF 降级、Landing padding）在本任务范围内。

## 数据库修改方案

不涉及（零表/字段/索引变更）。

## 接口定义（唯一后端改动，方案 §3.5）

- `POST /api/v1/assets/{asset_id}/download-link`
  - 入参新增：`as_attachment: bool = False`（可选；请求体字段，向后兼容——
    现有调用方 `AssetPreviewModal.tsx:78` 传 `{}` 不受影响）
  - 返回值：`DownloadLinkOut` **结构不变**（url / expires_in / is_sensitive）
  - 行为：`as_attachment=true` 时 presign Params 附加
    `ResponseContentDisposition: attachment; filename="<ASCII兜底>"; filename*=UTF-8''<RFC5987>`
  - `share.py` 的分享下载签发同改（同样为可选参数或直接 attachment，按方案"分享下载签发同改"执行）
  - 错误码：不变（404/403 逻辑原样）
- 预览路径零变化：`as_attachment` 默认 False，`AssetPreviewModal` 复用同端点的
  URL 仍为内联语义（桌面 PDF iframe 预览不得破坏，方案 §6.7）。

## 前端改动点

见方案 §2（基建/壳层）、§3.1-§3.4（逐页）、§3.5（下载直连前端）、§3.6（UA 降级）、§7（PR 序列）。

## 后端改动点

仅 §3.5 豁免：`presign.py sign_get_url` 加可选参数 + `assets.py download-link`
加 `as_attachment` + `share.py` 同改。**除此之外后端零改动。**

## 工作包拆解与派发顺序

| 波次 | 工作包 | 角色 | 范围（方案章节） | 依赖 |
| --- | --- | --- | --- | --- |
| 1 | 前端 A · 基建+移动壳层 | 前端 | §2 全部（use-viewports/tokens.css 移动层/index.html/AppShell/AppHeader/TabBar/更多 Drawer/badge）+ §3.3 的 ProjectMembersDrawer 一行修复 + §3.4 ghost-btn 三件套 | 无 |
| 1 | 后端 · presign 附件语义 | 后端 | §3.5 后端部分 + pytest 用例 | 无（契约已定死） |
| 1 | 测试用例包 | 测试 | 按方案 §6 产出结构化验收用例清单（docs/qdev/ 下） | 无 |
| 2 | 前端 B · 工作区+下载 | 前端 | §3.1 / §3.2 / §3.5 前端部分 / §3.6 / §3.4 ShareModal+预览 dvh | 前端 A（import use-viewports） |
| 2 | 前端 C · B 类页面微调 | 前端 | §3.3 表格全部（除 ProjectMembersDrawer） | 前端 A（.ms-hscroll/.ms-breadcrumb 类名） |

冲突隔离（并行安全）：A 碰 tokens.css/index.html/App.tsx/AppHeader/MobileTabBar(新)/ProjectMembersDrawer/FolderTree/UserMenu/AssetTagEditor；B 碰 ProjectDetailPage/FolderDetailPage/AssetCardList(新)/download-store/hooks.ts/ShareModal/ua.ts(新)/visualViewport hook(新)/后端三文件；C 碰 MyPermissionsPage/TaskCenterDrawer/ApprovalsPage/AdminUsersPage/AdminGroupsPage/AdminAuditPage/SearchPage/AppBreadcrumb。三者文件集两两无交集。

## 测试功能点

结构化用例由测试用例包产出（本目录 `2026-09-10-mobile-adaptation-testcases.md`）；
可自动化部分：后端 as_attachment 契约 pytest（后端包编写，容器内跑）；
`pnpm build` / `pnpm lint` 全绿为硬门槛。真机项记入遗留（方案 §6.2-6.6 需 tester）。

## 模糊点与决策记录

| 模糊点 | 决策 | 理由 |
| --- | --- | --- |
| 壳层断点（v2 双钩子 vs v3 单一 <1024） | 单一 `useCompactViewport()`<1024 | 第 2/3 轮审查共识：iPad 竖屏壳层必须移动化，A/B 类页面提前换控件无副作用（终审已确认） |
| 后端是否解冻 | 仅 §3.5 一处豁免 | 无 attachment 头则"下载"对 jpg/mp4 是内联打开，核心动线不成立；签名参数不属契约变化 |
| 移动端批量下载 | 批量栏不放"下载" | 浏览器拦截连续多下载；诚实降级 + §6 防误报口径 |
| 是否做原生滑动 pager | 不做（§4） | 动共享 AssetPreviewModal 触 PC 红线，留下轮 |
| 分支策略 | 从 liuqi 切 `feat/mobile-adaptation` | 用户指定；不直推 main |

## 实施期决策记录（第一波完成后补充）

| 盲点/事项 | 决策 | 理由 |
| --- | --- | --- |
| 992-1023 断点灰区（antd lg 实为 ≥992） | 按 antd 语义执行，实际生效点 992px | 992+ 宽度 PC 顶栏（约 880px）已放得下；工作区在该区间表内横滚 = 现状等同；方案 §1.1 的"1024"以 antd lg 语义理解 |
| /dev-login 页移动端表现 | 明确不做、移出验收 | dev 专用页，无 tester/用户场景 |
| ⌘K 监听 compact 是否卸载 | 保留 | 平板接键盘属边缘场景；CommandPalette Modal 本身响应式 |
| 分享接收侧（ShareLandingPage 下载 CTA） | 由后端 share.py resolve 无条件 attachment 覆盖 | 前端 `href+download` 跨域借响应头生效，前端零改动 |
| UploadFloatingIndicator 与批量栏叠层 | 接受叠放（z-float 80 > batchbar 60，瞬态） | 避免上传浮标与工作区选中状态做跨组件耦合；方案 §3.4"叠加批量栏高度"降级为已声明偏差 |
| 键盘期 UploadFloatingIndicator 隐藏 | 不做（仅 TabBar/批量栏/Drawer 收缩做） | 避免第二波并行包交叉依赖键盘 hook；浮标瞬态影响可忽略 |
