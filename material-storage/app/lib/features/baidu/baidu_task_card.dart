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
      margin: const EdgeInsets.only(bottom: Tk.spaceSm),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Tk.rLg))),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, Tk.spaceMd, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(t.sourceDir,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: Tk.fzMd, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 6),
              Badge(label: taskStatusText(t.displayStatus),
                  tone: baiduTaskTone(t.displayStatus)),
            ]),
            const SizedBox(height: Tk.spaceXs),
            Text('→ ${t.targetLabel}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: Tk.fzSm, color: Tk.muted)),
            const SizedBox(height: Tk.spaceSm),
            ClipRRect(
              // 4px 高进度条的圆角(radius 按条高缩放渲染,视觉=胶囊不变)
              borderRadius: BorderRadius.circular(Tk.rSm),
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
              spacing: Tk.spaceMd,
              runSpacing: 2,
              children: [
                Text('${t.doneFiles ?? 0} / ${t.totalFiles ?? 0} 个文件',
                    style: const TextStyle(fontSize: Tk.fzSm, color: Tk.muted)),
                Text(
                    '${fmtBytes(t.doneBytes)}'
                    '${t.totalBytes == null ? '' : ' / ${fmtBytes(t.totalBytes!)}'}',
                    style: const TextStyle(fontSize: Tk.fzSm, color: Tk.muted)),
                if (t.isActive)
                  Text(
                      t.etaSeconds != null
                          ? '预计剩余 ${fmtEtaShort(t.etaSeconds!)}'
                          : '估算中',
                      style:
                          const TextStyle(fontSize: Tk.fzSm, color: Tk.muted)),
                if (t.status == 'failed' && t.failReason != null)
                  Text(kFailReasonLabels[t.failReason!] ?? t.failReason!,
                      style: const TextStyle(fontSize: Tk.fzSm, color: Tk.red)),
                if (t.status == 'completed' && (t.totalFiles ?? 0) == 0)
                  const Text('源目录为空',
                      style: TextStyle(fontSize: Tk.fzSm, color: Tk.muted)),
                if (t.status == 'cancelled' && (t.cancelledFiles ?? 0) > 0)
                  Text('已取消 ${t.cancelledFiles} 个文件',
                      style:
                          const TextStyle(fontSize: Tk.fzSm, color: Tk.muted)),
              ],
            ),
            // E12:操作行触控加高(≥44 逻辑高;保留文字钮——可读性优于裸图标)
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              _cardAction(context, '查看',
                  onPressed: () => Navigator.of(context)
                      .pushNamed('/baidu-task', arguments: t.id)),
              if (t.isActive)
                _cardAction(context, '取消',
                    foreground: Tk.red,
                    onPressed: busy ? null : () => onAction('cancel')),
              if (t.canRetryFailed)
                _cardAction(context, '全部重试失败',
                    onPressed: busy ? null : () => onAction('retry-failed')),
              if (t.isTerminal)
                _cardAction(context, '删除',
                    foreground: Tk.red,
                    onPressed: busy ? null : () => onAction('delete')),
            ]),
          ],
        ),
      ),
    );
  }

  /// E12:任务卡文字钮(加高触控:44 逻辑高 + 左间距,替代紧凑默认档)。
  Widget _cardAction(
    BuildContext context,
    String label, {
    VoidCallback? onPressed,
    Color? foreground,
  }) =>
      Padding(
        padding: const EdgeInsets.only(left: Tk.spaceXs),
        child: TextButton(
          style: TextButton.styleFrom(
            foregroundColor: foreground,
            minimumSize: const Size(44, 44),
            padding: const EdgeInsets.symmetric(horizontal: Tk.spaceSm),
            visualDensity: VisualDensity.standard,
          ),
          onPressed: onPressed,
          child: Text(label, style: const TextStyle(fontSize: Tk.fzSm)),
        ),
      );
}
