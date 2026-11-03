/// 现状 D1 下载主体(安卓实况图适配拆件,方案 §5.4/§5.5):
/// [runLegacyDownloadJob] = 原 downloads.dart runDownloadJob 主体收编(空间预检
/// → link → fetch 落 app cache → runSavePlan → 共享收尾),行为逐字保留;
/// [finishDownloadSave] = 原 :174-189 尾部语义共享件。
///
/// 拆件动机:motion_photo_save.dart 的两条 D1 回落(大小闸门/空间分档)与
/// 合成失败收尾都要「完全回到现状」,直接调本文件而非回调 runDownloadJob——
/// 后者顶部就是 motion 能力分流,capable 机上会重入死循环;两处共用一份编排
/// 防漂移,兑现降级路径零回归。
library;

import 'dart:io';

import 'package:dio/dio.dart' show CancelToken, DioException;

import '../core/api/ms_api.dart' show ApiException;
import '../core/fmt.dart' show fmtBytes;
import '../core/transfers/transfer_task.dart' show TransferKind;
import '../models/models.dart';
import 'app_log.dart';
import 'downloads.dart' show DownloadIo, defaultSavePlatform;
import 'media_save.dart';
import 'notifier.dart';

/// 原 runDownloadJob 主体(现状行为零改动,含进度折算口径,见
/// [_legacyProgress];[platform] 由编排层传入,直接调用时缺省按端判定)。
Future<void> runLegacyDownloadJob({
  required Asset asset,
  required void Function(int doneBytes) onProgress,
  required CancelToken token,
  required DownloadIo io,
  SavePlatform? platform,
}) async {
  final plat = platform ?? defaultSavePlatform();
  final kind = classifyAssetKind(
    filename: asset.filename,
    contentType: asset.contentType,
  );
  final plan = planSaveRoutes(platform: plat, kind: kind);
  final total = asset.sizeBytes.toInt();

  final root = await io.tempRoot();
  final required = estimateRequiredBytes(total, plan);
  final free = await io.freeBytes(root.path);
  if (checkSpace(free, required) == SpaceVerdict.insufficient) {
    throw SaveAbortException(
      '空间不足:预计需 ${fmtBytes(required)},该目录仅剩 ${fmtBytes(free!)},已中止下载',
    );
  }

  final url = await io.link(asset);
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final temp = await io.fetch(
    url: url,
    savePath: '${root.path}/dl_${stamp}_${baseNameOf(asset.filename)}',
    totalBytes: total,
    onProgress: _legacyProgress(onProgress, total),
    token: token,
  );

  if (token.isCancelled) {
    // 取消竞态:下载完才发现已取消 → 不再落盘;已下载临时一并清掉(P2-2,
    // 不留垃圾;删除失败忽略——临时目录本就随系统回收)
    try {
      await temp.delete();
    } catch (_) {}
    return;
  }
  final outcomes = await runSavePlan(file: temp, plan: plan, savers: io.savers);
  await finishDownloadSave(
    temp: temp,
    outcomes: outcomes,
    asset: asset,
    io: io,
  );
}

/// fetch 进度折算(现状口径不变):DownloadIo.fetch 现透传 (done,
/// contentLength),旧 downloadTo 链路等价于 done*total/len;contentLength 未知
/// 不上报(同旧 `t > 0` 守卫),队列侧按 asset.sizeBytes 归一并 clamp。
void Function(int doneBytes, int? contentLength) _legacyProgress(
  void Function(int doneBytes) onProgress,
  int total,
) => (done, len) {
  if (total <= 0 || len == null || len <= 0) return;
  onProgress((done * total / len).round());
};

/// 404 收口谓词(§5.4 步骤 2;实况图补抓「仅 404 走 D1」的唯一判定面):
/// 主 Dio link 层=ApiException(404);presigned GET fetch 层=DioException
/// badResponse 404——两层异常形态不同,判定收口于此,勿在调用点各写各的。
bool isNotFound(Object e) =>
    (e is ApiException && e.status == 404) ||
    (e is DioException && e.response?.statusCode == 404);

/// 下载落盘收尾(原 downloads.dart :174-189 尾部语义,legacy/motion 两编排
/// 共用防漂移):任一路成功 → 删临时 + toast + 系统通知;全败 → AppLog +
/// 保留临时供取证(重试=重新下载+重新落盘)+ SaveAbortException(用户文案,
/// 直透任务错误)。
Future<void> finishDownloadSave({
  required File temp,
  required List<RouteOutcome> outcomes,
  required Asset asset,
  required DownloadIo io,
}) async {
  if (!outcomes.any((o) => o.isOk)) {
    AppLog.error('download', '全部落盘路失败,临时文件保留:${temp.path}');
    throw SaveAbortException('下载完成但保存失败:${saveSummary(outcomes)}');
  }
  temp.delete().ignore(); // 落盘成功后删临时(D1 双落盘共用一次下载)
  AppLog.info('download', '✓ ${asset.filename} → ${saveSummary(outcomes)}');
  io.toast?.call('${asset.filename}:${saveSummary(outcomes)}');
  // P8(mobile-ux-polish):后台时系统通知「下载完成」(保存摘要进正文;
  // 前台维持 toast 现状,通知侧 gate 丢弃;同窗多任务由 Notifier 聚合)
  Notifier.I.taskFinished(
    kind: TransferKind.download,
    ok: true,
    filename: asset.filename,
    detail: saveSummary(outcomes),
  );
}
