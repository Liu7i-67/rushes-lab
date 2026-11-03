/// 步骤 3 补抓支路(安卓实况图适配 §5.4 步骤 3 拆件,§5.4 步骤号即拆分
/// 边界):heic/mov/png(iOS 来源/外部异构 livp)输入的 variant=unpacked
/// 按需补抓。链:先删原始解包目录(heic/mov 已无用途;不删则补抓支路最坏
/// 驻留恰好吃满 6× 闸门零裕度)→ link(variant='unpacked')→ fetch(补抓段
/// 进度恒报 0.95——首段已用满 [0,0.95],终态 1.0 由任务队列自然表达;**仅
/// 404 走 D1**,连接类/超时/5xx/403=任务失败外溢,残缺临时不进 D1)→
/// Content-Length 剩余空间复检一次(6× 预检按 asset.sizeBytes 计,unpacked
/// zip 的 HEVC→H.264 转码膨胀下载前不可知;len 未知/free=null 沿 unknown→
/// 放行;不足按 4× zip 估——二次解包+flm 产物+入库副本,原始档已在盘上计入
/// 当前 free)→ 二次解包。「仅 jpg 的 zip」(mov 转码失败降级)→ [onStatic]
/// 静图退化;fetch 后取消 → [onCancel](P2-2 同款清临时);D1/退化经
/// [onD1]/[onStatic] 收口调用方编排态(先清中间产物再 runSavePlan 等在
/// 调用方 d1 内)。返回合成输入 (image, video);null=已在支路内收尾。
library;

import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;

import '../core/fmt.dart' show fmtBytes;
import '../models/models.dart';
import 'downloads.dart' show DownloadIo;
import 'legacy_download.dart' show isNotFound;
import 'livp.dart' show LivpService;
import 'motion_photo_verify.dart' show deleteQuietly;

/// 补抓支路收口束(调用方编排态:D1 收尾/静图退化/取消清理)+ 产物登记
/// (调用方 D1/成功/取消收尾统一幂等清理)。
class RefetchSink {
  RefetchSink({
    required this.artifacts,
    required this.onD1,
    required this.onStatic,
    required this.onCancel,
  });

  /// 补抓链登记的中间产物(zip/二次解包目录)。
  final RefetchArtifacts artifacts;

  /// D1 收尾(调用方:先清中间产物再 runSavePlan+共享收尾)。
  final Future<void> Function(String reason) onD1;

  /// D7 静图退化收尾(调用方 saveImageWithPath,不写 Downloads)。
  final Future<void> Function(File image, String reason) onStatic;

  /// fetch 后取消(P2-2 同款:清原档临时+补抓档,静默返回)。
  final Future<void> Function() onCancel;
}

/// 补抓链登记的中间产物(zip/二次解包目录)。
class RefetchArtifacts {
  File? zip;
  Directory? dir;
}

/// 首段进度映射(§5.4 步骤 2,整链映射 [0,0.95]):frac×0.95——首段完成时
/// 报 0.95 而非 1.0,为补抓段留出可视增量,避免「≥首段完成值 1.0 且 ≤0.95」
/// 的空约束;len 未知按 asset.sizeBytes 归一(队列侧按 totalBytes 归一并 clamp)。
void Function(int doneBytes, int? contentLength) motionFirstSegmentProgress(
  void Function(int doneBytes) onProgress,
  int total,
) => (done, len) {
  if (total <= 0) return;
  final denom = (len != null && len > 0) ? len : total;
  final frac = (done / denom).clamp(0.0, 1.0);
  onProgress((frac * 0.95 * total).round());
};

/// 条目扩展名(小写,含点;zip 条目名诊断用,解包分诊与编排共用)。
String motionExtOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}

/// 补抓 unpacked 并解包;返回合成输入,或 null=已收尾(调用方直接返回)。
Future<({File image, File video})?> refetchUnpackedInputs({
  required Asset asset,
  required DownloadIo io,
  required CancelToken token,
  required void Function(int doneBytes) onProgress,
  required int total,
  required String zipPath,
  required Directory unpackDir,
  required RefetchSink sink,
}) async {
  final artifacts = sink.artifacts;
  await deleteQuietly(unpackDir);
  final String refetchUrl;
  try {
    refetchUrl = await io.link(asset, variant: 'unpacked');
  } catch (e) {
    // 仅 404 走 D1(link 层未就绪/超 200MB 或静图永久失败 livp 恒 404 不重派);
    // 连接类/超时/5xx/403=任务失败外溢(残缺临时不进 D1,与首段同语义)
    if (isNotFound(e)) {
      await sink.onD1('unpacked 404(首访已触发自愈或恒 404)');
      return null;
    }
    rethrow;
  }
  final zip = File(zipPath);
  artifacts.zip = zip;
  int? refetchLen;
  try {
    await io.fetch(
      url: refetchUrl,
      savePath: zip.path,
      totalBytes: total,
      onProgress: (done, len) {
        if (len != null && len > 0) refetchLen = len;
        onProgress((0.95 * total).round()); // 补抓段进度恒报 0.95
      },
      token: token,
    );
  } catch (e) {
    if (isNotFound(e)) {
      await sink.onD1('unpacked 下载 404(presigned 对象竞态消失)');
      return null;
    }
    rethrow;
  }
  if (token.isCancelled) {
    await sink.onCancel(); // 取消竞态(与首段同款 P2-2):静默返回
    return null;
  }
  final free2 = await io.freeBytes(Directory(zipPath).parent.path);
  if (refetchLen != null && free2 != null && free2 < 4 * refetchLen!) {
    await sink.onD1('补抓档 ${fmtBytes(refetchLen!)} 后剩余空间不足,放弃合成');
    return null;
  }
  final dir2 = await Directory.systemTemp.createTemp('motion_unpack2');
  artifacts.dir = dir2;
  ({File image, File? video}) parts;
  try {
    parts = await LivpService.unpackToFiles(await zip.readAsBytes(), dir2);
  } catch (e) {
    await sink.onD1('unpacked 解包失败:$e');
    return null;
  }
  if (parts.video == null) {
    // 后端「仅 jpg 的 zip」(mov 转码失败降级)→ 同 D7 静图退化
    await sink.onStatic(parts.image, 'unpacked 无视频条目');
    return null;
  }
  return (image: parts.image, video: parts.video!);
}
