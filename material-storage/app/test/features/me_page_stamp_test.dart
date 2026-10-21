/// P6 我的页构建 stamp 单测:buildStampLabel 纯函数文案(注入/空);
/// 测试环境 stamp 恒空(未注入)→ 页面不渲染「构建」行(空 stamp 不显示契约)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/me/me_page.dart';
import 'package:ms_app/main.dart' show kAppBuildStamp;

void main() {
  group('buildStampLabel(P6 stamp 迁移文案)', () {
    test('注入 stamp → 「构建 <stamp>」', () {
      expect(buildStampLabel('2026-10-21 14:15'), '构建 2026-10-21 14:15');
    });

    test('空 stamp → null(整行不渲染)', () {
      expect(buildStampLabel(''), isNull);
    });
  });

  testWidgets('测试环境 stamp 恒空 → 我的页不渲染「构建」小字行', (tester) async {
    expect(kAppBuildStamp, '', reason: 'flutter test 未注入 dart-define');
    await tester.pumpWidget(const MaterialApp(home: MePage()));
    await tester.pump();
    expect(find.textContaining('构建 '), findsNothing);
    // 账号信息区仍正常
    expect(find.text('(未登录)'), findsOneWidget);
  });
}
