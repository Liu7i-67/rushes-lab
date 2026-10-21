/// TransferCard — 传输任务卡(§7;app-polish E7 重构):圆角 rLg 卡(与百度
/// 任务卡同语言:图标容器+标题+副标题+内嵌线性进度条+进度行);终态=状态徽标
/// +错误/字节行+重试(failed/canceled)/移除。速度/剩余时间不做(App 简化,
/// §17 已登记差异)。取消/移除确认由页面层处理(onCancel/onRemove 已确认语义)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/fmt.dart';
import '../../core/transfers/transfer_task.dart';
import '../../theme/tokens.dart';
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
    // E7:圆角卡容器(rLg + surface 底,与百度任务卡同语言);ListTile 结构
    // 保留(行语义/无障碍不变)
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Tk.surface,
        borderRadius: const BorderRadius.all(Radius.circular(Tk.rLg)),
        border: Border.all(color: Tk.border),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
            horizontal: Tk.spaceMd, vertical: Tk.spaceXs),
        // 图标容器化(44 圆角块,项目/文件夹行同语言)
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: t.kind == TransferKind.upload
                ? Tk.accentFaint
                : Tk.green.withValues(alpha: 0.10),
            borderRadius: const BorderRadius.all(Radius.circular(Tk.rMd)),
          ),
          child: Icon(
            t.kind == TransferKind.upload
                ? Icons.upload_outlined
                : Icons.download_outlined,
            size: 22,
            color: t.kind == TransferKind.upload ? Tk.accentStrong : Tk.green,
          ),
        ),
        title: Text(
          t.filename,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: Tk.fzTitle),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.where,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: Tk.fzMd, color: Tk.muted),
            ),
            const SizedBox(height: Tk.spaceXs),
            if (active) ...[
              // 内嵌进度条(圆角胶囊细条;2≈半高与条高耦合,非档值保留,
              // A3 映射表「极小缝保留」注,同 upload_sheet 口径)
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: t.progress,
                  minHeight: 4,
                  backgroundColor: Tk.fill,
                ),
              ),
              const SizedBox(height: Tk.spaceXs),
              // 进度行:状态说明居左,「百分比 · 字节」右对齐(E7;
              // 状态词用「进行中」,避免与「上传/下载」分段标签文字撞车)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '进行中',
                      style: const TextStyle(
                          fontSize: Tk.fzMd, color: Tk.muted),
                    ),
                  ),
                  Text(
                    _activeLine,
                    style: const TextStyle(fontSize: Tk.fzMd, color: Tk.muted),
                  ),
                ],
              ),
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
                  const SizedBox(width: Tk.spaceSm),
                  Expanded(
                    child: Text(
                      t.error ?? _sizeLine,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: Tk.fzMd, color: Tk.muted),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        // 活动态=取消;终态=重试(failed/canceled)+移除;done 只留移除
        // (done 重传必撞同名 409 查重,不提供)。触控:默认 IconButton 尺寸
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
                    icon: const Icon(Icons.delete_outline_outlined,
                        color: Tk.muted),
                    tooltip: '移除',
                  ),
                ],
              ),
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
