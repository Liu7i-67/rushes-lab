/// TransferCard — 传输任务卡(§6 F11):AppCard 内图标容器 44(上传金浅底/
/// 下载 ok 浅底)+ 文件名 15.5 + 路径 13 + 状态徽标 + 金色进度条(失败
/// danger、完成 ok、取消 ink3)+ 字节/百分比 tabular;活动态取消、失败/取消
/// 重试、终态移除(确认语义由页面层处理)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/fmt.dart';
import '../../core/transfers/transfer_task.dart';
import '../../theme/context_tk.dart';
import '../../theme/tk_colors.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
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
    final tk = context.tk;
    final t = task;
    final active = !t.status.isTerminal;
    final upload = t.kind == TransferKind.upload;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(
        Tk.spaceMd,
        Tk.spaceMd,
        Tk.spaceSm,
        Tk.spaceMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: upload ? tk.goldSoft : tk.okSoft,
                  borderRadius: BorderRadius.circular(Tk.rSm),
                ),
                child: Icon(
                  upload ? Icons.upload_outlined : Icons.download_outlined,
                  size: 22,
                  color: upload ? tk.goldInk : tk.ok,
                ),
              ),
              const SizedBox(width: Tk.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: Tk.fzRowTitle,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                        color: tk.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      t.where,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                    ),
                  ],
                ),
              ),
              if (active)
                IconButton(
                  onPressed: onCancel,
                  icon: const Icon(Icons.close_outlined),
                  tooltip: '取消',
                )
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (t.status == TransferStatus.failed ||
                        t.status == TransferStatus.canceled)
                      IconButton(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh_outlined),
                        // 下载重试=重新下载并落盘;上传=从头重传
                        tooltip: upload ? '重试(从头重传)' : '重试(重新下载并落盘)',
                      ),
                    IconButton(
                      onPressed: onRemove,
                      icon: Icon(Icons.delete_outline_outlined, color: tk.ink3),
                      tooltip: '移除',
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: t.progress,
              minHeight: 4,
              color: _barColor(tk),
              backgroundColor: tk.surface3,
            ),
          ),
          const SizedBox(height: Tk.spaceSm),
          if (active)
            Row(
              children: [
                Badge(label: t.status.label, tone: BadgeTone.gold),
                const Spacer(),
                Text(
                  _activeLine,
                  style: TextStyle(
                    fontSize: Tk.fzMd,
                    color: tk.ink2,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                Badge(label: t.status.label, tone: _badgeTone),
                if ((t.error ?? _sizeLine).isNotEmpty) ...[
                  const SizedBox(width: Tk.spaceSm),
                  Expanded(
                    child: Text(
                      t.error ?? _sizeLine,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                    ),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  BadgeTone get _badgeTone => switch (task.status) {
    TransferStatus.done => BadgeTone.ok,
    TransferStatus.failed => BadgeTone.danger,
    TransferStatus.canceled => BadgeTone.neutral,
    _ => BadgeTone.gold,
  };

  Color _barColor(TkColors tk) => switch (task.status) {
    TransferStatus.done => tk.ok,
    TransferStatus.failed => tk.danger,
    TransferStatus.canceled => tk.ink3,
    _ => tk.gold,
  };

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
