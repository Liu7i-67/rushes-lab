/// P1 预览页底部操作栏避开虚拟导航栏单测(target-behavior 锁:实现落地前
/// SafeArea 断言会红——实现于 preview_actions.dart:外层带色 Container 内包
/// `SafeArea(top: false)`,内容 Row padding 不变 EdgeInsets.fromLTRB(16,4,16,8))。
/// 用注入 bottom MediaQuery padding 模拟 Android 虚拟导航栏,验证:
/// - PreviewActions 子树存在 SafeArea 结构;
/// - 三钮文字底边不被 40px 底部安全区吞掉(完整可见可点);
/// - 无底部安全区(padding=0)时三钮齐全可点、点按照常(视觉不回退)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/preview/preview_actions.dart';
import 'package:ms_app/theme/tokens.dart';

/// 测试窗高 600;注入的虚拟导航栏高度
const _navBarHeight = 40.0;
const _windowHeight = 600.0;

Future<void> pumpActions(
  WidgetTester tester, {
  required double bottomPadding,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(padding: EdgeInsets.only(bottom: bottomPadding)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: PreviewActions(
              canDownload: true,
              onDownload: () {},
              onShare: () {},
              onRequest: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('有虚拟导航栏(bottom padding 40):SafeArea 结构存在,三钮不被遮挡', (tester) async {
    await pumpActions(tester, bottomPadding: _navBarHeight);

    // 结构:SafeArea(top:false) 在 PreviewActions 子树内
    expect(
      find.descendant(
        of: find.byType(PreviewActions),
        matching: find.byType(SafeArea),
      ),
      findsOneWidget,
      reason: 'P1:操作栏经 SafeArea 避开虚拟导航栏',
    );

    // 几何:三钮文字底边必须落在安全区之上(否则被虚拟按键压住不可点)
    for (final label in ['下载', '分享', '申请权限']) {
      final rect = tester.getRect(find.text(label));
      expect(
        rect.bottom,
        lessThanOrEqualTo(_windowHeight - _navBarHeight),
        reason: '「$label」须完整落在虚拟导航栏之上(bottom=${rect.bottom})',
      );
    }

    // 视觉:操作栏底色 previewSurface(背景延伸进导航栏区域不露底色)
    expect(
      find.byWidgetPredicate(
        (w) => w is Container && w.color == Tk.previewSurface,
      ),
      findsWidgets,
    );
  });

  testWidgets('无虚拟导航栏(padding=0):三钮齐全可点,点按照常(回归)', (tester) async {
    var downloads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: PreviewActions(
              canDownload: true,
              onDownload: () => downloads++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('下载'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('申请权限'), findsOneWidget);
    await tester.tap(find.text('下载'));
    expect(downloads, 1, reason: 'padding=0 时点按照常触发');
  });
}
