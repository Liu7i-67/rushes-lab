/// 审计筛选抽屉页面级用例(2026-10-28 抽屉化迁移新增):
/// 页面 tap `audit_filter_btn` 开 endDrawer → 4 控件可见;抽屉内改动即时
/// 触发重查(记录式假 API 断言次数与参数变化);「重置」= 四值清空 + 重查
/// + Badge 消失;「完成」仅关抽屉不触发请求;Badge 计数 0/1/2 显隐
/// (Material 3 Badge,非 widgets/badge.dart 自研同名件)。
/// 组件级断言(AuditFilterDrawer 直构)由 admin_polish / audit_filter_actor /
/// forms_polish2 / probe_p2 四处迁移用例兜底,此处不重复。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/audit_api.dart' show AuditApi, AuditFilter;
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/admin/admin_audit_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/app_chip.dart' show AppChip;

import '../helpers/api_harness.dart';

/// 审计列表假 API:记录每次 AuditFilter 口径(重查参数变化断言用)。
class _FakeAuditApi extends AuditApi {
  _FakeAuditApi(super.api);

  List<AuditEvent> listResult = const [];
  final listCalls = <AuditFilter>[];

  @override
  Future<List<AuditEvent>> list({
    AuditFilter filter = const AuditFilter(),
    int limit = 30,
    int offset = 0,
  }) async {
    listCalls.add(filter);
    return listResult;
  }
}

/// projects.listPaged 桩(抽屉「按项目筛选」选项数据源;照 admin_pages_test
/// FakeProjectsPagedApi 同款,偏移页回空 = 取完)。
class _FakePagedProjectsApi extends FakeProjectsApi {
  _FakePagedProjectsApi(super.api);

  List<Project> pagedResult = const [];

  @override
  Future<List<Project>> listPaged({int limit = 100, int offset = 0}) async {
    if (offset > 0) return const [];
    return pagedResult;
  }
}

/// 叠加审计域的会话假 API(其余域继承 FakeMsApi 记录式桩)。
class _FakeDrawerMsApi extends FakeMsApi {
  late final _audit = _FakeAuditApi(this);
  late final _projects = _FakePagedProjectsApi(this);

  @override
  _FakeAuditApi get audit => _audit;
  @override
  _FakePagedProjectsApi get projects => _projects;
}

_FakeDrawerMsApi _install() {
  final api = _FakeDrawerMsApi();
  session.api = api;
  addTearDown(() => session.api = null);
  return api;
}

Future<void> _pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: AdminAuditPage()));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('页面级:tap 筛选钮开抽屉,4 控件+重置/完成可见;默认无 Badge', (tester) async {
    final api = _install();
    await _pumpPage(tester);
    expect(api.audit.listCalls, hasLength(1), reason: '前置:首轮挂载查一次');
    expect(find.byKey(const Key('audit_filter_btn')), findsOneWidget);
    expect(
      find.byType(Badge),
      findsNothing,
      reason: '0 项生效筛选不挂 Badge(material 3 Badge)',
    );

    await tester.tap(find.byKey(const Key('audit_filter_btn')));
    await tester.pumpAndSettle();

    expect(find.text('筛选'), findsOneWidget, reason: '抽屉标题');
    expect(find.text('事件类型'), findsOneWidget);
    expect(find.text('按项目筛选(可选)'), findsOneWidget);
    expect(find.text('按操作者筛选(可选)'), findsOneWidget);
    expect(find.text('按日期筛选(可选)'), findsOneWidget);
    expect(find.text('重置'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
  });

  testWidgets('即时生效:chip 选「下载」+ 抽屉选操作者各触发重查;Badge 计数 1→2', (tester) async {
    final api = _install();
    api.users.userResult = [UserBrief(id: 'u1', name: '张三')];
    await _pumpPage(tester);

    // chip 轨选「下载」→ eventType 筛选生效,Badge 计数 1
    await tester.tap(find.widgetWithText(AppChip, '下载'));
    await tester.pumpAndSettle();
    expect(api.audit.listCalls, hasLength(2), reason: 'chip 改动即重查');
    expect(api.audit.listCalls.last.eventType, 'download');
    expect(find.byType(Badge), findsOneWidget);
    expect(
      find.descendant(of: find.byType(Badge), matching: find.text('1')),
      findsOneWidget,
      reason: '1 项生效筛选 Badge 计数 1',
    );

    // 开抽屉选操作者 → 即时重查,参数叠加(chip 同值保留)
    await tester.tap(find.byKey(const Key('audit_filter_btn')));
    await tester.pumpAndSettle();
    expect(find.text('下载'), findsWidgets, reason: '抽屉事件类型字段与 chip 同值联动(回显中文)');

    await tester.tap(find.text('全部操作者'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(BottomSheet), matching: find.text('张三')),
    );
    await tester.pumpAndSettle();

    expect(api.audit.listCalls, hasLength(3), reason: '抽屉内改动即时重查');
    expect(api.audit.listCalls.last.actorUserId, 'u1');
    expect(
      api.audit.listCalls.last.eventType,
      'download',
      reason: 'chip 已生效的 eventType 保留',
    );
    expect(
      find.descendant(of: find.byType(Badge), matching: find.text('2')),
      findsOneWidget,
      reason: '2 项生效筛选 Badge 计数 2',
    );
  });

  testWidgets('重置=四值清空+重查+Badge 消失;完成仅关抽屉不触发请求', (tester) async {
    final api = _install();
    api.users.userResult = [UserBrief(id: 'u1', name: '张三')];
    await _pumpPage(tester);

    // 铺两项筛选:chip「下载」+ 抽屉选操作者张三
    await tester.tap(find.widgetWithText(AppChip, '下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('audit_filter_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部操作者'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(BottomSheet), matching: find.text('张三')),
    );
    await tester.pumpAndSettle();
    expect(api.audit.listCalls, hasLength(3));

    // 重置:抽屉驻留,四值清空 + 重查 + Badge 消失
    await tester.tap(find.text('重置'));
    await tester.pumpAndSettle();
    expect(api.audit.listCalls, hasLength(4), reason: '重置触发重查');
    final f = api.audit.listCalls.last;
    expect(f.eventType, '', reason: '重置:事件类型清空');
    expect(f.actorUserId, '', reason: '重置:操作者清空');
    expect(f.projectId, '', reason: '重置:项目清空');
    expect(f.from, isNull, reason: '重置:单日起止清空');
    expect(f.to, isNull);
    expect(find.byType(Badge), findsNothing, reason: '重置后 0 项生效筛选');
    expect(find.text('— 全部 —'), findsOneWidget, reason: '事件类型字段回「全部」');
    expect(find.text('全部操作者'), findsOneWidget, reason: '操作者字段回「全部操作者」');

    // 完成:仅关抽屉,不触发请求
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('按项目筛选(可选)'), findsNothing, reason: '完成关抽屉');
    expect(api.audit.listCalls, hasLength(4), reason: '完成不触发请求');
  });
}
