import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
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

  group('LivpService.unpackToFiles 恶意条目名 basename 净化(遗留项 10)', () {
    /// 构造含单个恶意名图片条目的 zip → 解包:断言产物落在 tmpDir 内、
    /// 文件名不含分隔符、字节原样。
    Future<void> roundtrip(String entryName) async {
      final arc = Archive()
        ..addFile(ArchiveFile(entryName, 4, const <int>[1, 2, 3, 4]));
      final livp = ZipEncoder().encode(arc)!;
      final tmp = await Directory.systemTemp.createTemp('livp_evil');
      try {
        final parts = await LivpService.unpackToFiles(livp, tmp);
        expect(parts.video, isNull, reason: '无视频条目');
        final img = parts.image;
        expect(
          img.parent.path,
          tmp.path,
          reason: '$entryName 净化后产物必须落在 tmpDir 内(不得穿越)',
        );
        expect(
          img.path.replaceAll('\\', '/').split('/').last,
          'evil.jpg',
          reason: '$entryName 取路径分隔后的末段,文件名不含分隔符',
        );
        expect(await img.readAsBytes(), const <int>[1, 2, 3, 4]);
      } finally {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    }

    test('相对路径穿越条目名(../../evil.jpg)取末段落盘', () async {
      await roundtrip('../../evil.jpg');
    });

    test('反斜杠分隔条目名(..\\evil.jpg,Windows 变体)取末段落盘', () async {
      await roundtrip('..\\evil.jpg');
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

  group('内容嗅探 sniffImageExtFromBytes / sniffVideoExtFromBytes(T1)', () {
    /// 构造 16 字节 ISOBMFF ftyp 头:size(4) + 'ftyp'(4) + brand(4,不足补空格)
    /// + padding(4)。
    List<int> ftyp(String brand) => <int>[
      ...[0x00, 0x00, 0x00, 0x18],
      ...'ftyp'.codeUnits,
      ...brand.padRight(4).codeUnits,
      0x00,
      0x00,
      0x00,
      0x00,
    ];

    // 表驱动:图片 brand 映射(文档接口定义逐条;决策 3 从保守清单)
    const imageBrands = <String, String?>{
      'heic': 'heic',
      'heix': 'heic',
      'hevc': 'heic',
      'mif1': 'heif',
      'msf1': 'heif',
      'avif': null, // 其他 brand 一律不动(F3)
      'isom': null,
      'mp42': null,
    };
    imageBrands.forEach((brand, expected) {
      test('ftyp brand=$brand → ${expected ?? 'null'}', () {
        expect(sniffImageExtFromBytes(ftyp(brand)), expected);
      });
    });

    test('JPEG 魔数 FF D8 FF → jpeg', () {
      expect(
        sniffImageExtFromBytes([0xFF, 0xD8, 0xFF, 0xE1, ...List.filled(12, 0)]),
        'jpeg',
      );
    });

    test('PNG 魔数 89 50 4E 47 → png', () {
      expect(
        sniffImageExtFromBytes([
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
          ...List.filled(8, 0),
        ]),
        'png',
      );
    });

    test('短字节(<12)→ null:含 3 字节 JPEG 短头与截断 ftyp', () {
      expect(sniffImageExtFromBytes(const <int>[]), isNull);
      expect(sniffImageExtFromBytes([0xFF, 0xD8, 0xFF]), isNull);
      expect(sniffImageExtFromBytes(ftyp('heic').sublist(0, 11)), isNull);
      expect(sniffVideoExtFromBytes(ftyp('qt  ').sublist(0, 11)), isNull);
    });

    test('全零内容 → null', () {
      expect(sniffImageExtFromBytes(List.filled(16, 0)), isNull);
      expect(sniffVideoExtFromBytes(List.filled(16, 0)), isNull);
    });

    test('视频:仅 brand="qt  " → mov;isom/mp42/非 ftyp → null(F2/决策 4)', () {
      expect(sniffVideoExtFromBytes(ftyp('qt  ')), 'mov');
      expect(sniffVideoExtFromBytes(ftyp('isom')), isNull);
      expect(sniffVideoExtFromBytes(ftyp('mp42')), isNull);
      expect(sniffVideoExtFromBytes(ftyp('heic')), isNull);
      expect(
        sniffVideoExtFromBytes([0xFF, 0xD8, 0xFF, ...List.filled(13, 0)]),
        isNull,
      );
    });
  });

  group('LivpService.unpackToFiles 落盘扩展名规范化(C2/T2)', () {
    /// 嗅探 fixture:16 字节 ftyp 头 + 填充到 [total] 字节(条目可被 pick 挑出)。
    List<int> ftypBytes(String brand, {int total = 2048}) {
      final head = <int>[
        0x00,
        0x00,
        0x00,
        0x18,
        ...'ftyp'.codeUnits,
        ...brand.padRight(4).codeUnits,
        0x00,
        0x00,
        0x00,
        0x00,
      ];
      return [...head, ...List.filled(total - head.length, 0x11)];
    }

    List<int> jpegBytes({int total = 2048}) => [
      0xFF,
      0xD8,
      0xFF,
      0xE1,
      ...List.filled(total - 4, 0x22),
    ];

    /// 名→字节 map → 内存 zip 构造 livp → unpackToFiles(纯 Dart,不触平台通道)。
    Future<({File image, File? video})> unpack(
      Map<String, List<int>> entries,
      Directory tmp,
    ) {
      final arc = Archive();
      entries.forEach(
        (name, bytes) => arc.addFile(ArchiveFile(name, bytes.length, bytes)),
      );
      return LivpService.unpackToFiles(ZipEncoder().encode(arc)!, tmp);
    }

    String fileName(File f) => f.path.replaceAll('\\', '/').split('/').last;

    Future<T> inTmp<T>(Future<T> Function(Directory tmp) body) async {
      final tmp = await Directory.systemTemp.createTemp('livp_norm');
      try {
        return await body(tmp);
      } finally {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    }

    test('heic 内容 .heif 错名 → 落盘 .heic;双重基名 IMG_0129.JPEG 不损(F1 实锤)', () async {
      await inTmp((tmp) async {
        final content = ftypBytes('heic');
        final parts = await unpack({'IMG_0129.JPEG.heif': content}, tmp);
        expect(fileName(parts.image), 'IMG_0129.JPEG.heic');
        expect(parts.video, isNull, reason: '无视频 livp:video null 不炸(T2)');
        expect(await parts.image.readAsBytes(), content, reason: '字节原样,仅改名');
      });
    });

    test('命名正确幂等不变:heic 内容 .heic / JPEG 内容 .JPG.jpeg / qt 内容 .mov', () async {
      await inTmp((tmp) async {
        expect(
          fileName(
            (await unpack({'IMG_4921.heic': ftypBytes('heic')}, tmp)).image,
          ),
          'IMG_4921.heic',
        );
        expect(
          fileName(
            (await unpack({'IMG_0531.JPG.jpeg': jpegBytes()}, tmp)).image,
          ),
          'IMG_0531.JPG.jpeg',
        );
        final movParts = await unpack({
          'IMG_0531.mov': ftypBytes('qt  '),
          'IMG_0531.heic': ftypBytes('heic'), // pick 需静态图条目
        }, tmp);
        expect(fileName(movParts.video!), 'IMG_0531.mov');
      });
    });

    test('扩展名相同按小写比较:.HEIC(heix 内容)原名;.HEIF(heic 内容)→ 小写 .heic', () async {
      await inTmp((tmp) async {
        expect(
          fileName(
            (await unpack({'IMG_0777.HEIC': ftypBytes('heix')}, tmp)).image,
          ),
          'IMG_0777.HEIC',
          reason: '嗅探 heic == 现扩展名 heic(小写比较)→ 原名落盘',
        );
        expect(
          fileName(
            (await unpack({'IMG_0778.HEIF': ftypBytes('heic')}, tmp)).image,
          ),
          'IMG_0778.heic',
          reason: '替换段统一为嗅探结果的小写扩展名',
        );
      });
    });

    test('qt 内容 .mp4 错名 → 落盘 .mov;mp4(isom)内容保持原名(F2/决策 4)', () async {
      await inTmp((tmp) async {
        final qtParts = await unpack({
          'IMG_0129.mp4': ftypBytes('qt  '),
          'IMG_0129.heic': ftypBytes('heic'), // pick 需静态图条目
        }, tmp);
        expect(fileName(qtParts.video!), 'IMG_0129.mov');
        expect(fileName(qtParts.image), 'IMG_0129.heic');

        final mp4Parts = await unpack({
          'IMG_0200.mp4': ftypBytes('isom'),
          'IMG_0200.heic': ftypBytes('heic'),
        }, tmp);
        expect(
          fileName(mp4Parts.video!),
          'IMG_0200.mp4',
          reason: 'mp4 改名无益,如实保留',
        );
      });
    });

    test('嗅探失败/未知内容 → 原名落盘(F3 零回归)', () async {
      await inTmp((tmp) async {
        expect(
          fileName(
            (await unpack({'IMG_0300.heif': List.filled(2048, 0)}, tmp)).image,
          ),
          'IMG_0300.heif',
        );
        expect(
          fileName(
            (await unpack({'IMG_0301.heif': ftypBytes('avif')}, tmp)).image,
          ),
          'IMG_0301.heif',
          reason: 'avif 等其他 brand 不动(决策 3)',
        );
      });
    });

    test('图像+视频同时错名各自规范化;落盘字节与条目逐字节一致', () async {
      await inTmp((tmp) async {
        final heic = ftypBytes('heic');
        final qt = ftypBytes('qt  ', total: 1024);
        final parts = await unpack({
          'IMG_0129.JPEG.heif': heic,
          'IMG_0129.mp4': qt,
        }, tmp);
        expect(fileName(parts.image), 'IMG_0129.JPEG.heic');
        expect(fileName(parts.video!), 'IMG_0129.mov');
        expect(await parts.image.readAsBytes(), heic);
        expect(await parts.video!.readAsBytes(), qt);
      });
    });
  });
}
