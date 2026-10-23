/// B9 测试功能点 3(详情侧):任务详情文件明细——key_conflict 失败行分流
/// 【随机后缀】直发 + 菜单【覆盖导入】(B8 baidu_file_actions 复用件回归)/
/// 普通失败行【重试】/non_retryable 置灰/状态 chips 筛选(服务端 status)/
/// skipped_exists 行覆盖导入确认文案/分页加载更多。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/baidu/baidu_task_files.dart';

import '../helpers/fake_baidu.dart';

Future<void> pumpFiles(
  WidgetTester tester,
  FakeBaiduAdapter adapter, {
  String taskStatus = 'failed',
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: BaiduTaskFiles(
          taskId: 't1',
          taskStatus: taskStatus,
          api: baiduApiWith(adapter),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('行操作分流:普通失败行重试;non_retryable 置灰「不可重试」', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      return {
        'items': [
          fileJson(
            'fd1',
            relPath: 'a.jpg',
            status: 'failed',
            lastError: 'download_failed: 网络抖动',
          ),
          fileJson(
            'fd2',
            relPath: 'b.jpg',
            status: 'failed',
            lastError: 'name_too_long: x',
            nonRetryable: true,
          ),
        ],
        'total': 2,
      };
    });
    await pumpFiles(tester, adapter);

    expect(find.text('重试'), findsOneWidget);
    final retryBtn = tester.widget<TextButton>(
      find.ancestor(of: find.text('重试'), matching: find.byType(TextButton)),
    );
    expect(retryBtn.onPressed, isNotNull);
    expect(find.text('不可重试'), findsOneWidget);
    final nrBtn = tester.widget<TextButton>(
      find.ancestor(of: find.text('不可重试'), matching: find.byType(TextButton)),
    );
    expect(nrBtn.onPressed, isNull, reason: '结构性失败重试置灰(web 同口径)');

    // 重试直发(无确认)
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(
      adapter.calls.any(
        (c) =>
            c.method == 'POST' &&
            c.path == '/api/v1/baidu/backup/tasks/t1/files/fd1/retry',
      ),
      isTrue,
    );
  });

  testWidgets('key_conflict 行分流:随机后缀直发 + 菜单覆盖导入(确认点名占用者)', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.path.endsWith('/random-suffix')) {
        return (202, {'finalized': true, 'status': 'enumerating'});
      }
      return {
        'items': [
          fileJson(
            'fk1',
            relPath: '冲突.jpg',
            status: 'failed',
            lastError: 'key_conflict:p1/f9/冲突.jpg 已被 成片.jpg占用',
          ),
        ],
        'total': 1,
      };
    });
    await pumpFiles(tester, adapter);

    expect(
      find.text('重试'),
      findsNothing,
      reason: 'key_conflict 行不显示普通重试(原样重试必再撞冲突)',
    );
    expect(find.text('随机后缀'), findsOneWidget);

    // 菜单 → 覆盖导入 → 确认文案点名占用者
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('覆盖导入'), findsOneWidget);
    expect(
      find.text(
        '将永久删除目标位置的原文件:成片.jpg,然后重新导入'
        '(需对该文件有管理权限)。',
      ),
      findsOneWidget,
      reason: 'key_conflict 确认文案解析 F1 占用者',
    );
    await tester.tap(find.text('覆盖导入'));
    await tester.pumpAndSettle();
    // 确认弹窗(B8 runFileAction)
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(
      adapter.calls.any(
        (c) =>
            c.method == 'POST' &&
            c.path == '/api/v1/baidu/backup/tasks/t1/files/fk1/overwrite',
      ),
      isTrue,
    );
  });

  testWidgets('skipped_exists 行(failed 任务):菜单覆盖导入;通用确认文案', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      return {
        'items': [
          fileJson('fs1', relPath: '已存在.jpg', status: 'skipped_exists'),
        ],
        'total': 1,
      };
    });
    await pumpFiles(tester, adapter);

    expect(find.text('随机后缀'), findsNothing);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('覆盖导入'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('将永久删除目标位置的原文件后重新导入'),
      findsOneWidget,
      reason: '无占用者信息回落通用确认文案',
    );
  });

  testWidgets('状态 chips:选「失败」带服务端 status 筛选;加载更多按 offset 翻页', (tester) async {
    var sawStatusFilter = false;
    final adapter = FakeBaiduAdapter((req) async {
      if (req.query['status'] == 'failed') sawStatusFilter = true;
      if ((req.query['offset'] ?? '0') == '0') {
        return {
          'items': [
            fileJson(
              'fd1',
              relPath: 'a.jpg',
              status: 'failed',
              lastError: 'download_failed: x',
            ),
          ],
          'total': 2,
        };
      }
      expect(req.query['offset'], '1');
      return {
        'items': [
          fileJson(
            'fd2',
            relPath: 'b.jpg',
            status: 'failed',
            lastError: 'download_failed: y',
          ),
        ],
        'total': 2,
      };
    });
    await pumpFiles(tester, adapter);
    expect(find.text('a.jpg'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget);

    // 点「失败」chip:服务端筛选重拉第一页
    await tester.tap(find.text('失败'));
    await tester.pumpAndSettle();
    expect(find.text('a.jpg'), findsOneWidget, reason: '筛选后重拉首页');

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('b.jpg'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    expect(sawStatusFilter, isTrue, reason: 'chips 选择走服务端 status 筛选');
  });

  testWidgets('目标已删除:回退源路径并标注;非本人无关字段不出现', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      return {
        'items': [
          fileJson(
            'fd9',
            relPath: 'c.jpg',
            status: 'failed',
            lastError: 'download_failed: x',
            targetPath: null,
          ),
        ],
        'total': 1,
      };
    });
    await pumpFiles(tester, adapter);
    expect(
      find.textContaining('/照片/c.jpg(目标已删除)'),
      findsOneWidget,
      reason: 'target_path 两级皆空 → 源路径 + (目标已删除)',
    );
  });
}
