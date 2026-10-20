/// PreviewKind — 预览类型判定(B2 §8.2,对标 web AssetPreviewModal.detectKind 八类)。
///
/// 钉子:扩展名判定一律 endswith(点文件 `.png` 的 suffix 教训——勿用「取最后一段
/// 再比较空串」写法);判定顺序与 web 逐条对齐:livp → markdown → text → pdf →
/// heic/heif(先于 image/* 前缀)→ image/* ct → video/* ct → 扩展名白名单 →
/// text/* 兜底 → unsupported。
library;

enum PreviewKind { markdown, text, image, pdf, video, livp, heic, unsupported }

/// web IMAGE_EXT 白名单(刻意不含 .heic/.heif——那条路走缩略图,不塞原图)。
const kImageExts = <String>[
  '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.bmp', '.avif', '.ico',
];

const kVideoExts = <String>['.mp4', '.mov', '.webm', '.m4v'];

/// Flutter 内置解码不了的「image 白名单内」扩展:原图不可显,仅当 worker 恰有
/// 缩略图(JPEG 转码)才可看,否则色块 +「下载后打开」(§8.2 已知边界)。
const kUnDecodableImageExts = <String>['.svg', '.avif', '.ico'];

bool _endsWithAny(String name, List<String> exts) {
  for (final e in exts) {
    if (name.endsWith(e)) return true;
  }
  return false;
}

PreviewKind detectKind({required String filename, String? contentType}) {
  final name = filename.toLowerCase();
  final ct = (contentType ?? '').toLowerCase();
  // livp 先按扩展名判(iOS Live Photo,zip 容器;content_type 是浏览器猜的)
  if (name.endsWith('.livp')) return PreviewKind.livp;
  if (name.endsWith('.md') || ct.startsWith('text/markdown')) {
    return PreviewKind.markdown;
  }
  if (name.endsWith('.txt') || ct == 'text/plain') return PreviewKind.text;
  if (name.endsWith('.pdf') || ct == 'application/pdf') return PreviewKind.pdf;
  // HEIC/HEIF 必须先于 image/* 前缀判(与 web 同序):此 kind 预览走缩略图
  if (name.endsWith('.heic') ||
      name.endsWith('.heif') ||
      ct == 'image/heic' ||
      ct == 'image/heif') {
    return PreviewKind.heic;
  }
  if (ct.startsWith('image/')) return PreviewKind.image;
  if (ct.startsWith('video/')) return PreviewKind.video;
  if (_endsWithAny(name, kImageExts)) return PreviewKind.image;
  if (_endsWithAny(name, kVideoExts)) return PreviewKind.video;
  // text/* 兜底也按 text 处理(csv/log/json 看着也能用,web 同哲学)
  if (ct.startsWith('text/')) return PreviewKind.text;
  return PreviewKind.unsupported;
}

// 注:曾有的 isPreviewable(k) B2 修复 P2-7 删除——全仓零消费(唯一调用方是其
// 自身单测);B4 若有真实消费点再加回,不留无主 API。
