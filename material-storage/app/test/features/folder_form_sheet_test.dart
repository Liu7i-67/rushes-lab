/// 新建/重命名文件夹表单单测(B6 测试功能点 1):子夹=仅名称;项目根新建=
/// 名称+敏感开关(仅此处有义);重命名预填;成功失效 folders scope;
/// 409/422 detail 透传;folderNameError 前端校验纯函数。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/folders/folder_form_sheet.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

void main() {
  test('folderNameError:空/首尾空白拒绝(web 422 同口径文案)', () {
    expect(folderNameError(null), '请输入名称');
    expect(folderNameError('  '), '请输入名称');
    expect(folderNameError(' a '), '名称首尾不能包含空白字符');
    expect(folderNameError('正常名称'), isNull);
  });

  testWidgets('新建子夹:提交 create(parent=本夹)并失效 folders', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    var folders = 0;
    void onFolders() => folders++;
    RefreshBus.I.addListener('folders', onFolders);
    addTearDown(() => RefreshBus.I.removeListener('folders', onFolders));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showFolderFormSheet(ctx,
                  mode: FolderFormMode.createChild,
                  projectId: 'p1',
                  parentFolderId: 'f1',
                  parentLabel: '档案'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 敏感开关不出现(子夹恒普通)
    expect(find.text('敏感文件夹'), findsNothing);

    await tester.enterText(find.byType(TextField), '2026 婚礼素材');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final call = api.foldersOps.createCalls.single;
    expect(call.projectId, 'p1');
    expect(call.parentFolderId, 'f1');
    expect(call.name, '2026 婚礼素材');
    expect(call.isSensitive, isFalse);
    expect(folders, greaterThan(0));
    expect(find.text('新建子文件夹「档案」下'), findsNothing, reason: '成功后表单已收起');
  });

  testWidgets('项目根新建:敏感开关出现,开=true 提交', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showFolderFormSheet(ctx,
                  mode: FolderFormMode.createRoot,
                  projectId: 'p1',
                  parentLabel: '医美项目'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('敏感文件夹'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '敏感素材');
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final call = api.foldersOps.createCalls.single;
    expect(call.parentFolderId, isNull);
    expect(call.isSensitive, isTrue);
  });

  testWidgets('重命名:预填现名;空名校验拦下;409 detail 透传', (tester) async {
    final api = installFakeApi();
    api.foldersOps.renameStaged = ApiException(409, '该项目下已存在同名文件夹');
    addTearDown(() => session.api = null);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showFolderFormSheet(ctx,
                  mode: FolderFormMode.rename,
                  folder: Folder(id: 'f1', name: '旧名', parentFolderId: null)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('重命名文件夹「旧名」'), findsOneWidget);
    expect(find.text('旧名'), findsWidgets, reason: '名称预填现名');

    // 空名 → 前端校验拦下(不发请求;全空白按「请输入名称」口径)
    await tester.enterText(find.byType(TextField).first, ' ');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(api.foldersOps.renameCalls, isEmpty);
    expect(find.text('请输入名称'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '新名');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(api.foldersOps.renameCalls.single,
        (folderId: 'f1', name: '新名'));
    expect(find.textContaining('该项目下已存在同名文件夹'), findsOneWidget,
        reason: '409 detail 透传');
  });
}
