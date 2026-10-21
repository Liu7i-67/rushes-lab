/// ThumbnailImage — 宫格缩略图(B2 §8.1):tags.thumbnail_key 存在才请求
/// thumbnail-url(否则端点必 404,web AssetThumbnail 同门槛);URL 经
/// ThumbnailCache 过期重签/并发去重/LRU 驱逐;请求或解码失败降级类型色块。
library;

import 'package:flutter/material.dart';

import '../../core/preview_kind.dart';
import '../../core/session.dart';
import '../../core/thumbnail_cache.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/type_block.dart';

/// 进程级缩略图 URL 缓存(只存 URL 不存位图;签名走会话 API)。
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
  late Future<String>? _future;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant ThumbnailImage old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id) _resolve();
  }

  void _resolve() {
    // web 同门槛:无 thumbnail_key 不发签名请求(B2 遗留:initState 曾无条件
    // urlOf,无 key 资产也打一发注定 404 的请求;B3 单测暴露 pending timer 顺手修)
    _future =
        widget.asset.hasThumbnail ? thumbnailCache.urlOf(widget.asset.id) : null;
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
    // web 同门槛:无 thumbnail_key 不打请求,直接色块(worker 对非图不生成)
    if (!widget.asset.hasThumbnail) return _fallback;
    return FutureBuilder<String>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const ColoredBox(
            color: Tk.fill,
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        if (snap.hasError) return _fallback;
        return Image.network(
          snap.data!,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, _, _) => _fallback,
        );
      },
    );
  }
}
