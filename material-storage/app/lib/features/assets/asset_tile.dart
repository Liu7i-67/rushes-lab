/// AssetGridTile — 宫格块(F8):1:1.06 媒体块(圆角 12)+ 文件名 12.5/ink2 +
/// 元信息 11(ink3 由 DefaultTextStyle 继承);无缩略图/失败用 AssetPlate 打样卡
/// (seed=宫格下标),真实缩略图仍走 ThumbnailImage。右上类型角标,左上选中勾;
/// 选中态 160ms 缩放 + 2px 金环 + 4px 柔光。
/// 视频时长角标不做——契约核对 AssetOut 无 duration 字段(2026-10-20)。
library;

import 'package:flutter/material.dart';

import '../../core/fmt.dart';
import '../../core/haptics.dart';
import '../../core/thumb_variant.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/asset_plate.dart';
import 'asset_kind_tag.dart';
import 'thumbnail_image.dart';

/// 媒体块圆角(F8 定稿 12,与 rMd 14 区分)。
const double assetMediaRadius = 12;

class AssetGridTile extends StatelessWidget {
  const AssetGridTile({
    super.key,
    required this.asset,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
    this.index = 0,
    this.variant = ThumbVariant.large,
  });

  final Asset asset;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// 打样卡种子(宫格下标;无缩略图/失败时编号与配色来源)。
  final int index;

  /// 缩略图规格(thumb-variant 批 D1):宫格 cell 由 assets_body 传
  /// [ThumbVariant.small](240px 源);默认 large 兼容既有构造面。
  final ThumbVariant variant;

  static const _radius = BorderRadius.all(Radius.circular(assetMediaRadius));

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    // P2-7:reduced-motion 下选中缩放/金环/勾选切换瞬时完成。
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 160);
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
            child: Center(
              child: AspectRatio(
                aspectRatio: 1 / 1.06,
                child: AnimatedContainer(
                  duration: duration,
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    borderRadius: _radius,
                    // 选中:2px 金环 + 4px 金色柔光(向外扩,不挤占布局)。
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: tk.goldBright,
                              spreadRadius: 2,
                              blurRadius: 0,
                            ),
                            BoxShadow(
                              color: tk.gold.withValues(alpha: 0.22),
                              spreadRadius: 4,
                              blurRadius: 0,
                            ),
                          ]
                        : null,
                  ),
                  child: AnimatedScale(
                    scale: selected ? 0.96 : 1,
                    duration: duration,
                    curve: Curves.easeOut,
                    child: ClipRRect(
                      borderRadius: _radius,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ThumbnailImage(
                            asset: asset,
                            variant: variant,
                            fallback: AssetPlate(
                              seed: index,
                              borderRadius: _radius,
                            ),
                          ),
                          Positioned(
                            top: 6,
                            right: 6,
                            child: AssetKindTag(asset: asset),
                          ),
                          if (selecting)
                            Positioned(
                              left: 7,
                              top: 7,
                              child: _SelectCheck(selected: selected),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 2, right: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  asset.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.1,
                    color: tk.ink2,
                  ),
                ),
                // 颜色由 DefaultTextStyle 继承 ink3(字号在 Text 上显式声明)。
                DefaultTextStyle(
                  style: TextStyle(fontSize: Tk.fzXs, color: tk.ink3),
                  child: Text(
                    '${fmtBytes(asset.sizeBytes)} · ${fmtDate(asset.createdAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: Tk.fzXs),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// AssetTileSkeleton — 宫格未加载区占位骨(快速滚动批 F3):与 AssetGridTile
/// 同尺寸结构(1:1.06 媒体块 + 两行文字条),灰底圆角取 ListSkeleton 同款
/// surface3;纯静态不做 shimmer(D7);不可点按(骨架命中只经 body 触发补齐)。
/// 统一 key 供测试定位(同屏多枚同 key,断言用 findsWidgets/first)。
class AssetTileSkeleton extends StatelessWidget {
  const AssetTileSkeleton({super.key = const Key('asset_tile_skeleton')});

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final radius = BorderRadius.circular(assetMediaRadius);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: 1 / 1.06,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: tk.surface3,
                  borderRadius: radius,
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 2, right: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 文件名/元信息两行条:高度近似 AssetGridTile 文字区。
              Container(
                height: 13,
                margin: const EdgeInsets.only(bottom: 4),
                decoration: BoxDecoration(
                  color: tk.surface3,
                  borderRadius: BorderRadius.circular(Tk.rSm),
                ),
              ),
              FractionallySizedBox(
                widthFactor: 0.55,
                child: Container(
                  height: 11,
                  decoration: BoxDecoration(
                    color: tk.surface3,
                    borderRadius: BorderRadius.circular(Tk.rSm),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 左上选中圆勾:22 直径,选中金底深墨勾;未选中多选态白描边半透明底。
class _SelectCheck extends StatelessWidget {
  const _SelectCheck({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    // P2-7:reduced-motion 下勾底/勾形切换瞬时完成。
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 160);
    return AnimatedContainer(
      duration: duration,
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? tk.goldBright : const Color(0x4712110C),
        border: Border.all(
          color: selected
              ? tk.goldBright
              : Colors.white.withValues(alpha: 0.85),
          width: 1.5,
        ),
      ),
      child: AnimatedSwitcher(
        duration: duration,
        child: selected
            ? const Icon(
                Icons.check,
                key: ValueKey(true),
                size: 14,
                color: Color(0xFF231C0C),
              )
            : const SizedBox.shrink(key: ValueKey(false)),
      ),
    );
  }
}
