/// ThemeController — 外观偏好三态(跟随系统/深色/浅色)与持久化。
///
/// - 默认 [ThemePref.system];[load] 读盘失败/非法值保持 system。
/// - [setPref] 同步改值并 notify(立即预览),随后异步落盘(失败静默)。
/// - [themeController] 为全局单例;单测可 `ThemeController(store: ...)` 注入。
library;

import 'package:flutter/material.dart';

import 'theme_store.dart';

enum ThemePref { system, dark, light }

class ThemeController extends ChangeNotifier {
  factory ThemeController({ThemeStore? store}) => ThemeController._(store);

  ThemeController._(this._store);

  ThemeStore? _store;
  ThemePref _pref = ThemePref.system;

  ThemePref get pref => _pref;

  ThemeMode get mode => switch (_pref) {
    ThemePref.system => ThemeMode.system,
    ThemePref.dark => ThemeMode.dark,
    ThemePref.light => ThemeMode.light,
  };

  /// 外观行/设置面板的当前模式文案(跟随系统带当前系统明暗)。
  String labelFor(Brightness systemBrightness) => switch (_pref) {
    ThemePref.system =>
      '跟随系统 · ${systemBrightness == Brightness.dark ? '深色' : '浅色'}',
    ThemePref.dark => '深色',
    ThemePref.light => '浅色',
  };

  /// 启动读盘;失败/非法值/无存储时保持 system。
  Future<void> load() async {
    _store ??= await ThemeStore.openDefault();
    final raw = await _store?.read();
    final next = _parse(raw);
    if (next == _pref) return;
    _pref = next;
    notifyListeners();
  }

  /// 立即生效 + notify;写盘异步(await 前已完成 UI 通知)。失败静默。
  Future<void> setPref(ThemePref pref) async {
    _pref = pref;
    notifyListeners();
    _store ??= await ThemeStore.openDefault();
    await _store?.write(pref.name);
  }

  static ThemePref _parse(String? raw) {
    if (raw == null) return ThemePref.system;
    try {
      return ThemePref.values.byName(raw.trim());
    } catch (_) {
      return ThemePref.system; // 非法值回落
    }
  }
}

/// 全局单例(App 启动时 load;设置面板直接写)。
final ThemeController themeController = ThemeController();
