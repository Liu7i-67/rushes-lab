/// BgPartPutChannel(iOS bg 分片通道)单测(feat/ios-bg-upload 包 B,
/// 测试功能点 3):fake BgDownloader 驱动,不触真实平台通道/真实网络。
/// 覆盖:幂等 init + 组回调注册 + F6 残留清理;UploadTask 任务形态
/// (binary PUT/group/retries/headers/临时目录);临时文件写/删时序;
/// complete 态 etag 小写键提取(缺失回空串);failed 态异常映射
/// (403→「分片签名已过期」/HTTP→badResponse/连接类/其余);取消联动
/// (cancelForToken 与 CancelToken.whenCancel 自动取消);token 映射
/// 不残留(P2-1);enqueue 拒绝;cleanupUpload/clearStaleChunkDir 目录
/// 收口。API 形态以 pub cache background_downloader 9.6.6 源码为准
/// (TaskStatusUpdate 位置参数顺序、responseHeaders 小写键、
/// TaskHttpException.httpResponseCode)。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart' show ApiException;
import 'package:ms_app/core/transfers/bg_downloader_adapter.dart';
import 'package:ms_app/core/transfers/bg_part_put_channel.dart';
import 'package:ms_app/core/transfers/part_put_channel.dart';

/// fake BgDownloader:记录调用、回调可编程,无平台通道。
class _FakeDownloader implements BgDownloader {
  int initCalls = 0;
  String? registeredGroup;
  BgStatusCallback? callback;
  final enqueued = <UploadTask>[];
  final canceled = <String>[];
  bool enqueueOk = true;

  @override
  Future<void> init() async {
    initCalls++;
  }

  @override
  Future<bool> enqueue(UploadTask task) async {
    enqueued.add(task);
    return enqueueOk;
  }

  @override
  Future<bool> cancelTasksWithIds(Iterable<String> taskIds) async {
    canceled.addAll(taskIds);
    return true;
  }

  @override
  void registerStatusCallback(String group, BgStatusCallback cb) {
    registeredGroup = group;
    callback = cb;
  }

  /// 模拟原生终态回调(参数顺序对应 TaskStatusUpdate 位置参数)。
  void emit(
    Task task,
    TaskStatus status, {
    TaskException? exception,
    Map<String, String>? responseHeaders,
    int? statusCode,
  }) {
    callback!(
      TaskStatusUpdate(
        task,
        status,
        exception,
        null,
        responseHeaders,
        statusCode,
      ),
    );
  }
}

void main() {
  /// 等待条件成立(有界真轮询):put 链含真实文件 IO(writeAsBytes/create/
  /// delete),纯微任务排空不保证落地,必须给 IO 完成留事件循环时间。
  Future<void> waitUntil(bool Function() cond, {int maxTicks = 500}) async {
    for (var i = 0; i < maxTicks && !cond(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  /// 等待 fake 上收到第 [count] 个入队任务并返回之。
  Future<UploadTask> waitEnqueued(_FakeDownloader dl, int count) async {
    await waitUntil(() => dl.enqueued.length >= count);
    return dl.enqueued[count - 1];
  }

  PartPutRequest req(String url, int partNumber, {CancelToken? token}) =>
      PartPutRequest(
        url: url,
        chunk: _Chunk.bytes,
        uploadId: 'u1',
        partNumber: partNumber,
        cancelToken: token,
      );

  late Directory baseDir;
  late _FakeDownloader fake;
  late BgPartPutChannelImpl channel;

  setUp(() async {
    baseDir = await Directory.systemTemp.createTemp('bg_part_test');
    fake = _FakeDownloader();
    channel = BgPartPutChannelImpl.forTest(downloader: fake, baseDir: baseDir);
  });

  tearDown(() async {
    await baseDir.delete(recursive: true);
  });

  File partFile(int n) =>
      File('${baseDir.path}/bg-upload-parts/u1/part-$n.bin');

  group('ensureInit(F2/F6)', () {
    test('幂等:多次调用 init 仅一次;组回调注册且 group 正确', () async {
      await channel.ensureInit();
      await channel.ensureInit();
      expect(fake.initCalls, 1);
      expect(fake.registeredGroup, 'ms-upload-parts');
      expect(fake.callback, isNotNull);
    });

    test('F6:启动清理进程被杀残留的 bg-upload-parts 目录树', () async {
      final stale = File('${baseDir.path}/bg-upload-parts/orphan/part-9.bin');
      await stale.create(recursive: true);
      await channel.ensureInit();
      expect(
        Directory('${baseDir.path}/bg-upload-parts').existsSync(),
        isFalse,
      );
    });

    test('门面静态入口与工厂单例同一实例(接线契约)', () {
      expect(BgPartPutChannel.instance, isA<PartPutChannel>());
      expect(
        identical(
          BgPartPutChannel.instance,
          createPartPutChannel(iosOverride: true),
        ),
        isTrue,
      );
    });
  });

  group('put(complete/failed/canceled 终态收敛)', () {
    test('任务形态:binary PUT/group/retries0/临时目录与文件名/headers', () async {
      final f = channel.put(req('https://minio.example/presigned?sig=x', 1));
      final t = await waitEnqueued(fake, 1);
      expect(t.url, 'https://minio.example/presigned?sig=x');
      expect(t.httpRequestMethod, 'PUT');
      expect(t.post, 'binary');
      expect(t.group, 'ms-upload-parts');
      expect(t.retries, 0);
      expect(t.updates, Updates.status);
      expect(t.baseDirectory, BaseDirectory.applicationDocuments);
      expect(t.directory, 'bg-upload-parts/u1');
      expect(t.filename, 'part-1.bin');
      expect(t.headers['content-length'], '${_Chunk.bytes.length}');
      expect(t.headers['Content-Disposition'], '');
      // 临时分片文件在途存在(原生侧上传的数据源)
      expect(partFile(1).existsSync(), isTrue);
      fake.emit(
        t,
        TaskStatus.complete,
        responseHeaders: {'etag': '"ET-1"'},
        statusCode: 200,
      );
      await expectLater(f, completion(isA<PartPutResult>()));
      // finally:临时文件用完即删
      expect(partFile(1).existsSync(), isFalse);
    });

    test('complete:etag 从小写键提取;响应头缺失回空串', () async {
      final f1 = channel.put(req('https://x/p1', 1));
      fake.emit(
        await waitEnqueued(fake, 1),
        TaskStatus.complete,
        responseHeaders: {'etag': '"A"', 'content-type': 'application/xml'},
        statusCode: 200,
      );
      expect((await f1).etag, '"A"');

      final f2 = channel.put(req('https://x/p2', 2));
      fake.emit(
        await waitEnqueued(fake, 2),
        TaskStatus.complete,
        statusCode: 200,
      );
      expect((await f2).etag, '');
    });

    test('非终态更新(enqueued/running)不收敛 put', () async {
      var resolved = false;
      final f = channel.put(req('https://x/p1', 1)).then((r) {
        resolved = true;
        return r;
      });
      final t = await waitEnqueued(fake, 1);
      fake.emit(t, TaskStatus.enqueued);
      fake.emit(t, TaskStatus.running);
      await waitUntil(() => false, maxTicks: 5); // 给几个空轮,确认不收敛
      expect(resolved, isFalse, reason: '非终态必须忽略');
      fake.emit(
        t,
        TaskStatus.complete,
        responseHeaders: {'etag': '"E"'},
        statusCode: 200,
      );
      expect((await f).etag, '"E"');
    });

    test('failed 403(TaskHttpException)→ ApiException「分片签名已过期」', () async {
      final f = channel.put(req('https://x/p1', 1));
      fake.emit(
        await waitEnqueued(fake, 1),
        TaskStatus.failed,
        exception: TaskHttpException('Forbidden', 403),
        statusCode: 403,
      );
      await expectLater(
        f,
        throwsA(
          isA<ApiException>()
              .having((e) => e.status, 'status', 403)
              .having((e) => e.message, 'message', contains('分片签名已过期')),
        ),
      );
    });

    test('failed 其他 HTTP 码 → DioException.badResponse(带状态码)', () async {
      final f = channel.put(req('https://x/p1', 1));
      fake.emit(
        await waitEnqueued(fake, 1),
        TaskStatus.failed,
        exception: TaskHttpException('InternalError', 500),
        statusCode: 500,
      );
      await expectLater(
        f,
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.badResponse)
              .having((e) => e.response?.statusCode, 'statusCode', 500),
        ),
      );
    });

    test('notFound(404 终态)→ DioException.badResponse 404', () async {
      final f = channel.put(req('https://x/p1', 1));
      fake.emit(
        await waitEnqueued(fake, 1),
        TaskStatus.notFound,
        statusCode: 404,
      );
      await expectLater(
        f,
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.badResponse)
              .having((e) => e.response?.statusCode, 'statusCode', 404),
        ),
      );
    });

    test('failed 连接类 → DioException.connectionError(断网/超时同 dio 口径)', () async {
      final f = channel.put(req('https://x/p1', 1));
      fake.emit(
        await waitEnqueued(fake, 1),
        TaskStatus.failed,
        exception: TaskConnectionException('offline'),
      );
      await expectLater(
        f,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.connectionError,
          ),
        ),
      );
    });

    test('failed 其余 → DioException.unknown(落传输失败兜底文案)', () async {
      final f = channel.put(req('https://x/p1', 1));
      fake.emit(
        await waitEnqueued(fake, 1),
        TaskStatus.failed,
        exception: TaskException('weird'),
      );
      await expectLater(
        f,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.unknown,
          ),
        ),
      );
    });

    test('canceled(无 token)→ 取消等价 DioException', () async {
      final f = channel.put(req('https://x/p1', 1));
      fake.emit(await waitEnqueued(fake, 1), TaskStatus.canceled);
      await expectLater(
        f,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
    });

    test('enqueue 拒绝(返回 false)→ unknown DioException,临时文件已清', () async {
      fake.enqueueOk = false;
      await expectLater(
        channel.put(req('https://x/p1', 1)),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.unknown,
          ),
        ),
      );
      expect(partFile(1).existsSync(), isFalse, reason: '失败路径 finally 也要删临时文件');
    });
  });

  group('取消联动(F4)', () {
    test(
      'cancelForToken → cancelTasksWithIds(在途 taskId);canceled 终态收场',
      () async {
        final token = CancelToken();
        final f = channel.put(req('https://x/p1', 1, token: token));
        final t = await waitEnqueued(fake, 1);
        await channel.cancelForToken(token);
        expect(fake.canceled, [t.taskId]);
        fake.emit(t, TaskStatus.canceled);
        await expectLater(
          f,
          throwsA(
            isA<DioException>().having(
              (e) => e.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );
        expect(partFile(1).existsSync(), isFalse);
      },
    );

    test('CancelToken.cancel 自动联动取消原生任务', () async {
      final token = CancelToken();
      final f = channel.put(req('https://x/p1', 1, token: token));
      final t = await waitEnqueued(fake, 1);
      token.cancel('用户取消');
      await waitUntil(() => fake.canceled.isNotEmpty);
      expect(fake.canceled, [
        t.taskId,
      ], reason: 'whenCancel 监听 → cancelTasksWithIds');
      fake.emit(t, TaskStatus.canceled);
      await expectLater(f, throwsA(isA<DioException>()));
    });

    test('已终态任务的 token 取消空跑(不误取消其他任务)', () async {
      final token = CancelToken();
      final f1 = channel.put(req('https://x/p1', 1, token: token));
      fake.emit(
        await waitEnqueued(fake, 1),
        TaskStatus.complete,
        responseHeaders: {'etag': '"E"'},
        statusCode: 200,
      );
      await f1;
      token.cancel('迟到的取消');
      await waitUntil(() => false, maxTicks: 6); // 给监听几个轮次
      expect(fake.canceled, isEmpty, reason: 'put 收尾已注销在途集合');
    });

    test('P2-1:put 收尾移除 taskId,空集整键删(token 映射不残留)', () async {
      final token = CancelToken();
      final f1 = channel.put(req('https://x/p1', 1, token: token));
      final t1 = await waitEnqueued(fake, 1);
      expect(channel.tokenKeyCount, 1, reason: '在途:token→taskId 映射存在');
      fake.emit(
        t1,
        TaskStatus.complete,
        responseHeaders: {'etag': '"E1"'},
        statusCode: 200,
      );
      await f1;
      expect(channel.tokenKeyCount, 0, reason: '收尾后空集整键移除');
      // 同 token 多次 put:每次收敛后都不残留(进程级单例不无界累积)
      final f2 = channel.put(req('https://x/p2', 2, token: token));
      final t2 = await waitEnqueued(fake, 2);
      fake.emit(
        t2,
        TaskStatus.complete,
        responseHeaders: {'etag': '"E2"'},
        statusCode: 200,
      );
      await f2;
      expect(channel.tokenKeyCount, 0);
      // 映射已清:cancelForToken 空跑无异常且不误取消
      await channel.cancelForToken(token);
      expect(fake.canceled, isEmpty);
    });

    test('P2-1:cancelForToken 清理路径下发取消后整键移除', () async {
      final token = CancelToken();
      final f = channel.put(req('https://x/p1', 1, token: token));
      final t = await waitEnqueued(fake, 1);
      await channel.cancelForToken(token);
      expect(fake.canceled, [t.taskId], reason: '名下在途任务全部下发取消');
      expect(channel.tokenKeyCount, 0, reason: '取消路径同样整键清理');
      fake.emit(t, TaskStatus.canceled); // 终态回调:put 以取消收场
      await expectLater(
        f,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(channel.tokenKeyCount, 0, reason: '终态 finally 移除为 no-op');
    });
  });

  group('临时目录收口', () {
    test('cleanupUpload 只删该会话目录', () async {
      final keep = File('${baseDir.path}/bg-upload-parts/u2/part-1.bin');
      await keep.create(recursive: true);
      final gone = File('${baseDir.path}/bg-upload-parts/u1/part-1.bin');
      await gone.create(recursive: true);
      await channel.cleanupUpload('u1');
      expect(gone.existsSync(), isFalse);
      expect(keep.existsSync(), isTrue);
    });

    test('clearStaleChunkDir 整树清理(幂等,目录不存在不抛)', () async {
      await File('${baseDir.path}/bg-upload-parts/u3/part-2.bin')
          .create(recursive: true);
      await channel.clearStaleChunkDir();
      expect(
        Directory('${baseDir.path}/bg-upload-parts').existsSync(),
        isFalse,
      );
      await channel.clearStaleChunkDir(); // 幂等
    });
  });
}

/// 定值 chunk(避免每个用例重复造 3 字节列表)
class _Chunk {
  static final bytes = Uint8List.fromList([1, 2, 3]);
}
