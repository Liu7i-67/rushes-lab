/// FolderGrantsSheet — 普通一级夹 explicit grant 管理(B6 §8.4;web
/// FolderGrantsPanel 移动版):grants 列表 + 添加(SubjectPicker + 多 level
/// viewer/downloader/uploader chips,一次授多 level)+ 撤销。**无有效期/倒计时
/// 控件**——后端只收 levels+主体,恒永久(web 同款勿造假 UI)。入口仅普通一级夹。
library;

export 'folder_grants_form.dart'
    show FolderGrantForm, kGrantLevels, grantLevelLabel;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import 'folder_grants_form.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';

/// 打开普通一级夹授权管理面板。
Future<void> showFolderGrantsSheet(
  BuildContext context, {
  required Folder folder,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _GrantsSheet(folder: folder),
  );
}

class _GrantsSheet extends StatefulWidget {
  const _GrantsSheet({required this.folder});

  final Folder folder;

  @override
  State<_GrantsSheet> createState() => _GrantsSheetState();
}

class _GrantsSheetState extends State<_GrantsSheet> {
  var _showForm = false;
  late Future<List<FolderGrantRow>> _grants = _load();

  Future<List<FolderGrantRow>> _load() =>
      session.api!.foldersOps.listGrants(widget.folder.id);

  void _reload() => setState(() => _grants = _load());

  Future<void> _revoke(FolderGrantRow g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销此 grant?'),
        content: Text('将撤 ${g.name ?? g.subjectId} 的'
            '${grantLevelLabel(g.level)}权限'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(foregroundColor: Tk.red),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('撤销')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await session.api!.foldersOps.removeGrant(
        widget.folder.id,
        subject: g.subject,
        level: g.level,
      );
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('撤销失败:$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: _showForm
            ? FolderGrantForm(folder: widget.folder, onDone: () {
                setState(() {
                  _showForm = false;
                  _grants = _load();
                });
              })
            : Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('授权管理 · ${widget.folder.name}',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Text(
                        '补充给特定人/组的夹级权限,与项目级取并集(恒永久)',
                        style: TextStyle(fontSize: 11.5, color: Tk.subtle)),
                    const SizedBox(height: 8),
                    Expanded(child: _grantList()),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.add_moderator_outlined,
                            size: 18),
                        label: const Text('添加授权'),
                        onPressed: () => setState(() => _showForm = true),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _grantList() {
    return FutureBuilder<List<FolderGrantRow>>(
      future: _grants,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Text('加载失败:${snap.error}',
                style: Theme.of(context).textTheme.bodySmall),
          );
        }
        final grants = snap.data ?? const <FolderGrantRow>[];
        if (grants.isEmpty) {
          return const Center(
            child: Text('还没设置 explicit grant\n该夹沿用项目级权限',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: Tk.subtle)),
          );
        }
        return ListView.separated(
          itemCount: grants.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final g = grants[i];
            return ListTile(
              visualDensity: VisualDensity.compact,
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                radius: 13,
                backgroundColor: g.kind == 'user' ? Tk.fg : Tk.border,
                child: Text(
                  g.kind == 'user'
                      ? (g.name ?? '?').isEmpty
                          ? '?'
                          : g.name!.characters.first.toUpperCase()
                      : '群',
                  style: TextStyle(
                      fontSize: 11,
                      color: g.kind == 'user' ? Tk.surface : Tk.muted),
                ),
              ),
              title: Text(g.name ?? g.subjectId,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w500)),
              subtitle: Text(grantLevelLabel(g.level),
                  style: const TextStyle(fontSize: 11, color: Tk.muted)),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: '撤销',
                onPressed: () => _revoke(g),
              ),
            );
          },
        );
      },
    );
  }
}
