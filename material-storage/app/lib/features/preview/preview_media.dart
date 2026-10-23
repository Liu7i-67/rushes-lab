/// PreviewMedia — 预览主体渲染(B2 §8.2 八类;B2 遗留拆分后装配层):
/// 决策在 preview_plan.dart(纯函数),md/text 拉取在 preview_text_load.dart,
/// 视频/实况播放器在 preview_player.dart(自持控制器)。本层只做加载编排与
/// 组装:切张由父级以 ValueKey(asset.id) 重建清态;起播/解码失败一律降级
/// 「下载后打开」色块。livp「查看照片」回切显示静态缩略图而非暂停帧
/// (plan playingLive 维度,控制器 Offstage 保活便于续播)。
/// C2/C3(app-polish):媒体区统一包一层点按手势——单击经 [PreviewMedia.onSingleTap]
/// 上抛(页面切沉浸);单击/双击用自管「双击窗口」手动消歧(不注册框架
/// onDoubleTap,原因见 _onTapUp 字段注释),双击走图片分支 1x↔2.5x 缩放动画。
/// C6(app-polish):Android PDF 由「需下载后打开」死胡同改为就地面板
/// (下载完成就地「打开」,见 preview_doc_views.AndroidPdfPanel)。
/// G2(app-polish-2):图片分支两段式渐进加载——进入默认签 thumbnail-url
/// 直显缩略图(不再直接签原图);捏合/双击放大 >1.5x 时签发一次
/// download-link 原图,就绪后同 Image fade 平滑替换(缩放态不打断,复位
/// 不回退);失败保持缩略图叠 P7 式小字提示。无缩略图资产维持原图 inline,
/// heic/svg 等恒缩略图,livp/视频/PDF 分支零改动。
/// P2-1(app-polish-2 探针实证缺陷修复):放大签发的原图下载/解码失败
/// (Image errorBuilder)时不再落「图片解码失败」失败卡——缩略图可用态
/// 回退保持缩略图+_thumbFallback 提示(与 403 路径同观感),仅无缩略图
/// 可用时保留失败卡。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart'
    show kDoubleTapSlop, kDoubleTapTimeout;
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

/// C3:双击放大目标倍率(规格 2.5x;捏合上限 maxScale 4 不变)。
const double kDoubleTapScale = 2.5;

/// G2:放大触发原图签发的缩放阈值(捏合/双击超过即签,规格 1.5x)。
const double kOriginalZoomThreshold = 1.5;

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

class _PreviewMediaState extends State<PreviewMedia>
    with TickerProviderStateMixin {
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

  // C3:双击缩放动画(220ms)——双击点为锚点,平移钳制防出界;捏合开始即停。
  late final AnimationController _zoomCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  VoidCallback? _zoomTick; // 当前动画取值监听(每次动画重建,先摘旧的)

  // C2/C3:单击/双击手动消歧。不注册框架 onDoubleTap——其底层
  // DoubleTapGestureRecognizer 在指针按下即挂 40ms 倒计时 Timer 且不可取消,
  // 横滑/捏合(每次 pointer down)都会遗留 pending Timer(widget 测试
  // pending-timer 不变量必炸,真机无碍但测试红线不许)。改自管「双击窗口」:
  // 首击 tapUp 挂 kDoubleTapTimeout 窗口,窗口内第二击(位移 ≤kDoubleTapSlop)
  // =双击缩放;窗口自然到期=单击上抛。拖拽/捏合不产生 tapUp,零 Timer 遗留。
  Timer? _tapWindow;
  var _awaitingSecondTap = false;
  Offset? _doubleTapAnchor;

  // P3:未放大态横滑切页的位移累计——图片分支的手势被 InteractiveViewer 的
  // scale 识别器持有(panEnabled:false 只是让它忽略平移,arena 仍归它),
  // 故在交互回调里按焦距位移/速度手动判切页,阈值口径与外层一致。
  var _swipeDx = 0.0;

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

  @override
  void dispose() {
    _tapWindow?.cancel();
    _zoomCtrl.dispose();
    _transform.dispose();
    super.dispose();
  }

  /// P3:交互中按当前缩放分流——未放大(scale≈1)累计横滑位移(供切页判定),
  /// 放大后位移归 InteractiveViewer 平移,不再累计。
  /// G2:捏合放大越过 1.5x 阈值即触发原图签发(去重内闸,连发安全)。
  void _onInteractionUpdate(ScaleUpdateDetails d) {
    if (_transform.value.getMaxScaleOnAxis() <= 1.01) {
      _swipeDx += d.focalPointDelta.dx;
    }
    if (_transform.value.getMaxScaleOnAxis() > kOriginalZoomThreshold) {
      _maybeRequestOriginal();
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

  // ── C3 双击缩放 ──────────────────────────────────────────────────────────

  /// 捏合开始即停双击动画(实变换以捏合为准,避免两路互写变换矩阵)。
  void _onInteractionStart(ScaleStartDetails d) {
    if (_zoomTick != null) {
      _zoomCtrl.removeListener(_zoomTick!);
      _zoomTick = null;
    }
    if (_zoomCtrl.isAnimating) _zoomCtrl.stop();
  }

  /// C2/C3:tapUp 手动消歧(见字段注释)——非图片分支单击即时上抛;图片
  /// 分支首击挂双击窗口,窗口内近距第二击=双击缩放,否则到期按单击上抛。
  void _onTapUp(TapUpDetails d) {
    if (!_zoomable) {
      widget.onSingleTap?.call();
      return;
    }
    final anchor = _doubleTapAnchor;
    if (_awaitingSecondTap &&
        anchor != null &&
        (d.localPosition - anchor).distance <= kDoubleTapSlop) {
      _tapWindow?.cancel();
      _tapWindow = null;
      _awaitingSecondTap = false;
      _handleDoubleTap(); // 第二击 → 双击缩放(锚点=首击点)
      return;
    }
    _doubleTapAnchor = d.localPosition;
    _awaitingSecondTap = true;
    _tapWindow?.cancel();
    _tapWindow = Timer(kDoubleTapTimeout, _firePendingSingle);
  }

  /// 双击窗口到期未成双 → 按单击上抛(页面沉浸切换)。
  void _firePendingSingle() {
    _tapWindow = null;
    if (!mounted) return;
    if (_awaitingSecondTap) {
      _awaitingSecondTap = false;
      widget.onSingleTap?.call();
    }
  }

  /// 双击 1x↔2.5x(Matrix4Tween 动画;放大锚点=双击点,平移钳制在半幅内
  /// 防出界;复位恒回 identity)。缩放态即时同步(外层横滑让位/交还随动)。
  void _handleDoubleTap() {
    final zoomTo = !_zoomed;
    final box = context.findRenderObject();
    final size = box is RenderBox && box.hasSize ? box.size : Size.zero;
    final anchor = _doubleTapAnchor ?? size.center(Offset.zero);
    final s = zoomTo ? kDoubleTapScale : 1.0;
    final maxT = (s - 1) / 2;
    final tx = zoomTo
        ? (-anchor.dx * (s - 1)).clamp(-maxT * size.width, maxT * size.width)
        : 0.0;
    final ty = zoomTo
        ? (-anchor.dy * (s - 1)).clamp(-maxT * size.height, maxT * size.height)
        : 0.0;
    final target = Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
    if (_zoomTick != null) _zoomCtrl.removeListener(_zoomTick!);
    final anim =
        _zoomCtrl.drive(Matrix4Tween(begin: _transform.value.clone(), end: target));
    void tick() => _transform.value = anim.value;
    _zoomTick = tick;
    _zoomCtrl.addListener(tick);
    _zoomCtrl.forward(from: 0);
    if (_zoomed != zoomTo) {
      setState(() => _zoomed = zoomTo);
      widget.onZoomChanged?.call(zoomTo);
    }
    // G2:双击放大目标 2.5x > 1.5x 阈值 → 签发原图(去重内闸)
    if (zoomTo) _maybeRequestOriginal();
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

  /// 当前渲染分支是否图片(复用 plan 纯函数;决定双击缩放手势是否注册)。
  bool get _zoomable {
    if (_loading || _fail != null || _url == null) return false;
    final planKind = _thumbFallback && _kind == PreviewKind.video
        ? PreviewKind.image
        : _kind;
    return previewBodyPlan(
          kind: planKind,
          videoReady: _videoReady,
          hasFail: _fail != null,
          hasUrl: _url != null,
          playingLive: _playingLive,
        ) ==
        PreviewBody.image;
  }

  /// C2/C3:媒体区点按统一包一层(tapUp 手动消歧,见 _onTapUp 注释)。
  Widget _tapRegion(Widget child) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: _onTapUp,
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    if (_kind == PreviewKind.unsupported) {
      return _tapRegion(_block('该类型暂不支持预览'));
    }
    if (_kind == PreviewKind.pdf && !Platform.isIOS) {
      // C6(app-polish):Android 不再「需下载后打开」死胡同——就地面板可下载可打开
      return _tapRegion(AndroidPdfPanel(asset: _a));
    }
    final core = Center(
      child: _loading
          ? const CircularProgressIndicator(color: Colors.white70)
          : _render(),
    );
    Widget content = core;
    // P7/G2:缩略图兜底(原图 inline 失败回退/放大签原图失败保持)时叠加
    // 不打断的小字提示(纯展示,手势穿透不阻断查看)
    if (_thumbFallback) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          core,
          Positioned(
            left: Tk.spaceLg,
            right: Tk.spaceLg,
            bottom: Tk.spaceMd,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    // 横 10 就近归 spaceSm;竖 5 属同容器比例微缝保留
                    horizontal: 10,
                    vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(Tk.rSm),
                ),
                child: const Text(
                  '原图不可用(无下载权限或加载失败),当前为缩略图预览',
                  style: TextStyle(color: Tk.previewFg2, fontSize: Tk.fzXs),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ],
      );
    }
    return _tapRegion(content);
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
            style: const TextStyle(fontSize: Tk.fzMd, color: Tk.previewFg),
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

  /// G2:缩略图→原图平滑替换——AnimatedSwitcher 同尺寸 fade 交叠(布局恒满幅,
  /// StackFit.expand),InteractiveViewer/变换矩阵不动,缩放态不打断。
  Widget _previewImage(String url) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        // 默认 layoutBuilder 居中 Stack 会让 Image 收缩到内在尺寸,这里恒撑满
        layoutBuilder: (currentChild, previousChildren) => Stack(
          fit: StackFit.expand,
          alignment: Alignment.center,
          children: [
            ...previousChildren,
            ?currentChild,
          ],
        ),
        child: Image.network(
          url,
          key: ValueKey(url), // URL 变化即触发 fade(thumb→原图)
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) {
            // P2-1(测试实证缺陷修复):原图签发成功但下载/解码失败——缩略图
            // 可用态回退保持缩略图(_thumbFallback 叠 P7 式小字提示,与 403
            // 路径同观感),仅无缩略图可用(或失败的正是缩略图)时保留失败卡。
            // errorBuilder 处于 build 期,回退经 post-frame setState 落地:
            // 本帧先现失败卡,下帧起 fade 回缩略图(同 thumb↔原图交叠款)。
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
            return _block('图片解码失败,建议下载后打开');
          },
        ),
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
        onInteractionStart: _onInteractionStart, // C3:捏合打断双击动画
        onInteractionUpdate: _onInteractionUpdate,
        onInteractionEnd: _onInteractionEnd,
        child: _previewImage(_url!),
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
        bottom: Tk.spaceLg,
        child: Center(
          child: TextButton.icon(
            onPressed: _toggleLive,
            style: TextButton.styleFrom(
              backgroundColor: Colors.black54,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(
                  horizontal: Tk.spaceLg, vertical: Tk.spaceSm),
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
