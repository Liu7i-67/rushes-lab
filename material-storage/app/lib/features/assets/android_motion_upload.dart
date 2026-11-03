/// Android motion photo 上传入队编排(方案 §5.3;worker 见
/// android_motion_worker.dart,本件=入队分支+入队壳,upload_pick 只留极简
/// 一行调用、upload_sheet 零改动——拆件兑现 300 行硬顶):
/// - [tryAndroidMotionPhoto]:`_enqueueAlbumAsset` 普通轨前的分支。只做格式
///   识别,不做机型白名单判定(上传↔下载判定刻意分离,D4);命中=Android +
///   jpg/jpeg + ≤150MB + 三读预筛(生产入口 probeMotionPhotoFileGuarded,
///   零全量读秒回)→ motion livp 任务入队;任何未命中/超限返回 false,调用方
///   照走普通轨原样(零改动)。
/// - [enqueueMotionPhotoUpload]:入队壳(显示名 {base}.livp、totalBytes=原档
///   字节数)。**打包延迟到队列 worker 执行时**:入队阶段 compute 打包会让
///   99 张批在汇总 toast 前串行等待分钟级、临时 livp 逐张落盘到各自成功终态
///   才删(≈3-6GB 共存);worker 内打包则同时存活的临时 livp 被队列并发(2)
///   自然封顶,retry=从头重打包语义更自然(§5.3)。
/// 异常语义(§7 第 5 条):probe 异常视同未命中落普通轨——预筛 IO 异常不得
/// 把整项计跳过(生产入口 guarded 已吞成 null,此 catch 兜注入假件,AppLog
/// 打点不静默);大小闸门(File.length)与入队异常照常外溢 → 外层
/// enqueueBatchNamed 逐项捕获计跳过(与 iOS 轨同语义)。
/// 注入缝(§5.3 测试铁律):isAndroid/sizeOf/probe/enqueue 全可注入,
/// @visibleForTesting,零平台通道可测。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:wechat_assets_picker/wechat_assets_picker.dart'
    show AssetEntity;

import '../../core/api/content_types.dart' show extOf;
import '../../core/transfers/transfer_queue.dart' show TransferQueue;
import '../../core/transfers/transfer_task.dart'
    show TransferKind, TransferRequest;
import '../../services/app_log.dart';
import '../../services/livp.dart' show LivpService;
import '../../services/motion_photo.dart'
    show MotionPhotoPlan, probeMotionPhotoFileGuarded;
// worker 拆件宿主(§5.3 注入缝钉 @visibleForTesting),本件是其唯一生产
// 调用方,非测试误用;拆件为兑现 300 行硬顶,跨库生产引用需就地豁免。
import 'android_motion_worker.dart' show kMotionPhotoMaxBytes;
// worker 拆件宿主(§5.3 注入缝钉 @visibleForTesting),本件是其唯一生产
// 调用方,非测试误用;拆件为兑现 300 行硬顶,跨库生产引用需就地豁免。
// ignore: invalid_use_of_visible_for_testing_member
import 'android_motion_worker.dart' show MotionPhotoWorkerIo;
// ignore: invalid_use_of_visible_for_testing_member
import 'android_motion_worker.dart' show runMotionPhotoWorker;

/// 入队分支编排(upload_pick `_enqueueAlbumAsset` 普通轨前极简一行调用;
/// 插入点=r 取得之后、普通轨 enqueueLocalUpload 之前,勿上提到 iOS 门之上:
/// iOS 轨会多付 originFile 读取,且 iOS 命名解析链不得被触碰):
/// [e] 相册资产(仅取 id 拼兜底基名)/ [folderId] [where] 目标夹与归属路径 /
/// [srcPath] originFile 本地路径 / [filename] resolveAlbumUploadName 解析名。
/// 返回 true=已接管(motion 任务已入队,调用方 return);false=落普通轨。
@visibleForTesting
Future<bool> tryAndroidMotionPhoto(
  AssetEntity e,
  String folderId,
  String where,
  String srcPath,
  String filename, {
  bool? isAndroid,
  Future<int> Function(String path)? sizeOf,
  Future<MotionPhotoPlan?> Function(String path)? probe,
  Future<String> Function({
    required String base,
    required String srcPath,
    required MotionPhotoPlan plan,
    required int srcBytes,
  })?
  enqueue,
}) async {
  if (!(isAndroid ?? (!kIsWeb && Platform.isAndroid))) return false;
  // title 可能是 X.JPG 原大写:extOf 内部 toLowerCase
  final ext = extOf(filename);
  if (ext != 'jpg' && ext != 'jpeg') return false;
  // 大小闸门前置:先查长度再付预筛(安卓长时实况可近百 MB,超限降级普通轨,
  // 防 isolate 内存峰值与后端 livp worker 200MB 永久失败带;异常外溢=该项计跳过)
  final srcBytes = await (sizeOf?.call(srcPath) ?? File(srcPath).length());
  if (srcBytes > kMotionPhotoMaxBytes) return false;
  MotionPhotoPlan? plan;
  try {
    plan = await (probe?.call(srcPath) ?? probeMotionPhotoFileGuarded(srcPath));
  } catch (err) {
    // 预筛异常视同未命中(不能把整项吞掉不上传,§7 第 5 条;AppLog 不静默)
    AppLog.error('motion-upload', '预筛异常,落普通轨:$filename', err);
    return false;
  }
  if (plan == null) return false;
  final base = LivpService.baseNameOf(filename, 'IMG_${e.id}');
  if (enqueue != null) {
    await enqueue(base: base, srcPath: srcPath, plan: plan, srcBytes: srcBytes);
  } else {
    enqueueMotionPhotoUpload(
      folderId: folderId,
      where: where,
      base: base,
      srcPath: srcPath,
      plan: plan,
      srcBytes: srcBytes,
    );
  }
  return true;
}

/// motion 上传入队壳(§5.3):totalBytes 以原档大小入队(STORED zip≈jpg+mp4
/// ≈原档,进度归一用,终值以 complete 回报为准);worker 闭包自含全部上下文,
/// 重试=同描述重新入队从头来。[io] 注入束透传 worker(测试假件由此进入,
/// 生产缺省);worker 闭包先于入队构造,taskId 此时未生成——临时文件唯一命名
/// 不依赖它(见 android_motion_worker.dart _newPackToken)。
String enqueueMotionPhotoUpload({
  required String folderId,
  required String where,
  required String base,
  required String srcPath,
  required MotionPhotoPlan plan,
  required int srcBytes,
  // 同 import 处豁免:worker 注入束跨库生产透传(唯一生产调用方)。
  // ignore: invalid_use_of_visible_for_testing_member
  MotionPhotoWorkerIo? io,
}) => TransferQueue.I.enqueue(
  TransferRequest(
    kind: TransferKind.upload,
    filename: '$base.livp',
    where: where,
    totalBytes: srcBytes,
    // ignore: invalid_use_of_visible_for_testing_member
    worker: (onProgress, token) => runMotionPhotoWorker(
      onProgress,
      token,
      folderId: folderId,
      where: where,
      base: base,
      srcPath: srcPath,
      enqueuePlan: plan,
      totalBytes: srcBytes,
      io: io,
    ),
  ),
);
