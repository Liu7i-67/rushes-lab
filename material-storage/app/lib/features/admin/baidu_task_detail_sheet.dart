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
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/badge.dart';
import 'baidu_task_file_list.dart';
import 'baidu_task_labels.dart';

/// 打开任务详情;返回是否文件明细有变更(调用方据此刷新列表)。
Future<bool> showBaiduTaskDetailSheet(
  BuildContext context,
  AdminBaiduTask task,
) async {
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
      setState(() => _error = errorMessage(e, '详情加载失败,请稍后重试'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final t = _detail ?? widget.task;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.92,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Tk.spacePage,
                0,
                Tk.spaceSm,
                Tk.spaceSm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '备份任务详情',
                          style: TextStyle(
                            fontSize: Tk.fzSection,
                            fontWeight: FontWeight.w600,
                            color: tk.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          t.sourceDir,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            // 概要 + 调度字段限高滚动(小屏给文件明细留出至少半屏);
            // 内容超高时可滚,不挤压下方的文件列表
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.34,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Tk.spacePage,
                      ),
                      child: AppCard(
                        padding: const EdgeInsets.all(Tk.spaceMd),
                        child: _summary(t),
                      ),
                    ),
                    if (_detail != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          Tk.spacePage,
                          Tk.spaceSm,
                          Tk.spacePage,
                          0,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: _detailFields(_detail!),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Tk.spaceSm),
            Divider(height: 1, color: tk.line),
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

  Widget _summary(AdminBaiduTask t) {
    final tk = context.tk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Badge(
              label: taskStatusText(t.status),
              tone: baiduTaskTone(t.status),
            ),
            if (t.cancelRequested && t.isActive)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Badge(label: '取消请求中', tone: BadgeTone.warn),
              ),
            const Spacer(),
            Text(
              '共 ${t.totalFiles} · 完成 ${t.doneFiles}'
              '${t.skippedFiles > 0 ? ' · 跳过 ${t.skippedFiles}' : ''}'
              '${t.failedFiles > 0 ? ' · 失败 ${t.failedFiles}' : ''}',
              style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // enumerating 阶段清单未就绪,不渲染进度条(web 同款改进)
        if (t.status != 'enumerating') ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(Tk.rPill),
            child: LinearProgressIndicator(
              value: t.progressPct / 100,
              minHeight: 6,
              backgroundColor: tk.surface3,
            ),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          '${fmtBytes(t.doneBytes)}'
          '${t.totalBytes > 0 ? ' / ${fmtBytes(t.totalBytes)}' : ''}'
          ' · ${t.project.name} / ${t.targetFolder?.name ?? '已删'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
        ),
        if (t.failReason != null)
          Text(
            '失败原因:${kFailReasonLabels[t.failReason] ?? t.failReason}',
            style: TextStyle(fontSize: Tk.fzMd, color: tk.danger),
          ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(fontSize: Tk.fzMd, color: tk.danger),
          ),
      ],
    );
  }

  List<Widget> _detailFields(AdminBaiduTaskDetail d) {
    String tm(String? iso) => iso == null ? '—' : fmtIsoShort(iso);
    return [
      _kv(
        '用户',
        '${d.user.name}'
            '${d.user.username != null ? '(${d.user.username})' : ''}',
      ),
      _kv(
        '失败/取消原因',
        '失败:${d.failReason == null ? '—' : (kFailReasonLabels[d.failReason] ?? d.failReason!)}'
            ' · 取消:${d.cancelReason == null ? '—' : (kCancelReasonLabels[d.cancelReason] ?? d.cancelReason!)}',
      ),
      _kv('创建/更新', '${tm(d.createdAt)} / ${tm(d.updatedAt)}'),
      _kv('绑定 UID 快照(创建时)', d.boundBaiduUid ?? '—'),
      _kv(
        '当前绑定',
        d.binding == null
            ? '无绑定行'
            : '${d.binding!.baiduUid}(${d.binding!.status})',
      ),
      _kv(
        '调度观测',
        '复活 ${d.retryCount} 次 · 枚举${d.enumDone ? '完成' : '未完成'} · '
            '最近派发 ${tm(d.dispatchedAt)} · 轮起点 ${tm(d.roundStartedAt)} · '
            '租约 ${tm(d.leaseUntil)} · Runner ${d.runnerId ?? '—'}',
      ),
    ];
  }

  Widget _kv(String k, String v) {
    final tk = context.tk;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
            child: Text(
              k,
              style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: TextStyle(fontSize: Tk.fzMd, color: tk.ink2),
            ),
          ),
        ],
      ),
    );
  }
}
