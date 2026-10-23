/// 传输页(§6 F11):PageHeader 大标题 + 任务计数 + 「清已完成」,分段
/// AppSegmented(全部/上传/下载,带实时计数);TransferCard 列表;空态引导。
/// 取消/移除确认、清已完成只清终态、重试语义均与旧版一致。
library;

import 'package:flutter/material.dart';

import '../../core/transfers/transfer_queue.dart';
import '../../core/transfers/transfer_task.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/page_header.dart';
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

  /// 危险动作统一确认(取消=未完成文件停止;移除=记录删除)。
  Future<bool> _confirmDanger(
    String title,
    String content,
    String okLabel,
  ) async {
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
      body: AnimatedBuilder(
        animation: q,
        builder: (context, _) {
          final tasks = q.tasks.where(_match).toList();
          final uploadCount = q.tasks
              .where((t) => t.kind == TransferKind.upload)
              .length;
          final downloadCount = q.tasks
              .where((t) => t.kind == TransferKind.download)
              .length;
          final hasTerminal = q.tasks.any((t) => t.status.isTerminal);
          return Column(
            children: [
              PageHeader(
                title: '传输',
                count: '${q.tasks.length}',
                subtitle: '上传与下载在后台继续，退出页面不会中断',
                actions: [
                  TextButton(
                    onPressed: hasTerminal ? q.clearFinished : null,
                    child: const Text('清已完成'),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Tk.spacePage,
                  Tk.spaceMd,
                  Tk.spacePage,
                  Tk.spaceSm,
                ),
                child: AppSegmented<_Segment>(
                  segments: [
                    Segment(
                      value: _Segment.all,
                      label: '全部',
                      count: q.tasks.length,
                    ),
                    Segment(
                      value: _Segment.upload,
                      label: '上传',
                      count: uploadCount,
                    ),
                    Segment(
                      value: _Segment.download,
                      label: '下载',
                      count: downloadCount,
                    ),
                  ],
                  value: _segment,
                  onChanged: (v) => setState(() => _segment = v),
                ),
              ),
              Expanded(
                child: tasks.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(top: 48),
                        children: const [
                          EmptyState(
                            icon: Icons.sync_outlined,
                            message: '暂无传输任务',
                            description:
                                '下载与上传任务会在这里显示进度;'
                                '完成后可在任务卡重试或移除',
                          ),
                        ],
                      )
                    : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(
                          Tk.spacePage,
                          Tk.spaceXs,
                          Tk.spacePage,
                          Tk.spaceXl,
                        ),
                        itemCount: tasks.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: Tk.spaceMd),
                        itemBuilder: (context, i) {
                          final t = tasks[i];
                          return TransferCard(
                            task: t,
                            onCancel: () async {
                              if (await _confirmDanger(
                                '取消该传输任务?',
                                '「${t.filename}」未完成的部分将被放弃,'
                                    '可稍后重新上传/下载。',
                                '取消任务',
                              )) {
                                q.cancel(t.id);
                              }
                            },
                            onRetry: () => q.retry(t.id),
                            onRemove: () async {
                              if (await _confirmDanger(
                                '移除该任务记录?',
                                '仅从列表移除「${t.filename}」,'
                                    '已完成文件不受影响。',
                                '移除',
                              )) {
                                q.remove(t.id);
                                if (context.mounted) {
                                  toast(context, '已移除任务记录');
                                }
                              }
                            },
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
