/// BaiduNewTaskPage — 新建备份任务向导(B9 §8.10,web BaiduNewTaskModal
/// 移动版,两步):①源目录=网盘树选择器(必选,根目录不可作源);②目标=
/// 项目(仅可上传项目)+ 承接夹(项目根=自动创建,或夹树选定,敏感子树
/// 禁选)→ POST /backup/tasks。**同名默认跳过、向导无覆盖选项**(覆盖导入
/// 是任务详情逐文件后置操作且需管理权限);成功后提示排队预期 + W1 跨项目
/// 前缀重叠预警(web 文案口径),并失效任务列表刷新。
/// 本文件保留状态/导航/提交,两步视图见 new_task_source_step /
/// new_task_step_views。
library;

import 'package:flutter/material.dart';

import '../../core/api/baidu_api.dart';
import '../../core/api/ms_api.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/page_header.dart';
import '../../widgets/pickers/picker_sheet.dart';
import '../../widgets/toast.dart';
import 'baidu_target_picker.dart';
import 'netdisk_tree_sheet.dart';
import 'new_task_source_step.dart';
import 'new_task_step_views.dart';

class BaiduNewTaskPage extends StatefulWidget {
  const BaiduNewTaskPage({super.key, this.api});

  /// 测试注入;缺省取现役 session 客户端。
  final BaiduApi? api;

  @override
  State<BaiduNewTaskPage> createState() => _BaiduNewTaskPageState();
}

class _BaiduNewTaskPageState extends State<BaiduNewTaskPage> {
  BaiduApi get _api => widget.api ?? session.api!.baidu;

  var _step = 0; // 0=选源目录;1=选目标
  String? _sourceDir;
  final _nameCtrl = TextEditingController();

  List<Project> _projects = const [];
  var _projectsLoading = true;
  String? _projectsError;
  String? _projectId;
  List<Folder> _folders = const [];
  var _foldersLoading = false;
  String? _foldersError;
  var _target = const BaiduTarget.root();
  var _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProjects() async {
    setState(() {
      _projectsLoading = true;
      _projectsError = null;
    });
    try {
      final all = await session.api!.projects.list();
      if (!mounted) return;
      final creatable = [
        for (final p in all)
          if (projectAcceptsTask(p, session.me)) p,
      ];
      setState(() {
        _projects = creatable;
        _projectsLoading = false;
        if (_projectId == null && creatable.isNotEmpty) {
          _projectId = creatable.first.id;
          _loadFolders(creatable.first.id);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _projectsError = errorMessage(e, '项目列表加载失败');
        _projectsLoading = false;
      });
    }
  }

  Future<void> _loadFolders(String projectId) async {
    setState(() {
      _foldersLoading = true;
      _foldersError = null;
    });
    try {
      final fs = await session.api!.folders.list(projectId);
      if (!mounted) return;
      setState(() {
        _folders = fs;
        _foldersLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // 失败显式呈现错误态+重试(P2-2:勿把失败伪装成「项目暂无文件夹」空态)
      setState(() {
        _folders = const [];
        _foldersLoading = false;
        _foldersError = errorMessage(e, '文件夹列表加载失败');
      });
    }
  }

  Future<void> _pickSource() async {
    final path = await showNetdiskTreePicker(context);
    if (path != null && path != '/' && mounted) {
      if (_nameCtrl.text.trim().isEmpty) {
        _nameCtrl.text = _defaultTaskName(path);
      }
      setState(() {
        _sourceDir = path;
        _step = 1;
      });
    }
  }

  String _defaultTaskName(String path) {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? '网盘备份' : parts.last;
  }

  /// 目标项目弹层选择(I2:替代下拉,可搜索);重选同一项目不重置,切换项目
  /// 则承接夹目标重置为项目根并按新项目重载文件夹(原 onChanged 语义不变)。
  Future<void> _pickTargetProject() async {
    Project? current;
    for (final p in _projects) {
      if (p.id == _projectId) current = p;
    }
    final picked = await showPickerSheet<Project>(
      context: context,
      title: '目标项目',
      items: _projects,
      initial: current,
      labelOf: (p) => p.name,
      searchTextHint: '搜索项目…',
    );
    if (picked == null || !mounted || picked.id == _projectId) return;
    setState(() {
      _projectId = picked.id;
      _target = const BaiduTarget.root();
      _folders = const [];
    });
    _loadFolders(picked.id);
  }

  Project? get _currentProject {
    for (final p in _projects) {
      if (p.id == _projectId) return p;
    }
    return null;
  }

  Future<void> _submit() async {
    final source = _sourceDir;
    final projectId = _projectId;
    if (source == null || source == '/') {
      _toast('请先选择一个网盘目录(不支持整盘根目录)');
      return;
    }
    if (projectId == null) {
      _toast('请选择目标项目');
      return;
    }
    setState(() => _submitting = true);
    try {
      final task = await _api.createTask(
        sourceDir: source,
        projectId: projectId,
        targetFolderId: _target.isRoot ? null : _target.folder!.id,
      );
      RefreshBus.I.invalidate('baidu-tasks');
      if (!mounted) return;
      setState(() => _submitting = false);
      // E12:排队预期 + W1 跨项目前缀重叠预警统一为「结果卡」弹层(info 单钮,
      // 可从容读完;替代原 100+ 字 SnackBar 文字墙)。W1 文案保持 web 逐字口径。
      await showTaskCreatedDialog(context, task);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _toast('创建任务失败:${e.message}', tone: ToastTone.error);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _toast('创建任务失败:${errorMessage(e, '网络异常,请稍后重试')}', tone: ToastTone.error);
    }
  }

  /// P2-3:本地 SnackBar 封装改全局 toast()(floating+tone 图标+latest
  /// wins,与全库口径一致);校验提示 info,创建失败 error。
  void _toast(String msg, {ToastTone tone = ToastTone.info}) =>
      toast(context, msg, tone: tone);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          PageHeader(
            back: true,
            title: '新建备份任务',
            subtitle: '步骤 ${_step + 1} / 2',
          ),
          Expanded(
            child: _step == 0
                ? NewTaskSourceStep(sourceDir: _sourceDir, onPick: _pickSource)
                : NewTaskTargetStep(
                    sourceDir: _sourceDir,
                    nameController: _nameCtrl,
                    projectsLoading: _projectsLoading,
                    projectsError: _projectsError,
                    projects: _projects,
                    projectId: _projectId,
                    projectName: _currentProject?.name,
                    folders: _folders,
                    foldersLoading: _foldersLoading,
                    foldersError: _foldersError,
                    target: _target,
                    onReloadProjects: _loadProjects,
                    onReloadFolders: () {
                      final id = _projectId;
                      if (id != null) _loadFolders(id);
                    },
                    onPickProject: _pickTargetProject,
                    onTargetChanged: (t) => setState(() => _target = t),
                  ),
          ),
        ],
      ),
      bottomNavigationBar: _bottomBar(context),
    );
  }

  Widget _bottomBar(BuildContext context) {
    final tk = context.tk;
    return Container(
      decoration: BoxDecoration(
        color: tk.bg,
        border: Border(top: BorderSide(color: tk.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Tk.spacePage,
            Tk.spaceSm,
            Tk.spacePage,
            Tk.spaceMd,
          ),
          child: Row(
            children: [
              if (_step == 1) ...[
                TextButton(
                  onPressed: _submitting
                      ? null
                      : () => setState(() => _step = 0),
                  child: const Text('上一步'),
                ),
                const SizedBox(width: Tk.spaceSm),
              ],
              Expanded(
                child: _step == 0
                    ? FilledButton(
                        onPressed: _sourceDir == null
                            ? null
                            : () => setState(() => _step = 1),
                        child: const Text('下一步'),
                      )
                    : FilledButton(
                        onPressed: _submitting ? null : _submit,
                        child: Text(_submitting ? '创建中…' : '开始备份'),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
