/// AssetSelectionBar — 宫格多选态底部操作栏(F8):✕ + 已选 N 项 + 六键
/// (全选/下载/分享/移动/删除/更多),主操作金、禁用 ink3,禁用原因点按 toast。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../core/transfers/transfer_queue.dart' show TransferQueue;
import '../../models/models.dart';
import '../../services/downloads.dart';
import '../../services/app_log.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/toast.dart';
import 'asset_writeback.dart';
import 'selection_action_button.dart';
import 'selection_actions_menu.dart';

/// 多选下载编排:已知无权提示;>20 确认;逐文件入队不中断。
Future<(int, int)?> downloadSelectedAssets(
  BuildContext context, {
  required List<Asset> assets,
  required bool? canDownload,
  required String where,
  SavePlatform? platform,
  TransferQueue? queue,
  DownloadIo? io,
}) async {
  if (canDownload == false) {
    toast(context, '当前文件夹无下载权限,可先在预览页申请');
    return null;
  }
  if (needsBatchConfirm(assets.length)) {
    final go = await _confirmBatch(context, assets.length);
    if (!go) return null;
  }
  final (enqueued, skipped) = await enqueueDownloads(
    assets,
    where: where,
    platform: platform,
    queue: queue,
    io: io,
  );
  if (!context.mounted) return (enqueued, skipped);
  toast(
    context,
    skipped > 0 ? '已加入下载队列 $enqueued 个,跳过 $skipped 个' : '已加入下载队列 $enqueued 个',
    tone: ToastTone.success,
  );
  return (enqueued, skipped);
}

/// 批量软删编排:确认 → 逐条 DELETE(失败不中断)→ 汇总 toast。
Future<(int, int)?> deleteSelectedAssets(
  BuildContext context, {
  required List<Asset> assets,
  required String folderId,
}) async {
  if (assets.isEmpty) return null;
  final go = await showAppConfirm(
    context,
    title: '删除 ${assets.length} 个文件?',
    content: '文件将移入回收站,可在文件夹「⋯ → 回收站」中恢复。',
    confirmLabel: '删除',
    danger: true,
  );
  if (go != true) return null;
  var ok = 0;
  var fail = 0;
  String? firstError;
  for (final a in assets) {
    try {
      await session.api!.assets.delete(a.id);
      ok++;
    } on ApiException catch (e) {
      fail++;
      firstError ??= e.message; // 403/409 detail 透传(首个失败原因入汇总)
      AppLog.error('delete', '删除失败:${a.filename}', e);
    } catch (_) {
      fail++;
    }
  }
  if (ok > 0) {
    notifyAssetMutation(folderId);
  }
  if (!context.mounted) return (ok, fail);
  toast(
    context,
    '删除 $ok 个文件 · 失败 $fail 个${firstError == null ? '' : '(首个失败:$firstError)'}',
    tone: fail > 0 ? ToastTone.error : ToastTone.success,
  );
  return (ok, fail);
}

Future<bool> _confirmBatch(BuildContext context, int count) async {
  final go = await showAppConfirm(
    context,
    title: '批量下载确认',
    content: '即将下载 $count 个文件,逐个保存到相册 / Download/浣花视界,继续?',
    confirmLabel: '继续下载',
  );
  return go ?? false;
}

class AssetSelectionBar extends StatelessWidget {
  const AssetSelectionBar({
    super.key,
    required this.count,
    required this.canDownload,
    required this.onClear,
    this.allSelected = false,
    this.onToggleAll,
    required this.onDownload,
    this.onShare,
    this.onMove,
    this.onDelete,
    this.onBatchTag,
    this.onBatchPrefix,
    this.onRequest,
  });

  final int count;

  final bool? canDownload;

  final bool allSelected;
  final VoidCallback? onToggleAll;

  /// ✕ 退出多选(清空选中并退出显式选择态)。
  final VoidCallback onClear;

  final VoidCallback onDownload;

  /// 分享/申请权限仅恰好单选可用(count==1 才点亮,多选置灰)。
  final VoidCallback? onShare;
  final VoidCallback? onMove;
  final VoidCallback? onDelete;

  final VoidCallback? onBatchTag;
  final VoidCallback? onBatchPrefix;
  final VoidCallback? onRequest;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final canAct = count > 0;
    final single = count == 1;
    final noDownloadPerm = canDownload == false;
    return Container(
      decoration: BoxDecoration(
        color: tk.surface,
        border: Border(top: BorderSide(color: tk.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Tk.spaceXs,
            Tk.spaceXs,
            Tk.spaceXs,
            Tk.spaceXs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: '退出多选',
                    icon: const Icon(Icons.close, size: 20),
                    color: tk.ink2,
                    onPressed: onClear,
                  ),
                  Text(
                    '已选 $count 项',
                    style: TextStyle(
                      fontSize: Tk.fzMd,
                      fontWeight: FontWeight.w600,
                      color: tk.ink,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: SelectionActionButton(
                      icon: allSelected ? Icons.deselect : Icons.select_all,
                      label: allSelected ? '取消全选' : '全选',
                      enabled: onToggleAll != null,
                      onTap: onToggleAll,
                    ),
                  ),
                  Expanded(
                    child: SelectionActionButton(
                      icon: Icons.download_outlined,
                      label: '下载',
                      tooltip: '批量下载',
                      primary: true,
                      disabledReason: noDownloadPerm
                          ? '当前文件夹无下载权限,可先在预览页申请'
                          : null,
                      enabled: canAct && !noDownloadPerm,
                      onTap: onDownload,
                    ),
                  ),
                  Expanded(
                    child: SelectionActionButton(
                      icon: Icons.ios_share_outlined,
                      label: '分享',
                      tooltip: single ? '分享链接(需登录访问)' : null,
                      disabledReason: canAct && !single
                          ? '分享仅单选可用,请只保留一个选中'
                          : null,
                      enabled: canAct && single && onShare != null,
                      onTap: onShare,
                    ),
                  ),
                  Expanded(
                    child: SelectionActionButton(
                      icon: Icons.drive_file_move_outlined,
                      label: '移动',
                      tooltip: '移动到其他目录',
                      enabled: canAct && onMove != null,
                      onTap: onMove,
                    ),
                  ),
                  Expanded(
                    child: SelectionActionButton(
                      icon: Icons.delete_outline_outlined,
                      label: '删除',
                      tooltip: '移入回收站',
                      enabled: canAct && onDelete != null,
                      onTap: onDelete,
                    ),
                  ),
                  Expanded(
                    child: SelectionMoreMenu(
                      count: count,
                      onBatchTag: onBatchTag,
                      onBatchPrefix: onBatchPrefix,
                      onRequest: onRequest,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
