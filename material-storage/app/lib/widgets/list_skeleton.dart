/// ListSkeleton — 列表/宫格加载骨架(app-polish A9,方案 §A9):替代主要
/// 页面首载的居中裸转圈。两形态:columns=1 列表行(圆头像+双行条),
/// columns≥2 宫格方块。呼吸式闪烁用 FadeTransition(不引 shimmer 包)。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class ListSkeleton extends StatefulWidget {
  const ListSkeleton({
    super.key,
    this.rows = 6,
    this.columns = 1,
    this.padding = const EdgeInsets.all(Tk.spaceLg),
  });

  /// 行数(列表模式=行条数;宫格模式=总格子数,取 rows×columns 语义为
  /// 宫格行数×列数更直观:宫格格子数 = rows * columns)。
  final int rows;

  /// 列数;1=列表形态,≥2=宫格形态(每行 columns 个方块)。
  final int columns;

  final EdgeInsetsGeometry padding;

  @override
  State<ListSkeleton> createState() => _ListSkeletonState();
}

class _ListSkeletonState extends State<ListSkeleton>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = Tween(begin: 0.45, end: 1.0).animate(
      CurvedAnimation(parent: _c, curve: Curves.easeInOut),
    );
    return Padding(
      padding: widget.padding,
      child: FadeTransition(
        opacity: fade,
        child: widget.columns <= 1
            ? Column(
                children: [
                  for (var i = 0; i < widget.rows; i++) ...[
                    if (i > 0) const SizedBox(height: Tk.spaceMd),
                    const _RowBone(),
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
                    const _CellBone(),
                ],
              ),
      ),
    );
  }
}

/// 骨架块基件:圆角填充块(Fill 色),统一 key 供测试定位。
class _Bone extends StatelessWidget {
  const _Bone({
    this.width,
    required this.height,
    this.round = false,
  });

  final double? width;
  final double height;
  final bool round;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Tk.fill,
        borderRadius:
            BorderRadius.circular(round ? 999 : Tk.rSm),
      ),
    );
  }
}

/// 列表行骨:圆头像 + 双行条(内容加载期的形状暗示)。
class _RowBone extends StatelessWidget {
  const _RowBone();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const _Bone(width: 40, height: 40, round: true),
        const SizedBox(width: Tk.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              _Bone(height: 13),
              SizedBox(height: Tk.spaceSm),
              FractionallySizedBox(
                widthFactor: 0.55,
                child: _Bone(height: 11),
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
  const _CellBone();

  @override
  Widget build(BuildContext context) {
    return const _Bone(height: double.infinity);
  }
}
