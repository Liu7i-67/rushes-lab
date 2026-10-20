/// 申请权限 sheet 单测(B5 测试功能点 5):access 仅 sensitive_folder 可选
/// (asset 目标下禁选);download 必填 duration_seconds(五档预设=web 实况,
/// 默认 1 小时);reason ≥4 字前端拦截;422/403 detail 透传;提交入参契约
/// (FakeApprovalsApi 记录;wire 级断言见 core/asset_ops_api_test)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/preview/request_access_sheet.dart';

import '../helpers/api_harness.dart';

Future<void> _pumpOpener(
  WidgetTester tester, {
  required String targetType,
  String targetId = 't1',
  String targetName = '目标',
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: FilledButton(
            onPressed: () => showRequestAccessSheet(ctx,
                targetType: targetType,
                targetId: targetId,
                targetName: targetName),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  test('allowedActionsOf:access 仅 sensitive_folder;后端无「编辑」动作', () {
    expect(allowedActionsOf('sensitive_folder'), ['access', 'download']);
    expect(allowedActionsOf('asset'), ['download']);
    expect(allowedActionsOf('folder'), ['download']);
    expect(allowedActionsOf('project'), ['download']);
  });

  test('reasonError:≥4 字合法(web min:4 同口径)', () {
    expect(reasonError('abc'), isNotNull);
    expect(reasonError(' 四个字了 '), isNull);
  });

  testWidgets('asset 目标:access 禁选,download 默认;短理由被拦截不发请求',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    await _pumpOpener(tester, targetType: 'asset', targetName: 'front.jpg');

    // access 选项存在但禁用
    final accessTile =
        tester.widget<RadioListTile<String>>(find.byWidgetPredicate(
            (w) => w is RadioListTile<String> && w.value == 'access'));
    expect(accessTile.enabled, isFalse, reason: 'asset 目标 access 禁选(web 同款)');
    final downloadTile =
        tester.widget<RadioListTile<String>>(find.byWidgetPredicate(
            (w) => w is RadioListTile<String> && w.value == 'download'));
    expect(downloadTile.enabled ?? true, isTrue);
    // 有效期预设区渲染(1 小时档在位)
    expect(find.text('1 小时'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '太短');
    await tester.tap(find.text('提交申请'));
    await tester.pump(); // SnackBar 进场
    expect(find.text('理由至少 4 个字'), findsOneWidget);
    expect(api.approvals.calls, isEmpty, reason: '前端拦截,不发请求');
  });

  testWidgets('asset 目标提交:action=download + duration_seconds=3600 + reason',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    await _pumpOpener(tester,
        targetType: 'asset', targetId: 'a1', targetName: 'front.jpg');
    await tester.enterText(find.byType(TextField), '需要导出给设计部修图使用');
    await tester.tap(find.text('提交申请'));
    await tester.pumpAndSettle();
    final call = api.approvals.calls.single;
    expect(call.targetType, 'asset');
    expect(call.targetId, 'a1');
    expect(call.action, 'download');
    expect(call.durationSeconds, 3600);
    expect(call.reason, '需要导出给设计部修图使用');
    expect(find.text('申请已提交'), findsOneWidget);
  });

  testWidgets('sensitive_folder 目标:access 默认可选且不携 duration_seconds',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    await _pumpOpener(tester,
        targetType: 'sensitive_folder', targetId: 'sf1', targetName: '敏感档案');
    // access 为默认动作(sensitive 首个可选),有效期区不渲染
    expect(find.text('有效期'), findsNothing);
    await tester.enterText(find.byType(TextField), '申请进入敏感目录整理档案');
    await tester.tap(find.text('提交申请'));
    await tester.pumpAndSettle();
    final call = api.approvals.calls.single;
    expect(call.action, 'access');
    expect(call.durationSeconds, isNull, reason: 'access=永久,不携时长');
  });

  testWidgets('后端 422:detail 透传展示(前端已过校验时兜底)', (tester) async {
    final api = installFakeApi();
    api.approvals.staged = ApiException(
        422, 'body.reason: String should have at least 4 characters');
    addTearDown(() => session.api = null);
    await _pumpOpener(tester, targetType: 'asset', targetName: 'front.jpg');
    await tester.enterText(find.byType(TextField), '合法理由四个字');
    await tester.tap(find.text('提交申请'));
    await tester.pumpAndSettle();
    expect(find.textContaining('body.reason'), findsOneWidget,
        reason: '422 detail 透传');
    expect(find.text('提交申请'), findsOneWidget, reason: '失败停留表单');
  });
}
