/// PreviewDocViews — 预览页辅助呈现件(B2 §8.2,从 preview_media 拆出):
/// 降级色块卡(「下载后打开」)/ 白底文档面板(md/text)/ pdf iOS 就绪面板。
library;

import 'package:flutter/material.dart';

import '../../core/preview_kind.dart';
import '../../theme/tokens.dart';
import '../../widgets/type_block.dart';

/// 降级卡:类型色块 + 失败信息 +「下载后打开」提示
/// (svg/avif/ico、unsupported、视频解码失败、pdf Android 占位共用)。
class PreviewBlock extends StatelessWidget {
  const PreviewBlock({
    super.key,
    required this.kind,
    required this.filename,
    required this.message,
  });

  final PreviewKind kind;
  final String filename;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 120,
          height: 120,
          child: TypeBlock(kind: kind, filename: filename),
        ),
        const SizedBox(height: 12),
        Text(message,
            style: const TextStyle(color: Colors.white70, fontSize: 13)),
        const SizedBox(height: 4),
        const Text(
          '可下载后用系统应用打开(下载入口后续版本开放)',
          style: TextStyle(color: Tk.subtle, fontSize: 11),
        ),
      ],
    );
  }
}

/// 白底文档面板:暗色画布上铺一张「纸」,md/text 在纸上渲染保证可读。
class DocSheet extends StatelessWidget {
  const DocSheet({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(child: child),
    );
  }
}

/// pdf iOS 就绪面板:临时文件已就绪,拉起 share_plus 分享面板
/// (快速预览/存储到文件);重按可再次拉起。
class PdfReadyPanel extends StatelessWidget {
  const PdfReadyPanel({super.key, required this.onShare});

  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.picture_as_pdf_outlined,
            color: Colors.white70, size: 48),
        const SizedBox(height: 12),
        const Text('PDF 已就绪', style: TextStyle(color: Colors.white70)),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: onShare,
          icon: const Icon(Icons.ios_share_outlined),
          label: const Text('分享 / 存储到文件'),
        ),
      ],
    );
  }
}
