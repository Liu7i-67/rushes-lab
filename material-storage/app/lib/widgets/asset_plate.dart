/// AssetPlate — 素材打样卡(§6 F3):双径向暖色渐变 + 线性底 + 1px 金弧
/// (弧端点星形)+ 右下三位编号;无缩略图时替代灰块,真实缩略图/图标用
/// [child] 覆盖在渐变之上。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tk_colors.dart';
import '../theme/tokens.dart';

class AssetPlate extends StatelessWidget {
  const AssetPlate({
    super.key,
    this.seed = 0,
    this.child,
    this.borderRadius,
    this.showNumber = true,
  });

  final int seed;
  final Widget? child;
  final BorderRadius? borderRadius;
  final bool showNumber;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(Tk.rMd),
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: CustomPaint(
              painter: _PlatePainter(seed: seed, brightness: tk.brightness),
              child: const SizedBox.expand(),
            ),
          ),
          if (showNumber)
            Positioned(
              right: 8,
              bottom: 5,
              child: Text(
                '${seed + 1}'.padLeft(3, '0'),
                style: TextStyle(
                  fontSize: 10.5,
                  letterSpacing: 1.26,
                  color: Tk.previewFg.withValues(alpha: 0.6),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          if (child != null) Positioned.fill(child: child!),
        ],
      ),
    );
  }
}

/// 纯绘制:种子只影响暖色板选择;两主题共用同一组介质色,
/// 底部加一层暗角保证 ivory 编号在浅色介质上仍可读。
class _PlatePainter extends CustomPainter {
  const _PlatePainter({required this.seed, required this.brightness});

  final int seed;
  final Brightness brightness;

  /// 5 组暖色打样 palette([p1, p2, p3, p4])。
  static const List<List<Color>> _palettes = [
    [
      Color(0xFFC79E88),
      Color(0xFFECDCCD),
      Color(0xFF8D6350),
      Color(0xFFCFA992),
    ],
    [
      Color(0xFFC79A9D),
      Color(0xFFEDDBD7),
      Color(0xFF8F5F63),
      Color(0xFFCFA8A6),
    ],
    [
      Color(0xFFCBB383),
      Color(0xFFEFE3C9),
      Color(0xFF8A7345),
      Color(0xFFD6C19A),
    ],
    [
      Color(0xFFB58E6B),
      Color(0xFFE5D2BA),
      Color(0xFF6F5138),
      Color(0xFFBD9B78),
    ],
    [
      Color(0xFFB39AA5),
      Color(0xFFE4D8DE),
      Color(0xFF6F5563),
      Color(0xFFBBA6B0),
    ],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final p = _palettes[seed % _palettes.length];

    // 线性底。
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment(-0.4, -1),
          end: Alignment(0.4, 1),
          colors: [p[2], p[3]],
        ).createShader(rect),
    );
    // 左上暖光。
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.68, -0.8),
          radius: 1.15,
          colors: [p[0], p[0].withValues(alpha: 0)],
          stops: const [0, 0.62],
        ).createShader(rect),
    );
    // 右下纸感高光。
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0.68, 0.84),
          radius: 1.05,
          colors: [p[1], p[1].withValues(alpha: 0)],
          stops: const [0, 0.58],
        ).createShader(rect),
    );
    // 底部暗角:编号可读性(两主题一致)。
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0x6B000000), Color(0x00000000)],
          stops: [0, 0.34],
        ).createShader(rect),
    );

    // 1px 金弧 + 弧端星形(100×100 设计坐标,等比居中缩放)。
    final scale = size.shortestSide / 100;
    final transform = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setTranslationRaw(
        (size.width - 100 * scale) / 2,
        (size.height - 100 * scale) / 2,
        0,
      );
    final matrix = transform.storage;
    final gold = TkColors.of(brightness).goldBright;
    final arc = Path()
      ..moveTo(76, 14)
      ..arcToPoint(
        const Offset(84, 74),
        radius: const Radius.circular(42),
        largeArc: true,
        clockwise: false,
      );
    arc.transform(matrix);
    canvas.drawPath(
      arc,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = gold.withValues(alpha: 0.55),
    );
    final star = Path()
      ..moveTo(76, 14)
      ..lineTo(77.5, 17.2)
      ..lineTo(81, 18.7)
      ..lineTo(77.5, 20.2)
      ..lineTo(76, 23.4)
      ..lineTo(74.5, 20.2)
      ..lineTo(71, 18.7)
      ..lineTo(74.5, 17.2)
      ..close();
    star.transform(matrix);
    canvas.drawPath(star, Paint()..color = gold.withValues(alpha: 0.68));
  }

  @override
  bool shouldRepaint(covariant _PlatePainter oldDelegate) =>
      oldDelegate.seed != seed || oldDelegate.brightness != brightness;
}
