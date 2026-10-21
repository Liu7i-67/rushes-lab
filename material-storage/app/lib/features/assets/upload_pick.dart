/// 上传选择器与面板(从 upload_sheet.dart 拆出,B3 遗留 348 行拆分件):
/// 统一上传面板两入口(相册多选/文件多选)+ 逐项打包入队 + 汇总 toast。
/// 入队与纯函数主体仍在 upload_sheet.dart(enqueueLocalUpload/enqueueBatch)。
library;

import 'dart:async' show Completer, Timer;
import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

import '../../services/album.dart';
import '../../services/app_log.dart';
import '../../services/livp.dart';
import 'upload_sheet.dart';

/// P2:相册权限被拒引导对话框的用户动作。
enum AlbumPermissionAction { openSettings, retry }

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

/// P2 权限引导循环(拒绝态不再抛 StateError):授权/limited 返回 true;
/// 用户取消/关闭或「去设置」超时未回前台返回 false(均不算上传)。
/// 循环语义:未授权 → 弹中文引导 → Android「去设置」跳系统页,等回前台
/// (resumed)再续判——授权返回→直接进选图;未授权返回→再弹引导。
/// [checkPermission]/[openSettings]/[waitResume] 注入供单测编排(生产用
/// AlbumService / 系统设置跳转 / AppLifecycle resumed 等待的默认实现)。
@visibleForTesting
Future<bool> ensureAlbumPermissionGuided(
  BuildContext context, {
  bool? isAndroid,
  Future<bool> Function()? checkPermission,
  Future<void> Function()? openSettings,
  Future<bool> Function()? waitResume,
}) async {
  while (true) {
    if (await (checkPermission?.call() ?? AlbumService.ensurePermission())) {
      return true;
    }
    if (!context.mounted) return false;
    final action =
        await showAlbumPermissionDialog(context, isAndroid: isAndroid);
    if (action == null) return false; // 取消/关闭:不算上传
    if (action == AlbumPermissionAction.openSettings) {
      await (openSettings?.call() ?? openAlbumPermissionSettings());
      // P2-1:launchUrl 毫秒级返回,若立刻重判会在用户仍停留系统设置页时
      // 弹出陈旧引导框(授权返回反而要再点一次取消)。等回前台(resumed)
      // 才续判;超时未回前台放弃本次(下次点上传重走完整流程)。
      if (!await (waitResume?.call() ?? waitForAppResume())) return false;
    }
  }
}

/// 相册权限+选择器(用户取消返回 null;选择器/权限失败 toast 后返回 null,
/// 不与逐项入队失败混为一谈)。
/// P2:拒绝态不再抛 StateError——经 [ensureAlbumPermissionGuided] 中文引导
/// 循环;其余异常仍走通用「相册选择失败」toast。
Future<List<AssetEntity>?> _pickAssets(BuildContext context) async {
  try {
    if (!await ensureAlbumPermissionGuided(context)) return null;
    if (!context.mounted) return null;
    return await AssetPicker.pickAssets(context, pickerConfig: albumPickerConfig());
  } catch (e) {
    AppLog.error('upload', '相册选择失败', e);
    if (context.mounted) sayToast(context, '相册选择失败:$e');
    return null;
  }
}

/// P2:选图配置——wechat_assets_picker 9.8 无全局静态 delegate 入口,在唯一
/// 调用点显式传中文 delegate(基类 AssetPickerTextDelegate 即 zh-Hans),
/// 选择器内置界面(含「权限引导」覆盖层)全中文化。
@visibleForTesting
AssetPickerConfig albumPickerConfig() => AssetPickerConfig(
      requestType: RequestType.all,
      maxAssets: 99,
      textDelegate: const AssetPickerTextDelegate(),
    );

/// P2:相册权限被拒引导对话框(自绘中文)。Android:「去设置」跳应用详情
/// 设置页;iOS:仅「重新尝试」重走 requestPermissionExtend(系统授权弹窗)。
/// 返回用户动作;取消/点外部关闭返回 null。
@visibleForTesting
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
const kAndroidAppPackage = 'com.rushes.lab.tx';

/// P2:「去设置」跳应用详情设置页(ACTION_APPLICATION_DETAILS_SETTINGS)。
/// url_launcher 走 ACTION_VIEW+data,系统设置对 `package:` scheme 的 VIEW
/// 意图即应用详情页;启动失败(未解析到处理方)回退 photo_manager 的
/// openSetting(同为应用设置页)。
@visibleForTesting
Uri androidAppDetailsSettingsUri({String packageName = kAndroidAppPackage}) =>
    Uri.parse('package:$packageName');

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

/// P2-1:等待 App 回到前台(resumed)再续判。「去设置」跳系统页后 App 转后台,
/// 须等用户操作完毕返回(授权与否都回)才重判真实权限态;已在前台(桌面端/
/// 测试环境/未真正切走)直接放行。等待带 [timeout] 上限防死等,[binding] 供
/// 测试注入;返回是否真的回到了前台(超时=false)。超时 Timer 在退出时必取
/// 消(不残留挂起定时器,widget 测试 FakeAsync 亦干净)。
@visibleForTesting
Future<bool> waitForAppResume({
  Duration timeout = const Duration(minutes: 5),
  WidgetsBinding? binding,
}) async {
  final b = binding ?? WidgetsBinding.instance;
  if (b.lifecycleState == AppLifecycleState.resumed) return true;
  final resumed = Completer<void>();
  final listener = AppLifecycleListener(binding: b, onResume: resumed.complete);
  final timedOut = Completer<void>();
  final timer = Timer(timeout, timedOut.complete);
  try {
    await Future.any(<Future<void>>[resumed.future, timedOut.future]);
  } finally {
    timer.cancel();
    listener.dispose();
  }
  return resumed.isCompleted;
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
