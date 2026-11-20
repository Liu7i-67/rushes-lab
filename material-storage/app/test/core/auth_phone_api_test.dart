/// auth_api 手机号四端点契约单测(phone-bind 批,§7.4;fake dio 照 ApiHarness
/// 本地 HttpServer 先例,plain test 非 testWidgets):
/// - 路径/方法/入参体逐项断言(与 §5.2 契约总表对齐);
/// - 200 出参解析(send-code → retry_after;bind → phone;confirm → 四字段);
/// - 非 200 走 ApiException(statusCode != 200 判错惯例),detail 透传,
///   retry_after 经既有 ApiException.raw['retry_after'] 读(钉子,不另造通道);
/// - confirm 出参 displayAccount 优先级 username → email → name 与 onlyName。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/auth_api.dart';
import 'package:ms_app/core/api/ms_api.dart';

import '../helpers/api_harness.dart';

void main() {
  late ApiHarness h;

  setUp(() async {
    h = ApiHarness((req) async {
      switch (req.uri.path) {
        case '/api/v1/account/phone/send-code':
          json(req, {'retry_after': 120});
          return;
        case '/api/v1/account/phone/bind':
          json(req, {'phone': '13800138000'});
          return;
        case '/api/v1/auth/phone/reset/send-code':
          json(req, {'retry_after': 120});
          return;
        case '/api/v1/auth/phone/reset/confirm':
          json(req, {
            'username': 'jia',
            'email': 'jia@x.com',
            'name': '甲',
            'new_password': 'Rand0m-Pass12',
          });
          return;
      }
      json(req, {'detail': 'no route'}, status: 404);
    }, capture: true);
    await h.start();
    addTearDown(h.stop);
  });

  group('POST 路径与入参(契约对齐)', () {
    test('sendPhoneBindCode → /account/phone/send-code {phone}', () async {
      await h.api!.auth.sendPhoneBindCode('13800138000');
      final c = h.captured.last;
      expect(c.method, 'POST');
      expect(c.path, '/api/v1/account/phone/send-code');
      expect(c.body, {'phone': '13800138000'});
    });

    test('bindPhone → /account/phone/bind {phone, code}', () async {
      await h.api!.auth.bindPhone('13800138000', 'AB12CD');
      final c = h.captured.last;
      expect(c.method, 'POST');
      expect(c.path, '/api/v1/account/phone/bind');
      expect(c.body, {'phone': '13800138000', 'code': 'AB12CD'});
    });

    test('sendPhoneResetCode → /auth/phone/reset/send-code {phone}', () async {
      await h.api!.auth.sendPhoneResetCode('13900139000');
      final c = h.captured.last;
      expect(c.method, 'POST');
      expect(c.path, '/api/v1/auth/phone/reset/send-code');
      expect(c.body, {'phone': '13900139000'});
    });

    test(
      'confirmPhoneReset → /auth/phone/reset/confirm {phone, code}',
      () async {
        await h.api!.auth.confirmPhoneReset('13900139000', 'ZX34QW');
        final c = h.captured.last;
        expect(c.method, 'POST');
        expect(c.path, '/api/v1/auth/phone/reset/confirm');
        expect(c.body, {'phone': '13900139000', 'code': 'ZX34QW'});
      },
    );
  });

  group('200 出参解析', () {
    test('send-code 双端点返回 retry_after', () async {
      expect(await h.api!.auth.sendPhoneBindCode('13800138000'), 120);
      expect(await h.api!.auth.sendPhoneResetCode('13900139000'), 120);
    });

    test('bind 返回归一化后的 phone', () async {
      expect(
        await h.api!.auth.bindPhone('+86 138-0013-8000', 'AB12CD'),
        '13800138000',
      );
    });

    test('confirm 返回四字段', () async {
      final r = await h.api!.auth.confirmPhoneReset('13900139000', 'ZX34QW');
      expect(r.username, 'jia');
      expect(r.email, 'jia@x.com');
      expect(r.name, '甲');
      expect(r.newPassword, 'Rand0m-Pass12');
    });

    test('PhoneResetResult 展示优先级 username → email → name', () {
      PhoneResetResult of(String? username, String? email, String name) =>
          PhoneResetResult(
            username: username,
            email: email,
            name: name,
            newPassword: 'x',
          );
      expect(of('u', 'e@x.com', '甲').displayAccount, 'u');
      expect(of(null, 'e@x.com', '甲').displayAccount, 'e@x.com');
      expect(of(null, null, '甲').displayAccount, '甲');
      expect(of('', '', '甲').displayAccount, '甲', reason: '空串视同缺失');
      expect(of('u', null, '甲').onlyName, isFalse);
      expect(of(null, '', '甲').onlyName, isTrue);
    });
  });

  group('非 200 → ApiException(detail 透传 + raw.retry_after 钉子)', () {
    test('429 冷却:status/message/raw retry_after 全链路', () async {
      final harness = ApiHarness((req) async {
        json(req, {'detail': '发送太频繁,请稍后再试', 'retry_after': 95}, status: 429);
      });
      await harness.start();
      addTearDown(harness.stop);
      final e = await _throwsApiException(
        () => harness.api!.auth.sendPhoneBindCode('13800138000'),
      );
      expect(e.status, 429);
      expect(e.message, '发送太频繁,请稍后再试');
      expect(
        retryAfterOf(e.raw),
        95,
        reason: 'retry_after 经 ApiException.raw 读',
      );
    });

    test('reset send-code 400「无法发送验证码」原样透出(无 retry_after 不倒计时)', () async {
      final harness = ApiHarness((req) async {
        json(req, {'detail': '无法发送验证码'}, status: 400);
      });
      await harness.start();
      addTearDown(harness.stop);
      final e = await _throwsApiException(
        () => harness.api!.auth.sendPhoneResetCode('13900139000'),
      );
      expect(e.status, 400);
      expect(e.message, '无法发送验证码');
      expect(retryAfterOf(e.raw), 0, reason: '无该字段 → 调用方不启动倒计时');
    });

    test('bind 409 占用 / bind 400 码错 / confirm 429 作废均抛 ApiException', () async {
      Future<void> round({
        required String path,
        required int status,
        required String detail,
        required Future<Object> Function(ApiHarness h) call,
      }) async {
        final harness = ApiHarness((req) async {
          json(req, {'detail': detail}, status: status);
        });
        await harness.start();
        addTearDown(harness.stop);
        final e = await _throwsApiException(() => call(harness));
        expect(e.status, status, reason: '$path $status');
        expect(e.message, detail, reason: '$path detail 透传');
      }

      await round(
        path: 'bind409',
        status: 409,
        detail: '该手机号已绑定其他账号',
        call: (h) => h.api!.auth.bindPhone('13800138000', 'AB12CD'),
      );
      await round(
        path: 'bind400',
        status: 400,
        detail: '验证码错误',
        call: (h) => h.api!.auth.bindPhone('13800138000', 'WRONG1'),
      );
      await round(
        path: 'confirm429',
        status: 429,
        detail: '错误次数过多,请重新获取',
        call: (h) => h.api!.auth.confirmPhoneReset('13900139000', 'WRONG1'),
      );
    });

    test('无 detail 的非 200 落中文兜底', () async {
      final harness = ApiHarness((req) async {
        json(req, {'detail': null}, status: 503);
      });
      await harness.start();
      addTearDown(harness.stop);
      final e = await _throwsApiException(
        () => harness.api!.auth.sendPhoneBindCode('13800138000'),
      );
      expect(e.status, 503);
      expect(e.message, '发送验证码失败', reason: 'extractDetail 无 detail → fallback');
    });
  });
}

Future<ApiException> _throwsApiException(Future<Object> Function() call) async {
  try {
    await call();
  } on ApiException catch (e) {
    return e;
  }
  fail('期望抛出 ApiException');
}
