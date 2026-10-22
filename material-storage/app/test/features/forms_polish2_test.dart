/// app-polish-2(P2 批)表单交互验收用例(对应需求文档 2026-10-22-app-polish-2.md):
/// - I2(#6) 五处下拉换 PickerSheet(本文件至少覆盖三处):点表单字段弹
///   弹层(顶部搜索框+单选列表+当前项高亮+确认即选即关),搜索过滤,
///   选择回填中文标签/raw token 数据流不变;覆盖 audit_filter_bar 事件类型+
///   项目、baidu_new_task_page 目标项目、initial_grants_field 权限模板
///   (「不使用」语义保留);
/// - I3(#5) 新建项目高度与取消可见性:SheetScaffold maxHeightFactor 0.85
///   (传参+几何断言);把手拖拽关闭触发未保存确认层(D2 守卫链回归锚)。
///
/// 套路:不 import 开发中的 picker_sheet——以页面行为断言(弹层用
/// find.byType(BottomSheet)/find.text 基础件);假 API 记录式(FakeMsApi)。
/// 凡依赖「尚未存在的行为」的断言标注 TODO(app-polish2 Ix): 现状应失败,
/// 交付后转绿。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/baidu_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/admin/audit_filter_bar.dart';
import 'package:ms_app/features/baidu/baidu_new_task_page.dart';
import 'package:ms_app/features/projects/initial_grants_field.dart';
import 'package:ms_app/features/projects/new_project_sheet.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/sheet_scaffold.dart';

import '../helpers/api_harness.dart';
import '../helpers/fake_baidu.dart';

// ── I2:audit_filter_bar(事件类型 + 项目)────────────────────────────────────

Widget _auditHost({
  String eventType = '',
  String projectId = '',
  required ValueChanged<String> onEventType,
  required ValueChanged<String> onProject,
}) {
  // 前置:先 installFakeApi(UserPicker 既有组件读会话 API)。
  // 宿主须自持筛选值并在回调里 setState(受控无状态组件,同 admin_audit_page)
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: StatefulBuilder(builder: (context, setState) {
          return AuditFilterBar(
            eventType: eventType,
            projectId: projectId,
            actor: null,
            day: null,
            projects: [
              Project(id: 'p1', name: '婚礼A', code: 'wed-a'),
              Project(id: 'p2', name: '写字楼B', code: 'off-b'),
            ],
            onEventTypeChanged: (v) {
              onEventType(v);
              setState(() => eventType = v);
            },
            onProjectChanged: (v) {
              onProject(v);
              setState(() => projectId = v);
            },
            onActorChanged: (_) {},
            onPickDate: () {},
            onClearDate: () {},
          );
        }),
      ),
    ),
  );
}

/// 弹层内的搜索框(PickerSheet 顶部 SearchField;现状为下拉菜单无弹层)。
Finder _sheetSearchField() => find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(TextField),
    );

void main() {
  testWidgets('I2:审计栏事件类型字段→弹层出现→搜索过滤→选择回填中文标签',
      (tester) async {
    installFakeApi();
    addTearDown(() => session.api = null);
    var event = '';
    await tester.pumpWidget(_auditHost(
      onEventType: (v) => event = v,
      onProject: (_) {},
    ));
    await tester.pump();

    await tester.tap(find.text('事件类型'));
    await tester.pumpAndSettle();

    // 已交付转绿(I2):PickerSheet 弹层(原 DropdownButtonFormField 菜单)
    expect(find.byType(BottomSheet), findsOneWidget,
        reason: 'I2:点事件类型字段弹 PickerSheet 弹层');
    expect(_sheetSearchField(), findsOneWidget, reason: 'I2:弹层顶部搜索框');

    // 搜索过滤:输入「传」只剩「上传」(标签「下载」被滤掉)
    await tester.enterText(_sheetSearchField(), '传');
    await tester.pumpAndSettle();
    expect(find.text('上传'), findsOneWidget, reason: 'I2:过滤后剩匹配项');
    expect(find.text('下载'), findsNothing, reason: 'I2:不匹配项被滤掉');

    await tester.tap(find.text('上传'));
    await tester.pumpAndSettle();
    expect(event, 'upload', reason: 'I2:选择回填 raw token(数据流不变)');
    expect(find.text('上传'), findsOneWidget, reason: 'I2:字段回显中文标签');
  });

  testWidgets('I2:审计栏项目字段→弹层搜索过滤→选择回填「名称(code)」',
      (tester) async {
    installFakeApi();
    addTearDown(() => session.api = null);
    var project = '';
    await tester.pumpWidget(_auditHost(
      onEventType: (_) {},
      onProject: (v) => project = v,
    ));
    await tester.pump();

    await tester.tap(find.text('按项目筛选(可选)'));
    await tester.pumpAndSettle();

    // 已交付转绿(I2):点项目字段弹 PickerSheet 弹层(原下拉菜单)
    expect(find.byType(BottomSheet), findsOneWidget,
        reason: 'I2:点项目字段弹 PickerSheet 弹层');

    await tester.enterText(_sheetSearchField(), '婚礼');
    await tester.pumpAndSettle();
    expect(find.text('婚礼A(wed-a)'), findsOneWidget);
    expect(find.text('写字楼B(off-b)'), findsNothing, reason: 'I2:项目列表被过滤');

    await tester.tap(find.text('婚礼A(wed-a)'));
    await tester.pumpAndSettle();
    expect(project, 'p1', reason: 'I2:选择回填项目 id');
    expect(find.text('婚礼A(wed-a)'), findsOneWidget,
        reason: 'I2:字段回显所选项目「名称(code)」');
  });

  // ── I2:baidu_new_task_page 目标项目 ───────────────────────────────────────
  testWidgets('I2:百度新建任务目标项目字段→弹层→搜索过滤→切换项目回显',
      (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.query['path'] == '/') {
        return netdiskJson([entry('/照片', '照片')]);
      }
      return (201, taskJson('t-new'));
    });
    final baidu = baiduApiWith(adapter);
    final api = installFakeApi(_WizardFakeApi(baidu));
    addTearDown(() => session.api = null);
    api.projects.listStaged = [
      Project(id: 'p-a', name: '可传项目A', code: 'A', myRoles: ['uploader']),
      Project(id: 'p-b', name: '写字楼B', code: 'B', myRoles: ['uploader']),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => BaiduNewTaskPage(api: baidu))),
              child: const Text('open-wizard'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open-wizard'));
    await tester.pumpAndSettle();
    // 步骤一:浏览 → 选目录 → 确认,进入步骤二(目标项目段)
    await tester.tap(find.text('浏览网盘选目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('照片'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('确定'));
    await tester.pumpAndSettle();
    expect(find.text('目标项目(仅列出你可上传的项目)'), findsOneWidget,
        reason: '前置:进入目标项目段');

    // 字段当前回显首个可用项目;点按弹 PickerSheet(不再下拉菜单)
    await tester.tap(find.text('可传项目A'));
    await tester.pumpAndSettle();

    // 已交付转绿(I2):目标项目点按弹 PickerSheet(原 DropdownButtonFormField)
    expect(find.byType(BottomSheet), findsOneWidget,
        reason: 'I2:点目标项目字段弹 PickerSheet 弹层');
    expect(_sheetSearchField(), findsOneWidget, reason: 'I2:弹层可搜索');

    await tester.enterText(_sheetSearchField(), '写');
    await tester.pumpAndSettle();
    await tester.tap(find.text('写字楼B'));
    await tester.pumpAndSettle();

    expect(find.text('写字楼B'), findsOneWidget,
        reason: 'I2:目标项目字段回显新选项目');
    expect(find.text('可传项目A'), findsNothing, reason: 'I2:旧选中值被替换');
  });

  // ── I2:initial_grants_field 权限模板(「不使用」语义保留)──────────────────
  testWidgets('I2:权限模板字段→弹层含「不使用模板」;选模板展开行,选不使用清空',
      (tester) async {
    final api = installFakeApi();
    api.adminTemplates.grantResult = [
      GrantTemplate(id: 't1', name: '标准模板', isDefault: false, items: [
        GrantTemplateItem(
            kind: 'group', id: 'g1', name: '后期组',
            roles: const ['viewer', 'uploader'], missing: false),
      ]),
    ];
    addTearDown(() => session.api = null);

    var rows = const <GrantRowData>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          return InitialGrantsField(
            value: rows,
            onChanged: (v) => setState(() => rows = v),
          );
        }),
      ),
    ));
    await tester.pumpAndSettle(); // 模板 Future 落定

    // 字段态:未选模板时显示「权限模板(可选)」(hint/label 两态同文案)
    await tester.tap(find.text('权限模板(可选)'));
    await tester.pumpAndSettle();

    // 已交付转绿(I2):权限模板点按弹 PickerSheet(原 DropdownButton)
    expect(find.byType(BottomSheet), findsOneWidget,
        reason: 'I2:点权限模板字段弹 PickerSheet 弹层');
    expect(find.text('不使用模板'), findsOneWidget,
        reason: 'I2:「不使用」语义项保留在候选');

    await tester.tap(find.text('标准模板'));
    await tester.pumpAndSettle();
    expect(rows, hasLength(1), reason: 'I2:选中模板展开条目为行');
    expect(find.text('后期组'), findsOneWidget);
    expect(find.text('标准模板'), findsOneWidget, reason: '字段回显所选模板');

    // 再开弹层选「不使用模板」→ 清空重来
    await tester.tap(find.text('标准模板'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget, reason: '再次弹层');
    await tester.tap(find.text('不使用模板'));
    await tester.pumpAndSettle();
    expect(rows, isEmpty, reason: 'I2:「不使用模板」=清空初始权限(null 语义)');
    expect(find.text('后期组'), findsNothing);
  });

  // ── I3:新建项目高度与取消可见性 ────────────────────────────────────────────
  testWidgets('I3:new_project sheet maxHeightFactor 0.85(传参+几何断言)',
      (tester) async {
    installFakeApi();
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    session.me = Me(id: 'me1', name: '甲', isProjectCreator: true);
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showNewProjectSheet(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('项目名称'), findsOneWidget, reason: '前置:长表单已挂载');

    // 已交付转绿(I3):SheetScaffold maxHeightFactor 0.9→0.85
    final scaffold = tester.widget<SheetScaffold>(find.byType(SheetScaffold));
    expect(scaffold.maxHeightFactor, 0.85, reason: 'I3:maxHeight 0.9→0.85');

    // 几何上限:弹层内容区不得超过屏高 85%(下界随表单内容高度浮动,不断言)
    final h = tester.getRect(find.byType(SheetScaffold)).height;
    expect(h, lessThanOrEqualTo(2000 * 0.851), reason: 'I3:不超过屏高 85%');
  });

  testWidgets('I3:把手拖拽关闭触发未保存确认弹层,确认后才真正关闭(D2 守卫链)',
      (tester) async {
    installFakeApi();
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    session.me = Me(id: 'me1', name: '甲', isProjectCreator: true);
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showNewProjectSheet(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '项目名称'), '项目A');
    await tester.pump();

    // 自 sheet 顶部把手区(滚动区之外)下滑 → 未保存确认层
    final topLeft = tester.getTopLeft(find.byType(BottomSheet));
    final size = tester.getSize(find.byType(BottomSheet));
    final g = await tester.startGesture(
        Offset(topLeft.dx + size.width / 2, topLeft.dy + 24));
    await g.moveBy(const Offset(0, 200));
    await g.moveBy(const Offset(0, 500));
    await g.up();
    await tester.pumpAndSettle();

    // TODO(app-polish2 I3): 把手拖拽关闭恢复后此链路保持;D2 守卫已落地,
    // 本用例为回归锚(现状应绿;若把手直关会红)
    expect(find.byType(AlertDialog), findsOneWidget,
        reason: 'I3:拖拽关闭触发未保存确认弹层');
    expect(find.text('放弃编辑?'), findsOneWidget);
    expect(find.widgetWithText(TextField, '项目名称'), findsOneWidget,
        reason: 'I3:确认前 sheet 不关闭');

    await tester.tap(find.text('放弃编辑'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '项目名称'), findsNothing,
        reason: 'I3:确认放弃后 sheet 关闭');
  });
}

/// 向导假 API(同 baidu_new_task_test):projects/folders 走 FakeMsApi,
/// baidu 域覆写为替身适配器。
class _WizardFakeApi extends FakeMsApi {
  _WizardFakeApi(this.baiduOverride);

  final BaiduApi baiduOverride;

  @override
  BaiduApi get baidu => baiduOverride;
}
