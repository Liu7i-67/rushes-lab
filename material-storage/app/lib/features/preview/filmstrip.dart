/// Filmstrip — 预览胶片条(B2 §8.2):顶部 ‹n/N› 同源的切张逻辑+横向缩略图条。
/// 序列=进入预览时的列表序;边界即停(首张不可前翻/末张不可后翻,web 同语义)。
/// FilmstripPager 为纯逻辑可单测;Widget 条供预览页挂载。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../assets/thumbnail_image.dart';

class FilmstripPager {
  FilmstripPager({required this.length, int initial = 0})
      : _i = length == 0 ? 0 : initial.clamp(0, length - 1);

  final int length;
  int _i;

  int get index => _i;
  bool get canPrev => _i > 0;
  bool get canNext => _i < length - 1;

  /// 边界即停:越界请求返回 false 且不动游标。
  bool prev() {
    if (!canPrev) return false;
    _i--;
    return true;
  }

  bool next() {
    if (!canNext) return false;
    _i++;
    return true;
  }

  /// 定位(胶片条点按):越界 clamp 到边界。
  void moveTo(int i) =>
      _i = length == 0 ? 0 : i.clamp(0, length - 1);
}

class Filmstrip extends StatelessWidget {
  const Filmstrip({
    super.key,
    required this.items,
    required this.index,
    required this.onSelect,
  });

  final List<Asset> items;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    if (items.length < 2) return const SizedBox.shrink();
    return SizedBox(
      height: 60,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final current = i == index;
          return GestureDetector(
            onTap: () => onSelect(i),
            child: Container(
              width: 48,
              height: 48,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  width: current ? 2 : 1,
                  color: current ? Tk.accent : Colors.white24,
                ),
              ),
              child: ThumbnailImage(asset: items[i]),
            ),
          );
        },
      ),
    );
  }
}
