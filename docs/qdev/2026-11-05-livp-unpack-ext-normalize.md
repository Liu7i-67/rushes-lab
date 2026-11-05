# qdev 需求文档:iOS livp 下载保存相册失败修复(解包扩展名内容规范化 + 实况恢复降级兜底)

日期:2026-11-05 | 分支:feat/livp-unpack-ext-normalize(自 liuqi@6424abb)| worktree:`E:/qbb/github_not_me/rushes-lab-feat-livp-unpack-ext`

## 背景与目标

**已实证根因**(2026-11-05 调研,prod 取证):外部工具导出的 livp 包内静态帧内容是真 HEIC
(ISOBMFF `ftyp` brand=`heic`),但条目名为 `IMG_0129.JPEG.heif`。iOS 端下载存相册链路
`AlbumService.saveLivpToAlbum` → photo_manager 3.12.0 `darwin.saveLivePhoto` 在原生层按
**文件扩展名**判 UTI(`.heif` → `public.heif`)建 ImageIO 写入目标,把 heic 内容重写进
heif 容器并注入 Live Photo 配对标识(MakerApple["17"])时 `CGImageDestinationFinalize`
失败,抛 `PlatformException(PMManager (-1), Failed to write Live Photo metadata to image file)`
→ 图库路失败 → 落入矩阵兜底分享面板(`media_save.dart` iOS livp 矩阵 `SaveRoute.share(onlyIfAllFailed: true)`)
→ 用户现象:「没保存到相册,弹出分享弹窗」。

**目标**:
1. 解包落盘前按**内容魔数**规范化静态帧/视频条目扩展名(治「错名」族,方案 1);
2. saveLivePhoto 失败时自动降级为「静态帧+视频分别存相册」(素材至少全部入库,用户拍板顺带);
3. 失败/降级文案中文化,不向用户直透英文异常(用户拍板顺带)。

## 功能点明细(逐条可验收)

- F1 livp 解包时,静态帧条目按内容嗅探规范扩展名:`IMG_0129.JPEG.heif`(heic 内容)
  落盘为 `IMG_0129.JPEG.heic`;`IMG_4921.heic`(heic)不变;`IMG_0531.JPG.jpeg`(JPEG)不变。
- F2 视频条目按内容嗅探:qt 内容(`ftyp` brand=`qt  `)无论条目名 `.mov`/`.mp4` 一律落盘
  `.mov`;mp4/isom 内容保持原名(PhotoKit 本就拒绝 mp4 容器,改名无益,如实保留)。
- F3 嗅探失败/未知内容(含 avif 等其他 ftyp brand)→ 保持原名落盘,零回归。
- F4 unpackToFiles 对外签名不变(`({File image, File? video}) Function(List<int>, Directory)`);
  pick/decode/pack/baseNameOf 行为零变化(打包轨、安卓 motion photo 合成轨不受影响)。
- F5 iOS `gallerySaver` 的 `saveLivePhoto` 动作:主路成功 → ok「已存入相册(实况照片)」(现状不变);
  主路抛错 → 自动降级调用 `saveLivpPairToGallery`(既有函数)分别存静态帧+视频;
  - 降级双成 → ok,用户文案含「非实况」如实注明;
  - 降级半成 → fail,文案如实分记(如「静态图已入库;视频存入失败:…」);
  - 降级全败 → fail(此后 runSavePlan 既有 share 兜底路照常触发)。
- F6 已知 Live Photo 错误模式中文映射(`_zhError`):"Failed to write Live Photo metadata to
  image/video file" → 中文;其他异常回落原文。降级与失败文案统一过该映射。
- F7 后端/上传/存储零改动(原始 livp 字节、PC 下载 zip 条目名均不动)。

## 组件拆分方案

| 组件 | 职责 | 文件 | 预估行数 |
| --- | --- | --- | --- |
| C1 内容嗅探 | 字节头 → 规范扩展名(图片/视频两函数,纯函数) | `material-storage/app/lib/services/livp.dart` | 134→~230 |
| C2 落盘规范化 | unpackToFiles 落盘前替换扩展名(仅最后一段) | 同上(同文件) | — |
| C3 实况降级编排 | 纯函数 `saveLivePhotoWithFallback`(注入 saveLivePhoto/降级件,可单测) | `material-storage/app/lib/services/download_savers.dart` | 222→~300 |
| C4 文案映射 | `_zhError` 中文映射 + gallerySaver catch 接线 | 同上(同文件) | — |
| C5 汇总文案支持 | `SinkOutcome.ok` 增可选 `okOverride`;`saveSummary` 成功区优先用它 | `material-storage/app/lib/services/media_save.dart` | 282→~300 |

依赖关系:C1/C2 与 C3/C4/C5 无相互 import 依赖,可并行;gallerySaver 最终接线依赖 C1(规范化让
saveLivePhoto 拿到 `.heic` 名)与 C3(降级),验收期联跑。

**可复用资产**:降级直接复用既有 `saveLivpPairToGallery`(`download_savers.dart:85`,
Android D1① 同款「解包双存分别计成败」)+ `livpPairOutcome`;嗅探参考后端 `workers/main.py`
`_LIVP_IMAGE_EXTS` 口径。**既有功能不得删**:pick/decode/pack/baseNameOf、矩阵与
`media_save_test` 全组合断言、`livpPairOutcome` 语义(P2-3 分别计成败)一律保留。

单文件长度约束:所有改动文件 ≤500 行,写前预判超限先拆工具文件。

## 数据库修改方案

不涉及。

## 接口定义

全部为 App 内部 Dart 接口(无网络接口):

```dart
// livp.dart 新增(公开,供测试与复用):
/// 图片字节头(建议 zip 条目前 16 字节)→ 规范扩展名(小写无点);无法识别 → null。
/// 规则:bytes[4..8]=='ftyp' 且 brand(bytes[8..12]):
///   heic/heix/hevc → 'heic';mif1/msf1 → 'heif';其他 brand → null;
/// FF D8 FF → 'jpeg';89 50 4E 47 → 'png';不足 12 字节/其他 → null。
String? sniffImageExtFromBytes(List<int> head);

/// 视频字节头 → 规范扩展名;仅 ftyp brand=='qt  ' → 'mov';其余(含 isom/mp42)→ null。
String? sniffVideoExtFromBytes(List<int> head);

// unpackToFiles 行为变更(签名不变):
//   静态帧/视频条目落盘前:ext=sniff{Image,Video}ExtFromBytes(条目前 16 字节);
//   ext!=null 且 != 当前小写扩展名 → 落盘名替换最后一段扩展名;null → 原名。

// download_savers.dart 新增:
/// 实况保存+降级编排(纯函数,可注入单测):
/// [saveLivePhoto] 抛错 → 调 [fallbackPair](生产=saveLivpPairToGallery 注入);
/// fallbackPair ok → SinkOutcome.ok(附 okOverride 含「非实况」注明);fail → fail(如实汇总)。
Future<SinkOutcome> saveLivePhotoWithFallback(
  File file, {
  required Future<void> Function() saveLivePhoto,
  required Future<SinkOutcome> Function(File file) fallbackPair,
});

/// 已知错误模式中文映射;未命中回落 '$e'。
String zhError(Object e);

// media_save.dart 变更:
class SinkOutcome {
  const SinkOutcome.ok(this.detail, {this.okOverride});  // detail 语义不变
  final String? okOverride;  // 成功展示文案覆盖(saveSummary 用);fail 路不适用
}
// saveSummary:成功区 `oks.add(o.outcome.okOverride ?? o.route.okText)`,其余不变。
```

## App 改动点 / 后端改动点

- App:`livp.dart`(C1/C2)、`download_savers.dart`(C3/C4)、`media_save.dart`(C5)。
- 后端:不涉及(零改动)。

## 测试功能点

- T1 嗅探表驱动:`ftyp`+heic/heix/hevc→heic;mif1/msf1→heif;`ftyp`+avif/其他→null;
  FF D8 FF→jpeg;PNG 魔数→png;短字节(<12)→null;全零→null。
- T2 unpackToFiles 规范化:heic 内容 `.heif` 名 → 落盘 `.heic`;正确命名(heic/JPEG/mov)
  幂等不变;qt 内容 `.mp4` 名 → 落盘 `.mov`;mp4 内容 → 原名;嗅探失败 → 原名;双重扩展名
  `IMG_0129.JPEG.heif` → `IMG_0129.JPEG.heic`(基名段不损);视频为 null(无视频 livp)不炸。
- T3 `saveLivePhotoWithFallback`:主路成功不触发降级;主路抛 PlatformException → 降级双成
  ok(okOverride 含「非实况」);降级半成 fail 如实分记;降级全败 fail 含中文原因。
- T4 `zhError`:image/video 两模式中文;未知 PlatformException 回落原文。
- T5 `saveSummary`:`okOverride` 优先;无 `okOverride` 时行为与既有断言一致(回归)。
- T6 回归:`media_save_test` 全组合矩阵、`livp_test`/`livp_base_name_test` 既有、
  `download_savers_test` 既有(P2-3 分别计成败/临时清理)、`motion_photo_test` 系列(pack 轨)、
  `downloads_test` 全绿。

## 模糊点与决策记录

1. **是否顺带降级兜底** → 用户拍板(2026-11-05):顺带加。理由:heic 命名正确的包
   (IMG_4921 族)photo_manager 能否注入成功无真机实证,降级保证任何原因失败时素材至少入库。
   注:系统内暂搜不到 IMG_4921.livp(疑权限/项目不可达),真机判别推迟到测试包发版后。
2. **失败文案中文化** → 用户拍板:顺带做(F6)。
3. **brand 映射边界**:heic/heix/hevc→`.heic`;mif1/msf1→`.heif`(保持现状,不引入新风险);
   avif 等其他 brand 不动。heix/hevc/heim 属 HEVC 编码家族;实测踩中 brand=heic,清单从保守。
4. **视频条目规范化仅 qt→mov**:mp4 内容改名无用(PhotoKit 拒容器),保持原样如实失败,
   不做转码(超 scope)。
5. **可行性评估**:改动面 App 端 3 文件+测试,无迁移无 FGA,成本小,可行(红线通过)。
