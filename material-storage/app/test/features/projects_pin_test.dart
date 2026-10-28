/// 项目置顶页面级用例(2026-10-28 B5 置顶新增):
/// - Project.fromJson 的 is_pinned 解析(有=true;缺省/null 回退 false 兼容旧后端);
/// - 长按菜单分级(D4):非 admin 仅见置顶项,admin 另有成员管理/请求链接;
///   菜单标题统一「<名> · 项目操作」;首项文案按 isPinned 切换;
/// - tap 置顶项调 fake.pin/unpin + _reload()(假桩按新排序返回,断言列表
///   渲染顺序);卡片图钉标识仅已置顶显示(组件级 + 页面级各一);
/// - 失败路径(P2-3):pin/unpin 抛 ApiException → toast 透传文案,
///   不翻本地标记、不触发 _reload(顺序与图钉维持原样)。
/// 管理菜单形态迁移(标题「项目A · 管理」→「项目A · 项目操作」)见
/// projects_page_ux_test 同步改断言。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/projects/project_card.dart';
import 'package:ms_app/features/projects/projects_page.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

/// 挂页并等到稳定态(照 projects_page_ux_test:逐 pump 避开 pumpAndSettle)。
Future<void> _pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: ProjectsPage()));
  await tester.pump();
  await tester.pump();
}

void _reset() {
  session.api = null;
  session.me = null;
}

/// 列表当前卡片渲染顺序(按 ValueKey `project_<id>` 解出 id,y 升序)。
List<String> _cardOrder(WidgetTester tester) {
  final entries = <(double, String)>[];
  for (final element in tester.elementList(find.byType(ProjectCard))) {
    final card = element.widget as ProjectCard;
    final id = (card.key! as ValueKey<String>).value.substring(
      'project_'.length,
    );
    entries.add((tester.getTopLeft(find.byWidget(card)).dy, id));
  }
  entries.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final e in entries) e.$2];
}

/// 卡片标题旁图钉标识(仅 isPinned 显示)。
Finder _pinIcon(String id) => find.descendant(
  of: find.byKey(ValueKey('project_$id')),
  matching: find.byIcon(Icons.push_pin),
);

void main() {
  test('Project.fromJson:is_pinned 解析(true/缺省 false/null 回退 false)', () {
    expect(
      Project.fromJson({
        'id': 'p1',
        'name': 'A',
        'code': 'a',
        'is_pinned': true,
      }).isPinned,
      isTrue,
      reason: 'is_pinned=true → 置顶',
    );
    expect(
      Project.fromJson({'id': 'p1', 'name': 'A', 'code': 'a'}).isPinned,
      isFalse,
      reason: '旧后端缺字段 → 缺省 false',
    );
    expect(
      Project.fromJson({
        'id': 'p1',
        'name': 'A',
        'code': 'a',
        'is_pinned': null,
      }).isPinned,
      isFalse,
      reason: 'null 回退 false(bool? ?? false 通式)',
    );
  });

  testWidgets('长按菜单分级:非 admin 仅见置顶项(未置顶文案「置顶到最前」)', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = <Project>[
      Project(id: 'p1', name: '项目A', code: 'PA'), // 无 my_roles = 仅访客
    ];
    session.me = Me(id: 'u1', name: 'Evan');
    addTearDown(_reset);
    await _pumpPage(tester);

    await tester.longPress(find.text('项目A'));
    await tester.pumpAndSettle();

    expect(find.text('项目A · 项目操作'), findsOneWidget, reason: '菜单标题统一「项目操作」');
    expect(find.text('置顶到最前'), findsOneWidget, reason: '置顶入口对所有用户开放');
    expect(find.text('成员管理'), findsNothing, reason: '非 admin 不见管理项');
    expect(find.text('请求链接'), findsNothing);
  });

  testWidgets('长按菜单分级:admin 见置顶+成员管理+请求链接;标题统一「项目操作」', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = <Project>[
      Project(id: 'p1', name: '项目A', code: 'PA', myRoles: ['admin']),
    ];
    session.me = Me(id: 'u1', name: 'Evan');
    addTearDown(_reset);
    await _pumpPage(tester);

    await tester.longPress(find.text('项目A'));
    await tester.pumpAndSettle();

    expect(find.text('项目A · 项目操作'), findsOneWidget);
    expect(find.text('置顶到最前'), findsOneWidget, reason: 'admin 同样首项置顶');
    expect(find.text('成员管理'), findsOneWidget, reason: 'canAdmin 项保留');
    expect(find.text('请求链接'), findsOneWidget);
  });

  testWidgets('置顶:tap 菜单项调 pin + 重拉;假桩按新排序返回,顺序与图钉联动', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = <Project>[
      Project(id: 'p2', name: '写字楼B', code: 'OFF'),
      Project(id: 'p1', name: '婚礼A', code: 'WED'),
    ]; // 现状序(created_at desc):p2 在前
    session.me = Me(id: 'u1', name: 'Evan');
    addTearDown(_reset);
    await _pumpPage(tester);
    expect(api.projects.listCalls, 1);
    expect(_cardOrder(tester), ['p2', 'p1'], reason: '前置:未置顶按原序');
    expect(_pinIcon('p1'), findsNothing, reason: '前置:未置顶无图钉');

    // 长按 p1 → 置顶到最前 → pin('p1') → 重拉(假桩返回置顶优先新序)
    await tester.longPress(find.text('婚礼A'));
    await tester.pumpAndSettle();
    api.projects.listStaged = <Project>[
      Project(id: 'p1', name: '婚礼A', code: 'WED', isPinned: true),
      Project(id: 'p2', name: '写字楼B', code: 'OFF'),
    ];
    await tester.tap(find.text('置顶到最前'));
    await tester.pumpAndSettle();

    expect(api.projects.pinCalls, ['p1'], reason: '未置顶 → 调 pin');
    expect(api.projects.unpinCalls, isEmpty);
    expect(api.projects.listCalls, 2, reason: '置顶成功后 _reload');
    expect(_cardOrder(tester), ['p1', 'p2'], reason: '假桩新排序 = 置顶优先渲染');
    expect(_pinIcon('p1'), findsOneWidget, reason: '已置顶卡片标题旁金色图钉');
    expect(_pinIcon('p2'), findsNothing);
  });

  testWidgets('取消置顶:tap 菜单项调 unpin + 重拉,顺序回退图钉消失(非 admin 同样可取消)', (
    tester,
  ) async {
    final api = installFakeApi();
    api.projects.listStaged = <Project>[
      Project(id: 'p1', name: '婚礼A', code: 'WED', isPinned: true),
      Project(id: 'p2', name: '写字楼B', code: 'OFF'),
    ];
    session.me = Me(id: 'u1', name: 'Evan'); // 非 admin
    addTearDown(_reset);
    await _pumpPage(tester);
    expect(_pinIcon('p1'), findsOneWidget, reason: '前置:已置顶有图钉');

    await tester.longPress(find.text('婚礼A'));
    await tester.pumpAndSettle();
    expect(find.text('取消置顶'), findsOneWidget, reason: 'isPinned=true 切换文案');

    api.projects.listStaged = <Project>[
      Project(id: 'p2', name: '写字楼B', code: 'OFF'),
      Project(id: 'p1', name: '婚礼A', code: 'WED'),
    ];
    await tester.tap(find.text('取消置顶'));
    await tester.pumpAndSettle();

    expect(api.projects.unpinCalls, ['p1'], reason: '已置顶 → 调 unpin');
    expect(api.projects.pinCalls, isEmpty);
    expect(api.projects.listCalls, 2, reason: '取消置顶成功后 _reload');
    expect(_cardOrder(tester), ['p2', 'p1'], reason: '取消后回原序');
    expect(_pinIcon('p1'), findsNothing, reason: '图钉标识随之消失');
  });

  testWidgets('置顶失败:pin 抛 ApiException → toast 透传文案;不重拉,顺序与图钉不变', (
    tester,
  ) async {
    final api = installFakeApi();
    api.projects.listStaged = <Project>[
      Project(id: 'p2', name: '写字楼B', code: 'OFF'),
      Project(id: 'p1', name: '婚礼A', code: 'WED'),
    ]; // 现状序(created_at desc):p2 在前
    session.me = Me(id: 'u1', name: 'Evan'); // 非 admin(仅见置顶项)
    addTearDown(_reset);
    await _pumpPage(tester);
    expect(api.projects.listCalls, 1);
    expect(_pinIcon('p1'), findsNothing, reason: '前置:未置顶无图钉');

    api.projects.pinStaged = ApiException(500, '置顶失败');
    await tester.longPress(find.text('婚礼A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('置顶到最前'));
    await tester.pumpAndSettle();

    expect(api.projects.pinCalls, ['p1'], reason: '请求已发出(失败在响应端)');
    expect(
      find.text('置顶失败'),
      findsOneWidget,
      reason: '失败 toast,ApiException 透传 e.message',
    );
    expect(api.projects.listCalls, 1, reason: '失败不走 _reload,列表不重拉');
    expect(_cardOrder(tester), ['p2', 'p1'], reason: '失败不翻本地标记,顺序不变');
    expect(_pinIcon('p1'), findsNothing, reason: '失败不显图钉');
    // 收尾:排空 toast duration Timer(照 pages_polish_test 先例)
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('取消置顶失败:unpin 抛 ApiException → toast 透传文案;不重拉,顺序与图钉不变', (
    tester,
  ) async {
    final api = installFakeApi();
    api.projects.listStaged = <Project>[
      Project(id: 'p1', name: '婚礼A', code: 'WED', isPinned: true),
      Project(id: 'p2', name: '写字楼B', code: 'OFF'),
    ];
    session.me = Me(id: 'u1', name: 'Evan'); // 非 admin 同样可取消置顶
    addTearDown(_reset);
    await _pumpPage(tester);
    expect(api.projects.listCalls, 1);
    expect(_pinIcon('p1'), findsOneWidget, reason: '前置:已置顶有图钉');

    api.projects.unpinStaged = ApiException(500, '取消置顶失败');
    await tester.longPress(find.text('婚礼A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消置顶'));
    await tester.pumpAndSettle();

    expect(api.projects.unpinCalls, ['p1'], reason: '请求已发出(失败在响应端)');
    expect(
      find.text('取消置顶失败'),
      findsOneWidget,
      reason: '失败 toast,ApiException 透传 e.message',
    );
    expect(api.projects.listCalls, 1, reason: '失败不走 _reload,列表不重拉');
    expect(_cardOrder(tester), ['p1', 'p2'], reason: '失败不翻本地标记,置顶序不变');
    expect(_pinIcon('p1'), findsOneWidget, reason: '失败图钉保留');
    // 收尾:排空 toast duration Timer
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('ProjectCard 组件级:图钉标识仅 isPinned 显示', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ProjectCard(
                key: const ValueKey('project_p1'),
                project: Project(
                  id: 'p1',
                  name: '婚礼A',
                  code: 'WED',
                  isPinned: true,
                ),
              ),
              ProjectCard(
                key: const ValueKey('project_p2'),
                project: Project(id: 'p2', name: '写字楼B', code: 'OFF'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(_pinIcon('p1'), findsOneWidget, reason: '已置顶 → 金色图钉(B5)');
    expect(_pinIcon('p2'), findsNothing, reason: '未置顶 → 无图钉');
  });
}
