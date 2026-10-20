# 浣花视界 App 完整版实施方案(v2.1 · 全功能对标 web 版)

> 状态:**待评审**(2026-10-20 v2.1:并入两份外审意见的采纳项,处理记录见 §18)。
> v2.1 修订要点:分享/请求链接范围按 web 实况修正(web 无列表/撤销);上传 complete
> 响应丢失语义;统一错误处理小节;轻量 B0 技术验证批;传输不持久化的明确决策。
> 对标源 = **web 版(material-storage/web)现有全部功能**,不区分一期二期,一次做全。
> UI 参照 Open Design 12 屏(`536948e5-…`);设计稿中 web 无对应物的元素见 §17。
> 输入:MVP 已打通 iOS livp 上传/下载(`material-storage/app/`,至 658d865)。
> 关联:`ios-livp-app-build-handbook.md`(构建链)、`permissions-model-v4.md`(权限模型)、
> `mobile-adaptation-plan.md`(web 响应式,与本方案无关)。

## 已拍板决策(2026-10-20,写入本方案为定稿口径)

| # | 决策 | 落地 |
| --- | --- | --- |
| D1 | Android 下载 livp **双落盘**(解包入图库 + .livp 原档存 Downloads,占双倍空间) | §6.2 |
| D2 | 素材多选操作栏**全量操作** | §8.3 |
| D3 | 搜索进版本 | §1 / §8.8 |
| D4 | 预览大图用缩略图(1024px) | §8.2 |
| D5(本轮) | **完整对标 web 版全部功能,不分期** | 全文;批次 §16 仅是工程顺序 |

---

## 0. 目标与原则

1. **功能对等**:web 版用户能做的事,App 都能做(管理后台、百度备份、审批、分享全量)。
2. **核心流程极简**(不因功能全而变复杂):上传两步、下载一步,其余功能收进二级入口,
   主界面(项目/搜索/传输/我的)不被管理功能污染。
3. **组件化纪律**:单文件目标 ≤ 200 行、硬顶 300;页面文件只留骨架,行/卡/表单拆组件文件。
4. **后端基本零改动**:全部走既有端点;唯一对接缺口=百度授权回调(§8.12 G1,App 侧解决)。

## 1. 对标功能矩阵(web → App)

对标源以 web 路由 + 组件盘点为准确(2026-10-20 代码核实)。**左列每行都必须有 App 落点。**

| 功能域 | web 入口/组件 | App 落点 | 端点(全部已有) |
| --- | --- | --- | --- |
| 登录 | LoginPage | 登录页(§4 探活,无环境选择) | POST /auth/local/login |
| 会话恢复/登出 | UserMenu | 我的页 + 自动恢复 | GET /auth/me、POST /auth/logout |
| 修改密码(含强制流) | ChangePasswordPage | 我的页→账号与安全 | POST /auth/change-password |
| 维护公告 | MaintenanceBanner | 登录页/首页顶部横幅 | GET /maintenance/banner |
| 项目列表 | ProjectsPage(首页) | tab1 项目(权限徽标) | GET /projects |
| 新建项目 | NewProjectModal | 项目页 + 菜单(闸门 is_project_creator) | POST /projects |
| 已删除项目/恢复 | DeletedProjectsModal | 我的页→回收站(项目) | GET /projects/deleted、POST restore |
| 项目成员管理 | ProjectMembersDrawer + SubjectPicker/RoleChipGroup | 项目页→成员(抽屉) | GET/POST/DELETE /projects/{id}/members、GET/DELETE grants |
| 刷新默认权限 | ApplyDefaultModal | 项目页→成员→应用默认模板 | POST /admin/grant-templates/apply-default |
| 文件夹浏览 | ProjectDetailPage + FolderTree | 项目→文件夹列表(subtree 徽标/敏感锁) | GET /folders?project_id= |
| 新建/重命名/移动/删除文件夹 | New/Rename/MoveFolderModal | 文件夹页 ⋯ 菜单 | POST/PATCH/DELETE /folders、PATCH move |
| 敏感夹邀请/撤销 | FolderInvitePanel | 文件夹页→授权(敏感夹) | POST/DELETE /folders/{id}/invite |
| 文件夹授权/倒计时 | FolderGrantsPanel + GrantCountdown | 文件夹页→授权 | GET/POST/DELETE /folders/{id}/grants |
| 素材宫格+缩略图 | FolderDetailPage + AssetThumbnail | 文件夹→宫格 | GET /assets、GET thumbnail-url |
| 素材预览(全类型) | AssetPreviewModal + ‹n/N› | 预览页(胶片条,§8.2) | thumbnail-url、live-preview-url、download-link |
| 详情/打标/备注 | AssetSummaryPanel + AssetTagEditor | 预览页元数据卡(§8.2) | PATCH /assets/{id}/meta |
| 批量打标 | BulkTagModal(merge/replace) | 操作栏⋯→批量打标 | PATCH /assets/{id}/meta(逐条) |
| 批量前缀 | BatchPrefixModal(add/remove) | 操作栏⋯→批量前缀 | POST /assets/batch-prefix |
| 批量移动 | BatchMoveAssetsModal | 操作栏「移动」 | POST /assets/batch-move |
| 批量下载 | 批量栏+download-store | 操作栏「下载」→逐文件入队 | POST download-link(逐个) |
| 删除(软删) | 批量栏/详情 | 操作栏「删除」(确认) | DELETE /assets/{id} |
| 文件夹回收站/恢复 | FolderTrashModal | 文件夹页 ⋯→回收站 | GET /assets/trash、POST restore |
| 分享创建(资产/文件夹) | ShareModal | 操作栏「分享」/预览页分享(有效期/提取码/下载开关→创建→复制公网链接) | POST /share/assets/{id}、/share/folders/{id} |
| 分享链接管理列表/撤销 | **web 无此功能**(share.py 仅 create+resolve,2026-10-20 核实) | **不做**;设计稿 09 的管理列表归 §17 差异清单 | — |
| 权限申请(审批发起) | RequestAccessModal(无下载权等触发) | 预览页/操作栏⋯→申请权限 | POST /approvals |
| 上传(全类型) | Uppy + PersistentUploadDrawer + 浮动指示 | 统一上传面板(§5)+ 传输中心 | POST uploads 三步 |
| 传输中心 | TaskCenterDrawer(上/下 segmented) | tab3 传输(§7) | — |
| 审批中心 | ApprovalsPage(待我审批/我发起的) | 我的→审批中心 | GET/POST /approvals、approve、reject |
| 通知 | NotificationsPage + Bell 未读轮询 30s | 我的→通知(红点轮询) | GET /notifications、POST mark-read |
| 我的权限 | MyPermissionsPage + 倒计时 | 我的→我的权限 | (同 grants 查询族) |
| 盲搜 | ⌘K + SearchPage + ?asset= 高亮 | tab2 搜索(§8.8) | GET /assets/search |
| 管理后台·用户 | AdminUsersPage(建带组/编辑/启停/重置/解锁) | 管理→用户 | /admin/directory/users 族 |
| 管理后台·组 | AdminGroupsPage(CRUD+成员) | 管理→组 | /admin/directory/groups 族 |
| 管理后台·审计 | AdminAuditPage + CSV 导出 | 管理→审计(筛选+CSV 落 Downloads) | GET /admin/audit、export.csv |
| 管理后台·权限模板 | AdminGrantTemplatesPage | 管理→权限模板 | /admin/grant-templates 族 |
| 管理后台·目录模板 | AdminFolderTemplatesPage(闸门 is_folder_template_manager) | 管理→目录模板 | /admin/folder-templates 族 |
| 管理后台·百度任务 | AdminBaiduTasksPage(全量+详情+文件) | 管理→备份任务 | /admin/baidu-backup/* |
| 百度备份·绑定 | BaiduBindModal(authorize→code→bind) | 我的→网盘备份→绑定(§8.12) | authorize-url、POST binding、DELETE |
| 百度备份·网盘浏览 | BaiduNewTaskModal 目录树 | 新建任务向导 | GET /baidu/backup/netdisk/folders |
| 百度备份·建任务 | BaiduNewTaskModal(项目/夹/模式) | 新建任务向导 | POST /baidu/backup/tasks |
| 百度备份·任务管理 | BaiduBackupDrawer/TaskDetail | 我的→网盘备份(取消/重试/删除) | tasks 族 + cancel/retry-failed |
| 请求链接创建 | RequestLinkCreateModal(项目列表页/项目工作区发起) | 项目页与项目内页菜单「请求链接」(创建即复制) | POST /request-links |
| 分享落地页/请求落地页 | /s/:token、/r/:token(公开) | **不在 App 内做**:创建后复制链接,url_launcher 系统浏览器打开(web 承载) | GET /share/{token} 等(仅 web 用) |
| 用户/组简表(选人) | users/groups 接口 | SubjectPicker/UserPicker 移动版 | GET /users、GET /groups |

**明确不做**(web 亦无,设计稿属前瞻):收藏、评论、离线缓存、通知设置、SSO/双重验证、
项目级分享设置、**分享链接管理列表/撤销**(share.py 仅 create+resolve,2026-10-20 核实)。
dev-login(X-User-Id)是 web 开发工具,App 用 `--dart-define` 指向本地栈代替。

## 2. 导航与信息架构

```
Login(未会话;维护横幅 + 底部小字诊断日志)
└─ HomeShell(IndexedStack 保状态;TabBar 四格 + home pill)
   ├─ tab1 项目 ProjectsPage ────┬─ push FoldersPage(projectId)
   │   (新建项目/回收站入口)      │    (⋯:新建夹/重命名/移动/删除/邀请/授权/回收站)
   │   └─ push 成员管理(项目)     └─ push AssetsPage(folderId)= 宫格 + 多选
   │                                     ├─ push PreviewPage(胶片条/元数据/操作)
   │                                     └─ 操作栏:分享/下载/移动/删除 + ⋯(打标/前缀/申请)
   ├─ tab2 搜索 SearchPage ── push PreviewPage(结果序列)
   ├─ tab3 传输 TransfersPage(上传/下载/badge)
   └─ tab4 我的 MePage
        ├─ 素材与权限:我的权限 / 审批中心(badge) / 回收站(项目)
        ├─ 网盘备份:绑定状态 / 任务列表 / 新建任务
        ├─ 通用:账号与安全(改密) / 诊断(日志推送) / 当前服务入口(只读)
        ├─ 管理(仅 admin 可见):用户 / 组 / 审计 / 权限模板 / 目录模板 / 备份任务
        └─ 退出登录
```

- 路由:命名路由 + `Navigator.push`(不引 go_router);HomeShell 用 IndexedStack。
- 管理后台入口闸门:`me.is_system_admin`(目录模板再叠 `is_folder_template_manager`);
  新建项目闸门 `is_project_creator`——与 web AppHeader 同口径。

## 3. 核心流程(上传/下载)——功能全量后依然是简单性验收线

- **上传两步**:宫格页「⬆」→ 半屏面板(从相册选择 / 选择文件)→ 选完入队,可继续浏览;
  宫格顶部迷你进度 + 传输 tab 可查。iOS 相册实况照片自动打包 livp,用户无感知。
- **下载一步**:预览页「下载」或操作栏多选「下载」→ 按类型自动落盘(相册/图库/Downloads/
  iOS 存到文件)→ toast 说明去处,传输 tab 可查可重试。
- 离开页面不中断;杀 App 即停(v1 不做后台续传,web 亦无)。

## 4. 后端地址自动探测(定稿口径,同 v1)

冷启动按序探测 `GET /healthz`(免鉴权,connectTimeout 3s),命中即用:

1. `--dart-define=MS_API_BASE=…`(仅开发构建,不进 UI)
2. `http://192.168.110.221`(内网正式环境,工作室 WiFi)
3. `https://bucket.taoxiplan.com`(公网 HTTPS 反代同一环境)

- 删除:登录页 dev/prod/custom 切换 UI、`ms_api_base` 手动持久化、`kDevEntry` 预设。
- 全失败 → 登录页「服务不可达 · 重试」横幅(重按重探)。
- 运行中不做自动热切换(防半途换 baseUrl 搞乱 cookie/上传),下次冷启动纠正。
- 保留:cookie 会话持久化(重启免登录);我的页只读显示当前入口(内网/公网);
  iOS ATS 放开 + Android cleartext(既有)。
- 注:内网入口是裸 IP,而 iOS `NSExceptionDomains` 与 Android networkSecurityConfig
  的例外机制**均不支持 IP 字面量**(Android 清单注释已实证),「收紧到单 host」不可行,
  只能全局放开——这是既定产品形态(ADR-0008 局域网部署、可完全离线)下的已知边界,
  不作为发布阻断项;公网入口恒为 HTTPS。

### 4.1 统一错误处理(全站口径)

| 情形 | 行为 |
| --- | --- |
| 401 | 单次触发:清会话、停轮询、跳登录(并发多请求只弹一次,去抖) |
| 403 / 422 | 后端 detail 透传(`_extractDetail` 兼容数组/对象形态,勿直接渲染原始对象) |
| 429 | 提示「操作过于频繁,请稍后再试」;**不自动重试**(尤其写操作,防止重复执行) |
| 超时 / 5xx / 断网 | GET 列表页显示可重试错误;**写操作不自动重放**,失败态留给用户手动重试 |
| presigned URL 过期 | 重签一次(缩略图/下载/播放链接),再失败按错误处理 |
| 上传 complete 响应丢失 | 任务标 failed 并提示「可能已上传,请先在素材列表核实」——后端
  `UploadUrlRequest` 无幂等键(2026-10-20 核实:仅 folder_id/filename/content_type/
  size_bytes),无法查询确认,**禁止自动重传**造成重复资产 |

## 5. 统一上传

- 入口唯一:宫格页 AppBar「⬆」+ 空态引导按钮 → 半屏面板:
  - **从相册选择**(wechat_assets_picker,RequestType.all 多选):iOS 实况照片 →
    `entityToLivp` 打包 `.livp`(现役逻辑);普通图/视频 → 原文件;Android 全部原文件。
  - **选择文件**(file_picker,any,多选):原文件直传(含 .livp 本身)。
- `uploadFile(path,…)` **流式分片**(16MB,RandomAccessFile 逐片读,三步编排+失败 abort 不变);
  `uploadBytes` 仅留 livp 小包。GB 级视频不 OOM。
- content_type 扩展名映射(`core/api/content_types.dart`);filename 净化沿用
  `LivpService.baseNameOf` 钉子(空标题兜底、`/` `\` 净化,勿回退)。
- 上传队列 UI 对标 web PersistentUploadDrawer + 浮动指示:宫格顶部迷你条 + 传输 tab 详情。
- `folder.my_can_upload == false` 时隐藏上传入口。

## 6. 下载与双端落盘

### 6.1 落盘矩阵

| 资产 | iOS | Android |
| --- | --- | --- |
| `.livp` | 解包 → 存相册恢复实况(现役);解包/存相册失败 → **原档兜底走 share「存储到文件」**,不让用户白下载 | **D1 双落盘**:①解包 → 静态图+视频分别存图库;②`.livp` 原档写 Downloads。两路分别记成功/失败,失败路单独重试;图库路失败不阻塞原档路(HEIC 兼容性风险的自然兜底) |
| 图片/视频 | `PhotoManager.editor` 存相册 | 同左(photo_manager 双端 API);失败兜底 media_store_plus 直写 |
| 其他文件 | share_plus 面板(「存储到文件」) | media_store_plus 写 Downloads |

- 重名策略:不覆盖,自动追加序号(media_store_plus/系统媒体库行为);重试已成功路不重复生成副本。
- 空间预检:下载前检查可用空间(原档 + 解包估算),不足则提示并中止,不半途写坏。

- 下载先落 app cache(进度回调),**落盘成功后删临时文件**;D1 双落盘共用一次下载。
- 批量下载逐文件入队(web download-store 同款,无 zip 打包)。
- toast 明说去处(「已存入相册」「已存入 Download/浣花视界」)。

### 6.2 Android 缺陷根因

MVP 写 `Directory.systemTemp`(应用私有 cache)→ 图库/Downloads 天然不可见。
修复=上表矩阵;权限:READ_MEDIA_IMAGES/VIDEO(13+)已有,MediaStore 写入免权限。

## 7. 传输中心(对标 web TaskCenterDrawer)

`TransferQueue` = app 级单例 `ChangeNotifier`(不引状态管理框架):

```dart
class TransferTask {
  String id; TransferKind kind;         // upload / download
  String filename; String where;        // 项目 / 文件夹 显示路径
  int doneBytes, totalBytes;
  TransferStatus status;                // queued/running/done/failed/canceled
  String? error; DateTime startedAt;
}
```

- 全局 FIFO 并发 2(上传下载混排);取消=CancelToken(上传尽力 abort 清悬挂分片);
  重试=重新入队从头来(web 同款,无断点续传);清已完成。
- **任务不持久化(明确决策)**:队列仅内存,杀 App/重启即清空——与 web 刷新页丢失
  Uppy 任务同语义;重启后上传重选即可、下载重点即可,成本低;后端 multipart 悬挂分片
  有既有清理兜底。若上传在 complete 前被杀,用户在资产列表核实是否已传完(§4.1)。
  不引入 TaskStore/schema 迁移/源文件引用矩阵(评审意见,不采纳理由见 §18)。
- 页面:全部/上传/下载分段 + 进行中(进度/百分比/取消)+ 已完成(重试/移除);
  TabBar 传输格 badge=running 数。速度/剩余时间不做(web 亦无)。

## 8. 各功能域实现要点

### 8.1 浏览(项目 → 文件夹 → 宫格)

- 项目行:名称 + code + 素材计数(无此字段则不显示)+ 权限徽标
  (`my_roles` 含 admin→可管理/green,含 uploader→可编辑/accent,非空→仅查看/neutral,
  `is_archived`→已归档/amber)+ 通知入口(右上,红点)。
- 文件夹行:`subtree_file_count` 徽标 + 敏感锁 + 「⋯」菜单(管理动作全收这里)。
- 宫格:3 列缩略图(`tags.thumbnail_key` 存在才请求 thumbnail-url,presigned 30min
  内存缓存+过期重签+同 URL 并发去重+LRU 上限约 80MB,失败降级类型色块);
  视频时长角标、livp 实况角标;点按=预览,长按=进入多选(设计稿 04)。
- 数据新鲜度:写操作(上传/删除/移动/打标/审批)成功后失效对应列表并刷新;从下级页
  返回时按需刷新,防 IndexedStack 挂着陈旧数据。

### 8.2 预览(对标 web AssetPreviewModal.detectKind)

| 类型 | 判定 | 呈现 |
| --- | --- | --- |
| image(png/jpg/gif/webp/svg/bmp/avif/ico) | 扩展名/content_type | 原图 presigned(download-link inline)或 **D4:缩略图** 大图 |
| heic/heif | 扩展名优先于 image/* | **缩略图**(1024px,D4) |
| livp | `.livp` | 静态图=缩略图;**实况短片=live-preview-url + video_player 播放**(web 同款) |
| video(mp4/mov/webm/m4v) | 扩展名 | download-link(inline)+ video_player |
| markdown / text | .md/.txt 或 content_type | flutter_markdown / 纯文本(download-link 拉取) |
| pdf | .pdf 或 application/pdf | dio 下载临时文件 → url_launcher 系统查看器 |
| unsupported | 其余 | 类型色块 + 「下载后打开」 |

- 结构:暗色画布(#141210)+ 顶部 ‹n/N› + 胶片条 + 底部元数据卡
  (文件名/大小/类型/时间/标签 chips + 备注);操作:下载/分享/申请权限。
  **下载权判定口径(与 web 同源)**:Asset 级无能力字段(AssetOut 已核实),用
  folder 级 `my_can_download`(进宫格页时已知)控制下载按钮;`false` 时下载禁用并
  给「申请权限」入口,点按仍以后端 403 为最终裁决。
- 详情打标:元数据卡「编辑」→ AssetTagEditor 移动版(user_labels ≤50 + notes,merge/replace 同 web)。

### 8.3 素材多选操作栏(D2 全量)

四键 + 溢出菜单,**全部对标 web 批量栏**:

- **分享**(ShareModal 移动版:有效期/提取码/下载开关→创建→复制链接+可选系统浏览器打开)
- **下载**(逐文件入队)
- **移动**(BatchMove 移动版:项目→文件夹两级选择器)
- **删除**(确认弹窗;403 透传 detail)
- ⋯ 菜单:**批量打标**(merge/replace)、**批量前缀**(add/remove)、**申请权限**
  (RequestAccess 移动版:查看/下载/编辑 + 用途说明 → POST /approvals)

### 8.4 文件夹管理

「⋯」菜单:新建子夹(名称+敏感开关)/ 重命名 / 移动(MoveFolder 同款选择器)/ 删除(确认;
有资产走软删语义由后端裁决)/ **敏感夹邀请**(邀请+撤销,FolderInvitePanel 移动版)/
**授权管理**(grants 列表+添加(选人+角色+有效期)+撤销+倒计时,FolderGrantsPanel 移动版)/
**回收站**(软删资产列表+恢复)。

### 8.5 项目管理

- 新建项目(NewProjectModal 移动版:名称/code/描述/可见性 + 权限模板 + 目录模板预填,
  闸门 is_project_creator);
- 成员管理(成员列表+添加(SubjectPicker 用户/组 + RoleChipGroup 角色)+移除+grants);
- 应用默认权限(ApplyDefault 确认);
- 已删除项目(列表+恢复,我的页→回收站)。

### 8.6 审批中心

- 分段:待我审批 / 我发起的;卡片=申请人+类型(申请查看/下载/编辑)+素材+用途;
  通过/拒绝双按钮(带确认);徽标=待我审批数。

### 8.7 通知 + 我的权限

- 通知:按时间倒序列表(未读橙点)+ 全部已读;**未读数 30s 轮询**(web 同款,
  `GET /notifications?limit=1` 取 `unread_count`,已核实列表接口自带)驱动
  我的 tab badge 与项目页铃铛红点。
- 轮询生命周期:**仅前台 + 已登录才轮询**;进后台/登出/401 即停;恢复前台立即刷一次
  再续周期(单一 PollingController,防多页面各起计时器、防重叠请求)。
- 通知点击跳转:payload 类型走白名单映射(审批/素材/项目),未知类型显示通用详情
  不崩溃、不把任意 URL 交给导航器。
- 我的权限:我在各项目/夹的 grants 列表 + 角色 + 过期倒计时。

### 8.8 搜索

- tab2:聚焦搜索框 + 结果列表(缩略图+文件名高亮+归属 项目/folder + 类型徽标);
  **防抖 ~300ms + 取消过期请求**(防旧查询结果覆盖新输入);点击 → push 预览
  (结果序列做胶片条);⌘K 命中数 50 截断的提示同 web 已知口径。

### 8.9 管理后台(移动版,仅 admin 可见)

设计稿 12 为「概览+入口」;**对标 web = 每个子功能做成完整移动列表页**:

- **用户**:列表(搜索/分页)+ 建用户(带组)+ 编辑 + 启用/停用 + 重置密码(回显一次性密码,
  可复制)+ 解锁;
- **组**:列表 + 建/编 + 成员管理(加/移);
- **审计**:筛选(事件类型/对象/主体/时间)+ 分页列表 + **CSV 导出**
  (dio 带会话下载 → Android 存 Downloads / iOS share 面板;不能用 url_launcher——
  系统浏览器不带 cookie 必 401);
- **权限模板**:列表 + 建模板(主体行×独立角色,50 条上限)+ 编辑 + 删除 + 应用默认;
- **目录模板**:列表 + 建(条目路径校验)+ 编辑 + 删除(闸门 is_folder_template_manager);
- **百度任务(管理)**:全量任务列表(状态筛选)+ 详情 + 文件明细分页。

### 8.10 百度备份·用户侧

入口:我的→网盘备份。**绑定对接缺口(G1)**:web 流程 authorize-url → 百度授权 →
回调 redirect 到 web 域拿 code。App 方案(零后端改动):**webview_flutter 内嵌授权页,
拦截回调提取 code** → POST binding。拦截按**回调 host+path 完整匹配**(不宽前缀);
授权取消/无 code/错误回调均有兜底 UI;失败给手动粘贴 code 输入框(一次性使用,
提示勿外传,提交后即清输入态)。绑定后:网盘目录树懒加载 → 新建任务向导
(选项目/文件夹 + 承接夹 + 覆盖/跳过语义按现有契约)→ 任务列表(状态/进度)+
取消/重试失败/删除。频控与 key 冲突语义透传后端文案(处置手册已有)。

### 8.11 请求链接

项目页与项目内页菜单「请求链接」(对标 RequestLinkCreateModal 的 web 发起位):创建后复制链接;
落地页 web 承载。

### 8.12 维护横幅

GET /maintenance/banner:登录页与首页顶部展示 active 横幅(对标 MaintenanceBanner),
可关闭,会话内不再弹。

## 9. 代码架构与组件化

**硬约定:单文件 ≤200 行目标、300 硬顶;超限必须拆。** 全功能量下目录纪律是可维护性底线:

```
lib/
  main.dart / app.dart / theme/tokens.dart + theme/app_theme.dart
  core/
    session.dart                    # 探活+baseUrl+cookie+Me 缓存+未读轮询
    api/                            # 按域拆客户端模块,全部薄封装:
      ms_api.dart(核心:Dio/日志/错误提取)
      auth_api.dart projects_api.dart folders_api.dart assets_api.dart
      approvals_api.dart notifications_api.dart share_api.dart
      admin_api.dart(directory/audit/templates) baidu_api.dart
      content_types.dart
    transfers/transfer_task.dart + transfer_queue.dart
    fmt.dart
  models/                           # 每域一文件:me/project/folder/asset/
                                    # search/approval/notification/share/
                                    # grant_template/folder_template/user/group/
                                    # audit_event/baidu_*
  services/                         # album/livp/app_log/wecom_push(平移)
    media_save.dart                 # §6 落盘策略路由(纯函数矩阵,可单测)
    downloads.dart                  # media_store_plus 封装
    clipboard_link.dart             # 复制链接+toast
  widgets/                          # badge/empty_state/error_view/类型色块/
                                    # avatar/倒计时/迷你进度/确认弹窗/分段控件
  features/
    auth/ login_page.dart change_password_page.dart
    shell/ home_shell.dart tab_bar.dart
    projects/ projects_page.dart project_row.dart new_project_sheet.dart
              project_members_sheet.dart grant_rows.dart deleted_projects_page.dart
    folders/ folders_page.dart folder_row.dart folder_menu.dart folder_form_sheet.dart
              move_folder_sheet.dart folder_trash_page.dart folder_grants_sheet.dart
    assets/ assets_page.dart asset_grid.dart asset_tile.dart upload_sheet.dart
            batch_action_bar.dart batch_tag_sheet.dart batch_prefix_sheet.dart
            batch_move_sheet.dart
    preview/ preview_page.dart filmstrip.dart meta_panel.dart tag_editor_sheet.dart
    search/ search_page.dart result_row.dart
    transfers/ transfers_page.dart transfer_card.dart
    approvals/ approvals_page.dart approval_card.dart
    notifications/ notifications_page.dart notification_row.dart
    permissions/ my_permissions_page.dart grant_row.dart
    share/ share_create_sheet.dart share_manage_page.dart request_link_sheet.dart
    baidu/ baidu_page.dart bind_webview_page.dart netdisk_tree_sheet.dart
           new_task_sheet.dart task_detail_page.dart
    admin/ admin_home.dart users_page.dart user_form_sheet.dart groups_page.dart
            group_members_sheet.dart audit_page.dart grant_templates_page.dart
            folder_templates_page.dart baidu_admin_tasks_page.dart
    me/ me_page.dart log_push_dialog.dart service_info_tile.dart
```

- 状态:setState + FutureBuilder(列表)+ ChangeNotifier(TransferQueue/Session/未读数)。
  **不引 riverpod/bloc/go_router**。
- 选人/组组件(SubjectPicker/UserPicker 移动版)单独 `widgets/pickers/`,三处复用
  (项目成员/夹授权/管理后台建用户)。
- 移动表单模式统一:底部半屏 sheet(bottom sheet)+ 数据驱动初始值
  (记忆钉子:勿 setFieldsValue 类回填坑,Flutter 无此雷但保持数据驱动习惯)。

## 10. 视觉与主题令牌(同 v1,对齐 app.css)

bg #FAFAF7 / surface #FFF / surface2 #F5F4EF / fill #F0EEE9 / fg #1A1A1A /
muted #6B6B68 / subtle #9A9A95 / border #E8E6E1 / accent #C2410C(+strong #9A3412、
soft #FEE4D0、faint #FEF3E8)/ green #047857 / amber #B45309 / red #9F1239 /
dark #141210(预览画布)。`ColorScheme.fromSeed(#C2410C)` 起步再精调;卡片圆角 20;
徽标 pill 四色(accent/green/neutral/amber);系统字体 + tabularFigures 数字。
共享组件:Badge/EmptyState/ErrorView/类型色块/Avatar(首字渐变)/倒计时 chip。

## 11. 数据契约与模型扩展(全部已有端点,零后端改动)

v1 方案列过的端点族继续有效,新增对接:

| 域 | 端点族 | 模型要点 |
| --- | --- | --- |
| Me | /auth/me | 补 is_system_admin / is_folder_template_manager / is_project_creator / is_project_deleter |
| Project | /projects 族 | 补 my_roles / is_archived / visibility / admins;deleted+restore |
| Folder | /folders 族 | 补 subtree_file_count;create/patch/move/delete/invite/grants |
| Asset | /assets 族 | 补 tags.thumbnail_key / user_labels / notes;trash/restore/meta/batch-prefix/batch-move |
| Share | /share 族 | ShareCreateOut(expires_at/download_url/…) |
| Approvals | /approvals 族 | scope/status 筛选、approve/reject |
| Notifications | /notifications 族 | 列表 + mark-read;unread 计数接口同 web 口径 |
| Admin | /admin/directory 族 + audit(+export.csv)+ 两模板族 + baidu-backup | 分页模型 |
| Baidu | /baidu/backup 族 | binding/authorize-url/netdisk folders/tasks(+cancel/retry/删除) |
| Request links | POST /request-links | 创建即复制 |

已知契约钉子(实施时遵守):422 detail 数组型要兼容(errorMessage 同 web 哲学,MVP
`_extractDetail` 已处理);DELETE 返 204;分片 PUT 必带 Content-Length(prod 411);
presigned thumbnail 30min 过期重签;`list_objects` 截断为后端已知项(搜索可达域口径同 web)。

## 12. 依赖变更

| 包 | 动作 | 用途 |
| --- | --- | --- |
| media_store_plus | 新增 | Android Downloads 落盘(D1②/审计 CSV/通用文件) |
| share_plus | 新增 | iOS 存文件面板 + 分享链接/一次性密码复制辅助 |
| url_launcher | 新增 | pdf 系统查看器、分享/请求链接开系统浏览器 |
| webview_flutter | 新增 | 百度授权回调拦截(§8.10 G1) |
| video_player | 新增 | 视频 + livp 实况短片播放(live-preview-url) |
| flutter_markdown | 新增 | .md 预览(对标 web ReactMarkdown) |
| dio/photo_manager/wechat_assets_picker/file_picker/archive/… | 保留 | 现役 |
| 状态管理/路由框架 | **不引入** | — |

版本在首个使用批次 `pub add` 锁定并记 pubspec 注释;升级须单独批次。

## 13. 权限与安全边界

- 可见性一律后端裁决(App 不自判);上传入口 `my_can_upload`;管理入口 `me.*` 旗标。
- 删除/移动/授权等写操作:不做客户端预判,403/422 透传 detail(web 同哲学)。
- sensitive folder:锁图标;邀请/授权走专用面板(后端裁决)。
- 审计 CSV:必须走带会话的 dio 下载(§8.9),禁 url_launcher 直开。
- 日志(AppLog)只记 host+path 不记凭据;企业微信推送密钥维持现役管理方式。
  脱敏红线(扩展日志时维持):Cookie、Authorization、百度授权 code/state、分享提取码、
  管理后台一次性重置密码、完整 presigned URL 一律不入日志。
- 日志推送收拢:我的页「诊断」入口 + 登录页底部小字(登录失败兜底出口)。

## 14. 测试与验收

**单测(PC)**:现役用例全保留 + 新增:探活顺序与超时降级、TransferQueue 状态机、
content_type 映射、**落盘矩阵(平台×类型,D1 双落盘)**、分片切块边界、
`detectKind` 移动版类型判定、徽标映射(my_roles→徽标)、批量前缀入参校验。

**隔离栈联调(api/docker-compose.feat-ms.yml + seed_demo_data)**:全功能域逐条过
矩阵 §1(每行至少一条 happy path + 一条 403 边界);`flutter analyze` + `flutter test` 全绿。

**真机双端验收(关键场景)**:

| 场景 | iPhone(TestFlight) | Android(release APK) |
| --- | --- | --- |
| 探活 | WiFi→内网 / 蜂窝→公网(我的页确认) | 同左 |
| 上传 | 实况→livp/普通图视频/文件/GB 级大文件 | 相册/文件/SAF 深层目录 |
| 下载落点 | 相册(实况/图/视频)、文件 app | **图库+Downloads 双可见(D1)** |
| 预览 | 图/heic/视频/livp 播放/md/pdf | 同左(HEIC 兼容性) |
| 管理后台 | 建用户带组/审计 CSV 落 Downloads | 同左 |
| 百度绑定 | webview 授权回调拿 code | 同左 |
| 权限拒绝流 | 相册拒绝→引导设置 | 13+ 细分媒体权限 |

构建链照 `ios-livp-app-build-handbook.md`(Windows 安卓:JAVA_HOME+镜像变量;
iOS:Mac+TestFlight;APP_BUILD_TIME 注入、release APK PIL 核验流程不变)。

## 15. 风险与对策

| # | 风险 | 对策 |
| --- | --- | --- |
| R1 | photo_manager Android 保存行为差异(厂商 ROM) | 首批真机验证;兜底 media_store_plus 直写;失败 toast 明示 |
| R2 | D1 解包 HEIC 在部分安卓图库不识别 | ②路 .livp 原档始终落 Downloads(双保险);失败不阻塞任务完成态 |
| R3 | 大文件上传 OOM | uploadFile 流式分片;PUT 带 Content-Length(prod 411 钉子) |
| R4 | 探活误判(WiFi 通但隔离) | 「重试探测」入口;运行中不热切换(§4) |
| R5 | webview 拦截百度回调被百度改版 | 拦截按「回调 URL 前缀」宽匹配;失败给手动粘贴 code 输入框兜底 |
| R6 | 缩略图 presigned 30min 过期裂图 | URL+过期时间缓存,过期重签;失败降级类型色块 |
| R7 | 管理后台表单在移动端体验降级(审计筛选等重表单) | 列表+筛选简化为分段/chip;CSV 导出走 dio;接受「可用不追求等效 PC 效率」 |
| R8 | 全功能量导致包体积/页面数膨胀 | 组件纪律(§9)+ 按域分文件;video_player 等重依赖按需懒加载页 |
| R9 | 杀 App 传输中断无续传 | 与 web 行为对齐(同样无续传);重试=从头;文档化预期 |
| R10 | 422 数组 detail 白屏类雷 | 统一 errorMessage 兼容(web 踩过 #31 白屏,App 侧 `_extractDetail` 已兜) |

## 16. 实施批次(工程顺序,非功能分期——全部交付)

每批:独立分支(基于 liuqi)→ 自测绿 → commit → `scripts/changelog.md` 记账 →
隔离栈联调。批次间可独立验收发布。

| 批 | 内容 | 交付判据 |
| --- | --- | --- |
| **B0 技术验证(轻量,~1 天)** | 三项 PoC,结论直接记入 changelog/本方案附录,不设签字仪式:①百度授权 webview 双端真机闭环(含取消/失败/手动 code 兜底);②Android 落盘 PoC(photo_manager 图库保存行为 + media_store_plus Downloads);③契约核对收尾(分享无列表/撤销、未读数、`my_can_upload`/`my_can_download` 判定——2026-10-20 已核完,见 §1/§4.1/§8.2) | 三项有结论;不可行项触发方案修订(如百度授权换降级路线) |
| B1 基建 | 目录重构(§9)+ 主题令牌 + Session 探活 + 登录简化 + HomeShell 四 tab + 我的页骨架(日志收拢/服务指示/退出) | 探活双端真机过;旧功能不回归 |
| B2 浏览线 | 项目/文件夹列表(徽标/计数/敏感锁)+ 宫格(缩略图缓存)+ 预览全类型(§8.2 含视频/livp 播放) | 双端浏览流畅;预览类型全覆盖 |
| B3 上传+传输 | 统一上传面板 + uploadFile 流式 + TransferQueue + 传输页 | GB 级上传不 OOM;取消/重试可用 |
| B4 下载线 | 落盘矩阵(D1 双落盘)+ 批量下载 + toast 去处 | **Android 图库+Downloads 双可见验收过** |
| B5 素材操作线 | 操作栏全量(分享/移动/删除/打标/前缀/申请)+ 回收站 + 详情打标 | 批量操作全对标 web;403 边界文案正确 |
| B6 文件夹+项目管理 | 夹 CRUD/移动/邀请/授权/回收站;新建项目/成员/应用默认/已删除项目 | 管理动作全量;权限闸门正确 |
| B7 协作线 | 审批中心 + 通知(轮询 badge)+ 我的权限 + 搜索 tab | 三域 happy path + 未读轮询真机过 |
| B8 管理后台 | 用户/组/审计(CSV)/权限模板/目录模板/百度任务管理 | admin 真机全流程;非 admin 不可见 |
| B9 百度用户侧+收尾 | 绑定(webview)/网盘浏览/建任务/任务管理 + 请求链接 + 维护横幅 + 错误边界 + 全量测试补齐 | 绑定回调真机过;§1 矩阵逐行勾检 |

## 17. 与设计稿的差异清单(对标源=web,非设计稿)

| 设计稿元素 | 处理 |
| --- | --- |
| 预览页「收藏 / 评论」 | 不做(web 无此功能) |
| 我的页「离线缓存」 | 不做(web 无) |
| 我的页「通知设置」「SSO/双重验证」 | 不做;账号与安全=修改密码(web 同) |
| 项目页右上「项目分享设置」(03 屏) | 不做项目级分享(web 分享为资产/文件夹级) |
| 传输页「速度/剩余时间」 | 不做(web 亦无) |
| 首页项目封面大图 | 降级为 code/徽标行(后端无项目封面字段);行布局保设计语言 |
| 「我的分享」管理列表/撤销(09 屏) | 不做(web 无分享列表/撤销接口,2026-10-20 核实 share.py 仅 create+resolve);App 只做分享创建 |
| tab2/传输/我的构成、配色、宫格、胶片条、操作栏四键、审批卡、管理入口分组 | 照设计稿实现 |

## 18. 外审意见处理记录(2026-10-20,v2.1)

输入:`scripts/task/mobile-app-full-version-plan-ds.md`(v2.5)与
`mobile-app-full-version-plan-gpt.md`(v3.4)。两份在功能范围上与 v2 一致,主要差异是
流程治理深度。逐条处理后如下。

### 18.1 已采纳(并入正文)

| # | 意见 | 落点 |
| --- | --- | --- |
| 1 | 分享管理/请求链接管理范围须对照 web 核实 | §1/§2/§17:web 无分享列表/撤销(share.py 仅 create+resolve),入口已裁掉;请求链接=仅创建,入口移到项目页/项目内(web 同位) |
| 2 | 上传 complete 响应丢失的语义须明确 | §4.1:后端 `UploadUrlRequest` 无幂等键(已核实),标 failed + 提示列表核实,禁自动重传 |
| 3 | 统一错误处理(401/403/422/429/超时/5xx/URL 过期) | §4.1 新增小节(压缩版,不建按操作类型的全量矩阵) |
| 4 | Asset 能力字段不能凭空假定 | §8.2:已核实 AssetOut 无 can_*,下载权=folder 级 `my_can_download` + 403 兜底(web 同源) |
| 5 | 通知未读数接口须核实 | §8.7:`GET /notifications?limit=1` 自带 `unread_count`(已核实),30s 轮询 |
| 6 | 轮询生命周期(前台/登录态/防重叠) | §8.7 |
| 7 | 通知 payload 白名单跳转、未知类型不崩溃 | §8.7 |
| 8 | 搜索防抖 + 取消过期请求 | §8.8 |
| 9 | IndexedStack 陈旧数据、写后刷新失效 | §8.1 |
| 10 | iOS livp 解包/存相册失败要有原档兜底 | §6.1 |
| 11 | 落盘重名不覆盖、失败路单独重试、空间预检 | §6.1 |
| 12 | 缩略图 LRU 上限 + 并发去重 | §8.1 |
| 13 | 百度回调完整匹配非宽前缀;code 不入日志;手动 code 仅一次性 | §8.10 + §13 |
| 14 | B0 前置技术验证 | §16 新增轻量 B0(~1 天三项 PoC,结论记 changelog,不设三态签字/责任人体系) |

### 18.2 不采纳(及理由)

| # | 意见 | 不采纳理由 |
| --- | --- | --- |
| 1 | B0 三态结论(已关闭/有条件接受/阻断)、书面批准、责任人指派、12 份治理交付物 | 单人开发 + 用户验收的团队规模不支撑该流程;真实风险点(百度授权/Android 落盘/契约)已由轻量 B0 覆盖,治理仪式不产生对应收益 |
| 2 | TaskStore 任务持久化(schemaVersion 迁移/逐步骤 stepResults/上传源引用矩阵/24h TTL 清理) | web 同行为=刷新即丢(Uppy 内存态);杀 App 后重传/重点的成本远低于持久化体系的实现与维护成本;悬挂分片有后端清理兜底(§7 已写明决策) |
| 3 | Cookie 加密存储(Keychain/Keystore)+ 账号↔origin 双维度映射 + 双账号测试 | 单账号单设备的内部工具现实;cookie 文件本就在 app 沙盒私有目录,与浏览器同等级保护;双账号是虚构需求 |
| 4 | 内网 HTTP 列为发布安全阻断项(硬性准入/VPN/书面风险接受) | 与 ADR-0008「生产改局域网部署、可完全离线运行」的产品决策直接冲突;且 ATS/networkSecurityConfig 均不支持 IP 字面量例外(§4 注),「限制明文范围」技术不可行;保持全局放开 + 公网 HTTPS 兜底现状 |
| 5 | 资源预留器(原子预留/磁盘减少策略/SAF 孤儿扫描) | 过度工程;以「下载前空间预检 + 失败可重试」覆盖真实风险 |
| 6 | livp 解压炸弹全套防御(边解压边计量/耗时上限) | livp 由自家 iOS 端从相册打包,来源可信;保留条目数/总大小简单上限即可 |
| 7 | 性能量化门槛(p95 帧耗时/内存峰值 ≤250MB 等)+ CI 门禁 + golden 测试 + 无障碍验收 | 仓库无 App CI 基建;内部分发工具的真机走查 + profiler 抽查已满足质量要求;引入指标体系成本大于收益 |
| 8 | Feature flag/构建 flavor 体系(隐藏未完成入口) | TestFlight/内测 APK 本身就是中间验收渠道(既有工作流);批次完成才合入正式发布 |
| 9 | 版本兼容窗口/最低支持版本/强制升级/灰度回滚/商店材料 | 内网 App,发新版即全员更新;无商店公开分发 |
| 10 | 上传幂等「强幂等模式」契约 | 后端无 idempotency_key 字段(已核实),无契约基础;用「提示核实+禁自动重传」口径(§4.1) |
| 11 | 传输调度双向公平(上传/下载各保底名额) | 全局 FIFO 并发 2 已满足此规模;公平调度器是伪需求 |
| 12 | 429 指数退避自动重试(限幂等请求) | 直接不自动重试(§4.1)更简单且更安全,用户手动重试的成本可忽略 |

### 18.3 两份外审中的事实性错误(勘误)

- 两份均给上传三步加了「+idempotency_key」字段:`UploadUrlRequest` 实际仅
  folder_id/filename/content_type/size_bytes,无幂等键。
- DS 版 F-31「未读数接口 B0 三态」:未读数就是列表接口自带字段,非独立接口,无缺口。
- 两份把内网 HTTP 当新发现的安全例外:这是 ADR-0008 既定产品形态,MVP 起即如此。
