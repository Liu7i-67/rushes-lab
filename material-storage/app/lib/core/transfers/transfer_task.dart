/// TransferTask — 传输中心数据模型(方案 §7,B3 功能点 3)。
///
/// mobile-ux-polish-2 R4c 起任务快照持久化(应用支持目录 transfers.json,
/// 见 transfer_store.dart):终态记录跨进程保留展示,非终态恢复标「进程中断」;
/// worker 闭包不入快照(源信息不可序列化),恢复记录重试降级为提示重新发起。
///
/// feat/ios-bg-upload F5 起上传任务带会话三元组(uploadId/bucket/key):
/// create 成功后写回 task 并入快照,供「进程中断」恢复时尽力 abort 服务端
/// multipart 会话(D6,减少孤儿分片)。
library;

import 'package:dio/dio.dart';

enum TransferKind { upload, download }

enum TransferStatus { queued, running, done, failed, canceled }

extension TransferStatusX on TransferStatus {
  /// 终态(done/failed/canceled)才可移除/清已完成;queued/running 为活动态。
  bool get isTerminal =>
      this == TransferStatus.done ||
      this == TransferStatus.failed ||
      this == TransferStatus.canceled;

  String get label => switch (this) {
    TransferStatus.queued => '排队中',
    TransferStatus.running => '传输中',
    TransferStatus.done => '已完成',
    TransferStatus.failed => '失败',
    TransferStatus.canceled => '已取消',
  };
}

/// 上传会话三元组(F5,feat/ios-bg-upload):create 成功后由后端返回,
/// worker 运行期经 [TransferRequest.onSessionCreated] 交队列写回 task 并入
/// 快照;「进程中断」恢复时据此尽力 DELETE abort 服务端 multipart(D6)。
class TransferUploadSession {
  const TransferUploadSession({
    required this.uploadId,
    required this.bucket,
    required this.key,
  });

  final String uploadId;
  final String bucket;
  final String key;
}

/// worker:队列启动任务时调用。onProgress 上报已完成字节;token 供取消
/// (dio 请求挂 token;上传的尽力 abort 在 worker 内部 catch 里做,不挂 token)。
/// 抛异常即失败;UploadAmbiguousException 由队列映射「可能已上传」文案。
typedef TransferWorker = Future<void> Function(
  void Function(int doneBytes) onProgress,
  CancelToken token,
);

/// 入队描述。重试=同描述重新入队从头来(无断点续传),故 worker 自含全部上下文。
class TransferRequest {
  TransferRequest({
    required this.kind,
    required this.filename,
    required this.where,
    required this.totalBytes,
    required this.worker,
    this.onSessionCreated,
  });

  final TransferKind kind;

  /// 显示文件名(已净化)。
  final String filename;

  /// 所在位置显示路径(项目/文件夹,§7 where)。
  final String where;

  /// 预知总字节;0=未知(进度条转 indeterminate)。
  final int totalBytes;

  final TransferWorker worker;

  /// create 成功后的会话回写钩子(F5,**可变**):入队方提供一个原回调
  /// (可为留痕 no-op);队列 enqueue 时把它包装为「写回 task 三字段+调度
  /// 快照持久化+调原回调」后回填本字段——worker 运行期(create 成功桥接,
  /// 见 upload_sheet.dart)读到的必是包装层。retry 重新入队前由队列归还
  /// 原回调再按新任务重新包装,防旧包装闭包写回已移除的任务。
  void Function(TransferUploadSession session)? onSessionCreated;
}

class TransferTask {
  TransferTask({
    required this.id,
    required this.kind,
    required this.filename,
    required this.where,
    required this.totalBytes,
    this.doneBytes = 0,
    this.status = TransferStatus.queued,
    this.error,
    required this.startedAt,
    this.uploadId,
    this.uploadBucket,
    this.uploadKey,
  });

  final String id;
  final TransferKind kind;
  final String filename;
  final String where;
  final int totalBytes;
  int doneBytes;
  TransferStatus status;
  String? error;
  DateTime startedAt;

  /// 上传会话三元组(F5,feat/ios-bg-upload):create 成功后由队列包装层
  /// 写回并入快照;null=下载任务/尚未建会话。恢复「进程中断」时据此尽力
  /// abort 服务端会话(D6),见 transfer_queue.dart 恢复路径。
  String? uploadId;
  String? uploadBucket;
  String? uploadKey;

  /// 瞬态标记(不入快照):仅 decodeTasks 对快照非终态任务改写「进程中断」
  /// 时置位。队列恢复路径据此区分「本次恢复的中断任务」(应尽力 abort)与
  /// 「历史快照里本就 failed『进程中断』的记录」(上次恢复已 abort 过,不
  /// 重复);终态原样还原不置位。
  bool interruptedByRestore = false;

  /// 0..1;totalBytes 未知(0)时 null → UI 转 indeterminate。
  double? get progress =>
      totalBytes > 0 ? (doneBytes / totalBytes).clamp(0.0, 1.0) : null;
}
