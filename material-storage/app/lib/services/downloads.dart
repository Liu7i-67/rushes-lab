/// 下载编排(B4 功能点 2/3,方案 §6;TransferQueue kind=download 的 worker):
/// 空间预检 → download-link → dio 落 app cache(进度回传入队)→ 按 §6.1 矩阵
/// 落盘(D1 双路共用本次下载)→ 成功删临时。平台执行件(photo_manager /
/// media_store_plus / share_plus)封装在 download_savers.dart,经
/// [DownloadIo] 注入束接入;PC 单测注入假件零平台通道、零网络。
///
/// 重试语义=重新下载+重新落盘(决策 #3:不查重已落盘,平台重名自动加后缀)。
library;

import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show ScaffoldMessenger, SnackBar, Text;
import 'package:path_provider/path_provider.dart';

import '../core/api/ms_api.dart' show ApiException;
import '../core/fmt.dart' show fmtBytes;
import '../core/session.dart';
import '../core/transfers/transfer_queue.dart';
import '../core/transfers/transfer_task.dart';
import '../models/models.dart';
import 'app_log.dart';
import 'download_savers.dart';
import 'media_save.dart';

export 'download_savers.dart'
    show
        defaultSavers,
        downloadsOutcome,
        downloadsSaver,
        gallerySaver,
        kAppDownloadDir,
        processFreeBytes,
        shareSaver;
export 'media_save.dart'
    show
        GalleryAction,
        RouteOutcome,
        SaveAbortException,
        SaveAssetKind,
        SavePlatform,
        SinkOutcome;

/// 批量下载确认门槛(>20 弹确认,桌面 web download-store 同款)。
const kBatchDownloadConfirmMax = 20;

bool needsBatchConfirm(int count) => count > kBatchDownloadConfirmMax;

/// 下载编排 IO 束:link/fetch/空间/落盘件/缓存目录/toast 全可注入
/// (PC 单测零平台通道、零网络;缺省=真实实现)。
class DownloadIo {
  DownloadIo({
    required this.link,
    required this.fetch,
    required this.freeBytes,
    required this.tempRoot,
    required this.savers,
    this.toast,
  });

  /// download-link 签发(403 无权由后端 detail 透传,最终裁决)。
  final Future<String> Function(Asset asset) link;

  /// 下载 presigned URL 到 [savePath](进度按字节上报)。
  final Future<File> Function({
    required String url,
    required String savePath,
    required int totalBytes,
    required void Function(int doneBytes) onProgress,
    required CancelToken token,
  }) fetch;

  /// 目录可用字节;null=未知(预检放行)。
  final Future<int?> Function(String dirPath) freeBytes;

  /// 下载临时目录(落盘成功即删临时,§6)。
  final Future<Directory> Function() tempRoot;

  final PlatformSavers savers;

  /// 编排完成 toast(与队列解耦;测试可注入收集)。
  final void Function(String message)? toast;
}

/// 真实 IO 束(session API + download_savers 平台件;toast 走根 navigator)。
DownloadIo defaultDownloadIo() {
  Future<File> fetch({
    required String url,
    required String savePath,
    required int totalBytes,
    required void Function(int doneBytes) onProgress,
    required CancelToken token,
  }) =>
      session.api!.assets.downloadTo(url, savePath, cancelToken: token,
          onProgress: (frac) => onProgress((frac * totalBytes).round()));
  return DownloadIo(
    link: (a) async {
      final api = session.api;
      if (api == null) throw ApiException(null, '会话已失效');
      return api.assets.downloadLink(a.id);
    },
    fetch: fetch,
    freeBytes: processFreeBytes,
    tempRoot: _defaultTempRoot,
    savers: defaultSavers(),
    toast: toastViaSession,
  );
}

Future<Directory> _defaultTempRoot() async {
  final base = await getTemporaryDirectory();
  final dir = Directory('${base.path}/downloads');
  await dir.create(recursive: true);
  return dir;
}

/// 根 navigator 上的全局 toast(队列 worker 无 BuildContext 场景)。
void toastViaSession(String msg) {
  final ctx = session.navigatorKey.currentState?.context;
  if (ctx == null) return;
  ScaffoldMessenger.maybeOf(ctx)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// 下载单个资产的编排(B4 功能点 2,TransferQueue worker 本体):
/// ① 空间预检(下载前;不足中止不半途写坏;未知放行)→ ② download-link →
/// dio 落 app cache(进度回传入队;presigned 日志只记 host+path 由 MsApi
/// 拦截器保证)→ ③ 按矩阵落盘(D1 双路共用本次下载)→ ④ 任一路成功删临时;
/// 全败保留临时供取证并抛错(重试=重新下载+重新落盘);下载完成即发现已取消
/// → 不落盘且删临时(P2-2)。
Future<void> runDownloadJob({
  required Asset asset,
  required void Function(int doneBytes) onProgress,
  required CancelToken token,
  SavePlatform? platform,
  DownloadIo? io,
}) async {
  final channel = io ?? defaultDownloadIo();
  final plat = platform ?? defaultSavePlatform();
  final kind = classifyAssetKind(
      filename: asset.filename, contentType: asset.contentType);
  final plan = planSaveRoutes(platform: plat, kind: kind);
  final total = asset.sizeBytes.toInt();

  final root = await channel.tempRoot();
  final required = estimateRequiredBytes(total, plan);
  final free = await channel.freeBytes(root.path);
  if (checkSpace(free, required) == SpaceVerdict.insufficient) {
    throw SaveAbortException(
        '空间不足:预计需 ${fmtBytes(required)},该目录仅剩 ${fmtBytes(free!)},已中止下载');
  }

  final url = await channel.link(asset);
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final temp = await channel.fetch(
    url: url,
    savePath: '${root.path}/dl_${stamp}_${baseNameOf(asset.filename)}',
    totalBytes: total,
    onProgress: onProgress,
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
  final outcomes =
      await runSavePlan(file: temp, plan: plan, savers: channel.savers);
  if (!outcomes.any((o) => o.isOk)) {
    AppLog.error('download', '全部落盘路失败,临时文件保留:${temp.path}');
    throw SaveAbortException('下载完成但保存失败:${saveSummary(outcomes)}');
  }
  temp.delete().ignore(); // 落盘成功后删临时(D1 双落盘共用一次下载)
  AppLog.info('download', '✓ ${asset.filename} → ${saveSummary(outcomes)}');
  channel.toast?.call('${asset.filename}:${saveSummary(outcomes)}');
}

/// 入队一个下载任务(预览页/宫格批量共用;重试=同 worker 从头来)。
String enqueueDownload({
  required Asset asset,
  required String where,
  SavePlatform? platform,
  TransferQueue? queue,
  DownloadIo? io,
}) {
  return (queue ?? TransferQueue.I).enqueue(TransferRequest(
    kind: TransferKind.download,
    filename: asset.filename,
    where: where,
    totalBytes: asset.sizeBytes.toInt(),
    worker: (onProgress, token) => runDownloadJob(
      asset: asset,
      onProgress: onProgress,
      token: token,
      platform: platform,
      io: io,
    ),
  ));
}

/// 批量逐文件入队(宫格操作栏「下载」键;单点失败不中断整批,口径同上传
/// enqueueBatch)。返回 (入队数, 跳过数)。
Future<(int, int)> enqueueDownloads(
  List<Asset> assets, {
  required String where,
  SavePlatform? platform,
  TransferQueue? queue,
  DownloadIo? io,
}) async {
  var enqueued = 0;
  var skipped = 0;
  for (final a in assets) {
    try {
      enqueueDownload(
          asset: a, where: where, platform: platform, queue: queue, io: io);
      enqueued += 1;
    } catch (e) {
      skipped += 1;
      AppLog.error('download', '单项入队失败,已跳过 ${a.filename}', e);
    }
  }
  return (enqueued, skipped);
}

/// 当前落盘平台(移动端专用;web/桌面无落盘矩阵,退 android 由 403/插件失败兜底)。
SavePlatform defaultSavePlatform() {
  if (kIsWeb) return SavePlatform.android;
  return Platform.isIOS ? SavePlatform.ios : SavePlatform.android;
}
