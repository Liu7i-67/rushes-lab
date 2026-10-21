/// content_type 扩展名映射(方案 §5 统一上传)。
///
/// create_upload 需显式 content_type:web Uppy 传浏览器 File.type;App 侧
/// 相册原文件 / file_picker 结果只有文件名 → 按扩展名推断。未识别类型落
/// application/octet-stream;.livp 固定 application/zip(现役语义,后端按
/// zip 容器解包,勿改)。
library;

const _byExt = <String, String>{
  // 图片
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'bmp': 'image/bmp',
  'svg': 'image/svg+xml',
  // 视频
  'mov': 'video/quicktime',
  'mp4': 'video/mp4',
  'm4v': 'video/x-m4v',
  'webm': 'video/webm',
  'avi': 'video/x-msvideo',
  // 音频
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'aac': 'audio/aac',
  // 文档/其他
  'pdf': 'application/pdf',
  'zip': 'application/zip',
  'livp': 'application/zip',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx':
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'md': 'text/markdown',
  'txt': 'text/plain',
  'json': 'application/json',
};

/// 文件名 → 小写扩展名(无点/点文件返回 '')。
String extOf(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot <= 0 || dot == filename.length - 1) return '';
  return filename.substring(dot + 1).toLowerCase();
}

/// 扩展名 → MIME;未识别落 application/octet-stream。
String contentTypeForFilename(String filename) =>
    _byExt[extOf(filename)] ?? 'application/octet-stream';
