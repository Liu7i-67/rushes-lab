/// 上传选择器与入队(从 upload_sheet.dart 拆出,B3 遗留 348 行拆分件):
/// 统一上传面板两入口(相册多选/文件多选)+ 逐项打包入队 + 汇总 toast
/// (app-polish D6:汇总走 [enqueueNamedBatchAndReport]——带名收集跳过明细,
/// toast 带「查看」打开跳过清单)。来源面板与授权引导 UI 见
/// upload_source_sheet.dart(§5.6 行数约束);入队与纯函数主体仍在
/// upload_sheet.dart(enqueueLocalUpload/enqueueBatch)。
library;

import 'dart:async' show Completer, Timer;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../services/album.dart';
import '../../services/app_log.dart';
import '../../services/livp.dart';
import '../../widgets/toast.dart';
import 'album_upload_name.dart';
import 'upload_sheet.dart';
import 'upload_source_sheet.dart';

// 授权引导对话框/「去设置」URI 已随 UI 拆到 upload_source_sheet.dart;
// 此处转出,既有 `import 'upload_pick.dart'` 的调用方(含用例)零改动。
export 'upload_source_sheet.dart'
    show
        AlbumPermissionAction,
        androidAppDetailsSettingsUri,
        kAndroidAppPackage,
        openAlbumPermissionSettings,
        showAlbumPermissionDialog;

/// B8:相册单次选择上限(与 wechat_assets_picker maxAssets 同源,勿再散写)。
const kAlbumPickLimit = 99;

/// 打开统一上传面板(宫格页两入口共用;app-polish B8:标题「上传到 <文件夹>」)。
/// 面板 UI 在 upload_source_sheet.dart;此处注入两路选择器回调,保持既有
/// `showUploadSheet(context, folderId:, where:)` 签名不变。
Future<void> showUploadSheet(
  BuildContext context, {
  required String folderId,
  required String where,
}) => showUploadSourceSheet(
  context,
  where: where,
  albumPickLimit: kAlbumPickLimit,
  onPickAlbum: () => _pickFromAlbum(context, folderId: folderId, where: where),
  onPickFiles: () => _pickFiles(context, folderId: folderId, where: where),
);

/// 相册多选(RequestType.all;iOS 实况 → livp 小包轨,其余原文件流式轨;
/// Android 全原文件)。逐项打包+入队收进 [enqueueNamedBatchAndReport]
/// (D6:带名收集,单点失败只跳过不中断剩余),完事汇总 toast。
Future<void> _pickFromAlbum(
  BuildContext context, {
  required String folderId,
  required String where,
}) async {
  final picked = await _pickAssets(context);
  if (picked == null || picked.isEmpty) return; // 用户取消:不算上传
  // B8:相册上限提示(选择器已硬顶 99,选满即提示分批)
  if (picked.length >= kAlbumPickLimit && context.mounted) {
    toast(context, '单次最多上传 $kAlbumPickLimit 个,本次已选满;更多素材请分批上传');
  }
  // D6:改带名收集(文件名+跳过原因),汇总 toast 有跳过带「查看」action
  // 打开跳过清单(语义不变:入队数/跳过数同口径,单点失败不中断)。
  // 展示名取 [_albumDisplayName] 的同步兜底名(仅 title,兜底 `IMG_<id>`),
  // 真实入队名由 [_enqueueAlbumAsset] 异步解析(titleAsync 真名 + 扩展名);
  // 两者可能不同,属已知取舍(D6),勿当 bug 返工。
  if (!context.mounted) return;
  await enqueueNamedBatchAndReport(
    context,
    where: where,
    items: picked.map(
      (e) => (
        _albumDisplayName(e),
        () => _enqueueAlbumAsset(e, folderId: folderId, where: where),
      ),
    ),
  );
}

/// D6:相册资产展示名(跳过清单用;仅同步 title,兜底 `IMG_<id>`)。
/// 真实入队名见 [_enqueueAlbumAsset]——经 [resolveAlbumUploadName] 异步补
/// 真名与扩展名(iOS title 恒空串);本函数保持同步是 D6 决策(不为失败清单
/// 文案重构 items 契约),展示名与上传名可能不同,属已知取舍,勿当 bug 改。
String _albumDisplayName(AssetEntity e) =>
    sanitizeUploadName(e.title ?? 'IMG_${e.id}', fallback: 'IMG_${e.id}');

/// D6 接线缝(相册/文件两路汇总位共用;@visibleForTesting 供用例直打):
/// 带名批量入队([enqueueBatchNamed],P1-1 单点失败不中断、失败项记文件名
/// +errorMessage 中文原因)→ [showUploadBatchToast] 汇总(有跳过带「查看」
/// action 打开跳过清单,标题带目标文件夹名)。where=「项目/夹」归属路径,
/// 取末段即文件夹名(showUploadSheet 标题同式)。
@visibleForTesting
Future<void> enqueueNamedBatchAndReport(
  BuildContext context, {
  required Iterable<(String filename, Future<void> Function() enqueue)> items,
  required String where,
}) async {
  final (enqueued, skips) = await enqueueBatchNamed(
    items,
    onError: (f, e) => AppLog.error('upload', '单项入队失败,已跳过:$f', e),
  );
  if (!context.mounted) return;
  showUploadBatchToast(
    context,
    enqueued: enqueued,
    skips: skips,
    where: where.split('/').last,
  );
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
    final action = await showAlbumPermissionDialog(
      context,
      isAndroid: isAndroid,
    );
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
    return await AssetPicker.pickAssets(
      context,
      pickerConfig: albumPickerConfig(),
    );
  } catch (e) {
    AppLog.error('upload', '相册选择失败', e);
    if (context.mounted) {
      toast(context, errorMessage(e, '相册选择失败,请稍后重试'), tone: ToastTone.error);
    }
    return null;
  }
}

/// P2:选图配置——wechat_assets_picker 9.8 无全局静态 delegate 入口,在唯一
/// 调用点显式传中文 delegate(基类 AssetPickerTextDelegate 即 zh-Hans),
/// 选择器内置界面(含「权限引导」覆盖层)全中文化。
@visibleForTesting
AssetPickerConfig albumPickerConfig() => AssetPickerConfig(
  requestType: RequestType.all,
  maxAssets: kAlbumPickLimit,
  textDelegate: const AssetPickerTextDelegate(),
);

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
/// 文件名/content_type 一律经 [resolveAlbumUploadName] 解析:iOS title 空串
/// 时靠 titleAsync/缓存路径/MIME 补真名与扩展名,不再落裸名 + octet-stream。
Future<void> _enqueueAlbumAsset(
  AssetEntity e, {
  required String folderId,
  required String where,
}) async {
  final live = AlbumService.isSupported && e.isLivePhoto;
  if (live) {
    // 现役实况链路:打包 .livp(小包轨,uploadBytes;iCloud 未下载在此抛)。
    // 扩展名恒为 .livp,只为借真名做上传名与 zip 内条目基名(同源,勿分叉)
    final r = await resolveAlbumUploadName(e);
    final base = LivpService.baseNameOf(r.filename, 'IMG_${e.id}');
    final bytes = await AlbumService.entityToLivp(e, baseName: base);
    await enqueueLocalUpload(
      folderId: folderId,
      where: where,
      filename: '$base.livp',
      bytes: bytes,
    );
    return;
  }
  final f = await e.originFile;
  if (f == null) {
    throw StateError('读取原文件失败 asset=${e.id}');
  }
  final r = await resolveAlbumUploadName(e, originPath: f.path);
  await enqueueLocalUpload(
    folderId: folderId,
    where: where,
    filename: r.filename,
    path: f.path,
    contentType: r.contentType,
  );
}

/// 文件多选直传(any:livp 无注册 Mime,custom 过滤会抛,现役钉子)。
/// 逐项入队收进 [enqueueNamedBatchAndReport](D6:带名收集,P1-1 同款
/// 单点失败不中断),完事汇总 toast(有跳过带「查看」)。
Future<void> _pickFiles(
  BuildContext context, {
  required String folderId,
  required String where,
}) async {
  final files = await _pickPlatformFiles(context);
  if (files.isEmpty) return; // 用户取消:不算上传
  if (!context.mounted) return;
  await enqueueNamedBatchAndReport(
    context,
    where: where,
    items: files.map(
      (f) => (
        sanitizeUploadName(f.name),
        () async {
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
        },
      ),
    ),
  );
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
    if (context.mounted) {
      toast(context, errorMessage(e, '文件选择失败,请稍后重试'), tone: ToastTone.error);
    }
    return const <PlatformFile>[];
  }
}
