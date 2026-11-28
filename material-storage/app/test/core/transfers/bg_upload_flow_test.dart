/// iOS 后台持续上传 — 上传 API×通道×预签窗口循环 集成单测(qdev 2026-11-27 §8-4/5):
/// - batch 通道(K=4 预签窗口,D3):窗口切分与推进(前窗收敛才签下一窗)、
///   parts 顺序与 PartNumber/etag 对齐(与完成顺序无关)、进度按窗口推进
///   (D8 分片粒度口径)、onSessionCreated 恰一次且三元组正确;
/// - 失败/丢失/取消钉子:单分片失败→原始异常透传+取消同窗兄弟分片(P2-2)
///   +尽力 abort+清临时目录(P2-3)、complete 响应丢失→UploadAmbiguousException
///   透传且禁自动重传、片间取消生效;
/// - uploadBytes(livp 小包轨)单/多分片同口径(含失败 abort);
/// - 非 batch 通道(batchCapable=false)顺序路径回归(现状:签一片传一片、
///   逐片进度、片间取消检查);
/// - abortUpload 公开契约(恢复中断接线用,D6)。
///
/// 确定性:dio 经 HttpClientAdapter 替身挡网(fake_baidu.dart 先例,无真实
/// socket);通道为记录型 fake(可编程 etag/抛错/Completer 挂起放行)。时序:
/// 链路含真实临时文件 IO(readChunk)与完整 dio 异步链,微任务泵推不动——
/// 一律「等 fake 录到目标状态」的有界真轮询(assets_upload_api_test 的
/// waitUntil 谓词+超时);失败/取消类以 `await done`(收尾)为锚。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/assets_upload_api.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/transfers/part_put_channel.dart';

// ── dio 替身:挡住 create / sign / complete / abort 四类端点并记录调用 ──────

/// create 响应三元组 + 调用记录容器。
class _Rec {
  final createBodies = <Map<String, dynamic>>[];
  final signs = <int>[]; // 签名调用的 partNumber(调用序)
  final completeBodies = <Map<String, dynamic>>[];
  final aborts = <({String path, String? bucket, String? key})>[];
  var completeCalls = 0;

  /// 非空时 complete 抛此异常(模拟 complete 响应丢失)。
  Object? completeError;
  final uploadId = 'up-1';
  final bucket = 'ms-bucket';
  final key = 'p/obj-key';
}

ResponseBody _json(Object? payload, [int status = 200]) =>
    ResponseBody.fromString(jsonEncode(payload), status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        });

class _Adapter implements HttpClientAdapter {
  _Adapter(this.rec);

  final _Rec rec;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (options.method == 'POST' && path == '/api/v1/assets/uploads') {
      rec.createBodies.add((options.data as Map).cast<String, dynamic>());
      return _json(
          {'upload_id': rec.uploadId, 'bucket': rec.bucket, 'key': rec.key});
    }
    final sign =
        RegExp(r'^/api/v1/assets/uploads/[^/]+/parts/(\d+)$').firstMatch(path);
    if (options.method == 'GET' && sign != null) {
      final n = int.parse(sign.group(1)!);
      rec.signs.add(n);
      return _json(
          {'url': 'https://minio.test/${rec.bucket}/${rec.key}?part=$n'});
    }
    if (options.method == 'POST' &&
        path == '/api/v1/assets/uploads/${rec.uploadId}/complete') {
      rec.completeCalls++;
      if (rec.completeError != null) throw rec.completeError!;
      rec.completeBodies.add((options.data as Map).cast<String, dynamic>());
      final c = rec.createBodies.last;
      return _json({
        'id': 'asset-1',
        'filename': c['filename'],
        'size_bytes': c['size_bytes'],
        'created_at': '2026-11-27T10:00:00Z',
        'folder_id': c['folder_id'],
      });
    }
    if (options.method == 'DELETE' &&
        RegExp(r'^/api/v1/assets/uploads/[^/]+$').hasMatch(path)) {
      rec.aborts.add((
        path: path,
        bucket: options.uri.queryParameters['bucket'],
        key: options.uri.queryParameters['key'],
      ));
      return _json({});
    }
    return _json({'detail': 'unexpected ${options.method} $path'}, 404);
  }

  @override
  void close({bool force = false}) {}
}

// ── 记录型 PartPutChannel fake:可编程 etag / 抛错 / 挂起放行 ────────────────

class _FakeChannel implements PartPutChannel {
  _FakeChannel(
      {this.gated = false, this.batch = true, this.failParts = const {}});

  /// true=put 挂起直到手动放行(驱动窗口收敛时序观察)。
  final bool gated;
  final bool batch;
  final Set<int> failParts; // 这些 partNumber 的 put 抛异常

  final calls = <PartPutRequest>[];
  final gates = <Completer<void>>[]; // 序=片序(窗口内逐片入队)

  @override
  bool get batchCapable => batch;

  @override
  Future<void> ensureInit() async {}

  @override
  Future<PartPutResult> put(PartPutRequest req) async {
    calls.add(req);
    if (failParts.contains(req.partNumber)) {
      throw StateError('分片 ${req.partNumber} put 失败');
    }
    if (!gated) return PartPutResult('etag-${req.partNumber}');
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    return PartPutResult('etag-${req.partNumber}');
  }

  final cancelTokenCalls = <CancelToken>[]; // P2-2:失败取消同窗兄弟分片记录
  final cleanups = <String>[]; // P2-3:catch 收尾清临时目录记录

  @override
  Future<void> cancelForToken(CancelToken token) async {
    cancelTokenCalls.add(token);
  }

  @override
  Future<void> cleanupUpload(String uploadId) async {
    cleanups.add(uploadId);
  }
}

void main() {
  /// 等待条件成立(有界真轮询):编排链含真实临时文件 IO(readChunk)与
  /// 完整 dio 异步链,微任务/零延迟定时器泵推不动(Windows 实测首次文件 IO
  /// ≈10ms 级)——断言以「fake 已录到目标状态」为锚(assets_upload_api_test
  /// 同款:轮询谓词+超时上限,不 sleep 猜时序),超时即 fail(带语义说明)。
  Future<void> waitUntil(bool Function() cond, String why,
      {int maxTicks = 500}) async {
    for (var i = 0; i < maxTicks && !cond(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    if (!cond()) fail('条件等待超时:$why');
  }

  /// 装配注入替身的 AssetsUploadApi。
  (AssetsUploadApi, _Rec) makeApi() {
    final rec = _Rec();
    final msApi = MsApi(baseUrl: 'http://mock.local');
    msApi.http.httpClientAdapter = _Adapter(rec);
    return (AssetsUploadApi(msApi), rec);
  }

  /// 临时文件(size 字节,内容 48+i%10 确定性 pattern)+ 清理登记。
  /// Windows 文件锁(errno=32):raf 等句柄延迟释放,删除短重试(3×50ms)
  /// 后仍失败则忽略,不 fail 测试。
  Future<(List<int>, File)> stage(int size) async {
    final dir = await Directory.systemTemp.createTemp('ms_bg_flow');
    addTearDown(() async {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await dir.delete(recursive: true);
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    final bytes = [for (var i = 0; i < size; i++) 48 + i % 10];
    final f = File('${dir.path}/v.mp4');
    await f.writeAsBytes(bytes);
    return (bytes, f);
  }

  /// 放行当前全部挂起 put(窗口收敛)。
  void releaseAll(_FakeChannel ch) {
    for (final g in ch.gates) {
      if (!g.isCompleted) g.complete();
    }
    ch.gates.clear();
  }

  group('预签窗口循环(batch 通道,K=4)', () {
    test('K=4 窗口切分与推进:10 片→4/4/2 三窗,前窗收敛才签下一窗', () async {
      expect(kSignAheadWindow, 4, reason: 'D3 决策:预签窗口深度 K=4');
      final (api, rec) = makeApi();
      final (bytes, f) = await stage(100); // partSize=10 → 10 片
      final token = CancelToken();
      final ch = _FakeChannel(gated: true);

      final fut = api.uploadFile(
          folderId: 'f1', filename: 'v.mp4', path: f.path, partSize: 10,
          cancelToken: token, channel: ch);
      await waitUntil(() => ch.calls.length >= 4, '窗口1:4 片已入队');
      expect(rec.signs, [1, 2, 3, 4], reason: '窗口1:签 1-4 片(不等完成)');
      expect(ch.calls.map((r) => r.partNumber), [1, 2, 3, 4]);
      expect(ch.calls.every((r) => identical(r.cancelToken, token)), isTrue,
          reason: 'CancelToken 透传到分片通道');
      expect(listEquals(ch.calls[0].chunk, bytes.sublist(0, 10)), isTrue);

      releaseAll(ch); // 收敛窗口1
      await waitUntil(() => ch.calls.length >= 8, '窗口2:前窗完成才推进');
      expect(rec.signs, [1, 2, 3, 4, 5, 6, 7, 8], reason: '窗口2:前窗完成才推进');
      expect(listEquals(ch.calls[4].chunk, bytes.sublist(40, 50)), isTrue,
          reason: '跨窗口读盘内容正确(第 5 片=字节区间 [40,50))');
      releaseAll(ch); // 收敛窗口2
      await waitUntil(() => ch.calls.length >= 10, '窗口3:尾部 2 片入队');
      expect(rec.signs, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], reason: '窗口3:尾部 2 片');
      releaseAll(ch); // 收敛窗口3
      await waitUntil(() => rec.completeCalls >= 1, 'complete 收敛');

      final asset = await fut;
      expect(asset.id, 'asset-1', reason: 'complete 响应解析为 Asset');
      expect(rec.completeCalls, 1);
      expect(rec.aborts, isEmpty, reason: '成功路径无 abort');
    });

    test('parts 顺序与 PartNumber 正确:complete 体按 1..N 升序,etag 与乱序完成无关',
        () async {
      final (api, rec) = makeApi();
      final (_, f) = await stage(60); // 6 片(窗口 4/2)
      final ch = _FakeChannel(gated: true);
      final fut = api.uploadFile(
          folderId: 'f1', filename: 'v.mp4', path: f.path, partSize: 10, channel: ch);
      await waitUntil(() => ch.calls.length >= 4, '窗口1:4 片已入队');
      // 窗口1 乱序收敛:part4→1→3→2(gates 序=片序 1..4;Future.wait 等全窗
      // settle 才推进,乱序只影响 put 完成序,不影响窗口推进时机)
      for (final i in [3, 0, 2, 1]) {
        ch.gates[i].complete();
      }
      await waitUntil(() => ch.calls.length >= 6, '窗口1 收敛 → 窗口2 已入队');
      expect(rec.completeCalls, 0, reason: '窗口2 未传完不发 complete');
      releaseAll(ch); // 收敛窗口2
      await waitUntil(() => rec.completeCalls >= 1, 'complete 收敛');
      await fut;

      final body = rec.completeBodies.single;
      expect(body['upload_id'], rec.uploadId);
      expect(body['parts'], [
        for (var n = 1; n <= 6; n++) {'PartNumber': n, 'ETag': 'etag-$n'},
      ], reason: '按 PartNumber 升序对齐 etag(与完成顺序无关)');
    });

    test('进度按窗口推进:窗口收敛才回调,事件数=窗口数,单调且终值满格', () async {
      final (api, rec) = makeApi();
      final (_, f) = await stage(100);
      final ch = _FakeChannel(gated: true);
      final prog = <(int, int)>[];
      final fut = api.uploadFile(
          folderId: 'f1', filename: 'v.mp4', path: f.path, partSize: 10,
          onProgress: (d, t) => prog.add((d, t)), channel: ch);
      await waitUntil(() => ch.calls.length >= 4, '窗口1:4 片已入队');
      expect(prog, isEmpty, reason: '窗口未收敛不上报进度');

      releaseAll(ch); // 收敛窗口1
      await waitUntil(() => prog.isNotEmpty, '窗口1 收敛 → 推进一次');
      await waitUntil(() => ch.calls.length >= 8, '窗口2 已入队(挂起中)');
      expect(prog, hasLength(1), reason: '窗口1 收敛 → 恰一次推进;窗口2 挂起中不追加');

      releaseAll(ch); // 收敛窗口2
      await waitUntil(() => prog.length >= 2, '窗口2 收敛 → 第二次推进');
      await waitUntil(() => ch.calls.length >= 10, '窗口3 已入队(挂起中)');
      expect(prog, hasLength(2));

      releaseAll(ch); // 收敛窗口3
      await waitUntil(() => prog.length >= 3, '窗口3 收敛 → 第三次推进');
      await waitUntil(() => rec.completeCalls >= 1, 'complete 收敛');
      await fut;
      final done = prog.map((p) => p.$1).toList();
      expect(done, List.of(done)..sort(), reason: '进度单调不减');
      expect(prog.last.$2, 100);
      expect(prog.last.$1, prog.last.$2, reason: '终值满格');
    });

    test('onSessionCreated 恰一次,三元组=create 响应(uploadId/bucket/key)', () async {
      final (api, rec) = makeApi();
      final (_, f) = await stage(20); // 2 片
      final ch = _FakeChannel();
      final sessions = <List<String>>[];
      final asset = await api.uploadFile(
          folderId: 'f1', filename: 'v.mp4', path: f.path, partSize: 10,
          channel: ch, onSessionCreated: (id, b, k) => sessions.add([id, b, k]));
      expect(asset.id, 'asset-1');
      expect(sessions, [
        [rec.uploadId, rec.bucket, rec.key]
      ], reason: '恰一次且与 create 响应三元组一致');
      expect(ch.calls.every((r) => r.uploadId == rec.uploadId), isTrue,
          reason: '会话 uploadId 贯穿分片通道请求');
    });

    test('单分片失败:原始异常透传,尽力 abort(DELETE),后续窗口不再签名', () async {
      final (api, rec) = makeApi();
      final (_, f) = await stage(100); // 10 片,part3 坏
      final ch = _FakeChannel(failParts: {3});
      final token = CancelToken();
      final done = expectLater(
          api.uploadFile(
              folderId: 'f1', filename: 'v.mp4', path: f.path, partSize: 10,
              cancelToken: token, channel: ch),
          throwsA(isA<StateError>()));
      await done; // 失败收尾(尽力 abort 先于异常上抛,收尾即终态)
      expect(rec.signs, [1, 2, 3, 4], reason: '窗口1 内失败:窗口2 不再签名');
      expect(ch.cancelTokenCalls, [token], reason: 'P2-2:取消同窗兄弟分片');
      expect(rec.aborts, hasLength(1), reason: '失败时尽力清半成品 multipart');
      expect(rec.aborts.single.path, '/api/v1/assets/uploads/${rec.uploadId}');
      expect(rec.aborts.single.bucket, rec.bucket);
      expect(rec.aborts.single.key, rec.key);
      expect(ch.cleanups, [rec.uploadId], reason: 'P2-3:失败收尾清会话临时分片目录');
    });

    test('complete 响应丢失:透传 UploadAmbiguousException,complete 恰一次(禁自动重传),仍尽力 abort',
        () async {
      final (api, rec) = makeApi();
      rec.completeError = SocketException('connection reset');
      final (_, f) = await stage(20);
      final ch = _FakeChannel();
      final done = expectLater(
          api.uploadFile(
              folderId: 'f1', filename: 'v.mp4', path: f.path, partSize: 10, channel: ch),
          throwsA(isA<UploadAmbiguousException>()));
      await done;
      expect(rec.completeCalls, 1, reason: '禁自动重传(§4.1:防重复资产)');
      expect(rec.aborts, hasLength(1),
          reason: 'complete 丢失仍尽力 abort(已达则无害落空)');
    });

    test('片间取消生效(batch):取消后不再签下一窗,abort 尽力', () async {
      final (api, rec) = makeApi();
      final (_, f) = await stage(100);
      final token = CancelToken();
      final ch = _FakeChannel(gated: true);
      final done = expectLater(
          api.uploadFile(
              folderId: 'f1', filename: 'v.mp4', path: f.path, partSize: 10,
              cancelToken: token, channel: ch),
          throwsA(anything));
      await waitUntil(() => ch.calls.length >= 4, '窗口1 已入队');
      expect(rec.signs, [1, 2, 3, 4], reason: '窗口1 已签');
      token.cancel('用户取消');
      releaseAll(ch); // 收敛窗口1 → 下一窗片间检查命中取消
      await done; // 取消检查命中 → 失败收尾(含尽力 abort)
      expect(rec.signs, [1, 2, 3, 4], reason: '取消后窗口2 不再签名(片间检查钉子)');
      expect(rec.aborts, hasLength(1), reason: '取消也尽力清服务端会话(F4)');
    });
  });

  group('uploadBytes(livp 小包轨)同口径', () {
    test('单分片:1 签 1 传,PartNumber=1,chunk 原样,onSessionCreated/complete 同口径',
        () async {
      final (api, rec) = makeApi();
      final ch = _FakeChannel();
      final bytes = [1, 2, 3, 4, 5, 6, 7, 8];
      var sessions = 0;
      final asset = await api.uploadBytes(
          folderId: 'f1',
          filename: 'a.livp',
          bytes: bytes,
          contentType: 'application/zip',
          channel: ch,
          onSessionCreated: (id, b, k) => sessions++);
      expect(asset.id, 'asset-1');
      expect(sessions, 1);
      expect(rec.signs, [1]);
      expect(ch.calls.single.partNumber, 1);
      expect(listEquals(ch.calls.single.chunk, bytes), isTrue,
          reason: '小包整包单片,chunk 与入参一致');
      expect(rec.completeBodies.single['parts'], [
        {'PartNumber': 1, 'ETag': 'etag-1'}
      ]);
      expect(rec.aborts, isEmpty);
    });

    test('多分片(partSize+9B→2 片):不等完成并发入队,分片/etag 映射同口径', () async {
      final (api, rec) = makeApi();
      final ch = _FakeChannel(gated: true);
      final ps = MsApi.partSize;
      final bytes = Uint8List(ps + 9); // 2 片
      final fut = api.uploadBytes(
          folderId: 'f1', filename: 'b.livp', bytes: bytes, channel: ch);
      await waitUntil(() => ch.calls.length >= 2, '两片均已入队(不等完成)');
      expect(rec.signs, [1, 2], reason: 'K=4 单窗:两片均入队(不等完成)');
      expect(ch.calls.map((r) => r.partNumber), [1, 2]);
      expect(ch.calls[0].chunk.length, ps);
      expect(ch.calls[1].chunk.length, 9);
      expect(listEquals(ch.calls[1].chunk, bytes.sublist(ps, ps + 9)), isTrue);
      releaseAll(ch); // 收敛两片
      await waitUntil(() => rec.completeCalls >= 1, 'complete 收敛');
      final asset = await fut;
      expect(asset.id, 'asset-1');
      expect(rec.completeBodies.single['parts'], [
        {'PartNumber': 1, 'ETag': 'etag-1'},
        {'PartNumber': 2, 'ETag': 'etag-2'},
      ]);
    });

    test('分片失败:抛原始异常且尽力 abort(livp 轨与流式轨同口径)', () async {
      final (api, rec) = makeApi();
      final ch = _FakeChannel(failParts: {1});
      final token = CancelToken();
      final done = expectLater(
          api.uploadBytes(folderId: 'f1', filename: 'c.livp', bytes: [1, 2],
              cancelToken: token, channel: ch),
          throwsA(isA<StateError>()));
      await done; // 失败收尾(尽力 abort 先于异常上抛)
      expect(rec.aborts, hasLength(1));
      expect(ch.cancelTokenCalls, [token], reason: 'P2-2:batch 失败联动取消');
      expect(ch.cleanups, [rec.uploadId], reason: 'P2-3:失败收尾清会话临时目录');
    });
  });

  group('非 batch 通道(batchCapable=false)顺序路径回归', () {
    test('顺序路径:签一片传一片(前片未收敛不签下一片),进度逐片推进(现状口径)',
        () async {
      final (api, rec) = makeApi();
      final (_, f) = await stage(30); // 3 片
      final ch = _FakeChannel(batch: false, gated: true);
      final prog = <(int, int)>[];
      final fut = api.uploadFile(
          folderId: 'f1', filename: 'v.mp4', path: f.path, partSize: 10,
          onProgress: (d, t) => prog.add((d, t)), channel: ch);
      await waitUntil(() => ch.calls.isNotEmpty, '片1 已入队');
      expect(rec.signs, [1], reason: 'put1 未完成不签第 2 片(Android 现状语义)');

      releaseAll(ch); // 收敛片1
      await waitUntil(() => ch.calls.length >= 2, '片1 收敛 → 片2 已入队');
      expect(rec.signs, [1, 2]);
      releaseAll(ch); // 收敛片2
      await waitUntil(() => ch.calls.length >= 3, '片2 收敛 → 片3 已入队');
      releaseAll(ch); // 收敛片3
      await waitUntil(() => rec.completeCalls >= 1, 'complete 收敛');
      final asset = await fut;
      expect(asset.id, 'asset-1');
      expect(prog, [(10, 30), (20, 30), (30, 30)],
          reason: '现状口径:逐片上报(end,size)');
    });

    test('顺序路径片间取消生效:取消后下一片不签,abort 尽力', () async {
      final (api, rec) = makeApi();
      final (_, f) = await stage(30);
      final token = CancelToken();
      final ch = _FakeChannel(batch: false, gated: true);
      final done = expectLater(
          api.uploadFile(
              folderId: 'f1', filename: 'v.mp4', path: f.path, partSize: 10,
              cancelToken: token, channel: ch),
          throwsA(anything));
      await waitUntil(() => ch.calls.isNotEmpty, '片1 已入队');
      expect(rec.signs, [1]);
      token.cancel('用户取消');
      releaseAll(ch); // put1 收敛 → 片间检查命中取消
      await done; // 取消检查命中 → 失败收尾(含尽力 abort)
      expect(rec.signs, [1], reason: '片间取消检查:第 2 片不签');
      expect(rec.aborts, hasLength(1));
    });
  });

  group('abortUpload 公开契约(恢复中断接线用,D6)', () {
    test('abortUpload(uploadId,bucket,key):DELETE /uploads/{id}?bucket&key',
        () async {
      final (api, rec) = makeApi();
      await api.abortUpload('u-abort', 'bk-x', 'key-x');
      expect(rec.aborts.single.path, '/api/v1/assets/uploads/u-abort');
      expect(rec.aborts.single.bucket, 'bk-x');
      expect(rec.aborts.single.key, 'key-x');
    });
  });
}
