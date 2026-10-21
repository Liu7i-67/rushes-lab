/// B9 测试功能点 3(列表侧):网盘备份页任务列表——状态徽标(含 queued 派生
/// 「排队中」)/进度统计/操作分流(active→取消;failed 且可重试→全部重试失败;
/// terminal→删除,均带确认)/失败原因中文透传/绑定卡与新建任务闸门;
/// P2-3:baidu-tasks 失效总线挂监听(新建任务页创建成功 → 本页重拉)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/features/baidu/baidu_page.dart';

import '../helpers/fake_baidu.dart';

Future<void> pumpPage(WidgetTester tester, FakeBaiduAdapter adapter,
    {Size size = const Size(800, 1600)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: BaiduPage(api: baiduApiWith(adapter)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('绑定卡:已绑定显示账号与授权期,新建任务可用;未绑定时新建禁用',
      (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.path == '/api/v1/baidu/backup/binding') {
        return {
          'bound': true,
          'status': 'active',
          'expires_at': '2026-11-20T00:00:00Z',
          'baidu_uid': 'uid-9',
          'nickname': '测试盘',
        };
      }
      return {'items': [], 'total': 0};
    });
    await pumpPage(tester, adapter);

    expect(find.text('已绑定'), findsOneWidget);
    expect(find.text('测试盘 · 授权至 2026-11-20'), findsOneWidget);
    final newBtn = tester.widget<FilledButton>(
        find.ancestor(of: find.text('新建备份任务'), matching: find.byType(FilledButton)));
    expect(newBtn.onPressed, isNotNull);
  });

  testWidgets('未绑定:新建任务禁用;绑定过期为 amber 提示', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.path == '/api/v1/baidu/backup/binding') {
        return {'bound': false, 'status': 'expired'};
      }
      return {'items': [], 'total': 0};
    });
    await pumpPage(tester, adapter);

    expect(find.text('绑定已过期'), findsOneWidget);
    final newBtn = tester.widget<FilledButton>(
        find.ancestor(of: find.text('新建备份任务'), matching: find.byType(FilledButton)));
    expect(newBtn.onPressed, isNull, reason: '未绑定不可新建(web 闸门同口径)');
    expect(find.text('重新绑定'), findsOneWidget);
  });

  testWidgets('任务列表:状态徽标 queued 派生「排队中」;操作按状态分流', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.path == '/api/v1/baidu/backup/binding') {
        return {'bound': true, 'status': 'active'};
      }
      expect(req.query['limit'], '20');
      return {
        'items': [
          taskJson('t1', status: 'running', queued: true, totalFiles: 10,
              doneFiles: 2),
          taskJson('t2', status: 'failed', failReason: 'timeout',
              totalFiles: 10, doneFiles: 4, failedFiles: 6,
              retryableFailedFiles: 5),
          taskJson('t3', status: 'completed', totalFiles: 3, doneFiles: 3),
        ],
        'total': 3,
      };
    });
    await pumpPage(tester, adapter);

    expect(find.text('排队中'), findsOneWidget, reason: '活动中 queued=true 派生展示态');
    expect(find.text('失败'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('达到单轮 48h 上限,可用「全部重试失败」断点续传'),
        findsOneWidget, reason: 'fail_reason 中文透传');
    expect(find.text('2 / 10 个文件'), findsOneWidget);

    // 操作分流:取消仅活动(t1);全部重试失败仅 failed 可重试(t2);删除仅终态(t2/t3)
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('全部重试失败'), findsOneWidget);
    expect(find.text('删除'), findsNWidgets(2));
  });

  testWidgets('取消:确认后 POST cancel;202 {finalized:false} 文案区分', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.path == '/api/v1/baidu/backup/binding') {
        return {'bound': true, 'status': 'active'};
      }
      if (req.path == '/api/v1/baidu/backup/tasks/t1/cancel') {
        expect(req.method, 'POST');
        return (202, {'finalized': false});
      }
      return {
        'items': [taskJson('t1', status: 'running', queued: true)],
        'total': 1,
      };
    });
    await pumpPage(tester, adapter);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('取消该任务?'), findsOneWidget);
    await tester.tap(find.text('取消任务'));
    await tester.pumpAndSettle();
    expect(find.text('取消请求已提交,任务将在最近检查点停止'), findsOneWidget,
        reason: 'finalized=false 文案区分(web 同口径)');
    expect(adapter.calls.any((c) =>
            c.path == '/api/v1/baidu/backup/tasks/t1/cancel' &&
            c.method == 'POST'),
        isTrue);
  });

  testWidgets('全部重试失败直发;删除带确认;409 detail 透传', (tester) async {
    var retryCalls = 0;
    late FakeBaiduAdapter adapter;
    adapter = FakeBaiduAdapter((req) async {
      if (req.path == '/api/v1/baidu/backup/binding') {
        return {'bound': true, 'status': 'active'};
      }
      if (req.path == '/api/v1/baidu/backup/tasks/t2/retry-failed') {
        retryCalls++;
        if (retryCalls == 1) return (202, {'finalized': true, 'status': 'enumerating'});
        return (409, {'detail': '无可重试文件'});
      }
      if (req.path == '/api/v1/baidu/backup/tasks/t2') {
        return (204, null);
      }
      return {
        'items': [
          taskJson('t2', status: 'failed', totalFiles: 10, doneFiles: 4,
              failedFiles: 6, retryableFailedFiles: 5),
        ],
        'total': 1,
      };
    });
    await pumpPage(tester, adapter);

    // 全部重试失败:直发(无确认)
    await tester.tap(find.text('全部重试失败'));
    await tester.pumpAndSettle();
    expect(find.text('失败文件已全部重新排队'), findsOneWidget);
    expect(retryCalls, 1);

    // 删除:确认弹窗 → 确认 → 204
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除该任务记录?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    // 前一条 toast(重试)尚在展示期,删除 toast 排队其后:推进假时钟让队列前进
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('任务记录已删除'), findsOneWidget);
    expect(adapter.calls.any((c) =>
        c.method == 'DELETE' && c.path == '/api/v1/baidu/backup/tasks/t2'),
        isTrue);
  });

  testWidgets('加载更多:offset=已拉条数追加', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.path == '/api/v1/baidu/backup/binding') {
        return {'bound': true, 'status': 'active'};
      }
      if ((req.query['offset'] ?? '0') == '0') {
        return {
          'items': [taskJson('t1', status: 'completed')],
          'total': 2,
        };
      }
      expect(req.query['offset'], '1');
      expect(int.parse(req.query['limit']!), lessThanOrEqualTo(100));
      return {
        'items': [taskJson('t2', status: 'completed')],
        'total': 2,
      };
    });
    await pumpPage(tester, adapter);
    expect(find.text('加载更多'), findsOneWidget);

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('/照片'), findsNWidgets(2), reason: '两条任务(默认 source_dir)');
    expect(find.text('加载更多'), findsNothing, reason: '取尽收起');
  });

  testWidgets('baidu-tasks 失效总线挂监听:invalidate 后本页重拉任务列表(P2-3)',
      (tester) async {
    var taskListCalls = 0;
    final adapter = FakeBaiduAdapter((req) async {
      if (req.path == '/api/v1/baidu/backup/binding') {
        return {'bound': true, 'status': 'active'};
      }
      if (req.path == '/api/v1/baidu/backup/tasks') {
        taskListCalls++;
        return {
          'items': [taskJson('t1', status: 'running', queued: true)],
          'total': 1,
        };
      }
      return {'items': [], 'total': 0};
    });
    await pumpPage(tester, adapter);
    final afterInitialLoad = taskListCalls;
    expect(afterInitialLoad, 1);

    // 新建任务页创建成功即 invalidate('baidu-tasks')(向导页在栈顶、本页
    // 在栈下仍 mounted):总线监听应触发本页重拉,不依赖弹层 pop 返回值
    RefreshBus.I.invalidate('baidu-tasks');
    await tester.pumpAndSettle();
    expect(taskListCalls, greaterThan(afterInitialLoad),
        reason: '总线失效触发刷新(弹层关闭通道之外的第二通道)');
  });
}
