/// 项目页(B2 §8.1;app-polish E3 精修):列表 + 权限徽标 + 下拉刷新。
/// E3:trailing 收敛=角色徽标+chevron;「成员管理/请求链接」管理动作移入
/// 长按菜单(Haptics.light 进菜单);图标 create_new_folder;首载骨架屏;
/// 空态有 project_creator 权限时给「新建项目」引导钮;错误走 errorMessage。
/// R3(mobile-ux-polish-2):RefreshIndicator 包住 loading/error/empty/列表
/// 全部分支,非列表分支经全高可滚动包装(AlwaysScrollableScrollPhysics)。
/// J2(app-polish-2,用户反馈 #7):AppBar 下常驻紧凑 SearchField,前端即时
/// 过滤已加载列表(名称/code 不区分大小写包含,不新增 API);清空恢复全量;
/// 过滤无命中显示「无匹配项目」轻空态(保留可下拉刷新)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/haptics.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/list_skeleton.dart';
import '../../widgets/search_field.dart';
import '../share/request_link_sheet.dart';
import 'new_project_sheet.dart';
import 'project_members_sheet.dart';
import 'role_badge.dart';

/// 项目页 AppBar 标题:P6 定稿恒为「项目」,不带 stamp 与用户名。
String projectsTitle() => '项目';

class ProjectsPage extends StatefulWidget {
  const ProjectsPage({super.key});

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  var _items = const <Project>[];
  var _loading = true; // 仅首轮整页骨架;刷新在旧数据上原地等(B2 修复 P2-9)
  String? _error;

  /// J2:搜索过滤词(名称/code 不区分大小写包含;空=全量)。
  var _query = '';

  /// J2:输入即时过滤已加载列表(纯前端,不新增 API)。
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
    // 数据新鲜度(B2 §8.1):IndexedStack 常驻页挂失效总线,写操作后自动重拉
    RefreshBus.I.addListener('projects', _reload);
    _reload();
  }

  @override
  void dispose() {
    RefreshBus.I.removeListener('projects', _reload);
    super.dispose();
  }

  /// 拉取并落态(失效总线/下拉刷新/重试/手动刷新同路);返回真 future,
  /// RefreshIndicator 的圈等完成后才收,旧列表在刷新期间继续展示不整页替换。
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

  /// E3:项目行管理动作长按菜单(admin:「成员管理/请求链接」,与 web
  /// 行尾双图标钮同闸门;整行 onTap 进宫格语义不变)。
  Future<void> _showRowMenu(Project p) async {
    Haptics.light(); // G2:长按菜单进入
    final canAdmin = p.myRoles.contains('admin');
    if (!canAdmin || !mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Tk.spaceLg,
                Tk.spaceSm,
                Tk.spaceLg,
                Tk.spaceSm,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${p.name} · 管理',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Tk.muted, fontSize: Tk.fzMd),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.people_outline),
              title: const Text('成员管理'),
              onTap: () => Navigator.of(sheetCtx).pop('members'),
            ),
            ListTile(
              leading: const Icon(Icons.link_outlined),
              title: const Text('请求链接'),
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

  /// R3:非列表内容(loading/error/empty)包成全高可滚动,使 RefreshIndicator
  /// 在这些状态也能下拉(AlwaysScrollableScrollPhysics + 全高撑起,
  /// ErrorView/EmptyState 自带居中,布局观感不变)。
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

  /// E3:空态 + 新建引导(is_project_creator 闸门;与 AppBar 同闸门)。
  Widget _emptyWithCta() {
    final canCreate = session.me?.isProjectCreator ?? false;
    return _scrollable(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const EmptyState(icon: Icons.folder_copy_outlined, message: '暂无可见项目'),
          if (canCreate) ...[
            const SizedBox(height: Tk.spaceLg),
            FilledButton.icon(
              onPressed: () => showNewProjectSheet(context),
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: const Text('新建项目'),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredProjects;
    return Scaffold(
      appBar: AppBar(
        title: Text(projectsTitle()),
        actions: [
          // B6:新建项目(总闸门 is_project_creator;成功后失效总线自动重拉)
          if (session.me?.isProjectCreator ?? false)
            IconButton(
              tooltip: '新建项目',
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: () async {
                await showNewProjectSheet(context);
              },
            ),
        ],
        // J2:标题下常驻紧凑搜索框(AppBar bottom 钉住,列表滚动不带走);
        // SearchField 自带清除钮,清空经 onChanged('') 恢复全量。
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Tk.spaceLg,
              0,
              Tk.spaceLg,
              Tk.spaceSm,
            ),
            child: SearchField(
              hintText: '搜索项目名称 / 代号',
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        ),
      ),
      // R3:下拉刷新覆盖全部状态(原仅非空列表分支;AppBar 刷新钮已删)
      body: RefreshIndicator(
        onRefresh: _reload,
        child: _loading
            ? _scrollable(const ListSkeleton(rows: 5))
            : _error != null
            ? _scrollable(ErrorView(message: _error!, onRetry: _reload))
            : _items.isEmpty
            ? _emptyWithCta()
            : filtered.isEmpty
            // J2:有数据但过滤无命中 → 轻空态(仍可下拉刷新)
            ? _scrollable(
                const EmptyState(icon: Icons.search_off, message: '无匹配项目'),
              )
            : ListView.separated(
                itemCount: filtered.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final p = filtered[i];
                  // E3:trailing 收敛=角色徽标+chevron;管理动作入长按菜单
                  return ListTile(
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        color: Tk.surface2,
                        borderRadius: BorderRadius.all(Radius.circular(Tk.rMd)),
                      ),
                      child: const Icon(
                        Icons.folder_copy_outlined,
                        color: Tk.accent,
                        size: 22,
                      ),
                    ),
                    title: Text(p.name),
                    subtitle: Text(p.code),
                    // E3:trailing 收敛=角色徽标+chevron(管理动作入长按菜单)
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MyRolesBadge(roles: p.myRoles),
                        const SizedBox(width: Tk.spaceXs),
                        const Icon(
                          Icons.chevron_right,
                          size: 20,
                          color: Tk.subtle,
                        ),
                      ],
                    ),
                    onTap: () => Navigator.of(context)
                        // B3:附带项目名(宫格上传任务 where 显示路径);
                        // B6:附带 my_roles(文件夹页「新建一级」闸门)
                        .pushNamed(
                          '/folders',
                          arguments: (p.id, p.name, p.myRoles),
                        ),
                    onLongPress: () => _showRowMenu(p),
                  );
                },
              ),
      ),
    );
  }
}
