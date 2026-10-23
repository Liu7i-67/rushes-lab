/// P2-1 回归:帧回调 push 后、页面 initState 置位前的窗口期内,第二路错误
/// 不得叠第二层报错页,currentError 保持首条(D2)。窗口期用 NavigatorObserver
/// 计 push 次数,页面探针模拟生产报错页的 markOnPage(true/false) 生命周期。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/error_report/error_report_controller.dart';
import 'package:ms_app/core/session.dart';

void main() {
  testWidgets('P2-1:窗口内第二个错误只 push 一次,currentError 为首条',
      (tester) async {
    final c = ErrorReportController();
    final pushed = <String?>[];
    await tester.pumpWidget(MaterialApp(
      navigatorKey: session.navigatorKey,
      navigatorObservers: [_PushObserver(pushed)],
      home: const Scaffold(body: Text('home')),
      onGenerateRoute: (s) => MaterialPageRoute<void>(
        settings: s,
        builder: (_) => _OnPageProbe(controller: c),
      ),
    ));
    await tester.pumpAndSettle();

    c.onApiError(ApiException(500, '首条'), method: 'GET', path: '/api/v1/x');
    await tester.pump(); // 帧后回调已 push,新页尚未 build(窗口期)
    expect(find.text('on-page'), findsNothing, reason: '仍在窗口期');
    c.onApiError(ApiException(502, '窗口内第二条'),
        method: 'GET', path: '/api/v1/x');
    await tester.pumpAndSettle();

    expect(pushed.where((n) => n == '/error-report'), hasLength(1),
        reason: '窗口内第二错不得叠第二层报错页');
    expect(c.currentError!.message, '首条', reason: 'D2:只展示首条错误');
    expect(find.text('on-page'), findsOneWidget);

    // 页面 initState 已复位标记:关闭(冷却过)后仍可再次跳转,不永久卡死
    session.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 3100));
    c.onApiError(ApiException(503, '第三条'), method: 'GET', path: '/api/v1/x');
    await tester.pumpAndSettle();
    expect(pushed.where((n) => n == '/error-report'), hasLength(2));
    expect(c.currentError!.message, '第三条');

    // 先卸载探针(dispose 会起冷却 Timer)再复位,防 pending timer 断言
    await tester.pumpWidget(const SizedBox());
    c.reset();
  });
}

/// 模拟生产报错页:initState 确认在页(D2),dispose 开冷却(D6)。
class _OnPageProbe extends StatefulWidget {
  const _OnPageProbe({required this.controller});

  final ErrorReportController controller;

  @override
  State<_OnPageProbe> createState() => _OnPageProbeState();
}

class _OnPageProbeState extends State<_OnPageProbe> {
  @override
  void initState() {
    super.initState();
    widget.controller.markOnPage(true);
  }

  @override
  void dispose() {
    widget.controller.markOnPage(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('on-page'));
}

class _PushObserver extends NavigatorObserver {
  _PushObserver(this.pushed);

  final List<String?> pushed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.settings.name);
    super.didPush(route, previousRoute);
  }
}
