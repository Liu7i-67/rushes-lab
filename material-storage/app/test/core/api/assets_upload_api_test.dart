/// AssetsUploadApi 通道化改造单测(feat/ios-bg-upload 包 C,测试功能点 4/5):
/// 注入 fake PartPutChannel + 小 partSize,覆盖——
/// - batch 通道预签窗口循环(K=kSignAheadWindow):窗口切分与推进(前窗收敛
///   才签下一窗)、parts 顺序与 PartNumber/ETag 对齐、进度按窗口末片上报(D8)、
///   onSessionCreated 恰一次;
/// - 单分片失败 → 原始异常透传 + 整任务失败 + 尽力 abort、无 complete、
///   取消同窗兄弟分片(P2-2)+ 清会话临时目录(P2-3);
/// - complete 响应丢失 → UploadAmbiguousException 透传,禁自动重传;
/// - 非 batch 通道顺序路径回归(签一片传一片、逐片进度);
/// - 片间取消检查(窗口边界取消即停 + 尽力 abort);
/// - uploadBytes(livp 小包轨)batch 同口径;
/// - abortUpload 公开契约(恢复中断接线用)。
/// create/sign/complete/abort 经本地 HttpServer 挡网(同 upload_file_test
/// 先例);分片 PUT 由 fake 通道拦下,不触真实网络与平台通道。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/assets_upload_api.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/transfers/part_put_channel.dart';

/// 记录型 fake 通道:可编程 etag / 抛错 / 挂起放行(Completer 驱动窗口收敛)。
class _FakeChannel implements PartPutChannel {
  _FakeChannel({this.batch = true});

  final bool batch;

  @override
  bool get batchCapable => batch;

  final puts = <PartPutRequest>[]; // 入队序(partNumber)
  final chunkLens = <int, int>{};
  final chunks = <int, List<int>>{};
  final etagOf = <int, String>{};
  final failOn = <int, Object>{};
  final gates = <int, Completer<void>>{};

  @override
  Future<void> ensureInit() async {}

  @override
  Future<PartPutResult> put(PartPutRequest req) async {
    puts.add(req);
    chunkLens[req.partNumber] = req.chunk.length;
    chunks[req.partNumber] = List<int>.from(req.chunk);
    final gate = gates[req.partNumber];
    if (gate != null) await gate.future;
    final err = failOn[req.partNumber];
    if (err != null) throw err;
    return PartPutResult(etagOf[req.partNumber] ?? '"E${req.partNumber}"');
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

  void releaseAll() {
    for (final g in gates.values) {
      if (!g.isCompleted) g.complete();
    }
  }
}

void main() {
  /// 等待条件成立(有界真轮询):编排链含真实文件 IO + 本地 HTTP 往返,
  /// 纯微任务排空不保证落地,必须给事件循环留出完成时间(且不许 sleep 猜时序)。
  Future<void> waitUntil(bool Function() cond, {int maxTicks = 500}) async {
    for (var i = 0; i < maxTicks && !cond(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  group('uploadFile × fake 通道(窗口/顺序/失败/取消)', () {
    late HttpServer server;
    late String base;
    late MsApi api;
    late AssetsUploadApi upload;
    late File tmpFile;

    var createCalls = 0;
    final signs = <int>[];
    final completeBodies = <Map<String, dynamic>>[];
    var completeCalls = 0;
    final aborts = <String>[]; // 记录 query 里 bucket/key
    var completeBehavior = _CompleteBehavior.ok;

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        final path = req.uri.path;
        try {
          if (path == '/api/v1/assets/uploads' && req.method == 'POST') {
            createCalls++;
            await utf8.decoder.bind(req).join();
            _json(req, {'upload_id': 'u1', 'key': 'p/f/obj', 'bucket': 'b'});
            return;
          }
          final sign = RegExp(r'^/api/v1/assets/uploads/u1/parts/(\d+)$')
              .firstMatch(path);
          if (sign != null && req.method == 'GET') {
            await utf8.decoder.bind(req).join();
            signs.add(int.parse(sign.group(1)!));
            _json(req, {
              'url': '$base/part/${sign.group(1)}',
              'expires_in': 7200,
            });
            return;
          }
          if (path == '/api/v1/assets/uploads/u1/complete') {
            completeCalls++;
            final body = jsonDecode(
              await utf8.decoder.bind(req).join(),
            ) as Map<String, dynamic>;
            completeBodies.add(body);
            switch (completeBehavior) {
              case _CompleteBehavior.ok:
                _json(req, {
                  'id': 'a1',
                  'folder_id': 'f',
                  'filename': 'obj.bin',
                  'size_bytes': 1,
                  'content_type': 'application/octet-stream',
                  'created_at': '2026-11-27T10:00:00Z',
                });
              case _CompleteBehavior.badRequest:
                _json(req, {'detail': '该文件夹已存在同名文件'}, status: 400);
              case _CompleteBehavior.dropConnection:
                final socket = await req.response.detachSocket();
                socket.destroy();
            }
            return;
          }
          if (path == '/api/v1/assets/uploads/u1' && req.method == 'DELETE') {
            aborts.add(
              'bucket=${req.uri.queryParameters['bucket']} key=${req.uri.queryParameters['key']}',
            );
            req.response.statusCode = 204;
            await req.response.close();
            return;
          }
          _json(req, {'detail': 'no route'}, status: 404);
        } catch (_) {
          try {
            req.response.statusCode = 500;
            await req.response.close();
          } catch (_) {}
        }
      });
      api = MsApi(baseUrl: base);
      upload = AssetsUploadApi(api);
    });

    tearDownAll(() async {
      await server.close();
    });

    setUp(() async {
      createCalls = 0;
      signs.clear();
      completeBodies.clear();
      completeCalls = 0;
      aborts.clear();
      completeBehavior = _CompleteBehavior.ok;
      tmpFile = File(
        '${Directory.systemTemp.path}/bgc_api_${DateTime.now().microsecondsSinceEpoch}.bin',
      );
      // 定值内容:byte[i] = (i * 7) % 256
      final builder = BytesBuilder(copy: false);
      for (var i = 0; i < 64; i++) {
        builder.add([0]);
      }
      await tmpFile.writeAsBytes(builder.takeBytes()); // 占位,测试内重写
    });

    tearDown(() async {
      if (await tmpFile.exists()) await tmpFile.delete();
    });

    /// 重写临时文件为 size 字节确定性内容
    Future<void> makeFile(int size) async {
      final builder = BytesBuilder(copy: false);
      for (var i = 0; i < size; i++) {
        builder.add([(i * 7) % 256]);
      }
      await tmpFile.writeAsBytes(builder.takeBytes(), flush: true);
    }

    test('K=4 预签窗口:窗口切分与推进、parts 顺序、进度按窗口末片(D8)', () async {
      await makeFile(20); // partSize 3 → 7 片 → 两个窗口(4+3)
      final ch = _FakeChannel();
      for (final n in [1, 2, 3, 4]) {
        ch.gates[n] = Completer<void>();
      }
      final progress = <(int, int)>[];
      final sessions = <(String, String, String)>[];
      final f = upload.uploadFile(
        folderId: 'f',
        filename: 'obj.bin',
        path: tmpFile.path,
        partSize: 3,
        cancelToken: CancelToken(),
        onProgress: (d, t) => progress.add((d, t)),
        onSessionCreated: (id, b, k) => sessions.add((id, b, k)),
        channel: ch,
      );
      await waitUntil(() => ch.puts.length >= 4);
      // 窗口 1:前 4 片「读chunk→sign→入队(不等完成)」,未收敛不推进
      expect(ch.puts.map((p) => p.partNumber).toList(), [1, 2, 3, 4]);
      expect(signs, [1, 2, 3, 4], reason: '预签窗口:窗口内逐片先签');
      expect(completeCalls, 0);
      expect(sessions, [('u1', 'b', 'p/f/obj')], reason: 'create 成功后回调一次');
      ch.releaseAll();
      // 窗口 1 收敛后推进窗口 2(第 5..7 片)→ complete,全部 await 到底
      final asset = await f;
      expect(asset.filename, 'obj.bin');
      // 窗口推进后:全 7 片都已签+入队
      expect(ch.puts.map((p) => p.partNumber).toList(), [1, 2, 3, 4, 5, 6, 7]);
      expect(signs, [1, 2, 3, 4, 5, 6, 7]);
      // parts 顺序与 ETag 对齐(Future.wait 保序)
      final parts = completeBodies.single['parts'] as List;
      expect(parts.map((p) => p['PartNumber']).toList(), [1, 2, 3, 4, 5, 6, 7]);
      expect(parts.map((p) => p['ETag']).toList(),
          ['"E1"', '"E2"', '"E3"', '"E4"', '"E5"', '"E6"', '"E7"']);
      // 进度按窗口末片上报:窗口 1 末片 end=12、窗口 2 末片 end=20
      expect(progress, [(12, 20), (20, 20)]);
    });

    test('三窗推进(4/4/2)+ 窗口内乱序收敛 + 分片字节正确', () async {
      await makeFile(100); // partSize 10 → 10 片 → 三窗(4/4/2)
      final ch = _FakeChannel();
      for (final n in [1, 2, 3, 4, 5, 6, 7, 8]) {
        ch.gates[n] = Completer<void>();
      }
      final progress = <(int, int)>[];
      final f = upload.uploadFile(
        folderId: 'f',
        filename: 'obj.bin',
        path: tmpFile.path,
        partSize: 10,
        onProgress: (d, t) => progress.add((d, t)),
        channel: ch,
      );
      await waitUntil(() => ch.puts.length >= 4);
      expect(signs, [1, 2, 3, 4], reason: '窗口 1:签 1-4(不等完成)');
      // 分片字节正确(读盘起点/长度,makeFile 定值 pattern (i*7)%256)
      List<int> want(int start, int end) =>
          List.generate(end - start, (i) => ((start + i) * 7) % 256);
      expect(ch.chunks[1], want(0, 10));
      expect(ch.chunks[3], want(20, 30));
      expect(ch.chunks[4], want(30, 40));
      // 乱序收敛窗口 1(4→1→3→2):推进不受完成顺序影响
      for (final n in [4, 1, 3, 2]) {
        ch.gates[n]!.complete();
      }
      await waitUntil(() => signs.length >= 8);
      expect(signs, [1, 2, 3, 4, 5, 6, 7, 8], reason: '前窗完成才推进窗口 2');
      expect(ch.chunks[5], want(40, 50), reason: '跨窗读盘位置正确');
      for (final n in [5, 6, 7, 8]) {
        ch.gates[n]!.complete();
      }
      await waitUntil(() => signs.length >= 10);
      expect(signs, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], reason: '窗口 3 尾部 2 片');
      final asset = await f;
      expect(asset.filename, 'obj.bin');
      final parts = completeBodies.single['parts'] as List;
      expect(parts.map((p) => p['PartNumber']).toList(),
          [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      // 进度:三窗末片 end=40/80/100
      expect(progress, [(40, 100), (80, 100), (100, 100)]);
    });

    test('单分片失败 → 原始异常透传、整任务失败、尽力 abort、无 complete', () async {
      await makeFile(12); // 4 片,单窗口
      final ch = _FakeChannel();
      final boom = StateError('part-2 boom');
      ch.failOn[2] = boom;
      final token = CancelToken();
      await expectLater(
        upload.uploadFile(
          folderId: 'f',
          filename: 'obj.bin',
          path: tmpFile.path,
          partSize: 3,
          cancelToken: token,
          channel: ch,
        ),
        throwsA(same(boom)),
      );
      expect(completeCalls, 0, reason: '任一分片失败即整任务失败');
      expect(ch.cancelTokenCalls, [token], reason: 'P2-2:取消同窗兄弟分片');
      expect(aborts.length, 1, reason: 'catch 尽力 abort');
      expect(aborts.single, 'bucket=b key=p/f/obj');
      expect(ch.cleanups, ['u1'], reason: 'P2-3:失败收尾清会话临时分片目录');
      expect(createCalls, 1, reason: '无自动重传');
    });

    test('complete 响应丢失 → UploadAmbiguousException 透传 + abort', () async {
      await makeFile(3); // 1 片
      completeBehavior = _CompleteBehavior.dropConnection;
      final ch = _FakeChannel();
      await expectLater(
        upload.uploadFile(
          folderId: 'f',
          filename: 'obj.bin',
          path: tmpFile.path,
          partSize: 3,
          channel: ch,
        ),
        throwsA(isA<UploadAmbiguousException>()),
      );
      expect(createCalls, 1, reason: '禁自动重传');
      expect(aborts.length, 1);
      expect(ch.cleanups, ['u1'], reason: 'P2-3:complete 丢失也清会话临时目录');
    });

    test('非 batch 通道:顺序回归(签一片传一片、逐片进度)', () async {
      await makeFile(10); // 4 片
      final ch = _FakeChannel(batch: false);
      ch.gates[1] = Completer<void>(); // 挂住 part1 → 循环必须停住
      final progress = <(int, int)>[];
      final f = upload.uploadFile(
        folderId: 'f',
        filename: 'obj.bin',
        path: tmpFile.path,
        partSize: 3,
        onProgress: (d, t) => progress.add((d, t)),
        channel: ch,
      );
      await waitUntil(() => ch.puts.isNotEmpty);
      expect(ch.puts.map((p) => p.partNumber).toList(), [
        1,
      ], reason: '顺序通道:上一片完成前不得签/传下一片');
      expect(signs, [1]);
      ch.releaseAll();
      await f;
      expect(signs, [1, 2, 3, 4]);
      expect(ch.puts.map((p) => p.partNumber).toList(), [1, 2, 3, 4]);
      // 逐片进度(现状口径):end 字节推进
      expect(progress, [(3, 10), (6, 10), (9, 10), (10, 10)]);
    });

    test('片间取消(窗口边界):下一窗填充前检查取消即停 + 尽力 abort', () async {
      await makeFile(20); // 7 片两窗
      final ch = _FakeChannel();
      final token = CancelToken();
      final progress = <int>[];
      await expectLater(
        upload.uploadFile(
          folderId: 'f',
          filename: 'obj.bin',
          path: tmpFile.path,
          partSize: 3,
          cancelToken: token,
          onProgress: (d, t) {
            progress.add(d);
            token.cancel('用户取消'); // 窗口 1 末上报时机取消 → 窗口 2 填充前即停
          },
          channel: ch,
        ),
        throwsA(isA<DioException>()),
      );
      expect(token.isCancelled, isTrue);
      expect(progress, [12], reason: '窗口 1 末片上报后即取消');
      expect(signs, [1, 2, 3, 4], reason: '窗口 2 不再签名');
      expect(aborts.length, 1);
    });

    // 注:编排层不调 channel.ensureInit——幂等初始化由 bg 通道 put 内部
    // 触发 + main.dart iOS gate 静态入口负责(dio 通道 no-op),见
    // bg_part_put_channel_test 的 ensureInit 组用例。
  });

  group('uploadBytes(livp 小包轨)batch 同口径', () {
    test('16MB+1KB → 2 片单窗口,parts 顺序、onPartsDone 窗口口径', () async {
      final server = await _startUploadServer();
      addTearDown(server.close);
      final api = MsApi(baseUrl: server.base);
      final upload = AssetsUploadApi(api);
      final bytes = Uint8List(MsApi.partSize + 1024);
      final ch = _FakeChannel();
      final partsDone = <(int, int)>[];
      final sessions = <(String, String, String)>[];
      final asset = await upload.uploadBytes(
        folderId: 'f',
        filename: 'live.zip',
        bytes: bytes,
        onPartsDone: (d, t) => partsDone.add((d, t)),
        onSessionCreated: (id, b, k) => sessions.add((id, b, k)),
        channel: ch,
      );
      expect(asset.filename, 'live.zip');
      expect(ch.puts.map((p) => p.partNumber).toList(), [1, 2]);
      expect(ch.chunkLens[1], MsApi.partSize);
      expect(ch.chunkLens[2], 1024);
      expect(partsDone, [(2, 2)], reason: 'D8:batch 按窗口末片上报');
      expect(sessions, [('u1', 'b', 'k')]);
      final parts = server.completeBodies.single['parts'] as List;
      expect(parts.map((p) => p['PartNumber']).toList(), [1, 2]);
    });
  });

  group('abortUpload 公开契约(恢复中断接线,D6)', () {
    test('DELETE 带 bucket/key query;服务端 5xx 也不抛(尽力语义)', () async {
      final server = await _startUploadServer();
      addTearDown(server.close);
      final api = MsApi(baseUrl: server.base);
      final upload = AssetsUploadApi(api);
      server.abortStatus = 500;
      await upload.abortUpload('u-orphan', 'bk', 'kk');
      expect(server.abortPaths, ['/api/v1/assets/uploads/u-orphan']);
      expect(server.abortQueries, ['bucket=bk&key=kk']);
    });
  });
}

enum _CompleteBehavior { ok, badRequest, dropConnection }

/// uploadBytes/abort 用挡网服务(create/sign/complete/abort 记录)。
class _UploadServer {
  _UploadServer(this.server, this.base);

  final HttpServer server;
  final String base;
  final completeBodies = <Map<String, dynamic>>[];
  final abortPaths = <String>[];
  final abortQueries = <String>[];
  int abortStatus = 204;

  void close() => server.close();
}

Future<_UploadServer> _startUploadServer() async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final st = _UploadServer(s, 'http://127.0.0.1:${s.port}');
  s.listen((req) async {
    final path = req.uri.path;
    if (path == '/api/v1/assets/uploads' && req.method == 'POST') {
      await utf8.decoder.bind(req).join();
      _json(req, {'upload_id': 'u1', 'key': 'k', 'bucket': 'b'});
    } else if (req.method == 'GET' &&
        path.startsWith('/api/v1/assets/uploads/u1/parts/')) {
      await utf8.decoder.bind(req).join();
      final n = path.split('/').last;
      _json(req, {'url': '${st.base}/part/$n', 'expires_in': 7200});
    } else if (path == '/api/v1/assets/uploads/u1/complete') {
      final body = jsonDecode(
        await utf8.decoder.bind(req).join(),
      ) as Map<String, dynamic>;
      st.completeBodies.add(body);
      _json(req, {
        'id': 'a1',
        'folder_id': 'f',
        'filename': 'live.zip',
        'size_bytes': 1,
        'content_type': 'application/zip',
        'created_at': '2026-11-27T10:00:00Z',
      });
    } else if (req.method == 'DELETE' &&
        path.startsWith('/api/v1/assets/uploads/')) {
      st.abortPaths.add(path);
      st.abortQueries.add(req.uri.query);
      req.response.statusCode = st.abortStatus;
      await req.response.close();
    } else {
      _json(req, {'detail': 'no route'}, status: 404);
    }
  });
  return st;
}

void _json(HttpRequest req, Object? data, {int status = 200}) {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(data));
  req.response.close().ignore();
}
