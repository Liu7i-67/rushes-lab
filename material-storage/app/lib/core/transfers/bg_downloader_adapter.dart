/// BgDownloader — background_downloader 插件的薄接口(包 B):
/// BgPartPutChannel 只依赖本接口,单测全用 fake;真实实现 [RealBgDownloader]
/// 包 FileDownloader(经典 API:registerCallbacks + enqueue + start),
/// 仅在 iOS 真实通道首次 ensureInit 时被触碰。
///
/// 更新送达机制(pub cache 9.6.6 源码核验,验收修正 P1:不设「回前台
/// 再补收」接口——它没有第二次机会):
/// ① init 时 `start()` 内部**无条件**先调 resumeFromBackground
///    (file_downloader.dart:807/827),落库补收就此完成且仅此一次:
///    retrieveLocallyStoredData 受 base_downloader.dart:270-293 的
///    `retrievedLocallyStoredData`(:112)一次性 flag 守卫,之后调用恒 no-op;
/// ② 此后挂起期间的状态/进度更新由 iOS 原生 delegate 直投:插件自注册
///    AppDelegate(BDPlugin.swift:71 addApplicationDelegate)并自动处理
///    handleEventsForBackgroundURLSession,系统唤醒窗口拉起 App 直接转发
///    事件,不需要 Dart 侧兜底;
/// ③ `doTrackTasks:false` 下插件不维护可重读的本地任务库,不存在「二次
///    补收」的数据面——曾经加的「resumed 观察者调 resumeFromBackground」
///    在真实插件上恒为 no-op(验收实证后撤销,留此说明防复发)。
///
/// 本仓用 `start(doTrackTasks: false, doRescheduleKilledTasks: false)`:
/// 不开持久化跟踪、不让插件自动重排被杀任务——进程被杀按需求 F5 标
/// 「进程中断」并 abort,重排会违语义重传。
library;

import 'package:background_downloader/background_downloader.dart';

/// 后台下载器接口(可 fake 的最小面)。
abstract class BgDownloader {
  /// 幂等初始化:确保插件就绪(内部含唯一一次落库补收,见库头注释①)。
  Future<void> init();

  /// 入队任务;false = 插件拒绝(如上传文件不存在)。
  Future<bool> enqueue(UploadTask task);

  /// 按任务 id 批量取消;返回是否有任务被取消。
  Future<bool> cancelTasksWithIds(Iterable<String> taskIds);

  /// 注册 group 级状态回调(须在 init/enqueue 之前注册)。
  void registerStatusCallback(String group, BgStatusCallback callback);
}

/// 任务状态回调签名(透传插件的 TaskStatusUpdate:complete 态带
/// responseHeaders(键已小写)、failed 态带 exception(TaskHttpException
/// 带 httpResponseCode))。
typedef BgStatusCallback = void Function(TaskStatusUpdate update);

/// 真实实现(包 FileDownloader 单例)。构造不触碰平台通道——真正的
/// 平台装配推迟到 init/enqueue 首次调用,保证 Windows 单测安全。
class RealBgDownloader implements BgDownloader {
  RealBgDownloader._();

  static final RealBgDownloader instance = RealBgDownloader._();

  bool _initialized = false;

  @override
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    final fd = FileDownloader();
    await fd.ready; // 持久存储就绪
    // 不 trackTasks / 不 rescheduleKilledTasks(F5 语义,见库头注释);
    // start() 内部恒调 resumeFromBackground → 唯一一次落库补收在此完成
    // (之后由 iOS 原生 delegate 直投更新,见库头注释①②)。
    await fd.start(doTrackTasks: false, doRescheduleKilledTasks: false);
  }

  @override
  Future<bool> enqueue(UploadTask task) => FileDownloader().enqueue(task);

  @override
  Future<bool> cancelTasksWithIds(Iterable<String> taskIds) =>
      FileDownloader().cancelTasksWithIds(taskIds);

  @override
  void registerStatusCallback(String group, BgStatusCallback callback) {
    // 组级注册:该组更新只进此回调,不占插件 updates 单订阅流(包开发者
    // 隔离口径,源码实证)——与 App 其他潜在 updates 监听互不干扰
    FileDownloader().registerCallbacks(
      group: group,
      taskStatusCallback: callback,
    );
  }
}
