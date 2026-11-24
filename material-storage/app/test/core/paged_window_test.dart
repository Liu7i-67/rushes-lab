/// PagedWindow 单测(快速滚动需求「测试功能点 1」全分支)。
///
/// 覆盖:DESC/ASC 两侧 assetAt(命中/骨架区/越界)、offsetWindowFor(DESC
/// 直通/ASC 反转/缺口恒从 loaded 邻接扩展/全已加载 null/越界 clamp/空倒挂
/// 区间)、displayIndexOf(正反向 + clamp);边界 total=0、loaded=0、
/// loaded=total、items 未就位;ASC 窗口全部用手工算例写死断言。
/// 纯 Dart 测试,无网络无 widget。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/paged_window.dart';
import 'package:ms_app/models/models.dart';

/// 后端 offset 序假数据:offset 0..n-1 ↔ a0..a{n-1}(a0 最新,DESC 排列)。
/// 构造方式贴 test/helpers/api_harness.dart 的 fakeAsset(直接 Asset(...))。
Asset _asset(String id) => Asset(
  id: id,
  filename: '$id.jpg',
  sizeBytes: 1,
  contentType: 'image/jpeg',
  createdAt: '2026-10-20T10:00:00Z',
);

/// DESC 侧 items:已加载块保持后端 offset 序(页面对象原样 append)。
List<Asset> _descItems(int n) => List.generate(n, (i) => _asset('a$i'));

/// ASC 侧 items:已加载块升序重排后(_toggleSort 形态)= DESC 块倒置,
/// 即 a{n-1}…a0(最旧在前)。
List<Asset> _ascItems(int n) =>
    List.generate(n, (i) => _asset('a${n - 1 - i}'));

void main() {
  group('DESC(descending=true):显示序=offset 序,骨架在尾部', () {
    test('assetAt:命中 [0,loaded) 返回 items[i]', () {
      final w = PagedWindow(total: 10, loaded: 4, descending: true);
      final items = _descItems(4);
      expect(w.assetAt(0, items)?.id, 'a0');
      expect(w.assetAt(3, items)?.id, 'a3');
    });

    test('assetAt:骨架区 [loaded,total) / 越界 / 负 index → null', () {
      final w = PagedWindow(total: 10, loaded: 4, descending: true);
      final items = _descItems(4);
      expect(w.assetAt(4, items), isNull, reason: '首个骨架位');
      expect(w.assetAt(9, items), isNull);
      expect(w.assetAt(10, items), isNull, reason: 'index==total 越界');
      expect(w.assetAt(-1, items), isNull);
    });

    test('offsetWindowFor:DESC 直通;部分已加载→窗口起点收缩到 loaded', () {
      final w = PagedWindow(total: 10, loaded: 4, descending: true);
      expect(w.offsetWindowFor(4, 8), (4, 8), reason: '区间全为缺口,原样');
      expect(w.offsetWindowFor(2, 8), (4, 8), reason: '[2,4) 已加载,只补 [4,8)');
      expect(w.offsetWindowFor(0, 4), isNull, reason: '全已加载 → null');
    });

    test('offsetWindowFor:越界 clamp 到 [0,total];空/倒挂区间 → null', () {
      final w = PagedWindow(total: 10, loaded: 8, descending: true);
      expect(w.offsetWindowFor(-5, 3), isNull, reason: 'clamp 后 [0,3) 全已加载');
      expect(w.offsetWindowFor(8, 99), (8, 10), reason: 'end 越界 clamp 到 total');
      expect(w.offsetWindowFor(5, 5), isNull, reason: '空区间');
      expect(w.offsetWindowFor(7, 3), isNull, reason: '倒挂区间');
    });

    test('displayIndexOf:直通 + clamp 到 [0,total-1]', () {
      final w = PagedWindow(total: 10, loaded: 2, descending: true);
      expect(w.displayIndexOf(0), 0);
      expect(w.displayIndexOf(7), 7);
      expect(w.displayIndexOf(-3), 0, reason: '负 offset clamp 到 0');
      expect(w.displayIndexOf(99), 9, reason: '越界 offset clamp 到 total-1');
    });
  });

  group('ASC(descending=false):显示序为 offset 序倒置,骨架在头部', () {
    // 手工算例基准:total=10,loaded=4(已加载 offset [0,4)=最新 4 条,
    // 升序显示在 [6,10);items 为升序重排块 _ascItems(4)=a3,a2,a1,a0)。
    test('assetAt:命中 [total-loaded,total) 按块内下标直取', () {
      final w = PagedWindow(total: 10, loaded: 4, descending: false);
      final items = _ascItems(4);
      expect(w.assetAt(6, items)?.id, 'a3', reason: '已加载里最旧的在块首');
      expect(w.assetAt(9, items)?.id, 'a0', reason: '最新的在升序末尾');
      expect(w.assetAt(5, items), isNull, reason: '头部骨架区');
      expect(w.assetAt(0, items), isNull);
      expect(w.assetAt(10, items), isNull, reason: '越界');
      expect(w.assetAt(-1, items), isNull);
    });

    test(
      'offsetWindowFor:ASC 反转 + 缺口恒从 loaded 邻接扩展(total=1000/loaded=200)',
      () {
        // loaded=200 → offset [0,200) 已加载 = 显示序 [800,1000)。
        // 邻接扩展语义(D5/D11):缺口起点恒 loaded=200(不再取 offset 尾窗
        // 起点 n-e——尾窗与前缀不邻接会破坏连续前缀,即已修复的 P0)。
        final w = PagedWindow(total: 1000, loaded: 200, descending: false);
        // 显示序 [0,500) ↔ offset 上界 n-s=1000 → 邻接缺口 [200,1000)
        // (旧尾窗口径给 (500,1000),不邻接 → P0)
        expect(w.offsetWindowFor(0, 500), (200, 1000));
        // 大 total 邻接算例:显示序 [0,250) ↔ offset 上界 1000 → (200,1000)
        // (旧口径 (750,1000) 是 offset 尾窗,append 后 loaded 失真)
        expect(w.offsetWindowFor(0, 250), (200, 1000));
        // 显示序 [100,300) ↔ offset 上界 n-s=900 → 邻接缺口 [200,900)
        expect(w.offsetWindowFor(100, 300), (200, 900));
        // 显示序 [850,950) ↔ offset 上界 n-s=150 ≤ loaded=200 全已加载 → null
        expect(w.offsetWindowFor(850, 950), isNull);
        // 显示序 [700,900) ↔ offset 上界 300 > loaded → 邻接缺口 [200,300)
        expect(w.offsetWindowFor(700, 900), (200, 300));
        // 越界 clamp:显示序 [-50,20) → [0,20) ↔ offset 上界 1000 → (200,1000)
        expect(w.offsetWindowFor(-50, 20), (200, 1000));
        // 显示序 [900,2000) → clamp [900,1000) ↔ offset 上界 100 ≤ loaded → null
        expect(w.offsetWindowFor(900, 2000), isNull);
      },
    );

    test('displayIndexOf:ASC 反转 + clamp', () {
      final w = PagedWindow(total: 10, loaded: 2, descending: false);
      expect(w.displayIndexOf(0), 9, reason: 'offset 0(最新)在升序末尾');
      expect(w.displayIndexOf(9), 0);
      expect(w.displayIndexOf(-1), 9, reason: 'clamp 到 0 再反转 → 9');
      expect(w.displayIndexOf(99), 0, reason: 'clamp 到 total-1 再反转 → 0');
    });

    test('ASC 一致性:骨架区窗口 ↔ displayIndexOf 互逆(抽样)', () {
      final w = PagedWindow(total: 10, loaded: 4, descending: false);
      expect(w.offsetWindowFor(0, 6), (
        4,
        10,
      ), reason: '头部骨架 [0,6) ↔ 缺口,恒从 loaded=4 邻接扩展');
      expect(w.offsetWindowFor(6, 10), isNull, reason: '已加载块窗口恒 null');
      // 窗口起点 4 反回显示序 = 10-1-4 = 5,即骨架区末位
      expect(w.displayIndexOf(4), 5);
    });
  });

  group('边界', () {
    test('total=0:assetAt/offsetWindowFor 恒 null,displayIndexOf=0', () {
      for (final descending in [true, false]) {
        final w = PagedWindow(total: 0, loaded: 0, descending: descending);
        expect(w.assetAt(0, const []), isNull);
        expect(w.assetAt(-1, const []), isNull);
        expect(w.offsetWindowFor(0, 10), isNull);
        expect(w.displayIndexOf(5), 0);
      }
    });

    test('loaded=0:assetAt 恒 null;窗口=整个请求区间(缺口全覆盖)', () {
      final wd = PagedWindow(total: 10, loaded: 0, descending: true);
      expect(wd.assetAt(0, const []), isNull);
      expect(wd.offsetWindowFor(0, 10), (0, 10));
      final wa = PagedWindow(total: 10, loaded: 0, descending: false);
      expect(wa.assetAt(0, const []), isNull);
      expect(wa.offsetWindowFor(0, 10), (
        0,
        10,
      ), reason: 'ASC 反转 [10-10,10-0)=(0,10) 同值');
    });

    test('loaded=total:assetAt 全区命中;offsetWindowFor 恒 null', () {
      final wd = PagedWindow(total: 6, loaded: 6, descending: true);
      final items = _descItems(6);
      expect(wd.assetAt(0, items)?.id, 'a0');
      expect(wd.assetAt(5, items)?.id, 'a5');
      expect(wd.offsetWindowFor(0, 6), isNull);
      final wa = PagedWindow(total: 6, loaded: 6, descending: false);
      final asc = _ascItems(6);
      expect(wa.assetAt(0, asc)?.id, 'a5', reason: '升序首条=最旧');
      expect(wa.assetAt(5, asc)?.id, 'a0');
      expect(wa.offsetWindowFor(0, 6), isNull);
      expect(wa.offsetWindowFor(3, 5), isNull);
    });

    test('items 未就位(短于 loaded / 空)→ assetAt null 兜底不炸', () {
      final w = PagedWindow(total: 10, loaded: 4, descending: true);
      expect(w.assetAt(2, _descItems(2)), isNull);
      expect(w.assetAt(0, const <Asset>[]), isNull);
      final wa = PagedWindow(total: 10, loaded: 4, descending: false);
      expect(wa.assetAt(8, _ascItems(1)), isNull);
      expect(wa.assetAt(6, const <Asset>[]), isNull);
    });

    test('loaded/total 异常入参兜底:loaded>total 按 total;负 total 视同 0', () {
      final w = PagedWindow(total: 5, loaded: 99, descending: true);
      expect(w.assetAt(4, _descItems(5))?.id, 'a4');
      expect(w.assetAt(5, _descItems(5)), isNull);
      expect(w.offsetWindowFor(0, 5), isNull, reason: '全量已加载');
      final wn = PagedWindow(total: -1, loaded: 3, descending: true);
      expect(wn.assetAt(0, _descItems(3)), isNull);
      expect(wn.offsetWindowFor(0, 2), isNull);
      expect(wn.displayIndexOf(2), 0);
    });
  });
}
