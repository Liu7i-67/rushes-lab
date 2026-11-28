/// iOS 后台持续上传 — bg 通道真实逻辑集成单测(自 bg_upload_restore_test.dart
/// 拆分,验收修正 P2-4:原文件超 500 行口径;本文件承载原「bg 通道真实逻辑」
/// 组的 2 用例及其专用 fake/helper,语义一字不改——包 D 仲裁后的基线):
/// - put 全链路(临时分片写盘→UploadTask 形态钉子→complete 态小写 etag 键
///   收敛→临时文件用完即删);
/// - failed 403→「分片签名已过期」映射、取消联动 cancelTasksWithIds。
///
/// 确定性:BgDownloader 为 fake(不触真实平台通道),无真实网络/等待;
/// put 内部走真实异步文件 IO(建目录+writeAsBytes),断言以「fake 已录到
/// 目标状态」的有界真轮询为锚。
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

/// BgDownloader fake:记录注册回调/入队/取消调用,emit 手动派发终态更新。
class _FakeBgDownloader implements BgDownloader {
  final tasks = <UploadTask>[];
  final cancelCalls = <List<String>>[];
  final registeredGroups = <String>[];
  BgStatusCallback? statusCb;
  var initCalls = 0;

  @override
  Future<void> init() async => initCalls++;

  @override
  Future<bool> enqueue(UploadTask task) async {
    tasks.add(task);
    return true;
  }

  @override
  Future<bool> cancelTasksWithIds(Iterable<String> taskIds) async {
    cancelCalls.add(List<String>.from(taskIds));
    return true;
  }

  @override
  void registerStatusCallback(String group, BgStatusCallback cb) {
    registeredGroups.add(group);
    statusCb = cb;
  }

  /// 模拟插件侧派发状态更新(TaskStatusUpdate 位置参数:
  /// task, status, [exception, responseBody, responseHeaders, …])。
  void emit(UploadTask task, TaskStatus status,
      {Map<String, String>? headers, TaskException? exception}) {
    statusCb!(TaskStatusUpdate(task, status, exception, null, headers));
  }
}

void main() {
  /// 等待条件成立(有界真轮询,同 bg_upload_flow_test 口径):bg 通道 put
  /// 内部走真实异步文件 IO(建目录+writeAsBytes),微任务泵推不动——断言
  /// 以「fake 已录到目标状态」为锚(轮询谓词+超时上限,不 sleep 猜时序),
  /// ≈5s 总超时即 fail(带语义说明)。
  Future<void> waitUntil(bool Function() cond, String why,
      {int maxTicks = 500}) async {
    for (var i = 0; i < maxTicks && !cond(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (!cond()) fail('条件等待超时:$why');
  }

  /// 临时目录健壮删除:通道 put finally 的异步 file.delete 与 tearDown 竞态
  /// 时 Windows 报 errno=32(文件被占用)/145(目录非空)——短重试 3×50ms,
  /// 仍失败忽略不 fail(bg_upload_flow_test stage 同款口径)。
  Future<void> cleanupDir(Directory dir) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await dir.delete(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  group('bg 通道真实逻辑(fake BgDownloader,不触平台通道)', () {
    test('put 全链路:临时分片写盘→UploadTask 形态钉子→complete 小写 etag 键收敛→'
        '临时文件用完即删', () async {
      final base = await Directory.systemTemp.createTemp('ms_bg_chan');
      addTearDown(() => cleanupDir(base));
      final dl = _FakeBgDownloader();
      final ch = BgPartPutChannelImpl.forTest(downloader: dl, baseDir: base);
      final chunk = Uint8List.fromList([1, 2, 3, 4, 5]);
      final put = ch.put(PartPutRequest(
          url: 'https://minio.test/bk/p?sig=1',
          chunk: chunk,
          uploadId: 'up-bg',
          partNumber: 1));
      await waitUntil(() => dl.tasks.isNotEmpty, 'bg 分片任务已入队');

      expect(dl.registeredGroups, [kBgPartGroup], reason: '组回调先于入队注册');
      expect(dl.initCalls, 1, reason: 'put 内幂等 ensureInit');
      final task = dl.tasks.single;
      expect(task.url, 'https://minio.test/bk/p?sig=1');
      expect(task.group, kBgPartGroup);
      expect(task.httpRequestMethod, 'PUT', reason: 'binary PUT 钉子');
      expect(task.post, 'binary');
      expect(task.retries, 0, reason: '分片级不做自动重试');
      expect(task.headers[Headers.contentLengthHeader], '${chunk.length}',
          reason: '显式 Content-Length 头(411 钉子双保险)');
      final partFile = File('${base.path}/$kBgPartDirName/up-bg/part-1.bin');
      expect(partFile.existsSync(), isTrue, reason: 'chunk 先落盘(请求体=文件)');
      expect(partFile.readAsBytesSync(), chunk);

      dl.emit(task, TaskStatus.complete, headers: {'etag': 'etag-abc'});
      final result = await put;
      expect(result.etag, 'etag-abc', reason: 'D4:responseHeaders 小写键提取');
      expect(partFile.existsSync(), isFalse, reason: '临时分片文件用完即删');
    });

    test('failed 403 →「分片签名已过期」;cancelForToken 联动取消原生任务,canceled 收场',
        () async {
      final base = await Directory.systemTemp.createTemp('ms_bg_chan');
      addTearDown(() => cleanupDir(base));
      final dl = _FakeBgDownloader();
      final ch = BgPartPutChannelImpl.forTest(downloader: dl, baseDir: base);

      // 失败映射:403(预签过期,F8 兜底)→ ApiException 专用文案
      final put403 = ch.put(PartPutRequest(
          url: 'https://minio.test/bk/p?sig=1',
          chunk: Uint8List.fromList([1]),
          uploadId: 'up-403',
          partNumber: 1));
      await waitUntil(() => dl.tasks.isNotEmpty, '403 分片任务已入队');
      dl.emit(dl.tasks.single, TaskStatus.failed,
          exception: TaskHttpException('Forbidden', 403));
      final err =
          await put403.then<Object>((_) => 'no-throw', onError: (Object e) => e);
      expect(err, isA<ApiException>(), reason: '与 dio 403 路径同构(ApiException)');
      expect((err as ApiException).message, '分片签名已过期,请重新上传');

      // 取消联动:cancelForToken → 该 token 名下原生任务全取消;
      // canceled 终态回调 → put 以取消等价异常收场(DioException.cancel)
      final token = CancelToken();
      final putCancel = ch.put(PartPutRequest(
          url: 'https://minio.test/bk/p?sig=2',
          chunk: Uint8List.fromList([2]),
          uploadId: 'up-cancel',
          partNumber: 1,
          cancelToken: token));
      await waitUntil(() => dl.tasks.length >= 2, '取消目标分片任务已入队');
      final cancelTask = dl.tasks[1]; // 精确引用目标任务(不用 tasks.last 模糊取)
      await ch.cancelForToken(token);
      expect(dl.cancelCalls, [
        [cancelTask.taskId]
      ], reason: '联动取消该 token 名下的原生任务');
      dl.emit(cancelTask, TaskStatus.canceled);
      final cancelErr = await putCancel
          .then<Object>((_) => 'no-throw', onError: (Object e) => e);
      expect(cancelErr, isA<DioException>());
      expect((cancelErr as DioException).type, DioExceptionType.cancel,
          reason: '取消等价异常:队列/表单按取消语义处置(F4)');
    });
  });
}
