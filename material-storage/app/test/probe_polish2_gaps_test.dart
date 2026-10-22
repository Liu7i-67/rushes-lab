/// 二期专职测试探针(mobile-ux-polish-2):覆盖既有用例缺口,只报问题不改码。
/// - R3:loading 分支下拉刷新(既有用例只钉了 empty/error/list 三分支);
/// - R3:空态 EmptyState 在可视区内垂直居中(布局不破);
/// - R4c:进度回调不挂写盘 + kPersistDebounce=500ms 钉死;
/// - R4c:恢复记录 retry 失败原因改写「历史记录,请重新发起传输」;
/// - R4c 交叉:恢复终态 + 新任务同轮入队收尾,快照终态一致;
/// - R4a:TransferNotifyTile 回前台(resumed)自动重查;
/// - R4a:queryPermission 真实 Android 通道(areNotificationsEnabled)两向。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show
        AndroidFlutterLocalNotificationsPlugin,
        FlutterLocalNotificationsPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/core/transfers/transfer_store.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';
import 'package:ms_app/features/me/me_page.dart';
import 'package:ms_app/features/projects/projects_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/services/notifier.dart';
import 'package:ms_app/widgets/empty_state.dart';
import 'package:ms_app/widgets/list_skeleton.dart' as ms_widgets;

import 'helpers/api_harness.dart';

// ── R3 探针支撑:可挂起首请求的假 projects 域 ───────────────────────────────

class _GatedProjectsApi extends FakeProjectsApi {
  _GatedProjectsApi(super.api);

  var calls = 0;
  Completer<void>? gate;

  @override
  Future<List<Project>> list() async {
    calls++;
    final g = gate;
    if (g != null) await g.future;
    return super.list();
  }
}

class _ShimApi extends FakeMsApi {
  _ShimApi() : super();

  late _GatedProjectsApi gated;
  @override
  FakeProjectsApi get projects => gated;
}

/// queryPermission 真实 Android 分支探针桩:替身注入 FlutterLocalNotificationsPlatform.instance。
class _FakeAndroidNotifPlugin extends AndroidFlutterLocalNotificationsPlugin {
  _FakeAndroidNotifPlugin(this.enabled);
  final bool? Function() enabled;
  @override
  Future<bool?> areNotificationsEnabled() async => enabled();
}

void main() {
  testWidgets('R3 补口:loading 分支可下拉触发 onRefresh', (tester) async {
    final shim = _ShimApi();
    final gated = _GatedProjectsApi(shim);
    shim.gated = gated;
    installFakeApi(shim);
    session.me = Me(id: 'u1', name: 'Evan');
    final firstGate = Completer<void>();
    gated.gate = firstGate; // 挂起首轮 → 页面停 loading
    addTearDown(() {
      session.api = null;
      session.me = null;
    });

    await tester.pumpWidget(const MaterialApp(home: ProjectsPage()));
    await tester.pump();
    await tester.pump();
    // app-polish E3:首载 loading 分支由裸转圈改为 ListSkeleton 骨架屏,
    // 探锚同步替换(分支行为——可下拉触发 onRefresh——不变)
    expect(find.byType(ms_widgets.ListSkeleton), findsOneWidget,
        reason: '前置:首轮挂起 → loading 分支(骨架屏)');
    expect(gated.calls, 1);

    gated.gate = null; // 后续刷新立即返回
    await tester.drag(find.byType(ListView).first, const Offset(0, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(gated.calls, 2, reason: 'R3:loading 分支下拉触发刷新');

    // 放行首轮请求,页面稳定收尾(loading 已被刷新转到空态)
    firstGate.complete();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('R3 补口:空态 EmptyState 在可视区内垂直居中(布局不破)',
      (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = const <Project>[];
    session.me = Me(id: 'u1', name: 'Evan');
    addTearDown(() {
      session.api = null;
      session.me = null;
    });

    await tester.pumpWidget(const MaterialApp(home: ProjectsPage()));
    await tester.pump();
    await tester.pump();

    final bodyRect = tester.getRect(find.byType(RefreshIndicator));
    final center = tester.getCenter(find.byType(EmptyState));
    expect((center.dy - bodyRect.center.dy).abs(), lessThan(8),
        reason: '空态内容相对 body 居中(${center.dy} vs ${bodyRect.center.dy})');
  });

  // ── R4c 补口 ─────────────────────────────────────────────────────────────

  TransferRequest req(String name, {required TransferWorker worker}) =>
      TransferRequest(
          kind: TransferKind.upload,
          filename: name,
          where: '项目A',
          totalBytes: 100,
          worker: worker);

  Future<void> drain([int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  List<Map<String, dynamic>> rowsOf(String content) =>
      (jsonDecode(content) as List).cast<Map<String, dynamic>>();

  test('R4c 补口:进度回调不挂写盘;收尾才第二次;kPersistDebounce=500ms',
      () async {
    expect(kPersistDebounce, const Duration(milliseconds: 500),
        reason: '需求 R4c 口径:去抖 500ms');

    final flushes = <void Function()>[];
    final writes = <String>[];
    final q = TransferQueue(
      now: () => DateTime(2026, 10, 21),
      store: TransferStore(
        read: () async => null,
        write: (c) async => writes.add(c),
      ),
      schedule: (_, cb) => flushes.add(cb),
    );

    late final void Function(int) progress;
    final gate = Completer<void>();
    q.enqueue(req('a', worker: (p, t) async {
      progress = p;
      await gate.future;
    }));
    await drain();
    expect(flushes, hasLength(1), reason: '入队挂第一次去抖');

    progress(30);
    progress(60);
    progress(90);
    await drain();
    expect(flushes, hasLength(1), reason: '进度回调不写盘(不挂去抖)');
    flushes.removeAt(0)(); // 触发入队点的在途去抖
    await drain();
    expect(writes, hasLength(1));
    expect(writes.single, isNot(contains('30')),
        reason: '快照=状态变化点口径,高频进度值不落盘');

    gate.complete();
    await drain();
    expect(flushes, hasLength(1), reason: '收尾(终态)挂第二次去抖');
    flushes.single();
    await drain();
    expect(writes, hasLength(2));
    expect(rowsOf(writes.last).single['status'], 'done');
    expect(rowsOf(writes.last).single['doneBytes'], 100, reason: '收尾落终值');
  });

  test('R4c 补口:恢复记录 retry 失败 → 原因改写「历史记录,请重新发起传输」',
      () async {
    final snapshot = encodeTasks([
      TransferTask(
          id: 't1',
          kind: TransferKind.upload,
          filename: '旧.jpg',
          where: '项目A',
          totalBytes: 1,
          status: TransferStatus.failed,
          error: kInterruptedError,
          startedAt: DateTime(2026, 10, 21)),
    ]);
    final q = TransferQueue(
      now: () => DateTime(2026, 10, 21),
      store: TransferStore(
          read: () async => snapshot, write: (_) async {}),
    );
    await q.attachStore(TransferStore(read: () async => snapshot));
    await drain();

    expect(q.retry('t1'), isNull);
    expect(q.byId('t1')!.error, '历史记录,请重新发起传输',
        reason: '卡片用户可见提示(传输页 onRetry 透传 q.retry)');
  });

  test('R4c 交叉:恢复终态 + 新任务同轮入队收尾 → 快照共存且终态一致', () async {
    final snapshot = encodeTasks([
      TransferTask(
          id: 't3',
          kind: TransferKind.download,
          filename: '旧.mp4',
          where: '项目A',
          totalBytes: 5,
          status: TransferStatus.done,
          startedAt: DateTime(2026, 10, 21)),
    ]);
    final writes = <String>[];
    final flushes = <void Function()>[];
    final q = TransferQueue(
      now: () => DateTime(2026, 10, 21),
      store: TransferStore(
        read: () async => snapshot,
        write: (c) async => writes.add(c),
      ),
      schedule: (_, cb) => flushes.add(cb),
    );
    await q.attachStore(TransferStore(read: () async => snapshot));
    await drain();

    final id = q.enqueue(req('新.jpg', worker: (p, t) async {}));
    await drain();
    expect(q.byId(id)!.status, TransferStatus.done);
    for (final f in List.of(flushes)) {
      f();
    }
    await drain();
    expect(rowsOf(writes.last), hasLength(2));
    expect(
        {
          for (final r in rowsOf(writes.last)) r['filename']: r['status'],
        },
        {'旧.mp4': 'done', '新.jpg': 'done'},
        reason: '恢复历史与新任务在快照中共存且终态正确');
  });

  // ── R4a 补口 ─────────────────────────────────────────────────────────────

  testWidgets('R4a 补口:回前台(resumed)自动重查授权态', (tester) async {
    final results = <bool>[false, true];
    var queries = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TransferNotifyTile(
          query: () async {
            queries++;
            return results.isNotEmpty ? results.removeAt(0) : true;
          },
          openSettings: () async {},
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('未开启,收不到后台传输完成提醒'), findsOneWidget);

    // 不点 Tile,直接模拟从设置页回前台 → didChangeAppLifecycleState 重查
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(queries, 2, reason: 'resumed 触发第二次查询');
    expect(find.text('✓已开启'), findsOneWidget, reason: '回前台实时刷新');
  });

  testWidgets('R4a 补口:queryPermission 真实 Android 分支(resolve 实例注入)',
      (tester) async {
    bool? enabled;
    final fake = _FakeAndroidNotifPlugin(() => enabled);
    // 平台接口 _instance 为 late static:测试环境从未注册 → 读取即抛
    // LateInitializationError(即 Notifier 降级日志的来源)。直接注入替身。
    FlutterLocalNotificationsPlatform.instance = fake;

    // queryPermission 不依赖 init/batcher:真实分支=resolve Android →
    // areNotificationsEnabled 透传
    enabled = false;
    expect(await Notifier.I.queryPermission(), isFalse,
        reason: 'Android 通道 false → 未开启(我的页可点跳设置)');
    enabled = true;
    expect(await Notifier.I.queryPermission(), isTrue,
        reason: 'Android 通道 true → 已开启(纯展示)');
  });
}
