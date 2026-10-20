/// ApprovalsApi — POST /api/v1/approvals 薄封装(B5 申请权限;契约
/// api/app/routers/approvals.py + models ApprovalCreateIn)。
/// action 枚举实况仅 download|access(**后端无「编辑」动作**);duration_seconds
/// ge=60(仅 download 必填,access 可空=永久);reason 4~2000 字,422/400
/// detail 由 [MsApi.err] 透传;**5xx 不经 guard5xx**:DioException.badResponse
/// 原样上抛,调用方 catch 渲染;全 API 层 5xx 统一兜底=已知技术债,B9 收尾批处理。
library;

import 'ms_api.dart';

class ApprovalsApi {
  ApprovalsApi(this._api);

  final MsApi _api;

  /// 有效期预设(web RequestAccessModal DURATION_PRESETS 实况;自定义档不搬,
  /// App 用五档预设,默认 1 小时)。
  static const durationPresets = <(String, int)>[
    ('15 分钟', 15 * 60),
    ('1 小时', 3600),
    ('1 天', 86400),
    ('7 天', 7 * 86400),
    ('30 天', 30 * 86400),
  ];

  /// target_type:sensitive_folder|asset|project|folder;action:download|access。
  /// action=access 后端仅收 target_type=sensitive_folder(否则 400);
  /// duration_seconds 仅 download 携带(access=永久,键省略)。
  Future<void> create({
    required String targetType,
    required String targetId,
    required String action,
    int? durationSeconds,
    required String reason,
  }) async {
    final r = await _api.http.post('/api/v1/approvals', data: {
      'target_type': targetType,
      'target_id': targetId,
      'action': action,
      'duration_seconds': ?durationSeconds,
      'reason': reason,
    });
    // 后端 201 Created
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw _api.err(r, '提交失败');
    }
  }
}
