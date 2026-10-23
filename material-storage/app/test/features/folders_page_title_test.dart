/// P4/P5/K 文件夹页与树行单测(F7 重设计后):
/// - P4:二级页头(PageHeader)标题=项目名/空回退「文件夹」;
/// - P5:FolderRow 图标语义(P2-3:仅敏感夹金底金字;普通含文件=实心
///   folder + surface3 + ink2;空夹=folder_outlined);
/// - K:直属计数唯一入口=行尾「N 项」徽标(直属数,不含子树),
///   副标题只表「敏感目录」/「空文件夹」;直属=0 不显示数字;
/// - F7:项目头卡计数(文件夹数/素材合计)、code/角色、空态新建入口、
///   项目「⋯」菜单闸门。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/folders/folder_row.dart';
import 'package:ms_app/features/folders/folder_tree.dart';
import 'package:ms_app/features/folders/folders_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/widgets/page_header.dart';

import '../helpers/api_harness.dart';

Folder folderOf(
  String id, {
  String? parent,
  int files = 0,
  int direct = 0,
  bool sensitive = false,
}) => Folder(
  id: id,
  name: '夹$id',
  parentFolderId: parent,
  projectId: 'p1',
  subtreeFileCount: files,
  directFileCount: direct,
  isSensitive: sensitive,
);

Widget _rowHost(FolderNode node) => MaterialApp(
  home: Scaffold(
    body: FolderRow(
      node: node,
      depth: 0,
      expanded: true,
      onToggle: () {},
      onOpen: () {},
    ),
  ),
);

/// 装页面 + 假 API + 定数据;名字/角色/项目列表按需覆写。
Future<void> _pumpPage(
  WidgetTester tester, {
  List<Folder> folders = const [],
  List<String> roles = const [],
  String name = '医美项目',
  List<Project> projects = const [],
}) async {
  final api = installFakeApi();
  api.folders.listResult = folders;
  if (projects.isNotEmpty) api.projects.listStaged = projects;
  addTearDown(() => session.api = null);
  await tester.pumpWidget(
    MaterialApp(
      home: FoldersPage(projectId: 'p1', projectName: name, myRoles: roles),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('P4:PageHeader 标题', () {
    testWidgets('显示项目名(长名不溢出)', (tester) async {
      const longName = '一个特别特别特别特别特别特别特别特别长的项目名称测试用例';
      await _pumpPage(tester, name: longName);
      expect(
        find.descendant(
          of: find.byType(PageHeader),
          matching: find.text(longName),
        ),
        findsOneWidget,
      );
      expect(find.text('文件夹'), findsNothing);
      expect(tester.takeException(), isNull, reason: '长名不溢出');
    });

    testWidgets('projectName 为空:页头回退「文件夹」,头卡「未命名项目」', (tester) async {
      await _pumpPage(tester, name: '');
      expect(find.text('文件夹'), findsOneWidget);
      expect(find.text('未命名项目'), findsOneWidget);
    });
  });

  group('P5:FolderRow 图标(P2-3 仅敏感夹金底;普通含文件 ink2)', () {
    testWidgets('subtreeFileCount>0 → 实心 Icons.folder + ink2(不金底)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _rowHost(FolderNode(folderOf('a', files: 3, direct: 3))),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.folder));
      expect(icon.color, TkColors.light.ink2, reason: '普通含文件不再金底金字');
      expect(find.byIcon(Icons.folder_outlined), findsNothing);
      expect(find.text('3 项'), findsOneWidget, reason: '行尾徽标=直属计数');
      expect(find.text('3 个素材'), findsNothing, reason: '副标题不再承载数字');
    });

    testWidgets('=0 → folder_outlined + ink2,无 badge', (tester) async {
      await tester.pumpWidget(_rowHost(FolderNode(folderOf('b'))));
      final icon = tester.widget<Icon>(find.byIcon(Icons.folder_outlined));
      expect(icon.color, TkColors.light.ink2);
      expect(find.byIcon(Icons.folder), findsNothing);
      expect(find.text('空文件夹'), findsOneWidget);
      expect(find.textContaining('项'), findsNothing);
    });

    testWidgets('深色主题:普通含文件图标取 dark ink2', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            body: FolderRow(
              node: FolderNode(folderOf('dark', files: 2)),
              depth: 0,
              expanded: true,
              onToggle: () {},
              onOpen: () {},
            ),
          ),
        ),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.folder));
      expect(icon.color, TkColors.dark.ink2);
    });

    testWidgets('敏感夹 → 左侧金锁 + 右侧 warn 锁,无普通文件夹图标', (tester) async {
      await tester.pumpWidget(
        _rowHost(FolderNode(folderOf('c', files: 1, sensitive: true))),
      );
      final locks = tester.widgetList<Icon>(find.byIcon(Icons.lock_outline));
      expect(locks, hasLength(2), reason: '图标容器内金锁 + 行尾敏感锁');
      expect(
        locks.any((i) => i.color == TkColors.light.goldInk),
        isTrue,
        reason: '敏感图标金底金字',
      );
      expect(
        locks.any((i) => i.color == TkColors.light.warn),
        isTrue,
        reason: '行尾 14 敏感锁 warn',
      );
      expect(find.byIcon(Icons.folder), findsNothing);
    });
  });

  group('K:FolderRow 计数(行尾「N 项」徽标唯一;副标题只表敏感/空)', () {
    testWidgets('直属>0 → 行尾「N 项」徽标唯一计数(副标题无数字)', (tester) async {
      await tester.pumpWidget(
        _rowHost(FolderNode(folderOf('d1', files: 5, direct: 2))),
      );
      expect(find.text('2 项'), findsOneWidget, reason: '唯一计数位=行尾徽标');
      expect(find.text('2 个素材'), findsNothing, reason: '副标题不再承载数字');
      expect(find.textContaining('子级'), findsNothing);
      expect(find.text('5 项'), findsNothing, reason: '子树数不再作主数字');
    });

    testWidgets('直属 0 且子树>0 → 不显示任何数字', (tester) async {
      await tester.pumpWidget(
        _rowHost(FolderNode(folderOf('d2', files: 1313))),
      );
      expect(find.textContaining('子级'), findsNothing);
      expect(find.textContaining('1313'), findsNothing);
      expect(find.textContaining('项'), findsNothing);
      expect(find.byIcon(Icons.folder), findsOneWidget);
    });

    testWidgets('皆 0 → 不显示任何数字', (tester) async {
      await tester.pumpWidget(_rowHost(FolderNode(folderOf('d3'))));
      expect(find.textContaining('项'), findsNothing);
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    });
  });

  group('F7:项目头卡与空态', () {
    testWidgets('计数=文件夹总数与直属素材合计;code/角色来自已有数据', (tester) async {
      await _pumpPage(
        tester,
        folders: [
          folderOf('a', direct: 3),
          folderOf('b', parent: 'a', direct: 6),
        ],
        roles: ['admin', 'uploader'],
        projects: [Project(id: 'p1', name: '医美项目', code: 'ym')],
      );

      expect(find.text('2 个文件夹'), findsOneWidget);
      expect(
        find.text('9 个素材'),
        findsOneWidget,
        reason: 'direct_file_count 求和',
      );
      expect(find.text('YM'), findsOneWidget, reason: '头卡 code 微标签');
      expect(find.text('ym · 管理 + 上传'), findsOneWidget, reason: '顶栏副标题');
    });

    testWidgets('空态:暂无文件夹 + 有权限时「新建一级文件夹」主操作', (tester) async {
      await _pumpPage(tester, roles: ['admin']);

      expect(find.text('暂无文件夹'), findsOneWidget);
      expect(find.text('新建一级文件夹'), findsOneWidget);
    });

    testWidgets('空态:无权限不渲染新建主操作', (tester) async {
      await _pumpPage(tester);

      expect(find.text('暂无文件夹'), findsOneWidget);
      expect(find.text('新建一级文件夹'), findsNothing);
    });

    testWidgets('树:默认全展开,点箭头折叠/再展开子夹', (tester) async {
      await _pumpPage(
        tester,
        folders: [
          folderOf('a'),
          folderOf('b', parent: 'a'),
        ],
      );

      expect(find.text('夹b'), findsOneWidget, reason: '默认全展开');
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      expect(find.text('夹b'), findsNothing, reason: '折叠隐藏子树');
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(find.text('夹b'), findsOneWidget, reason: '再展开恢复');
    });

    testWidgets('320 宽 + 字号 1.3 无 overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final api = installFakeApi();
      api.folders.listResult = [
        folderOf('a', direct: 3),
        folderOf('b', parent: 'a'),
      ];
      addTearDown(() => session.api = null);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(1.3),
            ),
            child: const FoldersPage(
              projectId: 'p1',
              projectName: '一个很长的医美项目名称',
              myRoles: ['admin', 'uploader'],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('项目「⋯」:admin 见成员管理/请求链接', (tester) async {
      await _pumpPage(tester, roles: ['admin']);

      await tester.tap(find.byTooltip('项目操作'));
      await tester.pumpAndSettle();
      expect(find.text('成员管理'), findsOneWidget);
      expect(find.text('请求链接'), findsOneWidget);
    });

    testWidgets('项目「⋯」:非 admin 只见权限说明', (tester) async {
      await _pumpPage(tester, roles: ['viewer']);

      await tester.tap(find.byTooltip('项目操作'));
      await tester.pumpAndSettle();
      expect(find.text('项目操作仅项目管理员可用'), findsOneWidget);
      expect(find.text('成员管理'), findsNothing);
      expect(find.text('请求链接'), findsNothing);
    });
  });
}
