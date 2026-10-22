/// BaiduNewTaskPage — 新建备份任务向导(B9 §8.10,web BaiduNewTaskModal
/// 移动版,两步):①源目录=网盘树选择器(必选,根目录不可作源);②目标=
/// 项目(仅可上传项目)+ 承接夹(项目根=自动创建,或夹树选定,敏感子树
/// 禁选)→ POST /backup/tasks。**同名默认跳过、向导无覆盖选项**(覆盖导入
/// 是任务详情逐文件后置操作且需管理权限);成功后提示排队预期 + W1 跨项目
/// 前缀重叠预警(web 文案口径),并失效任务列表刷新。
library;

import 'package:flutter/material.dart';

import '../../core/api/baidu_api.dart';
import '../../core/api/ms_api.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/pickers/picker_sheet.dart';
import '../../widgets/toast.dart';
import 'baidu_target_picker.dart';
import 'netdisk_tree_sheet.dart';
import 'new_task_source_step.dart';

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
      // 失败显式呈现错误态+重试(P2-2:勿把失败伪装成「项目暂无文件夹」空态,
      // 空态会让用户误以为目标只有项目根可选)
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
      setState(() {
        _sourceDir = path;
        _step = 1;
      });
    }
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
      await _showCreatedDialog(task);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _toast('创建任务失败:${e.message}', tone: ToastTone.error);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _toast('创建任务失败:${errorMessage(e, '网络异常,请稍后重试')}',
          tone: ToastTone.error);
    }
  }

  /// 创建成功结果卡:排队预期(恒有)+ W1 预警(命中时追加段),单「知道了」。
  Future<void> _showCreatedDialog(BaiduTask task) {
    final names = task.overlapProjectNames?.join('、');
    final w1 = task.crossProjectPrefixOverlap
        ? (names == null || names.isEmpty
            ? '目标文件夹名与其他项目下的同名文件夹共用存储编号:同名文件将自动加随机'
                '后缀存储(两处各持独立文件,互不覆盖);目标目录内已存在同名文件'
                '(含回收站)时该文件仍会失败并保留人工处理出路,如需同键替换请换'
                '一个目标文件夹名'
            : '目标文件夹名与项目「$names」下的同名文件夹共用存储编号:同名文件将'
                '自动加随机后缀存储(两处各持独立文件,互不覆盖);目标目录内已存在'
                '同名文件(含回收站)时该文件仍会失败并保留人工处理出路,如需同键替'
                '换请换一个目标文件夹名')
        : null;
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.check_circle_outline, color: Tk.green, size: 32),
        title: const Text('备份任务已创建'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '清单准备中;已有任务执行中时,新任务将排队,前序完成后约数分钟至'
              '一刻钟内自动开始。',
            ),
            if (w1 != null) ...[
              const SizedBox(height: Tk.spaceMd),
              Text(w1,
                  style: const TextStyle(
                      fontSize: Tk.fzSm, color: Tk.amber, height: 1.6)),
            ],
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// P2-3:本地 SnackBar 封装改全局 toast()(floating+tone 图标+latest
  /// wins,与全库口径一致);校验提示 info,创建失败 error。
  void _toast(String msg, {ToastTone tone = ToastTone.info}) =>
      toast(context, msg, tone: tone);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_step == 0 ? '新建备份任务 · 选源目录' : '新建备份任务 · 选目标'),
        actions: [
          if (_step == 1)
            TextButton(
              onPressed: () => setState(() => _step = 0),
              child: const Text('上一步'),
            ),
        ],
      ),
      body: Column(
        children: [
          // E12:向导步骤指示器(1 选择来源 → 2 确认创建,当前步高亮)
          _stepsHeader(),
          Expanded(child: _step == 0 ? _sourceStep() : _targetStep()),
        ],
      ),
      bottomNavigationBar: _step == 0 ? null : _bottomBar(),
    );
  }

  /// 顶部步骤指示:两段式步骤点+文案,已完成步带对勾。
  Widget _stepsHeader() {
    final labels = const ['选择来源', '确认创建'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(Tk.spaceLg, Tk.spaceMd, Tk.spaceLg, 0),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0)
              const Expanded(
                child: Divider(height: 1, color: Tk.border),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i <= _step ? Tk.accent : Tk.fill,
                  ),
                  child: Center(
                    child: i < _step
                        ? const Icon(Icons.check, size: 14, color: Tk.surface)
                        : Text('${i + 1}',
                            style: TextStyle(
                              fontSize: Tk.fzXs,
                              fontWeight: FontWeight.w600,
                              color: i <= _step ? Tk.surface : Tk.muted,
                            )),
                  ),
                ),
                const SizedBox(width: Tk.spaceSm),
                Text(
                  '${i + 1} ${labels[i]}',
                  style: TextStyle(
                    fontSize: Tk.fzMd,
                    fontWeight: i == _step ? FontWeight.w600 : FontWeight.w400,
                    color: i == _step ? Tk.fg : Tk.subtle,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _sourceStep() => NewTaskSourceStep(
        sourceDir: _sourceDir,
        onPick: _pickSource,
      );

  Widget _targetStep() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('源目录', style: Theme.of(context).textTheme.bodySmall),
          Text(_sourceDir ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: Tk.fzMd, fontWeight: FontWeight.w600)),
          const Divider(height: 24),
          if (_projectsLoading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_projectsError != null)
            Column(children: [
              Text(_projectsError!,
                  style: const TextStyle(fontSize: Tk.fzMd, color: Tk.red)),
              TextButton(onPressed: _loadProjects, child: const Text('重试')),
            ])
          else if (_projects.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                  child: Text('无可用项目(需具备项目上传权限)',
                      style: TextStyle(fontSize: Tk.fzMd, color: Tk.muted))),
            )
          else ...[
            const Text('目标项目(仅列出你可上传的项目)',
                style: TextStyle(fontSize: Tk.fzSm, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            // I2(#6):下拉改「只读字段+弹层选择器」(可搜索);仅列可上传项目
            // 的闸门不变(筛选在 _loadProjects,弹层 items 即闸门后列表)
            PickerField(
              value: _projects
                  .firstWhere((p) => p.id == _projectId,
                      orElse: () => _projects.first)
                  .name,
              hint: '选择目标项目',
              onTap: _pickTargetProject,
            ),
            const SizedBox(height: 12),
            if (_foldersLoading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_foldersError != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(children: [
                  Text(_foldersError!,
                      style: const TextStyle(fontSize: Tk.fzMd, color: Tk.red)),
                  TextButton(
                    onPressed: _projectId == null
                        ? null
                        : () => _loadFolders(_projectId!),
                    child: const Text('重试'),
                  ),
                ]),
              )
            else
              BaiduTargetPicker(
                projectId: _projectId!,
                projectName: _projects
                    .firstWhere((p) => p.id == _projectId,
                        orElse: () => _projects.first)
                    .name,
                folders: _folders,
                value: _target,
                onChanged: (t) => setState(() => _target = t),
              ),
            const SizedBox(height: 8),
            Text('已选目标:${_target.label}',
                style: const TextStyle(fontSize: Tk.fzSm, color: Tk.muted)),
          ],
        ],
      );

  Widget _bottomBar() => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              // E12:「上一步」底部也提供(AppBar 文字钮保留,双入口可达)
              OutlinedButton(
                onPressed: _submitting ? null : () => setState(() => _step = 0),
                child: const Text('上一步'),
              ),
              const SizedBox(width: Tk.spaceMd),
              Expanded(
                child: FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(_submitting ? '创建中…' : '开始备份'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
