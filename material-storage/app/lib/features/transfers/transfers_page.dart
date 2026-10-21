/// 传输页(方案 §7 / B3 功能点 4):tab3 替换占位。全部/上传/下载分段;
/// 进行中(进度/百分比/取消)+ 已完成(重试/移除);AppBar 清已完成只清终态;
/// TabBar 传输格 badge=running 数(见 shell/tab_bar.dart)。任务不持久化。
library;

import 'package:flutter/material.dart';

import '../../core/transfers/transfer_queue.dart';
import '../../core/transfers/transfer_task.dart';
import '../../widgets/empty_state.dart';
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
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: SegmentedButton<_Segment>(
                  segments: const [
                    ButtonSegment(
                        value: _Segment.all, label: Text('全部')),
                    ButtonSegment(
                        value: _Segment.upload, label: Text('上传')),
                    ButtonSegment(
                        value: _Segment.download, label: Text('下载')),
                  ],
                  selected: {_segment},
                  onSelectionChanged: (s) =>
                      setState(() => _segment = s.first),
                ),
              ),
              Expanded(
                child: tasks.isEmpty
                    ? const EmptyState(
                        icon: Icons.sync_outlined,
                        message: '暂无传输任务',
                      )
                    : ListView.builder(
                        itemCount: tasks.length,
                        itemBuilder: (context, i) {
                          final t = tasks[i];
                          return TransferCard(
                            task: t,
                            onCancel: () => q.cancel(t.id),
                            onRetry: () => q.retry(t.id),
                            onRemove: () => q.remove(t.id),
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
