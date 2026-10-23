/// FolderInviteSheet — 敏感夹邀请管理(B6 §8.4;F7 统一墨色 + 金色):
/// 成员列表(等级 + 永久/到期)+ 撤销;邀请表单 = SubjectPicker + 等级
/// viewer/downloader + 有效期预设(web DUR_OPTIONS 实况,多主体逐个 POST)。
/// 入口仅敏感夹(folder_row)。SheetScaffold 吸底金主按钮;撤销确认统一
/// showAppConfirm(danger);错误收口 toast+errorMessage。
library;

export 'folder_invite_form.dart'
    show FolderInviteForm, kInviteDurationOptions, kInviteLevels;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/fmt.dart' show fmtIsoShort;
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/app_row.dart';
import '../../widgets/buttons.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/sheet_scaffold.dart';
import '../../widgets/toast.dart';
import 'folder_invite_form.dart';

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
      if (!mounted) return;
      _reload();
    } catch (e) {
      if (!mounted) return;
      toast(context, '撤销失败:${errorMessage(e, '请稍后重试')}', tone: ToastTone.error);
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
          ? FolderInviteForm(
              folder: widget.folder,
              onDone: () {
                setState(() {
                  _showForm = false;
                  _members = _load();
                });
              },
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '敏感目录仅被邀请成员可见;邀请可设有效期',
                  style: TextStyle(fontSize: Tk.fzMd, color: context.tk.ink3),
                ),
                const SizedBox(height: Tk.spaceSm),
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
            child: Text(
              '加载失败:${errorMessage(snap.error!, '请稍后重试')}',
              style: TextStyle(fontSize: Tk.fzMd, color: context.tk.ink3),
            ),
          );
        }
        final members = snap.data ?? const <FolderMemberRow>[];
        if (members.isEmpty) {
          return const EmptyState(
            icon: Icons.mail_outline,
            message: '还没人被邀请',
            description: '点击下方「邀请成员」开始',
          );
        }
        return ListView.separated(
          itemCount: members.length,
          separatorBuilder: (_, _) =>
              Divider(height: 1, thickness: 1, color: context.tk.line),
          itemBuilder: (context, i) {
            final m = members[i];
            final expiry = m.permanent
                ? '永久'
                : (m.expiresAt == null
                      ? '临时'
                      : '到期 ${fmtIsoShort(m.expiresAt!)}');
            return AppRow(
              leading: _Avatar(name: m.name, kind: m.kind),
              title: m.name ?? m.subjectId,
              subtitle: '${m.level.toUpperCase()} · $expiry',
              showChevron: false,
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                color: context.tk.danger,
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

/// 用户/用户组首字头像(goldSoft 底 + goldInk 字)。
class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.kind});

  final String? name;
  final String kind;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final user = kind == 'user';
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: user ? tk.goldSoft : tk.surface3,
        shape: BoxShape.circle,
      ),
      child: Text(
        user
            ? ((name ?? '').isEmpty
                  ? '?'
                  : name!.characters.first.toUpperCase())
            : '群',
        style: TextStyle(
          fontSize: Tk.fzXs,
          fontWeight: FontWeight.w600,
          color: user ? tk.goldInk : tk.ink2,
        ),
      ),
    );
  }
}
