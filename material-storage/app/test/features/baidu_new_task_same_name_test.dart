/// qdev 2026-11-18 §5 D/§10:新建备份任务向导【创建同名文件夹】开关 widget 测试:
/// 默认不选 / 项目根模式置灰(F4)/ 选夹后可勾选 / 提交体口径——root 模式永不
/// 携带 create_same_name_folder(勾选态残留也不送)、夹+未勾不送、夹+勾选送 true。
/// harness 复用 baidu_new_task_test 同款(FakeBaiduAdapter 拦截 dio,提交体可断言)。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/baidu_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/baidu/baidu_new_task_page.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';
import '../helpers/fake_baidu.dart';

/// 向导假 API:projects/folders 走 FakeMsApi,baidu 域覆写为替身适配器。
class _WizardFakeApi extends FakeMsApi {
  _WizardFakeApi(this.baiduOverride);

  final BaiduApi baiduOverride;

  @override
  BaiduApi get baidu => baiduOverride;
}

/// 开关探测:包 D 计划用 Switch.adaptive(测试平台 android → Material Switch);
/// 兼容 CupertinoSwitch / SwitchListTile 内层 Switch,避免与实现形态耦合。
Finder _switchFinder() => find.byWidgetPredicate(
      (w) => w is Switch || w is CupertinoSwitch,
    );

bool _switchOn(WidgetTester tester) {
  final w = tester.widget(_switchFinder());
  return w is Switch ? w.value : (w as CupertinoSwitch).value;
}

/// 置灰判定:onChanged 为 null 即 disabled(Switch 与 CupertinoSwitch 同语义)。
bool _switchEnabled(WidgetTester tester) {
  final w = tester.widget(_switchFinder());
  return w is Switch
      ? w.onChanged != null
      : (w as CupertinoSwitch).onChanged != null;
}

void main() {
  Future<FakeMsApi> pumpWizard(
    WidgetTester tester,
    FakeBaiduAdapter adapter, {
    List<Project> projects = const [],
    List<Folder> folders = const [],
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final baidu = baiduApiWith(adapter);
    final api = installFakeApi(_WizardFakeApi(baidu));
    addTearDown(() => session.api = null);
    api.projects.listStaged = projects;
    api.folders.listResult = folders;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute(
                    builder: (_) => BaiduNewTaskPage(api: baidu),
                  ),
                ),
                child: const Text('open-wizard'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-wizard'));
    await tester.pumpAndSettle();
    return api;
  }

  FakeBaiduAdapter sourceAdapter() => FakeBaiduAdapter((req) async {
        if (req.query['path'] == '/') {
          return netdiskJson([entry('/照片', '照片')]);
        }
        return (201, taskJson('t-new'));
      });

  Future<void> pickSource(WidgetTester tester) async {
    await tester.tap(find.text('浏览网盘选目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('照片'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('确定'));
    await tester.pumpAndSettle();
  }

  Future<FakeBaiduAdapter> pumpToTargetStep(
    WidgetTester tester, {
    List<Folder> folders = const [],
  }) async {
    final adapter = sourceAdapter();
    await pumpWizard(
      tester,
      adapter,
      projects: [
        Project(id: 'p1', name: '项目一', code: 'P1', myRoles: ['admin']),
      ],
      folders: folders,
    );
    await pickSource(tester);
    return adapter;
  }

  FakeBaiduRequest? postedTask(FakeBaiduAdapter adapter) {
    for (final c in adapter.calls.reversed) {
      if (c.method == 'POST' && c.path.endsWith('/backup/tasks')) return c;
    }
    return null;
  }

  testWidgets('开关存在且默认不选;项目根模式置灰(F4)', (tester) async {
    await pumpToTargetStep(
      tester,
      folders: [
        Folder(id: 'f1', name: '普通夹', parentFolderId: null, projectId: 'p1'),
      ],
    );

    expect(_switchFinder(), findsOneWidget, reason: '目标区存在「创建同名文件夹」开关');
    expect(_switchOn(tester), isFalse, reason: '默认不选');
    expect(_switchEnabled(tester), isFalse, reason: '项目根模式置灰');

    // 置灰态点按不改变勾选态
    await tester.tap(_switchFinder());
    await tester.pump();
    expect(_switchOn(tester), isFalse);
  });

  testWidgets('选夹后可勾选;提交携带 create_same_name_folder=true + target_folder_id', (tester) async {
    final adapter = await pumpToTargetStep(
      tester,
      folders: [
        Folder(id: 'f1', name: '普通夹', parentFolderId: null, projectId: 'p1'),
      ],
    );
    await tester.tap(find.text('普通夹'));
    await tester.pumpAndSettle();

    expect(_switchEnabled(tester), isTrue, reason: '显式夹模式下开关可用');
    expect(_switchOn(tester), isFalse);

    await tester.tap(_switchFinder());
    await tester.pump();
    expect(_switchOn(tester), isTrue, reason: '选夹后可勾选');

    await tester.tap(find.text('开始备份'));
    await tester.pumpAndSettle();
    final post = postedTask(adapter);
    expect(post, isNotNull);
    expect(post!.body['create_same_name_folder'], isTrue);
    expect(post.body['target_folder_id'], 'f1');
    expect(find.text('备份任务已创建'), findsOneWidget);
  });

  testWidgets('选夹但未勾选:提交不携带该字段(缺省=现状行为)', (tester) async {
    final adapter = await pumpToTargetStep(
      tester,
      folders: [
        Folder(id: 'f1', name: '普通夹', parentFolderId: null, projectId: 'p1'),
      ],
    );
    await tester.tap(find.text('普通夹'));
    await tester.pumpAndSettle();
    expect(_switchOn(tester), isFalse);

    await tester.tap(find.text('开始备份'));
    await tester.pumpAndSettle();
    final post = postedTask(adapter);
    expect(post, isNotNull);
    expect(
      post!.body.containsKey('create_same_name_folder'),
      isFalse,
      reason: '不勾不上送字段(或送 false 语义等价,本断言按包 D 条件展开契约)',
    );
    expect(post.body['target_folder_id'], 'f1');
  });

  testWidgets('勾选后切回项目根再提交:仍不携带字段(root 永不送)', (tester) async {
    final adapter = await pumpToTargetStep(
      tester,
      folders: [
        Folder(id: 'f1', name: '普通夹', parentFolderId: null, projectId: 'p1'),
      ],
    );
    // 夹 + 勾选(勾选态残留场景)
    await tester.tap(find.text('普通夹'));
    await tester.pumpAndSettle();
    await tester.tap(_switchFinder());
    await tester.pump();
    expect(_switchOn(tester), isTrue);

    // 切回项目根 → 提交(root 模式下开关置灰,残留勾选态也不得上送)
    await tester.tap(find.text('项目根'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始备份'));
    await tester.pumpAndSettle();

    final post = postedTask(adapter);
    expect(post, isNotNull);
    expect(
      post!.body.containsKey('create_same_name_folder'),
      isFalse,
      reason: 'F4:项目根模式提交体永不携带该字段(后端静默归一不可被触发)',
    );
    expect(
      post.body.containsKey('target_folder_id'),
      isFalse,
      reason: '项目根=不传 target_folder_id(既有语义回归)',
    );
  });
}
