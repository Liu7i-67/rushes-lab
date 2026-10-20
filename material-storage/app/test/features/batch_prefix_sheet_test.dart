/// 批量前缀 sheet 单测(B5 测试功能点 4):add/remove 入参;前缀校验=web 实况
/// (trim 非空 / 不含 "/" / ≤128,非法禁提交);改名预览近似口径;
/// 成功失效 assets/folders scope;skipped_reasons 中文汇总 toast。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/assets/batch_prefix_sheet.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

Asset _asset(String name) => Asset(
    id: 'id-$name', filename: name, sizeBytes: 1,
    createdAt: '2026-10-20T10:00:00Z');

void main() {
  test('prefixErrorOf:web BatchPrefixModal 实况三则', () {
    expect(prefixErrorOf('   '), '前缀不能为空');
    expect(prefixErrorOf('a/b'), '前缀不能包含 "/"');
    expect(prefixErrorOf('x' * 129), '前缀最长 128 个字符');
    expect(prefixErrorOf('  2026-09- '), isNull);
    expect(prefixErrorOf('x' * 128), isNull);
  });

  test('previewRename:加/去预览与跳过口径(web 同)', () {
    expect(previewRename('a.jpg', 'p-', 'add'),
        (before: 'a.jpg', after: 'p-a.jpg', skip: null));
    expect(previewRename('p-a.jpg', 'p-', 'add').skip, '已带该前缀');
    expect(previewRename('p-a.jpg', 'p-', 'remove').after, 'a.jpg');
    expect(previewRename('a.jpg', 'p-', 'remove').skip, '前缀不匹配');
    expect(previewRename('p-', 'p-', 'remove').skip, '去后为空');
  });

  Future<void> pumpOpener(
    WidgetTester tester, {
    required List<Asset> assets,
    required List<String> selectedIds,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showBatchPrefixSheet(ctx,
                  assets: assets,
                  selectedIds: selectedIds,
                  folderId: 'f1',
                  onSettle: (_) {}),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('非法前缀(空/含 /)禁提交不发请求', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    await pumpOpener(tester,
        assets: [_asset('a.jpg')], selectedIds: ['id-a.jpg']);
    // 空文本:禁用
    await tester.tap(find.text('执行改名'), warnIfMissed: false);
    await tester.pump();
    expect(api.ops.prefixCalls, isEmpty);
    // 含 "/":错误提示且禁用
    await tester.enterText(find.byType(TextField), 'a/b');
    await tester.pump();
    expect(find.text('前缀不能包含 "/"'), findsOneWidget);
    await tester.tap(find.text('执行改名'), warnIfMissed: false);
    await tester.pump();
    expect(api.ops.prefixCalls, isEmpty);
  });

  testWidgets('加前缀:入参 action=add + prefix(trim 后);成功失效两 scope',
      (tester) async {
    final api = installFakeApi();
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

    await pumpOpener(tester,
        assets: [_asset('a.jpg')], selectedIds: ['id-a.jpg']);
    await tester.enterText(find.byType(TextField), '  2026-09- ');
    await tester.pump();
    // 预览行(近似口径)
    expect(find.textContaining('a.jpg → 2026-09-a.jpg'), findsOneWidget);
    await tester.tap(find.text('执行改名'));
    await tester.pumpAndSettle();
    final call = api.ops.prefixCalls.single;
    expect(call.action, 'add');
    expect(call.prefix, '2026-09-', reason: 'trim 后提交(服务端再 NFC 归一)');
    expect(call.ids, ['id-a.jpg']);
    expect(assets, greaterThan(0));
    expect(folders, greaterThan(0));
  });

  testWidgets('去前缀:入参 action=remove;skipped_reasons 中文汇总 toast',
      (tester) async {
    final api = installFakeApi();
    api.ops.prefixStaged =
        AssetBatchPrefixResult(renamed: 1, skipped: 2, skippedReasons: {
      'no_match': 1,
      'already_prefixed': 1,
    });
    addTearDown(() => session.api = null);
    await pumpOpener(tester,
        assets: [_asset('p-a.jpg')], selectedIds: ['id-p-a.jpg']);
    await tester.tap(find.text('去前缀'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'p-');
    await tester.pump();
    await tester.tap(find.text('执行改名'));
    await tester.pumpAndSettle();
    expect(api.ops.prefixCalls.single.action, 'remove');
    expect(find.textContaining('前缀不匹配 1'), findsOneWidget);
    expect(find.textContaining('已带该前缀 1'), findsOneWidget);
  });
}
