/// fmt 纯函数单测:字节人性化 / ISO 日期截取。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/fmt.dart';

void main() {
  test('fmtBytes:B/KB/MB/GB 分段', () {
    expect(fmtBytes(123), '123 B');
    expect(fmtBytes(2048), '2.0 KB');
    expect(fmtBytes(5 * 1024 * 1024), '5.0 MB');
    expect(fmtBytes(3.5 * 1024 * 1024 * 1024), '3.50 GB');
  });

  test('fmtDate:ISO 截日期段,短串原样', () {
    expect(fmtDate('2026-10-19T10:00:00Z'), '2026-10-19');
    expect(fmtDate(''), '');
    expect(fmtDate('bad'), 'bad');
  });
}
