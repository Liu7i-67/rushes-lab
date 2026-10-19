# 四项前端体验优化 — A/B/D(含 C 前端)手工测试用例清单

> 配套需求:`docs/qdev/2026-10-19-inapp-ux-enrichment.md`;实施细则正本:
> `rushes-spec/material-storage/inapp-browser-tip-preview-nav-audit-enrichment-plan.md`
> §1.4(A)/ §2.3(B)/ §3.3(C)/ §4.3(D)。
> C 包**后端**可执行用例另见 `material-storage/api/tests/test_audit_detail_names.py`
> (14 条 pytest);本清单覆盖 A1-A5 / D1-D3 / B1-B8 的手工验收 + C4 前端渲染补充。
>
> **执行标注约定**
> - `[devtools]`:Chrome devtools 可完整模拟(UA 覆写:Network conditions → User agent
>   自定义;宽度:设备工具栏 / 响应式模式;响应改写:Local overrides / 拦截)。
> - `[真机]`:必须真机验证(UA / webview 行为 / 触控 / 键盘,devtools 不可替代)。
> - `[devtools+真机]`:devtools 过一遍逻辑,交验前至少一台真机抽验。
> - 每条用例左上的复选框供执行时勾选。

## 通用准备

- 分支:`feat/inapp-ux-enrichment` 构建产物(本地 `pnpm build` 或部署到 dev 栈)。
- 账号:① 系统 admin 或项目内**有下载权**账号;② 项目内**无下载权**
  (`my_can_download === false`)账号;③ 零权限 outsider(403 路径)。
- 素材项目:一个含 ≥6 条素材的文件夹(Folder 页)与 ≥6 条素材的项目(Project 页),
  kind 覆盖:`image/*`、`video/mp4`、`pdf`、`md`、`text`、`heic`、`livp`、`zip`(unsupported)。
  livp 至少 2 条(A、C 两条,验串实况)。
- 参考层级常量:header `--ms-z-header:50` < inapp 横幅 `--ms-z-inapp-tip:55` <
  批量栏 `--ms-z-batchbar:60` < antd Modal(1000+)。
- 可复用 UA 串(devtools 粘贴用):
  - 微信 iOS:`Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.49(0x18003123) NetType/WIFI Language/zh_CN`
  - 企业微信 iOS:`Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 wxwork/4.1.12 MicroMessenger/8.0.31 NetType/WIFI`
  - 抖音 Android:`Mozilla/5.0 (Linux; Android 14; V2303A Build/UP1A.231005.007; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/116.0.0.0 Mobile Safari/537.36 aweme_270958 JsSdk/2.0 NetType/WIFI`
  - 手机 QQ Android:`Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/116.0.0.0 Mobile Safari/537.36 V1_AND_SQ_8.9.83 QQ/8.9.83`
  - 钉钉 Android:`Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36 DingTalk/7.6.0`
  - 微博 iOS:`Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Weibo/14.6.0 __weibo__`
  - PC 微信(Windows):`Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 MicroMessenger/7.0.20.1781`
    (注意:无 `Mobile`/`Android`/`iPhone` token → isMobile=false,预期**不弹**)

---

## A 包:内置浏览器检测提示(A1-A5,正本 §1.4)

- [ ] **A-01 [devtools]** 微信 UA 归因 + 横幅出现
  - 前置:devtools UA 覆写为上方「微信 iOS」串;清空 sessionStorage。
  - 步骤:打开任一常规路由(如 `/folders/...`),刷新。
  - 期望:顶部出现 warning Alert 横幅;标题含「微信」appName;含「复制链接」「关闭」操作;
    横幅 top=56px(贴 header 下沿),header 本身仍可见。
- [ ] **A-02 [devtools]** 企业微信 UA 归因(不被吞成微信)
  - 前置:UA 覆写为「企业微信 iOS」串(同时含 wxwork 与 MicroMessenger);清 sessionStorage。
  - 期望:横幅出现且 appName 为「企业微信」,不是「微信」(补充表优先于 inapp-spy 归因)。
- [ ] **A-03 [devtools]** 抖音 UA 归因
  - 前置:UA 覆写为「抖音 Android」串(aweme token);清 sessionStorage。
  - 期望:横幅出现,appName 为「抖音」;引导文案为 Android 版(「在浏览器打开」措辞)。
- [ ] **A-04 [devtools]** 补充表其余三家:QQ / 钉钉 / 微博
  - 步骤:分别覆写三条 UA,各刷新一次(每次先清 sessionStorage)。
  - 期望:三例均弹横幅,appName 分别为「QQ」「钉钉」「微博」。
- [ ] **A-05 [devtools,边界观察]** 未收录 token 的 webview
  - 步骤:UA 覆写为普通 Android WebView 串(`; wv)`,不含任何已收录 token)。
  - 期望:按 inapp-spy 判定为准 —— 若判为内置,appName 回落「内置浏览器」;
    若判为非内置则不弹。两种行为均可接受,记录实测结果即可(勿报缺陷)。
- [ ] **A-06 [devtools]** PC / 普通浏览器不弹(D-A2)
  - 步骤:① 默认桌面 Chrome UA;② 桌面 Safari UA;③ 上方「PC 微信」串(含 MicroMessenger
    但非 mobile)。各刷新。
  - 期望:三例均**不出现横幅**(PC 端引导「用手机浏览器打开」无意义)。
- [ ] **A-07 [devtools]** 关闭持久化 = 当次会话(D-A4)
  - 步骤:① 弹出后点「关闭」;② Application 面板查 sessionStorage 应有
    `ms-inapp-tip-dismissed='1'`;③ 同标签页切路由(登录页↔文件夹页)再刷新 → 不再弹;
    ④ 新开标签页(同源)→ 重新弹。
  - 期望:②③④ 全部符合;localStorage 无残留(静默周期仅会话级)。
- [ ] **A-08 [devtools+真机]** 分享落地页覆盖(highest-priority 场景)
  - 步骤:① devtools 微信 UA 下打开 `/s/:token`;② 真机微信内直接打开同一分享链接。
  - 期望:横幅在分享页出现(该路由在壳内、header 常驻 → top=56px);「复制链接」复制的是
    当前分享页完整 URL(含 `/ms-static/web` 前缀原样)。
- [ ] **A-09 [devtools]** 层叠:横幅不挡 header 交互
  - 步骤:横幅显示期间,依次点击 header 的汉堡菜单 / 搜索 / 头像下拉。
  - 期望:三个入口全部可正常点击、下拉正常展开(z-index 55 悬浮于内容之上、
    不覆盖 header 50 的点击区;fixed 悬浮遮住的内容顶部一条约 44px 属预期取舍)。
- [ ] **A-10 [devtools]** 层叠:横幅在 antd Modal 之下(边界补充)
  - 步骤:横幅显示期间,打开任意操作弹窗(如目录重命名 Modal)。
  - 期望:Modal 正常居中且完整可交互,横幅**不**盖在 Modal 遮罩/内容之上
    (55 ≪ 1000+);关闭 Modal 后横幅仍在原位。
- [ ] **A-11 [devtools]** 无 header 路由贴顶不盖登录卡
  - 步骤:微信 UA 下分别打开 `/login`、`/change-password`(`/dev-login` 如启用也过一遍)。
  - 期望:横幅出现且 top=12px(贴视口顶,无 56px 悬空),不遮住登录卡/表单可交互区。
- [ ] **A-12 [真机]** 微信内「复制链接」真实链路(§1.4-6 回归)
  - 步骤:真机微信打开站点 → 点横幅「复制链接」→ 粘贴到 Safari 地址栏访问。
  - 期望:无成功 toast 报错;粘贴出的 URL 可直接打开(验证 `copyToClipboard`
    在 HTTP 非安全上下文走 execCommand 降级路径)。
- [ ] **A-13 [真机]** 三家点名 App 真机回归(验收口径 §7)
  - 步骤:微信 / 企业微信 / 抖音真机各:① 开一次分享链接;② 开一次登录页。
  - 期望:6 个场景横幅均出现、appName 归因正确、复制链接可用;系统 Safari/Chrome
    打开同链接无横幅。
- [ ] **A-14 [真机]** iOS / Android 引导文案区分
  - 步骤:同一 App(如微信)iPhone 与 Android 各开一次,对比横幅引导行文案。
  - 期望:iOS 文案含「Safari」措辞,Android 文案含「在浏览器打开」措辞
    (以实施定稿文案为准;真机核对后允许微调,属低风险纯文案)。
- [ ] **A-15 [devtools,低优先]** 复制失败降级提示
  - 步骤:devtools 拦截/stub `navigator.clipboard` 与 `document.execCommand` 均抛错
    (或代码走查),点「复制链接」。
  - 期望:弹 `message.warning('复制失败,请长按地址栏手动复制')`,横幅不消失、无 JS 报错。
- [ ] **A-16 [devtools,边界观察]** 横幅与 MaintenanceBanner 同现
  - 步骤:若 dev 栈可注入维护标记,使维护横幅与 inapp 横幅同现。
  - 期望:两横幅不重叠、互不遮关键信息(记录实测;若重叠拍截图交开发定位)。

## D 包:移动端批量操作栏两行布局(D1-D3,正本 §4.3)

- [ ] **D-01 [devtools+真机]** 320px(iPhone SE 最小口径)全部按钮可见可点
  - 前置:ProjectDetailPage 移动端视口(<1024),项目内有素材;真机用 SE 或 320px 模拟。
  - 步骤:勾选 ≥1 条素材,观察批量栏。
  - 期望:行1「已选 N」+「清空选择」;行2 打标/前缀/移动/删除 4 按钮 **2×2 等宽网格**
    (测试轮 P1-2 修复:antd Button min-content ≈85px,4 列在 320/375px 最小需 364px 必溢出
    被裁,改 repeat(2,1fr) 每列 ≥132px 全宽安全;正本 §4.2 D3 扩展约定允许的变体);
    无横向裁剪、无横向滚动条;每按钮高 44px。
- [ ] **D-02 [devtools+真机]** 375px 主流口径
  - 步骤:375px 视口重复 D-01。
  - 期望:同 D-01;4 按钮 2×2 等宽,icon+文字不换行不省略,每列 ≈159px 富余。
- [ ] **D-03 [devtools]** 414 / 430px 富余宽度
  - 步骤:两种宽度各看一次批量栏。
  - 期望:两行结构不变,按钮等宽拉伸不变形;不出现单行回退。
- [ ] **D-04 [devtools]** 列表底部不被 sticky 栏盖(D2)
  - 步骤:勾选态滚动到素材列表最后一条。
  - 期望:末尾卡片完整可见可点,不被批量栏遮住(paddingBottom ≈132 生效;
    未选态底部间距恢复小间距 ≈12)。
- [ ] **D-05 [真机]** 键盘弹起隐藏与两行布局共存
  - 步骤:勾选态下聚焦页面搜索/输入框使软键盘弹起 → 观察批量栏;收起键盘再观察。
  - 期望:键盘弹起时整栏隐藏(kbVisible 逻辑不变);收起后恢复两行布局,选择状态保持。
- [ ] **D-06 [devtools]** 未选态无批量栏
  - 步骤:清空所有勾选。
  - 期望:批量栏整体消失,列表底部 padding 回落。
- [ ] **D-07 [devtools]** 「清空选择」text 弱化按钮可用
  - 步骤:点行1「清空选择」。
  - 期望:按钮为 text 型(视觉弱于行2 主操作);点击后全部勾选清空、批量栏消失。
- [ ] **D-08 [devtools]** Popconfirm 在两行栏上的定位(§4.3-5)
  - 步骤:点行2「删除」。
  - 期望:确认气泡出现在批量栏上方,不被裁剪、不出屏;确认/取消均正常;
    移动端气泡箭头指向删除按钮。
- [ ] **D-09 [devtools]** 四按钮功能回归(§4.3-4)
  - 步骤:打标 / 前缀 / 移动 / 删除各走一遍成功路径(小数据量)。
  - 期望:功能与重构前语义一致:弹窗/输入、成功 toast、列表刷新、勾选清空。
- [ ] **D-10 [devtools]** 跨页保留选中回归
  - 步骤:第 1 页勾选 2 条 → 翻到第 2 页再勾选 → 翻回第 1 页;中途观察行1「已选 N」计数。
  - 期望:跨页选中保持(W6 语义不回潮);计数含两页勾选总数。
- [ ] **D-11 [devtools]** PC(≥1024)零变化
  - 步骤:1024/1440 宽打开同项目页,勾选素材。
  - 期望:顶部 ActionsBar 原样,无两行批量栏出现(D1 明确 PC 分支与 FolderDetailPage 零变化)。
- [ ] **D-12 [devtools]** FolderDetailPage 无批量栏
  - 步骤:移动端视口打开文件夹详情页,尝试多选。
  - 期望:无批量栏(FolderDetailPage 是纯浏览页),列表浏览/下载入口不受影响。
- [ ] **D-13 [真机]** 真机单手触达与误触
  - 步骤:320/375px 真机各勾选后单手点击行2 四按钮。
  - 期望:无相邻按钮误触;批量下载**不**入栏(既定决策,出现即报回潮缺陷)。
- [ ] **D-14 [devtools,边界观察]** 批量栏与预览弹窗层叠(B×D 同页交叉)
  - 步骤:勾选态(批量栏在)打开素材预览 Modal。
  - 期望:Modal 盖过批量栏(60 ≪ 1000+),关闭后批量栏原位恢复;批量栏不被 Modal
    遮罩「顶出」或错位。

## B 包:预览弹窗导航下载(B1-B8,正本 §2.3)

- [ ] **B-01 [devtools]** 文件夹页入口:导航条计数与文件名
  - 前置:FolderDetailPage 文件夹内 ≥3 条可预览素材。
  - 步骤:选中一条(非首条)素材 → 预览。
  - 期望:Modal title 区出现 ‹ `n / N` ›(ms-mono)与文件名(省略);n 为当前素材在
    页内列表中的序号(与 Drawer 标题同口径)。
- [ ] **B-02 [devtools]** 边界禁用
  - 步骤:① 翻到第 1 条;② 翻到页内最后一条。
  - 期望:① ‹ 禁用;② › 禁用(不跨分页,页边界即停 —— 与 Drawer 翻页同语义)。
- [ ] **B-03 [devtools]** 切到 unsupported:modal 不消失(挂载改造钉子,必验)
  - 步骤:从可预览素材 › 翻到一条 `.zip`(unsupported)。
  - 期望:Modal **保持打开**,渲染 unsupported 卡;title 文件名同步变化;
    footer 下载按钮仍可见可点。Modal 整体闪没 = B3 钉子缺陷。
- [ ] **B-04 [devtools]** kind 轮播逐一重载
  - 步骤:构造 image → md → pdf → text → heic → livp → zip 相邻序列,连续 › 翻页。
  - 期望:每种 kind 内容正确渲染/降级卡正确,前一文件内容不残留;heic / livp 失败卡
    正常出现。
- [ ] **B-05 [devtools]** livp 播放态切走再切回不残留(切换重置钉子)
  - 步骤:livp A 播放实况中 → › 到下一张 → ‹ 切回 A。
  - 期望:切回后 A 从头进入正常预览态(无自动播放残留、无上一次的实况视频直贴)。
- [ ] **B-06 [devtools]** livp A → livp C 不串实况(最重边界,必验)
  - 步骤:两条 livp(A、C);A 播放实况视频的过程中直接 › 切到 C。
  - 期望:C 显示 C 自己的实况(或正常加载态),**不得**出现 A 的实况画面
    (`playingLive/liveUrl` 残留串渲染;§2.3-3 显式用例)。
- [ ] **B-07 [devtools]** 键盘 ← / → 与 Esc
  - 步骤:预览打开(list>1)按 → / ← 各数次;再按 Esc。
  - 期望:→/‹ 同步翻页、计数联动;到边界键再按无反应无报错;Esc 关闭 Modal(antd 自带)。
- [ ] **B-08 [devtools]** 键盘 ←/→ 在 video 焦点时不误触(B6)
  - 步骤:livp/video 播放态(焦点位于 `<video>` 元素,可点击视频后按键盘)按 ←/→。
  - 期望:不触发弹窗翻页(video 自身键位/行为优先,e.target=video 被忽略);
    焦点在 body 时按 ←/→ 仍翻页。
- [ ] **B-09 [devtools]** footer 下载正常链路(B5)
  - 步骤:有下载权账号,正常 image 预览态点 footer「下载」。
  - 期望:按钮 loading 态(dlLink.isPending)→ 浮窗进度出现 → 下载完成;
    footer 在所有 kind(含 unsupported 卡)下常驻。
- [ ] **B-10 [devtools]** 下载 403 兜底
  - 步骤:对一条中途被回收权限的素材(或用 outsider 会话直接调)在 footer 点下载。
  - 期望:`message.warning('无下载权限,请联系项目管理员')`(与降级卡同文案),无未处理异常。
- [ ] **B-11 [devtools+真机]** 无下载权账号:footer 禁用 + tooltip 指引
  - 前置:账号②(`my_can_download === false`)。
  - 步骤:打开预览,悬停/长按 footer 下载按钮。
  - 期望:按钮**禁用**态(点击无任何请求发出);tooltip 显示「无下载权限,可在文件面板点
    『申请下载』」—— disabled Button 不触发 hover,tooltip 必须 Tooltip 包裹后仍可见
    (devtools 悬停 + 真机长按各验一次)。
- [ ] **B-12 [devtools]** unsupported 卡内下载按钮不动
  - 步骤:zip 素材预览,分别用卡内下载按钮与 footer 下载各点一次。
  - 期望:两个入口均可用、走同一 handleDownload;降级卡(heic/livp 失败卡)内按钮原样。
- [ ] **B-13 [devtools]** 项目页入口同构(B8)
  - 步骤:ProjectDetailPage 单文件 Drawer 开预览,重复 B-01/B-02/B-07。
  - 期望:list=assetItems,计数/边界/键盘与文件夹页一致。
- [ ] **B-14 [devtools]** 搜索页入口:?focus= URL 联动(B8,参数名 focus 非 asset)
  - 步骤:SearchPage 搜出 ≥3 条 → 开 focus Drawer → 预览 → 按 ›。
  - 期望:翻页后 URL 变为 `?q=...&focus=<新id>`(replace,不留 history 记录 — 回退键
    退出页面而非上一张);刷新页面定位到同一文件。
- [ ] **B-15 [devtools]** Drawer 翻页与 modal 翻页同 state 同步
  - 步骤:文件夹页 Drawer 标题用 ‹ n/N › 翻 2 次 → 开预览看计数;再在 modal 内翻 2 次 →
    关闭 modal 看 Drawer 标题。
  - 期望:两处显示同一 n / N,互相同步(同一 detailIndex state)。
- [ ] **B-16 [devtools]** PC 三栏右栏:无导航条是预期(勿误报)
  - 步骤:PC 视口 ProjectDetailPage 三栏右栏单选素材 → 预览。
  - 期望:**无** ‹ n/N › 导航条(明确不做);footer 下载仍生效。报「右栏无翻页」= 误报。
- [ ] **B-17 [devtools]** 多选态 / 空选态面板回归(B 回归口径)
  - 步骤:项目页分别处于多选(≥2)与空选状态,检查面板与预览入口。
  - 期望:多选/空选面板无预览入口、渲染不受影响;单选预览入口仍受 isPreviewable 门控
    (unsupported 素材不出现「预览」QuickAction)。
- [ ] **B-18 [devtools]** 预览关闭后 Drawer 翻页仍正常
  - 步骤:modal 内翻到第 k 条 → Esc 关闭 → Drawer 标题 ‹ › 翻页。
  - 期望:Drawer 从第 k 条继续翻页正常;重新打开预览从当前 asset 开始。
- [ ] **B-19 [真机]** compact 小屏不破版(§2.3-6)
  - 步骤:375px(及 320px)真机/模拟开预览,选一条超长文件名素材。
  - 期望:导航条 + footer 均不溢出;长文件名省略号截断;footer 按钮完整可点。
- [ ] **B-20 [devtools]** 单 asset 旧调用兼容(B1 向后兼容)
  - 步骤:走不传 list 的预览路径(PC 右栏),观察行为。
  - 期望:无导航条、无键盘 ←/→ 响应、无控制台报错;footer 下载在 —— 现行为不回退。
- [ ] **B-21 [devtools]** 快速连按 › 竞态无串图
  - 步骤:大图素材上快速连按 → 多次。
  - 期望:最终停在最后到达的素材且内容与文件名一致;loading 态盖住中间请求,
    无前一张内容闪回错乱。
- [ ] **B-22 [devtools,防御分支观察]** SearchPage focus 未命中不炸
  - 步骤:手改 URL 为 `?q=...&focus=<不存在的id>`。
  - 期望:Drawer 不开、无 JS 报错(findIndex=-1 防御分支;§2.4 正常交互不可达,仅回归确认)。

## C 包前端:审计展开详情结构化渲染(C4,正本 §3.3-4/5/6;后端 14 条 pytest 已覆盖补名契约)

- [ ] **C-UI-01 [devtools]** 展开态结构化键值 + id/名称并列
  - 前置:admin 账号;系统内已有 folder_grant_added / project_member_added 等事件
    (可在测试环境做一次真实授权/成员操作生成)。
  - 步骤:审计页展开一条 grant 类事件。
  - 期望:details 不再是整块 JSON dump,而是键值列表;folder_id 行显示
    `目录名 (uuid 前 8 位…)` 形式(id 和名称都给);subject 行显示 `名称(UUID前8…)` 并带
    类型标注 `user:` →「(用户)」、`group:` →「(用户组)」(前端从原始串前缀取)。
- [ ] **C-UI-02 [devtools]** 对象数组不打 [object Object](正本 §3.3-1 显式项)
  - 步骤:编辑一个用户的所属组(产生 user_updated,changes.groups_added 为对象数组)
    → 展开该事件。
  - 期望:groups_added 逐字段展开(group_id/group_name 各自成行)或回落可读 JSON,
    页面**不出现** `[object Object]` 字样。
- [ ] **C-UI-03 [devtools]** 标量类型渲染矩阵
  - 步骤:找/造含布尔(details 如 requires_login / target_auto_created)、null、
    ISO 时间(expires_at)、标量数组、未知键的事件并展开。
  - 期望:布尔 → 是/否;null → —;ISO 时间 → 本地 locale 格式;标量数组 → 逐项 join;
    未知键 → 键名回落原样、值原样。
- [ ] **C-UI-04 [devtools]** raw JSON 调试兜底仍在
  - 步骤:展开任一事件,找 raw JSON 折叠区(`<details>`)并展开。
  - 期望:完整原始 details JSON 可查(与结构化列表内容一致)。
- [ ] **C-UI-05 [devtools]** actor_user_id / user_agent / event_time 补展示
  - 步骤:展开一条新事件与一条历史飞书事件(actor_open_id_snapshot 非空的存量行)。
  - 期望:新事件显示 actor_user_id,不再显示误导性 actor: {open_id};
    user_agent 行仅在有值时出现,超 120 字符截断且 title 悬浮可见完整值;
    event_time 为完整绝对时间(非只有 Tooltip)。
- [ ] **C-UI-06 [devtools]** 旧响应缓存回落(正本 §3.3-4)
  - 步骤:devtools 拦截 `/api/v1/admin/audit` 响应,删除某行的 resolved_names /
    user_agent 字段后放行 → 展开该行。
  - 期望:回落裸 UUID/现行为展示,不报错、不出现 undefined 字样(向后兼容)。
- [ ] **C-UI-07 [devtools]** 回归:收起态 / 过滤 / CSV 导出 / 分页(正本 §3.3-6)
  - 步骤:① 收起态元信息行照旧;② 事件类型/项目/操作者/日期过滤各一次;
    ③ CSV 导出打开核对;④ 翻页。
  - 期望:全部与改动前行为一致;CSV **不含** resolved_names / user_agent 新列(D-C1)。

---

## 执行顺序建议

1. C 包 pytest(容器内,`test_audit_detail_names.py`)先行锁后端契约;
2. A 包 devtools 串(A-01~A-11)→ D 包 devtools 串 → B 包 devtools 串(三包互不依赖);
3. 真机轮(A-08/A-12/A-13/A-14、D-01/D-02/D-05/D-13、B-11/B-19)集中一次过;
4. 回归收尾:C-UI-07、B-17/B-18、D-10/D-11。
