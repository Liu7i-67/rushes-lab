/// MsApi — 后端 REST 客户端核心:Dio 装配 / 全量日志 / 错误提取。
/// 按域的薄封装见同目录 auth_api.dart / projects_api.dart / folders_api.dart /
/// assets_api.dart(§9,本批 auth 域拆出 + 现役方法归类)。
///
/// 会话 cookie 持久化(PersistCookieJar)由 core/session.dart 装配注入;
/// 401 统一错误处理(§4.1)经 [onSessionExpired] 回调交 Session 去抖处理。
// ignore_for_file: unintended_html_in_doc_comment
library;

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../../services/app_log.dart';
import 'admin_templates_api.dart';
import 'approvals_api.dart';
import 'approvals_ops_api.dart';
import 'assets_api.dart';
import 'assets_ops_api.dart';
import 'auth_api.dart';
import 'baidu_api.dart';
import 'folders_api.dart';
import 'folders_ops_api.dart';
import 'notifications_api.dart';
import 'projects_api.dart';
import 'projects_ops_api.dart';
import 'share_api.dart';
import 'users_api.dart';

class ApiException implements Exception {
  ApiException(this.status, this.message);

  final int? status;
  final String message;

  @override
  String toString() => 'ApiException($status): $message';
}

/// FastAPI 错误体 detail 兼容 str / list / 对象(§4.1,勿裸 toString):
/// 数组型(422 校验错)逐条渲染 `loc: msg` 换行拼接,如
/// `body.old_password: field required`;字符串型原样透出。
String extractDetail(dynamic data, String fallback) {
  if (data is Map && data['detail'] != null) {
    final d = data['detail'];
    if (d is String) return d;
    if (d is List) {
      final lines = <String>[];
      for (final e in d) {
        if (e is Map) {
          final loc = (e['loc'] as List? ?? const []).join('.');
          final msg = '${e['msg'] ?? ''}';
          lines.add(loc.isEmpty ? msg : '$loc: $msg');
        } else {
          lines.add(e.toString());
        }
      }
      if (lines.isNotEmpty) return lines.join('\n');
    }
    return d.toString();
  }
  return fallback;
}

/// 任意异常 → 用户可读文案(B7 共用):ApiException 透传后端 detail
/// (403/409/422 透传钉子),网络/其余异常落中文 fallback。
String errorMessage(Object e, String fallback) =>
    e is ApiException ? e.message : fallback;

class MsApi {
  MsApi({
    required String baseUrl,
    CookieJar? jar,
    void Function()? onSessionExpired,
  }) : _http = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(minutes: 10),
          // 4xx 走业务错误提取,FastAPI detail 才能透出中文提示
          validateStatus: (s) => s != null && s < 500,
        )) {
    _jar = jar ?? CookieJar();
    _http.interceptors.add(CookieManager(_jar));
    // 全量 API 日志(移动端 debug 通道):方向/状态码/错误均入 AppLog
    _http.interceptors.add(_logInterceptor());
    // 401 会话失效钩子(§4.1:清会话跳登录由 Session 去抖;登录接口本身
    // 401=密码错误,不算会话失效,必须排除)
    if (onSessionExpired != null) {
      _http.interceptors.add(InterceptorsWrapper(onResponse: (r, h) {
        if (r.statusCode == 401 &&
            r.requestOptions.uri.path != '/api/v1/auth/local/login') {
          onSessionExpired();
        }
        h.next(r);
      }));
    }
    // 分片 PUT / 下载走独立裸 Dio:presigned URL 可能指向另一 host,不带 cookie;
    // 同样挂日志(预签 URL 的 query 带签名很长,只记 host+path)——
    // 否则 PUT 失败在日志里完全不可见(2026-10-20 prod 411 排障踩过)
    _put = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 10),
    ));
    _put.interceptors.add(_logInterceptor(withQuery: false));
  }

  late final CookieJar _jar;
  late final Dio _http;
  late final Dio _put;

  /// 与 web 端 Uppy getChunkSize 一致:16MB 分片(后端无强约束,保持同参最稳)
  static const int partSize = 16 * 1024 * 1024;

  String get baseUrl => _http.options.baseUrl;

  CookieJar get cookieJar => _jar;

  /// 带域路由的 JSON 客户端(cookie + 日志拦截)。
  Dio get http => _http;

  /// 直连 presigned URL 的裸 Dio(分片 PUT / 下载,无 cookie)。
  Dio get presignedHttp => _put;

  Exception err(Response<dynamic> r, String fallback) =>
      ApiException(r.statusCode, extractDetail(r.data, fallback));

  /// 5xx 兜底包装:validateStatus 只放行 <500(4xx 直接回 Response 走业务侧
  /// detail 提取),5xx 会在 dio 层抛 DioException.badResponse——这里统一转
  /// ApiException 透传后端中文 detail(§4.1 勿渲染原始对象;响应体无 detail/
  /// 非 JSON 时落到中文 fallback);断网/超时等其他异常原样上抛由调用方兜底。
  Future<Response<T>> guard5xx<T>(
      Future<Response<T>> request, String fallback) async {
    try {
      return await request;
    } on DioException catch (e) {
      final r = e.response;
      if (e.type == DioExceptionType.badResponse && r != null) {
        throw ApiException(r.statusCode, extractDetail(r.data, fallback));
      }
      rethrow;
    }
  }

  // ── 按域薄封装(无状态,惰性单建)────────────────────────────────────────
  late final auth = AuthApi(this);
  late final projects = ProjectsApi(this);
  late final folders = FoldersApi(this);
  late final assets = AssetsApi(this);
  late final ops = AssetOpsApi(this); // B5:打标/前缀/移动/回收站
  late final foldersOps = FolderOpsApi(this); // B6:文件夹管理动作
  late final projectsOps = ProjectOpsApi(this); // B6:项目建/删恢复/成员
  late final adminTemplates = AdminTemplatesApi(this); // B6:模板读端点
  late final users = UsersApi(this); // B6:选人数据源+登录名预检
  late final baidu = BaiduApi(this);
  late final share = ShareApi(this);
  late final approvals = ApprovalsApi(this);
  late final approvalsOps = ApprovalOpsApi(this); // B7:审批列表+决策
  late final notifications = NotificationsApi(this); // B7:通知列表+已读

  InterceptorsWrapper _logInterceptor({bool withQuery = true}) =>
      InterceptorsWrapper(
        onRequest: (o, h) {
          AppLog.info('api', '→ ${o.method} ${o.uri.host}${o.uri.path}'
              '${withQuery && o.uri.query.isNotEmpty ? '?${o.uri.query}' : ''}');
          h.next(o);
        },
        onResponse: (r, h) {
          AppLog.info('api', '← ${r.statusCode} ${r.requestOptions.uri.path}');
          h.next(r);
        },
        onError: (e, h) {
          AppLog.error(
              'api',
              '✗ ${e.requestOptions.method} ${e.requestOptions.uri.path}'
              '${e.response?.statusCode != null ? ' (${e.response?.statusCode})' : ''}',
              e.error);
          h.next(e);
        },
      );
}
