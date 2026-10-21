/// B9 测试功能点 1:网盘树懒加载——展开拉子级(path 透传)/文件行灰显不可选
/// /截断提示/错误态可重试(不置已加载死态)/点选目录+勾选返回/根目录不可作源。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/baidu/netdisk_tree_sheet.dart';

import '../helpers/fake_baidu.dart';

Future<void> pumpPicker(WidgetTester tester, FakeBaiduAdapter adapter) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: NetdiskTreePickerPage(api: baiduApiWith(adapter)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('根目录加载:目录行可选,文件行灰显不可选(disabled)', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      expect(req.path, '/api/v1/baidu/backup/netdisk/folders');
      expect(req.query['path'], '/');
      return netdiskJson([
        entry('/照片', '照片'),
        entry('/说明.txt', '说明.txt', isDir: false, size: 2048),
      ]);
    });
    await pumpPicker(tester, adapter);

    expect(find.text('照片'), findsOneWidget);
    final fileTile = tester.widget<ListTile>(find.ancestor(
        of: find.text('说明.txt'), matching: find.byType(ListTile)));
    expect(fileTile.enabled, isFalse, reason: '文件行灰显不可选(选目录建任务语义)');
    expect(find.text('2.0 KB'), findsOneWidget, reason: '文件行展示大小');
  });

  testWidgets('展开拉子级:展开请求带父路径;收起再展开不重拉(懒加载一次)',
      (tester) async {
    var childFetches = 0;
    final adapter = FakeBaiduAdapter((req) async {
      if (req.query['path'] == '/') {
        return netdiskJson([entry('/照片', '照片')]);
      }
      childFetches++;
      expect(req.query['path'], '/照片', reason: '懒加载=展开拉子级,path 透传');
      return netdiskJson([
        entry('/照片/2026', '2026'),
        entry('/照片/a.jpg', 'a.jpg', isDir: false, size: 1),
      ]);
    });
    await pumpPicker(tester, adapter);

    await tester.tap(find.text('照片'));
    await tester.pumpAndSettle();
    expect(childFetches, 1);
    expect(find.text('2026'), findsOneWidget);
    // 子级文件行同样灰显
    expect(
        tester
            .widget<ListTile>(find.ancestor(
                of: find.text('a.jpg'), matching: find.byType(ListTile)))
            .enabled,
        isFalse);

    // 收起 → 展开:children 已缓存,不重发
    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pumpAndSettle();
    expect(find.text('2026'), findsNothing);
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    expect(find.text('2026'), findsOneWidget);
    expect(childFetches, 1, reason: '懒加载一次,已加载节点不重拉');
  });

  testWidgets('子级加载失败:错误态显示可重试(不标记已加载),重试成功出子级',
      (tester) async {
    var fail = true;
    final adapter = FakeBaiduAdapter((req) async {
      if (req.query['path'] == '/') {
        return netdiskJson([entry('/照片', '照片')]);
      }
      if (fail) {
        // 绑定非 active 后端语义:409 detail 透传
        return (409, {'detail': '请先绑定百度网盘账号'});
      }
      return netdiskJson([entry('/照片/2026', '2026')]);
    });
    await pumpPicker(tester, adapter);

    await tester.tap(find.text('照片'));
    await tester.pumpAndSettle();
    expect(find.text('请先绑定百度网盘账号'), findsOneWidget,
        reason: '后端中文 detail 透传(频控/冲突语义同口径)');
    expect(find.text('2026'), findsNothing);

    fail = false;
    await tester.tap(find.byIcon(Icons.expand_more)); // 重试点开再拉
    await tester.pumpAndSettle();
    expect(find.text('2026'), findsOneWidget, reason: '错误态可重试,不置死态');
  });

  testWidgets('truncated 提示;根目录失败 → 错误态+重试成功', (tester) async {
    var failRoot = true;
    final adapter = FakeBaiduAdapter((req) async {
      if (failRoot) return (500, {'detail': '百度接口频控,请稍后重试'});
      if (req.query['path'] == '/') {
        return netdiskJson([entry('/照片', '照片')], truncated: true);
      }
      return netdiskJson([]);
    });
    await pumpPicker(tester, adapter);
    expect(find.text('百度接口频控,请稍后重试'), findsOneWidget);

    failRoot = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('照片'), findsOneWidget);
    expect(find.text('目录过大,仅显示部分内容'), findsOneWidget,
        reason: 'truncated 提示「分批浏览」口径');
  });

  testWidgets('点选目录高亮,勾选返回路径;未选时勾选禁用', (tester) async {
    // 选择器经 showNetdiskTreePicker 推入,内里读 session.api!.baidu:
    // 注入挂替身适配器的 session 客户端
    final adapter = FakeBaiduAdapter(
        (req) async => netdiskJson([entry('/照片', '照片')]));
    final msApi = MsApi(baseUrl: 'http://mock.local');
    msApi.http.httpClientAdapter = adapter;
    final savedApi = session.api;
    session.api = msApi;
    addTearDown(() => session.api = savedApi);
    String? popped;
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () async {
                popped = await showNetdiskTreePicker(ctx);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('选择网盘目录'), findsOneWidget);

    // 未选:确定(勾)禁用
    expect(
        tester.widget<IconButton>(find
            .ancestor(of: find.byTooltip('确定'),
                matching: find.byType(IconButton))).onPressed,
        isNull);

    await tester.tap(find.text('照片'));
    await tester.pumpAndSettle();
    expect(find.text('已选来源:/照片'), findsOneWidget);
    final checkBtn = tester.widget<IconButton>(find
        .ancestor(of: find.byTooltip('确定'), matching: find.byType(IconButton)));
    expect(checkBtn.onPressed, isNotNull);
    await tester.tap(find.byTooltip('确定'));
    await tester.pumpAndSettle();
    expect(popped, '/照片', reason: '勾选返回选定路径');
    expect(find.text('选择网盘目录'), findsNothing, reason: '选择器已收起');
  });
}
