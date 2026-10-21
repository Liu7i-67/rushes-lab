/// 上传入队主体(方案 §5 / B3 功能点 1;B3 遗留拆分后:选择器与面板在
/// upload_pick.dart,本文件只留纯函数与入队/指示件):
/// - filename 净化/批量入队纯循环/汇总文案(可单测);
/// - enqueueLocalUpload:相册/文件两路汇合点(bytes 小包轨 / path 流式轨);
/// - UploadEmptyGuide 空态引导 + UploadMiniBar 宫格顶部迷你进度条。
/// app-polish D6(包 D 增量,叠加在包 B 结构之上):跳过明细机械件——
/// UploadSkip(文件名+用户可读原因)/ enqueueBatchNamed(带名收集,语义同
/// enqueueBatch)/ showUploadSkipsSheet(跳过清单 sheet)/
/// showUploadBatchToast(汇总 toast,有跳过带「查看」action)。选择器侧
/// (upload_pick.dart,包 B 文件)接线说明见包 D 交付报告。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/api/content_types.dart';
import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../core/transfers/transfer_queue.dart';
import '../../core/transfers/transfer_task.dart';
import '../../services/app_log.dart';
import '../../services/livp.dart';
import '../../theme/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/sheet_scaffold.dart';
import '../../widgets/toast.dart';
import '../shell/home_shell.dart' show HomeShell;
import '../transfers/transfers_page.dart' show TransfersPage;

/// 上传成功后的数据新鲜度(§8.1):失效宫格 scope(B2 预留、宫格页已挂订阅)
/// + folders(子树计数)。独立顶层函数便于单测「上传成功 → invalidate 收到」。
void notifyUploadSuccess(String folderId) {
  RefreshBus.I.invalidate('assets:$folderId');
  RefreshBus.I.invalidate('folders');
}

/// B6(app-polish 接线收口):UploadMiniBar 点击 → 传输视图。HomeShell
/// (features/shell)已挂 RefreshBus `shell:tab:transfers` 监听:收到即切
/// 传输 tab,并把 shell 之上的推入页(迷你条所在的宫格页)弹回,让切换可见。
/// 本函数按「shell 是否在树」分流(RefreshBus 纯回调注册表无「是否已有订阅」
/// 查询通道,由壳 initState/dispose 自报 [HomeShell.isInTree]):
/// - 在树 → 已接管为真·切 tab,仅广播不 push(避免叠页;弹回由 shell 侧完成);
/// - 不在树(深链等非 shell 上下文)→ 保留 push 传输页全屏路由兜底:同一
///   TransferQueue 单例,返回即回原页。
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

// ── D6:上传跳过明细(文件名+原因;清单 sheet + 汇总 toast「查看」action)──

/// 单项跳过明细(D6):文件名 + 用户可读原因(经 errorMessage 中文兜底,
/// 勿直出 StateError/FileSystemException 原文)。
class UploadSkip {
  const UploadSkip({required this.filename, required this.reason});

  final String filename;
  final String reason;
}

/// 带名批量入队(D6;语义与 [enqueueBatch] 完全一致,P1-1 单点失败不中断):
/// items=(文件名, 惰性闭包) 对,失败项经 [onError] 上报后记入跳过明细。
/// 抽成独立纯循环保留 enqueueBatch 既有形状与其单测。
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
      skips.add(UploadSkip(
          filename: filename,
          reason: errorMessage(e, '无法读取该文件,已跳过')));
    }
  }
  return (enqueued, skips);
}

/// D6:跳过清单 sheet(文件名+原因;由汇总 toast 的「查看」action 打开)。
Future<void> showUploadSkipsSheet(
  BuildContext context, {
  required List<UploadSkip> skips,
  String? where,
}) {
  return showAppSheet<void>(
    context: context,
    title: where == null ? '跳过的文件(${skips.length})' : '跳过的文件 · $where',
    maxHeightFactor: 0.6,
    bottomActions: [
      FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('知道了'),
      ),
    ],
    child: ListView.builder(
      shrinkWrap: true,
      itemCount: skips.length,
      itemBuilder: (context, i) {
        final s = skips[i];
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.file_present_outlined, size: 20),
          title: Text(s.filename,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: Tk.fzMd)),
          subtitle: Text(s.reason,
              style: const TextStyle(fontSize: Tk.fzXs, color: Tk.muted)),
        );
      },
    ),
  );
}

/// D6:入队汇总 toast(与包 B 的 toast() 迁移同风格):无跳过=success 纯报数;
/// 有跳过=info 报双数 + 「查看」action 打开跳过清单 sheet(文件名+原因)。
/// 选择器侧(upload_pick.dart,包 B 文件)以
/// `showUploadBatchToast(context, enqueued: n, skips: skips, where: where)`
/// 替换现有 `toast(context, batchSummary(...))` 即完成接线。
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
          const SizedBox(height: Tk.spaceMd),
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

/// 宫格顶部迷你进度条(§5 队列指示 / B3 功能点 5;app-polish B6 可点跳传输):
/// 有活动上传(queued/running)才显示;细进度条=聚合字节进度,n/m=已完成/总
/// 上传任务数;整条可点 → 传输视图(见 [openTransfersView])。
class UploadMiniBar extends StatelessWidget {
  const UploadMiniBar({super.key, this.queue, this.onTap});

  /// 测试注入用;默认全局单例。
  final TransferQueue? queue;

  /// B6:整条点击回调(宫格页接 [openTransfersView]);null=纯展示不可点。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final q = queue ?? TransferQueue.I;
    return AnimatedBuilder(
      animation: q,
      builder: (context, _) {
        if (q.activeUploadCount == 0) return const SizedBox.shrink();
        final progress = q.uploadByteProgress;
        return InkWell(
          onTap: onTap,
          child: Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            padding: const EdgeInsets.fromLTRB(
                Tk.spaceLg, Tk.spaceXs, Tk.spaceLg, Tk.spaceXs),
            child: Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    // 3px 高条的圆角与条高耦合(2≈半高胶囊),不套 rSm
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: Tk.spaceMd),
                Text(
                  '${q.uploadDoneCount}/${q.uploadCount}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Icon(Icons.chevron_right, size: 16, color: Tk.muted),
              ],
            ),
          ),
        );
      },
    );
  }
}
