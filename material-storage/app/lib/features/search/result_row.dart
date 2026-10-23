/// ResultRow — 搜索结果行(墨金 WP2 §6 F10):44 缩略图(圆角 9)+ 文件名
/// 15.5(命中金浅底/金字)+ 归属 13/ink3 + 类型徽标(outline)+ chevron。
/// 行本体由搜索页放进 AppCard 内,相邻行由页面插 1px 分隔线。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/preview_kind.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';
import '../../widgets/type_block.dart' show extLabel;
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

/// 命中高亮文件名(goldSoft 底 + goldInk 字,两主题同构)。
Widget highlightText(
  BuildContext context,
  String text,
  String query, {
  TextStyle? style,
}) {
  final tk = context.tk;
  final spans = <TextSpan>[];
  for (final (seg, hit) in highlightSpans(text, query)) {
    spans.add(
      TextSpan(
        text: seg,
        style: hit
            ? TextStyle(
                backgroundColor: tk.goldSoft,
                color: tk.goldInk,
                fontWeight: FontWeight.w600,
              )
            : null,
      ),
    );
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
    final tk = context.tk;
    final r = result;
    final a = r.asset;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Tk.spaceMd, 10, Tk.spaceSm, 10),
          child: Row(
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: ThumbnailImage(asset: a, fallbackIconSize: 18),
                ),
              ),
              const SizedBox(width: Tk.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    highlightText(
                      context,
                      a.filename,
                      query,
                      style: TextStyle(
                        fontSize: Tk.fzRowTitle,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                        color: tk.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${r.projectName} / ${r.folderName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Tk.spaceSm),
              Badge(
                label: typeBadgeLabel(a.filename, a.contentType),
                tone: BadgeTone.outline,
              ),
              const SizedBox(width: 2),
              Icon(Icons.chevron_right, size: 18, color: tk.ink3),
            ],
          ),
        ),
      ),
    );
  }
}
