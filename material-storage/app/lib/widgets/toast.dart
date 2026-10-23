/// toast — 全局轻提示统一封装(墨色 + 金色:底部 86 暖炭条):
/// 悬浮在底部 86(键盘弹出时再顶起 viewInsets),固定暖炭底
/// (`#383228`,两种主题一致)+ 1px 细描边 + rSm 圆角 + shadow2 深色版;
/// 左侧 8 圆点(info/success 金 / error 红),正文 13.5;
/// **点击条身即销毁**;[actionLabel] 非空时右侧文字 action(执行 onAction
/// 后销毁);[duration] 默认 2.4s 到时自动销毁;进出场各 150ms(淡入上滑 /
/// 淡出下滑)。
///
/// 弃用 ScaffoldMessenger/SnackBar(用户反馈 #9):挂 root navigator
/// (session.navigatorKey,app.dart 注入 MaterialApp)的 Overlay,条目在全部
/// 路由(含 sheet/dialog)之上,免疫遮挡;无 root navigator 时(裸
/// MaterialApp 的单测环境)回退 [context] 所在最近 Overlay —— [context]
/// 参数仅为该兼容保留,签名不变(存量调用零改动)。
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
import '../theme/tk_colors.dart';
import '../theme/tokens.dart';

// ToastRouteObserver 拆到独立文件(§5.6);此处转出,app.dart 的
// `import 'widgets/toast.dart' show ToastRouteObserver` 无需改动。
export 'toast_route_observer.dart';

enum ToastTone { success, error, info }

/// 进出场动画时长(J1 定稿 150ms)。
const _kToastAnim = Duration(milliseconds: 150);

/// 浮层距底距离(设计 §2:Toast 底部 86;键盘弹出再顶起)。
const double kToastBottomOffset = 86;

/// 默认展示时长(设计 §2:2.4s 自动消失)。
const Duration kToastDuration = Duration(milliseconds: 2400);

/// 当前活跃 toast(latest-wins:新条先顶掉旧条;全库同刻至多一条)。
_ToastHandle? _current;

/// 展示轻提示;[actionLabel] 非空时挂右侧文字 action(如「查看详情」)。
void toast(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  ToastTone tone = ToastTone.info,
  Duration duration = kToastDuration,
}) {
  final dot = switch (tone) {
    ToastTone.success || ToastTone.info => Tk.previewGold,
    ToastTone.error => Tk.dangerOnDark,
  };
  final overlay =
      session.navigatorKey.currentState?.overlay ??
      Overlay.maybeOf(context, rootOverlay: true) ??
      Overlay.maybeOf(context);
  if (overlay == null) return; // 极端早期(无 Overlay)静默放弃
  _current?._removeNow(); // latest-wins:先移除旧 entry,再挂新条
  final handle = _ToastHandle(
    overlay: overlay,
    dotColor: dot,
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

/// 一条 toast 的宿主句柄:持有 OverlayEntry,负责插入与移除(立即顶替 /
/// 动画退场后摘除)。
class _ToastHandle {
  _ToastHandle({
    required this.overlay,
    required this.dotColor,
    required this.message,
    required this.duration,
    this.actionLabel,
    this.onAction,
  });

  final OverlayState overlay;
  final Color dotColor;
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
    begin: const Offset(0, 0.4), // 底部弹出:自下而上
    end: Offset.zero,
  ).animate(_curve);

  Timer? _auto;
  var _exiting = false;
  var _started = false;
  var _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true; // MediaQuery 首帧才可读,show/timer 延到这里启动
    // P2-7:reduced-motion 下不走 150ms 进出场(直接显隐)。
    _reduced = MediaQuery.disableAnimationsOf(context);
    _anim.addStatusListener(_onStatus);
    if (_reduced) {
      _anim.value = 1;
    } else {
      _anim.forward();
    }
    _auto = Timer(widget.handle.duration, _beginExit);
  }

  /// 退场动画播完摘除 entry(dispose 自清 timer/动画,防泄漏)。
  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _exiting) {
      widget.handle._removeNow();
    }
  }

  /// 点击条身 / action / 自动到期统一的退场入口:停掉自动销毁,反向播放;
  /// reduced-motion 直接摘除(无动画 ticker)。
  void _beginExit() {
    if (_exiting || !mounted) return;
    _exiting = true;
    _auto?.cancel();
    if (_reduced) {
      widget.handle._removeNow();
      return;
    }
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
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    // 固定暖炭底:浅色主题下也保持深色表面(设计 §3.1),故取 TkColors.dark。
    const barColor = Color(0xFF383228); // = TkColors.dark.surface4
    const barBorder = Color(0x12FFFFFF); // rgba(255,255,255,.07)
    const barText = Color(0xFFF3EDDF); // = TkColors.dark.ink
    return Positioned(
      left: Tk.spacePage,
      right: Tk.spacePage,
      bottom: kToastBottomOffset + insets,
      child: FadeTransition(
        opacity: _curve,
        child: SlideTransition(
          position: _slide,
          child: Container(
            decoration: BoxDecoration(
              color: barColor,
              borderRadius: BorderRadius.circular(Tk.rSm),
              border: Border.all(color: barBorder),
              boxShadow: TkColors.dark.shadow2,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(Tk.rSm),
                onTap: _beginExit, // 点击条身即销毁
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  child: Row(
                    children: [
                      _ToastDot(color: h.dotColor),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          h.message,
                          style: const TextStyle(
                            color: barText,
                            fontSize: 13.5,
                            height: 1.45,
                          ),
                        ),
                      ),
                      if (h.actionLabel != null)
                        TextButton(
                          onPressed: () {
                            h.onAction?.call();
                            _beginExit();
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: Tk.previewGold,
                            minimumSize: const Size(44, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            textStyle: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
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
    );
  }
}

/// 左侧 8 圆点(tone 色;error 红)。
class _ToastDot extends StatelessWidget {
  const _ToastDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('toast-dot'),
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
