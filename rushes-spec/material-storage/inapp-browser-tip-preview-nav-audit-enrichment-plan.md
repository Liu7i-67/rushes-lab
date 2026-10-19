# 四项前端体验优化方案:内置浏览器检测提示 / 预览弹窗导航下载 / 审计展开详情补名 / 移动端批量栏溢出

> 2026-10-19 调研定稿(同日追加 D 包;E 包「iOS livp 上传引导」调研后经用户拍板移除),
> 调研全程未动代码。行号引用为 **liuqi @ 4748980** 基线快照,
> 实施时一律按符号名/端点名 + grep 定位,勿按行号盲跳。
> 四个工作包(A–D)互相独立,可并行或分批实施。
> 实施等待用户明确指令。

---

## 0. 调研结论摘要

| # | 需求 | 现状根因 | 性质 | 建议工作量 |
|---|------|---------|------|-----------|
| A | 内置浏览器(企业微信/微信/抖音等)检测 + 引导提示 | 全前端无任何 UA 检测基建(`lib/ua.ts` 只有 `isIOS()`);现有下载/预览在微信 webview 内基本不可用 | 纯前端,新增 1 依赖 + 1 组件 | ~0.5 天 |
| B | 预览弹窗上一张/下一张/下载 | `AssetPreviewModal` 只收单个 `asset`,无列表上下文;下载按钮只存在于降级卡(iOS PDF / HEIC / livp 失败卡),正常预览态没有 | 纯前端(modal 改造 + 3 页面接线) | ~1 天 |
| C | 审计单条展开后尽可能展示(id → 对应名称) | 后端已补 actor 名 / 项目名 / 文件名(W2b),但 `details` 里的 `folder_id` / `subject`(FGA 串)/ 部分用户/组 id 原样裸吐;前端展开态把 `details` 整块 JSON dump,不翻译 | 后端补名 + 前端渲染 | 后端 ~0.5-1 天 + 前端 ~0.5 天 |
| D | 移动端多选后批量操作按钮超出显示区域 | 批量栏(compact 专属)单行 flex **无 flexWrap**:「已选 N」+ 5 个 44px 高按钮 ≈ 480-520px,375px 屏必溢出;compact 下 `main` `overflowX: hidden` 把溢出按钮直接裁掉 | 纯前端布局修复 | ~0.5 天 |

**建议实施顺序**:A(半天快赢)→ D(小修)→ C(后端先行)→ B(前端为主,含移动端回归)。

---

## 1. 需求 A:内置浏览器检测 + 引导在手机浏览器打开

### 1.1 现状(亲验)

- 唯一 UA 工具 `web/src/lib/ua.ts`,只有 `isIOS()`,注释明确「不参与布局切换」;全仓 grep
  `MicroMessenger|wxwork|aweme` 零命中 —— 无任何内置浏览器检测。
- 全局挂载点现成:`web/src/App.tsx:313-316`,`MaintenanceBanner` 与 `AppShell` 并列挂在
  `BrowserRouter` 下 —— 意味着放这个位置的组件**覆盖所有路由**,包括 `/login`、`/change-password`、
  分享落地页 `/s/:token`、申请链接页 `/r/:token`(分享链接正是在微信里点开的,是最主要的内置浏览器入口)。
- 已有 `copy-to-clipboard` 依赖(AssetSummaryPanel 在用),复制链接按钮零新增依赖。

### 1.2 选型:inapp-spy + 国产 App UA 补充表

**inapp-spy**(npm 5.0.10,零依赖 vanilla TS,框架无关):

```ts
import InAppSpy from 'inapp-spy';
const { isInApp, appKey, appName } = InAppSpy();  // appKey/appName 可选字段
```

- 官方识别列表(README 原文):facebook, gsa, instagram, line, linkedin, reddit, snapchat,
  telegram, threads, tiktok, twitter, **wechat**, whatsapp, messenger。
- ⚠ **不识别企业微信和抖音**(只有国际版 tiktok,没有 aweme)。
  但企业微信 UA 同时含 `MicroMessenger` 和 `wxwork`,会被 inapp-spy 报成 `wechat`
  ——「是否内置浏览器」判断正确,只是 appName 归因为微信。
- 结论:**inapp-spy 做基础判断,叠加一张国产 App UA token 补充表**用于精确归因和兜底:

| App | UA token(不区分大小写) | inapp-spy 是否已覆盖 |
|------|------------------------|---------------------|
| 微信 | `MicroMessenger` | ✅(appKey=wechat) |
| 企业微信 | `wxwork`(UA 同时含 MicroMessenger) | ⚠ 报成 wechat,需 supplement 区分 |
| 抖音/抖音极速版/头条系 | `aweme` / `douyin` / `BytedanceWebview` | ❌ supplement |
| 手机 QQ | `QQ/`(注意排除 `MQQBrowser`——那是 QQ 浏览器,属完整浏览器) | ❌ supplement(可选) |
| 钉钉 | `DingTalk` | ❌ supplement(可选) |
| 微博 | `Weibo` | ❌ supplement(可选) |

  决策点 D-A1:用户点名三家(微信/企业微信/抖音),建议顺带带上 QQ/钉钉/微博
  (成本 = 补充表多三行,零风险);默认全带。

### 1.3 实施方案

**新文件 `web/src/lib/inapp.ts`**(与 `ua.ts` 同层,纯函数):

```ts
import InAppSpy from 'inapp-spy';

export interface InAppResult {
  isInApp: boolean;
  appName: string;      // 归因名:'微信' | '企业微信' | '抖音' | 'QQ' | …(未识别时 '内置浏览器')
  isMobile: boolean;    // 仅移动端提示(见 D-A2)
}

const CN_SUPPLEMENTS: [RegExp, string][] = [
  [/wxwork/i, '企业微信'],
  [/aweme|douyin|bytedancewebview/i, '抖音'],
  [/QQ\//, 'QQ'], [/dingtalk/i, '钉钉'], [/weibo/i, '微博'],
];

export function detectInApp(): InAppResult { /* InAppSpy() + supplement + isMobile 判定 */ }
```

- `isMobile` 判定:`/Android|iPhone|iPad|Mobile/i.test(ua)`,iPadOS 13+ 伪装 Mac UA 的坑
  复用 `ua.ts` 里 `maxTouchPoints > 1` 的思路。**PC 端微信/企业微信的内置浏览器 UA 同样含
  MicroMessenger,但「用手机浏览器打开」的引导对 PC 无意义** → 仅移动端弹提示
  (决策点 D-A2:PC 是否也给弱提示,默认不给)。
- 判定时机:纯同步 UA 判断,**不用** `SFSVCExperimental`(Safari 17+ 实验特性,有误报说明,不需要)。

**新组件 `web/src/components/InAppBrowserTip.tsx`**,挂 `App.tsx:314` `<MaintenanceBanner />` 旁:

- 形态:**非阻断顶部固定 Alert 横幅**(antd `Alert` type=warning,`position: fixed; top: 0; z-index` 低于
  Modal 但盖住页面头),可关闭。决策点 D-A3:横幅(默认)vs 不可关 modal(过重,不推荐)。
  理由:内置浏览器里系统「能用但体验差」,阻断会把低配场景变成不可用;维护 modal(MaintenanceBanner)
  只留给真不可用场景。
- 文案(初稿,实施期真机核对):
  - 标题:`当前在 {appName} 内置浏览器中打开,部分功能(下载/预览)可能不可用`
  - 引导(iOS):`点击右上角「…」,选择在 Safari 中打开;或复制链接后粘贴到浏览器`
  - 引导(Android):`点击右上角「…」,选择「在浏览器打开」`
  - 注意:不同 App 菜单项措辞不一(iOS 微信 historically 无「在 Safari 打开」直入口,
    企业微信/抖音菜单项也各异)→ **「复制链接」按钮是通用兜底 CTA**,菜单文案仅作辅助,
    实施时逐家真机核对后微调(低风险纯文案)。
- 操作:`[复制链接]`(copy-to-clipboard,`window.location.href` 整串含 `/ms-static/web` 前缀,
  复制原样即可)+ `[关闭]`。
- 关闭持久化:`sessionStorage['ms-inapp-tip-dismissed']='1'` —— 当次会话不再弹,次日新会话再提示
  (决策点 D-A4:sessionStorage(默认)vs localStorage 长期静默)。
- 挂载位置在 `BrowserRouter` 内但**不依赖路由**,与 MaintenanceBanner 同层,登录页/分享页全覆盖。

**依赖变更**:`pnpm add inapp-spy`(仅构建期需要,部署产物为静态文件,对内网离线部署零影响;
Python constraints 不涉及)。

### 1.4 测试点

1. devtools 自定义 UA 模拟:微信 UA(`…MicroMessenger/8.0.49…`)、企业微信(`…MicroMessenger… wxwork/4.1…`)、
   抖音(`…aweme_270958…`)→ 分别归因正确、横幅出现。
2. 普通 Chrome/Safari/PC 微信(含 MicroMessenger 但非 mobile)→ 不弹。
3. 关闭后本次会话内切路由不再弹;新开标签页(新 session)重新弹。
4. 分享落地页 `/s/:token` 直接在微信内打开 → 横幅覆盖(highest-priority 场景)。
5. 真机回归:微信内点「复制链接」→ 粘贴到 Safari 能打开(clipboard 在微信 webview 的兼容性)。

### 1.5 风险与钉子

- UA 启发式天然有误报/漏报(新版本 App 改 UA)→ 文案写「如遇异常请换浏览器打开」留弹性;
  supplement 表是纯数据,后续加 token 一行事。
- inapp-spy 版本迭代可能调整 appKey 集合 —— 我们只用 `isInApp` + 自己的归因表,
  对库的耦合面极小(appName 不直接用)。

---

## 2. 需求 B:预览弹窗上一张 / 下一张 / 下载

### 2.1 现状(亲验)

- `web/src/components/AssetPreviewModal.tsx:19-23`:Props 只有 `{ asset, open, onClose }`,
  **没有列表上下文**;`footer={null}`,正常预览态(image/video/pdf/md/text)无任何操作按钮,
  下载按钮只存在于三张降级卡(iOS PDF §3.6 / HEIC 失败 / livp 失败)。
- 唯一调用方 `AssetSummaryPanel.tsx:210-216`(单选态 QuickAction「预览」打开)。
  AssetSummaryPanel 的使用方(即列表持有方):
  - `FolderDetailPage.tsx:241` —— 单文件详情 bottom Drawer,`selected={[detailAsset]}`,
    **Drawer 标题已有 ‹ n/N › 翻页**(detailIndex + items,页内 30 条边界禁用);
  - `ProjectDetailPage.tsx:948` —— 同构(detailIndex + assetItems);另有两处面板(空选/多选)无预览;
  - `SearchPage.tsx:264` —— focus Drawer,**刻意未做翻页**(源码注释「单文件态不做 ‹ n/N ›
    跨结果切换(二期可选)」),focus 由 `?asset=` 查询参数驱动。
- 下载链路现成:`useDownloadLink` + `useDownloads().start`(浮窗进度),403 → message.warning
  (AssetPreviewModal.tsx:76-85 已有同款 handler,可提为组件级复用)。
- 键盘:antd Modal 自带 Esc 关闭;←/→ 无监听。

### 2.2 实施方案

**`AssetPreviewModal` 扩展 Props(向后兼容,新参数全部可选)**:

```ts
interface Props {
  asset: Asset;
  open: boolean;
  onClose: () => void;
  // 列表上下文(三入口传入后启用导航条;不传 = 现行为,单 asset)
  list?: Asset[];
  index?: number;                 // asset 在 list 中的下标
  onIndexChange?: (i: number) => void;
}
```

- 导航条渲染:**对齐 FolderDetailPage Drawer 标题的既有样式**(ChevronLeft/ChevronRight text Button +
  `ms-mono` 的 `n / N` 计数 + 文件名省略),放在 Modal title 区(title 改为同款 flex 布局)或
  body 顶部工具条 —— 推荐 **title 区**,与 Drawer 视觉一致且不占预览高度。
- 边界:`index<=0` 禁用 ‹,`index>=list.length-1` 禁用 ›(与 Drawer 翻页同语义,**不跨分页**,
  FolderDetail 页内 items 是当前页 30 条,SearchPage 最多 50 条截断)。
- **下载按钮:footer 常驻**(替换 `footer={null}` 为自定义 footer:`[下载]` 居中/居右,
  `icon=<Download/>`,`loading={dlLink.isPending}`),所有 kind(含 unsupported 卡)可见可用;
  403 → `message.warning('无下载权限,请联系项目管理员')`(与现有降级卡 handler 同文案);
  降级卡内的下载按钮可顺势复用同一个 handler(三处重复代码收敛为组件级 `handleDownload`)。
- **键盘导航**:open 且 list 长度 >1 时挂 `keydown`(←/→ → onIndexChange,注意焦点在 input 时忽略
  —— 预览态无输入框,风险低,但 livp 播放态 video 有自己的键位,绑在 `document` 并检查
  `e.target` 非 `video` 即可)。Esc 维持 antd 自带。
- **切换重置钉子(实施必改)**:现有 effect(`AssetPreviewModal.tsx:89-143`)只在 `!open` 时清
  `content/liveUrl/playingLive`;**asset 切换时 livp 的 `playingLive/liveUrl` 不清** —— 从 livp(正在播实况)
  切到下一张再切回 livp,会直接残留播放态。实施时把「asset.id 变化」也纳入重置分支
  (即 `if (!open || asset 变了) reset`),content 本身由新请求覆盖 + loading 态盖住,无视觉问题。

**`AssetSummaryPanel` 透传**(单选态):

```ts
interface Props {
  selected: Asset[];
  me?: Me;
  folder?: Folder;
  list?: Asset[];                 // 新增:页面持有的完整列表
  listIndex?: number;
  onListIndexChange?: (i: number) => void;
}
```

forward 给 `AssetPreviewModal`。多选态/空选态不涉及(无预览入口)。

**三页面接线**:

| 页面 | list | index | onIndexChange | 备注 |
|------|------|-------|---------------|------|
| FolderDetailPage:241 | `items` | `detailIndex` | `setDetailIndex` | Drawer 标题翻页与 modal 翻页天然同步(同一 state) |
| ProjectDetailPage:948 | `assetItems` | `detailIndex` | `setDetailIndex` | 同上 |
| SearchPage:264 | `results` | `results.findIndex(r => r.id === focused.id)` | `(i) => setSearchParams({ q, asset: results[i].id }, { replace: true })` | 顺带把「二期可选」的 Drawer 翻页也补了(可选:Drawer 标题加同款 ‹ n/N ›,复用同一 index 源) |

**明确不做(P2 备忘)**:移动端滑动手势切图(motion 库可做,另期);相邻图预加载;
跨分页连续导航(与 Drawer 翻页语义保持一致,页边界即停);分享落地页 `/s/:token` 加预览弹窗
(分享页目前只有缩略图列表无预览,属另一需求)。

### 2.3 测试点

1. 三入口(Folder/Project/Search)开预览:‹ › 计数正确、边界禁用、标题文件名随切换变。
2. 键盘 ←/→;Esc 关闭;livp 播放中按 ←/→ 不误触 video 键位。
3. 各 kind 轮播:image → md → pdf → livp → heic → unsupported,逐一验证内容正确重载、
   **livp 播放态切换后不残留**(§2.2 钉子)。
4. footer 下载:正常下载走浮窗;无权限 403 → warning;unsupported 卡下载可用。
5. 回归:AssetSummaryPanel 多选态/空选态不受影响;预览关闭后 Drawer 翻页仍正常。
6. compact(移动端):导航条 + footer 在小屏不溢出,title 长文件名省略。

### 2.4 风险与钉子

- Modal 与 Drawer 叠层(Drawer 内开 Modal)现状靠 DOM 挂载序维持同 z-index —— 本次不动层级,
  只改 title/footer 内容,不引入新叠层。
- SearchPage 的 index 是 `findIndex` 派生值(非 state),`?asset=` 不在 results 里(如翻搜索词后
  旧深链)→ findIndex 返回 -1,此时不传 list(降级为单 asset 模式),不渲染导航条。

---

## 3. 需求 C:审计展开详情「有 id 就有名称」

### 3.1 现状(亲验 + 后端摸底)

**前端** `web/src/pages/AdminAuditPage.tsx:338-363` 展开态目前展示:
`actor_open_id / target_project_name / target_project_id / target_asset_filename /
target_asset_id / target_minio_key / request_ip` + `details` 整块 `JSON.stringify` dump。

**后端** `api/app/routers/admin.py`:
- `AuditOut`(80-94 行):已有 W2b 派生列 `target_asset_filename` / `target_project_name`
  (`_resolve_audit_target_names` 98-116 行:按页内 target_asset_id 集合一次 IN 查询
  Asset JOIN Folder JOIN Project,**明确禁止在主查询上 JOIN**——补名一律走独立批量查询,沿用此口径)。
- `details` 原样返回(184 行),**未做任何补名**。
- `AuditEvent` 表有 `user_agent`(String 512)列但 **AuditOut 不吐**;`actor_open_id_snapshot`
  是历史飞书列(#148 后新用户恒 NULL,前端展示「actor: {open_id}」已具误导性)。

**`details` 里带 id 但前端展示不出名称的高频键**(grep 实测的写入面):

| details 键 | 出现的事件(示例) | 现有名称? |
|-----------|------------------|-----------|
| `folder_id` | folder_grant_added/removed(folders.py:1224/1264)、folder_renamed/moved/deleted、sensitive invite/revoke | ❌(folder_created 有 `name`,其余没有) |
| `subject`(FGA 串 `user:<uuid>` / `group:<uuid>#member`) | folder_grant_*、project_member_* | ❌ 裸 UUID |
| `target_folder_id` | baidu_task_create | ❌ |
| `group_id` / `group_ids` | group_member_added/removed、user_created | ✅ 多数同行已带 `group_name`/`username`,但 `group_ids`(列表)没有 |
| `user_id` / `sharer_user_id` | user_created、share_link_created | 部分带 username/name,`sharer_user_id` 没有 |
| `task_id` | baidu_task_* / baidu_file_* | ❌(有 source_dir 可读性尚可) |

### 3.2 实施方案

**后端(落点 `routers/admin.py`,与 W2b 同构,零 migration)**:

1. `AuditOut` 新增字段(全部 optional,向后兼容):
   - `user_agent: str | None`(裸列透传);
   - `resolved_names: dict[str, str]` —— key = details 里的键名,value = 补出的显示名。
2. 新 helper `_resolve_audit_detail_names(rows)`,扫描每行 `details` 的已知键集合
   `{folder_id, target_folder_id, group_id, user_id, sharer_user_id, subject}`,
   按类型分桶收集 UUID(**details 是自由 JSON,值须 try-UUID 解析,垃圾值静默跳过**),每类一次批量
   IN 查询:
   - folder_id / target_folder_id → `folders.name`(不递归拼全路径,P2 可选);
   - user_id / sharer_user_id → `users.name`;
   - group_id → `groups.name`;
   - `subject` 特殊解析:`user:<uuid>` → `users.name` + 后缀`(用户)`;
     `group:<uuid>#member` → `groups.name` + 后缀`(用户组)`;解析不出原样跳过。
   查不到(已删除)→ 该键不进 `resolved_names`,前端回落裸值显示(与 W2b purge 行回 null 同口径)。
   页大小 ≤30、每页至多 3-4 个 IN 查询,无性能顾虑。
3. `list_audit` 组装(165-185 行)与 CSV 导出:`list` 接口带上;**CSV 导出默认不动**
   (决策点 D-C1:导出是否同步补 resolved_names,默认不动 —— CSV 已有项目名/文件名列,
   details_json 本就原样 dump)。

**前端(落点 `AdminAuditPage.tsx` EventRow 展开块 338-363 + `api/types.ts` AuditEvent)**:

1. `AuditEvent` 类型补 `user_agent?: string | null; resolved_names?: Record<string, string>`。
2. 展开态结构化渲染 `details`(**替换现在的整块 JSON dump 为键值列表**,raw JSON 保留在
   `<details>` 折叠区做调试兜底):
   - 键名 label 化:本地 `DETAIL_KEY_LABEL` 映射(folder_id→目录、subject→主体、level→权限级别、
     task_id→任务、source_dir→源目录、reason→原因、size_bytes→大小、expires_at→过期时间、
     token→令牌、via→来源、username→登录名、name→名称、action→动作 …;缺 key 回落 raw 键名,
     与 `tlabel()` 同哲学);
   - 值渲染:`resolved_names` 有该键 → `名称(UUID 前 8 位…)` 并列展示(**id 和名称都给**,
     满足「有 id 展示名称」且不丢溯源能力);布尔 → 是/否;null → —;数组 → 逐项 join;
     ISO 时间串(expires_at)→ locale 格式;未知键 → 原样字符串。
3. 展开态补充展示:`actor_user_id`(替换误导性的 `actor_open_id` —— open_id 仅历史行非空时保留展示)、
   `user_agent`(有值才显示)、完整 `event_time`(绝对时间,收起态只有 Tooltip 悬浮)。
4. 不动收起态元信息行(W2b 已优化过)与过滤/导出逻辑。

### 3.3 测试点

1. 造数覆盖:folder_grant_added(subject=user)、project_member_added(subject=group#member)、
   baidu_task_create(target_folder_id)、group_member_added(带 group_name 的行不受影响)、
   share_link_created(sharer_user_id)→ 展开后各 id 旁均有名称。
2. 已删除对象:grant 的 folder 删掉后 → 回落裸 UUID,不报错。
3. details 垃圾值(folder_id="not-a-uuid")→ 跳过补名,接口不 500。
4. 历史行(无 resolved_names 字段的旧响应缓存)→ 前端回落现行为。
5. `user_agent` 为空的行不渲染该行;`actor_open_id` 仅历史飞书行展示。
6. 回归:收起态、过滤(事件类型/项目/操作者/日期)、CSV 导出、分页不变。

### 3.4 风险与钉子

- `details` 是自由 JSON,已知键清单是**白名单制** —— 漏掉的键走原样渲染,不会错,
  后续新增事件写入点时按需往 `_resolve_audit_detail_names` 的键集合里补(写进 CLAUDE.md
  「后端新增 event_type 时顺手补 mapping」同款约定的注释)。
- `share_link_created` 的 `details.token` 是完整分享令牌(带访问能力),审计页本就 system admin
  可见,维持展示;如嫌敏感可在前端 label 上标注「令牌(慎扩散)」—— 决策点 D-C2,默认原样。
- FGA 相关注意:**只查 DB 的 users/groups 表做名称解析,不碰 OpenFGA read API**
  (已知 FGA read 按 user 过滤查不到组 tuple,绕开)。

---

## 4. 需求 D:移动端批量操作栏按钮溢出

### 4.1 现状(亲验)

- 批量操作栏**仅存在于 compact(<1024)单栏分支**(`web/src/pages/ProjectDetailPage.tsx:625` 起;
  FolderDetailPage 是纯浏览页无批量栏,PC 三栏走顶部 ActionsBar,均不受影响)。
- 栏体 `ProjectDetailPage.tsx:840-890`:`position: sticky; bottom: 0`,**`display: flex` 且无
  `flexWrap`**,单行内容依次为:
  「已选 N」(`flexShrink: 0`)+ `flex: 1` 占位 + 5 个 `height: 44` 按钮:
  `打标 / 前缀 / 移动 / 删除 / 清空选择`(icon + 2-4 个汉字,antd Button 默认不换行、
  min-content 不可再缩)。
- 宽度测算:375px 屏,compact `main` 左右 padding 12×2、栏体自身 padding 14+8、
  gap 8×6 → 可用 ≈ 317px;内容实际 ≈ 480-520px(`已选N`≈65 + 打标/前缀/移动/删除 各≈70 +
  `清空选择`≈110)→ **溢出 ≈ 160-200px**。
- 致命一环:compact 下 `main` 是 `overflowX: 'hidden'`(`App.tsx:158-163` compact 分支)→
  溢出的按钮被**直接裁剪,既看不见也点不到**,与用户反馈「部分按钮无法正常显示」吻合。
- 列表底部为防 sticky 栏盖内容,`paddingBottom: hasSelection ? 76 : 12`(794-796 行)——
  76 是按单行栏高估的,改两行布局后需同步加大。
- `kbVisible` 键盘弹起隐藏逻辑(846 行)与 `--ms-z-batchbar` 层级正常,不动。

### 4.2 实施方案

**把栏体重构为确定性的两行布局**(不依赖 flexWrap 的动态换行,高度可静态预算):

```
┌──────────────────────────────────────┐
│ 已选 3                    [清空选择] │   行1:计数 + 轻操作(清空)
│ [打标] [前缀] [移动] [删除]           │   行2:4 个动作按钮等宽 grid
└──────────────────────────────────────┘
```

- 行2 用 `display: grid; gridTemplateColumns: repeat(4, 1fr); gap: 8` —— 按钮等宽自适应,
  375px 下每个 ≈ 74px(容纳 icon 14 + 2 字 + padding),320px(iPhone SE)下 ≈ 58px 仍可容纳;
  若真机验证 SE 偏挤,fallback `repeat(auto-fit, minmax(64px, 1fr))` 允许 2×2(此时高度仍确定,
  4 列换 2×2 高度翻倍 → padding 预算按下限场景实测定稿)。
- 按钮维持 `height: 44` 触达标准;`清空选择` 降为行1 的 text 型按钮(非主操作,视觉弱化)。
- `paddingBottom` 由 76 调至 ≈ 132(两行 44 + 栏内 gap/padding + 栏 marginTop 12),
  实施时按真机量一次定常数。
- Popconfirm 包着删除按钮的结构不变(移动端 Popconfirm 弹层位置在两行布局下正常)。

**明确不做**:批量下载入栏(§3.1 既定决策:移动端浏览器拦截连续多下载,走卡片行内按钮,
勿回潮);PC 分支 ActionsBar 不动。

### 4.3 测试点

1. 320 / 375 / 414 / 430px 宽度真机(devtools 模拟 + 至少一台真机):5 个操作全部可见可点,
   无横向裁剪。
2. 勾选态滚动到列表底部:末尾卡片不被 sticky 栏盖住(padding 生效)。
3. 键盘弹起(搜索框聚焦)批量栏隐藏、收起恢复。
4. 回归:打标/前缀/移动/删除/清空功能本身不变;跨页保留选中语义不变;
   PC(≥1024)布局零变化。
5. Popconfirm 确认弹层在两行栏上定位正常。

### 4.4 风险与钉子

- 无架构风险,纯布局;唯一钉子是 padding 常数与极窄屏(SE)的按钮宽度,真机定稿。
- 该栏是 W6(批量移动)后新挤满的 —— 后续若再增按钮,按「行2 满 4 个则移行1 或换 2×2」约定扩展,
  写进组件注释。

---

## 5. 工作包拆分与文件清单

| 包 | 新增文件 | 修改文件 | 依赖 |
|----|---------|---------|------|
| A | `web/src/lib/inapp.ts`、`web/src/components/InAppBrowserTip.tsx` | `web/src/App.tsx`(挂载)、`web/package.json`(+inapp-spy) | 无 |
| B | — | `web/src/components/AssetPreviewModal.tsx`(Props+导航+footer+切换重置)、`AssetSummaryPanel.tsx`(透传)、`pages/FolderDetailPage.tsx` / `pages/ProjectDetailPage.tsx` / `pages/SearchPage.tsx`(接线) | 无 |
| C | — | `api/app/routers/admin.py`(AuditOut+helper+组装)、`web/src/api/types.ts`、`web/src/pages/AdminAuditPage.tsx` | 无 |
| D | — | `web/src/pages/ProjectDetailPage.tsx`(批量栏重构 + paddingBottom) | 无 |

四包零交集,可并行;均零 migration、零 FGA model 变更、零 nginx/env 变更。

## 6. 决策点汇总(默认值可被否决)

| # | 问题 | 默认 |
|---|------|------|
| D-A1 | 检测范围:仅用户点名三家(微信/企业微信/抖音)vs 顺带 QQ/钉钉/微博 | 顺带全带(成本≈0) |
| D-A2 | PC 端微信/企业微信(含 MicroMessenger 但非 mobile)是否提示 | 不提示(引导语对 PC 无意义) |
| D-A3 | 提示形态:非阻断可关横幅 vs 阻断 modal | 非阻断横幅 |
| D-A4 | 关闭后静默周期 | sessionStorage(当次会话) |
| D-C1 | CSV 导出是否同步补 resolved_names | 不动 |
| D-C2 | 分享令牌 token 前端是否标注「慎扩散」 | 原样展示 |
| D-D1 | 批量栏布局:两行确定性布局 vs 单行 flexWrap 动态换行 | 两行确定性布局 |

## 7. 验收口径(真机,交 tester)

- A:微信/企业微信/抖音真机各开一次分享链接 + 一次登录页 → 横幅 + 复制链接可用;
  系统 Safari/Chrome 无横幅。
- B:文件夹页/项目页/盲搜页三入口,预览内 ‹ › 键盘翻页 + 下载,移动端小屏不破版。
- C:管理员审计页,挑 grant / 成员 / 备份类事件各一条展开,id 旁有名称,raw JSON 仍可查。
- D:iPhone(含最小屏 SE 或 320px 模拟)项目文件夹多选 → 5 个批量按钮全部可见可点,
  无横向裁剪,列表底部不被遮挡。
