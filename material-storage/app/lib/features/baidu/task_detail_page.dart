/// BaiduTaskDetailPage — 任务详情(B9 §8.10,web BaiduTaskDetail 移动版):
/// 头部=状态徽标/源目录/目标/进度(文件+字节)/ETA/失败原因 + 任务级操作
/// (取消/全部重试失败/删除,与列表卡同口径);主体=BaiduTaskFiles 文件明细
/// (状态筛选+分页+文件级三操作复用 B8 处置手册);行操作成功(任务复活)
/// 后重拉任务概要,保持头部与判定同步。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/baidu_api.dart';
import '../../core/api/ms_api.dart';
import '../../core/fmt.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';
import '../../widgets/error_view.dart';
import '../admin/baidu_task_labels.dart';
import 'baidu_task_files.dart';

class BaiduTaskDetailPage extends StatefulWidget {
  const BaiduTaskDetailPage({super.key, required this.taskId, this.api});

  final String taskId;

  /// 测试注入;缺省取现役 session 客户端。
  final BaiduApi? api;

  @override
  State<BaiduTaskDetailPage> createState() => _BaiduTaskDetailPageState();
}

class _BaiduTaskDetailPageState extends State<BaiduTaskDetailPage> {
  BaiduApi get _api => widget.api ?? session.api!.baidu;

  BaiduTask? _task;
  String? _error;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final t = await _api.getTask(widget.taskId);
      if (!mounted) return;
      setState(() {
        _task = t;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = errorMessage(e, '任务详情加载失败'));
    }
  }

  Future<void> _taskAction(String action) async {
    if (_busy || _task == null) return;
    // 确认口径同列表卡(web Popconfirm 同款:取消/删除确认,重试直发)
    if (action == 'cancel' || action == 'delete') {
      final (title, content, okText) = action == 'cancel'
          ? ('取消该任务?', '未完成文件将停止导入(已完成文件保留)。', '取消任务')
          : ('删除该任务记录?', '仅删除任务记录与进度,已导入的文件不受影响。', '删除');
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(foregroundColor: Tk.red),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(okText),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      switch (action) {
        case 'cancel':
          final r = await _api.cancelTask(widget.taskId);
          if (!mounted) return;
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
              content: Text(r.finalized
                  ? '任务已取消'
                  : '取消请求已提交,任务将在最近检查点停止')));
        case 'retry-failed':
          await _api.retryFailed(widget.taskId);
          if (!mounted) return;
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(content: Text('失败文件已全部重新排队')));
        case 'delete':
          await _api.deleteTask(widget.taskId);
          if (!mounted) return;
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(const SnackBar(content: Text('任务记录已删除')));
          Navigator.of(context).pop(true);
          return;
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      // 传输层异常中文兜底(§4.1 勿渲染原始异常对象)
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(errorMessage(e, '操作失败,请稍后重试'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = _task;
    return Scaffold(
      appBar: AppBar(title: const Text('任务详情')),
      body: _error != null && t == null
          ? ErrorView(message: _error!, onRetry: _reload)
          : t == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        children: [_summaryCard(t)],
                      ),
                    ),
                    SizedBox(
                      height: 360,
                      child: BaiduTaskFiles(
                        key: ValueKey('${t.id}:${t.status}'),
                        taskId: t.id,
                        taskStatus: t.status,
                        api: widget.api,
                        onTaskRevived: _reload,
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _summaryCard(BaiduTask t) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Badge(
                  label: taskStatusText(t.displayStatus),
                  tone: baiduTaskTone(t.displayStatus)),
              if (t.cancelRequested && t.isActive) ...[
                const SizedBox(width: 6),
                const Badge(label: '取消中', tone: BadgeTone.amber),
              ],
              const SizedBox(width: 8),
              Expanded(
                child: Text(t.sourceDir,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 6),
            Text('目标:${t.targetLabel}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Tk.muted)),
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
                if (t.isTerminal && (t.failedFiles ?? 0) > 0)
                  Text('失败 ${t.failedFiles}',
                      style: const TextStyle(fontSize: 11.5, color: Tk.red)),
                if (t.isTerminal && (t.skippedFiles ?? 0) > 0)
                  Text('跳过 ${t.skippedFiles}',
                      style: const TextStyle(fontSize: 11.5, color: Tk.muted)),
              ],
            ),
            if (t.status == 'failed' || t.status == 'completed')
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '「覆盖导入」会永久删除原文件后重新导入(需管理权限);'
                  '同一任务同时只能有一个覆盖在途。',
                  style: TextStyle(fontSize: 11.5, color: Tk.amber),
                ),
              ),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              if (t.isActive)
                TextButton(
                  onPressed: _busy ? null : () => _taskAction('cancel'),
                  child:
                      const Text('取消', style: TextStyle(color: Tk.red)),
                ),
              if (t.canRetryFailed)
                TextButton(
                  onPressed: _busy ? null : () => _taskAction('retry-failed'),
                  child: const Text('全部重试失败'),
                ),
              if (t.isTerminal)
                TextButton(
                  onPressed: _busy ? null : () => _taskAction('delete'),
                  child: const Text('删除', style: TextStyle(color: Tk.red)),
                ),
            ]),
          ],
        ),
      ),
    );
  }
}
