/// ThumbnailImage — 宫格缩略图(B2 §8.1;storm-fix W1 管线接入):
/// tags.thumbnail_key 存在才请求 thumbnail-url(否则端点必 404,web AssetThumbnail
/// 同门槛);位图经 ThumbDiskStore 磁盘缓存——presigned URL ~25min 轮换/冷启动/
/// 二次进入均本地秒出;网络段改经共享取字节入口 fetchThumb(并发 6 闸 + 订阅
/// 句柄取消 + 20s 硬超时,dispose/换 asset 即 cancel);磁盘代数在 read 前捕获、
/// 贯穿 write/remove;加载中纯 surface3 占位(无 spinner),字节就位先 setState
/// 显示、写盘 fire-and-forget;签名/下载/解码失败降级类型色块。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/preview_kind.dart';
import '../../core/thumb_disk_store.dart';
import '../../core/thumb_fetch.dart';
import '../../core/thumb_pipeline.dart' show ThumbHandle;
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../widgets/type_block.dart';

export '../../core/thumbnail_cache.dart'
    show thumbnailCache; // 兼容旧 import(main/preview_media;彻底清理记遗留)

class ThumbnailImage extends StatefulWidget {
  const ThumbnailImage({
    super.key,
    required this.asset,
    this.fallbackIconSize,
    this.fallback,
  });

  final Asset asset;

  /// 降级色块图标边长(缺省 32;B7 搜索结果小格 48px 用 20 防 overflow)。
  final double? fallbackIconSize;

  /// 自定义降级件(如宫格传 AssetPlate);null = 保持 [TypeBlock] 默认行为。
  final Widget? fallback;

  @override
  State<ThumbnailImage> createState() => _ThumbnailImageState();
}

class _ThumbnailImageState extends State<ThumbnailImage> {
  Uint8List? _bytes;
  bool _failed = false;
  int _tag = 0; // 切 asset / dispose 后在途任务落地即弃
  ThumbHandle? _handle;
  int _gen = 0; // 本次加载捕获的磁盘代数(写盘/坏字节 remove 贯穿用)

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
    _tag++;
    _handle?.cancel();
    _handle = null;
    // web 同门槛:无 thumbnail_key 不发签名请求;换到无 key 资产只丢弃在途
    if (widget.asset.hasThumbnail) _load();
  }

  @override
  void dispose() {
    _tag++;
    _handle?.cancel();
    _handle = null;
    super.dispose();
  }

  /// 磁盘 → fetchThumb(签名+下载,受管线闸治理)→ setState → 写盘
  /// fire-and-forget;任一步异常/取消置 _failed,下次重建自然重试。
  Future<void> _load() async {
    final tag = ++_tag;
    final id = widget.asset.id;
    _handle?.cancel();
    _handle = null;
    try {
      // 磁盘代数必须在 read 之前捕获(write 紧前才捕获形同虚设)
      var gen = ThumbDiskStore.I.generation;
      _gen = gen;
      final cached = await ThumbDiskStore.I.read(id);
      if (tag != _tag || !mounted) return;
      if (cached != null) {
        setState(() => _bytes = cached);
        return;
      }
      // read 期间发生 clear(跨代):丢弃视同 miss,重新捕获当前代数继续
      // (不得直接 return——会停占位态)
      final nowGen = ThumbDiskStore.I.generation;
      if (nowGen != gen) {
        gen = nowGen;
        _gen = nowGen;
      }
      final handle = fetchThumb(id);
      _handle = handle;
      final bytes = await handle.future;
      if (tag != _tag || !mounted) return;
      if (bytes == null || bytes.isEmpty) {
        // cancel(null)/超时/异常:不落盘,置降级色块
        throw StateError('缩略图任务未产出字节($id)');
      }
      // 字节就位先 setState 显示;写盘 fire-and-forget(带代数防跨代误写)
      setState(() => _bytes = bytes);
      ThumbDiskStore.I.write(id, bytes, expectedGeneration: gen).ignore();
    } catch (_) {
      if (tag == _tag && mounted) setState(() => _failed = true);
    }
  }

  Widget get _fallback =>
      widget.fallback ??
      TypeBlock(
        kind: detectKind(
          filename: widget.asset.filename,
          contentType: widget.asset.contentType,
        ),
        filename: widget.asset.filename,
        iconSize: widget.fallbackIconSize,
      );

  @override
  Widget build(BuildContext context) {
    // web 同门槛 + 失败降级:直接类型色块(worker 对非图不生成/下载解码失败)
    if (!widget.asset.hasThumbnail || _failed) return _fallback;
    final bytes = _bytes;
    // 占位纯色(主题 surface3),无 CircularProgressIndicator(用户抱怨的
    // 第二段闪烁)
    if (bytes == null) return ColoredBox(color: context.tk.surface3);
    final tag = _tag;
    final id = widget.asset.id;
    final gen = _gen;
    return LayoutBuilder(
      builder: (context, box) {
        // 解码降采样:格宽 × dpr 取整 clamp 96..600(省内存;放大预览走他路)
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final px = box.maxWidth.isFinite ? (box.maxWidth * dpr).round() : 600;
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
          errorBuilder: (_, _, _) {
            // 坏字节兜底:删盘上坏文件(带代数防跨代误删)+ post-frame 置降级
            ThumbDiskStore.I.remove(id, expectedGeneration: gen).ignore();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              // 先比对捕获 tag/assetId 再 setState(防切张后旧资产回调误伤新格)
              if (!mounted || _tag != tag || widget.asset.id != id) return;
              setState(() {
                _failed = true;
                _bytes = null;
              });
            });
            return _fallback;
          },
        );
      },
    );
  }
}
