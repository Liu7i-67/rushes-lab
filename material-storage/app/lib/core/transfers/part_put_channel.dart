/// PartPutChannel — 上传分片 PUT 通道抽象(feat/ios-bg-upload 包 A)。
///
/// 把 assets_upload_api.dart 里内联的 dio 分片 PUT 抽象成可替换通道:
/// Android/非 iOS 走 [DioPartPutChannel](dio 装配原样搬移,行为零变化);
/// iOS 走 [BgPartPutChannel](background_downloader → 系统 background
/// URLSession,切后台后传输由系统接管,修复挂起断流)。
///
/// 协议钉子不在本层:显式 Content-Length(411)由各通道实现自带
/// (dio 通道透传原装配;bg 通道写进 UploadTask headers),调用方
/// (assets_upload_api 三步编排)语义不变。
library;

import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'bg_part_put_channel.dart';
import 'dio_part_put_channel.dart';

/// 单个分片 PUT 请求(不可变)。
class PartPutRequest {
  const PartPutRequest({
    required this.url,
    required this.chunk,
    required this.uploadId,
    required this.partNumber,
    this.cancelToken,
  });

  /// 预签名 PUT URL(sign GET 返回)。
  final String url;

  /// 本片字节(调用方已读满,长度即 Content-Length)。
  final Uint8List chunk;

  /// 上传会话 id(通道据此隔离临时分片目录)。
  final String uploadId;

  /// 分片序号(从 1 起,与后端 sign 端点一致)。
  final int partNumber;

  /// 取消令牌(dio 通道透传给 PUT;bg 通道联动取消原生队列任务)。
  final CancelToken? cancelToken;
}

/// 单个分片 PUT 结果。
class PartPutResult {
  const PartPutResult(this.etag);

  /// MinIO 回传的 ETag;通道拿不到时为空串(与现状 dio 路径一致:
  /// 空 etag 照常回传,后端 complete 会因 MinIO 校验失败报错,行为等价)。
  final String etag;
}

/// 分片 PUT 通道抽象。
abstract class PartPutChannel {
  /// 是否支持「先签后传不等完成」的批量入队(iOS bg 通道 true,
  /// dio 通道 false)——assets_upload_api 据此走预签窗口循环或顺序循环。
  bool get batchCapable;

  /// 初始化(bg:幂等注册回调 + 就绪 + 清残留临时目录;dio:no-op)。
  Future<void> ensureInit();

  /// 上传单个分片,完成(终态)后返回 etag。
  Future<PartPutResult> put(PartPutRequest req);

  /// 取消联动:bg 取消该 token 名下所有在途原生任务(canceled 终态会让
  /// 对应 put 以取消等价异常收场);dio:no-op(dio 由 CancelToken 自身取消)。
  Future<void> cancelForToken(CancelToken token);

  /// 清理该上传会话的临时分片目录(bg:删目录树;dio:no-op)。
  Future<void> cleanupUpload(String uploadId);
}

/// 平台默认通道工厂:iOS(!kIsWeb && Platform.isIOS)→ bg 通道,其余 →
/// dio 通道。[iosOverride] 仅供单测覆盖分流;[presignedHttp] 注入 dio 通道
/// 的裸 Dio(生产由 AssetsUploadApi 传 `_api.presignedHttp`,缺省为 null 时
/// dio 通道 put 会显式报错——bg 通道的 cancel/cleanup 用途不依赖 dio)。
PartPutChannel createPartPutChannel({Dio? presignedHttp, bool? iosOverride}) {
  final useBg = iosOverride ?? (!kIsWeb && Platform.isIOS);
  if (useBg) {
    // 进程级单例:registerCallbacks 按 group 全局注册,多实例会互相顶掉
    // 回调导致 put 永不收敛,必须复用同一实例。
    return BgPartPutChannel.instance;
  }
  return DioPartPutChannel(presignedHttp);
}
