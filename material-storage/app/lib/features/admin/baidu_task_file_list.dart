/// 百度任务文件明细列表(B8 功能点 7 拆件;web TaskDetailDrawer 文件区移动版):
/// 状态 chip 轨(web FILE_TABS 七项)+ 服务端分页(滚动到底自动加载)+
/// 文件级操作(行渲染与菜单拆见 baidu_task_file_rows.dart)。操作闸门:
/// 三端点挂用户侧 _own_task 守门,admin 仅对本人任务可操作——非本人行置灰 +
/// 「仅任务归属者可操作」提示(P2-4);加载失败呈现错误态 + 重试,不冒充
/// 「无文件」(P2-2)。处置手册语义见 baidu_file_actions.dart。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/error_view.dart';
import '../../widgets/toast.dart';
import 'admin_auto_load.dart';
import 'baidu_file_actions.dart';
import 'baidu_task_file_rows.dart';

export 'baidu_task_file_rows.dart' show BaiduTaskFileRow, kOwnerOnlyOpsHint;

/// 文件明细页大小(web FILE_PAGE_SIZE 同款)。
const kFileListPageSize = 20;

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
      toast(context, errorMessage(e, '加载失败,请稍后重试'), tone: ToastTone.error);
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
    final tk = context.tk;
    final isOwner = fileOpsAllowed(widget.task, session.me?.id);
    return Column(
      children: [
        // 文件状态 chip 轨(web FILE_TABS 同款七项;墨金 chip 由 AppChip 承载)
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(
              Tk.spacePage,
              Tk.spaceSm,
              Tk.spacePage,
              0,
            ),
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
                  child: AppChip(
                    label: label,
                    selected: _fileStatus == key,
                    onTap: () {
                      setState(() => _fileStatus = key);
                      _loadFiles();
                    },
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tk.spacePage),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '文件明细 共 $_fileTotal 条'
              '${isOwner ? '' : ' · $kOwnerOnlyOpsHint'}',
              style: TextStyle(
                fontSize: Tk.fzMd,
                color: isOwner ? tk.ink3 : tk.warn,
              ),
            ),
          ),
        ),
        Expanded(child: _list(isOwner)),
      ],
    );
  }

  Widget _list(bool isOwner) {
    final tk = context.tk;
    if (_filesLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    // 加载失败显式呈现错误态 + 重试(P2-2:不冒充「无文件」)
    if (_filesError != null) {
      return ErrorView(message: _filesError!, onRetry: _loadFiles);
    }
    if (_files.isEmpty) {
      return Center(
        child: Text(
          '无文件',
          style: TextStyle(color: tk.ink3, fontSize: Tk.fzMd),
        ),
      );
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
        return BaiduTaskFileRow(
          task: widget.task,
          file: row,
          plan: fileActionPlan(widget.task, row),
          isOwner: isOwner,
          onAction: (action) => _runAction(row, action),
        );
      },
    );
  }
}
