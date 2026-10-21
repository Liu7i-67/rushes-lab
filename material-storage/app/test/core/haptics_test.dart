/// Haptics 薄封装单测(app-polish A8):四个语义方法对应 HapticFeedback
/// 通道的四个振动类型(mock platform channel 验证调用)。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/haptics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String?>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') calls.add(call.arguments as String?);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('select/light/medium/impact 四挡对号入座', () {
    Haptics.select();
    Haptics.light();
    Haptics.medium();
    Haptics.impact();
    expect(calls, [
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.lightImpact',
      'HapticFeedbackType.mediumImpact',
      'HapticFeedbackType.heavyImpact',
    ]);
  });
}
