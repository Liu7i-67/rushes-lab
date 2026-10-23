/// 新建项目表单单测(B6 测试功能点 4):总闸门 is_project_creator;必填校验
/// (bucket/admin)/code pattern;权限模板条目展开为 initial_grants 行+增删改;
/// 目录模板选中提交 folder_template_id;艺人账号(闸门显隐+停顿预检+一次性
/// 密码回显);成功失效 projects scope。B6 批补:创建失败 409/500 三分归因
/// (P1-1)/提交防重(P2-1)/目录模板可回退(P2-3)。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart'
    show Headers, HttpClientAdapter, RequestOptions, ResponseBody;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/projects/folder_template_field.dart';
import 'package:ms_app/features/projects/initial_grants_field.dart';
import 'package:ms_app/features/projects/new_project_sheet.dart';
import 'package:ms_app/features/projects/project_create_fail.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';
import '../helpers/fake_apis_b6.dart';

Widget _host() => MaterialApp(
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
);

void main() {
  testWidgets('无 is_project_creator 闸门:不渲染表单,展示无权提示', (tester) async {
    installFakeApi();
    addTearDown(() => session.api = null);
    session.me = Me(
      id: 'u1',
      name: '甲',
      isSystemAdmin: false,
      isProjectCreator: false,
    );

    await tester.pumpWidget(_host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('当前账号暂无新建项目权限'), findsOneWidget);
    expect(find.text('项目编码(小写字母/数字/-)'), findsNothing);
  });

  testWidgets('必填校验+code pattern 前端拦下(不发请求);默认管理员=自己', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    session.me = Me(id: 'me1', name: '甲', isProjectCreator: true);

    await tester.pumpWidget(_host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 项目管理员预置自己(value chip + 候选行,多处理)
    expect(find.text('甲(自己)'), findsWidgets);
    expect(find.text('你本人将作为项目管理员'), findsOneWidget);
    // 墨金重做:吸底=取消 ghost + 创建项目主金
    expect(find.widgetWithText(OutlinedButton, '取消'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '创建项目'), findsOneWidget);
    // D6 钉子:表单字段 isDense=false(浮起 label 不裁切)
    final nameField = tester.widget<TextField>(
      find.widgetWithText(TextField, '项目名称'),
    );
    expect(
      nameField.decoration?.isDense,
      isFalse,
      reason: 'AppTextField 标签不裁切(isDense:false)',
    );

    // 空表单提交 → 名称校验拦
    await tester.tap(find.text('创建项目'));
    await tester.pump();
    expect(find.textContaining('请输入项目名称'), findsOneWidget);
    expect(api.projectsOps.createCalls, isEmpty);
    // 清掉 SnackBar(入场动画完成 → 计时器才起 → 到期退场):不排空会吞下一条
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // 名称+非法 code → pattern 拦(大写)
    await tester.enterText(find.widgetWithText(TextField, '项目名称'), '项目A');
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextField, '项目编码(小写字母/数字/-)'),
      'AB',
    );
    await tester.pump();
    await tester.tap(find.text('创建项目'));
    await tester.pump();
    expect(find.textContaining('编码仅限小写字母/数字'), findsOneWidget);
    await tester.pump(); // 先补一帧让 SnackBar 入场动画完成(计时器在完成后才起)
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    // 合法 code → admin 缺省已预置,但 bucket 默认 ms-dev → 应放行到 API 层
    await tester.enterText(
      find.widgetWithText(TextField, '项目编码(小写字母/数字/-)'),
      'demo-2026',
    );
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, '项目名称'), '演示项目');
    await tester.pump();
    await tester.tap(find.text('创建项目'));
    await tester.pumpAndSettle();

    final call = api.projectsOps.createCalls.single;
    expect(call['code'], 'demo-2026');
    expect(call['minio_bucket'], 'ms-dev', reason: '高级折叠默认 ms-dev');
    expect(call['admin_user_id'], 'me1', reason: '默认 admin=创建者');
  });

  // 第四批 A2/A5:bucket 由自由输入改为只读下拉(web NewProjectModal 同款)。
  // 原「限长 63 + 计数器」用例随自由输入一起废止(P2-D2 语义由只读下拉替代:
  // 可达值收敛到 kMinioBuckets,不再有超长输入面)。此处改写为等价验证:
  // 只读形态 → 点按弹层 → 选中回显 → 提交值恒为 value('ms-dev')。
  testWidgets('bucket 为只读下拉(A2/A5):无 maxLength 计数器、输入不生效;'
      '点按弹层选中回显,提交 minio_bucket=ms-dev', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    session.me = Me(id: 'me1', name: '甲', isProjectCreator: true);

    await tester.pumpWidget(_host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 展开「高级」露出 bucket 字段:只读 PickerField,回显默认桶 label
    await tester.tap(find.text('高级'));
    await tester.pumpAndSettle();
    final bucketField = find.widgetWithText(TextField, 'MinIO bucket(必填)');
    expect(bucketField, findsOneWidget);
    expect(
      tester.widget<TextField>(bucketField).readOnly,
      isTrue,
      reason: 'bucket 不再是自由输入框(A2:改 PickerField)',
    );
    expect(
      tester.widget<TextField>(bucketField).controller!.text,
      'ms-dev(开发环境)',
    );
    expect(
      find.textContaining('/63'),
      findsNothing,
      reason: '原 maxLength=63 计数器随自由输入移除',
    );

    // 点按字段 → 弹层出现唯一选项(含关闭钮)
    await tester.tap(bucketField);
    await tester.pumpAndSettle();
    expect(find.text('选择 MinIO bucket'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'ms-dev(开发环境)'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsWidgets);

    // 选中 → 弹层关闭、字段回显 label
    await tester.tap(find.widgetWithText(ListTile, 'ms-dev(开发环境)'));
    await tester.pumpAndSettle();
    expect(find.text('选择 MinIO bucket'), findsNothing);
    expect(
      tester.widget<TextField>(bucketField).controller!.text,
      'ms-dev(开发环境)',
    );

    // 提交请求体走 value(落库值),不是 label
    await tester.enterText(find.widgetWithText(TextField, '项目名称'), '项目A');
    await tester.enterText(
      find.widgetWithText(TextField, '项目编码(小写字母/数字/-)'),
      'demo-2026',
    );
    await tester.pump();
    await tester.tap(find.text('创建项目'));
    await tester.pumpAndSettle();
    expect(api.projectsOps.createCalls.single['minio_bucket'], 'ms-dev');
  });

  testWidgets('权限模板展开为 initial_grants 行(可增删改);目录模板选中提交 id;'
      '成功失效 projects', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi();
    api.adminTemplates.grantResult = [
      GrantTemplate(
        id: 't1',
        name: '标准项目',
        isDefault: true,
        items: [
          GrantTemplateItem(
            kind: 'group',
            id: 'g1',
            roles: ['viewer', 'uploader'],
            name: '后期组',
            missing: false,
          ),
        ],
      ),
    ];
    api.adminTemplates.folderResult = [
      FolderTemplate(
        id: 'ft1',
        name: '婚礼标准目录',
        entryCount: 2,
        entries: [
          FolderTemplateEntry(path: '成片'),
          FolderTemplateEntry(path: '素材'),
        ],
      ),
    ];
    addTearDown(() => session.api = null);
    session.me = Me(id: 'me1', name: '甲', isProjectCreator: true);
    var projects = 0;
    void onProjects() => projects++;
    RefreshBus.I.addListener('projects', onProjects);
    addTearDown(() => RefreshBus.I.removeListener('projects', onProjects));

    await tester.pumpWidget(_host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 选权限模板 → 弹层选择(I2:字段点按弹层,选即关即回填)→ 条目展开为行
    // (组行,角色已预勾)。字段初始为 hint 态,唯一可点
    await tester.tap(find.text('权限模板(可选)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标准项目(默认)'));
    await tester.pumpAndSettle();
    expect(find.text('后期组'), findsOneWidget);
    expect(find.text('1/50 行'), findsOneWidget);

    // 选目录模板:墨金版改 AppChip 横轨单选(含「空目录」)→ 点模板即选
    await tester.tap(find.text('婚礼标准目录(2 个目录)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('目录树预览'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '项目名称'), '演示');
    await tester.enterText(
      find.widgetWithText(TextField, '项目编码(小写字母/数字/-)'),
      'demo',
    );
    await tester.pump();
    await tester.tap(find.text('创建项目'));
    await tester.pumpAndSettle();

    final call = api.projectsOps.createCalls.single;
    expect(call['initial_grants'], [
      {
        'kind': 'group',
        'id': 'g1',
        'roles': ['viewer', 'uploader'],
      },
    ], reason: '模板条目展开为 initial_grants 行提交(无模板 id 入参)');
    expect(call['folder_template_id'], 'ft1');
    expect(call['artist_account'], isNull);
    expect(projects, greaterThan(0));
  });

  testWidgets('艺人账号:闸门关闭不渲染;开启时停顿预检冲突提示+成功一次性密码回显', (tester) async {
    tester.view.physicalSize = const Size(900, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi();
    api.users.usernameStaged = {'chenming': false, 'chenming2': true};
    api.projectsOps.createStaged = ProjectCreated(
      id: 'np1',
      name: '演示',
      code: 'demo',
      artistAccount: ArtistAccountCreated(
        userId: 'u9',
        username: 'chenming2',
        name: '陈明',
        temporaryPassword: 'OneTime-123',
      ),
    );
    addTearDown(() => session.api = null);
    session.me = Me(
      id: 'me1',
      name: '甲',
      isProjectCreator: true,
      isArtistAccountCreator: true,
    );

    await tester.pumpWidget(_host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('开通艺人账号'), findsOneWidget);

    // 登录名停顿 500ms 预检 → 已占用 → 冲突提示
    await tester.enterText(find.widgetWithText(TextField, '项目名称'), '演示');
    await tester.enterText(
      find.widgetWithText(TextField, '项目编码(小写字母/数字/-)'),
      'demo',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '艺人登录名(字母/数字/._-,2-64 位)'),
      'chenming',
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(api.users.usernameAvailableCalls, ['chenming']);
    expect(find.textContaining('该登录名已被占用'), findsOneWidget);

    // 换可用登录名+姓名 → 提交成功 → 一次性密码面板
    await tester.enterText(
      find.widgetWithText(TextField, '艺人登录名(字母/数字/._-,2-64 位)'),
      'chenming2',
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '艺人姓名(填写后自动带入项目名称,手改项目名后脱钩)'),
      '陈明',
    );
    await tester.pump();
    await tester.tap(find.text('创建项目'));
    await tester.pumpAndSettle();

    final call = api.projectsOps.createCalls.single;
    expect(call['artist_account'], {'username': 'chenming2', 'name': '陈明'});
    expect(find.text('项目与艺人账号已创建'), findsOneWidget);
    expect(find.text('OneTime-123'), findsOneWidget, reason: '一次性密码回显');
    expect(find.textContaining('仅展示这一次'), findsOneWidget);

    await tester.tap(find.text('我已保存,进入项目'));
    await tester.pumpAndSettle();
  });

  // ── B6 批补充(P1-1 / P2-1 / P2-3)──────────────────────────────────────────

  group('P1-1 创建失败文案归因 projectCreateFailCopy(web NewProjectModal 三分口径)', () {
    test('code 冲突:409 detail 字符串原样透出,不误归登录名', () {
      final e = ApiException(
        409,
        extractDetail(const {'detail': '项目 code 已存在'}, 'fallback'),
      );
      expect(e.message, '项目 code 已存在');
      expect(projectCreateFailCopy(e), '项目 code 已存在');
      expect(projectCreateFailCopy(e), isNot(contains('登录名')));
    });

    test('username_taken 预检:409 对象 detail 渲染 code token → 登录名引导', () {
      // B9 起对象型 detail 经 extractDetail 渲染为友好文案:无 message 字段时
      // 只保留 code token(projects.py :262-266;归因判据走 raw 兜底)
      final msg = extractDetail(const {
        'detail': {'code': 'username_taken', 'username': 'evan'},
      }, 'fallback');
      expect(msg, 'username_taken');
      final copy = projectCreateFailCopy(ApiException(409, msg));
      expect(copy, contains('登录名已被占用'));
      expect(copy, contains('更换登录名'));
      expect(copy, isNot(contains('项目已创建')), reason: '预检阶段项目未建');
    });

    test('竞态 409(raw detail 含 project_id)→ 项目已建/艺人未建引导', () {
      // B9:project_id 归因判据改读 ApiException.raw(渲染文案只留 code token,
      // 不再携带结构化字段名)
      final copy = projectCreateFailCopy(
        ApiException(
          409,
          'username_taken',
          raw: const {
            'detail': {
              'code': 'username_taken',
              'username': 'evan',
              'project_id': 'p1',
            },
          },
        ),
      );
      expect(copy, contains('项目已创建'));
      expect(copy, contains('艺人账号未能建立'));
    });

    test('其余 409/500 → 中性引导(P2-5 艺人段 500 同文案)', () {
      const neutral = '创建过程出现异常，请到项目列表确认项目是否已创建';
      expect(projectCreateFailCopy(ApiException(409, '并发冲突')), neutral);
      expect(
        projectCreateFailCopy(ApiException(500, 'Internal Server Error')),
        neutral,
      );
      // 500 竞态回滚等结构化 detail 亦归中性(状态码优先收窄)
      expect(
        projectCreateFailCopy(ApiException(500, 'username_taken')),
        neutral,
        reason: '500 不按登录名冲突引导',
      );
    });

    test('非 409/500 状态码原样透传(422 校验错/403 等)', () {
      expect(
        projectCreateFailCopy(ApiException(422, 'code: field required')),
        'code: field required',
      );
      expect(projectCreateFailCopy(ApiException(403, '无权限')), '无权限');
    });
  });

  testWidgets('P2-1 提交防重:create in-flight 期间连点只发一次请求', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = _GatedMsApi();
    session.api = api;
    addTearDown(() => session.api = null);
    session.me = Me(id: 'me1', name: '甲', isProjectCreator: true);

    await tester.pumpWidget(_host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '项目名称'), '演示');
    await tester.enterText(
      find.widgetWithText(TextField, '项目编码(小写字母/数字/-)'),
      'demo',
    );
    await tester.pump();

    // 第一次点击发出 create 并挂起;第二次点击被 _submitting 守卫拦下
    api.gatedOps.createGate = Completer<void>();
    await tester.tap(find.text('创建项目'));
    await tester.tap(find.text('创建项目'));
    await tester.pump();
    expect(
      api.gatedOps.createCalls,
      hasLength(1),
      reason: '_submitting 守卫拦下 in-flight 连点',
    );

    api.gatedOps.createGate!.complete();
    await tester.pumpAndSettle();
    expect(api.gatedOps.createCalls, hasLength(1), reason: '放行后也不补发');
    expect(find.text('创建项目'), findsNothing, reason: '成功后面板关闭');
  });

  testWidgets('P2-3 目录模板可回退:选中后再选「不使用模板(默认)」→ onChanged(null) 预览消失'
      '(I2:原下拉 null 项语义在弹层中保留)', (tester) async {
    final api = installFakeApi();
    api.adminTemplates.folderResult = [
      FolderTemplate(
        id: 'ft1',
        name: '婚礼标准目录',
        entryCount: 2,
        entries: [
          FolderTemplateEntry(path: '成片'),
          FolderTemplateEntry(path: '素材'),
        ],
      ),
    ];
    addTearDown(() => session.api = null);

    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return FolderTemplateField(
                value: selected,
                onChanged: (v) => setState(() => selected = v),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 初始「空目录」chip 选中(等同旧 hint 态);点模板 chip 即选
    await tester.tap(find.text('婚礼标准目录(2 个目录)'));
    await tester.pumpAndSettle();
    expect(selected, 'ft1');
    expect(find.textContaining('目录树预览'), findsOneWidget);

    // 回退:点「空目录」chip → onChanged(null),预览消失
    await tester.tap(find.text('空目录'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(find.textContaining('目录树预览'), findsNothing);
  });

  testWidgets('I2 授权模板:字段点按弹层→搜索→选择回填(行展开);'
      '回退「不使用模板」清空', (tester) async {
    final api = installFakeApi();
    api.adminTemplates.grantResult = [
      GrantTemplate(
        id: 't1',
        name: '标准项目',
        isDefault: true,
        items: [
          GrantTemplateItem(
            kind: 'group',
            id: 'g1',
            roles: ['viewer'],
            name: '后期组',
            missing: false,
          ),
        ],
      ),
      GrantTemplate(
        id: 't2',
        name: '婚礼模板',
        isDefault: false,
        items: [
          GrantTemplateItem(
            kind: 'user',
            id: 'u1',
            roles: ['viewer'],
            name: '甲',
            missing: false,
          ),
        ],
      ),
    ];
    addTearDown(() => session.api = null);

    List<GrantRowData> rows = const [];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return InitialGrantsField(
                value: rows,
                onChanged: (v) => setState(() => rows = v),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 字段 hint 态点按 → 弹层 → 搜索过滤 → 选择「婚礼模板」
    await tester.tap(find.text('权限模板(可选)'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(TextField),
      ),
      '婚礼',
    );
    await tester.pump();
    // 行断言限定弹层范围(字段本体在遮罩后仍在树里)
    Finder sheetRow(String label) => find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text(label),
    );
    expect(sheetRow('标准项目(默认)'), findsNothing, reason: '搜索过滤');
    await tester.tap(sheetRow('婚礼模板'));
    await tester.pumpAndSettle();
    expect(rows, hasLength(1), reason: '模板条目展开为 initial_grants 行');
    expect(rows.single.name, '甲');
    expect(
      find.widgetWithText(TextField, '婚礼模板'),
      findsOneWidget,
      reason: '字段回填所选模板',
    );

    // 重开弹层 → 回退「不使用模板」→ 行清空(PickerOption 语义:选中 null 项)
    await tester.tap(find.widgetWithText(TextField, '婚礼模板'));
    await tester.pumpAndSettle();
    await tester.tap(sheetRow('不使用模板'));
    await tester.pumpAndSettle();
    expect(rows, isEmpty, reason: '「不使用模板」清空重来(原下拉语义)');
  });

  testWidgets('端到端:mock 500 → guard5xx 转 ApiException,sheet 显中性引导文案'
      '(不出现 DioException 字样)', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 真实 MsApi/ProjectOpsApi(走 guard5xx);testWidgets 的 FakeAsync 区无法起
    // 真实 socket,替换 Dio adapter 桩出 500——badResponse 仍经真实 dio 链路
    // (validateStatus 只放行 <500 → DioException → guard5xx 转 ApiException)。
    final api = MsApi(baseUrl: 'http://stub.local');
    api.http.httpClientAdapter = _StubProjectCreateAdapter();
    session.api = api;
    addTearDown(() => session.api = null);
    session.me = Me(id: 'me1', name: '甲', isProjectCreator: true);

    await tester.pumpWidget(_host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '项目名称'), '演示');
    await tester.enterText(
      find.widgetWithText(TextField, '项目编码(小写字母/数字/-)'),
      'demo',
    );
    await tester.pump();
    await tester.tap(find.text('创建项目'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('创建过程出现异常，请到项目列表确认项目是否已创建'),
      findsOneWidget,
      reason: '500 经 guard5xx 转 ApiException → projectCreateFailCopy 中性引导',
    );
    expect(
      find.textContaining('DioException'),
      findsNothing,
      reason: '§4.1 勿渲染原始异常对象(修复前 5xx 裸渲染 DioException)',
    );
    expect(find.textContaining('创建失败'), findsOneWidget);

    // 清掉 SnackBar(到期退场计时器),不留 pending timer
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}

/// P2-1 测试专用:create 可挂起的假 projectsOps(Completer 放行)。
class _GatedProjectOpsApi extends FakeProjectOpsApi {
  _GatedProjectOpsApi(super.api);

  Completer<void>? createGate;

  @override
  Future<ProjectCreated> create({
    required String code,
    required String name,
    required String minioBucket,
    required String adminUserId,
    String? description,
    List<GrantEntry>? initialGrants,
    String? folderTemplateId,
    ({String username, String name})? artistAccount,
  }) async {
    final gate = createGate;
    if (gate == null) {
      return super.create(
        code: code,
        name: name,
        minioBucket: minioBucket,
        adminUserId: adminUserId,
        description: description,
        initialGrants: initialGrants,
        folderTemplateId: folderTemplateId,
        artistAccount: artistAccount,
      );
    }
    // 先记录调用再挂起,in-flight 期间可断言 createCalls
    final f = super.create(
      code: code,
      name: name,
      minioBucket: minioBucket,
      adminUserId: adminUserId,
      description: description,
      initialGrants: initialGrants,
      folderTemplateId: folderTemplateId,
      artistAccount: artistAccount,
    );
    await gate.future;
    return f;
  }
}

class _GatedMsApi extends FakeMsApi {
  _GatedMsApi();

  late final _GatedProjectOpsApi gatedOps = _GatedProjectOpsApi(this);

  @override
  FakeProjectOpsApi get projectsOps => gatedOps;
}

/// 端到端 500 桩 adapter:POST /api/v1/projects 固定回 500(裸服务端英文
/// detail),其余端点回 200 [](UserPicker/模板字段等附带的加载各自 catch)。
/// 替换 HttpClientAdapter 而非覆写 API 方法,让 create 走真实 dio→guard5xx
/// 链路(FakeAsync 区无真实 socket,响应纯微任务推进,无计时器挂起)。
class _StubProjectCreateAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final isCreate =
        options.method == 'POST' && options.uri.path == '/api/v1/projects';
    return ResponseBody.fromString(
      isCreate ? '{"detail":"Internal Server Error"}' : '[]',
      isCreate ? 500 : 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
