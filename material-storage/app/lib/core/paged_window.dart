/// PagedWindow — 「显示序 ↔ 后端 offset 序」映射纯模型(F1 快速滚动条)。
///
/// 两套序的关系(模型说明):
/// - 后端 offset 序:列表接口(宫格 assets list / 回收站 listTrash)按
///   created_at DESC 分页,offset=0 是最新一条;已加载数据在 offset 域恒为
///   连续前缀 [0, loaded)——本类不感知稀疏窗口(D5:连续 append 模型)。
/// - 显示序:用户在屏幕上看到的序。
///   * descending=true(回收站恒此态):显示序 = 后端 offset 序,已加载区
///     = 显示序 [0, loaded),骨架在尾部;
///   * descending=false(宫格页升序切换):显示序是 offset 序的倒置,
///     offset i 显示在 total-1-i 处——已加载块(后端最新 loaded 条)整体
///     挪到显示序尾部 [total-loaded, total),骨架在头部。注意此时页面
///     `_items` 已重排为升序(最旧在前),assetAt 直接按块内下标取数。
///
/// 补齐口径(D5 不变量的推论):offsetWindowFor 返回的缺口窗口恒与已加载
/// 前缀邻接——DESC 起点收缩到 max(显示序起点, loaded),ASC 恒从 loaded
/// 邻接扩展——保证 append 后 `_items` 仍是连续前缀。ASC 头部 seek 的代价
/// 是近乎补满 [loaded, total-displayStart)(D11,PM 拍板 2026-11-24),
/// 是连续前缀模型的固有约束,非缺陷。
///
/// 职责三件:显示序取数(assetAt,未命中返回 null 供骨架渲染)、显示序
/// 区间 → 待补齐的后端 offset 窗口(offsetWindowFor,半开区间
/// [start, end),只返回未加载缺口,全已加载返回 null)、后端 offset →
/// 显示序(displayIndexOf,气泡「~N / M」与定位用,clamp [0, total-1])。
/// 纯 Dart 无框架依赖,可纯单测。
library;

import '../models/models.dart';

/// 分页窗口模型;全部方法纯函数,不改任何状态。
class PagedWindow {
  PagedWindow({
    required this.total,
    required this.loaded,
    required this.descending,
  });

  /// 后端全量计数(列表接口 total)。
  final int total;

  /// 已加载条数(offset 域连续前缀 [0, loaded);>total 时按 total 兜底)。
  final int loaded;

  /// true = 显示序与后端 DESC offset 序一致(骨架在尾部);
  /// false = 升序显示,已加载块在显示序尾部(骨架在头部)。
  final bool descending;

  /// 显示序 index → 已加载数据;未命中(骨架区/越界/数据未就位)返回 null。
  Asset? assetAt(int displayIndex, List<Asset> items) {
    final n = total < 0 ? 0 : total;
    if (n <= 0 || displayIndex < 0 || displayIndex >= n) return null;
    final loadedN = loaded.clamp(0, n);
    final int? itemsIdx;
    if (descending) {
      // 已加载区 = 显示序 [0, loaded)
      itemsIdx = displayIndex < loadedN ? displayIndex : null;
    } else {
      // 已加载块 = 显示序 [total-loaded, total),块内下标直取
      final head = n - loadedN;
      itemsIdx = displayIndex >= head ? displayIndex - head : null;
    }
    if (itemsIdx == null || itemsIdx >= items.length) return null;
    return items[itemsIdx];
  }

  /// 显示序区间 [displayStart, displayEnd) → 后端 offset 窗口 (start, end)
  /// (半开区间;ASC 时反转:显示序 [s,e) ↔ offset [n-e, n-s))。越界
  /// clamp 到 [0, total];只补缺口,且缺口恒从已加载前缀末尾邻接扩展(D5:
  /// DESC 起点 = max(显示序起点, loaded),ASC 起点 = 恒 loaded)——保证
  /// append 后 `_items` 仍是 offset 域连续前缀。ASC 头部补齐因此近乎拉满
  /// [loaded, n-displayStart),是连续前缀模型的固有代价(D11),非缺陷。
  /// 区间完全落在已加载区(或空/倒挂区间)返回 null(无需加载)。
  (int, int)? offsetWindowFor(int displayStart, int displayEnd) {
    final n = total < 0 ? 0 : total;
    if (n <= 0) return null;
    final s = displayStart.clamp(0, n);
    final e = displayEnd.clamp(0, n);
    if (e <= s) return null;
    final loadedN = loaded.clamp(0, n);
    if (descending) {
      final gapStart = s > loadedN ? s : loadedN;
      if (gapStart >= e) return null; // 全已加载
      return (gapStart, e);
    }
    // ASC:显示序 [s,e) ↔ offset [n-e, n-s)。若取换算尾窗 [n-e, n-s),当
    // n-e > loaded 时窗口与已加载前缀不邻接,append 后 loaded=_items.length
    // 失真(P0);故缺口恒从 loaded 邻接扩展到 offset 上界 n-s。
    final offEnd = n - s;
    if (offEnd <= loadedN) return null; // 区间已全加载
    return (loadedN, offEnd);
  }

  /// 后端 offset → 显示序(clamp [0, total-1];气泡/定位用)。
  int displayIndexOf(int offset) {
    final n = total < 0 ? 0 : total;
    if (n <= 0) return 0;
    final o = offset.clamp(0, n - 1);
    return descending ? o : n - 1 - o;
  }
}
