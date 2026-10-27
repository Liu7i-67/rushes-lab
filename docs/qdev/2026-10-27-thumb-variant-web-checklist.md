# small 缩略图变体 + web 预览渐进式 — web 端手工测试清单(T2)

> 配套需求:`docs/qdev/2026-10-27-thumb-variant-video-cover.md` §3.6(web 契约)+ §6 功能点 11。
> 被测实现:`web/src/components/AssetThumbnail.tsx`、`web/src/hooks/useProgressiveThumb.ts`、
> `web/src/components/AssetPreviewModal.tsx` + `web/src/components/preview/` 下 5 个子组件。
> web 无自动化测试框架,本清单为结构化手测用例;`[devtools]` = Chrome DevTools 可完整验证。
> 契约与实现的偏差/细化见文末「偏差记录」,相关用例按实现实际行为写,勿按旧文档误报。

## 通用准备

- 构建:web 本地 `pnpm dev`(或 dev 栈部署);后端为同分支(thumbnail-url 已支持 `size` + 响应含 `variant`)。
- 账号:① 项目内**有下载权**账号;② 项目内 `my_can_download=false` 账号;③ 系统 admin(看审计)。
- 审计入口:admin 访问 `/admin/audit`,操作类型筛「临时链接签发」(signed_url_issued),按时间倒序核对。
- 素材夹(一个项目内):a) 新生成的普通图片 jpg/png/webp(**small+1024 双产物**,tags 含
  `thumbnail_key`+`thumbnail_small_key`);b) 存量图片(仅 `thumbnail_key`,未派生 small);
  c) 动图 .gif;d) .heic 有缩略图 1 张(+ `.heic` 带 `thumbnail_failed` 标记 1 张,可选);
  e) 无缩略图图片:`.svg` 或缩略图失败图(tags 无 `thumbnail_key`);f) 有封面视频(tags 有
  `thumbnail_key`)+ 无封面视频(tags 无,如 `thumbnail_skipped`);g) pdf / txt / md / livp 各 ≥1;
  图片总量 ≥3 屏(验 lazy)。
- 查 tags:Network 中 assets 列表接口响应 JSON 的 `tags` 字段。
- 规格判别:签名 URL 含 `thumbnails/{id}_s.jpg` = small(240px);`thumbnails/{id}.jpg` = large(1024px);
  响应 `variant` 字段同义。图片实际尺寸:Elements 选中 img 后 Console 执行 `$0.naturalWidth`。
- DevTools 技巧:失败模拟 = Network 面板右键请求 →「Block request URL」(解除:右侧 Blocking 页签);
  勾选 Disable cache 只影响 HTTP 缓存(字节请求),**不影响 react-query 缓存**(签名请求是否重发)。
- 缓存背景:presign 带 `cache_control=max-age=604800`,同一签名 URL 的字节请求第二次起可能显示
  from disk/memory cache(网络面板无字节流量),属预期(B4 卫生项),非缺陷。

## 一、列表图标(功能点 11a:small + lazy + fallback;Table 32px / 卡片 44px / 回收站)

- [ ] **L-01 [devtools]** Table 32px 图标走 small、变体正确
  - 前置:桌面宽度(≥1024,ProjectDetailPage Table 视图);素材 a。
  - 步骤:打开项目页 → Network 过滤 `thumbnail-url` → 点开请求看 URL 与响应(验证方法:Network)。
  - 期望:`GET /api/v1/assets/{id}/thumbnail-url?size=small`;响应 `variant:"small"`、url 含
    `{id}_s.jpg`;图标 32px 清晰渲染,naturalWidth ≤240。
- [ ] **L-02 [devtools]** 卡片 44px 同口径
  - 前置:窗口缩到 <1024(compact)切换为卡片列表(AssetCardList)。
  - 期望:请求同 L-01(size=small、variant 正确、_s.jpg),44px 渲染正常。
- [ ] **L-03** 回收站图标正常
  - 前置:软删 1 张素材 a;项目页点「回收站」打开 FolderTrashModal。
  - 期望:软删行缩略图照常显示(thumbnail-url 对软删行返回 200 不 404);图标 32px。
- [ ] **L-04 [devtools]** 未回补资产变体回落 large(列表侧)
  - 前置:素材 b(仅 1024)。
  - 期望:`?size=small` 响应 `variant:"large"`、url 含 `{id}.jpg`(无 `_s`);图标显示 1024 图缩至
    32/44px;**不**发第二次补偿请求(无 size=large)。
- [ ] **L-05 [devtools]** 滚动 lazy 生效;签 URL 请求随挂载全量发出(预期内)
  - 前置:Network 勾 Disable cache;图片 ≥3 屏。
  - 步骤:打开项目页静止不动 → 缓慢向下滚动,观察 Img 过滤下 `_s.jpg` 字节请求的出现时机。
  - 期望:打开瞬间 `thumbnail-url` **签名请求全量发出**(所有行挂载即签,antd Table 不虚拟化,
    预期内);字节请求仅视口附近出现,随滚动陆续增加(lazy 生效)。
- [ ] **L-06 [devtools]** fallback 图标路径(无 key / 字节失败)
  - 步骤:① 素材 e(无 key):不发 thumbnail-url 请求(query enabled=false),显示文件图标;
    ② Block 素材 a 的 `_s.jpg` 字节 URL → 刷新 → 签名成功但字节失败 → img onError。
  - 期望:两种情况均回落 FileText 文件图标,布局无跳动;②之后该行不再重试(retry:false)。

## 二、预览-渐进(功能点 11b;useProgressiveThumb + PreviewImage)

- [ ] **P-01 [devtools]** 渐进链路端到端:首帧 small → onload 后 large 替换(两次签名+两次字节)
  - 前置:Network 勾 Disable cache;素材 a;关闭预览状态。
  - 步骤:点开素材 a 预览 → Network 看 `thumbnail-url` 签名与 Img 字节的种类/顺序 → Elements 看
    img src 变化(验证方法:Network + Elements)。
  - 期望:签名 ≤2 次 —— `size=small` ×1(若列表 25min 内已签过则 0 次,react-query 命中,见 P-02)
    + `size=large` ×1;字节 2 次:`{id}_s.jpg` 先、`{id}.jpg` 后(waterfall 上 small 字节完成先于
    large);首帧为 240px 模糊图,onload 后 src 换成 1024 清晰图。large 签名可能先于首帧渲染出现
    (small 响应后即发,见偏差记录 1),属预期。
- [ ] **P-02 [devtools]** 从列表点入 25min 内首拍零**新 small 签名**(react-query 缓存命中)
  - 前置:列表已展示素材 a 图标(其 small 签名 25min 内已发)。
  - 期望:打开预览时 Network **无新的 size=small 请求**;仅 `size=large` ×1(variant=small 时);
    首帧仍 small(字节可能 from disk cache),无长时间 Spin。
- [ ] **P-03 [devtools]** 25min 内二次打开 = 零新签名
  - 前置:P-01 刚做完(≤25min),关闭预览再重开同一资产。
  - 期望:Network 无任何 thumbnail-url 请求(small+large 全命中);图片瞬开;
    若字节未禁缓存也可能无字节流量(disk cache)。
- [ ] **P-04 [devtools]** 列表导航连切不串图
  - 步骤:打开任一图片预览,用 title 区 ‹ › / 键盘 ←→ 快速连续切换多张图片。
  - 期望:每张显示内容与 title 文件名一致,无跨 asset 串图(渲染期重置 + generation 守卫);
    切到 GIF/heic/pdf 等非渐进 kind 再切回图片,亦无串图。

## 三、预览-回落短路(功能点 11b:variant=large 不发 large 请求)

- [ ] **S-01 [devtools]** 未回补资产预览短路
  - 前置:素材 b(variant=large);Disable cache 开启。
  - 步骤:打开预览,数 `thumbnail-url` 请求(验证方法:Network)。
  - 期望:**仅 1 次** `?size=small`(响应 `variant:"large"`),**无 size=large 请求**;图片直接显示
    1024 版,无二次替换;压缩图提示仍显示(1024 亦为压缩图),「查看原图」按钮正常显示。

## 四、预览-兜底(功能点 11:无缩略图回落 / small 失败回落)

- [ ] **F-01** 无 thumbnail_key → 原图(download-link)+ 审计
  - 前置:素材 e(.svg 或失败图);admin 可看审计。
  - 步骤:打开预览 → Network + `/admin/audit`(筛「临时链接签发」)。
  - 期望:Network 仅 `POST download-link` ×1,显示原图;审计页出现该资产的 signed_url_issued
    (维持改造前行为);无压缩图提示、无「查看原图」按钮。
- [ ] **F-02 [devtools]** small **签名**请求失败 → 自动回落原图(+审计)
  - 前置:素材 a 未在 25min 内签过(或刚刷新);Block 含 `thumbnail-url` 的请求 URL。
  - 步骤:打开预览 → 观察回落 → 解除 Block。
  - 期望:small 请求失败(红)→ 自动 `POST download-link` → 显示原图;审计出现 signed_url_issued;
    压缩图提示与「查看原图」按钮消失;无白屏无 crash。
- [ ] **F-03 [devtools]** small **字节**加载失败 → 自动回落原图
  - 前置:Block `*_s.jpg` 字节 URL(签名放行)。
  - 步骤:打开素材 a 预览 → 观察 → 解除 Block。
  - 期望:签名成功但 img onError → 自动 POST download-link 回落原图;提示/按钮消失
    (showingOriginal);网络恢复后本次会话内不自动切回缩略图(回落即终态,切张/重开才复位)。
- [ ] **F-04 [devtools]** 无下载权 + 回落请求 403
  - 前置:账号②;Block `thumbnail-url`。
  - 期望:打开预览 → 回落 download-link 403 → 出现错误 toast,页面不出图亦不 crash
    (记录实测文案;回落路径 403 走通用 errorMessage,无查看原图专属文案,属实现细节)。

## 五、GIF carve-out(功能点 11:GIF 维持原图可播动画 + 审计)

- [ ] **G-01** .gif 预览原图动画 + 签发审计存在
  - 前置:素材 c(动图);Network 开启;审计页可看。
  - 步骤:打开预览 → 观察动画与 footer → Network + 审计页核对。
  - 期望:`POST download-link` ×1,无 thumbnail-url 渐进请求;**动画正常播放**(帧在动);
    审计页出现 signed_url_issued;footer 无「查看原图」按钮、无压缩图提示;
    (对照:列表中该 GIF 图标仍为静态 small 缩略图,列表/预览差异属设计)。

## 六、heic(功能点 11:缩略图 + 失败卡,无查看原图按钮)

- [ ] **H-01** heic 有缩略图:服务端转码图,无查看原图按钮
  - 前置:素材 d(有 key 的 heic)。
  - 期望:显示服务端转码 JPEG(≤1024);Network 为 `thumbnail-url`(**无 size 参数**,默认 large,
    分支不动)+ 字节;下方文案「HEIC 预览为服务端压缩图(≤1024px),下载可获取原片。」;
    footer **无**「查看原图」按钮;缩略图本身无审计。
- [ ] **H-02** heic 失败卡
  - 前置:① tags 含 `thumbnail_failed` 的 heic;② 无 key 无标记的 heic(如刚上传未生成)。
  - 期望:① 显示失败卡(原因标记 + 「下载原片」按钮,点击走 download-link 并审计);
    ② 显示「还在生成(或生成失败),请稍后刷新重试」提示卡。

## 七、查看原图按钮(功能点 11:显式出口 + 审计 + 权限)

- [ ] **V-01** 显示条件矩阵(仅「非 GIF image kind 且有 thumbnail_key」)
  - 步骤:逐一打开:素材 a / 素材 b → 素材 c(gif)→ 素材 e(无 key)→ 素材 d(heic)→ video/pdf/livp。
  - 期望:仅素材 a、b 的 footer 出现「查看原图」(且未显原图时);其余全部不显示。
- [ ] **V-02 [devtools]** 点击行为:download-link + 审计 + 换原图 + 提示/按钮消失
  - 前置:素材 a 预览已打开(渐进缩略图显示中);Network + 审计页就绪。
  - 步骤:点「查看原图」→ Network / `/admin/audit` / Elements img src 三处核对。
  - 期望:`POST download-link` ×1(独立 mutation,按钮自身转圈,不影响「下载」按钮);
    审计页立即出现 signed_url_issued;img src 换为 download-link URL(显示原图);
    压缩图提示消失、「查看原图」按钮消失。
- [ ] **V-03 [devtools]** 无 can_download 权限:禁用 + 403 双保险
  - 前置:账号②打开素材 a 预览。
  - 期望:「查看原图」与「下载」均禁用;tooltip 仅在「下载」上有申请入口指引(查看原图无 tooltip,
    属实现细节)。双保险:权限中途被收回时点击 → `download-link` 403 → toast
    「无下载权限,请联系项目管理员」,不出图。

## 八、video(功能点 11:poster;Range 行为不变)

- [ ] **D-01 [devtools]** 有封面视频:poster 生效
  - 前置:素材 f-有封面(tags 有 thumbnail_key);Network + Elements。
  - 期望:Elements 中 `<video poster=...>` 有值(签名 URL 含 `thumbnails/{id}.jpg`,无 `_s`);
    Network 有 `thumbnail-url?size=large` ×1;播放前显示封面帧而非黑帧;`src` 仍为 download-link
    (video 分支 src 不变,审计照旧)。
- [ ] **D-02** 无封面视频:无 poster 黑帧
  - 前置:素材 f-无封面。
  - 期望:`<video>` 无 poster(黑帧);无 thumbnail-url 请求;播放功能本身正常。
- [ ] **D-03 [devtools]** 播放 Range 行为不变
  - 步骤:打开有封面视频 → 播放并拖动进度条,观察 Network 中视频字节请求。
  - 期望:对 download-link URL 的字节请求带 `Range` 请求头、响应 `206 Partial Content`,
    可播可 seek(与改造前一致)。

## 九、审计口径(任务书第 9 条:常规图片预览打开无 signed_url_issued)

- [ ] **A-01 [devtools]** 渐进预览打开不产生审计
  - 前置:素材 a;admin 记下审计页当前最新条目时间。
  - 步骤:打开素材 a 预览(渐进链路,不点查看原图)→ 刷新 `/admin/audit`(筛「临时链接签发」)。
  - 期望:无该资产的新 signed_url_issued(缩略图端点不审计,契约「审计不变」);Network 侧亦无
    download-link 请求。
- [ ] **A-02** 对照组:查看原图立即产生审计
  - 步骤:同一预览内点「查看原图」→ 刷新审计页。
  - 期望:立即出现 1 条该资产 signed_url_issued(证明 A-01 的「无」是口径设计而非漏记)。

## 十、压缩图提示文案(任务书第 10 条)

- [ ] **C-01** 提示可见
  - 前置:素材 a / b 渐进预览显示中。
  - 期望:图片下方显示「预览为压缩图(≤1024px),下载可获取原片。」(variant=large 的素材 b 亦显示)。
- [ ] **C-02** 显示原图后提示消失
  - 步骤:在 C-01 基础上点「查看原图」;另按 F-02/F-03 触发一次失败回落。
  - 期望:两条路径(显式按钮 / 失败回落)下提示均消失;关闭重开后(重新渐进)提示恢复。

## 十一、回归(任务书第 11 条:非 image 分支与下载不受影响)

- [ ] **R-01** pdf 预览一致
  - 期望:桌面 iframe 原生 viewer 可滚动翻页;仍 `POST download-link`;iOS 真机(可选)降级提示卡。
- [ ] **R-02** text / md 预览一致
  - 期望:txt 纯文本内联、md 渲染格式化(含表格等 GFM);Network 为 download-link + 字节 fetch。
- [ ] **R-03** livp 预览一致
  - 期望:静态图走 thumbnail-url(无 size 参数)+「播放实况」可播(live-preview-url);
    实况播放中 ‹ › 切到另一 livp 再切回,无实况串图;「下载源文件」按钮仍在。
- [ ] **R-04** 下载按钮 / 下载源文件 / unsupported 卡不受影响
  - 期望:各 kind 点「下载」均触发浏览器下载(download-link 审计照旧);livp 默认下载 = 解包 zip、
    次选项 = 原始 .livp;账号②下载禁用 + tooltip 指引;unsupported 文件仍显示占位卡。

## 实现与契约的偏差/细化记录(按实现测,无阻断性偏差)

1. **large 签名请求时机**:契约「后台 fetchQuery large 并在 onload 后替换 src」——实现为 small
   响应返回后即发 large fetchQuery(不等 img onload),`<img>` 的 src 替换确在 onload 后
   (PreviewImage loaded 门)。Network 上 large 签名可能早于首帧渲染出现,属契约「后台」的读法。
2. **查看原图按钮**:契约只定显示条件;实现额外在「已显示原图(点击后/失败回落)」时隐藏按钮,
   且无下载权时禁用 + 403 toast 双保险(任务书已认可)。
3. **字节失败回落范围**:契约「有 key 但 URL 失败 → onError 回落原图」未区分阶段;实现中
   large 阶段字节失败同样回落原图(P-01 后 Blocked large 亦可验),实现更稳。
4. **审计口径边界**:thumbnail-url(单发/批量)无审计(契约「两端点审计不变」沿用),故列表图标、
   渐进预览、video poster 均不产生 signed_url_issued;「常规图片预览无审计」仅指渐进链路 ——
   GIF / 无 key 图片 / heic 失败卡下载等 download-link 路径照旧审计(G-01/F-01/V-02)。
5. **分支不动项核实**:livp / heic 的 thumbnail-url 不带 `size`(默认 large)、pdf/text/livp/heic
   分支渲染不变、video poster 固定 `size=large` —— 与契约 §3.6.7 一致;web 渐进仅覆盖
   image kind(非 GIF 非 heic)且 hasThumbKey,与 §3.6 前置一致。
6. **缓存连带效应**:presign cache_control(后端 §3.3)使同一签名 URL 二次访问可能零字节流量
   (disk cache),Network 验证时注意区分「react-query 命中(签名不发)」与「HTTP 缓存命中(字节不发)」。

## 功能点映射(任务书 11 条 → 用例)

1 列表 → L-01~L-06;2 预览渐进 → P-01~P-04;3 回落短路 → S-01;4 兜底 → F-01~F-04;
5 GIF → G-01;6 heic → H-01~H-02;7 查看原图 → V-01~V-03;8 video → D-01~D-03;
9 审计口径 → A-01~A-02;10 提示文案 → C-01~C-02;11 回归 → R-01~R-04;
(§6 功能点 11 逐项:small+lazy=L-05、渐进=P-01、短路=S-01、GIF=G-01、heic 卡=H-02、
查看原图审计=V-02/A-02、poster=D-01、无缩略图回落=F-01~F-03)
