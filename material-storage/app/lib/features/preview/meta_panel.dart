/// MetaPanel — 预览底部元数据卡(B2 §8.2):文件名/大小/类型/时间/标签 chips+备注。
/// 暗色画布上的浮层用 darkSurface;B5 功能点 3:「编辑」钮点亮 → 打标/改标面板
/// (AssetTagEditor 移动版;单条不传 labels_mode)。
/// C4(app-polish):浮层化——四周留边+全圆角卡(rLg),与胶片条/操作钮圆角
/// 过渡,不再直角堆叠。
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
  const MetaPanel({super.key, required this.asset, this.onEdit});

  final Asset asset;

  /// 「编辑」动作(B5 点亮;null=不渲染编辑钮)。
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final kind = detectKind(
        filename: asset.filename, contentType: asset.contentType);
    return Container(
      width: double.infinity,
      // C4:浮层卡——横向留边+全圆角,与上方胶片条/下方操作钮过渡
      margin: const EdgeInsets.fromLTRB(Tk.spaceMd, 0, Tk.spaceMd, Tk.spaceXs),
      decoration: BoxDecoration(
        color: Tk.darkSurface,
        borderRadius: BorderRadius.circular(Tk.rLg),
      ),
      padding: const EdgeInsets.fromLTRB(
          Tk.spaceLg, Tk.spaceMd, Tk.spaceLg, Tk.spaceMd),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(
                asset.filename,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white, // 媒体叠加层例外:暗底浮层前景
                  fontSize: Tk.fzBody,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (onEdit != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined, size: 18),
                color: Tk.subtle,
                tooltip: '编辑标签与备注',
                onPressed: onEdit,
              ),
          ]),
          const SizedBox(height: Tk.spaceXs),
          Text(
            '${fmtBytes(asset.sizeBytes)} · ${kindLabel(kind)} · ${fmtDate(asset.createdAt)}',
            style: const TextStyle(color: Tk.subtle, fontSize: Tk.fzSm),
          ),
          if (asset.userLabels.isNotEmpty) ...[
            const SizedBox(height: Tk.spaceSm),
            Wrap(
              spacing: 6, // chip 间微缝,同 Badge 内距比例保留
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
              style: const TextStyle(color: Tk.muted, fontSize: Tk.fzSm),
            ),
          ],
        ],
      ),
    );
  }
}
