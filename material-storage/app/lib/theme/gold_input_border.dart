/// GoldGlowInputBorder — 聚焦态金色输入边框:金色 1.5px 描边 + 3px 柔光外圈。
///
/// 用 `OutlineInputBorder` 子类而非叠加 Widget:输入框聚焦时仍走原生
/// InputDecorator 的 label gap 动画,光晕只是同一路径的第二次描边。
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

class GoldGlowInputBorder extends OutlineInputBorder {
  const GoldGlowInputBorder({
    required this.glowColor,
    required this.strokeColor,
    this.strokeWidth = 1.5,
    super.borderRadius = const BorderRadius.all(Radius.circular(Tk.rSm)),
    super.gapPadding = 4.0,
  });

  /// 外圈柔光色(通常为 gold/danger 的 14% 透明度)。
  final Color glowColor;

  /// 主描边色。
  final Color strokeColor;
  final double strokeWidth;

  /// 主描边由 strokeColor/strokeWidth 推导;super.paint/dimensions 均走
  /// 该 getter,保证 label gap 与最小尺寸正确。
  @override
  BorderSide get borderSide =>
      BorderSide(color: strokeColor, width: strokeWidth);

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    // 先画 3px 外圈:路径取 rect 外扩 1.5,笔宽 3 → 光晕覆盖边框外 0~3px。
    final glow = Paint()
      ..color = glowColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    canvas.drawRRect(borderRadius.toRRect(rect.inflate(1.5)), glow);
    super.paint(
      canvas,
      rect,
      gapStart: gapStart,
      gapExtent: gapExtent,
      gapPercentage: gapPercentage,
      textDirection: textDirection,
    );
  }

  @override
  GoldGlowInputBorder copyWith({
    BorderSide? borderSide,
    BorderRadius? borderRadius,
    double? gapPadding,
  }) => GoldGlowInputBorder(
    glowColor: glowColor,
    strokeColor: borderSide?.color ?? strokeColor,
    strokeWidth: borderSide?.width ?? strokeWidth,
    borderRadius: borderRadius ?? this.borderRadius,
    gapPadding: gapPadding ?? this.gapPadding,
  );

  @override
  GoldGlowInputBorder scale(double t) => GoldGlowInputBorder(
    glowColor: glowColor,
    strokeColor: strokeColor,
    strokeWidth: strokeWidth * t,
    borderRadius: borderRadius * t,
    gapPadding: gapPadding * t,
  );

  @override
  bool operator ==(Object other) =>
      other is GoldGlowInputBorder &&
      other.glowColor == glowColor &&
      other.strokeColor == strokeColor &&
      other.strokeWidth == strokeWidth &&
      other.borderSide == borderSide &&
      other.borderRadius == borderRadius &&
      other.gapPadding == gapPadding;

  @override
  int get hashCode => Object.hash(
    glowColor,
    strokeColor,
    strokeWidth,
    borderSide,
    borderRadius,
    gapPadding,
  );
}
