/// 批量移动 bottom sheet(B5 功能点 1「移动」,对标 web BatchMoveAssetsModal 一期):
/// 项目固定=所选资产所属项目(一期项目内,后端断言整批同项目+目标夹同项目,
/// 混批 400);目标夹=当前项目夹列表树缩进单选,sensitive 及其子树级联禁选
/// (web disabledSet 级联源),源夹仅禁自身不级联(A 夹文件可移入 A 子夹);
/// 结果视图对账 moved+skipped+fga_pending=提交数。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../folders/folder_tree.dart';
import 'asset_writeback.dart';

/// 单批上限(后端 asset_ids ≤1000)。
const batchMoveLimit = 1000;

/// 整批禁用原因(混批多项目整批禁用+上限;null=可提交)。B5 钉子:
/// 混批提示文案与后端 400 detail 同口径。
String? batchMoveBlockReason(
    {required Set<String> projectIds, required int selectedCount}) {
  if (projectIds.length > 1) {
    return '所选文件属于多个项目,一期仅支持同一项目内批量移动';
  }
  if (selectedCount > batchMoveLimit) {
    return '单次最多移动 $batchMoveLimit 个文件,请减少选中后重试';
  }
  return null;
}

/// sensitive 及其子树全 id(级联禁选源;web FolderTree buildTree
/// ancestorDisabled 同口径:disabledSet 命中即整棵子树禁)。
Set<String> sensitiveCascadeIds(List<Folder> folders) {
  final ids = {for (final f in folders) f.id: f};
  final out = <String>{};
  for (final f in folders) {
    var cur = f;
    while (true) {
      if (cur.isSensitive) {
        out.add(f.id);
        break;
      }
      final p = cur.parentFolderId;
      if (p == null) break;
      final parent = ids[p];
      if (parent == null) break; // 断链防御:不误禁
      cur = parent;
    }
  }
  return out;
}

/// 打开批量移动面板;返回是否发生了移动(调用方据此清选中态)。
Future<bool> showBatchMoveSheet(
  BuildContext context, {
  required List<String> selectedIds,
  required String sourceFolderId,
  required String projectId,
  required String projectLabel,
}) async {
  final moved = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _BatchMoveSheet(
      selectedIds: selectedIds,
      sourceFolderId: sourceFolderId,
      projectId: projectId,
      projectLabel: projectLabel,
    ),
  );
  return moved ?? false;
}

class _BatchMoveSheet extends StatefulWidget {
  const _BatchMoveSheet({
    required this.selectedIds,
    required this.sourceFolderId,
    required this.projectId,
    required this.projectLabel,
  });

  final List<String> selectedIds;
  final String sourceFolderId;
  final String projectId;
  final String projectLabel;

  @override
  State<_BatchMoveSheet> createState() => _BatchMoveSheetState();
}

class _BatchMoveSheetState extends State<_BatchMoveSheet> {
  String? _targetId;
  String? _targetName;
  AssetBatchMoveResult? _result;
  var _submitting = false;
  late Future<List<Folder>> _foldersFuture = _load();

  Future<List<Folder>> _load() => session.api!.folders.list(widget.projectId);

  Future<void> _submit() async {
    final target = _targetId;
    if (target == null || _submitting) return;
    setState(() => _submitting = true);
    try {
      final r = await session.api!.ops.batchMove(widget.selectedIds, targetFolderId: target);
      if (r.movedCount > 0) notifyAssetMutation(widget.sourceFolderId);
      if (!mounted) return;
      setState(() {
        _result = r;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('批量移动失败:$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: _result != null
            ? _ResultView(result: _result!, submitted: widget.selectedIds.length)
            : _picker(context),
      ),
    );
  }

  Widget _picker(BuildContext context) {
    final block = batchMoveBlockReason(
        projectIds: {widget.projectId}, selectedCount: widget.selectedIds.length);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('移动 ${widget.selectedIds.length} 个文件',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text('目标项目:${widget.projectLabel}(一期仅支持项目内移动)',
            style: Theme.of(context).textTheme.bodySmall),
        if (block != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(block,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error, fontSize: 12)),
          ),
        const SizedBox(height: 8),
        Text('移动到哪个目录(敏感目录及其子目录不可选)',
            style: Theme.of(context).textTheme.bodySmall),
        Expanded(child: _folderList()),
        Text('已选目标:${_targetName != null ? '目录「$_targetName」' : '未选择'}',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: block != null || _targetId == null || _submitting
                ? null
                : _submit,
            child: Text(_submitting ? '移动中…' : '移动'),
          ),
        ),
      ]),
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
              TextButton(onPressed: () {
                setState(() => _foldersFuture = _load());
              }, child: const Text('重试')),
            ]),
          );
        }
        final folders = snap.data ?? const <Folder>[];
        final cascade = sensitiveCascadeIds(folders);
        final rows = <(FolderNode, int)>[];
        void walk(List<FolderNode> nodes, int depth) {
          for (final n in nodes) {
            rows.add((n, depth));
            walk(n.children, depth + 1);
          }
        }

        walk(buildFolderTree(folders), 0);
        return ListView.builder(
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final (node, depth) = rows[i];
            final f = node.folder;
            final disabled = cascade.contains(f.id) ||
                f.id == widget.sourceFolderId;
            final selected = f.id == _targetId;
            return ListTile(
              visualDensity: VisualDensity.compact,
              contentPadding: EdgeInsets.only(left: 8.0 + depth * 16, right: 8),
              leading: Icon(
                f.isSensitive ? Icons.folder_special_outlined : Icons.folder_outlined,
                size: 20,
                color: disabled ? Theme.of(context).disabledColor : null,
              ),
              title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              enabled: !disabled,
              selected: selected,
              trailing: selected ? const Icon(Icons.check) : null,
              onTap: disabled ? null : () => setState(() {
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

class _ResultView extends StatelessWidget {
  const _ResultView({required this.result, required this.submitted});

  final AssetBatchMoveResult result;
  final int submitted;

  @override
  Widget build(BuildContext context) {
    final pending = result.fgaPending.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('批量移动结果', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          result.movedCount == 0
              ? '本次未移动任何文件(共提交 $submitted 个)'
              : '成功移动 ${result.movedCount} 个文件(共提交 $submitted 个)',
        ),
        Text('对账:成功 ${result.movedCount} + 跳过 ${result.skipped.length}'
            '${pending > 0 ? ' + 待同步 $pending' : ''} = $submitted',
            style: Theme.of(context).textTheme.bodySmall),
        if (result.skipped.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final s in result.skipped.take(20))
            Text('· ${s.assetId} — ${AssetBatchMoveSkip.reasonLabel(s.reason)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
        ],
        if (pending > 0) ...[
          const SizedBox(height: 8),
          Text('权限同步待完成 $pending 个:文件已移动,系统将自动重试修复。',
              style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(result.movedCount > 0),
            child: const Text('完成'),
          ),
        ),
      ]),
    );
  }
}
