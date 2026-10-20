/// HomeShell(§2):IndexedStack 四 tab 保状态;底部四格导航。
/// tab1=项目(现役平移)/ tab2=搜索 / tab3=传输(占位,B2/B3 交付)/ tab4=我的。
library;

import 'package:flutter/material.dart';

import '../me/me_page.dart';
import '../projects/projects_page.dart';
import 'tab_bar.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  void _onTab(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          const ProjectsPage(),
          const ComingSoonPage(icon: Icons.search_outlined, title: '搜索'),
          const ComingSoonPage(icon: Icons.sync_outlined, title: '传输'),
          MePage(),
        ],
      ),
      bottomNavigationBar: AppTabBar(index: _index, onChanged: _onTab),
    );
  }
}

/// 占位页(B2 搜索 / B3 传输交付前;§16 批次表)。
class ComingSoonPage extends StatelessWidget {
  const ComingSoonPage({super.key, required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            const Text('即将上线'),
          ],
        ),
      ),
    );
  }
}
