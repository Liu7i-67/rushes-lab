/// 统一上传面板(方案 §5 / B3 功能点 1):入口唯一=宫格 AppBar「⬆」+ 空态引导
/// 按钮 → 半屏 bottom sheet 两选:
/// - 「从相册选择」wechat_assets_picker RequestType.all 多选:iOS 实况照片 →
///   `entityToLivp` 打包 .livp(现役逻辑,uploadBytes 小包轨);普通图/视频原文件;
///   Android 全原文件(uploadFile 流式轨)。
/// - 「选择文件」file_picker any 多选:原文件直传(含 .livp 本身)。
/// 选完即入队 TransferQueue(全局 FIFO 并发 2),面板即关可继续浏览;
/// 上传成功经 RefreshBus 失效 assets scope → 宫格自动刷新(B2 预留订阅落地)。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

import '../../core/api/content_types.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../core/transfers/transfer_queue.dart';
import '../../core/transfers/transfer_task.dart';
import '../../services/album.dart';
import '../../services/app_log.dart';
import '../../services/livp.dart';
import '../../widgets/empty_state.dart';

/// 上传成功后的数据新鲜度(§8.1):失效宫格 scope(B2 预留、宫格页已挂订阅)
/// + folders(子树计数)。独立顶层函数便于单测「上传成功 → invalidate 收到」。
void notifyUploadSuccess(String folderId) {
  RefreshBus.I.invalidate('assets:$folderId');
  RefreshBus.I.invalidate('folders');
}

/// filename 净化:basename 后沿用 `LivpService.baseNameOf` 钉子(空标题兜底、
/// `/` `\` 分隔符净化,勿回退),扩展名保留;`.livp` 这类点文件按空基名走兜底。
String sanitizeUploadName(String raw, {String fallback = '文件'}) {
  final name = raw.trim().replaceAll('\\', '/').split('/').last.trim();
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 ? name.substring(dot) : '';
  return '${LivpService.baseNameOf(name, fallback)}$ext';
}

/// 批量入队结果:(enqueued 入队数, skipped 跳过数)。
typedef EnqueueBatchResult = (int enqueued, int skipped);

/// 批量逐项入队(P1-1 钉子:单点失败不中断整批):对 [items] 逐个调用
/// 「打包+入队」惰性闭包,任一项抛错只计跳过并继续后续项——iOS iCloud
/// 未下载 `entityToLivp` 抛 StateError、`File.length()` 抛 FileSystemException
/// 等均不外泄中断剩余。返回 (入队数, 跳过数) 供汇总 toast;[onError] 供
/// 调用方逐项记日志。抽成可注入纯循环便于单测(模拟第 2 项抛错 →
/// 3 项批次 2 入队 + 1 跳过)。
Future<EnqueueBatchResult> enqueueBatch(
  Iterable<Future<void> Function()> items, {
  void Function(Object error)? onError,
}) async {
  var enqueued = 0;
  var skipped = 0;
  for (final item in items) {
    try {
      await item();
      enqueued += 1;
    } catch (e) {
      skipped += 1;
      onError?.call(e);
    }
  }
  return (enqueued, skipped);
}

/// 批量入队汇总 toast:有跳过时「已入队 x 个,跳过 y 个」,否则仅报入队数。
String batchSummary(int enqueued, int skipped) => skipped > 0
    ? '已入队 $enqueued 个,跳过 $skipped 个'
    : '已入队 $enqueued 个';

/// 入队一个本地上传(相册/文件两路汇合点):bytes 走小包轨(livp),
/// path 走流式轨;成功后失效 assets/folders scope。返回任务 id。
Future<String> enqueueLocalUpload({
  required String folderId,
  required String where,
  required String filename,
  String? path,
  List<int>? bytes,
}) async {
  assert((path == null) != (bytes == null), 'path / bytes 必须二选一');
  final api = session.api!;
  final contentType = filename.toLowerCase().endsWith('.livp')
      ? 'application/zip'
      : contentTypeForFilename(filename);
  final totalBytes = bytes != null ? bytes.length : await File(path!).length();
  return TransferQueue.I.enqueue(TransferRequest(
    kind: TransferKind.upload,
    filename: filename,
    where: where,
    totalBytes: totalBytes,
    worker: (onProgress, token) async {
      if (bytes != null) {
        await api.assets.uploadBytes(
          folderId: folderId,
          filename: filename,
          bytes: bytes,
          contentType: contentType,
          cancelToken: token,
          onPartsDone: (d, t) => onProgress(
              (bytes.length * d / t).round().clamp(0, bytes.length)), // 分片粒度字节进度
        );
      } else {
        await api.assets.uploadFile(
          path: path!,
          folderId: folderId,
          filename: filename,
          contentType: contentType,
          cancelToken: token,
          onProgress: (done, total) => onProgress(done),
        );
      }
      AppLog.info('upload', '✓ 已上传:$filename → $where');
      notifyUploadSuccess(folderId);
    },
  ));
}

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
  _say(context, batchSummary(enqueued, skipped));
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
    if (context.mounted) _say(context, '相册选择失败:$e');
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
  final files = await _pickPlatformFiles();
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
  _say(context, batchSummary(enqueued, skipped));
}

/// file_picker 选择(用户取消返回空;选择器失败 toast 后返回空)。
Future<List<PlatformFile>> _pickPlatformFiles() async {
  try {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
      withData: false, // 流式轨走 path,不整载入内存
    );
    return result?.files ?? const <PlatformFile>[];
  } catch (e) {
    AppLog.error('upload', '文件选择失败', e);
    return const <PlatformFile>[];
  }
}

void _say(BuildContext context, String msg) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(SnackBar(content: Text(msg)));
}

/// 空文件夹引导=上传第二入口(§5 入口唯一:AppBar「⬆」+ 此引导钮共用面板);
/// my_can_upload 已知 false 时 [enabled]=false 只留文案。
class UploadEmptyGuide extends StatelessWidget {
  const UploadEmptyGuide({super.key, this.enabled = true, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const EmptyState(icon: Icons.image_outlined, message: '空文件夹'),
          const SizedBox(height: 12),
          if (enabled)
            FilledButton.tonalIcon(
              onPressed: onTap,
              icon: const Icon(Icons.upload_outlined),
              label: const Text('上传素材'),
            ),
        ],
      ),
    );
  }
}

/// 宫格顶部迷你进度条(§5 队列指示 / B3 功能点 5):有活动上传(queued/running)
/// 才显示;细进度条=聚合字节进度,n/m=已完成/总上传任务数。入口唯一条:
/// AppBar 下方细条(方案 §5「宫格顶部迷你进度」)。
class UploadMiniBar extends StatelessWidget {
  const UploadMiniBar({super.key, this.queue});

  /// 测试注入用;默认全局单例。
  final TransferQueue? queue;

  @override
  Widget build(BuildContext context) {
    final q = queue ?? TransferQueue.I;
    return AnimatedBuilder(
      animation: q,
      builder: (context, _) {
        if (q.activeUploadCount == 0) return const SizedBox.shrink();
        final progress = q.uploadByteProgress;
        return Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${q.uploadDoneCount}/${q.uploadCount}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}
