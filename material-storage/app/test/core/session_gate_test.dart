/// Session.handleSessionExpired 单测(§4.1):401 触发清会话(清 me)+
/// 单飞闸门去抖(并发多请求只走一次);未登录态(me==null)不触发。
/// 需要 TestWidgetsFlutterBinding(navigatorKey 的 GlobalKey);
/// 因此与需要真实 socket 的探活测试(session_probe_test.dart)分文件。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/models/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('handleSessionExpired:清 me 并去抖(窗口期内第二次不重复处理)', () async {
    final s = Session();
    s.me = Me.fromJson(const {'id': 'u-1', 'name': '测试'});
    // 单测无 Navigator(navigatorKey.currentState 为 null)→ 只验证会话清理
    await s.handleSessionExpired();
    expect(s.me, isNull);
    // 去抖窗口(1s)内并发到达的第二个 401 不再触发
    await s.handleSessionExpired();
    expect(s.me, isNull);
  });

  test('未登录态下的 401(me==null)不触发清会话流程', () async {
    final s = Session();
    s.me = null;
    await s.handleSessionExpired();
    expect(s.me, isNull);
    expect(s.phase, SessionPhase.probing); // 无副作用
  });
}
