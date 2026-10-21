/// B9 遗留清偿:改密成功后 Me 刷新失败不吞——日志留痕 + 会话标脏(meStale),
/// 下次 restore() 强制重拉兜底;改密本身已生效,刷新失败不向调用方报错。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';

import '../helpers/api_harness.dart';

void main() {
  test('改密成功但 me 刷新失败:不抛、标脏;restore 重拉成功即清脏', () async {
    var meCalls = 0;
    var meBroken = true;
    final harness = ApiHarness((req) async {
      final path = req.uri.path;
      if (path == '/api/v1/auth/change-password' && req.method == 'POST') {
        await readJson(req);
        json(req, {'status': 'ok'});
        return;
      }
      if (path == '/api/v1/auth/me') {
        meCalls++;
        if (meBroken) {
          json(req, {'detail': 'boom'}, status: 500);
        } else {
          json(req, {
            'id': 'u-1',
            'name': '测试',
            'must_change_password': false,
          });
        }
        return;
      }
      json(req, {'detail': 'no route'}, status: 404);
    });
    await harness.start();
    addTearDown(harness.stop);

    final s = Session();
    s.me = null;
    addTearDown(() => s.me = null);
    // api 换绑到 session,走 Session.changePassword 全链路
    s.api = harness.api!;
    await s.changePassword('old', 'n3w');
    expect(meCalls, 1);
    expect(s.meStale, isTrue, reason: '刷新失败 → 会话标脏');
    expect(s.me, isNull, reason: '失败不回填旧 Me');

    // 下一次访问(restore)强制重拉:修好服务端后成功即清脏
    meBroken = false;
    final me = await s.restore();
    expect(me, isNotNull);
    expect(me!.mustChangePassword, isFalse);
    expect(meCalls, 2);
    expect(s.meStale, isFalse, reason: '重拉成功解除标脏');
  });

  test('改密成功且 me 刷新成功:不标脏', () async {
    final harness = ApiHarness((req) async {
      final path = req.uri.path;
      if (path == '/api/v1/auth/change-password' && req.method == 'POST') {
        await readJson(req);
        json(req, {'status': 'ok'});
        return;
      }
      if (path == '/api/v1/auth/me') {
        json(req, {
          'id': 'u-1',
          'name': '测试',
          'must_change_password': false,
        });
        return;
      }
      json(req, {'detail': 'no route'}, status: 404);
    });
    await harness.start();
    addTearDown(harness.stop);

    final s = Session();
    s.api = harness.api!;
    addTearDown(() => s.me = null);
    await s.changePassword('old', 'n3w');
    expect(s.meStale, isFalse);
    expect(s.me?.mustChangePassword, isFalse);
  });
}
