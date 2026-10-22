/// UpdateService — 检查更新(F2-2):独立 Dio 实例,不挂业务鉴权拦截器、
/// 不接 CookieManager / 401 登出钩子(与 ms_api 完全隔离);连接/接收超时
/// 各 10s;证书严格校验(D7:域名证书已实测有效,不做
/// badCertificateCallback 放行)。请求 `?t=<毫秒时间戳>` cache-bust 穿透 CDN。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import 'app_version_info.dart';
import 'update_errors.dart';

class UpdateService {
  UpdateService({Dio? dio, String? versionJsonUrl})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              // 明文取响应体自行 jsonDecode:CDN 对 .json 可能回
              // application/octet-stream,dio 的 json 转换器按 content-type
              // 判定会漏解,plain + 手动 decode 最稳。
              responseType: ResponseType.plain,
            )),
        _versionJsonUrl = versionJsonUrl ?? defaultVersionJsonUrl;

  /// 版本 JSON 地址(F1-5 契约;注入参数供单测指向本地 server)。
  static const defaultVersionJsonUrl =
      'https://resources.taoxiplan.com/huanhuashijie/app_version.json';

  final Dio _dio;
  final String _versionJsonUrl;

  /// 拉取远端版本信息。失败抛 [UpdateException](可读文案)或
  /// FormatException(version / android.url 无效 = 无有效更新信息);
  /// 404(首次发布前)同样落 UpdateException,自动检查侧一律静默。
  Future<AppVersionInfo> fetchLatest() async {
    final base = Uri.parse(_versionJsonUrl);
    final uri = base.replace(
      queryParameters: {
        ...base.queryParameters,
        't': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );
    final Response<dynamic> res;
    try {
      res = await _dio.getUri<dynamic>(uri);
    } on DioException catch (e) {
      throw UpdateException(describeDioError(e));
    }
    if (res.statusCode != 200) {
      throw UpdateException('服务异常(HTTP ${res.statusCode})');
    }
    final data = res.data;
    dynamic decoded;
    try {
      decoded = data is String && data.isNotEmpty ? jsonDecode(data) : data;
    } on FormatException {
      throw const UpdateException('版本信息格式错误');
    }
    if (decoded is! Map) {
      throw const UpdateException('版本信息格式错误');
    }
    return AppVersionInfo.fromJson(decoded);
  }
}
