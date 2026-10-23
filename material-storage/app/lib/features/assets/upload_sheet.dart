/// 上传入队主体(upload_sheet;选择器与面板见 upload_pick.dart):
/// - filename 净化/批量入队纯循环/汇总文案(可单测);
/// - enqueueLocalUpload:相册/文件两路汇合点(bytes 小包轨 / path 流式轨);
/// - 跳过明细收集与汇总 toast。
/// 空态引导/跳过清单已拆到 upload_guide.dart,进度胶囊拆到
/// upload_progress_pill.dart;此处 export 保持既有公开 API 不变。
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
import '../../widgets/toast.dart';
import '../shell/home_shell.dart' show HomeShell;
import '../transfers/transfers_page.dart' show TransfersPage;
import 'upload_guide.dart';

export 'upload_guide.dart'
    show UploadEmptyGuide, UploadSkip, showUploadSkipsSheet;
export 'upload_progress_pill.dart' show UploadMiniBar, UploadProgressPill;

/// 上传成功后的数据新鲜度:失效宫格 scope + folders(子树计数)。
void notifyUploadSuccess(String folderId) {
  RefreshBus.I.invalidate('assets:$folderId');
  RefreshBus.I.invalidate('folders');
}

/// UploadMiniBar 点击 → 传输视图。HomeShell 已挂 RefreshBus
/// `shell:tab:transfers` 监听:收到即切传输 tab,并把 shell 之上的推入页
/// (迷你条所在的宫格页)弹回。本函数按「shell 是否在树」分流:
/// - 在树 → 已接管为真·切 tab,仅广播不 push;
/// - 不在树(深链等非 shell 上下文)→ push 传输页全屏路由兜底。
void openTransfersView(BuildContext context) {
  RefreshBus.I.invalidate('shell:tab:transfers');
  if (HomeShell.isInTree) return;
  Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const TransfersPage()));
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
/// 「打包+入队」惰性闭包,任一项抛错只计跳过并继续后续项。
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

/// 批量入队汇总文案:有跳过时「已入队 x 个,跳过 y 个」,否则仅报入队数。
String batchSummary(int enqueued, int skipped) =>
    skipped > 0 ? '已入队 $enqueued 个,跳过 $skipped 个' : '已入队 $enqueued 个';

/// 带名批量入队(语义与 [enqueueBatch] 完全一致,P1-1 单点失败不中断):
/// items=(文件名, 惰性闭包) 对,失败项经 [onError] 上报后记入跳过明细。
Future<(int enqueued, List<UploadSkip> skips)> enqueueBatchNamed(
  Iterable<(String filename, Future<void> Function() enqueue)> items, {
  void Function(String filename, Object error)? onError,
}) async {
  var enqueued = 0;
  final skips = <UploadSkip>[];
  for (final (filename, enqueue) in items) {
    try {
      await enqueue();
      enqueued += 1;
    } catch (e) {
      onError?.call(filename, e);
      skips.add(UploadSkip(filename: filename, reason: UploadSkip.reasonOf(e)));
    }
  }
  return (enqueued, skips);
}

/// 入队汇总 toast:无跳过=success 纯报数;有跳过=info 报双数 + 「查看」action
/// 打开跳过清单 sheet(文件名+原因)。
void showUploadBatchToast(
  BuildContext context, {
  required int enqueued,
  required List<UploadSkip> skips,
  String? where,
}) {
  if (skips.isEmpty) {
    toast(context, batchSummary(enqueued, 0), tone: ToastTone.success);
    return;
  }
  toast(
    context,
    batchSummary(enqueued, skips.length),
    tone: ToastTone.info,
    actionLabel: '查看',
    onAction: () => showUploadSkipsSheet(context, skips: skips, where: where),
  );
}

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
  return TransferQueue.I.enqueue(
    TransferRequest(
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
              (bytes.length * d / t).round().clamp(0, bytes.length),
            ),
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
    ),
  );
}
