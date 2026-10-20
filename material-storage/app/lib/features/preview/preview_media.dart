/// PreviewMedia — 预览主体渲染(B2 §8.2 八类):image/heic/livp/video/markdown/
/// text/pdf/unsupported。切张由父级以 ValueKey(asset.id) 重建本组件清态
/// (web 切张清预览态同哲学);起播/解码失败一律降级「下载后打开」色块
/// (辅助呈现件见 preview_doc_views.dart)。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart'
    show CancelToken, Options, ResponseBody, ResponseType;
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../core/preview_kind.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../assets/thumbnail_image.dart' show thumbnailCache;
import 'preview_doc_views.dart';

/// md/text 拉取单次缓冲上限(P2-8):presigned 源超 10MB 不读流,降级色块。
const kMaxInlineTextBytes = 10 * 1024 * 1024;

/// 预览主体渲染决策(纯函数,单测锁 P1-1):video 类在视频控制器未就绪时
/// 恒为 loading,绝不落到 image 分支——把视频 presigned URL 塞进 Image.network
/// 会在起播期误显「图片解码失败」卡 + 多余图片式拉流(2026-10-20 测试 P1-1)。
PreviewBody previewBodyPlan({
  required PreviewKind kind,
  required bool videoReady,
  required bool hasFail,
  required bool hasUrl,
}) {
  if (hasFail) return PreviewBody.block;
  switch (kind) {
    case PreviewKind.markdown:
      return PreviewBody.markdown;
    case PreviewKind.text:
      return PreviewBody.text;
    case PreviewKind.pdf:
      return PreviewBody.pdf;
    case PreviewKind.video:
      return videoReady ? PreviewBody.player : PreviewBody.loading;
    case PreviewKind.livp:
      // 实况:控制器未就绪时静态图兜底(起播中由 _image 叠加载圈)
      return videoReady
          ? PreviewBody.player
          : (hasUrl ? PreviewBody.image : PreviewBody.loading);
    case PreviewKind.image || PreviewKind.heic:
      return hasUrl ? PreviewBody.image : PreviewBody.loading;
    case PreviewKind.unsupported:
      return PreviewBody.block;
  }
}

/// 预览主体渲染分支(与 [previewBodyPlan] 配套的呈现枚举)。
enum PreviewBody { block, markdown, text, pdf, player, image, loading }

/// 视频时长/进度文本(P2-1):m:ss,满一小时进 h:mm:ss。
String videoClock(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// 缩略图缺失/失败两态文案(P2-6,web AssetPreviewModal 同口径):
/// `tags.thumbnail_failed` 有值=worker 明确失败(原因标记透出,不误导重试);
/// 无值=还在生成(引导稍后刷新)。
String thumbFailText(Map<dynamic, dynamic> tags) {
  final reason = (tags['thumbnail_failed'] as String? ?? '').trim();
  if (reason.isEmpty) return '预览图还在生成,请稍后刷新重试';
  return '预览图生成失败(原因:$reason),可下载原片查看,恢复请联系管理员';
}

class PreviewMedia extends StatefulWidget {
  const PreviewMedia({super.key, required this.asset});

  final Asset asset;

  @override
  State<PreviewMedia> createState() => _PreviewMediaState();
}

class _PreviewMediaState extends State<PreviewMedia> {
  var _loading = true;
  String? _url; // 可直接呈现的图 URL(原图 inline / 缩略图)
  String? _text; // md/text 内容
  String? _fail; // 降级提示(色块 + 下载后打开)
  VideoPlayerController? _vc;
  var _videoReady = false;
  String? _liveUrl; // livp 实况短片(非空才有回切按钮,web 同口径)
  var _playingLive = false; // livp 在播实况短片;video 类恒 true(成功后)

  Asset get _a => widget.asset;

  PreviewKind get _kind =>
      detectKind(filename: _a.filename, contentType: _a.contentType);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _vc?.removeListener(_onVideoTick);
    _vc?.dispose();
    super.dispose();
  }

  /// 播放态驱动重建(P2-1 进度/时长/播放键跟随 value 刷新)。
  void _onVideoTick() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    switch (_kind) {
      case PreviewKind.livp:
        await _loadThumb();
        try {
          final r = await session.api!.assets.livePreviewUrl(_a.id);
          if (mounted) _liveUrl = r.url;
        } catch (_) {/* 403/404 → 只显示静态图(web 同口径) */}
        if (mounted) setState(() => _loading = false);
      case PreviewKind.heic:
        await _loadThumb();
        if (mounted) setState(() => _loading = false);
      case PreviewKind.image:
        // svg/avif/ico 超出 Flutter 解码:走缩略图(JPEG 转码),无则色块
        if (kUnDecodableImageExts
            .any((e) => _a.filename.toLowerCase().endsWith(e))) {
          await _loadThumb();
          if (mounted) setState(() => _loading = false);
          return;
        }
        await _loadInlineUrl();
      case PreviewKind.video:
        await _playVideo(await _loadInlineUrl());
      case PreviewKind.markdown || PreviewKind.text:
        await _loadText();
      case PreviewKind.pdf:
        if (Platform.isIOS) await _sharePdf();
        if (mounted) setState(() => _loading = false);
      case PreviewKind.unsupported:
        if (mounted) setState(() => _loading = false);
    }
  }

  /// download-link(inline)原图/媒体 URL;失败置 _fail。
  Future<String?> _loadInlineUrl() async {
    try {
      final url =
          await session.api!.assets.downloadLink(_a.id, asAttachment: false);
      if (mounted) _url = url;
      return url;
    } catch (_) {
      if (mounted) _fail = '预览加载失败';
      return null;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 缩略图大图(heic/livp 静态/不可解码 image);缺失/失败按 P2-6 两态置 _fail。
  Future<void> _loadThumb() async {
    try {
      if (!_a.hasThumbnail) {
        _fail = thumbFailText(_a.tags);
        return;
      }
      _url = await thumbnailCache.urlOf(_a.id);
    } catch (_) {
      _fail = thumbFailText(_a.tags);
    }
  }

  Future<void> _loadText() async {
    try {
      final url =
          await session.api!.assets.downloadLink(_a.id, asAttachment: false);
      // P2-8 大小预检:流式打开先看 Content-Length,>10MB 断流降级,不整包进内存
      // (presigned URL 按 GET 签名,HEAD 会被 MinIO 拒,不能走 HEAD 预检)。
      final cancel = CancelToken();
      final r = await session.api!.presignedHttp.get<ResponseBody>(
        url,
        options: Options(responseType: ResponseType.stream),
        cancelToken: cancel,
      );
      final body = r.data;
      if (body == null) throw StateError('empty response body');
      final len = body.contentLength; // -1 = 未回长度,无从预检则放行
      if (len > kMaxInlineTextBytes) {
        cancel.cancel(); // 断流:超限不缓冲(ResponseBody.close 是 dio 内部 API 勿用)
        if (mounted) {
          _fail = '文件过大(${(len / 1024 / 1024).ceil()}MB),建议下载后打开';
        }
        return;
      }
      final text = await utf8.decodeStream(body.stream);
      if (mounted) _text = text;
    } catch (_) {
      if (mounted) _fail = '预览加载失败';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 视频/实况短片起播;初始化或解码失败(如 Android HEVC .mov)→ 降级色块
  /// (实况落回静态图)。实况短片 loop+静音,web autoPlay loop muted 同口径。
  Future<void> _playVideo(String? url) async {
    if (url == null) return;
    try {
      final c = VideoPlayerController.networkUrl(Uri.parse(url));
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      _vc?.removeListener(_onVideoTick);
      _vc?.dispose();
      if (_kind == PreviewKind.livp) {
        await c.setLooping(true);
        await c.setVolume(0);
      }
      setState(() {
        _vc = c;
        _videoReady = true;
        _playingLive = true;
      });
      c.addListener(_onVideoTick);
      await c.play();
    } catch (_) {
      if (mounted) {
        setState(() {
          if (_kind == PreviewKind.livp) {
            _playingLive = false; // 实况播放失败落回静态图
          } else {
            _fail = '视频解码失败,建议下载后打开';
          }
        });
      }
    }
  }

  /// pdf iOS:dio 下载临时文件 → share_plus 面板(快速预览/存储到文件);
  /// Android 本批色块占位,B4 随 media_store_plus 落盘矩阵点亮(决策 #1)。
  Future<void> _sharePdf() async {
    try {
      final url = await session.api!.assets.downloadLink(_a.id);
      final save = '${Directory.systemTemp.path}/${_a.filename}';
      await session.api!.assets.downloadTo(url, save);
      await SharePlus.instance.share(ShareParams(files: [XFile(save)]));
    } catch (_) {
      if (mounted) _fail = 'PDF 加载失败';
    }
  }

  /// livp 实况/静态回切(P2-2,web 同款按钮语义):
  /// 静态→实况:控制器已就绪直接续播,否则起播(首播/失败重试);
  /// 实况→静态:暂停(控制器保留,再切回续播)。
  void _toggleLive() {
    if (_playingLive) {
      setState(() {
        _playingLive = false;
        _vc?.pause();
      });
      return;
    }
    if (_videoReady && _vc != null) {
      setState(() => _playingLive = true);
      _vc!.play();
    } else {
      _playVideo(_liveUrl);
    }
  }

  /// 视频 播放/暂停(P2-1):起播自动播,点画面/按钮切换。
  void _togglePlay() {
    final v = _vc?.value;
    if (v == null) return;
    v.isPlaying ? _vc!.pause() : _vc!.play();
  }

  @override
  Widget build(BuildContext context) {
    if (_kind == PreviewKind.unsupported) return _block('该类型暂不支持预览');
    if (_kind == PreviewKind.pdf && !Platform.isIOS) {
      return _block('PDF 预览后续版本开放');
    }
    return Center(
      child: _loading
          ? const CircularProgressIndicator(color: Colors.white70)
          : _render(),
    );
  }

  Widget _render() {
    switch (previewBodyPlan(
      kind: _kind,
      videoReady: _videoReady && _vc != null,
      hasFail: _fail != null,
      hasUrl: _url != null,
    )) {
      case PreviewBody.block:
        return _block(_fail ?? '暂无可预览内容');
      case PreviewBody.markdown:
        return DocSheet(child: MarkdownBody(data: _text ?? ''));
      case PreviewBody.text:
        return DocSheet(
          child: SelectableText(
            _text ?? '',
            style: const TextStyle(fontSize: 13, color: Tk.fg),
          ),
        );
      case PreviewBody.pdf:
        return PdfReadyPanel(onShare: _sharePdf);
      case PreviewBody.player:
        return _player();
      case PreviewBody.image:
        return _image();
      case PreviewBody.loading:
        return const Center(child: CircularProgressIndicator(color: Colors.white70));
    }
  }

  Widget _image() {
    final stack = <Widget>[
      InteractiveViewer(
        maxScale: 4,
        child: Image.network(
          _url!,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => _block('图片解码失败,建议下载后打开'),
        ),
      ),
    ];
    // livp 起播中:静态图上叠加加载圈
    if (_playingLive && _kind == PreviewKind.livp && !_videoReady) {
      stack.add(const Positioned.fill(
        child: Center(
            child: CircularProgressIndicator(color: Colors.white70)),
      ));
    }
    // livp 回切按钮(P2-2):静态态显「播放实况」(web liveUrl 非空才出按钮)
    if (_kind == PreviewKind.livp && _liveUrl != null && !_playingLive) {
      stack.add(_liveToggle());
    }
    return Stack(fit: StackFit.expand, children: stack);
  }

  Widget _liveToggle() => Positioned(
        left: 0,
        right: 0,
        bottom: 16,
        child: Center(
          child: TextButton.icon(
            onPressed: _toggleLive,
            style: TextButton.styleFrom(
              backgroundColor: Colors.black54,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            ),
            icon: Icon(
              _playingLive ? Icons.image_outlined : Icons.play_arrow,
              size: 16,
            ),
            label: Text(_playingLive ? '查看照片' : '播放实况'),
          ),
        ),
      );

  Widget _player() {
    final v = _vc!.value;
    final isLive = _kind == PreviewKind.livp; // 实况短片无控制条(web 同口径)
    return AspectRatio(
      aspectRatio: v.aspectRatio == 0 ? 16 / 9 : v.aspectRatio,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          VideoPlayer(_vc!),
          if (!isLive) ...[
            // P2-1:点画面切换播放/暂停
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _togglePlay,
              child: const SizedBox.expand(),
            ),
            Center(
              child: IconButton.filled(
                onPressed: _togglePlay,
                icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow,
                    size: 32),
                style: IconButton.styleFrom(backgroundColor: Colors.black54),
              ),
            ),
            VideoProgressIndicator(
              _vc!,
              allowScrubbing: true, // P2-1:进度条可拖动
              colors: const VideoProgressColors(playedColor: Tk.accent),
            ),
            // P2-1:进度/时长角标(悬于进度条上方右侧)
            Positioned(
              right: 8,
              bottom: 14,
              child: Text(
                '${videoClock(v.position)} / ${videoClock(v.duration)}',
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
          ],
          if (isLive) _liveToggle(), // 实况在播 →「查看照片」回切
        ],
      ),
    );
  }

  Widget _block(String msg) => PreviewBlock(
        kind: _kind,
        filename: _a.filename,
        message: msg,
      );
}
