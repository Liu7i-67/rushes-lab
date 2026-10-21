/// 批量移动 sheet 单测(B5 测试功能点 2):项目固定显示;目标夹树 sensitive
/// 及其子树级联禁选+源夹自身禁选(web FolderTree 实况);提交入参
/// target_folder_id;结果对账视图;成功失效 assets/folders scope;
/// 混批多项目整批禁用(pure,矩阵兜底)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/assets/batch_move_sheet.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

Folder _folder(String id, String name,
        {String? parent, bool sensitive = false}) =>
    Folder(
        id: id,
        name: name,
        parentFolderId: parent,
        projectId: 'p1',
        isSensitive: sensitive);

void main() {
  test('batchMoveBlockReason:混批多项目整批禁用+上限,与后端 400 detail 同文案', () {
    expect(batchMoveBlockReason(projectIds: {'p1', 'p2'}, selectedCount: 3),
        '所选文件属于多个项目,一期仅支持同一项目内批量移动');
    expect(batchMoveBlockReason(projectIds: {'p1'}, selectedCount: 1001),
        contains('1000'));
    expect(batchMoveBlockReason(projectIds: {'p1'}, selectedCount: 3), isNull);
  });

  test('sensitiveCascadeIds:sensitive 及其子树级联;断链不误禁(web ancestorDisabled)',
      () {
    final folders = [
      _folder('f1', '普通'),
      _folder('f2', '敏感', sensitive: true),
      _folder('f3', '敏感子夹', parent: 'f2'),
      _folder('f4', '敏感孙夹', parent: 'f3'),
      _folder('f5', '孤儿', parent: 'ghost'),
    ];
    expect(sensitiveCascadeIds(folders), {'f2', 'f3', 'f4'});
  });

  testWidgets('项目固定展示;敏感夹及其子夹禁选、源夹自身禁选;选普通夹提交成功并失效',
      (tester) async {
    final api = installFakeApi();
    api.folders.listResult = [
      _folder('f1', '当前夹'),
      _folder('f2', '目标夹'),
      _folder('sf', '敏感夹', sensitive: true),
      _folder('sc', '敏感子夹', parent: 'sf'),
    ];
    addTearDown(() => session.api = null);
    var assets = 0;
    var folders = 0;
    void onAssets() => assets++;
    void onFolders() => folders++;
    RefreshBus.I.addListener('assets:f1', onAssets);
    RefreshBus.I.addListener('folders', onFolders);
    addTearDown(() {
      RefreshBus.I.removeListener('assets:f1', onAssets);
      RefreshBus.I.removeListener('folders', onFolders);
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showBatchMoveSheet(ctx,
                  selectedIds: const ['a1', 'a2', 'a3'],
                  sourceFolderId: 'f1',
                  projectId: 'p1',
                  projectLabel: '医美项目'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 项目固定(web:目标项目 Select disabled)
    expect(find.textContaining('目标项目:医美项目'), findsOneWidget);
    expect(find.textContaining('一期仅支持项目内移动'), findsOneWidget);

    // 敏感夹/其子夹禁选(点按不选):ListTile enabled=false
    bool tileEnabled(String name) => tester
        .widget<ListTile>(find.ancestor(
            of: find.text(name), matching: find.byType(ListTile)))
        .enabled;
    expect(tileEnabled('敏感夹'), isFalse, reason: 'sensitive 禁选');
    expect(tileEnabled('敏感子夹'), isFalse, reason: 'sensitive 子树级联禁选');
    expect(tileEnabled('当前夹'), isFalse, reason: '源夹自身禁选');
    expect(tileEnabled('目标夹'), isTrue);

    await tester.tap(find.text('目标夹'));
    await tester.pump();
    expect(find.textContaining('目录「目标夹」'), findsOneWidget);
    await tester.tap(find.text('移动'));
    await tester.pumpAndSettle();

    final call = api.ops.moveCalls.single;
    expect(call.ids, ['a1', 'a2', 'a3']);
    expect(call.targetFolderId, 'f2');
    expect(assets, greaterThan(0));
    expect(folders, greaterThan(0));

    // 结果视图:对账恒等式 + skipped/fga_pending 中文
    expect(find.textContaining('成功移动 3 个文件(共提交 3 个)'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
  });

  testWidgets('结果视图:skipped/fga_pending 中文与对账行(moved=0 警示口径)',
      (tester) async {
    final api = installFakeApi();
    api.folders.listResult = [_folder('f1', '当前夹'), _folder('f2', '目标夹')];
    api.ops.moveStaged = AssetBatchMoveResult(movedCount: 0, skipped: [
      AssetBatchMoveSkip(assetId: 'a2', reason: 'duplicate_location'),
      AssetBatchMoveSkip(assetId: 'a3', reason: 'duplicate_filename'),
    ], fgaPending: ['a4']);
    addTearDown(() => session.api = null);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showBatchMoveSheet(ctx,
                  selectedIds: const ['a1', 'a2', 'a3', 'a4'],
                  sourceFolderId: 'f1',
                  projectId: 'p1',
                  projectLabel: '医美项目'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目标夹'));
    await tester.pump();
    await tester.tap(find.text('移动'));
    await tester.pumpAndSettle();
    expect(find.text('本次未移动任何文件(共提交 4 个)'), findsOneWidget);
    expect(find.textContaining('对账:成功 0 + 跳过 2 + 待同步 1 = 4'), findsOneWidget);
    expect(find.textContaining('已在目标位置'), findsOneWidget);
    expect(find.textContaining('目标已有同名文件'), findsOneWidget);
  });

  testWidgets('400 detail 透传(混批多项目漏检/目标跨项目由后端兜底)', (tester) async {
    final api = installFakeApi();
    api.folders.listResult = [_folder('f1', '当前夹'), _folder('f2', '目标夹')];
    api.ops.moveStaged =
        ApiException(400, '目标文件夹与所选文件不属于同一个项目');
    addTearDown(() => session.api = null);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showBatchMoveSheet(ctx,
                  selectedIds: const ['a1'],
                  sourceFolderId: 'f1',
                  projectId: 'p1',
                  projectLabel: '医美项目'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目标夹'));
    await tester.pump();
    await tester.tap(find.text('移动'));
    await tester.pumpAndSettle();
    expect(find.textContaining('目标文件夹与所选文件不属于同一个项目'), findsOneWidget);
  });
}
