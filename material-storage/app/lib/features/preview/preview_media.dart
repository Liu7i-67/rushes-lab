/// PreviewMedia — 预览主体加载编排与状态机(B2 §8.2 八类;D10 拆分后装配层):
/// 决策在 preview_plan.dart(纯函数),md/text 拉取在 preview_text_load.dart,
/// 视频/实况播放器在 preview_player.dart(自持控制器),媒体区渲染与手势在
/// preview_image_view.dart(W4+W6 改造落在本层组合的 view)。本层只做加载
/// 编排与状态机:切张由父级以 ValueKey(asset.id) 重建清态;起播/解码失败
/// 一律降级「下载后打开」色块。livp「查看照片」回切显示静态缩略图而非暂停帧
/// (plan playingLive 维度,控制器 Offstage 保活便于续播)。
/// C2/C3(app-polish):媒体区单击上抛在 view 层经双击窗口消歧后回调至此
/// (onSingleTap → 页面切沉浸)。
/// W4 #19-#21(app-thumbnail-storm-fix,用户拍板 D4):放大永不自动换原图——
/// G2 升级链路(_maybeRequestOriginal/_requestOriginal/AnimatedSwitcher 等)
/// 整体删除;livePreviewUrl 与 _loadThumb 并行发起(冷缓存 live URL 不被
/// 缩略图字节最坏 20s 阻塞),_loading 在 _loadThumb 落定即 false,晚到
/// live URL 经 setState 刷新出「播放实况」按钮;视频/PDF/text/markdown 零改动。
/// W6 #23-#26(app-thumbnail-storm-fix):缩略图统一数据源——先读磁盘
/// ThumbDiskStore(命中零网络 Image.memory 直出),未命中经共享取字节入口
/// fetchThumb(与宫格/胶片条共享任务去重,受并发 6 闸 + 20s 硬超时治理)并
/// 按磁盘代数写盘;失败/取消/超时统一 P2-6 两态文案落失败卡,不弹报错页。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/preview_kind.dart';
import '../../core/session.dart';
import '../../core/thumb_disk_store.dart';
import '../../core/thumb_fetch.dart';
import '../../core/thumb_pipeline.dart' show ThumbHandle;
import '../../core/thumb_variant.dart';
import '../../models/models.dart';
import 'preview_image_view.dart';
import 'preview_plan.dart';
import 'preview_text_load.dart';

export 'preview_image_view.dart'
    show
        kSwipeDistanceThreshold,
        kSwipeVelocityThreshold; // preview_page 既有 import 兼容

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
  /// W6:预览缩略图 UI 总等待上限(自进入预览起算、含管线排队——与管线
  /// deadline「执行起算」不同口径;有意为之的双重上限)。
  static const _thumbWaitLimit = Duration(seconds: 20);

  var _loading = true;
  Uint8List? _thumbBytes; // W6:缩略图字节(磁盘直读/共享取字节;非空恒 Image.memory)
  String? _url; // 可直接呈现的图 URL(W6 语义:仅无缩略图原图 inline;video 播放 inline)
  String? _text; // md/text 内容
  String? _fail; // 降级提示(色块 + 下载后打开)
  var _videoReady = false;
  var _playerDead = false; // 起播/解码失败后停挂播放器(重试时复位)
  String? _liveUrl; // livp 实况短片(非空才有回切按钮,web 同口径)
  var _playingLive = false; // livp 在播实况短片;video 类就绪即 true

  // P7(mobile-ux-polish):原图 inline 失败回退缩略图预览(叠不打断的小字
  // 提示,视频 inline 失败同口径降级为静态帧渲染)。
  var _thumbFallback = false;

  // W6 #23:共享取字节任务句柄。每 State 生命周期只允许发起一次——切张由
  // 父级 ValueKey(asset.id) 重建 State 保证;重入会泄漏旧句柄无人 cancel。
  ThumbHandle? _thumbHandle;

  // W6 #23/#25:本次加载捕获的磁盘代数(read 前捕获,贯穿 write/remove,
  // 防跨代误写/误删)。
  int _thumbGen = 0;

  Asset get _a => widget.asset;

  PreviewKind get _kind =>
      detectKind(filename: _a.filename, contentType: _a.contentType);

  /// 播放器挂载 URL:video=原图 inline;livp=实况短片(W6:语义不变)。
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
    // W6 #23:横切/退出即取消共享任务(最后订阅者离开 → 管线终止/释放名额),
    // 防任务残留占名额与 watchdog 至 20s。
    _thumbHandle?.cancel();
    _thumbHandle = null;
    super.dispose();
  }

  Future<void> _load() async {
    switch (_kind) {
      case PreviewKind.livp:
        // W4 #21:livePreviewUrl 与 _loadThumb 并行发起(冷缓存下 live URL
        // 不被缩略图字节最坏 20s 阻塞,断网 35s 落降级破验收 2)。
        final live = _loadLiveUrl();
        await _loadThumb();
        if (mounted) setState(() => _loading = false);
        await live;
      case PreviewKind.heic:
        await _loadThumb();
        if (mounted) setState(() => _loading = false);
      case PreviewKind.image:
        // svg/avif/ico 超出 Flutter 解码:走缩略图(JPEG 转码),无则色块
        if (kUnDecodableImageExts.any(
          (e) => _a.filename.toLowerCase().endsWith(e),
        )) {
          await _loadThumb();
          if (mounted) setState(() => _loading = false);
          return;
        }
        // W4/W6:有缩略图缩略图直显(磁盘直读/共享取字节,放大恒缩略图);
        // 无缩略图维持原图 inline(现状,web 同口径)
        if (_a.hasThumbnail) {
          await _loadThumb();
          if (mounted) setState(() => _loading = false);
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

  /// livp 实况短片 URL(W4 #21 并行发起;失败静默回退静态图,web 同口径)。
  /// 晚到的 live URL 必须 setState——并行后 _loading=false 的刷新先于本回调,
  /// 不 setState 则「播放实况」按钮/播放器永不出现。
  Future<void> _loadLiveUrl() async {
    try {
      final r = await session.api!.assets.livePreviewUrl(_a.id);
      if (mounted) setState(() => _liveUrl = r.url);
    } catch (_) {
      /* 403/404 → 只显示静态图(web 同口径) */
    }
  }

  /// download-link(inline)原图/媒体 URL;失败置 _fail。
  /// P7(mobile-ux-polish):失败(403 无下载权/网络错)时若有缩略图则回退
  /// 缩略图预览(叠不打断的小字提示,不阻断查看);无缩略图维持原失败卡。
  /// 视频 inline 失败同口径降级(渲染侧按静态图处理,不再挂播放器)。
  Future<void> _loadInlineUrl() async {
    try {
      final url = await session.api!.assets.downloadLink(
        _a.id,
        asAttachment: false,
      );
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

  /// W6 #23:缩略图数据源(顺序写死)——
  /// ① 无 thumbnail_key 直接两态失败卡(不读盘,走现状 inline/失败分支);
  /// ② 捕获磁盘代数 → ThumbDiskStore.read(读返回后先查 mounted——read 期间
  ///    dispose 直接返回不发 fetch,防无人取消的任务占名额至 20s;再校验代数,
  ///    跨代丢弃视同 miss:重新捕获当前代数续走,不得直接 return——三空会
  ///    永久转圈)→ 命中记 _thumbBytes 零网络;
  /// ③ miss 经共享取字节入口 fetchThumb(与宫格/胶片条共享任务不重复下载),
  ///    句柄存 _thumbHandle(dispose 必 cancel);外层 .timeout(20s) 为 UI
  ///    总等待上限,onTimeout 先 cancel 再落失败;成功记 _thumbBytes 并按
  ///    捕获代数写盘(fire-and-forget);收到 null(cancel/clear)仍 mounted
  ///    也置 _fail(防 _thumbBytes/_url/_fail 三空永久 loading)。
  /// 签名/下载失败(404/5xx/网络)统一 P2-6 两态文案置 _fail。
  /// thumb-variant 批 D1:**缩略图恒 large**(磁盘直读/fetchThumb/写盘同规格
  /// 传 [ThumbVariant.large],写盘落 `<id>.lg.bin`)——预览清晰度上限 1024,
  /// W4「放大不换原图」与 W6「重开零网络」语义均不变;宫格/胶片条/搜索行的
  /// small 变体不进预览链。
  Future<void> _loadThumb() async {
    if (!_a.hasThumbnail) {
      _fail = thumbFailText(_a.tags);
      return;
    }
    final id = _a.id;
    // 恒 large(见方法注释):磁盘直读与 fetchThumb 同规格,与宫格 small 互不串
    const variant = ThumbVariant.large;
    try {
      // 磁盘代数必须在 read 之前捕获(write 紧前才捕获形同虚设)
      var gen = ThumbDiskStore.I.generation;
      _thumbGen = gen;
      final cached = await ThumbDiskStore.I.read(id, variant: variant);
      if (!mounted) return; // read 期间 dispose:不发 fetch
      final nowGen = ThumbDiskStore.I.generation;
      if (nowGen != gen) {
        // read 期间 clear(跨代):丢弃视同 miss,重新捕获当前代数继续
        gen = nowGen;
        _thumbGen = nowGen;
      }
      if (cached != null) {
        setState(() => _thumbBytes = cached); // 磁盘命中:零网络直出
        return;
      }
      final handle = fetchThumb(id, variant: variant);
      _thumbHandle = handle; // 每 State 只发起一次(见字段注释)
      final bytes = await handle.future.timeout(
        _thumbWaitLimit,
        onTimeout: () {
          // UI 总等待上限(含排队):先取消任务再落失败
          handle.cancel();
          throw TimeoutException('预览缩略图等待超时', _thumbWaitLimit);
        },
      );
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty) {
        // cancel(null)/clear:仍 mounted 也落失败,防三空永久 loading
        setState(() => _fail = thumbFailText(_a.tags));
        return;
      }
      setState(() => _thumbBytes = bytes);
      // 写盘 fire-and-forget(带捕获代数;全局写互斥在 store 内部);large 落
      // `<id>.lg.bin`,保留「取到字节即写盘」现状(W6 语义不变,不回退)
      ThumbDiskStore.I
          .write(id, bytes, expectedGeneration: gen, variant: variant)
          .ignore();
    } catch (_) {
      // 签名失败(404/5xx)/下载失败/超时:统一两态文案(p7-both 500 语义同)
      if (mounted) setState(() => _fail = thumbFailText(_a.tags));
    }
  }

  /// md/text 正文(拆 preview_text_load.dart;P2-8 超限断流降级)。
  Future<void> _loadText() async {
    try {
      final url = await session.api!.assets.downloadLink(
        _a.id,
        asAttachment: false,
      );
      final text = await fetchInlineText(
        (token) => openPresignedStream(
          session.api!.presignedHttp,
          url,
          cancelToken: token,
        ),
      );
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

  /// W6 #25:Image.memory 解码失败(view 层 errorBuilder 上抛)——删盘上
  /// 坏字节(带捕获代数,防跨代误删新会话写入)+ post-frame 置失败卡
  /// (文案与「预览图还在生成」语义区分;同时清 _thumbFallback 防视频回退
  /// 分支残留矛盾提示)。
  void _onThumbDecodeFailed() {
    final id = _a.id;
    final gen = _thumbGen;
    // 解码失败的是预览自己取的 large 字节:按 large 删盘(防误删宫格 small 文件)
    ThumbDiskStore.I
        .remove(id, expectedGeneration: gen, variant: ThumbVariant.large)
        .ignore();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _fail = '图片解码失败,建议下载后打开';
        _thumbFallback = false;
      });
    });
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
      thumbBytes: _thumbBytes,
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
      onThumbDecodeFailed: _onThumbDecodeFailed,
      onToggleLive: _toggleLive,
      onPlayerReady: _onPlayerReady,
      onPlayerError: _onPlayerError,
      onSharePdf: _sharePdf,
    );
  }
}
