/// B9 测试功能点 2:新建备份任务向导——源目录必选(网盘树选定,根目录不可作
/// 源)/项目仅列可上传(admin/uploader)/承接夹选择(项目根=自动创建承接夹,
/// 敏感夹及其子树禁选)/提交入参=实码({source_dir,project_id[,target_folder_id]})/
/// 成功后失效任务列表刷新(RefreshBus 'baidu-tasks')。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/api/baidu_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/baidu/baidu_new_task_page.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';
import '../helpers/fake_baidu.dart';

/// 向导假 API:projects/folders 走 FakeMsApi,baidu 域覆写为替身适配器
/// (网盘树选择器读 session.api!.baidu,与向导注入同源)。
class _WizardFakeApi extends FakeMsApi {
  _WizardFakeApi(this.baiduOverride);

  final BaiduApi baiduOverride;

  @override
  BaiduApi get baidu => baiduOverride;
}

void main() {
  Future<void> pumpWizard(WidgetTester tester, FakeBaiduAdapter adapter,
      {List<Project> projects = const [], List<Folder> folders = const []}) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final baidu = baiduApiWith(adapter);
    final api = installFakeApi(_WizardFakeApi(baidu));
    addTearDown(() => session.api = null);
    api.projects.listStaged = projects;
    api.folders.listResult = folders;
    // 宿主页承载(生产形态:向导自页面 push,pop 后 snackbar 由宿主 Scaffold 承接)
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
  }

  testWidgets('无可用项目(空列表):步骤二给出空态提示且提交拦截', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.query['path'] == '/') {
        return netdiskJson([entry('/照片', '照片')]);
      }
      return (201, taskJson('t-new'));
    });
    await pumpWizard(tester, adapter, projects: []);

    // 步骤一:浏览 → 选目录 → 自动进步骤二
    await tester.tap(find.text('浏览网盘选目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('照片'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('确定'));
    await tester.pumpAndSettle();
    expect(find.text('新建备份任务 · 选目标'), findsOneWidget);
    expect(find.text('无可用项目(需具备项目上传权限)'), findsOneWidget);

    // 提交拦截:项目必选
    await tester.tap(find.text('开始备份'));
    await tester.pumpAndSettle();
    expect(find.text('请选择目标项目'), findsOneWidget);
    expect(adapter.calls.any((c) => c.method == 'POST'), isFalse,
        reason: '校验不过不发请求');
  });

  testWidgets('提交入参=实码:项目根默认承接(无 target_folder_id);成功后弹提示并返回',
      (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.query['path'] == '/') {
        return netdiskJson([entry('/照片', '照片')]);
      }
      return (201, taskJson('t-new'));
    });
    var invalidated = 0;
    RefreshBus.I.addListener('baidu-tasks', () => invalidated++);
    addTearDown(() => RefreshBus.I.removeListener('baidu-tasks',
        () => invalidated++));

    await pumpWizard(tester, adapter, projects: [
      Project(id: 'p1', name: '项目一', code: 'P1', myRoles: ['admin']),
    ]);

    await tester.tap(find.text('浏览网盘选目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('照片'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('确定'));
    await tester.pumpAndSettle();

    expect(find.text('目标项目(仅列出你可上传的项目)'), findsOneWidget);
    expect(find.text('项目根'), findsOneWidget, reason: '默认目标=项目根(自动承接夹)');

    await tester.tap(find.text('开始备份'));
    await tester.pumpAndSettle();

    final post = adapter.calls
        .lastWhere((c) => c.method == 'POST' && c.path.endsWith('/backup/tasks'));
    expect(post.body['source_dir'], '/照片');
    expect(post.body['project_id'], 'p1');
    expect(post.body.containsKey('target_folder_id'), isFalse,
        reason: '项目根=不传 target_folder_id(后端自动创建承接夹)');
    expect(find.text('备份任务已创建,清单准备中;已有任务执行中时,新任务将排队,'
        '前序完成后约数分钟至一刻钟内自动开始'), findsOneWidget);
    expect(invalidated, greaterThanOrEqualTo(1), reason: '成功后失效任务列表');
  });

  testWidgets('承接夹=选定文件夹:入参携带 target_folder_id;敏感夹及子树禁选',
      (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.query['path'] == '/') {
        return netdiskJson([entry('/照片', '照片')]);
      }
      return (201, taskJson('t-new'));
    });
    await pumpWizard(tester, adapter, projects: [
      Project(id: 'p1', name: '项目一', code: 'P1', myRoles: ['uploader']),
    ], folders: [
      Folder(id: 'f1', name: '普通夹', parentFolderId: null, projectId: 'p1'),
      Folder(id: 'fs', name: '敏感夹', parentFolderId: null, projectId: 'p1',
          isSensitive: true),
      Folder(id: 'fs2', name: '敏感子夹', parentFolderId: 'fs', projectId: 'p1'),
    ]);

    await tester.tap(find.text('浏览网盘选目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('照片'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('确定'));
    await tester.pumpAndSettle();

    expect(find.text('普通夹'), findsOneWidget);
    expect(find.text('敏感夹'), findsNothing, reason: '敏感夹整棵子树禁选');
    expect(find.text('敏感子夹'), findsNothing);

    await tester.tap(find.text('普通夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始备份'));
    await tester.pumpAndSettle();

    final post = adapter.calls
        .lastWhere((c) => c.method == 'POST' && c.path.endsWith('/backup/tasks'));
    expect(post.body['target_folder_id'], 'f1');
  });

  testWidgets('文件夹列表加载失败:错误态+重试,不伪装成空夹选择器(P2-2)',
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
      Project(id: 'p1', name: '项目一', code: 'P1', myRoles: ['admin']),
    ];
    api.folders.listStaged = ApiException(500, '服务器开小差了');

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
    await tester.tap(find.text('浏览网盘选目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('照片'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('确定'));
    await tester.pumpAndSettle();

    // 失败显式呈现:错误文案(detail 透传)+重试,不冒充「项目暂无文件夹」空态
    expect(find.text('服务器开小差了'), findsOneWidget,
        reason: '500 detail 透传(errorMessage 收敛口径)');
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('项目根'), findsNothing,
        reason: '失败不得回落到空 folders 的选择器(只剩项目根=误导)');
    expect(find.text('普通夹'), findsNothing);

    // 重试成功后恢复选择器
    api.folders.listStaged = null;
    api.folders.listResult = [
      Folder(id: 'f1', name: '普通夹', parentFolderId: null, projectId: 'p1'),
    ];
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('文件夹列表加载失败'), findsNothing);
    expect(find.text('普通夹'), findsOneWidget);
  });

  testWidgets('非可上传项目不入列(is_system_admin 之外的闸门)', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.query['path'] == '/') {
        return netdiskJson([entry('/照片', '照片')]);
      }
      return (201, taskJson('t-new'));
    });
    await pumpWizard(tester, adapter, projects: [
      Project(id: 'p-view', name: '只读项目', code: 'V', myRoles: ['viewer']),
      Project(id: 'p-up', name: '可传项目', code: 'U', myRoles: ['uploader']),
    ]);

    await tester.tap(find.text('浏览网盘选目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('照片'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('确定'));
    await tester.pumpAndSettle();

    // 下拉默认选第一个可用项目;只读项目不出现在选项
    await tester.tap(find.text('可传项目'));
    await tester.pumpAndSettle();
    expect(find.text('只读项目'), findsNothing,
        reason: 'viewer 项目不在可承接列表');
  });
}
