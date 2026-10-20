/// AssetSelectionBar — 宫格多选态底部操作栏(B5 功能点 1 全量点亮,B4 壳):
/// 四键=下载(B4)/分享(**仅恰好单选可用**,多选置灰)/移动/删除(确认弹窗+
/// 软删循环,403/409 detail 透传)+ ⋯ 溢出菜单(批量打标/批量前缀/申请权限
/// ——申请同样仅恰好单选)。下载权三态口径同预览页(单夹详情 my_can_download;
/// 已知 false 才禁用+提示)。deleteSelectedAssets 编排对标 web handleBulkDelete:
/// 逐条 DELETE、失败逐条计数不中断、汇总 toast。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../core/transfers/transfer_queue.dart' show TransferQueue;
import '../../models/models.dart';
import '../../services/downloads.dart';
import '../../services/app_log.dart';
import 'asset_writeback.dart';

/// 多选下载编排(B4;宫格「下载」键回调):已知无权 → 提示;>20 → 确认弹窗;
/// 逐文件入队,单点失败不中断整批。返回 (入队数, 跳过数);用户取消返回 null。
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
    _say(context, '当前文件夹无下载权限,可先在预览页申请');
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
  _say(context,
      skipped > 0 ? '已加入下载队列 $enqueued 个,跳过 $skipped 个' : '已加入下载队列 $enqueued 个');
  return (enqueued, skipped);
}

/// 批量软删编排(B5 功能点 1;web handleBulkDelete 同口径):确认弹窗 →
/// 逐条 DELETE(单条失败计数不中断,403/409 detail 透传)→ 汇总 toast。
/// 返回 (成功数, 失败数);用户取消确认返回 null。成功即失效
/// `assets:<folderId>`+folders 两 scope(宫格订阅静默刷新)。
Future<(int, int)?> deleteSelectedAssets(
  BuildContext context, {
  required List<Asset> assets,
  required String folderId,
}) async {
  if (assets.isEmpty) return null;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('删除 ${assets.length} 个文件?'),
      content: const Text('文件将移入回收站,可在文件夹「⋯ → 回收站」中恢复。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除')),
      ],
    ),
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
  _say(context,
      '删除 $ok 个文件 · 失败 $fail 个${firstError == null ? '' : '(首个失败:$firstError)'}');
  return (ok, fail);
}

Future<bool> _confirmBatch(BuildContext context, int count) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('批量下载确认'),
      content: Text('即将下载 $count 个文件,逐个保存到相册 / Download/浣花视界,继续?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('继续下载')),
      ],
    ),
  );
  return go ?? false;
}

void _say(BuildContext context, String msg) {
  AppLog.info('download', msg);
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// RefreshBus 间接引用已移除:删除成功直接走 notifyAssetMutation
/// (asset_writeback.dart,`assets:<folderId>`+folders 两 scope 失效)。

class AssetSelectionBar extends StatelessWidget {
  const AssetSelectionBar({
    super.key,
    required this.count,
    required this.canDownload,
    required this.onDownload,
    required this.onClear,
    this.onShare,
    this.onMove,
    this.onDelete,
    this.onBatchTag,
    this.onBatchPrefix,
    this.onRequest,
  });

  final int count;

  /// 单夹详情 my_can_download 三态:false=下载键禁用(已知无权)。
  final bool? canDownload;

  final VoidCallback onDownload;
  final VoidCallback onClear;

  /// 分享/申请权限仅恰好单选可用(count==1 才点亮,多选置灰)。
  final VoidCallback? onShare;
  final VoidCallback? onMove;
  final VoidCallback? onDelete;

  /// ⋯ 溢出菜单:批量打标/批量前缀/申请权限。
  final VoidCallback? onBatchTag;
  final VoidCallback? onBatchPrefix;
  final VoidCallback? onRequest;

  @override
  Widget build(BuildContext context) {
    final downloadDisabled = canDownload == false;
    final single = count == 1;
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Text('已选 $count 项'),
            const Spacer(),
            _key(
              context,
              icon: Icons.download_outlined,
              label: '下载',
              tooltip: downloadDisabled ? '无下载权限 · 可先在预览页申请' : '批量下载',
              enabled: !downloadDisabled,
              onTap: onDownload,
            ),
            _key(
              context,
              icon: Icons.ios_share_outlined,
              label: '分享',
              tooltip: single ? '分享链接(需登录访问)' : '仅单选可用',
              enabled: single && onShare != null,
              onTap: onShare,
            ),
            _key(
              context,
              icon: Icons.drive_file_move_outlined,
              label: '移动',
              tooltip: '移动到其他目录',
              enabled: onMove != null,
              onTap: onMove,
            ),
            _key(
              context,
              icon: Icons.delete_outline_outlined,
              label: '删除',
              tooltip: '移入回收站',
              enabled: onDelete != null,
              onTap: onDelete,
            ),
            _moreMenu(context),
            TextButton(onPressed: onClear, child: const Text('清空')),
          ],
        ),
      ),
    );
  }

  Widget _moreMenu(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_horiz),
      tooltip: '更多操作',
      onSelected: (key) {
        switch (key) {
          case 'tag':
            onBatchTag?.call();
          case 'prefix':
            onBatchPrefix?.call();
          case 'request':
            onRequest?.call();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'tag',
          enabled: onBatchTag != null,
          child: const ListTile(
            leading: Icon(Icons.sell_outlined),
            title: Text('批量打标'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'prefix',
          enabled: onBatchPrefix != null,
          child: const ListTile(
            leading: Icon(Icons.text_increase_outlined),
            title: Text('批量前缀'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'request',
          enabled: count == 1 && onRequest != null,
          child: ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: const Text('申请权限'),
            subtitle: count == 1 ? null : const Text('仅单选可用'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }

  /// 操作键:icon+label 竖排(操作栏四键设计语言)。
  Widget _key(
    BuildContext context, {
    required IconData icon,
    required String label,
    String? tooltip,
    bool enabled = false,
    VoidCallback? onTap,
  }) {
    final color = enabled ? null : Theme.of(context).disabledColor;
    final btn = InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: enabled ? onTap : null, // null=禁用(无回调/无权/多选置灰)
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip, child: btn);
  }
}
