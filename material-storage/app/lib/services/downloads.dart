/// 下载编排(B4 功能点 2/3,方案 §6;TransferQueue kind=download 的 worker):
/// 空间预检 → download-link → dio 落 app cache(进度回传入队)→ 按 §6.1 矩阵
/// 落盘(D1 双路共用本次下载)→ 成功删临时。平台执行件(photo_manager /
/// media_store_plus / share_plus)封装在 download_savers.dart,经
/// [DownloadIo] 注入束接入;PC 单测注入假件零平台通道、零网络。
///
/// 安卓实况图适配(2026-11-02 方案 §5.4):android+livp 且机型 capable 时
/// 顶部能力分流进 [runMotionPhotoDownload](motion_photo_save.dart 编排);
/// 其余行为零改动——现状主体收编至 legacy_download.dart 的
/// runLegacyDownloadJob(D1 回落直调它,不回调本文件防 capable 机重入)。
///
/// 重试语义=重新下载+重新落盘(决策 #3:不查重已落盘;相册/Downloads 落地
/// 同名为「先删后插覆盖替换」,见 download_savers.dart 钉子,非自动加后缀)。
library;

import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show ScaffoldMessenger, SnackBar, Text;
import 'package:path_provider/path_provider.dart';

import '../core/api/ms_api.dart' show ApiException;
import '../core/session.dart';
import '../core/transfers/transfer_queue.dart';
import '../core/transfers/transfer_task.dart';
import '../models/models.dart';
import 'app_log.dart';
import 'download_savers.dart';
import 'legacy_download.dart' show runLegacyDownloadJob;
import 'media_save.dart';
import 'motion_photo_capability.dart' show motionPhotoCapable;
import 'motion_photo_save.dart' show runMotionPhotoDownload;

export 'download_savers.dart'
    show
        defaultSavers,
        downloadsOutcome,
        downloadsSaver,
        gallerySaver,
        kAppDownloadDir,
        processFreeBytes,
        shareSaver;
export 'legacy_download.dart' show finishDownloadSave, runLegacyDownloadJob;
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
  /// [variant]='unpacked' 请求 livp 解包档(实况图补抓;缺省不带该键——
  /// 后端 Literal 非 None 可选,带 null 必 422,见 assets_api.downloadLink)。
  final Future<String> Function(Asset asset, {String? variant}) link;

  /// 下载 presigned URL 到 [savePath]。onProgress 透传 (已收字节,
  /// contentLength)——contentLength 未知为 null(实况图补抓段的空间复检
  /// 取数;折算口径见 legacy_download._legacyProgress)。
  final Future<File> Function({
    required String url,
    required String savePath,
    required int totalBytes,
    required void Function(int doneBytes, int? contentLength) onProgress,
    required CancelToken token,
  })
  fetch;

  /// 目录可用字节;null=未知(预检放行)。
  final Future<int?> Function(String dirPath) freeBytes;

  /// 下载临时目录(落盘成功即删临时,§6)。
  final Future<Directory> Function() tempRoot;

  final PlatformSavers savers;

  /// 编排完成 toast(与队列解耦;测试可注入收集)。
  final void Function(String message)? toast;
}

/// 真实 IO 束(session API + download_savers 平台件;toast 走根 navigator)。
/// fetch 直用 presignedHttp.download 透传 dio (c,t) 的 t——绕开
/// assets_api.downloadTo(其 onProgress 只回 frac,t 未外露,补抓段空间复检
/// 无处取数);t<=0(content-length 未知)归一为 null。
DownloadIo defaultDownloadIo() {
  Future<File> fetch({
    required String url,
    required String savePath,
    required int totalBytes,
    required void Function(int doneBytes, int? contentLength) onProgress,
    required CancelToken token,
  }) async {
    await session.api!.presignedHttp.download(
      url,
      savePath,
      onReceiveProgress: (c, t) => onProgress(c, t > 0 ? t : null),
      cancelToken: token,
    );
    return File(savePath);
  }

  return DownloadIo(
    link: (a, {variant}) async {
      final api = session.api;
      if (api == null) throw ApiException(null, '会话已失效');
      return api.assets.downloadLink(a.id, variant: variant);
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
/// 顶部能力分流——android+livp 且机型白名单 capable(motionPhotoCapable,
/// 注入束可覆盖)→ runMotionPhotoDownload(实况图合成链);其余/不 capable
/// → 现状 D1 主体 runLegacyDownloadJob(空间预检 → download-link → dio 落
/// app cache → 按矩阵落盘 → 任一路成功删临时;全败保留临时供取证并抛错;
/// 下载完成即发现已取消 → 不落盘且删临时 P2-2)。
Future<void> runDownloadJob({
  required Asset asset,
  required void Function(int doneBytes) onProgress,
  required CancelToken token,
  SavePlatform? platform,
  DownloadIo? io,
  Future<bool> Function()? motionCapable,
}) async {
  final channel = io ?? defaultDownloadIo();
  final plat = platform ?? defaultSavePlatform();
  final kind = classifyAssetKind(
    filename: asset.filename,
    contentType: asset.contentType,
  );
  if (plat == SavePlatform.android &&
      kind == SaveAssetKind.livp &&
      await (motionCapable ?? motionPhotoCapable)()) {
    return runMotionPhotoDownload(
      asset: asset,
      onProgress: onProgress,
      token: token,
      io: channel,
    );
  }
  return runLegacyDownloadJob(
    asset: asset,
    onProgress: onProgress,
    token: token,
    io: channel,
    platform: plat,
  );
}

/// 入队一个下载任务(预览页/宫格批量共用;重试=同 worker 从头来)。
String enqueueDownload({
  required Asset asset,
  required String where,
  SavePlatform? platform,
  TransferQueue? queue,
  DownloadIo? io,
  Future<bool> Function()? motionCapable,
}) {
  return (queue ?? TransferQueue.I).enqueue(
    TransferRequest(
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
        motionCapable: motionCapable,
      ),
    ),
  );
}

/// 批量逐文件入队(宫格操作栏「下载」键;单点失败不中断整批,口径同上传
/// enqueueBatch)。返回 (入队数, 跳过数)。
Future<(int, int)> enqueueDownloads(
  List<Asset> assets, {
  required String where,
  SavePlatform? platform,
  TransferQueue? queue,
  DownloadIo? io,
  Future<bool> Function()? motionCapable,
}) async {
  var enqueued = 0;
  var skipped = 0;
  for (final a in assets) {
    try {
      enqueueDownload(
        asset: a,
        where: where,
        platform: platform,
        queue: queue,
        io: io,
        motionCapable: motionCapable,
      );
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
