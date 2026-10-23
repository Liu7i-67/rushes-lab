/// TkColors 调色板单测(WP0):令牌逐字对齐 §4、对比度、lerp 端点。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/tk_colors.dart';

/// WCAG 2.x 相对亮度对比度(纯 Dart,不依赖渲染)。
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('§4.1 深色', () {
    const t = TkColors.dark;

    test('表面 / 前景 / 描边', () {
      expect(t.brightness, Brightness.dark);
      expect(t.bg, const Color(0xFF131210));
      expect(t.surface, const Color(0xFF1B1915));
      expect(t.surface2, const Color(0xFF201D18));
      expect(t.surface3, const Color(0xFF292520));
      expect(t.surface4, const Color(0xFF383228));
      expect(t.ink, const Color(0xFFF3EDDF));
      expect(t.ink2, const Color(0xFFC6BFB0));
      expect(t.ink3, const Color(0xFF9A9384));
      expect(t.line, const Color(0xFF2E2A23));
      expect(t.lineStrong, const Color(0xFF423B31));
      expect(t.controlBorder, const Color(0xFF70695B));
    });

    test('金色 / 语义色 / chrome', () {
      expect(t.gold, const Color(0xFFC1A063));
      expect(t.goldBright, const Color(0xFFDCC084));
      expect(t.goldInk, const Color(0xFFE4CB94));
      expect(t.goldSoft, const Color(0xFF2B2418));
      expect(t.fillInk, const Color(0xFFF0E8D6));
      expect(t.onFillInk, const Color(0xFF17150F));
      expect(t.barBg, const Color(0xFF0E0D0A));
      expect(t.barLine, const Color(0x0FFFFFFF));
      expect(t.tabFg, const Color(0xFF8D887C));
      expect(t.tabFgActive, const Color(0xFFF6F0E0));
      expect(t.chromeFg, const Color(0xFFECE5D5));
      expect(t.scrim, const Color(0x9E000000));
      expect(t.sheen, const Color(0x12FFFFFF));
      expect(t.switchKnob, const Color(0xFFD9D2C2));
      expect(t.ok, const Color(0xFF7ECBA6));
      expect(t.okSoft, const Color(0xFF16281F));
      expect(t.warn, const Color(0xFFE3B26B));
      expect(t.warnSoft, const Color(0xFF2A2317));
      expect(t.danger, const Color(0xFFEA8A82));
      expect(t.dangerSoft, const Color(0xFF2C1817));
      expect(t.dangerFill, const Color(0xFFB94C46));
      expect(t.onDanger, const Color(0xFFFFF4F1));
    });

    test('阴影 / 登录与头卡渐变', () {
      expect(t.shadow1, hasLength(2));
      expect(t.shadow1.first.offset, const Offset(0, 1));
      expect(t.shadow1.first.blurRadius, 2);
      expect(t.shadow2.single.blurRadius, 48);
      expect(t.loginBg.colors, [
        const Color(0xFF131210),
        const Color(0xFF12110D),
        const Color(0xFF0F0E0A),
      ]);
      expect(t.loginField, const Color(0xD61A1712));
      expect(t.loginBorder, const Color(0x21FFFFFF));
      expect(t.headBg.colors, [
        const Color(0xFF262117),
        const Color(0xFF1B1813),
      ]);
      expect(t.loginGlow.colors.first, const Color(0x29C9A961));
      expect(t.headGlow.colors.first, const Color(0x29C9A961));
    });
  });

  group('§4.2 浅色', () {
    const t = TkColors.light;

    test('表面 / 前景 / 描边 / 金色', () {
      expect(t.brightness, Brightness.light);
      expect(t.bg, const Color(0xFFF6F3EC));
      expect(t.surface, const Color(0xFFFFFFFF));
      expect(t.surface2, const Color(0xFFFAF7F1));
      expect(t.surface3, const Color(0xFFEFEAE1));
      expect(t.surface4, const Color(0xFFE6DFD2));
      expect(t.ink, const Color(0xFF17150F));
      expect(t.ink2, const Color(0xFF56514A));
      expect(t.ink3, const Color(0xFF6F6A5E));
      expect(t.line, const Color(0xFFE5DFD3));
      expect(t.lineStrong, const Color(0xFFD3CBBC));
      expect(t.controlBorder, const Color(0xFF918777));
      expect(t.gold, const Color(0xFFA07B39));
      expect(t.goldBright, const Color(0xFFC9A961));
      expect(t.goldInk, const Color(0xFF6F5522));
      expect(t.goldSoft, const Color(0xFFF4EBD9));
    });

    test('填充 / chrome / 语义色', () {
      expect(t.fillInk, const Color(0xFF17150F));
      expect(t.onFillInk, const Color(0xFFF7F2E6));
      expect(t.barBg, const Color(0xFFFFFFFF));
      expect(t.barLine, const Color(0x1717150F));
      expect(t.tabFg, const Color(0xFF6F6A5E));
      expect(t.tabFgActive, const Color(0xFF17150F));
      expect(t.chromeFg, const Color(0xFF17150F));
      expect(t.scrim, const Color(0x5C17150F));
      expect(t.sheen, const Color(0xCCFFFFFF));
      expect(t.switchKnob, const Color(0xFFFFFFFF));
      expect(t.ok, const Color(0xFF1D6B52));
      expect(t.okSoft, const Color(0xFFE6F0EB));
      expect(t.warn, const Color(0xFF8A5A12));
      expect(t.warnSoft, const Color(0xFFF8ECD8));
      expect(t.danger, const Color(0xFF9D2B2F));
      expect(t.dangerSoft, const Color(0xFFFBE9E8));
      expect(t.dangerFill, const Color(0xFF9D2B2F));
      expect(t.onDanger, const Color(0xFFFFF6F3));
    });

    test('阴影 / 登录与头卡渐变', () {
      expect(t.shadow1, hasLength(2));
      expect(t.shadow2.single.blurRadius, 44);
      expect(t.loginBg.colors, [
        const Color(0xFFF6F3EC),
        const Color(0xFFF2EEE4),
      ]);
      expect(t.loginField, const Color(0xFFFFFFFF));
      expect(t.loginBorder, const Color(0xFFD9D1C1));
      expect(t.headBg.colors, [
        const Color(0xFFFFFDF8),
        const Color(0xFFF5EFE1),
      ]);
      expect(t.loginGlow.colors.first, const Color(0x33C9A961));
      expect(t.headGlow.colors.first, const Color(0x42C9A961));
    });
  });

  group('对比度(WCAG)', () {
    test('深色:正文/次级/元信息/金字 ≥4.5,金色描边 ≥3', () {
      expect(
        contrast(TkColors.dark.ink, TkColors.dark.bg),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(TkColors.dark.ink2, TkColors.dark.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(TkColors.dark.ink3, TkColors.dark.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(TkColors.dark.goldInk, TkColors.dark.goldSoft),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(TkColors.dark.gold, TkColors.dark.bg),
        greaterThanOrEqualTo(3.0),
      );
    });

    test('浅色:正文/次级/元信息/金字 ≥4.5,金色描边 ≥3', () {
      expect(
        contrast(TkColors.light.ink, TkColors.light.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(TkColors.light.ink2, TkColors.light.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(TkColors.light.ink3, TkColors.light.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(TkColors.light.goldInk, TkColors.light.goldSoft),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(TkColors.light.gold, TkColors.light.bg),
        greaterThanOrEqualTo(3.0),
      );
    });

    test('危险文字两主题均 ≥4.5', () {
      expect(
        contrast(TkColors.dark.danger, TkColors.dark.dangerSoft),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(TkColors.light.danger, TkColors.light.dangerSoft),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('控件描边 controlBorder 两主题对 surface/bg 均 ≥3(P1-1)', () {
      expect(
        contrast(TkColors.dark.controlBorder, TkColors.dark.surface),
        greaterThanOrEqualTo(3.0),
      );
      expect(
        contrast(TkColors.dark.controlBorder, TkColors.dark.bg),
        greaterThanOrEqualTo(3.0),
      );
      expect(
        contrast(TkColors.light.controlBorder, TkColors.light.surface),
        greaterThanOrEqualTo(3.0),
      );
      expect(
        contrast(TkColors.light.controlBorder, TkColors.light.bg),
        greaterThanOrEqualTo(3.0),
      );
    });
  });

  test('of(brightness) 映射', () {
    expect(identical(TkColors.of(Brightness.dark), TkColors.dark), isTrue);
    expect(identical(TkColors.of(Brightness.light), TkColors.light), isTrue);
  });

  test('lerp t=0/1 返回两端', () {
    expect(TkColors.dark.lerp(TkColors.light, 0).bg, TkColors.dark.bg);
    expect(TkColors.light.lerp(TkColors.dark, 1).bg, TkColors.dark.bg);
    expect(TkColors.dark.lerp(TkColors.light, 0).brightness, Brightness.dark);
    expect(TkColors.dark.lerp(TkColors.light, 1).brightness, Brightness.light);
  });

  test('copyWith 覆盖单字段、其余保留', () {
    final t = TkColors.dark.copyWith(gold: const Color(0xFF112233));
    expect(t.gold, const Color(0xFF112233));
    expect(t.bg, TkColors.dark.bg);
    expect(t.brightness, Brightness.dark);
  });
}
