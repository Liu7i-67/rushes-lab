/// ThemeStore — 外观偏好持久化(`theme.txt`,复用 path_provider)。
///
/// - [read]/[write] 可注入:单测零真实 IO(与 TransferStore 同款模式)。
/// - `openDefault()` 在测试环境无插件通道时返回 null,调用方降级为仅内存。
/// - 读写失败一律静默(返回 null / 不抛),不阻塞启动。
/// - 非法值不在本层判断,由 ThemeController 回落 [ThemePref.system]。
library;

import 'dart:async' show FutureOr;
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 偏好文件名(应用支持目录下)。
const String kThemeFileName = 'theme.txt';

class ThemeStore {
  factory ThemeStore({
    Future<String?> Function()? read,
    FutureOr<void> Function(String)? write,
  }) => ThemeStore._(read, write);

  ThemeStore._(this._read, this._write);

  final Future<String?> Function()? _read;
  final FutureOr<void> Function(String)? _write;

  /// 真实存储(应用支持目录/theme.txt);打开失败返回 null(静默降级)。
  static Future<ThemeStore?> openDefault() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$kThemeFileName');
      return ThemeStore(
        read: () async =>
            await file.exists() ? await file.readAsString() : null,
        write: (content) async => file.writeAsString(content, flush: true),
      );
    } catch (_) {
      return null;
    }
  }

  /// 读原始偏好;文件不存在/未注入/读失败 → null。
  Future<String?> read() async {
    final r = _read;
    if (r == null) return null;
    try {
      return await r();
    } catch (_) {
      return null;
    }
  }

  /// 写偏好;失败静默(不抛,不影响 UI 即时切换)。
  Future<void> write(String value) async {
    final w = _write;
    if (w == null) return;
    try {
      await w(value);
    } catch (_) {
      // 持久化失败降级为仅本次进程生效。
    }
  }
}
