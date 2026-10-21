/// AssetsApi — /api/v1/assets 族薄封装:列表 / 盲搜 / 下载 / 删除。
/// 上传三步编排(B3)拆至 assets_upload_api.dart(300 行硬顶拆分),
/// 本类同名委托透传,调用方面不变(uploadFile/uploadBytes/partRanges)。
library;

import 'dart:io';

import 'package:dio/dio.dart';

import '../../models/models.dart';
import 'assets_upload_api.dart';
import 'ms_api.dart';

export 'assets_upload_api.dart'
    show UploadAmbiguousException, completeResponseLost;

class AssetsApi {
  AssetsApi(this._api);

  final MsApi _api;

  late final _upload = AssetsUploadApi(_api);

  // ── 上传三步编排(B3)→ assets_upload_api.dart 同名委托(API 面不变)──

  /// livp 小包直传;签名/清理/complete 丢失语义见 [AssetsUploadApi.uploadBytes]。
  Future<Asset> uploadBytes({
    required String folderId,
    required String filename,
    required List<int> bytes,
    String contentType = 'application/zip',
    CancelToken? cancelToken,
    void Function(int done, int total)? onPartsDone,
  }) =>
      _upload.uploadBytes(
        folderId: folderId,
        filename: filename,
        bytes: bytes,
        contentType: contentType,
        cancelToken: cancelToken,
        onPartsDone: onPartsDone,
      );

  /// 流式分片上传;[AssetsUploadApi.uploadFile]。
  Future<Asset> uploadFile({
    required String folderId,
    required String filename,
    required String path,
    String contentType = 'application/octet-stream',
    CancelToken? cancelToken,
    int partSize = MsApi.partSize,
    void Function(int done, int total)? onProgress,
  }) =>
      _upload.uploadFile(
        folderId: folderId,
        filename: filename,
        path: path,
        contentType: contentType,
        cancelToken: cancelToken,
        partSize: partSize,
        onProgress: onProgress,
      );

  /// 分片区间表(纯函数)→ [AssetsUploadApi.partRanges]。
  static List<(int, int, int)> partRanges(int size, int partSize) =>
      AssetsUploadApi.partRanges(size, partSize);

  /// 跨 folder 盲搜(B7 §8.8;GET /assets/search?q=;契约 assets.py 实码:
  /// q 必填 1~200 字,命中文件名/user_labels/notes;后端按 can_view 过滤,
  /// limit 缺省 50=web 同款截断口径)。空 q(去空白后)客户端直接回空,
  /// 不打注定 400 的请求。cancelToken:防抖换词时取消过期请求(§8.8)。
  Future<List<SearchResult>> search(String q,
      {int limit = 50, CancelToken? cancelToken}) async {
    final query = q.trim();
    if (query.isEmpty) return const [];
    final r = await _api.http.get('/api/v1/assets/search',
        queryParameters: {'q': query, 'limit': limit},
        cancelToken: cancelToken);
    if (r.statusCode != 200) throw _api.err(r, '搜索失败');
    return ((r.data as List? ?? const []))
        .map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

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

  /// 下载到本地文件,返回文件;onProgress(0..1);cancelToken 取消=dio abort 即刻落终态。
  Future<File> downloadTo(String url, String savePath,
      {void Function(double)? onProgress, CancelToken? cancelToken}) async {
    await _api.presignedHttp.download(url, savePath,
        onReceiveProgress: (c, t) {
      if (t > 0 && onProgress != null) onProgress(c / t);
    }, cancelToken: cancelToken);
    return File(savePath);
  }

  Future<void> delete(String assetId) async {
    final r = await _api.http.delete('/api/v1/assets/$assetId');
    // FastAPI DELETE 默认 204 No Content
    if (r.statusCode != 200 && r.statusCode != 204) throw _api.err(r, '删除失败');
  }

  // B5 操作端点(updateMeta/batchPrefix/batchMove/listTrash/restore)拆至 assets_ops_api.dart(MsApi.ops)。
}
