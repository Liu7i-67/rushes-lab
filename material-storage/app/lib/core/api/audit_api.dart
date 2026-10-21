/// AuditApi — /api/v1/admin/audit 族薄封装(B8;admin.py 实码):
/// 查询(event_type/actor_user_id/project_id/from/to 精确过滤 + limit/offset)
/// 与 export.csv(同参;响应=text/csv 流,UTF-8 BOM)。
///
/// CSV 钉子:必须 dio 带会话下载(cookie 在 DioHttpCookieJar),禁 url_launcher
/// ——系统浏览器不带会话 cookie 必 401;落盘矩阵复用 services 落盘件
/// (Android media_store_plus Downloads / iOS share_plus,audit 页装配)。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../models/models.dart';
import 'ms_api.dart';

/// 审计筛选条件(列表与 CSV 导出共用同一组参数,web 同款)。
class AuditFilter {
  const AuditFilter({
    this.eventType = '',
    this.actorUserId = '',
    this.projectId = '',
    this.from,
    this.to,
  });

  final String eventType;
  final String actorUserId;
  final String projectId;

  /// ISO8601 UTC(web toISOString 同款);from <= event_time <= to。
  final String? from;
  final String? to;

  Map<String, dynamic> toQuery() => {
        if (eventType.isNotEmpty) 'event_type': eventType,
        if (actorUserId.isNotEmpty) 'actor_user_id': actorUserId,
        if (projectId.isNotEmpty) 'project_id': projectId,
        if (from != null) 'from': from,
        if (to != null) 'to': to,
      };
}

class AuditApi {
  AuditApi(this._api);

  final MsApi _api;

  /// GET /audit — 查询(倒序分页;页行带补名派生列)。
  Future<List<AuditEvent>> list({
    AuditFilter filter = const AuditFilter(),
    int limit = 30,
    int offset = 0,
  }) async {
    final r = await _api.http.get('/api/v1/admin/audit', queryParameters: {
      ...filter.toQuery(),
      'limit': limit,
      'offset': offset,
    });
    if (r.statusCode != 200) throw _api.err(r, '审计记录加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => AuditEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /audit/export.csv — 同参导出,**dio 带会话**拉字节流(上限 5 万行,
  /// 后端 StreamingResponse 截断)。回传 `(字节, Content-Disposition 原文)`:
  /// 文件名解析交 audit_export.csvFilenameFromDisposition(解析失败回落时间戳
  /// 名),不丢弃响应头(P2-5)。4xx detail 照常透传(403 非 admin 深链兜底)。
  Future<(Uint8List, String?)> exportCsv(
      {AuditFilter filter = const AuditFilter()}) async {
    final r = await _api.guard5xx(
      _api.http.get('/api/v1/admin/audit/export.csv',
          queryParameters: filter.toQuery(),
          options: Options(responseType: ResponseType.bytes)),
      '导出 CSV 失败',
    );
    if (r.statusCode != 200) throw _api.err(r, '导出 CSV 失败');
    final data = r.data;
    final bytes = data is Uint8List
        ? data
        : Uint8List.fromList((data as List).cast<int>());
    return (bytes, r.headers.value('content-disposition'));
  }
}
