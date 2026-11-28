/// AssetsUploadApi — 上传三步编排(B3;自 assets_api.dart 物理拆分:
/// 主文件过 300 行硬顶,API 面不变——AssetsApi 以同名委托方法透传,
/// 调用方仍走 `api.assets.uploadFile/uploadBytes`,静态 partRanges 同名透传)。
///
/// 上传与 web Uppy 同款:sign → 分片 PUT(必带 Content-Length)→ complete,
/// 失败尽力 abort;B3 起双轨([uploadBytes] livp 小包 / [uploadFile] 流式分片)。
///
/// feat/ios-bg-upload 包 C:分片 PUT 执行器抽象为 PartPutChannel——非 iOS
/// 平台走 dio 通道(原装配原样搬移,行为零变化);iOS 走 bg 通道(系统
/// background URLSession,切后台持续上传)。batchCapable 通道(仅 iOS bg)
/// 走「预签窗口」循环([kSignAheadWindow]):窗口内逐片 读chunk→sign→入队
/// (不等完成),窗口末统一收敛 etag/异常——挂起期间传输不依赖 Dart 存活,
/// 窗口深度保证有 4 片已在系统队列里;窗口内单分片失败先取消同窗兄弟分片
/// 原生任务(验收修正 P2-2),失败收尾 abort + 清会话临时目录(P2-3)。
/// 协议钉子全部保留:显式 Content-Length、partRanges、_readExact、
/// 片间取消检查、UploadAmbiguousException、catch 尽力 abort。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../models/models.dart';
import '../transfers/part_put_channel.dart';
import 'ms_api.dart';

/// 预签窗口深度 K(D3):batch 通道一次预签并入队 K 片。4×16MB=64MB 窗口
/// 在分片预签 TTL(7200s,F8)内无过期风险;挂起期间窗口内分片传输不依赖
/// App 进程存活,唤醒/回前台后推进下一窗口。
const int kSignAheadWindow = 4;

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

class AssetsUploadApi {
  AssetsUploadApi(this._api);

  final MsApi _api;

  /// 上传 [bytes] 为 [filename](livp 建议 content_type application/zip)。
  /// onPartsDone(completed, total) 供进度展示。失败时尽力 abort 半成品。
  /// B3:小包(livp)专用;cancelToken 取消=dio abort,清理/abort 不挂 token 照发。
  /// [onSessionCreated] 在 create 成功后回调一次(feat/ios-bg-upload 包 D:
  /// 会话三元组持久化用);[channel] 仅供单测注入(缺省工厂默认实例)。
  Future<Asset> uploadBytes({
    required String folderId,
    required String filename,
    required List<int> bytes,
    String contentType = 'application/zip',
    CancelToken? cancelToken,
    void Function(int done, int total)? onPartsDone,
    void Function(String uploadId, String bucket, String key)? onSessionCreated,
    @visibleForTesting PartPutChannel? channel,
  }) async {
    final create = await _api.http.post(
      '/api/v1/assets/uploads',
      data: {
        'folder_id': folderId,
        'filename': filename,
        'content_type': contentType,
        'size_bytes': bytes.length,
      },
      cancelToken: cancelToken,
    );
    if (create.statusCode != 200) throw _api.err(create, '创建上传失败');
    final c = create.data as Map<String, dynamic>;
    final uploadId = c['upload_id'] as String;
    final key = c['key'] as String;
    final bucket = c['bucket'] as String;
    onSessionCreated?.call(uploadId, bucket, key);

    final ch = _resolveChannel(channel);
    try {
      final ranges = partRanges(bytes.length, MsApi.partSize);
      final parts = await _putParts(
        channel: ch,
        uploadId: uploadId,
        bucket: bucket,
        key: key,
        ranges: ranges,
        cancelToken: cancelToken,
        readChunk: (n, start, end) async =>
            Uint8List.fromList(bytes.sublist(start, end)),
        onPartDone: onPartsDone == null
            ? null
            : (range, total) => onPartsDone(range.$1, total),
      );
      // complete 响应丢失语义与 uploadFile 同源(P2-1:分类收口
      // [completeResponseLost] 两轨共用),命中换抛专用异常禁自动重传
      return await _completeSession(
        folderId: folderId,
        uploadId: uploadId,
        bucket: bucket,
        key: key,
        parts: parts,
        cancelToken: cancelToken,
      );
    } catch (e) {
      // 尽力清理半成品 multipart,不留 MinIO 悬挂分片(不挂 cancelToken:
      // 取消场景下 abort 仍要发出;失败不阻塞取消态);P2-3:追加会话临时
      // 分片目录清理(bg 通道删目录树,dio 通道 no-op;自带 try-catch 不抛)
      await abortUpload(uploadId, bucket, key);
      try {
        await ch.cleanupUpload(uploadId);
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
  /// [onSessionCreated]/[channel] 见 [uploadBytes]。
  Future<Asset> uploadFile({
    required String folderId,
    required String filename,
    required String path,
    String contentType = 'application/octet-stream',
    CancelToken? cancelToken,
    int partSize = MsApi.partSize,
    void Function(int done, int total)? onProgress,
    void Function(String uploadId, String bucket, String key)? onSessionCreated,
    @visibleForTesting PartPutChannel? channel,
  }) async {
    final f = File(path);
    final size = await f.length();
    final create = await _api.http.post(
      '/api/v1/assets/uploads',
      data: {
        'folder_id': folderId,
        'filename': filename,
        'content_type': contentType,
        'size_bytes': size,
      },
      cancelToken: cancelToken,
    );
    if (create.statusCode != 200) throw _api.err(create, '创建上传失败');
    final c = create.data as Map<String, dynamic>;
    final uploadId = c['upload_id'] as String;
    final key = c['key'] as String;
    final bucket = c['bucket'] as String;
    onSessionCreated?.call(uploadId, bucket, key);

    final ch = _resolveChannel(channel);
    final raf = await f.open();
    try {
      final parts = await _putParts(
        channel: ch,
        uploadId: uploadId,
        bucket: bucket,
        key: key,
        ranges: partRanges(size, partSize),
        cancelToken: cancelToken,
        readChunk: (n, start, end) async {
          // 片间主动检查取消:dio 空闲间隙(签名/读盘之间)的取消也能立即生效
          if (cancelToken?.isCancelled ?? false) {
            throw cancelToken!.cancelError ??
                DioException(requestOptions: RequestOptions(path: path));
          }
          await raf.setPosition(start);
          return _readExact(raf, end - start);
        },
        onPartDone: onProgress == null
            ? null
            : (range, total) => onProgress(range.$3, size),
      );
      // complete 响应丢失(§4.1 功能点 8):分类收口在 [completeResponseLost]
      // (P2-1 起 uploadFile/uploadBytes 两轨共用),命中即上抛专用异常,
      // 调用方禁自动重传;4xx/5xx(badResponse)照常透传后端 detail。
      // 判定细则见该函数注释。
      return await _completeSession(
        folderId: folderId,
        uploadId: uploadId,
        bucket: bucket,
        key: key,
        parts: parts,
        cancelToken: cancelToken,
      );
    } catch (e) {
      // 尽力清理半成品 multipart(不挂 cancelToken,取消场景下仍发出;
      // complete 实际已达后端时 abort 是无害空操作)——complete 丢失语义下
      // 依然 abort:若 complete 未达则清干净,已达则对象已成形、abort 落空;
      // P2-3:追加会话临时分片目录清理(bg 删目录树,dio no-op,不抛)
      await abortUpload(uploadId, bucket, key);
      try {
        await ch.cleanupUpload(uploadId);
      } catch (_) {}
      rethrow;
    } finally {
      await raf.close();
    }
  }

  /// 尽力 abort 悬挂 multipart(提取自既有 catch 语义,公开复用:
  /// feat/ios-bg-upload 包 D 进程恢复路径对「进程中断且已有 uploadId」的
  /// 任务也会调用)。不挂 cancelToken(取消场景下仍要发出),失败静默——
  /// complete 实际已达后端时 abort 是无害空操作。
  Future<void> abortUpload(String uploadId, String bucket, String key) async {
    try {
      await _api.http.delete(
        '/api/v1/assets/uploads/$uploadId',
        queryParameters: {'bucket': bucket, 'key': key},
      );
    } catch (_) {}
  }

  /// 缺省通道:工厂按平台分流(iOS → bg;其余 → dio,注入 presignedHttp)。
  PartPutChannel _resolveChannel(PartPutChannel? injected) =>
      injected ?? createPartPutChannel(presignedHttp: _api.presignedHttp);

  /// 分片签名 GET(sign → url),失败透传 [_api.err] 中文兜底。
  Future<String> _signPart(
    String uploadId,
    int n,
    String bucket,
    String key,
    CancelToken? cancelToken,
  ) async {
    final sign = await _api.http.get(
      '/api/v1/assets/uploads/$uploadId/parts/$n',
      queryParameters: {'bucket': bucket, 'key': key},
      cancelToken: cancelToken,
    );
    if (sign.statusCode != 200) throw _api.err(sign, '分片签名失败');
    return (sign.data as Map<String, dynamic>)['url'] as String;
  }

  /// complete 步骤(两轨共用):含响应丢失分类([UploadAmbiguousException])
  /// 与 4xx detail 透传,语义与拆分前逐行一致。
  Future<Asset> _completeSession({
    required String folderId,
    required String uploadId,
    required String bucket,
    required String key,
    required List<Map<String, dynamic>> parts,
    CancelToken? cancelToken,
  }) async {
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
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      if (completeResponseLost(e)) throw UploadAmbiguousException(e);
      rethrow;
    }
    if (done.statusCode != 200) throw _api.err(done, '完成上传失败');
    return Asset.fromJson(done.data as Map<String, dynamic>);
  }

  /// 分片循环(两轨共用):batch 通道(仅 iOS bg)走预签窗口循环;
  /// 其余(dio 通道)走现顺序循环——两分支的 读chunk→sign→PUT 顺序、
  /// parts 组装与进度口径都与拆分前一致。
  ///
  /// batch 窗口:窗口内逐片 读chunk→sign→channel.put(入队,不等完成),
  /// 窗口末 Future.wait 收敛 etag/异常后推进、按窗口末片上报进度(D8:
  /// 进度按「已完成分片」推进,粒度粗化可接受);单分片失败 → 先取消同窗
  /// 其余已入队原生分片(P2-2,服务端已随 abort,继续传只占后台带宽)→
  /// Future.wait 上抛 → 整任务失败进调用方 catch 尽力 abort + 清临时目录
  /// (P2-3)。
  Future<List<Map<String, dynamic>>> _putParts({
    required PartPutChannel channel,
    required String uploadId,
    required String bucket,
    required String key,
    required List<(int, int, int)> ranges,
    required Future<Uint8List> Function(int partNumber, int start, int end)
    readChunk,
    CancelToken? cancelToken,
    required void Function((int, int, int) range, int totalParts)? onPartDone,
  }) async {
    final totalParts = ranges.length;
    final parts = <Map<String, dynamic>>[];
    if (channel.batchCapable) {
      for (var i = 0; i < ranges.length; i += kSignAheadWindow) {
        final window = ranges.sublist(
          i,
          (i + kSignAheadWindow).clamp(0, ranges.length),
        );
        final pending = <Future<PartPutResult>>[];
        for (final (n, start, end) in window) {
          final chunk = await readChunk(n, start, end);
          final url = await _signPart(uploadId, n, bucket, key, cancelToken);
          final fut = channel.put(
            PartPutRequest(
              url: url,
              chunk: chunk,
              uploadId: uploadId,
              partNumber: n,
              cancelToken: cancelToken,
            ),
          );
          // 立刻挂错误监听(语义 no-op):窗口内「先入队后统一收敛」,若某片
          // 在 Future.wait 挂上监听前就已失败,Dart 会把它判成 unhandled
          // async error(生产里打进全局错误上报)。ignore 的监听不影响
          // 下方 Future.wait 照常收割该错误(监听是多方广播,不是吞掉)。
          fut.ignore();
          pending.add(fut);
        }
        // 窗口收敛:全部 settle 后推进(首个异常在此上抛,等价整任务失败)
        final List<PartPutResult> results;
        try {
          results = await Future.wait(pending);
        } catch (_) {
          // P2-2:窗口内单分片失败 → 先取消同窗其余已入队的原生分片任务
          // (服务端会话随调用方 abort,放任兄弟分片继续传只占后台带宽;
          // cancelForToken 对已终态任务 no-op,dio 通道该方法为 no-op,无需
          // 区分平台),再 rethrow 原异常——顺序语义:失败→兄弟分片原生
          // 任务取消→调用方 abort 服务端
          if (cancelToken != null) await channel.cancelForToken(cancelToken);
          rethrow;
        }
        for (var j = 0; j < window.length; j++) {
          parts.add({'PartNumber': window[j].$1, 'ETag': results[j].etag});
        }
        onPartDone?.call(window.last, totalParts);
      }
      return parts;
    }
    // 非 batch:现顺序循环(dio 通道,行为逐字节等价)
    for (final (n, start, end) in ranges) {
      final chunk = await readChunk(n, start, end);
      final url = await _signPart(uploadId, n, bucket, key, cancelToken);
      final result = await channel.put(
        PartPutRequest(
          url: url,
          chunk: chunk,
          uploadId: uploadId,
          partNumber: n,
          cancelToken: cancelToken,
        ),
      );
      parts.add({'PartNumber': n, 'ETag': result.etag});
      onPartDone?.call((n, start, end), totalParts);
    }
    return parts;
  }
}
