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
/// (Android D1①)或 saveLivpToAlbum 恢复实况(iOS 现役);永不抛出。
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
          saveImage: (f) => PhotoManager.editor
              .saveImageWithPath(f.path, title: baseNameOf(f.path)),
          saveVideo: (f) =>
              PhotoManager.editor.saveVideo(f, title: baseNameOf(f.path)),
        );
      case GalleryAction.saveLivePhoto:
        // iOS:解包→darwin saveLivePhoto 恢复实况(AlbumService 现役,B0 留用)
        await AlbumService.saveLivpToAlbum(await file.readAsBytes());
        return const SinkOutcome.ok('已存入相册(实况照片)');
      case GalleryAction.saveImage:
        final e = await PhotoManager.editor
            .saveImageWithPath(file.path, title: baseNameOf(file.path));
        return SinkOutcome.ok(_assetLoc(e, '已存入相册'));
      case GalleryAction.saveVideo:
        final e = await PhotoManager.editor
            .saveVideo(file, title: baseNameOf(file.path));
        return SinkOutcome.ok(_assetLoc(e, '已存入相册'));
    }
  } catch (e) {
    AppLog.error('download', '图库落盘失败', e);
    return SinkOutcome.fail('$e');
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
  final tmp =
      await (unpackParent ?? Directory.systemTemp).createTemp('livp_unpack');
  try {
    final parts =
        await LivpService.unpackToFiles(await file.readAsBytes(), tmp);
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
    if (imgErr != null)
      '静态图失败:$imgErr'
    else
      '静态图已入库(${_assetLoc(img, '静态图')})',
    if (video != null)
      vidErr != null
          ? '实况短片失败:$vidErr'
          : '实况短片已入库(${_assetLoc(vid, '实况短片')})',
  ];
  return SinkOutcome.fail(facts.join(';'));
}

/// saveFile 返回值 → 结果(纯函数;B0 用例沿用,单测锁死「null 亦成功」语义):
/// info 非 null → detail=路径+saveStatus+uri;null → 按成功提交处理。
SinkOutcome downloadsOutcome(SaveInfo? info) {
  if (info == null) {
    return const SinkOutcome.ok('Download/$kAppDownloadDir/(此版本 saveFile '
        '成功亦返回 null,未带回文件信息;重名自动加后缀)');
  }
  return SinkOutcome.ok(
      'Download/$kAppDownloadDir/${info.name}(重复名自动加后缀:'
      '${info.saveStatus.name}) uri=${info.uri}');
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
