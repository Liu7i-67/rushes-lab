/// WeComPush 单测:本地 mock 服务器实现企业微信两条端点,
/// 验证 multipart 上传字段/文件名 + file 消息体 + errcode 错误面。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/services/wecom_push.dart';

void main() {
  late HttpServer server;
  late WeComPush push;
  String? uploadedFilename;
  List<int>? uploadedBytes;
  Map<String, dynamic>? sentBody;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
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
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"errcode":0,"errmsg":"ok"}');
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
    push = WeComPush(apiBase: 'http://127.0.0.1:${server.port}');
  });

  tearDownAll(() async => server.close());

  test('两步推送:upload_media(multipart media)→ send(file 消息)', () async {
    final tmp = File(
        '${Directory.systemTemp.path}/wecom_test_${DateTime.now().millisecondsSinceEpoch}.log');
    await tmp.writeAsString('2026-10-19T16:00:00 [INFO] [test] hello\n');
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
