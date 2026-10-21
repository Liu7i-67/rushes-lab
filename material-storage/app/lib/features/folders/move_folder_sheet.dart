/// MoveFolderSheet — 文件夹移动选择器(B6 §8.4;web MoveFolderModal 移动版):
/// 目标=项目根(移为一级)+ 项目内夹树;sensitive 及其子树级联禁选(目标侧
/// 后端 400);源自身及其子树整支禁选(防环,需求「目标不含自身子树」)。
/// 提交 PATCH parent_folder_id(null=项目一级);409(一级夹带 explicit grant
/// 禁 reparent 等)/400 detail 透传。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
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
        projectLabel: projectLabel ?? ''),
  );
  return ok ?? false;
}

/// 禁选目标 id 集 = 源自身 + 源子树 + sensitive 级联(web canMove 实况:
/// sensitive 源一律禁移动 → 调用方闸门拦;此处兜底含源)。纯函数可单测。
Set<String> moveTargetBlockIds(List<Folder> folders, String sourceId) {
  final byId = {for (final f in folders) f.id: f};
  // 源子树:自源向下收集后代(parentFolderId 可空,统一按 String? 键分桶)
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
      await session.api!.foldersOps
          .move(widget.folder.id, parentFolderId: _targetId);
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
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('移动「${widget.folder.name}」',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('目标项目:${widget.projectLabel}(移动限同项目内)',
                  style: Theme.of(context).textTheme.bodySmall),
              if (widget.folder.isSensitive)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('敏感文件夹只能直挂项目一级,不支持移动',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12)),
                ),
              const SizedBox(height: 8),
              Text('移动到哪个目录(自身及其子夹、敏感目录不可选)',
                  style: Theme.of(context).textTheme.bodySmall),
              Expanded(child: _folderList()),
              Text(
                  '已选目标:${_targetId == null ? (_targetName == null ? '未选择' : '项目根(一级)') : '目录「$_targetName」'}',
                  style: Theme.of(context).textTheme.bodySmall),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12)),
                ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed:
                      _targetName == null || _submitting ? null : _submit,
                  child: Text(_submitting ? '移动中…' : '移动'),
                ),
              ),
            ],
          ),
        ),
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
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('目录加载失败:${snap.error}',
                  style: Theme.of(context).textTheme.bodySmall),
              TextButton(
                onPressed: () => setState(() => _foldersFuture = _load()),
                child: const Text('重试'),
              ),
            ]),
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
        return ListView.builder(
          itemCount: rows.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              // 项目根选项(null parent = 移为一级)
              final selected = _targetId == null && _targetName != null;
              return ListTile(
                visualDensity: VisualDensity.compact,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: const Icon(Icons.home_outlined, size: 20),
                title: const Text('项目根(移为一级)',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                selected: selected,
                trailing: selected ? const Icon(Icons.check) : null,
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
            return ListTile(
              visualDensity: VisualDensity.compact,
              contentPadding:
                  EdgeInsets.only(left: 8.0 + depth * 16, right: 8),
              leading: Icon(
                f.isSensitive
                    ? Icons.folder_special_outlined
                    : Icons.folder_outlined,
                size: 20,
                color: disabled ? Theme.of(context).disabledColor : null,
              ),
              title: Text(f.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              enabled: !disabled,
              selected: selected,
              trailing: selected ? const Icon(Icons.check) : null,
              onTap: disabled
                  ? null
                  : () => setState(() {
                        _targetId = f.id;
                        _targetName = f.name;
                      }),
            );
          },
        );
      },
    );
  }
}
