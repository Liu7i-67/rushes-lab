/// 项目页(现役平移,B1 不加新功能):列表 + 下拉刷新 + 构建戳标题。
/// 新建项目/回收站等入口按方案 §16 后续批交付。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../main.dart' show kAppBuildStamp;
import '../../models/models.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../me/log_push.dart';

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
  late Future<List<Project>> _future;

  @override
  void initState() {
    super.initState();
    _future = session.api!.projects.list();
  }

  void _reload() =>
      setState(() => _future = session.api!.projects.list());

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
      body: FutureBuilder<List<Project>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return ErrorView(message: '${snap.error}', onRetry: _reload);
          }
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.folder_copy_outlined,
              message: '暂无可见项目',
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final p = items[i];
                return ListTile(
                  leading: const Icon(Icons.folder_copy_outlined),
                  title: Text(p.name),
                  subtitle: Text(p.code),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context)
                      .pushNamed('/folders', arguments: p.id),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
