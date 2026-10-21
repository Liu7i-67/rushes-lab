/// B2 测试修复单测锁(P1-1 + P2-1/P2-6 纯逻辑部分;B4 起拆自 preview_plan.dart
/// /preview_text_load.dart)+ B4 新增 playingLive 维度(livp「查看照片」回切
/// 显示静态缩略图而非暂停帧,B2 遗留清偿):
/// - P1-1:previewBodyPlan 对 video 类在控制器未就绪时恒 loading,绝不落 image
///   分支(老路径把视频 presigned URL 塞 Image.network → 起播期误显
///   「图片解码失败」卡 + 多余图片式拉流);
/// - playingLive:livp videoReady 且回静态 → image(player 保活 Offstage 续播);
/// - P2-1:videoClock 时长文本;P2-6:thumbFailText 两态文案。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/preview_kind.dart';
import 'package:ms_app/features/preview/preview_plan.dart';
import 'package:ms_app/features/preview/preview_text_load.dart';

PreviewBody plan(
  PreviewKind kind, {
  bool videoReady = false,
  bool hasFail = false,
  bool hasUrl = false,
  bool playingLive = true,
}) =>
    previewBodyPlan(
      kind: kind,
      videoReady: videoReady,
      hasFail: hasFail,
      hasUrl: hasUrl,
      playingLive: playingLive,
    );

void main() {
  group('previewBodyPlan — P1-1 锁:video 起播期绝不走图片渲染', () {
    test('video + URL 已取得 + 控制器未就绪 → loading(不产生 Image 分支)', () {
      expect(plan(PreviewKind.video, hasUrl: true), PreviewBody.loading);
    });

    test('video 全输入矩阵:未就绪恒 loading,就绪才 player,任何组合不落 image', () {
      for (final hasUrl in [false, true]) {
        for (final hasFail in [false, true]) {
          expect(
            plan(PreviewKind.video, hasUrl: hasUrl, hasFail: hasFail),
            hasFail ? PreviewBody.block : PreviewBody.loading,
            reason: 'video 未就绪(hasUrl=$hasUrl, hasFail=$hasFail)不得落 image',
          );
          expect(
            plan(PreviewKind.video,
                videoReady: true, hasUrl: hasUrl, hasFail: hasFail),
            hasFail ? PreviewBody.block : PreviewBody.player,
          );
        }
      }
    });
  });

  group('previewBodyPlan — playingLive 维度(B2 遗留:查看照片显缩略图)', () {
    test('livp 就绪在播 → player;回切(playingLive=false)→ image 静态缩略图',
        () {
      expect(plan(PreviewKind.livp, videoReady: true, hasUrl: true),
          PreviewBody.player);
      expect(
          plan(PreviewKind.livp,
              videoReady: true, hasUrl: true, playingLive: false),
          PreviewBody.image,
          reason: '查看照片=静态缩略图,而非暂停帧(控制器保活便于续播)');
    });

    test('livp 未就绪:playingLive 不影响(image 兜底/loading),起播圈由视图层叠',
        () {
      expect(plan(PreviewKind.livp, hasUrl: true), PreviewBody.image);
      expect(plan(PreviewKind.livp, hasUrl: true, playingLive: false),
          PreviewBody.image);
      expect(plan(PreviewKind.livp), PreviewBody.loading);
    });

    test('video 类不受 playingLive 影响(就绪恒 player)', () {
      expect(
          plan(PreviewKind.video, videoReady: true, hasUrl: true,
              playingLive: false),
          PreviewBody.player);
    });
  });

  group('previewBodyPlan — 八类映射', () {
    test('fail 优先:一切类型有失败即色块', () {
      for (final kind in PreviewKind.values) {
        expect(plan(kind, hasFail: true, videoReady: true, hasUrl: true),
            PreviewBody.block);
      }
    });

    test('image/heic:URL 在即图,不在则加载态', () {
      expect(plan(PreviewKind.image, hasUrl: true), PreviewBody.image);
      expect(plan(PreviewKind.image), PreviewBody.loading);
      expect(plan(PreviewKind.heic, hasUrl: true), PreviewBody.image);
      expect(plan(PreviewKind.heic), PreviewBody.loading);
    });

    test('md/text/pdf 直接映射;unsupported 恒色块', () {
      expect(plan(PreviewKind.markdown), PreviewBody.markdown);
      expect(plan(PreviewKind.text), PreviewBody.text);
      expect(plan(PreviewKind.pdf), PreviewBody.pdf);
      expect(plan(PreviewKind.unsupported, videoReady: true, hasUrl: true),
          PreviewBody.block);
    });
  });

  group('videoClock(P2-1 时长文本)', () {
    test('m:ss 常规段;满一小时进 h:mm:ss', () {
      expect(videoClock(Duration.zero), '0:00');
      expect(videoClock(const Duration(seconds: 5)), '0:05');
      expect(videoClock(const Duration(seconds: 65)), '1:05');
      expect(videoClock(const Duration(minutes: 9, seconds: 59)), '9:59');
      expect(videoClock(const Duration(hours: 1)), '1:00:00');
      expect(videoClock(const Duration(hours: 1, minutes: 1, seconds: 1)),
          '1:01:01');
    });
  });

  group('thumbFailText(P2-6 两态文案)', () {
    test('无 thumbnail_failed 标记 → 生成中,引导稍后刷新', () {
      expect(thumbFailText(const {}), '预览图还在生成,请稍后刷新重试');
      expect(thumbFailText(const {'thumbnail_key': 'k'}), '预览图还在生成,请稍后刷新重试');
      expect(thumbFailText(const {'thumbnail_failed': ''}), '预览图还在生成,请稍后刷新重试');
    });

    test('有 thumbnail_failed 标记 → 明确失败,原因透出', () {
      final t = thumbFailText(const {'thumbnail_failed': 'RuntimeError'});
      expect(t, contains('生成失败'));
      expect(t, contains('RuntimeError'));
      expect(t, isNot(contains('稍后刷新'))); // 不再误导重试(web W1-B 同口径)
    });
  });

  group('kMaxInlineTextBytes(P2-8 预检阈值,现居 preview_text_load)', () {
    test('10MB', () {
      expect(kMaxInlineTextBytes, 10 * 1024 * 1024);
    });
  });
}
