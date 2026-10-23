/// 全局错误上报控制器单测(feat/app-error-page 测试功能点 1-6):
/// 门槛(5xx/网络异常上报;4xx/401/badResponse 不上报)、D5 debug/release
/// 分流、防套娃(在页忽略)、关闭后 3s 冷却窗、build 期帧后调度、
/// install 链式转发 previous。
///
/// 导航走 session.navigatorKey(与生产同款),测试内注册 `/error-report`
/// 占位页;每个用例用独立 ErrorReportController 实例 + 末尾 reset,
/// 避免 flutter_test 的 pending timer 断言。
library;

import 'dart:ui' show PlatformDispatcher;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/error_report/error_info.dart';
import 'package:ms_app/core/error_report/error_report_controller.dart';
import 'package:ms_app/core/session.dart';

void main() {
  late void Function(FlutterErrorDetails)? savedFlutter;
  late bool Function(Object, StackTrace)? savedZone;

  setUp(() {
    savedFlutter = FlutterError.onError;
    savedZone = PlatformDispatcher.instance.onError;
  });

  tearDown(() {
    FlutterError.onError = savedFlutter;
    PlatformDispatcher.instance.onError = savedZone;
  });

  Route<void>? errorRoute(RouteSettings s) => MaterialPageRoute<void>(
        settings: s,
        builder: (_) => const Scaffold(body: Text('error-page')),
      );

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: session.navigatorKey,
      home: const Scaffold(body: Text('home')),
      onGenerateRoute: errorRoute,
    ));
    await tester.pumpAndSettle();
  }

  DioException netError(DioExceptionType type, {int? status}) => DioException(
        requestOptions: RequestOptions(path: '/api/v1/probe'),
        type: type,
        message: type == DioExceptionType.connectionTimeout ? '连接超时' : null,
        response: status == null
            ? null
            : Response<void>(
                requestOptions: RequestOptions(path: '/api/v1/probe'),
                statusCode: status,
              ),
      );

  testWidgets('功能点1:5xx 上报并跳转;4xx/401 不上报(D1)', (tester) async {
    final c = ErrorReportController();
    await pumpHost(tester);

    c.onApiError(ApiException(404, '不存在'), method: 'GET', path: '/api/v1/x');
    c.onApiError(ApiException(401, '未认证'),
        method: 'GET', path: '/api/v1/x');
    await tester.pumpAndSettle();
    expect(c.currentError, isNull,
        reason: '4xx 保持就地 toast;401 走既有跳登录,均不进报错页');
    expect(find.text('error-page'), findsNothing);

    c.onApiError(ApiException(500, '服务暂不可用'),
        method: 'GET', path: '/api/v1/x');
    await tester.pumpAndSettle();
    expect(c.currentError, isNotNull);
    expect(c.currentError!.kind, ErrorKind.api);
    expect(c.currentError!.status, 500);
    expect(c.currentError!.source, 'GET /api/v1/x');
    expect(c.currentError!.message, '服务暂不可用');
    expect(find.text('error-page'), findsOneWidget, reason: '5xx 跳转报错页');
  });

  testWidgets('功能点1:网络异常上报;badResponse 型不上报', (tester) async {
    final c = ErrorReportController();
    await pumpHost(tester);

    c.onNetworkError(netError(DioExceptionType.badResponse, status: 502),
        method: 'GET', path: '/api/v1/x');
    await tester.pumpAndSettle();
    expect(c.currentError, isNull, reason: 'badResponse 已由 5xx 路径承载,防重复上报');
    expect(find.text('error-page'), findsNothing);

    c.onNetworkError(netError(DioExceptionType.connectionTimeout),
        method: 'GET', path: '/api/v1/x');
    await tester.pumpAndSettle();
    expect(c.currentError, isNotNull);
    expect(c.currentError!.kind, ErrorKind.api);
    expect(c.currentError!.status, isNull);
    expect(c.currentError!.source, 'GET /api/v1/x');
    expect(c.currentError!.message, '连接超时');
    expect(find.text('error-page'), findsOneWidget);
  });

  testWidgets('P1-1:cancel 是正常业务动作,不上报不跳转', (tester) async {
    final c = ErrorReportController();
    await pumpHost(tester);
    c.onNetworkError(netError(DioExceptionType.cancel),
        method: 'GET', path: '/api/v1/x');
    await tester.pumpAndSettle();
    expect(c.currentError, isNull, reason: '取消(防抖换词/传输取消)不是错误');
    expect(find.text('error-page'), findsNothing);
  });

  testWidgets('功能点2 D5:debug 框架异常不跳;API 5xx 照跳;注入 false 后框架异常跳',
      (tester) async {
    await pumpHost(tester);
    final debugC = ErrorReportController()..install(); // 缺省 kDebugMode=true
    debugC.onSystemError(StateError('render-boom'), StackTrace.current, 'render');
    await tester.pumpAndSettle();
    expect(debugC.currentError, isNull, reason: 'debug 框架异常噪声只记 AppLog(D5)');
    expect(find.text('error-page'), findsNothing);

    debugC.onApiError(ApiException(503, 'api-boom'));
    await tester.pumpAndSettle();
    expect(debugC.currentError, isNotNull, reason: 'API 5xx debug+release 都跳(D5)');

    final releaseC = ErrorReportController()..install(debugFrameworkJump: false);
    releaseC.onSystemError(StateError('zone-boom'), StackTrace.current, 'zone');
    await tester.pumpAndSettle();
    expect(releaseC.currentError, isNotNull, reason: '注入翻转=release 行为,框架异常跳转');
    expect(releaseC.currentError!.kind, ErrorKind.system);
    expect(releaseC.currentError!.source, 'zone');
    expect(releaseC.currentError!.stackText, isNotNull);
  });

  testWidgets('功能点3 防套娃:在页期间上报忽略,currentError 与页面栈不变',
      (tester) async {
    final c = ErrorReportController();
    await pumpHost(tester);
    c.onApiError(ApiException(500, '首条'), method: 'POST', path: '/api/v1/x');
    await tester.pumpAndSettle();
    final first = c.currentError;
    expect(first, isNotNull);

    c.markOnPage(true); // 报错页 initState 已置位
    c.onApiError(ApiException(500, '第二条'), method: 'POST', path: '/api/v1/x');
    await tester.pumpAndSettle();
    expect(c.currentError, same(first), reason: '在页新错误不改展示内容(D2)');
    expect(find.text('error-page'), findsOneWidget, reason: '不重复 push');
    c.reset();
  });

  testWidgets('功能点4 冷却窗:关闭后 3s 内不跳,超窗恢复', (tester) async {
    final c = ErrorReportController();
    await pumpHost(tester);
    c.markOnPage(true);
    c.markOnPage(false); // 页面 dispose(关闭/pop)
    c.onApiError(ApiException(500, '冷却中'));
    await tester.pump();
    expect(c.currentError, isNull, reason: '3s 冷却窗内仅记日志(D6)');
    expect(find.text('error-page'), findsNothing);

    // 冷却由 Timer 驱动:假时钟推进 3.1s 后窗口过期
    await tester.pump(const Duration(seconds: 3, milliseconds: 100));
    c.onApiError(ApiException(500, '冷却后'));
    await tester.pumpAndSettle();
    expect(c.currentError, isNotNull, reason: '超窗恢复跳转');
    expect(c.currentError!.message, '冷却后');
    expect(find.text('error-page'), findsOneWidget);
    c.reset();
  });

  testWidgets('功能点5 帧后调度:build 内同步上报不抛,帧后跳转', (tester) async {
    final c = ErrorReportController()..install(debugFrameworkJump: false);
    var fired = false;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: session.navigatorKey,
      onGenerateRoute: errorRoute,
      home: Builder(builder: (_) {
        if (!fired) {
          fired = true;
          c.onSystemError(StateError('boom-in-build'), StackTrace.current, 'render');
        }
        return const Scaffold(body: Text('home'));
      }),
    ));
    expect(fired, isTrue);
    expect(tester.takeException(), isNull,
        reason: '同步 push 会触发 setState during build;帧后调度不得抛');
    await tester.pumpAndSettle();
    expect(find.text('error-page'), findsOneWidget, reason: '下一帧完成跳转');
    expect(c.currentError!.source, 'render');
  });

  testWidgets('功能点6 install 链式:previous 仍被调,PlatformDispatcher 返回值透传',
      (tester) async {
    final flutterCalls = <FlutterErrorDetails>[];
    final zoneCalls = <Object>[];
    final prevFlutter = FlutterError.onError;
    final prevZone = PlatformDispatcher.instance.onError;
    void stubFlutter(FlutterErrorDetails d) => flutterCalls.add(d);
    FlutterError.onError = stubFlutter;
    PlatformDispatcher.instance.onError = (e, st) {
      zoneCalls.add(e);
      return false;
    };
    try {
      final c = ErrorReportController()..install(); // debug 缺省:框架异常只记日志
      expect(identical(FlutterError.onError, stubFlutter), isFalse,
          reason: '已换装为链式钩子');
      final details =
          FlutterErrorDetails(exception: StateError('boom'), library: 'test');
      FlutterError.onError!(details);
      expect(flutterCalls, [details], reason: 'AppLog 等既有兜底不丢');

      final handled = PlatformDispatcher.instance.onError!(
          StateError('zone-boom'), StackTrace.current);
      expect(zoneCalls, hasLength(1));
      expect(handled, isFalse, reason: 'previous 返回值原样透传');
      expect(c.currentError, isNull, reason: 'debug 缺省框架异常只记日志(D5)');
    } finally {
      FlutterError.onError = prevFlutter;
      PlatformDispatcher.instance.onError = prevZone;
    }
  });
}
