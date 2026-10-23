/// MinIO bucket 下拉(第四批 A2/A5):bucket 由自由输入改为单选项 `PickerField`
/// + `showPickerSheet<String>`(同 web NewProjectModal 硬编码 options)。覆盖:
/// 字段可见→点按弹层(唯一项/关闭钮)→选中回显→不开弹层直接提交走默认值;
/// 以及 `minioBucketLabel` 回落。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/projects/minio_buckets.dart';
import 'package:ms_app/features/projects/new_project_sheet.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

Widget _host() => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (ctx) => Center(
        child: FilledButton(
          onPressed: () => showNewProjectSheet(ctx),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

Finder get _bucketField => find.widgetWithText(TextField, 'MinIO bucket(必填)');

/// 装配假 API + 创建者账号,打开弹层并展开「高级」(bucket 收在折叠内)。
Future<FakeMsApi> _openAdvanced(WidgetTester tester) async {
  final api = installFakeApi();
  addTearDown(() => session.api = null);
  session.me = Me(id: 'me1', name: '甲', isProjectCreator: true);
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_host());
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('高级'));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('展开「高级」后 bucket 字段可见,只读且回显默认桶 label', (tester) async {
    await _openAdvanced(tester);
    expect(_bucketField, findsOneWidget);
    expect(tester.widget<TextField>(_bucketField).readOnly, isTrue);
    expect(
      tester.widget<TextField>(_bucketField).controller!.text,
      'ms-dev(开发环境)',
    );
  });

  testWidgets('点按字段弹出选择器:出现 ms-dev(开发环境) 与关闭钮', (tester) async {
    await _openAdvanced(tester);
    await tester.tap(_bucketField);
    await tester.pumpAndSettle();

    expect(find.text('选择 MinIO bucket'), findsOneWidget);
    // 字段本身也在同一 BottomSheet 内(只读 TextField 的 EditableText 同文案),
    // 故行断言限定 ListTile,与既有 _sheetRow 用法一致。
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.widgetWithText(ListTile, 'ms-dev(开发环境)'),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('关闭'), findsWidgets, reason: '弹层可取消');
  });

  testWidgets('选择器里点选 ms-dev(开发环境) → 弹层关闭、字段回显', (tester) async {
    await _openAdvanced(tester);
    await tester.tap(_bucketField);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.widgetWithText(ListTile, 'ms-dev(开发环境)'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('选择 MinIO bucket'), findsNothing, reason: '选即关');
    expect(
      tester.widget<TextField>(_bucketField).controller!.text,
      'ms-dev(开发环境)',
    );
  });

  testWidgets('不打开选择器直接提交 → 请求体 minio_bucket=ms-dev(默认值链路)', (tester) async {
    final api = await _openAdvanced(tester);
    await tester.enterText(find.widgetWithText(TextField, '项目名称'), '演示');
    await tester.enterText(
      find.widgetWithText(TextField, '项目编码(小写字母/数字/-)'),
      'demo',
    );
    await tester.pump();
    await tester.tap(find.text('创建项目'));
    await tester.pumpAndSettle();

    expect(
      api.projectsOps.createCalls.single['minio_bucket'],
      'ms-dev',
      reason: '默认 _bucket = kMinioBuckets.first.value',
    );
  });

  group('minioBucketLabel(纯函数)', () {
    test('已知 value → 中文 label', () {
      expect(minioBucketLabel('ms-dev'), 'ms-dev(开发环境)');
    });

    test('未知 value 回落原值(兼容历史数据)', () {
      expect(minioBucketLabel('unknown-x'), 'unknown-x');
    });

    test('kMinioBuckets 首项即默认桶', () {
      expect(kMinioBuckets.first.value, 'ms-dev');
      expect(kMinioBuckets.first.label, 'ms-dev(开发环境)');
    });
  });
}
