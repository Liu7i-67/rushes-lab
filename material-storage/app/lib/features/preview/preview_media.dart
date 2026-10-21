/// PreviewMedia — 预览主体渲染(B2 §8.2 八类;B2 遗留拆分后装配层):
/// 决策在 preview_plan.dart(纯函数),md/text 拉取在 preview_text_load.dart,
/// 视频/实况播放器在 preview_player.dart(自持控制器)。本层只做加载编排与
/// 组装:切张由父级以 ValueKey(asset.id) 重建清态;起播/解码失败一律降级
/// 「下载后打开」色块。livp「查看照片」回切显示静态缩略图而非暂停帧
/// (plan playingLive 维度,控制器 Offstage 保活便于续播)。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/preview_kind.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../assets/thumbnail_image.dart' show thumbnailCache;
import 'preview_doc_views.dart';
import 'preview_player.dart';
import 'preview_plan.dart';
import 'preview_text_load.dart';

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
  var _videoReady = false;
  var _playerDead = false; // 起播/解码失败后停挂播放器(重试时复位)
  String? _liveUrl; // livp 实况短片(非空才有回切按钮,web 同口径)
  var _playingLive = false; // livp 在播实况短片;video 类就绪即 true

  Asset get _a => widget.asset;

  PreviewKind get _kind =>
      detectKind(filename: _a.filename, contentType: _a.contentType);

  /// 播放器挂载 URL:video=原图 inline;livp=实况短片。
  String? get _playUrl => switch (_kind) {
        PreviewKind.video => _url,
        PreviewKind.livp => _liveUrl,
        _ => null,
      };

  @override
  void initState() {
    super.initState();
    _load();
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
        await _loadInlineUrl(); // URL 就绪即挂播放器(plan loading 分支可见)
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
  Future<void> _loadInlineUrl() async {
    try {
      final url =
          await session.api!.assets.downloadLink(_a.id, asAttachment: false);
      if (mounted) _url = url;
    } catch (_) {
      if (mounted) _fail = '预览加载失败';
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

  /// md/text 正文(拆 preview_text_load.dart;P2-8 超限断流降级)。
  Future<void> _loadText() async {
    try {
      final url =
          await session.api!.assets.downloadLink(_a.id, asAttachment: false);
      final text = await fetchInlineText((token) =>
          openPresignedStream(session.api!.presignedHttp, url,
              cancelToken: token));
      if (mounted) _text = text;
    } on TextTooLargeException catch (e) {
      if (mounted) {
        _fail = '文件过大(${(e.sizeBytes / 1024 / 1024).ceil()}MB),建议下载后打开';
      }
    } catch (_) {
      if (mounted) _fail = '预览加载失败';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// pdf iOS:dio 下载临时文件 → share_plus 面板(快速预览/存储到文件);
  /// Android 改「下载后打开」(§8.2/B4 功能点 5:点下方「下载」→ Downloads)。
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

  /// livp 实况/静态回切(P2-2,web 同款按钮语义):静态→实况:控制器已就绪
  /// 直接续播,否则起播(首播/失败重试);实况→静态:暂停保活,显示静态缩略图。
  void _toggleLive() {
    if (_playingLive) {
      setState(() => _playingLive = false); // 控制器保留,plan 转 image 分支
      return;
    }
    setState(() {
      _playerDead = false; // 失败重试:重新挂播放器
      _playingLive = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_kind == PreviewKind.unsupported) return _block('该类型暂不支持预览');
    if (_kind == PreviewKind.pdf && !Platform.isIOS) {
      return _block('PDF 需下载后打开(保存在 Download/浣花视界)');
    }
    return Center(
      child: _loading
          ? const CircularProgressIndicator(color: Colors.white70)
          : _render(),
    );
  }

  Widget _render() {
    final body = previewBodyPlan(
      kind: _kind,
      videoReady: _videoReady,
      hasFail: _fail != null,
      hasUrl: _url != null,
      playingLive: _playingLive,
    );
    switch (body) {
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
      case PreviewBody.loading:
        // loading 且可播 URL 已在:挂播放器(自显转圈;livp 静起播同款)
        if (_playUrl != null && !_playerDead) return _player();
        return const Center(
            child: CircularProgressIndicator(color: Colors.white70));
      case PreviewBody.image:
        return _image();
    }
  }

  Widget _player() => MediaVideoPlayer(
        key: ValueKey(_playUrl!),
        url: _playUrl!,
        playing: _kind == PreviewKind.video || _playingLive,
        isLive: _kind == PreviewKind.livp,
        onReady: () {
          if (!mounted) return;
          setState(() => _videoReady = true);
        },
        onError: () {
          if (!mounted) return;
          setState(() {
            _playerDead = true;
            if (_kind == PreviewKind.livp) {
              _playingLive = false; // 实况起播失败落回静态图(可重试)
            } else {
              _fail = '视频解码失败,建议下载后打开';
            }
          });
        },
      );

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
    // livp 起播中:静态图上叠加加载圈(播放器 Offstage 预热)
    if (_kind == PreviewKind.livp && _playingLive && !_videoReady) {
      stack.add(const Positioned.fill(
        child: Center(
            child: CircularProgressIndicator(color: Colors.white70)),
      ));
    }
    // livp 回切按钮(P2-2):静态态显「播放实况」(web liveUrl 非空才出按钮)
    if (_kind == PreviewKind.livp && _liveUrl != null && !_playingLive) {
      stack.add(_liveToggle());
    }
    // 播放器后台挂载保活(livp 静态态/起播中):暂停续播免重新起播
    if (_playUrl != null && !_playerDead && bodyBehindImage) {
      stack.add(Offstage(
        offstage: true,
        child: _player(),
      ));
    }
    return Stack(fit: StackFit.expand, children: stack);
  }

  /// image 分支下播放器需后台挂载的条件:livp 已有就绪控制器或正在起播
  /// (video 类 plan 恒走 player/loading 分支,不经此处)。
  bool get bodyBehindImage =>
      _kind == PreviewKind.livp && (_videoReady || _playingLive);

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

  Widget _block(String msg) => PreviewBlock(
        kind: _kind,
        filename: _a.filename,
        message: msg,
      );
}
