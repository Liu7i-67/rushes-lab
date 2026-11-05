/// T3/T4/T5 用例(qdev 包 C):实况保存降级兜底 —— 注入视角。
///
/// 全部注入假闭包,零平台通道、零磁盘 IO:
/// - saveLivePhotoWithFallback(纯函数编排,C3):主路成功不降级 / 主路抛
///   PlatformException → 降级双成(ok+okOverride 注明「非实况」)/ 降级半成
///   (fail 如实分记)/ 降级全败(fail,英文原始错误过中文映射)(T3);
/// - zhError(文案映射,C4):image/video 两模式中文、未知异常回落原文(T4);
/// - saveSummary:SinkOutcome.okOverride 优先、缺省回落 route.okText(C5/T5)。
library;

import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/services/download_savers.dart'
    show saveLivePhotoWithFallback, zhError;
import 'package:ms_app/services/media_save.dart'
    show GalleryAction, RouteOutcome, SaveRoute, SinkOutcome, saveSummary;

/// 主路实证错误(photo_manager darwin saveLivePhoto 把 heic 内容写进 heif
/// 容器注入配对标识时 CGImageDestinationFinalize 失败,2026-11-05 prod 取证)。
/// 注:本环境 Flutter 3.47 的 PlatformException 构造非 const(与既有
/// download_savers_test 非 const 构造口径一致)。
final _livePhotoErr = PlatformException(
  code: '-1',
  message: 'Failed to write Live Photo metadata to image file',
);

void main() {
  group('saveLivePhotoWithFallback(实况保存降级编排,T3)', () {
    test('主路成功 → ok(文案含实况),不触发降级(F5 现状不变)', () async {
      var fallbackCalls = 0;
      final file = File('IMG_0129.livp');
      final out = await saveLivePhotoWithFallback(
        file,
        saveLivePhoto: () async {},
        fallbackPair: (f) async {
          fallbackCalls++;
          return const SinkOutcome.ok('不该到达');
        },
      );
      expect(out.isOk, isTrue);
      expect(fallbackCalls, 0, reason: '主路成功不得触发降级');
      expect(out.detail, contains('实况'), reason: 'F5:主路成功文案「已存入相册(实况照片)」现状不变');
    });

    test('主路抛 Live Photo 元数据错 → 降级双成 → ok,okOverride 注明「非实况」', () async {
      final file = File('IMG_0129.livp');
      final got = <File>[];
      final out = await saveLivePhotoWithFallback(
        file,
        saveLivePhoto: () async => throw _livePhotoErr,
        fallbackPair: (f) async {
          got.add(f);
          return const SinkOutcome.ok(
            'Pictures/IMG_0129.jpg;Pictures/IMG_0129.mov',
          );
        },
      );
      expect(out.isOk, isTrue);
      expect(got, [file], reason: '降级收原档(生产=saveLivpPairToGallery 注入)');
      expect(out.okOverride, isNotNull, reason: 'F5:降级双成成功文案须注明非实况');
      expect(out.okOverride!, contains('非实况'));
      expect(
        out.detail,
        contains('IMG_0129.mov'),
        reason: 'detail 语义不变:透传降级落点',
      );
    });

    test('主路抛错 → 降级半成 → fail 如实分记(已入库一半不吞)', () async {
      final out = await saveLivePhotoWithFallback(
        File('IMG_0129.livp'),
        saveLivePhoto: () async => throw _livePhotoErr,
        fallbackPair: (f) async => const SinkOutcome.fail(
          '静态图已入库(Pictures/IMG_0129.jpg);视频存入失败:StateError(vid boom)',
        ),
      );
      expect(out.isOk, isFalse);
      expect(out.detail, contains('静态图已入库'), reason: 'F5:文案如实分记,已入库的一半让用户看得到');
      expect(out.detail, contains('视频存入失败'));
    });

    test('主路抛错 → 降级全败 → fail,英文原始错误过中文映射(不直透)', () async {
      final out = await saveLivePhotoWithFallback(
        File('IMG_0129.livp'),
        saveLivePhoto: () async => throw _livePhotoErr,
        fallbackPair: (f) async => const SinkOutcome.fail(
          '静态图失败:PlatformException(-1, Failed to write Live Photo metadata to image file);'
          '实况短片失败:PlatformException(-1, Failed to write Live Photo metadata to video file)',
        ),
      );
      expect(out.isOk, isFalse, reason: 'F5:降级全败 → fail(share 兜底路照常触发)');
      expect(
        out.detail.contains('Failed to write Live Photo metadata'),
        isFalse,
        reason: 'F6:降级与失败文案统一过 zhError,不向用户直透英文异常',
      );
      expect(out.detail, contains('失败'), reason: '如实汇总两半失败');
    });
  });

  group('zhError(已知错误模式中文映射,T4/F6)', () {
    test('image 模式 → 中文(不再含原始英文)', () {
      final zh = zhError(
        PlatformException(
          code: '-1',
          message: 'Failed to write Live Photo metadata to image file',
        ),
      );
      expect(zh.contains('Failed to write'), isFalse);
      expect(
        RegExp('[\u4e00-\u9fa5]').hasMatch(zh),
        isTrue,
        reason: '映射结果须为中文(具体措辞文档未钉,不锁字面)',
      );
    });

    test('video 模式 → 中文(不再含原始英文)', () {
      final zh = zhError(
        PlatformException(
          code: '-1',
          message: 'Failed to write Live Photo metadata to video file',
        ),
      );
      expect(zh.contains('Failed to write'), isFalse);
      expect(RegExp('[\u4e00-\u9fa5]').hasMatch(zh), isTrue);
    });

    test('未知 PlatformException → 回落原文(message 保留)', () {
      expect(
        zhError(PlatformException(code: 'E9', message: 'boom unknown')),
        contains('boom unknown'),
      );
    });

    test('非 PlatformException 异常 → 回落原文(F6「其他异常回落原文」)', () {
      expect(zhError(StateError('raw boom')), contains('raw boom'));
    });
  });

  group('saveSummary 的 okOverride(C5/T5)', () {
    test('有 okOverride → 成功展示文案优先用 override(detail 不混入)', () {
      const route = SaveRoute.gallery(GalleryAction.saveLivePhoto);
      final outcomes = [
        RouteOutcome(
          route: route,
          outcome: const SinkOutcome.ok(
            'Pictures/IMG_0129.jpg;Pictures/IMG_0129.mov',
            okOverride: '已存入相册(非实况:静态图与视频分别入库)',
          ),
        ),
      ];
      expect(saveSummary(outcomes), '已存入相册(非实况:静态图与视频分别入库)');
    });

    test('无 okOverride → 行为与既有断言一致:用 route.okText(回归)', () {
      const route = SaveRoute.gallery(GalleryAction.saveLivePhoto);
      final outcomes = [
        RouteOutcome(
          route: route,
          outcome: const SinkOutcome.ok('Pictures/x.jpg'),
        ),
      ];
      expect(saveSummary(outcomes), '已存入相册');
    });

    test('混合:override 路 + 普通路顿号连接(其余行为不变)', () {
      const live = SaveRoute.gallery(GalleryAction.saveLivePhoto);
      const downloads = SaveRoute.downloads();
      final outcomes = [
        RouteOutcome(
          route: live,
          outcome: const SinkOutcome.ok('p', okOverride: '已存入相册(非实况)'),
        ),
        const RouteOutcome(route: downloads, outcome: SinkOutcome.ok('y')),
      ];
      expect(saveSummary(outcomes), '已存入相册(非实况)、已存入 Download/浣花视界');
    });
  });
}
