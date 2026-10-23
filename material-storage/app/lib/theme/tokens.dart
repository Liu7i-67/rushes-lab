/// Tk — 非颜色视觉令牌(唯一长期事实源)。
///
/// 新设计(2026-10 墨色 + 金色双主题,见 docs/qdev/2026-10-23-app-ink-gold-ui.md §4):
/// - 字号/间距/圆角只在 [Tk] 定义;颜色的唯一入口是 `context.tk`(TkColors)。
/// - 预览画布等固定暗色区域两种主题下都不变,用本文件的 preview* 静态常量。
/// - 并行迁移期的旧颜色别名已在 WP12 收尾时整段删除,不得再引用。
library;

import 'package:flutter/material.dart';

abstract final class Tk {
  // ── 字号(§4.4;正文 16、元信息 13、微标签 11 为下限)──
  static const double fzDisplay = 27; // 一级页大标题
  static const double fzSection = 20; // 区块标题 / 弹层标题
  static const double fzTitle = 17; // 二级页标题
  static const double fzRowTitle = 15.5; // 列表标题
  static const double fzBody = 16; // 正文 / 表单
  static const double fzMd = 13; // 元信息
  static const double fzSm = 12; // 紧凑标签(页签/徽标)
  static const double fzXs = 11; // 微标签
  static const double fzStat = 22; // 概览数字

  // 存量代码兼容别名(字号档位收敛后的旧名)。
  static const double fzLg = fzSection; // = 20
  static const double fzMicro = fzXs; // = 11
  static const double fzMeta = fzMd; // = 13

  // ── 间距(§4.4;页面左右留白 20)──
  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 12;
  static const double spaceLg = 16;
  static const double spaceXl = 24;
  static const double space2xl = 32;
  static const double spacePage = 20;

  // ── 圆角(§4.4)──
  static const double rXs = 6; // 小徽标
  static const double rSm = 10; // 输入、按钮
  static const double rMd = 14; // 卡片
  static const double rLg = 18; // 媒体块
  static const double rXl = 24; // 弹层顶部
  static const double rPill = 999;

  // ── 预览固定暗色(§4.3;两种主题下都不变)──
  static const Color previewBg = Color(0xFF0F0E0A);
  static const Color previewSurface = Color(0xFF1A1813);
  static const Color previewFg = Color(0xFFF7F1E2);
  static const Color previewFg2 = Color(0xFFA49D8C);
  static const Color previewLine = Color(0x17FFFFFF);
  static const Color previewGold = Color(0xFFDCC084);
  static const Color videoCanvas = Color(0xFF000000);
  static const Color dangerOnDark = Color(0xFFEF8B86);
}
