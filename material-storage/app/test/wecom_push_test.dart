/// WeComPush 单测:本地 mock 服务器实现企业微信两条端点,
/// 验证 multipart 上传字段/文件名 + file 消息体 + errcode 错误面;
/// P10:已登录先发 text 身份消息(text → upload_media → file 顺序)、
/// 身份消息失败不阻断 file 推送、未登录维持只发 file。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/services/wecom_push.dart';

void main() {
  late HttpServer server;
  late WeComPush push;
  String? uploadedFilename;
  List<int>? uploadedBytes;
  Map<String, dynamic>? sentBody;

  /// P10:请求路径序(text→upload→file 顺序断言)+ 全部 send 消息体。
  final paths = <String>[];
  final sentBodies = <Map<String, dynamic>>[];

  /// P10:首个 send 请求返回非零 errcode(身份消息失败不阻断用)。
  var failFirstSend = false;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      paths.add(path);
      if (path == '/cgi-bin/webhook/upload_media') {
        expect(req.uri.queryParameters['type'], 'file');
        expect(req.uri.queryParameters['key'], WeComPush.defaultWebhookKey);
        // 解析 multipart:抽 filename 与文件体(按 boundary 粗切)
        final ct = req.headers.value('content-type') ?? '';
        final boundary = RegExp('boundary=(.+)').firstMatch(ct)!.group(1)!.trim();
        final body = await utf8.decoder.bind(req.cast<List<int>>()).join();
        // ignore: avoid_print
        final parts = body.split('--$boundary');
        final filePart = parts.firstWhere((p) => p.contains('name="media"'));
        final fm = RegExp('filename="([^"]+)"').firstMatch(filePart);
        uploadedFilename = fm?.group(1);
        uploadedBytes = utf8.encode(filePart);
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"errcode":0,"errmsg":"ok","media_id":"MID_TEST"}');
        await req.response.close();
        return;
      }
      if (path == '/cgi-bin/webhook/send') {
        sentBody = jsonDecode(await utf8.decoder.bind(req).join())
            as Map<String, dynamic>;
        sentBodies.add(sentBody!);
        req.response.headers.contentType = ContentType.json;
        if (failFirstSend && sentBodies.length == 1) {
          req.response.write('{"errcode":93000,"errmsg":"invalid webhook url"}');
        } else {
          req.response.write('{"errcode":0,"errmsg":"ok"}');
        }
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
    push = WeComPush(apiBase: 'http://127.0.0.1:${server.port}');
  });

  tearDownAll(() async => server.close());

  setUp(() {
    paths.clear();
    sentBodies.clear();
    sentBody = null;
    failFirstSend = false;
    session.me = null;
  });

  tearDown(() => session.me = null);

  Future<File> tmpLog() async {
    final tmp = File(
        '${Directory.systemTemp.path}/wecom_test_${DateTime.now().millisecondsSinceEpoch}.log');
    await tmp.writeAsString('2026-10-19T16:00:00 [INFO] [test] hello\n');
    return tmp;
  }

  test('两步推送:upload_media(multipart media)→ send(file 消息)', () async {
    final tmp = await tmpLog();
    addTearDown(() => tmp.delete().catchError((_) => tmp));

    final mediaId = await push.pushLogFile(tmp);
    expect(mediaId, 'MID_TEST');
    expect(uploadedFilename, isNotNull);
    expect(uploadedFilename!.startsWith('msapp_log_'), isTrue);
    expect(uploadedFilename!.endsWith('.log'), isTrue);
    expect(utf8.decode(uploadedBytes!).contains('hello'), isTrue);

    expect(sentBody!['msgtype'], 'file');
    expect((sentBody!['file'] as Map)['media_id'], 'MID_TEST');
  });

  test('P10 已登录:先发 text 身份消息,再照常传 file(text→upload→file 顺序)',
      () async {
    final tmp = await tmpLog();
    addTearDown(() => tmp.delete().catchError((_) => tmp));
    session.me = Me(id: 'u1', name: 'Evan');

    await push.pushLogFile(tmp);

    expect(paths, [
      '/cgi-bin/webhook/send',
      '/cgi-bin/webhook/upload_media',
      '/cgi-bin/webhook/send',
    ]);
    expect(sentBodies, hasLength(2));
    final text = sentBodies.first;
    expect(text['msgtype'], 'text');
    final content = (text['text'] as Map)['content'] as String;
    expect(content, contains('【移动端日志】用户 Evan(uid u1)· '));
    expect(
      RegExp(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}$').hasMatch(content),
      isTrue,
      reason: '末尾为 yyyy-MM-dd HH:mm 时间戳,实际=$content',
    );
    final file = sentBodies.last;
    expect(file['msgtype'], 'file');
    expect((file['file'] as Map)['media_id'], 'MID_TEST');
  });

  test('P10 身份消息失败不阻断 file 推送(首条 send 返非零 errcode)', () async {
    final tmp = await tmpLog();
    addTearDown(() => tmp.delete().catchError((_) => tmp));
    session.me = Me(id: 'u2', name: '测试员');
    failFirstSend = true;

    final mediaId = await push.pushLogFile(tmp);

    expect(mediaId, 'MID_TEST', reason: '身份消息失败只记日志,推送整体成功');
    expect(paths, [
      '/cgi-bin/webhook/send',
      '/cgi-bin/webhook/upload_media',
      '/cgi-bin/webhook/send',
    ]);
    expect(sentBodies.last['msgtype'], 'file');
    expect((sentBodies.last['file'] as Map)['media_id'], 'MID_TEST');
  });

  test('P10 未登录:维持只发 file(无 text 身份消息)', () async {
    final tmp = await tmpLog();
    addTearDown(() => tmp.delete().catchError((_) => tmp));
    expect(session.me, isNull);

    await push.pushLogFile(tmp);

    expect(paths, ['/cgi-bin/webhook/upload_media', '/cgi-bin/webhook/send']);
    expect(sentBodies, hasLength(1));
    expect(sentBodies.single['msgtype'], 'file');
  });

  test('send 返回非零 errcode 抛 WeComPushException', () async {
    // 换一个 send 总是失败的桩
    final bad = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    bad.listen((req) async {
      if (req.uri.path == '/cgi-bin/webhook/upload_media') {
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"errcode":0,"media_id":"M2"}');
        await req.response.close();
        return;
      }
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"errcode":93000,"errmsg":"invalid webhook url"}');
      await req.response.close();
    });
    final badPush = WeComPush(apiBase: 'http://127.0.0.1:${bad.port}');
    final tmp = File('${Directory.systemTemp.path}/wecom_bad.log');
    await tmp.writeAsString('x');
    await expectLater(
      badPush.pushLogFile(tmp),
      throwsA(isA<WeComPushException>()
          .having((e) => e.stage, 'stage', 'send')
          .having((e) => e.errcode, 'errcode', 93000)),
    );
    await tmp.delete().catchError((_) => tmp);
    await bad.close();
  });
}
