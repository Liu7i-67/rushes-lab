/// B0② 落盘路由纯函数(方案 §6.1 平台×类型矩阵骨架,PC 可单测)。
/// 插件通道调用在 b0_sinks.dart(薄,真机验证);本文件只做分类、路由决策
/// 与双路编排(零插件依赖,可注入平台通道结果单测)。
library;

import 'dart:io';

/// 单路落盘结果。成功 detail=落点路径;失败 detail=完整错误(真机取证用)。
class B0SinkOutcome {
  const B0SinkOutcome.ok(this.detail) : isOk = true;
  const B0SinkOutcome.fail(this.detail) : isOk = false;

  final bool isOk;
  final String detail;
}

/// PoC 关心的资产形态。
enum B0AssetKind { livp, image, video, other }

/// 图库路(photo_manager)子策略(§6.1 Android 列):
/// livp 解包后静态图+视频分别存;图片/视频直存;其他类型不进图库。
enum B0GalleryStrategy { livpUnpackPair, saveImage, saveVideo, skip }

const _imageExts = {'.jpg', '.jpeg', '.png', '.heic', '.heif', '.gif', '.webp'};
const _videoExts = {'.mp4', '.mov', '.m4v'};

String _extOf(String filename) {
  final dot = filename.lastIndexOf('.');
  return dot < 0 ? '' : filename.substring(dot).toLowerCase();
}

B0AssetKind classifyAsset({
  required String filename,
  String? contentType,
}) {
  final ext = _extOf(filename);
  if (ext == '.livp') return B0AssetKind.livp;
  final ct = (contentType ?? '').toLowerCase();
  if (ct.startsWith('image/') || _imageExts.contains(ext)) {
    return B0AssetKind.image;
  }
  if (ct.startsWith('video/') || _videoExts.contains(ext)) {
    return B0AssetKind.video;
  }
  return B0AssetKind.other;
}

/// §6.1 矩阵(Android 列)的 PoC 骨架。
B0GalleryStrategy galleryStrategyOf(B0AssetKind kind) => switch (kind) {
      B0AssetKind.livp => B0GalleryStrategy.livpUnpackPair,
      B0AssetKind.image => B0GalleryStrategy.saveImage,
      B0AssetKind.video => B0GalleryStrategy.saveVideo,
      B0AssetKind.other => B0GalleryStrategy.skip,
    };

/// Downloads 路(media_store_plus)PoC 口径:一律写原档
/// (livp 原档写 Downloads 即 §6.1 D1②;其他类型同落 Downloads 供取证)。
bool downloadsCopyApplies(B0AssetKind kind) => true;

/// 双路落盘编排(§6「两路分别记成功/失败,图库路失败不阻塞原档路」):
/// 两路同时启动、互不等待对方完成;单路抛错兜成失败 outcome,绝不影响另一路。
/// 竞态防护(2026-10-20 真机):Downloads 路 media_store_plus saveFile 搬运完成
/// 后会**无条件删除源文件**,两路共用同一临时文件时图库路慢一步即读不到 →
/// 各路先复制出独立副本再落盘;副本在该路**成功**后各自清理,失败路保留供取证。
Future<(B0SinkOutcome gallery, B0SinkOutcome downloads)> runBothSinks(
  File file,
  B0AssetKind kind, {
  required Future<B0SinkOutcome> Function(File file, B0AssetKind kind) gallery,
  required Future<B0SinkOutcome> Function(File file) downloads,
}) async {
  final fg = _runRoute(file, '图库路', (f) => gallery(f, kind));
  final fd = _runRoute(file, 'Downloads 路', downloads);
  return (await fg, await fd);
}

Future<B0SinkOutcome> _runRoute(
    File src, String route, Future<B0SinkOutcome> Function(File) act) async {
  try {
    final copy = await _copyForRoute(src);
    final out = await act(copy);
    if (out.isOk) _cleanupCopy(copy); // 成功即清各自副本;失败路保留供真机取证
    return out;
  } catch (e) {
    return B0SinkOutcome.fail('$route 异常:$e');
  }
}

/// 文件名提取:兼容正斜杠/反斜杠与混合分隔符路径(Windows 临时目录拼接常见
/// `\dir/name` 混合;按 Platform.pathSeparator 单分隔切会把目录名并进文件名,
/// 导致副本落到不存在的子目录)。
String b0BaseName(String path) => path.split(RegExp(r'[/\\]')).last;

/// 单路独立副本:独占临时目录、文件名与原档一致(图库路落盘命名沿用原文件名)。
/// 复制失败时清掉半成品目录后原样上抛,由 _runRoute 兜成该路失败 outcome。
Future<File> _copyForRoute(File src) async {
  final tmp = await Directory.systemTemp.createTemp('b0_route');
  try {
    final dst = File('${tmp.path}/${b0BaseName(src.path)}');
    await src.copy(dst.path);
    return dst;
  } catch (_) {
    tmp.delete(recursive: true).ignore();
    rethrow;
  }
}

/// 副本清理:连同独占目录一起删(失败静默——Downloads 路源文件可能已被
/// media_store_plus 搬运删除,取证场景下残留也无害)。
void _cleanupCopy(File copy) {
  copy.parent.delete(recursive: true).ignore();
}
