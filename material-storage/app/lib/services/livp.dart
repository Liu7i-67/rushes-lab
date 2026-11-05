/// LivpService — .livp 容器打包/解包(纯 Dart,PC 可单测)。
///
/// .livp = zip 容器:静态帧(HEIC/JPEG)+ 实况短片(MOV)。
/// 后端 workers/main.py `_pick_livp_entries` 按「最大静态图条目 + 最大视频条目」
/// 挑选(不挑文件名)→ 本打包器保 iOS 相册导出的命名习惯即可,
/// 解包端用同一口径挑选,与后端语义一致。
///
/// 解包落盘前按**内容魔数**嗅探并规范化条目扩展名(C1/C2):外部工具导出的
/// livp 存在「真 heic 内容、.heif 错名」条目(2026-11-05 实锤
/// `IMG_0129.JPEG.heif`),iOS photo_manager darwin.saveLivePhoto 按**文件扩展名**
/// 判 UTI(`.heif` → public.heif),错名会把 heic 内容重写进 heif 容器,
/// 注入 Live Photo 配对标识时 CGImageDestinationFinalize 失败 → 存相册落分享兜底。
/// 落盘名按嗅探结果替换条目基名**最后一段**扩展名,嗅探失败/一致则原名(零回归)。
/// 详见 docs/qdev/2026-11-05-livp-unpack-ext-normalize.md。
library;

import 'dart:io';

import 'package:archive/archive.dart';

const _imageExts = {'heic', 'heif', 'jpeg', 'jpg', 'png'};
const _videoExts = {'mov', 'mp4', 'm4v'};

String _ext(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

class LivpParts {
  LivpParts({required this.image, required this.video});

  /// 静态帧 zip 条目(按类别内最大挑出)
  final ArchiveFile image;

  /// 实况短片 zip 条目;可为 null(退化 livp:无视频)
  final ArchiveFile? video;
}

class LivpService {
  /// 相册资源标题 → livp 基名(去扩展名)。空/纯空白/去扩展名后为空的标题
  /// 兜底 [fallback]:title 为空串时会拼出 '.livp' 空基名点文件与 '.jpg'/'.mov'
  /// 点文件条目,后端 pathlib 判不出扩展名(2026-10-20 iOS 真机实锤)。
  static String baseNameOf(String? title, String fallback) {
    final t = (title ?? '').trim();
    var base = (t.contains('.') ? t.substring(0, t.lastIndexOf('.')) : t)
        .trim();
    // 去扩展名后只剩点号('.')也视为无主名
    if (base.replaceAll('.', '').trim().isEmpty) base = fallback.trim();
    // 分隔符净化:iOS PHAsset localIdentifier 形如 "UUID/L0/001",兜底名直接
    // 进文件名会被 create_upload 的路径分隔符校验 400(2026-10-20 TestFlight 实锤)
    return base.replaceAll('/', '-').replaceAll('\\', '-');
  }

  /// 打包:静态帧 + 实况短片 → .livp 字节。
  /// [baseName] 不含扩展名,习惯用相册原始资源名(如 IMG_1234)。
  /// [stored] 为 true 时条目按 ZIP_STORED 写入(archive 3.6.1 per-entry 实现
  /// = `ArchiveFile.compress = false`;jpg/mp4 已压缩,deflate 近零收益白烧
  /// CPU,motion photo 轨专用)。缺省 false,保持既有 deflate 行为零回归。
  static List<int> pack({
    required List<int> imageBytes,
    required String imageExt,
    required List<int> videoBytes,
    required String videoExt,
    String baseName = 'IMG_LIVP',
    bool stored = false,
  }) {
    final arc = Archive()
      ..addFile(
        ArchiveFile(
          '$baseName.${imageExt.toLowerCase()}',
          imageBytes.length,
          imageBytes,
        )..compress = !stored,
      )
      ..addFile(
        ArchiveFile(
          '$baseName.${videoExt.toLowerCase()}',
          videoBytes.length,
          videoBytes,
        )..compress = !stored,
      );
    return ZipEncoder().encode(arc)!;
  }

  /// 解包:按「类别内最大条目」挑出静态帧与视频(与后端口径一致)。
  static LivpParts pick(Archive arc) {
    ArchiveFile? image;
    ArchiveFile? video;
    for (final f in arc.files) {
      if (f.isFile) {
        final e = _ext(f.name);
        final len = (f.content as List<int>).length;
        if (_imageExts.contains(e)) {
          if (image == null || len > (image.content as List<int>).length) {
            image = f;
          }
        } else if (_videoExts.contains(e)) {
          if (video == null || len > (video.content as List<int>).length) {
            video = f;
          }
        }
      }
    }
    if (image == null) {
      throw const FormatException('livp 内未找到静态图条目(heic/jpg/...)');
    }
    return LivpParts(image: image, video: video);
  }

  static LivpParts decode(List<int> livpBytes) =>
      pick(ZipDecoder().decodeBytes(livpBytes));

  /// 解包到临时目录,产出 (imageFile, videoFile?);供存相册用。
  /// 条目名经 [_entryBaseName] basename 净化后落盘(防恶意条目名路径穿越),
  /// 再按内容嗅探规范化最后一段扩展名([_normalizedEntryName],C2)。
  static Future<({File image, File? video})> unpackToFiles(
    List<int> livpBytes,
    Directory tmpDir,
  ) async {
    final parts = decode(livpBytes);
    await tmpDir.create(recursive: true);
    final img = File(
      '${tmpDir.path}/${_normalizedEntryName(parts.image.name, parts.image.content as List<int>, sniffImageExtFromBytes)}',
    );
    await img.writeAsBytes(parts.image.content as List<int>);
    File? vid;
    final v = parts.video;
    if (v != null) {
      vid = File(
        '${tmpDir.path}/${_normalizedEntryName(v.name, v.content as List<int>, sniffVideoExtFromBytes)}',
      );
      await vid.writeAsBytes(v.content as List<int>);
    }
    return (image: img, video: vid);
  }

  /// 条目名落盘前的 basename 净化(方案遗留项 10 顺手项):zip 条目名可携带
  /// 路径分隔(`../../evil.jpg`、`a/b/c.jpg`、反斜杠变体),直接拼 tmpDir 会
  /// 写出临时目录(路径穿越)。取分隔后的末段落盘;正常条目名(无分隔符)
  /// 原样不变。净化后为空(条目名恰为分隔符)→ 落盘必败,由调用方按解包
  /// 失败兜底(D1/matrix 既有 catch 面)。
  static String _entryBaseName(String name) {
    final norm = name.replaceAll('\\', '/');
    final i = norm.lastIndexOf('/');
    return i < 0 ? name : norm.substring(i + 1);
  }

  /// 落盘名规范化(C2):按内容嗅探结果替换条目基名**最后一段**扩展名。
  /// 嗅探 null 或与现扩展名相同(小写比较)→ 原名落盘(零回归);双重基名
  /// `IMG_0129.JPEG.heif`(heic 内容)只动末段 → `IMG_0129.JPEG.heic`,
  /// 基名段不损。条目名先经 [_entryBaseName] 净化再规范(与落盘口径一致)。
  static String _normalizedEntryName(
    String name,
    List<int> bytes,
    String? Function(List<int> head) sniff,
  ) {
    final ext = sniff(bytes.take(16).toList());
    final base = _entryBaseName(name);
    if (ext == null) return base;
    final dot = base.lastIndexOf('.');
    if (dot < 0) return '$base.$ext';
    if (base.substring(dot + 1).toLowerCase() == ext) return base;
    return '${base.substring(0, dot + 1)}$ext';
  }
}

/// bytes[from..to) 的 ASCII 解码(嗅探 ISOBMFF `ftyp` box 用)。
String _ascii(List<int> b, int from, int to) =>
    String.fromCharCodes(b.sublist(from, to));

/// 图片字节头(建议 zip 条目前 16 字节)→ 规范扩展名(小写无点);无法识别 → null。
/// 规则:bytes[4..8]=='ftyp' 且 brand(bytes[8..12]):
///   heic/heix/hevc → 'heic';mif1/msf1 → 'heif';其他 brand(avif 等)→ null;
/// FF D8 FF → 'jpeg';89 50 4E 47 → 'png';不足 12 字节/其他 → null。
String? sniffImageExtFromBytes(List<int> head) {
  if (head.length < 12) return null;
  if (_ascii(head, 4, 8) == 'ftyp') {
    final brand = _ascii(head, 8, 12);
    if (brand == 'heic' || brand == 'heix' || brand == 'hevc') return 'heic';
    if (brand == 'mif1' || brand == 'msf1') return 'heif';
    return null;
  }
  if (head[0] == 0xFF && head[1] == 0xD8 && head[2] == 0xFF) return 'jpeg';
  if (head[0] == 0x89 &&
      head[1] == 0x50 &&
      head[2] == 0x4E &&
      head[3] == 0x47) {
    return 'png';
  }
  return null;
}

/// 视频字节头 → 规范扩展名;仅 ftyp brand=='qt  '(末尾两空格)→ 'mov';
/// 其余(含 isom/mp42,PhotoKit 本就拒绝 mp4 容器,改名无益)→ null,原名如实保留。
String? sniffVideoExtFromBytes(List<int> head) {
  if (head.length < 12) return null;
  if (_ascii(head, 4, 8) == 'ftyp' && _ascii(head, 8, 12) == 'qt  ') {
    return 'mov';
  }
  return null;
}
