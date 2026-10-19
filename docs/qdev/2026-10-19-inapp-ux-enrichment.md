# 四项前端体验优化实施需求(A 检测提示 / D 批量栏 / C 审计补名 / B 预览导航下载)

> qdev 需求文档。**实施细则正本**:`rushes-spec/material-storage/inapp-browser-tip-preview-nav-audit-enrichment-plan.md`
> (qplan 3 轮盲审定稿,commit 63bf7d8)。本文档定契约与验收标准;实现细节(样式参数、
> 精确行号、钉子清单)以正本为准,冲突时以正本为准。
> 实施顺序(用户指令):**A → D → C → B**。基线:feat/inapp-ux-enrichment(= liuqi c423431 代码态 + 方案文档)。

## 背景与目标

四项互相独立的体验优化(全部零 migration、零 FGA model 变更、零 nginx/env 变更):

- **A 内置浏览器检测提示**:企业微信/微信/抖音等内置浏览器里下载/预览基本不可用,全前端无 UA 检测基建。目标:检测后非阻断横幅引导用户「在浏览器打开/复制链接」。
- **D 移动端批量栏溢出**:compact(<1024)批量操作栏单行 flex 无 wrap,375px 屏溢出 ≈160-200px,且 compact main `overflowX:hidden` 把按钮直接裁掉。目标:两行确定性布局,320px 起全部按钮可见可点。
- **C 审计展开详情补名**:审计事件 `details` 里 folder_id/subject(FGA 串)/user_id 等裸 UUID,前端整块 JSON dump 不翻译。目标:「有 id 就有名称」,结构化渲染。
- **B 预览弹窗导航下载**:AssetPreviewModal 只收单 asset 无列表上下文,正常预览态无下载按钮。目标:‹ › 导航(页内列表)+ 键盘 ←/→ + footer 常驻下载。

## 功能点明细(逐条可验收)

### A 包

- A1 新建 `web/src/lib/inapp.ts`:`detectInApp(): { isInApp: boolean; appName: string; isMobile: boolean }` —— inapp-spy 判 isInApp + 国产 UA token 补充表(wxwork→企业微信 / aweme|douyin|bytedancewebview→抖音 / QQ\/→QQ / dingtalk→钉钉 / weibo→微博;未识别 isInApp=true 时 appName='内置浏览器');isMobile=`/Android|iPhone|iPad|Mobile/i` 或 iPadOS 13+ 伪装(`maxTouchPoints>1`)。纯函数零副作用。
- A2 新建 `web/src/components/InAppBrowserTip.tsx`:仅 `isInApp && isMobile` 渲染;antd Alert warning 非阻断可关;`position:fixed; left/right:0`;常规路由 `top:56px`(AppHeader 下沿,header 保持可交互),**无 header 路由(`/login`、`/change-password`、`/dev-login`)降 `top:12px`**(pathname 白名单判定);`z-index: var(--ms-z-inapp-tip, 55)`;标题含 appName;引导文案分 iOS/Android;操作=[复制链接](走 `web/src/utils/copy.ts` 的 `copyToClipboard(window.location.href)`,返回 false → message.warning 手动复制提示)+[关闭];关闭持久化 `sessionStorage['ms-inapp-tip-dismissed']='1'`(当次会话不再弹)。
- A3 挂载:`web/src/App.tsx` 313-316 `<MaintenanceBanner />` 旁(BrowserRouter 内、不依赖路由),覆盖含 `/login`、`/s/:token`。
- A4 `web/src/styles/tokens.css` 新增 `--ms-z-inapp-tip: 55`(既有 z 体系 header 50 / batchbar 60 之间)。
- A5 `web/package.json` + `inapp-spy@^5.0.10`(pnpm add;仅构建期,静态产物部署零影响)。
- PC 端(含 MicroMessenger 但非 mobile)不弹(D-A2)。

### D 包

- D1 `web/src/pages/ProjectDetailPage.tsx` compact 批量栏(~840-890)重构为两行:行1 = 「已选 N」+ flex 占位 + 「清空选择」(text 型按钮视觉弱化);行2 = 打标/前缀/移动/删除 4 按钮 `display:grid; gridTemplateColumns: repeat(4, 1fr); gap:8`(等宽自适应)。按钮维持 height 44;Popconfirm 包删除的结构不变;`kbVisible` 隐藏逻辑与 `--ms-z-batchbar` 层级不动;sticky bottom 不动。
- D2 列表 `paddingBottom: hasSelection ? 76 : 12`(~794-796)按两行栏高调大(≈132,以实测为准常数化)。
- D3 组件注释写明扩展约定:行2 满 4 个则移行1 或换 2×2。
- PC(≥1024)分支与 FolderDetailPage 零变化;批量下载不入栏(既定决策勿回潮)。

### C 包

- C1 后端 `api/app/routers/admin.py`:`AuditOut` 新增 `user_agent: str | None = None`、`resolved_names: dict[str, str] = {}`;新 helper `_resolve_audit_detail_names(rows)` 按 details 白名单标量键 `{folder_id, target_folder_id, parent_folder_id, old_parent_folder_id, new_parent_folder_id, group_id, user_id, sharer_user_id, subject}` 分桶收集(try-UUID 解析,垃圾值静默跳过),folder 桶→`folders.name`、user 桶→`users.name`、group 桶→`groups.name`、subject→**复用 `api/app/services/subject_names.py` 的 `resolve_subject_names`**(纯名称不加类型后缀;found=False 不进 resolved_names);查不到的键不进 dict;独立批量 IN 查询(**禁止在 audit 主查询上 JOIN**,沿用 W2b 口径);页 ≤30 行至多 3-4 个 IN 查询。仅 list 端点带上;CSV 导出不动。
- C2 后端 `api/app/services/audit.py`:`write()` 组装 record 处 `user_agent[:512]` 截断(收口全部写入路径——directory.py 有 9 处绕过 ctx 直读 header,不能只改 deps.py)。
- C3 前端 `web/src/api/types.ts`:AuditEvent 补 `user_agent?: string | null; resolved_names?: Record<string, string>`。
- C4 前端 `web/src/pages/AdminAuditPage.tsx` 展开态(~338-363):details 从整块 JSON.stringify dump 改**结构化键值列表**(raw JSON 保留在 `<details>` 折叠区):键名 label 化(DETAIL_KEY_LABEL 映射,缺 key 回落 raw 键名);值渲染 resolved_names 命中→`名称(UUID 前 8 位…)` 并列(id 和名称都给;subject 类型标注由前端从原始串前缀取 user:→(用户) / group:→(用户组));布尔→是/否;null→—;标量数组→join;**对象/对象数组→逐字段展开或 JSON.stringify(勿打出 [object Object])**;ISO 时间→locale;未知键原样。补展示 `actor_user_id`(替换误导性 actor_open_id,后者仅历史行非空时保留)、`user_agent`(有值才显示,截断 ~120 字符 + title 悬浮完整值)、完整 `event_time`。不动收起态/过滤/导出。

### B 包

- B1 `web/src/components/AssetPreviewModal.tsx` Props 扩展(全部可选向后兼容):`list?: Asset[]; index?: number | null; onIndexChange?: (i: number) => void; canDownload?: boolean`。
- B2 导航条:title 区(ChevronLeft/ChevronRight text Button + ms-mono `n / N` + 文件名省略,对齐 FolderDetailPage Drawer 标题既有样式);`(index ?? 0) <= 0` 禁 ‹、`>= list.length - 1` 禁 ›;不传 list = 现行为无导航条。
- B3 **挂载改造(必改钉子)**:`AssetSummaryPanel.tsx`(~210-216)modal 挂载条件从 `isPreviewable(a) &&` 改为按 `previewOpen` 挂载;「预览」QuickAction 按钮保留 isPreviewable 门控。
- B4 **切换重置(必改钉子)**:effect 重置分支从 `if (!open)` 扩为 `!open || asset.id 变化` 也清 `content/liveUrl/playingLive`(修 livp A→C 串实况)。
- B5 footer 常驻下载:`footer={null}` 改自定义 footer([下载] 按钮,icon Download,loading=dlLink.isPending);所有 kind 含 unsupported 卡可见;`canDownload === false` 时禁用 + tooltip「无下载权限,可在文件面板点『申请下载』」(**antd disabled Button 不触发 hover,Tooltip 须包住 Button**——照抄 ProjectDetailPage ~1193 既有写法);403→message.warning(与降级卡同文案);复用组件级 handleDownload。三张降级卡内下载按钮不动。
- B6 键盘导航:open 且 list.length>1 时挂 document keydown ←/→(e.target 为 video 时忽略);Esc 维持 antd 自带。
- B7 `AssetSummaryPanel` Props 扩展:`list?: Asset[]; listIndex?: number; onListIndexChange?: (i: number) => void`,透传给 modal(含内部 canDownload 判定一并透传);多选/空选态不涉及。
- B8 三页面接线:FolderDetailPage(~241,list=items,index=detailIndex,onIndexChange=setDetailIndex);ProjectDetailPage(~948,list=assetItems,同构);SearchPage(~264,list=results,index=findIndex,onIndexChange=`(i) => setSearchParams({ q, focus: results[i].id }, { replace: true })` —— **参数名是 focus 非 asset**);PC 三栏右栏(~1281)刻意不接 list(无翻页是预期行为);Drawer 翻页与 modal 翻页同一 state 天然同步。

## 数据库修改方案

**不涉及**。四包零 migration;C 只读既有列(audit_events.user_agent String(512))。

## 接口定义

唯一接口变更(其余包纯前端):

**GET /api/v1/admin/audit**(list 端点,入参不变)响应 `items[]` 每项**新增**:

| 字段 | 类型 | 说明 |
|------|------|------|
| `user_agent` | `string \| null` | 裸列透传(展示端前端截断) |
| `resolved_names` | `Record<string, string>` | key=details 键名(白名单 9 键),value=纯显示名;查不到/垃圾值不进 |

错误码:无新增(补名全程静默容错,不影响主查询)。CSV 导出端点**不变**(D-C1)。分页/过滤行为不变。

## 前端改动点 / 后端改动点

见「功能点明细」;文件清单与批次(正本 §5):

| 包 | 新增 | 修改 |
|----|------|------|
| A | lib/inapp.ts、components/InAppBrowserTip.tsx | App.tsx、styles/tokens.css、package.json(+inapp-spy) |
| D | — | pages/ProjectDetailPage.tsx(批量栏区 ~840-890 + paddingBottom) |
| C | — | api/app/routers/admin.py、api/app/services/audit.py、web/src/api/types.ts、web/src/pages/AdminAuditPage.tsx |
| B | — | components/AssetPreviewModal.tsx、components/AssetSummaryPanel.tsx、pages/FolderDetailPage.tsx、pages/ProjectDetailPage.tsx(接线区 ~948)、pages/SearchPage.tsx |

B×D 同改 ProjectDetailPage.tsx(不同区域)→ **D 先行、B 后接**;C×B 共享 types.ts 不同 interface → 无冲突。

## 测试功能点

按正本 §1.4(A 五条+层叠)、§2.3(B 六条,重点:unsupported 切换 modal 不卸载、livp A→C 不串实况、无权禁用态)、§3.3(C 六条,重点:subject 纯名称、垃圾 UUID 不 500、已删对象回落、user_updated 对象数组渲染)、§4.3(D 五条)。C 包写 pytest 可执行用例;A/B/D 写结构化用例清单(前端无自动化框架),统一存 `docs/qdev/2026-10-19-inapp-ux-enrichment-cases.md`。

## 模糊点与决策记录

- 全部决策点按正本 §6 默认执行(用户指令「按审查后的方案」):D-A1 补充表全带六家 / D-A2 PC 不提示 / D-A3 非阻断横幅 / D-A4 sessionStorage / D-C1 CSV 不动 / D-C2 token 原样 / D-D1 两行确定性布局。
- 实施顺序按用户指令 A→D→C→B(批次:A+D 并行 → C 后端+前端并行 → B)。
- 横幅文案为初稿,真机核对后可微调(纯文案低风险)。

## 项目约定(所有子智能体必读)

- 代码根:`material-storage/`(前端 `web/` React19+antd6.4.2+vite+TS strict;后端 `api/` FastAPI+SQLAlchemy async)。包管理 pnpm。
- 构建验证命令(前端,在 `material-storage/web/` 下):`pnpm lint`、`pnpm build`(tsc -b && vite build,类型错会 fail)。后端:`python -m compileall` 或隔离栈 pytest(由测试阶段处理)。
- 行号引用是 liuqi@c423431 基线,实施时按符号名+grep 定位,勿按行号盲跳。
- antd v6 铁律:Modal 回显忌 setFieldsValue;Form rules 混 pattern 则 min/max 失效;message.error 兼容数组型 detail。
- 改动最小化:不重构无关代码、不改无关样式;注释密度对齐周边代码。
