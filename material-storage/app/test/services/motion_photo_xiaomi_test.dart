/// 小米官方动态照片 SDK 接入 Dart 侧单测(2026-11-16 方案 §6 第一段,包 C):
/// 全部经 §4.4 注入缝注假件(isAndroidPlatform/fetchDeviceInfo/invokeSdk),
/// 测试宿主零平台通道,与仓库测试风格一致。覆盖:
/// - defaultXiaomiComposer 五分支(§3 probe 语义逐条):非 Android→null 且
///   device_info 零调用;device_info 通道异常/字段缺失→null;非 xiaomi→null
///   且 ms/motion_photo 零调用;xiaomi+isSupported=true→三字段齐;
///   xiaomi+false/返回非 bool/通道异常(同步·异步抛)→(false,null,null)(D2);
/// - extractPresentationTimestampUs 五形态:MotionPhoto 优先/仅 MicroVideo/
///   单双引号/无 XMP→null/窗外(>256KB 头窗)→null;
/// - muxXiaomiLivePhoto 三态:ok=true 原样返回 outPath/ok=false 抛且日志+
///   幂等删半成品/通道 error 抛;长值锚:timestampUs=4000000000(>2^31)原样
///   透传 invokeSdk args(§4.3 装箱钉子的 Dart 侧守门);
/// - defaultVerifyXiaomiProduct:通道异常→false/返回非 bool→false(fail-safe
///   全兜),附 args 带 path 与常规 true/false 形态。
///
/// invokeSdk 假件签名钉子(§6):类型含可选位置参,假件必须写成
/// `(method, [args]) async => …` 形态(单参闭包赋值类型不匹配)。
library;

import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/services/motion_photo.dart' show xmpHeadWindow;
import 'package:ms_app/services/motion_photo_xiaomi.dart';

import '../core/session_restore_log_test.dart' show captureLogs;

/// invokeSdk 假件签名钉子(§6):类型含可选位置参,假件必须写成
/// `(method, [args]) async => …` 形态(单参闭包赋值类型不匹配)。
typedef InvokeSdkFake = Future<Object?> Function(
  String method, [
  Map<String, Object?>? args,
]);

/// invokeSdk 假件工厂:恒回 [reply](签名含可选位置参——钉子形态)。
InvokeSdkFake sdkReply(Object? reply) =>
    (String method, [Map<String, Object?>? args]) async => reply;

void main() {
  group('defaultXiaomiComposer(§3 probe 五分支)', () {
    test('非 Android → null 且 fetchDeviceInfo 零调用(平台门先于通道)', () async {
      var fetchCalls = 0;
      Future<Map<Object?, Object?>?> fetch() async {
        fetchCalls += 1;
        return {'manufacturer': 'xiaomi'};
      }

      // 测试宿主(VM,非 Android)缺省 gate 即 null:
      expect(await defaultXiaomiComposer()(), isNull);
      // 显式非 Android 同样 null:
      expect(
        await defaultXiaomiComposer(
          isAndroidPlatform: false,
          fetchDeviceInfo: fetch,
        )(),
        isNull,
      );
      expect(fetchCalls, 0, reason: '平台门必须先于 device_info 通道,不白付调用');
    });

    test('device_info 通道异常 → null(意外异常≈今日行为,整体 try/catch 兜)', () async {
      expect(
        await defaultXiaomiComposer(
          isAndroidPlatform: true,
          fetchDeviceInfo: () async => throw StateError('channel 瞬断(模拟)'),
        )(),
        isNull,
      );
    });

    test('device_info 字段缺失(返回 null / map 无 manufacturer)→ null', () async {
      expect(
        await defaultXiaomiComposer(
          isAndroidPlatform: true,
          fetchDeviceInfo: () async => null,
        )(),
        isNull,
      );
      expect(
        await defaultXiaomiComposer(
          isAndroidPlatform: true,
          fetchDeviceInfo: () async => {'model': '23127PN0CC'},
        )(),
        isNull,
        reason: 'map 缺 manufacturer 字段同走 null',
      );
    });

    test(
      '非 xiaomi manufacturer → null 且 ms/motion_photo 零调用(照旧 flm)',
      () async {
        var sdkCalls = 0;
        expect(
          await defaultXiaomiComposer(
            isAndroidPlatform: true,
            fetchDeviceInfo: () async => {'manufacturer': 'google'},
            invokeSdk: (String method, [Map<String, Object?>? args]) async {
              sdkCalls += 1;
              return true;
            },
          )(),
          isNull,
        );
        expect(sdkCalls, 0, reason: '白名单其余机型不触 SDK 通道(零影响)');
      },
    );

    test(
      'xiaomi + isSupported=true → supported=true 且 generate/verifyProduct 非空',
      () async {
        final calls = <(String, Map<String, Object?>?)>[];
        final r = await defaultXiaomiComposer(
          isAndroidPlatform: true,
          // 真机实报 manufacturer="Xiaomi"(大小写归一后命中)
          fetchDeviceInfo: () async => {'manufacturer': 'Xiaomi'},
          invokeSdk: (String method, [Map<String, Object?>? args]) async {
            calls.add((method, args));
            return true;
          },
        )();
        expect(r, isNotNull);
        expect(r!.supported, isTrue);
        expect(r.generate, isNotNull, reason: 'supported=true 时 generate 必非空');
        expect(
          r.verifyProduct,
          isNotNull,
          reason: 'supported=true 时 verifyProduct 必非空',
        );
        expect(calls.single.$1, 'isSupported');
        expect(calls.single.$2, isNull, reason: 'isSupported 无参数');
      },
    );

    test('xiaomi + isSupported=false/返回非 bool/通道异常(同步·异步抛)→'
        '(false, null, null)(§3-5,D2 降级)', () async {
      final List<(String, InvokeSdkFake)> cases = [
        ('返回 false', sdkReply(false)),
        ('返回非 bool 字符串', sdkReply('true')),
        ('返回非 bool 数字', sdkReply(1)),
        ('返回 null', sdkReply(null)),
        // 通道异常与 false/非 bool 同列(§3-5):实现单独 try/catch 收口为
        // supported=false 落 D1,不经外层整体兜底;同步抛/异步抛两形态均落
        // (false,null,null)。PlatformException=真实 channel 异常形态。
        (
          '通道异常·异步抛(async 体内 throw,await 时外抛)',
          (String method, [Map<String, Object?>? args]) async =>
              throw PlatformException(code: 'mux_fail'),
        ),
        (
          '通道异常·同步抛(非 async 调用点即时外抛)',
          (String method, [Map<String, Object?>? args]) =>
              throw PlatformException(code: 'channel-error'),
        ),
      ];
      for (final (label, invoke) in cases) {
        final r = await defaultXiaomiComposer(
          isAndroidPlatform: true,
          fetchDeviceInfo: () async => {'manufacturer': 'xiaomi'},
          invokeSdk: invoke,
        )();
        expect(r, isNotNull, reason: '$label:supported=false 非 null(编排层走 D1)');
        expect(r!.supported, isFalse, reason: label);
        expect(r.generate, isNull, reason: label);
        expect(r.verifyProduct, isNull, reason: label);
      }
    });
  });

  group('extractPresentationTimestampUs(五形态)', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('xiaomi_ts_test');
    });
    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('双标记并存:MotionPhoto 优先(MicroVideo 在前亦取 MotionPhoto)', () async {
      final f = await File('${tmp.path}/a.jpg').writeAsString(
        'noise GCamera:MicroVideoPresentationTimestampUs="999999" '
        'GCamera:MotionPhotoPresentationTimestampUs="123456" tail',
      );
      expect(await extractPresentationTimestampUs(f), 123456);
    });

    test('仅 MicroVideo 标记 → 取其值(次选分支)', () async {
      final f = await File('${tmp.path}/b.jpg').writeAsString(
        'noise GCamera:MicroVideoPresentationTimestampUs="7777" tail',
      );
      expect(await extractPresentationTimestampUs(f), 7777);
    });

    test('单/双引号容忍(MotionPhoto 单引号 / MicroVideo 双引号)', () async {
      final singleQuoted = await File('${tmp.path}/c.jpg')
          .writeAsString("GCamera:MotionPhotoPresentationTimestampUs='424242'");
      expect(await extractPresentationTimestampUs(singleQuoted), 424242);
      final doubleQuoted = await File('${tmp.path}/d.jpg')
          .writeAsString('GCamera:MicroVideoPresentationTimestampUs="424243"');
      expect(await extractPresentationTimestampUs(doubleQuoted), 424243);
    });

    test('无 XMP 命中 → null(编排层兜底 0,D3:iOS 补抓 jpg 无 motion XMP)', () async {
      final f = await File('${tmp.path}/e.jpg')
          .writeAsString('plain bytes without any motion timestamp attribute');
      expect(await extractPresentationTimestampUs(f), isNull);
    });

    test('时间戳在 256KB 头窗之外 → null(禁全量回读)', () async {
      final filler = 'A' * xmpHeadWindow; // 窗外起点恰在 262144 偏移
      final f = await File('${tmp.path}/f.jpg').writeAsString(
        '$filler GCamera:MotionPhotoPresentationTimestampUs="123"',
      );
      expect(await extractPresentationTimestampUs(f), isNull);
    });
  });

  group('muxXiaomiLivePhoto(三态 + 长值锚)', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('xiaomi_mux_test');
    });
    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('ok=true → 原样返回 outPath,args 四字段齐全', () async {
      final calls = <(String, Map<String, Object?>?)>[];
      final out = await muxXiaomiLivePhoto(
        imagePath: '${tmp.path}/i.jpg',
        videoPath: '${tmp.path}/v.mp4',
        timestampUs: 123456,
        outPath: '${tmp.path}/out.jpg',
        invokeSdk: (String method, [Map<String, Object?>? args]) async {
          calls.add((method, args));
          return true;
        },
      );
      expect(out, '${tmp.path}/out.jpg', reason: '成功原样返回 outPath');
      expect(calls.single.$1, 'mux');
      final args = calls.single.$2!;
      expect(args['imagePath'], '${tmp.path}/i.jpg');
      expect(args['videoPath'], '${tmp.path}/v.mp4');
      expect(args['outPath'], '${tmp.path}/out.jpg');
      expect(args['timestampUs'], 123456);
    });

    test('长值锚:timestampUs=4000000000(>2^31)原样透传 invokeSdk args', () async {
      Object? received;
      final out = await muxXiaomiLivePhoto(
        imagePath: 'i',
        videoPath: 'v',
        timestampUs: 4000000000,
        outPath: 'o',
        invokeSdk: (String method, [Map<String, Object?>? args]) async {
          received = args!['timestampUs'];
          return true;
        },
      );
      expect(out, 'o');
      expect(received, 4000000000, reason: '§4.3 装箱钉子:Dart 侧透传必须无损');
    });

    test('ok=false → 抛 xiaomi 前缀异常 + ERROR 日志 + 幂等删半成品', () async {
      final outPath = '${tmp.path}/out2.jpg';
      await File(outPath).writeAsString('orphan'); // 预置半成品占盘
      final (lines, restore) = captureLogs();
      try {
        await expectLater(
          muxXiaomiLivePhoto(
            imagePath: 'i',
            videoPath: 'v',
            timestampUs: 0,
            outPath: outPath,
            invokeSdk: (String method, [Map<String, Object?>? args]) async =>
                false,
          ),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'toString',
              contains('xiaomi mux 失败'),
            ),
          ),
        );
        expect(File(outPath).existsSync(), isFalse, reason: '失败路径删半成品防孤儿占盘');
        final errorLines = lines
            .where((l) => l.contains('[ERROR] [motion]'))
            .toList();
        expect(errorLines, hasLength(1), reason: 'ok=false 恰记一条 ERROR');
        expect(errorLines.single, contains('xiaomi mux 失败'));
      } finally {
        restore();
      }
    });

    test('通道 error → 抛异常 + 日志(原生 try/catch result.error 形态)', () async {
      final (lines, restore) = captureLogs();
      try {
        await expectLater(
          muxXiaomiLivePhoto(
            imagePath: 'i',
            videoPath: 'v',
            timestampUs: 0,
            outPath: '${tmp.path}/out3.jpg',
            invokeSdk: (String method, [Map<String, Object?>? args]) async =>
                throw PlatformException(code: 'mux_fail', message: 'boom(模拟)'),
          ),
          throwsA(isA<Exception>()),
        );
        expect(
          lines.where((l) => l.contains('[ERROR] [motion]')).join(' '),
          contains('xiaomi mux 失败'),
        );
      } finally {
        restore();
      }
    });
  });

  group('defaultVerifyXiaomiProduct(isLivePhotoFile oracle 封装)', () {
    test('通道返回 true → true,且 args 带 path(oracle 读产物路径)', () async {
      final calls = <(String, Map<String, Object?>?)>[];
      final ok = await defaultVerifyXiaomiProduct(
        '/product/MVIMG_0_MP.jpg',
        invokeSdk: (String method, [Map<String, Object?>? args]) async {
          calls.add((method, args));
          return true;
        },
      );
      expect(ok, isTrue);
      expect(calls.single.$1, 'isLivePhotoFile');
      expect(calls.single.$2!['path'], '/product/MVIMG_0_MP.jpg');
    });

    test('通道返回 false → false', () async {
      expect(
        await defaultVerifyXiaomiProduct(
          'p',
          invokeSdk: (String method, [Map<String, Object?>? args]) async =>
              false,
        ),
        isFalse,
      );
    });

    test('通道异常 → false(fail-safe 全兜)', () async {
      expect(
        await defaultVerifyXiaomiProduct(
          'p',
          invokeSdk: (String method, [Map<String, Object?>? args]) async =>
              throw StateError('通道瞬断(模拟)'),
        ),
        isFalse,
      );
    });

    test('返回非 bool → false', () async {
      expect(
        await defaultVerifyXiaomiProduct(
          'p',
          invokeSdk: (String method, [Map<String, Object?>? args]) async =>
              'yes',
        ),
        isFalse,
      );
    });
  });
}
