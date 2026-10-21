/// TransferTask — 传输中心数据模型(方案 §7,B3 功能点 3)。
///
/// 任务仅内存不持久化(杀 App 即清,与 web Uppy 刷新丢任务同语义,已定稿);
/// 下载类型本批先入模型(B4 预览页下载钮点亮时接入队方)。
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

/// worker:队列启动任务时调用。onProgress 上报已完成字节;token 供取消
/// (dio 请求挂 token;上传的尽力 abort 在 worker 内部 catch 里做,不挂 token)。
/// 抛异常即失败;UploadAmbiguousException 由队列映射「可能已上传」文案。
typedef TransferWorker = Future<void> Function(
    void Function(int doneBytes) onProgress, CancelToken token);

/// 入队描述。重试=同描述重新入队从头来(无断点续传),故 worker 自含全部上下文。
class TransferRequest {
  TransferRequest({
    required this.kind,
    required this.filename,
    required this.where,
    required this.totalBytes,
    required this.worker,
  });

  final TransferKind kind;

  /// 显示文件名(已净化)。
  final String filename;

  /// 所在位置显示路径(项目/文件夹,§7 where)。
  final String where;

  /// 预知总字节;0=未知(进度条转 indeterminate)。
  final int totalBytes;

  final TransferWorker worker;
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

  /// 0..1;totalBytes 未知(0)时 null → UI 转 indeterminate。
  double? get progress =>
      totalBytes > 0 ? (doneBytes / totalBytes).clamp(0.0, 1.0) : null;
}
