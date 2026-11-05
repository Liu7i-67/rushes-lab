/// B4 下载落盘执行件单测(P2-3 局部失败修复):livp 解包双存「分别计成败」
/// ——静态图成功+视频失败时如实记「静态图已入库/实况短片失败」,不入
/// 「整路失败」误报;解包临时目录 finally 必清(泄漏断言,注入 unpackParent
/// 观测)。photo_manager 通道不触:存图件全注入假件,PC 零平台通道。
/// 2026-11-05 增:T3 saveLivePhotoWithFallback 降级全组合、T4 zhError 中文映射
/// (gallerySaver 本体不测,纯编排函数注入闭包)、F6 zhifyComposite 复合文案
/// 子串净化(降级 fail 路英文模式中文化且分记结构保留)。
library;

import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/services/download_savers.dart';
import 'package:ms_app/services/livp.dart' show LivpService;
import 'package:ms_app/services/media_save.dart' show SinkOutcome, baseNameOf;

/// 真 livp 文件(zip:静态图+实况短片),落独立临时目录。
Future<File> _makeLivp() async {
  final dir = await Directory.systemTemp.createTemp('savers_livp_src');
  addTearDown(() => dir.delete(recursive: true).ignore());
  final f = File('${dir.path}/IMG_T.livp');
  await f.writeAsBytes(
    LivpService.pack(
      imageBytes: const [1, 2, 3, 4],
      imageExt: 'jpg',
      videoBytes: const [5, 6, 7, 8],
      videoExt: 'mov',
      baseName: 'IMG_T',
    ),
  );
  return f;
}

/// 轮询等 [dir] 清空(解包临时清理是 fire-and-forget,微任务泵不保证完成)。
Future<void> _untilEmpty(Directory dir, {int maxMs = 3000}) async {
  // 解包目录可能被整目录删除(递归清理),此时 listSync 抛路径不存在——
  // 目录都已不存在,同样是「清理干净」,不能当作泄漏失败。
  bool empty() {
    try {
      return dir.listSync(recursive: true).isEmpty;
    } on PathNotFoundException {
      return true;
    }
  }

  final deadline = DateTime.now().add(Duration(milliseconds: maxMs));
  while (DateTime.now().isBefore(deadline)) {
    if (empty()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('临时目录未在时限内清理干净:${dir.path}');
}

void main() {
  group('livpPairOutcome(静态图/实况短片分别计成败,P2-3)', () {
    test('全成 → ok,文案含两落点', () async {
      final saved = <String>[];
      final out = await livpPairOutcome(
        image: File('IMG_T.jpg'),
        video: File('IMG_T.mov'),
        saveImage: (f) async {
          saved.add(baseNameOf(f.path));
          return null; // null=无定位信息,落 fallback 文案
        },
        saveVideo: (f) async {
          saved.add(baseNameOf(f.path));
          return null;
        },
      );
      expect(out.isOk, isTrue);
      expect(out.detail, contains('静态图'));
      expect(out.detail, contains('实况短片'));
      expect(saved, ['IMG_T.jpg', 'IMG_T.mov']);
    });

    test('静态图成功+视频失败 → fail 但如实分记:静态图已入库、实况短片失败'
        '(不入「整路失败」误报)', () async {
      final out = await livpPairOutcome(
        image: File('IMG_T.jpg'),
        video: File('IMG_T.mov'),
        saveImage: (f) async => null,
        saveVideo: (f) async => throw StateError('saveVideo boom'),
      );
      expect(out.isOk, isFalse);
      expect(out.detail, contains('静态图已入库'));
      expect(out.detail, contains('实况短片失败'));
      expect(out.detail, contains('saveVideo boom'));
    });

    test('静态图失败+视频成功 → 对称如实分记', () async {
      final out = await livpPairOutcome(
        image: File('IMG_T.jpg'),
        video: File('IMG_T.mov'),
        saveImage: (f) async => throw StateError('img boom'),
        saveVideo: (f) async => null,
      );
      expect(out.isOk, isFalse);
      expect(out.detail, contains('静态图失败'));
      expect(out.detail, contains('img boom'));
      expect(out.detail, contains('实况短片已入库'));
    });

    test('双败 → 两半失败都进文案', () async {
      final out = await livpPairOutcome(
        image: File('IMG_T.jpg'),
        video: File('IMG_T.mov'),
        saveImage: (f) async => throw StateError('img boom'),
        saveVideo: (f) async => throw StateError('vid boom'),
      );
      expect(out.isOk, isFalse);
      expect(out.detail, contains('静态图失败'));
      expect(out.detail, contains('实况短片失败'));
    });

    test('无实况短片条目(退化 livp)→ 只存静态图即 ok', () async {
      var videoCalled = false;
      final out = await livpPairOutcome(
        image: File('IMG_T.jpg'),
        video: null,
        saveImage: (f) async => null,
        saveVideo: (f) async {
          videoCalled = true;
          return null;
        },
      );
      expect(out.isOk, isTrue);
      expect(videoCalled, isFalse);
    });
  });

  group('saveLivpPairToGallery(解包临时目录 finally 必清,P2-3 泄漏修复)', () {
    test('子存失败(视频抛错)→ 临时目录清理干净(泄漏断言)', () async {
      final parent = await Directory.systemTemp.createTemp('savers_leak');
      addTearDown(() => parent.delete(recursive: true).ignore());
      final out = await saveLivpPairToGallery(
        await _makeLivp(),
        saveImage: (f) async => null,
        saveVideo: (f) async => throw StateError('saveVideo boom'),
        unpackParent: parent,
      );
      expect(out.isOk, isFalse, reason: '视频失败 → 路结果 fail,但文案如实分记');
      expect(out.detail, contains('静态图已入库'));
      await _untilEmpty(parent, maxMs: 3000);
    });

    test('解包失败(非 livp 字节)→ 异常外溢前临时目录也清理(gallerySaver 外层兜成 fail)', () async {
      final parent = await Directory.systemTemp.createTemp('savers_leak');
      addTearDown(() => parent.delete(recursive: true).ignore());
      final dir = await Directory.systemTemp.createTemp('savers_bad_src');
      addTearDown(() => dir.delete(recursive: true).ignore());
      final bad = File('${dir.path}/bad.livp');
      await bad.writeAsBytes(const [0, 1, 2, 3]); // 非 zip
      await expectLater(
        saveLivpPairToGallery(
          bad,
          saveImage: (f) async => null,
          saveVideo: (f) async => null,
          unpackParent: parent,
        ),
        throwsA(anything),
      );
      await _untilEmpty(parent, maxMs: 3000);
    });

    test('全成 → ok 且临时目录同样清理干净', () async {
      final parent = await Directory.systemTemp.createTemp('savers_leak');
      addTearDown(() => parent.delete(recursive: true).ignore());
      final names = <String>[];
      final out = await saveLivpPairToGallery(
        await _makeLivp(),
        saveImage: (f) async {
          names.add(baseNameOf(f.path));
          return null;
        },
        saveVideo: (f) async {
          names.add(baseNameOf(f.path));
          return null;
        },
        unpackParent: parent,
      );
      expect(out.isOk, isTrue);
      expect(
        names,
        containsAll(['IMG_T.jpg', 'IMG_T.mov']),
        reason: '解包出的静态图+视频文件名直通存图件',
      );
      await _untilEmpty(parent, maxMs: 3000);
    });
  });

  group('saveLivePhotoWithFallback(T3:主路失败自动降级「双存」)', () {
    test('主路成功 → ok「已存入相册(实况照片)」,降级件零调用', () async {
      var fallbackCalls = 0;
      final out = await saveLivePhotoWithFallback(
        File('IMG_T.livp'),
        saveLivePhoto: () async {},
        fallbackPair: (f) async {
          fallbackCalls++;
          return const SinkOutcome.ok('不该到达');
        },
      );
      expect(out.isOk, isTrue);
      expect(out.detail, '已存入相册(实况照片)');
      expect(fallbackCalls, 0);
    });

    test('主路抛 PlatformException → 降级双成 ok:okOverride 含「非实况」'
        '(saveSummary 展示文案),原档透传降级件,降级落点保留在 detail', () async {
      final got = <File>[];
      final out = await saveLivePhotoWithFallback(
        File('IMG_T.livp'),
        saveLivePhoto: () async => throw PlatformException(
          code: 'PMManager (-1)',
          message: 'Failed to write Live Photo metadata to image file',
        ),
        fallbackPair: (f) async {
          got.add(f);
          return const SinkOutcome.ok('Pictures/IMG_T.jpg;Pictures/IMG_T.mov');
        },
      );
      expect(out.isOk, isTrue);
      expect(out.okOverride, contains('非实况'));
      expect(out.detail, 'Pictures/IMG_T.jpg;Pictures/IMG_T.mov');
      expect(got.single.path, 'IMG_T.livp');
    });

    test('降级半成 → fail 原样透传,文案如实分记(已入库的一半不丢)', () async {
      final out = await saveLivePhotoWithFallback(
        File('IMG_T.livp'),
        saveLivePhoto: () async => throw StateError('boom'),
        fallbackPair: (f) async => const SinkOutcome.fail(
          '静态图已入库(Pictures/IMG_T.jpg);实况短片失败:disk full',
        ),
      );
      expect(out.isOk, isFalse);
      expect(out.detail, contains('静态图已入库'));
      expect(out.detail, contains('实况短片失败'));
      expect(out.okOverride, isNull, reason: 'fail 路不适用 okOverride');
      expect(
        out.detail,
        isNot(contains('Failed to write Live Photo metadata')),
        reason: 'F6:fail 文案过 zhifyComposite 无英文残留(本例无模式,原文保留)',
      );
    });

    test('降级全败 → fail 原样透传,含中文原因(降级件产出 zhError 映射文案)', () async {
      final zh = zhError(
        PlatformException(
          code: 'PMManager (-1)',
          message: 'Failed to write Live Photo metadata to image file',
        ),
      );
      final out = await saveLivePhotoWithFallback(
        File('IMG_T.livp'),
        saveLivePhoto: () async => throw StateError('boom'),
        fallbackPair: (f) async => SinkOutcome.fail(zh),
      );
      expect(out.isOk, isFalse);
      expect(out.detail, '系统无法为静态帧写入实况标识');
      expect(
        out.detail,
        isNot(contains('Failed to write Live Photo metadata')),
        reason: 'F6:fail 文案无英文残留',
      );
    });

    test('降级半成且子错为已知英文模式 → fail 文案净化:分记保留、英文中文化(F6)', () async {
      final out = await saveLivePhotoWithFallback(
        File('IMG_T.livp'),
        saveLivePhoto: () async => throw StateError('boom'),
        fallbackPair: (f) async => const SinkOutcome.fail(
          '静态图已入库(Pictures/IMG_T.jpg);'
          '实况短片失败:PlatformException(PMManager (-1), '
          'Failed to write Live Photo metadata to video file)',
        ),
      );
      expect(out.isOk, isFalse);
      expect(out.detail, contains('静态图已入库(Pictures/IMG_T.jpg)'));
      expect(
        out.detail,
        contains('实况短片失败:PlatformException(PMManager (-1), 系统无法为视频写入实况标识)'),
      );
      expect(
        out.detail,
        isNot(contains('Failed to write Live Photo metadata')),
      );
    });
  });

  group('zhError(T4:已知 Live Photo 错误模式中文映射)', () {
    test('image 模式 → 「系统无法为静态帧写入实况标识」', () {
      expect(
        zhError(
          PlatformException(
            code: 'PMManager (-1)',
            message: 'Failed to write Live Photo metadata to image file',
          ),
        ),
        '系统无法为静态帧写入实况标识',
      );
    });

    test('video 模式 → 「系统无法为视频写入实况标识」', () {
      expect(
        zhError(
          PlatformException(
            code: 'PMManager (-1)',
            message: 'Failed to write Live Photo metadata to video file',
          ),
        ),
        '系统无法为视频写入实况标识',
      );
    });

    test('未知异常回落原文(\$e)', () {
      final e = PlatformException(code: 'PMManager (-1)', message: 'disk full');
      expect(zhError(e), '$e');
      expect(zhError(StateError('boom')), contains('boom'));
    });
  });

  group('zhifyComposite(复合文案中文净化:F6,子串替换保分记结构)', () {
    test('image 模式 → 子串替换为中文,其余原样', () {
      const raw =
          '静态图失败:PlatformException(PMManager (-1), '
          'Failed to write Live Photo metadata to image file)';
      expect(
        zhifyComposite(raw),
        '静态图失败:PlatformException(PMManager (-1), 系统无法为静态帧写入实况标识)',
      );
    });

    test('video 模式 → 子串替换为中文,其余原样', () {
      const raw =
          '实况短片失败:PlatformException(PMManager (-1), '
          'Failed to write Live Photo metadata to video file)';
      expect(
        zhifyComposite(raw),
        '实况短片失败:PlatformException(PMManager (-1), 系统无法为视频写入实况标识)',
      );
    });

    test('复合文案:「静态图已入库」分记保留,两处英文模式均中文化', () {
      const raw =
          '静态图已入库(Pictures/IMG_T.jpg);'
          '实况短片失败:PlatformException(PMManager (-1), '
          'Failed to write Live Photo metadata to video file);'
          '静态图失败:PlatformException(PMManager (-1), '
          'Failed to write Live Photo metadata to image file)';
      final out = zhifyComposite(raw);
      expect(out, contains('静态图已入库(Pictures/IMG_T.jpg)'));
      expect(
        out,
        contains('实况短片失败:PlatformException(PMManager (-1), 系统无法为视频写入实况标识)'),
      );
      expect(
        out,
        contains('静态图失败:PlatformException(PMManager (-1), 系统无法为静态帧写入实况标识)'),
      );
      expect(out, isNot(contains('Failed to write Live Photo metadata')));
      expect(out.split(';').length, 3, reason: '分号分记结构不动');
    });

    test('无模式命中 → 原文回落(含空串)', () {
      const raw = '静态图已入库(Pictures/x.jpg);实况短片失败:disk full';
      expect(zhifyComposite(raw), raw);
      expect(zhifyComposite(''), '');
    });
  });
}
