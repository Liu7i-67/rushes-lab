import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/services/livp.dart';

void main() {
  test('baseNameOf:空标题兜底,正常标题去扩展名(空串曾拼出 .livp 空基名点文件)', () {
    expect(LivpService.baseNameOf(null, 'IMG_fb'), 'IMG_fb');
    expect(LivpService.baseNameOf('', 'IMG_fb'), 'IMG_fb');
    expect(LivpService.baseNameOf('   ', 'IMG_fb'), 'IMG_fb');
    // '.' / '..' 这类去扩展名后为空的也兜底
    expect(LivpService.baseNameOf('.', 'IMG_fb'), 'IMG_fb');
    expect(LivpService.baseNameOf('..jpg', 'IMG_fb'), 'IMG_fb');
    // 正常:带扩展名去扩展名,不带则原样,首尾空白不带入
    expect(LivpService.baseNameOf('IMG_1234.HEIC', 'IMG_fb'), 'IMG_1234');
    expect(LivpService.baseNameOf('IMG_1234', 'IMG_fb'), 'IMG_1234');
    expect(LivpService.baseNameOf(' IMG_5.jpg ', 'IMG_fb'), 'IMG_5');
    // 分隔符净化:iOS PHAsset localIdentifier 形如 "UUID/L0/001" 含 '/',
    // 兜底名与标题两条路都不得带 '/'/'\'(create_upload 路径校验 400 之前先自净)
    expect(LivpService.baseNameOf('', 'IMG_UUID/L0/001'), 'IMG_UUID-L0-001');
    expect(LivpService.baseNameOf('a/b.jpg', 'IMG_fb'), 'a-b');
    expect(LivpService.baseNameOf(r'c\d.jpg', 'IMG_fb'), 'c-d');
  });

  test('兜底基名打包出的条目带主名,不再是 .jpg/.mov 点文件(后端 pathlib 判不出)', () {
    final base = LivpService.baseNameOf('', 'IMG_fb');
    final z = LivpService.pack(
      imageBytes: [1, 2],
      imageExt: 'jpg',
      videoBytes: [3],
      videoExt: 'mov',
      baseName: base,
    );
    final parts = LivpService.decode(z);
    expect(parts.image.name, 'IMG_fb.jpg');
    expect(parts.video!.name, 'IMG_fb.mov');
  });
}
