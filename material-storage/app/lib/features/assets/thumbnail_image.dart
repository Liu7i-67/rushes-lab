/// ThumbnailImage — 宫格缩略图(B2 §8.1;app-polish-3 包 B 改造:磁盘优先 + 淡入):
/// tags.thumbnail_key 存在才请求 thumbnail-url(否则端点必 404,web AssetThumbnail
/// 同门槛);位图经 ThumbDiskStore 磁盘缓存——presigned URL ~25min 轮换/冷启动/
/// 二次进入均本地秒出,不再整图重下;加载中纯 Tk.fill 占位(**无 spinner**,
/// 消「白屏→加载动画→显示」三段闪烁),就位 180ms 淡入;签名/下载/解码任一
/// 失败降级类型色块。
library;

import 'dart:io' show BytesBuilder, HttpClient;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/preview_kind.dart';
import '../../core/session.dart';
import '../../core/thumb_disk_store.dart';
import '../../core/thumbnail_cache.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/type_block.dart';

/// 进程级缩略图 URL 缓存(只存 URL 不存位图;位图字节磁盘见 ThumbDiskStore;
/// 签名走会话 API)。
final thumbnailCache = ThumbnailCache(signer: (assetId) async {
  final r = await session.api!.assets.thumbnailUrl(assetId);
  return SignedThumb(url: r.url, expiresInSeconds: r.expiresIn);
});

class ThumbnailImage extends StatefulWidget {
  const ThumbnailImage({super.key, required this.asset, this.fallbackIconSize});

  final Asset asset;

  /// 降级色块图标边长(缺省 32;B7 搜索结果小格 48px 用 20 防 overflow)。
  final double? fallbackIconSize;

  @override
  State<ThumbnailImage> createState() => _ThumbnailImageState();
}

class _ThumbnailImageState extends State<ThumbnailImage> {
  /// presigned 直连裸 HttpClient(无 cookie,预签 host 可能非入口;连接池复用)。
  /// 不走 session.api!.presignedHttp(dio):dio 每请求内置 Timer.run 零时器,
  /// fake-async 单测(Filmstrip 惰性建格)尾部仍在途即报 pending timer;
  /// 裸 HttpClient 与旧 Image.network 同语义,测试下经 HttpOverrides 可注假响应。
  static final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  Uint8List? _bytes;
  bool _failed = false;
  int _tag = 0; // 切 asset / dispose 后在途请求落地即弃(无需 cancel)

  @override
  void initState() {
    super.initState();
    if (widget.asset.hasThumbnail) _load();
  }

  @override
  void didUpdateWidget(covariant ThumbnailImage old) {
    super.didUpdateWidget(old);
    if (old.asset.id == widget.asset.id) return;
    setState(() {
      _bytes = null;
      _failed = false;
    });
    // web 同门槛:无 thumbnail_key 不发签名请求;换到无 key 资产只丢弃在途
    if (widget.asset.hasThumbnail) {
      _load();
    } else {
      _tag++;
    }
  }

  @override
  void dispose() {
    _tag++;
    super.dispose();
  }

  /// 磁盘 → 签 URL → HTTP 字节下载 → 落盘 → setState;任一步异常置 _failed。
  Future<void> _load() async {
    final tag = ++_tag;
    final id = widget.asset.id;
    try {
      final cached = await ThumbDiskStore.I.read(id);
      if (tag != _tag || !mounted) return;
      if (cached != null) {
        setState(() => _bytes = cached);
        return;
      }
      final url = await thumbnailCache.urlOf(id); // 进程级 URL 缓存/单飞重签
      if (tag != _tag || !mounted) return;
      final bytes = await _download(url);
      if (bytes.isEmpty) throw StateError('缩略图响应为空');
      await ThumbDiskStore.I.write(id, bytes);
      if (tag != _tag || !mounted) return;
      setState(() => _bytes = bytes);
    } catch (_) {
      if (tag == _tag && mounted) setState(() => _failed = true);
    }
  }

  /// presigned URL 整包拉取为字节(缩略图量级小,不落临时文件)。
  static Future<Uint8List> _download(String url) async {
    final req = await _http.getUrl(Uri.parse(url));
    final resp = await req.close();
    if (resp.statusCode != 200) {
      await resp.drain<void>();
      throw StateError('缩略图下载失败(${resp.statusCode})');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Widget get _fallback => TypeBlock(
        kind: detectKind(
            filename: widget.asset.filename,
            contentType: widget.asset.contentType),
        filename: widget.asset.filename,
        iconSize: widget.fallbackIconSize,
      );

  @override
  Widget build(BuildContext context) {
    // web 同门槛 + 失败降级:直接类型色块(worker 对非图不生成/下载解码失败)
    if (!widget.asset.hasThumbnail || _failed) return _fallback;
    final bytes = _bytes;
    // 占位纯色,无 CircularProgressIndicator(用户抱怨的第二段闪烁)
    if (bytes == null) return const ColoredBox(color: Tk.fill);
    return LayoutBuilder(builder: (context, box) {
      // 解码降采样:格宽 × dpr 取整 clamp 96..600(省内存;放大预览走他路)
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final px =
          box.maxWidth.isFinite ? (box.maxWidth * dpr).round() : 600;
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: px.clamp(96, 600),
        gaplessPlayback: true,
        // 仅首帧淡入(180ms):字节就位不闪,wasSync(内存缓存命中)直出
        frameBuilder: (context, child, frame, wasSync) => wasSync
            ? child
            : AnimatedOpacity(
                opacity: frame == null ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                child: child,
              ),
        errorBuilder: (_, _, _) => _fallback,
      );
    });
  }
}
