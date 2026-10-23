/// P6 我的页构建 stamp 单测 + WP2 版式:buildStampLabel 纯函数文案;
/// 测试环境 stamp 恒空 → 不渲染「构建」行;PageHeader 大标题 27;
/// 分组顺序(协作/网盘与传输/偏好/账号与安全/诊断/关于)与设置入口。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/me/me_page.dart';
import 'package:ms_app/main.dart' show kAppBuildStamp;
import 'package:ms_app/theme/tokens.dart';
import 'package:ms_app/widgets/page_header.dart';

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.dragUntilVisible(
    target,
    find.byType(ListView),
    const Offset(0, -260),
  );
  await tester.pump();
}

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

  testWidgets('PageHeader 大标题「我的」27 号 + 设置入口打开外观面板', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MePage()));
    await tester.pump();

    expect(find.byType(PageHeader), findsOneWidget);
    final title = tester.widget<Text>(
      find.descendant(of: find.byType(PageHeader), matching: find.text('我的')),
    );
    expect(title.style?.fontSize, Tk.fzDisplay);

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('外观'), findsWidgets);
    expect(find.text('跟随系统'), findsOneWidget);

    // 关闭面板(点遮罩)后从「偏好 · 外观」行再次打开
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('外观'));
    await tester.tap(find.byKey(const Key('me_appearance')));
    await tester.pumpAndSettle();
    expect(find.text('浅色'), findsOneWidget, reason: '外观行也可打开面板');
  });

  testWidgets('分组顺序渲染:协作 → 网盘与传输 → 偏好 → 账号与安全 → 诊断 → 关于', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MePage()));
    await tester.pump();
    for (final label in ['协作', '网盘与传输', '偏好', '账号与安全', '诊断', '关于']) {
      if (label == '账号与安全') {
        await _scrollTo(tester, find.text('退出登录'));
      } else {
        await _scrollTo(tester, find.text(label));
      }
      expect(find.text(label), findsOneWidget, reason: '分组「$label」渲染');
      if (label == '账号与安全') {
        expect(find.text('退出登录'), findsOneWidget, reason: '账号与安全内含退出登录');
      }
    }
  });
}
