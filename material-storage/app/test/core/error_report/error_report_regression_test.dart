/// 全局报错钩子回归用例(专职测试 P1-1/P1-2):
/// · cancel 型 DioException 经真实拦截器链路不上报(搜索防抖/传输取消);
/// · 轮询静默标记(noErrorReport extra)对 5xx/传输异常均不触发全局钩子,
///   失败留给下一拍自愈(banner 8s / 未读数 30s)。
/// 纯 Dart 测试(本文件不含 testWidgets),本地 HttpServer 走真实 socket;
/// 帧后窗口竞态(P2-1)需 Widget 环境,见 error_report_race_test.dart。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/maintenance/banner_controller.dart';

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
        if (path == '/slow') {
          // 留出取消窗口;客户端断开后写响应会抛,统一吞掉
          await Future<void>.delayed(const Duration(milliseconds: 300));
          req.response.statusCode = 200;
        } else if (path == '/api/v1/notifications') {
          req.response.statusCode = 500;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'detail': '通知服务异常'}));
        } else if (path == '/api/v1/maintenance/banner') {
          req.response.statusCode = 500;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'detail': '横幅服务异常'}));
        } else {
          req.response.statusCode = 200;
        }
        await req.response.close();
      } catch (_) {
        // 取消后连接已断,忽略写响应失败
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

  test('P1-1:cancel 经真实拦截器不上报(onError 双重排除)', () async {
    final token = CancelToken();
    final future = api.http.get('/slow', cancelToken: token);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    token.cancel('换词');
    await expectLater(
      future,
      throwsA(isA<DioException>()
          .having((e) => e.type, 'type', DioExceptionType.cancel)),
    );
    expect(netErrors, isEmpty, reason: '取消是正常业务动作,不是网络异常');
    expect(apiErrors, isEmpty);
  });

  test('P1-2:banner 轮询 5xx 与网络异常均不上报', () async {
    final banner = MaintenanceBannerController(api: api);
    await banner.performTick();
    expect(apiErrors, isEmpty, reason: 'banner 5xx 静默,等下一拍');

    final deadApi = MsApi(
      baseUrl: await _deadBase(),
      onApiError: apiErrors.add,
      onNetworkError: netErrors.add,
    );
    await MaintenanceBannerController(api: deadApi).performTick();
    expect(netErrors, isEmpty, reason: 'banner 网络异常静默自愈');

    // 对照:同路径请求不带标记时仍会触发钩子(证明标记是生效条件)
    await expectLater(
      deadApi.http.get('/api/v1/maintenance/banner'),
      throwsA(isA<DioException>()),
    );
    expect(netErrors, hasLength(1));
  });

  test('P1-2:未读数轮询 5xx/网络异常均不上报;非 silent 仍上报', () async {
    await expectLater(
      api.notifications.list(limit: 1, silent: true),
      throwsA(isA<ApiException>()),
    );
    expect(apiErrors, isEmpty, reason: 'silent 请求 5xx 不进全局报错页');

    final deadApi = MsApi(
      baseUrl: await _deadBase(),
      onApiError: apiErrors.add,
      onNetworkError: netErrors.add,
    );
    await expectLater(
      deadApi.notifications.list(limit: 1, silent: true),
      throwsA(isA<DioException>()),
    );
    expect(netErrors, isEmpty, reason: 'silent 请求网络异常不进全局报错页');

    // 对照:其余调用点不带标记,5xx 照常上报(行为不变)
    await expectLater(
      api.notifications.list(limit: 1),
      throwsA(isA<ApiException>()),
    );
    expect(apiErrors, hasLength(1), reason: '普通请求 5xx 仍交全局报错页');
  });
}

/// 取一个已释放的本地端口(连接必被拒)制造传输层网络异常。
Future<String> _deadBase() async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close(force: true);
  return 'http://127.0.0.1:$port';
}
