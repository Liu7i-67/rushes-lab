/// ResultRow — 搜索结果行(B7 §8.8):缩略图(复用 B2 ThumbnailImage,含
/// 类型色块降级)+ 文件名命中高亮 + 归属(项目/文件夹)+ 类型徽标。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/preview_kind.dart';
import '../../widgets/type_block.dart' show extLabel;
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';
import '../assets/thumbnail_image.dart';

/// 命中高亮 span 拆分纯函数(可单测;忽略大小写,web SearchPage.Highlight
/// 同算法):返回 (text, hit) 段序列。
List<(String, bool)> highlightSpans(String text, String query) {
  final q = query.toLowerCase();
  final out = <(String, bool)>[];
  if (q.isEmpty) {
    if (text.isNotEmpty) out.add((text, false));
    return out;
  }
  final lower = text.toLowerCase();
  var i = 0;
  while (i < text.length) {
    final idx = lower.indexOf(q, i);
    if (idx < 0) {
      out.add((text.substring(i), false));
      break;
    }
    if (idx > i) out.add((text.substring(i, idx), false));
    out.add((text.substring(idx, idx + q.length), true));
    i = idx + q.length;
  }
  return out;
}

/// 类型徽标文案:扩展名大写(JPG/MP4…);无扩展名按预览类型兜底。
String typeBadgeLabel(String filename, String? contentType) {
  final ext = extLabel(filename);
  if (ext.isNotEmpty) return ext;
  return switch (detectKind(filename: filename, contentType: contentType)) {
    PreviewKind.video || PreviewKind.livp => '视频',
    PreviewKind.image || PreviewKind.heic => '图片',
    PreviewKind.pdf => 'PDF',
    PreviewKind.markdown || PreviewKind.text => '文档',
    _ => '文件',
  };
}

/// 命中高亮文件名(q 非空时 accent 底色,web 同款)。
Widget highlightText(String text, String query, {TextStyle? style}) {
  final spans = <TextSpan>[];
  for (final (seg, hit) in highlightSpans(text, query)) {
    spans.add(TextSpan(
      text: seg,
      style: hit
          ? TextStyle(
              background: Paint()..color = Tk.accentFaint,
              color: Tk.accentStrong,
              fontWeight: FontWeight.w600)
          : null,
    ));
  }
  return Text.rich(
    TextSpan(style: style, children: spans),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
}

class ResultRow extends StatelessWidget {
  const ResultRow({
    super.key,
    required this.result,
    required this.query,
    this.onTap,
  });

  final SearchResult result;
  final String query;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final a = r.asset;
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(Tk.rMd)),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: Tk.spaceMd, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: Tk.border),
          borderRadius: const BorderRadius.all(Radius.circular(Tk.rMd)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(Tk.rSm)),
                child: ThumbnailImage(asset: a, fallbackIconSize: 20),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  highlightText(a.filename, query,
                      style: const TextStyle(
                          fontSize: Tk.fzBody, fontWeight: FontWeight.w500)),
                  const SizedBox(height: Tk.spaceXs),
                  // E9:归属行 fzXs→fzSm 提升可读性
                  Text(
                    '${r.projectName} / ${r.folderName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: Tk.fzSm, color: Tk.subtle),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Tk.spaceSm),
            Badge(label: typeBadgeLabel(a.filename, a.contentType)),
          ],
        ),
      ),
    );
  }
}
