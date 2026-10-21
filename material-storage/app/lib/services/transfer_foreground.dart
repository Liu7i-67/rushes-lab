/// TransferForeground — 传输前台服务封装(mobile-ux-polish-2 R4d)。
///
/// **插件选型(定稿,理由回填需求文档决策 #11):flutter_foreground_task ^11.0.3**
/// ① 本场景只需「保活+常驻通知」,传输本体仍在主 isolate 执行,无需后台
///    isolate 通信/自绘 UI——fft 的 init/startService/stopService 一对 API
///    接入面最小;
/// ② 自带独立通知 channel(AndroidNotificationOptions.channelId),与 P8 完成
///    通知 channel(ms_transfers)并存零冲突;
/// ③ 11.0.3 与本仓工具链兼容(Flutter 3.47.7 / Dart 3.13 / AGP 9.1 /
///    Kotlin 2.4 / Gradle 9.3.1)。
///    备选 flutter_background_service:需手写 service 配置与 isolates 通信
///    协议,对本场景接入成本更高,故不取。
///
/// 联动(队列状态机变化点=入队/收尾/取消/移除/清理/恢复统一上报):存在活跃
/// 任务(queued/running)→ 启服务(常驻通知「正在传输 N 个任务」,N 变化经
/// updateService 刷新文案);全终态 → 必停服务(stopService,不留常驻)。
///
/// 平台分支:仅 Android;iOS 无前台服务概念,完全跳过(不启不崩,维持现状
/// 尽力而为)。Android 14+ 对 dataSync 前台服务有 6h/24h 系统限时,超时由系统
/// 停服务:TaskHandler.onDestroy 只记日志、allowAutoRestart=false 不与系统
/// 对抗,主 isolate 队列继续尽力执行;启/停/刷任何一步失败都静默记日志不崩溃
/// (stopService 内部已把异常封装为 ServiceRequestFailure,不外抛)。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app_log.dart';

/// 服务通知 serviceId(flutter_foreground_task startService 用)。
@visibleForTesting
const kTransferForegroundServiceId = 256;

/// 服务通知 channel(独立于 P8 完成通知 channel ms_transfers,两 channel 并存)。
const kForegroundChannelId = 'ms_transfer_fg';
const _kForegroundChannelName = '传输进行中';
const _kForegroundChannelDesc = '有传输任务进行中的常驻通知,防止进程被回收';

/// 服务通知小图标在 manifest 的 meta-data 名(→ @drawable/ic_notification,
/// 与 P8 完成通知同一单色小图标;manifest 侧同步声明)。
const kForegroundIconMetaData = 'ms_transfer_fg_notification_icon';

/// 服务通知正文(标题恒「传输进行中」,正文带活跃任务数)。
@visibleForTesting
String foregroundNotificationText(int activeCount) =>
    '正在传输 $activeCount 个任务';

/// 启停委托:测试注入记录调用;生产=FlutterForegroundTask 平台通道。
abstract class ForegroundDelegate {
  /// 启动服务并展示「正在传输 [activeCount] 个任务」。
  Future<void> start(int activeCount);

  /// 服务已运行时刷新计数文案。
  Future<void> update(int activeCount);

  /// 停止服务(队列全终态,不留常驻)。
  Future<void> stop();
}

/// 真实委托:fft 的 start/update/stop 返回 ServiceRequestResult(失败封装在
/// ServiceRequestFailure 不外抛)——统一转抛,由 [TransferForeground] 记日志。
class FlutterForegroundDelegate implements ForegroundDelegate {
  const FlutterForegroundDelegate();

  @override
  Future<void> start(int activeCount) async {
    final result = await FlutterForegroundTask.startService(
      serviceId: kTransferForegroundServiceId,
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: _kForegroundChannelName,
      notificationText: foregroundNotificationText(activeCount),
      notificationIcon:
          const NotificationIcon(metaDataName: kForegroundIconMetaData),
      callback: _transferForegroundCallback,
    );
    if (result is ServiceRequestFailure) throw result.error;
  }

  @override
  Future<void> update(int activeCount) async {
    final result = await FlutterForegroundTask.updateService(
      notificationText: foregroundNotificationText(activeCount),
    );
    if (result is ServiceRequestFailure) throw result.error;
  }

  @override
  Future<void> stop() async {
    final result = await FlutterForegroundTask.stopService();
    if (result is ServiceRequestFailure) throw result.error;
  }
}

/// 服务 isolate 侧任务处理器:传输执行在主 isolate(前台服务只为提升进程
/// 优先级防杀),服务侧无周期任务;onDestroy=系统停服(Android 14+ dataSync
/// 限时超时/用户滑掉任务)只留日志,主 isolate 不受影响继续尽力执行。
class _TransferTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {} // eventAction=nothing 不触发

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    AppLog.info('foreground', '前台服务销毁(系统限时/任务移除)isTimeout=$isTimeout');
  }
}

/// 服务入口(@pragma 必须:release 构建裁剪保护,插件要求)。
@pragma('vm:entry-point')
void _transferForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_TransferTaskHandler());
}

/// 前台服务管理单例:main 挂 [init] 一次;传输队列经 [sync] 上报活跃任务数,
/// 启停联动全部在此(单测注入 [ForegroundDelegate] 断言状态机)。
class TransferForeground {
  static final TransferForeground I = TransferForeground._();

  TransferForeground._() : _isAndroid = Platform.isAndroid;

  /// 测试构造:注入启停委托与平台分支(isAndroid=false 复刻 iOS 跳过路径)。
  @visibleForTesting
  TransferForeground.test({ForegroundDelegate? delegate, bool isAndroid = true}) {
    _delegate = delegate;
    _isAndroid = isAndroid;
    _initialized = true;
  }

  ForegroundDelegate? _delegate;
  bool _isAndroid = false;
  var _initialized = false;
  var _running = false;
  var _lastActive = 0;

  /// main 挂接一次:通信端口须在 runApp 前初始化(插件要求)+ 服务参数装配。
  /// 任何失败静默降级为无保活(传输照常尽力而为);非 Android 全跳过。
  Future<void> init() async {
    if (!_isAndroid || _initialized) return;
    try {
      FlutterForegroundTask.initCommunicationPort();
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: kForegroundChannelId,
          channelName: _kForegroundChannelName,
          channelDescription: _kForegroundChannelDesc,
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          allowWakeLock: true,
          // Android 14+ dataSync 系统限时超时后不自动重启(不与系统对抗)
          allowAutoRestart: false,
          // 任务移除(滑掉 App)即停服务,不留常驻(R4d「必须停」口径)
          stopWithTask: true,
        ),
      );
      _delegate = const FlutterForegroundDelegate();
      _initialized = true;
      AppLog.info('foreground', '前台服务就绪(channel=$kForegroundChannelId)');
    } catch (e) {
      _initialized = false;
      AppLog.error('foreground', '前台服务初始化失败,降级为无保活', e);
    }
  }

  /// 队列状态机变化点上报活跃任务数(queued+running):
  /// - >0 且未运行 → 启动;>0 且运行中且 N 变化 → 刷文案;
  /// - ==0 → 必停(全终态不留常驻);
  /// - 仅 Android;单步失败只记日志:启失败保持未运行(下一变化点重试,覆盖
  ///   系统限时后被拒启的边界),刷文案失败不改运行态(服务大概率仍在),
  ///   停无论成败按未运行处理(停止意图已表达,防反复 stop)。队列不受影响,
  ///   继续普通执行。
  Future<void> sync(int activeCount) async {
    if (!_isAndroid || !_initialized) return;
    final delegate = _delegate;
    if (delegate == null) return;
    if (activeCount > 0) {
      if (!_running) {
        try {
          await delegate.start(activeCount);
          _running = true;
          _lastActive = activeCount;
          AppLog.info('foreground', '前台服务已启动(active=$activeCount)');
        } catch (e) {
          AppLog.error('foreground', '前台服务启动失败(降级,队列照常)', e);
        }
      } else if (activeCount != _lastActive) {
        try {
          await delegate.update(activeCount);
          _lastActive = activeCount;
        } catch (e) {
          AppLog.error('foreground', '前台服务文案刷新失败(通知保持旧计数)', e);
        }
      }
    } else if (_running) {
      try {
        await delegate.stop();
        AppLog.info('foreground', '前台服务已停止(队列全终态)');
      } catch (e) {
        AppLog.error('foreground', '前台服务停止失败(按未运行处理)', e);
      }
      _running = false;
      _lastActive = 0;
    }
  }
}
