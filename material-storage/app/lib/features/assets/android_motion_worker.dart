/// Android motion photo 上传 worker(方案 §5.3;入队编排见
/// android_motion_upload.dart,本件=worker 全流程+打包内核+注入束):
/// ① 复验(TOCTOU:入队→执行间原文件可能被编辑/删除/替换)三分支——命中→
///    以复验新 plan 打包(**弃入队 plan**,旧 plan 拆分=错位产物静默坏数据)
///    且复查 File.length() 仍 ≤150MB(超限落降级);null 但文件在→降级普通轨
///    直传原档({base}.jpg/image/jpeg,任务仍算成功);文件不存在→任务失败
///    (「原文件已不存在」);
/// ② compute isolate 打包(STORED,主 isolate 零大对象)→ ③ uploadFile
///    16MB 流式轨 → ④ 终态(成功/失败/取消)一律删临时(retry 从头重打包);
/// ⑤ 上传进度按复验后实际 size 归一并 clamp 到入队 totalBytes(§5.3);
/// ⑥ 降级与失败分支 AppLog 区分打点(复验超限/复验 null/文件不存在/打包失败)。
/// 注入缝:[MotionPhotoWorkerIo] 全假件可注入(@visibleForTesting,零平台通道)。
library;

import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;

import '../../core/api/ms_api.dart' show ApiException;
import '../../core/session.dart' show session;
import '../../services/app_log.dart';
import '../../services/livp.dart' show LivpService;
import '../../services/motion_photo.dart'
    show MotionPhotoPlan, probeMotionPhotoFileGuarded;
import 'upload_sheet.dart' show notifyUploadSuccess;

/// 大小闸门(§5.3/§9):原档 >150MB 落普通轨降级(防 isolate 内存峰值与后端
/// livp worker 200MB 永久失败带);入队侧前置与 worker 复验共用同一常量。
const kMotionPhotoMaxBytes = 150 * 1024 * 1024;

/// 复验签名(生产=[probeMotionPhotoFileGuarded];测试=假件)。
typedef MotionPhotoProbe = Future<MotionPhotoPlan?> Function(String path);

/// 打包签名:按 plan 区间拆分+STORED zip 落临时,返回临时文件完整路径
/// (目标文件在 worker 执行时才创建)。
typedef MotionPhotoPack = Future<String> Function({
  required String srcPath,
  required MotionPhotoPlan plan,
  required String base,
});

/// 上传签名(uploadFile 同形;测试=假件收集断言)。
typedef MotionPhotoUpload = Future<void> Function({
  required String folderId,
  required String filename,
  required String path,
  required String contentType,
  CancelToken? cancelToken,
  void Function(int done, int total)? onProgress,
});

/// 临时清理签名(终态一律调;删除失败静默)。
typedef MotionPhotoDeleteTemp = Future<void> Function(String path);

/// worker 注入束(§5.3 测试铁律):缺省=生产实现;测试注入假件零平台通道。
@visibleForTesting
class MotionPhotoWorkerIo {
  MotionPhotoWorkerIo({
    MotionPhotoProbe? probe,
    Future<int> Function(String path)? sizeOf,
    MotionPhotoPack? pack,
    MotionPhotoUpload? upload,
    MotionPhotoDeleteTemp? deleteTemp,
  }) : probe = probe ?? probeMotionPhotoFileGuarded,
       sizeOf = sizeOf ?? _defaultSizeOf,
       pack = pack ?? _packLivpToTemp,
       upload = upload ?? _defaultUpload,
       deleteTemp = deleteTemp ?? _deleteTempQuietly;

  final MotionPhotoProbe probe;

  /// 文件大小(复验超限复查与进度归一基准;注入供 >150MB 分支单测)。
  final Future<int> Function(String path) sizeOf;

  final MotionPhotoPack pack;
  final MotionPhotoUpload upload;
  final MotionPhotoDeleteTemp deleteTemp;
}

/// motion 上传 worker(队列 TransferWorker 同形;§5.3 全流程见头注释)。
/// [enqueuePlan] 为入队时预筛所得,复验命中即弃(参数保留以钉「弃入队 plan」
/// 语义并供单测断言);抛异常=任务失败外溢到队列(retry 同描述从头重跑)。
@visibleForTesting
Future<void> runMotionPhotoWorker(
  void Function(int doneBytes) onProgress,
  CancelToken token, {
  required String folderId,
  required String where,
  required String base,
  required String srcPath,
  required MotionPhotoPlan enqueuePlan,
  required int totalBytes,
  MotionPhotoWorkerIo? io,
}) async {
  final w = io ?? MotionPhotoWorkerIo();
  // ① 复验(TOCTOU)三分支
  final plan = await w.probe(srcPath);
  if (plan == null) {
    if (!await File(srcPath).exists()) {
      AppLog.error('motion-upload', '原文件已不存在(复验未命中):$base');
      throw ApiException(null, '原文件已不存在');
    }
    AppLog.info('motion-upload', '复验未命中,降级普通轨直传原档:$base');
    await _uploadOriginalAsJpg(
      w,
      onProgress: onProgress,
      token: token,
      folderId: folderId,
      base: base,
      srcPath: srcPath,
      totalBytes: totalBytes,
    );
    AppLog.info('upload', '✓ 已上传:$base.livp(降级 .jpg 直传)→ $where');
    notifyUploadSuccess(folderId);
    return;
  }
  // 复验同时复查大小闸门(入队后被替换成超大文件的极端场景,超限落降级,
  // 守住 §9 内存预算);size 兼作本任务进度归一基准
  final size = await w.sizeOf(srcPath);
  if (size > kMotionPhotoMaxBytes) {
    AppLog.info('motion-upload', '复验超限($size B > 150MB),降级普通轨:$base');
    await _uploadOriginalAsJpg(
      w,
      onProgress: onProgress,
      token: token,
      folderId: folderId,
      base: base,
      srcPath: srcPath,
      totalBytes: totalBytes,
    );
    AppLog.info('upload', '✓ 已上传:$base.livp(降级 .jpg 直传)→ $where');
    notifyUploadSuccess(folderId);
    return;
  }
  String? tempPath;
  try {
    // ② 打包(compute isolate;失败=任务失败外溢,retry 从头重打包)
    try {
      tempPath = await w.pack(srcPath: srcPath, plan: plan, base: base);
    } catch (err) {
      AppLog.error('motion-upload', 'motion livp 打包失败:$base', err);
      rethrow;
    }
    // ③ 上传(16MB 流式轨);进度按复验后实际 size 归一并 clamp(⑤)
    await w.upload(
      folderId: folderId,
      filename: '$base.livp',
      path: tempPath,
      contentType: 'application/zip',
      cancelToken: token,
      onProgress: (done, total) =>
          onProgress(mapMotionProgress(done, total, size, totalBytes)),
    );
    AppLog.info('upload', '✓ 已上传:$base.livp → $where');
    notifyUploadSuccess(folderId);
  } finally {
    // ④ 终态(成功/失败/取消)一律删临时(进程被杀=非终态,finally 不执行,
    // 遗留项 10 记档);删除失败静默,不掩盖主流程结果
    if (tempPath != null) await w.deleteTemp(tempPath);
  }
}

/// 降级普通轨:原档直传,实际上传名 {base}.jpg / image/jpeg——仍以 .livp 名
/// 传 JPEG 原字节会让后端 livp 双 job 永久失败 + unpacked 恒 404 挡自愈
/// (§5.3);传输卡片显示名仍 .livp 属已知取舍。正常返回=任务算成功。
Future<void> _uploadOriginalAsJpg(
  MotionPhotoWorkerIo w, {
  required void Function(int doneBytes) onProgress,
  required CancelToken token,
  required String folderId,
  required String base,
  required String srcPath,
  required int totalBytes,
}) async {
  final size = await w.sizeOf(srcPath);
  await w.upload(
    folderId: folderId,
    filename: '$base.jpg',
    path: srcPath,
    contentType: 'image/jpeg',
    cancelToken: token,
    onProgress: (done, total) =>
        onProgress(mapMotionProgress(done, total, size, totalBytes)),
  );
}

/// 上传进度归一(纯函数,§5.3 ⑤):uploadFile 回报 (done, total) 为实际上传
/// 文件字节;按复验后实际 size [normalizeBytes] 折算回入队字节语义,再 clamp
/// 到入队 totalBytes——TOCTOU 后实际≠入队时进度不越界(消费端本有 clamp,
/// 此处为字节语义/单调正确,非修越界 bug)。total/normalize 非正值→0。
@visibleForTesting
int mapMotionProgress(
  int done,
  int total,
  int normalizeBytes,
  int enqueuedBytes,
) {
  if (total <= 0 || normalizeBytes <= 0) return 0;
  final scaled = (done * normalizeBytes / total).round();
  return scaled.clamp(0, enqueuedBytes);
}

/// 生产上传缺省:现有 uploadFile 16MB 流式轨(session 注入缝同仓库惯例)。
/// uploadFile 签名是 [MotionPhotoUpload] 的超集(多可选 partSize、contentType
/// 非必传),可直接 tear-off,零转发样板。
MotionPhotoUpload get _defaultUpload => session.api!.assets.uploadFile;

/// 生产清理缺省:幂等删临时,失败静默(临时区在 app cache,系统可回收)。
Future<void> _deleteTempQuietly(String path) async {
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

/// 生产大小读取缺省(复验超限复查与进度归一基准)。
Future<int> _defaultSizeOf(String path) => File(path).length();

// ── 打包内核(compute isolate;主 isolate 零大对象)─────────────────────────

/// 生产打包入口:主 isolate 解析临时目录完整路径(isolate 内平台通道不可用,
/// 路径随参数传入 compute)→ 唯一临时名 → [packMotionPhotoLivpInDir]。
Future<String> _packLivpToTemp({
  required String srcPath,
  required MotionPhotoPlan plan,
  required String base,
}) async {
  final tmp = await getTemporaryDirectory();
  return packMotionPhotoLivpInDir(
    srcPath: srcPath,
    plan: plan,
    base: base,
    dirPath: tmp.path,
  );
}

/// 打包到指定目录(内核真身;@visibleForTesting 供真打包单测与并发唯一名
/// 断言注入目录):目标文件在 worker 执行时才创建;失败尽力清扫半截产物。
@visibleForTesting
Future<String> packMotionPhotoLivpInDir({
  required String srcPath,
  required MotionPhotoPlan plan,
  required String base,
  required String dirPath,
}) async {
  final target = '$dirPath/motion_pack_${_newPackToken()}.livp';
  try {
    await compute(_packMotionPhotoLivpToFile, (
      srcPath: srcPath,
      targetPath: target,
      base: base,
      videoStart: plan.videoStart,
      videoEnd: plan.videoEnd,
    ));
  } catch (_) {
    try {
      final f = File(target);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    rethrow;
  }
  return target;
}

var _packSeq = 0;

/// 临时名唯一 token(§5.3:时间戳 36 进制 + 进程内自增序号——同微秒并发调用
/// 也不撞;taskId 在 enqueue 内才生成、worker 闭包先于入队构造拿不到,勿用)。
String _newPackToken() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${++_packSeq}';

/// compute isolate 消息(命名 record:纯路径/区间,零大对象过 isolate 边界)。
typedef _MotionPackJob = ({
  String srcPath,
  String targetPath,
  String base,
  int videoStart,
  int videoEnd,
});

/// compute isolate 顶层函数:全量读+按 plan 区间拆分+LivpService.pack(STORED:
/// jpg/mp4 已压缩,deflate 近零收益白烧 CPU,§5.3)落临时文件。条目名
/// {base}.jpg + {base}.mp4(后端 livp 两族扩展名直接命中,后端零感知)。
void _packMotionPhotoLivpToFile(_MotionPackJob job) {
  final all = File(job.srcPath).readAsBytesSync();
  final packed = LivpService.pack(
    imageBytes: all.sublist(0, job.videoStart),
    imageExt: 'jpg',
    videoBytes: all.sublist(job.videoStart, job.videoEnd),
    videoExt: 'mp4',
    baseName: job.base,
    stored: true,
  );
  File(job.targetPath).writeAsBytesSync(packed, flush: true);
}
