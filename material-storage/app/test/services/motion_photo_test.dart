/// Motion Photo 探测内核测试(§7.1 全集;fixture 全部字节级手工构造)。
///
/// 布局口径(§3.1,fixture 锁实现、真机未证):
/// - GContainer/MicroVideo:视频 = 文件末尾 N 字节;三星混合形态尾部另有
///   `[SEFH(L)][size=L(4B LE)]["SEFT"]`,totalTrailerLen = L+8,
///   videoEnd = fileSize - (L+8),video = [videoEnd-N, videoEnd)。
/// - 纯 SEFT(无 XMP,老三星):SEFH 内 marker `MotionPhoto_Data` 后 4B LE
///   = videoStart 绝对偏移。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/services/livp.dart';
import 'package:ms_app/services/motion_photo.dart';

String _a(String name, String value, bool single) =>
    single ? "$name='$value'" : '$name="$value"';

/// 构造 GContainer/MicroVideo XMP 文本(属性顺序/引号形态可变,§5.1 守卫③)。
String buildXmp({
  bool motionFlag = false,
  bool microFlag = false,
  int? microOffset,
  int? motionLength,
  bool primaryLength0 = false,
  bool lengthBeforeSemantic = false,
  bool singleQuotes = false,
  int motionItemCount = 1,
  bool flmVendors = false,
  bool extraFields = false,
  bool withDirectory = true,
}) {
  String item(String semantic, String? mime, String? length, bool lenFirst) {
    final parts = <String>[
      if (lenFirst && length != null) _a('Item:Length', length, singleQuotes),
      _a('Item:Semantic', semantic, singleQuotes),
      if (mime != null) _a('Item:Mime', mime, singleQuotes),
      if (!lenFirst && length != null) _a('Item:Length', length, singleQuotes),
    ];
    return '<Container:Item ${parts.join(' ')}/>';
  }

  final flags = <String>[
    if (motionFlag) _a('GCamera:MotionPhoto', '1', singleQuotes),
    if (microFlag) _a('GCamera:MicroVideo', '1', singleQuotes),
    if (microOffset != null)
      _a('GCamera:MicroVideoOffset', '$microOffset', singleQuotes),
    if (flmVendors) 'OpCamera:LivePhoto="1" MiCamera:LivePhoto="1"',
    if (extraFields) 'photoshop:Credit="unit-test" tiff:Model="FixtureCam"',
  ].join(' ');
  final dir = withDirectory
      ? '<Container:Directory>'
            '${item('Primary', 'image/jpeg', primaryLength0 ? '0' : null, false)}'
            '${List.generate(motionItemCount, (i) => item('MotionPhoto', 'video/mp4', '${motionLength ?? 0}', lengthBeforeSemantic)).join()}'
            '</Container:Directory>'
      : '';
  return '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF rdf:about="" '
      'xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" '
      'xmlns:Container="http://ns.google.com/photos/1.0/container/" '
      'xmlns:Item="http://ns.google.com/photos/1.0/container/item/" '
      '$flags>$dir</rdf:RDF></x:xmpmeta>';
}

/// 标准 JPEG 骨架:SOI + APP1(XMP)+ filler + EOI
List<int> app1Segment(String xmp) {
  final payload = utf8.encode(xmp);
  final sig = utf8.encode('http://ns.adobe.com/xap/1.0/\x00');
  final segLen = 2 + sig.length + payload.length;
  return [0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF, ...sig, ...payload];
}

Uint8List buildJpeg({String? xmp, int filler = 0}) {
  final b = BytesBuilder();
  b.add([0xFF, 0xD8]); // SOI
  if (xmp != null) {
    b.add(app1Segment(xmp));
  }
  if (filler > 0) b.add(List.filled(filler, 0x00));
  b.add([0xFF, 0xD9]); // EOI
  return b.toBytes();
}

/// 伪 MP4:[0..4) box size(BE)+ [4..8) 'ftyp' + 填充;withFtyp=false 时全 0x77
Uint8List fakeMp4(int n, {bool withFtyp = true}) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = withFtyp ? 0x30 + (i % 64) : 0x77;
  }
  if (withFtyp) {
    ByteData.sublistView(out).setUint32(0, n, Endian.big);
    out.setRange(4, 8, utf8.encode('ftyp'));
  }
  return out;
}

/// SEFT trailer:[SEFH 块 l 字节(含 marker + 4B LE videoStartAbs)][size 4B LE]
/// ["SEFT"]。forcedLen 覆写 size 字段(构造 L 非法域用例);corruptSefh 把 SEFH
/// 块填成 0x77(构造「SEFH 亦坏」用例)。
Uint8List seftTrailer({
  required int videoStartAbs,
  int l = 24,
  int? forcedLen,
  bool corruptSefh = false,
}) {
  final block = Uint8List(l);
  if (corruptSefh) {
    for (var i = 0; i < l; i++) {
      block[i] = 0x77;
    }
  } else {
    const marker = 'MotionPhoto_Data';
    block.setRange(0, 4, utf8.encode('SEFH'));
    block.setRange(4, 4 + marker.length, utf8.encode(marker));
    ByteData.sublistView(block)
        .setUint32(4 + marker.length, videoStartAbs, Endian.little);
  }
  final out = BytesBuilder();
  out.add(block);
  out.add(
    (ByteData(
      4,
    )..setUint32(0, forcedLen ?? l, Endian.little)).buffer.asUint8List(),
  );
  out.add(utf8.encode('SEFT'));
  return out.toBytes();
}

Uint8List joinBytes(Iterable<List<int>> parts) {
  final b = BytesBuilder();
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

/// `</x:xmpmeta>` 结束后的偏移(测试内自算 xmpEnd,不依赖实现内部)
int xmpEndOf(List<int> b) {
  final m = utf8.encode('</x:xmpmeta>');
  for (var i = 0; i + m.length <= b.length; i++) {
    var ok = true;
    for (var j = 0; j < m.length; j++) {
      if (b[i + j] != m[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i + m.length;
  }
  return -1;
}

/// 稀疏写大文件(truncate 定长 + 分块定位写,不在内存拼全量)
Future<File> writeSparse(File f, int size, Map<int, List<int>> chunks) async {
  final raf = await f.open(mode: FileMode.write);
  await raf.truncate(size);
  final keys = chunks.keys.toList()..sort();
  for (final k in keys) {
    await raf.setPosition(k);
    await raf.writeFrom(chunks[k]!);
  }
  await raf.close();
  return f;
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('motion_photo_test');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('probeMotionPhoto 全量字节内核 — 阳例', () {
    test('GContainer 新建 XMP:最小 JPEG 骨架 + 伪 MP4,拆分恰为两段', () {
      const n = 2048;
      final jpeg = buildJpeg(xmp: buildXmp(motionFlag: true, motionLength: n));
      final vid = fakeMp4(n);
      final split = probeMotionPhoto(joinBytes([jpeg, vid]))!;
      expect(split.format, 'gcontainer');
      expect(split.image, jpeg);
      expect(split.video, vid);
      // 最小骨架:SOI 开头 / EOI 收尾(XMP 原样保留在 image 内)
      expect(split.image[0], 0xFF);
      expect(split.image[1], 0xD8);
      expect(split.image[split.image.length - 2], 0xFF);
      expect(split.image[split.image.length - 1], 0xD9);
      // 守卫⑥ 锚点:ftyp box 头在 video[4..8)
      expect(utf8.decode(split.video.sublist(4, 8)), 'ftyp');
    });

    test('GContainer 主图已含其他 XMP 字段:不干扰 motion 提取', () {
      const n = 1024;
      final jpeg = buildJpeg(
        xmp: buildXmp(motionFlag: true, motionLength: n, extraFields: true),
      );
      final split = probeMotionPhoto(joinBytes([jpeg, fakeMp4(n)]))!;
      expect(split.format, 'gcontainer');
      expect(split.video.length, n);
    });

    test('MicroVideo(老格式):GCamera:MicroVideoOffset=N,video=末尾 N 字节', () {
      const n = 1024;
      final jpeg = buildJpeg(
        xmp: buildXmp(microFlag: true, microOffset: n, withDirectory: false),
      );
      final vid = fakeMp4(n);
      final split = probeMotionPhoto(joinBytes([jpeg, vid]))!;
      expect(split.format, 'microvideo');
      expect(split.image, jpeg);
      expect(split.video, vid);
    });

    test('双标记并存且区间一致(flm 默认模板形态):互验通过,format 取 gcontainer', () {
      const n = 1024;
      final jpeg = buildJpeg(
        xmp: buildXmp(
          motionFlag: true,
          microFlag: true,
          microOffset: n,
          motionLength: n,
        ),
      );
      final split = probeMotionPhoto(joinBytes([jpeg, fakeMp4(n)]))!;
      expect(split.format, 'gcontainer');
      expect(split.video.length, n);
    });

    test('GContainer+SEFT 三星混合形态:拆分恰为 [fileSize-L-8-N, fileSize-L-8),trailer 不入任何一侧,命中轨=XMP', () {
      const n = 2048;
      const l = 64; // L ∈ [24,4088] 合法域
      final jpeg = buildJpeg(xmp: buildXmp(motionFlag: true, motionLength: n));
      final vid = fakeMp4(n);
      final trailer = seftTrailer(videoStartAbs: jpeg.length, l: l);
      final bytes = joinBytes([jpeg, vid, trailer]);
      final split = probeMotionPhoto(bytes)!;
      // 命中轨 = XMP(gcontainer),非 SEFT 分支(尾签名不旁路 XMP,互斥)
      expect(split.format, 'gcontainer');
      expect(split.format, isNot('seft'));
      expect(split.image, jpeg);
      expect(split.video, vid);
      expect(bytes.length, jpeg.length + n + l + 8);
      expect(split.image.length + split.video.length, bytes.length - (l + 8));
      // videoEnd = fileSize - totalTrailerLen(=L+8,钉死口径)
      expect(split.video.length, n);
      // trailer 末字节留有 SEFT 签名,不入任何一侧
      expect(utf8.decode(bytes.sublist(bytes.length - 4)), 'SEFT');
    });

    test('Primary 无 Item:Length 形态:N 只认 MotionPhoto 条目,命中', () {
      const n = 1024;
      final jpeg = buildJpeg(
        xmp: buildXmp(motionFlag: true, motionLength: n, primaryLength0: false),
      );
      final vid = fakeMp4(n);
      final split = probeMotionPhoto(joinBytes([jpeg, vid]))!;
      expect(split.format, 'gcontainer');
      expect(split.video, vid);
    });

    test('Primary Item:Length="0" 形态(flm 默认模板):0 不得被当成 N', () {
      const n = 1024;
      final jpeg = buildJpeg(
        xmp: buildXmp(motionFlag: true, motionLength: n, primaryLength0: true),
      );
      final vid = fakeMp4(n);
      final split = probeMotionPhoto(joinBytes([jpeg, vid]))!;
      expect(split.format, 'gcontainer');
      expect(split.video, vid);
      expect(split.video.length, n); // 若实现退化成「取首个 Item:Length」,此断言必败
    });

    test('厂商变体:Item:Length 写在 Item:Semantic 之前(不得假定属性顺序)', () {
      const n = 1024;
      final jpeg = buildJpeg(
        xmp: buildXmp(
          motionFlag: true,
          motionLength: n,
          lengthBeforeSemantic: true,
        ),
      );
      final split = probeMotionPhoto(joinBytes([jpeg, fakeMp4(n)]))!;
      expect(split.format, 'gcontainer');
      expect(split.video.length, n);
    });

    test('属性值单引号形态:与双引号同语义', () {
      const n = 1024;
      final jpeg = buildJpeg(
        xmp: buildXmp(motionFlag: true, motionLength: n, singleQuotes: true),
      );
      final split = probeMotionPhoto(joinBytes([jpeg, fakeMp4(n)]))!;
      expect(split.format, 'gcontainer');
      expect(split.video.length, n);
    });

    test('(P1)纯 SEFT(无 XMP 老三星):XMP 轨未命中后由尾签名兜底进入,format=seft', () {
      const n = 1024;
      final jpeg = buildJpeg(); // 无 XMP
      final vid = fakeMp4(n);
      final trailer = seftTrailer(videoStartAbs: jpeg.length, l: 24);
      final split = probeMotionPhoto(joinBytes([jpeg, vid, trailer]))!;
      expect(split.format, 'seft'); // 只有 SEFT 兜底轨能给出该标签
      expect(split.image, jpeg);
      expect(split.video, vid);
    });

    test(
      'flm 真实输出形态回喂:四组厂商标记 XMP + Primary Length="0" 必须命中(锁 flm 产物→自校验闭环)',
      () {
        const n = 2048;
        final xmp = buildXmp(
          motionFlag: true,
          microFlag: true,
          microOffset: n,
          flmVendors: true,
          primaryLength0: true,
          motionLength: n,
        );
        final jpeg = buildJpeg(xmp: xmp);
        final vid = fakeMp4(n);
        final split = probeMotionPhoto(joinBytes([jpeg, vid]))!;
        expect(split.format, 'gcontainer'); // 双标记一致 → gcontainer 优先
        expect(split.image, jpeg);
        expect(split.video, vid);
      },
    );
  });

  group('probeMotionPhoto 全量字节内核 — 阴例(降级普通轨)', () {
    test('普通 jpg 无 XMP → null', () {
      expect(probeMotionPhoto(buildJpeg()), isNull);
    });

    test('XMP 无 motion 字段(如 Photoshop XMP)→ null', () {
      final jpeg = buildJpeg(xmp: buildXmp(extraFields: true));
      expect(probeMotionPhoto(jpeg), isNull);
    });

    test('Length 越界 > fileSize → null(videoStart 为负)', () {
      final jpeg = buildJpeg(
        xmp: buildXmp(motionFlag: true, motionLength: 1 << 30),
      );
      expect(probeMotionPhoto(jpeg), isNull);
    });

    test('Length < 1024 → null(防 XMP 残留小值误判)', () {
      final jpeg = buildJpeg(
        xmp: buildXmp(motionFlag: true, motionLength: 512),
      );
      expect(probeMotionPhoto(joinBytes([jpeg, fakeMp4(512)])), isNull);
    });

    test('videoStart<xmpEnd → null(声明 N 超物理视频,videoStart 落回 XMP 区内;该处已布置 ftyp,仅此守卫可败)', () {
      const n = 1400;
      final jpeg = buildJpeg(xmp: buildXmp(motionFlag: true, motionLength: n));
      final bytes = joinBytes([jpeg, fakeMp4(1024)]);
      final xmpEnd = xmpEndOf(bytes);
      final videoStart = bytes.length - n;
      expect(videoStart, greaterThan(0));
      expect(videoStart, lessThanOrEqualTo(xmpEnd)); // 前置:构造确实落在该守卫域
      // 在 videoStart 处布置 box size + ftyp,隔离出「仅 xmpEnd 子句可败」
      bytes.setRange(videoStart, videoStart + 8, [
        0,
        0,
        0,
        0x20,
        0x66,
        0x74,
        0x79,
        0x70,
      ]);
      expect(probeMotionPhoto(bytes), isNull);
    });

    test('视频无 ftyp 头(剥视频残留/假 mp4)→ null', () {
      const n = 1024;
      final jpeg = buildJpeg(xmp: buildXmp(motionFlag: true, motionLength: n));
      expect(
        probeMotionPhoto(joinBytes([jpeg, fakeMp4(n, withFtyp: false)])),
        isNull,
      );
    });

    test('非 JPEG 文件 → null(守卫① SOI)', () {
      final png = Uint8List.fromList([
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        ...List.filled(64, 0),
      ]);
      expect(probeMotionPhoto(png), isNull);
    });

    test('双标记并存但区间不一致 → null(互验失败)', () {
      const n = 1024;
      final jpeg = buildJpeg(
        xmp: buildXmp(
          motionFlag: true,
          microFlag: true,
          microOffset: n + 7,
          motionLength: n,
        ),
      );
      expect(probeMotionPhoto(joinBytes([jpeg, fakeMp4(n)])), isNull);
    });

    test('Container:Directory 含 2 个 MotionPhoto item(v2 多段)→ null', () {
      const n = 1024;
      final jpeg = buildJpeg(
        xmp: buildXmp(motionFlag: true, motionLength: n, motionItemCount: 2),
      );
      expect(probeMotionPhoto(joinBytes([jpeg, fakeMp4(n)])), isNull);
    });

    test('totalTrailerLen 非法①:L 非法域 + 尾签名 + SEFH 可解析 → 落 SEFT 兜底后仍命中', () {
      const n = 1024;
      final jpeg = buildJpeg(xmp: buildXmp(motionFlag: true, motionLength: n));
      final vid = fakeMp4(n);
      // size 字段覆写为 5(<24 非法)→ XMP 轨 trailer 修正失败判未命中;
      // SEFH 块本身完好(魔数搜索可解析)→ 兜底命中,videoEnd = SEFH 块起点
      final trailer = seftTrailer(
        videoStartAbs: jpeg.length,
        l: 24,
        forcedLen: 5,
      );
      final split = probeMotionPhoto(joinBytes([jpeg, vid, trailer]))!;
      expect(split.format, 'seft');
      expect(split.image, jpeg);
      expect(split.video, vid);
    });

    test('totalTrailerLen 非法②:L 非法域 + 尾签名 + SEFH 亦坏 → 终局 null', () {
      const n = 1024;
      final jpeg = buildJpeg(xmp: buildXmp(motionFlag: true, motionLength: n));
      final trailer = seftTrailer(
        videoStartAbs: jpeg.length,
        l: 24,
        forcedLen: 5,
        corruptSefh: true,
      );
      expect(probeMotionPhoto(joinBytes([jpeg, fakeMp4(n), trailer])), isNull);
    });

    test('混合形态 trailer 修正成功但视频无 ftyp → 守卫⑥安全挡回 null', () {
      const n = 1024;
      final jpeg = buildJpeg(xmp: buildXmp(motionFlag: true, motionLength: n));
      final trailer = seftTrailer(videoStartAbs: jpeg.length, l: 24);
      expect(
        probeMotionPhoto(
          joinBytes([jpeg, fakeMp4(n, withFtyp: false), trailer]),
        ),
        isNull,
      );
    });
  });

  group('拆分自洽', () {
    test('probe 产物喂 LivpService.pack(stored)→ decode 还原两端字节一致', () {
      const n = 2048;
      final jpeg = buildJpeg(xmp: buildXmp(motionFlag: true, motionLength: n));
      final vid = fakeMp4(n);
      final split = probeMotionPhoto(joinBytes([jpeg, vid]))!;
      final livp = LivpService.pack(
        imageBytes: split.image,
        imageExt: 'jpg',
        videoBytes: split.video,
        videoExt: 'mp4',
        baseName: 'MVIMG_0001',
        stored: true,
      );
      final parts = LivpService.decode(livp);
      expect(parts.image.name, 'MVIMG_0001.jpg');
      expect(parts.video!.name, 'MVIMG_0001.mp4');
      expect(parts.image.content, split.image);
      expect(parts.video!.content, split.video);
    });
  });

  group('probeMotionPhotoFile 文件版窗口行为(三读预筛,稀疏写大文件)', () {
    test('XMP 恰落头 256KB 窗内 + 定点 8 字节读偏移(videoStart 超出头窗)', () async {
      const n = 2048;
      const xmpAt = 200000; // < 256KB:窗内
      const videoAt = 265000; // > 256KB:videoStart 落在头窗之外
      final f = await writeSparse(
        File('${tmp.path}/in_window.jpg'),
        videoAt + 1 + n,
        {
          0: [0xFF, 0xD8],
          xmpAt: app1Segment(buildXmp(motionFlag: true, motionLength: n)),
          videoAt: [0xFF, 0xD9],
          videoAt + 1: fakeMp4(n),
        },
      );
      final plan = await probeMotionPhotoFile(f.path);
      expect(plan, isNotNull);
      expect(plan!.format, 'gcontainer');
      expect(plan.videoStart, videoAt + 1);
      expect(plan.videoEnd, videoAt + 1 + n); // 无 trailer = fileSize
      expect(plan.fileSize, videoAt + 1 + n);
      expect(plan.videoStart, greaterThan(xmpHeadWindow)); // 定点读超出头窗
    });

    test('XMP 落头 256KB 窗外 → fail-safe null', () async {
      const n = 1024;
      const xmpAt = 300000; // > 256KB
      final seg = app1Segment(buildXmp(motionFlag: true, motionLength: n));
      final f = await writeSparse(
        File('${tmp.path}/out_window.jpg'),
        xmpAt + seg.length + 1 + n,
        {
          0: [0xFF, 0xD8],
          xmpAt: [...seg, 0xFF, 0xD9, ...fakeMp4(n)],
        },
      );
      expect(await probeMotionPhotoFile(f.path), isNull);
    });

    test('纯 SEFT 尾签落尾 64KB 窗(文件 >256KB):尾窗读 + SEFH + 定点读全链生效', () async {
      const n = 2048;
      const videoAt = 300000;
      final trailer = seftTrailer(videoStartAbs: videoAt, l: 24);
      final size = videoAt + n + trailer.length;
      final f = await writeSparse(File('${tmp.path}/pure_seft.jpg'), size, {
        0: [0xFF, 0xD8, 0xFF, 0xD9],
        videoAt: fakeMp4(n),
        videoAt + n: trailer,
      });
      final plan = await probeMotionPhotoFile(f.path);
      expect(plan, isNotNull);
      expect(plan!.format, 'seft');
      expect(plan.videoStart, videoAt);
      expect(plan.videoEnd, videoAt + n);
      expect(plan.fileSize, size);
    });

    test(
      'XMP 命中后走 trailer 修正而非 SEFT 分支(大文件互斥断言:videoEnd=fileSize-(L+8))',
      () async {
        const n = 2048;
        const videoAt = 300000;
        final jpeg = buildJpeg(
          xmp: buildXmp(motionFlag: true, motionLength: n),
        );
        final trailer = seftTrailer(videoStartAbs: videoAt, l: 24);
        final size = videoAt + n + trailer.length;
        final f = await writeSparse(File('${tmp.path}/hybrid.jpg'), size, {
          0: jpeg,
          videoAt: fakeMp4(n),
          videoAt + n: trailer,
        });
        final plan = await probeMotionPhotoFile(f.path);
        expect(plan, isNotNull);
        expect(plan!.format, 'gcontainer'); // 混合形态恒走 XMP 轨
        expect(plan.format, isNot('seft'));
        expect(plan.videoEnd, size - 24 - 8); // totalTrailerLen = L+8
        expect(plan.videoStart, videoAt);
      },
    );

    test('probeMotionPhotoFileGuarded:任何 IO 异常 → null(文件不存在)', () async {
      expect(await probeMotionPhotoFileGuarded('${tmp.path}/nope.jpg'), isNull);
    });
  });

  group('probeMotionPhotoFile × flm 产物回喂', () {
    test('flm 四族模板产物(小文件)文件版命中,videoEnd=fileSize(无 trailer)', () async {
      const n = 2048;
      final xmp = buildXmp(
        motionFlag: true,
        microFlag: true,
        microOffset: n,
        flmVendors: true,
        primaryLength0: true,
        motionLength: n,
      );
      final bytes = joinBytes([buildJpeg(xmp: xmp), fakeMp4(n)]);
      final f = File('${tmp.path}/flm_out.jpg');
      await f.writeAsBytes(bytes);
      final plan = await probeMotionPhotoFile(f.path);
      expect(plan, isNotNull);
      expect(plan!.format, 'gcontainer');
      expect(plan.videoStart, bytes.length - n);
      expect(plan.videoEnd, plan.fileSize);
      expect(plan.fileSize, bytes.length);
    });
  });
}
