/// 操作栏回调编排(assets_page 拆件,守 300 行硬顶):
/// - [GridSelection]:显式多选态(selecting)+ 选中集合的纯状态机;
/// - [AssetBatchActions]:输入页面已就绪的数据切片(选中资产/选中 id/单夹
///   详情),输出动作完成后的清选中/前缀剩余回传回调;弹层本体见各 *_sheet。
library;

import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../widgets/toast.dart';
import '../preview/preview_page.dart';
import '../preview/request_access_sheet.dart';
import '../share/share_create_sheet.dart';
import 'asset_selection_bar.dart';
import 'batch_move_sheet.dart';
import 'batch_prefix_sheet.dart';
import 'batch_tag_sheet.dart';

/// 宫格多选状态:「选择」进入(0 选中也保持操作栏)/「取消」退出;
/// 长按/点格自动进入;全选只勾满已加载条目,再点清空并退出。
class GridSelection {
  bool selecting = false;
  final Set<String> selected = <String>{};

  int get count => selected.length;

  void toggle(Asset a) {
    selecting = true;
    if (!selected.remove(a.id)) selected.add(a.id);
  }

  void toggleMode() {
    if (selecting) {
      clear();
    } else {
      selecting = true;
    }
  }

  void toggleAll(List<Asset> items) {
    if (items.isNotEmpty && selected.length >= items.length) {
      clear();
      return;
    }
    selecting = true;
    selected
      ..clear()
      ..addAll([for (final a in items) a.id]);
  }

  void clear() {
    selected.clear();
    selecting = false;
  }

  /// 静默刷新后剪掉他端已删的失效选中 id。
  void retain(Set<String> liveIds) =>
      selected.removeWhere((id) => !liveIds.contains(id));

  /// 批量前缀中途失败:未提交 id 保留选中;全部提交完则退出多选。
  void settlePrefix(Set<String> remaining) {
    selected
      ..clear()
      ..addAll(remaining);
    if (remaining.isEmpty) selecting = false;
  }
}

/// 批量动作编排(全选/下载/分享/移动/删除/打标/前缀/申请权限)。
class AssetBatchActions {
  AssetBatchActions({
    required this.context,
    required this.folderId,
    required this.where,
    required this.whereLabel,
    required this.detail,
    required this.canDownload,
    required this.picked,
    required this.selectedIds,
    required this.onCleared,
    required this.onPrefixSettled,
  });

  final BuildContext context;
  final String folderId;
  final String where;
  final String? whereLabel;
  final Folder? detail;
  final bool? canDownload;
  final List<Asset> picked;
  final List<String> selectedIds;
  final VoidCallback onCleared;
  final void Function(Set<String> remaining) onPrefixSettled;

  /// 批量下载:>20 确认、逐文件入队;入队成功即清选中态。
  Future<void> download() async {
    Haptics.light();
    final r = await downloadSelectedAssets(
      context,
      assets: picked,
      canDownload: canDownload,
      where: where,
    );
    if (r != null && context.mounted) onCleared();
  }

  Future<void> share() => shareSingleAsset(context, picked);

  Future<void> move() async {
    final moved = await moveSelectedAssets(
      context,
      selectedIds: selectedIds,
      sourceFolderId: folderId,
      detail: detail,
      whereLabel: whereLabel,
      assetNames: {for (final a in picked) a.id: a.filename},
    );
    if (moved && context.mounted) onCleared();
  }

  Future<void> delete() async {
    if (await deleteSelected(context, picked: picked, folderId: folderId)) {
      if (context.mounted) onCleared();
    }
  }

  Future<void> batchTag() async {
    if (await batchTagSelected(
      context,
      selectedIds: selectedIds,
      folderId: folderId,
    )) {
      if (context.mounted) onCleared();
    }
  }

  void batchPrefix() {
    batchPrefixSelected(
      context,
      picked: picked,
      selectedIds: selectedIds,
      folderId: folderId,
      onSettle: (remaining) {
        if (context.mounted) onPrefixSettled(remaining);
      },
    );
  }

  Future<void> requestAccess() => requestAccessSingle(context, picked);
}

/// 打开预览页(宫格点按;items 顺序=宫格当前排序,index 对应)。
void openAssetPreview(
  BuildContext context,
  List<Asset> items,
  int index,
  String folderId,
  bool? canDownload,
  String where,
) {
  Navigator.of(context).pushNamed(
    '/preview',
    arguments: PreviewArgs(
      items: List.of(items),
      index: index,
      folderId: folderId,
      canDownload: canDownload,
      where: where,
    ),
  );
}

/// 分享:仅恰好单选可用(bar 已置灰多选;此处兜底)。恒 false=不清选中。
Future<bool> shareSingleAsset(BuildContext context, List<Asset> picked) async {
  if (picked.length != 1) return false;
  await showShareSheet(
    context,
    kind: 'asset',
    targetId: picked.first.id,
    targetLabel: picked.first.filename,
  );
  return false;
}

/// 移动:项目固定=单夹详情回填的 projectId(详情未到 → 提示稍后)。
Future<bool> moveSelectedAssets(
  BuildContext context, {
  required List<String> selectedIds,
  required String sourceFolderId,
  required Folder? detail,
  required String? whereLabel,
  Map<String, String>? assetNames,
}) async {
  final projectId = detail?.projectId;
  if (projectId == null) {
    AppLog.info('assets', '目录详情未加载完成,移动稍后重试');
    toast(context, '目录详情未加载完成,稍后重试');
    return false;
  }
  return showBatchMoveSheet(
    context,
    selectedIds: selectedIds,
    sourceFolderId: sourceFolderId,
    projectId: projectId,
    projectLabel: whereLabel ?? projectId,
    assetNames: assetNames,
  );
}

/// 删除:确认弹窗+软删循环+403/409 detail 透传;完成即清选中。
Future<bool> deleteSelected(
  BuildContext context, {
  required List<Asset> picked,
  required String folderId,
}) async =>
    await deleteSelectedAssets(context, assets: picked, folderId: folderId) !=
    null;

/// 批量打标(⋯):有任一成功即清选中。
Future<bool> batchTagSelected(
  BuildContext context, {
  required List<String> selectedIds,
  required String folderId,
}) async {
  return showBatchTagSheet(context, assetIds: selectedIds, folderId: folderId);
}

/// 批量前缀(⋯):中途失败 → 未提交剩余 id 保留选中供重试。
void batchPrefixSelected(
  BuildContext context, {
  required List<Asset> picked,
  required List<String> selectedIds,
  required String folderId,
  required void Function(Set<String> remaining) onSettle,
}) {
  showBatchPrefixSheet(
    context,
    assets: picked,
    selectedIds: selectedIds,
    folderId: folderId,
    onSettle: (remaining) {
      onSettle(remaining.toSet());
    },
  );
}

/// 申请权限(⋯):仅恰好单选(bar 置灰多选;此处兜底)。恒 false=不清选中。
Future<bool> requestAccessSingle(
  BuildContext context,
  List<Asset> picked,
) async {
  if (picked.length != 1) return false;
  await showRequestAccessSheet(
    context,
    targetType: 'asset',
    targetId: picked.first.id,
    targetName: picked.first.filename,
  );
  return false;
}
