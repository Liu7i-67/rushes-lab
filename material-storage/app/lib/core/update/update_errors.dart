/// 更新链路(检查/下载/安装)共用错误类型与可读文案(F2-2/6):
/// message 直接透 SnackBar,不再走 ms_api 的 ApiException 通道
/// (更新走独立 Dio + 静态资源直链,无后端 detail 结构)。
library;

import 'package:dio/dio.dart';

/// 携带用户可读 message 的更新链路异常;toString 即 message。
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// DioException → 中文可读文案(手动检查/下载失败 SnackBar 用;
/// 自动检查不消费文案,整体静默)。cancel 不在此描述:取消语义由
/// CancelToken.isCancelled 判定,不算错误。
String describeDioError(DioException e) => switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        '连接超时,请稍后重试',
      DioExceptionType.badResponse => '服务异常(HTTP ${e.response?.statusCode})',
      DioExceptionType.connectionError => '网络不可达,请检查网络后重试',
      _ => e.message ?? '网络异常,请稍后重试',
    };
