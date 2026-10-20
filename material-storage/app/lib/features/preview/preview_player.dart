/// MediaVideoPlayer — 预览视频/实况短片播放器(从 preview_media 拆出,B2 遗留
/// 431 行拆分件之一):自持 VideoPlayerController(初始化/销毁/进度监听),
/// 就绪/失败经回调上抛。livp 实况 loop+静音无控制条(web autoPlay loop muted
/// 同口径),播放态由父级 `playing` 驱动(「查看照片/播放实况」回切,B2 遗留
/// 修复:静态态显示缩略图而非暂停帧);普通视频自带点按切换+进度条+角标(P2-1)。
/// 起播/解码失败(如 Android HEVC .mov 硬解设备相关)→ onError 降级「下载后打开」。
library;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../theme/tokens.dart';
import 'preview_plan.dart' show videoClock;

class MediaVideoPlayer extends StatefulWidget {
  const MediaVideoPlayer({
    super.key,
    required this.url,
    required this.playing,
    required this.isLive,
    this.onReady,
    this.onError,
  });

  final String url;

  /// 期望播放态(livp 由父级「查看照片/播放实况」驱动;视频恒 true)。
  final bool playing;

  /// livp 实况短片:loop+静音、无控制条;false=普通视频(控制条+点按切换)。
  final bool isLive;

  /// 控制器初始化成功(首帧可播)。
  final VoidCallback? onReady;

  /// 初始化/解码失败(父级降级:livp 落回静态图,视频落「下载后打开」色块)。
  final VoidCallback? onError;

  @override
  State<MediaVideoPlayer> createState() => _MediaVideoPlayerState();
}

class _MediaVideoPlayerState extends State<MediaVideoPlayer> {
  VideoPlayerController? _vc;
  var _ready = false;
  // 播放态自持:普通视频点按切换只动内部态;widget.playing 变化(回切)同步
  var _playing = false;

  @override
  void initState() {
    super.initState();
    _playing = widget.playing;
    _init();
  }

  @override
  void didUpdateWidget(covariant MediaVideoPlayer old) {
    super.didUpdateWidget(old);
    if (widget.playing != old.playing) {
      _playing = widget.playing;
      _applyPlaying();
    }
  }

  Future<void> _init() async {
    try {
      final c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      if (widget.isLive) {
        await c.setLooping(true);
        await c.setVolume(0);
      }
      setState(() {
        _vc = c;
        _ready = true;
        _playing = widget.playing;
      });
      c.addListener(_onTick);
      _applyPlaying();
      widget.onReady?.call();
    } catch (_) {
      widget.onError?.call(); // 父级降级:livp 落回静态图,视频落色块
    }
  }

  void _applyPlaying() {
    final c = _vc;
    if (c == null || !_ready) return;
    _playing ? c.play() : c.pause();
  }

  /// 播放态驱动重建(P2-1 进度/时长/播放键跟随 value 刷新;实况无控制条但
  /// 播放键图标也随状态变化)。
  void _onTick() {
    if (mounted) setState(() {});
  }

  void _toggle() {
    final c = _vc;
    if (c == null) return;
    setState(() => _playing = !_playing);
    _applyPlaying();
  }

  @override
  void dispose() {
    _vc?.removeListener(_onTick);
    _vc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _vc;
    if (!_ready || c == null) {
      // 起播中转圈;失败态父级已切换呈现,这里兜底同款转圈
      return const Center(
          child: CircularProgressIndicator(color: Colors.white70));
    }
    final v = c.value;
    return AspectRatio(
      aspectRatio: v.aspectRatio == 0 ? 16 / 9 : v.aspectRatio,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          VideoPlayer(c),
          if (!widget.isLive) ...[
            // P2-1:点画面切换播放/暂停
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggle,
              child: const SizedBox.expand(),
            ),
            Center(
              child: IconButton.filled(
                onPressed: _toggle,
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow, size: 32),
                style: IconButton.styleFrom(backgroundColor: Colors.black54),
              ),
            ),
            VideoProgressIndicator(
              c,
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
        ],
      ),
    );
  }
}
