/// 上传来源面板与相册授权引导 UI(自 upload_pick.dart 拆出,§5.6):
/// 底部「从相册选择 / 选择文件」两项来源 + 相册权限被拒时的中文引导对话框
/// 及其「去设置」系统页 URI。选择器与入队编排留在 upload_pick.dart。
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/app_log.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_row.dart';
import '../../widgets/sheet_scaffold.dart';

/// P2:相册权限被拒引导对话框的用户动作。
enum AlbumPermissionAction { openSettings, retry }

/// 打开统一上传面板(宫格页两入口共用;app-polish B8:标题「上传到 <文件夹>」)。
/// [onPickAlbum]/[onPickFiles] 由 upload_pick 注入,先关面板再走选择流程。
Future<void> showUploadSourceSheet(
  BuildContext context, {
  required String where,
  required int albumPickLimit,
  required VoidCallback onPickAlbum,
  required VoidCallback onPickFiles,
}) {
  // where=「项目/夹」归属路径,取末段即文件夹名
  final folderName = where.split('/').last;
  return showAppSheet<void>(
    context: context,
    title: '上传到 $folderName',
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionCard(
          children: [
            AppRow(
              leading: const Icon(Icons.photo_library_outlined),
              goldIcon: true,
              title: '从相册选择',
              subtitle: '实况照片自动打包 .livp;图/视频传原文件,单次最多 $albumPickLimit 个',
              onTap: () {
                Navigator.pop(context);
                onPickAlbum();
              },
            ),
            AppRow(
              leading: const Icon(Icons.folder_open_outlined),
              title: '选择文件',
              subtitle: '原文件直传,支持多选(含 .livp)',
              onTap: () {
                Navigator.pop(context);
                onPickFiles();
              },
            ),
          ],
        ),
        const SizedBox(height: Tk.spaceSm),
      ],
    ),
  );
}

/// P2:相册权限被拒引导对话框(自绘中文)。Android:「去设置」跳应用详情
/// 设置页;iOS:仅「重新尝试」重走 requestPermissionExtend(系统授权弹窗)。
/// 返回用户动作;取消/点外部关闭返回 null。权限引导循环(upload_pick)与
/// 单测直接调用。
Future<AlbumPermissionAction?> showAlbumPermissionDialog(
  BuildContext context, {
  bool? isAndroid,
}) {
  final android = isAndroid ?? Platform.isAndroid;
  return showDialog<AlbumPermissionAction>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('需要相册访问权限'),
      content: const Text('选择照片、视频上传时需要访问相册,请授权后重试。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(
            android
                ? AlbumPermissionAction.openSettings
                : AlbumPermissionAction.retry,
          ),
          child: Text(android ? '去设置' : '重新尝试'),
        ),
      ],
    ),
  );
}

/// Android 应用包名(构建 applicationId;跳应用详情设置页用)。
const kAndroidAppPackage = 'com.taoxiplan.huanhuashijie';

/// P2:「去设置」跳应用详情设置页(ACTION_APPLICATION_DETAILS_SETTINGS)。
/// url_launcher 走 ACTION_VIEW+data,系统设置对 `package:` scheme 的 VIEW
/// 意图即应用详情页;启动失败(未解析到处理方)回退 photo_manager 的
/// openSetting(同为应用设置页)。
@visibleForTesting
Uri androidAppDetailsSettingsUri({String packageName = kAndroidAppPackage}) =>
    Uri.parse('package:$packageName');

/// P2:「去设置」跳应用详情设置页(ACTION_APPLICATION_DETAILS_SETTINGS)。
/// url_launcher 走 ACTION_VIEW+data,系统设置对 `package:` scheme 的 VIEW
/// 意图即应用详情页;启动失败(未解析到处理方)回退 photo_manager 的
/// openSetting(同为应用设置页)。
Future<void> openAlbumPermissionSettings() async {
  try {
    final launched = await launchUrl(
      androidAppDetailsSettingsUri(),
      mode: LaunchMode.externalApplication,
    );
    if (launched) return;
    AppLog.info('upload', 'package: 意图未启动,回退 openSetting');
  } catch (e) {
    AppLog.error('upload', '跳应用详情设置页失败,回退 openSetting', e);
  }
  await PhotoManager.openSetting();
}
