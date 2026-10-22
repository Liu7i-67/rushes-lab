/// 文件夹行计数(app-polish-3 测试功能点 1,D1 定稿):直属>0 显示「N 项」
/// 徽标;直属=0 一律不显示任何数字(「子级 M 项」子树弱提示已整体删除——
/// 用户原话「不应该展示子级20项」,数字只引发「点进去是空的」二次误导);
/// 图标实心/空心仍按 subtree>0 点亮(hasFiles 语义保留)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/folders/folder_row.dart';
import 'package:ms_app/features/folders/folder_tree.dart';
import 'package:ms_app/models/models.dart';

Folder _folder({
  required String id,
  required String name,
  int direct = 0,
  int subtree = 0,
}) =>
    Folder(
      id: id,
      name: name,
      parentFolderId: null,
      projectId: 'p1',
      directFileCount: direct,
      subtreeFileCount: subtree,
    );

/// 直挂一行 FolderRow(children 挂空壳子节点表达「有子级」)。
Widget _host(Folder f, {bool hasChildren = false}) => MaterialApp(
      home: Scaffold(
        body: FolderRow(
          node: FolderNode(f)
            ..children.addAll([
              if (hasChildren) FolderNode(_folder(id: '${f.id}-c', name: '子夹')),
            ]),
          depth: 0,
          expanded: false,
          onToggle: () {},
          onOpen: () {},
        ),
      ),
    );

void main() {
  testWidgets('功能点 1:直属 0 + 子树 20 → 无「子级」、无数字、无「项」;'
      '子树含文件 → 实心图标点亮', (tester) async {
    await tester.pumpWidget(_host(
      _folder(id: 'a', name: 'A夹', direct: 0, subtree: 20),
      hasChildren: true,
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('子级'), findsNothing,
        reason: 'D1:用户原话「不应该展示子级20项」——子树弱提示整体删除');
    expect(find.textContaining('20'), findsNothing,
        reason: '直属=0 时不得出现任何数字(含子树数)');
    expect(find.textContaining('项'), findsNothing,
        reason: '直属=0 时行内无「项」字样');
    expect(find.byIcon(Icons.folder), findsOneWidget,
        reason: '实心图标仍按 subtree>0 点亮(含文件语义保留)');
    expect(find.byIcon(Icons.folder_outlined), findsNothing);
  });

  testWidgets('功能点 1:直属 5 → 显示「5 项」徽标,且无任何「子级」提示',
      (tester) async {
    await tester.pumpWidget(_host(
      _folder(id: 'b', name: 'B夹', direct: 5, subtree: 9),
    ));
    await tester.pumpAndSettle();

    expect(find.text('5 项'), findsOneWidget,
        reason: '直属>0 保留「N 项」徽标(数字=本夹直属,不含子树)');
    expect(find.text('9 项'), findsNothing, reason: '徽标只按直属,不按子树');
    expect(find.textContaining('子级'), findsNothing,
        reason: '直属>0 也不得再叠「子级 M 项」(D1 完全删除)');
  });

  testWidgets('功能点 1:直属 0 + 子树 0 → 无任何数字;空夹空心图标',
      (tester) async {
    await tester.pumpWidget(_host(_folder(id: 'c', name: 'C夹')));
    await tester.pumpAndSettle();

    expect(find.textContaining('项'), findsNothing,
        reason: '空夹无计数徽标');
    expect(find.textContaining('子级'), findsNothing);
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget,
        reason: '子树=0 空夹维持橙色空心图标');
    expect(find.byIcon(Icons.folder), findsNothing);
  });
}
