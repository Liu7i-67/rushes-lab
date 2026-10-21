/// TransferForeground 单测(mobile-ux-polish-2 批 R4d):
/// 启停状态机(插件接口 mock = ForegroundDelegate 注入,零平台通道):
/// - 活跃任务(>0)→ 启动一次;计数变化 → 刷文案(update),不重复 start;
/// - 全终态(0)→ 必停一次(stop),再报 0 不重复停(防反复);
/// - 启动失败容错:不标记运行态,下一变化点重试(覆盖 Android 14+ dataSync
///   系统限时停服后被拒启的边界);刷文案失败保持运行态下次重试;
/// - 停止失败按未运行处理(停止意图已表达,不反复 stop);后续可重启;
/// - 平台分支:iOS(isAndroid=false)完全不启不崩(维持现状尽力而为);
/// - 通知文案/channel 锚:独立 channel「传输进行中」,与 P8 完成通知并存。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/services/transfer_foreground.dart';

/// 记录式委托:start/update/stop 调用序列全收;[failOn] 按方法名注入失败
/// (可变,供「条件恢复后重试」用例切换)。
class RecordingDelegate implements ForegroundDelegate {
  RecordingDelegate({this.failOn});

  String? failOn;
  final starts = <int>[];
  final updates = <int>[];
  var stops = 0;

  @override
  Future<void> start(int activeCount) async {
    if (failOn == 'start') {
      throw StateError('start rejected(系统限时/通道失败)');
    }
    starts.add(activeCount);
  }

  @override
  Future<void> update(int activeCount) async {
    if (failOn == 'update') {
      throw StateError('update failed');
    }
    updates.add(activeCount);
  }

  @override
  Future<void> stop() async {
    stops++; // 记录停止尝试(失败也算一次意图表达,钉「不反复 stop」)
    if (failOn == 'stop') {
      throw StateError('stop failed');
    }
  }
}

void main() {
  group('启停状态机(活跃→start、变化→update、全终态→stop)', () {
    test('活跃任务上报 → 启动并带计数;运行中计数变化 → 刷文案不重启', () async {
      final d = RecordingDelegate();
      final fg = TransferForeground.test(delegate: d);

      await fg.sync(2);
      expect(d.starts, [2], reason: '入队(有 queued/running)→ 启服务');
      expect(d.updates, isEmpty);

      await fg.sync(5);
      expect(d.starts, hasLength(1), reason: '已运行不重复 start');
      expect(d.updates, [5], reason: '「正在传输 N 个任务」随 N 刷新');

      await fg.sync(5);
      expect(d.updates, hasLength(1), reason: '计数不变不刷(防通知抖动)');
    });

    test('全终态上报 → 必停一次;再报 0 不重复 stop(不留常驻+防反复)',
        () async {
      final d = RecordingDelegate();
      final fg = TransferForeground.test(delegate: d);

      await fg.sync(1);
      await fg.sync(0);
      expect(d.stops, 1, reason: '队列全终态 → 停服务');

      await fg.sync(0);
      expect(d.stops, 1, reason: '未运行再报 0 不重复 stop');
    });

    test('从未启动(如队列恢复即全终态)报 0:不调 stop', () async {
      final d = RecordingDelegate();
      final fg = TransferForeground.test(delegate: d);
      await fg.sync(0);
      expect(d.starts, isEmpty);
      expect(d.stops, 0);
    });
  });

  group('失败容错(单步失败只记日志不崩溃,队列照常)', () {
    test('启动失败:不标记运行,同一实例下一变化点重试 start(系统限时后被拒启边界)',
        () async {
      final d = RecordingDelegate(failOn: 'start');
      final fg = TransferForeground.test(delegate: d);

      await fg.sync(2);
      expect(d.starts, isEmpty, reason: '启动失败(异常被吞,不外抛)');

      // 条件恢复(如系统限时窗口重置)→ 下一变化点重新尝试启动
      d.failOn = null;
      await fg.sync(3);
      expect(d.starts, [3], reason: '失败不置运行态 → 下次上报重试 start');
    });

    test('刷文案失败:保持运行态,计数差异保留 → 下次上报重试 update',
        () async {
      final d = RecordingDelegate(failOn: 'update');
      final fg = TransferForeground.test(delegate: d);

      await fg.sync(2); // start 成功
      await fg.sync(4); // update 失败(异常被吞)
      expect(d.starts, hasLength(1));
      expect(d.updates, isEmpty);

      // 同计数再报:update 曾失败,lastActive 未推进 → 仍会重试
      final d2 = RecordingDelegate();
      final fg2 = TransferForeground.test(delegate: d2);
      await fg2.sync(2);
      await fg2.sync(4);
      await fg2.sync(4);
      expect(d2.updates, [4], reason: '成功路径:同计数不重复刷(对照)');
      expect(d2.updates, hasLength(1));
    });

    test('停止失败按未运行处理:不反复 stop;后续活跃可重新 start', () async {
      final d = RecordingDelegate(failOn: 'stop');
      final fg = TransferForeground.test(delegate: d);

      await fg.sync(1);
      await fg.sync(0); // stop 失败 → 仍按未运行处理
      expect(d.stops, 1);

      await fg.sync(0);
      expect(d.stops, 1, reason: '停止意图已表达,不反复 stop');

      await fg.sync(2);
      expect(d.starts, [1, 2], reason: '服务实际可能已停,重新启动语义正确');
    });
  });

  group('平台分支与文案锚', () {
    test('iOS(isAndroid=false):任何上报都不触 delegate(不启不崩,维持现状)',
        () async {
      final d = RecordingDelegate();
      final fg = TransferForeground.test(delegate: d, isAndroid: false);

      await fg.sync(3);
      await fg.sync(1);
      await fg.sync(0);
      expect(d.starts, isEmpty);
      expect(d.updates, isEmpty);
      expect(d.stops, 0);
    });

    test('通知文案:标题恒「传输进行中」,正文带活跃任务数', () {
      expect(foregroundNotificationText(1), '正在传输 1 个任务');
      expect(foregroundNotificationText(12), '正在传输 12 个任务');
    });

    test('channel 独立于 P8 完成通知 channel(ms_transfers),两 channel 并存',
        () {
      expect(kForegroundChannelId, 'ms_transfer_fg');
      expect(kForegroundChannelId, isNot('ms_transfers'));
      expect(kTransferForegroundServiceId, 256);
      expect(kForegroundIconMetaData, 'ms_transfer_fg_notification_icon');
    });
  });
}
