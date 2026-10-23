/// MaintenanceOverlay — 维护横幅全局弹层(B9 §8.12):挂 MaterialApp.builder,
/// 覆盖登录页与主界面全部路由(不分登录态)。maintaining=不可关强提示
/// (PopScope canPop:false + barrierDismissible:false,部署窗口阻止继续
/// 上传/下载);justFinished=「升级完成」自动关(controller 6s 计时);
/// 网络错误不触发任何切换(控制器 lastKnownActive 兜底)。
///
/// 实现注记:builder 位置在 Navigator 之上,弹层走全局 navigatorKey 压路由
/// (Android 返回键被 PopScope 拦死,不能只做 Stack 遮罩);内容经
/// ListenableBuilder 跟随 controller 原地刷新(维持中 message/issues 变化可见)。
/// 视觉:墨色 + 金色双主题 — 弹层底/圆角/标题 20 全部交 DialogTheme,
/// 状态点 warn、完成图标 ok、issues 编号 goldInk、遮罩 scrim。
library;

import 'package:flutter/material.dart';

import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../session.dart';
import 'banner_controller.dart';

enum _DialogKind { none, maintaining, finished }

class MaintenanceOverlay extends StatefulWidget {
  const MaintenanceOverlay({super.key, this.controller});

  /// 测试注入;默认全局单例。
  final MaintenanceBannerController? controller;

  @override
  State<MaintenanceOverlay> createState() => _MaintenanceOverlayState();
}

class _MaintenanceOverlayState extends State<MaintenanceOverlay> {
  MaintenanceBannerController get _c => widget.controller ?? maintenanceBanner;
  _DialogKind _kind = _DialogKind.none;
  Future<void>? _shown;

  @override
  void initState() {
    super.initState();
    _c.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    _c.removeListener(_sync);
    super.dispose();
  }

  _DialogKind get _target => switch (_c.phase) {
    MaintenancePhase.maintaining => _DialogKind.maintaining,
    MaintenancePhase.justFinished => _DialogKind.finished,
    _ => _DialogKind.none,
  };

  void _sync() {
    if (!mounted) return;
    if (_target == _kind && _shown != null) return; // 已就位(内容自刷新)
    _close();
    _open();
  }

  void _close() {
    _kind = _DialogKind.none;
    final f = _shown;
    _shown = null;
    final nav = session.navigatorKey.currentState;
    if (f != null && nav != null && nav.canPop()) nav.pop();
  }

  void _open() {
    final kind = _target;
    if (kind == _DialogKind.none) return;
    final nav = session.navigatorKey.currentState;
    if (nav == null) {
      // Navigator 未就绪(冷启动极早期),下一帧重试
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
      return;
    }
    final f = showDialog<void>(
      context: nav.context,
      barrierDismissible: false,
      barrierColor: nav.context.tk.scrim,
      builder: (_) => PopScope(
        canPop: false,
        child: kind == _DialogKind.maintaining
            ? _MaintainingCard(controller: _c)
            : const _FinishedCard(),
      ),
    );
    _shown = f;
    _kind = kind;
    f.whenComplete(() {
      if (!identical(_shown, f)) return; // 已被新弹层顶替,老闭包不处理
      _shown = null;
      _kind = _DialogKind.none;
      // 被外部清路由(如 401 回登录页)移除但仍非 idle → 重弹
      if (_c.phase != MaintenancePhase.idle) _sync();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 维护中卡片:内容经 ListenableBuilder 跟随 controller(维持中更新可见)。
class _MaintainingCard extends StatelessWidget {
  const _MaintainingCard({required this.controller});

  final MaintenanceBannerController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final tk = context.tk;
        final info = controller.info;
        final custom = info?.message?.trim();
        final issues = info?.issues ?? const <(int, String)>[];
        return AlertDialog(
          title: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: tk.warn,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: Tk.spaceSm),
              // 字号/字重交 DialogTheme(title 20);此处只带语义文案。
              const Expanded(child: Text('系统升级中')),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  custom == null || custom.isEmpty
                      ? '我们正在部署一次更新,通常 1 分钟内恢复。'
                      : custom,
                  style: TextStyle(fontSize: 14, height: 1.5, color: tk.ink2),
                ),
                if (issues.isNotEmpty) ...[
                  const SizedBox(height: Tk.spaceMd),
                  Text(
                    '本次解决',
                    style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                  ),
                  const SizedBox(height: Tk.spaceXs),
                  for (final (no, summary) in issues)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '#$no',
                            style: TextStyle(
                              fontSize: Tk.fzMd,
                              fontWeight: FontWeight.w600,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              color: tk.goldInk,
                            ),
                          ),
                          const SizedBox(width: Tk.spaceSm),
                          Expanded(
                            child: Text(
                              summary,
                              style: TextStyle(
                                fontSize: Tk.fzMd,
                                height: 1.5,
                                color: tk.ink2,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                const SizedBox(height: Tk.spaceMd),
                Text(
                  '如果你正在上传或下载,可能会被打断 — 升级完成后请重试。',
                  style: TextStyle(
                    fontSize: Tk.fzMd,
                    height: 1.5,
                    color: tk.ink3,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 升级完成卡片(6s 后由 controller 计时切 idle,弹层随之自动关)。
class _FinishedCard extends StatelessWidget {
  const _FinishedCard();

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.check_circle, size: 20, color: tk.ok),
          const SizedBox(width: Tk.spaceSm),
          const Expanded(child: Text('升级完成')),
        ],
      ),
      content: Text(
        '已恢复正常使用,如果之前的操作中断,请重新尝试一次。',
        style: TextStyle(fontSize: 14, height: 1.5, color: tk.ink2),
      ),
    );
  }
}
