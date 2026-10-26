/// PreviewImageView — 预览媒体区渲染/手势层(D10 从 preview_media 拆出,
/// 纯迁移零行为变化):
/// - 渲染分支装配:Image 装配([_previewImage])、InteractiveViewer 装配
///   ([_image])、播放器挂载([_player])、实况回切([_liveToggle])、
///   正文/失败卡/PDF 面板分支([_render]);
/// - 手势:C2/C3 单击/双击「双击窗口」手动消歧([_onTapUp])、双击
///   1x↔2.5x 缩放动画([_handleDoubleTap])、捏合与横滑判定
///   ([_onInteraction*])。
/// 状态(加载/URL/失败/播放态)由 PreviewMedia(加载编排与状态机)持有,
/// 经 props 注入;状态变更经 on* 回调上抛(切沉浸/切页/放大让位/实况切换/
/// 播放器就绪与失败)。G2(app-polish-2):捏合/双击放大 >1.5x 经
/// [PreviewImageView.onOriginalRequest] 触发原图签发(本层不关心签发编排)。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart'
    show kDoubleTapSlop, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../core/preview_kind.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import 'preview_doc_views.dart';
import 'preview_player.dart';
import 'preview_plan.dart';

/// P3(mobile-ux-polish)横滑切页阈值(位移 px / 速度 px·s⁻¹):
/// 内层(InteractiveViewer 交互回调)与外层(preview_page GestureDetector)
/// 两路判定共用同一口径;一次滑动手势只会被 arena 判给其中一路,不双触发。
const kSwipeDistanceThreshold = 60.0;
const kSwipeVelocityThreshold = 500.0;

/// C3:双击放大目标倍率(规格 2.5x;捏合上限 maxScale 4 不变)。
const double kDoubleTapScale = 2.5;

/// G2:放大触发原图签发的缩放阈值(捏合/双击超过即签,规格 1.5x)。
const double kOriginalZoomThreshold = 1.5;

class PreviewImageView extends StatefulWidget {
  const PreviewImageView({
    super.key,
    required this.asset,
    required this.kind,
    required this.loading,
    required this.onToggleLive,
    required this.onPlayerReady,
    required this.onPlayerError,
    required this.onSharePdf,
    this.url,
    this.text,
    this.fail,
    this.thumbFallback = false,
    this.videoReady = false,
    this.playerDead = false,
    this.playingLive = false,
    this.playUrl,
    this.liveUrl,
    this.onSingleTap,
    this.onSwipe,
    this.onZoomChanged,
    this.onOriginalRequest,
    this.onImageDecodeFailed,
  });

  final Asset asset;
  final PreviewKind kind;

  /// 首轮加载中(true=加载圈;PreviewMedia 状态机持有)。
  final bool loading;

  /// 可直接呈现的图 URL(原图 inline / 缩略图)。
  final String? url;

  /// md/text 正文。
  final String? text;

  /// 降级提示(色块 + 下载后打开)。
  final String? fail;

  /// P7/G2:缩略图兜底提示条(原图 inline 失败回退/放大签原图失败保持)。
  final bool thumbFallback;

  /// 播放器就绪/死亡/在播态(PreviewMedia 状态机持有)。
  final bool videoReady;
  final bool playerDead;
  final bool playingLive;

  /// 播放器挂载 URL(video=原图 inline;livp=实况短片)。
  final String? playUrl;

  /// livp 实况短片 URL(非空才有回切按钮,web 同口径)。
  final String? liveUrl;

  /// C2:媒体区单击(图片分支经双击窗口消歧后上抛;页面沉浸切换)。
  final VoidCallback? onSingleTap;

  /// P3:未放大态单指横滑切页(true=下一张/false=上一张)。
  final ValueChanged<bool>? onSwipe;

  /// P3:图片放大态(scale>1)回报(外层横滑切页据此让位)。
  final ValueChanged<bool>? onZoomChanged;

  /// G2:捏合/双击放大越过 [kOriginalZoomThreshold](签发编排归
  /// PreviewMedia;去重与失败回退均在状态机侧)。
  final VoidCallback? onOriginalRequest;

  /// P2-1:Image 下载/解码失败(errorBuilder)上抛(失败 URL;回退编排——
  /// 缩略图可用则 post-frame 回退缩略图——归 PreviewMedia 状态机)。
  final ValueChanged<String>? onImageDecodeFailed;

  /// livp 实况/静态回切(状态机切换 _playingLive)。
  final VoidCallback onToggleLive;

  /// 播放器起播就绪/失败(状态机置 _videoReady/_playerDead/_fail 等)。
  final VoidCallback onPlayerReady;
  final VoidCallback onPlayerError;

  /// pdf iOS 面板「分享/打开」(dio 下载临时文件 → share_plus)。
  final VoidCallback onSharePdf;

  @override
  State<PreviewImageView> createState() => _PreviewImageViewState();
}

class _PreviewImageViewState extends State<PreviewImageView>
    with TickerProviderStateMixin {
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

  PreviewKind get _kind => widget.kind;

  @override
  void dispose() {
    _tapWindow?.cancel();
    _zoomCtrl.dispose();
    _transform.dispose();
    super.dispose();
  }

  /// P3:交互中按当前缩放分流——未放大(scale≈1)累计横滑位移(供切页判定),
  /// 放大后位移归 InteractiveViewer 平移,不再累计。
  /// G2:捏合放大越过 1.5x 阈值即触发原图签发(去重内闸在状态机侧,连发安全)。
  void _onInteractionUpdate(ScaleUpdateDetails d) {
    if (_transform.value.getMaxScaleOnAxis() <= 1.01) {
      _swipeDx += d.focalPointDelta.dx;
    }
    if (_transform.value.getMaxScaleOnAxis() > kOriginalZoomThreshold) {
      widget.onOriginalRequest?.call();
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
    // G2:双击放大目标 2.5x > 1.5x 阈值 → 触发原图签发(去重内闸在状态机侧)
    if (zoomTo) widget.onOriginalRequest?.call();
  }

  /// 当前渲染分支是否图片(复用 plan 纯函数;决定双击缩放手势是否注册)。
  bool get _zoomable {
    if (widget.loading || widget.fail != null || widget.url == null) {
      return false;
    }
    return previewBodyPlan(
          kind: _planKind,
          videoReady: widget.videoReady,
          hasFail: widget.fail != null,
          hasUrl: widget.url != null,
          playingLive: widget.playingLive,
        ) ==
        PreviewBody.image;
  }

  /// 渲染分支判定用的 kind(P7:视频 inline 失败回退缩略图 → 按静态图渲染)。
  PreviewKind get _planKind =>
      widget.thumbFallback && _kind == PreviewKind.video
          ? PreviewKind.image
          : _kind;

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
      return _tapRegion(AndroidPdfPanel(asset: widget.asset));
    }
    final core = Center(
      child: widget.loading
          ? const CircularProgressIndicator(color: Colors.white70)
          : _render(),
    );
    Widget content = core;
    // P7/G2:缩略图兜底(原图 inline 失败回退/放大签原图失败保持)时叠加
    // 不打断的小字提示(纯展示,手势穿透不阻断查看)
    if (widget.thumbFallback) {
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
    final body = previewBodyPlan(
      kind: _planKind,
      videoReady: widget.videoReady,
      hasFail: widget.fail != null,
      hasUrl: widget.url != null,
      playingLive: widget.playingLive,
    );
    switch (body) {
      case PreviewBody.block:
        return _block(widget.fail ?? '暂无可预览内容');
      case PreviewBody.markdown:
        return DocSheet(child: MarkdownBody(data: widget.text ?? ''));
      case PreviewBody.text:
        return DocSheet(
          child: SelectableText(
            widget.text ?? '',
            style: const TextStyle(fontSize: Tk.fzMd, color: Tk.previewFg),
          ),
        );
      case PreviewBody.pdf:
        return PdfReadyPanel(onShare: widget.onSharePdf);
      case PreviewBody.player:
      case PreviewBody.loading:
        // loading 且可播 URL 已在:挂播放器(自显转圈;livp 静起播同款)
        if (widget.playUrl != null && !widget.playerDead) return _player();
        return const Center(
            child: CircularProgressIndicator(color: Colors.white70));
      case PreviewBody.image:
        return _image();
    }
  }

  Widget _player() => MediaVideoPlayer(
        key: ValueKey(widget.playUrl!),
        url: widget.playUrl!,
        playing: _kind == PreviewKind.video || widget.playingLive,
        isLive: _kind == PreviewKind.livp,
        onReady: widget.onPlayerReady,
        onError: widget.onPlayerError,
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
            // errorBuilder 处于 build 期,回退经 post-frame setState 落地
            // (编排归 PreviewMedia):本帧先现失败卡,下帧起 fade 回缩略图
            // (同 thumb↔原图交叠款)。
            widget.onImageDecodeFailed?.call(url);
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
        child: _previewImage(widget.url!),
      ),
    ];
    // livp 起播中:静态图上叠加加载圈(播放器 Offstage 预热)
    if (_kind == PreviewKind.livp && widget.playingLive && !widget.videoReady) {
      stack.add(const Positioned.fill(
        child: Center(
            child: CircularProgressIndicator(color: Colors.white70)),
      ));
    }
    // livp 回切按钮(P2-2):静态态显「播放实况」(web liveUrl 非空才出按钮)
    if (_kind == PreviewKind.livp &&
        widget.liveUrl != null &&
        !widget.playingLive) {
      stack.add(_liveToggle());
    }
    // 播放器后台挂载保活(livp 静态态/起播中):暂停续播免重新起播
    if (widget.playUrl != null &&
        !widget.playerDead &&
        bodyBehindImage) {
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
      _kind == PreviewKind.livp && (widget.videoReady || widget.playingLive);

  Widget _liveToggle() => Positioned(
        left: 0,
        right: 0,
        bottom: Tk.spaceLg,
        child: Center(
          child: TextButton.icon(
            onPressed: widget.onToggleLive,
            style: TextButton.styleFrom(
              backgroundColor: Colors.black54,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(
                  horizontal: Tk.spaceLg, vertical: Tk.spaceSm),
            ),
            icon: Icon(
              widget.playingLive ? Icons.image_outlined : Icons.play_arrow,
              size: 16,
            ),
            label: Text(widget.playingLive ? '查看照片' : '播放实况'),
          ),
        ),
      );

  Widget _block(String msg) => PreviewBlock(
        kind: _kind,
        filename: widget.asset.filename,
        message: msg,
      );
}
