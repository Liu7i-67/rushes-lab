/// PreviewDocViews — 预览页辅助呈现件(B2 §8.2,从 preview_media 拆出):
/// 降级色块卡(「下载后打开」)/ 白底文档面板(md/text)/ pdf iOS 就绪面板。
/// C6(app-polish):新增 AndroidPdfPanel——PDF 在 Android 不再是「需下载后
/// 打开」死胡同:就地「下载并打开」(会话 dio 直下临时文件,复用 _sharePdf
/// 同款链路),完成转「打开」(share_plus XFile 拉系统分享/打开,工程内
/// iOS pdf 先例;url_launcher 在本工程约定不用于 file://)。失败 toast(error)。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/preview_kind.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/toast.dart';
import '../../widgets/type_block.dart';

/// 降级卡:类型色块 + 失败信息 +「下载后打开」提示
/// (svg/avif/ico、unsupported、视频解码失败共用;
/// B4 起下载入口已开放,引导点下方「下载」)。
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
        Text(message,
            style: const TextStyle(color: Colors.white70, fontSize: Tk.fzMd)),
        const SizedBox(height: Tk.spaceXs),
        const Text(
          '点下方「下载」保存后用系统应用打开',
          style: TextStyle(color: Tk.subtle, fontSize: Tk.fzXs),
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
      margin: const EdgeInsets.all(Tk.spaceLg),
      padding: const EdgeInsets.all(Tk.spaceLg),
      decoration: BoxDecoration(
        color: Colors.white, // 媒体叠加层例外:「纸」的白底(可读性优先)
        borderRadius: BorderRadius.circular(Tk.rMd),
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
        const SizedBox(height: Tk.spaceMd),
        const Text('PDF 已就绪', style: TextStyle(color: Colors.white70)),
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
/// dio → 系统临时目录);完成→就地「打开」(share_plus XFile,系统分享面板
/// 可选 PDF 应用打开)并自动拉起一次;失败 toast(error)可重试。
/// 不走 TransferQueue(就地直下与 iOS _sharePdf 同链路;批量入队在下方操作钮)。
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
      toast(context, errorMessage(e, 'PDF 下载失败,请稍后重试'),
          tone: ToastTone.error);
    }
  }

  Future<void> _open() async {
    try {
      await SharePlus.instance
          .share(ShareParams(files: [XFile(_localPath!)]));
    } catch (_) {
      if (mounted) {
        toast(context, '打开失败:未找到可处理 PDF 的应用',
            tone: ToastTone.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.picture_as_pdf_outlined,
            color: Colors.white70, size: 48),
        const SizedBox(height: Tk.spaceMd),
        Text(
          _localPath == null ? 'PDF 需下载后打开' : 'PDF 已下载,可打开',
          style: const TextStyle(color: Colors.white70, fontSize: Tk.fzMd),
        ),
        const SizedBox(height: Tk.spaceSm),
        if (_busy) ...[
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Colors.white70),
          ),
          const SizedBox(height: Tk.spaceSm),
          const Text('下载中…',
              style: TextStyle(color: Tk.subtle, fontSize: Tk.fzXs)),
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
          style: TextStyle(color: Tk.subtle, fontSize: Tk.fzXs),
        ),
      ],
    );
  }
}
