/// B0① 绑定页状态机单测:授权码一次性清空(提交无论成败即清)、
/// 成功/失败/过期文案分明、失败可重走、开关关闭提示「网盘备份未启用」、
/// 5xx 错误态展示后端中文 detail(勿裸渲染原始异常对象)。
/// 走真实 BaiduApi,dio 层替换 FakeAdapter(widget test 禁真实 socket);
/// 响应体对齐 api/app/routers/baidu_backup.py 契约。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/baidu_api.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/features/baidu/bind_code_page.dart';
import 'package:ms_app/widgets/badge.dart' as app_badge;

/// 非 null 时 authorize-url 直接回该状态码(对齐后端 503=凭证未配置)
int? forceAuthorizeStatus;

/// 按 path+method 返回契约响应;记录 binding 请求体供断言。
class _FakeBaiduAdapter implements HttpClientAdapter {
  String? lastBindCode;
  Set<String>? lastBindBodyKeys;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bodyText = await (requestStream ?? const Stream<Uint8List>.empty())
        .cast<List<int>>()
        .transform(utf8.decoder)
        .join();
    Map<String, dynamic> body = const {};
    if (bodyText.isNotEmpty) {
      body = jsonDecode(bodyText) as Map<String, dynamic>;
    }

    ResponseBody ok(Object data, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

    final path = options.uri.path;
    if (path == '/api/v1/baidu/backup/binding/authorize-url') {
      if (forceAuthorizeStatus != null) {
        return ok(const {
          'detail': '百度应用凭证未配置(BAIDU_APP_KEY/BAIDU_APP_SECRET),无法绑定',
        }, forceAuthorizeStatus!);
      }
      return ok({
        'url':
            'https://openapi.baidu.com/oauth/2.0/authorize'
            '?client_id=abc&redirect_uri=oob',
      });
    }
    if (path == '/api/v1/baidu/backup/binding') {
      if (options.method == 'GET') {
        return ok({'bound': false, 'status': 'unbound'});
      }
      lastBindCode = body['code'] as String?;
      lastBindBodyKeys = body.keys.toSet();
      if (lastBindCode == 'GOODCODE') {
        return ok({
          'bound': true,
          'status': 'active',
          'expires_at': '2026-10-20T12:00:00Z',
          'baidu_uid': 'uid-9',
          'nickname': '测试盘',
        });
      }
      return ok(const {'detail': '授权码无效或已过期,请重新获取授权码后再试(授权码 10 分钟内单次有效)'}, 400);
    }
    return ok(const {'detail': 'no route'}, 404);
  }
}

void main() {
  late _FakeBaiduAdapter adapter;
  late BaiduApi api;

  setUp(() {
    adapter = _FakeBaiduAdapter();
    final msApi = MsApi(baseUrl: 'http://mock.local');
    msApi.http.httpClientAdapter = adapter;
    api = BaiduApi(msApi);
  });

  Future<void> pumpPage(WidgetTester tester, {bool enabled = true}) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: BindCodePage(api: api, enabled: enabled),
      ),
    );
    await tester.pumpAndSettle();
  }

  TextField codeField(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField));

  testWidgets('开关关闭 → 「网盘备份未启用」提示,流程不渲染', (tester) async {
    await pumpPage(tester, enabled: false);
    expect(find.text('网盘备份未启用'), findsOneWidget);
    expect(find.text('生成授权链接'), findsNothing);
  });

  testWidgets('生成链接 → 展示授权链接与步骤引导', (tester) async {
    await pumpPage(tester);
    expect(find.text('绑定百度网盘账号'), findsOneWidget);
    expect(find.text('通过授权码完成一次绑定'), findsOneWidget);
    expect(find.textContaining('当前未绑定'), findsOneWidget);
    await tester.tap(find.text('生成授权链接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('openapi.baidu.com'), findsOneWidget);
    expect(find.text('复制链接'), findsOneWidget);
    expect(find.text('浏览器打开'), findsOneWidget);
    expect(find.textContaining('单次有效约 10 分钟'), findsOneWidget);
    // 步骤徽标金:步骤 1 完成态 + 步骤 2 待输入
    expect(
      tester
          .widget<app_badge.Badge>(
            find.widgetWithText(app_badge.Badge, '步骤 1 / 2'),
          )
          .tone,
      app_badge.BadgeTone.gold,
    );
    expect(find.text('步骤 2 / 2'), findsOneWidget);
  });

  testWidgets('提交成功:请求体恰为 {code};输入态清空 + 成功文案 + 状态行更新', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('生成授权链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'GOODCODE');
    await tester.tap(find.text('绑定'));
    await tester.pumpAndSettle();
    expect(adapter.lastBindCode, 'GOODCODE');
    expect(adapter.lastBindBodyKeys, {'code'});
    // 成功后回步骤 0:输入卡片收起(授权码已消费,重绑需重新生成链接)
    expect(
      find.byType(TextField),
      findsNothing,
      reason: '输入态一次性消费:成功后输入卡片不再呈现',
    );
    expect(find.textContaining('绑定成功'), findsOneWidget);
    expect(find.textContaining('当前已绑定'), findsOneWidget);
  });

  testWidgets('提交失败(400 过期):输入态同样清空 + 过期文案分明 + 可重走', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('生成授权链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'BADCODE');
    await tester.tap(find.text('绑定'));
    await tester.pumpAndSettle();
    expect(adapter.lastBindCode, 'BADCODE');
    expect(codeField(tester).controller!.text, '', reason: '失败也清输入态');
    expect(find.textContaining('授权码无效或已过期'), findsOneWidget);
    expect(find.text('重新生成链接'), findsOneWidget, reason: '失败给重走入口');
    // 可重走:链接仍在,输入框可再填
    expect(find.textContaining('openapi.baidu.com'), findsOneWidget);
    expect(codeField(tester).enabled, isTrue);
  });

  testWidgets('空码提交:仅警示,不发起绑定', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('生成授权链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('绑定'));
    await tester.pumpAndSettle();
    expect(find.text('请先粘贴授权码'), findsOneWidget);
    expect(adapter.lastBindCode, isNull);
    expect(codeField(tester).controller!.text, '');
  });

  testWidgets('生成链接遇 503:展示后端中文 detail,不裸渲染 DioException(P1-1)', (
    tester,
  ) async {
    forceAuthorizeStatus = 503;
    addTearDown(() => forceAuthorizeStatus = null);
    await pumpPage(tester);
    await tester.tap(find.text('生成授权链接'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('百度应用凭证未配置'),
      findsOneWidget,
      reason: '后端中文 detail 透传',
    );
    expect(
      find.textContaining('DioException'),
      findsNothing,
      reason: '勿渲染原始异常对象',
    );
    expect(find.textContaining('Exception'), findsNothing);
    // 失败态可重走:按钮恢复可点,输入卡片未展开
    expect(find.text('生成授权链接'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
