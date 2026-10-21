/// 百度任务文件级三操作入口判定与确认文案(B8 功能点 7;B9 起域中立复用:
/// admin 明细行与用户侧 manifest 行经 BaiduFileOpRow 最小契约共用本文件,
/// web BaiduTaskDetail 处置手册语义移动版):key_conflict 失败行分流为
/// 【覆盖导入】【随机后缀导入】(原样重试必然再撞同一冲突);普通失败行走
/// 【重试】,non_retryable 置灰(结构性失败重试无法自愈)。端点=用户侧
/// /backup/tasks/{id}/files/{fid}/*,默认经 AdminBaiduApi,用户页注入 invoke。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';

/// key_conflict 前缀(后端 KEY_CONFLICT_PREFIX;last_error 格式
/// `{key} 已被 {names}占用`,F1 点名占用者)。
const kKeyConflictPrefix = 'key_conflict:';

/// 行操作可用性(纯函数;web BaiduTaskDetail 操作列 render 同口径)。
class FileActionPlan {
  const FileActionPlan({
    required this.canRetry,
    required this.canOverwrite,
    required this.canResolveConflict,
  });

  /// 普通失败行:重试(任务须 failed;行 non_retryable 由 UI 置灰)。
  final bool canRetry;

  /// skipped_exists 行(任务 failed/completed):覆盖导入。
  final bool canOverwrite;

  /// key_conflict 失败行:覆盖导入 + 随机后缀导入两条出路。
  final bool canResolveConflict;

  bool get hasAny => canRetry || canOverwrite || canResolveConflict;
}

/// 域中立判定(用户侧/明细页共用):taskStatus=任务当前状态。
FileActionPlan fileRowActionPlan(String taskStatus, BaiduFileOpRow row) {
  final isKeyConflict = row.isKeyConflict;
  final taskResolvable = taskStatus == 'failed' || taskStatus == 'completed';
  return FileActionPlan(
    canRetry:
        taskStatus == 'failed' && row.status == 'failed' && !isKeyConflict,
    canOverwrite: taskResolvable && row.status == 'skipped_exists',
    canResolveConflict: isKeyConflict && taskResolvable,
  );
}

/// admin 明细行口径(B8 调用面不变)。
FileActionPlan fileActionPlan(AdminBaiduTask task, AdminBaiduTaskFile row) =>
    fileRowActionPlan(task.status, row);

/// 文件级三操作归属者闸门(P2-4):三端点挂用户侧 _own_task 守门,admin 仅对
/// 本人任务可操作、他人任务必 404;UI 渲染操作前先比对任务归属者与当前登录者,
/// 非本人置灰 + 提示,避免必然失败的点击。currentUserId 传 session.me?.id。
bool fileOpsAllowed(AdminBaiduTask task, String? currentUserId) =>
    currentUserId != null && task.user.id == currentUserId;

const _kHolderMarker = ' 已被 ';
const _kHolderTerminator = '占用';
const _kRecycleSuffix = '(回收站)';

/// 从 key_conflict last_error 解析占用者文件名(F1 格式;解析失败回 null
/// → 确认文案回落通用版,web keyConflictHolders 同口径:右锚 lastIndexOf
/// 躲开名内「已被」字样,无终止符/空名=截断不可信一并回退)。
List<String>? keyConflictHolders(String? lastError) {
  if (lastError == null) return null;
  final idx = lastError.lastIndexOf(_kHolderMarker);
  if (idx < 0) return null;
  var segment = lastError.substring(idx + _kHolderMarker.length);
  if (!segment.endsWith(_kHolderTerminator)) return null;
  segment = segment.substring(0, segment.length - _kHolderTerminator.length);
  if (segment.isEmpty) return null;
  final holders = segment
      .split('、')
      .map((s) => s.endsWith(_kRecycleSuffix)
          ? s.substring(0, s.length - _kRecycleSuffix.length).trim()
          : s.trim())
      .where((s) => s.isNotEmpty && !s.contains(_kHolderMarker))
      .toList();
  return holders.isNotEmpty ? holders : null;
}

/// 行操作确认文案(标题, 内容):key_conflict 行点名将被删除的占用者文件。
(String, String) confirmText(BaiduFileOpRow row, FileActionPlan plan) {
  if (plan.canResolveConflict) {
    final holders = keyConflictHolders(row.lastError);
    return (
      '覆盖导入?',
      holders == null
          ? '该文件的存储位置已被其他资产占用,将永久删除占用原文件后重新导入'
              '(需对该文件有管理权限)。'
          : '将永久删除目标位置的原文件:${holders.join('、')},然后重新导入'
              '(需对该文件有管理权限)。'
    );
  }
  return (
    '覆盖导入?',
    '将永久删除目标位置的原文件后重新导入(需对该文件有管理权限);'
        '同一任务同时只能有一个覆盖在途。'
  );
}

const kRandomSuffixTip = '换一个不冲突的存储位置重新导入(网盘原文件名不变)';

const kNonRetryableTip = '结构性失败(路径/文件名超限等),重试无法恢复,'
    '请通知任务归属者删除任务后拆分重建';

/// 执行行操作(确认 → 调用户侧端点 → toast;404=非本人任务 / 409 状态或
/// 准入不满足,detail 原样透传)。返回是否成功(调用方据此刷新明细)。
/// [invoke] 缺省走 AdminBaiduApi(B8 admin 明细页);用户侧页(B9)注入
/// BaiduApi 同端点封装,语义与路径一致。
Future<bool> runFileAction(
  BuildContext context, {
  required String taskId,
  required String taskStatus,
  required BaiduFileOpRow row,
  required String action, // retry / overwrite / random-suffix
  Future<void> Function(String action)? invoke,
}) async {
  final plan = fileRowActionPlan(taskStatus, row);
  if (!plan.hasAny) return false;
  // 确认仅覆盖导入类破坏性操作(web Popconfirm 同口径);retry / random-suffix
  // 直发(web 同款——换 key 不删任何已有文件)
  if (action == 'overwrite') {
    final (title, content) = confirmText(row, plan);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(foregroundColor: Tk.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return false;
  }
  Future<void> call(String a) async {
    final inv = invoke;
    if (inv != null) return inv(a);
    switch (a) {
      case 'retry':
        await session.api!.adminBaidu.retryFile(taskId, row.id);
      case 'overwrite':
        await session.api!.adminBaidu.overwriteFile(taskId, row.id);
      case 'random-suffix':
        await session.api!.adminBaidu.randomSuffixFile(taskId, row.id);
    }
  }

  try {
    await call(action);
    if (!context.mounted) return true;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已提交,任务复活入队(清单准备中)')));
    return true;
  } on ApiException catch (e) {
    // 404(他人任务,_own_task 守门)/409(non_retryable/状态不满足)/
    // 502 百度侧错误:detail 原样透传
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(e.message)));
    return false;
  } catch (e) {
    if (!context.mounted) return false;
    // 传输层异常中文兜底(§4.1 勿渲染原始异常对象)
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errorMessage(e, '操作失败,请稍后重试'))));
    return false;
  }
}
