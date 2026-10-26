/// 缩略图签名请求 noErrorReport 钩子回归(storm-fix 测试功能点 T11②,D2):
/// 单发 thumbnailUrl / 批量 thumbnailUrls / livp livePreviewUrl 的 5xx 与传输层
/// 异常均不触发全局报错钩子(失败仅落格内降级);对照不带标记的请求仍会上报,
/// 证明标记是生效条件。先例 error_report_regression_test.dart:78-97。
/// 纯 Dart 测试,本地 HttpServer 走真实 socket。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';

void main() {
  late HttpServer server;
  late String base;
  late List<ApiException> apiErrors;
  late List<DioException> netErrors;
  late MsApi api;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      try {
        final path = req.uri.path;
        if (path == '/api/v1/assets') {
          // 对照用:不带标记的普通资产接口,5xx 应进全局报错页
          req.response.statusCode = 500;
          req.response.headers.contentType = ContentType.json;
          req.response.write('{"detail":"资产服务异常"}');
        } else if (path.endsWith('/thumbnail-url') ||
            path == '/api/v1/assets/thumbnail-urls' ||
            path.endsWith('/live-preview-url')) {
          req.response.statusCode = 500;
          req.response.headers.contentType = ContentType.json;
          req.response.write('{"detail":"缩略图服务异常"}');
        } else {
          req.response.statusCode = 200;
        }
        await req.response.close();
      } catch (_) {
        // 客户端提前断开时写响应会抛,吞掉
      }
    });
  });

  tearDownAll(() => server.close(force: true));

  setUp(() {
    apiErrors = <ApiException>[];
    netErrors = <DioException>[];
    api = MsApi(
      baseUrl: base,
      onApiError: apiErrors.add,
      onNetworkError: netErrors.add,
    );
  });

  test('T11②:thumbnailUrl 5xx 静默;对照不带标记的 5xx 照常上报', () async {
    await expectLater(
      api.assets.thumbnailUrl('a1'),
      throwsA(isA<ApiException>()),
      reason: '异常仍上抛给调用方(格内降级色块)',
    );
    expect(apiErrors, isEmpty, reason: 'noErrorReport:5xx 不进全局报错页');

    // 对照:不带标记的普通资产接口同机 5xx → onApiError 被调(证明标记是生效条件)
    await expectLater(api.assets.list('f1'), throwsA(isA<ApiException>()));
    expect(apiErrors, hasLength(1));
  });

  test('T11②:thumbnailUrls 批量 5xx 静默;对照不带标记照常上报', () async {
    await expectLater(
      api.assets.thumbnailUrls(['a1', 'a2']),
      throwsA(isA<ApiException>()),
    );
    expect(apiErrors, isEmpty, reason: '批量预热失败静默,等单发兜底');

    await expectLater(api.assets.list('f1'), throwsA(isA<ApiException>()));
    expect(apiErrors, hasLength(1));
  });

  test('T11②:livePreviewUrl 5xx 静默(断网横切 livp 不弹整页报错)', () async {
    await expectLater(
      api.assets.livePreviewUrl('lv1'),
      throwsA(isA<ApiException>()),
    );
    expect(apiErrors, isEmpty);

    await expectLater(api.assets.list('f1'), throwsA(isA<ApiException>()));
    expect(apiErrors, hasLength(1));
  });

  test('T11②:传输层异常(连接拒绝)三端点均不上报;对照不带标记上报', () async {
    final deadBase = await _deadBase();
    final deadApi = MsApi(
      baseUrl: deadBase,
      onApiError: apiErrors.add,
      onNetworkError: netErrors.add,
    );
    await expectLater(
      deadApi.assets.thumbnailUrl('a1'),
      throwsA(isA<DioException>()),
    );
    await expectLater(
      deadApi.assets.thumbnailUrls(['a1']),
      throwsA(isA<DioException>()),
    );
    await expectLater(
      deadApi.assets.livePreviewUrl('lv1'),
      throwsA(isA<DioException>()),
    );
    expect(netErrors, isEmpty, reason: 'noErrorReport:传输异常静默自愈');

    // 对照:不带标记 → onNetworkError 被调
    final plain = MsApi(
      baseUrl: await _deadBase(),
      onApiError: apiErrors.add,
      onNetworkError: netErrors.add,
    );
    await expectLater(
      plain.http.get('/api/v1/assets/a1/thumbnail-url'),
      throwsA(isA<DioException>()),
    );
    expect(netErrors, hasLength(1));
    expect(apiErrors, isEmpty);
  });
}

/// 取一个已释放的本地端口(连接必被拒)制造传输层网络异常。
Future<String> _deadBase() async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close(force: true);
  return 'http://127.0.0.1:$port';
}
