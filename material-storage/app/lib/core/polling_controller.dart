/// PollingController — 前台轮询单机(B7 §8.7 定稿):**仅前台 + 已登录才轮**,
/// 进后台/登出/401 即停,恢复前台立即刷一次再续周期;防重叠(上一轮未完成
/// 不发下一轮,完成后才排下一拍)。全局唯一实例挂 App 生命周期
/// (WidgetsBindingObserver)+ Session 门控,防多页面各起计时器。
///
/// 可测化:计时走 [Timer](widget 测试 FakeAsync 下 tester.pump 即假时钟推进);
/// tick/gate 皆抽象方法,测试注入假实现即可,无需真实网络。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'api/ms_api.dart';
import 'session.dart';

abstract class PollingController extends ChangeNotifier
    with WidgetsBindingObserver {
  PollingController({this.interval = const Duration(seconds: 30)});

  /// 轮询周期(§8.7:30s,web refetchInterval 同款)。
  final Duration interval;

  Timer? _timer;
  bool _active = false; // 循环在跑(前台周期中)
  bool _busy = false; // 上一轮 tick 未完成(防重叠)

  /// 是否在轮询(测试/调试观测)。
  bool get polling => _active;

  /// 是否允许轮询(子类给门控:已登录且 API 就绪)。
  bool canPoll();

  /// 一轮拉取(子类实现;抛异常=本轮失败,不终止循环)。
  Future<void> performTick();

  /// 挂 App 生命周期观察(进程内一次;main.dart 调)。
  void attach() => WidgetsBinding.instance.addObserver(this);

  /// 门控变化入口(Session notify 驱动:登录/登出/401 清会话):
  /// 满足门控且未跑 → 立即刷一次再续周期;不满足 → 停。
  void syncGate() {
    if (canPoll()) {
      if (!_active) refreshNow();
    } else {
      stop();
    }
  }

  /// 立即刷一次再续周期(恢复前台/启动;与 web refetchOnWindowFocus 同哲学)。
  void refreshNow() {
    _timer?.cancel();
    _timer = null;
    _active = true;
    _runTick();
  }

  /// 停轮询(进后台/登出/401):取消待拍;in-flight 一轮让它自然落地,
  /// 完成回调见 _active=false 不再续拍。
  void stop() {
    _active = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _runTick() async {
    if (_busy || !_active) return;
    _busy = true;
    try {
      await performTick();
    } catch (_) {
      // 单轮失败不终止循环(弱网抖动下一拍自愈);401 由 Session 清会话
      // 经 syncGate 停轮,这里不重复处置。
    } finally {
      _busy = false;
      if (_active) {
        _timer?.cancel();
        _timer = Timer(interval, () {
          _timer = null;
          _runTick();
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 恢复前台:立即刷一次再续周期(即便从未停过也重拍,保证新鲜)
      if (canPoll()) refreshNow();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      stop(); // 进后台即停
    }
    // inactive(iOS 下拉通知/过渡态)不停:仍是前台语义
  }
}

/// UnreadPoller — 通知未读数轮询(§8.7):30s `GET /notifications?limit=1`
/// 取 unread_count(web useNotificationsUnread 同款),驱动我的 tab badge
/// 与我的页「通知」入口红点(全局未读,无逐项目口径)。
class UnreadPoller extends PollingController {
  /// [sessionOverride] 仅供测试注入隔离实例;生产恒绑全局 [session]。
  UnreadPoller({Session? sessionOverride, this.api})
      : _session = sessionOverride ?? session;

  final Session _session;

  /// 测试注入的 API(优先);生产为 null → 读 session.api(探活后才就绪)。
  final MsApi? api;

  int _unreadCount = 0;

  /// 当前全局未读数;写入即广播(badge/红点 AnimatedBuilder 重建)。
  int get unreadCount => _unreadCount;
  set unreadCount(int v) {
    if (v == _unreadCount) return;
    _unreadCount = v;
    notifyListeners();
  }

  @override
  bool canPoll() => _session.me != null && effectiveApi != null;

  /// API 解析:注入优先,否则会话 API(未探活/未登录为 null)。
  MsApi? get effectiveApi => api ?? _session.api;

  @override
  void stop() {
    super.stop();
    // P2-5:登出/401 停轮即清零复位 —— 防重登后、首轮 tick 落地前
    // 短暂显示上一账号的计数(进后台停轮同样复位,回前台 refreshNow 立即重拉)。
    unreadCount = 0;
  }

  @override
  Future<void> performTick() async {
    final api = effectiveApi;
    if (api == null) return;
    final list = await api.notifications.list(limit: 1);
    unreadCount = list.unreadCount;
  }
}

/// 全局单例(§8.7 单一 PollingController;main.dart attach + Session 门控接线,
/// 默认绑全局 [session])。
final UnreadPoller unreadPoller = UnreadPoller();
