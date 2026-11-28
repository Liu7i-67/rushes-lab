/// DioPartPutChannel — dio 分片 PUT 通道(包 A):Android/非 iOS 平台的
/// 上传通道,**原样搬移**自 assets_upload_api.dart 既有 PUT 装配(Stream body、
/// 显式 Content-Length(prod 链路 chunked PUT 回 411 的钉子)、etag 从响应头
/// `etag` 取、CancelToken 透传),保证非 iOS 路径行为逐字节等价于现状。
///
/// 装配来源:MsApi.presignedHttp(独立裸 Dio,无 cookie,挂日志拦截器);
/// 生产由 AssetsUploadApi 经工厂注入,单测可注入本地 HttpServer 形态的 Dio。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'part_put_channel.dart';

class DioPartPutChannel implements PartPutChannel {
  DioPartPutChannel(this.presignedHttp);

  /// 装配的裸 Dio(MsApi.presignedHttp);null 时 put 显式报错
  /// (cancel/cleanup no-op 用途不依赖 dio)。
  final Dio? presignedHttp;

  @override
  bool get batchCapable => false;

  @override
  Future<void> ensureInit() async {
    // dio 无需初始化(no-op):装配即用
  }

  @override
  Future<PartPutResult> put(PartPutRequest req) async {
    final dio = presignedHttp;
    if (dio == null) {
      throw StateError('dio 分片通道未注入 presignedHttp(工厂应传 MsApi.presignedHttp)');
    }
    // ⚠ 必须显式带 Content-Length:Stream body 无长度时 dio 走 chunked 传输,
    // prod 链路(跳板机 nginx → MinIO)对 chunked PUT 回 411 Length Required
    // (iOS prod 实测踩坑;dev 链路容忍 chunked,故 PC 对 dev 验证时未暴露)
    final put = await dio.put(
      req.url,
      data: Stream<Uint8List>.value(req.chunk),
      options: Options(
        headers: {Headers.contentLengthHeader: req.chunk.length},
      ),
      cancelToken: req.cancelToken,
    );
    // etag 缺失回空串(与现状一致:后端 complete 会因 MinIO 校验失败报错)
    final etag = put.headers.value('etag') ?? '';
    return PartPutResult(etag);
  }

  @override
  Future<void> cancelForToken(CancelToken token) async {
    // no-op:dio PUT 挂了 CancelToken,取消由 dio 自身即刻生效
  }

  @override
  Future<void> cleanupUpload(String uploadId) async {
    // no-op:dio 通道 chunk 直传内存流,不落临时分片文件
  }
}
