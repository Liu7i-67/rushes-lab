/// AssetsApi — /api/v1/assets 族薄封装:列表 / 上传三步编排 / 下载 / 删除。
/// 上传与 web Uppy 同款:sign → 分片 PUT(presigned,必带 Content-Length)
/// → complete;失败尽力 abort 半成品。
/// B3 起双轨:[uploadBytes] 仅留 livp 小包;大文件走 [uploadFile] 流式分片
/// (RandomAccessFile 逐片读,GB 级不 OOM)。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../models/models.dart';
import 'ms_api.dart';

/// 上传 complete 响应丢失(§4.1 已定稿):请求可能已达后端但响应丢失,
/// 后端 UploadUrlRequest 无幂等键无法查询确认 → 任务标 failed 并提示
/// 「可能已上传,请先在素材列表核实」,禁止自动重传造成重复资产。
class UploadAmbiguousException implements Exception {
  UploadAmbiguousException(this.cause);

  final Object cause;

  @override
  String toString() => 'UploadAmbiguousException: $cause';
}

/// complete 响应丢失判定(§4.1 已定稿,[uploadFile]/[uploadBytes] 两轨共用
/// 的异常分类收口):仅连接类异常(请求可能已达后端,响应丢失)→ true,
/// 调用方换抛 [UploadAmbiguousException](禁自动重传,提示核实);
/// 4xx/5xx(badResponse)照常透传后端 detail。连接类判定:dio 标准连接类
/// (receiveTimeout/connectionError)∪ unknown 下的传输断裂
/// (HttpException/SocketException——跳板机链路实测「Connection closed
/// while receiving data」落 unknown,语义同为响应丢失,fail-safe 提示
/// 核实优于误标失败诱发重复上传)。connectionTimeout=连接未建立、请求
/// 必未达;cancel=用户取消,两者不算。
bool completeResponseLost(DioException e) {
  final transportBroken =
      e.error is HttpException || e.error is SocketException;
  return e.type == DioExceptionType.receiveTimeout ||
      e.type == DioExceptionType.connectionError ||
      (e.type == DioExceptionType.unknown && transportBroken);
}

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

  /// 上传 [bytes] 为 [filename](livp 建议 content_type application/zip)。
  /// onPartsDone(completed, total) 供进度展示。失败时尽力 abort 半成品。
  /// B3:小包(livp)专用;cancelToken 取消=dio abort,清理/abort 不挂 token 照发。
  Future<Asset> uploadBytes({
    required String folderId,
    required String filename,
    required List<int> bytes,
    String contentType = 'application/zip',
    CancelToken? cancelToken,
    void Function(int done, int total)? onPartsDone,
  }) async {
    final create = await _api.http.post('/api/v1/assets/uploads', data: {
      'folder_id': folderId,
      'filename': filename,
      'content_type': contentType,
      'size_bytes': bytes.length,
    }, cancelToken: cancelToken);
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
            queryParameters: {'bucket': bucket, 'key': key},
            cancelToken: cancelToken);
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
          cancelToken: cancelToken,
        );
        final etag = put.headers.value('etag') ?? '';
        parts.add({'PartNumber': n, 'ETag': etag});
        if (onPartsDone != null) onPartsDone(n, totalParts);
      }
      // complete 响应丢失语义与 uploadFile 同源(P2-1:分类收口
      // [completeResponseLost] 两轨共用),命中换抛专用异常禁自动重传
      Response<dynamic> done;
      try {
        done = await _api.http.post(
            '/api/v1/assets/uploads/$uploadId/complete',
            data: {
              'upload_id': uploadId,
              'folder_id': folderId,
              'bucket': bucket,
              'key': key,
              'parts': parts,
            },
            cancelToken: cancelToken);
      } on DioException catch (e) {
        if (completeResponseLost(e)) throw UploadAmbiguousException(e);
        rethrow;
      }
      if (done.statusCode != 200) throw _api.err(done, '完成上传失败');
      return Asset.fromJson(done.data as Map<String, dynamic>);
    } catch (e) {
      // 尽力清理半成品 multipart,不留 MinIO 悬挂分片(不挂 cancelToken:
      // 取消场景下 abort 仍要发出;失败不阻塞取消态)
      try {
        await _api.http.delete('/api/v1/assets/uploads/$uploadId',
            queryParameters: {'bucket': bucket, 'key': key});
      } catch (_) {}
      rethrow;
    }
  }

  /// 分片区间表(纯函数可单测):(partNumber, start, end),end 不含。
  /// size 恰为 partSize 整数倍 → 末片满片不空发;size=0 → 单片空区间
  /// (与 uploadBytes 的 clamp(1,…) 同语义:0 字节文件也走一次空 PUT)。
  static List<(int, int, int)> partRanges(int size, int partSize) {
    final total = (size / partSize).ceil().clamp(1, 1 << 30);
    return [
      for (var n = 1; n <= total; n++)
        (n, (n - 1) * partSize, (n * partSize).clamp(0, size)),
    ];
  }

  /// RandomAccessFile.read 允许短读,循环读满 [count](EOF 提前断:
  /// 实际内容比声明短时交由后端 complete 校验报错)。
  static Future<Uint8List> _readExact(RandomAccessFile raf, int count) async {
    final out = BytesBuilder(copy: false);
    while (out.length < count) {
      final b = await raf.read(count - out.length);
      if (b.isEmpty) break;
      out.add(b);
    }
    return out.toBytes();
  }

  /// 流式分片上传本地文件(方案 §5 / B3 功能点 2):16MB 逐片 RandomAccessFile
  /// 读,整文件不进内存,GB 级视频不 OOM。三步编排+失败 abort 语义与
  /// [uploadBytes] 一致;分片 PUT 必带 Content-Length(prod 411 钉子)。
  /// [partSize] 仅测试注入可缩小,生产恒用 MsApi.partSize(16MB)。
  Future<Asset> uploadFile({
    required String folderId,
    required String filename,
    required String path,
    String contentType = 'application/octet-stream',
    CancelToken? cancelToken,
    int partSize = MsApi.partSize,
    void Function(int done, int total)? onProgress,
  }) async {
    final f = File(path);
    final size = await f.length();
    final create = await _api.http.post('/api/v1/assets/uploads', data: {
      'folder_id': folderId,
      'filename': filename,
      'content_type': contentType,
      'size_bytes': size,
    }, cancelToken: cancelToken);
    if (create.statusCode != 200) throw _api.err(create, '创建上传失败');
    final c = create.data as Map<String, dynamic>;
    final uploadId = c['upload_id'] as String;
    final key = c['key'] as String;
    final bucket = c['bucket'] as String;

    final raf = await f.open();
    try {
      final parts = <Map<String, dynamic>>[];
      for (final (n, start, end) in partRanges(size, partSize)) {
        // 片间主动检查取消:dio 空闲间隙(签名/读盘之间)的取消也能立即生效
        if (cancelToken?.isCancelled ?? false) {
          throw cancelToken!.cancelError ??
              DioException(requestOptions: RequestOptions(path: path));
        }
        await raf.setPosition(start);
        final chunk = await _readExact(raf, end - start);
        final sign = await _api.http.get(
            '/api/v1/assets/uploads/$uploadId/parts/$n',
            queryParameters: {'bucket': bucket, 'key': key},
            cancelToken: cancelToken);
        if (sign.statusCode != 200) throw _api.err(sign, '分片签名失败');
        final url = (sign.data as Map<String, dynamic>)['url'] as String;
        // ⚠ Content-Length 钉子同 uploadBytes(prod 链路 chunked PUT 回 411)
        final put = await _api.presignedHttp.put(
          url,
          data: Stream<Uint8List>.value(chunk),
          options: Options(
            headers: {Headers.contentLengthHeader: chunk.length},
          ),
          cancelToken: cancelToken,
        );
        final etag = put.headers.value('etag') ?? '';
        parts.add({'PartNumber': n, 'ETag': etag});
        if (onProgress != null) onProgress(end, size);
      }
      Response<dynamic> done;
      try {
        done = await _api.http.post(
            '/api/v1/assets/uploads/$uploadId/complete',
            data: {
              'upload_id': uploadId,
              'folder_id': folderId,
              'bucket': bucket,
              'key': key,
              'parts': parts,
            },
            cancelToken: cancelToken);
      } on DioException catch (e) {
        // complete 响应丢失(§4.1 功能点 8):分类收口在 [completeResponseLost]
        // (P2-1 起 uploadFile/uploadBytes 两轨共用),命中即上抛专用异常,
        // 调用方禁自动重传;4xx/5xx(badResponse)照常透传后端 detail。
        // 判定细则见该函数注释。
        if (completeResponseLost(e)) throw UploadAmbiguousException(e);
        rethrow;
      }
      if (done.statusCode != 200) throw _api.err(done, '完成上传失败');
      return Asset.fromJson(done.data as Map<String, dynamic>);
    } catch (e) {
      // 尽力清理半成品 multipart(不挂 cancelToken,取消场景下仍发出;
      // complete 实际已达后端时 abort 是无害空操作)——complete 丢失语义下
      // 依然 abort:若 complete 未达则清干净,已达则对象已成形、abort 落空
      try {
        await _api.http.delete('/api/v1/assets/uploads/$uploadId',
            queryParameters: {'bucket': bucket, 'key': key});
      } catch (_) {}
      rethrow;
    } finally {
      await raf.close();
    }
  }
}
