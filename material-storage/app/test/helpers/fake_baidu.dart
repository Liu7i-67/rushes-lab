/// Baidu 域 widget 测试假件(B9;dio HttpClientAdapter 替身——widget 测试
/// FakeAsync 区真实 socket 永不推进,禁真实 HTTP,见 bind_code_page_test 头注)。
/// handler 按 (method, path, query, body) 编排,返回值:
///   Map/List      → 200 JSON
///   (status, body) → 任意状态码(JSON body;204 自动空体)
///   抛异常          → 适配器层错误(模拟断网)
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:ms_app/core/api/baidu_api.dart';
import 'package:ms_app/core/api/ms_api.dart';

class FakeBaiduRequest {
  FakeBaiduRequest(this.method, this.path, this.query, this.body);

  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, dynamic> body;

  bool get isGet => method == 'GET';
}

class FakeBaiduAdapter implements HttpClientAdapter {
  FakeBaiduAdapter(this.handler);

  final Future<Object?> Function(FakeBaiduRequest req) handler;

  /// 已捕获请求(供入参断言:提交体/翻页 offset/status 筛选)。
  final calls = <FakeBaiduRequest>[];

  static const _jsonHeaders = {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bodyText = await (requestStream ?? const Stream<Uint8List>.empty())
        .cast<List<int>>()
        .transform(utf8.decoder)
        .join();
    Map<String, dynamic> body = const {};
    if (bodyText.isNotEmpty) {
      body = jsonDecode(bodyText) as Map<String, dynamic>;
    }
    final req = FakeBaiduRequest(
        options.method, options.uri.path, options.uri.queryParameters, body);
    calls.add(req);
    final out = await handler(req);
    var status = 200;
    Object? payload = out;
    if (out is (int, Object?)) {
      status = out.$1;
      payload = out.$2;
    }
    if (status == 204) return ResponseBody.fromString('', 204);
    return ResponseBody.fromString(
        jsonEncode(payload), status,
        headers: _jsonHeaders);
  }

  @override
  void close({bool force = false}) {}
}

/// 装配注入替身的 BaiduApi(widget 测试直传页面 api 入参)。
BaiduApi baiduApiWith(FakeBaiduAdapter adapter) {
  final msApi = MsApi(baseUrl: 'http://mock.local');
  msApi.http.httpClientAdapter = adapter;
  return BaiduApi(msApi);
}

/// 网盘目录懒加载响应体。
Map<String, Object?> netdiskJson(List<Map<String, Object?>> list,
        {bool truncated = false}) =>
    {'list': list, 'truncated': truncated};

Map<String, Object?> entry(String path, String name,
        {bool isDir = true, int? size}) =>
    {'path': path, 'name': name, 'is_dir': isDir, 'size_bytes': size};

/// BaiduTaskOut 形 JSON(必填字段齐,选填按需覆盖)。
Map<String, Object?> taskJson(String id,
    {String sourceDir = '/照片',
    String status = 'running',
    bool queued = false,
    int? totalFiles,
    int? doneFiles,
    int? failedFiles,
    int? skippedFiles,
    int? cancelledFiles,
    String? failReason,
    int? etaSeconds,
    int? retryableFailedFiles,
    String projectName = '项目一',
    String? targetFolderName = '照片夹',
    bool targetAutoCreated = false,
    bool crossOverlap = false,
    List<String>? overlapNames}) {
  return {
    'id': id,
    'source_dir': sourceDir,
    'project_id': 'p1',
    'project_name': projectName,
    'target_folder_id': targetFolderName == null ? null : 'f9',
    'target_folder_name': targetFolderName,
    'target_auto_created': targetAutoCreated,
    'status': status,
    'queued': queued,
    'fail_reason': failReason,
    'cancel_requested': false,
    'total_files': totalFiles,
    'done_files': doneFiles,
    'failed_files': failedFiles,
    'skipped_files': skippedFiles,
    'cancelled_files': cancelledFiles,
    'total_bytes': 1024,
    'done_bytes': 512,
    'speed_bps': 0,
    'eta_seconds': etaSeconds,
    'retryable_failed_files': retryableFailedFiles,
    'created_at': '2026-10-20T10:00:00Z',
    'updated_at': '2026-10-20T10:01:00Z',
    'cross_project_prefix_overlap': crossOverlap,
    'overlap_project_names': overlapNames,
  };
}

/// BaiduTaskFileOut 形 JSON。
Map<String, Object?> fileJson(String id,
    {String relPath = 'a.jpg',
    String status = 'failed',
    String? lastError,
    bool nonRetryable = false,
    String? targetPath = 'p1/f9/a.jpg'}) {
  return {
    'id': id,
    'fs_id': 1,
    'source_path': '/照片/$relPath',
    'source_size': 123,
    'rel_path': relPath,
    'target_path': targetPath,
    'status': status,
    'overwrite': false,
    'bytes_done': 0,
    'attempts': 1,
    'last_error': lastError,
    'non_retryable': nonRetryable,
    'asset_id': null,
    'created_at': '2026-10-20T10:00:00Z',
    'updated_at': '2026-10-20T10:01:00Z',
  };
}
