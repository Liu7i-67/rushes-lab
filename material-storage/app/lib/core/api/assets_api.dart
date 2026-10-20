/// AssetsApi — /api/v1/assets 族薄封装:列表 / 上传三步编排 / 下载 / 删除。
/// 上传与 web Uppy 同款:sign → 分片 PUT(presigned,必带 Content-Length)
/// → complete;失败尽力 abort 半成品。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../models/models.dart';
import 'ms_api.dart';

class AssetsApi {
  AssetsApi(this._api);

  final MsApi _api;

  Future<AssetPage> list(String folderId, {int limit = 30, int offset = 0}) async {
    final r = await _api.http.get('/api/v1/assets', queryParameters: {
      'folder_id': folderId,
      'limit': limit,
      'offset': offset,
    });
    if (r.statusCode != 200) throw _api.err(r, '文件列表加载失败');
    return AssetPage.fromJson(r.data as Map<String, dynamic>);
  }

  /// 缩略图 presigned URL(B2 宫格):tags.thumbnail_key 不存在时端点 404
  /// → ApiException(404),调用方降级类型色块。
  Future<({String url, int expiresIn})> thumbnailUrl(String assetId) async {
    final r = await _api.http.get('/api/v1/assets/$assetId/thumbnail-url');
    if (r.statusCode != 200) throw _api.err(r, '缩略图加载失败');
    final d = r.data as Map<String, dynamic>;
    return (url: d['url'] as String, expiresIn: (d['expires_in'] ?? 1800) as int);
  }

  /// livp 实况短片 presigned URL:can_download enforce(403 无权),
  /// 无 live_video_key 404 → 调用方落回静态缩略图(web 同口径)。
  Future<({String url, int expiresIn})> livePreviewUrl(String assetId) async {
    final r = await _api.http.get('/api/v1/assets/$assetId/live-preview-url');
    if (r.statusCode != 200) throw _api.err(r, '实况预览加载失败');
    final d = r.data as Map<String, dynamic>;
    return (url: d['url'] as String, expiresIn: (d['expires_in'] ?? 1800) as int);
  }

  Future<String> downloadLink(String assetId, {bool asAttachment = true}) async {
    final r = await _api.http.post('/api/v1/assets/$assetId/download-link',
        data: {'as_attachment': asAttachment});
    if (r.statusCode != 200) throw _api.err(r, '获取下载链接失败');
    return (r.data as Map<String, dynamic>)['url'] as String;
  }

  /// 下载到本地文件,返回文件;onProgress(0..1)。
  Future<File> downloadTo(String url, String savePath,
      {void Function(double)? onProgress}) async {
    await _api.presignedHttp.download(url, savePath, onReceiveProgress: (c, t) {
      if (t > 0 && onProgress != null) onProgress(c / t);
    });
    return File(savePath);
  }

  Future<void> delete(String assetId) async {
    final r = await _api.http.delete('/api/v1/assets/$assetId');
    // FastAPI DELETE 默认 204 No Content
    if (r.statusCode != 200 && r.statusCode != 204) throw _api.err(r, '删除失败');
  }

  /// 上传 [bytes] 为 [filename](livp 建议 content_type application/zip)。
  /// onPartsDone(completed, total) 供进度展示。失败时尽力 abort 半成品。
  Future<Asset> uploadBytes({
    required String folderId,
    required String filename,
    required List<int> bytes,
    String contentType = 'application/zip',
    void Function(int done, int total)? onPartsDone,
  }) async {
    final create = await _api.http.post('/api/v1/assets/uploads', data: {
      'folder_id': folderId,
      'filename': filename,
      'content_type': contentType,
      'size_bytes': bytes.length,
    });
    if (create.statusCode != 200) throw _api.err(create, '创建上传失败');
    final c = create.data as Map<String, dynamic>;
    final uploadId = c['upload_id'] as String;
    final key = c['key'] as String;
    final bucket = c['bucket'] as String;

    try {
      final totalParts =
          (bytes.length / MsApi.partSize).ceil().clamp(1, 1 << 30);
      final parts = <Map<String, dynamic>>[];
      for (var n = 1; n <= totalParts; n++) {
        final start = (n - 1) * MsApi.partSize;
        final end = (n * MsApi.partSize).clamp(0, bytes.length);
        final chunk = Uint8List.fromList(bytes.sublist(start, end));
        final sign = await _api.http.get(
            '/api/v1/assets/uploads/$uploadId/parts/$n',
            queryParameters: {'bucket': bucket, 'key': key});
        if (sign.statusCode != 200) throw _api.err(sign, '分片签名失败');
        final url = (sign.data as Map<String, dynamic>)['url'] as String;
        // ⚠ 必须显式带 Content-Length:Stream body 无长度时 dio 走 chunked 传输,
        // prod 链路(跳板机 nginx → MinIO)对 chunked PUT 回 411 Length Required
        // (iOS prod 实测踩坑;dev 链路容忍 chunked,故 PC 对 dev 验证时未暴露)
        final put = await _api.presignedHttp.put(
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
      final done = await _api.http.post(
          '/api/v1/assets/uploads/$uploadId/complete',
          data: {
            'upload_id': uploadId,
            'folder_id': folderId,
            'bucket': bucket,
            'key': key,
            'parts': parts,
          });
      if (done.statusCode != 200) throw _api.err(done, '完成上传失败');
      return Asset.fromJson(done.data as Map<String, dynamic>);
    } catch (e) {
      // 尽力清理半成品 multipart,不留 MinIO 悬挂分片
      try {
        await _api.http.delete('/api/v1/assets/uploads/$uploadId',
            queryParameters: {'bucket': bucket, 'key': key});
      } catch (_) {}
      rethrow;
    }
  }
}
