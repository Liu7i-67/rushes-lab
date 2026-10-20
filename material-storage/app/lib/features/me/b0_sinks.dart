/// B0② 双路落盘薄封装(插件通道,PC 单测不可达,真机验证):
///   ① photo_manager 存系统图库(复用 services/album.dart 现役 editor API;
///      livp 按 §6.1 D1① 解包后静态图+视频分别存);
///   ② media_store_plus 写 Downloads/浣花视界/(§6.1 D1② 原档直写)。
/// 两路永不抛出,统一回 [B0SinkOutcome](失败带完整错误,供真机取证)。
/// 结果模型与双路编排在 b0_sink_plan.dart(纯 Dart,可单测),此处转发导出。
library;

import 'dart:io';

import 'package:media_store_plus/media_store_plus.dart';
import 'package:photo_manager/photo_manager.dart';

import 'b0_sink_plan.dart';
import '../../services/app_log.dart';
import '../../services/livp.dart';

export 'b0_sink_plan.dart' show B0SinkOutcome;

/// 应用在 Downloads 下的子目录(§6「Download/浣花视界」)。
const kAppDownloadDir = '浣花视界';

Future<bool> _ensureGalleryPermission() async {
  final state = await PhotoManager.requestPermissionExtend();
  AppLog.info('b0', '相册权限 state=$state');
  return state.isAuth;
}

/// ① 图库路:成功 detail=落点(相册相对路径+文件名);失败=完整错误。
Future<B0SinkOutcome> b0SaveToGallery(File file, B0AssetKind kind) async {
  try {
    if (!await _ensureGalleryPermission()) {
      return const B0SinkOutcome.fail('未获相册权限(需「所有照片」+「修改/删除」授权)');
    }
    switch (galleryStrategyOf(kind)) {
      case B0GalleryStrategy.livpUnpackPair:
        final tmp = await Directory.systemTemp.createTemp('b0_unzip');
        final parts = await LivpService.unpackToFiles(
            await file.readAsBytes(), tmp);
        final img = await PhotoManager.editor.saveImageWithPath(
            parts.image.path, title: b0BaseName(parts.image.path));
        final vid = parts.video == null
            ? null
            : await PhotoManager.editor.saveVideo(parts.video!,
                title: b0BaseName(parts.video!.path));
        tmp.delete(recursive: true).ignore();
        final loc = [
          _assetLoc(img, '静态图'),
          if (vid != null) _assetLoc(vid, '实况短片'),
        ].join(';');
        return B0SinkOutcome.ok(loc.isEmpty ? '已存入系统图库' : loc);
      case B0GalleryStrategy.saveImage:
        final e = await PhotoManager.editor
            .saveImageWithPath(file.path, title: b0BaseName(file.path));
        return B0SinkOutcome.ok(_assetLoc(e, '已存入系统图库'));
      case B0GalleryStrategy.saveVideo:
        final e = await PhotoManager.editor.saveVideo(file,
            title: b0BaseName(file.path));
        return B0SinkOutcome.ok(_assetLoc(e, '已存入系统图库'));
      case B0GalleryStrategy.skip:
        return const B0SinkOutcome.fail('该类型不进图库(仅 livp/图片/视频,PoC 跳过)');
    }
  } catch (e) {
    AppLog.error('b0', '图库落盘失败', e);
    return B0SinkOutcome.fail('$e');
  }
}

String _assetLoc(AssetEntity? e, String fallback) {
  if (e == null) return fallback;
  final dir = e.relativePath; // Android:如 'Pictures/';iOS 为空
  return '${dir == null || dir.isEmpty ? '系统图库' : dir}${e.title}';
}

/// ② Downloads 路:media_store_plus → Downloads/浣花视界/(免权限,API 29+;
/// saveFile 内部会搬运并删除源文件——runBothSinks 已为各路复制独立副本,
/// 此处的删除只波及本路副本,不反噬图库路)。成功 detail=content uri + 常规路径。
Future<B0SinkOutcome> b0SaveToDownloads(File file) async {
  try {
    await MediaStore.ensureInitialized();
    MediaStore.appFolder = kAppDownloadDir;
    final info = await MediaStore().saveFile(
      tempFilePath: file.path,
      dirType: DirType.download,
      dirName: DirName.download,
    );
    if (info == null) {
      return const B0SinkOutcome.fail('saveFile 返回空(null),未落盘');
    }
    return B0SinkOutcome.ok(
        'Download/$kAppDownloadDir/${info.name}(重复名自动加后缀:'
        '${info.saveStatus.name}) uri=${info.uri}');
  } catch (e) {
    AppLog.error('b0', 'Downloads 落盘失败', e);
    return B0SinkOutcome.fail('$e');
  }
}
