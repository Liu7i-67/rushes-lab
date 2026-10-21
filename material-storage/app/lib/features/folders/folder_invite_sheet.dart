/// FolderInviteSheet — 敏感夹邀请管理(B6 §8.4;web FolderInvitePanel 移动版):
/// 成员列表(等级徽章 + 永久/到期)+ 撤销;邀请表单 = SubjectPicker + 等级
/// viewer/downloader + **有效期预设档位 = web DUR_OPTIONS 实况**(永久/1h/24h/
/// 7d/30d,多主体逐个 POST,部分失败计数提示)。入口仅敏感夹(folder_row)。
/// app-polish D1:骨架迁移 SheetScaffold(标题/列表定高内滚/PrimaryXl 吸底);
/// 撤销确认统一 showAppConfirm(danger);错误收口 toast+errorMessage(E14)。
library;

export 'folder_invite_form.dart'
    show FolderInviteForm, kInviteDurationOptions, kInviteLevels;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/fmt.dart' show fmtIsoShort;
import '../../core/session.dart';
import 'folder_invite_form.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/buttons.dart';
import '../../widgets/sheet_scaffold.dart';
import '../../widgets/toast.dart';

/// 打开敏感夹邀请管理面板(对外 API 不变)。
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
    final ok = await showAppConfirm(
      context,
      title: '撤销此成员邀请?',
      content: '${m.name ?? m.subjectId} 将立即失去访问',
      confirmLabel: '撤销',
      danger: true,
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
      toast(context, '撤销失败:${errorMessage(e, '请稍后重试')}',
          tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SheetScaffold(
      title: '邀请管理 · ${widget.folder.name}',
      maxHeightFactor: 0.75,
      bottomActions: _showForm
          ? const <Widget>[]
          : <Widget>[
              PrimaryXl(
                icon: Icons.person_add_alt_1,
                label: '邀请成员',
                onPressed: () => setState(() => _showForm = true),
              ),
            ],
      child: _showForm
          ? FolderInviteForm(folder: widget.folder, onDone: () {
              setState(() {
                _showForm = false;
                _members = _load();
              });
            })
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('敏感目录仅被邀请成员可见;邀请可设有效期',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: Tk.spaceSm),
                // 列表定高内滚(外层 SheetScaffold 已管总高与吸底钮)
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.45,
                  child: _memberList(),
                ),
              ],
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
            child: Text('加载失败:${errorMessage(snap.error!, '请稍后重试')}',
                style: Theme.of(context).textTheme.bodySmall),
          );
        }
        final members = snap.data ?? const <FolderMemberRow>[];
        if (members.isEmpty) {
          return const Center(
            child: Text('还没人被邀请\n点击下方「邀请成员」开始',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: Tk.fzMd, color: Tk.subtle)),
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
                      fontSize: Tk.fzXs,
                      color: m.kind == 'user' ? Tk.surface : Tk.muted),
                ),
              ),
              title: Text(m.name ?? m.subjectId,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: Tk.fzMd, fontWeight: FontWeight.w500)),
              subtitle: Row(children: [
                Text(m.level.toUpperCase(),
                    style: const TextStyle(
                        fontSize: Tk.fzXs,
                        letterSpacing: 0.3,
                        color: Tk.muted)),
                const SizedBox(width: Tk.spaceSm),
                Text(
                  m.permanent
                      ? '永久'
                      : (m.expiresAt == null ? '临时' : '到期 ${fmtIsoShort(m.expiresAt!)}'),
                  style: const TextStyle(fontSize: Tk.fzXs, color: Tk.subtle),
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
