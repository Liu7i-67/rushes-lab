/// BgPartPutChannel — iOS 后台分片 PUT 通道(包 B 核心):chunk 写临时文件 →
/// UploadTask(binary PUT,httpRequestMethod 'PUT')→ enqueue 进系统
/// background URLSession 队列 → Completer 桥把 TaskStatusUpdate 收敛成
/// [PartPutResult]。App 切后台/锁屏后被挂起,分片由系统网络进程继续传;
/// 挂起期间的更新由插件 iOS 原生 delegate 直投(handleEventsForBackground
/// URLSession,系统唤醒窗口自动转发,见 bg_downloader_adapter 库头注释),
/// 回前台后进度与终态不丢。
///
/// ETag 来源:TaskStatusUpdate.responseHeaders['etag'](插件已在原生侧把
/// 键统一小写;缺失回空串,与 dio 路径口径一致)。失败映射:403 →
/// 「分片签名已过期」(预签 TTL 过期,7200s 窗口极端场景兜底);其余 HTTP
/// 码/连接类/取消分别映射回 DioException 对应形态,传输队列文案语义不变。
///
/// 临时分片目录:`<Documents>/bg-upload-parts/<uploadId>/part-<n>.bin`。
/// base 用 BaseDirectory.applicationDocuments(与 path_provider
/// getApplicationDocumentsDirectory 在 iOS 同源 NSDocumentDirectory 一一对应;
/// 插件的 BaseDirectory.temporary 在 iOS 原生侧映射 NSCachesDirectory,与
/// path_provider 的 tmp 目录不同源,写入/上传会找不到文件——源码核验后规避)。
///
/// 结构钉子:Dart 禁止同名 static 与 instance 成员共存,而 PartPutChannel
/// 接口的 ensureInit 是实例方法、main.dart 启动接线要静态入口——拆成
/// [BgPartPutChannel] 静态门面 + [BgPartPutChannelImpl] 单例实现两班倒。
library;

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../api/ms_api.dart' show ApiException;
import 'bg_downloader_adapter.dart';
import 'part_put_channel.dart';

/// 分片任务/回调共用的 group(回调注册与任务 group 必须一致才会收到更新)
const String kBgPartGroup = 'ms-upload-parts';

/// 临时分片根目录名(Documents 下)
const String kBgPartDirName = 'bg-upload-parts';

/// 静态门面:main.dart 等 App 接线入口(仅静态,无状态)。
class BgPartPutChannel {
  BgPartPutChannel._();

  /// 通道单例(工厂 createPartPutChannel 在 iOS 返回它)。
  static final BgPartPutChannelImpl instance = BgPartPutChannelImpl.I;

  /// F2/F6 启动初始化(幂等):注册组状态回调 + 插件就绪 +
  /// 清进程被杀残留的分片临时目录。失败静默处可 put 时幂等重试。
  static Future<void> ensureInit() => instance.ensureInit();
}

/// 通道实现(单例):PartPutChannel 的 iOS 后台 URLSession 实现。
class BgPartPutChannelImpl implements PartPutChannel {
  BgPartPutChannelImpl._(this._downloader, this._baseDirOverride);

  /// 进程级单例:registerCallbacks 按 group 全局注册,多实例会互相顶掉
  /// 回调导致 put 永不收敛,必须全 App 复用同一实例。
  static final BgPartPutChannelImpl I = BgPartPutChannelImpl._(null, null);

  /// 单测构造:注入 fake BgDownloader + 临时 baseDir,不触真实平台通道。
  @visibleForTesting
  factory BgPartPutChannelImpl.forTest({
    BgDownloader? downloader,
    Directory? baseDir,
  }) => BgPartPutChannelImpl._(downloader, baseDir);

  final BgDownloader? _downloader;
  final Directory? _baseDirOverride;

  /// 下游下载器:测试注入优先;生产包 RealBgDownloader(FileDownloader)。
  BgDownloader get _dl => _downloader ?? RealBgDownloader.instance;

  /// 在途任务:taskId → 收敛器与取消令牌(终态回调据此路由)。
  final Map<String, _PendingPart> _inflight = {};

  /// token → 在途 taskId 集(cancelForToken / whenCancel 联动取消)。
  final Map<CancelToken, Set<String>> _tokenTasks = {};

  Future<void>? _initFuture;

  @override
  bool get batchCapable => true;

  /// 单测可断言的最小计数(P2-1:token 映射不残留用例)。
  @visibleForTesting
  int get tokenKeyCount => _tokenTasks.length;

  /// 幂等初始化:注册组回调(须先于 init,插件直投更新才有人接)→
  /// 插件就绪(内部含唯一一次落库补收)→ F6 清理进程被杀残留的临时分片
  /// 目录。并发调用合一。
  @override
  Future<void> ensureInit() {
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    try {
      _dl.registerStatusCallback(kBgPartGroup, _onStatus);
      await _dl.init();
      await clearStaleChunkDir();
    } catch (_) {
      _initFuture = null; // 失败允许下次重试(初值短路会让后续 put 用裸回调)
      rethrow;
    }
  }

  @override
  Future<PartPutResult> put(PartPutRequest req) async {
    await ensureInit();
    final filename = 'part-${req.partNumber}.bin';
    final dir = await _sessionDir(req.uploadId);
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(req.chunk, flush: true);
    // binary PUT 任务:文件即请求体(iOS 原生 uploadTask fromFile,
    // Content-Length 由系统按文件尺寸设定;显式头一并带上作双保险,
    // 与 dio 通道 411 钉子同源)。Content-Disposition 空串=插件约定不设该头
    // (S3/MinIO 预签 PUT 无需;非空会额外塞 attachment 文件名)。retries=0:
    // 失败即失败,按现状由上层任务语义处置,不做分片级自动重试。
    final task = UploadTask(
      url: req.url,
      filename: filename,
      directory: '$kBgPartDirName/${req.uploadId}',
      baseDirectory: BaseDirectory.applicationDocuments,
      group: kBgPartGroup,
      updates: Updates.status,
      httpRequestMethod: 'PUT',
      post: 'binary',
      mimeType: 'application/octet-stream',
      retries: 0,
      headers: {
        Headers.contentLengthHeader: '${req.chunk.length}',
        'Content-Disposition': '',
      },
    );
    final completer = Completer<PartPutResult>();
    final token = req.cancelToken;
    _inflight[task.taskId] = _PendingPart(completer, token, req.url);
    if (token != null) {
      _tokenTasks.putIfAbsent(token, () => <String>{}).add(task.taskId);
      // 取消联动(前台取消即刻生效):token 取消 → 取消原生任务 →
      // canceled 终态回调让 completer 以取消等价异常收场。任务已终态时
      // 本监听空跑(cancelForToken 对空集合 no-op),无需反注册。
      unawaited(token.whenCancel.then((_) => cancelForToken(token)));
    }
    try {
      final ok = await _dl.enqueue(task);
      if (!ok) {
        // 插件拒绝入队(如原生侧找不到上传文件):按未知传输失败收场
        throw DioException(
          requestOptions: RequestOptions(path: req.url),
          type: DioExceptionType.unknown,
          error: '后台分片任务入队失败(part ${req.partNumber})',
        );
      }
      return await completer.future;
    } finally {
      _inflight.remove(task.taskId);
      if (token != null) {
        // P2-1:移除 taskId 后空集整键删——进程级单例的 _tokenTasks
        // 不随上传次数无界累积空 Set+CancelToken
        final ids = _tokenTasks[token];
        if (ids != null) {
          ids.remove(task.taskId);
          if (ids.isEmpty) _tokenTasks.remove(token);
        }
      }
      // 临时分片文件用完即删(目录留待 cleanupUpload/F6 收口)
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  @override
  Future<void> cancelForToken(CancelToken token) async {
    final ids = _tokenTasks[token];
    if (ids == null || ids.isEmpty) return;
    await _dl.cancelTasksWithIds(List<String>.from(ids));
    // 名下任务已全部下发取消 → 整键清理(P2-1,防残留);canceled 终态
    // 回调负责把对应 put 的 completer 以取消收场,届时 finally 的移除为
    // no-op;重复 cancelForToken 对空映射亦空跑
    _tokenTasks.remove(token);
  }

  @override
  Future<void> cleanupUpload(String uploadId) async {
    final dir = Directory(
      '${(await _rootDir()).path}/$kBgPartDirName/$uploadId',
    );
    if (await dir.exists()) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// F6 启动清理:整个 bg-upload-parts 树(进程被杀残留的 chunk 文件;
  /// 正常路径 put 的 finally 已逐文件删,此处兜底)。幂等。
  Future<void> clearStaleChunkDir() async {
    final root = Directory('${(await _rootDir()).path}/$kBgPartDirName');
    if (await root.exists()) {
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<Directory> _rootDir() async =>
      _baseDirOverride ?? await getApplicationDocumentsDirectory();

  Future<Directory> _sessionDir(String uploadId) async {
    final dir = Directory(
      '${(await _rootDir()).path}/$kBgPartDirName/$uploadId',
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// 组状态回调:仅处理终态(complete/notFound/failed/canceled),
  /// 非终态(enqueued/running/waitingToRetry/paused)忽略。
  void _onStatus(TaskStatusUpdate update) {
    final pending = _inflight[update.task.taskId];
    if (pending == null) return;
    switch (update.status) {
      case TaskStatus.complete:
        // responseHeaders 键已被插件统一小写 → etag 直接小写键取
        pending.completer.complete(
          PartPutResult(update.responseHeaders?['etag'] ?? ''),
        );
      case TaskStatus.failed || TaskStatus.notFound:
        pending.completer.completeError(
          _mapFailure(
            _TaskFailure(
              update.exception ?? TaskHttpException('upload failed', -1),
              url: pending.url,
              notFound: update.status == TaskStatus.notFound,
            ),
          ),
        );
      case TaskStatus.canceled:
        // 取消等价异常:与 dio 取消同形态(队列/表单按取消语义处置)
        pending.completer.completeError(
          pending.cancelToken?.cancelError ?? _cancelException(pending.url),
        );
      default:
        break;
    }
  }

  /// 插件失败态 → 与 dio 路径同构的异常形态(队列文案映射不变):
  /// 403(预签过期)→ ApiException「分片签名已过期」;其余 HTTP 码 →
  /// DioException.badResponse(落传输失败兜底文案);连接类 → connectionError;
  /// 其余 → unknown。
  Exception _mapFailure(_TaskFailure f) {
    final ex = f.exception;
    if (ex is TaskHttpException && ex.httpResponseCode == 403) {
      return ApiException(403, '分片签名已过期,请重新上传');
    }
    final code = f.notFound
        ? 404
        : ex is TaskHttpException && ex.httpResponseCode > 0
        ? ex.httpResponseCode
        : null;
    if (code != null) {
      return DioException(
        requestOptions: RequestOptions(path: f.url),
        type: DioExceptionType.badResponse,
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: f.url),
          statusCode: code,
        ),
      );
    }
    if (ex is TaskConnectionException) {
      return DioException(
        requestOptions: RequestOptions(path: f.url),
        type: DioExceptionType.connectionError,
        error: ex.description,
      );
    }
    return DioException(
      requestOptions: RequestOptions(path: f.url),
      type: DioExceptionType.unknown,
      error: ex.description.isEmpty ? '后台分片上传失败' : ex.description,
    );
  }

  DioException _cancelException(String url) => DioException(
    requestOptions: RequestOptions(path: url),
    type: DioExceptionType.cancel,
  );
}

/// 在途分片的收敛上下文。
class _PendingPart {
  _PendingPart(this.completer, this.cancelToken, this.url);

  final Completer<PartPutResult> completer;
  final CancelToken? cancelToken;
  final String url;
}

/// 失败映射的中间载体(异常 + 请求形态 + notFound 标记)。
class _TaskFailure {
  const _TaskFailure(
    this.exception, {
    required this.url,
    this.notFound = false,
  });

  final TaskException exception;
  final String url;
  final bool notFound;
}
