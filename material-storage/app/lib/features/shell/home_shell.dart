/// HomeShell(§2):IndexedStack 四 tab 保状态;底部四格导航。
/// tab1=项目(现役平移)/ tab2=搜索(B7 交付,§8.8)/ tab3=传输(B3 交付,§7)/
/// tab4=我的。
/// app-polish B6:挂 RefreshBus `shell:tab:transfers` 监听——上传迷你条
/// (upload_sheet.dart [openTransfersView])点击广播此 scope 即切传输 tab;
/// 调用方在 shell 之上的推入页(宫格等)时同步弹回本路由,让切换可见。
library;

import 'package:flutter/material.dart';

import '../../core/refresh_bus.dart';
import '../me/me_page.dart';
import '../projects/projects_page.dart';
import '../search/search_page.dart';
import '../transfers/transfers_page.dart';
import 'tab_bar.dart';

/// shell:tab:transfers 广播 → 传输 tab 的 IndexedStack 下标(与 children
/// 顺序耦合,children 重排时同步改)。
const _kTransfersTabIndex = 2;

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// B6:shell 是否挂载在树上(生产挂于 /home 常驻)。上传迷你条侧
  /// (upload_sheet.dart [openTransfersView])据此区分「shell 接管切 tab」与
  /// 「非 shell 上下文 push 兜底」——RefreshBus 是纯回调注册表、无「是否已有
  /// 订阅」查询通道,由本壳 initState/dispose 自报(inject 隔离测试亦适用)。
  static bool get isInTree => _HomeShellState._active != null;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static _HomeShellState? _active;

  int _index = 0;

  void _onTab(int i) => setState(() => _index = i);

  @override
  void initState() {
    super.initState();
    _active = this;
    // B6:上传迷你条点击 → 真·切 tab(upload_sheet.dart 只广播,shell 接管)
    RefreshBus.I.addListener('shell:tab:transfers', _onTransfersTab);
  }

  @override
  void dispose() {
    if (identical(_active, this)) _active = null;
    RefreshBus.I.removeListener('shell:tab:transfers', _onTransfersTab);
    super.dispose();
  }

  /// B6:收到广播 → 切传输 tab;若调用方仍在 shell 之上的推入页(迷你条所在
  /// 的宫格页等),一并弹回本路由——否则 tab 在底下换了用户看不见。以「本
  /// 路由是否 isCurrent」判断,不在推入页时不做多弹。
  void _onTransfersTab() {
    if (!mounted) return;
    setState(() => _index = _kTransfersTabIndex);
    final shellRoute = ModalRoute.of(context);
    if (shellRoute != null && !shellRoute.isCurrent) {
      Navigator.of(context).popUntil((r) => r == shellRoute);
    }
  }

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
