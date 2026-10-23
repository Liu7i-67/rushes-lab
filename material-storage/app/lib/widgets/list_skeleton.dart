/// ListSkeleton — 列表/宫格加载骨架(app-polish A9,方案 §A9):替代主要
/// 页面首载的居中裸转圈。两形态:columns=1 列表行(40 圆头像+双行条),
/// columns≥2 宫格方块(默认 3 列)。呼吸式闪烁用 FadeTransition(不引
/// shimmer 包),骨面另叠一道 `sheen` 水平高光(P2-4,独立 1.3s 扫过);
/// `MediaQuery.disableAnimations` 为 true 时静态 0.7 透明度、无高光扫动,
/// 不 repeat——避免 reduced-motion 设备/测试的持续动画。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tokens.dart';

class ListSkeleton extends StatefulWidget {
  const ListSkeleton({
    super.key,
    this.rows = 6,
    this.columns = 1,
    this.padding = const EdgeInsets.all(Tk.spaceLg),
  });

  /// 行数(列表模式=行条数;宫格模式=宫格行数,格子数 = rows * columns)。
  final int rows;

  /// 列数;1=列表形态,≥2=宫格形态(每行 columns 个方块)。
  final int columns;

  final EdgeInsetsGeometry padding;

  @override
  State<ListSkeleton> createState() => _ListSkeletonState();
}

class _ListSkeletonState extends State<ListSkeleton>
    with TickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  /// 骨面高光扫过:独立 1.3s 循环,与 900ms 呼吸互不干扰。
  late final _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );

  /// reduced-motion:不启动呼吸动画,用静态 0.7 透明度。
  var _reduced = false;
  var _driven = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced != _reduced) {
      _reduced = reduced;
      if (!reduced) _driven = false; // 恢复动画时重新按需启动
    }
    if (_reduced) {
      _c.stop();
      _sweep.stop();
    } else if (!_driven) {
      _driven = true;
      _c
        ..value = 0
        ..repeat(reverse: true);
      _sweep
        ..value = 0
        ..repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = Tween(
      begin: 0.45,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));
    final sweep = _reduced ? null : _sweep;
    final body = widget.columns <= 1
        ? Column(
            children: [
              for (var i = 0; i < widget.rows; i++) ...[
                if (i > 0) const SizedBox(height: Tk.spaceMd),
                _RowBone(sweep: sweep),
              ],
            ],
          )
        : GridView.count(
            crossAxisCount: widget.columns,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: Tk.spaceMd,
            crossAxisSpacing: Tk.spaceMd,
            childAspectRatio: 0.75,
            padding: EdgeInsets.zero,
            children: [
              for (var i = 0; i < widget.rows * widget.columns; i++)
                _CellBone(sweep: sweep),
            ],
          );
    return Padding(
      padding: widget.padding,
      child: _reduced
          ? Opacity(opacity: 0.7, child: body)
          : FadeTransition(opacity: fade, child: body),
    );
  }
}

/// 骨架块基件:圆角填充块(surface3)+ sheen 高光;统一 key 供测试定位。
class _Bone extends StatelessWidget {
  const _Bone({
    this.width,
    required this.height,
    this.round = false,
    this.sweep,
  });

  final double? width;
  final double height;
  final bool round;

  /// 高光扫过进度(0→1 循环);null = reduced-motion 静态底色。
  final Animation<double>? sweep;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final radius = BorderRadius.circular(round ? 999 : Tk.rSm);
    final animation = sweep;
    return Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: tk.surface3, borderRadius: radius),
      child: animation == null
          ? null
          : AnimatedBuilder(
              animation: animation,
              builder: (context, _) {
                // 高光带从左侧画外扫到右侧画外(中心 -1.8 → 1.8)。
                final shift = -1.8 + 3.6 * animation.value;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment(shift - 0.7, 0),
                      end: Alignment(shift + 0.7, 0),
                      colors: [
                        tk.sheen.withValues(alpha: 0),
                        tk.sheen,
                        tk.sheen.withValues(alpha: 0),
                      ],
                      stops: const [0.0, 0.5, 1.0],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// 列表行骨:40 圆头像 + 双行条(内容加载期的形状暗示)。
class _RowBone extends StatelessWidget {
  const _RowBone({this.sweep});

  final Animation<double>? sweep;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Bone(width: 40, height: 40, round: true, sweep: sweep),
        const SizedBox(width: Tk.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Bone(height: 13, sweep: sweep),
              const SizedBox(height: Tk.spaceSm),
              FractionallySizedBox(
                widthFactor: 0.55,
                child: _Bone(height: 11, sweep: sweep),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 宫格方块骨。
class _CellBone extends StatelessWidget {
  const _CellBone({this.sweep});

  final Animation<double>? sweep;

  @override
  Widget build(BuildContext context) {
    return _Bone(height: double.infinity, sweep: sweep);
  }
}
