/// BaiduTaskDetailPage — 任务详情(B9 §8.10,web BaiduTaskDetail 移动版):
/// 页首(返回 + 源目录副标题)+ 状态卡(状态徽标/目标/进度/统计/失败原因)
/// + 任务级操作(取消/全部重试失败/删除,与列表卡同口径);主体=
/// BaiduTaskFiles 文件明细(状态筛选+分页+文件级三操作复用 B8 处置手册);
/// 行操作成功(任务复活)后重拉任务概要,保持头部与判定同步。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/baidu_api.dart';
import '../../core/api/ms_api.dart';
import '../../core/fmt.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/badge.dart';
import '../../widgets/error_view.dart';
import '../../widgets/page_header.dart';
import '../../widgets/toast.dart';
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
    // 确认口径同列表卡(web Popconfirm 同款:取消/删除确认,重试直发)。
    // E12/E14:确认统一 showAppConfirm(danger)
    if (action == 'cancel' || action == 'delete') {
      final (title, content, okText) = action == 'cancel'
          ? ('取消该任务?', '未完成文件将停止导入(已完成文件保留)。', '取消任务')
          : ('删除该任务记录?', '仅删除任务记录与进度,已导入的文件不受影响。', '删除');
      final ok = await showAppConfirm(
        context,
        title: title,
        content: content,
        confirmLabel: okText,
        danger: true,
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      switch (action) {
        case 'cancel':
          final r = await _api.cancelTask(widget.taskId);
          if (!mounted) return;
          toast(context, r.finalized ? '任务已取消' : '取消请求已提交,任务将在最近检查点停止');
        case 'retry-failed':
          await _api.retryFailed(widget.taskId);
          if (!mounted) return;
          toast(context, '失败文件已全部重新排队', tone: ToastTone.success);
        case 'delete':
          await _api.deleteTask(widget.taskId);
          if (!mounted) return;
          toast(context, '任务记录已删除');
          Navigator.of(context).pop(true);
          return;
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      toast(context, e.message, tone: ToastTone.error);
    } catch (e) {
      if (!mounted) return;
      // 传输层异常中文兜底(§4.1 勿渲染原始异常对象)
      toast(context, errorMessage(e, '操作失败,请稍后重试'), tone: ToastTone.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = _task;
    return Scaffold(
      body: Column(
        children: [
          PageHeader(back: true, title: '任务详情', subtitle: t?.sourceDir),
          Expanded(
            child: _error != null && t == null
                ? ErrorView(message: _error!, onRetry: _reload)
                : t == null
                ? const Center(child: CircularProgressIndicator())
                // E12:概要卡自适应内容高(SingleChildScrollView 收缩,不再写死
                // 360 定高挤压小屏);文件明细区 Expanded 吃剩余空间
                : Column(
                    children: [
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(
                            Tk.spacePage,
                            Tk.spaceLg,
                            Tk.spacePage,
                            0,
                          ),
                          child: _summaryCard(t),
                        ),
                      ),
                      Expanded(
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
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(BaiduTask t) {
    final tk = context.tk;
    final progressColor = t.status == 'failed'
        ? tk.danger
        : t.status == 'completed'
        ? tk.ok
        : tk.gold;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Badge(
                label: taskStatusText(t.displayStatus),
                tone: baiduTaskTone(t.displayStatus),
              ),
              if (t.cancelRequested && t.isActive) ...[
                const SizedBox(width: 6),
                const Badge(label: '取消中', tone: BadgeTone.warn),
              ],
              const SizedBox(width: Tk.spaceSm),
              Expanded(
                child: Text(
                  t.sourceDir,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '目标:${t.targetLabel}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
          ),
          const SizedBox(height: Tk.spaceMd),
          ClipRRect(
            borderRadius: BorderRadius.circular(Tk.rSm),
            child: LinearProgressIndicator(
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
              if (t.isTerminal && (t.failedFiles ?? 0) > 0)
                Text(
                  '失败 ${t.failedFiles}',
                  style: TextStyle(fontSize: Tk.fzMd, color: tk.danger),
                ),
              if (t.isTerminal && (t.skippedFiles ?? 0) > 0)
                Text(
                  '跳过 ${t.skippedFiles}',
                  style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                ),
            ],
          ),
          if (t.status == 'failed' || t.status == 'completed')
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: Tk.spaceMd),
              padding: const EdgeInsets.all(Tk.spaceMd),
              decoration: BoxDecoration(
                color: tk.warnSoft,
                borderRadius: BorderRadius.circular(Tk.rSm),
              ),
              child: Text(
                '「覆盖导入」会永久删除原文件后重新导入(需管理权限);'
                '同一任务同时只能有一个覆盖在途。',
                style: TextStyle(
                  fontSize: Tk.fzSm,
                  height: 1.5,
                  color: tk.warn,
                ),
              ),
            ),
          const SizedBox(height: Tk.spaceXs),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (t.isActive)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: tk.danger,
                    minimumSize: const Size(44, 44),
                  ),
                  onPressed: _busy ? null : () => _taskAction('cancel'),
                  child: const Text('取消'),
                ),
              if (t.canRetryFailed)
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                  onPressed: _busy ? null : () => _taskAction('retry-failed'),
                  child: const Text('全部重试失败'),
                ),
              if (t.isTerminal)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: tk.danger,
                    minimumSize: const Size(44, 44),
                  ),
                  onPressed: _busy ? null : () => _taskAction('delete'),
                  child: const Text('删除'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
