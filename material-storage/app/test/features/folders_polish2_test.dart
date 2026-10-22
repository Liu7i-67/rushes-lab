/// app-polish-2(P2 批)文件夹直属计数验收用例(对应需求文档
/// 2026-10-22-app-polish-2.md K2 #1):FolderRow 计数三态——
/// - 直属>0:主徽标「N 项」(数字=本夹直属,不含子树);
/// - 直属 0 且子树>0:灰字弱提示「子级 M 项」(fzXs muted),不再出现误导的
///   「1313 项」全量主数字;图标实心(子树含文件)语义保持;
/// - 两者皆 0:不显示任何数字。
///
/// 套路:直挂 FolderRow widget(独立验收基线;开发侧同条目用例见
/// folders_page_title_test.dart K 组,两套互为对照)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/folders/folder_row.dart';
import 'package:ms_app/features/folders/folder_tree.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/tokens.dart';

Widget _host(FolderNode node) => MaterialApp(
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

FolderNode _node(
        {required String name, int direct = 0, int subtree = 0}) =>
    FolderNode(Folder(
      id: name,
      name: name,
      parentFolderId: null,
      projectId: 'p1',
      directFileCount: direct,
      subtreeFileCount: subtree,
    ));

void main() {
  testWidgets('K2:直属>0 显示「N 项」主徽标(数字=直属,不含子树)', (tester) async {
    await tester.pumpWidget(_host(_node(
        name: '成片夹', direct: 3, subtree: 1313)));
    expect(find.text('3 项'), findsOneWidget, reason: 'K2:主数字=直属数');
    expect(find.text('1313 项'), findsNothing,
        reason: 'K2:子树全量不再作主数字');
    expect(find.textContaining('子级'), findsNothing,
        reason: 'K2:有直属时不出「子级」弱提示');
  });

  testWidgets('K2:直属 0 且子树>0 显示「子级 M 项」灰字弱提示', (tester) async {
    await tester.pumpWidget(_host(_node(name: '空直属夹', subtree: 1313)));
    expect(find.text('子级 1313 项'), findsOneWidget,
        reason: 'K2:子树数降级为「子级 M 项」弱提示');
    expect(find.text('1313 项'), findsNothing,
        reason: 'K2:不再出现误导的全量主数字');

    // 弱提示样式:fzXs + muted 灰字(弱于主徽标)
    final text = tester.widget<Text>(find.text('子级 1313 项'));
    expect(text.style?.fontSize, Tk.fzXs);
    expect(text.style?.color, Tk.muted);

    // 图标实心(子树含文件)语义保持不变
    expect(find.byIcon(Icons.folder), findsOneWidget);
    expect(find.byIcon(Icons.folder_outlined), findsNothing);
  });

  testWidgets('K2:直属与子树皆 0 不显示任何数字', (tester) async {
    await tester.pumpWidget(_host(_node(name: '空夹')));
    expect(find.text('0 项'), findsNothing);
    expect(find.textContaining('项'), findsNothing,
        reason: 'K2:皆 0 不显示数字');
    // 空夹图标保持橙色空心
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
  });
}
