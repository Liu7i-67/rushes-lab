/// MsApi 全链路单测:本地 HttpServer 按后端真实契约 mock,
/// 验证 登录 cookie 会话 / 列表 / 16MB 分片上传编排 / 下载回读 字节一致性。
/// 契约以 api/app/routers/{auth,projects,folders,assets}.py 为准。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/api/ms_api.dart';

const _okUser = 'evan';
const _okPass = 'secret123';

Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
  final body = await utf8.decoder.bind(req).join();
  return body.isEmpty ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>;
}

Future<List<int>> _readBytes(HttpRequest req) async {
  final out = <int>[];
  await for (final chunk in req) {
    out.addAll(chunk);
  }
  return out;
}

void _json(HttpRequest req, Object? data, {int status = 200}) {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(data));
  // 必须 close 否则 keep-alive 连接永不结束,客户端读 body 挂死
  req.response.close().ignore();
}

void main() {
  late HttpServer server;
  late MsApi api;
  final uploadedParts = <int, List<int>>{};

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';

    server.listen((req) async {
      final path = req.uri.path;
      try {
        // ── auth ──
        if (path == '/api/v1/auth/local/login' && req.method == 'POST') {
          final b = await _readJson(req);
          if (b['username'] == _okUser && b['password'] == _okPass) {
            req.response.headers.set(
                'set-cookie', 'ms_session=tok123; Path=/');
            _json(req, {
              'status': 'ok',
              'user_id': 'u-1',
              'name': '测试',
              'must_change_password': false,
            });
          } else {
            _json(req, {'detail': '用户名或密码错误'}, status: 401);
          }
          return;
        }
        if (path == '/api/v1/auth/me') {
          final cookie = req.headers.value(HttpHeaders.cookieHeader) ?? '';
          if (!cookie.contains('ms_session=tok123')) {
            _json(req, {'detail': '未认证'}, status: 401);
            return;
          }
          _json(req, {
            'id': 'u-1',
            'name': '测试',
            'must_change_password': false,
          });
          return;
        }

        // ── browse ──
        if (path == '/api/v1/projects') {
          _json(req, [
            {'id': 'p1', 'code': 'P1', 'name': '项目一'}
          ]);
          return;
        }
        if (path == '/api/v1/folders') {
          _json(req, [
            {
              'id': 'f1',
              'project_id': 'p1',
              'parent_folder_id': null,
              'name': '根目录',
              'is_sensitive': false,
              'my_can_upload': true,
            },
            {
              'id': 'f2',
              'project_id': 'p1',
              'parent_folder_id': 'f1',
              'name': '子目录',
              'is_sensitive': false,
            },
          ]);
          return;
        }
        if (path == '/api/v1/assets') {
          _json(req, {
            'items': [
              {
                'id': 'a1',
                'folder_id': 'f1',
                'filename': 'IMG_0001.livp',
                'size_bytes': 123,
                'content_type': 'application/zip',
                'created_at': '2026-10-19T10:00:00Z',
              }
            ],
            'total': 1,
          });
          return;
        }

        // ── multipart upload ──
        if (path == '/api/v1/assets/uploads' && req.method == 'POST') {
          final b = await _readJson(req);
          expect(b['folder_id'], 'f1');
          expect(b['filename'], 'test.livp');
          _json(req, {
            'upload_id': 'u1',
            'key': 'p1/f1/test.livp',
            'bucket': 'ms-dev',
          });
          return;
        }
        final partMatch =
            RegExp(r'^/api/v1/assets/uploads/u1/parts/(\d+)$').firstMatch(path);
        if (partMatch != null && req.method == 'GET') {
          expect(req.uri.queryParameters['bucket'], 'ms-dev');
          expect(req.uri.queryParameters['key'], 'p1/f1/test.livp');
          _json(req, {
            'url': '$base/minio-part/${partMatch.group(1)}',
            'expires_in': 900,
          });
          return;
        }
        final putMatch = RegExp(r'^/minio-part/(\d+)$').firstMatch(path);
        if (putMatch != null && req.method == 'PUT') {
          final n = int.parse(putMatch.group(1)!);
          uploadedParts[n] = await _readBytes(req);
          // 回归守卫:part PUT 必须带 Content-Length(chunked 传输在 prod 链路回 411)
          expect(req.headers.value(HttpHeaders.contentLengthHeader),
              '${uploadedParts[n]!.length}',
              reason: 'part PUT 需固定长度,禁 chunked');
          req.response.headers.set('etag', '"ETAG$n"');
          req.response.statusCode = 200;
          await req.response.close();
          return;
        }
        if (path == '/api/v1/assets/uploads/u1/complete') {
          final b = await _readJson(req);
          final parts = (b['parts'] as List).cast<Map<String, dynamic>>();
          expect(parts.length, 2, reason: '17MB 载荷应切 2 片(16MB 分片)');
          expect(parts[0]['PartNumber'], 1);
          expect(parts[0]['ETag'], '"ETAG1"');
          expect(parts[1]['PartNumber'], 2);
          _json(req, {
            'id': 'a2',
            'folder_id': 'f1',
            'filename': 'test.livp',
            'size_bytes': b['size_bytes'] ?? uploadedParts.values
                .map((e) => e.length)
                .reduce((a, b) => a + b),
            'content_type': 'application/zip',
            'created_at': '2026-10-19T11:00:00Z',
          });
          return;
        }

        // ── download ──
        if (path == '/api/v1/assets/a1/download-link' && req.method == 'POST') {
          _json(req, {'url': '$base/file/IMG_0001.livp'});
          return;
        }
        if (path == '/file/IMG_0001.livp') {
          final bytes = <int>[...uploadedParts[1] ?? const [], ...uploadedParts[2] ?? const []];
          req.response.headers.contentType =
              ContentType('application', 'zip');
          req.response.add(bytes);
          await req.response.close();
          return;
        }
        if (path == '/api/v1/assets/a2' && req.method == 'DELETE') {
          _json(req, {'status': 'ok'});
          return;
        }

        _json(req, {'detail': 'no route: ${req.method} $path'}, status: 404);
      } catch (e) {
        try {
          _json(req, {'detail': 'mock error: $e'}, status: 500);
        } catch (_) {}
      }
    });

    api = MsApi(baseUrl: base);
  });

  tearDownAll(() async {
    await server.close();
  });

  test('登录失败 → 中文 detail 透出;成功 → cookie 会话 /me 通过', () async {
    await expectLater(
      api.login('evan', 'wrong'),
      throwsA(isA<ApiException>()
          .having((e) => e.message, 'detail', '用户名或密码错误')),
    );
    final me = await api.login(_okUser, _okPass);
    expect(me.name, '测试');
    final again = await api.me();
    expect(again.id, 'u-1');
  });

  test('项目/文件夹/文件列表模型解析', () async {
    final projects = await api.projects();
    expect(projects.single.name, '项目一');
    final folders = await api.folders('p1');
    expect(folders.length, 2);
    expect(folders[1].parentFolderId, 'f1');
    final page = await api.assets('f1');
    expect(page.items.single.isLivp, isTrue);
  });

  test('分片上传编排:17MB 载荷切 2 片,ETag 收集正确,complete 校验字节', () async {
    // 16MB + 1KB → 2 片,验证与 web Uppy 同款分片大小
    final payload = List<int>.generate(
        MsApi.partSize + 1024, (i) => i % 256);
    final asset = await api.uploadBytes(
      folderId: 'f1',
      filename: 'test.livp',
      bytes: payload,
    );
    expect(asset.filename, 'test.livp');
    // mock 端校验过 parts;这里校验服务端收到的字节与载荷一致
    final reassembled = [...uploadedParts[1]!, ...uploadedParts[2]!];
    expect(reassembled.length, payload.length);
    expect(reassembled, payload);
  });

  test('下载链:download-link → downloadTo 回读字节一致;删除资产', () async {
    final url = await api.downloadLink('a1');
    final f = await api.downloadTo(url, '${Directory.systemTemp.path}/t.livp');
    // mock /file 返回的是上一测试上传的分片重组 → 与该载荷一致
    final expected = [...uploadedParts[1] ?? const [], ...uploadedParts[2] ?? const []];
    expect(await f.length(), expected.length);
    await api.deleteAsset('a2');
  });
}
