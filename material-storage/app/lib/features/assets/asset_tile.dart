/// AssetGridTile — 宫格块(B2 §8.1):缩略图/类型色块 + 文件名 + livp 实况角标;
/// 多选态选中打勾。视频时长角标不做——契约核对 AssetOut 无 duration 字段(2026-10-20)。
/// app-polish:B2 长按进多选 Haptics.medium、多选态点选 Haptics.select、
/// 选中缩放+对勾切换动效;B7 文件名/元信息按 token 收敛,元信息 subtle→muted。
library;

import 'package:flutter/material.dart';

import '../../core/fmt.dart';
import '../../core/haptics.dart';
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
      // B2:多选态点选=细粒度 selection 触觉;浏览态点按进预览不扰。
      onTap: () {
        if (selecting) Haptics.select();
        onTap();
      },
      // B2:长按进多选=medium 触觉(有分量的状态切换)。
      onLongPress: () {
        Haptics.medium();
        onLongPress();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            // B2:选中缩放动效(轻微收拢示意「已抓起」)。
            child: AnimatedScale(
              scale: selected ? 0.94 : 1.0,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Tk.rMd),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ThumbnailImage(asset: asset),
                    // livp 实况角标(.livp 扩展名 endswith 判定)
                    if (asset.isLivp)
                      Positioned(
                        left: Tk.spaceSm,
                        bottom: Tk.spaceSm,
                        child: _pill('实况'),
                      ),
                    if (selected) const Positioned.fill(child: ColoredBox(color: Colors.black26)),
                    if (selecting)
                      Positioned(
                        top: Tk.spaceSm,
                        right: Tk.spaceSm,
                        // B2:对勾切换动效(fade+scale)。
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 150),
                          transitionBuilder: (child, anim) => FadeTransition(
                            opacity: anim,
                            child: ScaleTransition(scale: anim, child: child),
                          ),
                          child: Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            // key 切换触发 AnimatedSwitcher
                            key: ValueKey(selected),
                            size: 22,
                            color: selected ? Tk.accent : Colors.white,
                            shadows: const [
                              Shadow(blurRadius: 4, color: Colors.black38)
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: Tk.spaceXs, left: 2, right: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  asset.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: Tk.fzSm),
                ),
                // B7:元信息 10px→fzXs(11 下限)、subtle→muted 提对比;仍小于
                // 文件名(fzSm)层级不倒置。
                Text(
                  '${fmtBytes(asset.sizeBytes)} · ${fmtDate(asset.createdAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: Tk.fzXs, color: Tk.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(String label) => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: Tk.spaceSm, vertical: 2), // 2=胶囊上下微缝(<4 保留)
        decoration: const BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.all(Radius.circular(Tk.rPill)),
        ),
        child: Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: Tk.fzXs),
        ),
      );
}
