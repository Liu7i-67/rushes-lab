/// 401 会话失效钩子接线单测(§4.1):业务接口 401 触发 onSessionExpired;
/// 登录接口本身 401(密码错误)不算会话失效;不触发自动重试(429/超时同理不钩)。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart' show SingleFlightGate;
import 'package:ms_app/models/models.dart';

void main() {
  late HttpServer server;
  late String base;
  var fired = 0;

  setUp(() async {
    fired = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      Future<void> deny() async {
        req.response.statusCode = 401;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'detail': '未认证'}));
        await req.response.close();
      }

      switch (req.uri.path) {
        case '/api/v1/auth/me':
        case '/api/v1/projects':
          await deny();
          return;
        case '/api/v1/auth/local/login':
          // 登录失败也是 401(密码错误),语义≠会话失效
          await deny();
          return;
        default:
          req.response.statusCode = 404;
          await req.response.close();
          return;
      }
    });
  });

  tearDown(() async => server.close());

  test('业务接口 401 → 触发 onSessionExpired(1 次/请求)', () async {
    final api = MsApi(baseUrl: base, onSessionExpired: () => fired++);
    await expectLater(
      api.auth.me(),
      throwsA(isA<ApiException>()),
    );
    expect(fired, 1);
  });

  test('登录接口 401(密码错误)不触发会话失效钩子', () async {
    final api = MsApi(baseUrl: base, onSessionExpired: () => fired++);
    await expectLater(
      api.auth.login('a', 'b'),
      throwsA(isA<ApiException>()
          .having((e) => e.message, 'detail', '未认证')),
    );
    expect(fired, 0);
  });

  test('并发两个业务 401 → Session 闸门去抖只跳一次', () async {
    final s = SessionLike();
    final api = MsApi(baseUrl: base, onSessionExpired: s.expire);
    final f1 = api.projects.list().catchError((Object _) => <Project>[]);
    final f2 = api.projects.list().catchError((Object _) => <Project>[]);
    await Future.wait([f1, f2]);
    expect(s.jumps, 1, reason: '并发多请求只触发一次跳登录(去抖)');
  });
}

/// Session 401 去抖行为的最小复刻(闸门 + 计数;真 Session 见 probe 测试)。
class SessionLike {
  final _gate = SingleFlightGate(const Duration(seconds: 1));
  int jumps = 0;

  void expire() {
    if (_gate.acquire()) jumps++;
  }
}
