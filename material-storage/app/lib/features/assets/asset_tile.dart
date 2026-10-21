/// AssetGridTile — 宫格块(B2 §8.1):缩略图/类型色块 + 文件名 + livp 实况角标;
/// 多选态选中打勾。视频时长角标不做——契约核对 AssetOut 无 duration 字段(2026-10-20)。
library;

import 'package:flutter/material.dart';

import '../../core/fmt.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import 'thumbnail_image.dart';

class AssetGridTile extends StatelessWidget {
  const AssetGridTile({
    super.key,
    required this.asset,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final Asset asset;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ThumbnailImage(asset: asset),
                  // livp 实况角标(.livp 扩展名 endswith 判定)
                  if (asset.isLivp)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: _pill('实况'),
                    ),
                  if (selected) Positioned.fill(child: ColoredBox(color: Colors.black26)),
                  if (selecting)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Icon(
                        selected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 22,
                        color: selected ? Tk.accent : Colors.white,
                        shadows: const [
                          Shadow(blurRadius: 4, color: Colors.black38)
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2, right: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  asset.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                Text(
                  '${fmtBytes(asset.sizeBytes)} · ${fmtDate(asset.createdAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: Tk.subtle),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 10),
        ),
      );
}
