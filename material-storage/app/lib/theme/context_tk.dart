/// BuildContext.tk — 主题颜色令牌的单入口。
///
/// 兜底必须存在:既有 widget 单测常裸挂 MaterialApp(默认主题没有
/// TkColors extension),此时按当前 brightness 取静态调色板,不得崩溃。
library;

import 'package:flutter/material.dart';

import 'tk_colors.dart';

extension TkContext on BuildContext {
  TkColors get tk =>
      Theme.of(this).extension<TkColors>() ??
      TkColors.of(Theme.of(this).brightness);
}
