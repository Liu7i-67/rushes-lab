/// 百度任务文件明细(用户侧;B9 §8.10):AppChip 状态筛选 + 服务端分页 +
/// AppRow 文件行(状态图标/失败原因/行内操作,复用 B8 baidu_file_actions)。
library;

import 'package:flutter/material.dart';

import '../../core/api/baidu_api.dart';
import '../../core/api/ms_api.dart';
import '../../core/fmt.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_row.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/section_label.dart';
import '../../widgets/sheet_scaffold.dart';
import '../admin/baidu_file_actions.dart';
import '../admin/baidu_task_labels.dart';

const kFileListPageSize = 20;

class BaiduTaskFiles extends StatefulWidget {
  const BaiduTaskFiles({
    super.key,
    required this.taskId,
    required this.taskStatus,
    this.api,
    this.onTaskRevived,
  });

  final String taskId;
  final String taskStatus;
  final BaiduApi? api;
  final VoidCallback? onTaskRevived;

  @override
  State<BaiduTaskFiles> createState() => _BaiduTaskFilesState();
}

class _BaiduTaskFilesState extends State<BaiduTaskFiles> {
  BaiduApi get _api => widget.api ?? session.api!.baidu;

  var _status = '';
  var _files = <BaiduTaskFile>[];
  var _total = 0;
  var _loading = true;
  var _loadingMore = false;
  String? _error;
  var _reloadTag = 0;

  static const _filters = [
    ('', '全部'),
    ('pending', '等待'),
    ('importing', '导入中'),
    ('success', '成功'),
    ('skipped_exists', '跳过'),
    ('failed', '失败'),
    ('cancelled', '已取消'),
  ];

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    final tag = ++_reloadTag;
    setState(() {
      _loading = _files.isEmpty;
      _error = null;
    });
    try {
      final page = await _api.taskFiles(
        widget.taskId,
        status: _status.isEmpty ? null : _status,
        limit: kFileListPageSize,
        offset: reset ? 0 : _files.length,
      );
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        if (reset) {
          _files = page.items;
        } else {
          final known = _files.map((f) => f.id).toSet();
          _files.addAll(page.items.where((f) => !known.contains(f.id)));
        }
        _total = page.total;
        _loading = false;
      });
    } catch (e) {
      if (tag != _reloadTag || !mounted) return;
      // 失败显式呈现错误态(B8 P2-2:不冒充「无文件」),留手动重试
      setState(() {
        _loading = false;
        _error = errorMessage(e, '文件明细加载失败');
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    await _load();
    if (mounted) setState(() => _loadingMore = false);
  }

  Future<void> _runAction(BaiduTaskFile row, String action) async {
    final ok = await runFileAction(
      context,
      taskId: widget.taskId,
      taskStatus: widget.taskStatus,
      row: row,
      action: action,
      invoke: (a) => _api.fileOp(widget.taskId, row.id, a),
    );
    if (ok && mounted) {
      await _load(reset: true);
      widget.onTaskRevived?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Tk.spacePage),
            children: [
              for (final (key, label) in _filters)
                Padding(
                  padding: const EdgeInsets.only(right: Tk.spaceSm),
                  child: AppChip(
                    label: label,
                    selected: _status == key,
                    onTap: () {
                      setState(() => _status = key);
                      _load(reset: true);
                    },
                  ),
                ),
            ],
          ),
        ),
        SectionLabel(title: '文件明细', hint: '共 $_total 条'),
        Expanded(child: _list(context)),
      ],
    );
  }

  Widget _list(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: () => _load(reset: true));
    }
    if (_files.isEmpty) return const EmptyState(message: '无文件');
    final hasMore = _files.length < _total;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        Tk.spacePage,
        0,
        Tk.spacePage,
        Tk.spaceXl,
      ),
      itemCount: _files.length + (hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _files.length) {
          return Padding(
            padding: const EdgeInsets.all(Tk.spaceSm),
            child: OutlinedButton(
              onPressed: _loadingMore ? null : _loadMore,
              child: Text(_loadingMore ? '加载中…' : '加载更多'),
            ),
          );
        }
        return _fileCard(context, _files[i]);
      },
    );
  }

  Widget _fileCard(BuildContext context, BaiduTaskFile row) {
    final plan = fileRowActionPlan(widget.taskStatus, row);
    final error = row.status == 'failed' ? row.lastError : null;
    final details =
        '${fileStatusText(row.status)} · ${fmtBytes(row.sourceSize)}'
        ' · → ${row.targetDisplay}${error == null ? '' : ' · $error'}';
    return AppCard(
      margin: const EdgeInsets.only(bottom: Tk.spaceSm),
      padding: EdgeInsets.zero,
      child: AppRow(
        leading: _statusIcon(context, row.status),
        title: row.relPath,
        subtitle: details,
        trailing: _opsMenu(context, row, plan),
        onTap: plan.hasAny ? () => _openRowOps(row, plan) : null,
      ),
    );
  }

  /// 文件状态图标(成功=ok/失败=danger/导入中=gold/等待=warn/其它=ink3)。
  Widget _statusIcon(BuildContext context, String status) {
    final tk = context.tk;
    final (icon, fg, bg) = switch (status) {
      'success' => (Icons.check_circle_outline, tk.ok, tk.okSoft),
      'failed' => (Icons.error_outline, tk.danger, tk.dangerSoft),
      'importing' => (Icons.sync, tk.goldInk, tk.goldSoft),
      'pending' => (Icons.schedule, tk.warn, tk.warnSoft),
      'cancelled' => (Icons.block, tk.ink3, tk.surface3),
      _ => (Icons.skip_next_outlined, tk.ink3, tk.surface3),
    };
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Tk.rSm),
      ),
      child: Icon(icon, size: 18, color: fg),
    );
  }

  Widget _opsMenu(
    BuildContext context,
    BaiduTaskFile row,
    FileActionPlan plan,
  ) {
    final tk = context.tk;
    if (!plan.hasAny) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (plan.canRetry)
          TextButton(
            onPressed: row.nonRetryable ? null : () => _runAction(row, 'retry'),
            child: Text(
              row.nonRetryable ? '不可重试' : '重试',
              style: TextStyle(
                fontSize: Tk.fzSm,
                color: row.nonRetryable ? tk.ink3 : tk.goldInk,
              ),
            ),
          ),
        if (plan.canResolveConflict)
          TextButton(
            onPressed: () => _runAction(row, 'random-suffix'),
            child: const Text('随机后缀', style: TextStyle(fontSize: Tk.fzSm)),
          ),
        if (plan.canOverwrite || plan.canResolveConflict)
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.more_vert, size: 18),
            tooltip: '更多操作',
            onPressed: () => _openRowOps(row, plan),
          ),
      ],
    );
  }

  Future<void> _openRowOps(BaiduTaskFile row, FileActionPlan plan) async {
    final action = await showAppSheet<String>(
      context: context,
      title: '文件操作',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (plan.canRetry && row.nonRetryable)
            AppRow(
              leading: const Icon(Icons.refresh),
              title: '重试（不可用）',
              subtitle: kNonRetryableTip,
              showChevron: false,
            ),
          if (plan.canOverwrite || plan.canResolveConflict)
            AppRow(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: '覆盖导入',
              subtitle: confirmText(row, plan).$2,
              onTap: () => Navigator.of(context).pop('overwrite'),
            ),
          if (plan.canResolveConflict)
            AppRow(
              leading: const Icon(Icons.shuffle_outlined),
              title: '随机后缀导入',
              subtitle: kRandomSuffixTip,
              onTap: () => Navigator.of(context).pop('random-suffix'),
            ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    await _runAction(row, action);
  }
}
