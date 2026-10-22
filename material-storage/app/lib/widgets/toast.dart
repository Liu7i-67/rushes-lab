/// toast — 全局轻提示统一封装(app-polish A6;J1 重构为顶部 Overlay 悬浮条):
/// 顶部 SafeArea 下悬浮条(tone 图标配色沿用:成功绿/失败红/信息橙,surface
/// 底 + rLg 圆角 + 轻阴影 + 左右 margin),**点击条身即销毁**;[actionLabel]
/// 非空时右侧文字 action(执行 onAction 后销毁);[duration] 到时自动销毁;
/// 进出场各 150ms(淡入下滑 / 淡出上滑)。
///
/// 弃用 ScaffoldMessenger/SnackBar(用户反馈 #9:原从底部弹出且无法点击
/// 关闭):挂 root navigator(session.navigatorKey,app.dart 注入 MaterialApp)
/// 的 Overlay,条目在全部路由(含 sheet/dialog)之上,免疫遮挡;无 root
/// navigator 时(裸 MaterialApp 的单测环境)回退 [context] 所在最近
/// Overlay —— [context] 参数仅为该兼容保留,签名不变(存量调用零改动)。
/// 「latest wins」保留:新 toast 先无动画移除旧 entry,不排队。
///
/// P1-2(J1 探针实证缺陷修复):toast 生命周期绑定路由变化——路由
/// push/pop/replace 时主动销毁当前 toast(页面切走,旧页提示对新页无意义;
/// 兼修隐形 toast 吞新页 AppBar 首击的命中测试问题),见 [ToastRouteObserver]
/// (app.dart 挂 navigatorObservers;裸 MaterialApp 单测环境未挂 observer
/// 则退回原行为,同页 toast 不受任何影响)。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/session.dart';
import '../theme/tokens.dart';

enum ToastTone { success, error, info }

/// 进出场动画时长(J1 定稿 150ms)。
const _kToastAnim = Duration(milliseconds: 150);

/// 当前活跃 toast(latest-wins:新条先顶掉旧条;全库同刻至多一条)。
_ToastHandle? _current;

/// 展示轻提示;[actionLabel] 非空时挂右侧文字 action(如「查看详情」)。
void toast(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  ToastTone tone = ToastTone.info,
  Duration duration = const Duration(seconds: 3),
}) {
  final (icon, color) = switch (tone) {
    ToastTone.success => (Icons.check_circle_outline, Tk.green),
    ToastTone.error => (Icons.error_outline, Tk.red),
    ToastTone.info => (Icons.info_outline, Tk.accent),
  };
  final overlay =
      session.navigatorKey.currentState?.overlay ??
      Overlay.maybeOf(context, rootOverlay: true) ??
      Overlay.maybeOf(context);
  if (overlay == null) return; // 极端早期(无 Overlay)静默放弃
  _current?._removeNow(); // latest-wins:先移除旧 entry,再挂新条
  final handle = _ToastHandle(
    overlay: overlay,
    icon: icon,
    iconColor: color,
    message: message,
    actionLabel: actionLabel,
    onAction: onAction,
    duration: duration,
  ).._show();
  _current = handle;
}

/// P1-2(J1 探针实证缺陷修复):主动销毁当前 toast(若有)——路由变化时由
/// [ToastRouteObserver] 调;立即摘除 entry(不走 150ms 退场动画,页面切换
/// 即刻让位,不留参与命中测试的隐形残影)。无在显 toast 时安全空操作。
void dismissCurrentToast() {
  _current?._removeNow();
  _current = null;
}

/// P1-2:路由观察者——push/pop/replace 即销毁当前 toast。语义:页面切走,
/// 旧页提示对新页无意义;兼修 Overlay 条目跨路由存活、隐形盖住新页顶部
/// (AppBar 返回键区)吞首击的缺陷。app.dart 挂 MaterialApp
/// .navigatorObservers;裸 MaterialApp 的单测环境未挂 observer 时不生效
/// (同页 toast 行为零改动)。didPop 覆盖「toast 弹出后用户按返回」场景。
class ToastRouteObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      dismissCurrentToast();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      dismissCurrentToast();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      dismissCurrentToast();
}

/// 一条 toast 的宿主句柄:持有 OverlayEntry,负责插入与移除(立即顶替 /
/// 动画退场后摘除)。
class _ToastHandle {
  _ToastHandle({
    required this.overlay,
    required this.icon,
    required this.iconColor,
    required this.message,
    required this.duration,
    this.actionLabel,
    this.onAction,
  });

  final OverlayState overlay;
  final IconData icon;
  final Color iconColor;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration duration;

  OverlayEntry? _entry;

  void _show() {
    _entry = OverlayEntry(builder: (_) => _ToastBar(handle: this));
    overlay.insert(_entry!);
  }

  /// 摘除 entry(latest-wins 顶替、退场动画完成共用)。同一帧内先插后摘
  /// (连发顶替)也须真移除——不能用 entry.mounted 判跳过(未首帧构建的
  /// entry mounted 恒 false,会漏摘);宿主已随旧树销毁时 remove() 自身
  /// 按 overlay 未挂载安全返回,无需前置守卫。
  void _removeNow() {
    _entry?.remove();
    _entry = null;
  }
}

class _ToastBar extends StatefulWidget {
  const _ToastBar({required this.handle});

  final _ToastHandle handle;

  @override
  State<_ToastBar> createState() => _ToastBarState();
}

class _ToastBarState extends State<_ToastBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: _kToastAnim,
    reverseDuration: _kToastAnim,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _anim,
    curve: Curves.easeOut,
  );
  late final Animation<Offset> _slide = Tween(
    begin: const Offset(0, -0.4),
    end: Offset.zero,
  ).animate(_curve);

  Timer? _auto;
  var _exiting = false;

  @override
  void initState() {
    super.initState();
    _anim.addStatusListener(_onStatus);
    _anim.forward();
    _auto = Timer(widget.handle.duration, _beginExit);
  }

  /// 退场动画播完摘除 entry(dispose 自清 timer/动画,防泄漏)。
  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _exiting) {
      widget.handle._removeNow();
    }
  }

  /// 点击条身 / action / 自动到期统一的退场入口:停掉自动销毁,反向播放。
  void _beginExit() {
    if (_exiting || !mounted) return;
    _exiting = true;
    _auto?.cancel();
    _anim.reverse();
  }

  @override
  void dispose() {
    _auto?.cancel(); // 顶替立即移除时状态直接 dispose,防 timer 泄漏
    _curve.dispose();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.handle;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Tk.spaceMd,
            Tk.spaceSm,
            Tk.spaceMd,
            0,
          ),
          child: FadeTransition(
            opacity: _curve,
            child: SlideTransition(
              position: _slide,
              child: Material(
                color: Tk.surface,
                elevation: 3, // 轻阴影
                borderRadius: const BorderRadius.all(Radius.circular(Tk.rLg)),
                child: InkWell(
                  borderRadius: const BorderRadius.all(Radius.circular(Tk.rLg)),
                  onTap: _beginExit, // 点击条身即销毁
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Tk.spaceLg,
                      Tk.spaceMd,
                      Tk.spaceSm,
                      Tk.spaceMd,
                    ),
                    child: Row(
                      children: [
                        Icon(h.icon, size: 20, color: h.iconColor),
                        const SizedBox(width: Tk.spaceSm),
                        Expanded(child: Text(h.message)),
                        if (h.actionLabel != null)
                          TextButton(
                            onPressed: () {
                              h.onAction?.call();
                              _beginExit();
                            },
                            child: Text(h.actionLabel!),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
