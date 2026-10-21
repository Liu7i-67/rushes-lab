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

/// P3(mobile-ux-polish)横滑切页阈值(位移 px / 速度 px·s⁻¹):
/// 内层(InteractiveViewer 交互回调)与外层(preview_page GestureDetector)
/// 两路判定共用同一口径;一次滑动手势只会被 arena 判给其中一路,不双触发。
const kSwipeDistanceThreshold = 60.0;
const kSwipeVelocityThreshold = 500.0;

class PreviewMedia extends StatefulWidget {
  const PreviewMedia({
    super.key,
    required this.asset,
    this.onSwipe,
    this.onZoomChanged,
  });

  final Asset asset;

  /// P3:未放大态单指横滑切页(仅图片分支经 InteractiveViewer 交互回调上报,
  /// true=下一张/false=上一张;其余分支由外层 GestureDetector 统一处理)。
  final ValueChanged<bool>? onSwipe;

  /// P3(mobile-ux-polish):图片放大态(scale>1)回报——外层横滑切页据此让位
  /// (放大后拖动归 InteractiveViewer 平移,不切页;null=调用方不关心)。
  final ValueChanged<bool>? onZoomChanged;

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

  // P3:图片放大态与变换控制——放大后单指拖动为平移(内层吃掉手势),
  // 捏回原大复位并交还横滑切页。
  var _zoomed = false;
  final _transform = TransformationController();

  // P3:未放大态横滑切页的位移累计——图片分支的手势被 InteractiveViewer 的
  // scale 识别器持有(panEnabled:false 只是让它忽略平移,arena 仍归它),
  // 故在交互回调里按焦距位移/速度手动判切页,阈值口径与外层一致。
  var _swipeDx = 0.0;

  // P7(mobile-ux-polish):原图 inline 失败回退缩略图预览(叠不打断的小字提示)。
  var _thumbFallback = false;

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

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// P3:交互中按当前缩放分流——未放大(scale≈1)累计横滑位移(供切页判定),
  /// 放大后位移归 InteractiveViewer 平移,不再累计。
  void _onInteractionUpdate(ScaleUpdateDetails d) {
    if (_transform.value.getMaxScaleOnAxis() <= 1.01) {
      _swipeDx += d.focalPointDelta.dx;
    }
  }

  /// P3:交互结束分流——未放大则复位变换并按位移/速度判切页(边界即停由
  /// 父级 pager 保证);缩放过则维护放大态(拖动交给 panEnabled:true 平移)。
  void _onInteractionEnd(ScaleEndDetails d) {
    final dx = _swipeDx;
    _swipeDx = 0;
    final zoomedNow = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (!zoomedNow) {
      _transform.value = Matrix4.identity();
      final v = d.velocity.pixelsPerSecond.dx;
      if (dx < -kSwipeDistanceThreshold || v < -kSwipeVelocityThreshold) {
        widget.onSwipe?.call(true);
      } else if (dx > kSwipeDistanceThreshold ||
          v > kSwipeVelocityThreshold) {
        widget.onSwipe?.call(false);
      }
    }
    if (zoomedNow != _zoomed) {
      setState(() => _zoomed = zoomedNow);
      widget.onZoomChanged?.call(zoomedNow);
    }
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
  /// P7(mobile-ux-polish):失败(403 无下载权/网络错)时若有缩略图则回退
  /// 缩略图预览(叠不打断的小字提示,不阻断查看);无缩略图维持原失败卡。
  /// 视频 inline 失败同口径降级(渲染侧按静态图处理,不再挂播放器)。
  Future<void> _loadInlineUrl() async {
    try {
      final url =
          await session.api!.assets.downloadLink(_a.id, asAttachment: false);
      if (mounted) _url = url;
    } catch (_) {
      if (!mounted) return;
      if (_a.hasThumbnail) {
        await _loadThumb(); // 缩略图也失败会置 _fail(既有两态文案)
        // P1-2(测试实证缺陷修复):缩略图确实可用(未置 _fail)才降级提示条;
        // 双失败(原图+缩略图签名/加载都失败)维持失败卡,不再叠自相矛盾的
        // 「当前为缩略图预览」提示。
        if (_fail == null) _thumbFallback = true;
      } else {
        _fail = '预览加载失败';
      }
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
    final core = Center(
      child: _loading
          ? const CircularProgressIndicator(color: Colors.white70)
          : _render(),
    );
    // P7:缩略图降级时叠加不打断的小字提示(纯展示,手势穿透不阻断查看)
    if (!_thumbFallback) return core;
    return Stack(
      fit: StackFit.expand,
      children: [
        core,
        Positioned(
          left: 16,
          right: 16,
          bottom: 12,
          child: Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '原图不可用(无下载权限或加载失败),当前为缩略图预览',
                style: TextStyle(color: Tk.subtle, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _render() {
    // P7:视频 inline 失败回退缩略图 → 不挂播放器,按静态图渲染(可放大看帧)
    final planKind = _thumbFallback && _kind == PreviewKind.video
        ? PreviewKind.image
        : _kind;
    final body = previewBodyPlan(
      kind: planKind,
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
        // P3(mobile-ux-polish):未放大关 pan(交互回调判横滑切页),放大后
        // 开(拖图平移不切页);缩回 ~1 由 _onInteractionEnd 复位交还横滑。
        transformationController: _transform,
        panEnabled: _zoomed,
        minScale: 1,
        maxScale: 4,
        onInteractionUpdate: _onInteractionUpdate,
        onInteractionEnd: _onInteractionEnd,
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
