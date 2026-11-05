/// T1/T2 用例(qdev 包 C):livp 解包扩展名按内容魔数规范化 —— 外部行为视角。
///
/// 只依需求文档「接口定义」节,经公开 API 断言:
/// - sniffImageExtFromBytes / sniffVideoExtFromBytes(livp.dart 顶层纯函数,
///   同文档接口定义的顶层签名):字节头 → 规范扩展名(T1 表驱动);
/// - LivpService.unpackToFiles:落盘前按嗅探替换最后一段扩展名;断言落盘
///   文件名与内容字节一致(读写回验)(T2)。
/// zip 条目一律用真实魔数字节经 archive 包内存构造,零平台通道、不依赖
/// 真实 livp 样本。
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/services/livp.dart'
    show LivpService, sniffImageExtFromBytes, sniffVideoExtFromBytes;

const _ftypTag = <int>[0x66, 0x74, 0x79, 0x70]; // 'ftyp'

/// ISOBMFF 头紧 12 字节:[0..4) size 字段(值任意,契约只看 4..8 与 8..12)、
/// [4..8) 'ftyp'、[8..12) brand(brand 不足 4 字符右侧补空格,如 'qt  ')。
List<int> _isobmff(String brand) {
  final b = brand.codeUnits;
  if (b.isEmpty || b.length > 4) {
    throw ArgumentError('brand 须 1..4 字符:$brand');
  }
  return <int>[
    0x00,
    0x00,
    0x00,
    0x18,
    ..._ftypTag,
    for (var i = 0; i < 4; i++) i < b.length ? b[i] : 0x20,
  ];
}

/// JPEG 头(JFIF APP0,恰 12 字节;契约:FF D8 FF → jpeg)。
List<int> _jpegHead() => <int>[
  0xFF,
  0xD8,
  0xFF,
  0xE0,
  0x00,
  0x10,
  0x4A,
  0x46,
  0x49,
  0x46,
  0x00,
  0x01,
];

/// PNG 头(8 字节签名 + IHDR 长度,恰 12 字节;契约:89 50 4E 47 → png)。
List<int> _pngHead() => <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
];

/// zip 条目内容 = 头 + 4 字节尾料,凑满 16 字节:落盘嗅探按「条目前 16 字节」
/// 取头,≥16 的条目不依赖实现对短条目的截断方式(短条目行为由专门用例盯)。
List<int> _pad16(List<int> head) => [...head, 0x2E, 0xB4, 0x11, 0x9A];

/// zip 条目用 ISOBMFF box(16 字节):heic / 'qt  ' / isom / avif 等 brand。
List<int> _box(String brand) => _pad16(_isobmff(brand));

String _baseName(String path) => path.replaceAll('\\', '/').split('/').last;

/// 单静态帧条目(可选视频条目)zip 内存构造 → unpackToFiles;返回落盘产物。
Future<({File image, File? video, Directory tmp})> _unpack({
  required String imageName,
  required List<int> imageBytes,
  String? videoName,
  List<int>? videoBytes,
}) async {
  final arc = Archive()
    ..addFile(ArchiveFile(imageName, imageBytes.length, imageBytes));
  if (videoName != null) {
    final vb = videoBytes!;
    arc.addFile(ArchiveFile(videoName, vb.length, vb));
  }
  final livp = ZipEncoder().encode(arc)!;
  final tmp = await Directory.systemTemp.createTemp('livp_norm_t2');
  addTearDown(() => tmp.delete(recursive: true).ignore());
  final parts = await LivpService.unpackToFiles(livp, tmp);
  return (image: parts.image, video: parts.video, tmp: tmp);
}

void main() {
  group('sniffImageExtFromBytes(T1 魔数表驱动)', () {
    test("ftyp brand heic/heix/hevc → 'heic'", () {
      expect(sniffImageExtFromBytes(_isobmff('heic')), 'heic');
      expect(sniffImageExtFromBytes(_isobmff('heix')), 'heic');
      expect(sniffImageExtFromBytes(_isobmff('hevc')), 'heic');
    });

    test("ftyp brand mif1/msf1 → 'heif'(保持现状,不引入新风险)", () {
      expect(sniffImageExtFromBytes(_isobmff('mif1')), 'heif');
      expect(sniffImageExtFromBytes(_isobmff('msf1')), 'heif');
    });

    test('其他 brand(avif/isom/qt)→ null(F3:嗅探失败保持原名,零回归)', () {
      expect(
        sniffImageExtFromBytes(_isobmff('avif')),
        isNull,
        reason: 'F3:avif 等其他 ftyp brand 不动',
      );
      expect(sniffImageExtFromBytes(_isobmff('isom')), isNull);
      expect(
        sniffImageExtFromBytes(_isobmff('qt  ')),
        isNull,
        reason: 'qt 是视频 brand,图片嗅探不认',
      );
    });

    test('FF D8 FF → jpeg;89 50 4E 47 → png', () {
      expect(sniffImageExtFromBytes(_jpegHead()), 'jpeg');
      expect(sniffImageExtFromBytes(_pngHead()), 'png');
    });

    test('短字节(<12)→ null;全零 → null;恰 12 字节 ftyp 可识别(边界)', () {
      expect(
        sniffImageExtFromBytes(_isobmff('heic').sublist(0, 11)),
        isNull,
        reason: 'brand 需 bytes[8..12],缺 1 字节即不可识别',
      );
      expect(sniffImageExtFromBytes(List<int>.filled(16, 0)), isNull);
      expect(sniffImageExtFromBytes(List<int>.filled(11, 0)), isNull);
      expect(
        sniffImageExtFromBytes(_isobmff('heic')),
        'heic',
        reason: '恰 12 字节(ftyp+brand)须可识别',
      );
    });
  });

  group('sniffVideoExtFromBytes(T1)', () {
    test("ftyp brand 'qt  '(qt+两空格)→ 'mov'", () {
      expect(sniffVideoExtFromBytes(_isobmff('qt  ')), 'mov');
    });

    test('其余 brand(isom/mp42/heic)→ null(决策 4:mp4 内容改名无益,如实保留)', () {
      expect(sniffVideoExtFromBytes(_isobmff('isom')), isNull);
      expect(sniffVideoExtFromBytes(_isobmff('mp42')), isNull);
      expect(sniffVideoExtFromBytes(_isobmff('heic')), isNull);
    });

    test('jpeg/png 头与短字节 → null(图片字节/不足 12 字节不是视频)', () {
      expect(sniffVideoExtFromBytes(_jpegHead()), isNull);
      expect(sniffVideoExtFromBytes(_pngHead()), isNull);
      expect(sniffVideoExtFromBytes(_isobmff('qt  ').sublist(0, 11)), isNull);
    });
  });

  group('unpackToFiles 落盘扩展名规范化(T2;断言落盘名+内容字节读写回验)', () {
    test('heic 内容错名 IMG_0129.JPEG.heif → 落盘 IMG_0129.JPEG.heic'
        '(prod 实证族;双重扩展名只换最后一段,基名段不损)', () async {
      final r = await _unpack(
        imageName: 'IMG_0129.JPEG.heif',
        imageBytes: _box('heic'),
      );
      expect(_baseName(r.image.path), 'IMG_0129.JPEG.heic');
      expect(r.image.parent.path, r.tmp.path, reason: '产物落 tmpDir 内');
      expect(await r.image.readAsBytes(), _box('heic'), reason: '内容字节读写回验一致');
    });

    test('heic 内容单段错名 IMG_0129.heif → 落盘 IMG_0129.heic', () async {
      final r = await _unpack(
        imageName: 'IMG_0129.heif',
        imageBytes: _box('heic'),
      );
      expect(_baseName(r.image.path), 'IMG_0129.heic');
      expect(await r.image.readAsBytes(), _box('heic'));
    });

    test('正确命名幂等:IMG_4921.heic(heic 内容)不变(F1)', () async {
      final r = await _unpack(
        imageName: 'IMG_4921.heic',
        imageBytes: _box('heic'),
      );
      expect(_baseName(r.image.path), 'IMG_4921.heic');
      expect(await r.image.readAsBytes(), _box('heic'));
    });

    test('正确命名幂等:IMG_0531.JPG.jpeg(JPEG 内容)不变(F1)', () async {
      final jpeg = _pad16(_jpegHead());
      final r = await _unpack(imageName: 'IMG_0531.JPG.jpeg', imageBytes: jpeg);
      expect(_baseName(r.image.path), 'IMG_0531.JPG.jpeg');
      expect(await r.image.readAsBytes(), jpeg);
    });

    test('qt 内容错名 .mp4 → 落盘 .mov(F2:qt 无论 .mov/.mp4 一律落盘 .mov)', () async {
      final r = await _unpack(
        imageName: 'IMG_0129.JPEG.heic',
        imageBytes: _box('heic'),
        videoName: 'IMG_0129.mp4',
        videoBytes: _box('qt  '),
      );
      expect(r.video, isNotNull);
      expect(_baseName(r.video!.path), 'IMG_0129.mov');
      expect(await r.video!.readAsBytes(), _box('qt  '), reason: '内容字节读写回验一致');
    });

    test('qt 内容 .mov 名幂等不变(「一律 .mov」的不动侧)', () async {
      final r = await _unpack(
        imageName: 'IMG_4921.heic',
        imageBytes: _box('heic'),
        videoName: 'IMG_4921.mov',
        videoBytes: _box('qt  '),
      );
      expect(_baseName(r.video!.path), 'IMG_4921.mov');
      expect(await r.video!.readAsBytes(), _box('qt  '));
    });

    test('mp4(isom)内容保持原名(PhotoKit 拒 mp4 容器,改名无益,如实保留)', () async {
      final r = await _unpack(
        imageName: 'IMG_4921.heic',
        imageBytes: _box('heic'),
        videoName: 'IMG_4921.mp4',
        videoBytes: _box('isom'),
      );
      expect(
        _baseName(r.video!.path),
        'IMG_4921.mp4',
        reason: 'F2:mp4/isom 内容保持原名',
      );
      expect(await r.video!.readAsBytes(), _box('isom'));
    });

    test('avif brand 不动:嗅探失败 → 原名落盘(F3 零回归)', () async {
      final r = await _unpack(
        imageName: 'IMG_0129.heif',
        imageBytes: _box('avif'),
      );
      expect(_baseName(r.image.path), 'IMG_0129.heif');
      expect(await r.image.readAsBytes(), _box('avif'));
    });

    test('PNG:错名 .heic 纠为 .png;正确 .png 幂等(规则:嗅探结果 != 当前小写扩展名才换)', () async {
      final png = _pad16(_pngHead());
      final fixed = await _unpack(imageName: 'IMG_0007.heic', imageBytes: png);
      expect(_baseName(fixed.image.path), 'IMG_0007.png');
      expect(await fixed.image.readAsBytes(), png);
      final idem = await _unpack(imageName: 'IMG_0008.png', imageBytes: png);
      expect(_baseName(idem.image.path), 'IMG_0008.png');
      expect(await idem.image.readAsBytes(), png);
    });

    test('短字节条目(8 字节,<12)→ 原名落盘且字节原样(嗅探失败零回归)', () async {
      // 有 'ftyp' 标记、缺 brand 的 8 字节残条
      const short = <int>[0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70];
      final r = await _unpack(imageName: 'IMG_0009.heic', imageBytes: short);
      expect(_baseName(r.image.path), 'IMG_0009.heic');
      expect(await r.image.readAsBytes(), short);
    });

    test('无视频条目的退化 livp → video 为 null 不炸,静态图照常规范化', () async {
      final r = await _unpack(
        imageName: 'IMG_0129.JPEG.heif',
        imageBytes: _box('heic'),
      );
      expect(r.video, isNull);
      expect(_baseName(r.image.path), 'IMG_0129.JPEG.heic');
    });
  });
}
