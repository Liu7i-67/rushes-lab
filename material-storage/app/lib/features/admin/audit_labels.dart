/// 审计展示常量(B8;web AdminAuditPage EVENT_TYPES / labels.ts 映射对齐):
/// 事件类型筛选全集(56 项,后端任意字符串精确匹配无白名单——新增写入点须回补)
/// 与粗分类配色(details 键中文 label 桌面已有,移动端仅挑高频键,缺省回落裸键)。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// event_type 过滤全集(web AdminAuditPage 同款,含首位 '' = 全部)。
const kAuditEventTypes = <String>[
  '', 'upload', 'download', 'signed_url_issued',
  'approval_submitted', 'approval_state_changed',
  'access_denied',
  'project_created', 'project_deleted', 'project_restored',
  'project_member_added', 'project_member_removed',
  'user_created', 'user_updated',
  'group_member_added', 'group_member_removed',
  'folder_created', 'sensitive_folder_invited', 'sensitive_folder_revoked',
  'folder_template_changed', 'folder_template_applied',
  'share_link_created', 'share_link_accessed',
  // 备份类(11)
  'baidu_bind', 'baidu_unbind', 'baidu_task_create', 'baidu_task_cancel',
  'baidu_task_delete', 'baidu_task_retry', 'baidu_file_retry',
  'baidu_file_overwrite', 'baidu_file_random_suffix', 'baidu_file_imported',
  'baidu_task_auto_finalized',
  // 文件类(8)
  'asset_deleted', 'asset_restored', 'asset_purged',
  'asset.tag_updated', 'asset.batch_renamed',
  'download_denied', 'proxy_download', 'folder_deleted',
  // 用户/组(7)
  'user_disabled', 'user_enabled', 'user_password_reset',
  'group_created', 'group_updated', 'group_deleted', 'password_changed',
  // 登录/通知(3)
  'local_login_success', 'local_login_failed', 'notification_sent',
  // 权限模板/目录/授权(4)
  'folder_grant_added', 'folder_grant_removed', 'grant_template_changed',
  'grant_revoked',
  // 六项优化(2026-10-17)与后续批次回填
  'user_login_unlocked', 'local_login_locked',
  'folder_renamed', 'folder_moved', 'asset_batch_moved',
];

/// details 高频键 → 中文 label(C 包白名单制,缺 key 回落裸键,不会错)。
const kAuditDetailKeyLabels = <String, String>{
  'folder_id': '目录',
  'target_folder_id': '目标目录',
  'parent_folder_id': '父目录',
  'old_parent_folder_id': '原父目录',
  'new_parent_folder_id': '新父目录',
  'group_id': '用户组',
  'user_id': '用户',
  'sharer_user_id': '分享者',
  'subject': '主体',
  'role': '角色',
  'task_id': '任务',
  'file_id': '备份文件',
  'source_dir': '源目录',
  'reason': '原因',
  'username': '登录名',
  'name': '名称',
  'old_name': '原名称',
  'new_name': '新名称',
  'action': '动作',
  'filename': '文件名',
  'changes': '变更内容',
  'status': '状态',
  'fail_reason': '失败原因',
  'email': '邮箱',
  'via': '来源',
};

/// event_type → 粗分类色(web eventColor 同规则)。
Color auditEventColor(String eventType) {
  if (eventType.startsWith('access_denied')) return Tk.red;
  if (eventType.startsWith('baidu_')) return Tk.green;
  if (eventType.contains('approval')) return Tk.amber;
  if (eventType.startsWith('share') || eventType.startsWith('signed_url')) {
    return Tk.green;
  }
  if (eventType.startsWith('upload') || eventType.startsWith('download')) {
    return Tk.accent;
  }
  if (eventType.contains('project') ||
      eventType.contains('folder') ||
      eventType.contains('invite')) {
    return Tk.fg;
  }
  return Tk.muted;
}
