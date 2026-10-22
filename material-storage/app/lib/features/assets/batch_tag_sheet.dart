/// 打标/改标 bottom sheet(B5 功能点 1「⋯ 批量打标」+ 功能点 3「详情打标」):
/// - 批量(操作栏 ⋯):merge/replace 显式选择(默认 merge=web 批量实况
///   BulkTagModal 硬编码 merge),逐 id PATCH;user_labels ≤50 前端明示校验
///   (后端 _normalize_labels 静默截断,web 不提示,App 增强);notes 留空=不改。
/// - 单条(预览页元数据卡「编辑」=AssetTagEditor 移动版):**不传 labels_mode**
///   (后端默认 replace,web 单条实况);无变化不提交;返回更新后 Asset 供回填。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../theme/tokens.dart';
import '../../widgets/toast.dart';
import 'asset_writeback.dart';

/// 标签解析:逗号/、/换行分隔 → trim → 去空 → 去重(保序;web tags 输入同口径)。
List<String> parseLabels(String raw) {
  final out = <String>[];
  for (final part in raw.split(RegExp('[,，、\n]'))) {
    final s = part.trim();
    if (s.isNotEmpty && !out.contains(s)) out.add(s);
  }
  return out;
}

/// 上限校验(≤50):null=合法。批量空标签由「提交」禁用态表达(web 同口径),
/// 不走此函数。
String? tagLabelsError(List<String> labels) {
  if (labels.length > 50) return '最多 50 个标签(当前 ${labels.length} 个)';
  return null;
}

bool _listEq(List<String> a, List<String> b) =>
    a.length == b.length && List.generate(a.length, (i) => a[i] == b[i]).every((e) => e);

/// 单条编辑(预览页):返回更新后 Asset(无变化/失败 = null)。
Future<Asset?> showTagEditSheet(BuildContext context,
    {required Asset asset, required String folderId}) {
  return showModalBottomSheet<Asset>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetCtx) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
      child: _TagEditSheet(
        folderId: folderId,
        batch: false,
        initialLabels: asset.userLabels,
        initialNotes: asset.notes ?? '',
        assetIds: [asset.id],
      ),
    ),
  );
}

/// 批量打标(操作栏 ⋯):返回是否有任一成功(调用方据此清选中态)。
Future<bool> showBatchTagSheet(BuildContext context,
    {required List<String> assetIds, required String folderId}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetCtx) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
      child: _TagEditSheet(
        folderId: folderId,
        batch: true,
        assetIds: assetIds,
      ),
    ),
  );
  return ok ?? false;
}

class _TagEditSheet extends StatefulWidget {
  const _TagEditSheet({
    required this.folderId,
    required this.batch,
    required this.assetIds,
    this.initialLabels = const [],
    this.initialNotes = '',
  });

  final String folderId;
  final bool batch;
  final List<String> assetIds;
  final List<String> initialLabels;
  final String initialNotes;

  @override
  State<_TagEditSheet> createState() => _TagEditSheetState();
}

class _TagEditSheetState extends State<_TagEditSheet> {
  late final TextEditingController _labels = TextEditingController(
      text: widget.initialLabels.join(', '));
  late final TextEditingController _notes =
      TextEditingController(text: widget.initialNotes);
  String _mode = 'merge'; // 批量默认 merge(web 实况)
  var _submitting = false;

  @override
  void dispose() {
    _labels.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final labels = parseLabels(_labels.text);
    if (tagLabelsError(labels) != null) return;
    if (widget.batch && labels.isEmpty) return;
    setState(() => _submitting = true);
    final notesText = _notes.text.trim();
    try {
      if (!widget.batch) {
        final labelsChanged = !_listEq(labels, widget.initialLabels);
        final notesChanged = notesText != widget.initialNotes.trim();
        if (!labelsChanged && !notesChanged) {
          Navigator.of(context).pop(); // 无变化不提交(web 实况)
          return;
        }
        final updated = await session.api!.ops.updateMeta(widget.assetIds.first,
            userLabels: labelsChanged ? labels : null,
            notes: notesChanged ? notesText : null);
        notifyAssetMutation(widget.folderId);
        if (!mounted) return;
        Navigator.of(context).pop(updated);
        return;
      }
      var ok = 0;
      var fail = 0;
      for (final id in widget.assetIds) {
        try {
          await session.api!.ops.updateMeta(id,
              userLabels: labels,
              notes: notesText.isEmpty ? null : notesText,
              labelsMode: _mode);
          ok++;
        } catch (e) {
          fail++;
          AppLog.error('tag', '打标失败 $id', e);
        }
      }
      if (ok > 0) notifyAssetMutation(widget.folderId);
      if (!mounted) return;
      Navigator.of(context).pop(ok > 0);
      toast(context, '已为 $ok 个文件打标${fail > 0 ? ' · 失败 $fail' : ''}',
          tone: fail > 0 ? ToastTone.error : ToastTone.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      toast(context, errorMessage(e, '标签保存失败,请稍后重试'),
          tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = parseLabels(_labels.text);
    final err = tagLabelsError(labels);
    final batchEmpty = widget.batch && labels.isEmpty;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        // 标签多时 chips 撑高(≤50):内容可滚,防小屏 RenderFlex overflow
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.batch ? '批量打标(${widget.assetIds.length} 个文件)' : '编辑标签与备注',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Tk.spaceXs),
          Text(
              widget.batch
                  ? '给选中文件统一打标;输入后逗号分隔,多个标签。'
                  : '逗号分隔多个标签;备注留空保存即清空。',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: Tk.spaceMd),
          TextField(
            controller: _labels,
            autofocus: true,
            decoration: InputDecoration(
              labelText: '标签(逗号分隔)',
              errorText: err,
              helperText: batchEmpty ? '先输入至少一个标签' : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (labels.isNotEmpty) ...[
            const SizedBox(height: Tk.spaceSm),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final l in labels) Chip(label: Text(l), visualDensity: VisualDensity.compact),
            ]),
          ],
          const SizedBox(height: Tk.spaceMd),
          TextField(
            controller: _notes,
            decoration: InputDecoration(
                labelText: '备注',
                hintText: widget.batch ? '留空 = 不改备注' : null),
            minLines: 1,
            maxLines: 3,
          ),
          if (widget.batch) ...[
            const SizedBox(height: Tk.spaceMd),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'merge', label: Text('合并已有标签')),
                ButtonSegment(value: 'replace', label: Text('替换已有标签')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ],
          const SizedBox(height: Tk.spaceLg),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _submitting || err != null || batchEmpty ? null : _submit,
              child: Text(_submitting ? '提交中…' : (widget.batch ? '打标' : '保存')),
            ),
          ),
        ]),
        ),
      ),
    );
  }
}
