/// P4/P5 文件夹页与树行单测:
/// - P4:FoldersPage AppBar 标题=项目名,空回退「文件夹」(FakeFoldersApi 供数);
/// - P5:FolderRow 含文件(子树计数>0)实心深色图标、空夹橙色空心,
///   「N 项」badge 与敏感锁不受影响。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/folders/folder_row.dart';
import 'package:ms_app/features/folders/folder_tree.dart';
import 'package:ms_app/features/folders/folders_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/tokens.dart';

import '../helpers/api_harness.dart';

Folder folderOf(String id,
        {String? parent, int files = 0, bool sensitive = false}) =>
    Folder(
      id: id,
      name: '夹$id',
      parentFolderId: parent,
      projectId: 'p1',
      subtreeFileCount: files,
      isSensitive: sensitive,
    );

void main() {
  group('P4:FoldersPage AppBar 标题', () {
    testWidgets('显示项目名(含长名经 FittedBox 缩放)', (tester) async {
      final api = installFakeApi();
      api.folders.listResult = const [];
      addTearDown(() => session.api = null);
      const longName = '一个特别特别特别特别特别特别特别特别长的项目名称测试用例';
      await tester.pumpWidget(MaterialApp(
        home: FoldersPage(projectId: 'p1', projectName: longName),
      ));
      await tester.pumpAndSettle();
      expect(find.text(longName), findsOneWidget);
      expect(find.text('文件夹'), findsNothing);
      expect(tester.takeException(), isNull, reason: '长名不溢出');
    });

    testWidgets('projectName 为空回退「文件夹」', (tester) async {
      final api = installFakeApi();
      api.folders.listResult = const [];
      addTearDown(() => session.api = null);
      await tester.pumpWidget(const MaterialApp(
        home: FoldersPage(projectId: 'p1'),
      ));
      await tester.pumpAndSettle();
      expect(find.text('文件夹'), findsOneWidget);
    });
  });

  group('P5:FolderRow 图标(实心=含文件,对齐 web)', () {
    Widget host(FolderNode node) => MaterialApp(
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

    testWidgets('subtreeFileCount>0 → Icons.folder 实心 + Tk.fg', (tester) async {
      await tester.pumpWidget(host(FolderNode(folderOf('a', files: 3))));
      final icon = tester.widget<Icon>(find.byIcon(Icons.folder));
      expect(icon.color, Tk.fg);
      expect(find.byIcon(Icons.folder_outlined), findsNothing);
      // 「N 项」badge 保留
      expect(find.text('3 项'), findsOneWidget);
    });

    testWidgets('=0 → folder_outlined 空心 + Tk.accent,无 badge', (tester) async {
      await tester.pumpWidget(host(FolderNode(folderOf('b'))));
      final icon = tester.widget<Icon>(find.byIcon(Icons.folder_outlined));
      expect(icon.color, Tk.accent);
      expect(find.byIcon(Icons.folder), findsNothing);
      expect(find.textContaining('项'), findsNothing);
    });

    testWidgets('敏感锁与实心分支互不影响', (tester) async {
      await tester.pumpWidget(
          host(FolderNode(folderOf('c', files: 1, sensitive: true))));
      expect(find.byIcon(Icons.folder), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });
  });
}
