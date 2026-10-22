/// 测试功能点 T5 支路(F2-2):UpdateService 对本地 HttpServer 的失败语义 —
/// 404 → UpdateException(可读文案)、坏 JSON / 顶层非 Map → UpdateException、
/// 响应超时 → UpdateException(自动检查侧静默的前提)、成功 → 解析模型、
/// `?t=` cache-bust 必带。另附 describeDioError 文案映射纯函数直测。
/// 手法对齐 test/ms_api_test.dart 的本地 HttpServer mock。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/update/update_errors.dart';
import 'package:ms_app/core/update/update_service.dart';

void main() {
  late HttpServer server;
  late String base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
  });

  void reply(HttpRequest req, int status, String body) {
    try {
      req.response.statusCode = status;
      req.response.write(body);
      req.response.close().ignore();
    } catch (_) {
      // 客户端已断开(如超时取消)时写失败,不影响断言
    }
  }

  /// 注入独立 Dio(超时可缩到毫秒级,真实 10s 配置不进单测);
  /// responseType=plain 对齐真实装配(CDN 可能回非 json content-type)。
  UpdateService serviceWith({Duration? timeout}) => UpdateService(
        dio: Dio(BaseOptions(
          connectTimeout: timeout ?? const Duration(seconds: 2),
          receiveTimeout: timeout ?? const Duration(seconds: 2),
          responseType: ResponseType.plain,
        )),
        versionJsonUrl: '$base/app_version.json',
      );

  test('200 + 合法 JSON → 解析出 AppVersionInfo;请求带 ?t= cache-bust', () async {
    Uri? seen;
    server.listen((req) {
      seen = req.uri;
      reply(
          req,
          200,
          jsonEncode({
            'version': '1.2.3',
            'build': 7,
            'changelog': 'x',
            'force': false,
            'android': {'url': 'https://cdn/huanhuashijie-1.2.3.apk'},
          }));
    });
    final info = await serviceWith().fetchLatest();
    expect(info.version, '1.2.3');
    expect(info.build, 7);
    expect(info.androidUrl, 'https://cdn/huanhuashijie-1.2.3.apk');
    expect(seen, isNotNull);
    expect(seen!.queryParameters['t'], isNotEmpty,
        reason: 'cache-bust 毫秒时间戳必带(F2-2 穿透 CDN)');
  });

  test('404(首次发布前)→ UpdateException 可读文案,非 FormatException', () async {
    server.listen((req) => reply(req, 404, 'no such key'));
    await expectLater(
      serviceWith().fetchLatest(),
      throwsA(isA<UpdateException>()
          .having((e) => e.message, 'message', contains('404'))),
    );
  });

  test('200 + 坏 JSON → UpdateException「版本信息格式错误」', () async {
    server.listen((req) => reply(req, 200, '{not json'));
    await expectLater(
      serviceWith().fetchLatest(),
      throwsA(isA<UpdateException>()
          .having((e) => e.message, 'message', '版本信息格式错误')),
    );
  });

  test('200 + 合法 JSON 但顶层非 Map(数组)→ UpdateException', () async {
    server.listen((req) => reply(req, 200, '[1,2,3]'));
    await expectLater(
      serviceWith().fetchLatest(),
      throwsA(isA<UpdateException>()
          .having((e) => e.message, 'message', '版本信息格式错误')),
    );
  });

  test('合法 JSON 但字段无效(version 缺失)→ FormatException(无有效更新信息)',
      () async {
    server.listen((req) => reply(req, 200, jsonEncode({'build': 1})));
    await expectLater(
      serviceWith().fetchLatest(),
      throwsA(isA<FormatException>()),
    );
  });

  test('响应超时 → UpdateException「连接超时,请稍后重试」', () async {
    server.listen((req) async {
      try {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        reply(req, 200, '{}');
      } catch (_) {}
    });
    final svc = serviceWith(timeout: const Duration(milliseconds: 100));
    await expectLater(
      svc.fetchLatest(),
      throwsA(isA<UpdateException>()
          .having((e) => e.message, 'message', '连接超时,请稍后重试')),
    );
  });

  group('describeDioError 文案映射(F2-6 手动检查 SnackBar 用)', () {
    DioException err(DioExceptionType type, {Response<dynamic>? response}) =>
        DioException(
          requestOptions: RequestOptions(path: '/'),
          type: type,
          response: response,
        );

    test('连接/发送/接收超时 → 连接超时文案', () {
      for (final t in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ]) {
        expect(describeDioError(err(t)), '连接超时,请稍后重试');
      }
    });

    test('badResponse → 服务异常(HTTP <code>)', () {
      final e = err(DioExceptionType.badResponse,
          response: Response<dynamic>(
            requestOptions: RequestOptions(path: '/'),
            statusCode: 500,
          ));
      expect(describeDioError(e), '服务异常(HTTP 500)');
    });

    test('connectionError → 网络不可达文案', () {
      expect(describeDioError(err(DioExceptionType.connectionError)),
          '网络不可达,请检查网络后重试');
    });
  });
}
