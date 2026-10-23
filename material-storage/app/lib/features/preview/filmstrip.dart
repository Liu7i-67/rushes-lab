/// Filmstrip — 预览胶片条(F9;D10 保留原型省略的既有能力):横向缩略图条,
/// 选中金框(previewGold / 2px)、圆角 10、间距 8;浮层化=previewSurface 底 +
/// 圆角 18 + 横向留边。序列=进入预览时的列表序;边界即停;当前张恒居中
/// (首帧 jumpTo,切张 200ms animateTo)。
library;

import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../assets/thumbnail_image.dart';

class FilmstripPager {
  FilmstripPager({required this.length, int initial = 0})
    : _i = length == 0 ? 0 : initial.clamp(0, length - 1);

  final int length;
  int _i;

  int get index => _i;
  bool get canPrev => _i > 0;
  bool get canNext => _i < length - 1;

  /// 边界即停:越界请求返回 false 且不动游标。
  bool prev() {
    if (!canPrev) return false;
    _i--;
    return true;
  }

  bool next() {
    if (!canNext) return false;
    _i++;
    return true;
  }

  /// 定位(胶片条点按):越界 clamp 到边界。
  void moveTo(int i) => _i = length == 0 ? 0 : i.clamp(0, length - 1);
}

/// 布局常量(与 build 同源):小格 48 + 间隔 8(spaceSm)+ 条内水平 padding 8;
/// 浮层卡另加页面留边 12。
const double _kThumb = 48;
const double _kGap = Tk.spaceSm;
const double _kItemStride = _kThumb + _kGap;
const double _kEdgePad = Tk.spaceSm;

class Filmstrip extends StatefulWidget {
  const Filmstrip({
    super.key,
    required this.items,
    required this.index,
    required this.onSelect,
  });

  final List<Asset> items;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  State<Filmstrip> createState() => _FilmstripState();
}

class _FilmstripState extends State<Filmstrip> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    // 首帧定位——布局完拿到 viewport 后直接 jumpTo(无开场滚动)。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _follow(animate: false);
    });
  }

  @override
  void didUpdateWidget(covariant Filmstrip old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _follow(animate: true);
      });
    }
  }

  /// 当前张恒居中(G1):index 变化后一律把当前张滚到条中央
  /// (target=(item 中心-viewport/2).clamp);首帧 jumpTo。
  void _follow({required bool animate}) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final viewport = position.viewportDimension;
    final left = _kEdgePad + widget.index * _kItemStride;
    final right = left + _kThumb;
    final target = ((left + right) / 2 - viewport / 2).clamp(
      0.0,
      position.maxScrollExtent,
    );
    if (animate) {
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    } else {
      _controller.jumpTo(target);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.length < 2) return const SizedBox.shrink();
    return Container(
      // 62 = 内容 60(48 格 + 上下 6)+ 卡片 1px 描边 ×2
      height: 62,
      margin: const EdgeInsets.fromLTRB(Tk.spaceMd, 0, Tk.spaceMd, Tk.spaceSm),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Tk.previewSurface,
        borderRadius: BorderRadius.circular(Tk.rLg),
        border: Border.all(color: Tk.previewLine),
      ),
      child: ListView.separated(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: _kEdgePad,
          vertical: 6,
        ), // 参与定高(60=48+2×6)
        itemCount: widget.items.length,
        separatorBuilder: (_, _) => const SizedBox(width: _kGap),
        itemBuilder: (context, i) {
          final current = i == widget.index;
          // P2-6:小格补按钮/选中语义与「第 N 张」标签(读屏可定位/感知当前)。
          return Semantics(
            container: true,
            button: true,
            selected: current,
            label: '第 ${i + 1} 张',
            child: GestureDetector(
              onTap: () {
                Haptics.select();
                widget.onSelect(i);
              },
              child: Container(
                width: _kThumb,
                height: _kThumb,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Tk.rSm),
                  border: Border.all(
                    width: current ? 2 : 1,
                    color: current ? Tk.previewGold : Tk.previewLine,
                  ),
                ),
                child: ThumbnailImage(asset: widget.items[i]),
              ),
            ),
          );
        },
      ),
    );
  }
}
