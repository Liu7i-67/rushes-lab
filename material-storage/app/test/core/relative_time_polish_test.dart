/// app-polish 验收用例(对应需求文档 2026-10-21-app-polish.md E6):
/// 通知相对时间格式化纯函数单测(fmtRelativeTime,lib/core/fmt.dart;
/// notification_row.dart 消费)。
///
/// 落地口径(E6 定稿,占位注释矩阵的细化):
/// 刚刚(<1 分钟)/ N 分钟前(<1 小时)/ N 小时前(今日)/
/// 昨天 HH:mm / 前天 HH:mm / N 天前(3~7 天)/ MM-DD(同年)/
/// YYYY-MM-DD(跨年)/ 无法解析原样返回。
/// `now` 注入消除时钟依赖;createdAt 为本地等价时刻的 ISO(UTC 亦可,
/// 函数内 toLocal 归一——注入的 now 同样 toLocal,两侧一致即可)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/fmt.dart';

void main() {
  group('E6:通知相对时间格式化(fmtRelativeTime 纯函数)', () {
    // 锚点 now=2026-10-21 12:00(本地)
    final now = DateTime(2026, 10, 21, 12, 0, 0);

    test('刚刚(<1 分钟)', () {
      expect(
        fmtRelativeTime('2026-10-21T11:59:30', now: now),
        '刚刚',
      );
    });

    test('N 分钟前(<1 小时)', () {
      expect(fmtRelativeTime('2026-10-21T11:55:00', now: now), '5 分钟前');
      expect(fmtRelativeTime('2026-10-21T11:01:00', now: now), '59 分钟前');
    });

    test('N 小时前(今日)', () {
      expect(fmtRelativeTime('2026-10-21T09:00:00', now: now), '3 小时前');
      expect(fmtRelativeTime('2026-10-21T00:30:00', now: now), '11 小时前');
    });

    test('昨天 HH:mm / 前天 HH:mm', () {
      expect(fmtRelativeTime('2026-10-20T21:00:00', now: now), '昨天 21:00');
      expect(fmtRelativeTime('2026-10-19T09:05:00', now: now), '前天 09:05');
    });

    test('N 天前(3~7 天)', () {
      expect(fmtRelativeTime('2026-10-18T08:00:00', now: now), '3 天前');
      expect(fmtRelativeTime('2026-10-14T08:00:00', now: now), '7 天前');
    });

    test('同年更早 → MM-DD;跨年 → YYYY-MM-DD', () {
      expect(fmtRelativeTime('2026-10-13T09:00:00', now: now), '10-13',
          reason: '8 天前(>7)落 MM-DD');
      expect(fmtRelativeTime('2026-01-02T09:00:00', now: now), '01-02');
      expect(fmtRelativeTime('2025-12-31T09:00:00', now: now), '2025-12-31');
    });

    test('未来时刻(时钟偏差兜底)按小时差回落不崩溃', () {
      final r = fmtRelativeTime('2026-10-21T12:30:00', now: now);
      expect(r, isNotEmpty);
    });

    test('非法 iso 原样返回(不崩溃)', () {
      expect(fmtRelativeTime('not-a-date'), 'not-a-date');
      expect(fmtRelativeTime(''), '');
    });

    test('UTC iso 与本地 now 混用:toLocal 归一(时区无关断言)', () {
      // 同一时刻的 UTC 写法与本地写法必须得到同一文案(不受测试机时区影响)
      final utcIso = '2026-10-21T03:50:00Z';
      final localIso =
          DateTime(2026, 10, 21, 11, 50).toUtc().toIso8601String(); // 3:50Z
      final a = fmtRelativeTime(utcIso, now: now);
      final b = fmtRelativeTime(localIso, now: now);
      expect(a, b);
      expect(a, '10 分钟前', reason: 'UTC+8 下 03:50Z=本地 11:50;其余时区两式仍相等');
    });
  });
}
