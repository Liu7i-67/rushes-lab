/// buildAppTheme — 明/暗双主题 ThemeData 组装(§5.2)。
///
/// 颜色全部来自 [TkColors](ThemeExtension,`context.tk` 单入口);
/// 组件结构/字号/间距/圆角两主题共用同一套令牌,仅取值不同。
/// `buildAppTheme()` 不带参时按浅色(兼容旧调用点)。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_typography.dart';
import 'gold_input_border.dart';
import 'tk_colors.dart';
import 'tokens.dart';

/// 金色主按钮上的深墨字(两主题一致,§5.2)。
const Color _onGold = Color(0xFF1A1509);

ThemeData buildAppTheme([Brightness brightness = Brightness.light]) {
  final tk = TkColors.of(brightness);
  final scheme = _scheme(tk);
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: tk.bg,
  );
  final text = applyTkType(base.textTheme)
      .apply(bodyColor: tk.ink, displayColor: tk.ink);
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(Tk.rSm),
    // 可交互描边用 controlBorder(≥3:1);lineStrong 仅装饰性发丝线。
    borderSide: BorderSide(color: tk.controlBorder),
  );
  return base.copyWith(
    extensions: [tk],
    textTheme: text,
    appBarTheme: _appBar(tk),
    cardTheme: CardThemeData(
      color: tk.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tk.rMd),
        side: BorderSide(color: tk.line),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: tk.bg,
      isDense: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      hintStyle: TextStyle(fontSize: Tk.fzBody, color: tk.ink3),
      labelStyle: TextStyle(fontSize: Tk.fzBody, color: tk.ink2),
      floatingLabelStyle: TextStyle(fontSize: Tk.fzMd, color: tk.goldInk),
      errorStyle: TextStyle(fontSize: Tk.fzMd, color: tk.danger),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: GoldGlowInputBorder(
        glowColor: tk.gold.withValues(alpha: 0.14),
        strokeColor: tk.gold,
      ),
      errorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: tk.danger),
      ),
      focusedErrorBorder: GoldGlowInputBorder(
        glowColor: tk.danger.withValues(alpha: 0.14),
        strokeColor: tk.danger,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: tk.gold,
        foregroundColor: _onGold,
        disabledBackgroundColor: tk.gold.withValues(alpha: 0.45),
        disabledForegroundColor: _onGold.withValues(alpha: 0.45),
        minimumSize: const Size(44, 48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Tk.rSm),
        ),
        textStyle: const TextStyle(
          fontSize: Tk.fzRowTitle,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: tk.ink,
        backgroundColor: Colors.transparent,
        minimumSize: const Size(44, 48),
        side: BorderSide(color: tk.controlBorder),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Tk.rSm),
        ),
        textStyle: const TextStyle(
          fontSize: Tk.fzRowTitle,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: tk.goldInk,
        minimumSize: const Size(44, 44),
        textStyle: const TextStyle(
          fontSize: Tk.fzRowTitle,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: tk.ink,
        iconSize: 22,
        minimumSize: const Size(44, 44),
      ),
    ),
    dividerTheme: DividerThemeData(color: tk.line, space: 1, thickness: 1),
    listTileTheme: ListTileThemeData(
      iconColor: tk.ink2,
      textColor: tk.ink,
      titleTextStyle: TextStyle(
        fontSize: Tk.fzRowTitle,
        fontWeight: FontWeight.w500,
        color: tk.ink,
      ),
      subtitleTextStyle: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
      contentPadding: const EdgeInsets.symmetric(horizontal: Tk.spaceLg),
      minVerticalPadding: Tk.spaceMd,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: tk.surface,
      modalBackgroundColor: tk.surface,
      modalBarrierColor: tk.scrim,
      elevation: 0,
      modalElevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Tk.rXl)),
      ),
      dragHandleColor: tk.lineStrong,
      dragHandleSize: const Size(38, 4),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: tk.surface,
      elevation: 0,
      barrierColor: tk.scrim,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tk.rXl),
      ),
      titleTextStyle: TextStyle(
        fontSize: Tk.fzSection,
        fontWeight: FontWeight.w600,
        color: tk.ink,
      ),
      contentTextStyle: TextStyle(
        fontSize: Tk.fzBody,
        height: 1.5,
        color: tk.ink2,
      ),
    ),
    chipTheme: _chip(tk),
    navigationBarTheme: _navBar(tk),
    snackBarTheme: SnackBarThemeData(
      // toast 自定义(固定暗色);此处只做 Material 默认 SnackBar 兜底。
      backgroundColor: TkColors.dark.surface,
      contentTextStyle: TextStyle(fontSize: Tk.fzMd, color: TkColors.dark.ink),
      actionTextColor: TkColors.dark.goldBright,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tk.rSm),
      ),
    ),
  );
}

ColorScheme _scheme(TkColors tk) => ColorScheme(
  brightness: tk.brightness,
  primary: tk.gold,
  onPrimary: _onGold,
  primaryContainer: tk.goldSoft,
  onPrimaryContainer: tk.goldInk,
  secondary: tk.gold,
  onSecondary: _onGold,
  secondaryContainer: tk.goldSoft,
  onSecondaryContainer: tk.goldInk,
  error: tk.danger,
  onError: tk.onDanger,
  errorContainer: tk.dangerSoft,
  onErrorContainer: tk.danger,
  surface: tk.surface,
  onSurface: tk.ink,
  surfaceContainerHigh: tk.surface2,
  surfaceContainerLow: tk.surface2,
  surfaceContainerHighest: tk.surface3,
  outline: tk.line,
  outlineVariant: tk.line,
  surfaceTint: Colors.transparent,
  inverseSurface: tk.fillInk,
  onInverseSurface: tk.onFillInk,
  scrim: tk.scrim,
);

AppBarThemeData _appBar(TkColors tk) => AppBarThemeData(
  backgroundColor: tk.bg,
  foregroundColor: tk.ink,
  elevation: 0,
  scrolledUnderElevation: 0,
  centerTitle: false,
  toolbarHeight: 60,
  titleTextStyle: TextStyle(
    fontSize: Tk.fzTitle,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: tk.ink,
  ),
  iconTheme: IconThemeData(color: tk.ink, size: 22),
  actionsIconTheme: IconThemeData(color: tk.ink, size: 22),
  shape: Border(bottom: BorderSide(color: tk.line)),
  systemOverlayStyle: _overlay(tk.brightness),
);

SystemUiOverlayStyle _overlay(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    // iOS 语义相反:浅色背景配深色图标。
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
  );
}

ChipThemeData _chip(TkColors tk) => ChipThemeData(
  backgroundColor: tk.surface2,
  selectedColor: tk.goldSoft,
  disabledColor: tk.surface3,
  // 未选中 chip 是可交互控件:描边用 controlBorder(≥3:1),lineStrong 仅装饰。
  side: BorderSide(color: tk.controlBorder),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Tk.rPill)),
  // 高度 44 近似:13*1.5 + 12*2 ≈ 43.5(无 height 字段)。
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  labelStyle: TextStyle(
    fontSize: Tk.fzMd,
    height: 1.5,
    fontWeight: FontWeight.w500,
    color: tk.ink2,
  ),
  secondaryLabelStyle: TextStyle(
    fontSize: Tk.fzMd,
    height: 1.5,
    fontWeight: FontWeight.w600,
    color: tk.goldInk,
  ),
  iconTheme: IconThemeData(color: tk.ink2, size: 18),
  checkmarkColor: tk.goldInk,
  showCheckmark: true,
  brightness: tk.brightness,
);

NavigationBarThemeData _navBar(TkColors tk) => NavigationBarThemeData(
  backgroundColor: tk.barBg,
  elevation: 0,
  height: 64,
  surfaceTintColor: Colors.transparent,
  indicatorColor: tk.goldSoft,
  iconTheme: WidgetStateProperty.resolveWith(
    (states) => IconThemeData(
      color: states.contains(WidgetState.selected) ? tk.goldInk : tk.tabFg,
      size: 24,
    ),
  ),
  labelTextStyle: WidgetStateProperty.resolveWith(
    (states) => TextStyle(
      fontSize: Tk.fzSm,
      fontWeight: states.contains(WidgetState.selected)
          ? FontWeight.w600
          : FontWeight.w500,
      color: states.contains(WidgetState.selected) ? tk.tabFgActive : tk.tabFg,
    ),
  ),
);
