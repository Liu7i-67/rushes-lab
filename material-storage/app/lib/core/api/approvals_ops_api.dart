/// ApprovalOpsApi — /api/v1/approvals 列表与决策(B7 §8.6;契约
/// api/app/routers/approvals.py 实码)。提交申请在 approvals_api.dart(MsApi.approvals)。
///
/// scope 口径钉子(方案 v2.2 修正):待我审批=scope=all **&status=pending**;
/// 我发起的=scope=self(后端按申请人过滤,勿用它做待审列表)。
/// 决策端点 POST /{id}/approve | /{id}/reject,入参 {decision_note?}(可空),
/// 响应 ApprovalOut;403(非目标管理者)/404/409 detail 透传由 [MsApi.err]。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class ApprovalOpsApi {
  ApprovalOpsApi(this._api);

  final MsApi _api;

  /// 审批列表。scope: self(默认,后端缺省)| all;status: pending/approved/
  /// rejected/revoked/expired(缺省=不过滤);按 created_at 倒序。
  Future<List<Approval>> list({
    String scope = 'self',
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    final r = await _api.http.get('/api/v1/approvals', queryParameters: {
      'scope': scope,
      'status': ?status,
      'limit': limit,
      'offset': offset,
    });
    if (r.statusCode != 200) throw _api.err(r, '审批列表加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => Approval.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 批准;decisionNote 可选备注(决策人留言)。
  Future<Approval> approve(String id, {String? decisionNote}) =>
      _decide(id, approve: true, decisionNote: decisionNote);

  /// 拒绝;decisionNote 可选原因。
  Future<Approval> reject(String id, {String? decisionNote}) =>
      _decide(id, approve: false, decisionNote: decisionNote);

  Future<Approval> _decide(
    String id, {
    required bool approve,
    String? decisionNote,
  }) async {
    final r = await _api.http
        .post('/api/v1/approvals/$id/${approve ? 'approve' : 'reject'}', data: {
      'decision_note': ?decisionNote,
    });
    if (r.statusCode != 200) throw _api.err(r, approve ? '批准失败' : '拒绝失败');
    return Approval.fromJson(r.data as Map<String, dynamic>);
  }
}
