/// Session 探活单测(§4 定稿):候选序(dart-define 优先/内网在公网前)、
/// 顺序探测命中即用、全失败 → unreachable 且重按可恢复;401 单飞闸门去抖。
/// 探活/闸门均为真时序,本地 HttpServer / 短窗口 Timer 驱动。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';

/// 起一个只应答探活路径(kProbePath)=200 的本地服务(banner 空数据形态)。
Future<HttpServer> _startProbeServer() async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((req) async {
    if (req.uri.path == kProbePath) {
      req.response.write('{"items":[]}');
    } else {
      req.response.statusCode = 404;
    }
    await req.response.close();
  });
  return s;
}

/// 起一个对探活请求恒应答 403 的本地服务(复刻反代拦截形态,本次真机事故根因)。
Future<HttpServer> _startForbiddenServer() async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((req) async {
    req.response.statusCode = 403;
    await req.response.close();
  });
  return s;
}

/// 起一个绑定后立刻关闭的死口(连接拒绝,不耗 3s 超时)。
Future<int> _deadPort() async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

void main() {
  // 注意:本文件不起 TestWidgetsFlutterBinding(它会把全部 HTTP 拦成 400,
  // 探活需要真实本地 socket);需要 binding 的 handleSessionExpired 测试
  // 见 session_gate_test.dart。
  test('默认候选序:内网在公网前;dart-define 未注入则不含开发口', () {
    final c = defaultProbeCandidates();
    expect(c.contains(kIntranetEntry), isTrue);
    expect(c.contains(kPublicEntry), isTrue);
    expect(c.lastIndexOf(kIntranetEntry),
        lessThan(c.lastIndexOf(kPublicEntry)));
    // 47.108.196.211 dev 预设不在探活序列(§4 删除项)
    expect(c.any((u) => u.contains('47.108.196.211')), isFalse);
  });

  test('顺序探测:首候选不可达 → 降级下一候选,命中即用', () async {
    final ok = await _startProbeServer();
    addTearDown(ok.close);
    final dead = await _deadPort();

    final s = Session();
    expect(s.phase, SessionPhase.probing);
    await s.probe(candidates: [
      'http://127.0.0.1:$dead',
      'http://127.0.0.1:${ok.port}',
    ]);
    expect(s.phase, SessionPhase.ready);
    expect(s.baseUrl, 'http://127.0.0.1:${ok.port}');
    expect(s.api, isNotNull);
  });

  test('候选探活 403 → 视为失败继续下一候选(锁死 2026-10-20 真机 /healthz 被反代 403 根因)',
      () async {
    final forbidden = await _startForbiddenServer();
    final ok = await _startProbeServer();
    addTearDown(forbidden.close);
    addTearDown(ok.close);

    final s = Session();
    await s.probe(candidates: [
      'http://127.0.0.1:${forbidden.port}',
      'http://127.0.0.1:${ok.port}',
    ]);
    expect(s.phase, SessionPhase.ready);
    expect(s.baseUrl, 'http://127.0.0.1:${ok.port}');
  });

  test('首个命中即用,不再探后续候选(命中即用语义)', () async {
    final first = await _startProbeServer();
    final second = await _startProbeServer();
    addTearDown(first.close);
    addTearDown(second.close);

    final s = Session();
    await s.probe(candidates: [
      'http://127.0.0.1:${first.port}',
      'http://127.0.0.1:${second.port}',
    ]);
    expect(s.baseUrl, 'http://127.0.0.1:${first.port}');
  });

  test('全失败 → unreachable;重试命中后恢复 ready(登录页「重试」路径)', () async {
    final dead1 = await _deadPort();
    final dead2 = await _deadPort();
    final s = Session();
    await s.probe(candidates: [
      'http://127.0.0.1:$dead1',
      'http://127.0.0.1:$dead2',
    ]);
    expect(s.phase, SessionPhase.unreachable);

    final ok = await _startProbeServer();
    addTearDown(ok.close);
    await s.probe(candidates: ['http://127.0.0.1:${ok.port}']);
    expect(s.phase, SessionPhase.ready);
  });

  test('SingleFlightGate:窗口期内并发只放行一次,窗口过后复位', () async {
    final gate = SingleFlightGate(const Duration(milliseconds: 30));
    expect(gate.acquire(), isTrue);
    expect(gate.acquire(), isFalse);
    expect(gate.acquire(), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(gate.acquire(), isTrue);
    gate.reset();
  });
}
