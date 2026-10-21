/// 百度备份任务详情(B8 功能点 7;web AdminBaiduTasksPage TaskDetailDrawer
/// 移动版):概要(状态/进度/计数/失败取消原因)+ 任务字段(绑定快照/当前绑定)
/// + 调度观测字段 + 文件明细(BaiduTaskFileList 拆件:状态过滤/分页/文件级
/// 三操作)。admin 看后端原始 status/last_error,不做 queued 派生(方案 §3.2)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart';
import '../../core/fmt.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';
import 'baidu_task_file_list.dart';
import 'baidu_task_labels.dart';

/// 打开任务详情;返回是否文件明细有变更(调用方据此刷新列表)。
Future<bool> showBaiduTaskDetailSheet(
    BuildContext context, AdminBaiduTask task) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _BaiduTaskDetailSheet(task: task),
  );
  return ok ?? false;
}

class _BaiduTaskDetailSheet extends StatefulWidget {
  const _BaiduTaskDetailSheet({required this.task});

  final AdminBaiduTask task;

  @override
  State<_BaiduTaskDetailSheet> createState() => _BaiduTaskDetailSheetState();
}

class _BaiduTaskDetailSheetState extends State<_BaiduTaskDetailSheet> {
  AdminBaiduTaskDetail? _detail;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    try {
      final d = await session.api!.adminBaidu.taskDetail(widget.task.id);
      if (!mounted) return;
      setState(() => _detail = d);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is ApiException ? e.message : '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _detail ?? widget.task;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.9,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Badge(
                        label: taskStatusText(t.status),
                        tone: baiduTaskTone(t.status)),
                    if (t.cancelRequested && t.isActive)
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Badge(label: '取消请求中', tone: BadgeTone.amber),
                      ),
                    const Spacer(),
                    Text(
                        '共 ${t.totalFiles} · 完成 ${t.doneFiles}'
                        '${t.skippedFiles > 0 ? ' · 跳过 ${t.skippedFiles}' : ''}'
                        '${t.failedFiles > 0 ? ' · 失败 ${t.failedFiles}' : ''}',
                        style:
                            const TextStyle(fontSize: 11, color: Tk.muted)),
                  ]),
                  const SizedBox(height: 6),
                  Text(t.sourceDir,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5)),
                  // enumerating 阶段清单未就绪,不渲染进度条(web 同款改进)
                  if (t.status != 'enumerating') ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: t.progressPct / 100,
                      backgroundColor: Tk.fill,
                    ),
                  ],
                  Text(
                    '${fmtBytes(t.doneBytes)}'
                    '${t.totalBytes > 0 ? ' / ${fmtBytes(t.totalBytes)}' : ''}'
                    ' · ${t.project.name} / ${t.targetFolder?.name ?? '已删'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Tk.muted),
                  ),
                  if (t.failReason != null)
                    Text(
                        '失败原因:'
                        '${kFailReasonLabels[t.failReason] ?? t.failReason}',
                        style: const TextStyle(
                            fontSize: 11.5, color: Tk.red)),
                  if (_error != null)
                    Text(_error!,
                        style: TextStyle(
                            fontSize: 11.5,
                            color: Theme.of(context).colorScheme.error)),
                ],
              ),
            ),
            if (_detail != null) ..._detailFields(_detail!),
            const Divider(height: 1),
            // Expanded:文件列表 Column 内含 Expanded,须吃外层 Column 剩余高度
            Expanded(
              child: BaiduTaskFileList(
                task: t,
                onChanged: () => Navigator.of(context).pop(true),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _detailFields(AdminBaiduTaskDetail d) {
    String tm(String? iso) => iso == null ? '—' : fmtIsoShort(iso);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Column(children: [
          _kv(
              '用户',
              '${d.user.name}'
              '${d.user.username != null ? '(${d.user.username})' : ''}'),
          _kv(
              '失败/取消原因',
              '失败:${d.failReason == null ? '—' : (kFailReasonLabels[d.failReason] ?? d.failReason!)}'
              ' · 取消:${d.cancelReason == null ? '—' : (kCancelReasonLabels[d.cancelReason] ?? d.cancelReason!)}'),
          _kv('创建/更新', '${tm(d.createdAt)} / ${tm(d.updatedAt)}'),
          _kv('绑定 UID 快照(创建时)', d.boundBaiduUid ?? '—'),
          _kv('当前绑定', d.binding == null
              ? '无绑定行'
              : '${d.binding!.baiduUid}(${d.binding!.status})'),
          _kv(
              '调度观测',
              '复活 ${d.retryCount} 次 · 枚举${d.enumDone ? '完成' : '未完成'} · '
              '最近派发 ${tm(d.dispatchedAt)} · 轮起点 ${tm(d.roundStartedAt)} · '
              '租约 ${tm(d.leaseUntil)} · Runner ${d.runnerId ?? '—'}'),
        ]),
      ),
    ];
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 128,
              child: Text(k,
                  style: const TextStyle(fontSize: 11, color: Tk.subtle)),
            ),
            Expanded(
              child: Text(v,
                  style: const TextStyle(fontSize: 11, color: Tk.muted)),
            ),
          ],
        ),
      );
}
