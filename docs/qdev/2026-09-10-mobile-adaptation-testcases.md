# 测试用例清单 · 移动端显示适配（2026-09-10）

> 依据：[rushes-spec/material-storage/mobile-adaptation-plan.md](../../rushes-spec/material-storage/mobile-adaptation-plan.md) §3/§5/§6/§7
> 与 [2026-09-10-mobile-adaptation.md](./2026-09-10-mobile-adaptation.md)（工作包/验收口径）。
> 用例总数 89。每条可独立执行、可判定；"预期"列均为可观察断言，禁止以"页面正常"代替。

## 0. 环境与工具说明

### 0.1 日常验证（开发自测，Chrome DevTools 设备仿真）

- 仿真尺寸：**375×667**（iPhone SE）、**390×844**（iPhone 12/13/14）、**768×1024**（iPad 竖屏）；
  **1024×768** 仅做宽度点抽查（iPad 横屏临界）。
- 设备工具栏 Device type 选 **Touch（Mobile）**：DevTools 会同时模拟 `pointer:coarse and hover:none`，
  触控层 CSS 与 hover 降级据此生效；切回 Desktop type 验证鼠标路径。
- 横向滚动判定口径：`document.documentElement.scrollWidth <= window.innerWidth`；
  **表内横滚（`scroll.x=600`）不计为页面横向滚动**（§6.1 明确允许，与现状等同）。
- z 层级判定口径：内容(0) < header(50) < 批量栏(60) < TabBar(70) < UploadFloatingIndicator(80)
  < antd Drawer/Modal(1000+)。预览 Modal 与详情 Drawer 靠 DOM 挂载顺序叠层，实现禁止改 `getContainer`。
- 键盘类用例 DevTools 无法模拟 iOS 键盘，标注"真机"的以真机为准；
  KB-04 可在 Console 以 `el.focus()` + 手动派发 `visualViewport` resize 事件辅助预验。

### 0.2 真机项（tester 执行）

- 触发条件：部署 **server2** 后执行；部署方用 **`MAINTENANCE_ISSUES` modal** 告知 tester
  本轮回归范围与"请用手机访问"提示（方案 §7 PR4）。
- 真机环境两组：**iOS Safari**（含刘海机型验证 safe-area）与 **Android Chrome**；
  分享复制兜底项另需 **内网 HTTP** 环境（§6.6）。
- 真机用例集中在：下载落盘（DL-02/03/04/05/07）、分享（SHARE-03/04/05）、键盘（KB-01/02/03），
  以及 SHELL-06（安全区）、TOUCH-05（iOS 聚焦缩放）的真机复核。

### 0.3 自动化门槛（命令级，非 UI 用例）

| ID | 命令 | 通过标准 | 覆盖说明 |
| --- | --- | --- | --- |
| AUTO-01 | `material-storage/web` 下 `pnpm build` | 退出码 0，无 TS/Vite 错误 | 全部新增组件/hook 的类型与编译硬门槛，是所有 UI 用例的前置 |
| AUTO-02 | `material-storage/web` 下 `pnpm lint` | 退出码 0（按现有 lint 口径） | 同上 |
| AUTO-03 | 后端容器 `pytest tests/test_download_attachment.py`（后端包产出） | 不传 `as_attachment`（含传 `{}`，即 `AssetPreviewModal.tsx:78` 现有调用形态）时：`DownloadLinkOut` 三字段（url/expires_in/is_sensitive）结构不变、签名 URL Params **无** `ResponseContentDisposition`、404/403 行为不变 | 覆盖"预览路径零变化"的后端面（§6.7）；前端面由 PC-04 人工复核 |
| AUTO-04 | 同上 | `as_attachment=true` 时 presign Params 含 `ResponseContentDisposition: attachment; filename="<ASCII兜底>"; filename*=UTF-8''<RFC5987>`（中文文件名走 RFC 5987 百分号编码） | DL-02/03/05 的后端契约面 |
| AUTO-05 | 同上 | `share.py` 分享下载签发同带 attachment 语义 | DL-07 的后端契约面 |

**其余 UI 用例均为人工执行**（仿真 / 真机），无现成前端 UI 自动化设施，本清单不虚构。

---

## 1. 全局壳层（SHELL，13 条）

| ID | 前置 | 步骤 | 预期 | 尺寸 | 方式 |
| --- | --- | --- | --- | --- | --- |
| SHELL-01 | 已登录，任意页 | 375×667 + Touch 打开 `/`；比较 `scrollWidth` 与 `innerWidth`；查看 `main` padding | 无横向页面滚动；main padding 为 compact 值（`16px 12px calc(56px+safe-area+32px)`）而非 PC 的 `32px 24px 80px` | 375 / 390 | 仿真 |
| SHELL-02 | 已登录 | 768×1024 打开 `/` | 同样无横向滚动，**且 TabBar 存在**（平板竖屏获移动壳层，非 PC 顶栏） | 768 | 仿真 |
| SHELL-03 | 已登录 | 375 观察顶栏元素 | 六个 nav chips（项目/审批/我的权限/审计/用户/用户组）均不渲染 | 375 / 768 | 仿真 |
| SHELL-04 | 已登录 | 375 观察顶栏；尝试触达搜索 | 无 ⌘K 触发框、无 CommandPalette 入口；搜索唯一触达路径 = TabBar"搜索"tab 进 `/search` | 375 | 仿真 |
| SHELL-05 | 已登录 | 375 观察顶栏 | 无通知 Bell；顶栏仅剩 logo、任务收件箱 icon、头像（通知唯一正门 = TabBar） | 375 | 仿真 |
| SHELL-06 | 已登录，存在未读通知 | 375 检查 TabBar | 5 个 tab（项目/搜索/审批/通知/更多）fixed bottom，总高 56px；通知 tab 有未读 badge（与 PC Bell 同一 query 缓存）；`padding-bottom` 含 `env(safe-area-inset-bottom)`（刘海真机复核） | 375 | 仿真（+真机复核） |
| SHELL-07 | 已登录 | 依次访问 `/`、`/projects/:id`、`/projects/:id/folders/:id`、`/folders/:id` | 四种 URL 下均为且仅为"项目"tab 高亮 | 375 | 仿真 |
| SHELL-08 | 已登录 | 依次访问 `/search`、`/approvals`、`/notifications` | 分别高亮"搜索/审批/通知"，其余 tab 不亮 | 375 | 仿真 |
| SHELL-09 | 已登录 | 访问 `/my-permissions` 与 `/admin/users` | 5 个 tab 均不高亮；从"更多"Drawer 进入这些页时"更多"呈高亮 | 375 | 仿真 |
| SHELL-10 | 非 `is_system_admin` 账号 | 打开"更多" Drawer | 仅"我的权限"一项；**无** 审计/用户管理/用户组管理 入口（无 403 死链） | 375 | 仿真 |
| SHELL-11 | `is_system_admin` 账号 | 打开"更多" Drawer 并逐项点击 | 四项（我的权限/审计/用户管理/用户组管理）齐全；点击后进入对应路由且 Drawer 关闭 | 375 | 仿真 |
| SHELL-12 | 已登录 | 打开"更多" Drawer 检查规格 | `placement=bottom`、高度内容撑开且 ≤60vh、顶部 36×4 grip 条、点遮罩关闭、每条目高度 ≥44px | 375 | 仿真 |
| SHELL-13 | 仓库 checkout 状态 | 检查 `index.html` 与 `tokens.css` | viewport meta 含 `viewport-fit=cover`；有 `theme-color #FAFAF7`；tokens.css 含 `--ms-tabbar-h:56px` 与 `--ms-z-header/batchbar/tabbar/float` 阶梯 | 静态 | 仿真（静态检查） |

## 2. ProjectDetailPage（PD，20 条）

| ID | 前置 | 步骤 | 预期 | 尺寸 | 方式 |
| --- | --- | --- | --- | --- | --- |
| PD-01 | 打开有 ≥1 folder 的项目 | 375 检查布局骨架与滚动 | 单栏：无 FolderTree Sider、无右 Summary Sider；无 `calc(100vh-…)` 固高内滚（自然文档流滚动）；容器无 `borderRadius`/`boxShadow`（仅 PC 分支保留） | 375 / 768 | 仿真 |
| PD-02 | 同上 | 观察 folder header 最左 | 有夹树触发按钮 = hamburger icon + 当前 folder 名 + chevron-down | 375 | 仿真 |
| PD-03 | 同上 | tap 触发按钮 | 左侧 Drawer 弹出，宽 `min(320px, 84vw)`（375 下 315px），树完整可滚动，含新建入口（有权限时） | 375 | 仿真 |
| PD-04 | Drawer 已打开 | 在 Drawer 选中另一 folder | Drawer 关闭；URL replace 为 `/projects/:id/folders/:fid`；header folder 名与列表更新；回第 1 页且清空选择 | 375 | 仿真 |
| PD-05 | folder 内有含长文件名/多标签的文件 | 375 检查卡片结构 | 每卡：缩略图 44px + 文件名两行省略 + 副行(size · 日期) + 标签独立行（≤3 个 + "+N"）+ 行尾下载 icon；卡片无横向溢出 | 375 | 仿真 |
| PD-06 | 同上 | tap 卡片主体（避开 checkbox/下载钮） | bottom 详情 Drawer，高 `min(72vh, 72dvh)`，内容为 AssetSummaryPanel 单选态（预览/下载/分享/打标/元信息）；内容超高时 Drawer 内部可滚 | 375 | 仿真 |
| PD-07 | 详情 Drawer 已开，当前页 ≥2 个文件 | 连续 tap `›` 与 `‹` | 头部 `‹ n/N ›` 切换内容，N=当前页文件数；Drawer 常驻不关；边界行为与 PR 描述一致（不循环或按钮禁用） | 375 | 仿真 |
| PD-08 | 详情 Drawer 已开 | tap"预览"，关闭预览 | 预览 Modal 叠于 Drawer 之上；关闭后 Drawer 仍在且停留在原文件（未改 getContainer，DOM 顺序叠层正确） | 375 | 仿真 |
| PD-09 | 当前页 ≥3 个文件 | 勾 1 张 → 观察计数与全选框；tap 全选 → 再 tap | 计数变"已选 1 / 本页 M"；全选框呈半选态；tap 全选后全勾选，再 tap 清空；卡片 checkbox 与全选共享同一 `selectedIds` | 375 | 仿真 |
| PD-10 | 勾选 ≥1 | 观察底部 | 批量操作栏浮出：sticky，`bottom = 56px + safe-area`，z 低于 TabBar 高于内容；含"已选 N"+ 打标/删除/清空选择 | 375 | 仿真 |
| PD-11 | 勾选 ≥1（**防误报口径**） | 检查批量栏按钮集 | 批量栏**没有"下载"按钮**——移动端设计如此（浏览器拦截连续多下载），逐个下载走每卡行内按钮；不得记 bug | 375 | 仿真 |
| PD-12 | 批量栏可见 | tap"清空选择"；再分别翻页、切夹 | 三种操作后批量栏收起；列表追加的 padding-bottom 恢复 | 375 | 仿真 |
| PD-13 | 勾选 ≥1 且 folder 文件多 | 滚动到列表末端 | 最后一张卡与分页器完整可见，不被"批量栏 + TabBar"双层遮挡 | 375 | 仿真 |
| PD-14 | folder total > 30 | 观察并翻到第 2 页 | 分页器以文档流普通块出现（非 overlay）；翻页后选择清空、列表回顶、新页加载 | 375 | 仿真 |
| PD-15 | 分别用 有/无 `my_can_upload` 的账号 | 观察上传按钮并 tap | 无权限：disabled + Tooltip 文案；有权限：打开上传抽屉，Uppy Dashboard 在窄屏自响应式完整可用 | 375 | 仿真 |
| PD-16 | 勾选 ≥1 且有上传权限 | 批量栏 tap"打标"，输入标签回车，确认 | BulkTagModal 宽度钳制在屏内；tags Select 可输入成 chip；确认后 toast 成功、卡片标签行更新 | 375 | 仿真 |
| PD-17 | 分别用 有/无 `my_can_admin` 的账号 | 观察 folder header | 有权限：有"管理"按钮 → bottom Drawer 内渲染 FolderInvitePanel/FolderGrantsPanel 空选态；无权限：无此按钮 | 375 | 仿真 |
| PD-18 | sensitive 与普通夹各一 | 375 观察 header 一行 | sensitive 徽标 / 我的权限 chips / 成员 / 申请链接 / 删除文件夹允许 wrap，无溢出无裁切；按钮显隐沿用现有权限逻辑 | 375 | 仿真 |
| PD-19 | 卡片有下载权限 | tap 卡片行尾下载 icon | 触发下载流程且**不**打开详情 Drawer（stopPropagation 生效）；请求期间按钮有 loading 态 | 375 | 仿真 |
| PD-20 | 打开无任何 folder 的项目 | 375 查看空态 | 空态卡片（图标+文案+新建/申请按钮）单列完整、无横向滚动；按钮可用 | 375 | 仿真 |

## 3. FolderDetailPage（FD，4 条）

| ID | 前置 | 步骤 | 预期 | 尺寸 | 方式 |
| --- | --- | --- | --- | --- | --- |
| FD-01 | 375 打开 `/folders/:id`（≥1 文件） | 检查列表并 tap 卡片 | 复用 AssetCardList 但**无 checkbox**（无批量操作）；tap 卡片 → 详情 Drawer + `‹n/N›` 切换可用 | 375 / 768 | 仿真 |
| FD-02 | folder total > 30 | 滚动页面观察分页器 | 分页器保持 `sticky bottom:0` 钉底，位于 TabBar 之上不被盖；翻页后回顶 | 375 | 仿真 |
| FD-03 | 深层级 folder（长面包屑） | 375 观察面包屑 | `.ms-breadcrumb` 容器横向滚动（不撑破布局），滚动末项完整显示 | 375 | 仿真 |
| FD-04 | 分别用 有/无 `my_can_upload` 的账号 | 观察上传按钮并 tap | 门控同 PD-15；有权限时上传抽屉窄屏可用 | 375 | 仿真 |

## 4. 搜索（SEARCH，3 条）

| ID | 前置 | 步骤 | 预期 | 尺寸 | 方式 |
| --- | --- | --- | --- | --- | --- |
| SEARCH-01 | 已登录 | TabBar tap"搜索"，输入关键词，再清空 | 300ms 防抖后出结果；URL `?q=` 同步；清空后恢复引导文案 | 375 | 仿真 |
| SEARCH-02 | 有命中结果 | 375 检查结果行 | folder/project 信息换行到文件名下方（单行不再挤压）；`Enter` kbd 徽标不渲染；命中词高亮正常；长文件名省略不溢出 | 375 | 仿真 |
| SEARCH-03 | 有命中结果 | tap 任一结果卡 | 跳转 `/folders/:id` 进入卡片列表；此时 TabBar"项目"高亮（映射含 /folders/*） | 375 | 仿真 |

## 5. 通知（NOTIF，1 条）

| ID | 前置 | 步骤 | 预期 | 尺寸 | 方式 |
| --- | --- | --- | --- | --- | --- |
| NOTIF-01 | 有 ≥1 未读通知 | 375 打开 `/notifications`，tap 条目，再"全部已读" | 列表单列无溢出；tap 按类型跳转并标已读；全部已读后 TabBar"通知"badge 立即消失（同源缓存） | 375 | 仿真 |

## 6. 审批（APPR，3 条）

| ID | 前置 | 步骤 | 预期 | 尺寸 | 方式 |
| --- | --- | --- | --- | --- | --- |
| APPR-01 | 存在待审项 | 375 检查审批行布局 | 单列：操作按钮组换行到卡片底部且为常规尺寸（非 small）；padding `'14px 16px'`；meta 行（状态/资源/申请人/时间）wrap 不溢出 | 375 | 仿真 |
| APPR-02 | 有可决策的 pending 项 | tap 批准；再对另一项 tap 拒绝 | 批准 → toast"已批准"且状态徽标更新；拒绝 → modal.confirm 在屏内可完整操作 | 375 | 仿真 |
| APPR-03 | 两种 scope 均有数据 | 切换"我的申请 / 待我审批"tabs | 切换正常；Tab 栏 375 下不溢出（antd Tabs 自滚动） | 375 | 仿真 |

## 7. 我的权限（PERM，2 条）

| ID | 前置 | 步骤 | 预期 | 尺寸 | 方式 |
| --- | --- | --- | --- | --- | --- |
| PERM-01 | 账号有多种角色项目 | 375 操作 Segmented | Segmented 包在 `.ms-hscroll`：可横向滑动，右缘渐隐提示；4 个过滤（含计数）逐个切换且列表随之变化 | 375 | 仿真 |
| PERM-02 | 有临时授权与多角色卡片 | 375 检查行布局 | 角色 badge / 日期 / 倒计时 wrap，无单行挤压溢出 | 375 | 仿真 |

## 8. Admin 三页（ADMIN，5 条，低频"可用"级）

| ID | 前置 | 步骤 | 预期 | 尺寸 | 方式 |
| --- | --- | --- | --- | --- | --- |
| ADM-01 | `is_system_admin`，有用户数据 | 375 打开 `/admin/users` 检查行 | 行容器 wrap：创建日期换行（`flexBasis:100%`）；姓名/状态/账号信息列完整可读；停用/启用/重置按钮完整可见可点 | 375 | 仿真 |
| ADM-02 | 同上 | 操作搜索框与角色 Select | 固定宽已改 `flex:1, minWidth:0`，无溢出；搜索与过滤实际生效 | 375 | 仿真 |
| ADM-03 | 存在用户组 | 375 打开用户组页与某组成员 Modal | 行 wrap 不溢出；成员 Modal 宽 `min(560px, calc(100vw - 16px))` 屏内完整、列表可滚 | 375 | 仿真 |
| ADM-04 | 有审计数据 | 375 打开 `/admin/audit` 检查时间筛选 | RangePicker 替换为单个 DatePicker（无 showTime），文案注明"按日期筛选"；选日期后筛选生效 | 375 | 仿真 |
| ADM-05 | 同上 | 操作 UserPicker 与查看事件行 | UserPicker `flex:1, minWidth:0` 可用；EventRow wrap 无溢出；重置按钮可达 | 375 | 仿真 |

## 9. 认证与落地页（AUTH，4 条）

| ID | 前置 | 步骤 | 预期 | 尺寸 | 方式 |
| --- | --- | --- | --- | --- | --- |
| AUTH-01 | 有效本地账号 | 375 打开 `/login` 登录 | 纵向 margin 收敛（64→24px）；表单单列完整；登录成功回跳 `next`；无横向滚动 | 375 | 仿真 |
| AUTH-02 | `must_change_password` 账号 | 375 完成 `/change-password` | 页面收敛不溢出；改密流程可完整提交 | 375 | 仿真 |
| AUTH-03 | 有效分享链接 | 375 打开 `/s/:token` | 卡片自适应（640 宽约束解除后不溢出）；asset 类显示"下载到本地"大按钮，folder 类显示"打开文件夹" | 375 | 仿真 |
| AUTH-04 | 有效申请链接 | 375 打开 `/r/:token` 并操作 | 内容完整无溢出；接受/拒绝操作可完成并出结果态 | 375 | 仿真 |

## 10. 下载（DL，7 条）

| ID | 前置 | 步骤 | 预期 | 尺寸 | 方式 |
| --- | --- | --- | --- | --- | --- |
| DL-01 | 有下载权限 | 375 tap 卡片行尾下载，看 DevTools Network 与任务中心 | Network 可见 `POST /assets/{id}/download-link` 请求体含 `"as_attachment":true`；打开签名 URL 用 `target=_blank`，SPA 不被顶掉；任务中心新增"文件名 + 已交给系统下载"记录并 toast | 375 | 仿真 |
| DL-02 | 真机（iOS Safari / Android Chrome），有 jpg | tap 下载 | jpg **真实落盘**（iOS 存"文件"、Android 进下载管理），浏览器**不**内联打开图片；文件名正确 | 375 真机 | **真机** |
| DL-03 | 真机，有 mp4 | tap 下载 | mp4 真实落盘，**不**内联进播放器页 | 375 真机 | **真机** |
| DL-04 | 真机，准备 >500MB 素材 | 发起下载，期间保持页面 | 走系统下载器（自带断点），页面不崩、无 JS 内存暴涨；完成后核对文件大小一致 | 375 真机 | **真机** |
| DL-05 | 真机，准备中文名文件（如 `棚拍-A机-01.mp4`） | 下载并查看落盘名 | 文件名与原名一致（RFC 5987 生效），无百分号编码残留/乱码 | 375 真机 | **真机** |
| DL-06 | 仿真环境（无 showSaveFilePicker） | 下载时看 Network | 移动路径**无** fetch→Blob 全量请求（对素材 URL 无 XHR/fetch stream），仅 presign 请求 + 导航（旧崩页元凶已删除） | 375 | 仿真 |
| DL-07 | 真机，asset 分享链接（jpg） | 打开 `/s/:token` tap"下载到本地" | 真实落盘而非内联打开（依赖 share.py attachment 签发 = AUTO-05）；"访问需登录"提示正常 | 375 真机（内网） | **真机** |

## 11. 分享（SHARE，5 条）

| ID | 前置 | 步骤 | 预期 | 尺寸 | 方式 |
| --- | --- | --- | --- | --- | --- |
| SHARE-01 | 有可分享素材 | 375：tap 卡片 → Drawer tap"分享" → 提交 | 两步动线可达 ShareModal；TTL Select 与表单在钳制宽度内可用；提交出结果态 | 375 | 仿真 |
| SHARE-02 | 结果态已显示 | 375 检查并 tap 复制 | 结果态为全宽"复制链接"大按钮（非 Input.Group）；DevTools HTTPS 下 tap 后 toast"链接已复制" | 375 | 仿真 |
| SHARE-03 | 真机（navigator.share 可用） | 生成分享并在结果态触发分享 | 优先拉起系统分享面板（iOS 分享 sheet / Android 分享）；取消分享不报错 | 真机 | **真机** |
| SHARE-04 | 真机 HTTPS 环境 | 复制链接并粘贴验证 | `navigator.clipboard` 路径复制成功；粘贴出的 landing_url 可打开落地页 | 真机 | **真机** |
| SHARE-05 | 真机 + 内网 HTTP 环境 | 同上 | clipboard API 不可用时 `execCommand('copy')` 兜底生效：toast 成功、不出现"复制失败"（§6.6） | 真机（内网） | **真机** |

## 12. 键盘（KB，4 条）

| ID | 前置 | 步骤 | 预期 | 尺寸 | 方式 |
| --- | --- | --- | --- | --- | --- |
| KB-01 | 真机，详情 Drawer 已开 | tap 打标输入框（Select/标签输入） | 键盘弹起时：TabBar、批量操作栏、UploadFloatingIndicator 隐藏；详情 Drawer **不隐藏**而是收缩为 `visualViewport.height − 顶栏`，输入框与确认按钮可见可点 | 真机 | **真机** |
| KB-02 | 承 KB-01 | 收起键盘 | 三者恢复显示；Drawer 高度恢复 `min(72vh,72dvh)`；`‹n/N›` 与滚动位置正常 | 真机 | **真机** |
| KB-03 | 真机，无输入聚焦 | 捏合缩放页面触发 viewport resize | TabBar 不消失不闪烁（resize 守卫：仅 activeElement 为输入类时才判为键盘） | 真机 | **真机** |
| KB-04 | 375 `/search` | Console：`input.focus()` + 派发 resize 模拟键盘；再 blur | 聚焦时 TabBar 隐藏，失焦恢复（真机由 KB-01/02 同机制覆盖） | 375 | 仿真（辅助） |

## 13. 触控（TOUCH，5 条）

| ID | 前置 | 步骤 | 预期 | 尺寸 | 方式 |
| --- | --- | --- | --- | --- | --- |
| TOUCH-01 | Touch 仿真（coarse） | 检查新组件命中区 | ≥44px：卡片下载按钮、批量栏按钮、TabBar 5 tab、更多 Drawer 条目（getBoundingClientRect 实测） | 375 | 仿真 |
| TOUCH-02 | Touch 仿真 | 检查旧 antd 控件地板 | `.ant-btn-sm` ≥34px、`.ant-btn-icon-only` ≥38px（computed min-height/min-width） | 375 | 仿真 |
| TOUCH-03 | Touch 仿真 | 检查三个自定义 ghost 按钮（FolderTree 新建 / UserMenu 复制 / AssetTagEditor 确认） | 均带 `.ms-ghost-btn` class 且 ≥38×38px | 375 | 仿真 |
| TOUCH-04 | Touch 仿真 vs Desktop 仿真 | 对比卡片 hover | coarse 下 hover 无 transform 位移（仅边框/阴影变化）；鼠标路径下位移保留 | 375 / 1440 | 仿真 |
| TOUCH-05 | <768 仿真 + iOS 真机 | 检查输入 computed font-size；真机聚焦输入 | `.ant-input`/Select 搜索 input/DatePicker 内 input 均 ≥16px；iOS 真机聚焦**不触发自动放大** | 375 | 仿真 + 真机复核 |

## 14. PC 回归（PC，8 条）——红线：PC 分支应零变化

| ID | 前置 | 步骤 | 预期（截图对比点） | 尺寸 | 方式 |
| --- | --- | --- | --- | --- | --- |
| PC-01 | feat 分支合入前先截基线图 | 1440 与 1920 打开任意页，对比顶栏 | 六个 nav chips、⌘K 触发框（minWidth 220）、任务收件箱、Bell+badge、头像逐元素在位，位置/尺寸/交互（⌘K 打开 Palette）与基线一致 | 1440 / 1920 | 仿真（截图对比） |
| PC-02 | 有多夹多文件项目 | 1440 对比 ProjectDetail | 三栏（260 / 中栏 / 320）+ 固高内滚（`calc(100vh-56-32-80)`）+ 容器圆角阴影保留；分页钉底、切夹回顶行为不变 | 1440 / 1920 | 仿真 |
| PC-03 | 同上 | 对比 Table 交互 | 行点击切换选中、size/created_at 排序、rowSelection 列、批量"下载 N"按钮**存在且可用**（PC 批量下载保留，与移动端口径相反，均非 bug）、`scroll.x=600` 不变 | 1440 | 仿真 |
| PC-04 | 有 图片/视频/PDF 各一 | 1440 打开预览弹窗 | 图片/视频 maxHeight 65vh、PDF iframe 68vh 内联可滚，工具栏按钮尺寸不变；Network 中预览 URL 无 attachment 语义（AUTO-03 兜底） | 1440 | 仿真 |
| PC-05 | 登录态 | 1440/1920 对比全部 B 类页（Projects 卡片网格 / Approvals / MyPermissions / AdminUsers / AdminGroups / AdminAudit） | 六页逐页截图零变化；全局无 TabBar；main padding 仍 `32px 24px 80px` | 1440 / 1920 | 仿真 |
| PC-06 | — | 1024 宽度点抽查 | 呈现 PC 骨架（顶栏 chips + 三栏，按实现断点，须与 PR 描述一致）；ProjectDetail 中栏 Table 允许表内横滚（与现状等同，不算回归） | 1024 | 仿真 |
| PC-07 | 1440 打开 ProjectDetail | DevTools 响应式拖拽 1440→900→1440 来回三次 | 断点处壳层即时切换；全程无白屏/报错（hooks 置顶约定成立，无分支 hook 数量不匹配崩溃） | 900↔1440 | 仿真 |
| PC-08 | 桌面 Chromium | 发起单文件下载 | 仍走 File System Access API 保存对话框路径；任务中心进度/取消可用（FSA 路径保留，fetch→Blob 删除仅限移动分支） | 1440 | 仿真 |

---

## 附：方案未覆盖的测试盲点（对照代码发现，供 PM/前端确认）

1. **断点灰区 992–1023**：方案通篇写 `useCompactViewport()` 为 `<1024（antd lg）`，但 antd 的 `lg` 断点实为 **≥992px**——按方案 §2.1 的实现（`!screens.lg`）在 992px 即切 PC 壳层，与方案文字"1024"有 31px 出入。PC-06 按"1024=PC"写，但 992–1023 区间的归属需实现前拍板（自定义 `min-width:1024` media 或接受 992），否则用例与实现可能各执一词。
2. **`/dev-login`（DevLoginPage）不在方案 §0.2 页面清单**：它绕过 AppShell（无顶栏/无 TabBar）直接渲染，移动端表现无定义；tester 若从历史记录进入会看到"裸页"。建议明确豁免或补一条用例。
3. **⌘K 全局快捷键监听在 compact 下是否卸载未定义**：AppHeader 的 `window keydown` 监听若随 PC 分支保留，平板接物理键盘按 Ctrl/⌘+K 仍会弹出 CommandPalette（Modal 宽 560 会被钳制），与"Palette 保留 PC 专属"表述矛盾，无验收口径。
4. **分享落地页（接收侧）移动下载依赖 share.py 同改**：`ShareLandingPage.tsx:212` 的 CTA 是 `href=download_url` + `download` 属性，跨域响应无 attachment 头时 `download` 属性被忽略 → jpg/mp4 会内联打开。方案 §3.5 提了"share.py 同改"，但 §6 核心流只测"发起分享"，未列接收侧落地页下载——本清单 DL-07 已补，后端包务必覆盖 AUTO-05。
5. **MaintenanceBanner 顶横幅**：维护期横幅激活时会叠在 56px 顶栏上方并压缩可视高度，影响截图对比基线与"无横向滚动"判定，方案未提；建议基线截图在无横幅状态下截取。
6. **Modal 钳制后的逐一手测清单**：方案 §5 只说"逐 Modal 手测清单（§6）"但未列清单；本清单已覆盖 BulkTagModal（PD-16）、成员/用户组 Modal（ADM-03）、RequestAccessModal（FD-01 间接）、拒绝 confirm（APPR-02），若 PR 中新增 Modal 需另行补充。
