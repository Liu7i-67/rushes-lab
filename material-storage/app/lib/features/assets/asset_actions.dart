/// 资产上传/下载动作集(宫格页操作逻辑,与页面渲染解耦):
/// 上传:iOS=相册实况;其他平台=文件选 .livp(PC 验证链路)。
/// 下载:iOS livp 存相册;其他落临时目录并顺带验证 livp 可解包。
/// 界面浮层 + 全量日志双写经 [say](推送企业微信走 AppLog)。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart' show BuildContext;

import '../../core/api/ms_api.dart' show ApiException;
import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/album.dart';
import '../../services/livp.dart';

class AssetActions {
  AssetActions({required this.folderId, required this.say});

  final String folderId;
  final void Function(String msg) say;

  /// 上传:iOS=相册实况;其他平台=文件选 .livp(PC 验证链路)。
  /// 返回是否走到成功收尾(失败/取消一律 false,调用方据此决定是否刷新列表;
  /// 用户取消选图/选文件同样 false——未发生上传,不多刷一次)。
  Future<bool> upload(BuildContext context) async {
    try {
      return AlbumService.isSupported
          ? await _uploadFromAlbum(context)
          : await _uploadFromFile();
    } on ApiException catch (e) {
      say('上传失败:${e.message}');
    } catch (e) {
      say('上传失败:$e');
    }
    return false;
  }

  Future<bool> _uploadFromAlbum(BuildContext context) async {
    await AlbumService.ensurePermission();
    if (!context.mounted) return false;
    final picked = await AlbumService.pickLivePhotos(context);
    if (picked.isEmpty) return false; // 用户取消/未选:不算上传
    var i = 0;
    for (final e in picked) {
      i++;
      say('打包实况 ${(e.title ?? '').trim().isEmpty ? e.id : e.title}'
          '($i/${picked.length})…');
      final bytes = await AlbumService.entityToLivp(e);
      final name = '${LivpService.baseNameOf(e.title, 'IMG_${e.id}')}.livp';
      say('上传 $name …');
      final asset = await session.api!.assets.uploadBytes(
        folderId: folderId,
        filename: name,
        bytes: bytes,
        onPartsDone: (d, t) => say('$name 分片 $d/$t'),
      );
      say('✓ 已上传:${asset.filename}');
    }
    return true;
  }

  Future<bool> _uploadFromFile() async {
    // Android SAF 按 Mime 过滤,livp 无注册 Mime,FileType.custom 会直接抛
    // PlatformException(Unsupported filter)→ 改 any + 选完自校验扩展名
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    final f = result?.files.single;
    if (f == null || f.bytes == null) return false; // 用户取消选文件
    if (!f.name.toLowerCase().endsWith('.livp')) {
      say('已忽略非 livp 文件:${f.name}(请选择 .livp 文件)');
      return false; // 未发生上传:同样不触发调用方刷新
    }
    say('上传 ${f.name} …');
    final asset = await session.api!.assets.uploadBytes(
      folderId: folderId,
      filename: f.name,
      bytes: f.bytes!,
      onPartsDone: (d, t) => say('${f.name} 分片 $d/$t'),
    );
    say('✓ 已上传:${asset.filename}');
    return true;
  }

  Future<void> download(Asset a) async {
    if (a.isLivp && AlbumService.isSupported) {
      await downloadToAlbum(a);
      return;
    }
    try {
      final url = await session.api!.assets.downloadLink(a.id);
      final save = '${Directory.systemTemp.path}/${a.filename}';
      say('下载 ${a.filename} …');
      await session.api!.assets.downloadTo(url, save);
      say('✓ 已保存:$save');
      if (a.isLivp) {
        // PC/Android:验证容器可解包(不存相册)
        final bytes = await File(save).readAsBytes();
        final parts = LivpService.decode(bytes);
        say(
          '✓ livp 解包 OK:静态图 ${parts.image.name}'
          '${parts.video != null ? ' + 视频 ${parts.video!.name}' : ' (无视频)'}',
        );
      }
    } on ApiException catch (e) {
      say('下载失败:${e.message}');
    } catch (e) {
      say('下载失败:$e');
    }
  }

  Future<void> downloadToAlbum(Asset a) async {
    try {
      final url = await session.api!.assets.downloadLink(a.id);
      final save = '${Directory.systemTemp.path}/${a.filename}';
      say('下载 ${a.filename} …');
      await session.api!.assets.downloadTo(url, save);
      final bytes = await File(save).readAsBytes();
      await AlbumService.saveLivpToAlbum(bytes);
      say('✓ 已存入相册(实况照片)');
    } on ApiException catch (e) {
      say('下载失败:${e.message}');
    } catch (e) {
      say('存相册失败:$e');
    }
  }
}
