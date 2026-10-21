/// 管理后台审计/权限模板应用域出参契约(B8;api/app/routers/admin.py 实码):
/// AuditOut(resolved_names=details 白名单键补名派生列)与 apply-default
/// 部分成功结果(成功/失败条目形状勿混用,三字段显式可空)。
library;

/// AuditOut(audit 查询行;details 为自由 JSON,原样透传)。
class AuditEvent {
  AuditEvent({
    required this.id,
    required this.eventType,
    required this.eventTime,
    required this.actorUserId,
    required this.actorName,
    required this.actorOpenId,
    required this.targetAssetId,
    required this.targetAssetFilename,
    required this.targetProjectId,
    required this.targetProjectName,
    required this.targetMinioKey,
    required this.requestIp,
    required this.userAgent,
    required this.resolvedNames,
    required this.details,
  });

  factory AuditEvent.fromJson(Map<String, dynamic> j) => AuditEvent(
        id: j['id'] as String,
        eventType: (j['event_type'] ?? '') as String,
        eventTime: (j['event_time'] ?? '') as String,
        actorUserId: j['actor_user_id'] as String?,
        actorName: j['actor_name'] as String?,
        actorOpenId: j['actor_open_id'] as String?,
        targetAssetId: j['target_asset_id'] as String?,
        targetAssetFilename: j['target_asset_filename'] as String?,
        targetProjectId: j['target_project_id'] as String?,
        targetProjectName: j['target_project_name'] as String?,
        targetMinioKey: j['target_minio_key'] as String?,
        requestIp: j['request_ip'] as String?,
        userAgent: j['user_agent'] as String?,
        resolvedNames: (j['resolved_names'] ?? const {}) as Map<String, dynamic>,
        details: (j['details'] ?? const {}) as Map<String, dynamic>,
      );

  final String id;
  final String eventType;
  final String eventTime;
  final String? actorUserId;
  final String? actorName;
  final String? actorOpenId;
  final String? targetAssetId;

  /// W2b 批量反查的人类可读名(purge 后/历史行回 null,展示回落 id 片段)。
  final String? targetAssetFilename;
  final String? targetProjectId;
  final String? targetProjectName;
  final String? targetMinioKey;
  final String? requestIp;
  final String? userAgent;

  /// details 白名单键 → 纯显示名(查不到/垃圾值的键不进 dict,前端回落裸值)。
  final Map<String, dynamic> resolvedNames;
  final Map<String, dynamic> details;

  /// details 键补名:resolved_names 命中优先,否则原值。
  String nameOf(String key) =>
      resolvedNames[key] as String? ?? (details[key]?.toString() ?? '');
}

/// ApplyDefaultResultItem(单项目结果:成功 = applied/skipped_stale,失败 = error)。
class ApplyDefaultResultItem {
  ApplyDefaultResultItem({
    required this.projectId,
    this.applied,
    this.skippedStale,
    this.error,
  });

  factory ApplyDefaultResultItem.fromJson(Map<String, dynamic> j) =>
      ApplyDefaultResultItem(
        projectId: j['project_id'] as String,
        applied: j['applied'] as int?,
        skippedStale: j['skipped_stale'] as int?,
        error: j['error'] as String?,
      );

  final String projectId;
  final int? applied;
  final int? skippedStale;
  final String? error;

  bool get isFailed => error != null;
}

/// ApplyDefaultOut(逐项目结果 + 汇总;叠加不删语义,部分成功)。
class ApplyDefaultResult {
  ApplyDefaultResult({
    required this.results,
    required this.totalApplied,
    required this.totalSkipped,
  });

  factory ApplyDefaultResult.fromJson(Map<String, dynamic> j) =>
      ApplyDefaultResult(
        results: ((j['results'] ?? const []) as List)
            .map((e) =>
                ApplyDefaultResultItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        totalApplied: (j['total_applied'] ?? 0) as int,
        totalSkipped: (j['total_skipped'] ?? 0) as int,
      );

  final List<ApplyDefaultResultItem> results;
  final int totalApplied;
  final int totalSkipped;

  int get failedCount => results.where((r) => r.isFailed).length;
}
