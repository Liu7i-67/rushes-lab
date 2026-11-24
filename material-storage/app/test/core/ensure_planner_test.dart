/// EnsurePlanner 单测(P2-3 抽取「补齐在途守卫 + pendingTarget 续补」决策
/// 核心;决策结果与 assets_page/trash_page 原内联守卫逐分支等价,专职测试
/// 要求的全分支):
/// - loading / hasError 整页态拦截;
/// - failed 拦截与 force 放行(回收站失败闸语义;宫格页核心路不闸走默认);
/// - 在途记 pending:pending 为 null 必记、只取更远(严格大于)、非更远/
///   持平忽略;记的值 = 裸 displayEnd(不含余量,P2-3 统一语义);
/// - 在途优先于全量短路(loadingMore + loaded≥total 仍记 pending);
/// - 全量加载短路(非在途不记 pending、不发缺口,含 loaded 越界形态);
/// - 缺口计算:DESC 裸 displayEnd + margin → 窗口从 loaded 邻接起、越界
///   clamp 到 total、目标区间已全覆盖 gap=null → 忽略;ASC 恒从 loaded
///   邻接扩展到 offset 上界(D5/D11);total=0 空窗忽略;
/// - nextRound 续补判断:有进展返回裸 pending 续补、无进展清 null(防死
///   循环:缺口响应为空不续补)、无 pending 恒 null。
/// 纯 Dart 测试,无网络无 widget。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/ensure_planner.dart';
import 'package:ms_app/core/paged_window.dart';

void main() {
  // 基准窗:total=1000,loaded=200(宫格首载页口径)。
  // DESC:骨架在尾 [200,1000);ASC:骨架在头 [0,800),已加载块在显示序尾。
  PagedWindow desc() => PagedWindow(total: 1000, loaded: 200, descending: true);
  PagedWindow asc() => PagedWindow(total: 1000, loaded: 200, descending: false);

  /// decide 便捷入口:默认 = 列表态、非在途、无 pending(逐参覆盖)。
  EnsureDecision decide(
    PagedWindow window, {
    int displayEnd = 900,
    int margin = 200,
    bool loading = false,
    bool hasError = false,
    bool loadMoreFailed = false,
    bool force = false,
    bool loadingMore = false,
    int? pendingTarget,
  }) => EnsurePlanner.decide(
    window: window,
    displayEnd: displayEnd,
    margin: margin,
    loading: loading,
    hasError: hasError,
    loadMoreFailed: loadMoreFailed,
    force: force,
    loadingMore: loadingMore,
    pendingTarget: pendingTarget,
  );

  group('decide:整页态拦截(①)', () {
    test('loading=true → 忽略,优先于一切(含在途记 pending)', () {
      expect(
        decide(desc(), loading: true, loadingMore: true, pendingTarget: null),
        isA<EnsureIgnore>(),
        reason: '整页在途时骨架/滚动路都不该发请求',
      );
    });

    test('hasError=true → 忽略', () {
      expect(decide(desc(), hasError: true), isA<EnsureIgnore>());
    });
  });

  group('decide:失败态拦截与放行(②,回收站失败闸语义)', () {
    test('loadMoreFailed=true 且非 force → 忽略(自动路被拦,防失败风暴)', () {
      expect(
        decide(desc(), loadMoreFailed: true),
        isA<EnsureIgnore>(),
        reason: '骨架行/滚动监听自动触发在失败态被拦',
      );
    });

    test('loadMoreFailed=true 且 force=true → 放行,正常出缺口', () {
      final d = decide(
        desc(),
        displayEnd: 750,
        loadMoreFailed: true,
        force: true,
      );
      expect(d, isA<EnsureFetch>(), reason: '重试条/重新 seek 是显式动作,放行');
      expect((d as EnsureFetch).start, 200);
      expect(d.end, 950, reason: '750 + margin 200 → 窗口 [200,950)');
    });

    test('宫格页核心路不闸:failed/force 走默认值(不拦)', () {
      expect(decide(desc(), displayEnd: 900), isA<EnsureFetch>());
    });
  });

  group('decide:在途记 pending(③,裸 displayEnd 统一语义)', () {
    test('pending=null → 必记;值为裸 displayEnd,不含 margin', () {
      final d = decide(desc(), displayEnd: 900, loadingMore: true);
      expect(d, isA<EnsureRecordPending>());
      expect(
        (d as EnsureRecordPending).displayEnd,
        900,
        reason: 'P2-3 统一:两页都存裸显示序(旧 trash 口径存 1100,已废除)',
      );
    });

    test('只取更远:入目标严格大于 pending 才更新', () {
      final farther = decide(
        desc(),
        displayEnd: 950,
        loadingMore: true,
        pendingTarget: 900,
      );
      expect(farther, isA<EnsureRecordPending>());
      expect((farther as EnsureRecordPending).displayEnd, 950);

      final nearer = decide(
        desc(),
        displayEnd: 850,
        loadingMore: true,
        pendingTarget: 900,
      );
      expect(nearer, isA<EnsureIgnore>(), reason: '非更远:记录只空转,忽略');
    });

    test('入目标与 pending 持平 → 忽略(非「大于等于」)', () {
      expect(
        decide(desc(), displayEnd: 900, loadingMore: true, pendingTarget: 900),
        isA<EnsureIgnore>(),
      );
    });

    test('在途 + 已全量加载 → 仍记 pending(在途优先于全量短路)', () {
      final full = PagedWindow(total: 1000, loaded: 1000, descending: true);
      final d = decide(
        full,
        displayEnd: 999,
        loadingMore: true,
        pendingTarget: null,
      );
      expect(d, isA<EnsureRecordPending>(), reason: '在途轮完成后还要续补一轮');
      expect((d as EnsureRecordPending).displayEnd, 999);
    });
  });

  group('decide:非在途短路(④/⑤ gap=null)', () {
    test('已全量加载 → 忽略(不记 pending、不发缺口)', () {
      final full = PagedWindow(total: 1000, loaded: 1000, descending: true);
      expect(decide(full, displayEnd: 999), isA<EnsureIgnore>());
    });

    test('loaded 越界形态(loaded>total)→ 忽略', () {
      final over = PagedWindow(total: 1000, loaded: 1200, descending: true);
      expect(decide(over, displayEnd: 999), isA<EnsureIgnore>());
    });

    test('目标区间已全覆盖(gap=null)→ 忽略', () {
      // DESC seek(0):margin 后 [0,200) 仍在已加载前缀内,无缺口。
      expect(
        decide(desc(), displayEnd: 0),
        isA<EnsureIgnore>(),
        reason: '对应页内「DESC 拖到最顶 onSeek(0) 不发请求」',
      );
    });

    test('total=0 空窗 → 忽略', () {
      final empty = PagedWindow(total: 0, loaded: 0, descending: true);
      expect(decide(empty, displayEnd: 0), isA<EnsureIgnore>());
    });
  });

  group('decide:发起缺口(⑤,窗口换算)', () {
    test('DESC:裸 displayEnd + margin → 窗口从 loaded 邻接起', () {
      final d = decide(desc(), displayEnd: 210, margin: 200);
      expect(
        d,
        const EnsureFetch(200, 410),
        reason: 'seek(210) → 缺口 [200,410)',
      );
    });

    test('DESC 跨批大缺口:决策只出整窗,分批策略留给页面', () {
      // 大文件夹口径(total=2000,宫格 T13 用例同款):seek(1250) → 缺口
      // [200,1450),宽度 1250 > 单批 500,由页面分批并行。
      final big = PagedWindow(total: 2000, loaded: 200, descending: true);
      final d = decide(big, displayEnd: 1250, margin: 200);
      expect(
        d,
        const EnsureFetch(200, 1450),
        reason: 'seek(1250) → 缺口 [200,1450)',
      );
    });

    test('越界 clamp:目标超 total 截到 total', () {
      final d = decide(desc(), displayEnd: 998, margin: 200);
      expect(d, const EnsureFetch(200, 1000), reason: '1198 clamp 到 total');
    });

    test('ASC:恒从 loaded 邻接扩展到 offset 上界(D5/D11)', () {
      // ASC seek 显示序 0(最旧端):显示序 [0,200) ↔ offset [800,1000),
      // 与已加载前缀不邻接 → 恒扩展为 [200,1000)。
      final d = decide(asc(), displayEnd: 0, margin: 200);
      expect(d, const EnsureFetch(200, 1000));
    });

    test('ASC 小目标同样邻接扩展(缺口末端只随 displayStart,D11)', () {
      final d = decide(asc(), displayEnd: 100, margin: 200);
      expect(
        d,
        const EnsureFetch(200, 1000),
        reason:
            '显示序 [0,300) ↔ offset [700,1000),但缺口末端恒取 offset '
            '上界 n-displayStart=1000 → 邻接扩展 [200,1000)(D11 头部代价)',
      );
    });
  });

  group('gapFor:续补轮的缺口换算(pending 裸值消费点)', () {
    test('裸 pending + margin 还原目标窗口(越界 clamp 到 total);全已覆盖 null', () {
      expect(EnsurePlanner.gapFor(desc(), 900, 200), (
        200,
        1000,
      ), reason: '1100 clamp 到 total=1000,与页内补齐口径一致');
      expect(EnsurePlanner.gapFor(desc(), 700, 200), (200, 900));
      expect(
        EnsurePlanner.gapFor(desc(), 0, 200),
        isNull,
        reason: '[0,200) 已全覆盖 → null(续补空转收敛)',
      );
    });
  });

  group('nextRound:成功一轮后的续补判断', () {
    test('有进展 + 有 pending → 返回裸目标续补一轮', () {
      expect(
        EnsurePlanner.nextRound(pendingTarget: 1900, progressed: true),
        1900,
      );
    });

    test('无进展 → 清 null(防死循环:缺口响应为空不续补)', () {
      expect(
        EnsurePlanner.nextRound(pendingTarget: 1900, progressed: false),
        isNull,
        reason: '窗口模型未动,同目标再拉必然再空,终止续补链',
      );
    });

    test('无 pending → 恒 null(有/无进展一致)', () {
      expect(
        EnsurePlanner.nextRound(pendingTarget: null, progressed: true),
        isNull,
      );
      expect(
        EnsurePlanner.nextRound(pendingTarget: null, progressed: false),
        isNull,
      );
    });
  });
}
