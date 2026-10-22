/// 测试功能点 T7(F2-6):ApkUpdater 下载落盘语义 —
/// - tempApkPath 命名契约 `{tmp}/huanhuashijie-update-<version>.apk`(尾斜杠不双写);
/// - 开始前删同名旧文件:预置残留被新包完整覆盖;
/// - 取消:半成品被清理,download 正常返回不抛(取消不算错误);
/// - install:可注入 opener,done=false → 可读 UpdateException。
/// dio/tempDirPath/openApk 全注入:指向本地 HttpServer 与系统临时目录,
/// 不触 path_provider / OpenFilex 平台通道。
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/update/apk_updater.dart';
import 'package:ms_app/core/update/update_errors.dart';

/// 有界轮询(条件满足即返回,超时 fail 带原因):等半成品落盘用。
Future<void> _waitUntil(Future<bool> Function() cond, String reason) async {
  for (var i = 0; i < 100; i++) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('2s 内条件未满足:$reason');
}

/// 有界轮询(只等不 fail):Windows 上取消后文件句柄释放/删除可见性略有延迟,
/// 断言前给 2s 宽限,超时后以末次实测值参与 expect。
Future<bool> _eventually(Future<bool> Function() cond) async {
  var ok = false;
  for (var i = 0; i < 100; i++) {
    ok = await cond();
    if (ok) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return ok;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('apk_updater_test');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  ApkUpdater updaterWith({Dio? dio, ApkOpener? openApk}) => ApkUpdater(
        dio: dio ?? Dio(),
        tempDirPath: () async => tmp.path,
        openApk: openApk ?? ((_) async => (done: true, message: '')),
      );

  group('tempApkPath(F2-6 命名契约)', () {
    test('{tmp}/huanhuashijie-update-<version>.apk;目录尾斜杠不双写', () async {
      final a = ApkUpdater(tempDirPath: () async => '/tmp');
      expect(
          await a.tempApkPath('1.2.3'), '/tmp/huanhuashijie-update-1.2.3.apk');
      final b = ApkUpdater(tempDirPath: () async => '/tmp/');
      expect(
          await b.tempApkPath('1.2.3'), '/tmp/huanhuashijie-update-1.2.3.apk');
    });
  });

  group('download(T7)', () {
    test('开始前删同名旧文件:预置残留被新包覆盖,进度百分比收口 100', () async {
      final bytes = List<int>.generate(128 * 1024, (i) => i % 251);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        try {
          req.response.statusCode = 200;
          req.response.contentLength = bytes.length;
          req.response.add(bytes);
          await req.response.close();
        } catch (_) {}
      });
      addTearDown(() => server.close(force: true));

      final updater = updaterWith();
      final savePath = await updater.tempApkPath('2.0.0');
      final apk = File(savePath);
      await apk.writeAsString('stale-old-half-apk-content');

      final percents = <int>[];
      await updater.download(
        url: 'http://127.0.0.1:${server.port}/a.apk',
        savePath: savePath,
        cancelToken: CancelToken(),
        onProgress: percents.add,
      );

      expect(await apk.length(), bytes.length,
          reason: '同名旧文件已先删,落盘为新包字节(T7)');
      expect(await apk.readAsBytes(), bytes);
      expect(percents, isNotEmpty);
      expect(percents.last, 100, reason: '总长已知 → 百分比收口 100');
      expect(percents.every((p) => p == -1 || (p >= 0 && p <= 100)), isTrue,
          reason: 'percent 契约:-1=总长未知,否则 0..100');
    });

    test('取消:半成品被清理,download 正常返回不抛(取消不算错误)', () async {
      final chunk = List<int>.filled(64 * 1024, 7);
      final release = Completer<void>(); // 挂住服务端:首块后不再发数据
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        try {
          req.response.statusCode = 200;
          req.response.contentLength =
              chunk.length * 100; // 总长已知且远大于首块:客户端停在半成品态
          req.response.add(chunk);
          await req.response.flush();
          await release.future;
          req.response.add(chunk);
          await req.response.close();
        } catch (_) {}
      });
      addTearDown(() {
        release.complete(); // 放行挂起的 handler,便于 server 干净退出
        return server.close(force: true);
      });

      final updater = updaterWith();
      final savePath = await updater.tempApkPath('2.0.1');
      final token = CancelToken();
      final fut = updater.download(
        url: 'http://127.0.0.1:${server.port}/a.apk',
        savePath: savePath,
        cancelToken: token,
        onProgress: (_) {},
      );

      // 复刻「下载中点取消」:等半成品落盘(首块已写)再 cancel
      await _waitUntil(
        () async => await File(savePath).exists() &&
            await File(savePath).length() > 0,
        '半成品未落盘,取消路径无从验证',
      );
      token.cancel();
      await fut; // 不抛 = 取消不算错误(F2-6)

      expect(
        await _eventually(() async => !await File(savePath).exists()),
        isTrue,
        reason: '取消后半成品必须清理(T7)',
      );
    });
  });

  group('install(F2-6 调起安装)', () {
    test('opener done → 正常返回,且收到传入的 savePath', () async {
      String? opened;
      final updater = updaterWith(
        openApk: (p) async {
          opened = p;
          return (done: true, message: '');
        },
      );
      await updater.install('/tmp/x.apk');
      expect(opened, '/tmp/x.apk');
    });

    test('opener done=false → UpdateException 透出可读原因', () async {
      final updater = updaterWith(
        openApk: (_) async => (done: false, message: '请允许安装未知应用'),
      );
      await expectLater(
        updater.install('/tmp/x.apk'),
        throwsA(isA<UpdateException>()
            .having((e) => e.message, 'message', '无法启动安装:请允许安装未知应用')),
      );
    });
  });
}
