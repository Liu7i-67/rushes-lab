/// 百度任务卡(B9 §8.10,自 baidu_page 拆件守 300 行硬顶;web TaskItem
/// 移动版):源目录 14.5/w600 + 目标 13/ink3 + 状态徽标 + 金色/红色/绿色
/// 进度条 + 文件数/字节/ETA 13 + 失败原因红字 + 操作行(查看/取消/全部重试
/// 失败/删除,44 高文字钮,回调上抛页面执行确认)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/fmt.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
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
    final tk = context.tk;
    final t = task;
    final progressColor = t.status == 'failed'
        ? tk.danger
        : t.status == 'completed'
        ? tk.ok
        : tk.gold;
    return AppCard(
      margin: const EdgeInsets.only(bottom: Tk.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t.sourceDir,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.5,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                    color: tk.ink,
                  ),
                ),
              ),
              const SizedBox(width: Tk.spaceSm),
              Badge(
                label: taskStatusText(t.displayStatus),
                tone: baiduTaskTone(t.displayStatus),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '→ ${t.targetLabel}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
          ),
          const SizedBox(height: Tk.spaceMd),
          ClipRRect(
            // 5px 高进度条的圆角(radius 按条高缩放渲染,视觉=胶囊不变)
            borderRadius: BorderRadius.circular(Tk.rSm),
            child: LinearProgressIndicator(
              key: ValueKey('baidu-task-progress-${t.id}'),
              value: t.progressPct / 100,
              minHeight: 5,
              backgroundColor: tk.surface3,
              color: progressColor,
            ),
          ),
          const SizedBox(height: Tk.spaceSm),
          Wrap(
            spacing: Tk.spaceMd,
            runSpacing: Tk.spaceXs,
            children: [
              Text(
                '${t.doneFiles ?? 0} / ${t.totalFiles ?? 0} 个文件',
                style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
              ),
              Text(
                '${fmtBytes(t.doneBytes)}'
                '${t.totalBytes == null ? '' : ' / ${fmtBytes(t.totalBytes!)}'}',
                style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
              ),
              if (t.isActive)
                Text(
                  t.etaSeconds != null
                      ? '预计剩余 ${fmtEtaShort(t.etaSeconds!)}'
                      : '估算中',
                  style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                ),
              if (t.status == 'failed' && t.failReason != null)
                Text(
                  kFailReasonLabels[t.failReason!] ?? t.failReason!,
                  style: TextStyle(fontSize: Tk.fzMd, color: tk.danger),
                ),
              if (t.status == 'completed' && (t.totalFiles ?? 0) == 0)
                Text(
                  '源目录为空',
                  style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                ),
              if (t.status == 'cancelled' && (t.cancelledFiles ?? 0) > 0)
                Text(
                  '已取消 ${t.cancelledFiles} 个文件',
                  style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                ),
            ],
          ),
          const SizedBox(height: Tk.spaceXs),
          // E12:操作行触控加高(≥44 逻辑高;保留文字钮——可读性优于裸图标)
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _cardAction(
                '查看',
                onPressed: () =>
                    Navigator.of(context)
                        .pushNamed('/baidu-task', arguments: t.id),
              ),
              if (t.isActive)
                _cardAction(
                  '取消',
                  foreground: tk.danger,
                  onPressed: busy ? null : () => onAction('cancel'),
                ),
              if (t.canRetryFailed)
                _cardAction(
                  '全部重试失败',
                  onPressed: busy ? null : () => onAction('retry-failed'),
                ),
              if (t.isTerminal)
                _cardAction(
                  '删除',
                  foreground: tk.danger,
                  onPressed: busy ? null : () => onAction('delete'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// E12:任务卡文字钮(加高触控:44 逻辑高 + 左间距,替代紧凑默认档)。
  Widget _cardAction(
    String label, {
    VoidCallback? onPressed,
    Color? foreground,
  }) => Padding(
    padding: const EdgeInsets.only(left: Tk.spaceXs),
    child: TextButton(
      style: TextButton.styleFrom(
        foregroundColor: foreground,
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: Tk.spaceSm),
        visualDensity: VisualDensity.standard,
      ),
      onPressed: onPressed,
      child: Text(label, style: const TextStyle(fontSize: Tk.fzMd)),
    ),
  );
}
