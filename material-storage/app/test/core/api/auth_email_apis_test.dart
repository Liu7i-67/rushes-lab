/// 邮箱账号批次 auth 域新方法契约(方案 §5.8 + 钉子 37 + §5.7.4):
/// - 七个新方法(含 public-config)5xx 全部 noErrorReport:异常照抛给页面、
///   不触发全局报错钩子(对照不带标记的 /auth/me 500 照常上报);
/// - 429 响应头 retry-after 解析进 ApiException.retryAfterSeconds;
/// - public-config / verify / confirm / send-code 响应字段解析。
/// 纯 Dart 测试,本地 HttpServer 走真实 socket(先例 thumbnail_no_report_test)。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';

void main() {
  late HttpServer server;
  late String base;
  late List<ApiException> apiErrors;
  late MsApi api;

  Future<void> respond(
    HttpRequest req, {
    required int status,
    Map<String, Object> headers = const {},
    Object? body,
  }) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    headers.forEach((k, v) => req.response.headers.set(k, v));
    if (body != null) req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> route(HttpRequest req) async {
    final path = req.uri.path;
    switch (path) {
      case '/api/v1/auth/public-config':
        return respond(req, status: 200, body: {
          'email_auth_enabled': true,
          'password_reset_enabled': true,
          'password_min_length': 10,
        });
      case '/api/v1/auth/email/code':
        return respond(req, status: 200, body: {
          'status': 'sent',
          'masked_email': 'n***@example.com',
          'expires_in': 600,
        });
      case '/api/v1/auth/email/confirm':
        return respond(req, status: 200, body: {
          'status': 'ok',
          'email': 'new@example.com',
          'email_verified': true,
          'action': 'change',
        });
      case '/api/v1/auth/email/unbind':
        return respond(req, status: 200, body: {'status': 'ok'});
      case '/api/v1/auth/password-reset/request':
        // 演练双分支:cooldown 邮箱 → 429 + Retry-After(§5.7.4 机器可读
        // 剩余时间);其余 → 502(SMTP 确定失败,页面内失败卡片场景)
        final body = await readJsonBody(req);
        if (body['email'] == 'cooldown@example.com') {
          return respond(
            req,
            status: 429,
            headers: {'retry-after': '42'},
            body: {'detail': '发送过于频繁,请 42 秒后再试'},
          );
        }
        return respond(
          req,
          status: 502,
          body: {'detail': '邮件发送失败,请稍后重试'},
        );
      case '/api/v1/auth/password-reset/verify':
        return respond(req, status: 200, body: {
          'valid': true,
          'email_masked': 'a***@example.com',
          'expires_at': '2026-11-05T12:00:00Z',
        });
      case '/api/v1/auth/password-reset/confirm':
        return respond(req, status: 200, body: {'status': 'ok'});
      case '/api/v1/auth/me':
        // 对照:不带 noErrorReport 的既有端点,500 应上报
        return respond(req, status: 500, body: {'detail': '服务异常'});
      default:
        return respond(req, status: 404, body: {'detail': 'no route'});
    }
  }

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      try {
        await route(req);
      } catch (_) {
        // 客户端提前断开时写响应会抛,吞掉
      }
    });
  });

  tearDownAll(() => server.close(force: true));

  setUp(() {
    apiErrors = <ApiException>[];
    api = MsApi(baseUrl: base, onApiError: apiErrors.add);
  });

  test('public-config:三字段解析(§5.2 契约)', () async {
    final cfg = await api.auth.publicConfig();
    expect(cfg.emailAuthEnabled, isTrue);
    expect(cfg.passwordResetEnabled, isTrue);
    expect(cfg.passwordMinLength, 10);
  });

  test('sendEmailCode/confirmEmailCode:脱敏邮箱与 action 解析', () async {
    final sent = await api.auth.sendEmailCode(
      email: 'new@example.com',
      password: 'pw',
    );
    expect(sent.maskedEmail, 'n***@example.com');
    expect(sent.expiresIn, 600);

    final done = await api.auth.confirmEmailCode(code: '123456');
    expect(done.email, 'new@example.com');
    expect(done.action, 'change');
  });

  test('requestPasswordReset 502:异常照抛 + noErrorReport 不进全局报错页', () async {
    await expectLater(
      api.auth.requestPasswordReset(email: 'a@example.com'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.status, 'status', 502)
            .having((e) => e.message, 'message', '邮件发送失败,请稍后重试'),
      ),
      reason: '502(SMTP 失败)必须回到页面失败卡片',
    );
    expect(apiErrors, isEmpty, reason: '钉子 37:noErrorReport,5xx 不整页跳报错');
  });

  test('429 Retry-After 头解析进 retryAfterSeconds(§5.7.4)', () async {
    await expectLater(
      api.auth.requestPasswordReset(email: 'cooldown@example.com'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.status, 'status', 429)
            .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', 42),
      ),
    );
    expect(apiErrors, isEmpty, reason: '429 属页面内冷却提示,不上报');
  });

  test('verifyResetToken/resetPassword/unbindEmail:契约解析 + 静默 5xx', () async {
    final v = await api.auth.verifyResetToken(token: 'tok');
    expect(v.valid, isTrue);
    expect(v.emailMasked, 'a***@example.com');

    await api.auth.resetPassword(token: 'tok', newPassword: 'n3wpass1');
    await api.auth.unbindEmail(password: 'pw');
    expect(apiErrors, isEmpty);
  });

  test('对照:不带标记的 /auth/me 500 照常上报(证明标记是生效条件)', () async {
    await expectLater(api.auth.me(), throwsA(isA<ApiException>()));
    expect(apiErrors, hasLength(1));
  });
}

/// 读取 JSON 请求体(空体回落空 Map)。
Future<Map<String, dynamic>> readJsonBody(HttpRequest req) async {
  final body = await utf8.decoder.bind(req).join();
  if (body.isEmpty) return <String, dynamic>{};
  return jsonDecode(body) as Map<String, dynamic>;
}
