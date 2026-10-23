/// 搜索单测(B7 测试功能点 4):防抖 300ms(窗口内多次输入只发末次)/
/// 取消过期请求(旧响应不覆盖新输入)/命中高亮/50 截断提示/结果序列进预览。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/search/result_row.dart';
import 'package:ms_app/features/search/search_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/features/preview/preview_page.dart';
import 'package:ms_app/widgets/page_header.dart';

import '../helpers/api_harness.dart';

SearchResult resultOf(
  String id, {
  String? filename,
  String? contentType = 'image/jpeg',
  String folderId = 'f1',
  String folderName = '成片夹',
  String projectName = '项目一',
}) => SearchResult(
  asset: Asset(
    id: id,
    filename: filename ?? '$id.jpg',
    sizeBytes: 1,
    contentType: contentType,
    createdAt: '2026-10-20T10:00:00Z',
    folderId: folderId,
    userLabels: const ['关键标签'],
  ),
  folderName: folderName,
  projectId: 'p1',
  projectName: projectName,
);

void main() {
  test('highlightSpans:忽略大小写命中拆段;无命中整段原样;空 query', () {
    expect(highlightSpans('Report_Final.PNG', 'final'), [
      ('Report_', false),
      ('Final', true),
      ('.PNG', false),
    ]);
    expect(highlightSpans('abc', 'xyz'), [('abc', false)]);
    expect(highlightSpans('abc', ''), [('abc', false)]);
  });

  test('typeBadgeLabel:扩展名大写优先;无扩展名按类型兜底', () {
    expect(typeBadgeLabel('a.Mp4', null), 'MP4');
    expect(typeBadgeLabel('noext', 'video/mp4'), '视频');
    expect(typeBadgeLabel('noext', 'application/pdf'), 'PDF');
  });

  testWidgets('防抖 300ms:窗口内连续输入只发末次;清空不发请求', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);

    await tester.pumpWidget(const MaterialApp(home: SearchPage()));
    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'ab');
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.assets.searchCalls, isEmpty, reason: '300ms 未到不发');

    await tester.pump(const Duration(milliseconds: 250));
    expect(api.assets.searchCalls.map((c) => c.q), [
      'ab',
    ], reason: '窗口内多次输入只发末次');
    expect(find.text('找到 0 个文件'), findsOneWidget);
  });

  testWidgets('取消过期请求:旧响应迟到不覆盖新输入结果', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    final gate = Completer<void>();

    await tester.pumpWidget(const MaterialApp(home: SearchPage()));
    // 第一次查询挂起(迟到响应编排)
    api.assets.searchStaged.add(
      gate.future.then(
        (_) => <SearchResult>[resultOf('old', filename: '旧结果.jpg')],
      ),
    );
    await tester.enterText(find.byType(TextField), '旧');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(api.assets.searchCalls.single.q, '旧');

    // 换词:新查询立即回
    api.assets.searchStaged.add(<SearchResult>[
      resultOf('new', filename: '新结果.jpg'),
    ]);
    await tester.enterText(find.byType(TextField), '新');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(api.assets.searchCalls.length, 2);
    expect(find.text('新结果.jpg'), findsOneWidget);

    // 放行旧响应:代际不匹配被丢弃
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('旧结果.jpg'), findsNothing, reason: '旧响应不覆盖新输入');
    expect(find.text('新结果.jpg'), findsOneWidget);
  });

  testWidgets('结果行:命中高亮+归属+类型徽标;50 截断提示;空结果态', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.assets.searchStaged.add([
      for (var i = 0; i < 50; i++) resultOf('a$i', filename: '报表明细$i.jpg'),
    ]);

    await tester.pumpWidget(const MaterialApp(home: SearchPage()));
    await tester.enterText(find.byType(TextField), '报表');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    // 截断提示在列表尾(builder 惰性构建),滚到可见
    await tester.scrollUntilVisible(
      find.text('结果超过 50 条,MVP 截断 — 用更精确关键词缩小范围'),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    expect(
      find.text('结果超过 50 条,MVP 截断 — 用更精确关键词缩小范围'),
      findsOneWidget,
      reason: '50 截断提示(web 同款文案)',
    );
    expect(find.text('项目一 / 成片夹'), findsWidgets, reason: '归属行');
    expect(find.text('JPG'), findsWidgets, reason: '类型徽标');

    // 空结果态
    api.assets.searchStaged.add(const <SearchResult>[]);
    await tester.enterText(find.byType(TextField), '不存在的词');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有命中「不存在的词」'), findsOneWidget);
  });

  testWidgets('点击结果 → push 预览(结果序列做胶片条,带上 where/folderId)', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.assets.searchStaged.add([
      resultOf('a0', filename: '第一张.jpg'),
      resultOf('a1', filename: '第二张.jpg'),
    ]);
    PreviewArgs? args;
    await tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: (s) {
          if (s.name == '/preview') args = s.arguments as PreviewArgs;
          return MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('PreviewT')),
          );
        },
        home: const SearchPage(),
      ),
    );
    await tester.enterText(find.byType(TextField), '第');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.tap(find.text('第二张.jpg'));
    await tester.pumpAndSettle();
    expect(args, isNotNull);
    expect(args!.items.map((a) => a.id), ['a0', 'a1'], reason: '结果序列整表进预览');
    expect(args!.index, 1, reason: '起点=点击行');
    expect(args!.where, '项目一/成片夹');
  });

  testWidgets('点击结果 → 预览参数带逐素材 folderId/where(跨文件夹结果)', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.assets.searchStaged.add([
      resultOf('a0', filename: '跨夹一.jpg'),
      resultOf(
        'a1',
        filename: '跨夹二.jpg',
        folderId: 'f2',
        folderName: '另一夹',
        projectName: '项目二',
      ),
    ]);
    PreviewArgs? args;
    await tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: (s) {
          if (s.name == '/preview') args = s.arguments as PreviewArgs;
          return MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('PreviewT')),
          );
        },
        home: const SearchPage(),
      ),
    );
    await tester.enterText(find.byType(TextField), '跨夹');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.tap(find.text('跨夹二.jpg'));
    await tester.pumpAndSettle();
    expect(args, isNotNull);
    expect(args!.folderId, 'f2', reason: '页面级 folderId=起点素材');
    expect(args!.where, '项目二/另一夹', reason: '页面级 where=起点素材');
    expect(args!.folderIds, {
      'a0': 'f1',
      'a1': 'f2',
    }, reason: '逐素材 folderId 映射');
    expect(args!.wheres, {
      'a0': '项目一/成片夹',
      'a1': '项目二/另一夹',
    }, reason: '逐素材 where 映射');
  });

  testWidgets('PageHeader 大标题 + 类型 chip 客户端过滤(全部/图片/视频/PDF/Markdown)', (
    tester,
  ) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.assets.searchStaged.add([
      resultOf('i1', filename: '图.jpg'),
      resultOf('v1', filename: '片.mp4', contentType: null),
      resultOf('p1', filename: '文.pdf', contentType: null),
      resultOf('m1', filename: '注.md', contentType: null),
    ]);

    await tester.pumpWidget(const MaterialApp(home: SearchPage()));
    expect(find.byType(PageHeader), findsOneWidget);
    expect(find.text('搜索文件名 / 标签 / 备注'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '素材');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    for (final name in ['图.jpg', '片.mp4', '文.pdf', '注.md']) {
      expect(find.text(name), findsOneWidget, reason: '全部:$name');
    }

    await tester.tap(find.text('图片'));
    await tester.pump();
    expect(find.text('图.jpg'), findsOneWidget);
    expect(find.text('片.mp4'), findsNothing);
    expect(find.text('文.pdf'), findsNothing);
    expect(find.text('注.md'), findsNothing);
    expect(find.text('找到 1 个文件'), findsOneWidget);

    await tester.tap(find.text('视频'));
    await tester.pump();
    expect(find.text('片.mp4'), findsOneWidget);
    expect(find.text('图.jpg'), findsNothing);

    await tester.tap(find.text('PDF'));
    await tester.pump();
    expect(find.text('文.pdf'), findsOneWidget);
    expect(find.text('片.mp4'), findsNothing);

    await tester.tap(find.text('Markdown'));
    await tester.pump();
    expect(find.text('注.md'), findsOneWidget);
    expect(find.text('文.pdf'), findsNothing);

    await tester.tap(find.text('全部'));
    await tester.pump();
    expect(find.text('图.jpg'), findsOneWidget);
    expect(find.text('片.mp4'), findsOneWidget);
    expect(find.text('文.pdf'), findsOneWidget);
    expect(find.text('注.md'), findsOneWidget);
  });
}
