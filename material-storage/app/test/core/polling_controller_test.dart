/// PollingController 单测(B7 测试功能点 5 + 通知功能点 2 的轮询生命周期):
/// 门控起停(登录起/登出停/401 清会话停)/30s 周期/防重叠(上轮未完不发
/// 下轮)/恢复前台立即刷一次再续周期。假时钟=widget 测试 FakeAsync
/// (tester.pump 即时间推进;不引 fake_async 依赖)。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/api/notifications_api.dart';
import 'package:ms_app/core/polling_controller.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/models/models.dart';

/// 可编排 tick 的裸控制器(不经网络)。
class _CountingPoller extends PollingController {
  _CountingPoller({this.failOnce});

  bool gate = true;
  int ticks = 0;
  Completer<void>? hold; // 非 null 时挂起当前 tick(防重叠编排)
  Object? failOnce; // 下一轮 tick 抛出(弱网/401 兜底不炸循环)

  @override
  bool canPoll() => gate;

  @override
  Future<void> performTick() async {
    ticks++;
    final h = hold;
    if (h != null) await h.future;
    final f = failOnce;
    if (f != null) {
      failOnce = null;
      throw f;
    }
  }
}

void main() {
  // 401 用例走 Session.handleSessionExpired → navigatorKey(需 binding)
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 拉起无 UI 的 binding 世界(tester.pump 假时钟可用)。
  Future<void> holdWorld(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

  testWidgets('门控+周期:syncGate 起轮立即刷;登出停;再登恢复', (tester) async {
    await holdWorld(tester);
    final p = _CountingPoller();
        p.gate = false;
    p.syncGate(); // 未登录门控关 → 不起
    expect(p.polling, isFalse);
    expect(p.ticks, 0);

    p.gate = true;
    p.syncGate(); // 登录 → 立即刷一次
    await tester.pump(const Duration(milliseconds: 10));
    expect(p.polling, isTrue);
    expect(p.ticks, 1);

    await tester.pump(const Duration(seconds: 30)); // 一个周期后再刷
    expect(p.ticks, 2);

    p.gate = false;
    p.syncGate(); // 登出 → 停
    expect(p.polling, isFalse);
    await tester.pump(const Duration(seconds: 90));
    expect(p.ticks, 2, reason: '停轮后不再发');

    p.gate = true;
    p.syncGate(); // 重新登录 → 立即刷
    await tester.pump(const Duration(milliseconds: 10));
    expect(p.ticks, 3);
    p.stop(); // 测试体收尾停轮(勿留 pending timer)
  });

  testWidgets('周期=30s 且失败不终止循环(弱网下一拍自愈)', (tester) async {
    await holdWorld(tester);
    final p = _CountingPoller(failOnce: ApiException(500, 'x'));
        p.syncGate();
    await tester.pump(const Duration(milliseconds: 10));
    expect(p.ticks, 1);
    await tester.pump(const Duration(seconds: 29));
    expect(p.ticks, 1, reason: '30s 未到不发');
    await tester.pump(const Duration(seconds: 1));
    expect(p.ticks, 2, reason: '上一轮失败不终止循环');
    p.stop();
  });

  testWidgets('防重叠:上轮未完成时定时器到点不发,完成后才排下一拍', (tester) async {
    await holdWorld(tester);
    final p = _CountingPoller();
        final hold = Completer<void>();
    p.syncGate();
    await tester.pump(const Duration(milliseconds: 10));
    expect(p.ticks, 1);

    p.hold = hold; // 第二轮挂起
    await tester.pump(const Duration(seconds: 30));
    expect(p.ticks, 2);

    // 挂起期间连续两个周期到点:都不发(防重叠)
    await tester.pump(const Duration(seconds: 60));
    expect(p.ticks, 2);

    hold.complete(); // 放行 → finally 只排一拍
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(seconds: 30));
    expect(p.ticks, 3, reason: '挂起积压不补发,放行后续一拍');
    p.stop();
  });

  testWidgets('进后台停 / 恢复前台立即刷一次再续周期', (tester) async {
    await holdWorld(tester);
    final p = _CountingPoller();
        p.syncGate();
    await tester.pump(const Duration(milliseconds: 10));
    expect(p.ticks, 1);

    p.didChangeAppLifecycleState(AppLifecycleState.paused); // 进后台
    expect(p.polling, isFalse);
    await tester.pump(const Duration(seconds: 90));
    expect(p.ticks, 1, reason: '后台不轮');

    p.didChangeAppLifecycleState(AppLifecycleState.resumed); // 回前台
    await tester.pump(const Duration(milliseconds: 10));
    expect(p.polling, isTrue);
    expect(p.ticks, 2, reason: '恢复前台立即刷一次');
    await tester.pump(const Duration(seconds: 30));
    expect(p.ticks, 3, reason: '再续 30s 周期');
    p.stop();
  });

  testWidgets('401 停:Session 清会话(notifyListeners)经 syncGate 停轮',
      (tester) async {
    await holdWorld(tester);
    final session = Session();
    final api = _GateApi();
    session.api = api;
    session.me = Me(id: 'u0', name: '甲');
    final p = UnreadPoller(sessionOverride: session, api: api);
        session.addListener(p.syncGate);
    p.syncGate();
    await tester.pump();
    expect(p.polling, isTrue);
    expect(p.unreadCount, 3);

    await session.handleSessionExpired(); // 401 钩子 → me=null → 停
    expect(session.me, isNull);
    expect(p.polling, isFalse, reason: '401 清会话即停');
    session.removeListener(p.syncGate);
    p.stop();
    // Session 401 去抖 SingleFlightGate 的 1s 窗口 Timer 也要走完
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('UnreadPoller:unreadCount 写入去重广播;limit=1 轻量口径',
      (tester) async {
    await holdWorld(tester);
    final api = _GateApi();
    final p = UnreadPoller(
      sessionOverride: Session()
        ..api = api
        ..me = Me(id: 'u0', name: '甲'),
      api: api,
    );
        var notified = 0;
    p.addListener(() => notified++);
    p.syncGate();
    await tester.pump();
    expect(api.notifications.listLimits, [1],
        reason: 'GET /notifications?limit=1(web 同款)');
    expect(p.unreadCount, 3);
    expect(notified, 1, reason: '同值写入不广播');
    p.unreadCount = 3;
    expect(notified, 1);
    p.unreadCount = 0;
    expect(notified, 2);
    p.stop();
  });

  testWidgets('stop 复位(P2-5):停轮(登出/401)时 unreadCount 清零,'
      '防重登后短暂显示上账号计数', (tester) async {
    await holdWorld(tester);
    final api = _GateApi();
    final p = UnreadPoller(
      sessionOverride: Session()
        ..api = api
        ..me = Me(id: 'u0', name: '甲'),
      api: api,
    );
    var notified = 0;
    p.addListener(() => notified++);
    p.syncGate();
    await tester.pump();
    expect(p.unreadCount, 3);
    expect(notified, 1);

    p.stop(); // 登出/401 停轮路径
    expect(p.unreadCount, 0, reason: '停轮即清零复位,不残留上账号计数');
    expect(notified, 2, reason: '复位广播驱动 badge 即时消失');

    p.stop();
    expect(notified, 2, reason: '已为 0 再停不重复广播');

    // 重登:立即刷一次,取到服务端新值而非旧计数残留
    p.syncGate();
    await tester.pump();
    expect(p.unreadCount, 2, reason: '重登首轮取服务端口径');
    p.stop();
  });
}

class _GateApi extends MsApi {
  _GateApi() : super(baseUrl: 'http://b7.test.local');

  final _notifications = _GateNotificationsApi();

  @override
  _GateNotificationsApi get notifications => _notifications;
}

class _GateNotificationsApi extends NotificationsApi {
  _GateNotificationsApi() : super(_stub);

  static final _stub = MsApi(baseUrl: 'http://b7.test.local');

  final listLimits = <int>[];

  @override
  Future<NotificationsList> list({int limit = 50, int offset = 0}) async {
    listLimits.add(limit);
    return NotificationsList(
        items: const [], total: 0, unreadCount: 3 - (listLimits.length - 1));
  }
}
