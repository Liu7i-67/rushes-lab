/// ThemeStore 单测(WP0):可注入读写、首次为空、异常静默。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/theme_store.dart';

void main() {
  test('read 透传注入值', () async {
    final store = ThemeStore(read: () async => 'dark');
    expect(await store.read(), 'dark');
  });

  test('write 透传内容(同步闭包亦可)', () async {
    String? written;
    final store = ThemeStore(write: (v) => written = v);
    await store.write('light');
    expect(written, 'light');
  });

  test('首次为空:文件不存在/未注入 → null', () async {
    final store = ThemeStore(write: (_) {});
    expect(await store.read(), isNull);
  });

  test('读异常 → null 且不抛', () async {
    final store = ThemeStore(read: () async => throw StateError('io'));
    expect(await store.read(), isNull);
  });

  test('写异常 → 不抛', () async {
    final store = ThemeStore(write: (_) async => throw StateError('io'));
    await store.write('dark'); // 不抛即通过
  });
}
