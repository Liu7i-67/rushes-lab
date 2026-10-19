/// AlbumService — iOS 相册实况照片读写桥(photo_manager 3.12 实测 API)。
///
/// ⚠ 本文件 iOS 专属能力只能真机验证(PC/Android 走不通):
///   - 读:AssetEntity.originFile(静态帧原文件)+ originFileWithSubtype(配对视频)
///   - 写:PhotoManager.editor.saveLivePhoto(imageFile, videoFile, title)
///     (底层 PHAssetCreationRequest + .pairedVideo;原配对文件可靠,
///      任意照片+视频硬凑不保证成功 — flutter_photo_manager#1009)
/// 选择器 UI 用 wechat_assets_picker(微信风格,onlyLivePhotos 过滤)。
library;

import 'dart:io';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:path_provider/path_provider.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

import 'app_log.dart';
import 'livp.dart';

class AlbumService {
  static bool get isSupported => !kIsWeb && Platform.isIOS;

  static Future<void> ensurePermission() async {
    final state = await PhotoManager.requestPermissionExtend();
    AppLog.info('album', '相册权限 state=$state');
    if (!state.isAuth) {
      throw StateError('未获相册权限(需「所有照片/有限」+「添加到照片」授权)');
    }
  }

  /// 微信风格选图(仅实况照片,多选)。需要 BuildContext 开选择器路由。
  static Future<List<AssetEntity>> pickLivePhotos(BuildContext context) async {
    final picked = await AssetPicker.pickAssets(
      context,
      pickerConfig: AssetPickerConfig(
        requestType: RequestType.image,
        maxAssets: 99,
        filterOptions: FilterOptionGroup(onlyLivePhotos: true),
      ),
    );
    return picked ?? const [];
  }

  /// 实况照片 → .livp 字节(静态帧 + 配对视频原文件直接 zip,零转码)。
  static Future<List<int>> entityToLivp(AssetEntity e) async {
    final image = await e.originFile;
    final video = await e.originFileWithSubtype;
    if (image == null) {
      throw StateError('读取静态帧失败(资源可能在 iCloud 未下载)');
    }
    final title = e.title ?? 'IMG_${e.id}';
    final baseName =
        title.contains('.') ? title.substring(0, title.lastIndexOf('.')) : title;
    final imgBytes = await image.readAsBytes();
    if (video == null) {
      // 非实况(onlyLivePhotos 已滤,理论不可达)→ 退化为纯静态 livp
      AppLog.info('album', 'asset ${e.id} 无配对视频,打包为无实况 livp');
      final arc = Archive()
        ..addFile(ArchiveFile(
            '$baseName.${_extOf(image.path, 'HEIC')}',
            imgBytes.length,
            imgBytes));
      return ZipEncoder().encode(arc)!;
    }
    return LivpService.pack(
      imageBytes: imgBytes,
      imageExt: _extOf(image.path, 'HEIC'),
      videoBytes: await video.readAsBytes(),
      videoExt: _extOf(video.path, 'MOV'),
      baseName: baseName,
    );
  }

  /// .livp 字节 → 存回 iOS 相册(恢复为实况照片)。
  static Future<void> saveLivpToAlbum(List<int> livpBytes) async {
    final tmp = await getTemporaryDirectory();
    final parts = await LivpService.unpackToFiles(
        livpBytes, Directory('${tmp.path}/livp_in'));
    final imageFile = parts.image;
    final videoFile = parts.video;
    final baseName = _stripExt(_baseNameOf(imageFile.path));
    if (videoFile == null) {
      // 无视频部分 → 按普通照片存
      await PhotoManager.editor
          .saveImageWithPath(imageFile.path, title: baseName);
      return;
    }
    AppLog.info('album', 'saveLivePhoto: image=${imageFile.path.split('/').last}'
        ' video=${videoFile.path.split('/').last} title=$baseName');
    await PhotoManager.editor.darwin.saveLivePhoto(
      imageFile: imageFile,
      videoFile: videoFile,
      title: baseName,
    );
  }

  static String _extOf(String path, String fallback) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? fallback : path.substring(dot + 1);
  }

  static String _baseNameOf(String path) =>
      path.split(Platform.pathSeparator).last;

  static String _stripExt(String name) =>
      name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
}
