/// 传输页(方案 §7 / B3 功能点 4;app-polish E7 精修):全部/上传/下载分段
/// (分段标签带实时计数:「全部 3」);进行中(进度/百分比/取消,取消带
/// danger 确认)+ 已完成(重试/移除,移除带 danger 确认);AppBar 清已完成
/// 只清终态;空态引导。TabBar 传输格 badge=running 数(见 shell/tab_bar.dart)。
/// 任务不持久化。
library;

import 'package:flutter/material.dart';

import '../../core/transfers/transfer_queue.dart';
import '../../core/transfers/transfer_task.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/toast.dart';
import 'transfer_card.dart';

enum _Segment { all, upload, download }

class TransfersPage extends StatefulWidget {
  const TransfersPage({super.key, this.queue});

  /// 测试注入用;默认全局单例。
  final TransferQueue? queue;

  @override
  State<TransfersPage> createState() => _TransfersPageState();
}

class _TransfersPageState extends State<TransfersPage> {
  var _segment = _Segment.all;

  bool _match(TransferTask t) => switch (_segment) {
        _Segment.all => true,
        _Segment.upload => t.kind == TransferKind.upload,
        _Segment.download => t.kind == TransferKind.download,
      };

  /// E7:危险动作统一确认(取消=未完成文件停止;移除=记录删除)。
  /// 返回 true=用户确认。
  Future<bool> _confirmDanger(String title, String content, String okLabel) async {
    final ok = await showAppConfirm(
      context,
      title: title,
      content: content,
      confirmLabel: okLabel,
      danger: true,
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.queue ?? TransferQueue.I;
    return Scaffold(
      appBar: AppBar(
        title: const Text('传输'),
        actions: [
          // 清已完成:只清终态(done/failed/canceled),活动任务保留
          AnimatedBuilder(
            animation: q,
            builder: (context, _) {
              final hasTerminal =
                  q.tasks.any((t) => t.status.isTerminal);
              return TextButton(
                onPressed: hasTerminal ? q.clearFinished : null,
                child: const Text('清已完成'),
              );
            },
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: q,
        builder: (context, _) {
          final tasks = q.tasks.where(_match).toList();
          // E7:分段计数(全部 N / 上传 N / 下载 N,随队列实时刷新)
          final uploadCount =
              q.tasks.where((t) => t.kind == TransferKind.upload).length;
          final downloadCount =
              q.tasks.where((t) => t.kind == TransferKind.download).length;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: SegmentedButton<_Segment>(
                  segments: [
                    ButtonSegment(
                        value: _Segment.all,
                        label: Text('全部 ${q.tasks.length}')),
                    ButtonSegment(
                        value: _Segment.upload,
                        label: Text('上传 $uploadCount')),
                    ButtonSegment(
                        value: _Segment.download,
                        label: Text('下载 $downloadCount')),
                  ],
                  selected: {_segment},
                  onSelectionChanged: (s) =>
                      setState(() => _segment = s.first),
                ),
              ),
              Expanded(
                child: tasks.isEmpty
                    ? // E7:空态引导(说明任务来源,下拉可刷新)
                    ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 80),
                          const EmptyState(
                            icon: Icons.sync_outlined,
                            message: '暂无传输任务',
                          ),
                          const SizedBox(height: Tk.spaceSm),
                          Text(
                            '下载与上传任务会在这里显示进度;完成后可在任务卡重试或移除',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Tk.subtle, fontSize: Tk.fzMd),
                          ),
                        ],
                      )
                    : ListView.separated(
                        itemCount: tasks.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: Tk.spaceSm),
                        itemBuilder: (context, i) {
                          final t = tasks[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: Tk.spaceMd),
                            child: TransferCard(
                              task: t,
                              onCancel: () async {
                                // E7:取消带 danger 确认
                                if (await _confirmDanger(
                                    '取消该传输任务?',
                                    '「${t.filename}」未完成的部分将被放弃,可稍后重新上传/下载。',
                                    '取消任务')) {
                                  q.cancel(t.id);
                                }
                              },
                              onRetry: () => q.retry(t.id),
                              onRemove: () async {
                                // E7:移除带 danger 确认(仅删记录,不影响已落盘文件)
                                if (await _confirmDanger(
                                    '移除该任务记录?',
                                    '仅从列表移除「${t.filename}」,已完成文件不受影响。',
                                    '移除')) {
                                  q.remove(t.id);
                                  if (context.mounted) {
                                    toast(context, '已移除任务记录');
                                  }
                                }
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
