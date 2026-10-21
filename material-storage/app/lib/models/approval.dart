/// Approval — /api/v1/approvals 契约(B7;models/__init__.py ApprovalOut 实码)。
///
/// enrich 字段(target_name/parent_project_id/requester_name/folder_id)由 router
/// 层反查回填;旧后端缺键时为 null,卡片展示走兜底(类型 label + id 前 8 位)。
library;

class Approval {
  Approval({
    required this.id,
    required this.applicantUserId,
    required this.targetType,
    required this.targetId,
    required this.action,
    required this.durationSeconds,
    required this.reason,
    required this.status,
    required this.createdAt,
    this.approverUserId,
    this.decidedAt,
    this.decisionNote,
    this.targetName,
    this.parentProjectId,
    this.requesterName,
    this.folderId,
  });

  factory Approval.fromJson(Map<String, dynamic> j) => Approval(
        id: j['id'] as String,
        applicantUserId: j['applicant_user_id'] as String,
        targetType: j['target_type'] as String,
        targetId: j['target_id'] as String,
        action: j['action'] as String,
        durationSeconds: (j['duration_seconds'] as num?)?.toInt(),
        reason: (j['reason'] ?? '') as String,
        status: j['status'] as String,
        createdAt: (j['created_at'] ?? '') as String,
        approverUserId: j['approver_user_id'] as String?,
        decidedAt: j['decided_at'] as String?,
        decisionNote: j['decision_note'] as String?,
        targetName: j['target_name'] as String?,
        parentProjectId: j['parent_project_id'] as String?,
        requesterName: j['requester_name'] as String?,
        folderId: j['folder_id'] as String?,
      );

  final String id;
  final String applicantUserId;
  final String targetType; // asset / folder / sensitive_folder / project
  final String targetId;
  final String action; // download / access(后端枚举仅此两种)
  final int? durationSeconds; // null=永久(access 恒 null)
  final String reason;
  final String status; // pending / approved / rejected / revoked / expired
  final String createdAt;

  final String? approverUserId;
  final String? decidedAt;
  final String? decisionNote;

  // ── router enrich(反查,可能为 null)───────────────────────────────────
  final String? targetName; // 人类可读资源名
  final String? parentProjectId; // folder/asset 时的父项目
  final String? requesterName; // 申请人姓名(审批人决策关键信息)
  final String? folderId; // asset 目标所在 folder(跳转用)

  /// 展示名:target_name 优先,缺省「类型 id前8位…」(web 同兜底)。
  String get targetLabel {
    if (targetName != null && targetName!.isNotEmpty) return targetName!;
    return '$targetTypeLabel ${targetId.length > 8 ? targetId.substring(0, 8) : targetId}…';
  }

  /// 动作中文(web ACTION_LABEL 实况):access=访问 / download=下载;未知回 raw。
  String get actionLabel => kActionLabel[action] ?? action;

  /// 对象类型中文(web TARGET_TYPE_LABEL 实况);未知回 raw。
  String get targetTypeLabel => kTargetTypeLabel[targetType] ?? targetType;

  /// 状态中文(web STATUS_META label 实况);未知回 raw。
  String get statusLabel => kStatusLabel[status] ?? status;
}

/// action → 中文(web ACTION_LABEL)。
const kActionLabel = <String, String>{'access': '访问', 'download': '下载'};

/// target_type → 中文(web TARGET_TYPE_LABEL)。
const kTargetTypeLabel = <String, String>{
  'asset': '文件',
  'folder': '文件夹',
  'sensitive_folder': '敏感目录',
  'project': '项目',
};

/// status → 中文(web STATUS_META label 行)。
const kStatusLabel = <String, String>{
  'pending': '待审',
  'approved': '已批准',
  'rejected': '已拒绝',
  'revoked': '已撤销',
  'expired': '已过期',
};
