/// 「默认收拢全部文件夹」App 端验收(2026-11-19 settings-mcp-collapse
/// §9 App 1/2/3,F9/D4):
/// - prefs 开:进入 FoldersPage 后**所有含子级节点**预填 _collapsed——顶层行
///   可见、子级行不渲染;点箭头逐层展开(展开根见子,子仍收拢);再点收拢
///   (子树整支隐藏);
/// - prefs 关:默认全展开(回归 folders_page_title_test 既有口径,折叠/
///   再展开行为不变);
/// - prefs 接口异常:文件夹页正常渲染且按未收拢兜底(ErrorView 不出现);
/// - 开关切换对下一次进入生效(D4):重挂载(路由重进同构)按新值渲染;
/// - prefs 开 + 手工展开后失效重拉(RefreshBus 'folders'):手工展开态保持
///   不被预填覆盖,其余含子级节点仍收拢(默认收拢只并不清且跳过手工展开)。
///
/// 打桩:helpers/api_harness 的 FakeMsApi(prefs 域=FakePrefsApi,folders/
/// projects 域照既有假件);widget 测试 FakeAsync 区真实 socket 永不推进,
/// 桩在 pumpWidget(首个请求)前就位;每个用例独立构造样本,不共享可变
/// fixture。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/folders/folder_row.dart';
import 'package:ms_app/features/folders/folders_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/error_view.dart';
import 'package:ms_app/widgets/page_header.dart';

import '../helpers/api_harness.dart';

/// 三层树样本:根A → 子A1 → 孙A11;独立根B(叶子,无子级)。
/// 每次调用返回全新列表(表驱动样本互不共享)。
List<Folder> _tree() => [
      Folder(id: 'a', name: '根夹A', parentFolderId: null, projectId: 'p1'),
      Folder(id: 'a1', name: '子夹A1', parentFolderId: 'a', projectId: 'p1'),
      Folder(
        id: 'a11',
        name: '孙夹A11',
        parentFolderId: 'a1',
        projectId: 'p1',
      ),
      Folder(id: 'b', name: '根夹B', parentFolderId: null, projectId: 'p1'),
    ];

/// 行定位(经行内名称文本回溯 FolderRow,不与页头/行尾 more_horiz 图标串扰)。
Finder _row(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(FolderRow));

/// 行内展开箭头(expanded=expand_more;收拢=chevron_right;叶子=占位无箭头)。
Finder _rowIcon(String name, IconData icon) =>
    find.descendant(of: _row(name), matching: find.byIcon(icon));

/// 挂页面 + 全假 API;返回 prefs 域桩供用例内编排/断言。
/// projectCode 传 'ym' 旁路 _loadCode 兜底反查(桩 projects 域仍在,双保险)。
Future<FakePrefsApi> _pumpPage(
  WidgetTester tester, {
  List<Folder> folders = const [],
  bool collapsed = false,
  Object? getStaged,
}) async {
  final api = installFakeApi();
  api.folders.listResult = folders;
  api.prefs.getStaged =
      getStaged ?? UserPrefs(folderTreeDefaultCollapsed: collapsed);
  addTearDown(() => session.api = null);
  await tester.pumpWidget(
    MaterialApp(
      home: FoldersPage(
        key: UniqueKey(),
        projectId: 'p1',
        projectName: '医美项目',
        projectCode: 'ym',
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api.prefs;
}

void main() {
  group('prefs 开:进入即全部含子级节点收拢(F9)', () {
    testWidgets('顶层行可见、子级行不渲染;含子级行=收拢箭头,叶子无箭头',
        (tester) async {
      await _pumpPage(tester, folders: _tree(), collapsed: true);

      expect(find.text('根夹A'), findsOneWidget, reason: '顶层行可见');
      expect(find.text('根夹B'), findsOneWidget, reason: '顶层行可见');
      expect(find.text('子夹A1'), findsNothing, reason: '子级行不渲染');
      expect(find.text('孙夹A11'), findsNothing, reason: '孙级行不渲染');

      expect(
        _rowIcon('根夹A', Icons.chevron_right),
        findsOneWidget,
        reason: '含子级节点预填收拢态(chevron_right)',
      );
      expect(
        _rowIcon('根夹A', Icons.expand_more),
        findsNothing,
        reason: '预填后不应出现展开态箭头',
      );
      expect(
        _rowIcon('根夹B', Icons.chevron_right),
        findsNothing,
        reason: '叶子节点无子级,箭头位=占位',
      );
      expect(_rowIcon('根夹B', Icons.expand_more), findsNothing);
    });

    testWidgets('点箭头逐层展开(根→子,子仍收拢);再点收拢(子树整支隐藏)',
        (tester) async {
      await _pumpPage(tester, folders: _tree(), collapsed: true);

      await tester.tap(_rowIcon('根夹A', Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(find.text('子夹A1'), findsOneWidget, reason: '展开根后子级可见');
      expect(find.text('孙夹A11'), findsNothing, reason: '逐层:子级自身仍收拢');
      expect(
        _rowIcon('子夹A1', Icons.chevron_right),
        findsOneWidget,
        reason: '子级行箭头=收拢态',
      );

      await tester.tap(_rowIcon('子夹A1', Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(find.text('孙夹A11'), findsOneWidget, reason: '第二层展开见孙');
      expect(_rowIcon('子夹A1', Icons.expand_more), findsOneWidget);

      await tester.tap(_rowIcon('根夹A', Icons.expand_more));
      await tester.pumpAndSettle();
      expect(find.text('子夹A1'), findsNothing, reason: '再点收拢');
      expect(find.text('孙夹A11'), findsNothing, reason: '折叠隐藏整支子树');
    });
  });

  group('prefs 关:默认全展开(回归现状)', () {
    testWidgets('初载即全展开;点箭头折叠/再展开行为保持', (tester) async {
      await _pumpPage(tester, folders: _tree(), collapsed: false);

      expect(find.text('子夹A1'), findsOneWidget, reason: '开关关=现状全展开');
      expect(find.text('孙夹A11'), findsOneWidget);
      expect(
        _rowIcon('根夹A', Icons.expand_more),
        findsOneWidget,
        reason: '含子级行=展开态箭头',
      );

      await tester.tap(_rowIcon('根夹A', Icons.expand_more));
      await tester.pumpAndSettle();
      expect(find.text('子夹A1'), findsNothing);
      expect(find.text('孙夹A11'), findsNothing, reason: '折叠隐藏整支子树');

      await tester.tap(_rowIcon('根夹A', Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(find.text('子夹A1'), findsOneWidget, reason: '再展开恢复');
      expect(find.text('孙夹A11'), findsOneWidget);
    });

    testWidgets('开关切换对下一次进入生效:重挂载(路由重进同构)按新值渲染(D4)',
        (tester) async {
      final prefs = await _pumpPage(tester, folders: _tree(), collapsed: true);
      expect(find.text('子夹A1'), findsNothing, reason: '前置:本轮全收拢');

      // 用户关掉开关后的服务端新值;UniqueKey 强制重建 State=重进项目语义
      prefs.getStaged = const UserPrefs(folderTreeDefaultCollapsed: false);
      await tester.pumpWidget(
        MaterialApp(
          home: FoldersPage(
            key: UniqueKey(),
            projectId: 'p1',
            projectName: '医美项目',
            projectCode: 'ym',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('子夹A1'),
        findsOneWidget,
        reason: '重进页面按关闭后值全展开',
      );
      expect(find.text('孙夹A11'), findsOneWidget);
    });
  });

  group('prefs 接口异常:按未收拢兜底正常渲染(§9 App 3)', () {
    testWidgets('getPrefs 抛错:全展开渲染、不误入整页错误态', (tester) async {
      await _pumpPage(
        tester,
        folders: _tree(),
        getStaged: ApiException(500, '偏好加载失败'),
      );

      expect(find.text('根夹A'), findsOneWidget, reason: '文件夹页正常渲染');
      expect(find.text('子夹A1'), findsOneWidget, reason: '按未收拢兜底');
      expect(find.text('孙夹A11'), findsOneWidget, reason: '按未收拢兜底');
      expect(
        find.byType(ErrorView),
        findsNothing,
        reason: 'prefs 失败静默,不落整页错误态',
      );
      expect(find.byType(PageHeader), findsOneWidget);
    });
  });

  group('重拉不覆盖手工展开态(F9 修正)', () {
    testWidgets('开关开启→手工展开根→RefreshBus 失效重拉:根仍展开,其余含子级仍收拢',
        (tester) async {
      await _pumpPage(tester, folders: _tree(), collapsed: true);
      expect(find.text('子夹A1'), findsNothing, reason: '前置:初载全收拢');

      // 手工展开根夹A(逐层:子级 A1 自身仍收拢)
      await tester.tap(_rowIcon('根夹A', Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(find.text('子夹A1'), findsOneWidget, reason: '前置:手工展开生效');
      expect(find.text('孙夹A11'), findsNothing, reason: '子级 A1 仍收拢');

      // 失效总线重拉(下拉刷新/返回重拉同路):预填跳过手工展开过的节点
      RefreshBus.I.invalidate('folders');
      await tester.pumpAndSettle();

      expect(find.text('根夹A'), findsOneWidget, reason: '重拉后顶层行仍在');
      expect(
        find.text('子夹A1'),
        findsOneWidget,
        reason: '手工展开态不被重拉预填覆盖',
      );
      expect(
        find.text('孙夹A11'),
        findsNothing,
        reason: 'A1 未手工展开,重拉后仍收拢(孙级不渲染)',
      );
      expect(
        _rowIcon('根夹A', Icons.expand_more),
        findsOneWidget,
        reason: '根夹A 保持展开态箭头',
      );
      expect(
        _rowIcon('子夹A1', Icons.chevron_right),
        findsOneWidget,
        reason: '其余含子级节点重拉后仍收拢',
      );
    });
  });
}
