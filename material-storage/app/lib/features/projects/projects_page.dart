/// 项目页(B2 §8.1):列表 + 权限徽标(ROLE_META 同 web)+ 下拉刷新。
/// 新建项目/回收站等入口按方案 §16 后续批交付;素材计数后端无字段,不显示。
library;

import 'package:flutter/material.dart';

import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../main.dart' show kAppBuildStamp;
import '../../models/models.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../me/log_push.dart';
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
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                            onTap: () => Navigator.of(context)
                                .pushNamed('/folders', arguments: p.id),
                          );
                        },
                      ),
                    ),
    );
  }
}
