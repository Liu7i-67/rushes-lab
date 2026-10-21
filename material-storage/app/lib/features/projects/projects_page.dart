/// 项目页(B2 §8.1):列表 + 权限徽标 + 下拉刷新。B6 点亮:新建项目入口
/// (is_project_creator 闸门)+ 行内「成员」入口(my_roles 含 admin)。
library;

import 'package:flutter/material.dart';

import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../main.dart' show kAppBuildStamp;
import '../../models/models.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../me/log_push.dart';
import '../share/request_link_sheet.dart';
import 'new_project_sheet.dart';
import 'project_members_sheet.dart';
import 'role_badge.dart';

/// 项目页 AppBar 标题:打包注入 stamp 时在「项目」后追加最后编辑时间
/// (TestFlight 分辨构建新旧用),未注入时保持原标题。
String projectsTitle(String? userName, String buildStamp) {
  final tail = userName == null ? '' : ' · $userName';
  return buildStamp.isEmpty ? '项目$tail' : '项目 · 最后编辑 $buildStamp$tail';
}

class ProjectsPage extends StatefulWidget {
  const ProjectsPage({super.key});

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  var _items = const <Project>[];
  var _loading = true; // 仅首轮整页 spinner;刷新在旧数据上原地等(B2 修复 P2-9)
  String? _error;

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
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 标题可能较长(项目 · 最后编辑 YYYY-MM-DD HH:mm · 用户名),缩放防溢出
        title: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(projectsTitle(session.me?.name, kAppBuildStamp)),
        ),
        actions: [
          logPushButton(context),
          // B6:新建项目(总闸门 is_project_creator;成功后失效总线自动重拉)
          if (session.me?.isProjectCreator ?? false)
            IconButton(
              tooltip: '新建项目',
              icon: const Icon(Icons.add_business_outlined),
              onPressed: () async {
                await showNewProjectSheet(context);
              },
            ),
          IconButton(onPressed: _reload, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(message: _error!, onRetry: _reload)
              : _items.isEmpty
                  ? const EmptyState(
                      icon: Icons.folder_copy_outlined,
                      message: '暂无可见项目',
                    )
                  : RefreshIndicator(
                      onRefresh: _reload,
                      child: ListView.separated(
                        itemCount: _items.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final p = _items[i];
                          return ListTile(
                            leading: const Icon(Icons.folder_copy_outlined),
                            title: Text(p.name),
                            subtitle: Text(p.code),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                MyRolesBadge(roles: p.myRoles),
                                // B6:成员管理入口(项目 admin;后端 can_admin 兜底)
                                if (p.myRoles.contains('admin'))
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    tooltip: '成员管理',
                                    icon: const Icon(Icons.people_outline,
                                        size: 20),
                                    onPressed: () =>
                                        showProjectMembersSheet(context,
                                            project: p),
                                  ),
                                // B9 §8.11:请求链接入口(项目页发起位=
                                // my_roles 含 admin,web 同闸门;非 admin 不露出)
                                if (p.myRoles.contains('admin'))
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    tooltip: '请求链接',
                                    icon: const Icon(Icons.link_outlined,
                                        size: 20),
                                    onPressed: () => showRequestLinkSheet(
                                        context,
                                        targetType: 'project',
                                        targetId: p.id,
                                        targetLabel: p.name),
                                  ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                            onTap: () => Navigator.of(context)
                                // B3:附带项目名(宫格上传任务 where 显示路径);
                                // B6:附带 my_roles(文件夹页「新建一级」闸门)
                                .pushNamed('/folders',
                                    arguments: (p.id, p.name, p.myRoles)),
                          );
                        },
                      ),
                    ),
    );
  }
}
