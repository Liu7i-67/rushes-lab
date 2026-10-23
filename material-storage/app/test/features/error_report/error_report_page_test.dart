/// 报错页单测(feat/app-error-page 测试功能点 7-10):四要素与 stackText
/// 两态渲染、复制文本含全字段 + CopyButton、推送日志成功/失败两路径
/// (HttpOverrides 桩掉 WeComPush 的 Dio 传输层,全程无真实 socket)、
/// 关闭 pop 栈深减一。
///
/// 页面从 errorReporter.currentError 取首条错误(生产由 controller push 前
/// 写入);用例末尾手动卸载页面并推进 3s 冷却窗,避免 pending timer 断言。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/error_report/error_info.dart';
import 'package:ms_app/core/error_report/error_report_controller.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/error_report/error_report_page.dart';
import 'package:ms_app/features/error_report/error_report_sections.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/widgets/copy_button.dart';

// ── WeComPush 传输层桩:按企微两步端点回 JSON,不发真实请求 ─────────────────

bool _failSend = false;

class _StubClient implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _StubRequest(url.path.contains('upload_media'));

  @override
  set connectionTimeout(Duration? _) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _StubRequest implements HttpClientRequest {
  _StubRequest(this._upload);

  final bool _upload;

  @override
  final HttpHeaders headers = _StubHeaders();

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<HttpClientResponse> close() async => _StubResponse(
    _upload
        ? '{"errcode":0,"media_id":"MID_TEST"}'
        : _failSend
        ? '{"errcode":93000,"errmsg":"invalid webhook url"}'
        : '{"errcode":0,"errmsg":"ok"}',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _StubHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void forEach(void Function(String name, List<String> values) action) {
    action(HttpHeaders.contentTypeHeader, const [
      'application/json; charset=utf-8',
    ]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _StubResponse extends Stream<List<int>> implements HttpClientResponse {
  _StubResponse(this._body);

  final String _body;
  final HttpHeaders _headers = _StubHeaders();

  @override
  int get statusCode => 200;

  @override
  HttpHeaders get headers => _headers;

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  String get reasonPhrase => 'OK';

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(utf8.encode(_body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// ── 夹具 ───────────────────────────────────────────────────────────────────

ErrorInfo _info({String? stackText}) => ErrorInfo(
  kind: ErrorKind.api,
  time: DateTime(2026, 10, 23, 12, 34, 56),
  source: 'GET /api/v1/projects',
  status: 500,
  message: '项目列表加载失败',
  stackText: stackText,
);

Future<void> _pumpPage(
  WidgetTester tester,
  ErrorInfo? info, {
  Brightness brightness = Brightness.light,
}) async {
  errorReporter.currentError = info;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness),
      home: ErrorReportPage(key: UniqueKey()),
    ),
  );
  await tester.pumpAndSettle();
}

/// 卸载页面触发 dispose(markOnPage(false) 起 3s 冷却 Timer)并推进过期。
Future<void> _disposePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 4));
  errorReporter.reset();
}

/// 推送链路含真实文件 IO(F10 dumpFile):runAsync 与 pump 交替推进。
Future<void> _flushPush(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
    if (find.textContaining('推送成功').evaluate().isNotEmpty ||
        find.textContaining('推送失败').evaluate().isNotEmpty) {
      return;
    }
  }
}

Future<void> _stubZone(WidgetTester tester, Future<void> Function() body) =>
    HttpOverrides.runZoned(
      body,
      createHttpClient: (SecurityContext? _) => _StubClient(),
    );

void main() {
  setUp(() {
    _failSend = false;
    session.me = null;
    errorReporter.reset();
  });

  tearDown(() {
    session.me = null;
    errorReporter.reset();
  });

  testWidgets('功能点7:四要素可见,stackText 有态展示堆栈', (tester) async {
    await _pumpPage(tester, _info(stackText: '#0 main.dart 42'));
    expect(find.text('接口异常'), findsOneWidget, reason: '类型');
    expect(find.text('2026-10-23 12:34:56'), findsOneWidget, reason: '发生时间');
    expect(find.text('GET /api/v1/projects'), findsOneWidget, reason: '来源');
    expect(find.text('500'), findsOneWidget, reason: 'HTTP 状态码');
    expect(find.text('项目列表加载失败'), findsOneWidget, reason: 'message');
    // 堆栈区在详情卡之下(ListView 懒构建):上滑后断言
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('堆栈信息'), findsOneWidget);
    expect(find.textContaining('#0 main.dart 42'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _disposePage(tester);
  });

  testWidgets('功能点7:stackText 缺失无堆栈区;系统异常无状态码行', (tester) async {
    await _pumpPage(tester, _info());
    expect(find.text('项目列表加载失败'), findsOneWidget);
    expect(find.text('堆栈信息'), findsNothing, reason: '无 stackText 不渲染堆栈区');
    expect(find.text('HTTP 状态码'), findsOneWidget);

    await _pumpPage(
      tester,
      ErrorInfo(
        kind: ErrorKind.system,
        time: DateTime(2026, 10, 23, 9, 5, 1),
        source: 'flutter',
        message: 'RenderFlex overflowed',
        stackText: '#0 build',
      ),
    );
    expect(find.text('系统异常'), findsOneWidget);
    expect(find.text('flutter'), findsOneWidget);
    expect(find.text('HTTP 状态码'), findsNothing, reason: '系统异常无状态码');
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('堆栈信息'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _disposePage(tester);
  });

  testWidgets('功能点8:CopyButton 存在,文本含时间/类型/来源/状态码/详情/堆栈', (tester) async {
    final info = _info(stackText: '#0 main.dart 42');
    await _pumpPage(tester, info);
    expect(find.text('复制诊断'), findsOneWidget);
    final copy = tester.widget<CopyButton>(find.byType(CopyButton));
    for (final part in [
      '2026-10-23 12:34:56',
      '接口异常',
      'GET /api/v1/projects',
      '500',
      '项目列表加载失败',
      '#0 main.dart 42',
    ]) {
      expect(copy.text, contains(part), reason: '复制文本缺字段:$part');
    }
    expect(copy.text, info.toClipboardText());
    await _disposePage(tester);
  });

  testWidgets(
    '功能点9/10:推送日志成功 → 就地展示成功文案',
    (tester) => _stubZone(tester, () async {
      await _pumpPage(tester, _info());
      await tester.tap(find.text('推送日志'));
      await tester.pump();
      expect(find.text('推送中…'), findsOneWidget, reason: '推送中按钮态');
      await _flushPush(tester);
      expect(find.textContaining('推送成功'), findsOneWidget);
      expect(find.textContaining('推送失败'), findsNothing);
      expect(tester.takeException(), isNull);
      await _disposePage(tester);
    }),
  );

  testWidgets(
    '功能点9/11:推送失败就地提示,不触发新跳转,可重试',
    (tester) => _stubZone(tester, () async {
      _failSend = true;
      final info = _info();
      await _pumpPage(tester, info);
      await tester.tap(find.text('推送日志'));
      await tester.pump();
      await _flushPush(tester);
      expect(find.textContaining('推送失败'), findsOneWidget);
      expect(find.textContaining('本地日志保留'), findsOneWidget, reason: '失败不清日志');
      expect(find.text('推送日志'), findsOneWidget, reason: '按钮恢复可重试');
      expect(errorReporter.currentError, same(info), reason: '不产生新的错误上报');
      expect(
        tester.state<NavigatorState>(find.byType(Navigator)).canPop(),
        isFalse,
        reason: '推送失败不 push 新路由/弹窗',
      );
      await _disposePage(tester);
    }),
  );

  testWidgets('堆栈区:等宽 12、surface2 底、独立可滚动', (tester) async {
    final stack = List.generate(80, (i) => '#$i 帧 stack line').join('\n');
    await _pumpPage(tester, _info(stackText: stack));
    // ListView 懒构建:先滑到堆栈区
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.byType(ErrorStackCard), findsOneWidget);

    final scroll = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: find.byType(ErrorStackCard),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    expect(scroll.scrollDirection, Axis.vertical, reason: '堆栈独立滚动');
    final text = tester.widget<SelectableText>(
      find.descendant(
        of: find.byType(ErrorStackCard),
        matching: find.byType(SelectableText),
      ),
    );
    expect(text.style?.fontSize, 12);
    expect(text.style?.fontFamily, 'monospace');

    // 拖动滚动不抛异常(整页仍可滚动)
    await tester.drag(find.byType(ErrorStackCard), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _disposePage(tester);
  });

  testWidgets('双主题渲染不抛:Scaffold 背景随主题', (tester) async {
    for (final brightness in Brightness.values) {
      await _pumpPage(
        tester,
        _info(stackText: '#0 main.dart 42'),
        brightness: brightness,
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        TkColors.of(brightness).bg,
      );
      expect(find.text('应用错误'), findsOneWidget);
      expect(find.text('复制诊断'), findsOneWidget);
      expect(find.text('推送日志'), findsOneWidget);
    }
    await _disposePage(tester);
  });

  testWidgets('功能点10:返回与底部关闭均 pop,栈深减一', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(body: Text('host')),
      ),
    );
    expect(nav.currentState!.canPop(), isFalse);

    for (final close in [
      find.byIcon(Icons.arrow_back_ios_new),
      find.text('关闭'),
    ]) {
      errorReporter.currentError = _info();
      nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const ErrorReportPage()),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ErrorReportPage), findsOneWidget);
      expect(nav.currentState!.canPop(), isTrue, reason: '报错页在栈上');

      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byType(ErrorReportPage), findsNothing);
      expect(find.text('host'), findsOneWidget);
      expect(nav.currentState!.canPop(), isFalse, reason: 'pop 后栈深减一,保留原页面栈');
    }
    await _disposePage(tester);
  });

  testWidgets('320 宽 + 字号 1.3 无 overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    errorReporter.currentError = _info(stackText: '#0 main.dart 42');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: const ErrorReportPage(),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('应用错误'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    await _disposePage(tester);
  });
}
