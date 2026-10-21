/// HomeShell(§2):IndexedStack 四 tab 保状态;底部四格导航。
/// tab1=项目(现役平移)/ tab2=搜索(B7 交付,§8.8)/ tab3=传输(B3 交付,§7)/
/// tab4=我的。
library;

import 'package:flutter/material.dart';

import '../me/me_page.dart';
import '../projects/projects_page.dart';
import '../search/search_page.dart';
import '../transfers/transfers_page.dart';
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
          const SearchPage(),
          const TransfersPage(),
          MePage(),
        ],
      ),
      bottomNavigationBar: AppTabBar(index: _index, onChanged: _onTab),
    );
  }
}
