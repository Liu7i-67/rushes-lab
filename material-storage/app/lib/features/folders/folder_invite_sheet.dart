/// FolderInviteSheet — 敏感夹邀请管理(B6 §8.4;web FolderInvitePanel 移动版):
/// 成员列表(等级徽章 + 永久/到期)+ 撤销;邀请表单 = SubjectPicker + 等级
/// viewer/downloader + **有效期预设档位 = web DUR_OPTIONS 实况**(永久/1h/24h/
/// 7d/30d,多主体逐个 POST,部分失败计数提示)。入口仅敏感夹(folder_row)。
library;

export 'folder_invite_form.dart'
    show FolderInviteForm, kInviteDurationOptions, kInviteLevels;

import 'package:flutter/material.dart';

import '../../core/fmt.dart' show fmtIsoShort;
import '../../core/session.dart';
import 'folder_invite_form.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';

/// 打开敏感夹邀请管理面板。
Future<void> showFolderInviteSheet(
  BuildContext context, {
  required Folder folder,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _InviteSheet(folder: folder),
  );
}

class _InviteSheet extends StatefulWidget {
  const _InviteSheet({required this.folder});

  final Folder folder;

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  var _showForm = false;
  late Future<List<FolderMemberRow>> _members = _load();

  Future<List<FolderMemberRow>> _load() =>
      session.api!.foldersOps.listMembers(widget.folder.id);

  void _reload() => setState(() => _members = _load());

  Future<void> _revoke(FolderMemberRow m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销此成员邀请?'),
        content: Text('${m.name ?? m.subjectId} 将立即失去访问'),
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
      await session.api!.foldersOps.revokeInvite(
        widget.folder.id,
        subject: m.subject,
        level: m.level,
        permanent: m.permanent,
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
            ? FolderInviteForm(folder: widget.folder, onDone: () {
                setState(() {
                  _showForm = false;
                  _members = _load();
                });
              })
            : Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('邀请管理 · ${widget.folder.name}',
                        style: Theme.of(context).textTheme.titleMedium),
                    Text('敏感目录仅被邀请成员可见;邀请可设有效期',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 8),
                    Expanded(child: _memberList()),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.person_add_alt_1, size: 18),
                        label: const Text('邀请成员'),
                        onPressed: () => setState(() => _showForm = true),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _memberList() {
    return FutureBuilder<List<FolderMemberRow>>(
      future: _members,
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
        final members = snap.data ?? const <FolderMemberRow>[];
        if (members.isEmpty) {
          return const Center(
            child: Text('还没人被邀请\n点击下方「邀请成员」开始',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: Tk.subtle)),
          );
        }
        return ListView.separated(
          itemCount: members.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final m = members[i];
            return ListTile(
              visualDensity: VisualDensity.compact,
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                radius: 13,
                backgroundColor: m.kind == 'user' ? Tk.fg : Tk.border,
                child: Text(
                  m.kind == 'user'
                      ? (m.name ?? '?').isEmpty
                          ? '?'
                          : m.name!.characters.first.toUpperCase()
                      : '群',
                  style: TextStyle(
                      fontSize: 11,
                      color: m.kind == 'user' ? Tk.surface : Tk.muted),
                ),
              ),
              title: Text(m.name ?? m.subjectId,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
              subtitle: Row(children: [
                Text(m.level.toUpperCase(),
                    style: const TextStyle(
                        fontSize: 10, letterSpacing: 0.3, color: Tk.muted)),
                const SizedBox(width: 8),
                Text(
                  m.permanent
                      ? '永久'
                      : (m.expiresAt == null ? '临时' : '到期 ${fmtIsoShort(m.expiresAt!)}'),
                  style: const TextStyle(fontSize: 10.5, color: Tk.subtle),
                ),
              ]),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: '撤销',
                onPressed: () => _revoke(m),
              ),
            );
          },
        );
      },
    );
  }
}
