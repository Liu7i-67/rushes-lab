/// Tk — 视觉令牌全集(方案 §10,对齐 web/src/styles/tokens.css;
/// dark 系出处=Open Design 设计稿,web tokens.css 无此值)。
/// 只放常量;主题组装见同目录 app_theme.dart。
///
/// ── 迁移映射表(app-polish A 包;全库唯一,后续包照此执行)──
///
/// 字号(A1,6 档;全库 279 处 14 档 10~17 收敛,半档归整、层级不倒置):
/// ```
/// 9.5 / 10 / 10.5 / 11 / 11.5 → fzXs   = 11  注脚·元信息·徽标(≥11 下限)
/// 12 / 12.5                   → fzSm   = 12  次级说明·按钮小字
/// 13 / 13.5                   → fzMd   = 13  密排正文·列表副标题
/// 14 / 14.5                   → fzBody = 14  默认正文·表单
/// 15 / 16                     → fzTitle= 15  行标题·卡片/弹窗标题
/// 17                          → fzLg   = 17  页首大标题
/// ```
///
/// 间距(A2,4/8/12/16/24 五档):
/// ```
/// 4→spaceXs  8→spaceSm  12→spaceMd  16→spaceLg  24→spaceXl
/// 非档值就近归档:6→spaceSm;<4 的 2/3 属视觉微缝保留原值;
/// 参与尺寸计算的(如加载圈 suffix padding 10)保留并注释。
/// ```
///
/// 圆角(A3,4 档 + 胶囊;11 档收敛):
/// ```
/// ≤8(2/3/4/6/8)→ rSm = 8    缩略图·小容器(2/3 极小缝可视情保留并注释)
/// 10 / 12 / 14   → rMd = 12  小卡·输入框
/// 16             → rLg = 16  列表卡
/// ≥18(18/20)   → rXl = 20  大卡(主题 Card 档)
/// 999(胶囊)    → rPill = 999  Badge 等全圆角
/// ```
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

  // ── 字号(A1;映射见文件头)──
  static const double fzXs = 11;
  static const double fzSm = 12;
  static const double fzMd = 13;
  static const double fzBody = 14;
  static const double fzTitle = 15;
  static const double fzLg = 17;

  // ── 间距(A2;映射见文件头)──
  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 12;
  static const double spaceLg = 16;
  static const double spaceXl = 24;

  // ── 圆角(A3;映射见文件头)──
  static const double rSm = 8;
  static const double rMd = 12;
  static const double rLg = 16;
  static const double rXl = 20;
  static const double rPill = 999;
}
