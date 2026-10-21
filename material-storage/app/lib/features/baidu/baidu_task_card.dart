/// 百度任务卡(B9 §8.10,自 baidu_page 拆件守 300 行硬顶;web TaskItem
/// 移动版):状态徽标(queued 派生「排队中」)/目标/进度条/字节统计/ETA/
/// 失败原因中文 + 操作行(查看/取消/全部重试失败/删除,回调上抛页面执行)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/fmt.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';
import '../admin/baidu_task_labels.dart';

/// 任务卡(行=状态徽标/目标/进度/统计/操作;web TaskItem 移动版)。
class BaiduTaskCard extends StatelessWidget {
  const BaiduTaskCard({
    super.key,
    required this.task,
    required this.busy,
    required this.onAction,
  });

  final BaiduTask task;
  final bool busy;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final t = task;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(t.sourceDir,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 6),
              Badge(label: taskStatusText(t.displayStatus),
                  tone: baiduTaskTone(t.displayStatus)),
            ]),
            const SizedBox(height: 4),
            Text('→ ${t.targetLabel}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: Tk.muted)),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: t.progressPct / 100,
                minHeight: 4,
                backgroundColor: Tk.fill,
                color: t.status == 'failed'
                    ? Tk.red
                    : t.status == 'completed'
                        ? Tk.green
                        : Tk.accent,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 2,
              children: [
                Text('${t.doneFiles ?? 0} / ${t.totalFiles ?? 0} 个文件',
                    style: const TextStyle(fontSize: 11.5, color: Tk.muted)),
                Text(
                    '${fmtBytes(t.doneBytes)}'
                    '${t.totalBytes == null ? '' : ' / ${fmtBytes(t.totalBytes!)}'}',
                    style: const TextStyle(fontSize: 11.5, color: Tk.muted)),
                if (t.isActive)
                  Text(
                      t.etaSeconds != null
                          ? '预计剩余 ${fmtEtaShort(t.etaSeconds!)}'
                          : '估算中',
                      style:
                          const TextStyle(fontSize: 11.5, color: Tk.muted)),
                if (t.status == 'failed' && t.failReason != null)
                  Text(kFailReasonLabels[t.failReason!] ?? t.failReason!,
                      style: const TextStyle(fontSize: 11.5, color: Tk.red)),
                if (t.status == 'completed' && (t.totalFiles ?? 0) == 0)
                  const Text('源目录为空',
                      style: TextStyle(fontSize: 11.5, color: Tk.muted)),
                if (t.status == 'cancelled' && (t.cancelledFiles ?? 0) > 0)
                  Text('已取消 ${t.cancelledFiles} 个文件',
                      style:
                          const TextStyle(fontSize: 11.5, color: Tk.muted)),
              ],
            ),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                onPressed: () => Navigator.of(context)
                    .pushNamed('/baidu-task', arguments: t.id),
                child: const Text('查看'),
              ),
              if (t.isActive)
                TextButton(
                  onPressed: busy ? null : () => onAction('cancel'),
                  child: const Text('取消',
                      style: TextStyle(color: Tk.red)),
                ),
              if (t.canRetryFailed)
                TextButton(
                  onPressed: busy ? null : () => onAction('retry-failed'),
                  child: const Text('全部重试失败'),
                ),
              if (t.isTerminal)
                TextButton(
                  onPressed: busy ? null : () => onAction('delete'),
                  child: const Text('删除', style: TextStyle(color: Tk.red)),
                ),
            ]),
          ],
        ),
      ),
    );
  }
}
