/// 授权管理面板单测(B6 测试功能点 3):多 level chips 一次授多 level;
/// **无有效期控件**(钉子:后端只收 levels+主体恒永久);撤销 query 形状;
/// 列表展示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/folders/folder_grants_sheet.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

void main() {
  testWidgets('grants 列表展示;撤销弹层确认后 DELETE(subject+level)',
      (tester) async {
    final api = installFakeApi();
    api.foldersOps.listGrantsStaged = [
      FolderGrantRow(
          subject: 'group:g1#member',
          kind: 'group',
          subjectId: 'g1',
          name: '后期组',
          level: 'uploader'),
    ];
    addTearDown(() => session.api = null);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showFolderGrantsSheet(
                  ctx,
                  folder: Folder(
                      id: 'f1', name: '档案夹', parentFolderId: null,
                      projectId: 'p1')),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('授权管理 · 档案夹'), findsOneWidget);
    expect(find.text('后期组'), findsOneWidget);
    expect(find.text('上传'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '撤销'));
    await tester.pumpAndSettle();
    expect(api.foldersOps.removeGrantCalls.single,
        (folderId: 'f1', subject: 'group:g1#member', level: 'uploader'));
  });

  testWidgets('添加 grant:默认勾「查看」;多选 上传+查看 一次授多 level;'
      '无有效期控件;未选主体前端拦', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    session.me = Me(id: 'u1', name: '甲');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showFolderGrantsSheet(
                  ctx,
                  folder: Folder(
                      id: 'f1', name: '档案夹', parentFolderId: null,
                      projectId: 'p1')),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加授权'));
    await tester.pumpAndSettle();

    // 钉子:grants 表单无「有效期」字样控件(web 同款,防假 UI)
    expect(find.text('有效期'), findsNothing);
    expect(find.textContaining('恒永久'), findsWidgets);

    // 未选主体直接提交 → 前端拦
    await tester.tap(find.text('添加').last);
    await tester.pump();
    expect(find.text('请选至少一个主体'), findsOneWidget);

    // 选自己:app-polish D1 起主体选择走弹层(原内联常驻列表已下线)——
    // 点「添加用户 / 用户组」→ 弹层勾自己 → 完成(N) 回填汇总
    await tester.tap(find.text('添加用户 / 用户组'));
    await tester.pumpAndSettle(); // 弹层进场动画
    await tester.pump(const Duration(milliseconds: 300)); // 空 query 首搜防抖
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '甲(自己)'));
    await tester.pump(); // 勾选即时回填「完成(1)」
    await tester.tap(find.text('完成(1)'));
    await tester.pumpAndSettle(); // 退场动画后 onChanged 回填
    expect(find.textContaining('已选 1 项'), findsOneWidget);

    // 勾 上传(默认已有 查看)→ 提交 levels 固定序 [uploader, viewer]
    await tester.tap(find.text('上传'));
    await tester.pump();
    await tester.tap(find.text('添加').last);
    await tester.pumpAndSettle();

    final call = api.foldersOps.addGrantCalls.single;
    expect(call.userId, 'u1');
    expect(call.levels, ['uploader', 'viewer'],
        reason: 'levels 固定序=kGrantLevels 声明序(web LEVEL_ORDER)');
    expect(find.text('授权管理 · 档案夹'), findsOneWidget, reason: '成功回列表');
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });
}
