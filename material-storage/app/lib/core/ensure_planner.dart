/// EnsurePlanner — 「补齐在途守卫 + pendingTarget 续补」决策核心(P2-3 抽取)。
///
/// assets_page 与 trash_page 的 _ensureVisibleLoaded/_fetchGap 原各有一份
/// 同构守卫逻辑(约 70% 重复),且 pendingTarget 语义漂移:宫格页存裸
/// displayEnd(续补时再加余量),回收站存 displayEnd+余量——维护隐患。
/// 本类把决策收拢为纯函数(页面保留各自 fetch 策略与失败 UI):
/// - [EnsurePlanner.decide]:入口三分支决策——忽略 / 记续补目标 / 发起
///   缺口拉取(输出 [EnsureDecision]);
/// - pendingTarget 统一为「裸 displayEnd」语义(不含余量;消费时调用方
///   再 + 一页余量经 [EnsurePlanner.gapFor] 换算缺口),两页一致;
/// - [EnsurePlanner.nextRound]:成功一轮后的续补判断——无进展清 pending
///   (防同窗反复空拉死循环),有进展才续补一轮。
/// 纯 Dart 无框架依赖,可纯单测(决策结果与原两页内联守卫逐分支等价)。
library;

import 'paged_window.dart';

/// 补齐入口决策结果([EnsurePlanner.decide] 的输出,三分支互斥)。
sealed class EnsureDecision {
  const EnsureDecision();
}

/// 忽略:整页在途/错误、失败态未放行、已全量加载、目标区间已全覆盖。
class EnsureIgnore extends EnsureDecision {
  const EnsureIgnore();
}

/// 记续补目标:补齐在途且入目标更远(只在更远时更新)。[displayEnd] 为
/// 裸显示序(统一语义,不含一页余量;消费时调用方自行加余量换算缺口)。
class EnsureRecordPending extends EnsureDecision {
  const EnsureRecordPending(this.displayEnd);

  final int displayEnd;

  @override
  bool operator ==(Object other) =>
      other is EnsureRecordPending && other.displayEnd == displayEnd;

  @override
  int get hashCode => displayEnd.hashCode;
}

/// 发起缺口拉取:后端 offset 半开窗口 [start, end),恒非空、与已加载
/// 前缀邻接(D5,由 PagedWindow.offsetWindowFor 保证;ASC 恒从 loaded
/// 邻接扩展,D11)。
class EnsureFetch extends EnsureDecision {
  const EnsureFetch(this.start, this.end);

  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is EnsureFetch && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// 补齐决策核心;全部方法纯函数,不改任何状态。
class EnsurePlanner {
  const EnsurePlanner._();

  /// 补齐入口决策。判定顺序(与原两页内联守卫逐分支等价):
  /// ① 整页在途/错误(loading/hasError)→ 忽略(页面 UI 态未就绪);
  /// ② 补齐失败态未放行(loadMoreFailed 且非 force)→ 忽略——回收站把
  ///    失败闸放在核心(自动路拦、显式用户动作放行);宫格页的失败闸在
  ///    骨架命中入口(_onSkeletonHit,失败不自动重试),核心调用走默认值
  ///    不闸(滚动重滑可重试,F5 语义);
  /// ③ 补齐在途(loadingMore)→ 只把更远目标记为 pending(裸 displayEnd;
  ///    非更远的目标完成后必被缺口判定去重,记录只空转);
  /// ④ 已全量加载(window.loaded ≥ window.total)→ 忽略(非在途无续补轮,
  ///    不记 pending);
  /// ⑤ 计算缺口(裸 displayEnd + [margin] 余量 → offsetWindowFor):
  ///    目标区间已全覆盖 → 忽略;否则发起 [start, end) 拉取。
  static EnsureDecision decide({
    required PagedWindow window,
    required int displayEnd,
    required int margin,
    required bool loading,
    required bool hasError,
    required bool loadingMore,
    required int? pendingTarget,
    bool loadMoreFailed = false,
    bool force = false,
  }) {
    if (loading || hasError) return const EnsureIgnore();
    if (loadMoreFailed && !force) return const EnsureIgnore();
    if (loadingMore) {
      if (pendingTarget == null || displayEnd > pendingTarget) {
        return EnsureRecordPending(displayEnd);
      }
      return const EnsureIgnore();
    }
    if (window.loaded >= window.total) return const EnsureIgnore();
    final gap = gapFor(window, displayEnd, margin);
    if (gap == null) return const EnsureIgnore();
    return EnsureFetch(gap.$1, gap.$2);
  }

  /// 显示序目标(裸)+ 一页余量 → 后端 offset 缺口窗口(半开 [start,end));
  /// 目标区间已全覆盖返回 null。ASC 恒从 loaded 邻接扩展(D5/D11)。
  static (int, int)? gapFor(PagedWindow window, int displayEnd, int margin) =>
      window.offsetWindowFor(0, displayEnd + margin);

  /// 成功一轮后的续补判断:记录过更远目标且有进展 → 返回该目标(裸
  /// displayEnd,调用方加余量再补一轮);无进展(缺口响应为空、窗口模型
  /// 未动)→ 返回 null,调用方清 pending 防死循环(同窗反复空拉)。
  static int? nextRound({
    required int? pendingTarget,
    required bool progressed,
  }) => progressed ? pendingTarget : null;
}
