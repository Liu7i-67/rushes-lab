/// R4b(mobile-ux-polish-2)会话恢复可观测单测:
/// - restore() 失败不再静默:AppLog.error 留痕(异常 toString、持久化 jar 是否
///   就绪、cookie 文件目录是否存在、statusCode 若可用)——供真机「切出重开要求
///   重登」经企微日志推送定位(后端 TTL=7 天已排除过期);
/// - 恢复语义不变:失败仍 me=null 留登录页(notifyListeners 照常);
/// - initPersistence 失败分支同样记日志(降级内存 jar 不静默)。
/// 经 debugPrint 捕获 AppLog 输出(测试环境无文件落盘,log 走控制台同步);
/// path_provider 通道 mock 控制支持目录成败。注意:全程不用本地 HttpServer
/// ——TestWidgetsFlutterBinding 会拦 HTTP(恒 400),auth 域改注入桩 API。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show VoidCallback, debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/auth_api.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/models/models.dart';

const _supportChannel = MethodChannel('plugins.flutter.io/path_provider');

/// 挂 path_provider 通道桩:getApplicationSupportDirectory 返回 [dir.path]
/// (method_channel_path_provider 的通道方法名即此,非 *Path)。
/// [fail]=true 时抛平台异常(初始化失败路径注入)。返回清桩函数。
VoidCallback stubSupportDir(Directory? dir, {bool fail = false}) {
  TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_supportChannel, (call) async {
    if (call.method == 'getApplicationSupportDirectory') {
      if (fail) {
        throw PlatformException(code: 'channel-error', message: 'no plugin');
      }
      return dir!.path;
    }
    return null;
  });
  return () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_supportChannel, null);
}

/// 捕获 AppLog 输出(替换 debugPrint;AppLog.log 同步调用它)。
/// 返回 (行列表, 还原函数)。
(List<String>, VoidCallback) captureLogs() {
  final lines = <String>[];
  final prev = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) lines.add(message);
  };
  return (lines, () => debugPrint = prev);
}

/// auth.me() 结果可编排的桩 API([staged] 为 Exception 则抛,否则回 Me)。
class _StubAuthApi extends AuthApi {
  _StubAuthApi(super.api);

  Object? staged;
  var calls = 0;

  @override
  Future<Me> me() async {
    calls++;
    final s = staged;
    if (s is Exception) throw s;
    return s as Me? ?? Me(id: 'u-1', name: '测试');
  }
}

class _StubApi extends MsApi {
  _StubApi() : super(baseUrl: 'http://stub.test.local');

  late final _auth = _StubAuthApi(this);

  @override
  _StubAuthApi get auth => _auth;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('restore 失败:me=null 语义不变 + ERROR 日志含 jar/cookie 目录/statusCode',
      () async {
    final tmp = await Directory.systemTemp.createTemp('ms_session');
    addTearDown(() => tmp.delete(recursive: true));
    addTearDown(stubSupportDir(tmp));

    final api = _StubApi();
    api.auth.staged = ApiException(500, 'boom');

    final s = Session();
    await s.initPersistence(); // jar 就绪,cookie 目录 = $tmp/.cookies
    Directory('${tmp.path}/.cookies').createSync(recursive: true);
    s.api = api;

    var notified = 0;
    s.addListener(() => notified++);
    final (lines, restore) = captureLogs();
    addTearDown(restore);

    final me = await s.restore();

    // 恢复语义不变(R4b 只加观测,不改行为)
    expect(me, isNull);
    expect(s.me, isNull, reason: '失败仍留登录页');
    expect(notified, 1, reason: '照常 notifyListeners(登录页刷新)');

    // 日志可定位:jar 就绪 / cookie 目录存在 / statusCode / 异常 toString
    final errorLines =
        lines.where((l) => l.contains('[ERROR] [session]')).toList();
    expect(errorLines, hasLength(1), reason: '失败恰记一条 ERROR(防误报/防重复)');
    expect(errorLines.single, contains('会话恢复失败'));
    expect(errorLines.single, contains('jar就绪=true'),
        reason: '持久化 jar 是否初始化(区分插件通道失败)');
    expect(errorLines.single, contains('cookie目录存在=true'),
        reason: 'cookie 文件目录存在性(区分 cookie 丢失)');
    expect(errorLines.single, contains('status=500'),
        reason: 'statusCode 若可用(区分后端异常)');
    expect(errorLines.single, contains('ApiException(500)'),
        reason: '含异常 toString');
    expect(api.auth.calls, 1);
  });

  test('restore 成功:无 ERROR session 日志(防误报)', () async {
    final tmp = await Directory.systemTemp.createTemp('ms_session');
    addTearDown(() => tmp.delete(recursive: true));
    addTearDown(stubSupportDir(tmp));

    final api = _StubApi();
    final s = Session();
    await s.initPersistence();
    s.api = api;
    addTearDown(() => s.me = null);

    final (lines, restore) = captureLogs();
    addTearDown(restore);

    final me = await s.restore();
    expect(me, isNotNull);
    expect(
      lines.where((l) => l.contains('[ERROR] [session]')),
      isEmpty,
      reason: '成功路径不产生 session ERROR(污染日志干扰真机排查)',
    );
  });

  test('initPersistence 失败:降级内存 jar 留日志;后续 restore 失败日志标 jar 未就绪',
      () async {
    addTearDown(stubSupportDir(null, fail: true));

    final api = _StubApi();
    api.auth.staged = ApiException(500, 'boom');
    final s = Session();
    final (lines, restore) = captureLogs();
    addTearDown(restore);

    // 初始化失败:不抛、降级内存 jar、留日志(插件通道失败=重登候选根因)
    await s.initPersistence();
    expect(
      lines.where((l) =>
          l.contains('[ERROR] [session]') &&
          l.contains('cookie 持久化初始化失败')),
      hasLength(1),
    );

    // 后续恢复失败:日志标 jar未就绪=false、cookie目录不存在=false
    s.api = api;
    await s.restore();
    final errorLines = lines.where((l) => l.contains('会话恢复失败')).toList();
    expect(errorLines, hasLength(1));
    expect(errorLines.single, contains('jar就绪=false'));
    expect(errorLines.single, contains('cookie目录存在=false'));
    expect(s.me, isNull);
  });
}
