/// MoveFolderSheet — 文件夹移动选择器(B6 §8.4;F7 统一墨色 + 金色):
/// 目标=项目根(移为一级)+ 项目内夹树;sensitive 及其子树级联禁选(目标侧
/// 后端 400);源自身及其子树整支禁选(防环)。提交 PATCH
/// parent_folder_id(null=项目一级);409/400 detail 透传。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_row.dart';
import '../../widgets/buttons.dart';
import '../../widgets/sheet_scaffold.dart';
import '../assets/batch_move_sheet.dart' show sensitiveCascadeIds;
import 'folder_tree.dart';

/// 打开移动面板;返回是否成功移动。
Future<bool> showMoveFolderSheet(
  BuildContext context, {
  required Folder folder,
  required String projectId,
  String? projectLabel,
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _MoveFolderSheet(
      folder: folder,
      projectId: projectId,
      projectLabel: projectLabel ?? '',
    ),
  );
  return ok ?? false;
}

/// 禁选目标 id 集 = 源自身 + 源子树 + sensitive 级联(web canMove 实况:
/// sensitive 源一律禁移动 → 调用方闸门拦;此处兜底含源)。纯函数可单测。
Set<String> moveTargetBlockIds(List<Folder> folders, String sourceId) {
  final byId = {for (final f in folders) f.id: f};
  final children = <String?, List<String>>{};
  for (final f in folders) {
    children.putIfAbsent(f.parentFolderId, () => []).add(f.id);
  }
  final blocked = <String>{sourceId};
  final stack = [sourceId];
  while (stack.isNotEmpty) {
    final cur = stack.removeLast();
    for (final c in children[cur] ?? const <String>[]) {
      if (blocked.add(c)) stack.add(c);
    }
  }
  return blocked.union(sensitiveCascadeIds(byId.values.toList()));
}

class _MoveFolderSheet extends StatefulWidget {
  const _MoveFolderSheet({
    required this.folder,
    required this.projectId,
    required this.projectLabel,
  });

  final Folder folder;
  final String projectId;
  final String projectLabel;

  @override
  State<_MoveFolderSheet> createState() => _MoveFolderSheetState();
}

class _MoveFolderSheetState extends State<_MoveFolderSheet> {
  String? _targetId; // null = 项目根(一级)
  String? _targetName;
  var _submitting = false;
  String? _error;
  late Future<List<Folder>> _foldersFuture = _load();

  Future<List<Folder>> _load() => session.api!.folders.list(widget.projectId);

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await session.api!.foldersOps.move(
        widget.folder.id,
        parentFolderId: _targetId,
      );
      RefreshBus.I.invalidate('folders');
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = errorMessage(e, '移动失败,请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return SheetScaffold(
      title: '移动「${widget.folder.name}」',
      errorText: _error,
      maxHeightFactor: 0.75,
      bottomActions: [
        PrimaryXl(
          onPressed: _targetName == null || _submitting ? null : _submit,
          label: _submitting ? '移动中…' : '移动',
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '目标项目:${widget.projectLabel}(移动限同项目内)',
            style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
          ),
          if (widget.folder.isSensitive)
            Padding(
              padding: const EdgeInsets.only(top: Tk.spaceXs),
              child: Text(
                '敏感文件夹只能直挂项目一级,不支持移动',
                style: TextStyle(fontSize: Tk.fzMd, color: tk.danger),
              ),
            ),
          const SizedBox(height: Tk.spaceSm),
          Text(
            '移动到哪个目录(自身及其子夹、敏感目录不可选)',
            style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
          ),
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.42,
            child: _folderList(),
          ),
          Text(
            '已选目标:${_targetId == null ? (_targetName == null ? '未选择' : '项目根(一级)') : '目录「$_targetName」'}',
            style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
          ),
        ],
      ),
    );
  }

  Widget _folderList() {
    return FutureBuilder<List<Folder>>(
      future: _foldersFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '目录加载失败:${errorMessage(snap.error!, '请下拉重试')}',
                  style: TextStyle(fontSize: Tk.fzMd, color: context.tk.ink3),
                ),
                TextButton(
                  onPressed: () => setState(() => _foldersFuture = _load()),
                  child: const Text('重试'),
                ),
              ],
            ),
          );
        }
        final folders = snap.data ?? const <Folder>[];
        final blocked = moveTargetBlockIds(folders, widget.folder.id);
        final rows = <(FolderNode, int)>[];
        void walk(List<FolderNode> nodes, int depth) {
          for (final n in nodes) {
            rows.add((n, depth));
            walk(n.children, depth + 1);
          }
        }

        walk(buildFolderTree(folders), 0);
        return ListView.separated(
          itemCount: rows.length + 1,
          separatorBuilder: (_, _) =>
              Divider(height: 1, thickness: 1, color: context.tk.line),
          itemBuilder: (context, i) {
            if (i == 0) {
              final selected = _targetId == null && _targetName != null;
              return AppRow(
                leading: const Icon(Icons.home_outlined),
                title: '项目根(移为一级)',
                showChevron: false,
                trailing: selected
                    ? Icon(Icons.check, size: 20, color: context.tk.gold)
                    : null,
                onTap: () => setState(() {
                  _targetId = null;
                  _targetName = '__root__';
                }),
              );
            }
            final (node, depth) = rows[i - 1];
            final f = node.folder;
            final disabled = blocked.contains(f.id);
            final selected = f.id == _targetId;
            return Padding(
              padding: EdgeInsets.only(left: depth * Tk.spaceLg.toDouble()),
              child: AppRow(
                leading: Icon(
                  f.isSensitive ? Icons.lock_outline : Icons.folder_outlined,
                  color: disabled
                      ? context.tk.ink3
                      : f.isSensitive
                      ? context.tk.goldInk
                      : context.tk.ink2,
                ),
                title: f.name,
                subtitle: disabled ? '不可选(自身/子夹/敏感目录)' : null,
                showChevron: false,
                trailing: selected
                    ? Icon(Icons.check, size: 20, color: context.tk.gold)
                    : null,
                onTap: disabled
                    ? null
                    : () => setState(() {
                        _targetId = f.id;
                        _targetName = f.name;
                      }),
              ),
            );
          },
        );
      },
    );
  }
}
