/// MetaPanel — 预览底部元数据卡(B2 §8.2):文件名/大小/类型/时间/标签 chips+备注。
/// 暗色画布上的浮层用 darkSurface;「编辑」按钮 B5 点亮,本批不渲染。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/fmt.dart';
import '../../core/preview_kind.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';

/// 类型中文名(纯函数可单测;与 detectKind 八类一一对应)。
String kindLabel(PreviewKind k) => switch (k) {
      PreviewKind.image => '图片',
      PreviewKind.heic => 'HEIC 图片',
      PreviewKind.livp => '实况照片',
      PreviewKind.video => '视频',
      PreviewKind.pdf => 'PDF',
      PreviewKind.markdown => 'Markdown',
      PreviewKind.text => '文本',
      PreviewKind.unsupported => '文件',
    };

class MetaPanel extends StatelessWidget {
  const MetaPanel({super.key, required this.asset});

  final Asset asset;

  @override
  Widget build(BuildContext context) {
    final kind = detectKind(
        filename: asset.filename, contentType: asset.contentType);
    return Container(
      width: double.infinity,
      color: Tk.darkSurface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            asset.filename,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${fmtBytes(asset.sizeBytes)} · ${kindLabel(kind)} · ${fmtDate(asset.createdAt)}',
            style: const TextStyle(color: Tk.subtle, fontSize: 12),
          ),
          if (asset.userLabels.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final l in asset.userLabels)
                  Badge(label: l, tone: BadgeTone.neutral),
              ],
            ),
          ],
          if (asset.notes != null && asset.notes!.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              asset.notes!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Tk.muted, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
