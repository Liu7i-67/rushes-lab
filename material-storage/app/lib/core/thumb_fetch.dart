/// ThumbFetch — 缩略图字节共享取入口(app-thumbnail-storm-fix 架构件/W5):
/// 宫格/胶片条/预览统一经 [fetchThumb] 提交「签名→字节下载」进程级共享任务,
/// 同 assetId 自动共享订阅与字节(经 [thumbPipeline] 受并发 6/硬超时 20s/订阅
/// 取消治理)。静态 [_thumbHttp] 不设 maxConnectionsPerHost(D5:池限在取消
/// 场景制造无计时器 _pending 死等,并发治理唯一归口管线闸),connectionTimeout
/// 15s 兜底建连期。
///
/// D7 分阶段写死:① job 内 urlOf 之前注册 abandonAwait(带签名闸代数)——
/// 终态经 abort 链放弃闸内等待;② getUrl 返回后立即注册 req.abort(晚注册
/// 立即触发规则覆盖「返回后才发现已取消」);③ req.close() 返回后先查
/// isCancelled——已取消则 resp.drain 归还连接再抛取消(此时无 subscription、
/// abort 对已到响应头的连接无效);④ 响应体期显式 resp.listen 持 subscription
/// (await for 拿不到 subscription)再注册「subscription.cancel + 以异常完成
/// 下载 completer」;每个 await 后查 isCancelled 短路。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'thumbnail_cache.dart';
import 'thumb_pipeline.dart';

/// presigned 直连裸 HttpClient(无 cookie;不设池限,见 D5)。
final HttpClient _thumbHttp = HttpClient()
  ..connectionTimeout = const Duration(seconds: 15);

/// 进程级共享任务:签名→下载字节(宫格/胶片条/预览统一入口)。
ThumbHandle fetchThumb(String assetId) {
  return thumbPipeline.submit(assetId, (ctx) => _fetchJob(assetId, ctx));
}

Future<Uint8List?> _fetchJob(String assetId, ThumbTaskContext ctx) async {
  // ① 放弃链先注册:任务终态(最后订阅者 cancel/deadline/clear)→
  //    abandonAwait 同步放弃闸内等待(带代数,clear 后旧代 no-op)
  final signGen = thumbnailCache.generation;
  ctx.registerAbort(
    () => thumbnailCache.abandonAwait(assetId, generation: signGen),
  );
  if (ctx.isCancelled) throw ThumbCancelled('取消于签名前($assetId)');
  final url = await thumbnailCache.urlOf(assetId);
  if (ctx.isCancelled) throw ThumbCancelled('取消于签名后($assetId)');
  // ② 连接已建(getUrl 返回):晚注册立即触发规则覆盖此点
  final req = await _thumbHttp.getUrl(Uri.parse(url));
  ctx.registerAbort(req.abort);
  if (ctx.isCancelled) throw ThumbCancelled('取消于建连后($assetId)');
  // ③ TTFB/响应头期
  final resp = await req.close();
  if (ctx.isCancelled) {
    // 无 subscription、abort 对已到响应头连接无效:drain 归还连接再抛取消
    await resp.drain<void>().catchError((_) {});
    throw ThumbCancelled('取消于响应头后($assetId)');
  }
  if (resp.statusCode != 200) {
    await resp.drain<void>().catchError((_) {});
    throw StateError('缩略图下载失败(${resp.statusCode})');
  }
  // ④ 响应体期:显式 listen 持 subscription(await for 拿不到,cancel 不断流)
  final done = Completer<Uint8List>();
  final builder = BytesBuilder(copy: false);
  final sub = resp.listen(
    builder.add,
    onError: (Object e, StackTrace st) {
      if (!done.isCompleted) done.completeError(e, st);
    },
    onDone: () {
      if (!done.isCompleted) done.complete(builder.takeBytes());
    },
    cancelOnError: true,
  );
  ctx.registerAbort(() {
    sub.cancel();
    if (!done.isCompleted) {
      done.completeError(ThumbCancelled('下载中断($assetId)'));
    }
  });
  final bytes = await done.future;
  if (ctx.isCancelled) throw ThumbCancelled('取消于下载后($assetId)');
  return bytes;
}
