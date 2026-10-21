/// 上传入队主体(方案 §5 / B3 功能点 1;B3 遗留拆分后:选择器与面板在
/// upload_pick.dart,本文件只留纯函数与入队/指示件):
/// - filename 净化/批量入队纯循环/汇总文案(可单测);
/// - enqueueLocalUpload:相册/文件两路汇合点(bytes 小包轨 / path 流式轨);
/// - UploadEmptyGuide 空态引导 + UploadMiniBar 宫格顶部迷你进度条。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/api/content_types.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../core/transfers/transfer_queue.dart';
import '../../core/transfers/transfer_task.dart';
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
