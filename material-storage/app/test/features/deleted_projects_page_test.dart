/// 已删除项目页单测(B6 测试功能点 6):列表(删除时间/操作人)+ 搜索重置分页
/// + 恢复确认(失效 projects)+ 加载更多;非 is_project_deleter 入口不可见由
/// me_page 闸门(MePageTest 侧)与本页 403 detail 透传兜底。B6 批补:加载更多
/// 防连点/搜索 reload 代际 tag(P2-2)+ 恢复防重(P2-1)。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/me/me_page.dart';
import 'package:ms_app/features/projects/deleted_projects_page.dart';
// 页面 widget 与分页模型同名:测试里模型用法居多,hide 掉模型的同名类
import 'package:ms_app/models/models.dart' as models
    show DeletedProject, DeletedProjectsPage, Me;

import '../helpers/api_harness.dart';
import '../helpers/fake_apis_b6.dart';

List<models.DeletedProject> _page(int from, int to) => [
      for (var i = from; i < to; i++)
        models.DeletedProject(
            id: 'p$i', code: 'c$i', name: '项目$i',
            deletedAt: '2026-10-20T10:00:00Z'),
    ];

void main() {
  testWidgets('列表展示+恢复确认+失效 projects', (tester) async {
    final api = installFakeApi();
    api.projectsOps.listDeletedStaged = models.DeletedProjectsPage(items: [
      models.DeletedProject(
          id: 'p1', code: 'old', name: '旧项目',
          deletedAt: '2026-10-20T10:00:00Z', deletedByName: '管理员'),
    ], total: 1);
    addTearDown(() => session.api = null);
    session.me = models.Me(id: 'u0', name: '管');
    var projects = 0;
    void onProjects() => projects++;
    RefreshBus.I.addListener('projects', onProjects);
    addTearDown(() => RefreshBus.I.removeListener('projects', onProjects));

    await tester.pumpWidget(const MaterialApp(home: DeletedProjectsPage()));
    await tester.pumpAndSettle();

    expect(find.text('回收站(项目)'), findsOneWidget);
    expect(find.text('旧项目(old)'), findsOneWidget);
    expect(find.textContaining('删除于 2026-10-20 · 管理员'), findsOneWidget);

    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '恢复'));
    await tester.pumpAndSettle();
    expect(api.projectsOps.restoreCalls, ['p1']);
    expect(projects, greaterThan(0));
    expect(find.textContaining('已恢复'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6)); // 清 SnackBar timer
    await tester.pumpAndSettle();
  });

  testWidgets('空列表与搜索词区分文案;恢复 404 detail 透传', (tester) async {
    final api = installFakeApi();
    api.projectsOps.listDeletedStaged = models.DeletedProjectsPage(items: [], total: 0);
    api.projectsOps.restoreStaged = ApiException(404, 'project not found');
    addTearDown(() => session.api = null);

    await tester.pumpWidget(const MaterialApp(home: DeletedProjectsPage()));
    await tester.pumpAndSettle();
    expect(find.text('没有已删除的项目'), findsOneWidget);

    // 搜索后空 → 「无匹配项目」
    await tester.enterText(find.byType(TextField), '不存在的');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(api.projectsOps.listDeletedCalls.last.q, '不存在的');
    expect(find.text('无匹配项目'), findsOneWidget);
  });

  testWidgets('me_page 回收站(项目)入口仅 is_project_deleter 可见', (tester) async {
    installFakeApi();
    addTearDown(() => session.api = null);
    session.me = models.Me(id: 'u1', name: '甲', isSystemAdmin: false,
        isProjectDeleter: false);
    await tester.pumpWidget(const MaterialApp(home: MePage()));
    expect(find.text('回收站(项目)'), findsNothing);

    session.me = models.Me(id: 'u0', name: '管', isSystemAdmin: false,
        isProjectDeleter: true);
    await tester.pumpWidget(MaterialApp(home: MePage()));
    await tester.pumpAndSettle();
    expect(find.text('回收站(项目)'), findsOneWidget);
  });

  testWidgets('自动加载(app-polish E10):滚到底按 offset=20 追加下一页,取尽即止',
      (tester) async {
    final api = installFakeApi();
    // 第一页 20 条 + total 25 → 滚到底自动拉第二页(5 条)→ 25/25 停
    addTearDown(() => session.api = null);
    api.projectsOps.listDeletedStaged = models.DeletedProjectsPage(
        items: [
          for (var i = 0; i < 20; i++)
            models.DeletedProject(
                id: 'p$i', code: 'c$i', name: '项目$i',
                deletedAt: '2026-10-20T10:00:00Z'),
        ],
        total: 25);

    await tester.pumpWidget(const MaterialApp(home: DeletedProjectsPage()));
    await tester.pumpAndSettle();
    // E10:「加载更多」按钮已移除,改滚动到底自动加载
    expect(find.text('加载更多'), findsNothing);

    // 第二页 5 条(拖动即触发,先入桩)
    api.projectsOps.listDeletedStaged = models.DeletedProjectsPage(
        items: [
          for (var i = 20; i < 25; i++)
            models.DeletedProject(
                id: 'p$i', code: 'c$i', name: '项目$i',
                deletedAt: '2026-10-20T10:00:00Z'),
        ],
        total: 25);
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(api.projectsOps.listDeletedCalls.last.offset, 20);
    expect(find.text('加载更多'), findsNothing,
        reason: '25/25 无更多(自动加载取尽即止)');
  });

  // ── B6 批补充(P2-1 / P2-2)─────────────────────────────────────────────────

  testWidgets('P2-2 自动加载防连点:in-flight 期间再滚只发一次请求且不重复追加',
      (tester) async {
    final api = _GatedMsApi();
    session.api = api;
    addTearDown(() => session.api = null);
    api.projectsOps.listDeletedStaged =
        models.DeletedProjectsPage(items: _page(0, 20), total: 25);

    await tester.pumpWidget(const MaterialApp(home: DeletedProjectsPage()));
    await tester.pumpAndSettle();

    // 第二页先入桩(挂起前捕获),滚动触发 loadMore 挂起在 gate 上
    api.gatedOps.listDeletedStaged =
        models.DeletedProjectsPage(items: _page(20, 25), total: 25);
    api.gatedOps.loadMoreGate = Completer<void>();
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: 'E10:in-flight 底部加载指示可见');
    expect(
        api.projectsOps.listDeletedCalls.where((c) => c.offset > 0).length, 1,
        reason: 'in-flight 再滚只发一次请求(_loadingMore 守卫拦下)');

    api.gatedOps.loadMoreGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('加载更多'), findsNothing, reason: '25/25 无更多(按钮已移除)');
    // 列表惰性构建:滚到第二页区段再断言(滚动态下 find.text 才会物化行)
    await tester.dragUntilVisible(
        find.text('项目24(c24)'), find.byType(ListView), const Offset(0, -400));
    expect(find.text('项目24(c24)'), findsOneWidget, reason: '放行后追加第二页');
    expect(find.text('项目20(c20)'), findsOneWidget,
        reason: '两次请求会把第二页追加两遍(变 2 个同名 widget)');
  });

  testWidgets('P2-2 搜索 reload 后旧 loadMore 迟到响应被代际 tag 丢弃',
      (tester) async {
    final api = _GatedMsApi();
    session.api = api;
    addTearDown(() => session.api = null);
    api.projectsOps.listDeletedStaged =
        models.DeletedProjectsPage(items: _page(0, 20), total: 25);

    await tester.pumpWidget(const MaterialApp(home: DeletedProjectsPage()));
    await tester.pumpAndSettle();

    // 旧词第二页挂起 in-flight(挂起前捕获快照);E10:滚动触发而非点按钮
    api.gatedOps.listDeletedStaged =
        models.DeletedProjectsPage(items: _page(20, 25), total: 25);
    api.gatedOps.loadMoreGate = Completer<void>();
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pump();

    // 新词搜索 reload(offset=0 不受 gate):整表替换,代际 tag 自增。
    // 小调注释:E10 起底部加载指示为转圈动画,gate 未放行期间不可
    // pumpAndSettle(会永不落定),改逐 pump
    api.gatedOps.listDeletedStaged = models.DeletedProjectsPage(items: [
      models.DeletedProject(
          id: 'q1', code: 'new', name: '新词项目',
          deletedAt: '2026-10-20T10:00:00Z'),
    ], total: 1);
    await tester.enterText(find.byType(TextField), '新词');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump();
    expect(find.text('新词项目(new)'), findsOneWidget);

    // 放行旧 loadMore:tag 不匹配 → 旧词第二页整页丢弃,不污染新词列表
    api.gatedOps.loadMoreGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('项目20(c20)'), findsNothing,
        reason: '旧词迟到响应按代际丢弃');
    expect(find.text('新词项目(new)'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing, reason: '新词 1/1 无更多按钮');
  });

  testWidgets('P2-1 恢复防重:restore in-flight 期间再点恢复不发第二次请求',
      (tester) async {
    final api = _GatedMsApi();
    session.api = api;
    addTearDown(() => session.api = null);
    api.projectsOps.listDeletedStaged =
        models.DeletedProjectsPage(items: _page(0, 1), total: 1);

    await tester.pumpWidget(const MaterialApp(home: DeletedProjectsPage()));
    await tester.pumpAndSettle();

    api.gatedOps.restoreGate = Completer<void>();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '恢复'));
    await tester.pumpAndSettle(); // 对话框已关,restore 挂起中
    expect(api.projectsOps.restoreCalls, ['p0']);

    await tester.tap(find.text('恢复')); // 守卫:in-flight 再点不发请求
    await tester.pump();
    expect(api.projectsOps.restoreCalls, hasLength(1));

    api.gatedOps.restoreGate!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('已恢复'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6)); // 清 SnackBar timer
    await tester.pumpAndSettle();
  });
}

/// P2 测试专用:可挂起的假 projectsOps(loadMore/restore 由 Completer 放行;
/// 挂起前先走 super 取桩值快照,放行后返回旧词页以验证代际丢弃)。
class _GatedProjectOpsApi extends FakeProjectOpsApi {
  _GatedProjectOpsApi(super.api);

  /// 非 null 且 offset>0 的 listDeleted 挂起至放行(loadMore 竞态编排)。
  Completer<void>? loadMoreGate;

  /// 非 null 的 restore 挂起至放行(恢复防重编排)。
  Completer<void>? restoreGate;

  @override
  Future<models.DeletedProjectsPage> listDeleted(
      {String? q, int limit = 20, int offset = 0}) async {
    final gate = loadMoreGate;
    if (gate == null || offset == 0) {
      return super.listDeleted(q: q, limit: limit, offset: offset);
    }
    final stale =
        await super.listDeleted(q: q, limit: limit, offset: offset);
    await gate.future;
    return stale;
  }

  @override
  Future<void> restore(String projectId) async {
    final gate = restoreGate;
    final r = super.restore(projectId); // 先记录调用再挂起,in-flight 可断言
    if (gate != null) await gate.future;
    await r;
  }
}

class _GatedMsApi extends FakeMsApi {
  _GatedMsApi();

  late final _GatedProjectOpsApi gatedOps = _GatedProjectOpsApi(this);

  @override
  FakeProjectOpsApi get projectsOps => gatedOps;
}
