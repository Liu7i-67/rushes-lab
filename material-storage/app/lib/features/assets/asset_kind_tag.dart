/// AssetKindTag — 宫格块右上角类型角标(F8/§7.2):
/// 20 高、圆角 6、暖炭半透明底 `rgba(18,17,12,.58)` + 象牙字 10.5/w600。
/// 视频显示「视频」,PDF/MD 显示扩展名,livp 显示「实况」;图片/文本不出角标。
library;

import 'package:flutter/material.dart';

import '../../core/preview_kind.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';

/// 角标文案(null = 该类型不展示角标)。
String? assetKindLabel(Asset asset) => switch (detectKind(
  filename: asset.filename,
  contentType: asset.contentType,
)) {
  PreviewKind.video => '视频',
  PreviewKind.pdf => 'PDF',
  PreviewKind.markdown => 'MD',
  PreviewKind.livp => '实况',
  _ => null,
};

IconData assetKindIcon(Asset asset) => switch (detectKind(
  filename: asset.filename,
  contentType: asset.contentType,
)) {
  PreviewKind.video => Icons.play_arrow_rounded,
  PreviewKind.pdf => Icons.picture_as_pdf_outlined,
  PreviewKind.markdown => Icons.article_outlined,
  PreviewKind.livp => Icons.motion_photos_on_outlined,
  _ => Icons.insert_drive_file_outlined,
};

class AssetKindTag extends StatelessWidget {
  const AssetKindTag({super.key, required this.asset});

  final Asset asset;

  /// 角标底色两种主题共用(叠在缩略图/打样卡上的媒体层,§4.1 scrim 同族)。
  static const Color _bg = Color(0x9412110C);

  @override
  Widget build(BuildContext context) {
    final label = assetKindLabel(asset);
    if (label == null) return const SizedBox.shrink();
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(Tk.rXs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(assetKindIcon(asset), size: 11, color: Tk.previewFg),
          const SizedBox(width: 3),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10.5,
              height: 1.2,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: Tk.previewFg,
            ),
          ),
        ],
      ),
    );
  }
}
