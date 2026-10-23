/// 项目页(B2 §8.1;墨金重做 WP2 §6 F6):PageHeader 大标题 + 通知铃 +
/// 新建项目(creator 闸门),标题下独立 46 高搜索行(即时过滤名称/code);
/// 列表换成 ProjectCard(金底首字标记/角色徽标/chevron),整卡进文件夹,
/// 长按保留「成员管理/请求链接」管理菜单;loading/error/empty 用共享组件,
/// 下拉刷新覆盖全部状态。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/haptics.dart';
import '../../core/polling_controller.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_row.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/list_skeleton.dart';
import '../../widgets/page_header.dart';
import '../../widgets/search_field.dart';
import '../../widgets/sheet_scaffold.dart';
import '../share/request_link_sheet.dart';
import 'new_project_sheet.dart';
import 'project_card.dart';
import 'project_members_sheet.dart';

/// 项目页标题:P6 定稿恒为「项目」,不带 stamp 与用户名。
String projectsTitle() => '项目';

class ProjectsPage extends StatefulWidget {
  const ProjectsPage({super.key});

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  var _items = const <Project>[];
  var _loading = true; // 仅首轮整页骨架;刷新在旧数据上原地等
  String? _error;

  /// 搜索过滤词(名称/code 不区分大小写包含;空=全量)。
  var _query = '';

  List<Project> get _filteredProjects {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _items;
    return _items
        .where(
          (p) =>
              p.name.toLowerCase().contains(q) ||
              p.code.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  void initState() {
    super.initState();
    // 数据新鲜度:IndexedStack 常驻页挂失效总线,写操作后自动重拉
    RefreshBus.I.addListener('projects', _reload);
    _reload();
  }

  @override
  void dispose() {
    RefreshBus.I.removeListener('projects', _reload);
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final items = await session.api!.projects.list();
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorMessage(e, '项目列表加载失败');
        _loading = false;
      });
    }
  }

  /// 长按管理菜单(admin 闸门不变):管理 shell 换成 SheetScaffold + AppRow。
  Future<void> _showRowMenu(Project p) async {
    Haptics.light();
    final canAdmin = p.myRoles.contains('admin');
    if (!canAdmin || !mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SheetScaffold(
        title: '${p.name} · 管理',
        showClose: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppRow(
              leading: const Icon(Icons.people_outline),
              title: '成员管理',
              onTap: () => Navigator.of(sheetCtx).pop('members'),
            ),
            AppRow(
              leading: const Icon(Icons.link_outlined),
              title: '请求链接',
              onTap: () => Navigator.of(sheetCtx).pop('link'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'members':
        await showProjectMembersSheet(context, project: p);
      case 'link':
        await showRequestLinkSheet(
          context,
          targetType: 'project',
          targetId: p.id,
          targetLabel: p.name,
        );
    }
  }

  /// 非列表内容包成全高可滚动,使 RefreshIndicator 在这些状态也能下拉。
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

  Widget _emptyWithCta() {
    final canCreate = session.me?.isProjectCreator ?? false;
    return _scrollable(
      EmptyState(
        icon: Icons.folder_copy_outlined,
        title: '暂无可见项目',
        message: canCreate ? '新建项目后在这里管理文件夹与素材' : '当前账号暂无可见项目',
        actionLabel: canCreate ? '新建项目' : null,
        onAction: canCreate ? () => showNewProjectSheet(context) : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredProjects;
    final total = _items.length;
    return Scaffold(
      body: Column(
        children: [
          PageHeader(
            title: projectsTitle(),
            count: _loading ? null : '$total',
            subtitle: total == 0 ? null : '共 $total 个项目',
            actions: [
              const _NotificationsBell(),
              if (session.me?.isProjectCreator ?? false)
                IconButton(
                  tooltip: '新建项目',
                  icon: const Icon(Icons.create_new_folder_outlined),
                  onPressed: () => showNewProjectSheet(context),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tk.spacePage,
              Tk.spaceMd,
              Tk.spacePage,
              Tk.spaceSm,
            ),
            child: SearchField(
              hintText: '搜索项目名称 / 代号',
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: _loading
                  ? _scrollable(const ListSkeleton(rows: 5))
                  : _error != null
                  ? _scrollable(ErrorView(message: _error!, onRetry: _reload))
                  : _items.isEmpty
                  ? _emptyWithCta()
                  : filtered.isEmpty
                  ? _scrollable(
                      const EmptyState(
                        icon: Icons.search_off,
                        message: '无匹配项目',
                      ),
                    )
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(
                        Tk.spacePage,
                        Tk.spaceXs,
                        Tk.spacePage,
                        Tk.spaceXl,
                      ),
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: Tk.spaceMd),
                      itemBuilder: (context, i) {
                        final p = filtered[i];
                        return ProjectCard(
                          key: ValueKey('project_${p.id}'),
                          project: p,
                          onTap: () => Navigator.of(context)
                              // 附带项目名(上传任务路径)与 my_roles(文件夹闸门)
                              .pushNamed(
                                '/folders',
                                arguments: (p.id, p.name, p.myRoles),
                              ),
                          onLongPress: () => _showRowMenu(p),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 通知铃:未读 >0 挂 8px 金点,点击进通知页。
class _NotificationsBell extends StatelessWidget {
  const _NotificationsBell();

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return AnimatedBuilder(
      animation: unreadPoller,
      builder: (context, _) {
        final unread = unreadPoller.unreadCount;
        return IconButton(
          tooltip: '通知',
          onPressed: () => Navigator.of(context).pushNamed('/notifications'),
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(Icons.notifications_outlined),
              if (unread > 0)
                Positioned(
                  right: -1,
                  top: -1,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: tk.gold,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
