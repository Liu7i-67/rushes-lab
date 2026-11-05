/// 邮箱账号方案 §7.4 改造:后端 session_version 自增后旧 JWT 立即失效,
/// Session.changePassword 成功路径不再调 me() 刷新(必 401 触发全局过期
/// 钩子),改 `await logout()` 清 me / cookie / 清缓存钩子;导航由页面统一
/// 回登录页(change_password_page widget 测试另见 features/)。
/// 原 B9 meStale 标脏语义随 me() 刷新路径一并移除,本文件按新契约改写。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

void main() {
  test('改密成功:logout() 被调用、me 清空;不再调 me() 刷新', () async {
    var meCalls = 0;
    var logoutCalls = 0;
    final harness = ApiHarness((req) async {
      final path = req.uri.path;
      if (path == '/api/v1/auth/change-password' && req.method == 'POST') {
        await readJson(req);
        json(req, {'status': 'ok'});
        return;
      }
      if (path == '/api/v1/auth/logout' && req.method == 'POST') {
        logoutCalls++;
        noContent(req);
        return;
      }
      if (path == '/api/v1/auth/me') {
        meCalls++;
        json(req, {'id': 'u-1', 'name': '测试'});
        return;
      }
      json(req, {'detail': 'no route'}, status: 404);
    });
    await harness.start();
    addTearDown(harness.stop);

    final s = Session();
    s.api = harness.api!;
    s.me = Me(id: 'u-1', name: '测试');
    addTearDown(() => s.me = null);

    await s.changePassword('old', 'n3wpass1');
    expect(logoutCalls, 1, reason: '§7.4:改密成功主动 logout 清会话');
    expect(meCalls, 0, reason: '§7.4:不再调 me() 刷新(旧 JWT 已失效必 401)');
    expect(s.me, isNull, reason: 'logout 清空 Me 缓存');
  });

  test('改密失败(后端 400):不清会话、不调 logout,me 保留', () async {
    var logoutCalls = 0;
    final harness = ApiHarness((req) async {
      final path = req.uri.path;
      if (path == '/api/v1/auth/change-password' && req.method == 'POST') {
        await readJson(req);
        json(req, {'detail': '账号密码不正确'}, status: 400);
        return;
      }
      if (path == '/api/v1/auth/logout' && req.method == 'POST') {
        logoutCalls++;
        noContent(req);
        return;
      }
      json(req, {'detail': 'no route'}, status: 404);
    });
    await harness.start();
    addTearDown(harness.stop);

    final s = Session();
    s.api = harness.api!;
    s.me = Me(id: 'u-1', name: '测试');
    addTearDown(() => s.me = null);

    await expectLater(
      s.changePassword('wrong', 'n3wpass1'),
      throwsA(isA<ApiException>()),
    );
    expect(logoutCalls, 0, reason: '改密未成功不触发 logout');
    expect(s.me, isNotNull, reason: '失败不清会话');
  });
}
