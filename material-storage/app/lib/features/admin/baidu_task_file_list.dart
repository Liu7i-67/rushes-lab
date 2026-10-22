/// 百度任务文件明细列表(B8 功能点 7 拆件;web TaskDetailDrawer 文件区移动版):
/// 状态 chips(web FILE_TABS 七项)+ 服务端分页(滚动到底自动加载)+ 行内
/// 操作——普通失败行「重试」(non_retryable 置灰,web Tooltip 语义移到
/// 长按/菜单)、key_conflict 行「随机后缀」直发 + 菜单「覆盖导入」(确认点名
/// 占用者)。操作闸门:三端点挂用户侧 _own_task 守门,admin 仅对本人任务可
/// 操作——非本人行渲染置灰 +「仅任务归属者可操作」提示(P2-4);加载失败
/// 呈现错误态 + 重试,不冒充「无文件」(P2-2)。处置手册语义见 baidu_file_actions.dart。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/fmt.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_view.dart';
import '../../widgets/toast.dart';
import 'admin_auto_load.dart';
import 'baidu_file_actions.dart';
import 'baidu_task_labels.dart';

/// 文件明细页大小(web FILE_PAGE_SIZE 同款)。
const kFileListPageSize = 20;

/// 非本人任务的操作提示(操作端点 _own_task 守门,admin 观测不越权)。
const kOwnerOnlyOpsHint = '仅任务归属者可操作';

class BaiduTaskFileList extends StatefulWidget {
  const BaiduTaskFileList({
    super.key,
    required this.task,
    required this.onChanged,
  });

  final AdminBaiduTask task;

  /// 行操作成功(任务将复活入队)后回调:父级刷新详情并关闭。
  final VoidCallback onChanged;

  @override
  State<BaiduTaskFileList> createState() => _BaiduTaskFileListState();
}

class _BaiduTaskFileListState extends State<BaiduTaskFileList>
    with AutoLoadScroll<BaiduTaskFileList> {
  String _fileStatus = '';
  var _files = <AdminBaiduTaskFile>[];
  var _fileTotal = 0;
  var _filesLoading = true;
  var _loadingMore = false;
  String? _filesError;
  var _reloadTag = 0;

  @override
  void initState() {
    super.initState(); // AutoLoadScroll:挂滚动监听
    _loadFiles();
  }

  @override
  void onAutoLoad() => _loadMoreFiles();

  Future<void> _loadFiles() async {
    final tag = ++_reloadTag;
    setState(() {
      _filesLoading = _files.isEmpty;
      _filesError = null;
    });
    try {
      final page = await session.api!.adminBaidu.taskFiles(
        widget.task.id,
        status: _fileStatus.isEmpty ? null : _fileStatus,
        limit: kFileListPageSize,
        offset: 0,
      );
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _files = page.items;
        _fileTotal = page.total;
        _filesLoading = false;
      });
    } catch (e) {
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _filesLoading = false;
        // 失败显式呈现错误态(P2-2:不得回落为「无文件」),留手动重试入口
        _filesError = errorMessage(e, '加载失败,请稍后重试');
      });
    }
  }

  /// 到底自动加载(F6):加载中/已取全守卫;失败 toast,滚动可再次触发。
  Future<void> _loadMoreFiles() async {
    if (_loadingMore || _filesLoading || _files.length >= _fileTotal) return;
    setState(() => _loadingMore = true);
    final tag = _reloadTag;
    try {
      final page = await session.api!.adminBaidu.taskFiles(
        widget.task.id,
        status: _fileStatus.isEmpty ? null : _fileStatus,
        limit: kFileListPageSize,
        offset: _files.length,
      );
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _files.addAll(page.items);
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      toast(context, errorMessage(e, '加载失败,请稍后重试'),
          tone: ToastTone.error);
    }
  }

  Future<void> _runAction(AdminBaiduTaskFile row, String action) async {
    if (!fileOpsAllowed(widget.task, session.me?.id)) return;
    final ok = await runFileAction(
      context,
      taskId: widget.task.id,
      taskStatus: widget.task.status,
      row: row,
      action: action,
    );
    if (ok && mounted) widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final isOwner = fileOpsAllowed(widget.task, session.me?.id);
    return Column(
      children: [
        // 文件状态 chips(web FILE_TABS 同款七项)
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Tk.spaceMd),
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
                  padding: const EdgeInsets.only(right: Tk.spaceSm),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: _fileStatus == key,
                    onSelected: (_) {
                      setState(() => _fileStatus = key);
                      _loadFiles();
                    },
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tk.spaceLg),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
                '文件明细 共 $_fileTotal 条'
                '${isOwner ? '' : ' · $kOwnerOnlyOpsHint'}',
                style: TextStyle(
                    fontSize: Tk.fzXs, color: isOwner ? Tk.subtle : Tk.amber)),
          ),
        ),
        Expanded(child: _list(isOwner)),
      ],
    );
  }

  Widget _list(bool isOwner) {
    final task = widget.task;
    if (_filesLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    // 加载失败显式呈现错误态 + 重试(P2-2:不冒充「无文件」)
    if (_filesError != null) {
      return ErrorView(message: _filesError!, onRetry: _loadFiles);
    }
    if (_files.isEmpty) {
      return const Center(
          child:
              Text('无文件', style: TextStyle(color: Tk.muted, fontSize: Tk.fzSm)));
    }
    return ListView.builder(
      controller: scrollController,
      itemCount: _files.length + (_files.length < _fileTotal ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _files.length) {
          // F6:底部自动加载指示器(到底自动触发;失败后可点重试)
          return AutoLoadFooter(loading: _loadingMore, onTap: _loadMoreFiles);
        }
        final row = _files[i];
        final plan = fileActionPlan(task, row);
        return ListTile(
          visualDensity: VisualDensity.compact,
          dense: true,
          title: Text(row.relPath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: Tk.fzMd)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${fileStatusText(row.status)} · ${fmtBytes(row.bytesDone)} · '
                '尝试 ${row.attempts} 次',
                style: const TextStyle(fontSize: Tk.fzXs),
              ),
              if (row.status == 'failed' &&
                  row.lastError != null &&
                  row.lastError!.isNotEmpty)
                Text(row.lastError!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: Tk.fzXs, color: Tk.red)),
            ],
          ),
          trailing: _opsMenu(task, row, plan, isOwner),
          onTap: plan.hasAny && isOwner
              ? () => _openRowOps(task, row, plan)
              : null,
        );
      },
    );
  }

  Widget _opsMenu(AdminBaiduTask task, AdminBaiduTaskFile row,
      FileActionPlan plan, bool isOwner) {
    if (!plan.hasAny) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      // 普通失败行:重试(non_retryable 置灰 = disabled,结构性失败不可自愈);
      // 他人任务全部操作一并置灰(P2-4:_own_task 守门必 404,前端先收敛,
      // 原因见表头 amber「仅任务归属者可操作」)。F2:文字钮加高至 44 触控,
      // shrinkWrap 收边距保持视觉紧凑
      if (plan.canRetry)
        TextButton(
          style: _kRowTextButtonStyle,
          onPressed: isOwner && !row.nonRetryable
              ? () => _runAction(row, 'retry')
              : null,
          child: Text(row.nonRetryable ? '不可重试' : '重试',
              style: TextStyle(
                  fontSize: Tk.fzSm,
                  color: isOwner && !row.nonRetryable ? Tk.accent : Tk.subtle)),
        ),
      // key_conflict 行:随机后缀直发(web 同款;换 key 非破坏性)
      if (plan.canResolveConflict)
        TextButton(
          style: _kRowTextButtonStyle,
          onPressed: isOwner ? () => _runAction(row, 'random-suffix') : null,
          child: Text('随机后缀',
              style: TextStyle(
                  fontSize: Tk.fzSm, color: isOwner ? null : Tk.subtle)),
        ),
      if (plan.canOverwrite || plan.canResolveConflict)
        // F2:更多操作钮回标准 24 图标(原 18 过小,触控不达标)
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.more_vert),
          tooltip: isOwner ? '更多操作' : kOwnerOnlyOpsHint,
          onPressed: isOwner ? () => _openRowOps(task, row, plan) : null,
        ),
    ]);
  }

  Future<void> _openRowOps(
      AdminBaiduTask task, AdminBaiduTaskFile row, FileActionPlan plan) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (plan.canRetry && row.nonRetryable)
            ListTile(
              enabled: false,
              leading: const Icon(Icons.refresh),
              title: const Text('重试(不可用)'),
              subtitle: const Text(kNonRetryableTip),
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

/// 密排行内文字钮通用样式(F2):44×44 触控下限 + shrinkWrap 收默认外边距,
/// 视觉紧凑、触控达标。
final ButtonStyle _kRowTextButtonStyle = TextButton.styleFrom(
  minimumSize: const Size(44, 44),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.compact,
  padding: const EdgeInsets.symmetric(horizontal: Tk.spaceSm),
);
