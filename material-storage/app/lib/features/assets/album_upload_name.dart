/// 相册素材上传名解析(album_upload_name):AssetEntity → (filename, contentType)。
///
/// iOS 根治点:photo_manager 3.12 的 iOS 桥接在 needTitle=false 时把 title 写成
/// 空串(不是 null),旧逻辑 `e.title ?? 缓存路径名` 的 `??` 对空串不生效,最终
/// 落成无扩展名文件(后端判不出类型 → 无缩略图、Web 不可预览)。取扩展名顺序:
/// title → titleAsync → originFile 缓存路径 → mimeTypeAsync;全空时把 MIME 当
/// 显式 content_type 兜底。
///
/// 约束(勿回退):title 有值(Android 常态)不发起 titleAsync,mimeTypeAsync 只在
/// 扩展名仍未知时调一次并复用;平台异常(素材已删/iCloud 未下载)一律吞成
/// null。净化与类型映射复用 sanitizeUploadName / extOf /
/// contentTypeForFilename,勿重写(分隔符与 MIME 口径全局一致)。
library;

import 'package:photo_manager/photo_manager.dart' show AssetEntity;

import '../../core/api/content_types.dart';
import 'upload_sheet.dart' show sanitizeUploadName;

/// 解析结果:filename 恒非空且已净化;contentType=null 表示交给调用方推断。
typedef AlbumUploadName = ({String filename, String? contentType});

/// MIME → 扩展名(iOS 相册会给出的族;tiff/bmp 对应截图与扫描件)。
const _extByMime = <String, String>{
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/heic': 'heic',
  'image/heif': 'heif',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/tiff': 'tiff',
  'image/bmp': 'bmp',
  'video/quicktime': 'mov',
  'video/mp4': 'mp4',
  'video/x-m4v': 'm4v',
  'video/webm': 'webm',
};

/// 扩展名 ↔ MIME。iOS 常见 UTI 派生值;未知/空返回 null。
/// 入参容错:大小写不敏感、允许 `;` 参数、允许前导点、允许直接给映射值族
/// 的扩展名(如 `png`/`jpg`;别名 `jpeg` 不在表内,返回 null)。
String? extensionFromMime(String? mime) {
  final head = _mimeHead(mime);
  if (head == null) return null;
  // 前导点入参('.PNG')按扩展名口径归一,再查 MIME 表与映射值族
  final key = _normExt(head);
  if (key == null) return null;
  final hit = _extByMime[key];
  if (hit != null) return hit;
  return _extByMime.containsValue(key) ? key : null;
}

/// 解析相册素材上传名(iOS title 空串根治点;算法顺序固定,见方案 §3.1)。
/// [originPath] = AssetEntity.originFile 的本地缓存路径(可为 null)。
/// [titleOf]/[mimeOf] 仅供测试注入,生产默认 titleAsync / mimeTypeAsync。
/// 不抛错:读取失败按 null 处理并降级。
Future<AlbumUploadName> resolveAlbumUploadName(
  AssetEntity e, {
  String? originPath,
  Future<String?> Function(AssetEntity e)? titleOf,
  Future<String?> Function(AssetEntity e)? mimeOf,
}) async {
  // 1. title 优先;iOS 空串才为本次上传按需取真名(不预开 needTitle)
  var raw = (e.title ?? '').trim();
  if (raw.isEmpty) {
    raw = (await _quietly(() => (titleOf ?? _titleOf)(e)))?.trim() ?? '';
  }

  // 2. 基名净化:兜底 IMG_<id> 保留可追溯性,分隔符约束沿用既有实现;
  //    尾点无意义且会拼出双点('IMG_1234.' + MIME 扩展名 → IMG_1234..png),先去掉
  var base = _trimTailDots(sanitizeUploadName(raw, fallback: 'IMG_${e.id}'));
  if (base.isEmpty) base = sanitizeUploadName('', fallback: 'IMG_${e.id}');

  // 3. 扩展名三级来源;mime 惰性求值,一次调用供 contentType 复用
  String? ext = _normExt(extOf(base));
  ext ??= _normExt(extOf(_baseNameOf(originPath)));
  String? mime;
  if (ext == null) {
    mime = await _quietly(() => (mimeOf ?? _mimeOf)(e));
    ext = _normExt(extensionFromMime(mime));
  }

  // 4. 拼名:base 已以同一扩展名结尾(大小写不敏感)时不重复拼
  final filename = ext == null || base.toLowerCase().endsWith('.$ext')
      ? base
      : '$base.$ext';

  // 5. contentType:有扩展名走映射表;无扩展名仅 image/* video/* 可作显式值
  final mimeHead = _mimeHead(mime);
  final isMediaMime =
      mimeHead != null &&
      (mimeHead.startsWith('image/') || mimeHead.startsWith('video/')) &&
      mimeHead != 'image/svg+xml';
  final contentType = ext != null
      ? contentTypeForFilename(filename)
      : (isMediaMime ? mimeHead : null);
  return (filename: filename, contentType: contentType);
}

Future<String?> _titleOf(AssetEntity e) => e.titleAsync;
Future<String?> _mimeOf(AssetEntity e) => e.mimeTypeAsync;

/// 平台读取兜底:吞掉所有异常(含 PlatformException),失败按 null 降级
/// (F5:素材已删/iCloud 未下载不得中断整批上传)。
Future<String?> _quietly(Future<String?> Function() read) async {
  try {
    return await read();
  } catch (_) {
    return null;
  }
}

/// MIME 主值:去 `;` 参数、trim、小写;空返回 null。
String? _mimeHead(String? mime) {
  final m = (mime ?? '').trim().toLowerCase();
  final semi = m.indexOf(';');
  final head = (semi < 0 ? m : m.substring(0, semi)).trim();
  return head.isEmpty ? null : head;
}

/// 扩展名归一化:去前导点、小写;空返回 null。
String? _normExt(String? raw) {
  final v = (raw ?? '').trim().toLowerCase().replaceFirst(RegExp(r'^\.+'), '');
  return v.isEmpty ? null : v;
}

/// 取路径 basename(反斜杠也识别,兼容桌面端测试路径)。
String _baseNameOf(String? path) =>
    path == null ? '' : path.replaceAll('\\', '/').split('/').last;

/// 去基名尾点:sanitizeUploadName 会保留 title 末尾的点,直接拼扩展名会得到
/// 双点文件名;去完为空由调用方回落兜底名。
String _trimTailDots(String name) => name.replaceFirst(RegExp(r'\.+$'), '');
