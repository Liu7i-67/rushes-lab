# 安卓实况图·小米机型官方动态照片 SDK 接入方案(2026-11-16)

> 周期铁律(用户拍板,贯穿全文的验收底线):**不影响其他机型**——google/oppo/oneplus/realme/vivo/iqoo
> 品牌设备与全部非 livp 下载路径的行为与当前 liuqi HEAD(0.1.15+19)逐字节一致;**仅在既有实况图
> 功能上新增 manufacturer=xiaomi 机型的官方 SDK 合成支持**。小米/红米(实报 manufacturer="Xiaomi")
> 是本周期唯一允许行为变化的机型集合,变化点恰两处:「合成器选择」与「MIUI 降级路径」(D2,
> 由静图改为 D1 双落盘)。

## 1. 背景

- 2026-11-16 小米14 真机反例:flm(flutter_live_motion 0.1.0)合成产物在 HyperOS 相册不播动,
  链路本身全绿(快路径→合成→三段自校验→入相册)。根因(联网实证):flm 模板缺小米相册要读的
  私有 Exif 标记(`0x8897` 等)+ PresentationTimestampUs 硬编码 0。
- 解法选型(用户拍板=方案 B):小米官方「动态照片 SDK」`com.xiaomi.camera:livephoto:1.0.3`
  (dev.mi.com 申请制),maven 账密已到手并验证(pom/metadata 双 200),已落本机
  `~/.gradle/gradle.properties`(xgLivephotoUser/xgLivephotoPass,机器级凭据,**绝不入仓库**)。
- 调研旁证(不进本方案实现,仅备后路):AssassinJY/live_motion_photos_convert 的字段组合在
  HyperOS 3 实测「livp 转单 jpg 相册可识别可播」;小米相册另有三方动图开关
  (motionPhotoThirdParty/isPlayableMotionPhoto)可能拦截结构正确的文件(真机排查项)。

## 2. SDK 事实清单(以 AAR 1.0.3 解包 javap + POM 原文实证为准)

- 制品:`com.xiaomi.camera:livephoto:1.0.3`(aar,61,458 字节,纯 Java/Kotlin 库,无 so、无资源)。
- POM 传递依赖(均 runtime,均真实存在于公共仓,已核原文):`androidx.appcompat:appcompat:1.1.0`
  (AndroidX;工程依赖图中已有更高版本 appcompat,Gradle 冲突解析取高,**不会降级现有依赖,
  无 jetifier/legacy 问题**)+ `com.adobe.xmp:xmpcore:5.1.3`(约 200KB)。
- 公共 API(javap 逐字):
  ```
  com.xiaomi.livephoto.MiLivePhotoTools:
    static boolean isDeviceSupportLivePhoto();
    static boolean isLivePhotoFile(String);
    static boolean isLivePhotoFile(Context, Uri);
    static boolean isLivePhoto(Context, String);
    static boolean isLivePhoto(Context, Uri);
    static MiLivePhotoInfo decodeLivephoto(Context, Uri, Uri, Uri);
    static MiLivePhotoInfo decodeLivephoto(String, String, String);
    static boolean muxLivephoto(Context, String, String, long, String);
    static boolean muxLivephoto(Context, String, String, long, String, boolean); // ← 本方案用
    static boolean muxLivephoto(Context, Uri, Uri, long, Uri);
    static boolean muxLivephoto(Context, Uri, Uri, long, Uri, boolean);
  com.xiaomi.livephoto.MiLivePhotoInfo: isMotionPhotoVersion/getType/getVersion/
    getVideoOffset(=视频字节数,视频在文件尾)/getVideoPresentationTimestampUs + setter 族
  ```
  签名语义:`muxLivephoto(ctx, imagePath, videoPath, videoPresentationTimestampUs, outPath,
  insertMediaStore) → boolean`,**返回布尔不抛异常**(Kotlin 侧仍需 try/catch 防虚拟机错误外溢);
  `videoPresentationTimestampUs` 传 0 时官方口径「不保证相册正常播放和编辑」(仍可识别)。
- 设备支持判定 `isDeviceSupportLivePhoto()`:HyperOS(`ro.miui.ui.version.code`≥816)且
  小米相册 versionCode>407621;**MIUI 一律 false(不识别三方合成动图)**。
- SDK 的 `isLivePhotoFile(String)` 读文件头 XMP 判「MicroVideo/MotionPhoto」关键词——本方案将其
  作为产物语义层校验 oracle(见 §4.4/§4.5)。

## 3. 方案总览(分流图,仅 manufacturer=xiaomi 分支为新增)

```
runDownloadJob 顶部(现状零改动):
  android + livp + motionPhotoCapable()(白名单+SDK≥31,现状逻辑不动)
    → runMotionPhotoDownload
        步骤 -1(新增,唯一新分支):
          xiaomi = await (xiaomiComposer ?? defaultXiaomiComposer)()
          xiaomi == null                → 非 xiaomi / 非 Android / device_info 通道异常
                                        → 一切照旧走 flm
          xiaomi.supported == false     → 小米+MIUI/旧相册 → fallbackLegacyDownload(D1 双落盘)
          xiaomi.supported == true      → 步骤 0-3 照旧(闸门/下载/解包/快路径或补抓)
                                        步骤 4:doGenerate 换 xiaomi.generate(channel mux)
                                          → 产物过双重自校验(**oracle 先于字节三段**:xiaomi.verifyProduct
                                            即 channel isLivePhotoFile 的 SDK oracle,字节校验在后)
                                          → 照旧 photo_manager saveImageWithPath 入相册
        其余路径(google/oppo/...白名单) → flm 合成,代码路径与今日完全一致
  非 livp / 非白名单 / iOS              → 现状,零改动
```

probe 判定语义(精确,保证「其他机型零影响」的失败安全方向):
1. 非 Android(`!kIsWeb && Platform.isAndroid` 不满足,含测试宿主/桌面/web)→ `null`
   (对齐 capability 模块同款显式平台门,**不靠 channel 异常兜**,iOS 上 flm 本就不被调用);
2. `ms/device_info` getInfo 异常/字段缺失 → `null`(此向失败=行为与今日完全一致,任何机型都
   不受波及;不缓存不记忆化,每次重试);
3. manufacturer 归一后 ≠ `xiaomi` → `null`(flm,零影响;**代价如实声明:所有白名单机型每次
   livp 下载多一次 device_info 无状态往返**,成本一次轻量 channel RPC,不优化——避免动
   capability 模块违反零改动清单);
4. = xiaomi 且 channel `isSupported` 返回 true → `(supported: true, generate: <mux 封装>,
   verifyProduct: <isLivePhotoFile 封装>)`;
5. = xiaomi 且 `isSupported` false / 通道异常 / 返回非 bool → `(supported: false, null, null)`
   → `fallbackLegacyDownload`(D2)。

## 4. 逐文件改动清单

### 4.1 `material-storage/app/android/build.gradle.kts`(根构建脚本,**不是 settings.gradle.kts**)
仓库声明的真源在根构建脚本 `allprojects { repositories { google(); mavenCentral() } }`(现状
3-8 行;settings.gradle.kts 的 repositories 属 pluginManagement,管插件不管依赖)。在
`mavenCentral()` 后追加:
```kotlin
// ① 定义置于现有 allprojects 块之前:
val xgUser = providers.gradleProperty("xgLivephotoUser").getOrElse("")
val xgPass = providers.gradleProperty("xgLivephotoPass").getOrElse("")
if (xgUser.isEmpty() || xgPass.isEmpty()) {
    logger.warn("⚠ 缺少小米动态照片 SDK maven 凭据(~/.gradle/gradle.properties 的 " +
        "xgLivephotoUser/xgLivephotoPass 两属性),livephoto 依赖将无法解析," +
        "配置见 docs/qdev/2026-11-16-xiaomi-motionphoto-sdk.md §4.1")
}
// ② 在现有 3-8 行 `allprojects { repositories { google(); mavenCentral() } }` 块内
//    mavenCentral() 之后插入以下 maven 块(**勿另建第二个 allprojects 块,样例仅展示插入物**):
maven {
    url = uri("https://repos.xiaomi.com/maven")
    content { includeGroup("com.xiaomi.camera") } // 只允许 livephoto 走此仓,防其他 group 元数据查询带凭据打小米仓
    credentials {
        username = xgUser
        password = xgPass
    }
}
```
(对齐 `app/build.gradle.kts` keystore 缺失告警先例:缺凭据给中文指引而非裸抛;凭据只存机器级
`~/.gradle/gradle.properties`,本机已配好并验证。**构建机迁移注意**:新构建机须先配该两属性。)

### 4.2 `material-storage/app/android/app/build.gradle.kts`
dependencies 追加:
```kotlin
implementation("com.xiaomi.camera:livephoto:1.0.3")
implementation("com.adobe.xmp:xmpcore:5.1.3") // POM 已传递声明,显式钉版双保险
```
无条件编译进 APK(D4:净增≈AAR 61KB + xmpcore ~200KB ≈ 0.26MB 量级;appcompat 走冲突解析
取高、预计零增量——以构建冒烟 APK 体积差实证为准,真机无感)。

### 4.3 `material-storage/app/android/app/src/main/kotlin/com/taoxiplan/huanhuashijie/MainActivity.kt`(现 26 行)
注册第二个 channel `ms/motion_photo`(与 `ms/device_info` 并列),三个 method。**线程模型
(钉子,勿省)**:`mux` 是秒级盘 IO(合成上限 150MB 源,§见 kMotionMaxSourceBytes),
`isLivePhotoFile` 也有头部读 IO——两者跑在 platform 主线程会冻结 UI/ANR(现有 `getInfo` 只读
Build 字段所以无害,不可比照)。因此本 channel 必须注册到**后台 TaskQueue**(Flutter 官方机制):
```kotlin
val taskQueue = flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue()
MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ms/motion_photo",
    StandardMethodCodec.INSTANCE, taskQueue)
    .setMethodCallHandler { call, result -> ... }
```
三个 method(`isSupported` 读系统属性+包版本,同走后台队列无害):
- `isSupported` → `try { MiLivePhotoTools.isDeviceSupportLivePhoto() } catch (e: Throwable) { false }`;
- `isLivePhotoFile` args=`{path}` → `try { MiLivePhotoTools.isLivePhotoFile(path) }
  catch (e: Throwable) { false }`(oracle,异常按 false);
- `mux` args=`{imagePath, videoPath, timestampUs, outPath}` →
  ```kotlin
  // StandardMessageCodec 把 <2^31 的 Dart int 解为 java.lang.Integer:
  // 必须经 Number 取值,直接 argument<Long>/as Long 会 ClassCastException(钉子,勿改)
  val ts = (call.argument<Number>("timestampUs") ?: 0L).toLong()
  val ok = try {
      MiLivePhotoTools.muxLivephoto(
          applicationContext, img, vid, ts, out, /*insertMediaStore=*/false,
      )
  } catch (e: Throwable) { result.error("mux_fail", e.toString(), null); return@setMethodCallHandler }
  result.success(ok)
  ```
  **insertMediaStore 恒 false(D1)**:入相册统一走既有 photo_manager 路径(命名/同名去重/
  toast/通知语义单一)。文件预计 ~80 行。

### 4.4 新文件 `material-storage/app/lib/services/motion_photo_xiaomi.dart`(预计 ~190 行,≤300 硬顶)
**测试注入缝(对齐 capability 模块 `isAndroidPlatform/fetchDeviceInfo` 先例,测试宿主零平台
通道)**:所有涉通道函数一律带 `@visibleForTesting` 注入参,缺省=真实通道实现——
- `typedef XiaomiComposer = Future<({bool supported,
  Future<String> Function({required String imagePath, required String videoPath})? generate,
  Future<bool> Function(String productPath)? verifyProduct})?> Function();`
  (generate 字段用**结构性函数类型**=MotionPhotoGenerator 的展开形,可互相赋值;避免新件
  import 回 motion_photo_save.dart 形成互指——依赖方向保持 save→xiaomi 单向);
- `defaultXiaomiComposer({bool? isAndroidPlatform,
  Future<Map<Object?, Object?>?> Function()? fetchDeviceInfo,
  Future<Object?> Function(String method, [Map<String, Object?>? args])? invokeSdk})`:
  按 §3 语义实现(自持一次 `ms/device_info` 调用,不复用 capability 模块的私有记忆化,
  理由见 §3-3 成本声明);**实现体整体再兜一层 try/catch(_)→null**——§3-2「意外异常≈今日
  行为」的承诺由结构保证(对齐 capability 件 catch 全兜先例),不靠分支枚举完备性;
- `muxXiaomiLivePhoto({required String imagePath, required String videoPath,
  required int timestampUs, required String outPath, invokeSdk}) → Future<String>`:
  channel `mux` 封装,**out 路径由本函数调用方(生成器闭包)生成并传入,本函数只负责调通道并
  在成功时原样返回 outPath**;`ok==false` 或通道异常 → **先静默删 out 半成品(幂等,防孤儿
  占盘——成功路径产物由编排层既有 `flmProduct` 变量 + `cleanIntermediates` 登记清理
  (motion_photo_save.dart:137-143,262,符号名沿用不重命名),失败路径编排层拿不到路径,删除责任
  在本函数)** → 再 `AppLog.error('motion', 'xiaomi mux 失败', e)` → 抛带 `xiaomi` 前缀的
  Exception(交编排层 catch 走 D1;步骤 4 既有 catch 文案 `'flm 合成异常'` 不改——xiaomi 异常
  经此文案时 reason 带 xiaomi 前缀+前条日志,可分诊;不改既有 catch 文案=最小化 diff,grep 证实现有用例并不依赖该字符串);
- `defaultVerifyXiaomiProduct(String productPath, {invokeSdk})`:channel `isLivePhotoFile`
  封装,**任何异常按 false**(fail-safe,对齐 verify 件全兜语义);
- 生成器适配闭包(并入 composer 返回的 generate):`({required imagePath, required videoPath})`
  签名对齐既有 `MotionPhotoGenerator`,内部:系统临时目录生成 out 路径(**钉后缀
  `<时间戳>_motion.jpg`**——入相册 MIME 由 title 的 .jpg 决定不受影响,钉后缀只为真机排障
  时容器语义零歧义)→ `extractPresentationTimestampUs`(纯函数,见下)→ mux → 返回 outPath;
- `extractPresentationTimestampUs(File image) → int?`:定点读头 256KB(`readFileRange` 复用
  `motion_photo_verify.dart:68`;窗口常量 `xmpHeadWindow` 复用 `motion_photo.dart:23`——
  两者不同宿主,新件 import 两处),正则取 `GCamera:MotionPhotoPresentationTimestampUs` 优先、
  `GCamera:MicroVideoPresentationTimestampUs` 次之(容忍单/双引号),无命中 → null;
  时间戳来源语义:安卓上传源 livp 的快路径 jpg 带 XMP 残留(原值可信);iOS 源补抓 unpacked
  的 jpg 无 motion XMP → null → 编排层兜底 0(D3)。

### 4.5 `material-storage/app/lib/services/motion_photo_save.dart`(现 298 行,硬顶 300 → 必须补偿拆件)
- **拆件前置(补偿行数)**:私有 `_fallbackLegacy`(284-298,15 行)迁至 `legacy_download.dart`
  并**改公开名 `fallbackLegacyDownload`**(私有名跨库不可 import;函数体零变化;原 99/115 两处
  调用点 + 新步骤 -1 共三处同步改名);
- 新增可选参 `XiaomiComposer? xiaomiComposer`(缺省=生产 composer;测试注入桩)+ 新增
  `import 'motion_photo_xiaomi.dart'`(净增 1 行);
- 步骤 -1(**插在现 83 行 `final doGenerate = …` 之前**,~5 行):
  `final xiaomi = await (xiaomiComposer ?? defaultXiaomiComposer)();`
  三分支:null→继续;/supported=false→`return fallbackLegacyDownload(asset, onProgress,
  token, io);`(位置参数,签名随迁零变化)/supported=true→留 `xiaomi.generate`;
- 生成器选择(现 83 行**原位改** 1 行):`final doGenerate = xiaomi?.generate ?? generate ??
  defaultMotionPhotoGenerator();`
- 步骤 4b 双重自校验(xiaomi 支路,**oracle 先于字节校验**,~5 行):`xiaomi?.generate != null`
  时先调 `(xiaomi!.verifyProduct ?? defaultVerifyXiaomiProduct)(product.path)`,false →
  D1(`'小米产物语义校验未过(SDK oracle)'`);oracle 通过后再走现状字节三段校验
  (verifyMotionProductWithInputs,不动);**字节校验失败时 D1 reason 追加矛盾信号标记**
  (如 `'(SDK oracle 已过——字节校验形态分歧,T3 校准点)'`)——理由:字节校验①就是 XMP 命中,
  后跑会先拒掉 oracle 本可识别的形态,oracle 沦为死代码;先跑 oracle+矛盾信号自动暴露
  R2 场景,双层任一失败=D1,fail-safe 方向与全链一致;
- 净变化 ≈ 298 -15 +14 ≈ 297 行,保持 ≤300 硬顶(实现时以实际行数复核,超顶再把 xiaomi 支路
  收口束整体下沉 §4.4 新件——与 §5.5 guardFastPathInputs 下沉先例同构);
- 库头注释(1-10 行)同步补步骤 -1 一句(仓库注释口径纪律)。

### 4.6 `AndroidManifest.xml` 唯一改动:包可见性(其余清单零改动)
SDK 的 `isDeviceSupportLivePhoto()` 要读 `com.miui.gallery` 的 versionCode;targetSdk≥30
(Android 11+)施行包可见性过滤,**livephoto-1.0.3 AAR 自带 manifest 已解包核实无任何
`<queries>` 声明**——不在主清单声明则 getPackageInfo 必 NameNotFoundException →
isSupported 恒 false → 功能在真机静默失效(P1 级坑,已实证)。在现有 `<queries>` 块内加:
```xml
<package android:name="com.miui.gallery" />
```
其余清单项零改动:SDK 文档要的 READ/WRITE_EXTERNAL_STORAGE 已带 maxSdkVersion 封顶
(READ→32/WRITE→29,AndroidManifest.xml:8,11),分区存储下 MediaStore 插入不需要新权限
(真机若见权限断言列入遗留,不预加 legacy 权限)。

### 4.7 零改动清单(审查必查)
`motion_photo_capability.dart` / `downloads.dart` / `motion_photo_refetch.dart` /
`motion_photo_verify.dart`(仅 import 被复用,不改本体)/ `media_save.dart`(D1 矩阵)/
上传侧全部 / iOS 侧全部 / `pubspec.yaml`(无新 Dart 依赖)/
`settings.gradle.kts`(依赖仓不在该文件,见 §4.1)。

## 5. 决策记录

- **D1 insertMediaStore=false,入相册仍走 photo_manager**:命名控制/同名系统加后缀/toast/通知
  全链单一路径,与 D1 降级、flm 支路共享收尾;依据=AssassinJY 实测同格式文件落盘即被相册识别。
  后路(真机若不识别):channel `mux` 加 insert 布尔参透传,改动点单一,已预留。
- **D2 小米+isSupported=false(MIUI/旧相册)→ fallbackLegacyDownload(D1 双落盘)**:小米官方口径
  MIUI 不识别三方合成动图,今日这些机器走 flm 产出「静图」用户观感=bug 本体;D1 双落盘(封面+
  视频+原档入 Downloads)严格更优。此为小米机型集合内的行为改进,属「新增小米支持」授权范围,
  不触其他品牌。
- **D3 时间戳:取快路径 jpg 残留 XMP 值,缺失兜底 0**:官方口径 0=「不保证播放/编辑」但仍可识别;
  AssassinJY 实测 0 亦识别可播。MOV still-image-time 解析需 MP4 timed metadata 栈,列遗留。
- **D4 依赖无条件入包**:不拆 flavor/不 compileOnly(代码被 MainActivity 直接引用,条件编译复杂度
  与 ~0.26MB 体积不成比例);运行期由 §3 probe 门控,非 xiaomi 机型永不触达 SDK 调用。
  appcompat 传递依赖经 Gradle 冲突解析取高,不降级现有依赖(§2 已核 groupId=androidx)。
- **D5 上传侧零接入**:小米相机拍的动图现状 probe(XMP+ftyp 守卫)已识别转 livp;SDK 只接
  下载合成,上传语义不变。
- **D6 flm 依赖保留**:google/oppo/…白名单机型继续 flm;不删依赖不删缺省生成器
  (「既有功能不得删」铁律,对齐 qdev 派发惯例)。

## 6. 测试计划

新 `test/services/motion_photo_xiaomi_test.dart`(全部经 §4.4 注入缝注假件,**零平台通道**,
与仓库测试风格一致;**invokeSdk 假件签名钉子**:类型含可选位置参,假件必须写成
`(method, [args]) async => …` 形态,单参闭包赋值会类型不匹配):
- composer 五分支(§3 语义逐条,注入 isAndroidPlatform/fetchDeviceInfo/invokeSdk 假件):
  非 Android→null;device_info 通道异常/字段缺失→null;非 xiaomi→null;xiaomi+isSupported
  true→三字段齐(generate/verifyProduct 非空);xiaomi+false/通道异常/返回非 bool→
  (false, null, null);
- `extractPresentationTimestampUs`:命中 MotionPhoto 优先/仅 MicroVideo/单双引号/无 XMP→null/
  窗外(>256KB)→null;
- mux 封装(注入 invokeSdk):ok=false→抛且日志;通道 error→抛;ok=true→原样返回 outPath;
  **长值锚:timestampUs>2^31(如 4_000_000_000)原样透传 invokeSdk 参数**(§4.3 装箱钉子的
  Dart 侧守门);
- `defaultVerifyXiaomiProduct`(注入 invokeSdk):通道异常→false;返回非 bool→false。

`test/services/motion_photo_save_test.dart` 连坐增补(直接调 runMotionPhotoDownload 的用例
统一显式注入 `() async => null` composer 桩;**例外**:经 runDownloadJob 的既有「回落不重入」
用例(downloads.dart 零改动无此参数)无法注入,依赖 probe fail-safe 方向兜底——Windows 宿主
平台门恒 null/Android 宿主通道异常亦 null,两宿主均安全,属已知且接受的例外):
- composer 返回 null → 走 flm 缺省(回归锚:断言 flm 假件被调);
- supported=false → **行为断言**(不新增 legacy 注入缝):FakeIo.savers 收到解包双存行为/
  Downloads 落盘发生 + flm 假件零调用(与既有 D1 用例同款断言方式);
- supported=true+假 generate+假 verifyProduct → saveImageWithPath 收到假产物路径、finishOk
  文案不变;oracle=false → D1 收尾;
- **顺序钉(oracle 先于字节校验)用副作用法断言**:oracle 假件返回 true 的同时截断产物文件尾
  (使后跑的字节校验必败)→ 断言 D1 reason 含 T3 矛盾信号标记——若字节校验先跑(实现倒序)
  则 oracle 无从截断、reason 无标记,顺序由此钉死(字节校验是真函数非注入件,调用序断言法
  不可行)。**观测缝**:D1 reason 只进 AppLog,须复用
  `test/core/session_restore_log_test.dart:44-51` 的 `captureLogs()`(AppLog 同步调
  debugPrint)先例捕获日志断言;或退化为行为等价断言(oracle 截尾+saved 空+Downloads 落盘
  发生,钉死顺序但不验标记字符串本体),两法择一,实现时不得静默放弃顺序钉;
- 既有全部用例断言不变(fl 支路文案/顺序零漂移)。

全量 `flutter test` 绿(基线≈1340:2026-11-16 user-delegation 合并后实测口径,以本周期合并实测为准)+`flutter analyze` 0;
Android debug APK 构建冒烟(gradle 依赖解析实证,凭据本机已备;顺带记录 APK 体积差修正
D4 量级)。

## 7. 验收清单

1. 单测/analyze/构建冒烟(§6);
2. 真机小米14(HyperOS,即报障机):下载 livp → 相册长按播动;exiftool 取证产物含
   `0x8897=1` + MicroVideo 族 XMP + 时间戳字段;
3. 回归锚:任一非小米安卓机(MuMu 或 tester 手机)下载 livp 行为与当前 liuqi HEAD 基线一致
   (flm 支路日志形态不变);
4. `scripts/changelog.md` 追加当日条目(App 分组,一句话+分支名)。

## 8. 风险与遗留

- **R1 构建机单点**:无 `~/.gradle/gradle.properties` 两属性的机器构建必失败(依赖解析;§4.1
  已配缺凭据中文指引)。迁移手册=本文档 §4.1;不为此做仓库内凭据或 AAR vendor(maven 方式
  已定,前期对话论证)。
- **R2 SDK 产物字节形态未实证**:三段字节校验内核认 GCamera 族,若 SDK 只写非 GCamera 字段,
  字节校验会系统性误拒(全量 xiaomi 下载落 D1)——oracle 层已兜识别语义,但「字节校验误拒而
  oracle 通过」的矛盾信号=真机校准点 T3:二选一(放宽 xiaomi 支路字节校验为长度+ftyp 两段 /
  扩 extractMotionXmp 兼容 SDK 形态),以真机 exiftool 取证为准,届时小改不另起周期。
- **R3 真机权限断言风险**:SDK 文档要求 legacy 存储权限,Manifest 已封顶未申全量;分区存储下
  理论无碍,真机若崩按遗留处理。**包可见性(§4.6)已实证前置处理**——AAR 无 queries 声明,
  不加 `<package android:name="com.miui.gallery"/>` 则 isSupported 恒 false 功能静默失效,
  已列包 A 必做项。
- **R4 MIUI xiaomi 行为变化**(D2):changelog 明示「小米旧系统(MIUI)从单静图改为分别保存
  封面与视频」。无 MIUI 真机时代位证据=supported=false 链路单测(§6);真机项挂遗留。
- **R5 mux 通道无超时**:后台 TaskQueue handler 若原生侧未 reply(进程死亡/引擎 detach),
  Dart Future 永挂、任务卡 running——与 flm 通道现状同形(非回归),刻意不设超时,进程死亡即
  随任务回收;同形态暴露面=SDK 内部死锁/极慢盘 IO 会把传输并发 2 的一个槽位挂住直至杀 App
  (并冻结同队列 motion 通道调用)——知情取舍,实施不得自行发明超时。
- **R6 后台 TaskQueue 串行排队**:全局传输队列并发 2(上传下载混排),两个 livp 下载并发时
  第二个任务的 probe/mux/oracle 调用会在同一串行后台队列排队等首个秒级 mux 完成——头部阻塞
  非死锁,刻意的简单性取舍,知情接受;
- **R7 SDK 后台线程兼容性未实证**:§2 仅核了公共 API 签名,SDK 内部线程假设未验(后台
  TaskQueue=HandlerThread 有 Looper,无 Looper 之忧;但若 SDK 内部强制绑定主线程 Handler,
  mux 在后台恒失败→全量 xiaomi 落 D1,且 CI 全绿只余真机暴露)——包 A 冒烟与 §7-2 真机时
  优先看 mux_fail 日志形态;
- **回滚口径**:整分支不合入即回滚,无数据/账号/迁移面;gradle 依赖、清单 queries、原生
  channel 与 Dart 接线全部随分支同退,liuqi 主线零残留;
- 遗留(不在本周期):MOV still-image-time 时间戳解析(D3 后路)/oppo·vivo 私有字段适配
  (另周期)/小米相册三方开关排查口径(真机 FAQ)/probe 复用 capability 记忆化省一次 RPC
  (§3-3,刻意不优化)。

## 9. 实施顺序(qdev 派发包切分建议)

1. 包 A(gradle+原生+清单):android/build.gradle.kts 仓凭据/app build.gradle.kts 依赖/
   AndroidManifest queries 包可见性一行/MainActivity.kt 三 method(后台 TaskQueue)+
   debug 构建冒烟(依赖解析+体积差记录);
2. 包 B(Dart):motion_photo_xiaomi.dart 新件 + motion_photo_save.dart 接线(含
   fallbackLegacyDownload 迁移改名)+ legacy_download.dart 归位;
3. 包 C(测试):两个测试文件增补 + 全量回归;
4. 收尾:changelog + analyze/test/build 三绿汇总。
