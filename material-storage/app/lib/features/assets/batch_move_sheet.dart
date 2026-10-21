/// 批量移动 bottom sheet(B5 功能点 1「移动」,对标 web BatchMoveAssetsModal 一期):
/// 项目固定=所选资产所属项目(一期项目内,后端断言整批同项目+目标夹同项目,
/// 混批 400);目标夹=当前项目夹列表树缩进单选,sensitive 及其子树级联禁选
/// (web disabledSet 级联源),源夹仅禁自身不级联(A 夹文件可移入 A 子夹);
/// 结果视图主行为用户口径(恒等式 moved+skipped+fga_pending=提交数仅在
/// 文案内体现,不再单独渲染工程「对账:成功 x + 跳过 y」行——测试报告
/// P1-D5:该行工程师口径残留,信息已并入主行,删除;待同步细节单独一行)。
/// app-polish D5:部分成功文案改用户口径「已移动 x 项,y 项跳过(共提交 n 个)」;
/// 跳过清单按原因分组、显示文件名(经可选 [showBatchMoveSheet] assetNames
/// 入参传入 id→文件名映射;未传/缺名兜底截断 id 并注明);提交错误收口
/// SheetScaffold errorText 位(errorMessage 兜底);加载逻辑不动。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/sheet_scaffold.dart';
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

/// 跳过行显示名(D5):文件名映射命中显示文件名;未传/缺名兜底截断 id 并注明
/// (纯函数可单测)。
String batchMoveSkipLabel(String assetId, Map<String, String>? assetNames) {
  final name = assetNames?[assetId];
  if (name != null && name.isNotEmpty) return name;
  final short = assetId.length > 12 ? '${assetId.substring(0, 12)}…' : assetId;
  return '$short(未取得文件名)';
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
/// [assetNames] 可选 id→文件名映射(D5 跳过行显示文件名;调用方持选中资产
/// 对象时传入,缺省兜底截断 id)。既有调用零改动。
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

  Future<void> _submit() async {
    final target = _targetId;
    if (target == null || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
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
      setState(() {
        _submitting = false;
        // D5 错误收口:errorText 位(ApiException detail 透传,余下中文兜底)
        _error = errorMessage(e, '批量移动失败,请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return SheetScaffold(
      title: result != null
          ? '批量移动结果'
          : '移动 ${widget.selectedIds.length} 个文件',
      errorText: _error,
      maxHeightFactor: 0.75,
      bottomActions: <Widget>[
        if (result != null)
          PrimaryXl(
            onPressed: () =>
                Navigator.of(context).pop(result.movedCount > 0),
            label: '完成',
          )
        else
          PrimaryXl(
            onPressed: _targetId != null &&
                    !_submitting &&
                    batchMoveBlockReason(
                            projectIds: {widget.projectId},
                            selectedCount: widget.selectedIds.length) ==
                        null
                ? _submit
                : null,
            label: _submitting ? '移动中…' : '移动',
          ),
      ],
      child: result != null
          ? _ResultView(
              result: result,
              submitted: widget.selectedIds.length,
              assetNames: widget.assetNames)
          : _picker(context),
    );
  }

  Widget _picker(BuildContext context) {
    final block = batchMoveBlockReason(
        projectIds: {widget.projectId}, selectedCount: widget.selectedIds.length);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('目标项目:${widget.projectLabel}(一期仅支持项目内移动)',
            style: Theme.of(context).textTheme.bodySmall),
        if (block != null)
          Padding(
            padding: const EdgeInsets.only(top: Tk.spaceXs),
            child: Text(block,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: Tk.fzSm)),
          ),
        const SizedBox(height: Tk.spaceSm),
        Text('移动到哪个目录(敏感目录及其子目录不可选)',
            style: Theme.of(context).textTheme.bodySmall),
        // 夹树定高内滚(外层 SheetScaffold 已管总高;夹多时此处自滚)
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.42,
          child: _folderList(),
        ),
        Text('已选目标:${_targetName != null ? '目录「$_targetName」' : '未选择'}',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: Tk.spaceSm),
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
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('目录加载失败:${errorMessage(snap.error!, '请下拉重试')}',
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
              contentPadding: EdgeInsets.only(left: Tk.spaceSm + depth * 16, right: Tk.spaceSm),
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
  const _ResultView({
    required this.result,
    required this.submitted,
    this.assetNames,
  });

  final AssetBatchMoveResult result;
  final int submitted;
  final Map<String, String>? assetNames;

  @override
  Widget build(BuildContext context) {
    final pending = result.fgaPending.length;
    final skipped = result.skipped;
    // D5 主行用户口径:全成/全跳沿用既有文案(既有用例钉住),部分成功改
    // 「已移动 x 项,y 项跳过」
    final headline = result.movedCount == 0
        ? '本次未移动任何文件(共提交 $submitted 个)'
        : skipped.isEmpty
            ? '成功移动 ${result.movedCount} 个文件(共提交 $submitted 个)'
            : '已移动 ${result.movedCount} 项,${skipped.length} 项跳过'
                '(共提交 $submitted 个)';
    // D5 跳过按原因分组(计数并列在组头,行=文件名)
    final groups = <String, List<AssetBatchMoveSkip>>{};
    for (final s in skipped) {
      groups.putIfAbsent(s.reason, () => []).add(s);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(headline),
        // P1-D5:工程口径「对账:成功 x + 跳过 y(待同步 z)= n」行删除——
        // moved/跳过数已并入主行,待同步数由下方 pending 行单独承载
        if (skipped.isNotEmpty) ...[
          const SizedBox(height: Tk.spaceSm),
          for (final entry in groups.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: Tk.spaceXs, bottom: Tk.spaceXs / 2),
              child: Text(
                  '${AssetBatchMoveSkip.reasonLabel(entry.key)} ${entry.value.length} 项',
                  style: const TextStyle(
                      fontSize: Tk.fzSm, fontWeight: FontWeight.w600)),
            ),
            for (final s in entry.value.take(20))
              Text('· ${batchMoveSkipLabel(s.assetId, assetNames)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
        if (pending > 0) ...[
          const SizedBox(height: Tk.spaceSm),
          Text('权限同步待完成 $pending 个:文件已移动,系统将自动重试修复。',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }
}
