/// 测试功能点 5(B2):预览胶片条切张 — 边界即停 + 序列正确(纯逻辑 FilmstripPager)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/preview/filmstrip.dart';

void main() {
  group('FilmstripPager', () {
    test('初始定位:越界初始值 clamp 到边界', () {
      expect(FilmstripPager(length: 5, initial: 2).index, 2);
      expect(FilmstripPager(length: 5, initial: -1).index, 0);
      expect(FilmstripPager(length: 5, initial: 9).index, 4);
    });

    test('next/prev 序列正确:逐张移动', () {
      final p = FilmstripPager(length: 4, initial: 0);
      expect(p.next(), isTrue);
      expect(p.index, 1);
      expect(p.next(), isTrue);
      expect(p.index, 2);
      expect(p.prev(), isTrue);
      expect(p.index, 1);
    });

    test('边界即停:首张 prev 不动,末张 next 不动(返回 false)', () {
      final p = FilmstripPager(length: 3, initial: 0);
      expect(p.canPrev, isFalse);
      expect(p.prev(), isFalse);
      expect(p.index, 0); // 不越界
      p..next()..next();
      expect(p.index, 2);
      expect(p.canNext, isFalse);
      expect(p.next(), isFalse);
      expect(p.index, 2); // 停在末张
    });

    test('moveTo(胶片条点按)clamp', () {
      final p = FilmstripPager(length: 3);
      p.moveTo(2);
      expect(p.index, 2);
      p.moveTo(99);
      expect(p.index, 2);
      p.moveTo(-5);
      expect(p.index, 0);
    });

    test('空列表/单文件:恒 0 且不可切', () {
      final empty = FilmstripPager(length: 0);
      expect(empty.index, 0);
      expect(empty.next(), isFalse);
      final single = FilmstripPager(length: 1);
      expect(single.next(), isFalse);
      expect(single.prev(), isFalse);
    });
  });
}
