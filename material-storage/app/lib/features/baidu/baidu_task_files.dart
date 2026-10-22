/// 百度任务文件明细(用户侧;B9 §8.10,B8 baidu_task_file_list 同款交互):
/// 状态 chips(七项)+ 服务端分页(加载更多)+ 行内操作——普通失败行「重试」
/// (non_retryable 置灰)、key_conflict 行「随机后缀」直发 + 菜单「覆盖导入」
/// (确认点名占用者),复用 B8 baidu_file_actions 判定/文案/执行链(invoke 注入
/// 用户侧 BaiduApi——本人任务,fileOpsAllowed 闸门天然满足,不设归属者置灰)。
library;

import 'package:flutter/material.dart';

import '../../core/api/baidu_api.dart';
import '../../core/api/ms_api.dart';
import '../../core/fmt.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_view.dart';
import '../admin/baidu_file_actions.dart';
import '../admin/baidu_task_labels.dart';

/// 文件明细页大小(web FILE_PAGE_SIZE 同款)。
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

  /// 任务当前状态(行操作判定入参;任务复活后由详情页刷新携带)。
  final String taskStatus;

  /// 测试注入;缺省取现役 session 客户端。
  final BaiduApi? api;

  /// 行操作成功(任务复活入队)后回调:详情页刷新任务概要。
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
          // 加载更多:按 id 去重追加(翻页间隙状态变化防重)
          final known = _files.map((f) => f.id).toSet();
          _files.addAll(page.items.where((f) => !known.contains(f.id)));
        }
        _total = page.total;
        _loading = false;
      });
    } catch (e) {
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _loading = false;
        // 失败显式呈现错误态(B8 P2-2 口径:不冒充「无文件」),留手动重试;
        // errorMessage 统一兜底——detail 透传 + 传输层异常中文文案(勿 '$e')
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
      // 用户侧直调本人任务端点(与 adminBaidu 同路径,域归属清晰)
      invoke: (a) => _api.fileOp(widget.taskId, row.id, a),
    );
    if (ok && mounted) {
      // 行操作成功=任务复活入队:刷新明细,并通知详情页刷新任务头
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
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final (key, label) in const [
                ('', '全部'),
                ('pending', '等待'),
                ('importing', '导入中'),
                ('success', '成功'),
                ('skipped_exists', '跳过'),
                ('failed', '失败'),
                ('cancelled', '已取消'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: _status == key,
                    onSelected: (_) {
                      setState(() => _status = key);
                      _load(reset: true);
                    },
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('文件明细 共 $_total 条',
                style: const TextStyle(fontSize: Tk.fzXs, color: Tk.subtle)),
          ),
        ),
        Expanded(child: _list()),
      ],
    );
  }

  Widget _list() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: () => _load(reset: true));
    }
    if (_files.isEmpty) {
      return const Center(
          child: Text('无文件', style: TextStyle(color: Tk.muted, fontSize: Tk.fzSm)));
    }
    final hasMore = _files.length < _total;
    return ListView.builder(
      itemCount: _files.length + (hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _files.length) {
          return Padding(
            padding: const EdgeInsets.all(8),
            child: OutlinedButton(
                onPressed: _loadingMore ? null : _loadMore,
                child: Text(_loadingMore ? '加载中…' : '加载更多')),
          );
        }
        final row = _files[i];
        final plan = fileRowActionPlan(widget.taskStatus, row);
        return ListTile(
          visualDensity: VisualDensity.compact,
          dense: true,
          title: Text(row.relPath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: Tk.fzSm)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${fileStatusText(row.status)} · ${fmtBytes(row.sourceSize)} · '
                '→ ${row.targetDisplay}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: Tk.fzXs,
                    color: row.targetPath == null ? Tk.amber : Tk.muted),
              ),
              if (row.status == 'failed' &&
                  row.lastError != null &&
                  row.lastError!.isNotEmpty)
                Text(row.lastError!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: Tk.fzXs, color: Tk.red)),
            ],
          ),
          trailing: _opsMenu(row, plan),
          onTap: plan.hasAny ? () => _openRowOps(row, plan) : null,
        );
      },
    );
  }

  Widget _opsMenu(BaiduTaskFile row, FileActionPlan plan) {
    if (!plan.hasAny) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      // 普通失败行:重试(non_retryable 置灰 = disabled,结构性失败不可自愈)
      if (plan.canRetry)
        TextButton(
          onPressed:
              row.nonRetryable ? null : () => _runAction(row, 'retry'),
          child: Text(row.nonRetryable ? '不可重试' : '重试',
              style: TextStyle(
                  fontSize: Tk.fzSm,
                  color: row.nonRetryable ? Tk.subtle : Tk.accent)),
        ),
      // key_conflict 行:随机后缀直发(web 同款;换 key 非破坏性)
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
    ]);
  }

  Future<void> _openRowOps(BaiduTaskFile row, FileActionPlan plan) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (plan.canRetry && row.nonRetryable)
            const ListTile(
              enabled: false,
              leading: Icon(Icons.refresh),
              title: Text('重试(不可用)'),
              subtitle: Text(kNonRetryableTip),
            ),
          if (plan.canOverwrite || plan.canResolveConflict)
            ListTile(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('覆盖导入'),
              subtitle: Text(confirmText(row, plan).$2,
                  maxLines: 3, overflow: TextOverflow.ellipsis),
              iconColor: Tk.red,
              onTap: () => Navigator.of(context).pop('overwrite'),
            ),
          if (plan.canResolveConflict)
            ListTile(
              leading: const Icon(Icons.shuffle_outlined),
              title: const Text('随机后缀导入'),
              subtitle: const Text(kRandomSuffixTip),
              onTap: () => Navigator.of(context).pop('random-suffix'),
            ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    await _runAction(row, action);
  }
}
