/// 落盘策略路由(方案 §6.1 平台×类型矩阵,B4 正式实现;B0 PoC 骨架升级)。
///
/// 本文件纯 Dart:分类、矩阵决策、双路/兜底编排、空间估算(零插件依赖,
/// PC 可注入平台执行件结果单测)。插件通道薄封装在 downloads.dart。
///
/// 钉子(2026-10-20 B0 真机实证,沿用):
/// - media_store_plus saveFile 成功亦返 null → 以无异常为成败(见 downloads.dart);
/// - saveFile 搬运后会**无条件删源文件** → 多路并发落盘时每路持独立副本;
/// - 矩阵声明不进图库的类型(other)**没有图库路** → 短路不复制不调用
///   (B0「skip 短路」的正式化:null 路由即零 IO)。
library;

import 'dart:io';

/// 资产落盘形态(B0 classifyAsset 升级版,口径不变)。
enum SaveAssetKind { livp, image, video, other }

/// 落盘平台(§6.1 两列;PC/web 不落盘,无条目)。
enum SavePlatform { ios, android }

/// 图库路(photo_manager)动作;矩阵不进图库时该路整条缺席(=skip 短路)。
enum GalleryAction {
  saveLivePhoto, // iOS livp:解包→saveLivePhoto 恢复实况(AlbumService 现役)
  saveLivpPair, // Android livp D1①:解包→静态图+视频分别存图库
  saveImage,
  saveVideo,
}

/// 落盘路身份。
enum SaveRouteId { gallery, downloads, share }

/// 单条落盘路声明。
class SaveRoute {
  const SaveRoute.gallery(this.galleryAction, {this.onlyIfAllFailed = false})
      : id = SaveRouteId.gallery,
        okText = '已存入相册';
  const SaveRoute.downloads({this.onlyIfAllFailed = false})
      : id = SaveRouteId.downloads,
        galleryAction = null,
        okText = '已存入 Download/浣花视界';
  const SaveRoute.share({this.onlyIfAllFailed = false})
      : id = SaveRouteId.share,
        galleryAction = null,
        okText = '已弹出分享面板';

  final SaveRouteId id;
  final GalleryAction? galleryAction; // 仅 gallery 路非空

  /// 兜底路:true=前面所有路都失败才执行(图库失败兜 Downloads/分享)。
  final bool onlyIfAllFailed;

  /// 成功后 toast 里的去处文案(§6「toast 明说去处」)。
  final String okText;

  String get label => switch (id) {
        SaveRouteId.gallery => '相册',
        SaveRouteId.downloads => 'Download/浣花视界',
        SaveRouteId.share => '分享面板',
      };
}

/// 落盘计划:平台×类型的矩阵决策结果(纯数据,可单测全组合)。
class SavePlan {
  const SavePlan({required this.kind, required this.routes});

  final SaveAssetKind kind;
  final List<SaveRoute> routes;

  bool get anyOkRoute => routes.any((r) => !r.onlyIfAllFailed);
}

/// §6.1 矩阵(唯一真源;改动须同步需求文档与 media_save_test 全组合用例):
/// - iOS livp:解包存相册恢复实况;失败兜底原档 share「存储到文件」(不让用户白下载);
/// - Android livp:**D1 双落盘**——图库解包双存 + 原档写 Downloads,两路无条件并发、
///   互不阻塞、分别记成败(图库 HEIC 兼容性风险的自然兜底);
/// - 图片/视频(双端):photo_manager 存相册;Android 失败兜底 media_store_plus 直写;
/// - 其他文件(含 pdf):iOS share 面板 / Android 写 Downloads。
SavePlan planSaveRoutes({
  required SavePlatform platform,
  required SaveAssetKind kind,
}) {
  final routes = switch ((platform, kind)) {
    (SavePlatform.ios, SaveAssetKind.livp) => [
        const SaveRoute.gallery(GalleryAction.saveLivePhoto),
        const SaveRoute.share(onlyIfAllFailed: true),
      ],
    (SavePlatform.ios, SaveAssetKind.image) => [
        const SaveRoute.gallery(GalleryAction.saveImage),
      ],
    (SavePlatform.ios, SaveAssetKind.video) => [
        const SaveRoute.gallery(GalleryAction.saveVideo),
      ],
    (SavePlatform.ios, SaveAssetKind.other) => [const SaveRoute.share()],
    (SavePlatform.android, SaveAssetKind.livp) => [
        const SaveRoute.gallery(GalleryAction.saveLivpPair),
        const SaveRoute.downloads(), // D1②:无条件并发,非兜底
      ],
    (SavePlatform.android, SaveAssetKind.image) => [
        const SaveRoute.gallery(GalleryAction.saveImage),
        const SaveRoute.downloads(onlyIfAllFailed: true),
      ],
    (SavePlatform.android, SaveAssetKind.video) => [
        const SaveRoute.gallery(GalleryAction.saveVideo),
        const SaveRoute.downloads(onlyIfAllFailed: true),
      ],
    (SavePlatform.android, SaveAssetKind.other) => [
        const SaveRoute.downloads(),
      ],
  };
  return SavePlan(kind: kind, routes: routes);
}

const _imageExts = {'.jpg', '.jpeg', '.png', '.heic', '.heif', '.gif', '.webp'};
const _videoExts = {'.mp4', '.mov', '.m4v'};

String _extOf(String filename) {
  final dot = filename.lastIndexOf('.');
  return dot < 0 ? '' : filename.substring(dot).toLowerCase();
}

/// 资产分类(content_type 优先,扩展名兜底;livp 恒按扩展名)。
SaveAssetKind classifyAssetKind({
  required String filename,
  String? contentType,
}) {
  final ext = _extOf(filename);
  if (ext == '.livp') return SaveAssetKind.livp;
  final ct = (contentType ?? '').toLowerCase();
  if (ct.startsWith('image/') || _imageExts.contains(ext)) {
    return SaveAssetKind.image;
  }
  if (ct.startsWith('video/') || _videoExts.contains(ext)) {
    return SaveAssetKind.video;
  }
  return SaveAssetKind.other;
}

/// 单路落盘结果(成功 detail=落点;失败 detail=完整错误)。B0 SinkOutcome 沿用。
class SinkOutcome {
  const SinkOutcome.ok(this.detail) : isOk = true;
  const SinkOutcome.fail(this.detail) : isOk = false;

  final bool isOk;
  final String detail;
}

/// 单路执行结果(声明 + 结果),供汇总文案与分路成败判定。
class RouteOutcome {
  const RouteOutcome({required this.route, required this.outcome});

  final SaveRoute route;
  final SinkOutcome outcome;

  bool get isOk => outcome.isOk;
}

/// 平台执行件注入束(PC 单测注入假件,不触平台通道;生产见 downloads.dart)。
class PlatformSavers {
  PlatformSavers({
    required this.gallery,
    required this.downloads,
    required this.share,
  });

  final Future<SinkOutcome> Function(File file, GalleryAction action) gallery;
  final Future<SinkOutcome> Function(File file) downloads;
  final Future<SinkOutcome> Function(File file) share;
}

/// 计划执行:主路并发(互不阻塞)、各持独立副本;主路全败才依序走兜底路
/// (首个成功即止)。返回声明序的执行结果(未执行的兜底路不在结果里)。
Future<List<RouteOutcome>> runSavePlan({
  required File file,
  required SavePlan plan,
  required PlatformSavers savers,
}) async {
  final primaries =
      plan.routes.where((r) => !r.onlyIfAllFailed).toList(growable: false);
  final fallbacks =
      plan.routes.where((r) => r.onlyIfAllFailed).toList(growable: false);
  // 多主路并发 → 各路独立副本(Downloads 路 saveFile 删源竞态钉子);
  // 单主路直接用原档,免一次全量复制
  final parallel = primaries.length > 1;
  final results = await Future.wait([
    for (final r in primaries) _runRoute(file, r, savers, copy: parallel),
  ]);
  if (results.any((x) => x.isOk)) return results;
  for (final r in fallbacks) {
    final out = await _runRoute(file, r, savers, copy: false); // 兜底串行,无竞态
    if (out.isOk) return [...results, out];
    results.add(out); // 兜底也败 → 继续下一条,全败由调用方汇总
  }
  return results;
}

Future<RouteOutcome> _runRoute(
  File src,
  SaveRoute route,
  PlatformSavers savers, {
  required bool copy,
}) async {
  try {
    final f = copy ? await _copyForRoute(src) : src;
    final SinkOutcome out = switch (route.id) {
      SaveRouteId.gallery => await savers.gallery(f, route.galleryAction!),
      SaveRouteId.downloads => await savers.downloads(f),
      SaveRouteId.share => await savers.share(f),
    };
    if (copy && out.isOk) _cleanupCopy(f); // 成功即清各自副本;失败路保留供取证
    return RouteOutcome(route: route, outcome: out);
  } catch (e) {
    return RouteOutcome(
        route: route, outcome: SinkOutcome.fail('${route.label}路 异常:$e'));
  }
}

/// 文件名提取:兼容正斜杠/反斜杠与混合分隔符路径(B0 b0BaseName 钉子沿用:
/// Windows/临时目录拼接常见 `\dir/name` 混合,单分隔切会把目录名并进文件名)。
String baseNameOf(String path) => path.split(RegExp(r'[/\\]')).last;

Future<File> _copyForRoute(File src) async {
  final tmp = await Directory.systemTemp.createTemp('ms_save_route');
  try {
    final dst = File('${tmp.path}/${baseNameOf(src.path)}');
    await src.copy(dst.path);
    return dst;
  } catch (_) {
    tmp.delete(recursive: true).ignore();
    rethrow;
  }
}

/// 副本清理:连同独占目录一起删(fire-and-forget;失败静默——Downloads 路
/// 源文件可能已被 saveFile 搬走,残留无害)。
void _cleanupCopy(File copy) {
  copy.parent.delete(recursive: true).ignore();
}

/// 落盘结果汇总(纯函数,toast/任务错误文案唯一来源):
/// 成功路 okText 顿号连接;失败路追加「失败:路:detail」。
String saveSummary(List<RouteOutcome> outcomes) {
  final oks = <String>[];
  final fails = <String>[];
  for (final o in outcomes) {
    o.outcome.isOk ? oks.add(o.route.okText) : fails.add(o.outcome.detail);
  }
  final buf = oks.isEmpty ? '未保存' : oks.join('、');
  return fails.isEmpty ? buf : '$buf;失败:${fails.join(';')}';
}

/// 编排层中止异常(空间不足 / 全部落盘路失败):message 即用户文案,
/// 直透 TransferQueue 任务错误(绕开「Bad state:」前缀)。
class SaveAbortException implements Exception {
  SaveAbortException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 空间需求估算(§6.1「原档+解包估算」,偏乐观口径:未计平台保存自身写入
/// 等放大,估算不足时走全败链路兜底):下载临时 1× + 每条路各占 1×(主路
/// 并发各自副本)+ livp 解包约 1×(zip 内静态图+视频≈压缩包大小)。
/// Android livp D1 = 4×。
int estimateRequiredBytes(int sizeBytes, SavePlan plan) {
  var units = 1;
  units += plan.routes.length;
  if (plan.kind == SaveAssetKind.livp) units += 1;
  return sizeBytes * units;
}

/// 空间预检判定(纯函数):freeBytes 未知(null)→ unknown 放行;
/// free ≤ required → insufficient(相等即不足,保守中止)。
SpaceVerdict checkSpace(int? freeBytes, int required) {
  if (freeBytes == null) return SpaceVerdict.unknown;
  return freeBytes > required ? SpaceVerdict.ok : SpaceVerdict.insufficient;
}

enum SpaceVerdict { ok, unknown, insufficient }
