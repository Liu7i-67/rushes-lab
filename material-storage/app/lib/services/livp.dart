/// LivpService — .livp 容器打包/解包(纯 Dart,PC 可单测)。
///
/// .livp = zip 容器:静态帧(HEIC/JPEG)+ 实况短片(MOV)。
/// 后端 workers/main.py `_pick_livp_entries` 按「最大静态图条目 + 最大视频条目」
/// 挑选(不挑文件名)→ 本打包器保 iOS 相册导出的命名习惯即可,
/// 解包端用同一口径挑选,与后端语义一致。
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
  /// 打包:静态帧 + 实况短片 → .livp 字节。
  /// [baseName] 不含扩展名,习惯用相册原始资源名(如 IMG_1234)。
  static List<int> pack({
    required List<int> imageBytes,
    required String imageExt,
    required List<int> videoBytes,
    required String videoExt,
    String baseName = 'IMG_LIVP',
  }) {
    final arc = Archive()
      ..addFile(ArchiveFile(
          '$baseName.${imageExt.toLowerCase()}', imageBytes.length, imageBytes))
      ..addFile(ArchiveFile(
          '$baseName.${videoExt.toLowerCase()}', videoBytes.length, videoBytes));
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
  static Future<({File image, File? video})> unpackToFiles(
    List<int> livpBytes,
    Directory tmpDir,
  ) async {
    final parts = decode(livpBytes);
    await tmpDir.create(recursive: true);
    final img = File('${tmpDir.path}/${parts.image.name}');
    await img.writeAsBytes(parts.image.content as List<int>);
    File? vid;
    final v = parts.video;
    if (v != null) {
      vid = File('${tmpDir.path}/${v.name}');
      await vid.writeAsBytes(v.content as List<int>);
    }
    return (image: img, video: vid);
  }
}
