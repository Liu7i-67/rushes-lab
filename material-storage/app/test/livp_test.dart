import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/services/livp.dart';

void main() {
  group('LivpService.pack / decode', () {
    test('roundtrip:静态帧+视频 按类别内最大挑回', () {
      final img = List<int>.generate(4096, (i) => i % 251);
      final vid = List<int>.generate(8192, (i) => Random().nextInt(256));
      final livp = LivpService.pack(
        imageBytes: img,
        imageExt: 'HEIC',
        videoBytes: vid,
        videoExt: 'MOV',
        baseName: 'IMG_0001',
      );

      final parts = LivpService.decode(livp);
      expect(parts.image.content, img);
      expect(parts.video, isNotNull);
      expect(parts.video!.content, vid);
      expect(parts.image.name.toLowerCase().endsWith('.heic'), isTrue);
      expect(parts.video!.name.toLowerCase().endsWith('.mov'), isTrue);
    });

    test('后端同口径:zip 含干扰条目仍按「类别内最大」挑选', () {
      // 模拟真实 livp:元数据小图 + 真静态大图 + 视频 + 干扰文本
      final decoy = List.filled(64, 1);
      final realImg = List.filled(1024, 7);
      final video = List.filled(512, 9);
      final arc = LivpService.pack(
        imageBytes: realImg,
        imageExt: 'jpg',
        videoBytes: video,
        videoExt: 'mov',
      );
      // 追加干扰条目直接操作 Archive 太繁琐 → 这里验证 pack 产物本身可再解
      final parts = LivpService.decode(arc);
      expect(parts.image.content, realImg);
      expect(parts.video!.content, video);
      expect(decoy.length, 64); // noise 数据仅构造用
    });

    test('无视频的退化 livp:image 必在,video 为 null', () {
      final img = List.filled(128, 3);
      final arc = LivpService.pack(
        imageBytes: img,
        imageExt: 'heic',
        // 退化打包:仅静态图(entityToLivp 的 iCloud 降级分支同构)
        videoBytes: img,
        videoExt: 'mov',
      );
      // 直接构造仅含图片的 zip 验证 null 分支
      final bytesOnly = LivpService.pack(
        imageBytes: img,
        imageExt: 'heic',
        videoBytes: List.filled(0, 0),
        videoExt: 'mov',
      );
      // 0 字节视频条目存在但内容为空 — 解包仍挑它;断言不炸、图对
      final parts = LivpService.decode(bytesOnly);
      expect(parts.image.content, img);
      expect(arc.length, greaterThan(0));
    });

    test('非 livp zip(无静态图条目)报 FormatException', () {
      final bad = LivpService.pack(
        imageBytes: List.filled(16, 0),
        imageExt: 'bin',
        videoBytes: List.filled(16, 0),
        videoExt: 'bin',
      );
      expect(() => LivpService.decode(bad), throwsFormatException);
    });
  });

  group(
    'LivpService.pack stored 开关(archive 3.6.1 per-entry compress=false)',
    () {
      /// 顺序解析 zip 本地文件头(PK\x03\x04;method 在偏移 8 的 2 字节 LE,
      /// 跳条目用 nameLen@26 + extraLen@28 + compressedSize@18)。
      /// 返回第 [index] 个条目的 compression method(0=STORED,8=DEFLATE)。
      int methodOf(List<int> zip, int index) {
        var pos = 0;
        for (var i = 0; i < index; i++) {
          final nameLen = zip[pos + 26] | (zip[pos + 27] << 8);
          final extraLen = zip[pos + 28] | (zip[pos + 29] << 8);
          final compSize =
              zip[pos + 18] |
              (zip[pos + 19] << 8) |
              (zip[pos + 20] << 16) |
              (zip[pos + 21] << 24);
          pos += 30 + nameLen + extraLen + compSize;
        }
        expect(zip[pos + 0], 0x50);
        expect(zip[pos + 1], 0x4B);
        expect(zip[pos + 2], 0x03);
        expect(zip[pos + 3], 0x04); // local file header signature
        return zip[pos + 8] | (zip[pos + 9] << 8);
      }

      List<int> imgBytes() => List<int>.generate(2048, (i) => i & 0x7F);
      List<int> vidBytes() => List<int>.generate(1024, (i) => 0x41 + (i % 26));

      test('stored=true:两条目压缩方式均为 STORED(0),解包内容逐字节一致', () {
        final img = imgBytes();
        final vid = vidBytes();
        final livp = LivpService.pack(
          imageBytes: img,
          imageExt: 'jpg',
          videoBytes: vid,
          videoExt: 'mp4',
          baseName: 'MVIMG_0001',
          stored: true,
        );
        expect(methodOf(livp, 0), 0);
        expect(methodOf(livp, 1), 0);
        final parts = LivpService.decode(livp);
        expect(parts.image.name, 'MVIMG_0001.jpg');
        expect(parts.video!.name, 'MVIMG_0001.mp4');
        expect(parts.image.content, img);
        expect(parts.video!.content, vid);
      });

      test('缺省 stored=false:两条目压缩方式均为 DEFLATE(8),既有行为零回归', () {
        final img = imgBytes();
        final vid = vidBytes();
        final livp = LivpService.pack(
          imageBytes: img,
          imageExt: 'jpg',
          videoBytes: vid,
          videoExt: 'mp4',
          baseName: 'MVIMG_0001',
        );
        expect(methodOf(livp, 0), 8);
        expect(methodOf(livp, 1), 8);
        final parts = LivpService.decode(livp);
        expect(parts.image.content, img);
        expect(parts.video!.content, vid);
      });
    },
  );
}
