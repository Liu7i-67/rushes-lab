/// PartPutChannel 工厂分流 + dio 通道请求形态单测(feat/ios-bg-upload 包 A,
/// 测试功能点 1/2):工厂按 iosOverride 分流(iOS→bg 通道单例、其余→dio 通道);
/// dio 通道与现状 assets_upload_api 既有 PUT 装配逐项等价(Stream body 字节
/// 一致、显式 Content-Length 头且无 chunked、etag 响应头解析、缺失回空串、
/// CancelToken 透传取消);no-op 方法契约。契约以 assets_upload_api.dart
/// 拆分前实现(dio put + headers[etag])为准;本地 HttpServer 挡网同
/// upload_file_test 先例,不触真实网络。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/transfers/bg_part_put_channel.dart';
import 'package:ms_app/core/transfers/dio_part_put_channel.dart';
import 'package:ms_app/core/transfers/part_put_channel.dart';

void main() {
  group('createPartPutChannel 工厂分流', () {
    test('iosOverride=true → bg 通道单例(重复调用同一实例)', () {
      final a = createPartPutChannel(iosOverride: true);
      final b = createPartPutChannel(iosOverride: true);
      expect(a, isA<BgPartPutChannelImpl>());
      expect(identical(a, b), isTrue, reason: 'bg 通道必须进程级单例');
      expect(a.batchCapable, isTrue);
    });

    test('iosOverride=false → dio 通道(每次新实例,stateless)', () {
      final a = createPartPutChannel(iosOverride: false);
      final b = createPartPutChannel(iosOverride: false);
      expect(a, isA<DioPartPutChannel>());
      expect(a.batchCapable, isFalse);
      expect(identical(a, b), isFalse);
    });

    test('不传 override 按当前平台(Windows 测试机 → dio 通道)', () {
      expect(createPartPutChannel(), isA<DioPartPutChannel>());
    });
  });

  group('DioPartPutChannel 请求形态(本地 HttpServer 挡网)', () {
    late HttpServer server;
    late String base;
    late Dio dio;
    late DioPartPutChannel channel;

    final putBodies = <List<int>>[];
    final putHeaders = <HttpHeaders>[];
    var holdPut = false;
    final putArrived = Completer<void>();
    final putHold = Completer<void>();

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        if (req.method == 'PUT') {
          final bytes = await _readBytes(req);
          putBodies.add(bytes);
          putHeaders.add(req.headers);
          if (holdPut) {
            putArrived.complete();
            await putHold.future; // 挂住响应,制造取消窗口
          }
          req.response.headers.set('etag', '"ET-1"');
          req.response.statusCode = 200;
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });
      dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      channel = DioPartPutChannel(dio);
    });

    tearDownAll(() async {
      await server.close();
    });

    setUp(() {
      putBodies.clear();
      putHeaders.clear();
      holdPut = false;
    });

    tearDown(() {
      if (!putHold.isCompleted) putHold.complete();
    });

    PartPutRequest req(Uint8List chunk, {CancelToken? token}) => PartPutRequest(
      url: '$base/presigned/part-1',
      chunk: chunk,
      uploadId: 'u1',
      partNumber: 1,
      cancelToken: token,
    );

    test('PUT 形态:Stream body 字节一致 + 显式 Content-Length + 非 chunked', () async {
      final chunk = Uint8List.fromList(List.generate(97, (i) => i % 251));
      final result = await channel.put(req(chunk));
      expect(result.etag, '"ET-1"', reason: 'etag 从响应头 etag 取');
      expect(putBodies.single, chunk);
      expect(
        putHeaders.single.value(HttpHeaders.contentLengthHeader),
        '${chunk.length}',
        reason: 'prod 411 钉子:必须显式 Content-Length,禁 chunked',
      );
      expect(putHeaders.single.chunkedTransferEncoding, isFalse);
    });

    test('etag 缺失 → 空串回传(与现状 dio 路径口径一致)', () async {
      // 该 server 恒回 etag;缺失场景由接口契约保证(headers.value ?? ''),
      // 此处用单独 server 验证真实缺头路径
      final s2 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(s2.close);
      s2.listen((req) async {
        await _readBytes(req);
        req.response.statusCode = 200; // 不回 etag 头
        await req.response.close();
      });
      final c2 = DioPartPutChannel(Dio());
      final r = await c2.put(
        PartPutRequest(
          url: 'http://127.0.0.1:${s2.port}/no-etag',
          chunk: Uint8List.fromList([1, 2, 3]),
          uploadId: 'u1',
          partNumber: 1,
        ),
      );
      expect(r.etag, '');
    });

    test('CancelToken 透传:PUT 在途取消 → 抛 cancel DioException', () async {
      holdPut = true;
      final token = CancelToken();
      final f = channel.put(req(Uint8List.fromList([9, 9, 9]), token: token));
      await putArrived.future;
      token.cancel('用户取消');
      await expectLater(f, throwsA(isA<DioException>()));
      expect(token.isCancelled, isTrue);
    });

    test('no-op 契约:ensureInit/cancelForToken/cleanupUpload 正常完成', () async {
      await channel.ensureInit();
      await channel.cancelForToken(CancelToken());
      await channel.cleanupUpload('u1');
    });

    test('未注入 dio 时 put 显式报错(StateError)', () async {
      final bare = DioPartPutChannel(null);
      await expectLater(
        bare.put(req(Uint8List.fromList([1]))),
        throwsA(isA<StateError>()),
      );
    });
  });
}

Future<List<int>> _readBytes(HttpRequest req) async {
  final out = <int>[];
  await for (final chunk in req) {
    out.addAll(chunk);
  }
  return out;
}
