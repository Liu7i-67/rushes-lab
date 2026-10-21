/// TypeBlock — 类型色块(B2 §7 widgets 补件):缩略图缺失/不可解码/unsupported
/// 时的降级呈现,按 kind 给色与图标,角落缀扩展名小字。颜色取自 §10 令牌。
library;

import 'package:flutter/material.dart';

import '../core/preview_kind.dart';
import '../theme/tokens.dart';

/// kind → (底色, 前景色) 纯映射,可单测。
(Color, Color) kindColors(PreviewKind k) => switch (k) {
      PreviewKind.image ||
      PreviewKind.heic =>
        (Tk.accentFaint, Tk.accentStrong),
      PreviewKind.video || PreviewKind.livp => (
          Tk.green.withValues(alpha: 0.10),
          Tk.green
        ),
      PreviewKind.pdf => (Tk.red.withValues(alpha: 0.08), Tk.red),
      PreviewKind.markdown ||
      PreviewKind.text ||
      PreviewKind.unsupported =>
        (Tk.fill, Tk.muted),
    };

IconData kindIcon(PreviewKind k) => switch (k) {
      PreviewKind.image || PreviewKind.heic => Icons.image_outlined,
      PreviewKind.video => Icons.movie_outlined,
      PreviewKind.livp => Icons.motion_photos_on_outlined,
      PreviewKind.pdf => Icons.picture_as_pdf_outlined,
      PreviewKind.markdown => Icons.article_outlined,
      PreviewKind.text => Icons.text_snippet_outlined,
      PreviewKind.unsupported => Icons.insert_drive_file_outlined,
    };

/// 展示用扩展名小字:`a.b.PNG` → `PNG`;无扩展名 → 空串(点文件钉子:endswith 判)。
String extLabel(String filename) {
  final name = filename.toLowerCase();
  const exts = [...kImageExts, ...kVideoExts, '.livp', '.heic', '.heif', '.md', '.txt', '.pdf'];
  for (final e in exts) {
    if (name.endsWith(e)) return e.substring(1).toUpperCase();
  }
  return '';
}

class TypeBlock extends StatelessWidget {
  const TypeBlock({super.key, required this.kind, this.filename, this.iconSize});

  final PreviewKind kind;
  final String? filename;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = kindColors(kind);
    final label = filename == null ? '' : extLabel(filename!);
    return ColoredBox(
      color: bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(kindIcon(kind), color: fg, size: iconSize ?? 32),
            if (label.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(color: fg, fontSize: 10, letterSpacing: 0.4),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
