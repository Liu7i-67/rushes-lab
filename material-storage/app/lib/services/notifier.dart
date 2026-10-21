/// Notifier — 传输完成系统级本地通知(mobile-ux-polish P8)。
///
/// 口径(用户拍板):**后台(生命周期非 resumed)才发系统通知,前台维持应用内
/// SnackBar/无提示现状**;同窗口多条终态聚合为一条汇总(防批量 99 张逐条轰炸,
/// 短窗口 ~3s);通知权限**首次建传输任务时**才请求(app 启动不弹,幂等)。
///
/// 降级哲学(与 AppLog 同款):插件初始化/权限/发送任何一步失败都静默,系统
/// 通知整体不可用只损失「后台感知」,不影响业务流。单测注入 sink/schedule/
/// gate/permission,零平台通道、零真实等待。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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
    TransferKind kind, List<TransferNotifyEntry> entries) {
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
  return (
    '$label完成:$okCount 成功 · ${fails.length} 失败',
    _nameList(fails, '失败:'),
  );
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
      final group =
          batch.where((r) => r.$1 == kind).map((r) => r.$2).toList();
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

  /// 测试构造:注入聚合批(自带 sink/gate/schedule)与权限桩,零平台通道。
  @visibleForTesting
  Notifier.test({required this._batcher, this._permission});

  /// Android 通知渠道(传输完成)。
  static const _channelId = 'ms_transfers';
  static const _channelName = '传输完成';
  static const _channelDesc = '上传/下载完成的后台通知';

  final _plugin = FlutterLocalNotificationsPlugin();

  /// 聚合批(init 成功才挂;null=通知不可用——单测/初始化失败静默降级,
  /// taskFinished/ensurePermission 直接 no-op,业务流零感知)。
  TransferNotifyBatcher? _batcher;

  /// 权限请求实现(注入点;null=真实平台通道)。
  Future<void> Function()? _permission;

  /// 本会话已请求过权限(幂等:至多请求一次;系统侧「未决才弹」由 OS 保证)。
  var _permissionAsked = false;

  @visibleForTesting
  bool get permissionAsked => _permissionAsked;

  var _notifyId = 0;

  /// main 挂接一次:插件初始化 + Android 渠道创建。iOS 侧启动**不弹**权限
  /// (Darwin 初始化全 false),权限统一在 [ensurePermission](首次入队)。
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
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDesc,
          ));
      _batcher = TransferNotifyBatcher(sink: _send, gate: isBackground);
      AppLog.info('notifier', '系统通知就绪(channel=$_channelId)');
    } catch (e) {
      _batcher = null;
      AppLog.error('notifier', '系统通知初始化失败,降级为仅应用内提示', e);
    }
  }

  /// 通知权限(Android 13+ 运行时权限 / iOS 授权):幂等,本会话至多请求一次;
  /// 首次建传输任务时调用(不在 app 启动即弹)。失败静默——无权限只损失后台
  /// 通知,不影响业务流。
  Future<void> ensurePermission() async {
    if (_permissionAsked || _batcher == null) return;
    _permissionAsked = true;
    try {
      final injected = _permission;
      if (injected != null) {
        await injected();
        return;
      }
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (e) {
      AppLog.error('notifier', '通知权限请求失败(静默降级,不影响任务)', e);
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
        kind, TransferNotifyEntry(ok: ok, filename: filename, detail: detail));
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
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (e) {
      AppLog.error('notifier', '通知发送失败:$title $body', e);
    }
  }
}
