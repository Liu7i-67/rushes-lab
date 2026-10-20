/// BaiduApi 契约单测(契约=api/app/routers/baidu_backup.py 实际代码):
/// authorize-url(POST→{url})/ binding(POST {code})/ binding 状态(GET)
/// 三端点的方法/路径/字段/错误口径(404=未启用,400=授权码无效或过期,
/// 5xx=后端中文 detail 透传,勿裸渲染原始异常对象)。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/baidu_api.dart';
import 'package:ms_app/core/api/ms_api.dart';

String? lastAuthorizeMethod;
String? lastAuthorizeQuery;
String? lastBindCode;
Set<String>? lastBindBodyKeys;

/// 5xx 注入(对齐 baidu_backup.py:authorize-url 503=凭证未配置,
/// bind 502=uinfo 失败);非 null 时对应端点直接回该状态码+中文 detail。
int? forceAuthorizeStatus;
int? forceBindStatus;

Future<HttpServer> _startServer({required bool enabled}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    Future<void> json(Object? data, {int status = 200}) async {
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(data));
      await req.response.close();
    }

    final path = req.uri.path;
    if (!enabled) {
      // 开关关闭部署:_ensure_enabled() 统一 404 feature not found
      await json(const {'detail': 'feature not found'}, status: 404);
      return;
    }
    if (path == '/api/v1/baidu/backup/binding/authorize-url' &&
        req.method == 'POST') {
      await utf8.decoder.bind(req).join();
      lastAuthorizeMethod = req.method;
      lastAuthorizeQuery = req.uri.query;
      if (forceAuthorizeStatus != null) {
        await json(
            const {
              'detail': '百度应用凭证未配置(BAIDU_APP_KEY/BAIDU_APP_SECRET),无法绑定',
            },
            status: forceAuthorizeStatus!);
        return;
      }
      await json({
        'url': 'https://openapi.baidu.com/oauth/2.0/authorize'
            '?client_id=abc&redirect_uri=oob&scope=basic,netdisk',
      });
      return;
    }
    if (path == '/api/v1/baidu/backup/binding' && req.method == 'POST') {
      final body =
          jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      final code = body['code'] as String? ?? '';
      lastBindCode = code;
      lastBindBodyKeys = body.keys.toSet();
      if (forceBindStatus != null) {
        await json(const {
          'detail': '获取百度账号信息失败,请稍后重试;本次绑定未生效',
        }, status: forceBindStatus!);
        return;
      }
      if (code == 'GOODCODE') {
        // 契约:BaiduBindOut{bound,status,expires_at,baidu_uid,nickname}
        await json({
          'bound': true,
          'status': 'active',
          'expires_at': '2026-10-20T12:00:00Z',
          'baidu_uid': 'uid-9',
          'nickname': '测试盘',
        });
      } else if (code == 'NULLNICK') {
        await json({
          'bound': true,
          'status': 'active',
          'expires_at': '2026-10-20T12:00:00Z',
          'baidu_uid': 'uid-7',
        });
      } else {
        // 契约:400 detail(授权码无效或已过期)
        await json(const {
          'detail': '授权码无效或已过期,请重新获取授权码后再试(授权码 10 分钟内单次有效)',
        }, status: 400);
      }
      return;
    }
    if (path == '/api/v1/baidu/backup/binding' && req.method == 'GET') {
      // 契约:BaiduBindingOut(bound/status 必有,其余可缺)
      await json({'bound': false, 'status': 'unbound'});
      return;
    }
    await json({'detail': 'no route: ${req.method} $path'}, status: 404);
  });
  return server;
}

void main() {
  late HttpServer server;
  late BaiduApi api;
  late BaiduApi disabledApi;

  setUpAll(() async {
    server = await _startServer(enabled: true);
    disabledApi = BaiduApi(MsApi(
        baseUrl: 'http://127.0.0.1:${(await _startServer(enabled: false)).port}'));
    api = BaiduApi(MsApi(baseUrl: 'http://127.0.0.1:${server.port}'));
  });

  tearDownAll(() async {
    await server.close();
  });

  test('authorize-url:POST 无 query,返回 url 字段', () async {
    final url = await api.authorizeUrl();
    expect(lastAuthorizeMethod, 'POST');
    expect(lastAuthorizeQuery, ''); // 链接内容在响应体;请求侧无敏感 query
    expect(url, contains('openapi.baidu.com'));
    expect(url, contains('redirect_uri=oob'));
  });

  test('binding:请求体恰为 {code};成功响应解析含昵称', () async {
    final b = await api.bind('GOODCODE');
    expect(lastBindCode, 'GOODCODE');
    expect(lastBindBodyKeys, {'code'}); // 请求体字段口径=BaiduBindIn
    expect(b.bound, isTrue);
    expect(b.status, 'active');
    expect(b.baiduUid, 'uid-9');
    expect(b.nickname, '测试盘');
    expect(b.displayName, '测试盘');
  });

  test('binding:nickname 缺失回退 uid 展示(§4 口径)', () async {
    final b = await api.bind('NULLNICK');
    expect(b.nickname, isNull);
    expect(b.displayName, 'uid-7');
  });

  test('binding:400 → detail 透出(过期文案)', () async {
    await expectLater(
      api.bind('EXPIRED'),
      throwsA(isA<ApiException>()
          .having((e) => e.status, 'status', 400)
          .having((e) => e.message, 'message', contains('授权码无效或已过期'))),
    );
  });

  test('开关关闭:三端点 404 → 未启用口径(authorize-url)', () async {
    await expectLater(
      disabledApi.authorizeUrl(),
      throwsA(isA<ApiException>()
          .having((e) => e.status, 'status', 404)
          .having((e) => e.message, 'message', '网盘备份未启用')),
    );
  });

  test('开关关闭:bind 404 → 未启用口径', () async {
    await expectLater(
      disabledApi.bind('GOODCODE'),
      throwsA(isA<ApiException>()
          .having((e) => e.status, 'status', 404)
          .having((e) => e.message, 'message', '网盘备份未启用')),
    );
  });

  test('开关关闭:binding 状态 404 → null(调用方按未启用处理)', () async {
    await expectLater(disabledApi.bindingStatus(), completion(isNull));
  });

  test('binding 状态:200 解析 bound=false/unbound', () async {
    final s = await api.bindingStatus();
    expect(s, isNotNull);
    expect(s!.bound, isFalse);
    expect(s.status, 'unbound');
  });

  test('authorize-url 503:dio badResponse 转 ApiException,后端中文 detail 透出', () async {
    // validateStatus 只放行 <500:5xx 原先抛 DioException 裸渲染,
    // guard5xx 后必须以 ApiException+中文 detail 上抛(P1-1 锁定)
    forceAuthorizeStatus = 503;
    addTearDown(() => forceAuthorizeStatus = null);
    await expectLater(
      api.authorizeUrl(),
      throwsA(isA<ApiException>()
          .having((e) => e.status, 'status', 503)
          .having((e) => e.message, 'message',
              contains('百度应用凭证未配置(BAIDU_APP_KEY/BAIDU_APP_SECRET)'))),
    );
  });

  test('bind 502:后端中文 detail 透出(获取百度账号信息失败)', () async {
    forceBindStatus = 502;
    addTearDown(() => forceBindStatus = null);
    await expectLater(
      api.bind('GOODCODE'),
      throwsA(isA<ApiException>()
          .having((e) => e.status, 'status', 502)
          .having((e) => e.message, 'message', contains('获取百度账号信息失败'))
          .having((e) => e.message, 'message', contains('本次绑定未生效'))),
    );
  });
}
