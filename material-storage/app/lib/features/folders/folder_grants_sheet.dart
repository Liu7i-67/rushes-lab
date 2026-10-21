/// FolderGrantsSheet — 普通一级夹 explicit grant 管理(B6 §8.4;web
/// FolderGrantsPanel 移动版):grants 列表 + 添加(SubjectPicker + 多 level
/// viewer/downloader/uploader chips,一次授多 level)+ 撤销。**无有效期/倒计时
/// 控件**——后端只收 levels+主体,恒永久(web 同款勿造假 UI)。入口仅普通一级夹。
/// app-polish D1:骨架迁移 SheetScaffold(标题/列表定高内滚/PrimaryXl 吸底);
/// 撤销确认统一 showAppConfirm(danger);错误收口 toast+errorMessage(E14)。
library;

export 'folder_grants_form.dart'
    show FolderGrantForm, kGrantLevels, grantLevelLabel;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/session.dart';
import 'folder_grants_form.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/buttons.dart';
import '../../widgets/sheet_scaffold.dart';
import '../../widgets/toast.dart';

/// 打开普通一级夹授权管理面板(对外 API 不变)。
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
    final ok = await showAppConfirm(
      context,
      title: '撤销此 grant?',
      content: '将撤 ${g.name ?? g.subjectId} 的'
          '${grantLevelLabel(g.level)}权限',
      confirmLabel: '撤销',
      danger: true,
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
      toast(context, '撤销失败:${errorMessage(e, '请稍后重试')}',
          tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SheetScaffold(
      title: '授权管理 · ${widget.folder.name}',
      maxHeightFactor: 0.75,
      bottomActions: _showForm
          ? const <Widget>[]
          : <Widget>[
              PrimaryXl(
                icon: Icons.add_moderator_outlined,
                label: '添加授权',
                onPressed: () => setState(() => _showForm = true),
              ),
            ],
      child: _showForm
          ? FolderGrantForm(folder: widget.folder, onDone: () {
              setState(() {
                _showForm = false;
                _grants = _load();
              });
            })
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    '补充给特定人/组的夹级权限,与项目级取并集(恒永久)',
                    style: TextStyle(fontSize: Tk.fzXs, color: Tk.subtle)),
                const SizedBox(height: Tk.spaceSm),
                // 列表定高内滚(外层 SheetScaffold 已管总高与吸底钮)
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.45,
                  child: _grantList(),
                ),
              ],
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
            child: Text('加载失败:${errorMessage(snap.error!, '请稍后重试')}',
                style: Theme.of(context).textTheme.bodySmall),
          );
        }
        final grants = snap.data ?? const <FolderGrantRow>[];
        if (grants.isEmpty) {
          return const Center(
            child: Text('还没设置 explicit grant\n该夹沿用项目级权限',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: Tk.fzMd, color: Tk.subtle)),
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
                      fontSize: Tk.fzXs,
                      color: g.kind == 'user' ? Tk.surface : Tk.muted),
                ),
              ),
              title: Text(g.name ?? g.subjectId,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: Tk.fzMd, fontWeight: FontWeight.w500)),
              subtitle: Text(grantLevelLabel(g.level),
                  style: const TextStyle(fontSize: Tk.fzXs, color: Tk.muted)),
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
