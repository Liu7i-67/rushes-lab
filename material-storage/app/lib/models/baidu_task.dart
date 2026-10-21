/// 百度备份用户侧域契约(B9 §8.10;api/app/models/__init__.py BaiduNetdisk*/
/// BaiduTask*/BaiduTasksPage/BaiduTaskFile*/BaiduTasksPage/BaiduCancelOut 实码)。
/// BaiduFileOpRow 是 B8 文件级三操作(baidu_file_actions.dart)的行最小契约,
/// admin 明细行(AdminBaiduTaskFile)与本域 manifest 行共用判定/文案/执行链。
library;

/// 文件级行操作所需最小面:id/status/non_retryable/last_error(+isKeyConflict)。
abstract class BaiduFileOpRow {
  const BaiduFileOpRow();

  String get id;
  String get status;
  bool get nonRetryable;
  String? get lastError;

  /// key_conflict 失败行(last_error 以 `key_conflict:` 开头,后端
  /// format_key_conflict_message F1 格式点名占用者)。
  bool get isKeyConflict =>
      status == 'failed' && (lastError?.startsWith('key_conflict:') ?? false);
}

/// BaiduNetdiskFolderOut — 网盘目录树条目(目录+文件两态;文件行前端灰显
/// 不可选,保持「选目录创建任务」语义)。
class BaiduNetdiskEntry {
  BaiduNetdiskEntry({
    required this.path,
    required this.name,
    required this.isDir,
    this.sizeBytes,
  });

  factory BaiduNetdiskEntry.fromJson(Map<String, dynamic> j) =>
      BaiduNetdiskEntry(
        path: (j['path'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        isDir: (j['is_dir'] ?? true) as bool,
        sizeBytes: j['size_bytes'] as int?,
      );

  /// 完整绝对路径(目录即选定 source_dir;文件行仅展示)。
  final String path;
  final String name;
  final bool isDir;
  final int? sizeBytes; // 目录恒 null;文件缺省按 0
}

/// BaiduNetdiskFoldersOut — 懒加载响应;truncated=true 提示「目录过大」。
class BaiduNetdiskFolders {
  BaiduNetdiskFolders({required this.list, this.truncated = false});

  factory BaiduNetdiskFolders.fromJson(Map<String, dynamic> j) =>
      BaiduNetdiskFolders(
        list: ((j['list'] ?? const []) as List)
            .map((e) => BaiduNetdiskEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        truncated: (j['truncated'] ?? false) as bool,
      );

  final List<BaiduNetdiskEntry> list;

  /// 后端聚合页数上限内未取尽(前端提示,不拦其余操作)。
  final bool truncated;
}

/// BaiduTaskOut — 用户侧任务(queued/eta_seconds/retryable_failed_files 为
/// 接口派生;进度统计 enumerating 阶段聚合列为 NULL → 按 0 兜底)。
class BaiduTask {
  BaiduTask({
    required this.id,
    required this.sourceDir,
    required this.projectId,
    this.projectName,
    this.targetFolderId,
    this.targetFolderName,
    this.targetAutoCreated = false,
    required this.status,
    this.queued = false,
    this.failReason,
    this.cancelRequested = false,
    this.totalFiles,
    this.doneFiles,
    this.failedFiles,
    this.skippedFiles,
    this.cancelledFiles,
    this.totalBytes,
    this.doneBytes = 0,
    this.etaSeconds,
    this.retryableFailedFiles,
    required this.createdAt,
    required this.updatedAt,
    this.crossProjectPrefixOverlap = false,
    this.overlapProjectNames,
  });

  factory BaiduTask.fromJson(Map<String, dynamic> j) => BaiduTask(
        id: j['id'] as String,
        sourceDir: (j['source_dir'] ?? '') as String,
        projectId: j['project_id'] as String,
        projectName: j['project_name'] as String?,
        targetFolderId: j['target_folder_id'] as String?,
        targetFolderName: j['target_folder_name'] as String?,
        targetAutoCreated: (j['target_auto_created'] ?? false) as bool,
        status: (j['status'] ?? '') as String,
        queued: (j['queued'] ?? false) as bool,
        failReason: j['fail_reason'] as String?,
        cancelRequested: (j['cancel_requested'] ?? false) as bool,
        totalFiles: j['total_files'] as int?,
        doneFiles: j['done_files'] as int?,
        failedFiles: j['failed_files'] as int?,
        skippedFiles: j['skipped_files'] as int?,
        cancelledFiles: j['cancelled_files'] as int?,
        totalBytes: j['total_bytes'] as int?,
        doneBytes: (j['done_bytes'] ?? 0) as int,
        etaSeconds: j['eta_seconds'] as int?,
        retryableFailedFiles: j['retryable_failed_files'] as int?,
        createdAt: (j['created_at'] ?? '') as String,
        updatedAt: (j['updated_at'] ?? '') as String,
        crossProjectPrefixOverlap:
            (j['cross_project_prefix_overlap'] ?? false) as bool,
        overlapProjectNames: (j['overlap_project_names'] as List?)
            ?.map((e) => e as String)
            .toList(),
      );

  final String id;
  final String sourceDir;
  final String projectId;
  final String? projectName; // 项目已删 → null,展示回退 projectId
  final String? targetFolderId;
  final String? targetFolderName; // null = 目标夹已删除(显示「(已删除)」)
  final bool targetAutoCreated;
  final String status; // enumerating/running/completed/cancelled/failed
  final bool queued; // 派生态:活动中但当前无 runner 实际推进(显示「排队中」)
  final String? failReason;
  final bool cancelRequested;
  final int? totalFiles;
  final int? doneFiles;
  final int? failedFiles;
  final int? skippedFiles;
  final int? cancelledFiles;
  final int? totalBytes;
  final int doneBytes;
  final int? etaSeconds; // speed_bps<=0 → null(「估算中」)
  final int? retryableFailedFiles; // failed 且 non_retryable=false 行数
  final String createdAt;
  final String updatedAt;

  /// W1 创建时刻跨项目前缀重叠预警(仅创建响应回填)。
  final bool crossProjectPrefixOverlap;
  final List<String>? overlapProjectNames;

  bool get isActive => status == 'enumerating' || status == 'running';
  bool get isTerminal => !isActive;

  /// 展示态(§3.1 口径):活动中但 queued=true 显示「排队中」。
  String get displayStatus =>
      queued && isActive ? 'queued' : status;

  /// 进度百分比(web TaskItem 同口径:done/total;completed 空目录=100)。
  int get progressPct {
    final total = totalFiles ?? 0;
    final done = doneFiles ?? 0;
    return total > 0 ? (done * 100 / total).round() : (status == 'completed' ? 100 : 0);
  }

  /// 目标展示串(web TaskItem targetLabel 同款)。
  String get targetLabel {
    final p = projectName ?? projectId;
    if (targetFolderName != null) return '$p / $targetFolderName';
    return targetAutoCreated ? '$p / 项目根(自动创建承接夹)' : '$p / (已删除)';
  }

  /// 「全部重试失败」可用性(§3.1:failed 且存在可重试行;列表未回传行数时
  /// 回退 failed_files>0,web 同款)。
  bool get canRetryFailed {
    if (status != 'failed') return false;
    final n = retryableFailedFiles;
    return n != null ? n > 0 : (failedFiles ?? 0) > 0;
  }
}

/// BaiduTasksPage — 任务分页(created_at DESC, id DESC 稳定排序)。
class BaiduTasksPage {
  BaiduTasksPage({required this.items, required this.total});

  factory BaiduTasksPage.fromJson(Map<String, dynamic> j) => BaiduTasksPage(
        items: ((j['items'] ?? const []) as List)
            .map((e) => BaiduTask.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: (j['total'] ?? 0) as int,
      );

  final List<BaiduTask> items;
  final int total;
}

/// BaiduTaskFileOut — manifest 行(target_path 两级回退拼装;皆 null =
/// 目标已删除,前端回退源路径+标注)。
class BaiduTaskFile extends BaiduFileOpRow {
  BaiduTaskFile({
    required this.id,
    required this.fsId,
    required this.sourcePath,
    required this.sourceSize,
    required this.relPath,
    this.targetPath,
    required this.status,
    this.bytesDone = 0,
    this.attempts = 0,
    this.nonRetryable = false,
    this.lastError,
    this.assetId,
  });

  factory BaiduTaskFile.fromJson(Map<String, dynamic> j) => BaiduTaskFile(
        id: j['id'] as String,
        fsId: (j['fs_id'] ?? 0) as int,
        sourcePath: (j['source_path'] ?? '') as String,
        sourceSize: (j['source_size'] ?? 0) as int,
        relPath: (j['rel_path'] ?? '') as String,
        targetPath: j['target_path'] as String?,
        status: (j['status'] ?? '') as String,
        bytesDone: (j['bytes_done'] ?? 0) as int,
        attempts: (j['attempts'] ?? 0) as int,
        nonRetryable: (j['non_retryable'] ?? false) as bool,
        lastError: j['last_error'] as String?,
        assetId: j['asset_id'] as String?,
      );

  @override
  final String id;
  final int fsId;
  final String sourcePath;
  final int sourceSize;
  final String relPath;

  /// 预计导入路径;null = 目标已删除(UI 回退源路径 +「(目标已删除)」)。
  final String? targetPath;

  @override
  final String status;
  final int bytesDone;
  final int attempts;
  @override
  final bool nonRetryable;
  @override
  final String? lastError;
  final String? assetId;

  /// 展示用目标路径(回退源路径并标注目标已删除)。
  String get targetDisplay => targetPath ?? '$sourcePath(目标已删除)';
}

/// BaiduTaskFilesPage — manifest 分页(排序 rel_path, id)。
class BaiduTaskFilesPage {
  BaiduTaskFilesPage({required this.items, required this.total});

  factory BaiduTaskFilesPage.fromJson(Map<String, dynamic> j) =>
      BaiduTaskFilesPage(
        items: ((j['items'] ?? const []) as List)
            .map((e) => BaiduTaskFile.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: (j['total'] ?? 0) as int,
      );

  final List<BaiduTaskFile> items;
  final int total;
}

/// BaiduCancelOut — cancel 202 响应:finalized=true=API 已直接终态化,
/// false=交 worker 消费(toast 文案区分)。
class BaiduCancelOut {
  BaiduCancelOut({required this.finalized});

  factory BaiduCancelOut.fromJson(Map<String, dynamic> j) =>
      BaiduCancelOut(finalized: (j['finalized'] ?? false) as bool);

  final bool finalized;
}
