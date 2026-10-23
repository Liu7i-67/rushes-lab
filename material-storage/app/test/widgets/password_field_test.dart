/// PasswordField 单测(P9):默认遮挡、眼睛切换明文、切换后已输入内容保持、
/// 再次切换恢复遮挡;validator/onSubmitted 透传。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/widgets/password_field.dart';

void main() {
  Widget host(
    TextEditingController controller, {
    String? Function(String?)? validator,
    ValueChanged<String>? onSubmitted,
  }) => MaterialApp(
    home: Scaffold(
      body: PasswordField(
        controller: controller,
        labelText: '密码',
        prefixIcon: const Icon(Icons.lock_outline),
        validator: validator,
        onSubmitted: onSubmitted,
      ),
    ),
  );

  /// suffixIcon 里的眼睛 IconButton 图标(suffixIcon 只有一个 Icon)。
  Icon eyeIcon(WidgetTester tester) => tester.widget<Icon>(
    find.descendant(
      of: find.byType(TextField),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Icon &&
            (w.icon == Icons.visibility_outlined ||
                w.icon == Icons.visibility_off_outlined),
      ),
    ),
  );

  testWidgets('默认遮挡;眼睛切换明文后内容保持,再切回遮挡', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(host(controller));
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue, reason: '默认遮挡');

    await tester.enterText(find.byType(TextField), 'secret123');
    expect(controller.text, 'secret123');

    // 遮挡态显示 visibility_outlined(点击亮文),眼睛图标 ink3
    expect(eyeIcon(tester).icon, Icons.visibility_outlined);
    expect(eyeIcon(tester).color, TkColors.light.ink3, reason: '眼睛图标 ink3');
    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isFalse,
      reason: '切换后明文',
    );
    expect(controller.text, 'secret123', reason: '已输入内容不丢');
    expect(eyeIcon(tester).icon, Icons.visibility_off_outlined);

    // 再切回遮挡
    await tester.tap(find.byIcon(Icons.visibility_off_outlined));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isTrue,
    );
    expect(controller.text, 'secret123');
  });

  testWidgets('切换遮挡不丢焦点(焦点保持)', (tester) async {
    await tester.pumpWidget(host(TextEditingController()));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue, reason: '聚焦中');

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue, reason: '点眼睛后焦点仍在字段');

    await tester.enterText(find.byType(TextField), 'ab');
    expect(find.widgetWithText(TextField, 'ab'), findsOneWidget);
  });

  testWidgets('onSubmitted 透传', (tester) async {
    var submitted = '';
    final controller = TextEditingController();
    await tester.pumpWidget(
      host(controller, onSubmitted: (v) => submitted = v),
    );
    await tester.enterText(find.byType(TextField), 'pw');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, 'pw');
  });
}
