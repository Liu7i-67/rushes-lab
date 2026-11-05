/// 下载落盘平台执行件(方案 §6.1;B0② PoC 薄封装正式化):
/// 图库路(photo_manager)/ Downloads 路(media_store_plus)/ 分享路(share_plus)
/// / 可用空间探测(df)。全部只经 [PlatformSavers] 注入束被 runSavePlan 调用,
/// PC 单测注入假件不触平台通道。
///
/// 钉子(2026-10-20 B0 真机实证,沿用):
/// - media_store_plus 0.1.3 saveFile **成功亦返 null**,勿以返回值判成败,
///   以无异常为准([downloadsOutcome] null→ok);
/// - saveFile 搬运后会**无条件删源文件** → 多路并发副本在 media_save.runSavePlan。
library;

import 'dart:io';

import 'package:media_store_plus/media_store_plus.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

import 'album.dart';
import 'app_log.dart';
import 'livp.dart' show LivpService;
import 'media_save.dart';

/// 应用在 Downloads 下的子目录(§6「Download/浣花视界」)。
const kAppDownloadDir = '浣花视界';

Future<bool> _ensureGalleryPermission() async {
  final state = await PhotoManager.requestPermissionExtend();
  AppLog.info('download', '相册权限 state=$state');
  return state.isAuth;
}

String _assetLoc(AssetEntity? e, String fallback) {
  if (e == null) return fallback;
  final dir = e.relativePath; // Android:如 'Pictures/';iOS 为空
  return '${dir == null || dir.isEmpty ? '系统图库' : dir}${e.title}';
}

/// 图库路(photo_manager):saveImage/saveVideo 直存;livp 按动作解包双存
/// (Android D1①)或 saveLivpToAlbum 恢复实况(iOS 现役,失败自动降级双存,
/// 见 [saveLivePhotoWithFallback]);永不抛出,失败文案经 [zhError] 中文化。
Future<SinkOutcome> gallerySaver(File file, GalleryAction action) async {
  try {
    if (!await _ensureGalleryPermission()) {
      return const SinkOutcome.fail('未获相册权限(需「所有照片」+「修改/删除」授权)');
    }
    switch (action) {
      case GalleryAction.saveLivpPair:
        // Android D1①:解包→静态图+视频分别存图库、分别计成败;解包临时
        // finally 必清(P2-3:子存任一失败不再泄漏 livp_unpack 目录)
        return await saveLivpPairToGallery(
          file,
          saveImage: (f) => PhotoManager.editor.saveImageWithPath(
            f.path,
            title: baseNameOf(f.path),
          ),
          saveVideo: (f) =>
              PhotoManager.editor.saveVideo(f, title: baseNameOf(f.path)),
        );
      case GalleryAction.saveLivePhoto:
        // iOS:解包→darwin saveLivePhoto 恢复实况(AlbumService 现役,B0 留用);
        // 主路失败自动降级「静态图+视频分别存相册」,素材至少全部入库(C3)
        return await saveLivePhotoWithFallback(
          file,
          saveLivePhoto: () async =>
              AlbumService.saveLivpToAlbum(await file.readAsBytes()),
          fallbackPair: (f) => saveLivpPairToGallery(
            f,
            saveImage: (img) => PhotoManager.editor.saveImageWithPath(
              img.path,
              title: baseNameOf(img.path),
            ),
            saveVideo: (v) =>
                PhotoManager.editor.saveVideo(v, title: baseNameOf(v.path)),
          ),
        );
      case GalleryAction.saveImage:
        final e = await PhotoManager.editor.saveImageWithPath(
          file.path,
          title: baseNameOf(file.path),
        );
        return SinkOutcome.ok(_assetLoc(e, '已存入相册'));
      case GalleryAction.saveVideo:
        final e = await PhotoManager.editor.saveVideo(
          file,
          title: baseNameOf(file.path),
        );
        return SinkOutcome.ok(_assetLoc(e, '已存入相册'));
    }
  } catch (e) {
    AppLog.error('download', '图库落盘失败', e);
    return SinkOutcome.fail(zhError(e));
  }
}

/// Live Photo 已知错误模式串(image/video 两路,En=英文原串,Zh=中文映射句;
/// zhError 与 zhifyComposite 共用同一对,收敛为文件级常量防双处副本漂移)。
const _lpMetaFailImageEn = 'Failed to write Live Photo metadata to image file';
const _lpMetaFailVideoEn = 'Failed to write Live Photo metadata to video file';
const _lpMetaFailImageZh = '系统无法为静态帧写入实况标识';
const _lpMetaFailVideoZh = '系统无法为视频写入实况标识';

/// 已知 Live Photo 错误模式中文映射(F6/C4):photo_manager darwin
/// saveLivePhoto 按扩展名判 UTI 建 ImageIO 写入目标,注入 Live Photo 配对
/// 标识失败时抛的 PlatformException message 含固定短语,直透英文对用户无意义
/// → 映射为可读中文;未命中模式回落原文(`'$e'`)。gallerySaver 外层 catch
/// 统一过此映射,不向用户直透英文异常。
String zhError(Object e) {
  final s = '$e';
  if (s.contains(_lpMetaFailImageEn)) {
    return _lpMetaFailImageZh;
  }
  if (s.contains(_lpMetaFailVideoEn)) {
    return _lpMetaFailVideoZh;
  }
  return s;
}

/// 复合文案中文净化(F6 补强):对文本中出现的两个已知 Live Photo 英文错误
/// 模式做**子串替换**(与 [zhError] 同两句中文),其余文本原样保留——
/// livpPairOutcome 复合分记(「静态图已入库(...);实况短片失败:...」)的
/// 结构必须不动;无模式命中返回原文。勿用 [zhError] 整串处理复合文案:
/// 那会把「静态图已入库」等分记一并吞掉。
String zhifyComposite(String text) {
  return text
      .replaceAll(_lpMetaFailImageEn, _lpMetaFailImageZh)
      .replaceAll(_lpMetaFailVideoEn, _lpMetaFailVideoZh);
}

/// 实况保存+降级编排(C3,纯函数注入闭包可单测):主路 [saveLivePhoto]
/// 成功 → ok「已存入相册(实况照片)」(现状文案不变);主路抛错(任何异常)
/// → 调 [fallbackPair]「静态图+视频分别存相册」(生产注入 [saveLivpPairToGallery])
/// ——双成 → ok(okOverride 注明「非实况」,saveSummary 成功展示优先取它,
/// detail 仍保留降级落点);半成/全败 → fail(文案经 [zhifyComposite] 净化
/// 已知英文模式,**复合分记结构保留**——已入库的一半仍如实分记,iOS 矩阵
/// share 兜底路照常由 runSavePlan 触发)。fallbackPair 自身抛错 → 同样
/// 收口 fail(日志与文案均可回溯),不外溢到 gallerySaver 外层 catch。
Future<SinkOutcome> saveLivePhotoWithFallback(
  File file, {
  required Future<void> Function() saveLivePhoto,
  required Future<SinkOutcome> Function(File file) fallbackPair,
}) async {
  try {
    await saveLivePhoto();
    return const SinkOutcome.ok('已存入相册(实况照片)');
  } catch (e) {
    // 主路根因仅进 AppLog 不进用户文案(避免 toast 冗长);排查入口 =
    // AppLog 'download' '实况恢复失败,降级为静态图+视频分别存相册'
    AppLog.error('download', '实况恢复失败,降级为静态图+视频分别存相册', e);
    final SinkOutcome fb;
    try {
      fb = await fallbackPair(file);
    } catch (fe) {
      AppLog.error('download', '降级路也失败', fe);
      // zhError 先整句映射已知模式(未命中回落原文),zhifyComposite 再子串兜底
      return SinkOutcome.fail(zhifyComposite(zhError(fe)));
    }
    if (fb.isOk) {
      return SinkOutcome.ok(fb.detail, okOverride: '已存入相册(静态图与视频分别保存,非实况)');
    }
    // F6:fail 文案过 zhifyComposite 净化已知英文模式,复合分记结构保留
    return SinkOutcome.fail(zhifyComposite(fb.detail));
  }
}

/// livp 解包双存整路(Android D1①;P2-3):解包临时目录 finally 必清——
/// 子存任一失败/解包本身抛错都不再泄漏 livp_unpack 目录;静态图与实况短片
/// **分别计成败**(见 [livpPairOutcome]),已入库的一半不并入「整路失败」误报。
/// [unpackParent] 仅测试注入(观测临时目录清理),缺省系统临时。
Future<SinkOutcome> saveLivpPairToGallery(
  File file, {
  required Future<AssetEntity?> Function(File image) saveImage,
  required Future<AssetEntity?> Function(File video) saveVideo,
  Directory? unpackParent,
}) async {
  final tmp = await (unpackParent ?? Directory.systemTemp).createTemp(
    'livp_unpack',
  );
  try {
    final parts = await LivpService.unpackToFiles(
      await file.readAsBytes(),
      tmp,
    );
    return await livpPairOutcome(
      image: parts.image,
      video: parts.video,
      saveImage: saveImage,
      saveVideo: saveVideo,
    );
  } finally {
    tmp.delete(recursive: true).ignore();
  }
}

/// livp 静态图+实况短片分别存图库,单路内分别计成败(P2-3):
/// - 全成 → ok(两落点);
/// - 有半成 → fail,但文案如实分记(如「静态图已入库(…);实况短片失败:…」),
///   让用户/错误上报看得到已入库的一半,而非整路失败一锅端;
/// 存图抛错由本函数收口为 SinkOutcome.fail,不再外溢。
Future<SinkOutcome> livpPairOutcome({
  required File image,
  required File? video,
  required Future<AssetEntity?> Function(File) saveImage,
  required Future<AssetEntity?> Function(File) saveVideo,
}) async {
  AssetEntity? img;
  Object? imgErr;
  try {
    img = await saveImage(image);
  } catch (e) {
    imgErr = e;
  }
  AssetEntity? vid;
  Object? vidErr;
  if (video != null) {
    try {
      vid = await saveVideo(video);
    } catch (e) {
      vidErr = e;
    }
  }
  if (imgErr == null && vidErr == null) {
    final loc = [
      _assetLoc(img, '静态图'),
      if (video != null) _assetLoc(vid, '实况短片'),
    ].join(';');
    return SinkOutcome.ok(loc.isEmpty ? '已存入相册' : loc);
  }
  final facts = <String>[
    if (imgErr != null) '静态图失败:$imgErr' else '静态图已入库(${_assetLoc(img, '静态图')})',
    if (video != null)
      vidErr != null ? '实况短片失败:$vidErr' : '实况短片已入库(${_assetLoc(vid, '实况短片')})',
  ];
  return SinkOutcome.fail(facts.join(';'));
}

/// saveFile 返回值 → 结果(纯函数;B0 用例沿用,单测锁死「null 亦成功」语义):
/// info 非 null → detail=路径+saveStatus+uri;null → 按成功提交处理。
/// 文案钉子:同名落地=insert 前先按 DISPLAY_NAME+RELATIVE_PATH 删除同名列
/// 再插入,**先删后插覆盖替换**(§2.4,非自动加后缀——0.1.3 行为实证纠正)。
SinkOutcome downloadsOutcome(SaveInfo? info) {
  if (info == null) {
    return const SinkOutcome.ok(
      'Download/$kAppDownloadDir/(此版本 saveFile '
      '成功亦返回 null,未带回文件信息;同名先删后插覆盖)',
    );
  }
  return SinkOutcome.ok(
    'Download/$kAppDownloadDir/${info.name}(同名先删后插覆盖:'
    '${info.saveStatus.name}) uri=${info.uri}',
  );
}

/// Downloads 路(media_store_plus):Downloads/浣花视界/,免权限(API 29+),
/// 重名自动加后缀;无异常即成功(返回 null 亦是成功,见 [downloadsOutcome])。
Future<SinkOutcome> downloadsSaver(File file) async {
  try {
    await MediaStore.ensureInitialized();
    MediaStore.appFolder = kAppDownloadDir;
    final info = await MediaStore().saveFile(
      tempFilePath: file.path,
      dirType: DirType.download,
      dirName: DirName.download,
    );
    return downloadsOutcome(info);
  } catch (e) {
    AppLog.error('download', 'Downloads 落盘失败', e);
    return SinkOutcome.fail('$e');
  }
}

/// 分享路(share_plus,iOS livp 原档兜底/other 面板):拉起面板即算成功,
/// 用户可选「存储到文件」;面板内取消不算失败(不抛错)。
Future<SinkOutcome> shareSaver(File file) async {
  try {
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    return const SinkOutcome.ok('已弹出分享面板,可选「存储到文件」');
  } catch (e) {
    AppLog.error('download', '分享面板失败', e);
    return SinkOutcome.fail('$e');
  }
}

/// 平台执行件默认束(生产;测试注入假束覆盖)。
PlatformSavers defaultSavers() => PlatformSavers(
  gallery: gallerySaver,
  downloads: downloadsSaver,
  share: shareSaver,
);

/// 可用空间探测(df -k;Android toybox 可用;iOS 沙盒无 df → null 放行)。
/// dart:io 无可用空间直接 API 且本批不新增包,故取系统 df;解析失败一律
/// null(未知)→ 预检放行不阻断。
Future<int?> processFreeBytes(String dirPath) async {
  try {
    final r = await Process.run('df', ['-k', dirPath]);
    if (r.exitCode != 0) return null;
    final lines = (r.stdout as String).trim().split('\n');
    if (lines.length < 2) return null;
    final cols = lines.last.trim().split(RegExp(r'\s+'));
    if (cols.length < 4) return null;
    final kb = int.tryParse(cols[cols.length - 3]); // Available 列
    return kb == null ? null : kb * 1024;
  } catch (_) {
    return null;
  }
}
