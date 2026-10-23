/// PreviewDocViews — 预览页辅助呈现件(B2 §8.2,从 preview_media 拆出):
/// 降级色块卡(「下载后打开」)/ 文档面板(md/text)/ pdf 就绪面板 /
/// Android PDF 就地面板(C6:下载完成就地「打开」,复用 _sharePdf 同款链路)。
/// 固定暗色画布(D8):卡片 previewSurface + 圆角 14,正文 previewFg /
/// previewFg2;文档面板内部以深色 Theme 承载 Markdown,浅色主题下也可读。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/preview_kind.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/toast.dart';
import '../../widgets/type_block.dart';

/// 降级卡:类型色块 + 失败信息 +「下载后打开」提示
/// (svg/avif/ico、unsupported、视频解码失败共用)。
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
        const SizedBox(height: Tk.spaceMd),
        Text(
          message,
          style: const TextStyle(color: Tk.previewFg2, fontSize: Tk.fzMd),
        ),
        const SizedBox(height: Tk.spaceXs),
        const Text(
          '点下方「下载」保存后用系统应用打开',
          style: TextStyle(color: Tk.previewFg2, fontSize: Tk.fzXs),
        ),
      ],
    );
  }
}

/// 文档面板:暗色画布上铺一张 previewSurface 卡(md/text 在卡内渲染)。
/// 内部套深色 Theme,保证 Markdown 默认文字/链接色在浅色主题下仍可读。
class DocSheet extends StatelessWidget {
  const DocSheet({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(Tk.spaceLg),
      padding: const EdgeInsets.all(Tk.spaceLg),
      decoration: BoxDecoration(
        color: Tk.previewSurface,
        borderRadius: BorderRadius.circular(Tk.rMd),
        border: Border.all(color: Tk.previewLine),
      ),
      child: Theme(
        data: buildAppTheme(Brightness.dark),
        child: SingleChildScrollView(
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Tk.previewFg),
            child: child,
          ),
        ),
      ),
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
        const Icon(
          Icons.picture_as_pdf_outlined,
          color: Tk.previewFg2,
          size: 48,
        ),
        const SizedBox(height: Tk.spaceMd),
        const Text('PDF 已就绪', style: TextStyle(color: Tk.previewFg)),
        const SizedBox(height: Tk.spaceSm),
        FilledButton.icon(
          onPressed: onShare,
          icon: const Icon(Icons.ios_share_outlined),
          label: const Text('分享 / 存储到文件'),
        ),
      ],
    );
  }
}

/// C6(app-polish):Android PDF 就地面板。idle→「下载并打开」(直下:会话
/// dio → 系统临时目录);完成→就地「打开」(share_plus XFile)并自动拉起
/// 一次;失败 toast(error)可重试。不走 TransferQueue。
class AndroidPdfPanel extends StatefulWidget {
  const AndroidPdfPanel({super.key, required this.asset});

  final Asset asset;

  @override
  State<AndroidPdfPanel> createState() => _AndroidPdfPanelState();
}

class _AndroidPdfPanelState extends State<AndroidPdfPanel> {
  var _busy = false;
  String? _localPath;

  Asset get _a => widget.asset;

  Future<void> _download() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final url = await session.api!.assets.downloadLink(_a.id);
      final save = '${Directory.systemTemp.path}/${_a.filename}';
      await session.api!.assets.downloadTo(url, save);
      if (!mounted) return;
      setState(() {
        _localPath = save;
        _busy = false;
      });
      await _open(); // 完成自动拉起一次;之后可就地重按「打开」
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      toast(context, errorMessage(e, 'PDF 下载失败,请稍后重试'), tone: ToastTone.error);
    }
  }

  Future<void> _open() async {
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(_localPath!)]));
    } catch (_) {
      if (mounted) {
        toast(context, '打开失败:未找到可处理 PDF 的应用', tone: ToastTone.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.picture_as_pdf_outlined,
          color: Tk.previewFg2,
          size: 48,
        ),
        const SizedBox(height: Tk.spaceMd),
        Text(
          _localPath == null ? 'PDF 需下载后打开' : 'PDF 已下载,可打开',
          style: const TextStyle(color: Tk.previewFg, fontSize: Tk.fzMd),
        ),
        const SizedBox(height: Tk.spaceSm),
        if (_busy) ...[
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Tk.previewFg2,
            ),
          ),
          const SizedBox(height: Tk.spaceSm),
          const Text(
            '下载中…',
            style: TextStyle(color: Tk.previewFg2, fontSize: Tk.fzXs),
          ),
        ] else if (_localPath != null)
          FilledButton.icon(
            onPressed: _open,
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('打开'),
          )
        else
          FilledButton.icon(
            onPressed: _download,
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('下载并打开'),
          ),
        const SizedBox(height: Tk.spaceXs),
        const Text(
          '保存到相册 / Download 可点下方「下载」',
          style: TextStyle(color: Tk.previewFg2, fontSize: Tk.fzXs),
        ),
      ],
    );
  }
}
