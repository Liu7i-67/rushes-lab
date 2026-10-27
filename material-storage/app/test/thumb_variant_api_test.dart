/// 签名端点 wire 契约单测(thumb-variant 批 T3,测试功能点 12 §6.12;
/// 契约 §3.2 端点段 + §3.7 签名函数段):
/// ① 单发签名 small → GET /api/v1/assets/{id}/thumbnail-url?size=small;
/// ② 单发 large → 不带 size query(后端默认 large,与旧后端行为一致);
/// ③ 批量签名 small → POST body 含 "size":"small";large/缺省 body 不含该
///    字段(旧后端对未知字段忽略,双向兼容);
/// ④ 响应含未知字段 variant(单发顶层 / 批量 urls[] 项)解析不炸——手工 JSON
///    解析只取 url/expires_in,不新增必填解析;
/// ⑤ 端到端:经 thumbnailCache 生产 signer 链 small 映射 ?size=small;批量
///    预热 prewarmThumbUrls small 批量 body 带 size 且落 small 缓存键。
///
/// 网络策略:本地 HttpServer 按后端真实契约 mock(ms_api_test 同手法,plain
/// test 真实 loopback socket);禁用 testWidgets——FakeAsync 区真实 socket
/// 永不推进、HTTP 恒 400(assets_page_refresh_test 头注),本文件全程不用。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/thumb_variant.dart';
import 'package:ms_app/core/thumbnail_cache.dart';
import 'package:ms_app/features/assets/thumb_prewarm.dart';
import 'package:ms_app/models/models.dart';

/// 已捕获请求:(method, path, query, body) 具名字段。
final _requests =
    <({String method, String path, Map<String, String> query, Map<String, dynamic> body})>[];

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

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      try {
        final raw = await utf8.decoder.bind(req).join();
        final bodyMap = raw.isEmpty
            ? <String, dynamic>{}
            : (jsonDecode(raw) as Map).cast<String, dynamic>();
        _requests.add((
          method: req.method,
          path: req.uri.path,
          query: req.uri.queryParameters,
          body: bodyMap,
        ));

        // 单发签名端点(§3.2):响应恒带新增 variant 字段(容忍语义验证用)
        final segments = req.uri.pathSegments;
        if (req.method == 'GET' &&
            segments.length == 5 &&
            segments[2] == 'assets' &&
            segments.last == 'thumbnail-url') {
          final id = segments[3];
          _json(req, {
            'url': 'https://blob.test/$id.jpg',
            'expires_in': 1800,
            'variant':
                req.uri.queryParameters['size'] == 'small' ? 'small' : 'large',
          });
          return;
        }
        // 批量签名端点(§3.2):urls[] 项恒带 variant 字段
        if (req.method == 'POST' &&
            req.uri.path == '/api/v1/assets/thumbnail-urls') {
          final ids = (bodyMap['asset_ids'] as List? ?? const []).cast<String>();
          _json(req, {
            'urls': [
              for (final id in ids)
                {
                  'asset_id': id,
                  'url': 'https://blob.test/$id.jpg',
                  'expires_in': 1800,
                  'variant': bodyMap['size'] == 'small' ? 'small' : 'large',
                },
            ],
            'missing': const <String>[],
          });
          return;
        }
        _json(req, {'detail': 'no route: ${req.method} ${req.uri.path}'},
            status: 404);
      } catch (e) {
        try {
          _json(req, {'detail': 'mock error: $e'}, status: 500);
        } catch (_) {}
      }
    });
    api = MsApi(baseUrl: 'http://127.0.0.1:${server.port}');
    session.api = api;
  });

  tearDownAll(() async {
    session.api = null;
    await server.close(force: true);
  });

  setUp(() {
    _requests.clear();
    thumbnailCache.clear(); // 生产 signer 链用例与全局缓存隔离
  });

  group('单发签名(thumbnailUrl)', () {
    test('size=small → GET /api/v1/assets/{id}/thumbnail-url?size=small;'
        '响应顶层未知字段 variant 解析不炸', () async {
      final r = await api.assets.thumbnailUrl('a1', size: 'small');

      expect(_requests.single.method, 'GET');
      expect(_requests.single.path, '/api/v1/assets/a1/thumbnail-url');
      expect(_requests.single.query['size'], 'small',
          reason: 'small 必须带 ?size=small(后端优先签 small 对象)');
      expect(r.url, 'https://blob.test/a1.jpg');
      expect(r.expiresIn, 1800,
          reason: '手工 JSON 解析仅取 url/expires_in,variant 字段被容忍');
    });

    test('size=large → 不带 size query(后端默认 large,向后兼容)', () async {
      final r = await api.assets.thumbnailUrl('a2', size: 'large');

      expect(_requests.single.path, '/api/v1/assets/a2/thumbnail-url');
      expect(_requests.single.query.containsKey('size'), isFalse,
          reason: 'large 不带 ?size(与旧后端现行为一致)');
      expect(r.url, 'https://blob.test/a2.jpg');
    });
  });

  group('批量签名(thumbnailUrls)', () {
    test('size=small → POST body 含 "size":"small";urls[] 项含未知 variant '
        '解析不炸', () async {
      final r = await api.assets.thumbnailUrls(['b1', 'b2'], size: 'small');

      expect(_requests.single.method, 'POST');
      expect(_requests.single.path, '/api/v1/assets/thumbnail-urls');
      expect(_requests.single.body['size'], 'small',
          reason: 'small 批量 body 必须带 size 字段');
      expect(_requests.single.body['asset_ids'], ['b1', 'b2'],
          reason: 'asset_ids 语义不变');
      expect(r.byId.keys.toList()..sort(), ['b1', 'b2']);
      expect(r.byId['b1']!.url, 'https://blob.test/b1.jpg');
      expect(r.byId['b1']!.expiresIn, 1800,
          reason: 'urls[] 项的 variant 未知字段按容忍语义忽略');
      expect(r.missing, isEmpty);
    });

    test('large/缺省 body 不含 size 字段(向后兼容,旧后端可忽略)', () async {
      await api.assets.thumbnailUrls(['b3'], size: 'large');
      await api.assets.thumbnailUrls(['b4']); // 缺省

      expect(_requests[0].body.containsKey('size'), isFalse,
          reason: 'large 显式传入也不带 size 字段');
      expect(_requests[0].body['asset_ids'], ['b3']);
      expect(_requests[1].body.containsKey('size'), isFalse,
          reason: '缺省 body 形状与旧客户端完全一致');
      expect(_requests[1].body['asset_ids'], ['b4']);
    });
  });

  group('端到端(生产 signer 链,经全局 thumbnailCache / prewarm)', () {
    test('thumbnailCache.urlOf small → 端点收到 ?size=small;'
        '响应含 variant 解析正常且条目落 small 缓存键', () async {
      final url =
          await thumbnailCache.urlOf('e2e-a', variant: ThumbVariant.small);

      expect(url, 'https://blob.test/e2e-a.jpg');
      expect(_requests.single.query['size'], 'small',
          reason: '生产 signer 将 ThumbVariant.small 映射为 ?size=small');
      // 响应顶层 variant 字段解析不炸;URL 已落缓存可复用
      expect(
        await thumbnailCache.urlOf('e2e-a', variant: ThumbVariant.small),
        url,
        reason: '命中缓存不再发请求',
      );
      expect(_requests.length, 1);
    });

    test('prewarmThumbUrls small → 批量 body 含 size:small;结果只落 small 键',
        () async {
      final items = [
        Asset(
          id: 'pw1',
          filename: 'a.jpg',
          sizeBytes: 1,
          contentType: 'image/jpeg',
          createdAt: '2026-10-27T00:00:00Z',
          folderId: 'f1',
          tags: {'thumbnail_key': 'thumbnails/pw1.jpg'},
        ),
      ];

      await prewarmThumbUrls(items, variant: ThumbVariant.small);

      expect(_requests.single.method, 'POST');
      expect(_requests.single.path, '/api/v1/assets/thumbnail-urls');
      expect(_requests.single.body['size'], 'small',
          reason: '批量预热 small 经 apiSize 透传到批量 body');
      expect(_requests.single.body['asset_ids'], ['pw1']);
      expect(
        thumbnailCache.missingOf(['pw1'], variant: ThumbVariant.small).toList(),
        isEmpty,
        reason: '预热结果写入 small 缓存键',
      );
      expect(
        thumbnailCache.missingOf(['pw1']).toList(),
        ['pw1'],
        reason: 'large 键不受 small 预热影响(变体条目隔离)',
      );
    });
  });
}
