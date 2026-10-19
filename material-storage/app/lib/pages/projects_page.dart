import 'package:flutter/material.dart';

import '../main.dart' show api;
import '../models.dart';
import 'log_push.dart';

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
    _future = api.projects();
  }

  void _reload() => setState(() => _future = api.projects());

  @override
  Widget build(BuildContext context) {
    final me = ModalRoute.of(context)?.settings.arguments as Me?;
    return Scaffold(
      appBar: AppBar(
        title: Text(me != null ? '项目 · ${me.name}' : '项目'),
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
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${snap.error}', textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton.tonal(onPressed: _reload, child: const Text('重试')),
                ],
              ),
            );
          }
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return const Center(child: Text('暂无可见项目'));
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
