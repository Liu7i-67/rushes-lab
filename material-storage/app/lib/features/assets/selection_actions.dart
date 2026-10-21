/// 操作栏 B5 回调编排(assets_page 瘦身拆件,守 300 行硬顶):
/// 输入=页面已就绪的数据切片(选中资产/选中 id/单夹详情),输出=返回是否
/// 清空选中(批量前缀经 onSettle 回传剩余 id)。弹层本体见各 *_sheet。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/app_log.dart';
import '../preview/request_access_sheet.dart';
import '../share/share_create_sheet.dart';
import 'asset_selection_bar.dart';
import 'batch_move_sheet.dart';
import 'batch_prefix_sheet.dart';
import 'batch_tag_sheet.dart';

/// 分享:仅恰好单选可用(bar 已置灰多选;此处兜底)。恒 false=不清选中。
Future<bool> shareSingleAsset(BuildContext context, List<Asset> picked) async {
  if (picked.length != 1) return false;
  await showShareSheet(context,
      kind: 'asset',
      targetId: picked.first.id,
      targetLabel: picked.first.filename);
  return false;
}

/// 移动:项目固定=单夹详情回填的 projectId(详情未到 → 提示稍后)。
/// 返回 true=已移动,调用方清选中。
Future<bool> moveSelectedAssets(
  BuildContext context, {
  required List<String> selectedIds,
  required String sourceFolderId,
  required Folder? detail,
  required String? whereLabel,
}) async {
  final projectId = detail?.projectId;
  if (projectId == null) {
    AppLog.info('assets', '目录详情未加载完成,移动稍后重试');
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('目录详情未加载完成,稍后重试')));
    return false;
  }
  final moved = await showBatchMoveSheet(context,
      selectedIds: selectedIds,
      sourceFolderId: sourceFolderId,
      projectId: projectId,
      projectLabel: whereLabel ?? projectId);
  return moved;
}

/// 删除:确认弹窗+软删循环+403/409 detail 透传;完成即清选中(web 同)。
Future<bool> deleteSelected(BuildContext context,
        {required List<Asset> picked, required String folderId}) async =>
    await deleteSelectedAssets(context, assets: picked, folderId: folderId) !=
    null;

/// 批量打标(⋯):有任一成功即清选中(失效已由宫格订阅驱动静默刷新)。
Future<bool> batchTagSelected(BuildContext context,
    {required List<String> selectedIds, required String folderId}) async {
  final ok = await showBatchTagSheet(context,
      assetIds: selectedIds, folderId: folderId);
  return ok;
}

/// 批量前缀(⋯):中途失败 → 未提交剩余 id 保留选中供重试(web 同语义)。
void batchPrefixSelected(
  BuildContext context, {
  required List<Asset> picked,
  required List<String> selectedIds,
  required String folderId,
  required void Function(Set<String> remaining) onSettle,
}) {
  showBatchPrefixSheet(context,
      assets: picked,
      selectedIds: selectedIds,
      folderId: folderId, onSettle: (remaining) {
    onSettle(remaining.toSet());
  });
}

/// 申请权限(⋯):仅恰好单选(bar 置灰多选;此处兜底)。恒 false=不清选中。
Future<bool> requestAccessSingle(
    BuildContext context, List<Asset> picked) async {
  if (picked.length != 1) return false;
  await showRequestAccessSheet(context,
      targetType: 'asset',
      targetId: picked.first.id,
      targetName: picked.first.filename);
  return false;
}
