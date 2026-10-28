/// RiskApi — /api/v1/admin/risk 族薄封装(risk-control-module-plan §3.1/§3.2):
/// 锁定快照列表(GET /locks,只读不写审计)与单 IP 解锁
/// (POST /locks/ips/{ip}/unlock;ip 不做格式校验透传,DEL 幂等,admin-only)。
/// 403/429 detail 经 [_api.err] 透传页面 toast / 错误态;5xx 走全局报错页。
library;

import '../../models/risk.dart';
import 'ms_api.dart';

class RiskApi {
  RiskApi(this._api);

  final MsApi _api;

  /// GET /locks — 当前全部锁快照(users 按 ttl 降序 + ips 同;两列表空 =
  /// 无任何锁)。刷新只靠挂载拉取与手动刷新,不轮询(D1)。
  Future<RiskLocks> fetchRiskLocks() async {
    final r = await _api.http.get('/api/v1/admin/risk/locks');
    if (r.statusCode != 200) throw _api.err(r, '风控锁定列表加载失败');
    return RiskLocks.fromJson(r.data as Map<String, dynamic>);
  }

  /// POST /locks/ips/{ip}/unlock — 解除单 IP 登录锁(连带清该 IP 失败计数;
  /// 幂等,was_locked=锁 key 曾存在)。[ip] 不做格式校验,路径透传(D3,
  /// 照 directory_api userId 同款裸插值;'unknown' 哨兵同样可解)。
  Future<RiskIpUnlockResult> unlockIp(String ip) async {
    final r = await _api.http.post('/api/v1/admin/risk/locks/ips/$ip/unlock');
    if (r.statusCode != 200) throw _api.err(r, '解除 IP 锁定失败');
    return RiskIpUnlockResult.fromJson(r.data as Map<String, dynamic>);
  }
}
