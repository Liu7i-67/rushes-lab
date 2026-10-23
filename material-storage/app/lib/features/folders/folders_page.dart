/// 项目内文件夹页(F7):二级页头(项目名 + code/角色副标题 + ⋯/新建一级)
/// + 项目头卡(列表求和计数)+「目录」行卡树。flat 列表自组树、按缩进展示、
/// 支持多级下钻;行=图标/直属计数徽标/敏感锁/「⋯」菜单;点夹进宫格。
/// 新建一级闸门=my_roles admin/uploader(敏感开关仅项目一级有义)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/list_skeleton.dart';
import '../../widgets/page_header.dart';
import '../../widgets/role_chips.dart';
import '../../widgets/section_label.dart';
import 'folder_form_sheet.dart';
import 'folder_row.dart';
import 'folder_tree.dart';
import 'project_head.dart';

class FoldersPage extends StatefulWidget {
  const FoldersPage({
    super.key,
    required this.projectId,
    this.projectName = '',
    this.projectCode = '',
    this.myRoles = const [],
  });

  final String projectId;

  /// 项目显示名(宫格/上传任务路径前缀,二级页标题)。
  final String projectName;

  /// 项目 code(路由暂未携带;为空时头卡 code 微标签与顶栏 code 段隐藏)。
  final String projectCode;

  /// 当前用户在本项目的角色(新建一级文件夹闸门:admin/uploader)。
  final List<String> myRoles;

  @override
  State<FoldersPage> createState() => _FoldersPageState();
}

class _FoldersPageState extends State<FoldersPage> {
  var _all = const <Folder>[];
  var _loading = true; // 仅首轮整页骨架;刷新在旧数据上原地等
  String? _error;
  final _collapsed = <String>{};
  var _code = '';

  bool get _canCreate =>
      widget.myRoles.contains('admin') || widget.myRoles.contains('uploader');

  String get _roleLabel =>
      widget.myRoles.isEmpty ? '仅访客' : joinedRoleLabels(widget.myRoles);

  String get _title => widget.projectName.isEmpty ? '文件夹' : widget.projectName;

  @override
  void initState() {
    super.initState();
    _code = widget.projectCode;
    // 数据新鲜度:上传等写操作成功后失效 'folders',本页自动重拉子树计数
    RefreshBus.I.addListener('folders', _reload);
    _reload();
    _loadCode();
  }

  @override
  void dispose() {
    RefreshBus.I.removeListener('folders', _reload);
    super.dispose();
  }

  /// 拉取并落态(失效总线/下拉刷新/返回重拉同路);返回真 future。
  Future<void> _reload() async {
    try {
      final folders = await session.api!.folders.list(widget.projectId);
      if (!mounted) return;
      setState(() {
        _all = folders;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorMessage(e, '文件夹加载失败');
        _loading = false;
      });
    }
  }

  /// 路由暂未携带项目 code:用现有项目列表接口兜底解析(不新增后端);
  /// 失败静默,头卡隐藏 code 段。
  Future<void> _loadCode() async {
    if (_code.isNotEmpty) return;
    try {
      final projects = await session.api!.projects.list();
      final i = projects.indexWhere((p) => p.id == widget.projectId);
      if (i >= 0 && mounted && projects[i].code.isNotEmpty) {
        setState(() => _code = projects[i].code);
      }
    } catch (_) {
      // 静默:code 非关键数据
    }
  }

  /// 深度优先铺平可见行(折叠的子树跳过);roots 顺序保持后端返回序。
  List<(FolderNode, int)> _visibleRows(List<FolderNode> roots) {
    final rows = <(FolderNode, int)>[];
    void walk(List<FolderNode> nodes, int depth) {
      for (final n in nodes) {
        rows.add((n, depth));
        if (n.children.isNotEmpty && !_collapsed.contains(n.folder.id)) {
          walk(n.children, depth + 1);
        }
      }
    }

    walk(roots, 0);
    return rows;
  }

  /// 显示路径(项目/…/本夹):父链自 flat 列表回溯;环防御=已访问 id 集合。
  String _whereOf(Folder f) {
    final byId = {for (final x in _all) x.id: x};
    final names = <String>[f.name];
    final seen = <String>{f.id};
    var cur = f.parentFolderId;
    while (cur != null && seen.add(cur)) {
      final p = byId[cur];
      if (p == null) break;
      names.insert(0, p.name);
      cur = p.parentFolderId;
    }
    return [
      if (widget.projectName.isNotEmpty) widget.projectName,
      ...names,
    ].join('/');
  }

  void _open(Folder f) {
    Navigator.of(context)
        .pushNamed('/assets', arguments: (f.id, f.name, _whereOf(f)))
        .then((_) => _reload());
  }

  void _createRoot() {
    showFolderFormSheet(
      context,
      mode: FolderFormMode.createRoot,
      projectId: widget.projectId,
      parentLabel: widget.projectName,
    );
  }

  void _openProjectMenu() {
    showProjectMenu(
      context,
      project: Project(id: widget.projectId, name: _title, code: _code),
      canAdmin: widget.myRoles.contains('admin'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _code.isEmpty ? _roleLabel : '$_code · $_roleLabel';
    return Scaffold(
      body: Column(
        children: [
          PageHeader(
            back: true,
            title: _title,
            subtitle: subtitle,
            actions: [
              IconButton(
                tooltip: '项目操作',
                icon: const Icon(Icons.more_horiz),
                onPressed: _openProjectMenu,
              ),
              if (_canCreate)
                IconButton(
                  tooltip: '新建一级文件夹',
                  icon: const Icon(Icons.create_new_folder_outlined),
                  onPressed: _createRoot,
                ),
            ],
          ),
          Expanded(
            child: RefreshIndicator(onRefresh: _reload, child: _body()),
          ),
        ],
      ),
    );
  }

  /// loading/error/空态全高可滚动包装,使 RefreshIndicator 任意状态可下拉。
  Widget _scrollable(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: constraints.maxHeight,
            child: Center(child: child),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return _scrollable(const ListSkeleton(rows: 5));
    if (_error != null) {
      return _scrollable(ErrorView(message: _error!, onRetry: _reload));
    }
    return _buildTree();
  }

  Widget _buildTree() {
    final roots = buildFolderTree(_all);
    if (roots.isEmpty) return _emptyView();
    final rows = _visibleRows(roots);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: Tk.spaceXl),
      children: [
        _head(),
        const SectionLabel(title: '目录', hint: '按更新时间'),
        SectionCard(
          margin: const EdgeInsets.symmetric(horizontal: Tk.spacePage),
          children: [
            for (final (node, depth) in rows)
              FolderRow(
                node: node,
                depth: depth,
                expanded: !_collapsed.contains(node.folder.id),
                onToggle: () => setState(() {
                  _collapsed.contains(node.folder.id)
                      ? _collapsed.remove(node.folder.id)
                      : _collapsed.add(node.folder.id);
                }),
                onOpen: () => _open(node.folder),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Text(
            '敏感文件夹仅系统管理员与授权成员可见。',
            style: TextStyle(fontSize: Tk.fzMd, color: context.tk.ink3),
          ),
        ),
      ],
    );
  }

  Widget _head() {
    return ProjectHead(
      code: _code,
      name: widget.projectName.isEmpty ? '未命名项目' : widget.projectName,
      folderCount: _all.length,
      assetCount: _all.fold(0, (sum, f) => sum + f.directFileCount),
      roleLabel: _roleLabel,
    );
  }

  Widget _emptyView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final rest = constraints.maxHeight - 300;
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            _head(),
            const SectionLabel(title: '目录', hint: '按更新时间'),
            SizedBox(
              height: rest > 280 ? rest : 280,
              child: EmptyState(
                icon: Icons.folder_outlined,
                message: '暂无文件夹',
                description: _canCreate ? '创建第一个文件夹,开始整理素材。' : '请联系项目管理员创建文件夹。',
                actionLabel: _canCreate ? '新建一级文件夹' : null,
                onAction: _canCreate ? _createRoot : null,
              ),
            ),
          ],
        );
      },
    );
  }
}
