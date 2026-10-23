/// ThemeController 单测(WP0):三态 mode、notify、持久化/恢复、文案。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/theme_controller.dart';
import 'package:ms_app/theme/theme_store.dart';

ThemeStore storeWith({String? initial, List<String>? writes}) =>
    ThemeStore(read: () async => initial, write: (v) => writes?.add(v));

void main() {
  test('默认 system,三态文案', () {
    final c = ThemeController(store: storeWith());
    expect(c.pref, ThemePref.system);
    expect(c.mode, ThemeMode.system);
    expect(c.labelFor(Brightness.dark), '跟随系统 · 深色');
    expect(c.labelFor(Brightness.light), '跟随系统 · 浅色');
  });

  test('setPref 立即更新 mode + notify + 异步持久化', () async {
    final writes = <String>[];
    final c = ThemeController(store: storeWith(writes: writes));
    var notified = 0;
    c.addListener(() => notified++);

    await c.setPref(ThemePref.dark);
    expect(c.pref, ThemePref.dark);
    expect(c.mode, ThemeMode.dark);
    expect(c.labelFor(Brightness.light), '深色');
    expect(notified, 1);
    expect(writes, ['dark']);

    await c.setPref(ThemePref.light);
    expect(c.mode, ThemeMode.light);
    expect(c.labelFor(Brightness.dark), '浅色');
    expect(notified, 2);
    expect(writes, ['dark', 'light']);

    await c.setPref(ThemePref.system);
    expect(c.mode, ThemeMode.system);
    expect(writes, ['dark', 'light', 'system']);
  });

  test('新 controller load 恢复上次选择并 notify', () async {
    final writes = <String>[];
    await ThemeController(store: storeWith(writes: writes))
        .setPref(ThemePref.dark);
    expect(writes.single, 'dark');

    final restored = ThemeController(
      store: ThemeStore(read: () async => writes.single),
    );
    var notified = 0;
    restored.addListener(() => notified++);
    await restored.load();
    expect(restored.pref, ThemePref.dark);
    expect(restored.mode, ThemeMode.dark);
    expect(notified, 1);
  });

  test('非法持久化值回落 system', () async {
    final c = ThemeController(store: ThemeStore(read: () async => 'bogus'));
    await c.load();
    expect(c.pref, ThemePref.system);
  });

  test('load 读异常/空值保持 system 且不 notify', () async {
    final broken = ThemeController(
      store: ThemeStore(read: () async => throw StateError('io')),
    );
    var notified = 0;
    broken.addListener(() => notified++);
    await broken.load();
    expect(broken.pref, ThemePref.system);
    expect(notified, 0);
  });

  test('load 值未变化不 notify', () async {
    final c = ThemeController(store: ThemeStore(read: () async => 'system'));
    var notified = 0;
    c.addListener(() => notified++);
    await c.load();
    expect(notified, 0);
  });

  test('写盘失败不抛且不影响切换', () async {
    final c = ThemeController(
      store: ThemeStore(write: (_) async => throw StateError('io')),
    );
    await c.setPref(ThemePref.dark);
    expect(c.pref, ThemePref.dark);
    expect(c.mode, ThemeMode.dark);
  });
}
