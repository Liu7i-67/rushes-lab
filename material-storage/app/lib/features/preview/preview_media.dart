/// PreviewMedia — 预览主体加载编排与状态机(B2 §8.2 八类;D10 拆分后装配层):
/// 决策在 preview_plan.dart(纯函数),md/text 拉取在 preview_text_load.dart,
/// 视频/实况播放器在 preview_player.dart(自持控制器),媒体区渲染与手势在
/// preview_image_view.dart(本层经组合装配)。本层只做加载编排与状态机:
/// 切张由父级以 ValueKey(asset.id) 重建清态;起播/解码失败一律降级
/// 「下载后打开」色块。livp「查看照片」回切显示静态缩略图而非暂停帧
/// (plan playingLive 维度,控制器 Offstage 保活便于续播)。
/// C2/C3(app-polish):媒体区单击上抛在 view 层经双击窗口消歧后回调至此
/// (onSingleTap → 页面切沉浸)。
/// G2(app-polish-2):图片分支两段式渐进加载——进入默认签 thumbnail-url
/// 直显缩略图(不再直接签原图);view 层放大 >1.5x 经 onOriginalRequest
/// 触发签发 download-link 原图,就绪后平滑替换(缩放态不打断,复位不回退);
/// 失败保持缩略图叠 P7 式小字提示。无缩略图资产维持原图 inline,
/// heic/svg 等恒缩略图,livp/视频/PDF 分支零改动。
/// P2-1(app-polish-2 探针实证缺陷修复):放大签发的原图下载/解码失败
/// (Image errorBuilder)时不再落「图片解码失败」失败卡——缩略图可用态
/// 回退保持缩略图+_thumbFallback 提示(与 403 路径同观感),仅无缩略图
/// 可用时保留失败卡。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/preview_kind.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../assets/thumbnail_image.dart' show thumbnailCache;
import 'preview_image_view.dart';
import 'preview_plan.dart';
import 'preview_text_load.dart';

export 'preview_image_view.dart'
    show kSwipeDistanceThreshold, kSwipeVelocityThreshold; // preview_page 既有 import 兼容

class PreviewMedia extends StatefulWidget {
  const PreviewMedia({
    super.key,
    required this.asset,
    this.onSwipe,
    this.onZoomChanged,
    this.onSingleTap,
  });

  final Asset asset;

  /// P3:未放大态单指横滑切页(仅图片分支经 InteractiveViewer 交互回调上报,
  /// true=下一张/false=上一张;其余分支由外层 GestureDetector 统一处理)。
  final ValueChanged<bool>? onSwipe;

  /// P3(mobile-ux-polish):图片放大态(scale>1)回报——外层横滑切页据此让位
  /// (放大后拖动归 InteractiveViewer 平移,不切页;null=调用方不关心)。
  final ValueChanged<bool>? onZoomChanged;

  /// C2(app-polish):媒体区单击(与 onDoubleTap 同一识别器消歧)。图片分支
  /// 用于页面沉浸态切换;视频分支由播放器内层点按(暂停)优先胜出,不回传。
  final VoidCallback? onSingleTap;

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

  // P7(mobile-ux-polish):原图 inline 失败回退缩略图预览(叠不打断的小字提示)。
  // G2 起图片分支反向复用:放大签原图失败(403/网络)时保持缩略图+同一提示。
  // P2-1:原图签发成功但下载/解码失败(Image errorBuilder)同口径——缩略图
  // 可用则回退保持缩略图+提示,仅无缩略图可用时保留失败卡。
  var _thumbFallback = false;

  // P2-1:本张缩略图 URL(_loadThumb 就绪时记录,不重签)——原图下载/解码
  // 失败时经 errorBuilder 回退复用。
  String? _thumbUrl;

  // G2(app-polish-2)缩略图优先状态机:
  var _showingThumb = false; // 当前 _url 为缩略图(进入默认;换原图后 false)
  var _originalRequested = false; // 本张原图签发去重(缩放反复越线只签一次)

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
        // G2:有缩略图先缩略图直显(原图待放大 >1.5x 再签,见
        // _maybeRequestOriginal);无缩略图维持原图 inline(现状,web 同口径)
        if (_a.hasThumbnail) {
          await _loadThumb();
          if (!mounted) return;
          if (_fail == null) _showingThumb = true;
          setState(() => _loading = false);
        } else {
          await _loadInlineUrl();
        }
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

  /// 缩略图大图(heic/livp 静态/不可解码 image/G2 默认首显);缺失/失败按
  /// P2-6 两态置 _fail。P2-1:URL 就绪时记入 _thumbUrl(原图失败回退复用)。
  Future<void> _loadThumb() async {
    try {
      if (!_a.hasThumbnail) {
        _fail = thumbFailText(_a.tags);
        return;
      }
      _url = _thumbUrl = await thumbnailCache.urlOf(_a.id);
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
  /// Android 改就地面板(C6:下载完成就地「打开」,见 AndroidPdfPanel)。
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

  // ── G2 缩略图优先 + 放大换原图 ────────────────────────────────────────────

  /// 当前张是否允许「放大换原图」:仅普通可解码图片且缩略图在显
  /// (svg/avif/ico/heic 恒缩略图;无缩略图进入时已是原图;其余分支零改动)。
  bool get _canUpgradeToOriginal =>
      _kind == PreviewKind.image &&
      _a.hasThumbnail &&
      !kUnDecodableImageExts
          .any((e) => _a.filename.toLowerCase().endsWith(e)) &&
      _showingThumb &&
      _fail == null;

  /// 缩放(捏合或双击)>1.5x 触发一次原图签发;签发去重:同一张预览会话内
  /// 只签一次(反复缩放/复位不重签;切张重建 State 后视为新会话)。
  /// view 层手势回调连发安全(本层同步置位去重)。
  void _maybeRequestOriginal() {
    if (!_canUpgradeToOriginal || _originalRequested) return;
    _originalRequested = true; // 同步置位,手势连发不双签
    _requestOriginal();
  }

  /// 签发 download-link 原图并平滑替换:就绪后仅换 _url(fade 由渲染层
  /// AnimatedSwitcher 承担,InteractiveViewer/变换矩阵不动,缩放态不打断;
  /// 复位 1x 不回退);失败(403 无下载权/网络)保持缩略图,叠 P7 式小字提示。
  /// 切张防串:State 随 asset.id 重建,旧请求落地经 mounted 守卫丢弃。
  Future<void> _requestOriginal() async {
    try {
      final url =
          await session.api!.assets.downloadLink(_a.id, asAttachment: false);
      if (!mounted) return;
      setState(() {
        _url = url;
        _showingThumb = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _thumbFallback = true);
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

  /// P2-1:Image 下载/解码失败(view 层 errorBuilder 上抛)——缩略图可用态
  /// 回退保持缩略图 + 提示;errorBuilder 处于 build 期,回退经 post-frame
  /// setState 落地:本帧先现失败卡,下帧起 fade 回缩略图。
  void _onImageDecodeFailed(String url) {
    if (_thumbUrl != null && url != _thumbUrl) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _url = _thumbUrl;
          _showingThumb = true;
          _thumbFallback = true; // 复位不重签(_originalRequested 保持)
        });
      });
    }
  }

  /// P3:播放器就绪/失败(状态机侧;view 层挂载)。
  void _onPlayerReady() {
    if (!mounted) return;
    setState(() => _videoReady = true);
  }

  void _onPlayerError() {
    if (!mounted) return;
    setState(() {
      _playerDead = true;
      if (_kind == PreviewKind.livp) {
        _playingLive = false; // 实况起播失败落回静态图(可重试)
      } else {
        _fail = '视频解码失败,建议下载后打开';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PreviewImageView(
      asset: _a,
      kind: _kind,
      loading: _loading,
      url: _url,
      text: _text,
      fail: _fail,
      thumbFallback: _thumbFallback,
      videoReady: _videoReady,
      playerDead: _playerDead,
      playingLive: _playingLive,
      playUrl: _playUrl,
      liveUrl: _liveUrl,
      onSingleTap: widget.onSingleTap,
      onSwipe: widget.onSwipe,
      onZoomChanged: widget.onZoomChanged,
      onOriginalRequest: _maybeRequestOriginal,
      onImageDecodeFailed: _onImageDecodeFailed,
      onToggleLive: _toggleLive,
      onPlayerReady: _onPlayerReady,
      onPlayerError: _onPlayerError,
      onSharePdf: _sharePdf,
    );
  }
}
