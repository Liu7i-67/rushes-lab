/// AssetSelectionBar — 宫格多选态底部操作栏(B4 功能点 4②壳,B5 全量):
/// 本批亮「下载」键(批量逐文件入队 TransferQueue,>20 确认弹窗,桌面 web
/// download-store 同款);分享/移动/删除仍占位禁用(B5)。下载权三态口径同
/// 预览页(单夹详情 my_can_download;已知 false 才禁用+提示)。
library;

import 'package:flutter/material.dart';

import '../../core/transfers/transfer_queue.dart' show TransferQueue;
import '../../models/models.dart';
import '../../services/downloads.dart';
import '../../services/app_log.dart';

/// 多选下载编排(宫格「下载」键回调;独立顶层函数便于单测):
/// 已知无权 → 提示;>20 → 确认弹窗;逐文件入队,单点失败不中断整批。
/// 返回 (入队数, 跳过数);用户取消确认弹窗返回 null。
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
    _say(context, '当前文件夹无下载权限,可在预览页申请(B5 开放申请入口)');
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

class AssetSelectionBar extends StatelessWidget {
  const AssetSelectionBar({
    super.key,
    required this.count,
    required this.canDownload,
    required this.onDownload,
    required this.onClear,
  });

  final int count;

  /// 单夹详情 my_can_download 三态:false=下载键禁用(已知无权)。
  final bool? canDownload;

  final VoidCallback onDownload;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final downloadDisabled = canDownload == false;
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            const SizedBox(width: 16),
            Text('已选 $count 项'),
            const Spacer(),
            _key(
              context,
              icon: Icons.download_outlined,
              label: '下载',
              tooltip: downloadDisabled ? '无下载权限 · 可申请(B5 开放申请入口)' : '批量下载',
              enabled: !downloadDisabled,
              onTap: onDownload,
            ),
            _key(context, icon: Icons.ios_share_outlined, label: '分享'),
            _key(context, icon: Icons.drive_file_move_outlined, label: '移动'),
            _key(context, icon: Icons.delete_outline_outlined, label: '删除'),
            TextButton(onPressed: onClear, child: const Text('清空')),
          ],
        ),
      ),
    );
  }

  /// 操作键:icon+label 竖排(操作栏四键设计语言);下载键点亮(B4),
  /// 分享/移动/删除占位禁用(B5 全量)。
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
      onTap: enabled ? onTap : null, // null=禁用(占位/无权)
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
