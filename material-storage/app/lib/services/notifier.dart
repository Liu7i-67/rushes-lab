/// Notifier — 传输完成系统级本地通知(mobile-ux-polish P8)+ 通知权限可达
/// (mobile-ux-polish-2 R4a)+ iOS 前台/刚切后台展示修复(app-polish-2 J3)。
///
/// 口径(用户拍板):**后台(生命周期非 resumed)才发系统通知,前台维持应用内
/// SnackBar/无提示现状**;同窗口多条终态聚合为一条汇总(防批量 99 张逐条轰炸,
/// 短窗口 ~3s);通知权限**首次建传输任务时**才请求(app 启动不弹,幂等)。
/// R4a:请求结果消费入内存(被拒不再全链路静默),请求后仍被拒 → 弹一次中文
/// 引导框(标题「开启系统通知」,「去设置」跳应用详情设置页,会话内至多一次);
/// 「我的」页「传输通知」状态行经 [queryPermission] 实时查询。
///
/// J3(用户反馈 #8「iOS 下载上传成功后没有系统级提示,安卓可以」)修复链:
/// ① iOS 前台展示(willPresent → banner)依赖 `UNUserNotificationCenter`
///    delegate——插件自带 delegate 实现,但挂接需 app 侧一行
///    `UNUserNotificationCenter.current().delegate = self`(flutter_local_notifications
///    22.3.2 README § iOS setup「General setup」+ 插件 example ios/Runner/AppDelegate.swift),
///    已补入 ios/Runner/AppDelegate.swift(FlutterAppDelegate 实现
///    UNUserNotificationCenterDelegate 并转发给 addApplicationDelegate 注册的插件);
/// ② 展示参数按 22.x 实名补齐:`DarwinNotificationDetails` 的
///    `interruptionLevel: InterruptionLevel.active`(iOS 15+:系统立即呈现并
///    点亮屏幕)、`presentSound: true`(原生侧 `presentSound && content.sound == nil`
///    时自动落 UNNotificationSound.defaultSound,见插件 iOS 源
///    FlutterLocalNotificationsPlugin.m `buildStandardNotificationContent`;
///    `sound` 参数只认包内自定义文件名,默认提示音走 presentSound 即可)、
///    `badgeNumber: 1` + present 四项显式开(前台 willPresent 的
///    presentationOptions 由插件按 per-notification present 标志给出,
///    iOS 14+ 走 presentBanner/presentList)——见 [kTransferDarwinDetails];
/// ③ **平台限制(文档记录,不强解)**:iOS 无前台服务机制,app 挂起后 Dart
///    冻结、传输本身暂停,不存在「挂起后仍完成并发通知」;本批覆盖的是
///    前台/刚切后台(未挂起)窗口。真机验证留人工:iOS 前台切后台数秒内
///    传完 → 收到横幅+提示音;角标观感(badgeNumber=1)是否接受。
///
/// 降级哲学(与 AppLog 同款):插件初始化/权限/发送任何一步失败都静默,系统
/// 通知整体不可用只损失「后台感知」,不影响业务流。单测注入 sink/schedule/
/// gate/permission/guide/queryPermission,零平台通道、零真实等待。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart'
    show
        AlertDialog,
        BuildContext,
        FilledButton,
        Navigator,
        Text,
        TextButton,
        showDialog;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:photo_manager/photo_manager.dart' show PhotoManager;
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import '../core/session.dart' show session;
import '../core/transfers/transfer_task.dart' show TransferKind;
import 'app_log.dart';

/// 通知出口签名(真实=系统通知;测试=收集断言)。
typedef NotifySink = Future<void> Function(String title, String body);

/// 单条传输终态的上报(P8 聚合输入)。
class TransferNotifyEntry {
  const TransferNotifyEntry({
    required this.ok,
    required this.filename,
    this.detail,
  });

  /// true=完成;false=失败。
  final bool ok;

  final String filename;

  /// 成功=保存结果摘要(下载「已存入相册…」);失败=简短原因。可空。
  final String? detail;
}

/// 同类任务终态 → 一条通知的标题/正文(纯函数,单测钉口径):
/// 单文件详报(标题带文件名),多文件聚合汇总(「N 个文件」或「k 成功 · m 失败」),
/// 批量带失败时正文列失败名单(最多 3 个,超出「等 N 个」)。
(String, String) transferNotifyTexts(
  TransferKind kind,
  List<TransferNotifyEntry> entries,
) {
  assert(entries.isNotEmpty, '空批不该聚通知');
  final label = kind == TransferKind.upload ? '上传' : '下载';
  final fails = entries.where((e) => !e.ok).toList();
  if (entries.length == 1) {
    final e = entries.single;
    return e.ok
        ? ('$label完成:${e.filename}', e.detail ?? '')
        : ('$label失败:${e.filename}', e.detail ?? '传输失败,请稍后重试');
  }
  final okCount = entries.length - fails.length;
  if (fails.isEmpty) {
    return ('$label完成:${entries.length} 个文件', _nameList(entries, ''));
  }
  if (okCount == 0) {
    return ('$label失败:${entries.length} 个文件', _nameList(fails, ''));
  }
  return ('$label完成:$okCount 成功 · ${fails.length} 失败', _nameList(fails, '失败:'));
}

/// 文件名名单正文:最多列 3 个,超出以「等 N 个」收尾。
String _nameList(List<TransferNotifyEntry> list, String prefix) {
  final names = list.take(3).map((e) => e.filename).join('、');
  final more = list.length > 3 ? ' 等 ${list.length} 个' : '';
  return '$prefix$names$more';
}

/// 终态聚合器:短窗口([window],默认 3s)内的同类任务终态并成一条汇总通知。
/// [schedule] 注入定时器(真实=Timer;测试=收集回调手动触发),[gate] 前台
/// 返回 false 直接丢弃(前台维持应用内现状)。聚合按 TransferKind 分组,
/// 同窗最多发两条(上传一条 + 下载一条)。
class TransferNotifyBatcher {
  TransferNotifyBatcher({
    required this.sink,
    required this.gate,
    this.window = const Duration(seconds: 3),
    void Function(Duration, void Function())? schedule,
  }) : _schedule = schedule ?? _defaultSchedule;

  /// 通知出口(真实=系统通知;测试注入收集)。
  final NotifySink sink;

  /// 前台 false(终态丢弃,维持应用内现状),后台 true。
  final bool Function() gate;

  final Duration window;

  final void Function(Duration, void Function()) _schedule;

  static void _defaultSchedule(Duration d, void Function() cb) => Timer(d, cb);

  final _pending = <(TransferKind, TransferNotifyEntry)>[];
  var _flushQueued = false;

  /// 终态上报:前台丢弃;后台入批,窗口内首批才挂定时器(防轰炸)。
  void add(TransferKind kind, TransferNotifyEntry entry) {
    if (!gate()) return;
    _pending.add((kind, entry));
    if (_flushQueued) return;
    _flushQueued = true;
    _schedule(window, _flush);
  }

  /// 窗口到期:按类分组各聚合一条;发完重开新批(下一批重新计窗)。
  void _flush() {
    _flushQueued = false;
    if (_pending.isEmpty) return;
    final batch = List.of(_pending);
    _pending.clear();
    for (final kind in TransferKind.values) {
      final group = batch.where((r) => r.$1 == kind).map((r) => r.$2).toList();
      if (group.isEmpty) continue;
      final (title, body) = transferNotifyTexts(kind, group);
      sink(title, body).catchError((Object e) {
        AppLog.error('notifier', '通知出口失败:$title', e);
      });
    }
  }
}

/// 传输完成系统通知单例(方案 P8):main 挂 [init] 一次;传输收尾方调
/// [taskFinished]/[ensurePermission],其余全程静默降级。
class Notifier {
  static final Notifier I = Notifier._();

  Notifier._();

  /// Android 通知渠道(传输完成)。
  static const _channelId = 'ms_transfers';
  static const _channelName = '传输完成';
  static const _channelDesc = '上传/下载完成的后台通知';

  final _plugin = FlutterLocalNotificationsPlugin();

  /// 聚合批(init 成功才挂;null=通知不可用——单测/初始化失败静默降级,
  /// taskFinished/ensurePermission 直接 no-op,业务流零感知)。
  TransferNotifyBatcher? _batcher;

  /// 权限请求实现(注入点;null=真实平台通道;返回 null=系统未给结论)。
  Future<bool?> Function()? _permission;

  /// 授权态查询实现(注入点;null=真实平台通道)。
  Future<bool> Function()? _queryPermission;

  /// 被拒引导实现(注入点;null=真实弹窗)。
  Future<void> Function()? _guide;

  /// 本会话已请求过权限(幂等:至多请求一次;系统侧「未决才弹」由 OS 保证)。
  var _permissionAsked = false;

  @visibleForTesting
  bool get permissionAsked => _permissionAsked;

  /// R4a:最近一次请求的授权态(null=未请求/请求链路失败——失败 ≠ 拒绝,
  /// 不据此弹引导);「请求后仍被拒 → 引导一次」以此判定。
  bool? _permissionGranted;

  @visibleForTesting
  bool? get permissionGranted => _permissionGranted;

  /// R4a:被拒引导本会话是否已弹过(至多一次,防骚扰)。
  @visibleForTesting
  bool get guideShown => _guideShown;
  var _guideShown = false;

  var _notifyId = 0;

  /// 测试构造:注入聚合批(自带 sink/gate/schedule)与权限/引导/查询桩,
  /// 零平台通道。
  @visibleForTesting
  Notifier.test({
    required this._batcher,
    Future<bool?> Function()? permission,
    Future<bool> Function()? queryPermission,
    Future<void> Function()? guide,
  }) {
    _permission = permission;
    _queryPermission = queryPermission;
    _guide = guide;
  }

  /// main 挂接一次:插件初始化 + Android 渠道创建。iOS 侧启动**不弹**权限
  /// (Darwin 初始化仅关 request*Permission,时序保留:权限统一在
  /// [ensurePermission] 首次入队时请求;前台展示 defaultPresent* 维持插件
  /// 默认全 true,per-notification 展示口径见 [kTransferDarwinDetails])。
  /// 任何失败静默降级为无系统通知(前台 SnackBar 现状不受影响)。
  Future<void> init() async {
    try {
      const settings = InitializationSettings(
        // 小图标只认 drawable 资源(flutter_launcher_icons 产物在 mipmap
        // 不适用),见 res/drawable/ic_notification.xml
        android: AndroidInitializationSettings('ic_notification'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      );
      final ok = await _plugin.initialize(settings: settings);
      if (ok != true) throw StateError('本地通知初始化未就绪');
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              _channelName,
              description: _channelDesc,
            ),
          );
      _batcher = TransferNotifyBatcher(sink: _send, gate: isBackground);
      AppLog.info('notifier', '系统通知就绪(channel=$_channelId)');
    } catch (e) {
      _batcher = null;
      AppLog.error('notifier', '系统通知初始化失败,降级为仅应用内提示', e);
    }
  }

  /// 通知权限(Android 13+ 运行时权限 / iOS 授权):幂等,本会话至多请求一次;
  /// 首次建传输任务时调用(不在 app 启动即弹)。
  /// R4a:消费请求结果记入 [permissionGranted];**请求后仍被拒 → 弹一次中文
  /// 引导框**(标题「开启系统通知」,「去设置」跳应用详情设置页,会话内至多
  /// 一次,已授权不弹);请求链路失败 ≠ 拒绝,静默降级不弹引导——无权限只损失
  /// 后台通知,不影响业务流。
  Future<void> ensurePermission() async {
    if (_permissionAsked || _batcher == null) return;
    _permissionAsked = true;
    bool? granted;
    try {
      final injected = _permission;
      granted = injected != null
          ? await injected()
          : await _requestRealPermission();
    } catch (e) {
      AppLog.error('notifier', '通知权限请求失败(静默降级,不影响任务)', e);
      return; // 链路失败不视为拒绝,不弹引导
    }
    _permissionGranted = granted ?? true; // null=系统未给结论(<13/iOS)视为可用
    if (!_permissionGranted!) {
      _guideShown = true; // 会话内至多一次(注入桩与真实弹窗同口径记一次)
      final guide = _guide;
      if (guide != null) {
        await guide();
      } else {
        await _showDeniedGuide();
      }
    }
  }

  /// 真实权限请求:Android 13+ 运行时权限(返回授权与否);Android <13 走
  /// null(视为可用,系统本就不拦);iOS 请求 alert/badge/sound。
  Future<bool?> _requestRealPermission() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) return android.requestNotificationsPermission();
    final granted = await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    return granted;
  }

  /// R4a:被拒引导(会话内至多一次)。经全局 navigator 挂弹窗(队列收尾侧
  /// 无 BuildContext);无 navigator(极早期)静默放弃——_permissionAsked 已挡
  /// 重入,本会话不再弹。
  Future<void> _showDeniedGuide() async {
    if (_guideShown) return;
    _guideShown = true;
    final ctx = session.navigatorKey.currentState?.context;
    if (ctx == null || !ctx.mounted) return;
    await showNotificationGuideDialog(ctx);
  }

  /// R4a:通知权限被拒的中文引导框(标题「开启系统通知」;正文说明后台传输
  /// 完成提醒用途;「去设置」跳应用详情设置页 + 「取消」)。独立公开便于
  /// widget 测试钉文案。
  @visibleForTesting
  Future<void> showNotificationGuideDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('开启系统通知'),
        content: const Text(
          '后台上传/下载完成后,需要系统通知权限才能收到完成提醒。'
          '建议开启,避免错过传输结果。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogCtx).pop();
              openNotificationSettings();
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  /// R4a:查询系统通知授权态(「我的」页「传输通知」状态行实时查询):
  /// Android areNotificationsEnabled(13+ 真实反映,<13 恒 true)/iOS
  /// checkPermissions;插件不可用或查询失败恒返回 true(降级口径:查不出
  /// 就不误报「未开启」)。
  Future<bool> queryPermission() async {
    final injected = _queryPermission;
    if (injected != null) return injected();
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final enabled = await android?.areNotificationsEnabled();
      if (enabled != null) return enabled;
      final ios = await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.checkPermissions();
      return ios?.isEnabled ?? true;
    } catch (e) {
      AppLog.error('notifier', '通知授权态查询失败,按已开启呈现', e);
      return true;
    }
  }

  /// 前后台判定(P8 口径):生命周期非 resumed 即按后台(启动早期 null 亦然)。
  bool isBackground() =>
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;

  /// 传输任务终态上报(队列收尾/下载收尾调用):前台丢弃,后台进聚合窗,
  /// 窗口到期一条汇总。通知不可用(未 init/初始化失败)时 no-op。
  void taskFinished({
    required TransferKind kind,
    required bool ok,
    required String filename,
    String? detail,
  }) {
    _batcher?.add(
      kind,
      TransferNotifyEntry(ok: ok, filename: filename, detail: detail),
    );
  }

  /// 真实通知出口:自增 id 逐条发(聚合后量小,无需 dedup);失败只记日志。
  Future<void> _send(String title, String body) async {
    try {
      await _plugin.show(
        id: _notifyId++,
        title: title,
        body: body.isEmpty ? null : body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDesc,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: kTransferDarwinDetails,
        ),
      );
    } catch (e) {
      AppLog.error('notifier', '通知发送失败:$title $body', e);
    }
  }
}

/// iOS 传输完成通知详情(J3 定稿;compile-time const,单测静态钉字段):
/// - `interruptionLevel: InterruptionLevel.active` — iOS 15+ 系统立即呈现、
///   点亮屏幕、可出声(22.x API:插件 lib/.../darwin/interruption_level.dart);
/// - `presentSound: true` — 原生 `presentSound && content.sound == nil` 时
///   自动落默认提示音(flutter_local_notifications 22.3.2
///   FlutterLocalNotificationsPlugin.m buildStandardNotificationContent),
///   前台/后台一致,无需自定义 sound 文件;
/// - `badgeNumber: 1` + `presentBadge` — 到达亮角标;
/// - `presentBanner`/`presentList`(iOS 14+ 前台 banner + 通知中心列表)
///   与 `presentAlert`(iOS <14)显式开,不依赖初始化默认值;willPresent 的
///   presentationOptions 由插件自带 delegate 按这些标志给出(delegate 挂接见
///   ios/Runner/AppDelegate.swift);
/// - `threadIdentifier` 同渠道聚合,上/下载两条在通知中心归组展示。
@visibleForTesting
const kTransferDarwinDetails = DarwinNotificationDetails(
  presentAlert: true,
  presentBanner: true,
  presentList: true,
  presentSound: true,
  presentBadge: true,
  badgeNumber: 1,
  threadIdentifier: Notifier._channelId,
  interruptionLevel: InterruptionLevel.active,
);

/// Android 应用包名(构建 applicationId;跳应用详情设置页用)。与 upload_pick
/// 的 kAndroidAppPackage 同值——各自独立常量,避免 services→features 反向依赖。
const kNotifierAndroidAppPackage = 'com.taoxiplan.huanhuashijie';

/// R4a:「去设置」跳应用详情设置页(一期 upload_pick.openAlbumPermissionSettings
/// 同款:url_launcher 走 ACTION_VIEW+package: data,系统设置对该意图即应用详情
/// 页;启动失败/异常回退 photo_manager 的 openSetting,同为应用设置页且 iOS 可用)。
Future<void> openNotificationSettings() async {
  try {
    final launched = await launchUrl(
      Uri.parse('package:$kNotifierAndroidAppPackage'),
      mode: LaunchMode.externalApplication,
    );
    if (launched) return;
    AppLog.info('notifier', 'package: 意图未启动,回退 openSetting');
  } catch (e) {
    AppLog.error('notifier', '跳应用详情设置页失败,回退 openSetting', e);
  }
  await PhotoManager.openSetting();
}
