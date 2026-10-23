/// MetaPanel — 预览底部元数据浮层(F9):文件名 15.5/w600、类型/大小/时间
/// 12、标签 pills、备注 12;「编辑」钮打开打标面板(AssetTagEditor 移动版,
/// 单条不传 labels_mode)。
/// 固定暗色画布(D8):底色 previewSurface、圆角 18、四边留边;内部 Badge
/// 用深色令牌(Theme 局部覆盖 TkColors.dark),浅色主题下也不出现浅色 pill。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/fmt.dart';
import '../../core/preview_kind.dart';
import '../../models/models.dart';
import '../../theme/tk_colors.dart';
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
  const MetaPanel({super.key, required this.asset, this.onEdit});

  final Asset asset;

  /// 「编辑」动作(B5 点亮;null=不渲染编辑钮)。
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final kind = detectKind(
      filename: asset.filename,
      contentType: asset.contentType,
    );
    return Theme(
      // 预览浮层固定暗色:仅替换颜色扩展,Badge 等 context.tk 消费者
      // 在浅色主题下也取深色令牌。
      data: Theme.of(context)
          .copyWith(extensions: <ThemeExtension<dynamic>>[TkColors.dark]),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(
          Tk.spaceMd,
          0,
          Tk.spaceMd,
          Tk.spaceSm,
        ),
        padding: const EdgeInsets.fromLTRB(
          Tk.spaceLg,
          Tk.spaceMd,
          Tk.spaceLg,
          Tk.spaceMd,
        ),
        decoration: BoxDecoration(
          color: Tk.previewSurface,
          borderRadius: BorderRadius.circular(Tk.rLg),
          border: Border.all(color: Tk.previewLine),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    asset.filename,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Tk.previewFg,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (onEdit != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    color: Tk.previewFg2,
                    tooltip: '编辑标签与备注',
                    onPressed: onEdit,
                  ),
              ],
            ),
            const SizedBox(height: Tk.spaceXs),
            Text(
              '${fmtBytes(asset.sizeBytes)} · ${kindLabel(kind)} · ${fmtDate(asset.createdAt)}',
              style: const TextStyle(color: Tk.previewFg2, fontSize: Tk.fzSm),
            ),
            if (asset.userLabels.isNotEmpty) ...[
              const SizedBox(height: Tk.spaceSm),
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
              const SizedBox(height: Tk.spaceSm),
              Text(
                asset.notes!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Tk.previewFg2, fontSize: Tk.fzSm),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
