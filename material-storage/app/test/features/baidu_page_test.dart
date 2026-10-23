/// B9 列表侧:网盘备份页任务列表(状态徽标/进度/操作分流/确认/失败原因/
/// 绑定卡闸门/加载更多/失效总线)。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/features/baidu/baidu_binding_card.dart';
import 'package:ms_app/features/baidu/baidu_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/widgets/badge.dart' as app_badge;

import '../helpers/fake_baidu.dart';

const _bindingPath = '/api/v1/baidu/backup/binding';

Map<String, Object?> _boundJson() => {'bound': true, 'status': 'active'};

app_badge.Badge statusBadge(WidgetTester tester, String label) =>
    tester.widget<app_badge.Badge>(find.widgetWithText(app_badge.Badge, label));

FilledButton newTaskButton(WidgetTester tester) => tester.widget<FilledButton>(
  find.ancestor(of: find.text('新建备份任务'), matching: find.byType(FilledButton)),
);

Color progressColor(WidgetTester tester, String id) => tester
    .widget<LinearProgressIndicator>(
      find.byKey(ValueKey('baidu-task-progress-$id')),
    )
    .color!;

Future<void> pumpPage(
  WidgetTester tester,
  FakeBaiduAdapter adapter, {
  Size size = const Size(800, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: BaiduPage(api: baiduApiWith(adapter))),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('P2-1:320×640 + 1.3 字号绑定卡按钮不截断(窄屏纵向整宽)', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: BaiduBindingCard(
                  binding: BaiduBindingInfo(bound: true, status: 'active'),
                  loaded: true,
                  busy: false,
                  onBind: () {},
                  onNewTask: () {},
                  onUnbind: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '320/1.3 无溢出异常');
    for (final label in ['切换账号', '新建备份任务']) {
      expect(find.text(label), findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: '窄屏纵向整宽后「$label」完整显示(不省略)',
      );
    }
  });

  testWidgets('绑定卡:已绑定显示账号与授权期,新建任务可用;未绑定时新建禁用', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.path == _bindingPath) {
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
    expect(statusBadge(tester, '已绑定').tone, app_badge.BadgeTone.ok);
    expect(find.text('网盘备份'), findsOneWidget);
    expect(find.text('素材异地留档，按任务增量同步'), findsOneWidget);
    expect(find.text('测试盘 · 授权至 2026-11-20'), findsOneWidget);
    expect(newTaskButton(tester).onPressed, isNotNull);
  });

  testWidgets('未绑定:新建任务禁用;绑定过期为 amber 提示', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.path == _bindingPath) {
        return {'bound': false, 'status': 'expired'};
      }
      return {'items': [], 'total': 0};
    });
    await pumpPage(tester, adapter);

    expect(find.text('绑定已过期'), findsOneWidget);
    expect(statusBadge(tester, '绑定已过期').tone, app_badge.BadgeTone.warn);
    expect(
      newTaskButton(tester).onPressed,
      isNull,
      reason: '未绑定不可新建(web 闸门同口径)',
    );
    expect(find.text('重新绑定'), findsOneWidget);
  });

  testWidgets('未绑定:绑定卡状态徽标 neutral,绑定入口可用', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.path == _bindingPath) {
        return {'bound': false, 'status': 'unbound'};
      }
      return {'items': [], 'total': 0};
    });
    await pumpPage(tester, adapter);

    expect(statusBadge(tester, '未绑定').tone, app_badge.BadgeTone.neutral);
    expect(find.text('绑定账号'), findsOneWidget);
    expect(find.text('暂无备份任务'), findsOneWidget);
  });

  testWidgets('任务列表:状态徽标 queued 派生「排队中」;操作按状态分流', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.path == _bindingPath) return _boundJson();
      expect(req.query['limit'], '20');
      return {
        'items': [
          taskJson(
            't1',
            status: 'running',
            queued: true,
            totalFiles: 10,
            doneFiles: 2,
          ),
          taskJson(
            't2',
            status: 'failed',
            failReason: 'timeout',
            totalFiles: 10,
            doneFiles: 4,
            failedFiles: 6,
            retryableFailedFiles: 5,
          ),
          taskJson('t3', status: 'completed', totalFiles: 3, doneFiles: 3),
        ],
        'total': 3,
      };
    });
    await pumpPage(tester, adapter);

    expect(find.text('排队中'), findsOneWidget, reason: '活动中 queued=true 派生展示态');
    expect(find.text('失败'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(
      find.text('达到单轮 48h 上限,可用「全部重试失败」断点续传'),
      findsOneWidget,
      reason: 'fail_reason 中文透传',
    );
    expect(find.text('2 / 10 个文件'), findsOneWidget);

    // 进度条颜色:进行中=金 / 失败=红 / 已完成=绿
    expect(progressColor(tester, 't1'), TkColors.light.gold);
    expect(progressColor(tester, 't2'), TkColors.light.danger);
    expect(progressColor(tester, 't3'), TkColors.light.ok);

    // 操作分流:取消仅活动(t1);全部重试失败仅 failed 可重试(t2);删除仅终态(t2/t3)
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('全部重试失败'), findsOneWidget);
    expect(find.text('删除'), findsNWidgets(2));
  });

  testWidgets('取消:确认后 POST cancel;202 {finalized:false} 文案区分', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.path == _bindingPath) return _boundJson();
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
    expect(
      find.text('取消请求已提交,任务将在最近检查点停止'),
      findsOneWidget,
      reason: 'finalized=false 文案区分(web 同口径)',
    );
    expect(
      adapter.calls.any(
        (c) =>
            c.path == '/api/v1/baidu/backup/tasks/t1/cancel' &&
            c.method == 'POST',
      ),
      isTrue,
    );
  });

  testWidgets('全部重试失败直发;删除带确认;409 detail 透传', (tester) async {
    var retryCalls = 0;
    late FakeBaiduAdapter adapter;
    adapter = FakeBaiduAdapter((req) async {
      if (req.path == _bindingPath) return _boundJson();
      if (req.path == '/api/v1/baidu/backup/tasks/t2/retry-failed') {
        retryCalls++;
        if (retryCalls == 1) {
          return (202, {'finalized': true, 'status': 'enumerating'});
        }
        return (409, {'detail': '无可重试文件'});
      }
      if (req.path == '/api/v1/baidu/backup/tasks/t2') {
        return (204, null);
      }
      return {
        'items': [
          taskJson(
            't2',
            status: 'failed',
            totalFiles: 10,
            doneFiles: 4,
            failedFiles: 6,
            retryableFailedFiles: 5,
          ),
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
    // app-polish E14:反馈统一 toast()(latest-wins,即时替换前一条重试
    // toast,原「推进假时钟等旧条排队」不再需要)
    expect(find.text('任务记录已删除'), findsOneWidget);
    expect(
      adapter.calls.any(
        (c) =>
            c.method == 'DELETE' && c.path == '/api/v1/baidu/backup/tasks/t2',
      ),
      isTrue,
    );
    // 收尾:排空 toast SnackBar 的 duration Timer
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('加载更多:offset=已拉条数追加', (tester) async {
    final adapter = FakeBaiduAdapter((req) async {
      if (req.path == _bindingPath) return _boundJson();
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

  testWidgets('baidu-tasks 失效总线挂监听:invalidate 后本页重拉任务列表(P2-3)', (tester) async {
    var taskListCalls = 0;
    final adapter = FakeBaiduAdapter((req) async {
      if (req.path == _bindingPath) return _boundJson();
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
    expect(
      taskListCalls,
      greaterThan(afterInitialLoad),
      reason: '总线失效触发刷新(弹层关闭通道之外的第二通道)',
    );
  });
}
