/// Haptics — 触觉反馈薄封装(app-polish A8):Flutter 内置 HapticFeedback
/// 四挡语义化别名,不引包、不持状态。供各页在关键交互点调用(方案 G2:
/// 长按多选=medium、选中切换=select、危险确认=impact、轻量点按=light),
/// UI 逻辑不感知震动结果,失败由系统吞掉(Firebase 式 best-effort)。
library;

import 'package:flutter/services.dart';

abstract final class Haptics {
  /// 轻点选(selectionClick):chip 勾选/分段切换/列表勾选等细粒度变化。
  static void select() => HapticFeedback.selectionClick();

  /// 轻触(lightImpact):普通按钮按下、轻量状态变化。
  static void light() => HapticFeedback.lightImpact();

  /// 中等(mediumImpact):长按进入多选、面板展开等有分量的操作。
  static void medium() => HapticFeedback.mediumImpact();

  /// 重击(heavyImpact):删除等危险动作确认瞬间。
  static void impact() => HapticFeedback.heavyImpact();
}
