/// InlineTextLoader — md/text 预览正文流式拉取(从 preview_media 拆出,B2
/// 遗留 431 行拆分件之一):先看 Content-Length 预检(超限断流降级),再整流
/// UTF-8 解码。P2-8:presigned URL 按 GET 签名,HEAD 会被 MinIO 拒,不能走
/// HEAD 预检;openStream 以回调注入,PC 单测可用假 ResponseBody 锁两态。
library;

import 'dart:convert';

import 'package:dio/dio.dart'
    show CancelToken, Dio, Options, ResponseBody, ResponseType;

/// 正文超限(P2-8):携带实际字节数,调用方转「文件过大,建议下载后打开」。
class TextTooLargeException implements Exception {
  TextTooLargeException(this.sizeBytes);

  final int sizeBytes;

  @override
  String toString() => 'TextTooLargeException($sizeBytes)';
}

/// md/text 拉取单次缓冲上限(P2-8):presigned 源超 10MB 不读流,降级色块。
const kMaxInlineTextBytes = 10 * 1024 * 1024;

/// 拉取正文为文本:超 [maxBytes] 抛 [TextTooLargeException](断流不缓冲);
/// Content-Length 缺失(-1)无从预检则放行。
Future<String> fetchInlineText(
  Future<ResponseBody> Function(CancelToken token) openStream, {
  int maxBytes = kMaxInlineTextBytes,
}) async {
  final cancel = CancelToken();
  final body = await openStream(cancel);
  final len = body.contentLength; // -1 = 未回长度,无从预检则放行
  if (len > maxBytes) {
    cancel.cancel(); // 断流:超限不缓冲(ResponseBody.close 是 dio 内部 API 勿用)
    throw TextTooLargeException(len);
  }
  return utf8.decodeStream(body.stream);
}

/// presigned 流式 GET 打开器(preview_media 注入用;stream 类型不整包进内存)。
Future<ResponseBody> openPresignedStream(Dio dio, String url,
    {CancelToken? cancelToken}) async {
  final r = await dio.get<ResponseBody>(url,
      options: Options(responseType: ResponseType.stream),
      cancelToken: cancelToken);
  return r.data!;
}
