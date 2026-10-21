/// 管理后台百度备份任务域出参契约(B8;admin.py AdminBaiduTask* 实码):
/// 全系统任务列表/详情(调度观测字段)/文件明细(manifest 分页)。
/// 聚合列 enumerating 阶段为 NULL → 序列化统一 0 兜底,模型直接吃 int。
library;

import 'baidu_task.dart' show BaiduFileOpRow;

/// 任务所属用户(username 可空:飞书老账号无本地用户名)。
class AdminTaskUser {
  AdminTaskUser({required this.id, required this.username, required this.name});

  factory AdminTaskUser.fromJson(Map<String, dynamic> j) => AdminTaskUser(
        id: j['id'] as String,
        username: j['username'] as String?,
        name: (j['name'] ?? '') as String,
      );

  final String id;
  final String? username;
  final String name;
}

/// 项目 / 目标文件夹引用(target_folder 夹已删 → 整个为 null)。
class AdminTaskRef {
  AdminTaskRef({required this.id, required this.name});

  factory AdminTaskRef.fromJson(Map<String, dynamic> j) =>
      AdminTaskRef(id: j['id'] as String, name: (j['name'] ?? '') as String);

  final String id;
  final String name;
}

/// AdminBaiduTaskOut(任务条目;fail_reason 已截 200)。
class AdminBaiduTask {
  AdminBaiduTask({
    required this.id,
    required this.user,
    required this.status,
    required this.sourceDir,
    required this.project,
    this.targetFolder,
    this.totalFiles = 0,
    this.doneFiles = 0,
    this.failedFiles = 0,
    this.skippedFiles = 0,
    this.cancelledFiles = 0,
    this.totalBytes = 0,
    this.doneBytes = 0,
    required this.createdAt,
    required this.updatedAt,
    this.failReason,
    this.cancelRequested = false,
  });

  factory AdminBaiduTask.fromJson(Map<String, dynamic> j) => AdminBaiduTask(
        id: j['id'] as String,
        user: AdminTaskUser.fromJson(j['user'] as Map<String, dynamic>),
        status: (j['status'] ?? '') as String,
        sourceDir: (j['source_dir'] ?? '') as String,
        project: AdminTaskRef.fromJson(j['project'] as Map<String, dynamic>),
        targetFolder: j['target_folder'] == null
            ? null
            : AdminTaskRef.fromJson(j['target_folder'] as Map<String, dynamic>),
        totalFiles: (j['total_files'] ?? 0) as int,
        doneFiles: (j['done_files'] ?? 0) as int,
        failedFiles: (j['failed_files'] ?? 0) as int,
        skippedFiles: (j['skipped_files'] ?? 0) as int,
        cancelledFiles: (j['cancelled_files'] ?? 0) as int,
        totalBytes: (j['total_bytes'] ?? 0) as int,
        doneBytes: (j['done_bytes'] ?? 0) as int,
        createdAt: (j['created_at'] ?? '') as String,
        updatedAt: (j['updated_at'] ?? '') as String,
        failReason: j['fail_reason'] as String?,
        cancelRequested: (j['cancel_requested'] ?? false) as bool,
      );

  final String id;
  final AdminTaskUser user;
  final String status;
  final String sourceDir;
  final AdminTaskRef project;
  final AdminTaskRef? targetFolder;
  final int totalFiles;
  final int doneFiles;
  final int failedFiles;
  final int skippedFiles;
  final int cancelledFiles;
  final int totalBytes;
  final int doneBytes;
  final String createdAt;
  final String updatedAt;
  final String? failReason;
  final bool cancelRequested;

  bool get isActive => status == 'enumerating' || status == 'running';

  /// 进度 =(done+skipped+cancelled)/total;total=0 时 completed(空目录)
  /// 视为 100%,其余状态 0(web AdminBaiduTasksPage.taskPct 同口径)。
  int get progressPct {
    final processed = doneFiles + skippedFiles + cancelledFiles;
    return totalFiles > 0
        ? (processed * 100 / totalFiles).round()
        : (status == 'completed' ? 100 : 0);
  }
}

/// 任务关联绑定行(baidu_uid 是 BaiduBinding 列名)。
class AdminTaskBinding {
  AdminTaskBinding({required this.id, required this.baiduUid, required this.status});

  factory AdminTaskBinding.fromJson(Map<String, dynamic> j) =>
      AdminTaskBinding(
        id: j['id'] as String,
        baiduUid: (j['baidu_uid'] ?? '') as String,
        status: (j['status'] ?? '') as String,
      );

  final String id;
  final String baiduUid;
  final String status;
}

/// AdminBaiduTaskDetailOut = 列表条目 + 快照/绑定行/调度观测字段。
class AdminBaiduTaskDetail extends AdminBaiduTask {
  AdminBaiduTaskDetail({
    required super.id,
    required super.user,
    required super.status,
    required super.sourceDir,
    required super.project,
    super.targetFolder,
    super.totalFiles = 0,
    super.doneFiles = 0,
    super.failedFiles = 0,
    super.skippedFiles = 0,
    super.cancelledFiles = 0,
    super.totalBytes = 0,
    super.doneBytes = 0,
    required super.createdAt,
    required super.updatedAt,
    super.failReason,
    super.cancelRequested = false,
    this.boundBaiduUid,
    this.binding,
    this.cancelReason,
    this.retryCount = 0,
    this.enumDone = false,
    this.dispatchedAt,
    this.roundStartedAt,
    this.leaseUntil,
    this.runnerId,
  });

  factory AdminBaiduTaskDetail.fromJson(Map<String, dynamic> j) =>
      AdminBaiduTaskDetail(
        id: j['id'] as String,
        user: AdminTaskUser.fromJson(j['user'] as Map<String, dynamic>),
        status: (j['status'] ?? '') as String,
        sourceDir: (j['source_dir'] ?? '') as String,
        project: AdminTaskRef.fromJson(j['project'] as Map<String, dynamic>),
        targetFolder: j['target_folder'] == null
            ? null
            : AdminTaskRef.fromJson(j['target_folder'] as Map<String, dynamic>),
        totalFiles: (j['total_files'] ?? 0) as int,
        doneFiles: (j['done_files'] ?? 0) as int,
        failedFiles: (j['failed_files'] ?? 0) as int,
        skippedFiles: (j['skipped_files'] ?? 0) as int,
        cancelledFiles: (j['cancelled_files'] ?? 0) as int,
        totalBytes: (j['total_bytes'] ?? 0) as int,
        doneBytes: (j['done_bytes'] ?? 0) as int,
        createdAt: (j['created_at'] ?? '') as String,
        updatedAt: (j['updated_at'] ?? '') as String,
        failReason: j['fail_reason'] as String?,
        cancelRequested: (j['cancel_requested'] ?? false) as bool,
        boundBaiduUid: j['bound_baidu_uid'] as String?,
        binding: j['binding'] == null
            ? null
            : AdminTaskBinding.fromJson(j['binding'] as Map<String, dynamic>),
        cancelReason: j['cancel_reason'] as String?,
        retryCount: (j['retry_count'] ?? 0) as int,
        enumDone: (j['enum_done'] ?? false) as bool,
        dispatchedAt: j['dispatched_at'] as String?,
        roundStartedAt: j['round_started_at'] as String?,
        leaseUntil: j['lease_until'] as String?,
        runnerId: j['runner_id'] as String?,
      );

  final String? boundBaiduUid;
  final AdminTaskBinding? binding;
  final String? cancelReason;
  final int retryCount;
  final bool enumDone;
  final String? dispatchedAt;
  final String? roundStartedAt;
  final String? leaseUntil;
  final String? runnerId;
}

/// 任务分页(AdminBaiduTasksPage;排序固定 created_at DESC, id DESC)。
class AdminBaiduTasksPage {
  AdminBaiduTasksPage({required this.items, required this.total});

  factory AdminBaiduTasksPage.fromJson(Map<String, dynamic> j) =>
      AdminBaiduTasksPage(
        items: ((j['items'] ?? const []) as List)
            .map((e) => AdminBaiduTask.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: (j['total'] ?? 0) as int,
      );

  final List<AdminBaiduTask> items;
  final int total;
}

/// AdminBaiduTaskFileOut(文件明细行;last_error 已截 200)。extends
/// BaiduFileOpRow(B9:与用户侧 manifest 行共用文件级三操作判定/文案/执行链,
/// isKeyConflict 判定继承同源)。
class AdminBaiduTaskFile extends BaiduFileOpRow {
  AdminBaiduTaskFile({
    required this.id,
    required this.sourcePath,
    required this.relPath,
    required this.status,
    this.bytesDone = 0,
    this.attempts = 0,
    this.nonRetryable = false,
    this.lastError,
    this.assetId,
    required this.updatedAt,
  });

  factory AdminBaiduTaskFile.fromJson(Map<String, dynamic> j) =>
      AdminBaiduTaskFile(
        id: j['id'] as String,
        sourcePath: (j['source_path'] ?? '') as String,
        relPath: (j['rel_path'] ?? '') as String,
        status: (j['status'] ?? '') as String,
        bytesDone: (j['bytes_done'] ?? 0) as int,
        attempts: (j['attempts'] ?? 0) as int,
        nonRetryable: (j['non_retryable'] ?? false) as bool,
        lastError: j['last_error'] as String?,
        assetId: j['asset_id'] as String?,
        updatedAt: (j['updated_at'] ?? '') as String,
      );

  @override
  final String id;
  final String sourcePath;
  final String relPath;
  @override
  final String status;
  final int bytesDone;
  final int attempts;
  @override
  final bool nonRetryable;
  @override
  final String? lastError;
  final String? assetId;
  final String updatedAt;
}

/// 文件明细分页(AdminBaiduTaskFilesPage;排序固定 rel_path, id)。
class AdminBaiduTaskFilesPage {
  AdminBaiduTaskFilesPage({required this.items, required this.total});

  factory AdminBaiduTaskFilesPage.fromJson(Map<String, dynamic> j) =>
      AdminBaiduTaskFilesPage(
        items: ((j['items'] ?? const []) as List)
            .map((e) => AdminBaiduTaskFile.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: (j['total'] ?? 0) as int,
      );

  final List<AdminBaiduTaskFile> items;
  final int total;
}

/// BaiduReviveOut(文件级三操作 202 响应;status=复活后入队状态,恒 enumerating)。
class BaiduReviveOut {
  BaiduReviveOut({required this.finalized, required this.status});

  factory BaiduReviveOut.fromJson(Map<String, dynamic> j) => BaiduReviveOut(
        finalized: (j['finalized'] ?? false) as bool,
        status: (j['status'] ?? '') as String,
      );

  final bool finalized;
  final String status;
}
