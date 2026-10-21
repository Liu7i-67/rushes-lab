/// uploadFile 流式分片单测(B3 测试功能点 4/5):分片边界纯函数(0 字节/
/// 整除不空发/余数片)+ 本地 HttpServer 按后端契约 mock 的端到端
/// (16MB 整倍恰 1 片、16MB+1KB 恰 2 片、字节一致、PUT 必带 Content-Length、
/// 取消即停+尽力 abort、complete 响应丢失→UploadAmbiguousException、
/// complete 4xx detail 照常透传)。契约以 api/app/routers/assets.py
/// uploads 三步+abort 为准。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/assets_api.dart';
import 'package:ms_app/core/api/ms_api.dart';

void main() {
  group('partRanges 分片边界(纯函数)', () {
    test('0 字节 → 单片空区间(仅一次空片,与 uploadBytes 同语义)', () {
      expect(AssetsApi.partRanges(0, 10), [(1, 0, 0)]);
    });
    test('恰为整数倍 → 不多出不空尾:10/10=1 片,20/10=2 片', () {
      expect(AssetsApi.partRanges(10, 10), [(1, 0, 10)]);
      expect(AssetsApi.partRanges(20, 10), [(1, 0, 10), (2, 10, 20)]);
    });
    test('有余数 → 末片为余数(非 0 字节空片)', () {
      expect(AssetsApi.partRanges(21, 10),
          [(1, 0, 10), (2, 10, 20), (3, 20, 21)]);
    });
    test('小于一片 → 1 片', () {
      expect(AssetsApi.partRanges(5, MsApi.partSize), [(1, 0, 5)]);
    });
  });

  group('uploadFile 端到端(本地 mock)', () {
    late HttpServer server;
    late MsApi api;
    late AssetsApi assets;
    late String base;

    final putParts = <int, List<int>>{};
    var createCalls = 0;
    var abortCalls = 0;
    var completeBehavior = _CompleteBehavior.ok;

    // 取消测试的确定性闸门:holdPart 的 PUT 读完 body 后 signal putArrived,
    // 再等 putHold 才响应(测试在窗口期内发起取消)
    var holdPart = 0;
    final putArrived = Completer<void>();
    final putHold = Completer<void>();

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        final path = req.uri.path;
        try {
          if (path == '/api/v1/assets/uploads' && req.method == 'POST') {
            createCalls++;
            await utf8.decoder.bind(req).join();
            _json(req, {'upload_id': 'u1', 'key': 'p/f/vid.mp4', 'bucket': 'b'});
            return;
          }
          final sign =
              RegExp(r'^/api/v1/assets/uploads/u1/parts/(\d+)$').firstMatch(path);
          if (sign != null && req.method == 'GET') {
            _json(req, {'url': '$base/part/${sign.group(1)}', 'expires_in': 900});
            return;
          }
          final put = RegExp(r'^/part/(\d+)$').firstMatch(path);
          if (put != null && req.method == 'PUT') {
            final n = int.parse(put.group(1)!);
            final bytes = await _readBytes(req);
            putParts[n] = bytes;
            // 回归守卫:流式分片 PUT 必带 Content-Length(prod 411 钉子)
            expect(req.headers.value(HttpHeaders.contentLengthHeader),
                '${bytes.length}',
                reason: 'part $n PUT 需固定长度,禁 chunked');
            if (n == holdPart) {
              putArrived.complete();
              await putHold.future; // 挂住响应,制造取消窗口
            }
            req.response.headers.set('etag', '"E$n"');
            req.response.statusCode = 200;
            await req.response.close();
            return;
          }
          if (path == '/api/v1/assets/uploads/u1/complete') {
            await utf8.decoder.bind(req).join();
            switch (completeBehavior) {
              case _CompleteBehavior.ok:
                _json(req, {
                  'id': 'a1',
                  'folder_id': 'f',
                  'filename': 'vid.mp4',
                  'size_bytes':
                      putParts.values.fold<int>(0, (a, b) => a + b.length),
                  'content_type': 'video/mp4',
                  'created_at': '2026-10-20T10:00:00Z',
                });
              case _CompleteBehavior.badRequest:
                _json(req, {'detail': '该文件夹已存在同名文件,请重命名后重新上传'},
                    status: 400);
              case _CompleteBehavior.dropConnection:
                // 模拟响应丢失:请求已达(体已读完)后掐断底层连接
                final socket = await req.response.detachSocket();
                socket.destroy();
            }
            return;
          }
          if (path == '/api/v1/assets/uploads/u1' && req.method == 'DELETE') {
            abortCalls++; // 尽力 abort 清悬挂分片
            req.response.statusCode = 204;
            await req.response.close();
            return;
          }
          _json(req, {'detail': 'no route: ${req.method} $path'}, status: 404);
        } catch (_) {
          try {
            req.response.statusCode = 500;
            await req.response.close();
          } catch (_) {}
        }
      });
      api = MsApi(baseUrl: base);
      assets = AssetsApi(api);
    });

    tearDownAll(() async {
      await server.close();
    });

    setUp(() {
      putParts.clear();
      createCalls = 0;
      abortCalls = 0;
      completeBehavior = _CompleteBehavior.ok;
      holdPart = 0;
    });

    tearDown(() {
      if (!putHold.isCompleted) putHold.complete();
    });

    test('16MB 整数倍:恰 1 片(整除不空发),字节一致,progress 走满', () async {
      final tmp = await _tempFile(MsApi.partSize);
      final progress = <int>[];
      final asset = await assets.uploadFile(
        folderId: 'f',
        filename: 'vid.mp4',
        path: tmp.path,
        contentType: 'video/mp4',
        onProgress: (d, t) => progress.add(d),
      );
      expect(asset.filename, 'vid.mp4');
      expect(putParts.keys.toList(), [1], reason: '16MB 整倍 → 恰 1 片,无第 2 空片');
      expect(putParts[1]!.length, MsApi.partSize);
      expect(progress.last, MsApi.partSize);
      // 流式字节一致(抽头尾 4KB,免整体比对内存翻倍)
      final head = await _readSlice(tmp, 0, 4096);
      final tail = await _readSlice(tmp, MsApi.partSize - 4096, MsApi.partSize);
      expect(putParts[1]!.sublist(0, 4096), head);
      expect(putParts[1]!.sublist(MsApi.partSize - 4096), tail);
      await tmp.delete();
    });

    test('16MB+1KB:恰 2 片,末片 1KB(余数片不空发)', () async {
      final tmp = await _tempFile(MsApi.partSize + 1024);
      await assets.uploadFile(
        folderId: 'f',
        filename: 'vid.mp4',
        path: tmp.path,
        contentType: 'video/mp4',
      );
      expect(putParts.keys.toList()..sort(), [1, 2]);
      expect(putParts[1]!.length, MsApi.partSize);
      expect(putParts[2]!.length, 1024);
      await tmp.delete();
    });

    test('流式结构(注入小片):4 字节文件 partSize=2 → 2+2,无第 3 空片', () async {
      final tmp = await _tempFile(4);
      await assets.uploadFile(
        folderId: 'f',
        filename: 'x.bin',
        path: tmp.path,
        partSize: 2,
      );
      expect(putParts.keys.toList()..sort(), [1, 2]);
      expect(putParts[1], [0, 1]);
      expect(putParts[2], [2, 3]);
      await tmp.delete();
    });

    test('取消:PUT 在途触发 CancelToken 即停,尽力 abort,抛 cancel', () async {
      final tmp = await _tempFile(4);
      final token = CancelToken();
      holdPart = 1;
      final f = assets.uploadFile(
        folderId: 'f',
        filename: 'x.bin',
        path: tmp.path,
        partSize: 2,
        cancelToken: token,
      );
      await putArrived.future; // part1 已达服务端、响应被挂住
      token.cancel('用户取消'); // CancelToken.cancel 为 void,无需 await
      await expectLater(f, throwsA(isA<DioException>()));
      expect(abortCalls, 1, reason: '取消后尽力 abort 悬挂 multipart');
      expect(token.isCancelled, isTrue);
      await tmp.delete();
    });

    test('complete 响应丢失(连接类异常)→ UploadAmbiguousException,无自动重传',
        () async {
      final tmp = await _tempFile(8);
      completeBehavior = _CompleteBehavior.dropConnection;
      await expectLater(
        assets.uploadFile(
          folderId: 'f',
          filename: 'vid.mp4',
          path: tmp.path,
          partSize: 8,
        ),
        throwsA(isA<UploadAmbiguousException>()),
      );
      expect(createCalls, 1, reason: '无幂等键,任何路径都不得自动重传');
      await tmp.delete();
    });

    test('complete 4xx:detail 照常透传 ApiException(非连接类不走专用异常)',
        () async {
      final tmp = await _tempFile(4);
      completeBehavior = _CompleteBehavior.badRequest;
      await expectLater(
        assets.uploadFile(
          folderId: 'f',
          filename: 'x.bin',
          path: tmp.path,
          partSize: 4,
        ),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', 400)
            .having((e) => e.message, 'detail', '该文件夹已存在同名文件,请重命名后重新上传')),
      );
      await tmp.delete();
    });
  });
}

enum _CompleteBehavior { ok, badRequest, dropConnection }

void _json(HttpRequest req, Object? data, {int status = 200}) {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(data));
  req.response.close().ignore();
}

Future<List<int>> _readBytes(HttpRequest req) async {
  final out = <int>[];
  await for (final chunk in req) {
    out.addAll(chunk);
  }
  return out;
}

/// 定值内容临时文件:byte[i] = i % 256
Future<File> _tempFile(int size) async {
  final f = File(
      '${Directory.systemTemp.path}/b3_upload_${DateTime.now().microsecondsSinceEpoch}_$size.bin');
  final builder = BytesBuilder(copy: false);
  var written = 0;
  var left = size;
  while (left > 0) {
    final n = left < (1 << 20) ? left : (1 << 20);
    builder.add(Uint8List.fromList(
        List<int>.generate(n, (i) => (written + i) % 256)));
    written += n;
    left -= n;
  }
  await f.writeAsBytes(builder.takeBytes());
  return f;
}

Future<Uint8List> _readSlice(File f, int start, int end) async {
  final raf = await f.open();
  try {
    await raf.setPosition(start);
    final out = BytesBuilder(copy: false);
    while (out.length < end - start) {
      final b = await raf.read(end - start - out.length);
      if (b.isEmpty) break;
      out.add(b);
    }
    return out.toBytes();
  } finally {
    await raf.close();
  }
}
