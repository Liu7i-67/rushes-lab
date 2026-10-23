/// 批量打标/单条打标 sheet 单测(B5 测试功能点 3):
/// merge/replace 入参 labels_mode 正确(默认 merge=web 批量实况);≤50 校验;
/// 逐 id PATCH;单条(预览页)**不传 labels_mode**(后端默认 replace,web 实况);
/// notes 携带口径;成功后失效 assets/folders scope。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/assets/batch_tag_sheet.dart';

import '../helpers/api_harness.dart';

void main() {
  /// RefreshBus 计数挂载/卸载(具名函数保证 removeListener 同一闭包)。
  (int Function(), int Function()) countScopes() {
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
    return (() => assets, () => folders);
  }

  test('parseLabels:逗号/、/换行分隔,trim 去空去重保序', () {
    expect(parseLabels('a, b，c、 d\ne,a'), ['a', 'b', 'c', 'd', 'e']);
    expect(parseLabels('  '), isEmpty);
  });

  test('tagLabelsError:≤50 合法,>50 拦截(后端静默截断,App 明示)', () {
    expect(tagLabelsError(List.generate(50, (i) => 'l$i')), isNull);
    expect(tagLabelsError(List.generate(51, (i) => 'l$i')), contains('50'));
  });

  testWidgets('批量打标:默认 merge,逐 id PATCH 带 labels_mode=merge;成功失效两 scope', (
    tester,
  ) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    final assetsCount = countScopes().$1;
    final foldersCount = countScopes().$2;

    await _open(
      tester,
      (ctx) =>
          showBatchTagSheet(ctx, assetIds: const ['a1', 'a2'], folderId: 'f1'),
    );
    await tester.enterText(find.byType(TextField).first, '棚拍, 现场');
    await tester.pump(); // 刷帧:提交钮由禁用(空标签)转可用
    await tester.tap(find.text('打标'));
    await tester.pumpAndSettle();

    expect(api.ops.metaCalls, hasLength(2), reason: '逐 id PATCH');
    expect(api.ops.metaCalls.map((c) => c.id).toSet(), {'a1', 'a2'});
    expect(
      api.ops.metaCalls.every((c) => c.mode == 'merge'),
      isTrue,
      reason: '批量默认 merge(web 实况)',
    );
    expect(api.ops.metaCalls.first.labels, ['棚拍', '现场']);
    expect(assetsCount(), greaterThan(0));
    expect(foldersCount(), greaterThan(0));
  });

  testWidgets('批量打标:切 replace 后 labels_mode=replace;空标签提交禁用', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    await _open(
      tester,
      (ctx) => showBatchTagSheet(ctx, assetIds: const ['a1'], folderId: 'f1'),
    );
    // 空标签:提交禁用
    await tester.tap(find.text('打标'), warnIfMissed: false);
    await tester.pump();
    expect(api.ops.metaCalls, isEmpty);
    // 切替换模式 + 输入
    await tester.tap(find.text('替换已有标签'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '新标签');
    await tester.pump(); // 刷帧:提交钮由禁用(空标签)转可用
    await tester.tap(find.text('打标'));
    await tester.pumpAndSettle();
    expect(api.ops.metaCalls.single.mode, 'replace');
  });

  testWidgets('批量打标:>50 个标签提交禁用', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    await _open(
      tester,
      (ctx) => showBatchTagSheet(ctx, assetIds: const ['a1'], folderId: 'f1'),
    );
    final many = List.generate(51, (i) => '标签$i').join(',');
    await tester.enterText(find.byType(TextField).first, many);
    await tester.pump();
    expect(find.textContaining('最多 50 个标签'), findsOneWidget);
    await tester.tap(find.text('打标'), warnIfMissed: false);
    await tester.pump();
    expect(api.ops.metaCalls, isEmpty, reason: '超限禁提交');
  });

  testWidgets('单条(预览页):不传 labels_mode;只改 notes 时仅提 notes;无变化不提交', (
    tester,
  ) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);

    // 只改 notes:labels 不变 → body 无 labels_mode、无 user_labels
    await _open(
      tester,
      (ctx) => showTagEditSheet(
        ctx,
        asset: fakeAsset('a1', labels: ['棚拍']),
        folderId: 'f1',
      ),
    );
    expect(find.text('替换已有标签'), findsNothing, reason: '单条不渲染模式选择');
    await tester.enterText(find.byType(TextField).at(1), '新备注');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final call = api.ops.metaCalls.single;
    expect(call.mode, isNull, reason: '单条编辑不传 labels_mode(web 实况)');
    expect(call.labels, isNull);
    expect(call.notes, '新备注');

    // 无变化:不提交直接关闭
    await _open(
      tester,
      (ctx) => showTagEditSheet(
        ctx,
        asset: fakeAsset('a1', labels: ['棚拍'], notes: '新备注'),
        folderId: 'f1',
      ),
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(api.ops.metaCalls, hasLength(1), reason: '无变化不提交(web 实况)');
  });
}

Future<void> _open(
  WidgetTester tester,
  Future<Object?> Function(BuildContext) open,
) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) {
            captured = ctx;
            return Center(
              child: FilledButton(
                onPressed: () => open(captured),
                child: const Text('open'),
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}
