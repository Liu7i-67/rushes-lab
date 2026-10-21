/// B9 全 API 层 5xx 统一兜底单测(遗留清偿,B5 技术债收口):validateStatus
/// 全放行后,任一域 API 命中 5xx 都回 Response 走 `_api.err` → ApiException
/// 中文文案(detail 有则透传,无则落域 fallback),不再有 DioException 裸渲染;
/// 非 JSON 错误体(反代 HTML)同样落中文 fallback。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';

void main() {
  late HttpServer server;
  late MsApi api;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      await utf8.decoder.bind(req).join();
      if (path == '/api/v1/share/folders/f1') {
        // 后端 500 且带中文 detail(share 域=B9 前未兜底的典型)
        req.response.statusCode = 500;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'detail': '分享服务暂时不可用,请稍后重试'}));
        await req.response.close();
        return;
      }
      if (path == '/api/v1/projects') {
        // 网关 502 错误页(非 JSON 无 detail)→ 中文 fallback
        req.response.statusCode = 502;
        req.response.write('<html>Bad Gateway</html>');
        await req.response.close();
        return;
      }
      if (path == '/api/v1/notifications') {
        // 500 空 detail(JSON 无 detail 键)→ 域 fallback
        req.response.statusCode = 500;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': 'oops'}));
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
    api = MsApi(baseUrl: 'http://127.0.0.1:${server.port}');
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  test('share 域 500:dio 不抛裸 DioException,转 ApiException 透传中文 detail', () async {
    await expectLater(
      api.share.shareFolder('f1', expiresInSeconds: 3600),
      throwsA(isA<ApiException>()
          .having((e) => e.status, 'status', 500)
          .having((e) => e.message, 'message', '分享服务暂时不可用,请稍后重试')),
    );
  });

  test('projects 域 502 非 JSON 错误体 → 域中文 fallback(无 DioException 字样)',
      () async {
    await expectLater(
      api.projects.list(),
      throwsA(isA<ApiException>()
          .having((e) => e.status, 'status', 502)
          .having((e) => e.message, 'message', '项目列表加载失败')),
    );
  });

  test('notifications 域 500 无 detail → 域中文 fallback', () async {
    await expectLater(
      api.notifications.list(),
      throwsA(isA<ApiException>()
          .having((e) => e.status, 'status', 500)
          .having((e) => e.message, 'message', '通知列表加载失败')),
    );
  });
}
