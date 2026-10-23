/// 通知中心单测(功能点 2/5):未读金点/kind 徽标/页头未读数/全部已读/
/// 白名单跳转三分支/标已读+红点联动/分页自动加载/空态。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/polling_controller.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/notifications/notifications_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/tk_colors.dart';

import '../helpers/api_harness.dart';

Color? dotColor(WidgetTester tester, Finder finder) =>
    (tester.widget<Container>(finder).decoration! as BoxDecoration).color;

void main() {
  testWidgets('P2-6:整行语义标注未读/已读通知(不只靠颜色区分)', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.notifications.listStaged = NotificationsList(
      items: [notificationOf('n1'), notificationOf('n2', unread: false)],
      total: 2,
      unreadCount: 1,
    );

    await tester.pumpWidget(const MaterialApp(home: NotificationsPage()));
    await tester.pumpAndSettle();

    bool hasLabel(String label) => tester.any(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.button == true &&
            w.properties.label == label,
      ),
    );
    expect(hasLabel('未读通知'), isTrue, reason: '未读行 role/名称可被读屏识别');
    expect(hasLabel('已读通知'), isTrue, reason: '已读行同样有语义标注');
  });

  testWidgets('列表:未读金点+kind 徽标+页头未读数;全部已读调 mark-read all', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.notifications.listStaged = NotificationsList(
      items: [
        notificationOf('n1'),
        notificationOf('n2', kind: 'approval_decided', unread: false),
      ],
      total: 2,
      unreadCount: 1,
    );

    await tester.pumpWidget(const MaterialApp(home: NotificationsPage()));
    await tester.pumpAndSettle();

    expect(find.text('标题n1'), findsOneWidget);
    expect(find.text('审批待办'), findsOneWidget);
    expect(find.text('审批结果'), findsOneWidget);
    // 未读数移到副标题;按钮恒显(全部已读)
    expect(find.text('1 条未读'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '全部已读'), findsOneWidget);

    // 未读金点 8 / gold;已读同宽透明点
    expect(
      dotColor(tester, find.byKey(const ValueKey('notif-dot-n1'))),
      TkColors.light.gold,
    );
    expect(
      dotColor(tester, find.byKey(const ValueKey('notif-dot-n2'))),
      Colors.transparent,
    );

    await tester.tap(find.widgetWithText(TextButton, '全部已读'));
    await tester.pumpAndSettle();
    expect(api.notifications.markReadCalls.single.all, isTrue);
    // 未读清零:副标题与按钮均为「全部已读」,按钮禁用
    expect(find.text('全部已读'), findsNWidgets(2));
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '全部已读'))
          .onPressed,
      isNull,
      reason: '无未读时入口禁用',
    );

    // 空列表:空态文案
    api.notifications.listStaged = NotificationsList(
      items: [],
      total: 0,
      unreadCount: 0,
    );
    await tester.pumpWidget(
      MaterialApp(home: NotificationsPage(key: UniqueKey())),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无通知'), findsOneWidget);
  });

  testWidgets('B9 分页(app-polish E6 改自动加载):滚到底按 offset 追加,不整页替换', (
    tester,
  ) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    var calls = 0;
    api.notifications.onListOverride = ({required limit, required offset}) {
      calls++;
      expect(limit, 100);
      if (offset == 0) {
        return NotificationsList(
          items: [notificationOf('n1'), notificationOf('n2')],
          total: 3,
          unreadCount: 2,
        );
      }
      expect(offset, 2, reason: '加载更多按已拉条数取 offset');
      return NotificationsList(
        items: [notificationOf('n3')],
        total: 3,
        unreadCount: 3,
      );
    };

    await tester.pumpWidget(const MaterialApp(home: NotificationsPage()));
    await tester.pumpAndSettle();
    expect(find.text('标题n1'), findsOneWidget);
    // E6:「加载更多」按钮已移除,改滚动到底自动加载
    expect(find.text('加载更多'), findsNothing);

    // 内容不足一屏(extentAfter=0<200 阈值)也允许首次滚动触发预取
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('标题n3'), findsOneWidget);
    expect(calls, 2, reason: '3/3 已取尽不再发请求');
  });

  testWidgets('白名单 approval_*:点击跳审批中心并标已读(红点即时减一)', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.notifications.listStaged = NotificationsList(
      items: [notificationOf('n1')],
      total: 1,
      unreadCount: 1,
    );
    final poller = UnreadPoller(sessionOverride: Session(), api: api);
    poller.unreadCount = 1; // 模拟全局 badge 现值(我的 tab 红点同源)

    await tester.pumpWidget(
      MaterialApp(
        home: NotificationsPage(poller: poller),
        routes: {
          '/approvals': (_) =>
              Scaffold(appBar: AppBar(title: const Text('审批中心T'))),
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('标题n1'));
    await tester.pumpAndSettle();
    expect(find.text('审批中心T'), findsOneWidget, reason: '审批类跳审批中心');
    expect(api.notifications.markReadCalls.single.ids, ['n1']);
    expect(poller.unreadCount, 0, reason: 'mark-read 成功红点即时更新');
  });

  testWidgets('mark-read 成功后行内未读样式即时消除(P2-1:原地替换,不等重拉)', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.notifications.listStaged = NotificationsList(
      items: [notificationOf('n1')],
      total: 1,
      unreadCount: 1,
    );
    final poller = UnreadPoller(sessionOverride: Session(), api: api);
    poller.unreadCount = 1;

    await tester.pumpWidget(
      MaterialApp(
        home: NotificationsPage(poller: poller),
        routes: {'/approvals': (_) => const Scaffold(body: Text('审批中心T'))},
      ),
    );
    await tester.pumpAndSettle();

    // 未读基线:金点 + 页头「1 条未读」
    expect(find.text('1 条未读'), findsOneWidget);
    expect(
      dotColor(tester, find.byKey(const ValueKey('notif-dot-n1'))),
      TkColors.light.gold,
    );

    await tester.tap(find.text('标题n1'));
    await tester.pumpAndSettle();

    // 页面被推入的审批路由盖住(offstage),skipOffstage 命中原列表结构
    expect(
      dotColor(
        tester,
        find.byKey(const ValueKey('notif-dot-n1'), skipOffstage: false),
      ),
      Colors.transparent,
      reason: '行内未读金点即时消除(原地替换 readAt,无重拉也不复原)',
    );
    // 未读清零:副标题+按钮均为「全部已读」
    expect(
      find.text('全部已读', skipOffstage: false),
      findsNWidgets(2),
      reason: '副标题切换 + 全部已读恒显',
    );
    expect(poller.unreadCount, 0, reason: '全局红点同步减一');
  });

  testWidgets('白名单 folder_invite:link 解析+/projects 反查成功 → 跳对应文件夹页', (
    tester,
  ) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.notifications.listStaged = NotificationsList(
      items: [
        notificationOf(
          'n1',
          kind: 'folder_invite',
          link: 'https://bucket.taoxiplan.com/ms-static/web/projects/p1/folders/f1',
        ),
      ],
      total: 1,
      unreadCount: 1,
    );
    api.projects.listStaged = [
      Project(id: 'p1', name: '项目一', code: 'P1', myRoles: const ['viewer']),
    ];
    Object? foldersArgs;
    await tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: (s) {
          if (s.name == '/folders') foldersArgs = s.arguments;
          return MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('FoldersT')),
          );
        },
        home: const NotificationsPage(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('标题n1'));
    await tester.pumpAndSettle();
    expect(foldersArgs, (
      'p1',
      '项目一',
      const <String>['viewer'],
    ), reason: '跳对应项目/文件夹(名/角色经 /projects 反查)');
    expect(find.text('FoldersT'), findsOneWidget);
  });

  testWidgets('folder_invite 反查失败(link 缺失/项目不可见)→ 通用详情不盲跳', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.notifications.listStaged = NotificationsList(
      items: [notificationOf('n1', kind: 'folder_invite')],
      total: 1,
      unreadCount: 1,
    );
    Object? foldersArgs;
    await tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: (s) {
          if (s.name == '/folders') foldersArgs = s.arguments;
          return MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('FoldersT')),
          );
        },
        home: const NotificationsPage(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题n1'));
    await tester.pumpAndSettle();
    expect(foldersArgs, isNull, reason: '无可跳转字段不盲跳');
    expect(find.text('FoldersT'), findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget, reason: '落通用详情');
  });

  testWidgets('未知 kind:通用详情弹窗,不崩溃、不把任意 URL 交导航器', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.notifications.listStaged = NotificationsList(
      items: [
        notificationOf('n1', kind: 'share', link: 'https://evil.example/x'),
      ],
      total: 1,
      unreadCount: 1,
    );
    var navigated = false;
    await tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: (s) {
          navigated = true;
          return MaterialPageRoute(builder: (_) => const SizedBox());
        },
        home: const NotificationsPage(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题n1'));
    await tester.pumpAndSettle();
    expect(navigated, isFalse, reason: '白名单外不导航');
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('正文n1'),
      ),
      findsOneWidget,
    );
  });
}
