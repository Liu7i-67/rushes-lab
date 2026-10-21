/// uploadBytes(livp 小包轨)单测(B3 修复 P2-1):complete 响应丢失分类
/// [completeResponseLost] 纯函数矩阵(receiveTimeout/connectionError/
/// unknown+传输断裂=丢失;connectionTimeout/cancel/badResponse/裸 unknown=
/// 否,两轨共用)+ 本地 HttpServer mock 的 uploadBytes 端到端——complete
/// 连接被掐 → UploadAmbiguousException(与 uploadFile 同语义),禁自动重传
/// +尽力 abort;complete 4xx detail 照常透传 ApiException。
/// 契约以 api/app/routers/assets.py uploads 三步+abort 为准。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/assets_api.dart';
import 'package:ms_app/core/api/ms_api.dart';

void main() {
  group('completeResponseLost(complete 异常分类,uploadFile/uploadBytes 共用)',
      () {
    bool lost(DioExceptionType type, {Object? error}) =>
        completeResponseLost(DioException(
          requestOptions: RequestOptions(path: '/complete'),
          type: type,
          error: error,
        ));

    test('连接类(请求可能已达、响应丢失)→ true', () {
      expect(lost(DioExceptionType.receiveTimeout), isTrue);
      expect(lost(DioExceptionType.connectionError), isTrue);
      expect(lost(DioExceptionType.unknown, error: HttpException('closed')),
          isTrue, reason: '跳板机实测「Connection closed」落 unknown');
      expect(lost(DioExceptionType.unknown, error: SocketException('reset')),
          isTrue);
    });

    test('非连接类(必未达/用户取消/明确响应)→ false,照常透传', () {
      expect(lost(DioExceptionType.connectionTimeout), isFalse,
          reason: '连接未建立,请求必未达');
      expect(lost(DioExceptionType.cancel), isFalse, reason: '用户取消不算');
      expect(lost(DioExceptionType.badResponse), isFalse,
          reason: '4xx/5xx 透传后端 detail,不走专用异常');
      expect(lost(DioExceptionType.unknown), isFalse,
          reason: '裸 unknown 无传输断裂证据');
    });
  });

  group('uploadBytes 端到端(本地 mock)', () {
    late HttpServer server;
    late MsApi api;
    late AssetsApi assets;
    late String base;

    var createCalls = 0;
    var abortCalls = 0;
    var dropComplete = false;

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        final path = req.uri.path;
        try {
          if (path == '/api/v1/assets/uploads' && req.method == 'POST') {
            createCalls++;
            await utf8.decoder.bind(req).join();
            _json(req, {'upload_id': 'u1', 'key': 'p/f/a.livp', 'bucket': 'b'});
            return;
          }
          final sign =
              RegExp(r'^/api/v1/assets/uploads/u1/parts/(\d+)$').firstMatch(path);
          if (sign != null && req.method == 'GET') {
            _json(req, {'url': '$base/part/${sign.group(1)}', 'expires_in': 900});
            return;
          }
          if (path.startsWith('/part/') && req.method == 'PUT') {
            await _readBytes(req);
            req.response.headers.set('etag', '"E1"');
            req.response.statusCode = 200;
            await req.response.close();
            return;
          }
          if (path == '/api/v1/assets/uploads/u1/complete') {
            await utf8.decoder.bind(req).join();
            if (dropComplete) {
              // 模拟响应丢失:请求已达(体已读完)后掐断底层连接
              final socket = await req.response.detachSocket();
              socket.destroy();
              return;
            }
            _json(req, {
              'id': 'a1',
              'folder_id': 'f',
              'filename': 'a.livp',
              'size_bytes': 4,
              'content_type': 'application/zip',
              'created_at': '2026-10-20T10:00:00Z',
            });
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
      createCalls = 0;
      abortCalls = 0;
      dropComplete = false;
    });

    test('complete 响应丢失(连接被掐)→ UploadAmbiguousException,'
        '无自动重传 + 尽力 abort(小包轨与流式轨同语义)', () async {
      dropComplete = true;
      await expectLater(
        assets.uploadBytes(
          folderId: 'f',
          filename: 'a.livp',
          bytes: [1, 2, 3, 4],
        ),
        throwsA(isA<UploadAmbiguousException>()),
      );
      expect(createCalls, 1, reason: '无幂等键,任何路径都不得自动重传');
      expect(abortCalls, 1, reason: '尽力清理半成品 multipart');
    });
  });
}

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
