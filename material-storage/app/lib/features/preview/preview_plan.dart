/// PreviewPlan — 预览主体渲染决策(纯函数,从 preview_media 拆出,B2 遗留
/// 431 行拆分件之一;单测锁 P1-1 与 B4 playingLive 维度)。
library;

import '../../core/preview_kind.dart';

/// 预览主体渲染决策(纯函数,单测锁 P1-1):video 类在视频控制器未就绪时
/// 恒为 loading,绝不落到 image 分支——把视频 presigned URL 塞进 Image.network
/// 会在起播期误显「图片解码失败」卡 + 多余图片式拉流(2026-10-20 测试 P1-1)。
///
/// [playingLive](B2 遗留新增维度):livp「查看照片」回切后显示**静态缩略图**
/// 而非暂停帧——videoReady && !playingLive → image(控制器保留后台暂停,
/// 再切回续播);video 类恒按在播渲染,不受该维度影响。
PreviewBody previewBodyPlan({
  required PreviewKind kind,
  required bool videoReady,
  required bool hasFail,
  required bool hasUrl,
  bool playingLive = true,
}) {
  if (hasFail) return PreviewBody.block;
  switch (kind) {
    case PreviewKind.markdown:
      return PreviewBody.markdown;
    case PreviewKind.text:
      return PreviewBody.text;
    case PreviewKind.pdf:
      return PreviewBody.pdf;
    case PreviewKind.video:
      return videoReady ? PreviewBody.player : PreviewBody.loading;
    case PreviewKind.livp:
      if (!videoReady) return hasUrl ? PreviewBody.image : PreviewBody.loading;
      return playingLive ? PreviewBody.player : PreviewBody.image;
    case PreviewKind.image || PreviewKind.heic:
      return hasUrl ? PreviewBody.image : PreviewBody.loading;
    case PreviewKind.unsupported:
      return PreviewBody.block;
  }
}

/// 预览主体渲染分支(与 [previewBodyPlan] 配套的呈现枚举)。
enum PreviewBody { block, markdown, text, pdf, player, image, loading }

/// 视频时长/进度文本(P2-1):m:ss,满一小时进 h:mm:ss。
String videoClock(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// 缩略图缺失/失败两态文案(P2-6,web AssetPreviewModal 同口径):
/// `tags.thumbnail_failed` 有值=worker 明确失败(原因标记透出,不误导重试);
/// 无值=还在生成(引导稍后刷新)。
String thumbFailText(Map<dynamic, dynamic> tags) {
  final reason = (tags['thumbnail_failed'] as String? ?? '').trim();
  if (reason.isEmpty) return '预览图还在生成,请稍后刷新重试';
  return '预览图生成失败(原因:$reason),可下载原片查看,恢复请联系管理员';
}
