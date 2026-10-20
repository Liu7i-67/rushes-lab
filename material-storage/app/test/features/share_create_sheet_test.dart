/// 分享 sheet 单测(B5 测试功能点 1):有效期四档=web ShareModal TTL_OPTIONS
/// 实况(1 小时/24 小时/7 天/30 天,默认 24 小时);requires_login 恒 true、
/// 无提取码/下载开关(经 FakeShareApi 记录入参;wire 级请求体断言见
/// core/asset_ops_api_test);创建后复制链接到剪贴板。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/api/share_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/share/share_create_sheet.dart';

import '../helpers/api_harness.dart';

Future<void> _pumpOpener(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: FilledButton(
            onPressed: () => showShareSheet(ctx,
                kind: 'asset', targetId: 'a1', targetLabel: 'front.jpg'),
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
  testWidgets('TTL_OPTIONS 四档=web 实况(1 小时/24 小时/7 天/30 天),默认 24 小时',
      (tester) async {
    expect(ShareApi.ttlOptions, [
      ('1 小时', 3600),
      ('24 小时', 86400),
      ('7 天', 7 * 86400),
      ('30 天', 30 * 86400),
    ]);
    installFakeApi();
    addTearDown(() => session.api = null);
    await _pumpOpener(tester);
    for (final label in ['1 小时', '24 小时', '7 天', '30 天']) {
      expect(find.text(label), findsOneWidget);
    }
    final radios =
        tester.widgetList<RadioListTile<int>>(find.byType(RadioListTile<int>));
    expect(radios.length, 4);
    // 无提取码/下载开关表单项(ShareCreateIn 无此字段)
    expect(find.textContaining('提取码'), findsNothing);
    expect(find.textContaining('允许下载'), findsNothing);
  });

  testWidgets('创建分享:默认档 expires_in_seconds=86400(asset 端点);'
      '结果态展示 landing_url/有效期', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    await _pumpOpener(tester);
    await tester.tap(find.text('生成分享链接'));
    await tester.pumpAndSettle();
    expect(api.share.calls, hasLength(1));
    final call = api.share.calls.single;
    expect(call.kind, 'asset');
    expect(call.id, 'a1');
    expect(call.expiresInSeconds, 86400);
    expect(find.textContaining('https://ms.test/s/tok'), findsOneWidget);
    expect(find.textContaining('有效期至'), findsOneWidget);
    expect(find.text('访问需登录:收件人打开链接后用本地账号登录即可访问。'),
        findsOneWidget);
  });

  testWidgets('切 30 天档 → expires_in_seconds=2592000;复制链接进剪贴板',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);

    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard =
            (call.arguments as Map<String, dynamic>)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await _pumpOpener(tester);
    await tester.tap(find.text('30 天'));
    await tester.pump();
    await tester.tap(find.text('生成分享链接'));
    await tester.pumpAndSettle();
    expect(api.share.calls.single.expiresInSeconds, 30 * 86400);

    await tester.tap(find.text('复制链接'));
    await tester.pump();
    expect(clipboard, 'https://ms.test/s/tok');
    expect(find.text('链接已复制'), findsOneWidget);
  });

  testWidgets('403 detail 透传(无 can_download 时分享被后端拒绝),停留表单态',
      (tester) async {
    final api = installFakeApi();
    api.share.staged =
        ApiException(403, 'no permission to share(需 can_download)');
    addTearDown(() => session.api = null);
    await _pumpOpener(tester);
    await tester.tap(find.text('生成分享链接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no permission to share'), findsOneWidget);
    expect(find.text('生成分享链接'), findsOneWidget, reason: '失败停留表单态(按钮恢复可点)');
  });

  testWidgets('folder 分享走 share_folder 入口(同表单,标题区分文件/文件夹)',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showShareSheet(ctx,
                  kind: 'folder', targetId: 'f1', targetLabel: '档案夹'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('分享文件夹'), findsOneWidget);
    await tester.tap(find.text('生成分享链接'));
    await tester.pumpAndSettle();
    expect(api.share.calls.single.kind, 'folder');
  });
}
