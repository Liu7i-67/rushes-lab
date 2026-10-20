/// 测试功能点 1(B2):detectKind 移动版类型判定 — 八类全覆盖 + 扩展名优先 +
/// 点文件 endswith 钉子(与 web AssetPreviewModal.detectKind 对齐)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/preview_kind.dart';

PreviewKind k(String filename, [String? ct]) =>
    detectKind(filename: filename, contentType: ct);

void main() {
  group('detectKind 八类', () {
    test('livp:扩展名优先,content_type 是浏览器猜的 zip/octet-stream 也无碍', () {
      expect(k('IMG_0001.livp', 'application/octet-stream'),
          PreviewKind.livp);
      expect(k('IMG_0001.LIVP'), PreviewKind.livp); // 大小写不敏感
    });

    test('markdown:.md 或 text/markdown', () {
      expect(k('说明.md', 'text/plain'), PreviewKind.markdown); // 扩展名优先
      expect(k('readme', 'text/markdown'), PreviewKind.markdown);
    });

    test('text:.txt 或 text/plain;text/* 兜底(csv/log/json)', () {
      expect(k('备注.txt'), PreviewKind.text);
      expect(k('file', 'text/plain'), PreviewKind.text);
      expect(k('data.csv', 'text/csv'), PreviewKind.text);
    });

    test('pdf:.pdf 或 application/pdf', () {
      expect(k('报告.pdf', 'application/octet-stream'), PreviewKind.pdf);
      expect(k('doc', 'application/pdf'), PreviewKind.pdf);
    });

    test('heic/heif:先于 image/* 前缀判(否则落 image 塞原图,web 同钉子)', () {
      expect(k('IMG.heic', 'image/heic'), PreviewKind.heic);
      expect(k('IMG.heif'), PreviewKind.heic); // heif 同归 heic 类(走缩略图)
      expect(k('photo', 'image/heif'), PreviewKind.heic);
      expect(k('IMG_0001.heic', 'image/quicktime'), PreviewKind.heic);
    });

    test('image:content_type 前缀 / 扩展名白名单', () {
      expect(k('shot.png'), PreviewKind.image);
      expect(k('shot.jpeg'), PreviewKind.image);
      expect(k('anim.gif', 'application/octet-stream'), PreviewKind.image);
      expect(k('pic', 'image/png'), PreviewKind.image);
      expect(k('A.PNG'), PreviewKind.image); // 大写扩展名
    });

    test('video:扩展名 / video/* 前缀', () {
      expect(k('clip.mp4'), PreviewKind.video);
      expect(k('iPhone.mov'), PreviewKind.video);
      expect(k('a.webm'), PreviewKind.video);
      expect(k('v.m4v'), PreviewKind.video);
      expect(k('v', 'video/mp4'), PreviewKind.video);
    });

    test('unsupported:无扩展名/未知扩展名/双扩展名不误判', () {
      expect(k('README', ''), PreviewKind.unsupported);
      expect(k('archive.tar.gz', 'application/octet-stream'),
          PreviewKind.unsupported);
      expect(k('data.bin', 'application/octet-stream'),
          PreviewKind.unsupported);
    });
  });

  group('点文件钉子(endswith,勿用 suffix 截取)', () {
    test('以点开头的隐藏文件名按扩展名语义判定', () {
      expect(k('.png'), PreviewKind.image); // '.png'.endsWith('.png')
      expect(k('.md'), PreviewKind.markdown);
      expect(k('.livp'), PreviewKind.livp);
    });
    test('以点结尾 = 无扩展名 → unsupported', () {
      expect(k('foo.', 'image/png'), PreviewKind.image); // ct 兜底仍在
      expect(k('foo.'), PreviewKind.unsupported);
    });
    test('content_type 为 null/空串不炸', () {
      expect(k('a.png', null), PreviewKind.image);
      expect(k('a', null), PreviewKind.unsupported);
    });
  });

  // 注:isPreviewable 用例随 API 一起删除(B2 修复 P2-7,零消费不留无主 API)。

  test('不可解码 image 白名单(svg/avif/ico)= 预览走缩略图降级口径', () {
    expect(kUnDecodableImageExts, ['.svg', '.avif', '.ico']);
    // 判定仍是 image(可预览),只是原图解码不了
    expect(k('logo.svg'), PreviewKind.image);
    expect(k('img.avif'), PreviewKind.image);
    expect(k('favicon.ico'), PreviewKind.image);
  });
}
