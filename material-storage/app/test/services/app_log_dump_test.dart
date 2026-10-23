/// AppLog.dumpFile 推送前防御截尾单测(企微 upload_media 硬限 20MB)。
///
/// 背景:Android 有传输前台服务,App 可能长期不重启,init 的冷启动轮转
/// 不会触发;错误风暴下日志可涨过 20MB,推送永久失败且重试无法自愈。
/// dumpFile 需在推送前把超限文件截尾到最近一半,并按行首对齐(不切半行)。
///
/// 测试手法:path_provider 通道桩把文档目录指向临时目录,走真实文件读写;
/// _file 是私有静态字段,经 AppLog.init 建立后再由已知路径取 File。
/// 无插件通道时 init 静默降级 _file=null(见 app_log.dart try/catch),
/// 该分支只写 systemTemp 占位文件、行为不变,不在此覆盖。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/services/app_log.dart';

const _providerChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late File logFile;

  /// 等 AppLog.log 的 fire-and-forget 追加落盘(最多 1s),避免跨用例串扰。
  Future<void> waitFor(String marker) async {
    for (var i = 0; i < 100; i++) {
      if ((await logFile.readAsString()).contains(marker)) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('ms_app_log');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _providerChannel,
          (call) async => call.method == 'getApplicationDocumentsDirectory'
              ? tmp.path
              : null,
        );
    await AppLog.init();
    logFile = File('${tmp.path}/app.log');
    expect(await logFile.exists(), isTrue, reason: '通道桩应让 init 建立真文件');
    await waitFor('AppLog 就绪'); // init 尾日志异步追加,落盘后再进入用例
  });

  tearDownAll(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_providerChannel, null);
    await tmp.delete(recursive: true);
  });

  setUp(() async {
    await logFile.writeAsString('', flush: true);
  });

  test('超限:截尾保最近一半,首行从行首对齐(无半行)', () async {
    final lines = [
      for (var i = 0; i < 80; i++)
        'L${i.toString().padLeft(4, '0')} ${'x' * 48}',
    ];
    await logFile.writeAsString('${lines.join('\n')}\n', flush: true);
    expect(await logFile.length(), greaterThan(1024), reason: '前置:文件确实超过注入阈值');

    final f = await AppLog.dumpFile(maxBytes: 1024);

    expect(await f.length(), lessThanOrEqualTo(1024), reason: '截到阈值以内');
    final content = await f.readAsString();
    // 截断锚点由 AppLog.info 异步追加,可能已/未落盘,断言时剔除
    final kept = content
        .split('\n')
        .where((l) => l.isNotEmpty && !l.contains('推送前日志超'))
        .toList();
    expect(kept, isNotEmpty, reason: '截尾不应把日志清空');
    // 每行都能在原文逐字命中:按字节直截会切出半行,这里会匹配不上
    for (final line in kept) {
      expect(lines, contains(line), reason: '保留行必须是原文完整行:$line');
    }
    // 保留的是尾部:最后一行仍是原文件最后一行
    expect(kept.last, lines.last, reason: '保最近段而非文件头');
    expect(kept.length, lessThan(lines.length), reason: '确实发生了截断');

    await waitFor('推送前日志超'); // 等锚点落盘,避免污染后续用例
  });

  test('未超限:dumpFile 原样返回,不截断', () async {
    final content = '${[for (var i = 0; i < 5; i++) 'small-$i'].join('\n')}\n';
    await logFile.writeAsString(content, flush: true);

    final f = await AppLog.dumpFile(maxBytes: 1024);

    expect(await f.readAsString(), content, reason: '未超限文件不得改动');
  });

  test('空文件:仍写占位行(既有行为回归)', () async {
    final f = await AppLog.dumpFile(maxBytes: 1024);

    expect(
      await f.readAsString(),
      contains('[INFO] [log] (空日志占位)'),
      reason: '企微拒绝空文件,空日志需占位行',
    );
  });
}
