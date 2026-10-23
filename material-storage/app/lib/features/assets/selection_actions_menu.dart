/// SelectionMoreMenu — 多选栏「更多」溢出菜单(asset_selection_bar 拆件):
/// 批量打标 / 批量前缀 / 申请权限(仅恰好单选)。菜单项禁用态不关闭弹层,
/// 原因由副标题给出;0 选中时整个菜单禁用。
library;

import 'package:flutter/material.dart';

import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';

class SelectionMoreMenu extends StatelessWidget {
  const SelectionMoreMenu({
    super.key,
    required this.count,
    this.onBatchTag,
    this.onBatchPrefix,
    this.onRequest,
  });

  final int count;
  final VoidCallback? onBatchTag;
  final VoidCallback? onBatchPrefix;
  final VoidCallback? onRequest;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final enabled = count > 0;
    final color = enabled ? tk.ink2 : tk.ink3;
    return PopupMenuButton<String>(
      tooltip: '更多操作',
      enabled: enabled,
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
          enabled: enabled && onBatchTag != null,
          child: const ListTile(
            leading: Icon(Icons.sell_outlined),
            title: Text('批量打标'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'prefix',
          enabled: enabled && onBatchPrefix != null,
          child: const ListTile(
            leading: Icon(Icons.text_increase_outlined),
            title: Text('批量前缀'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'request',
          enabled: enabled && count == 1 && onRequest != null,
          child: ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: const Text('申请权限'),
            subtitle: count == 1 ? null : const Text('仅单选可用'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
      child: SizedBox(
        height: 48,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.more_horiz, size: 20, color: color),
            const SizedBox(height: 2),
            Text(
              '更多',
              style: TextStyle(fontSize: Tk.fzXs, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
