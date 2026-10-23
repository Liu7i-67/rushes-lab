/// TkColors — 双主题颜色令牌(ThemeExtension,唯一颜色事实源);数值逐字对齐
/// docs/qdev/2026-10-23-app-ink-gold-ui.md §4.1/§4.2;固定暗色见 Tk.preview*。
///
/// 无障碍加值:`controlBorder` 是后加的「可交互控件描边」令牌(输入框/
/// OutlinedButton/未选中 chip/可读性徽标边),对 surface/bg 均 ≥3:1;设计
/// 原始 `lineStrong` 仅保留给装饰性发丝线(分隔线/拖拽把手),不承担可交互
/// 描边职责。
library;

import 'package:flutter/material.dart';

part 'tk_colors_dark.dart';
part 'tk_colors_light.dart';

@immutable
class TkColors extends ThemeExtension<TkColors> {
  // dart format off
  const TkColors({
    required this.brightness,
    required this.bg, required this.surface, required this.surface2,
    required this.surface3, required this.surface4,
    required this.ink, required this.ink2, required this.ink3,
    required this.line, required this.lineStrong, required this.controlBorder,
    required this.gold, required this.goldBright, required this.goldInk,
    required this.goldSoft, required this.fillInk, required this.onFillInk,
    required this.barBg, required this.barLine,
    required this.tabFg, required this.tabFgActive, required this.chromeFg,
    required this.scrim, required this.sheen, required this.switchKnob,
    required this.ok, required this.okSoft, required this.warn,
    required this.warnSoft, required this.danger, required this.dangerSoft,
    required this.dangerFill, required this.onDanger,
    required this.shadow1, required this.shadow2,
    required this.loginBg, required this.loginGlow,
    required this.loginField, required this.loginBorder,
    required this.headBg, required this.headGlow,
  });
  // dart format on

  final Brightness brightness;
  final Color bg, surface, surface2, surface3, surface4;
  final Color ink, ink2, ink3;
  final Color line, lineStrong;

  /// 可交互控件描边(输入框 / OutlinedButton / 未选中 chip):两主题对
  /// surface 与 bg 均 ≥3:1。不是设计原始 `lineStrong`(后者只做装饰性
  /// 发丝线,约 1.6:1,不可用于图标/控件边界)。
  final Color controlBorder;
  final Color gold, goldBright, goldInk, goldSoft;
  final Color fillInk, onFillInk;
  final Color barBg, barLine;
  final Color tabFg, tabFgActive, chromeFg;
  final Color scrim, sheen, switchKnob;
  final Color ok, okSoft, warn, warnSoft, danger, dangerSoft;
  final Color dangerFill, onDanger;
  final List<BoxShadow> shadow1, shadow2;
  final LinearGradient loginBg;
  final RadialGradient loginGlow;
  final Color loginField, loginBorder;
  final LinearGradient headBg;
  final RadialGradient headGlow;

  static const TkColors dark = _darkPalette;

  static const TkColors light = _lightPalette;

  static TkColors of(Brightness b) => b == Brightness.dark ? dark : light;

  // dart format off
  @override
  TkColors copyWith({
    Brightness? brightness,
    Color? bg, Color? surface, Color? surface2, Color? surface3,
    Color? surface4, Color? ink, Color? ink2, Color? ink3,
    Color? line, Color? lineStrong, Color? controlBorder,
    Color? gold, Color? goldBright,
    Color? goldInk, Color? goldSoft, Color? fillInk, Color? onFillInk,
    Color? barBg, Color? barLine, Color? tabFg, Color? tabFgActive,
    Color? chromeFg, Color? scrim, Color? sheen, Color? switchKnob,
    Color? ok, Color? okSoft, Color? warn, Color? warnSoft,
    Color? danger, Color? dangerSoft, Color? dangerFill, Color? onDanger,
    List<BoxShadow>? shadow1, List<BoxShadow>? shadow2,
    LinearGradient? loginBg, RadialGradient? loginGlow,
    Color? loginField, Color? loginBorder,
    LinearGradient? headBg, RadialGradient? headGlow,
  }) =>
      TkColors(
        brightness: brightness ?? this.brightness,
        bg: bg ?? this.bg, surface: surface ?? this.surface,
        surface2: surface2 ?? this.surface2,
        surface3: surface3 ?? this.surface3,
        surface4: surface4 ?? this.surface4,
        ink: ink ?? this.ink, ink2: ink2 ?? this.ink2,
        ink3: ink3 ?? this.ink3,
        line: line ?? this.line, lineStrong: lineStrong ?? this.lineStrong,
        controlBorder: controlBorder ?? this.controlBorder,
        gold: gold ?? this.gold, goldBright: goldBright ?? this.goldBright,
        goldInk: goldInk ?? this.goldInk, goldSoft: goldSoft ?? this.goldSoft,
        fillInk: fillInk ?? this.fillInk,
        onFillInk: onFillInk ?? this.onFillInk,
        barBg: barBg ?? this.barBg, barLine: barLine ?? this.barLine,
        tabFg: tabFg ?? this.tabFg,
        tabFgActive: tabFgActive ?? this.tabFgActive,
        chromeFg: chromeFg ?? this.chromeFg,
        scrim: scrim ?? this.scrim, sheen: sheen ?? this.sheen,
        switchKnob: switchKnob ?? this.switchKnob,
        ok: ok ?? this.ok, okSoft: okSoft ?? this.okSoft,
        warn: warn ?? this.warn, warnSoft: warnSoft ?? this.warnSoft,
        danger: danger ?? this.danger,
        dangerSoft: dangerSoft ?? this.dangerSoft,
        dangerFill: dangerFill ?? this.dangerFill,
        onDanger: onDanger ?? this.onDanger,
        shadow1: shadow1 ?? this.shadow1,
        shadow2: shadow2 ?? this.shadow2,
        loginBg: loginBg ?? this.loginBg,
        loginGlow: loginGlow ?? this.loginGlow,
        loginField: loginField ?? this.loginField,
        loginBorder: loginBorder ?? this.loginBorder,
        headBg: headBg ?? this.headBg, headGlow: headGlow ?? this.headGlow,
      );

  @override
  TkColors lerp(ThemeExtension<TkColors>? other, double t) {
    if (other is! TkColors) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return TkColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      bg: c(bg, other.bg), surface: c(surface, other.surface),
      surface2: c(surface2, other.surface2),
      surface3: c(surface3, other.surface3),
      surface4: c(surface4, other.surface4),
      ink: c(ink, other.ink), ink2: c(ink2, other.ink2),
      ink3: c(ink3, other.ink3),
      line: c(line, other.line), lineStrong: c(lineStrong, other.lineStrong),
      controlBorder: c(controlBorder, other.controlBorder),
      gold: c(gold, other.gold), goldBright: c(goldBright, other.goldBright),
      goldInk: c(goldInk, other.goldInk),
      goldSoft: c(goldSoft, other.goldSoft),
      fillInk: c(fillInk, other.fillInk),
      onFillInk: c(onFillInk, other.onFillInk),
      barBg: c(barBg, other.barBg), barLine: c(barLine, other.barLine),
      tabFg: c(tabFg, other.tabFg),
      tabFgActive: c(tabFgActive, other.tabFgActive),
      chromeFg: c(chromeFg, other.chromeFg),
      scrim: c(scrim, other.scrim), sheen: c(sheen, other.sheen),
      switchKnob: c(switchKnob, other.switchKnob),
      ok: c(ok, other.ok), okSoft: c(okSoft, other.okSoft),
      warn: c(warn, other.warn), warnSoft: c(warnSoft, other.warnSoft),
      danger: c(danger, other.danger),
      dangerSoft: c(dangerSoft, other.dangerSoft),
      dangerFill: c(dangerFill, other.dangerFill),
      onDanger: c(onDanger, other.onDanger),
      shadow1: BoxShadow.lerpList(shadow1, other.shadow1, t)!,
      shadow2: BoxShadow.lerpList(shadow2, other.shadow2, t)!,
      loginBg: LinearGradient.lerp(loginBg, other.loginBg, t)!,
      loginGlow: RadialGradient.lerp(loginGlow, other.loginGlow, t)!,
      loginField: c(loginField, other.loginField),
      loginBorder: c(loginBorder, other.loginBorder),
      headBg: LinearGradient.lerp(headBg, other.headBg, t)!,
      headGlow: RadialGradient.lerp(headGlow, other.headGlow, t)!,
    );
  }
  // dart format on
}
