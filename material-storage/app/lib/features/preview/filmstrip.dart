/// Filmstrip — 预览胶片条(B2 §8.2):顶部 ‹n/N› 同源的切张逻辑+横向缩略图条。
/// 序列=进入预览时的列表序;边界即停(首张不可前翻/末张不可后翻,web 同语义)。
/// FilmstripPager 为纯逻辑可单测;Widget 条供预览页挂载。
/// C1(app-polish):ScrollController 自动跟随——进入靠后张/横滑切张后把当前张
/// 滚到居中(已完全可见则不滚;首帧 jumpTo 免开场滚动,后续短动画 200ms)。
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
  void moveTo(int i) =>
      _i = length == 0 ? 0 : i.clamp(0, length - 1);
}

/// 布局常量(与 build 内保持同源):小格 48 + 间隔 6 + 条水平 padding 12。
const double _kThumb = 48;
const double _kGap = Tk.spaceSm; // 6→spaceSm(A2 就近归档)
const double _kItemStride = _kThumb + _kGap;
const double _kEdgePad = Tk.spaceMd;

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
    // C1:首帧定位——等首帧布局完拿到 viewport 后直接 jumpTo(无开场滚动)。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _follow(animate: false);
    });
  }

  @override
  void didUpdateWidget(covariant Filmstrip old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      // C1:切张(横滑/胶片条点选)后下一帧跟随;快速连滑时 animateTo 以
      // 当前 offset 重新出发,天然收敛到最后一次目标。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _follow(animate: true);
      });
    }
  }

  /// 当前张不完整可见时滚动到居中;已完全可见则不动(避免微抖)。
  void _follow({required bool animate}) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final viewport = position.viewportDimension;
    final left = _kEdgePad + widget.index * _kItemStride;
    final right = left + _kThumb;
    if (left >= position.pixels && right <= position.pixels + viewport) {
      return; // 当前张已完整可见
    }
    final target =
        ((left + right) / 2 - viewport / 2).clamp(0.0, position.maxScrollExtent);
    if (animate) {
      _controller.animateTo(target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic);
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
    return SizedBox(
      height: 60,
      child: ListView.separated(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
            horizontal: _kEdgePad, vertical: 6), // 参与定高计算(60=48+2×6)保留
        itemCount: widget.items.length,
        separatorBuilder: (_, _) => const SizedBox(width: _kGap),
        itemBuilder: (context, i) {
          final current = i == widget.index;
          return GestureDetector(
            onTap: () {
              Haptics.select(); // G2:轻量点选触觉
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
                  color: current ? Tk.accent : Colors.white24,
                ),
              ),
              child: ThumbnailImage(asset: widget.items[i]),
            ),
          );
        },
      ),
    );
  }
}
