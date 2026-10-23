/// app-polish 验收用例(对应需求文档 2026-10-21-app-polish.md 包 E 各条):
/// - E1 登录页:用户名 next/密码 done、autofillHints(username/password)、
///   右上开发者日志按钮移除(login_page.dart);
/// - E2 改密成功出现反馈文案(「…重新登录」)后再跳转(change_password_page.dart);
/// - E5 退出登录弹确认、点取消不登出(me_page.dart);
/// - E6 通知滚动到底自动加载(notifications_page.dart;相对时间纯函数另见
///   test/core/relative_time_polish_test.dart);
/// - E7 传输分段器带计数(全部 N/上传 N/下载 N,transfers_page.dart);
/// - E8 审批决策后滚动位置保持不归零(approvals_page.dart;现状已不回顶,
///   本用例为回归锁,交付「局部更新」实现后仍须绿);
/// - E9 搜索 onSubmitted 即时触发请求(search_page.dart)。
///
/// 套路:testWidgets + FakeMsApi 记录式假 API(test/helpers/api_harness.dart),
/// 不用真实 HTTP(FakeAsync 下 socket 永不推进);逐 pump 避开不定长动画。
/// 凡依赖「尚未存在的行为」的断言均标注 TODO(app-polish Ex):现状应失败,
/// 交付后转绿。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/auth_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';
import 'package:ms_app/features/approvals/approvals_page.dart';
import 'package:ms_app/features/auth/change_password_page.dart';
import 'package:ms_app/features/auth/login_page.dart';
import 'package:ms_app/features/me/me_page.dart';
import 'package:ms_app/features/notifications/notifications_page.dart';
import 'package:ms_app/features/search/search_page.dart';
import 'package:ms_app/features/transfers/transfers_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/app_segmented.dart';

import '../helpers/api_harness.dart';

// ── E2:auth 域记录式假 API(session.changePassword 走 auth.changePassword+
//    auth.me 两端点,均须短路段免真实 HTTP)──────────────────────────────────
class _AuthFakeApi extends AuthApi {
  _AuthFakeApi(super.api);

  final changeCalls = <({String oldPw, String newPw})>[];

  @override
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    changeCalls.add((oldPw: oldPassword, newPw: newPassword));
  }

  @override
  Future<Me> me() async => Me(id: 'me1', name: '甲');
}

class _AuthMsApi extends FakeMsApi {
  late final _auth = _AuthFakeApi(this);

  @override
  _AuthFakeApi get auth => _auth;
}

Approval _approval(String id, {String status = 'pending'}) => Approval(
  id: id,
  applicantUserId: 'u9',
  targetType: 'asset',
  targetId: 'a1',
  action: 'download',
  durationSeconds: 3600,
  reason: '关单需要',
  status: status,
  createdAt: '2026-10-20T09:00:00Z',
  requesterName: '用户$id',
);

void main() {
  // ── E1 登录页 ───────────────────────────────────────────────────────────
  testWidgets('E1:用户名框 textInputAction.next + autofillHints(username);'
      '密码框 done + autofillHints(password)', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pump();
    await tester.pump();

    final username = tester.widget<TextField>(
      find.widgetWithText(TextField, '用户名 / 邮箱'),
    );
    final password = tester.widget<TextField>(
      find.widgetWithText(TextField, '密码'),
    );

    // TODO(app-polish E1): 现状应失败(两框均未设置 textInputAction/
    // autofillHints),交付后转绿
    expect(
      username.textInputAction,
      TextInputAction.next,
      reason: 'E1:用户名框回车跳下一字段',
    );
    expect(
      username.autofillHints,
      contains(AutofillHints.username),
      reason: 'E1:用户名框声明 autofill hint',
    );
    expect(
      password.textInputAction,
      TextInputAction.done,
      reason: 'E1:密码框回车提交',
    );
    expect(
      password.autofillHints,
      contains(AutofillHints.password),
      reason: 'E1:密码框声明 autofill hint',
    );
  });

  testWidgets('E1:右上开发者日志按钮移除(功能并入「我的」诊断区)', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pump();
    // TODO(app-polish E1): 现状应失败(logPushButton 常驻右上角),交付后转绿
    expect(
      find.byIcon(Icons.bug_report_outlined),
      findsNothing,
      reason: 'E1:登录页右上角不再有日志推送入口',
    );
  });

  // ── E2 改密成功反馈 ─────────────────────────────────────────────────────
  testWidgets('E2:改密成功出现反馈文案(含「重新登录」)后再跳转', (tester) async {
    final api = _AuthMsApi();
    session.api = api;
    addTearDown(() {
      session.api = null;
      session.me = null;
    });

    await tester.pumpWidget(
      MaterialApp(
        routes: {
          '/': (_) => const Scaffold(body: Text('HOME')),
          '/change-password': (_) => const ChangePasswordPage(),
        },
        initialRoute: '/change-password',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, '原密码'), 'Old-1');
    await tester.enterText(find.widgetWithText(TextField, '新密码'), 'New-1!');
    await tester.enterText(find.widgetWithText(TextField, '确认新密码'), 'New-1!');
    await tester.tap(find.text('确认修改'));
    await tester.pump();
    await tester.pump();

    expect(api.auth.changeCalls.single, (
      oldPw: 'Old-1',
      newPw: 'New-1!',
    ), reason: '前置:改密请求已发(假 API 短路)');
    // TODO(app-polish E2): 现状应失败(成功即静默 pop,无任何反馈),交付后转绿
    expect(
      find.textContaining('重新登录'),
      findsWidgets,
      reason: 'E2:成功反馈(toast「已更新,请重新登录」)先于跳转出现',
    );
    expect(find.text('HOME'), findsOneWidget, reason: 'E2:反馈后回到非改密页');
    // 收尾:排空 toast SnackBar 的 duration Timer(实现经 A6 toast() 呈现)
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  // ── E5 退出登录确认 ─────────────────────────────────────────────────────
  testWidgets('E5:退出登录弹确认层;点取消不登出', (tester) async {
    installFakeApi();
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    session.me = Me(id: 'u1', name: '甲');
    await tester.pumpWidget(const MaterialApp(home: MePage()));
    await tester.pump();
    await tester.pump();

    // 小调注释:E5 精修后页面为分组卡片列表,退出登录行在 600dp 测试视口
    // 惰性构建窗口外,先滚到底再点(交互语义不变)
    await tester.dragUntilVisible(
      find.text('退出登录'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.tap(find.text('退出登录'));
    await tester.pump();
    await tester.pump();

    // TODO(app-polish E5): 现状应失败(直接 session.logout,无确认层),交付后转绿。
    // 确认层经 showAppConfirm(A5)呈现,确认/取消按钮语义对齐现役 AlertDialog
    // 约定(取消/确认),文案未定——按类型断言。
    expect(find.byType(AlertDialog), findsOneWidget, reason: 'E5:退出登录前弹确认层');
    expect(find.text('取消'), findsOneWidget, reason: 'E5:确认层提供取消出口');

    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump();
    expect(session.me, isNotNull, reason: 'E5:取消后不登出');
    expect(find.text('退出登录'), findsOneWidget, reason: 'E5:仍停留在「我的」页');
  });

  // ── E6 通知自动加载 ─────────────────────────────────────────────────────
  testWidgets('E6:通知列表滚动到底自动加载下一页(offset 递增),不再按钮式分页', (tester) async {
    final api = installFakeApi();
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    api.notifications.onListOverride = ({required limit, required offset}) {
      if (offset == 0) {
        return NotificationsList(
          items: [for (var i = 1; i <= 20; i++) notificationOf('n$i')],
          total: 25,
          unreadCount: 3,
        );
      }
      return NotificationsList(
        items: [for (var i = 21; i <= 25; i++) notificationOf('n$i')],
        total: 25,
        unreadCount: 3,
      );
    };

    await tester.pumpWidget(const MaterialApp(home: NotificationsPage()));
    await tester.pump();
    await tester.pump();
    expect(api.notifications.listCalls.single.offset, 0, reason: '首轮只拉第一页');

    // 只滚动,不点任何按钮——E6 验收点:到底即自动加载
    for (var i = 0; i < 5; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -1200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
    // TODO(app-polish E6): 现状应失败(需手点「加载更多」),交付后转绿
    expect(api.notifications.listCalls.length, 2, reason: 'E6:滚动到底自动请求第二页');
    expect(
      api.notifications.listCalls.last.offset,
      20,
      reason: 'E6:offset=已拉条数',
    );
    expect(find.text('加载更多'), findsNothing, reason: 'E6:「加载更多」按钮移除(改加载指示)');
    // 小调注释:行标题实为「标题n21」(notificationOf 的 title 前缀),
    // find.text 精确匹配需带前缀,语义不变
    expect(find.text('标题n21'), findsOneWidget, reason: 'E6:第二页内容拼接渲染');
  });

  // ── E7 传输分段计数 ─────────────────────────────────────────────────────
  testWidgets('E7:传输分段器带计数(全部 N/上传 N/下载 N)', (tester) async {
    final q = TransferQueue();
    void add(String name, TransferKind kind) {
      q.enqueue(
        TransferRequest(
          kind: kind,
          filename: name,
          where: '项目A/夹B',
          totalBytes: 100,
          worker: (p, token) async {},
        ),
      );
    }

    add('u1.mov', TransferKind.upload);
    add('u2.mov', TransferKind.upload);
    add('d1.bin', TransferKind.download);
    await tester.pump();

    await tester.pumpWidget(MaterialApp(home: TransfersPage(queue: q)));
    await tester.pump();

    // 分段标签 + 计数(WP2 起由 AppSegmented 渲染:label 与 count 两个 Text)
    final segmented = find.byWidgetPredicate((w) => w is AppSegmented);
    expect(segmented, findsOneWidget);
    for (final (label, count) in [('全部', '3'), ('上传', '2'), ('下载', '1')]) {
      expect(
        find.descendant(of: segmented, matching: find.text(label)),
        findsOneWidget,
        reason: 'E7:分段「$label」存在',
      );
      expect(
        find.descendant(of: segmented, matching: find.text(count)),
        findsOneWidget,
        reason: 'E7:「$label」段带计数 $count',
      );
    }
  });

  // ── E8 审批决策后滚动位置保持 ───────────────────────────────────────────
  testWidgets('E8:决策成功刷新列表后滚动位置不归零(回归锁;现状已不回顶)', (tester) async {
    final api = installFakeApi();
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    session.me = Me(id: 'admin1', name: '管', isSystemAdmin: true);
    api.approvalsOps.listResult = [
      for (var i = 1; i <= 30; i++) _approval('a$i'),
    ];

    await tester.pumpWidget(const MaterialApp(home: ApprovalsPage()));
    await tester.pump();
    await tester.pump();

    // 滚到底(30 张卡)
    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }
    double pixels() => tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(RefreshIndicator),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position
        .pixels;
    expect(pixels(), greaterThan(0), reason: '前置:已滚离顶部');

    // 决策最后一张卡(带确认弹窗)
    await tester.tap(find.text('批准').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '批准'),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.approvalsOps.decideCalls.single.id, 'a30', reason: '前置:决策已发');
    expect(find.textContaining('已批准'), findsOneWidget, reason: '前置:决策反馈');

    // E8 验收点:决策刷新(_reload)后不整页回顶
    expect(pixels(), greaterThan(0), reason: 'E8:决策后滚动位置保持(局部更新或保持 offset)');

    // 收尾:排空 SnackBar 计时器
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  // ── E9 搜索 onSubmitted 即时触发 ────────────────────────────────────────
  testWidgets('E9:键盘提交(onSubmitted)即时触发搜索,不等 300ms 防抖', (tester) async {
    final api = installFakeApi();
    addTearDown(() {
      session.api = null;
      session.me = null;
    });

    await tester.pumpWidget(const MaterialApp(home: SearchPage()));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '婚礼');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();
    // TODO(app-polish E9): 现状应失败(只有 onChanged 防抖路径,提交动作无
    // 处理器,此刻尚未发请求),交付后转绿
    expect(
      api.assets.searchCalls.any((c) => c.q == '婚礼'),
      isTrue,
      reason: 'E9:onSubmitted 即时搜索(不经 300ms 防抖)',
    );

    // 收尾:让 onChanged 挂起的防抖 Timer 到期(否则测试收尾报悬挂 Timer;
    // 到期后再触发一次防抖搜索属预期,不影响上方断言)
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  });
}
