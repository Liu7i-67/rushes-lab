/// B0② 落盘路由纯函数单测(§6.1 平台×类型矩阵骨架):
/// 分类(filename/contentType)与图库路策略、Downloads 路适用性。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/me/b0_sink_plan.dart';

void main() {
  group('classifyAsset', () {
    test('livp 按扩展名识别(大小写不敏感)', () {
      expect(
          classifyAsset(filename: 'IMG_0001.livp'), B0AssetKind.livp);
      expect(classifyAsset(filename: 'A.LIVP', contentType: 'application/zip'),
          B0AssetKind.livp);
    });
    test('图片:content_type 优先,扩展名兜底', () {
      expect(classifyAsset(filename: 'a.bin', contentType: 'image/jpeg'),
          B0AssetKind.image);
      expect(classifyAsset(filename: 'IMG_1.HEIC'), B0AssetKind.image);
      expect(classifyAsset(filename: 'pic.png'), B0AssetKind.image);
    });
    test('视频:content_type 优先,扩展名兜底', () {
      expect(classifyAsset(filename: 'v.bin', contentType: 'video/mp4'),
          B0AssetKind.video);
      expect(classifyAsset(filename: 'clip.mov'), B0AssetKind.video);
    });
    test('其他(pdf 等)归 other', () {
      expect(classifyAsset(filename: 'doc.pdf', contentType: 'application/pdf'),
          B0AssetKind.other);
      expect(classifyAsset(filename: 'noext'), B0AssetKind.other);
    });
  });

  group('galleryStrategyOf(§6.1 Android 列)', () {
    test('livp → 解包后静态图+视频分别存', () {
      expect(galleryStrategyOf(B0AssetKind.livp),
          B0GalleryStrategy.livpUnpackPair);
    });
    test('图片 → saveImage;视频 → saveVideo', () {
      expect(galleryStrategyOf(B0AssetKind.image),
          B0GalleryStrategy.saveImage);
      expect(galleryStrategyOf(B0AssetKind.video),
          B0GalleryStrategy.saveVideo);
    });
    test('其他类型不进图库(PoC 跳过,仅走 Downloads 路)', () {
      expect(galleryStrategyOf(B0AssetKind.other), B0GalleryStrategy.skip);
    });
  });

  test('Downloads 路:PoC 口径一律写原档(livp 原档含在内)', () {
    for (final kind in B0AssetKind.values) {
      expect(downloadsCopyApplies(kind), isTrue, reason: '$kind');
    }
  });

  test('b0BaseName:正斜杠/反斜杠/混合分隔符都只取末段文件名', () {
    expect(b0BaseName('/data/user/0/pkg/cache/b0_poc_IMG.livp'), 'b0_poc_IMG.livp');
    expect(b0BaseName(r'C:\Temp\b0_route_x\IMG_0001.jpg'), 'IMG_0001.jpg');
    expect(b0BaseName(r'C:\Temp\b0_route_x/IMG_0001.jpg'), 'IMG_0001.jpg',
        reason: '混合分隔符:单分隔切会把目录名并进文件名(真机竞态修复伴生回归)');
    expect(b0BaseName('plain.bin'), 'plain.bin');
  });
}
