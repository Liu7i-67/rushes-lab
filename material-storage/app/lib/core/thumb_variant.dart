/// ThumbVariant — 缩略图规格变体(大视频封面+small 变体批,A1 契约 §3.7):
/// large=既有 1024px 规格(预览页维持);small=240px 列表变体(D1 定稿,
/// 宫格/胶片条小格/搜索结果行)。
///
/// **全链维度(漏一环即互串)**:磁盘文件名(`<净化id>.<diskTag>.bin`)、
/// 管线去重键、URL 缓存键、签名闸 `_Job` 键、签名请求参数(`?size=` /
/// body `"size"`)一律以 [ThumbVariantX.diskTag] 或 [ThumbVariantX.apiSize]
/// 加维度——缺任何一环都会让 small 条目缓存到 large 字节/URL 或反之。
library;

/// 缩略图规格变体。
enum ThumbVariant { large, small }

extension ThumbVariantX on ThumbVariant {
  /// 磁盘文件名维度标签:`<净化assetId>.<diskTag>.bin` → `'lg'` / `'s'`。
  String get diskTag => this == ThumbVariant.large ? 'lg' : 's';

  /// 签名端点 size 参数值(单发 `?size=` / 批量 body `"size"`)
  /// → `'large'` / `'small'`。
  String get apiSize => this == ThumbVariant.large ? 'large' : 'small';
}
