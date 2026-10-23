/// 移动文件夹面板单测(B6 测试功能点 1):禁选集纯函数(自身+子树+sensitive
/// 级联)/项目根选项(移为一级=PATCH parent null)/选目标提交/409 detail 透传。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/folders/move_folder_sheet.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

Folder _folder(
  String id,
  String name, {
  String? parent,
  bool sensitive = false,
}) => Folder(
  id: id,
  name: name,
  parentFolderId: parent,
  projectId: 'p1',
  isSensitive: sensitive,
);

void main() {
  test('moveTargetBlockIds:自身+子树整支禁选+sensitive 级联(目标不含自身子树)', () {
    final folders = [
      _folder('f1', '源夹'),
      _folder('f2', '源子夹', parent: 'f1'),
      _folder('f3', '源孙夹', parent: 'f2'),
      _folder('f4', '普通目标'),
      _folder('sf', '敏感夹', sensitive: true),
      _folder('sc', '敏感子夹', parent: 'sf'),
    ];
    expect(moveTargetBlockIds(folders, 'f1'), {'f1', 'f2', 'f3', 'sf', 'sc'});
  });

  testWidgets('项目根可选;自身/子树/敏感夹禁选;选根提交 parent=null 并失效', (tester) async {
    final api = installFakeApi();
    api.folders.listResult = [
      _folder('f1', '源夹'),
      _folder('f2', '源子夹', parent: 'f1'),
      _folder('f4', '普通目标'),
      _folder('sf', '敏感夹', sensitive: true),
    ];
    addTearDown(() => session.api = null);
    var folders = 0;
    void onFolders() => folders++;
    RefreshBus.I.addListener('folders', onFolders);
    addTearDown(() => RefreshBus.I.removeListener('folders', onFolders));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () => showMoveFolderSheet(
                  ctx,
                  folder: Folder(
                    id: 'f1',
                    name: '源夹',
                    parentFolderId: null,
                    projectId: 'p1',
                  ),
                  projectId: 'p1',
                  projectLabel: '医美项目',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('目标项目:医美项目'), findsOneWidget);

    bool tileEnabled(String name) =>
        tester
            .widget<InkWell>(
              find
                  .ancestor(of: find.text(name), matching: find.byType(InkWell))
                  .first,
            )
            .onTap !=
        null;
    expect(tileEnabled('源夹'), isFalse, reason: '自身禁选');
    expect(tileEnabled('源子夹'), isFalse, reason: '自身子树整支禁选');
    expect(tileEnabled('敏感夹'), isFalse, reason: 'sensitive 目标禁选');
    expect(tileEnabled('普通目标'), isTrue);

    await tester.tap(find.text('项目根(移为一级)'));
    await tester.pump();
    await tester.tap(find.text('移动'));
    await tester.pumpAndSettle();

    final call = api.foldersOps.moveCalls.single;
    expect(call.folderId, 'f1');
    expect(call.parentFolderId, isNull, reason: '移为一级=显式 null');
    expect(folders, greaterThan(0));
  });

  testWidgets('选普通夹提交 parent=夹 id;409 detail 透传(带 explicit grant 等)', (
    tester,
  ) async {
    final api = installFakeApi();
    api.folders.listResult = [_folder('f1', '源夹'), _folder('f4', '普通目标')];
    api.foldersOps.moveStaged = ApiException(409, '带授权的一级文件夹不允许移动');
    addTearDown(() => session.api = null);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () => showMoveFolderSheet(
                  ctx,
                  folder: Folder(
                    id: 'f1',
                    name: '源夹',
                    parentFolderId: null,
                    projectId: 'p1',
                  ),
                  projectId: 'p1',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('普通目标'));
    await tester.pump();
    await tester.tap(find.text('移动'));
    await tester.pumpAndSettle();
    expect(api.foldersOps.moveCalls.single.parentFolderId, 'f4');
    expect(find.textContaining('带授权的一级文件夹不允许移动'), findsOneWidget);
  });
}
