# 浣花视界 App 完整版实施方案(v2.2 · 全功能对标 web 版)

> 状态:**待评审**(2026-10-20 v2.2:qplan 审查修正;v2.1 并入两份外审意见的采纳项,处理记录见 §18)。
> v2.2 修订要点:**百度绑定按后端实况改为 oob 复制码流程(原「webview 拦截回调」前提
> 不成立,§8.10)**;新建项目表单补齐必填字段与艺人账号开通(§8.5);应用默认权限入口
> 移到管理后台(§8.5/§8.9);我的权限数据源改按 web 口径(§8.7);分享表单对齐
> ShareCreateIn 实况(§8.3);审批动作按后端枚举修正+审批 scope 口径写明(§8.3/§8.6);
> 维护横幅对齐 web 不可关 modal 实况(§8.12);pdf 预览改走 share_plus(§8.2);
> **my_can_* 仅单夹详情端点回填的契约补入宫格页数据源(§1/§5/§8.2/§11)**;
> 批量移动按后端一期约束改项目内一级选择(§8.3)。
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
4. **后端基本零改动**:全部走既有端点;唯一需要 App 侧适配的对接点=百度授权绑定
   (oob 复制码流程的移动端交互,§8.10 G1)。

## 1. 对标功能矩阵(web → App)

对标源以 web 路由 + 组件盘点为准确(2026-10-20 代码核实)。**左列每行都必须有 App 落点。**

| 功能域 | web 入口/组件 | App 落点 | 端点(全部已有) |
| --- | --- | --- | --- |
| 登录 | LoginPage | 登录页(§4 探活,无环境选择) | POST /auth/local/login |
| 会话恢复/登出 | UserMenu | 我的页 + 自动恢复 | GET /auth/me、POST /auth/logout |
| 修改密码(含强制流) | ChangePasswordPage | 我的页→账号与安全 | POST /auth/change-password |
| 维护公告 | MaintenanceBanner(8s 轮询,active 弹**不可关** modal) | 全局维护弹层(§8.12,登录页/主界面均挂) | GET /maintenance/banner |
| 项目列表 | ProjectsPage(首页) | tab1 项目(权限徽标) | GET /projects |
| 新建项目 | NewProjectModal | 项目页 + 菜单(闸门 is_project_creator) | POST /projects |
| 已删除项目/恢复 | DeletedProjectsModal | 我的页→回收站(项目) | GET /projects/deleted、POST restore |
| 项目成员管理 | ProjectMembersDrawer + SubjectPicker/RoleChipGroup | 项目页→成员(抽屉) | GET/POST/DELETE /projects/{id}/members、GET/DELETE grants |
| 刷新默认权限 | ApplyDefaultModal(管理后台·权限模板页挂载,多项目批量) | 管理→权限模板→应用默认(§8.9;系统 admin 专用,项目成员页不设) | POST /admin/grant-templates/apply-default |
| 文件夹浏览 | ProjectDetailPage + FolderTree | 项目→文件夹列表(subtree 徽标/敏感锁) | GET /folders?project_id= |
| 新建/重命名/移动/删除文件夹 | New/Rename/MoveFolderModal | 文件夹页 ⋯ 菜单 | POST/PATCH/DELETE /folders、PATCH move |
| 敏感夹邀请/撤销 | FolderInvitePanel | 文件夹页→授权(敏感夹) | POST/DELETE /folders/{id}/invite |
| 文件夹授权 | FolderGrantsPanel(仅普通一级夹;添加=选人/组+多 level,**无有效期/倒计时**——HTTP 授夹授权恒永久) | 文件夹页→授权(入口仅普通一级夹,同 web) | GET/POST/DELETE /folders/{id}/grants |
| 素材宫格+缩略图 | ProjectDetailPage 宫格 + AssetThumbnail(FolderDetailPage 是盲搜落点,无批量栏) | 文件夹→宫格(**进宫格时拉 `GET /folders/{id}` 单夹详情——my_can_* 仅此端点回填,列表响应恒 False,web useFolder 同源**) | GET /folders/{id}、GET /assets、GET thumbnail-url |
| 素材预览(全类型) | AssetPreviewModal + ‹n/N› | 预览页(胶片条,§8.2) | thumbnail-url、live-preview-url、download-link |
| 详情/打标/备注 | AssetSummaryPanel + AssetTagEditor | 预览页元数据卡(§8.2) | PATCH /assets/{id}/meta |
| 批量打标 | ProjectDetailPage 内联批量打标弹窗(逐 id PATCH,硬编码 merge;web 无独立 BulkTagModal 文件) | 操作栏⋯→批量打标(App 增强为可选 merge/replace) | PATCH /assets/{id}/meta(逐条) |
| 批量前缀 | BatchPrefixModal(add/remove) | 操作栏⋯→批量前缀 | POST /assets/batch-prefix |
| 批量移动 | BatchMoveAssetsModal | 操作栏「移动」 | POST /assets/batch-move |
| 批量下载 | 桌面批量栏「下载 n」+ download-store 逐文件 presigned(**web 桌面端有**;仅 compact 移动底栏不放——浏览器拦截连续多下载,下载走单卡行内按钮) | 操作栏「下载」→逐文件入队(与桌面 web 同款;>20 确认同 web) | POST download-link(逐个) |
| 删除(软删) | 批量栏/详情 | 操作栏「删除」(确认) | DELETE /assets/{id} |
| 文件夹回收站/恢复 | FolderTrashModal | 文件夹页 ⋯→回收站 | GET /assets/trash、POST restore |
| 分享创建(资产/文件夹) | ShareModal(有效期四档;requires_login 恒 true) | 操作栏「分享」(仅单选)/预览页分享(有效期→创建→复制公网链接;字段对齐 ShareCreateIn,无提取码/下载开关) | POST /share/assets/{id}、/share/folders/{id} |
| 分享链接管理列表/撤销 | **web 无此功能**(share.py 仅 create+resolve,2026-10-20 核实) | **不做**;设计稿 09 的管理列表归 §17 差异清单 | — |
| 权限申请(审批发起) | RequestAccessModal(无下载权等触发) | 预览页/操作栏⋯→申请权限(**仅单选**) | POST /approvals |
| 上传(全类型) | Uppy + PersistentUploadDrawer + 浮动指示 | 统一上传面板(§5)+ 传输中心 | POST uploads 三步 |
| 传输中心 | TaskCenterDrawer(上/下 segmented) | tab3 传输(§7) | — |
| 审批中心 | ApprovalsPage(待我审批/我发起的) | 我的→审批中心 | GET/POST /approvals、approve、reject |
| 通知 | NotificationsPage + Bell 未读轮询 30s | 我的→通知(红点轮询) | GET /notifications、POST mark-read |
| 我的权限 | MyPermissionsPage + 倒计时 | 我的→我的权限 | GET /projects(my_roles)+ GET /approvals?scope=self&status=approved(web 同数据源) |
| 盲搜 | ⌘K + SearchPage + ?asset= 高亮 | tab2 搜索(§8.8) | GET /assets/search |
| 管理后台·用户 | AdminUsersPage(建带组/编辑/启停/重置/解锁) | 管理→用户 | /admin/directory/users 族 |
| 管理后台·组 | AdminGroupsPage(CRUD+成员) | 管理→组 | /admin/directory/groups 族 |
| 管理后台·审计 | AdminAuditPage + CSV 导出 | 管理→审计(筛选+CSV 落 Downloads) | GET /admin/audit、export.csv |
| 管理后台·权限模板 | AdminGrantTemplatesPage | 管理→权限模板 | /admin/grant-templates 族 |
| 管理后台·目录模板 | AdminFolderTemplatesPage(闸门 is_folder_template_manager) | 管理→目录模板 | /admin/folder-templates 族 |
| 管理后台·百度任务 | AdminBaiduTasksPage(全量+详情+文件) | 管理→备份任务 | /admin/baidu-backup/* |
| 百度备份·绑定 | BaiduBindModal(oob 复制码:authorize-url→浏览器授权→复制授权码回填) | 我的→网盘备份→绑定(§8.10) | authorize-url、POST binding、DELETE |
| 百度备份·网盘浏览 | BaiduNewTaskModal 目录树 | 新建任务向导 | GET /baidu/backup/netdisk/folders |
| 百度备份·建任务 | BaiduNewTaskModal(项目/夹/模式) | 新建任务向导 | POST /baidu/backup/tasks |
| 百度备份·任务管理 | BaiduBackupDrawer/TaskDetail(任务级取消/重试/删除 + **文件级行操作:重试/覆盖导入/随机后缀导入**,key_conflict 行分流) | 我的→网盘备份(任务管理 + 任务详情文件级处置) | tasks 族 + cancel/retry-failed + files/{fid}/retry、overwrite、random-suffix |
| 请求链接创建 | RequestLinkCreateModal(项目列表页/项目工作区发起) | 项目页与项目内页菜单「请求链接」(创建即复制) | POST /request-links |
| 分享落地页/请求落地页 | /s/:token、/r/:token(**需登录态**——resolve 均挂鉴权,未登录跳 web 登录页) | **不在 App 内做**:创建后复制链接,url_launcher 系统浏览器打开(web 承载) | GET /share/{token} 等(仅 web 用) |
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
        ├─ 素材与权限:我的权限 / 审批中心(badge) / 回收站(项目,仅 is_project_deleter 可见)
        ├─ 网盘备份:绑定状态 / 任务列表 / 新建任务
        ├─ 通用:账号与安全(改密) / 诊断(日志推送) / 当前服务入口(只读)
        ├─ 管理(仅 system admin 可见):用户 / 组 / 审计 / 权限模板 / 备份任务;
        │   目录模板单独放行(folder_template_manager 旗标,见下)
        └─ 退出登录
```

- 路由:命名路由 + `Navigator.push`(不引 go_router);HomeShell 用 IndexedStack。
- 强制改密流:登录成功且 `/auth/me` 返回 `must_change_password=true` → 只放行
  改密页(web App.tsx 路由守卫同款),改完才进 HomeShell。
- 管理后台入口闸门:`me.is_system_admin`;**目录模板为独立闸门
  `is_folder_template_manager ?? is_system_admin`**(org admin/持组 flag 的非 system
  admin 亦可见可管,后端写端点守门同口径,web AppHeader 同款)——即「管理」分组
  整体仅 system admin,但目录模板入口对目录模板管理员单开;
  新建项目闸门 `is_project_creator`——与 web AppHeader 同口径。

## 3. 核心流程(上传/下载)——功能全量后依然是简单性验收线

- **上传两步**:宫格页「⬆」→ 半屏面板(从相册选择 / 选择文件)→ 选完入队,可继续浏览;
  宫格顶部迷你进度 + 传输 tab 可查。iOS 相册实况照片自动打包 livp,用户无感知。
- **下载一步**:预览页「下载」或操作栏多选「下载」→ 按类型自动落盘(相册/图库/Downloads/
  iOS 存到文件)→ toast 说明去处,传输 tab 可查可重试。
- 离开页面不中断;杀 App 即停(v1 不做后台续传,web 亦无)。

## 4. 后端地址自动探测(定稿口径,同 v1)

冷启动按序探测 `GET /api/v1/maintenance/banner`(公开免鉴权,connectTimeout 3s),
命中(HTTP 200)即用:

1. `--dart-define=MS_API_BASE=…`(仅开发构建,不进 UI)
2. `http://192.168.110.221`(内网正式环境,工作室 WiFi)
3. `https://bucket.taoxiplan.com`(公网 HTTPS 反代同一环境)

> 注(v2.2 后实测修正,2026-10-20 真机验收发现):原定探活端点 `/healthz` 被跳板机
> nginx 反代 **403 拦截**(仅隔离栈直连容器时可用,真实入口链路从不放行),导致公网/
> 内网候选全灭、登录页恒「服务不可达」。探活端点换用 web MaintenanceBanner 每 8s
> 在轮询的公开免鉴权端点 `/api/v1/maintenance/banner`(无 banner 时也返回 200 空数据),
> 反代链路必然放行;命中判定保持「HTTP 200」语义,候选返回 4xx/5xx 一律视为失败继续下一个。

- 删除:登录页 dev/prod/custom 切换 UI、`ms_api_base` 手动持久化、`kDevEntry` 预设。
- 全失败 → 登录页「服务不可达 · 重试」横幅(重按重探)。
- 运行中不做自动热切换(防半途换 baseUrl 搞乱 cookie/上传),下次冷启动纠正。
- 保留:cookie 会话持久化(重启免登录);我的页只读显示当前入口(内网/公网);
  iOS ATS 放开 + Android cleartext(既有)。
- 注:内网入口是裸 IP,而 iOS `NSExceptionDomains` 与 Android networkSecurityConfig
  的例外机制**均不支持 IP 字面量**(Android 清单注释已实证),「收紧到单 host」不可行,
  只能全局放开——这是既定产品形态(ADR-0007 局域网部署、可完全离线)下的已知边界,
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
- `folder.my_can_upload == false` 时隐藏上传入口(**取值须来自单夹详情
  `GET /folders/{id}`,勿消费列表响应的 my_can_*(恒默认 False);宫格页进入/
  切夹时拉取,web useFolder 同源**)。

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
修复=上表矩阵;权限:READ_MEDIA_IMAGES/VIDEO(13+)已有,MediaStore 写入免权限
(**仅 API 29+**;minSdk 跟随 Flutter 默认,API<29 写 Downloads 需补
WRITE_EXTERNAL_STORAGE 运行时权限——B0② 真机确认最低支持基线,或直接声明
最低支持 Android 10,本工具内部分发场景取后者)。

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
  Uppy 任务同语义;重启后上传重选即可、下载重点即可,成本低。悬挂 multipart 分片
  当前后端**无自动清理**(唯一通道=客户端主动 abort;孤儿分片记日志待清理通道,
  量级可控为接受前提,后续可补 MinIO lifecycle 兜底)。若上传在 complete 前被杀,
  用户在资产列表核实是否已传完(§4.1)。
  不引入 TaskStore/schema 迁移/源文件引用矩阵(评审意见,不采纳理由见 §18)。
- 页面:全部/上传/下载分段 + 进行中(进度/百分比/取消)+ 已完成(重试/移除);
  TabBar 传输格 badge=running 数。速度/剩余时间不做(web 下载列表有速度显示,
  App 简化不做,§17 已登记差异)。

## 8. 各功能域实现要点

### 8.1 浏览(项目 → 文件夹 → 宫格)

- 项目行:名称 + code + 素材计数(无此字段则不显示)+ 权限徽标
  (**ROLE_META 同 web**:按 ROLE_RANK(admin>uploader>downloader>viewer)取最高角色
  主 chip——admin→管理/accent、uploader→上传/amber、downloader→下载/emerald、
  viewer→查看/neutral,多角色其余 +N;空角色→「仅访客」。不做已归档徽标——
  `GET /projects` 两分支均过滤 `is_archived=False`,归档项目永不出现在列表,
  徽标无数据源(web 亦不渲染))。
  项目行不设通知入口(web 项目列表亦无;通知只有全局未读数,无逐项目口径,见 §17)。
- 文件夹行:`subtree_file_count` 徽标 + 敏感锁 + 「⋯」菜单(管理动作全收这里)。
  层级导航:`GET /folders?project_id=` 平铺返回全树(含 parent_folder_id),FoldersPage
  自组树按缩进展示,点文件夹进入该夹宫格上下文,支持多级下钻(目录模板可建两级以上
  目录,web FolderTree 同数据)。
- 宫格:3 列缩略图(`tags.thumbnail_key` 存在才请求 thumbnail-url,presigned 30min
  内存缓存+过期重签+同 URL 并发去重+LRU 上限约 80MB,失败降级类型色块);
  视频时长角标、livp 实况角标;点按=预览,长按=进入多选(设计稿 04)。
- 数据新鲜度:写操作(上传/删除/移动/打标/审批)成功后失效对应列表并刷新;从下级页
  返回时按需刷新,防 IndexedStack 挂着陈旧数据。

### 8.2 预览(对标 web AssetPreviewModal.detectKind)

| 类型 | 判定 | 呈现 |
| --- | --- | --- |
| image(png/jpg/gif/webp/svg/bmp/avif/ico) | 扩展名/content_type | 原图 presigned(download-link inline)或 **D4:缩略图** 大图;svg/avif/ico 超出 Flutter 内置解码,无缩略图时降级类型色块+「下载后打开」(不引 flutter_svg,web 端靠浏览器解码、App 无此待遇属已知边界) |
| heic/heif | 扩展名优先于 image/* | **缩略图**(1024px,D4) |
| livp | `.livp` | 静态图=缩略图;**实况短片=live-preview-url + video_player 播放**(web 同款) |
| video(mp4/mov/webm/m4v) | 扩展名 | download-link(inline)+ video_player;起播/解码失败(如 Android 对 HEVC .mov 硬解设备相关)→降级「下载后打开」 |
| markdown / text | .md/.txt 或 content_type | flutter_markdown_plus / 纯文本(download-link 拉取) |
| pdf | .pdf 或 application/pdf | dio 下载临时文件 → iOS share_plus 面板(快速预览/存储到文件)/ Android media_store_plus 写 Downloads(§6.1 矩阵同口径;share_plus 在 Android 只拉分享面板不落盘)——url_launcher 对 file:// 在 iOS 恒失败、Android 需 FileProvider,不可靠,不用 |
| unsupported | 其余 | 类型色块 + 「下载后打开」 |

- 结构:暗色画布(#141210)+ 顶部 ‹n/N› + 胶片条 + 底部元数据卡
  (文件名/大小/类型/时间/标签 chips + 备注);操作:下载/分享/申请权限。
  **下载权判定口径(与 web 同源)**:Asset 级无能力字段(AssetOut 已核实),用
  folder 级 `my_can_download` 控制下载按钮——**取值须来自单夹详情 `GET /folders/{id}`
  回填**(列表响应恒默认 False,web AssetSummaryPanel 同源消费 useFolder 结果);
  `false` 时下载禁用并
  给「申请权限」入口,点按仍以后端 403 为最终裁决。
- 详情打标:元数据卡「编辑」→ AssetTagEditor 移动版(user_labels ≤50 + notes)。
  labels_mode 语义同 web 实况:**单条编辑不传 labels_mode(后端默认 replace)、批量
  硬编码 merge**;App 在批量打标面板暴露 merge/replace 显式选择属增强,单条保持默认。

### 8.3 素材多选操作栏(D2 全量)

四键 + 溢出菜单,**全部对标 web 批量栏**:

- **分享**(**仅恰好单选时可用,多选置灰**——后端只有单资产/单夹分享端点,web 的分享
  入口也只在单资产详情面板;ShareModal 移动版:有效期四档→创建→复制链接+可选系统
  浏览器打开;表单字段对齐 ShareCreateIn 实况,**无提取码/下载开关**(requires_login
  恒 true 同 web 硬编码))
- **下载**(逐文件入队)
- **移动**(BatchMove 移动版:**仅文件夹一级选择,项目固定=所选资产所属项目**
  ——后端一期显式断言整批恰属一个项目且目标夹同项目(跨项目是二期物理迁移),
  web 目标项目 Select 同样固定禁切换;混批含多项目资产时整批禁用并提示)
- **删除**(确认弹窗;403 透传 detail)
- ⋯ 菜单:**批量打标**(App 增强:可选 merge/replace;web 实况批量=merge)、
  **批量前缀**(add/remove)、**申请权限**(**仅恰好单选时可用**,多选置灰;
  RequestAccess 移动版:动作=**访问**(access,仅 target_type=sensitive_folder 可选)/
  **下载**(download,必填有效期 duration_seconds 预设)+ 用途说明 reason(必填 ≥4 字)
  → POST /approvals;**后端无「编辑」动作**,勿做第三选项)

### 8.4 文件夹管理

「⋯」菜单:新建子夹(名称+敏感开关)/ 重命名 / 移动(MoveFolder 同款选择器)/
删除(**仅空夹可删**:须先删光子夹与文件并在回收站彻底清空;删除为**硬删不可恢复**,
后端无「非空软删」路径,非空一律 409 detail 透传——web 同口径)/
**敏感夹邀请**(邀请(含**有效期预设**,web FolderInvitePanel 同款)+撤销)/
**授权管理**(grants 列表+添加(选人/组+多 level:viewer/downloader/uploader)+
撤销,FolderGrantsPanel 移动版;**无「有效期/倒计时」**——后端 add_folder_grant
只收 levels+主体,HTTP 授普通夹授权恒永久,勿做有效期选择器(会被后端静默忽略
造成假 UI);有效期/倒计时只在敏感夹邀请与审批临时授权(§8.6/§8.7)两处;
**入口仅普通一级夹显示**——后端三端点均强制 level-1,敏感夹 400 指引走
invite/members,子夹无此入口,同 web 显隐)/
**回收站**(软删资产列表+恢复)。

### 8.5 项目管理

- 新建项目(NewProjectModal 移动版,**表单字段对齐 ProjectCreateIn 实况**:名称/code/
  描述 + 项目管理员(必填,默认=创建者) + minio_bucket(必填,默认 'ms-dev',收进
  高级折叠) + 权限模板 + 目录模板预填 + **艺人账号可选开通**(闸门
  `is_artist_account_creator`;登录名可做停顿预检 `GET /users/username-available`
  (web 同款),不预检时以提交 409 兜底;开通成功回显一次性初始密码,可复制,仅此一次)。
  **权限模板注意契约**:ProjectCreateIn 无模板 id 入参——web 的模板 Select 是把模板
  条目**展开为 `initial_grants` 行**提交(可增删改,50 条上限),App 同款;客户端
  模型须含 initial_grants/folder_template_id/artist_account 三个可选字段。
  总闸门 `is_project_creator`;**无「可见性」字段**(visibility 非创建入参,web 表单亦无));
- 成员管理(成员列表+添加(SubjectPicker 用户/组 + RoleChipGroup 角色)+移除+grants);
- 应用默认权限不在项目成员页(web 实况=管理后台·权限模板页的多项目批量操作,
  系统 admin 专用;App 随 §8.9 权限模板页承载,避免项目管理员误触 403);
- 已删除项目(列表+恢复,我的页→回收站;**仅 `is_project_deleter` 可见**——后端
  deleted/restore 双端点均挂该闸门,与 web 显隐同口径)。

### 8.6 审批中心

- 分段+数据源(**scope 口径勿混**):待我审批 = `GET /approvals?scope=all&status=pending`
  (badge 同源);我发起的 = `GET /approvals?scope=self`(按申请人过滤——只含本人
  发起的申请,含 pending,看不到他人提交的待审件,勿用它做待审列表)。
- 卡片=申请人+动作(访问 access/下载 download)+对象(素材/文件夹/项目)+用途;
  通过/拒绝双按钮(带确认;决策权由后端 `enforce_admin_for_target` 守门,非管理者
  操作 403 透传 detail);徽标=待我审批数(**仅 `me.is_system_admin` 显示**——后端
  scope=all 对任意认证用户放行,非 admin 挂 badge 只会看到全组织待审噪声且决策必 403;
  web 无审批 badge,此为 App 新增面,从严收敛)。

### 8.7 通知 + 我的权限

- 通知:按时间倒序列表(未读橙点)+ 全部已读;**未读数 30s 轮询**(web 同款,
  `GET /notifications?limit=1` 取 `unread_count`,已核实列表接口自带)驱动
  我的 tab badge 与我的页「通知」入口红点(全局未读,无逐项目口径)。
- 轮询生命周期:**仅前台 + 已登录才轮询**;进后台/登出/401 即停;恢复前台立即刷一次
  再续周期(单一 PollingController,防多页面各起计时器、防重叠请求)。
- 通知点击跳转:payload kind 走白名单映射——后端现有 kind 仅
  `approval_pending/approval_decided/folder_invite` 三种(审批类跳审批中心,
  folder_invite 跳对应项目/文件夹);未知类型显示通用详情
  不崩溃、不把任意 URL 交给导航器。
- 我的权限(**数据源同 web MyPermissionsPage**:`GET /projects` 取各项目 my_roles +
  `GET /approvals?scope=self&status=approved` 取已批准的临时授权;倒计时 =
  GrantCountdown 同款;后端无「我的全部 grants」聚合端点,勿按逐夹 grants 拼凑)。

### 8.8 搜索

- tab2:聚焦搜索框 + 结果列表(缩略图+文件名高亮+归属 项目/folder + 类型徽标);
  **防抖 ~300ms + 取消过期请求**(防旧查询结果覆盖新输入);点击 → push 预览
  (结果序列做胶片条);⌘K 命中数 50 截断的提示同 web 已知口径。

### 8.9 管理后台(移动版)

整体仅 `is_system_admin` 可见;**目录模板例外**——入口按
`is_folder_template_manager ?? is_system_admin` 单独放行(org admin/持组 flag 的
非 system admin 亦可用,web AppHeader 同口径;后端写端点守门即该依赖),持 flag
者进入 App 后仅见目录模板入口。
设计稿 12 为「概览+入口」;**对标 web = 每个子功能做成完整移动列表页**:

- **用户**:列表(搜索/分页)+ 建用户(带组)+ 编辑 + 启用/停用 + 重置密码(回显一次性密码,
  可复制)+ 解锁;
- **组**:列表 + 建/编 + 成员管理(加/移);
- **审计**:筛选(事件类型/对象/主体/时间)+ 分页列表 + **CSV 导出**
  (dio 带会话下载 → Android 存 Downloads / iOS share 面板;不能用 url_launcher——
  系统浏览器不带 cookie 必 401);
- **权限模板**:列表 + 建模板(主体行×独立角色,50 条上限)+ 编辑 + 删除 +
  **应用默认**(ApplyDefaultModal 移动版:多项目批量勾选→逐项目刷新默认授权,
  `require_system_admin` 闸门,系统 admin 专用——全 App 唯一应用默认入口);
- **目录模板**:列表 + 建(条目路径校验)+ 编辑 + 删除(闸门 is_folder_template_manager);
- **百度任务(管理)**:全量任务列表(状态筛选)+ 详情 + 文件明细分页。

### 8.10 百度备份·用户侧

入口:我的→网盘备份(**按 `me.baidu_backup_enabled` 显隐**——开关关闭的部署里后端
/baidu/* 统一 404,入口不露出;web UserMenu 同口径)。**绑定流程(G1,按后端实况修正)= oob 复制码,与 web 完全同款**:
后端 `authorize_url()` 的 `redirect_uri` 恒为 `"oob"`(`baidu_client.py
_REDIRECT_URI_DEFAULT`,签发处未传参)——**不存在「回调 redirect 拿 code」环节**,
授权码是百度授权页上展示后人工复制回填的。App 交互(零后端改动、不引 webview):

1. `POST authorize-url` → 展示授权链接(可复制 + `url_launcher` 直接打开系统浏览器);
2. 用户在浏览器完成百度授权,oob 页面显示授权码(单次有效约 10 分钟)→ 复制;
3. 切回 App 粘贴授权码 → `POST binding`;
4. 授权码输入框**一次性使用**:提示勿外传,提交(无论成败)后即清输入态。

授权链接打不开/授权码过期/绑定失败均有明确错误文案与重走入口;不自动重试绑定。
绑定后:网盘目录树懒加载 → 新建任务向导(选项目/文件夹 + 承接夹;**同名文件默认
跳过**,覆盖导入是任务详情内的逐文件后置操作且需管理权限,向导表单无此选项)→
任务列表(状态/进度)+ 取消/重试失败/删除 + **任务详情文件级行操作(对标 web
BaiduTaskDetail,补齐 D5 全量)**:重试(non_retryable 置灰)/ 覆盖导入 /
随机后缀导入,key_conflict 行按处置手册分流。频控与 key 冲突语义
透传后端文案(处置手册已有)。

### 8.11 请求链接

项目页与项目内页菜单「请求链接」(对标 RequestLinkCreateModal 的 web 发起位):创建后复制链接;
落地页 web 承载。**入口显隐闸门同 web**:项目页发起位=项目 `my_roles` 含 admin,
项目内发起位=folder admin(单夹详情 my_can_admin);后端对非 system admin 且无
can_admin 一律 403,勿对普通用户露出入口。

### 8.12 维护横幅

GET /maintenance/banner(公开免鉴权),**与 web MaintenanceBanner 完全同款**:**前台
即轮询、不分登录态**(登录页/主界面均挂;与 §8.7 通知轮询共用 PollingController
节拍但**门控不同**——通知轮询须已登录,banner 轮询不需要);`active=true` 立即弹
**不可关闭**的全局提示(部署窗口,阻止用户继续上传/下载直至后端重启报错);`active`
由 true→false 时显示「升级完成」数秒后自动关闭;API 重启期间的网络错误**不**误判为
完成(lastKnownActive 兜底)。不做「可关闭横幅+会话内
不再弹」——那是弱提示语义,与 web 的部署安全强提示相反。

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
    share/ share_create_sheet.dart request_link_sheet.dart
    baidu/ baidu_page.dart bind_code_page.dart netdisk_tree_sheet.dart
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

## 10. 视觉与主题令牌(同 v1,对齐 web/src/styles/tokens.css)

bg #FAFAF7 / surface #FFF / surface2 #F5F3EE / fill #F0EEE9 / fg #1A1A1A /
muted #6B6B68 / subtle #9A9A95 / border #E8E6E1 / accent #C2410C(+strong #9A3412、
soft #FEE4D0、faint #FEF3E8)/ green #047857 / amber #B45309 / red #9F1239 /
dark #141210(预览画布;**出处=Open Design 设计稿**,web tokens.css 无此值——暗色 surface #1A1A18、视频画布 #000,实施按设计稿走)。`ColorScheme.fromSeed(#C2410C)` 起步再精调;卡片圆角 20;
徽标 pill 四色(accent/green/neutral/amber);系统字体 + tabularFigures 数字。
共享组件:Badge/EmptyState/ErrorView/类型色块/Avatar(首字渐变)/倒计时 chip。

## 11. 数据契约与模型扩展(全部已有端点,零后端改动)

v1 方案列过的端点族继续有效,新增对接:

| 域 | 端点族 | 模型要点 |
| --- | --- | --- |
| Me | /auth/me | 补 is_system_admin / is_folder_template_manager / is_project_creator / is_project_deleter / is_artist_account_creator / baidu_backup_enabled(网盘备份入口显隐开关,关闭时后端 /baidu/* 统一 404) |
| Project | /projects 族 | 补 my_roles / is_archived / visibility / admins;deleted+restore |
| Folder | /folders 族 | 补 subtree_file_count;create/patch/move/delete/invite/grants;**单夹详情 GET /folders/{id} 是 my_can_view/download/upload/admin 与 my_delete_grant 的唯一回填点(get_folder 惯例,列表/创建响应恒默认 False,宫格页必拉)** |
| Asset | /assets 族 | 补 tags.thumbnail_key / user_labels / notes;trash/restore/meta/batch-prefix/batch-move |
| Share | /share 族 | ShareCreateOut(token/landing_url/expires_at;download_url 在 resolve 侧) |
| Approvals | /approvals 族 | scope/status 筛选、approve/reject |
| Notifications | /notifications 族 | 列表 + mark-read;unread 计数接口同 web 口径 |
| Admin | /admin/directory 族 + audit(+export.csv)+ 两模板族 + baidu-backup | 分页模型 |
| Baidu | /baidu/backup 族 | binding/authorize-url/netdisk folders/tasks(+cancel/retry/删除) |
| Request links | POST /request-links | 创建即复制 |

已知契约钉子(实施时遵守):422 detail 数组型要兼容(errorMessage 同 web 哲学,MVP
`_extractDetail` 已处理);DELETE 多数返 204(**例外:admin/directory 删组/移除成员
返 200+JSON**,勿按 204 硬判);分片 PUT 必带 Content-Length(prod 411);
presigned thumbnail 30min 过期重签;`list_objects` 截断为后端已知项(搜索可达域口径同 web)。

## 12. 依赖变更

| 包 | 动作 | 用途 |
| --- | --- | --- |
| media_store_plus | 新增 | Android Downloads 落盘(D1②/审计 CSV/pdf/通用文件) |
| share_plus | 新增 | iOS 存文件面板 + pdf 预览/存储 + 分享链接/一次性密码复制辅助 |
| url_launcher | 新增 | 分享/请求链接开系统浏览器、百度授权链接外开(§8.10);**不用于 file://**(iOS 恒败) |
| video_player | 新增 | 视频 + livp 实况短片播放(live-preview-url) |
| flutter_markdown_plus | 新增 | .md 预览(flutter_markdown 官方已停更,此为其社区延续版) |
| dio/photo_manager/wechat_assets_picker/file_picker/archive/… | 保留 | 现役 |
| webview_flutter | **不引入** | 百度绑定=oob 复制码流程(§8.10),无回调可拦,webview 无必要 |
| 状态管理/路由框架 | **不引入** | — |

版本在首个使用批次 `pub add` 锁定并记 pubspec 注释;升级须单独批次。

## 13. 权限与安全边界

- 可见性一律后端裁决(App 不自判);上传入口 `my_can_upload`;管理入口 `me.*` 旗标。
- 删除/移动/授权等写操作:不做客户端预判,403/422 透传 detail(web 同哲学)。
- sensitive folder:锁图标;邀请/授权走专用面板(后端裁决)。
- 审计 CSV:必须走带会话的 dio 下载(§8.9),禁 url_launcher 直开。
- 日志(AppLog)只记 host+path 不记凭据;企业微信推送密钥维持现役管理方式。
  脱敏红线(扩展日志时维持):Cookie、Authorization、百度授权 code/state、分享 token、
  管理后台一次性重置密码、完整 presigned URL 一律不入日志。
- 日志推送收拢:我的页「诊断」入口 + 登录页底部小字(登录失败兜底出口)。

## 14. 测试与验收

**单测(PC)**:现役用例全保留 + 新增:探活顺序与超时降级、TransferQueue 状态机、
content_type 映射、**落盘矩阵(平台×类型,D1 双落盘)**、分片切块边界、
`detectKind` 移动版类型判定、徽标映射(my_roles→徽标)、批量前缀入参校验。

**联调(默认 hh2 dev;本地隔离栈 api/docker-compose.feat-ms.yml + seed_demo_data
仅用户明确要求时启用——CLAUDE.md 2026-10-20 立规,防 E 盘再被灌满)**:全功能域逐条过
矩阵 §1(每行至少一条 happy path + 一条 403 边界);`flutter analyze` + `flutter test` 全绿。

**真机双端验收(关键场景)**:

| 场景 | iPhone(TestFlight) | Android(release APK) |
| --- | --- | --- |
| 探活 | WiFi→内网 / 蜂窝→公网(我的页确认) | 同左 |
| 强制改密 | must_change_password 首登强制改密,改完才放行 | 同左 |
| 上传 | 实况→livp/普通图视频/文件/GB 级大文件 | 相册/文件/SAF 深层目录 |
| 下载落点 | 相册(实况/图/视频)、文件 app | **图库+Downloads 双可见(D1)** |
| 预览 | 图/heic/视频/livp 播放/md/pdf | 同左(HEIC 兼容性) |
| 管理后台 | 建用户带组/审计 CSV 落 Downloads | 同左 |
| 百度绑定 | oob 复制码闭环(链接外开→复制授权码→回填绑定) | 同左 |
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
| R5 | 百度授权页/流程改版导致复制码交互变化 | 与 web 完全同款 oob 流程,web 侧先暴露变化、App 跟随修正;粘贴码交互面小、改版影响可控(v2.1 的「webview 拦截回调」方案已废弃——后端 redirect_uri 恒为 oob,无回调可拦) |
| R6 | 缩略图 presigned 30min 过期裂图 | URL+过期时间缓存,过期重签;失败降级类型色块 |
| R7 | 管理后台表单在移动端体验降级(审计筛选等重表单) | 列表+筛选简化为分段/chip;CSV 导出走 dio;接受「可用不追求等效 PC 效率」 |
| R8 | 全功能量导致包体积/页面数膨胀 | 组件纪律(§9)+ 按域分文件;video_player 等重依赖按需懒加载页 |
| R9 | 杀 App 传输中断无续传 | 与 web 行为对齐(同样无续传);重试=从头;文档化预期 |
| R10 | 422 数组 detail 白屏类雷 | 统一 errorMessage 兼容(web 踩过 #31 白屏,App 侧 `_extractDetail` 已兜不崩溃;现役仅 toString 渲染,数组→友好文案仍须按 §4.1 实现) |

## 16. 实施批次(工程顺序,非功能分期——全部交付)

每批:独立分支(基于 liuqi)→ 自测绿 → commit → `scripts/changelog.md` 记账 →
联调(hh2 dev 默认;本地隔离栈仅用户明确要求时启用)。批次间可独立验收发布。

| 批 | 内容 | 交付判据 |
| --- | --- | --- |
| **B0 技术验证(轻量,~1 天)** | 三项 PoC,结论直接记入 changelog/本方案附录,不设签字仪式:①百度绑定 oob 复制码流程双端真机闭环(授权链接外开→复制授权码→回填→绑定成功;含授权码过期/绑定失败分支);②Android 落盘 PoC(photo_manager 图库保存行为 + media_store_plus Downloads);③契约核对收尾(2026-10-20 已核完:v2.2 修正项=oob 流程/新建项目必填字段/我的权限数据源/应用默认入口/分享表单字段/审批动作枚举/审批 scope 口径,见 §1/§8.3/§8.5/§8.6/§8.7/§8.9/§8.10) | 三项有结论;不可行项触发方案修订 |
| B1 基建 | 目录重构(§9)+ 主题令牌 + Session 探活 + 登录简化 + **改密页(含 must_change_password 强制流守卫——后端 F15 拦截除改密/me/logout 外全部端点,改密页缺席会卡死首登用户)** + HomeShell 四 tab + 我的页骨架(日志收拢/服务指示/退出) | 探活双端真机过;强制改密闭环;旧功能不回归 |
| B2 浏览线 | 项目/文件夹列表(徽标/计数/敏感锁)+ 宫格(缩略图缓存)+ 预览全类型(§8.2 含视频/livp 播放);预览页操作钮(下载/分享/申请)本批先占位禁用,随 B4/B5 点亮 | 双端浏览流畅;预览类型全覆盖 |
| B3 上传+传输 | 统一上传面板 + uploadFile 流式 + TransferQueue + 传输页 | GB 级上传不 OOM;取消/重试可用 |
| B4 下载线 | 落盘矩阵(D1 双落盘)+ 批量下载(含宫格多选与操作栏壳,本批先仅「下载」项点亮)+ toast 去处 | **Android 图库+Downloads 双可见验收过** |
| B5 素材操作线 | 操作栏全量(分享/移动/删除/打标/前缀/申请)+ 回收站 + 详情打标 | 批量操作全对标 web;403 边界文案正确 |
| B6 文件夹+项目管理 | 夹 CRUD/移动/邀请/授权;新建项目(含艺人账号开通)/成员/已删除项目(资产回收站归 B5) | 管理动作全量;权限闸门正确 |
| B7 协作线 | 审批中心 + 通知(轮询 badge)+ 我的权限 + 搜索 tab | 三域 happy path + 未读轮询真机过 |
| B8 管理后台 | 用户/组/审计(CSV)/权限模板/目录模板/百度任务管理 | admin 真机全流程;非 admin 不可见 |
| B9 百度用户侧+收尾 | 绑定(oob 复制码)/网盘浏览/建任务/任务管理 + 请求链接 + 维护横幅 + 错误边界 + 全量测试补齐 | 绑定闭环真机过;§1 矩阵逐行勾检 |

## 17. 与设计稿的差异清单(对标源=web,非设计稿)

| 设计稿元素 | 处理 |
| --- | --- |
| 预览页「收藏 / 评论」 | 不做(web 无此功能) |
| 我的页「离线缓存」 | 不做(web 无) |
| 我的页「通知设置」「SSO/双重验证」 | 不做;账号与安全=修改密码(web 同) |
| 项目页右上「项目分享设置」(03 屏) | 不做项目级分享(web 分享为资产/文件夹级) |
| 传输页「速度/剩余时间」 | 不做(App 简化;web 下载列表有速度显示,属有据差异) |
| 首页项目封面大图 | 降级为 code/徽标行(后端无项目封面字段);行布局保设计语言 |
| 「我的分享」管理列表/撤销(09 屏) | 不做(web 无分享列表/撤销接口,2026-10-20 核实 share.py 仅 create+resolve);App 只做分享创建 |
| 分享表单「提取码/下载开关」(设计稿若有) | 不做(后端 ShareCreateIn 仅 expires_in_seconds+requires_login,web 表单只有有效期四档);App 表单=web 同款 |
| 项目行右上「通知铃铛」(设计稿 03 屏若有) | 不做(后端通知仅全局 unread_count,无逐项目口径;web 项目列表亦无此入口;全局未读在 §8.7 我的 tab/铃铛承载) |
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
| 13 | 百度回调完整匹配非宽前缀;code 不入日志;手动 code 仅一次性 | 「回调匹配」项随 v2.2 修正失效——后端 redirect_uri 恒为 oob、无回调可拦(§18.3);code 不入日志(§13)与 code 一次性输入(§8.10)仍然生效 |
| 14 | B0 前置技术验证 | §16 新增轻量 B0(~1 天三项 PoC,结论记 changelog,不设三态签字/责任人体系) |

### 18.2 不采纳(及理由)

| # | 意见 | 不采纳理由 |
| --- | --- | --- |
| 1 | B0 三态结论(已关闭/有条件接受/阻断)、书面批准、责任人指派、12 份治理交付物 | 单人开发 + 用户验收的团队规模不支撑该流程;真实风险点(百度授权/Android 落盘/契约)已由轻量 B0 覆盖,治理仪式不产生对应收益 |
| 2 | TaskStore 任务持久化(schemaVersion 迁移/逐步骤 stepResults/上传源引用矩阵/24h TTL 清理) | web 同行为=刷新即丢(Uppy 内存态);杀 App 后重传/重点的成本远低于持久化体系的实现与维护成本;悬挂分片当前无自动清理但量级可控(§7 已如实写明,后续可补 MinIO lifecycle) |
| 3 | Cookie 加密存储(Keychain/Keystore)+ 账号↔origin 双维度映射 + 双账号测试 | 单账号单设备的内部工具现实;cookie 文件本就在 app 沙盒私有目录,与浏览器同等级保护;双账号是虚构需求 |
| 4 | 内网 HTTP 列为发布安全阻断项(硬性准入/VPN/书面风险接受) | 与 ADR-0007「生产改局域网部署、可完全离线运行」的产品决策直接冲突;且 ATS/networkSecurityConfig 均不支持 IP 字面量例外(§4 注),「限制明文范围」技术不可行;保持全局放开 + 公网 HTTPS 兜底现状 |
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
- 两份把内网 HTTP 当新发现的安全例外:这是 ADR-0007 既定产品形态,MVP 起即如此。
- **本方案 v2.1 自身的事实错误(v2.2 修正)**:①把百度授权描述为「回调 redirect 拿
  code」并以 webview 拦截为主方案——后端实况 `redirect_uri` 恒为 `"oob"`
  (baidu_client.py `_REDIRECT_URI_DEFAULT`,BaiduBindModal 头注释可证),是复制码
  回填流程,已按 §8.10 重写;②新建项目表单遗漏必填的 minio_bucket/admin_user_id
  与艺人账号开通、误列不存在的「可见性」入参(§8.5 已重写);③「应用默认权限」入口
  误放在项目成员页(实况=管理后台·权限模板页,系统 admin 专用,§1/§8.5/§8.9 已改);
  ④「我的权限」数据源误写为 grants 查询族(实况=/projects my_roles +
  /approvals?scope=self,§8.7 已改);⑤分享表单误含提取码/下载开关(实况
  ShareCreateIn 仅有效期+requires_login,§1/§8.3 已改);⑥pdf 预览误用 url_launcher
  开 file://(iOS 恒败,§8.2 已改 share_plus);⑦ADR 编号误引 0008(实为 0007);
  ⑧审批申请动作误含「编辑」(后端 action 枚举仅 download|access,§8.3/§8.6 已改);
  ⑨审批中心「待我审批」未写 scope=all&status=pending 口径(scope=self 是我发起的,
  §8.6 已补);⑩维护横幅误写「可关闭+会话内不再弹」(web 实况=active 弹不可关
  modal+升级完成提示,§8.12 已改)。
