/// 上传选择器与面板(从 upload_sheet.dart 拆出,B3 遗留 348 行拆分件):
/// 统一上传面板两入口(相册多选/文件多选)+ 逐项打包入队 + 汇总 toast。
/// 入队与纯函数主体仍在 upload_sheet.dart(enqueueLocalUpload/enqueueBatch)。
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

import '../../services/album.dart';
import '../../services/app_log.dart';
import '../../services/livp.dart';
import 'upload_sheet.dart';

/// 打开统一上传面板(宫格页两入口共用)。
Future<void> showUploadSheet(
  BuildContext context, {
  required String folderId,
  required String where,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('从相册选择'),
            subtitle: const Text('实况照片自动打包 .livp;图/视频传原文件'),
            onTap: () {
              Navigator.pop(sheetCtx);
              _pickFromAlbum(context, folderId: folderId, where: where);
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('选择文件'),
            subtitle: const Text('原文件直传,支持多选(含 .livp)'),
            onTap: () {
              Navigator.pop(sheetCtx);
              _pickFiles(context, folderId: folderId, where: where);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// 相册多选(RequestType.all;iOS 实况 → livp 小包轨,其余原文件流式轨;
/// Android 全原文件)。逐项打包+入队收进 [enqueueBatch] 内层 try/catch
/// (P1-1:单个失败只跳过,不中断剩余),完事汇总 toast。
Future<void> _pickFromAlbum(
  BuildContext context, {
  required String folderId,
  required String where,
}) async {
  final picked = await _pickAssets(context);
  if (picked == null || picked.isEmpty) return; // 用户取消:不算上传
  final (enqueued, skipped) = await enqueueBatch(
    picked.map((e) => () => _enqueueAlbumAsset(e, folderId: folderId, where: where)),
    onError: (e) => AppLog.error('upload', '单项入队失败,已跳过', e),
  );
  if (!context.mounted) return;
  sayToast(context, batchSummary(enqueued, skipped));
}

/// 相册权限+选择器(用户取消返回 null;选择器/权限失败 toast 后返回 null,
/// 不与逐项入队失败混为一谈)。
Future<List<AssetEntity>?> _pickAssets(BuildContext context) async {
  try {
    await AlbumService.ensurePermission();
    if (!context.mounted) return null;
    return await AssetPicker.pickAssets(
      context,
      pickerConfig: AssetPickerConfig(
        requestType: RequestType.all,
        maxAssets: 99,
      ),
    );
  } catch (e) {
    AppLog.error('upload', '相册选择失败', e);
    if (context.mounted) sayToast(context, '相册选择失败:$e');
    return null;
  }
}

/// 单个相册资产打包+入队(iOS 实况 → livp 小包轨,其余原文件流式轨;
/// Android 全原文件)。抛错由 [enqueueBatch] 逐项捕获计跳过。
Future<void> _enqueueAlbumAsset(
  AssetEntity e, {
  required String folderId,
  required String where,
}) async {
  final live = AlbumService.isSupported && e.isLivePhoto;
  if (live) {
    // 现役实况链路:打包 .livp(小包轨,uploadBytes;iCloud 未下载在此抛)
    final bytes = await AlbumService.entityToLivp(e);
    await enqueueLocalUpload(
      folderId: folderId,
      where: where,
      filename: '${LivpService.baseNameOf(e.title, 'IMG_${e.id}')}.livp',
      bytes: bytes,
    );
    return;
  }
  final f = await e.originFile;
  if (f == null) {
    throw StateError('读取原文件失败 asset=${e.id}');
  }
  await enqueueLocalUpload(
    folderId: folderId,
    where: where,
    filename: sanitizeUploadName(e.title ?? f.path.split('/').last,
        fallback: 'IMG_${e.id}'),
    path: f.path,
  );
}

/// 文件多选直传(any:livp 无注册 Mime,custom 过滤会抛,现役钉子)。
/// 逐项入队收进 [enqueueBatch] 内层 try/catch(P1-1 同款),完事汇总 toast。
Future<void> _pickFiles(
  BuildContext context, {
  required String folderId,
  required String where,
}) async {
  final files = await _pickPlatformFiles(context);
  if (files.isEmpty) return; // 用户取消:不算上传
  final (enqueued, skipped) = await enqueueBatch(
    files.map((f) => () async {
      final p = f.path;
      if (p == null) {
        throw StateError('无本地路径 file=${f.name}');
      }
      await enqueueLocalUpload(
        folderId: folderId,
        where: where,
        filename: sanitizeUploadName(f.name),
        path: p,
      );
    }),
    onError: (e) => AppLog.error('upload', '单项入队失败,已跳过', e),
  );
  if (!context.mounted) return;
  sayToast(context, batchSummary(enqueued, skipped));
}

/// file_picker 选择(用户取消返回空;选择器失败补 toast 后返回空——
/// B3 遗留清偿:原为静默只记日志,与相册路不一致)。
Future<List<PlatformFile>> _pickPlatformFiles(BuildContext context) async {
  try {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
      withData: false, // 流式轨走 path,不整载入内存
    );
    return result?.files ?? const <PlatformFile>[];
  } catch (e) {
    AppLog.error('upload', '文件选择失败', e);
    if (context.mounted) sayToast(context, '文件选择失败:$e');
    return const <PlatformFile>[];
  }
}

/// 面板/选择链路共用 toast(session 根 messenger 兜底;B3 拆分时收拢于此)。
void sayToast(BuildContext context, String msg) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(SnackBar(content: Text(msg)));
}
