/// FastScrollBar — 大列表右缘快速拖动条(F2 快速滚动条)。
///
/// 纯 UI 组件,不含任何加载逻辑:Stack 右缘覆盖的竖向拖动轨,thumb 高度按
/// 视口/maxScrollExtent 比例映射(最小 40);拖动中按 thumb 中心在轨道中的
/// 比例实时 `jumpTo` 跟手、滑块左侧浮「~N / M」序号气泡(位置 clamp 视口内),
/// 松手回调 [FastScrollBar.onSeek](显示序 index)交给页面触发补齐加载
/// (PagedWindow.offsetWindowFor,F3/F4 接线)。
///
/// 用法:调用方在列表 Stack 内右缘摆 `Align(child: FastScrollBar(...))`
/// ——组件吃满可用高度(热区宽 28 居中视觉条 4)。显隐由外部门控:
/// visible=false 或 total<=0 渲染 SizedBox.shrink(F3/F4 用 total≥100 +
/// 非 loading/error/empty + 非多选态)。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tokens.dart';

/// 列表右缘快速滚动条(拖动跟手 + 序号气泡 + 松手 seek 回调)。
class FastScrollBar extends StatefulWidget {
  const FastScrollBar({
    super.key,
    required this.controller,
    required this.total,
    required this.visible,
    this.onSeek,
    this.bubbleLabelBuilder,
  });

  /// 列表滚动控制器(读 pixels/viewportDimension/maxScrollExtent,jumpTo 跟手)。
  final ScrollController controller;

  /// 列表全量条数(= PagedWindow.total;气泡 M 与 seek 换算用)。
  final int total;

  /// 显隐开关(false 渲染 SizedBox.shrink;门控在调用方)。
  final bool visible;

  /// 拖动释放回调:入参 = 松手位置对应显示序 index(clamp [0, total-1]);
  /// 页面在此触发缺口补齐加载。null = 只跟手不回调。
  final void Function(int displayIndex)? onSeek;

  /// 气泡文案定制(入参 = 拖动位置对应显示序 index);缺省「~N / M」。
  final String Function(int displayIndex)? bubbleLabelBuilder;

  @override
  State<FastScrollBar> createState() => _FastScrollBarState();
}

class _FastScrollBarState extends State<FastScrollBar> {
  // ── 视觉常量:热区 28 便于手指命中,视觉条 4,thumb 6 略宽作把手示意 ──
  static const double _hotZone = 28;
  static const double _trackW = 4;
  static const double _thumbW = 6;
  static const double _trackInset = 10; // 轨道上下留白
  static const double _minThumbH = 40;
  static const double _bubbleH = 34; // 气泡估高(fzSm 文本+内边距,定位 clamp 用)

  bool _dragging = false;
  double _dragF = 0; // 拖动中 thumb 中心在轨道中的比例 [0,1]
  double _boxH = 0; // LayoutBuilder 实测高(拖动几何换算用)

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScrollChanged);
  }

  @override
  void didUpdateWidget(covariant FastScrollBar old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      // 换 controller:旧监听摘除、新监听挂上,并立即重算几何
      old.controller.removeListener(_onScrollChanged);
      widget.controller.addListener(_onScrollChanged);
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScrollChanged);
    super.dispose();
  }

  void _onScrollChanged() {
    if (mounted) setState(() {}); // 列表滚动 → thumb 位置实时跟随
  }

  // ── 几何换算(thumb 高度/位置计算前一律先判 hasClients)──────────────

  /// null = controller 尚未挂上滚动视口(hasClients=false)。
  ScrollPosition? get _position =>
      widget.controller.hasClients ? widget.controller.position : null;

  /// 当前滚动比例 [0,1](未挂载 / maxScrollExtent<=0 → 0)。
  double get _scrollF {
    final pos = _position;
    final maxExtent = pos?.maxScrollExtent ?? 0;
    if (maxExtent <= 0) return 0;
    return (pos!.pixels / maxExtent).clamp(0.0, 1.0);
  }

  /// thumb 高度 = viewport/maxScrollExtent 比例映射轨道高(最小 40);
  /// 全量已在视口内(maxScrollExtent<=0)→ 满轨。
  double _thumbHeight(double trackH) {
    final pos = _position;
    final maxExtent = pos?.maxScrollExtent ?? 0;
    if (maxExtent <= 0) return trackH;
    final h = trackH * pos!.viewportDimension / maxExtent;
    return h.clamp(_minThumbH, trackH);
  }

  /// 轨道高 = 可用高 − 上下留白(极小视口兜到最小 thumb 高)。
  double get _trackH =>
      (_boxH - _trackInset * 2).clamp(_minThumbH, double.infinity);

  // ── 拖动:按 thumb 中心在轨道中的比例 f 实时 jumpTo 跟手 ──────────────

  void _onDragStart(DragStartDetails d) => _applyDrag(d.localPosition.dy);

  void _onDragUpdate(DragUpdateDetails d) => _applyDrag(d.localPosition.dy);

  void _applyDrag(double dy) {
    if (_boxH <= 0) return; // 未完成布局,几何不可信
    final trackH = _trackH;
    final thumbH = _thumbHeight(trackH);
    final span = trackH - thumbH;
    final f = ((dy - _trackInset - thumbH / 2) / (span <= 0 ? 1 : span)).clamp(
      0.0,
      1.0,
    );
    setState(() {
      _dragging = true;
      _dragF = f;
    });
    final maxExtent = _position?.maxScrollExtent ?? 0;
    if (maxExtent > 0) {
      widget.controller.jumpTo((f * maxExtent).clamp(0.0, maxExtent));
    }
  }

  void _onDragEnd(DragEndDetails d) {
    if (!_dragging) return;
    setState(() => _dragging = false); // 收起气泡
    if (widget.total <= 0) return;
    widget.onSeek?.call(
      (_dragF * widget.total).round().clamp(0, widget.total - 1),
    );
  }

  void _onDragCancel() {
    if (_dragging) setState(() => _dragging = false); // 取消不触发 seek
  }

  // ── 渲染 ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!widget.visible || widget.total <= 0) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, cons) {
        final boxH = cons.maxHeight;
        if (!boxH.isFinite) return const SizedBox.shrink(); // 需有界高(Stack 场景必有)
        _boxH = boxH;
        final tk = context.tk;
        final trackH = _trackH;
        final thumbH = _thumbHeight(trackH);
        final f = _dragging ? _dragF : _scrollF;
        final hasClients = _position != null;
        return SizedBox(
          width: _hotZone,
          height: boxH,
          child: Stack(
            clipBehavior: Clip.none, // 气泡向左溢出条体(仍在列表 Stack 界内)
            alignment: Alignment.centerRight,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: _onDragStart,
                onVerticalDragUpdate: _onDragUpdate,
                onVerticalDragEnd: _onDragEnd,
                onVerticalDragCancel: _onDragCancel,
                child: Center(
                  child: SizedBox(
                    width: _trackW,
                    height: trackH,
                    child: Stack(
                      alignment: Alignment.topCenter,
                      children: [
                        Container(
                          // 视觉轨道(发丝线令牌:装饰性,HandleStrip 同源)
                          decoration: BoxDecoration(
                            color: tk.lineStrong,
                            borderRadius: BorderRadius.circular(Tk.rPill),
                          ),
                        ),
                        if (hasClients)
                          Positioned(
                            top: f * (trackH - thumbH),
                            child: Container(
                              // thumb(把手):金色,暗亮两色均可辨
                              width: _thumbW,
                              height: thumbH,
                              decoration: BoxDecoration(
                                color: tk.gold,
                                borderRadius: BorderRadius.circular(Tk.rPill),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_dragging) _buildBubble(context, trackH, thumbH),
            ],
          ),
        );
      },
    );
  }

  /// 滑块左侧序号气泡「~N / M」;垂直位置随 thumb 中心、clamp 视口内。
  Widget _buildBubble(BuildContext context, double trackH, double thumbH) {
    final tk = context.tk;
    final n = (_dragF * widget.total).round().clamp(0, widget.total - 1);
    final label = widget.bubbleLabelBuilder?.call(n) ?? '~$n / ${widget.total}';
    final thumbCenterY = _trackInset + _dragF * (trackH - thumbH) + thumbH / 2;
    final lo = _trackInset;
    var hi = _boxH - _bubbleH - _trackInset;
    if (hi < lo) hi = lo; // 极小视口兜底,防 clamp 上下界倒挂抛错
    final top = (thumbCenterY - _bubbleH / 2).clamp(lo, hi);
    return Positioned(
      right: _hotZone - 8, // 右缘贴视觉条左侧留 8,向左溢出条体
      top: top,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: tk.ink,
            borderRadius: BorderRadius.circular(Tk.rPill),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: Tk.fzSm,
              fontWeight: FontWeight.w600,
              color: tk.bg,
            ),
          ),
        ),
      ),
    );
  }
}
