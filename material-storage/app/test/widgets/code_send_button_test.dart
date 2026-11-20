/// CodeSendButton 倒计时状态机(phone-bind 批,§7.4):FakeAsync 区
/// tester.pump(Duration) 即可控制 Timer.periodic(等同注入时钟):
/// - 空闲可点;start(seconds) → 禁点并逐秒递减;归零自动回可点态;
/// - start(<=0) 忽略(「无 retry_after 不启动倒计时」钉子的组件侧守卫);
/// - reset() 立即回可点态;busy(请求在途)禁点。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/components/code_send_button.dart';

void main() {
  final taps = <int>[];
  late CodeSendButtonState state;

  Future<void> pumpButton(WidgetTester tester) async {
    taps.clear(); // 用例间互不污染(用例内自增断言)
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodeSendButton(
            key: const Key('send'),
            onPressed: () => taps.add(taps.length),
          ),
        ),
      ),
    );
    state = tester.state<CodeSendButtonState>(find.byType(CodeSendButton));
  }

  OutlinedButton buttonOf(WidgetTester tester) =>
      tester.widget<OutlinedButton>(find.byType(OutlinedButton));

  testWidgets('空闲可点;点击记录 onPressed', (tester) async {
    await pumpButton(tester);
    expect(find.text('获取验证码'), findsOneWidget);
    expect(buttonOf(tester).onPressed, isNotNull);
    expect(state.counting, isFalse);
    await tester.tap(find.byType(OutlinedButton));
    expect(taps, [0]);
  });

  testWidgets('start(120) → 禁点倒计时;逐秒递减;归零回可点态', (tester) async {
    await pumpButton(tester);
    state.start(120);
    await tester.pump();
    expect(state.counting, isTrue);
    expect(find.text('重新获取(120s)'), findsOneWidget);
    expect(buttonOf(tester).onPressed, isNull, reason: '倒计时内禁点');

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('重新获取(119s)'), findsOneWidget);

    // 推进到归零(剩 119s + 本拍):Timer.periodic 逐拍触发
    await tester.pump(const Duration(seconds: 119));
    expect(find.text('重新获取(0s)'), findsNothing);
    expect(state.counting, isFalse, reason: '递减到 0 自动停表');
    expect(buttonOf(tester).onPressed, isNotNull, reason: '归零回可点态');
    expect(find.text('获取验证码'), findsOneWidget);

    await tester.tap(find.byType(OutlinedButton));
    expect(taps.length, 1, reason: '回可点态后可再点(taps 用例内清零)');
  });

  testWidgets('start(0)/start(-5) 忽略:不启动倒计时(组件侧守卫钉子)', (tester) async {
    await pumpButton(tester);
    state.start(0);
    state.start(-5);
    await tester.pump();
    expect(state.counting, isFalse);
    expect(buttonOf(tester).onPressed, isNotNull);
  });

  testWidgets('reset() 立即回可点态', (tester) async {
    await pumpButton(tester);
    state.start(60);
    await tester.pump();
    expect(find.text('重新获取(60s)'), findsOneWidget);
    state.reset();
    await tester.pump();
    expect(state.counting, isFalse);
    expect(find.text('获取验证码'), findsOneWidget);
    expect(buttonOf(tester).onPressed, isNotNull);
  });

  testWidgets('busy(请求在途)禁点;busy 解除恢复', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CodeSendButton(onPressed: () {}, busy: true)),
      ),
    );
    expect(buttonOf(tester).onPressed, isNull);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CodeSendButton(onPressed: () {})),
      ),
    );
    expect(buttonOf(tester).onPressed, isNotNull);
  });
}
