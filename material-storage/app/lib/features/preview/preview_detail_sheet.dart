/// PreviewDetailSheet — 预览「文件详情」面板(F9 / §7.2):
/// 键值网格(84 / 1fr):所属位置、文件名、类型、大小、上传时间、标签、备注。
/// P2-9:预览浮层固定暗色(D8)——与画布同用 previewSurface 底 + 暗色主题,
/// 浅色 App 主题下也不回到纸感浅色;键 previewFg2、值 previewFg。
library;

import 'package:flutter/material.dart';

import '../../core/fmt.dart';
import '../../core/preview_kind.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import 'meta_panel.dart' show kindLabel;
import 'preview_chrome.dart' show showPreviewSheet;

/// 打开「文件详情」面板;`where` 为所属位置(项目/文件夹路径)。
Future<void> showPreviewDetailSheet(
  BuildContext context, {
  required Asset asset,
  String? where,
}) {
  return showPreviewSheet<void>(
    context: context,
    title: '文件详情',
    child: _DetailBody(asset: asset, where: where),
  );
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.asset, this.where});

  final Asset asset;
  final String? where;

  @override
  Widget build(BuildContext context) {
    final kind = detectKind(
      filename: asset.filename,
      contentType: asset.contentType,
    );
    final labels = asset.userLabels.join(' · ');
    final notes = asset.notes?.trim() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DetailRow(label: '所属位置', value: _nonEmpty(where)),
        _DetailRow(label: '文件名', value: asset.filename),
        _DetailRow(label: '类型', value: kindLabel(kind)),
        _DetailRow(label: '大小', value: fmtBytes(asset.sizeBytes)),
        _DetailRow(label: '上传时间', value: fmtDate(asset.createdAt)),
        _DetailRow(label: '标签', value: _nonEmpty(labels)),
        _DetailRow(label: '备注', value: _nonEmpty(notes)),
      ],
    );
  }

  static String _nonEmpty(String? value) =>
      value == null || value.trim().isEmpty ? '—' : value;
}

/// 单行键值:左固定 84、右 1fr;键 previewFg2、值 previewFg(固定暗色浮层)。
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: const TextStyle(fontSize: Tk.fzMd, color: Tk.previewFg2),
            ),
          ),
          const SizedBox(width: Tk.spaceMd),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: Tk.fzMd, color: Tk.previewFg),
            ),
          ),
        ],
      ),
    );
  }
}
