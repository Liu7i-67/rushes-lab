/// TypeBlock — 类型降级块(B2 §7 widgets 补件;P2-2 改造):缩略图缺失/
/// 不可解码/unsupported 时的降级呈现,默认复用 [AssetPlate] 金弧打样卡
/// (种子由文件名稳定 hash 取模,同文件跨次进入同卡面),居中图标 + 扩展名
/// 以 previewFg(暖白)压在渐变与中心暗晕上,两主题均可读;[usePlate]=false
/// 退回按 kind 取色的平面色块(特殊窄场景兼容)。
library;

import 'package:flutter/material.dart';

import '../core/preview_kind.dart';
import '../theme/context_tk.dart';
import '../theme/tokens.dart';
import 'asset_plate.dart';

/// kind → (底色, 前景色) 映射(取 `context.tk`,浅/深主题自动切换)。
(Color, Color) kindColors(BuildContext context, PreviewKind k) {
  final tk = context.tk;
  return switch (k) {
    PreviewKind.image || PreviewKind.heic => (tk.goldSoft, tk.goldInk),
    PreviewKind.video || PreviewKind.livp => (tk.okSoft, tk.ok),
    PreviewKind.pdf => (tk.dangerSoft, tk.danger),
    PreviewKind.markdown ||
    PreviewKind.text ||
    PreviewKind.unsupported => (tk.surface3, tk.ink2),
  };
}

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
  const exts = [
    ...kImageExts,
    ...kVideoExts,
    '.livp',
    '.heic',
    '.heif',
    '.md',
    '.txt',
    '.pdf',
  ];
  for (final e in exts) {
    if (name.endsWith(e)) return e.substring(1).toUpperCase();
  }
  return '';
}

/// 文件名 → 打样卡种子(P2-2):FNV-1a 稳定 hash 取模 1000,不依赖
/// Dart 运行时 `String.hashCode`(跨进程/版本可能变化);同文件恒同卡面。
int seedFromFilename(String filename) {
  var h = 0x811c9dc5;
  for (final unit in filename.codeUnits) {
    h ^= unit;
    h = (h * 0x01000193) & 0x7fffffff;
  }
  return h % 1000;
}

class TypeBlock extends StatelessWidget {
  const TypeBlock({
    super.key,
    required this.kind,
    this.filename,
    this.iconSize,
    this.usePlate = true,
  });

  final PreviewKind kind;
  final String? filename;
  final double? iconSize;

  /// 默认打样卡(金弧 + 暖色渐变);false 退回旧平面色块(兼容窄场景)。
  final bool usePlate;

  @override
  Widget build(BuildContext context) {
    final label = filename == null ? '' : extLabel(filename!);
    if (!usePlate) {
      final (bg, fg) = kindColors(context, kind);
      return ColoredBox(color: bg, child: _content(fg, label));
    }
    // 打样卡:中心径向暗晕保证暖白图标/扩展名在浅色介质上仍可读。
    return AssetPlate(
      seed: seedFromFilename(filename ?? ''),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            radius: 0.62,
            colors: [Color(0x66000000), Color(0x00000000)],
          ),
        ),
        child: _content(Tk.previewFg, label),
      ),
    );
  }

  Widget _content(Color fg, String label) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          kindIcon(kind),
          color: fg,
          size: iconSize ?? 32,
          shadows: const [Shadow(color: Color(0x80000000), blurRadius: 8)],
        ),
        if (label.isNotEmpty) ...[
          const SizedBox(height: Tk.spaceXs),
          Text(
            label,
            style: TextStyle(
              color: fg.withValues(alpha: 0.92),
              fontSize: Tk.fzXs,
              letterSpacing: 0.6,
              shadows: const [Shadow(color: Color(0x80000000), blurRadius: 6)],
            ),
          ),
        ],
      ],
    ),
  );
}
