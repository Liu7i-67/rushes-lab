/// TransferCard — 传输任务卡(§7):进行中=线性进度+百分比+取消钮;
/// 终态=状态徽标+错误文案+重试(failed/canceled)/移除。速度/剩余时间不做
/// (App 简化,§17 已登记差异)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/fmt.dart';
import '../../core/transfers/transfer_task.dart';
import '../../widgets/badge.dart';

class TransferCard extends StatelessWidget {
  const TransferCard({
    super.key,
    required this.task,
    this.onCancel,
    this.onRetry,
    this.onRemove,
  });

  final TransferTask task;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final t = task;
    final active = !t.status.isTerminal;
    return ListTile(
      leading: Icon(
        t.kind == TransferKind.upload
            ? Icons.upload_outlined
            : Icons.download_outlined,
      ),
      title: Text(
        t.filename,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.where,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          if (active) ...[
            LinearProgressIndicator(
              value: t.progress,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(height: 4),
            Text(_activeLine, style: Theme.of(context).textTheme.bodySmall),
          ] else ...[
            Row(
              children: [
                Badge(
                  label: t.status.label,
                  tone: switch (t.status) {
                    TransferStatus.done => BadgeTone.green,
                    TransferStatus.canceled => BadgeTone.neutral,
                    _ => BadgeTone.amber,
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.error ?? _sizeLine,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      // 活动态=取消;终态=重试(failed/canceled)+移除;done 只留移除
      // (done 重传必撞同名 409 查重,不提供)
      trailing: active
          ? IconButton(
              onPressed: onCancel,
              icon: const Icon(Icons.close_outlined),
              tooltip: '取消',
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (t.status == TransferStatus.failed ||
                    t.status == TransferStatus.canceled)
                  IconButton(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_outlined),
                    // B4:下载重试=重新下载+重新落盘(决策 #3);上传=从头重传
                    tooltip: t.kind == TransferKind.download
                        ? '重试(重新下载并落盘)'
                        : '重试(从头重传)',
                  ),
                IconButton(
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline_outlined),
                  tooltip: '移除',
                ),
              ],
            ),
    );
  }

  String get _activeLine {
    final percent = task.progress == null
        ? ''
        : '${(task.progress! * 100).toStringAsFixed(0)}% · ';
    return '$percent${fmtBytes(task.doneBytes)}/${fmtBytes(task.totalBytes)}';
  }

  String get _sizeLine {
    if (task.totalBytes <= 0) return '';
    return '${fmtBytes(task.doneBytes)}/${fmtBytes(task.totalBytes)}';
  }
}
