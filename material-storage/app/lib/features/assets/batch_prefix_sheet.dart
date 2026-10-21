/// 批量前缀 bottom sheet(B5 功能点 1「⋯ 批量前缀」,对标 web BatchPrefixModal):
/// action 加/去前缀 + prefix 输入(校验=web 实况:trim 非空 / 不含 "/" / ≤128);
/// 预览前 5 条(近似口径,服务端 NFC 归一为准);提交按 ≤1000/批分批顺序调用,
/// 任一批失败即中止并保留剩余 id 供重试(onSettle 回传,web 同语义)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import 'asset_writeback.dart';

/// 单批上限(后端 asset_ids ≤1000,超出 422)。
const batchPrefixLimit = 1000;

/// 前缀校验(web BatchPrefixModal prefixError 实况):null=合法。
String? prefixErrorOf(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '前缀不能为空';
  if (t.contains('/')) return '前缀不能包含 "/"';
  if (t.length > 128) return '前缀最长 128 个字符';
  return null;
}

/// 改名预览(web previewItems 同口径近似:startsWith 大小写敏感;
/// after=null 表示预计跳过,[skip] 为原因中文)。
({String before, String? after, String? skip}) previewRename(
    String filename, String prefix, String action) {
  final hit = filename.startsWith(prefix);
  if (action == 'add') {
    return hit
        ? (before: filename, after: null, skip: '已带该前缀')
        : (before: filename, after: '$prefix$filename', skip: null);
  }
  if (!hit) return (before: filename, after: null, skip: '前缀不匹配');
  final rest = filename.substring(prefix.length);
  return rest.isEmpty
      ? (before: filename, after: null, skip: '去后为空')
      : (before: filename, after: rest, skip: null);
}

/// 打开批量前缀面板。[onSettle] 提交完结回调:全部成功 → [](调用方清空选中),
/// 中途失败 → 未提交的剩余 id(web 同语义;返回 true=已全部提交)。
Future<bool> showBatchPrefixSheet(
  BuildContext context, {
  required List<Asset> assets,
  required List<String> selectedIds,
  required String folderId,
  required void Function(List<String> remainingIds) onSettle,
}) async {
  final done = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _BatchPrefixSheet(
        assets: assets,
        selectedIds: selectedIds,
        folderId: folderId,
        onSettle: onSettle),
  );
  if (done ?? false) onSettle(const []);
  return done ?? false;
}

class _BatchPrefixSheet extends StatefulWidget {
  const _BatchPrefixSheet({
    required this.assets,
    required this.selectedIds,
    required this.folderId,
    required this.onSettle,
  });

  final List<Asset> assets;
  final List<String> selectedIds;
  final String folderId;
  final void Function(List<String> remainingIds) onSettle;

  @override
  State<_BatchPrefixSheet> createState() => _BatchPrefixSheetState();
}

class _BatchPrefixSheetState extends State<_BatchPrefixSheet> {
  var _action = 'add';
  final _prefix = TextEditingController();
  var _submitting = false;

  @override
  void dispose() {
    _prefix.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final err = prefixErrorOf(_prefix.text);
    if (err != null || widget.selectedIds.isEmpty) return;
    final prefix = _prefix.text.trim();
    final ids = widget.selectedIds.toSet().toList(); // 去重兜底(web 同)
    setState(() => _submitting = true);
    var renamed = 0;
    var skipped = 0;
    final reasons = <String, int>{};
    try {
      for (var i = 0; i < ids.length; i += batchPrefixLimit) {
        final batch = ids.sublist(i, (i + batchPrefixLimit).clamp(0, ids.length));
        try {
          final r = await session.api!.ops.batchPrefix(batch, action: _action, prefix: prefix);
          renamed += r.renamed;
          skipped += r.skipped;
          r.skippedReasons.forEach((k, v) {
            if (v > 0) reasons[k] = (reasons[k] ?? 0) + v;
          });
        } on ApiException {
          // 任一批失败即中止;失败批整批未执行,剩余 id 回传保留选中(web 同语义)
          if (!mounted) return;
          setState(() => _submitting = false);
          Navigator.of(context).pop(false);
          ScaffoldMessenger.maybeOf(context)
            ?..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(
                content: Text('提交失败已中止,未提交部分保留选中,可重试')));
          widget.onSettle(ids.sublist(i));
          return;
        }
      }
      final reasonText = reasons.entries
          .map((e) =>
              '${AssetBatchPrefixResult.reasonLabel(e.key)} ${e.value}')
          .join(' · ');
      AppLog.info('prefix',
          'renamed=$renamed skipped=$skipped $reasonText');
      if (renamed > 0) notifyAssetMutation(widget.folderId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text('已重命名 $renamed 个,跳过 $skipped 个'
                '${reasonText.isEmpty ? '' : '($reasonText)'}')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('批量改名失败:$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final err = prefixErrorOf(_prefix.text);
    final preview = [
      for (final a in widget.assets.take(5))
        previewRename(a.filename, _prefix.text.trim(), _action),
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 20, right: 20, top: 0),
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('批量前缀(${widget.selectedIds.length} 个文件)',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('无批量撤销:加前缀可用「去前缀」按相同前缀反向恢复。',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'add', label: Text('加前缀')),
              ButtonSegment(value: 'remove', label: Text('去前缀')),
            ],
            selected: {_action},
            onSelectionChanged: (s) => setState(() => _action = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _prefix,
            maxLength: 160,
            decoration: InputDecoration(
              labelText: _action == 'add' ? '要加的前缀' : '要去掉的前缀',
              errorText: err,
              counterText: '',
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (preview.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...[
              for (final p in preview)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    p.after != null
                        ? '${p.before} → ${p.after}'
                        : '${p.before}(跳过:${p.skip})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _submitting || err != null || widget.selectedIds.isEmpty
                  ? null
                  : _submit,
              child: Text(_submitting ? '提交中…' : '执行改名'),
            ),
          ),
        ]),
      ),
    );
  }
}
