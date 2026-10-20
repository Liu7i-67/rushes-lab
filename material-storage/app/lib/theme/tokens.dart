/// Tk — 视觉令牌全集(方案 §10,对齐 web/src/styles/tokens.css;
/// dark 系出处=Open Design 设计稿,web tokens.css 无此值)。
/// 只放常量;主题组装见同目录 app_theme.dart。
library;

import 'package:flutter/material.dart';

abstract final class Tk {
  // ── 中性面 ──
  static const bg = Color(0xFFFAFAF7);
  static const surface = Color(0xFFFFFFFF);
  static const surface2 = Color(0xFFF5F3EE);
  static const fill = Color(0xFFF0EEE9);
  static const border = Color(0xFFE8E6E1);

  // ── 前景 ──
  static const fg = Color(0xFF1A1A1A);
  static const muted = Color(0xFF6B6B68);
  static const subtle = Color(0xFF9A9A95);

  // ── 强调(accent 及其梯度)──
  static const accent = Color(0xFFC2410C);
  static const accentStrong = Color(0xFF9A3412);
  static const accentSoft = Color(0xFFFEE4D0);
  static const accentFaint = Color(0xFFFEF3E8);

  // ── 语义色(徽标 pill 四色:accent/green/neutral/amber)──
  static const green = Color(0xFF047857);
  static const amber = Color(0xFFB45309);
  static const red = Color(0xFF9F1239);
  static const neutral = muted;

  // ── 暗色(预览画布,B4 预览批使用)──
  static const dark = Color(0xFF141210);
  static const darkSurface = Color(0xFF1A1A18);
  static const videoCanvas = Color(0xFF000000);
}
