# 安卓实况图(Motion Photo)适配(方案 + qdev 执行稿)

> 2026-11-02 撰写,基于 flutter_live_motion 0.1.0 源码级调研 + App 全链路现状核实。
> 目标(用户三条预期):
> ① 支持实况图的安卓机上,下载 livp 后在手机相册中以**实况图(Motion Photo)**形式保存;
> ② 支持实况图的安卓机上,上传拍摄的实况图,系统内保存为 **.livp** 资产;
> ③ 不支持实况图的安卓机上,上传/下载**完全保持现状**(优雅降级;口径见 D4——上传按格式识别、下载按机型白名单,两侧判定刻意分离)。
> 约束:不动 liuqi 分支;未经允许不发版。**本方案纯 App 侧改动,后端/web/iOS 零改动。**

## 1. 背景

iOS 实况照片在本系统中以 .livp(zip 容器:静态帧 HEIC/JPEG + 实况短片 MOV)存储,App 已有完整的 iOS 双向链路(上传 `AlbumService.entityToLivp` 打包、下载 `darwin.saveLivePhoto` 恢复)。安卓阵营 2023 起主流厂商(小米/OPPO/vivo/三星/荣耀等)陆续支持实况图,但存储方式不是 livp,而是 **Motion Photo**:单张 JPEG 文件,视频(MP4)以字节形式附加在 JPEG 尾部,位置由 JPEG 头部 XMP 元数据描述。各厂商字段命名有差异,主流收敛于 Google GContainer 标准。

当前 App 在安卓上的行为:
- 上传:photo_manager 3.12 的 `isLivePhoto` 在安卓上**恒为 false**(subtype 只有 iOS PHAsset 填)→ 安卓实况图走普通轨,整张 JPEG(含尾部视频)按 `.jpg` 直传,**视频部分丢失实况语义**(web/App 只能当普通图片看,live-preview 无)。
- 下载:安卓 livp 走 D1 双落盘(解包后静态图、视频分别入相册 + 原始 .livp 写 Downloads),**无法恢复为实况图**。

## 2. 现状链路事实(已核实,行号以 worktree qplan/android-live-photo@30e1e42 为准)

### 2.1 上传链路
- 相册选图入口 `wechat_assets_picker RequestType.all` → 逐资产分流 `_enqueueAlbumAsset`(app/lib/features/assets/upload_pick.dart:209-241):
  - `AlbumService.isSupported && e.isLivePhoto`(upload_pick.dart:214)= **iOS 专属门**;`isSupported => !kIsWeb && Platform.isIOS`(app/lib/services/album.dart:23)。
  - live 轨:`resolveAlbumUploadName` 取真名 → `LivpService.baseNameOf` 基名 → `AlbumService.entityToLivp`(originFile + originFileWithSubType → zip)→ `enqueueLocalUpload(filename: '$base.livp', bytes:)`。
  - 普通轨(Android 全走此轨):`e.originFile` → `enqueueLocalUpload(path:, contentType:)`。
- `resolveAlbumUploadName`(app/lib/features/assets/album_upload_name.dart:57-98):title→titleAsync→originFile 路径扩展名→MIME 四级兜底;**安卓 title 通常非空,已有实现可直接复用**。
- livp 打包器 `LivpService.pack`(app/lib/services/livp.dart:48-61):`pack({imageBytes, imageExt, videoBytes, videoExt, baseName})`,条目名 `{base}.{ext 小写}`,纯 zip 零转码——**与数据来源无关,可直接复用于安卓拆分产物**。
- `uploadContentTypeFor`(upload_sheet.dart:127-132):`.livp` 恒 `application/zip`。
- 上传小包轨 `uploadBytes`(app/lib/core/api/assets_upload_api.dart:54-132):三步 multipart,App 端成熟。

### 2.2 下载链路
- 编排 `runDownloadJob`(app/lib/services/downloads.dart:134-190):空间预检 → `download-link` 签 URL → dio 下载到 app cache → `runSavePlan` 按矩阵落盘 → 任一路成功删临时。
- 矩阵 `planSaveRoutes`(app/lib/services/media_save.dart:94-97):**(android, livp) = gallery(saveLivpPair) + downloads() 无条件并发(D1 双落盘)**;`saveLivpPairToGallery`(app/lib/services/download_savers.dart:79-99)= 解包 → 静图 `saveImageWithPath` + 视频 `saveVideo` 分别计成败;downloads 路 = media_store_plus 写 `Download/浣花视界`。
- `downloadLink(assetId, {asAttachment})`(app/lib/core/api/assets_api.dart:177-187):**不支持 `variant` 参数**;请求体仅 `as_attachment`。
- 解包 `LivpService.unpackToFiles`(livp.dart:92-107):返回 `(image: File, video: File?)`,按「类别内最大条目」挑(与后端 `_pick_livp_entries` 同口径)。

### 2.3 后端(零改动的事实依据)
- 上传 create **无 content_type 白名单、无魔数校验**(api/app/routers/assets.py:201-203 仅透传给 MinIO);livp 的一切派发只看文件名 `.livp` 后缀(assets.py:360-364:enqueue_livp_thumbnail + enqueue_livp_download)。
- livp worker 挑条目口径:`_LIVP_IMAGE_EXTS = ('.jpg','.jpeg','.heic','.heif','.png')`、`_LIVP_VIDEO_EXTS = ('.mov','.mp4')`,按「最大静图+最大视频」(api/app/workers/main.py:215-256)——**安卓拆分产物 jpg+mp4 命名直接落进两族扩展名,后端零感知**。
- **下载级解包(关键复用)**:`download-link` 支持 `variant="unpacked"`(仅 .livp,assets.py:1617-1665),交付 `derivatives/{id}/livp.zip`,**条目恒为 `{基名}.jpg + {基名}.mp4`**:静图 JPG 原字节透传或 HEIC/PNG 转码,视频全规格转 H.264 MP4;视频转码失败降级「仅 jpg 的 zip」;**缺失时 404 + 自愈重派**(600s 频控,_heal_livp_download_zip)。web 端 livp 下载已在用此 variant(web/src/lib/asset-download.ts:5-6)。

### 2.4 平台与工程
- 零自定义原生代码:MainActivity 空壳(app/android/app/src/main/kotlin/com/taoxiplan/huanhuashijie/MainActivity.kt),无 MethodChannel。
- minSdk 29(build.gradle.kts:52)/ targetSdk flutter 默认(:53);photo_manager 3.12.0、archive 3.6.1、media_store_plus 0.1.3 已锁定。
- media_store_plus 0.1.3 `saveFile({tempFilePath, dirType, dirName, relativePath?})`:**无 mimeType 参数,落地名/MIME 由 tempFilePath 末段文件名(扩展名)决定**;`DirType.photo + DirName.pictures` 写 `Pictures/`;≥API30 走 MediaStore insert,字节原样搬运。已知钉子:**insert 前先按 DISPLAY_NAME+RELATIVE_PATH 删除同名列再插入(同名=覆盖替换,saveStatus 枚举名 createdOrReplaced 即此意,不会自动加后缀)**、成功亦返 null(以无异常为准)、搬运后无条件删源文件、**Kotlin 侧 catch 分支不回调 result(MediaStorePlusPlugin.kt:192-206 仅 Log)→ 异常时 Dart await 永久挂起**(D1 收尾沿用该路径与今日暴露面一致,零回归成立,知悉即可)。→ 因此本方案合成产物**不使用** media_store_plus 入相册,改用 photo_manager `saveImageWithPath`(见 D3),media_store_plus 仅继续服务 D1 收尾的 Downloads 原档路(现状不动)。
- 相关既有测试:livp_test / livp_base_name_test / album_upload_name(_edge)_test / media_save_test(矩阵全组合)/ download_savers_test / downloads_test(注入 DownloadIo)——新增逻辑沿同款「纯函数+注入假件」模式。

## 3. 技术基线:安卓 Motion Photo 格式与 flutter_live_motion 能力(源码级)

### 3.1 Motion Photo 存储格式
单文件 = 标准 JPEG + 附加视频字节,视频位置由 JPEG 内 XMP(APP1 段)描述。需要支持的三族:

1. **GContainer / Google Motion Photo v1-v2**(Pixel 新机型、小米/OPPO/vivo/荣耀 2023+ 主流跟随;**三星 OneUI 2.5+ 为混合形态:同一文件既有 GContainer XMP、尾部又带 SEFT trailer,视频块不在文件末尾**,见下):
   XMP 特征 `GCamera:MotionPhoto="1"`,Container:Directory 含两个 item:Primary(image/jpeg,无 Length 或 Length="0"——flm 默认模板的 Primary 带 Item:Length="0",两形态都要兼容,提取只认 Semantic=MotionPhoto 的条目)+ MotionPhoto(video/mp4,**`Item:Length="N"` = 视频字节数**)。单 motion item 时**视频块 = 文件末尾 N 字节**,即 `videoStart = fileSize - N`;**若文件尾部 4 字节为 `SEFT` 签名(三星混合形态),读倒数第 5-8 字节小端 int 得 L(=SEFH 目录块+条目段长,**不是 trailer 总长**)——真实布局为 `video 结束 → SEFH 块(L 字节) → size 字段(4B) → "SEFT"(4B)`,故 `videoEnd = fileSize - (L + 8)`,视频区间修正为 `[fileSize - L - 8 - N, fileSize - L - 8)`**(依据 doodspav/motionphoto 与 ExifTool Samsung.pm 两个权威实现互证,**标注为「假说+真机字节校准」——与 MicroVideo 同款证据分级,§8-D① 的三星真机样本字节核对是冻结 fixture 前的硬前置**;trailer 解析失败/非法 → **XMP 轨该文件判未命中,允许落 SEFT 兜底分支**——该文件确有完整 SEFT trailer,SEFH 直接解析可能给出正确区间,再失败才终局 null 降普通轨;口径与 §5.1 两级探测②一致)。多 motion item(v2 带独立音轨)本期不解析(见 D5)。
2. **GCamera MicroVideo(老格式)**(Pixel 3/3a 世代 2018-2019 引入 MVIMG、部分 OPPO 旧 OLivePhoto、小米旧 MicroVideo 变体):
   XMP 特征 `GCamera:MicroVideo="1"` + **`GCamera:MicroVideoOffset="N"`**,视频块取文件末尾 N 字节(`videoStart = fileSize - N`;**尾部 `SEFT` 签名时同第 1 条做 trailer 修正:videoEnd = fileSize - (L+8),videoStart = videoEnd - N**)。
   **offset 语义假说**(以 flm `XmpMerger.updateLengthFieldsOnly` 源码 XmpMerger.kt:32-57 的行为互证——它重新合成时把 `MicroVideoOffset` 与 `Item:Length` 一并更新为**新视频的字节长度**,提示两种字段语义一致=「距文件尾的长度」;**这是第三方实现互证而非权威规范,故称假说**):`videoStart = fileSize - N`。以 fixture 单测锁死实现 + §8 验收 E 真机样本校准(无真机则标记「fixture 锁实现、真机未证」,守卫链保证偏差时安全降级)。
3. **Samsung SEFT trailer(老三星,OneUI < 2.5 的纯 SEFT 形态——无 GContainer XMP)**:文件尾部 SEFT/SEFH 块结构(尾部 4 字节 "SEFT",其前 4 字节 size=L=SEFH 块长;SEFH 内 marker 列表记 `MotionPhoto_Data` 偏移;video 区间终点 = fileSize - totalTrailerLen(统一命名 **totalTrailerLen = L + 8**,下同),同第 1 条口径)。**带 GContainer XMP 的三星新机型已在第 1 条以 trailer 修正覆盖**;本分支仅兜无 XMP 的纯 SEFT 残留,列 P1(D5)。

厂商相册回放识别:GContainer 是最大公约数——flutter_live_motion 的默认 XMP 模板同时打 GContainer + MicroVideo + OPPO + 小米四族标记(§3.2),声明兼容 Pixel / OPPO / Realme / 小米 / 「装有 Google Photos 的设备」;**三星相册原生识别 GContainer 的口径(OneUI 2.5+)来自公开资料而非 flm 声明,以真机验收 D 为准**。

### 3.2 flutter_live_motion 0.1.0(源码已通读)
- Dart 接口:`FlutterLiveMotion().generate({required String imagePath, required String videoPath})`;**Android 返回合成文件的 cacheDir 路径**(输出名 `MVIMG_{uuid}_MP.jpg`,FlutterLiveMotionPlugin.kt:41/49);iOS 返回 bool 直存相册(本方案**不在 iOS 调用**;其 pod 仅注册 method channel,零启动行为,集成无副作用)。
- Android 合成实现(MotionPhotoGeneratorHtml.kt,229 行纯 java.io,零三方依赖):读图+视频全内存 → 提取/合并原图 XMP(无 XMP 走 `XmpMerger.generateDefaultXmp` 新建——**一套模板打四组标记(GContainer 目录 + GCamera:MicroVideo/MicroVideoOffset + OpCamera + MiCamera,覆盖 Google/OPPO/小米三家),兼容面比单格式更广;xmp/GoogleXmpGenerator.kt 在源码中无调用点,系死代码)→ 若原图尾部已有旧视频(对**整张主图**搜首个 `ftyp` 标记)则截去 → JPEG + XMP + 视频字节重组 → 写输出文件。
- **两个已识别缺陷(均以方案侧守卫兜住,见 D6/§5.4/§9)+ 一个接受项**:
  1. **ftyp 误命中静默损坏**:对整张主图搜首个 `ftyp`(4 字节)——若 JPEG 高熵扫描数据中随机出现该序列(概率≈fileSize/2^32,12MB 图约 0.3%,批量下载累积不可忽略),截断点被误置到图中间,输出主图拦腰损坏**且不抛异常**,降级链(异常→D1)兜不住 → 方案在入相册前对 flm 产物做**输出自校验**(§5.4 步骤 4b),校验失败走 D1。
  2. **主线程执行**:onMethodCall 默认主线程,合成全程同步 IO(读图+读视频+重组+写盘),几十 MB 实况图会阻塞 UI 数百 ms~秒级,批量下载(队列并发 2)逐个叠加 → 记录取舍,真机验收关注掉帧;不可接受则换 Dart 内联实现(D6 后路)。
  3. **APP1 段长补丁的两个真实风险**(MotionPhotoGeneratorHtml.kt:84-95;`originalLength + n` 恰为被替换区域差值、与重组后实际段长恒等——**xpacket 包裹形态不失真**,此前推演有误):(a) newLength>65535 时 `and 0xFF` 高位静默截断;(b) `findPatternReverse` 在 `[0, xmpStart)` 内**从尾向头**找 FFE1,返回距 xmpStart 最近者——XMP 位于标准 APP1 段时命中的正是 XMP 自身段头(**不会**误中其前的 Exif APP1;「Exif 在前」恰是常见布局且无害);真实触发条件=**XMP 不位于标准 APP1 段内**(段头错位/APP11 扩展段/非段内嵌入)的罕见形态,此时补丁可能写错段。另注:no-XMP 输入走 embedXMP 分支时 rawApp1 仅 2 字节(SOI),补丁循环天然跳过。**接受项**:motion XMP 实测仅数 KB((a) 触发前提在本方案两条输入路径上不成立);(b) 触发前提(XMP 脱离标准 APP1,或段长字段恰为 65505=0xFFE1 时反向搜索命中长度字节自身的理论角例,概率可忽略)在相机产物/flm 新建两路径上现实不产生;两者自校验均不覆盖,真机验收 D/§8-A5 若出现相册不识别再回补定点校验,不在本期扩大防护面。
- 约束:sdk ^3.9.2(项目 Dart 3.13 ✓)、flutter ≥3.3.0 ✓、gradle minSdk 24(项目 29 ✓)、iOS podspec 13.0(项目 Flutter 3.47 本就要求 13+ ✓);依赖仅 plugin_platform_interface;AndroidManifest 空壳零权限。
- **没有解析/拆分能力**——识别安卓拍摄的实况图需自研(本方案 §5.1)。

### 3.3 关键自洽性(上传↔下载闭环)
- 上传侧拆出的主图 = 原 JPEG 截断到 videoStart(**XMP 里 MotionPhoto 字段残留**);下载侧 flm 合成时 `XmpMerger` 恰好会**更新而非重复**这些长度字段、且会截去尾部旧视频(搜 ftyp)——两侧语义互洽,不会产生双重视频或僵尸 XMP。
- 快路径(原始档解包直合成)的输入视频就是上传时拆出的原视频:其长度与残留 XMP 记录值**天然相等**,即便 flm 的 XMP 长度更新因属性顺序变体未生效,产物语义仍自洽(等于原值)。
- 后端 unpacked 交付的 jpg 大多无 MotionPhoto XMP(HEIC/PNG 重编码)→ flm 走「新建 APP1」分支 ✓;**两类例外形态(均由 §5.4 步骤 4b 校验兜住走 D1,属降级而非缺陷,AppLog 打点区分)**:① jpg(带 GContainer 残留 XMP)+mov 组合的外部异构 livp——unpacked 交付时 jpg 原字节透传(XMP 残留)、mov 转码为 mp4,若 flm 对残留 XMP 的长度更新因属性顺序变体而**命中相邻条目**(XmpMerger.kt:51-54 的正则要求先命中 `Item:Semantic="MotionPhoto"` 再取其后首个 `Item:Length`——属性顺序变体下它可能命中 MotionPhoto **之后相邻条目**(如 v2 音轨 item)的 Length 或不命中,新视频长度写错位、MotionPhoto 自身 Length 保持旧值):快路径旧值==新值恒自洽;补抓路径旧长度≠实际 video 由 video 比对拦下走 D1——**错位写入/未生效两种变体后果都列入 §8-D 三星真机观察项**;② 主图有 XMP 但**无任何 motion 字段**(如 Photoshop XMP 的外部异构 livp)——flm `XmpMerger` 对已有 XMP 只原位更新三个长度字段、**从不新增 motion 字段**(XmpMerger.kt:18-26),合成产物无 GCamera 标记 → probe 未命中 → D1。

## 4. 方案总览

```
上传(Android,相册轨;按【格式识别】,不做机型白名单判定——见 D4):
  AssetEntity ──originFile──▶ 预筛(头 256KB+尾 64KB+定点 8 字节;前置 >150MB 闸门)──未命中/超限──▶ 现状普通轨(零改动)
                    │命中(GContainer/MicroVideo + ftyp 守卫)
                    ▼
              enqueueMotionPhotoUpload(base, srcPath, plan)(入队秒回,不打包)
              ──▶ 队列 worker(并发 2 封顶临时共存):复验(TOCTOU)→
                  compute isolate 打包(STORED,{base}.jpg+{base}.mp4)→临时文件
                  →uploadFile 16MB 流式轨→终态删临时(§5.3)
              (后端按 .livp 全链路自动派发;不走 iOS 轨的 bytes 小包轨——批量 OOM/入队阻塞,§5.3)

下载(Android,livp;按【机型白名单】判定——见 D1/D4):
  capable(白名单机型)?
    ├─ 否 ──▶ 现状矩阵 D1 双落盘(零改动)
    └─ 是 ──▶ 步骤 0/1 闸门(>150MB 或 剩余空间∈(4×,6×) → 直接走 D1)→ 下原始档 → 解包:
                ├─ jpg + mp4(先验输入 video ftyp 头)──▶ flm.generate ──▶ 定点读自校验 ──▶ photo_manager 入相册 ✅实况图
                ├─ heic/mov/png(iOS 来源/外部异构)──▶ 请求 variant=unpacked:
                │     ├─ 成功(条目恒 jpg+mp4)──▶ flm.generate ──▶ 自校验 ──▶ 入相册 ✅
                │     └─ 404(首访,已触发自愈)──▶ D1 收尾(下次即合成;例外:超 200MB/永久失败 livp 恒 404,§5.4 步骤 3)
                ├─ 无视频条目 / m4v ──▶ saveImageWithPath 静图入相册(对齐 iOS 退化,m4v 不付 unpacked)
                └─ 合成/校验/保存任一失败 ──▶ D1 收尾(原始档已在手,零额外请求)
```

## 5. 实施设计

### 5.1 新增 `lib/services/motion_photo.dart` — Motion Photo 探测与拆分(纯 Dart,PC 可单测)

```dart
class MotionPhotoSplit {
  final List<int> image;   // 主图字节 [0, videoStart) —— 原 JPEG 截断,XMP 原样保留
  final List<int> video;   // 视频字节 [videoStart, videoEnd) —— Android 实况恒为 MP4
  final String format;     // 'gcontainer' | 'microvideo' | 'seft'(日志/测试用)
}

/// 三读预筛的轻量结果(不含字节)——命中后全量读+拆分+pack 收进 compute isolate,
/// 主 isolate 永不全量读(§5.3)。
class MotionPhotoPlan {
  final String format;
  final int videoStart;
  final int videoEnd;      // 无 trailer 时 = fileSize;三星混合形态 = fileSize - totalTrailerLen(=L+8)
  final int fileSize;
}

/// 全量字节版(测试与下载侧自校验共用内核;不做预筛)。
MotionPhotoSplit? probeMotionPhoto(List<int> bytes);

/// 文件版(生产入口):只做三读预筛(头 256KB+尾 64KB+定点 8 字节),
/// 返回轻量 [MotionPhotoPlan];未命中/守卫不过 → null(零全量读)。
Future<MotionPhotoPlan?> probeMotionPhotoFile(String path);
```

解析内核(逐条守卫,任一不满足即返回 null=降级普通轨):
1. `bytes[0..2] == FF D8`(JPEG SOI);
2. 在头部搜索标记 `<x:xmpmeta` … `</x:xmpmeta>`(与 flm `extractOriginalXmp` 同口径的 marker 搜索,不引 XML 解析器;单 APP1 段长度上限 64KB,但 Adobe Extended XMP 可跨段超此限——**256KB 是经验窗口而非推论**,漏检即 fail-safe 返回 null 降级普通轨,无害;实测相机 motion XMP 仅数 KB);
3. XMP 含 `GCamera:MotionPhoto="1"` → **元素域提取**(XMP 属性顺序无规范约束,三星等厂商模板存在 Length 写在 Semantic 之前的变体,**不得假定属性顺序**;实现=先定位含 `Item:Semantic="MotionPhoto"` 的 `Container:Item` 元素边界,再在元素内取 `Item:Length`;属性值容忍单/双引号)取出该 motion item 的 `Item:Length`;**且 `Container:Directory` 内 `Semantic="MotionPhoto"` 的条目数必须 ==1**(多 motion item=GContainer v2 多段,D5 明确不解析——直接判 null 降级普通轨,与 D5 口径闭环,防外部异构 livp/厂商 v2 产物把尾部按单视频误拆);或 XMP 含 `GCamera:MicroVideo="1"` → 提取 `GCamera:MicroVideoOffset`;**双标记并存时(flm 默认模板即两族同打)两族区间都计算并互验:不一致判 null,一致时 format 标签取 gcontainer**;
4. `videoEnd = fileSize`;**若尾部 4 字节为 `SEFT` 签名(三星混合形态,§3.1 第 1 条)则读倒数第 5-8 字节小端 int 得 L、令 `videoEnd = fileSize - (L + 8)`**(L 是 SEFH 块长,size 字段与 SEFT 签名共 8 字节另计)**(**L 合法域 24~4088**——最小 SEFH 单 MotionPhoto_Data tag 形态=24 字节(doodspav/motionphoto 口径),**等效约束 totalTrailerLen=L+8 ∈ [32,4096]**,双重校验一致;非法 → XMP 轨未命中、落 SEFT 兜底,见两级探测②);`videoStart = videoEnd - N`;守卫:`N >= 1024`(防 XMP 残留小值误判)、`videoStart > xmpEnd`(视频必须在 XMP 之后)、`videoStart < videoEnd`;
5. **MP4 强特征守卫**:`video[4..8] == 'ftyp'`(ISO-BMFF box 头)——不满足判 null(微信/截图等剥视频残留 XMP 的场景由此挡住;三星混合形态若 trailer 修正失败,videoStart 落点错位,此守卫亦将其安全挡回普通轨);
6. 拆分:image=[0, videoStart),video=[videoStart, videoEnd)(trailer 字节不入任何一侧,直接截除)。

**两级探测(普通图片零全量读;XMP 轨优先,SEFT 轨兜底)**:文件版 `probeMotionPhotoFile` 的预筛顺序钉死——① 头 256KB(守卫 1-3 与 XMP 提取)+ 按 videoStart 定点读 8 字节(守卫 5 的 ftyp 检查):**XMP 轨命中即按步骤 4 做尾部 trailer 修正**(混合形态三星既有 GContainer XMP 又有 SEFT 尾,必须走这条轨,尾签名不旁路 XMP);② **XMP 轨未命中(无 XMP/守卫败)且尾 64KB 有 `SEFT` 签名**才进纯 SEFT 分支(P1,无 XMP 的老三星形态,守卫 2/3 对它必败是预期);③ 两轨都未命中 → null 普通轨。**`probeMotionPhotoFile` 自身到预筛为止、零全量读**;「readAsBytes 全量读+守卫重验+步骤 6 拆分」属 **worker/compute isolate 职责**(§5.3 打包流程内,以 plan 的区间执行),勿在本函数实现。预筛不过只花小读。**两轨按此顺序互斥**(XMP 优先、SEFT 兜底,混合形态恒走 XMP 轨)。全量版 `probeMotionPhoto(List<int>)` 是同一内核(**单测用**;下载侧自校验用其**定点读版**——头部 XMP 段+videoStart±8B+image 段尾 32B,见 §5.4 步骤 4b,**禁对产物做全量 probe 回读**,主 isolate 零大对象)。
异常包装:`Future<MotionPhotoPlan?> probeMotionPhotoFileGuarded(String path)` = probeMotionPhotoFile 的 try/catch 包装(**任何 IO/解析异常 → null 落普通轨**;生产入口,§5.3)。

Samsung SEFT(P1,独立 try 分支,失败即 null):尾部 4 字节 `SEFT` → trailer 长度 → 前向找 `SEFH` → marker `MotionPhoto_Data` 偏移 → video=[offset, fileSize - totalTrailerLen)(=L+8,§3.1 口径)。字节序与小端实现以构造 fixture 单测锁死;老三星占比低,解析不出安全降级普通轨。

### 5.2 新增 `lib/services/motion_photo_capability.dart` — 机型能力判定

- MethodChannel `ms/device_info`(MainActivity.kt 加 ~10 行:返回 `{manufacturer, model, sdkInt}`)——**不引 device_info_plus**(只要 3 个字段,避免为一个字段拉整包依赖;项目现状零原生代码,新增面控制到最小)。
- 判定(进程内记忆化——**仅成功结果缓存,channel 异常/null 每次重试不缓存**,防首次瞬断把 capable 机整个会话锁死在降级态;可注入覆盖供测试):
  ```dart
  /// manufacturer 小写 ∈ 白名单 且 sdkInt >= 31(Android 12)。
  /// 显式前置 !kIsWeb && Platform.isAndroid(web/桌面 defaultSavePlatform 也返回
  /// android,不能只靠 channel 异常兜成 false)。
  /// 初版白名单:google, xiaomi, redmi, oppo, oneplus, realme, vivo, iqoo
  /// (常量表,真机校准后可扩;HUAWEI/samsung/honor 初始均排除——见 D1;
  ///  realme/oneplus 与 OPPO 同 ColorOS 生态,由 OPPO 真机验证推断,不单列真机项)
  /// 注:redmi 机型 MANUFACTURER 报 "Xiaomi"、iQOO 报 "vivo"(redmi/iqoo 是 brand
  /// 不是 manufacturer),这两项永不命中——保留仅为语义自文档,实际由 xiaomi/vivo 覆盖
  bool isMotionPhotoCapable(AndroidDeviceInfoLike info);
  ```
- channel 不可用(异常/null)→ **false**(降级现状,永不因判定失败阻塞保存)。

### 5.3 上传侧接线(upload_pick.dart `_enqueueAlbumAsset`)

在 iOS live 轨之后、普通轨之前插入 Android 分支。**只做格式识别,不做机型白名单判定**(判定口径与下载侧分离,理由见 D4)。现状代码里 `f`(originFile,:229)与 `r`(resolveAlbumUploadName,:233)在普通轨内取得——**分支插入点=`r` 取得(:233)之后、普通轨 `enqueueLocalUpload`(:234)之前**(分支引用 r.filename 与 f.path,插早了引用未定义变量;勿上提到 iOS 门之上:iOS 轨会多付 originFile 读取,且 iOS 命名解析链不得被触碰):
```dart
if (!kIsWeb && Platform.isAndroid && _extOf(r.filename) 属 jpg/jpeg) {  // _extOf 在本文件自备,内部 toLowerCase(title 可能是 X.JPG 原大写)
  // probe 任何异常在包装函数内部捕获→返回 null 落普通轨(外层
  // enqueueNamedBatchAndReport→enqueueBatchNamed 的逐项捕获语义是计跳过,
  // probe IO 异常不能把整项吞掉不上传,§7 第 5 条)
  // 大小闸门前置(File.length 先查):安卓长时实况可近百 MB,超 150MB 降级普通轨
  // (防 isolate 内存峰值与后端 livp worker 200MB 永久失败带,§9),且避免白付预筛
  if (await File(f.path).length() <= 150 * 1024 * 1024) {
    final plan = await probeMotionPhotoFileGuarded(f.path);  // 入队阶段只做三读预筛(秒回)
    if (plan != null) {
      final base = LivpService.baseNameOf(r.filename, 'IMG_${e.id}');
      // **打包延迟到队列 worker 执行时**:入队阶段 compute 打包会让 99 张批在
      // 汇总 toast 前串行等待分钟级,且临时 livp 逐张落盘到「各自成功终态」才删
      // (≈3-6GB 共存,低存储机写满殃及同队列其他传输);worker 内打包则同时存活
      // 的临时 livp 被队列并发(2)自然封顶,retry=从头重打包语义更自然。
      // totalBytes 以原档大小入队(STORED zip≈jpg+mp4≈原档,进度归一用,终值以 complete 回报为准)
      await enqueueMotionPhotoUpload(
        folderId:, where:, base: base, srcPath: f.path, plan: plan,
        srcBytes: 原档字节数,
      );
      // ↑ 入队/预筛异常照常外溢→外层逐项捕获计跳过(与 iOS 轨同语义)
      return;
    }
  }
}
// ↓ 现状普通轨,零改动
```
- **worker 内打包语义**(`enqueueMotionPhotoUpload` 的 worker 闭包):① 复验——重跑 `probeMotionPhotoFileGuarded`(入队到执行之间相册原文件可能被编辑/删除,TOCTOU),按结果分三例:**复验命中 → 以复验所得新 plan 打包,弃入队 plan**(旧 plan 拆分会产出错位产物=静默坏数据);**复验同时复查 File.length() 仍 ≤150MB**(入队后被替换成超大文件的极端场景,超限落「降级普通轨」分支,守住 §9 内存预算);**上传进度按复验后的实际 size 归一并 clamp 到入队 totalBytes**(transfer_queue 回写 doneBytes 虽无 clamp,但两处消费端已 clamp(transfer_task.dart:85/transfer_queue.dart:121)——此处按实际 size 归一是为字节语义/单调性正确,非修越界 bug);**复验 null 但文件仍在 → 降级:按普通轨直接上传原档,实际上传 filename=`{base}.jpg`、contentType=image/jpeg**(仍以 .livp 名传 JPEG 原字节会让后端 livp 双 job 永久失败+unpacked 恒 404 落 `download_zip_failed` 挡自愈;传输卡片显示名仍 .livp 属已知取舍),该降级在 worker 内完成、任务仍算成功;**文件不存在 → 任务失败**(明确文案「原文件已不存在」,uploadFile 的 length() 必抛,不吞不降级);② 打包——compute isolate 内全量读+按 plan 区间拆分+pack(ZIP_STORED)落临时文件(主 isolate 先取 `getTemporaryDirectory()` 完整路径随参数传入,目标文件在**worker 执行时**才创建;**临时名必须唯一:`motion_pack_<uuid>.livp`**(uuid 已满足唯一性;taskId 在 enqueue 内才生成、worker 闭包先于入队构造拿不到,勿写进命名)——队列并发 2 下两个 worker 同时打包,相册真名跨设备碰撞(IMG_*/Screenshot_*)现实存在,同名互踩会把另一任务的 zip 静默传上去);③ 上传——临时文件走 `uploadFile` 16MB 流式轨;④ **临时文件在任务终态(成功/失败/取消)一律删除**——retry 会从头重打包,无需保留(与早期「仅成功删」设计的差别即源于此);⑤ 打包/上传异常=任务失败(外溢到队列),retry 重跑全流程;**降级与失败分支 AppLog 区分打点**(复验超限/复验 null/文件不存在/打包失败,与下载侧 §5.4 步骤 7 同款观测口径)。**注:进程被杀(非终态)时 worker finally 不执行,cache 遗留 ≤150MB 临时 livp 无人清扫(启动恢复只标「进程中断」)**——遗留项 10 记档(启动清扫 motion 临时前缀为可选后路);
- **注入缝(测试铁律)**:Android 分支抽为 `@visibleForTesting` 纯编排函数(入队侧注入 `originFileOf/probe/enqueue` 假件;worker 侧 `enqueueMotionPhotoUpload` 注入 `probe/pack/upload/deleteTemp` 假件,`_enqueueAlbumAsset` 调用其生产缺省)——与 §5.4 对 `MotionPhotoGenerator` 的注入处理对齐,零平台通道可测。
- **pack 压缩方式**:motion 轨走 **ZIP_STORED**(jpg/mp4 已压缩,deflate 近零收益白烧 CPU;后端 unpacked 产物同款口径 workers/main.py:658-669)——`LivpService.pack` 加 `stored` 开关(archive 3.6.1 的 per-entry 实现=`ArchiveFile.compress=false`,zip_encoder 据此写 STORED;ZipEncoder 只有全局 level、**无 per-entry level 控制**,故开关做在条目上),缺省 deflate 保持 iOS 轨现状零回归,仅 motion 轨传 stored;livp_test 同步两档用例。
- iOS 轨、普通轨、file_picker 文件选择轨(`_pickFiles`)**全部不动**(file_picker 轨不接 probe:从文件管理器选的 jpg 语义应由用户掌控,列遗留项)。
- 普通图片代价:三读预筛(头 256KB+尾 64KB+定点 8 字节),未命中即走原路径,无感。

### 5.4 下载侧编排(downloads.dart + 新增 `lib/services/motion_photo_save.dart`)

- `assets_api.downloadLink` 加可选参数 `String? variant`(**仅 variant 非空("unpacked")才向请求体添加该键**——后端是 Literal 非 Optional,恒带键传 null 必 422;缺省不带键,行为不变)。
- `runDownloadJob` 顶部加一个分流(其余代码**行为零改动**——主体抽为 `_runLegacyDownloadJob` 私有函数属重构,见步骤 1):
  ```dart
  if (plat == SavePlatform.android && kind == SaveAssetKind.livp &&
      await motionPhotoCapable()) {          // 注入束可覆盖,测试用
    return runMotionPhotoDownload(asset:, onProgress:, token:, io:, …);
  }
  ```
- 新函数 `runMotionPhotoDownload`(独立编排,**planSaveRoutes 矩阵不动**——矩阵语义是「多路并发落盘」,motion photo 是「单产物多级降级链」,形状不同,独立函数回滚面最小):
  0. **大小闸门(先于一切)**:`asset.sizeBytes > 150MB`(镜像上传侧)→ **直接走 D1 路径,不进合成链**——flm 原生侧读图+读视频+**输出数组**(≈image+video 总量)≈**2-3×** 原件常驻(源码口径约 2×,取 3× 为保守上界),其 Kotlin `catch (e: Exception)` 捕不住 OutOfMemoryError(Error 非 Exception),超大盘子合成=主线程崩溃且任何 Dart 侧兜底无从生效(150MB 上限≈450MB 峰值,该闸门设上界不消除低端机风险——60-150MB 档低端安卓(java 堆 256-512MB)仍可能原生 OOM,§9 记录、§8-A 大样本项专测;收紧闸门/流式合成列 flm 后路一并考虑);D1 的全读暴露面与今日一致,不新增;
  1. 空间预检**分档,不比现状更严**(步骤 0/1 的两条 D1 回落**调用 `_runLegacyDownloadJob`——现状 `runDownloadJob` 主体抽成的私有函数,fetch/进度/取消/尾部语义全套,防两份编排漂移兑现零回归**;**不能直接回调 `runDownloadJob`**——其顶部就是 motion 分流,capable 机上会重入死循环;分流入参加 `motionCapable` 注入,回落路径传 false 短路):先按现状 D1 口径 4× 预检(不足→沿用现状中止语义,`SaveAbortException`);通过后,若剩余空间 **< 6×**(补抓支路最坏驻留≈5×:原始档+补抓档+二次解包目录+flm cache 产物+MediaStore 入库副本——**原始解包目录在补抓前已删,见步骤 3**;取 6× 留回裕度;unpacked zip 的 HEVC→H.264 转码膨胀在下载前不可知,由补抓 fetch 的 Content-Length 复检兜底,见步骤 3)则**不中止、直接降级走 D1 路径**(放弃合成,本机空间带 [4×,6×) 的行为与今日完全一致,零回归);≥6× 才进合成链;**freeBytes=null(df 失败等,现状 checkSpace unknown 语义)→ 放行进合成链**(与今日预检放行一致,不因新特性更严);**已知取舍:队列并发 2 时两任务各拿同一全局 freeBytes 各自承诺,存在重复计数超卖**——与现状 D1(4×)同类暴露,本期不新增处理(ENOSPC 由「先清中间产物再 D1」与 fetch Content-Length 复检兜底),共享在途承诺计数列后路;
  2. 下载**原始档**(进度上报**整链映射到 [0, 0.95]**:首段报 `frac × 0.95`——首段完成时报 0.95 而非 1.0,为补抓段留出空间,避免补抓段出现「≥首段完成值 1.0 且 ≤0.95」的空约束;transfer_task 按 asset.sizeBytes 归一并 clamp,裸报会提前顶格 100%;**每次 fetch 返回后检查 `token.isCancelled`——已取消则删临时直接返回,复刻现状 P2-2 取消竞态语义**;**fetch 网络异常=任务失败外溢(与现状一致,残缺临时文件处置也对齐现状=不删保留、app cache 系统可回收,downloads.dart:156-164 现状同款),严禁落入「异常→D1 收尾」catch-all**——残缺临时文件不能进 D1 存相册/写 Downloads;D1 收尾仅覆盖「完整下载到本地之后」的后续步骤异常,**该外溢规则对补抓段细化为:**仅 404**(download-link 层未就绪 / presigned GET 阶段对象竞态消失)按 D1 收尾,连接类/超时/5xx/其余 4xx(403 等,与现状 download-link 403 同义)一律任务失败外溢——与步骤 3 口径一致;**Dart 侧两层 404 异常形态不同**(主 Dio 的 `ApiException(404)` vs 裸 presigned GET 的 `DioException(badResponse, 404)`),实现须收口为一个 `isNotFound(Object e)` 谓词作为唯一判定面);
  3. 解包(`LivpService.unpackToFiles`,临时目录 finally 必清,沿 P2-3 钉子):
     - **video 为空** → 直接 `saveImageWithPath` 存原档静图收尾(**title=解包条目名,勿强制 .jpg**——条目可能是 heic,title 决定 DISPLAY_NAME/MIME,强改 .jpg 会造成 HEIC 字节配 image/jpeg 的错配;对齐 D7/iOS 退化语义,**不补抓 unpacked**——原档静图已可用,jpg-only livp 多付一次请求无意义;**此分支保存失败照走 D1 收尾**;「不写 Downloads 原档」仅指成功路径(D3/D7「退化即完成」口径),D1 收尾自身的 downloads 路仍按现状矩阵执行);
     - image 扩展名 jpg/jpeg 且 video 非空且 mp4 → **快路径**:先定点读 image 条目前 2 字节验 `FF D8` SOI(外部异构 livp 的改名 HEIC 条目防),再对输入 video 前 8 字节复用守卫 5 内核验 ftyp(外部异构 livp 的假 mp4 条目不过 → D1 收尾 + AppLog「input video 非 mp4」,防「合成仅静图语义的产物且自校验通过」的静默降级)→ 直接合成;
     - **video 条目为 m4v → 直接按无视频退化**(与「video 为空」同分支,title=条目名存静图收尾,不发起注定只回 jpg 的 unpacked 请求——后端 unpacked worker 只认 mov/mp4(workers/main.py `_LIVP_VIDEO_EXTS`);m4v 是 LivpService 视频族(livp.dart:14)里的极小众组合,已知取舍:capable 机少交付一个视频文件,遗留项 9);
     - 否则(heic/mov——iOS 来源;png——外部异构 livp 常见)→ **按需补抓**:**先删原始解包目录**(heic/mov 已无用途——补抓支路不删则最坏驻留 6× 恰好吃满闸门零裕度;删后=原始档+补抓档+二次解包+flm 产物+入库副本≈5×,6× 闸门留回裕度)→ `downloadLink(variant: 'unpacked')` → 下载(**fetch 拿到 Content-Length 后对剩余空间复检一次——freeBytes=null 沿用 unknown→放行同款语义;不足即 D1 收尾——6× 预检以 asset.sizeBytes 计,unpacked zip 的 HEVC→H.264 转码膨胀在下载前不可知**)→ 解包;**404 / 解包与挑条目异常 → D1 收尾(补抓段的 link/fetch 网络异常——连接类/超时/5xx/403——不在此列,与步骤 2 同语义任务失败外溢,仅 404 走 D1)**(**注意后端边界:超 200MB 或静图永久失败的 livp,404 不重派**——对此类资产「下次即合成」不成立,每次下载固定多付一次 404 请求,接受并 AppLog 区分记录;补抓解包后 video 仍为空 → 同上 saveImage 收尾);**补抓段进度恒报 0.95**(首段已用满 [0,0.95],补抓段无可视化增量,保完成终态 1.0 由任务队列自然表达;验收 A3 顺带观察);
     - 解包本身失败(zip 损坏)→ D1 收尾(其中 gallery 路同样解包失败,downloads 原档路兜底,与现状行为一致);
  4. **合成 + 输出自校验 + 入相册**(每步异常 → D1 收尾):
     a. `flm.generate(imagePath:, videoPath:)` → cacheDir 产物;
     b. **输出自校验**(flm ftyp 误命中静默损坏的唯一兜底,§3.2 缺陷 1;注意:**ftyp 误命中场景下**损坏只体现在 image 半段——误命中截断点处 Huffman 流戛然而止、无 EOI,而 video 半段与 XMP 长度字段对该场景恒自洽,**只查 video 侧对它是同义反复、零判别力**[其他畸形形态(如 §3.3 例外①的残留 XMP 长度失配)仍由 video 长度比对拦截,三项各司其职]):**三段定点读校验(不整读产物,主 isolate 零大对象)**:头部读 XMP 段(§5.1 同一内核的 XMP 解析)+ 定点读 videoStart±(ftyp 首字节/长度)+ 定点读 image 段尾 32 字节(与输入主图尾段比对),必须同时满足——
        - XMP 命中(gcontainer/microvideo,含双标记 gcontainer 优先规则);
        - `split.video 长度 == 输入 mp4 长度` 且 `split.video[0..8] == 输入 mp4[0..8]`(ftyp box 头);
        - **image 半段完整性=确定性尾段比对:`split.image` 尾 32 字节 == 输入主图尾 32 字节**(flm 对输入主图逐字节透传,尾段在手可定点读比对)——ftyp 误命中时截断点落在图中间,输出 image 尾段是图中间数据,与输入尾段相等的概率工程上可忽略(仅误命中点恰落在主图末 32 字节均匀填充区的理论角例,概率完备);**且无 padding 误拒**(GContainer/MicroVideo 规范允许 EOI 与视频块之间存在厂商 padding(Item:Padding/扇区对齐,数百字节~4KB),EOI 容忍窗假设会对此类白名单品牌每张必拒,目标①对该品牌整体落空——故弃 EOI 口径);两比对输入(上传拆分截断图/worker 透传 jpg)均满足前提;
        任一不满足=合成产物可疑 → **不落盘、走 D1**;
     c. **入相册:`PhotoManager.editor.saveImageWithPath(flm 产物路径, title: '{base}.jpg')`**——**无需物理改名**:saveImageWithPath 的 DISPLAY_NAME 与 MIME 均取自 title(photo_manager IDBUtils.kt saveImage 区段,DISPLAY_NAME/MIME put 约 :305-306,title 扩展名优先、路径扩展名/流嗅探兜底),产物路径的随机名(`MVIMG_{uuid}_MP.jpg`)不影响落地名;基名取 `asset.filename` 去扩展名再净化,必须以 `.jpg` 结尾(MIME 推断);与 D1 静图路、iOS 无视频退化路同一 API,**权限前置需在新编排内显式复刻 `_ensureGalleryPermission` 同款逻辑(download_savers.dart:26-30)——成功路径不走 runSavePlan/gallerySaver,权限链不会自动继承;未获授权=走 D1 收尾**;字节原样入 MediaStore Images,**同名由系统自动加后缀(与 D1 语义一致——不用 media_store_plus,因其同名=先删后插覆盖替换,见 §2.4/D3)**;**不传 relativePath**(photo_manager 对该参数的落点行为未证实,缺省=MediaStore Images 默认 `Pictures/` 根目录,与 D1 静图路同款落点;子目录收口列遗留项 8);
  5. **D1 收尾** = **先幂等删除全部链上中间产物(解包目录/补抓档/二次解包/flm 产物),仅保留原始档临时文件**,再调用现状 `runSavePlan(planSaveRoutes(android, livp))`——即完全回到今日行为(gallery 解包双存 + downloads 原档);副本/删源时序由 runSavePlan 既有机制处理(**android livp 双主路各持独立副本,media_store_plus 搬走的是副本**;原档临时文件在收尾期间不被消费,收尾返回后按「成功即删/全败保留取证」既有语义处置;**收尾全败 = 抛 SaveAbortException + 原档临时保留取证**,对齐 runDownloadJob 既有终态);**先清中间产物是零回归承诺的一部分**——不先清则降级路径瞬时空间峰值比今日 D1 高出链上中间产物,窄空间带机器会从「今日能成」变「ENOSPC 全败」;
  6. **合成成功路径的清理**:确认保存成功后,finally 链删除原档临时+解包临时目录+flm cache 产物(幂等,删除失败静默——均在 app cache,系统可回收);
  7. 收尾文案/通知:成功「{filename}:实况图已存入相册」;D1 收尾沿用 `saveSummary`;`Notifier.taskFinished` 同现有;`AppLog` 打点降级原因(probe 未命中/合成异常/自校验失败/unpacked 404 等,真机排查依据)。
- **capable 机型的 livp 不再写 Downloads 原档、不再静图视频分存**(合成成功时;见 D3);降级路径行为与现状逐字节一致。
- 取消语义:下载段沿用 CancelToken(每次 fetch 后检查,见步骤 2);合成段为本地同步操作不可中断(flm 主线程执行,见 §3.2 缺陷 2 取舍),取消只影响「不再进入下一步」,工作文件 finally 幂等清理。

### 5.5 依赖与平台改动清单

| 文件 | 改动 |
|---|---|
| app/pubspec.yaml | + `flutter_live_motion: ^0.1.0`(pubspec.lock 随之;**实施第一步=镜像解析 + 双端构建冒烟**:① `flutter pub add flutter_live_motion` 干跑(镜像可解析,已实测 200);② Android:`flutter build apk --debug` 冒烟——flm 的 android/build.gradle 是旧式 `apply plugin`、Manifest 带 `package` 属性、compileSdk 36/Kotlin 2.1.0,宿主是 AGP 9.1/Kotlin 2.4(flm buildscript classpath 还钉着 AGP 8.9.1/Kotlin 2.1.0,存在类路径冲突可能),兼容性以真实构建为准;**Android 冒烟失败出口钉死:先 vendor 本地拷贝做清理(Android 侧属 App 自身改动,无需额外授权)→ 仍败则切 D6 Dart 内联**(与 iOS 出口两选项相同,**次序相反**:Android 无需授权故 vendor 先行,iOS 改动须显式批准故 D6 优先);③ **iOS(在 mac 构建机上跑,Windows 开发机不可达)**:宿主 ios/ 已迁 Flutter SPM(pbxproj 含 XCLocalSwiftPackageReference)**且无 Podfile**,而 flm 仅 podspec(无 Package.swift)——pod-only 插件在 SPM 宿主上预期触发 Flutter 工具的 CocoaPods 回退(自动生成 Podfile,混编模式);**若 iOS 冒烟 `flutter build ios --no-codesign` 失败/被拒,出口优先级钉死:默认=放弃 flm 依赖、切 D6 Dart 内联合成**(~150 行、零插件依赖,iOS 彻底零接触,顺带根治 §3.2 缺陷 1/2——引言「iOS 零改动」硬约束下的唯一合规出口);备选=vendor 本地拷贝 path 依赖并为 iOS 补 Package.swift(SPM 化,iOS 侧类体仅注册 channel,移植面极小)——**此路属于 iOS 集成配置变更,须用户显式批准「允许 iOS 工程改动」才可用**,列为方案批准时的显式决策点;Android 侧 vendor 时顺手清理(去掉 Manifest 的 package 属性;flm build.gradle 已有 namespace)。**iOS 冒烟未过前,「iOS 零影响(D8)」不视为已证实**——D8 的实现断言以冒烟+§8-C 回归为准) |
| app/lib/services/motion_photo.dart | 新增(§5.1;**拆件预案:贴近 300 红线时按 探测内核/SEFT 兜底分支/文件版包装 三件拆**) |
| app/lib/services/motion_photo_capability.dart | 新增(§5.2) |
| app/lib/services/motion_photo_save.dart | 新增(§5.4 编排 + flm 封装注入接口 `MotionPhotoGenerator` + 输出自校验);**实施时若超 300 行硬顶(仓库既有行数约定,见 assets_upload_api.dart 头注释)按 编排/自校验 拆件**,§5.4 步骤号即拆分边界 |
| app/android/.../MainActivity.kt | + `ms/device_info` channel(~10 行) |
| app/lib/features/assets/upload_pick.dart | `_enqueueAlbumAsset` 插 Android 分支(§5.3)。**拆件前置:本文件现 294 行,分支+注释约 25-30 行必触 300 硬顶**——分支体抽 `@visibleForTesting` 纯编排函数放新文件 `android_motion_upload.dart`,worker 打包闭包同宿(见 upload_sheet 行),`_enqueueAlbumAsset` 只留一行调用 |
| app/lib/features/assets/upload_sheet.dart | 新增 `enqueueMotionPhotoUpload` 入队壳(§5.3)。**拆件前置:worker 全流程估百余行,本文件现 181 行必触 300 硬顶——worker 闭包本体落 `android_motion_upload.dart` 新文件**(与 upload_pick 拆件同宿),本文件只留入队壳;终态(成功/失败/取消)一律删临时、retry 从头重打包;复验失败降级普通轨原档直传;`enqueueLocalUpload` 既有签名不动 |
| app/lib/core/api/assets_api.dart | `downloadLink` + `variant` 可选参数 |
| app/lib/services/downloads.dart | `runDownloadJob` 顶部能力分流。**拆件前置:本文件现 243 行,分流+抽函数余量紧张**——`_runLegacyDownloadJob` 与共享收尾函数(原 :174-189 尾部语义)落 `legacy_download.dart` 新文件,downloads.dart 保留公共导出;`DownloadIo.link` 签名扩展为 `Future<String> Function(Asset, {String? variant})`(缺省不带键;测试假件同步演进,**编排层不得直接 `session.api!` 硬连**,维持注入测试约定);**`DownloadIo.fetch` 的 onProgress 演进为 `void Function(int doneBytes, int? contentLength)`**——现签名只回 doneBytes、totalBytes 由调用方预传(asset.sizeBytes),unpacked 补抓的真实 Content-Length 不外露,§5.4 步骤 3 的「复检一次」无处取数;**缺省实现须绕开 `assets_api.downloadTo`(其 onProgress 只回 frac,dio 内部的 t 未外露)直用 `presignedHttp.download` 把 `(c,t)` 的 t 透传出来**(或同步扩展 downloadTo 签名),现有调用方折算行为不变;D1 收尾的尾部语义(任一路成功→删临时+toast+`Notifier.taskFinished`,全败→`SaveAbortException`+保留取证,downloads.dart:174-189)在新编排中**抽共享私有函数复用**,两处不漂移 |
| app/lib/services/download_savers.dart | (仅文案)`downloadsOutcome` 成功 detail 里「重名自动加后缀」与源码行为(先删后插覆盖)相悖,顺手纠正;同款误导还有 downloads.dart 头注释「平台重名自动加后缀」——一并纠正。均属既有误导,与本方案无功能耦合 |
| 测试 | §7 |

后端 / web / iOS 代码**零改动**;Manifest **无新权限**(flm 写 cacheDir 私有目录免权限;合成产物入相册走 photo_manager 既有权限链 `requestPermissionExtend`,与 D1 静图路同款;**新路径不触 media_store_plus 入相册**,其 Dart 侧 `_sdkInt > 29` 才走 MediaStore insert(API 30+)/否则文件拷贝的分档差异对本次改动无影响——D1 保留路径的既有行为不变——其 `_sdkInt > 29` 分档意味着 API==29 设备走文件拷贝分支,属既有行为且仅 D1 保留路径可达,minSdk 29 下 API<29 本就不可达)。

## 6. 决策记录

- **D1 能力判定 = 厂商白名单 + SDK>=31,自写 10 行 MethodChannel。** 不引 device_info_plus(只要 3 字段);白名单常量表 google/xiaomi/redmi/oppo/oneplus/realme/vivo/iqoo(realme/oneplus 与 OPPO 同 ColorOS 生态,由 OPPO 验证推断)。**误含**的代价=该机存出的 Motion Photo 相册不播视频但静图完整(损失独立视频文件);**漏含**的代价=维持现状;宁可初期保守。**HUAWEI/samsung/honor 初始均排除,同一原则=相册对无 trailer 的纯 Google 格式回放识别未证**:华为另有私有「动态照片」格式(上传侧解析不了本就降级);三星拍摄产物为「GContainer XMP + SEFT trailer」混合形态(上传侧由 trailer 修正覆盖,§3.1,flm 亦仅自述 Samsung via Google Photos);honor(MagicOS)同未证。三者待真机(三星=§8-D 双验证)后逐一扩入白名单。SDK 门槛取 31(Android 12,2021+;GContainer 生态成型期)统一简化。
- **D2 下载输入 = 原始档优先 + 按需 unpacked 补抓。** Android 来源 livp(条目 jpg+mp4)一次下载直接合成零额外请求;iOS 来源(heic+mov)——**若 unpacked 未就绪(worker 未跑完)则首次 404→D1 收尾、重试即合成;就绪则首次即可合成(常态;Android 来源恒快路径零补抓)**;例外:超 200MB 或静图永久失败 livp 恒 404 不重派(§5.4 步骤 3,「下次即合成」不成立);iOS 来源 MOV 转码失败,后端恒交付 jpg-only zip → 恒走 D7 静图退化而非「重试即合成」(§5.4 步骤 3/D7 已覆盖,验收勿当缺陷)。不采用「unpacked 优先」:多数下载多一次往返,且 worker 故障时全员退化为 D1。iOS 来源 livp 的 unpacked 在上传完成时即并排派发(assets.py:360-364),**通常首次下载即可合成**;仅 worker 未跑完时才 404→D1(第二次起合成)。unpacked 不做轮询等待(worker 秒级-10s 级,等待体验差于本次降级)。
- **D3 保存形态 = 合成成功只入相册,不再 D1 双落盘、不写 Downloads 原档**(对齐 iOS「恢复实况即完成」语义,避免相册实况图+Downloads livp 双份冗余);**入相册用 photo_manager `saveImageWithPath`**(与 D1 静图路同 API:既有权限链、字节原样、**同名系统自动加后缀**——刻意不用 media_store_plus 入相册,其同名=先删后插覆盖替换,跨夹同名资产先后下载会静默丢旧文件,§2.4);**任何失败降级 = 完全回到现状 D1**(原始档已在手,零额外网络请求)。
- **D4 判定口径:上传按格式识别(无白名单),下载按机型白名单——两侧刻意分离。** 上传侧 probe 命中=该文件确是实况图(XMP 特征+区间+ftyp 三重守卫,误判趋零),转 livp 是对内容的忠实转档,**与机型回放能力无关**;老三星(OneUI 2.5+ 世代,主要对应 Android 10/11,GContainer 混合形态)与 Pixel 3/3a 世代/旧 OPPO(MicroVideo)被 SDK>=31 排除在下载白名单外,但它们**属于「支持实况图的安卓手机」**(目标②),上传侧不应被白名单连带排除——它们拍的实况图照样转 livp,只是本机下载时按白名单走现状 D1(回放能力未证实,保守)。目标③的「不支持」因此两侧口径不同:上传侧=格式不认识(probe 未命中→普通轨),下载侧=回放能力白名单外(D1 现状)。**探测只挂相册轨,file_picker 文件选择轨不接**(相册轨=系统媒体库,probe 语义可靠;file_picker 来源混杂——下载目录里的合成 jpg 再选上传会被转 livp,语义其实成立但保守未开,列遗留项待用户拍板)。
- **D5 格式支持:P0 = GContainer(含三星混合形态 trailer 修正)+ MicroVideo;P1(同批尽力)= 纯 SEFT(无 XMP 的老三星)。** GContainer 覆盖 Pixel/三星 OneUI 2.5+(混合形态)/2023+ 国产主流;MicroVideo 覆盖 Pixel 3/3a 世代/旧 OPPO/旧小米;纯 SEFT 独立 try 分支失败即降级,不阻塞 P0。GContainer v2 多 motion item(独立音轨,部分三星)不解析,降级普通轨(损失=该图当普通 jpg 上传,不丢数据)。华为私有格式不做(D1 已排除华为)。**已知保守边界(均安全降级普通轨,验收时勿误判为实现缺陷)**:旧 OPPO OLivePhoto 若仅带 OpCamera 字段(无 GCamera 标记);三星 HEIF 容器实况图(守卫 1 拦截,见验收 B.8);GContainer 规范允许的 image/png 主图(§5.3 的 jpg/jpeg 门与守卫 1 双重前置挡回,行为=现状)。
- **D6 flm 主选(用户指定),后路 = Dart 内联移植。** flm 风险:0.1.0、发布者未验证、下载量低;Android 实现 229 行纯 java.io 零三方依赖,通读发现**两个缺陷 + 一个接受项**(§3.2):①对整张主图搜首个 `ftyp`,高熵 JPEG 数据随机命中(12MB 图约 0.3%)会静默产出截断损坏文件——**以输出自校验兜住(§5.4 步骤 4b:定点读校验——XMP 段解析 + video 长度/首字节比对 + image 尾 32B 确定性比对,失败走 D1;禁全量回读),批量下载累积风险由此闭合**;②主线程同步 IO 阻塞 UI 数百 ms~秒级——记录取舍,真机验收关注掉帧,不可接受则换后路。后路 = 合成逻辑(JPEG 字节重组+XMP APP1 维护)内联为纯 Dart ~150 行(顺带根治两个缺陷:精确截断点已知、可 isolate 执行),接口已按注入设计(`MotionPhotoGenerator` 注入束),替换零波及编排层。**降级兜底边界:flm 任何 Exception 级异常/自校验失败 → D1;超 150MB 资产按大小闸门前置分流(§5.4 步骤 0,防原生 OOM Error 不可捕获)。**
- **D7 无视频 livp = saveImage 静图退化**(iOS 同语义);后端 unpacked「仅 jpg 的 zip」(视频转码失败降级)同样落此分支。
- **D8 iOS 零行为变化(代码层断言;集成层以 §5.5 冒烟③为前置)**:isSupported 门不动,flm 的 iOS 实现仅被集成、零调用;上传/下载 iOS 路径代码不动。宿主是 SPM 无 Podfile、flm 是 pod-only——集成兼容风险与处置见 §5.5 第一步③(冒烟失败默认出口=D6 Dart 内联,保住 iOS 零改动约束;vendor+SPM 化须用户显式批准)。
- **D9 探测守卫从严**:probe 命中必须同时满足 XMP 特征字段 + videoStart 区间合法 + `ftyp` box 头强特征;微信/截图等剥视频场景由此挡住,误判率趋零;代价是极小众容器变体(非 ftyp 开头的视频)降级普通轨,可接受。

## 7. 测试计划(全绿 + analyze 0 为交付门槛)

1. `test/services/motion_photo_test.dart`(新):构造字节级 fixture——
   - 阳例:GContainer(新建 XMP)/ GContainer(主图已含其他 XMP 字段)/ MicroVideo / **双标记并存且区间一致(flm 默认模板即此形态,下载自校验最常见输入)** / **GContainer+SEFT 三星混合形态**(XMP Item:Length=N + N 字节伪 mp4(ftyp 头)+ 伪 SEFH 块(L 字节)+ size(L)小端 4B + SEFT 签名 4B,断言拆分恰为 `[fileSize-L-8-N, fileSize-L-8)`、trailer 字节不入任何一侧、**命中轨=XMP(gcontainer)而非 SEFT 分支**;fixture 构造依据 §3.1 假说,冻结前须过 §8-D① 真机字节核对);GContainer fixture 同时含「Primary 无 Length」与「Primary Length="0"」两形态(防实现退化成「取首个 Item:Length」把 0 当 N);最小 JPEG 骨架(SOI+APP1(XMP)+EOI)+ 伪 MP4(含 ftyp box 头);
   - 阴例:普通 jpg 无 XMP / XMP 无 motion 字段 / Length 越界(>fileSize、<1024、videoStart<xmpEnd)/ 视频无 ftyp 头 / 非 JPEG 文件 / **Container:Directory 含 2 个 MotionPhoto item(v2 多段)** / **totalTrailerLen 非法(L 越界 24~4088/坏字节序)两断言(L 仅在尾签名存在时被读,「非法 L+无 SEFT 尾」不可构造):① 非法 L+尾签名+SEFH 可解析 → 落 SEFT 兜底后仍命中;② 非法 L+尾签名+SEFH 亦坏 → 终局 null** / **双标记并存但区间不一致 → null**;
   - 拆分自洽:probe 产物喂 `LivpService.pack` → `decode` 还原两端字节一致;
   - **文件版 `probeMotionPhotoFile` 窗口行为**(生产路径最易错处):XMP 恰落头 256KB 窗内/窗外(窗外 fail-safe null)、SEFT 尾签恰落尾 64KB 窗、定点 8 字节读偏移、XMP 轨命中后走 trailer 修正而非 SEFT 分支(互斥断言;大文件 fixture 用稀疏写构造);
   - **flm 真实输出形态回喂**(四族 XMP 模板 + Primary Length="0" 的构造产物,模拟 MotionPhotoGeneratorHtml 输出字节形态)必须命中——锁死「flm 产物 → 自校验」自产自证闭环;
   - (P1)纯 SEFT(无 XMP)阳例:SOI+EOI 最小图 + 尾部 SEFT/SEFH/MotionPhoto_Data 偏移 + trailer;断言 **XMP 轨未命中后由尾签名兜底进入**、两轨按「XMP 优先/SEFT 兜底」互斥。
2. `test/services/motion_photo_capability_test.dart`(新):白名单命中/越界、SDK 门槛、channel 异常 → false、注入覆盖。
3. `test/services/motion_photo_save_test.dart`(新):注入假 flm/media_store/link/download 的编排全分支——快路径合成 / **自校验失败→D1(对抗样本必须特制「image 半段被拦腰截断、video 尾与 XMP 长度完好」的产物字节——该形态下输出 image 尾 32B 必不等于输入尾段;只构造 video 侧畸形的用例对本防线是假绿)** / unpacked 补抓成功 / unpacked 404→D1 / heic 且补抓 404/解包异常→D1 / flm 异常→D1 / 无视频→saveImage(且不补抓 unpacked)/ **空间分档:free∈(4×,6×) 直接走 D1、free≥6× 走合成链、free≤4× 中止(checkSpace 相等即不足的保守语义,media_save.dart:275-278)** / **进度映射:首段完成时上报值 <1.0(0.95)、补抓段恒 0.95、无任何时刻 >0.95 且无后续回跳** / 临时目录与 cache 副本 finally 清理 / 进度与取消透传(含 fetch 后取消的删临时语义)/ 同名走 photo_manager(断言不触 media_store_plus 入相册)/ 权限拒绝→D1 收尾 / **fetch 网络异常→任务失败外溢(残缺临时不进 D1;补抓段同规则:403/5xx/超时外溢、仅 404 走 D1)** / 大小闸门:asset.sizeBytes>150MB 直接 D1 / **回落不重入 motion 分流**(步骤 0/1 走 _runLegacyDownloadJob,断言 capable 机回落无二次分流)/ freeBytes=null 放行进合成链。
4. `test/services/downloads_test.dart`(扩):capable 分流命中/不命中;`media_save_test.dart` **不回归**(矩阵未动,既有全组合用例原样通过)。
5. `test/features/android_motion_upload_test.dart`(**新建**;注意 upload_pick 已有外圈函数测试(upload_batch_report_test/upload_permission_test 测其 `@visibleForTesting` 函数),但 `_enqueueAlbumAsset` 本体私有且含平台通道——须走 §5.3 注入缝,新测试沿既有命名/注入习惯挂靠):入队侧:Android jpg 预筛命中→`enqueueMotionPhotoUpload`(filename='{base}.livp'、入队秒回不打包)、未命中/超 150MB/probe 抛错→普通轨原样(逐项捕获语义不变);worker 侧:复验命中**以复验新 plan 打包(弃入队 plan)**、**复验命中但 File.length()>150MB→按 f'{base}.jpg'/image/jpeg 降级且任务算成功**、复验 null 文件在→**降级普通轨(f'{base}.jpg'、image/jpeg)且任务算成功**、文件不存在→任务失败、打包 STORED(zip 条目 {base}.jpg/{base}.mp4、contentType=application/zip)、**终态(成功/失败/取消)一律删临时、retry 从头重打包**、上传异常=任务失败、**TOCTOU 后实际 size≠入队 totalBytes 时进度 clamp 不越界**、**并发两任务临时 livp 路径互不相同(唯一命名断言)**。
6. `assets_api` variant 参数:请求体序列化用例——**后端为 `variant: Literal["original","unpacked"] = "original"`(assets.py:1503),带 `"variant": null` 会被 pydantic 判 422(非 None 可选!)→ App 端缺省时**不携带该键**,传值仅 `"unpacked"`**;补一条「带 null 会 422」的认知锚点阴例注释。

## 8. 真机验收清单(交付后 tester 执行;本方案完成后 App 包走 debug 直装,不发版)

- **A. 支持实况图的安卓机(找一台 2023+ 小米/OPPO/vivo,系统相册能拍「实况/动态照片」)**:
  1. 相册拍实况图 → App 相册轨上传 → web/管理端看到 **.livp 资产**,预览可播实况短片(live-preview),宫格有「实况」角标;后端 livp 双 job 正常(thumbnail/live);
  2. 该资产在 App 下载 → 相册出现 `Pictures/{name}.jpg`(photo_manager `saveImageWithPath` 未传 relativePath → MediaStore Images 默认落 Pictures/ 根;**长按/查看时相册播放实况**);Downloads 无冗余 livp;
  3. 下载一个 iOS 拍摄来源的 livp(heic+mov)→ **unpacked 通常在上传完成时已由后端并排派发生成(assets.py:362-363),首次下载即可合成;若 worker 未跑完则首次 D1(相册静图+视频分存+Downloads livp),重试即合成;顺带观察:补抓段进度恒 0.95、无顶格回跳、终态 1.0**;
  4. 普通图片/视频的上传下载逐项回归不变;批量下载混合类型正常;
  5. **大样本专测(内存)**:上传+下载一条 >80MB 的长时实况图(低端安卓优先),观察上传打包与下载合成全程无 OOM 崩溃、无秒级 ANR(§5.4 步骤 0 的 150MB 闸门内残余风险的实证依据,不过则收紧闸门);**加测并发场景:两条 >80MB 实况图同时上传/同时下载(队列并发 2 顶格)**,观测双任务叠加油耗。
- **B. 不支持实况图回放的安卓机(老机型或非白名单品牌,如华为/三星——三星初始不在白名单,见 D1)**:
  6. 上传侧按**格式识别**不看白名单(D4):probe 命中的机型(如三星 OneUI 2.5+ 世代(Android 10/11)的混合形态实况图[trailer 修正——其字节细节与 MicroVideo 同属「fixture 锁实现、真机未证」证据强度,无三星真机时同 §8-E 标记]、旧 Pixel 的 MicroVideo)上传**仍转 .livp**(属目标②);probe 不命中的(华为私有格式实况图、trailer 修正失败的极端样本、普通图片)走普通 .jpg 轨(现状);普通图片上传回归;
  7. 下载 livp → D1 双落盘(现状),无「实况图」文案;
  8. 三星部分机型可用 **HEIF 容器**存实况图——probe 守卫 1(JPEG SOI)将其降级普通轨上传,**此为已知边界非 bug**(D5/遗留项 7);
  9. **观察项(D1 静图的 XMP 残留观感)**:安卓来源 livp 经 D1 双落盘存入的静图携带 motion 标记但无尾视频——motion-aware 相册(三星等)可能显示实况角标却播不出;已知取舍记录在案,是否剥离列遗留项 11。
- **C. iOS 回归**(模拟器/真机):实况上传 livp、下载恢复实况、角标预览——全链路不变;**新增互操作组合**:iOS 下载 Android 来源 livp(条目 jpg+mp4)走 `darwin.saveLivePhoto` 硬凑——已知边界(photo_manager 对任意照片+视频组合不保证成功,album.dart:5-7 注释自引上游 issue),失败走既有 share 兜底,不算回归。
- **D. (有条件)三星真机(扩白名单的前置验证;**①的字节核对同时是 SEFT 假说(§3.1)冻结 fixture 前的硬前置——无真机样本前 fixture 标「假说锁实现、真机未证」**)**:① 拍摄(混合形态:XMP+SEFT trailer)→ 上传,**先字节级核对:文件尾 8 字节为 size(L)+SEFT、App 拆分出的 video 首字节是 ftyp、mp4 独立可播且时长完整**;② 临时把 samsung 加入白名单直装包,下载 livp → 三星相册**原生**回放识别合成产物(纯 Google 格式、无 trailer)——双过则 samsung 正式扩入白名单,任一不过则维持排除(AppLog/字节样本回传分析);**顺带观察**:flm 对「Length 在 Semantic 前」变体 XMP 的 Primary Length 污染(§3.3 例外①)是否影响三星相册识别。老三星纯 SEFT 若无真机,以 fixture 单测为准,验收不强制。
- **E. (有条件,MicroVideo 语义校准)**:Pixel 3/3a 世代(2018-2019)或旧 OPPO / 旧小米任一(MicroVideo 格式;勿选 Pixel 3 之前的机型,无此格式)真机:拍实况 → 上传 → 核对 App 拆分的 video 字节边界(服务端 livp 内 mp4 可独立播放且时长完整)。**无此真机则 MicroVideo 支持标记为「fixture 锁实现、真机未证」**——守卫链保证解析偏差时安全降级普通轨,不损数据,后续真机到位再校准(遗留项 6)。

## 9. 风险与回退

| 风险 | 缓解 |
|---|---|
| flm 0.1.0 成熟度低 | Exception 级异常全降级 D1;**超 150MB 大小闸门前置分流**(OOM Error 原生不可捕获,§5.4 步骤 0);接口注入化,可换 Dart 内联实现(D6);真机 A2 首验 |
| flm ftyp 误命中→静默损坏产物(12MB 图约 0.3%,批量累积) | **入相册前输出自校验**(§5.4 步骤 4b:定点读校验——XMP 段解析 + video 长度/首字节比对 + **image 尾段确定性比对(输出尾 32B==输入尾 32B)**——损坏只体现在 image 半段,只查 video 侧零判别力;弃 EOI 容忍窗口径,防厂商 padding 系统性误拒),失败走 D1;对抗样本阴例单测锁死;另接受 flm APP1 段长补丁两边缘(>65535 截高位/误命中前段 FFE1,§3.2 缺陷 3) |
| flm 主线程同步 IO 阻塞 UI(数百 ms~秒级/张) | 记录取舍;真机验收 A 关注掉帧;不可接受换 Dart 内联(isolate, D6) |
| 上传批量串行打包卡 UI/整批 bytes 驻留/入队分钟级阻塞+3-6GB 临时共存(99×30-60MB) | **入队阶段只做三读预筛(秒回),打包延迟到 worker 执行时**(§5.3):同时存活临时 livp 被队列并发 2 封顶、compute isolate 打包零主 isolate 驻留、retry 从头重打包;真机验收 A 批量上传观察(含入队时延与磁盘占用) |
| 厂商相册对 GContainer 回放差异 | 白名单保守 + 常量表易扩;真机矩阵校准;误含最坏损失=静图完整、视频藏文件尾 |
| MicroVideo/SEFT 偏移语义属**假说**(flm 行为/权威三方实现互证,非官方规范直引) | fixture 锁实现;**SEFT 的 L+8 口径以 §8-D① 真机字节核对为冻结 fixture 硬前置**、MicroVideo 以 §8-E 校准(无真机标记「假说锁实现、真机未证」);解析失败一律安全降级 |
| unpacked 依赖 worker 健康 | 仅 iOS 来源二次下载场景用到;404 即降 D1,无阻塞无轮询 |
| 后端条目级上限错位(静图条目 100MB/workers/main.py `_LIVP_IMAGE_MAX_BYTES`,总量 200MB) | 上传侧 150MB 总量闸门不完全覆盖:jpg 条目 >100MB 的 livp 后端挑不到静图(无缩略图/live);算术上可达(jpg 101-149MB+≥1KB 视频)但**相机主图实际量级 12-50MB 远小于 100MB**,现实不可达;若真出现该形态后端静图永久失败(无缩略图/live)AppLog 可见,注记防后人误判闸门充分性/据错误论据放宽闸门 |
| 大实况图内存(4K 拍照 30-50MB;安卓长时实况可近百 MB,>iOS 轨量级) | 上传=worker 内 compute isolate 打包(瞬时峰值≈4× 原档,150MB 上限≈600MB,Dart 侧大分配失败一般**不可捕获**(VM 级终止而非 Exception,勿依赖 catch 降级),防线上靠 150MB 闸门压低概率,兜底=进程重启+启动恢复语义+遗留项 10 清扫;60-150MB 档低端机仍有卡顿/内存压力,§8-A5 观测)+流式轨+**原档 >150MB 降级普通轨**(§5.3);**两侧峰值均按单任务计,队列全局并发 2 极端下翻倍**(上传/下载混排两路同时打包/合成)——§8-A5 含并发双任务场景,后路=motion 打包/合成应用级串行锁;下载=150MB 闸门(flm 原生 2-3× 峰值,OOM Error 不可捕获,§5.4 步骤 0)+**低端机 60-150MB 档残余风险记档,§8-A 大样本专测**;真机校准后可收紧闸门 |
| probe 误判(非实况图被拆) | D9 三重守卫(XMP 特征+区间+ftyp);阴例单测覆盖 |
| 双通道 MethodChannel 兼容 | 10 行只读 channel,无状态;异常即 false 降级 |

回退:整个特性两个入口(upload 分支、download 分流)各自独立、互不依赖;任一出问题可单独摘除(删分支即回现状)。下载侧另有**编译期开关**=白名单常量表清空+重发版即全员降级现状(改常量需构建发版,非运行期开关;远程开关本期不做;上传侧格式识别无开关,回退=摘分支重发)。

## 10. 遗留项(不阻塞本期)

1. 华为/三星/荣耀扩白名单:回放识别未证(同一保守原则);三星=混合形态上传拆分+纯 Google 格式回放双验证(§8-D 为前置);均待真机后再议(白名单扩表即可开下载侧)。
2. file_picker 轨接 probe(下载目录合成 jpg 再上传转 livp):语义成立,保守未开,待用户拍板。
3. GContainer v2 多 motion item(独立音轨)解析。
4. flm 上游若停更/缺陷,内联 Dart 合成实现(D6 后路)。
5. 白名单细化到机型世代(当前只有 品牌+SDK 粒度,系统 API 不暴露更多;另注:redmi/iqoo 是 brand 不是 manufacturer,真机校准白名单时勿因这两项不命中而误判白名单失效,§5.2)。
6. 真机 §8-E 校准后,如 MicroVideo 语义与本方案 §3.1 有出入,以真机字节为准修正实现与 fixture(方案与实现同步更新)。
7. 三星 HEIF 容器实况图:probe 守卫 1(JPEG SOI)按设计降级普通轨(验收 B.8 已注明非 bug);如需支持另行扩展(HEIF 容器的 XMP 定位/拆分)。
8. 相册落点子目录收口:合成产物与 D1 静图路同落 `Pictures/` 根;若要收进 `Pictures/浣花视界/`,需真机确认 photo_manager 3.12 `saveImageWithPath` 的 relativePath 参数实际落点行为(RELATIVE_PATH 是否自动前缀 Pictures/)后再统一(D1 静图路是否同步收口一并议)。
9. m4v 视频条目的 livp(极小众):capable 机上按无视频退化(§5.4 步骤 3 注),如需对齐 D1 的 saveVideo 交付,可在快路径条件中放宽 mp4/m4v 并依赖 flm 对 m4v 的兼容性——未证,不做。
10. 进程死亡遗留清扫(上传+下载两侧):上传 motion 临时 livp(worker finally 不执行时 cache 遗留 ≤150MB)、下载侧补抓档残缺遗留、flm cacheDir 产物 `MVIMG_*`(正常路径步骤 6 已清,进程死亡同遗留)——启动清扫(按 motion_pack_/dl_/MVIMG 前缀)为可选后路,本期不做(同靠系统回收);另顺手项:`LivpService.unpackToFiles` 条目名拼路径未做 basename 净化(外部 livp 恶意条目名的理论穿越面,D1 今日即有、本方案未扩大,实施时顺手净化)。
11. D1 静图路的 motion XMP 残留剥离(§8-B9 观察项后续):如 motion-aware 相册(三星等)对「带实况标记却播不出」的观感问题属实,可在 D1 解包存图前对 jpg 条目剥 GCamera/Container 字段——涉及既有 D1 路径改动,待真机反馈再议。
