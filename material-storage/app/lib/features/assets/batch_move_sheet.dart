/// 批量移动 sheet:项目固定=所选资产所属项目;目标夹树缩进单选,sensitive 及
/// 其子树级联禁选,源夹仅禁自身;结果视图保留用户口径。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_row.dart';
import '../../widgets/buttons.dart';
import '../../widgets/sheet_scaffold.dart';
import '../folders/folder_tree.dart';
import 'asset_writeback.dart';
import 'batch_move_result.dart';

const batchMoveLimit = 1000;
String? batchMoveBlockReason({
  required Set<String> projectIds,
  required int selectedCount,
}) {
  if (projectIds.length > 1) return '所选文件属于多个项目,一期仅支持同一项目内批量移动';
  if (selectedCount > batchMoveLimit) {
    return '单次最多移动 $batchMoveLimit 个文件,请减少选中后重试';
  }
  return null;
}

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
      final parent = p == null ? null : ids[p];
      if (parent == null) break; // 断链防御:不误禁
      cur = parent;
    }
  }
  return out;
}

Future<bool> showBatchMoveSheet(
  BuildContext context, {
  required List<String> selectedIds,
  required String sourceFolderId,
  required String projectId,
  required String projectLabel,
  Map<String, String>? assetNames,
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
      assetNames: assetNames,
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
    this.assetNames,
  });
  final List<String> selectedIds;
  final String sourceFolderId;
  final String projectId;
  final String projectLabel;
  final Map<String, String>? assetNames;
  @override
  State<_BatchMoveSheet> createState() => _BatchMoveSheetState();
}

class _BatchMoveSheetState extends State<_BatchMoveSheet> {
  String? _targetId;
  String? _targetName;
  AssetBatchMoveResult? _result;
  var _submitting = false;
  String? _error;
  late Future<List<Folder>> _foldersFuture = _load();
  Future<List<Folder>> _load() => session.api!.folders.list(widget.projectId);
  String? get _blocked => batchMoveBlockReason(
    projectIds: {widget.projectId},
    selectedCount: widget.selectedIds.length,
  );
  Future<void> _submit() async {
    final target = _targetId;
    if (target == null || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final r = await session.api!.ops.batchMove(
        widget.selectedIds,
        targetFolderId: target,
      );
      if (r.movedCount > 0) notifyAssetMutation(widget.sourceFolderId);
      if (!mounted) return;
      setState(() {
        _result = r;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = errorMessage(e, '批量移动失败,请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return SheetScaffold(
      title: result != null ? '批量移动结果' : '移动 ${widget.selectedIds.length} 个文件',
      errorText: _error,
      maxHeightFactor: 0.75,
      bottomActions: [
        PrimaryXl(
          onPressed: result != null
              ? () => Navigator.of(context).pop(result.movedCount > 0)
              : _targetId != null && !_submitting && _blocked == null
              ? _submit
              : null,
          label: result != null ? '完成' : (_submitting ? '移动中…' : '移动'),
        ),
      ],
      child: result != null
          ? BatchMoveResultView(
              result: result,
              submitted: widget.selectedIds.length,
              assetNames: widget.assetNames,
            )
          : _picker(context),
    );
  }

  Widget _picker(BuildContext context) {
    final tk = context.tk;
    final block = _blocked;
    final style = TextStyle(fontSize: Tk.fzMd, color: tk.ink2);
    final hint = TextStyle(fontSize: Tk.fzMd, color: tk.ink3);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('目标项目:${widget.projectLabel}(一期仅支持项目内移动)', style: style),
        if (block != null)
          Text(
            block,
            style: TextStyle(fontSize: Tk.fzSm, color: tk.danger),
          ),
        const SizedBox(height: Tk.spaceMd),
        Text('移动到哪个目录(敏感目录及其子目录不可选)', style: hint),
        const SizedBox(height: Tk.spaceSm),
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.42,
          child: _folderList(),
        ),
        const SizedBox(height: Tk.spaceSm),
        Text(
          '已选目标:${_targetName != null ? '目录「$_targetName」' : '未选择'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ],
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
                  style: Theme.of(context).textTheme.bodySmall,
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
        final cascade = sensitiveCascadeIds(folders);
        final rows = <(FolderNode, int)>[];
        void walk(List<FolderNode> nodes, int depth) {
          for (final n in nodes) {
            rows.add((n, depth));
            walk(n.children, depth + 1);
          }
        }

        walk(buildFolderTree(folders), 0);
        final tk = context.tk;
        return AppCard(
          padding: EdgeInsets.zero,
          child: ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => Divider(height: 1, color: tk.line),
            itemBuilder: (context, i) {
              final (node, depth) = rows[i];
              final f = node.folder;
              final disabled =
                  cascade.contains(f.id) || f.id == widget.sourceFolderId;
              final selected = f.id == _targetId;
              final row = AppRow(
                leading: Icon(
                  f.isSensitive
                      ? Icons.folder_special_outlined
                      : Icons.folder_outlined,
                ),
                title: f.name,
                subtitle: disabled ? '不可选' : null,
                showChevron: false,
                onTap: disabled
                    ? null
                    : () => setState(() {
                        _targetId = f.id;
                        _targetName = f.name;
                      }),
                trailing: selected
                    ? Icon(Icons.check, color: tk.goldInk)
                    : null,
              );
              return Padding(
                padding: EdgeInsets.only(left: depth * 16.0),
                child: Opacity(opacity: disabled ? 0.45 : 1, child: row),
              );
            },
          ),
        );
      },
    );
  }
}
