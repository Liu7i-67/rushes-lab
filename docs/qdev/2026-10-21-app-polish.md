# App 移动端体验与 UI 精细化全面优化 · 需求文档

日期:2026-10-21 · 分支:`feat/app-polish`(基线 liuqi@32b4220) · 状态:定稿
代码范围:`material-storage/app`(Flutter,272 dart 文件,93 测试文件基线全绿)

## 背景与目标

用户反馈:「app 部分很多交互不符合移动端的体验,ui 风格也不够精细设计比较粗犷,全面优化一下,让 app 更加精致易用」。

三份只读调研(全局基建/用户侧页面/admin+测试基建)结论:

- **底子好**:M3 + `Tk` 颜色 token(338 处引用、裸色仅 2 处疏漏)+ 单一 `buildAppTheme`。
- **执行层失控**:fontSize 279 处/14 档(10~17 含 0.5 半档)、SizedBox 间距 259 处、圆角 11 档混用、列表形态四种;30 处 showModalBottomSheet 同构结构零封装、24 处确认 AlertDialog 零封装、117 处 SnackBar 无 floating 无 action;全库 **0 处 HapticFeedback、0 处 FAB**;9 处「点击加载更多」按钮式分页。
- **交互硬伤**:多选操作栏无全选/无取消入口/拥挤溢出风险;预览页胶片条不自动跟随、无沉浸模式、无双击缩放;项目列表行尾堆 4-5 元素;文件夹行三重导航符号;12+ 处原始异常 `'$e'` 直出;退出登录无确认;改密成功无反馈;百度警告 100+ 字 SnackBar 文字墙。

**目标**:一轮系统性精细化——建立字号/间距/圆角 token 与通用组件基建,按移动端惯例重做高频交互(多选/预览/分页/表单),统一反馈体系(错误文案/Toast/触觉),页面级精修,admin 轻量适配。不引新状态管理/路由框架(沿用 ChangeNotifier+命名路由,既有刻意选型)。

## 模糊点与决策记录

| # | 问题 | 决策 | 理由 |
|---|---|---|---|
| 1 | admin 页面是否纳入 | **轻量适配**:共享组件(搜索框/确认框/sheet 骨架/加载态)统一套用、密排小字与触控目标修复,不重排页面结构 | admin 在手机上被管理员真实使用;重排结构风险大收益低 |
| 2 | 深色模式 | **本轮不做** | 现状零基础(darkTheme 0 处),全局工程另立周期 |
| 3 | 「加载更多」按钮分页 | **9 处全部改滚动到底自动加载**(ScrollController+底部加载指示器) | 移动端标准交互,消灭 web 分页思维 |
| 4 | 预览页新交互 | 增加沉浸模式(单击显隐信息条)+双击缩放+胶片条自动跟随 | 图片查看器标配,不改既有横滑/捏合手势 |
| 5 | 触觉反馈 | 增加 HapticFeedback(长按多选/选中/危险确认等关键点) | 高感知低成本;纯增强不改逻辑 |
| 6 | 视觉风格方向 | 保持米白+橙既有品牌(tokens.css 对齐),只做收敛与精细化,不换风格 | app/web 视觉一致性是既有约定 |

(1-3 已按推荐项征求用户,未获回复,由 PM 按推荐项拍板,可随时推翻重议。)

## 功能点明细(逐条可验收)

### A. 基建:设计 token 扩展 + 通用组件(先行包,其余包消费)

- **A1 字号 token**:`lib/theme/tokens.dart` 新增字号常量(6-7 档,如 10/11/12/13/15/17,映射规则实现时定但必须全库一致),并完成 `lib/core`+`lib/widgets`+`lib/app.dart` 内收敛;features/ 内 279 处由 B-F 各包按同一映射迁移(半档 10.5/11.5/12.5/13.5/14.5 归整,视觉层级不得倒置——小字仍小、标题仍大)。
- **A2 间距 token**:常用间距收敛(4/8/12/16/24 阶梯),包 A 负责 token 定义+core/widgets 内迁移;features/ 内高频值由 B-F 各包迁移。
- **A3 圆角 token**:11 档收敛到 4 档(如 8=缩略图、12=小卡/输入、16=列表卡、20=大卡,胶囊另算),同上分工。
- **A4 `SheetScaffold`**(`lib/widgets/sheet_scaffold.dart`):统一底部弹层骨架——拖拽把手+标题+关闭钮+滚动区+可选吸底按钮组+键盘避让+ maxHeight 约束。新签 API 兼容现有「返回 bool/结果」约定。
- **A5 `showAppConfirm`**(`lib/widgets/app_confirm.dart`):统一确认弹层(标题/正文/确认/取消文案+危险态红色确认),替代 24 处零散 AlertDialog 确认。
- **A6 `toast()`**(`lib/widgets/toast.dart` 或 core):floating SnackBar 封装,支持 action(如「查看」)、统一成功/失败样式;替代各页自拼 ScaffoldMessenger。
- **A7 `SearchField`**(`lib/widgets/search_field.dart`):统一搜索框(7 处复制),主题圆角、prefixIcon、onSubmitted+清除钮。
- **A8 `Haptics` 工具**(`lib/core/haptics.dart`):selection/light/medium/impact 薄封装,供各页调用。
- **A9 `ListSkeleton`**(`lib/widgets/list_skeleton.dart`):列表/宫格加载骨架,替代主要页面居中裸转圈(首载场景)。
- **A10 危险按钮统一**:DangerButton 或 FilledButton 主题级红色变体,收敛 3+ 处 styleFrom 复制。
- **A11** `lib/core/error_boundary.dart:43,51` 两处裸色改引 Tk(疏漏修复)。

### B. 宫格与多选重做(features/assets/,高频路径)

- **B1 多选操作栏重排**(`asset_selection_bar.dart`):左端 ✕ 退出多选;新增「全选」(全选/取消全选切换);操作键图标+短文案,触控目标≥48dp 逻辑高度;320dp 宽度不溢出;禁用原因不依赖 Tooltip——禁用键点击弹底部说明或显示小字原因。
- **B2 长按多选触觉+动效**(`asset_tile.dart`):长按 HapticFeedback.medium+选中缩放/勾选动画;多选态点选 HapticFeedback.selection。
- **B3 自动加载**(`assets_body.dart`):移除「加载更多」格子,ScrollController 到底自动加载,底部线性加载指示器;加载失败 toast+可重试(再次滚动或点击指示器)。
- **B4 移除开发日志横条**(`assets_body.dart:74-82` `_log` 显示):调试信息不得出现在产品 UI(可改为 debugPrint)。
- **B5 上传入口 FAB**(`assets_page.dart`):右下 FloatingActionButton(extended:有选中上传中可显进度点),替换 AppBar 小图标;AppBar 保留多选管理等次级动作。
- **B6 UploadMiniBar 可点**(`upload_sheet.dart`):点击跳转传输 Tab(RefreshBus 或 Navigator 到 /home 传输格)。
- **B7 缩略图文字**(`asset_tile.dart`):文件名 12px→token、元信息 10px 提升至不小于 11px,颜色对比度提升(subtle→muted 或加深)。
- **B8 上传面板标题区**(`upload_pick.dart`):sheet 加标题「上传到 <文件夹>」;相册上限 99 预先提示。
- **B9 空态/错误态可下拉刷新**(`assets_body.dart`):loading/error/empty 分支包 AlwaysScrollableScrollPhysics(R3 模式补齐残留)。

### C. 预览页(features/preview/)

- **C1 胶片条自动跟随**(`filmstrip.dart`):ScrollController+animateTo 让当前张居中可见。
- **C2 沉浸模式**(`preview_page.dart`):单击媒体切换显隐(AppBar+胶片条+MetaPanel+操作钮),带动画过渡;再单击恢复;视频单击暂停与沉浸手势不冲突(单击空白/双击缩放手势仲裁明确)。
- **C3 双击放大/复位**(`preview_media.dart`):双击在 1x 与 2.5x 间切换(带动画),与捏合共存。
- **C4 底部信息区视觉**:三段(胶片条/MetaPanel/操作钮)浮层化或圆角过渡,不再直角堆叠;禁用钮原因不靠 Tooltip。
- **C5 下载入队反馈**(`preview_page.dart`):下载钮就地状态变化(入队中→已入队 ✓),Toast 改主题适配样式。
- **C6 Android PDF**(`preview_media.dart`):下载完成后就地提供「打开」动作(share_plus/url_launcher 打开本地文件),不再只给「需下载后打开」死胡同色块。
- **C7 申请权限 sheet**(`request_access_sheet.dart`):理由输入内联 errorText+字数计数;错误走 errorMessage。

### D. 表单与弹层规范(跨目录 sheet,消费 SheetScaffold)

- **D1 SheetScaffold 落地**:30 处 showModalBottomSheet 逐个迁移(至少用户侧 14 处全部+admin 16 处中的表单类),保持既有对外 API(静态 showXxx 方法与返回值)不变。
- **D2 新建项目表单**(`new_project_sheet.dart`):字段内联 errorText 校验(名称/code 规则前置),不再只靠提交时 SnackBar 报第一条;「创建」按钮吸底不随滚动;关闭时有未保存修改则弹 showAppConfirm。
- **D3 分享面板**(`share_create_sheet.dart`):有效期 RadioListTile×4 改 ChoiceChip 单选;结果 URL 样式化(maxLines+等宽字体+CopyButton);错误收口。
- **D4 请求链接**(`request_link_sheet.dart`):「复制链接」改 CopyButton 就地反馈(修复 SnackBar 被 sheet 遮挡的 R1 同款回归);表单分组标签样式化。
- **D5 批量移动结果**(`batch_move_sheet.dart`):「对账:成功 x+跳过 y」工程师文案改用户口径(如「已移动 x 项,y 项跳过(无权限/同名)」);跳过列表显示文件名而非 assetId。
- **D6 上传跳过原因**(`upload_sheet.dart`):入队汇总 toast 带「查看详情」action 打开跳过清单(文件名+原因)。

### E. 页面精修(用户侧各页)

- **E1 登录页**:品牌化首屏(accent 色容器图标+标题排版);textInputAction.next/密码 done 提交;autofillHints(username/password);错误信息固定高度区不跳动;右上开发者日志按钮移除(功能并入「我的」诊断区或 debugPrint);探活失败横幅卡片化。
- **E2 改密页**:复杂度规则前置提示文案;成功反馈(toast「已更新,请重新登录」)后再跳登录;错误不跳动。
- **E3 项目列表**(`projects_page.dart`):行重排——trailing 收敛为角色徽标+chevron,「成员/请求链接」等管理动作移入长按菜单或行尾单「⋯」;图标 add_business→create_new_folder;首载骨架屏;空态引导(有权限则给「新建项目」按钮);错误 errorMessage。
- **E4 文件夹页**(`folders_page.dart`+`folder_row.dart`):移除行尾 chevron(与整行可点重复),保留展开箭头并扩大触控区≥44dp;「⋯」提权为清晰图标;层级缩进改连续参考线或底色;loading/error/empty 分支补下拉刷新(R3 残留);菜单打开时的「权限核验中…」改骨架占位。
- **E5 我的页**(`me_page.dart`):iOS 设置式分组卡片(组容器+组内圆角+分隔);退出登录 showAppConfirm;「当前服务/日志推送」收纳进「诊断」折叠组或组内低位;头部摘要(角色+项目数或仅角色大字排版)。
- **E6 通知**(`notifications_page.dart`+`notification_row.dart`):相对时间(刚刚/N 分钟前/N 小时前/昨天/日期);自动加载;「全部已读」无未读时禁用+AppBar 未读数;未知 kind 详情 AlertDialog 改展示卡样式统一。
- **E7 传输页**(`transfers_page.dart`+`transfer_card.dart`):任务卡与百度任务卡统一语言(圆角卡+进度条内嵌);取消/移除加确认(危险);分段器带计数(全部 N/上传 N/下载 N);失败原因 errorMessage 化;空态引导动作。
- **E8 审批页**:决策后不整页回顶(局部更新或保持滚动位置);卡片白底改 token;两段计数。
- **E9 搜索页**(`search_page.dart`):onSubmitted 即时搜索;未搜索态给引导卡(图标+说明,可选最近关键词);搜索框圆角统一主题;结果行文字提升。
- **E10 回收站两页**:trash 行图标按类型区分(image/video/doc);恢复成功 toast 带目标夹名;deleted_projects 顶部说明收纳为可关闭提示或降级为空态文案;错误收口;自动加载。
- **E11 我的权限页**:补下拉刷新;「仅访客」弱化方式改小字标注(不再只靠边框)。
- **E12 百度**:向导步骤指示器(1/2 步)+「上一步」标准化;baidu_new_task 警告/排队预期文字墙改 showAppConfirm 或结果卡;任务卡操作行触控加大;task_detail 文件区 360 定高改自适应;空态统一 EmptyState。
- **E13 项目成员 sheet**:「点角色徽标撤销」改显式移除按钮(带图标),撤销走 showAppConfirm。
- **E14 错误文案全局收口**:各包按目录自查 `'$e'`/`:$e` 直出,统一走 `errorMessage()` 中文兜底(已有 util,推广)。

### F. admin 轻量适配(features/admin/,不重排结构)

- **F1**:7 处搜索框统一 SearchField(admin_users/admin_groups/admin_baidu_tasks 等)。
- **F2**:11pt 密排文字提升至 token 档(≥11 或归 12),行内 12.5px 文字钮改 IconButton+文字或加高触控。
- **F3**:确认框迁移 showAppConfirm(8 处)。
- **F4**:主操作 AppBar 图标语义化(语义不符的换图标)+FAB 不强求,但「应用默认/新建」双图标并存处在行内给文字标签或区分度提升。
- **F5**:grant_template/folder_template 表单复用 FormSkeleton(消 2 处内联骨架复制)。
- **F6**:admin 三处分页(users/audit/baidu_tasks/task_files)改自动加载。
- **F7**:审计筛选栏事件类型下拉暴露英文 raw token 改中文映射(audit_labels 已有映射,接入)。

### G. 全局(随各包落地,测试包统一验证)

- **G1**:flutter analyze 0 新告警;既有 93 测试文件全绿。
- **G2**:全库 HapticFeedback 覆盖关键点(长按多选/选中/下拉刷新触发可选/危险确认)。
- **G3**:全库 fontSize 裸写≤20 处(从 279 收敛,余量为无法归档的特殊场景并注释原因)。

## 数据库修改方案

不涉及。

## 接口定义

不涉及(纯前端;相对时间为本地时间格式化,PDF 打开用既有 url_launcher/share_plus 能力,无后端改动)。

## 前端改动点

全部改动在 `material-storage/app/lib`(+`test`),见上文 A-F 分包。**不改 pubspec 依赖集合**(HapticFeedback 为 Flutter 内置;若确需新依赖须回报 PM 决策)。禁止改动:`lib/core/api/*`(API 层)、`lib/core/transfers/*` 传输核心逻辑(UI 层展示可改)、路由结构(不引 go_router)。

## 后端改动点

不涉及。

## 测试功能点

新功能(widget/单元,复用 FakeMsApi 记录式假 API 套路):
1. A:token 收敛后 analyze+全量既有测试绿;SheetScaffold/showAppConfirm/toast/SearchField 基础 widget 测试(标题渲染、确认回调、action 回调)。
2. B:多选栏「全选」勾满/取消清空、✕ 退出多选;320dp 逻辑宽度无 overflow 异常;长按触发 HapticFeedback(mock channel 可验证调用);宫格滚动到底触发加载(快滚到底→fake api 第二页被请求);日志横条不再渲染(find byType 文本不存在)。
3. C:胶片条切换第 N 张后 animateTo 生效(验证 ScrollController offset 变化);单击切换沉浸(AppBar/信息条 offstage);双击 scale 变化(1↔2.5);PDF 色块场景 Android 下提供打开动作入口(呈现层验证)。
4. D:新建项目空名称提交→名称框 errorText 显示且不弹 SnackBar;有输入时下滑关闭→确认弹层出现;request_link 复制走 CopyButton(SnackBar 不再出现在 sheet 下);分享有效期 ChoiceChip 单选;批量移动结果文案含文件名。
5. E:登录 textInputAction/autofillHints 属性断言;改密成功出现反馈后跳转;退出登录弹确认、取消不登出;通知时间「5 分钟前」「昨天」格式单测(fmt 纯函数);传输分段计数;审批决策后滚动位置保持(scrollController offset 不归零);搜索 onSubmitted 触发请求;trash 图标按 kind 区分;百度向导步骤指示渲染;警告不再以 SnackBar 文字墙呈现(文本长度阈值断言或 find Text 不存在)。
6. F:admin 搜索框统一后筛选行为不回归(既有 admin_pages_test 全绿);自动加载触发;审计筛选中文文案。
7. 回归:93 个既有测试文件全绿+analyze 0 新告警;真机验收清单(P0-P2 级)另行人工执行(本周期不阻塞)。

## 派发与文件边界(防冲突)

- 包 A(基建):`lib/theme/*`、`lib/widgets/*`(新增)、`lib/core/haptics.dart`、`lib/core/error_boundary.dart`、`lib/app.dart`(仅当主题需要)。
- 包 B(宫格多选):`lib/features/assets/*`(upload_* 含)。
- 包 C(预览):`lib/features/preview/*`。
- 包 D(表单弹层):`lib/features/projects/new_project_sheet.dart`+`initial_grants_field/folder_template_field/artist_account_field`、`lib/features/share/*`、`lib/features/assets/batch_move_sheet.dart`(D5)、`lib/features/projects/project_members_sheet.dart`(E13/D1)。
- 包 E(页面精修):`lib/features/{auth,projects,folders,me,notifications,transfers,approvals,search,permissions,baidu,shell}/*`(排除包 D 文件)。
- 包 F(admin):`lib/features/admin/*`。
- 每包各自负责本目录错误文案收口(E14 分解)与 toast 推广;`lib/widgets/` 仅包 A 可写,其余包只读消费(发现组件缺口回报 PM,不自行加)。
- 时序:包 A 先行;B/C/D/E/F 依赖 A 的组件,第二波并行;测试用例包与 A 同波先行(写用例不依赖组件存在)。
