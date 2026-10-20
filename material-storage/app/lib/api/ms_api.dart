/// MsApi — 后端 REST 客户端(MVP 契约子集)。
///
/// 契约对齐 material-storage/api 实际路由(web 端 Uppy/Axios 同款):
///   POST /api/v1/auth/local/login        {username,password} → Set-Cookie ms_session
///   GET  /api/v1/auth/me
///   GET  /api/v1/projects                → Project[](默认 limit=100,MVP 单页)
///   GET  /api/v1/folders?project_id=     → Folder[]
///   GET  /api/v1/assets?folder_id&limit&offset → {items,total}
///   POST /api/v1/assets/uploads          {folder_id,filename,content_type,size_bytes}
///                                       → {upload_id,key,bucket}
///   GET  /api/v1/assets/uploads/{uid}/parts/{n}?bucket&key → {url}
///   PUT  <presigned url>                 → 响应头 ETag(分片 16MB,与 web Uppy 同块大小)
///   POST /api/v1/assets/uploads/{uid}/complete
///       {upload_id,folder_id,bucket,key,parts:[{PartNumber,ETag}]} → Asset
///   DELETE /api/v1/assets/uploads/{uid}?bucket&key  (abort)
///   POST /api/v1/assets/{id}/download-link {as_attachment} → {url}
///   GET  /api/v1/assets/{id}/thumbnail-url → {url}
///   DELETE /api/v1/assets/{id}           (软删,verify_dev 自清理用)
// ignore_for_file: unintended_html_in_doc_comment
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../models.dart';
import '../services/app_log.dart';

class ApiException implements Exception {
  ApiException(this.status, this.message);

  final int? status;
  final String message;

  @override
  String toString() => 'ApiException($status): $message';
}

/// FastAPI 错误体的 detail 兼容 str / list(与 web 端 errorMessage 同哲学)。
String _extractDetail(dynamic data, String fallback) {
  if (data is Map && data['detail'] != null) {
    final d = data['detail'];
    if (d is String) return d;
    return d.toString();
  }
  return fallback;
}

class MsApi {
  MsApi({required String baseUrl, CookieJar? jar})
      : _http = Dio(BaseOptions(
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
    // 分片 PUT 走独立裸 Dio:presigned URL 可能指向另一 host,不带 cookie;
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

  /// 与 web 端 Uppy getChunkSize 一致:16MB 分片(后端无强约束,保持同参最稳)
  static const int partSize = 16 * 1024 * 1024;

  String get baseUrl => _http.options.baseUrl;

  CookieJar get cookieJar => _jar;

  Exception _err(Response<dynamic> r, String fallback) =>
      ApiException(r.statusCode, _extractDetail(r.data, fallback));

  // ─── auth ────────────────────────────────────────────────────────────────

  Future<Me> login(String username, String password) async {
    final r = await _http.post('/api/v1/auth/local/login',
        data: {'username': username, 'password': password});
    if (r.statusCode != 200) throw _err(r, '登录失败');
    return me();
  }

  Future<Me> me() async {
    final r = await _http.get('/api/v1/auth/me');
    if (r.statusCode != 200) throw _err(r, '未登录或会话失效');
    return Me.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> logout() async {
    await _http.post('/api/v1/auth/logout');
  }

  // ─── browse ───────────────────────────────────────────────────────────────

  Future<List<Project>> projects() async {
    final r = await _http.get('/api/v1/projects');
    if (r.statusCode != 200) throw _err(r, '项目列表加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => Project.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Folder>> folders(String projectId) async {
    final r = await _http
        .get('/api/v1/folders', queryParameters: {'project_id': projectId});
    if (r.statusCode != 200) throw _err(r, '目录列表加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => Folder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<AssetPage> assets(String folderId,
      {int limit = 30, int offset = 0}) async {
    final r = await _http.get('/api/v1/assets', queryParameters: {
      'folder_id': folderId,
      'limit': limit,
      'offset': offset,
    });
    if (r.statusCode != 200) throw _err(r, '文件列表加载失败');
    return AssetPage.fromJson(r.data as Map<String, dynamic>);
  }

  // ─── download ─────────────────────────────────────────────────────────────

  Future<String> downloadLink(String assetId,
      {bool asAttachment = true}) async {
    final r = await _http.post('/api/v1/assets/$assetId/download-link',
        data: {'as_attachment': asAttachment});
    if (r.statusCode != 200) throw _err(r, '获取下载链接失败');
    return (r.data as Map<String, dynamic>)['url'] as String;
  }

  /// 下载到本地文件,返回文件;onProgress(0..1)。
  Future<File> downloadTo(String url, String savePath,
      {void Function(double)? onProgress}) async {
    await _put.download(url, savePath,
        onReceiveProgress: (c, t) {
      if (t > 0 && onProgress != null) onProgress(c / t);
    });
    return File(savePath);
  }

  Future<void> deleteAsset(String assetId) async {
    final r = await _http.delete('/api/v1/assets/$assetId');
    // FastAPI DELETE 默认 204 No Content
    if (r.statusCode != 200 && r.statusCode != 204) throw _err(r, '删除失败');
  }

  // ─── multipart upload(与 web Uppy 同款三步编排)─────────────────────────

  /// 上传 [bytes] 为 [filename](livp 建议 content_type application/zip)。
  /// onPartsDone(completed, total) 供进度展示。失败时尽力 abort 半成品。
  Future<Asset> uploadBytes({
    required String folderId,
    required String filename,
    required List<int> bytes,
    String contentType = 'application/zip',
    void Function(int done, int total)? onPartsDone,
  }) async {
    final create = await _http.post('/api/v1/assets/uploads', data: {
      'folder_id': folderId,
      'filename': filename,
      'content_type': contentType,
      'size_bytes': bytes.length,
    });
    if (create.statusCode != 200) {
      throw _err(create, '创建上传失败');
    }
    final c = create.data as Map<String, dynamic>;
    final uploadId = c['upload_id'] as String;
    final key = c['key'] as String;
    final bucket = c['bucket'] as String;

    try {
      final totalParts = (bytes.length / partSize).ceil().clamp(1, 1 << 30);
      final parts = <Map<String, dynamic>>[];
      for (var n = 1; n <= totalParts; n++) {
        final start = (n - 1) * partSize;
        final end = (n * partSize).clamp(0, bytes.length);
        final chunk = Uint8List.fromList(bytes.sublist(start, end));
        final sign = await _http.get(
            '/api/v1/assets/uploads/$uploadId/parts/$n',
            queryParameters: {'bucket': bucket, 'key': key});
        if (sign.statusCode != 200) throw _err(sign, '分片签名失败');
        final url = (sign.data as Map<String, dynamic>)['url'] as String;
        // ⚠ 必须显式带 Content-Length:Stream body 无长度时 dio 走 chunked 传输,
        // prod 链路(跳板机 nginx → MinIO)对 chunked PUT 回 411 Length Required
        // (iOS prod 实测踩坑;dev 链路容忍 chunked,故 PC 对 dev 验证时未暴露)
        final put = await _put.put(
          url,
          data: Stream<Uint8List>.value(chunk),
          options: Options(
            headers: {Headers.contentLengthHeader: chunk.length},
          ),
        );
        final etag = put.headers.value('etag') ?? '';
        parts.add({'PartNumber': n, 'ETag': etag});
        if (onPartsDone != null) onPartsDone(n, totalParts);
      }
      final done = await _http.post('/api/v1/assets/uploads/$uploadId/complete',
          data: {
            'upload_id': uploadId,
            'folder_id': folderId,
            'bucket': bucket,
            'key': key,
            'parts': parts,
          });
      if (done.statusCode != 200) throw _err(done, '完成上传失败');
      return Asset.fromJson(done.data as Map<String, dynamic>);
    } catch (e) {
      // 尽力清理半成品 multipart,不留 MinIO 悬挂分片
      try {
        await _http.delete('/api/v1/assets/uploads/$uploadId',
            queryParameters: {'bucket': bucket, 'key': key});
      } catch (_) {}
      rethrow;
    }
  }
}
